import SpeakerRecognition
import DictationLibrary
import Foundation
import Observation
import SpeechKit

enum DictationProfileSource: Equatable {
    case sharedProfile(DictationProfile)
    case unverifiedProfile
    case localSettings
}

enum SpokenLanguagesOwner: Equatable {
    enum Unavailable: Equatable {
        case checking
        case signedOut
        case unreachable
        case noSharedProfile
    }

    case local
    case profile([String])
    case unavailable(Unavailable)

    func languages(local: [String]) -> [String] {
        switch self {
        case .local: local
        case .profile(let languages): languages
        case .unavailable: []
        }
    }

    func edit(_ languages: [String]) -> SpokenLanguagesEdit {
        switch self {
        case .local: languages.isEmpty ? .ignored : .local(languages)
        case .profile: .profile(languages)
        case .unavailable: .ignored
        }
    }
}

enum SpokenLanguagesEdit: Equatable {
    case local([String])
    case profile([String])
    case ignored
}

@MainActor
@Observable
final class UnifiedDictationLibrary {
    let store: DictationLibraryStore
    let rootDirectory: URL
    private(set) var profile: DictationProfile?
    private(set) var profileState: DictationProfileState = .unverified
    private(set) var isRefreshing = false
    @ObservationIgnored private lazy var profileWriter = DictationProfileWriter(remote: store) { [weak self] account in
        await self?.profileSaved(account: account)
    }
    private var captures: [UUID: DictationCaptureWriter] = [:]
    private var historyResults: [UUID: DictationResultVersion] = [:]
    private var plans: [UUID: (plan: DictationPlan, session: DictationAccountSession?)] = [:]
    private var archivalConsentKnown = UserDefaults.standard.bool(forKey: "dictationArchiveConsent")
    private(set) var accountSession: DictationAccountSession?
    private(set) var heldCaptures: [DictationHeldCapture] = []
    private(set) var entries: [DictationArchiveEntry] = []
    private(set) var publicationStatus: DictationPublicationStatus?
    private(set) var archiveRefreshedAt: Date?
    private(set) var lastExportURL: URL?
    var lastError: String?
    var archiveRoleEnabled: Bool {
        didSet {
            UserDefaults.standard.set(archiveRoleEnabled, forKey: "dictationArchiveRoleEnabled")
            onArchiveRoleChanged()
        }
    }
    @ObservationIgnored private var publicationRequested = false
    @ObservationIgnored private var publicationTask: Task<DictationPublicationStatus, any Error>?
    @ObservationIgnored private let background: any DictationBackgroundExecution
    @ObservationIgnored private lazy var work = DictationLibraryWork(background: background) { [weak self] in
        self?.publicationTask?.cancel()
    }
    private var accountTask: Task<Void, Never>?
    private var reader: DictationArchive?
    private let vocabulary: @MainActor () -> [String]
    private let onAccountChange: @MainActor (DictationAccountSession?) -> Void
    private let onExportRequested: @MainActor () async throws -> URL
    private let onArchiveRoleChanged: @MainActor () -> Void

    static func makeStore(rootDirectory: URL) throws -> DictationLibraryStore {
        try DictationLibraryStore(
            directory: rootDirectory.appendingPathComponent("UnifiedDictation", isDirectory: true),
            source: "wisprclone", capacityBytes: 512 * 1_024 * 1_024, containerIdentifier: MumlaDataStore.cloudContainerIdentifier
        )
    }

    init(store: DictationLibraryStore,
         rootDirectory: URL,
         background: any DictationBackgroundExecution,
         vocabulary: @escaping @MainActor () -> [String],
         onAccountChange: @escaping @MainActor (DictationAccountSession?) -> Void,
         onExportRequested: @escaping @MainActor () async throws -> URL,
         onArchiveRoleChanged: @escaping @MainActor () -> Void) {
        self.background = background
        self.store = store
        self.rootDirectory = rootDirectory
        self.vocabulary = vocabulary
        self.onAccountChange = onAccountChange
        self.onExportRequested = onExportRequested
        self.onArchiveRoleChanged = onArchiveRoleChanged
        archiveRoleEnabled = UserDefaults.standard.bool(forKey: "dictationArchiveRoleEnabled")
        accountTask = Task { [weak self] in
            for await session in await store.accountEvents() {
                guard let self else { return }
                applyAccountSession(session)
            }
        }
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            heldCaptures = try await store.heldCaptures().filter { $0.reason == .unverifiedPlan }
            let snapshot = try await store.refresh()
            let session = store.accountSession()
            let state = await store.profileState()
            if let session { try store.validateAccountSession(session) }
            guard store.accountSession() == session else { throw DictationLibraryError.accountChanged }
            applyAccountSession(session)
            profile = snapshot?.profile
            profileState = state
            if let profile {
                archivalConsentKnown = profile.archiveEnabled
                UserDefaults.standard.set(profile.archiveEnabled, forKey: "dictationArchiveConsent")
            }
            for entry in try await store.entries() where plans[entry.id] == nil {
                plans[entry.id] = (entry.capture.plan, session)
            }
            publicationStatus = try await publish()
            heldCaptures = try await store.heldCaptures().filter { $0.reason == .unverifiedPlan }
            lastError = nil
        } catch {
            profileState = await store.profileState()
            publicationStatus = try? await store.status()
            if !(error is CancellationError) { lastError = error.localizedDescription }
        }
    }

    private func applyAccountSession(_ session: DictationAccountSession?) {
        guard accountSession != session else { return }
        accountSession = session
        profile = nil
        historyResults = [:]
        profileState = .unverified
        entries = []
        archiveRefreshedAt = nil
        lastExportURL = nil
        publicationStatus = nil
        lastError = nil
        reader = nil
        profileWriter.accountChanged()
        onAccountChange(session)
    }

    var languagesSave: SpokenLanguagesSave? { profileWriter.languagesSave }

    func retrySpokenLanguages() {
        guard profileWriter.retryLanguages(account: accountSession) == nil else { return }
        Task {
            await refresh()
            profileWriter.retryLanguages(account: accountSession)
        }
    }

    func updateProfile(_ edit: DictationProfileEdit, account: DictationAccountSession, creatingFrom base: DictationProfile) async throws {
        try await profileWriter.submit(edit, account: account, creatingFrom: base).value
    }

    private func profileSaved(account: DictationAccountSession) async {
        guard accountSession == account else { return }
        do { try store.validateAccountSession(account) } catch { return }
        profileState = await store.profileState()
        if case .ready(let snapshot) = profileState {
            profile = snapshot.profile
            archivalConsentKnown = snapshot.profile.archiveEnabled
            UserDefaults.standard.set(snapshot.profile.archiveEnabled, forKey: "dictationArchiveConsent")
        }
        publicationStatus = try? await store.status()
    }

    func spokenLanguagesOwner(iCloudSignedOut: Bool) -> SpokenLanguagesOwner {
        if case .saving(let languages) = profileWriter.languagesSave { return .profile(languages) }
        return Self.spokenLanguagesOwner(for: profileState, archivalConsentKnown: archivalConsentKnown, iCloudSignedOut: iCloudSignedOut)
    }

    func editSpokenLanguages(_ languages: [String], iCloudSignedOut: Bool) throws -> SpokenLanguagesEdit {
        let edit = spokenLanguagesOwner(iCloudSignedOut: iCloudSignedOut).edit(languages)
        guard case .profile(let languages) = edit else { return edit }
        guard let accountSession else {
            profileWriter.failWithoutAccount(languages)
            throw DictationLibraryError.accountUnavailable
        }
        profileWriter.saveLanguages(languages, account: accountSession)
        return edit
    }

    nonisolated static func dictationProfileSource(for state: DictationProfileState, archivalConsentKnown: Bool) -> DictationProfileSource {
        if case .ready(let snapshot) = state { return .sharedProfile(snapshot.profile) }
        return archivalConsentKnown ? .unverifiedProfile : .localSettings
    }

    nonisolated static func spokenLanguagesOwner(for state: DictationProfileState, archivalConsentKnown: Bool, iCloudSignedOut: Bool) -> SpokenLanguagesOwner {
        switch dictationProfileSource(for: state, archivalConsentKnown: archivalConsentKnown) {
        case .sharedProfile(let profile): .profile(profile.languages)
        case .localSettings: .local
        case .unverifiedProfile:
            switch state {
            case .absent: .unavailable(.noSharedProfile)
            case .unavailable: .unavailable(iCloudSignedOut ? .signedOut : .unreachable)
            case .unverified, .ready: .unavailable(.checking)
            }
        }
    }

    func reconcileHeldCapture(_ id: UUID, expectedAccount: DictationAccountSession) async throws {
        try await store.reconcileHeldCapture(id: id, session: expectedAccount)
        heldCaptures = try await store.heldCaptures().filter { $0.reason == .unverifiedPlan }
        publicationStatus = try await publish()
        try await refreshArchive()
    }

    static func capabilities() throws -> DictationCapabilities {
        let model = TranscriptionProviderType.dictation.libraryModelID
        return try DictationCapabilities(
            models: [model], fallbackModel: model, supportsCleanup: false,
            modelOptions: [model: ["transcribeStyle": "clean"]]
        )
    }

    nonisolated struct PreparedCapture: Sendable {
        let id: UUID
        let plan: DictationPlan
        let writer: DictationCaptureWriter?
        let library: UnifiedDictationLibrary
    }

    func prepareCapture(context: DictationContext) async throws -> PreparedCapture? {
        let frozenSession = accountSession
        let capabilities = try Self.capabilities()
        let plan: DictationPlan
        switch Self.dictationProfileSource(for: await store.profileState(), archivalConsentKnown: archivalConsentKnown) {
        case .sharedProfile:
            plan = try await currentPlan(context: context)
            guard store.accountSession() == frozenSession, accountSession == frozenSession else { throw DictationLibraryError.accountChanged }
        case .unverifiedProfile:
            var localProfile = DictationProfile(languages: [], dictionary: [])
            localProfile.archiveEnabled = true
            plan = DictationPlan(unverifiedProfile: localProfile, context: context, capabilities: capabilities)
        case .localSettings:
            return nil
        }
        let writer = plan.archiveEnabled ? try await store.beginCapture(plan: plan) : nil
        let id = writer?.id ?? UUID()
        if let writer { captures[id] = writer }
        plans[id] = (plan, frozenSession)
        return PreparedCapture(id: id, plan: plan, writer: writer, library: self)
    }

    private func currentPlan(context: DictationContext) async throws -> DictationPlan {
        guard accountSession != nil else { throw DictationLibraryError.accountUnavailable }
        return try await store.makePlan(context: context, capabilities: try Self.capabilities(), dictionary: vocabulary())
    }

    func refreshArchive() async throws {
        try await refreshCatalog()
        if archiveRoleEnabled {
            let reader = try archiveReader()
            try await retainOriginals(reader: reader, entries: try await reader.entries())
        }
    }

    func refreshCatalog() async throws {
        guard let session = accountSession else { throw DictationLibraryError.accountUnavailable }
        try store.validateAccountSession(session)
        let reader = try archiveReader()
        try await reader.refresh()
        try await reader.publishPendingResults(session: session)
        let remote = try await reader.entries()
        let local = try await store.entries()
        try store.validateAccountSession(session)
        var combined = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        for entry in local {
            combined[entry.id] = try combined[entry.id].map { try Self.merge(local: entry, remote: $0) } ?? entry
        }
        entries = combined.values.sorted { $0.capture.startedAt > $1.capture.startedAt }
        archiveRefreshedAt = .now
    }

    nonisolated static func merge(local: DictationArchiveEntry, remote: DictationArchiveEntry) throws -> DictationArchiveEntry {
        guard local.id == remote.id else { throw DictationLibraryError.contentConflict(local.id.uuidString) }
        var results = Dictionary(uniqueKeysWithValues: remote.results.map { ($0.id, $0) })
        for result in local.results {
            if let existing = results[result.id], existing != result { throw DictationLibraryError.contentConflict(result.id.uuidString) }
            results[result.id] = result
        }
        return DictationArchiveEntry(capture: local.capture, results: results.values.sorted { $0.createdAt < $1.createdAt },
            originalURL: local.originalURL ?? remote.originalURL, published: local.published || remote.published)
    }

    func original(for id: UUID) async throws -> URL {
        guard let session = accountSession else { throw DictationLibraryError.accountUnavailable }
        try store.validateAccountSession(session)
        if try await store.ownership(ofCapture: id) == .otherAccount { throw DictationLibraryError.accountChanged }
        if let writer = captures[id], FileManager.default.fileExists(atPath: writer.originalURL.path) { return writer.originalURL }
        if let entry = try await store.entries().first(where: { $0.id == id }), let url = entry.originalURL,
           FileManager.default.fileExists(atPath: url.path) { return url }
        return try await archiveReader().original(for: id)
    }

    func localOriginals() async throws -> [VoiceHistoryRecording] {
        guard let session = accountSession else { throw DictationLibraryError.accountUnavailable }
        try store.validateAccountSession(session)
        return try await store.entries().compactMap { entry in
            guard let url = entry.originalURL, let finishedAt = entry.capture.finishedAt else { return nil }
            return VoiceHistoryRecording(url: url, startedAt: entry.capture.startedAt, finishedAt: finishedAt)
        }
    }

    func captureID(for originalURL: URL) -> UUID? {
        captures.first { $0.value.originalURL == originalURL }?.key
    }

    func historyResult(for captureID: UUID, text: String) -> DictationResultVersion? {
        guard let result = historyResults[captureID],
              result.text.trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return result
    }

    func plan(for id: UUID) -> DictationPlan? { plans[id]?.plan }

    func finish(_ writer: DictationCaptureWriter) async throws {
        try await work.perform {
            do {
                _ = try await writer.finish()
                requestPublication()
            } catch DictationLibraryError.noAudio {
                notice("Dictation ended without audio", metadata: ["capture_id": writer.id.uuidString])
                throw DictationLibraryError.noAudio
            }
        }
    }

    @discardableResult
    private func requestPublication() -> Task<DictationPublicationStatus, any Error> {
        publicationRequested = true
        if let publicationTask { return publicationTask }
        work.begin()
        guard work.canPublish else {
            publicationRequested = false
            work.end()
            return Task { throw CancellationError() }
        }
        let task = Task { [self] in
            defer { publicationTask = nil; publicationRequested = false; work.end() }
            do {
                var status: DictationPublicationStatus
                repeat {
                    try Task.checkCancellation()
                    publicationRequested = false
                    status = try await performPublication()
                } while publicationRequested
                return status
            } catch is CancellationError { throw CancellationError() }
            catch { lastError = error.localizedDescription; throw error }
        }
        publicationTask = task
        return task
    }

    @discardableResult
    func publish() async throws -> DictationPublicationStatus {
        try await requestPublication().value
    }

    private func performPublication() async throws -> DictationPublicationStatus {
        let start = ContinuousClock.now
        var before: DictationPublicationStatus?
        do {
            before = try await store.status()
            let after = try await store.publishPending()
            publicationStatus = after
            logPublication(before: before, after: after, start: start, error: nil)
            return after
        } catch {
            let after = try? await store.status()
            publicationStatus = after
            logPublication(before: before, after: after, start: start, error: error)
            throw error
        }
    }

    private func logPublication(before: DictationPublicationStatus?, after: DictationPublicationStatus?, start: ContinuousClock.Instant, error: (any Error)?) {
        guard error != nil || (before?.pendingCaptureCount ?? 0) > 0 || (after?.pendingCaptureCount ?? 0) > 0
            || !(after?.failures.isEmpty ?? before?.failures.isEmpty ?? true) else { return }
        let elapsed = start.duration(to: .now)
        var metadata = ["pending_before": before.map { String($0.pendingCaptureCount) } ?? "unknown",
                        "pending_after": after.map { String($0.pendingCaptureCount) } ?? "unknown",
                        "held_count": after.map { String($0.heldCaptureCount) } ?? "unknown",
                        "outcome": error == nil ? ((after?.failures.isEmpty ?? true) ? "completed" : "capture_failures") : (error is CancellationError ? "cancelled" : "failed"),
                        "failure_count": after.map { String($0.failures.count) } ?? "unknown",
                        "duration_ms": String(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)]
        for (index, failure) in (after?.failures ?? before?.failures ?? []).prefix(3).enumerated() {
            metadata["failure_\(index + 1)_capture_id"] = failure.captureID.uuidString
            for (key, value) in DiagnosticError(failure.error).metadata { metadata["failure_\(index + 1)_\(key)"] = value }
        }
        if let error { metadata.merge(DiagnosticError(error).metadata) { _, new in new } }
        notice("Dictation library publication pass", metadata: metadata)
    }

    private func notice(_ message: StaticString, metadata: [String: String]) {
        #if os(iOS)
        CrashReporting.breadcrumb(message, category: "dictation_library", metadata: metadata)
        #else
        AppDiagnostics.info(message, category: "dictation_library", metadata: metadata)
        #endif
    }

    func releaseUploadedOriginals(session: DictationAccountSession) async throws {
        try store.validateAccountSession(session)
        _ = try await store.releasePublishedOriginals(finishedBefore: .now, session: session)
        publicationStatus = try await store.status()
        try await refreshArchive()
    }

    private enum ResultDestination {
        case producer
        case archive(DictationArchive, DictationAccountSession)
    }

    @discardableResult
    private func recordProviderResult(destination: ResultDestination, captureID: UUID, text: String, model: String, plan: DictationPlan) async throws -> DictationResultVersion {
        let result = DictationResultVersion(
            id: UUID(), captureID: captureID, createdAt: .now, kind: .providerOutput,
            text: text, model: model, contextWasUsed: false, parentResultID: nil, plan: plan
        )
        work.begin()
        defer { work.end() }
        switch destination {
        case .producer:
            try await store.addResult(result)
            requestPublication()
        case .archive(let archive, let session):
            try await archive.addResult(result, session: session)
            work.begin()
            Task {
                defer { work.end() }
                do {
                    try await archive.publishPendingResults(session: session)
                    publicationStatus = try await store.status()
                } catch { lastError = error.localizedDescription }
            }
        }
        historyResults[captureID] = result
        return result
    }

    func validateProviderCapture(_ id: UUID) async throws {
        if let prepared = plans[id], !prepared.plan.archiveEnabled {
            guard let session = prepared.session else { throw DictationLibraryError.accountUnavailable }
            try store.validateAccountSession(session)
            return
        }
        switch try await store.ownership(ofCapture: id) {
        case .current: try await store.validateCapture(id: id)
        case .held:
            guard let plan = plan(for: id), plan.dictionary.isEmpty, plan.languages.isEmpty, !plan.cleanupEnabled else {
                throw DictationLibraryError.accountUnavailable
            }
        case .otherAccount: throw DictationLibraryError.accountChanged
        case .unknown: throw DictationLibraryError.invalidCapture(id)
        }
    }

    func recordProviderOutput(_ text: String, captureID: UUID, model: String) async throws {
        guard let plan = plan(for: captureID) else { return }
        if plan.archiveEnabled {
            try await recordProviderResult(destination: .producer, captureID: captureID, text: text, model: model, plan: plan)
        }
        try await validateProviderCapture(captureID)
        try Task.checkCancellation()
    }

    func retranscribe(_ id: UUID, using transcriber: AccessTranscriber) async throws
        -> (result: DictationResultVersion, source: String, unfilteredText: String?)
    {
        guard let session = accountSession else { throw DictationLibraryError.accountUnavailable }
        try store.validateAccountSession(session)
        let destination: ResultDestination
        switch try await store.ownership(ofCapture: id) {
        case .current, .held: destination = .producer
        case .unknown: destination = .archive(try archiveReader(), session)
        case .otherAccount: throw DictationLibraryError.accountChanged
        }
        guard let entry = entries.first(where: { $0.id == id }) else { throw DictationLibraryError.invalidCapture(id) }
        let plan = profile != nil ? try await currentPlan(context: entry.capture.plan.context) : entry.capture.plan
        let wav = try await OriginalAudio.providerWAV(from: original(for: id), fileType: .caf)
        try store.validateAccountSession(session)
        try Task.checkCancellation()
        let transcript = try await transcriber.transcribe(wav: wav, languageHints: plan.languages, customVocabulary: plan.dictionary)
        let result = try await recordProviderResult(destination: destination, captureID: id, text: transcript.text,
                                                    model: TranscriptionProviderType.dictation.batchResultModelID, plan: plan)
        try store.validateAccountSession(session)
        try Task.checkCancellation()
        try await refreshArchive()
        return (result, entry.capture.source, transcript.unfilteredText)
    }

    func reseedRetainedLibrary() async throws {
        guard let session = accountSession else { throw DictationLibraryError.accountUnavailable }
        try store.validateAccountSession(session)
        _ = try await store.reseedPublication(session: session)
        try store.validateAccountSession(session)
        let report = try await archiveReader().reseedPublication(session: session)
        guard report.missingOriginalCaptureIDs.isEmpty else {
            throw SpeechKitError.invalidRequest(String(localized: "Restoration is incomplete: \(report.missingOriginalCaptureIDs.count) original recordings are unavailable."))
        }
        try await profileWriter.restoreCachedProfile(account: session).value
        publicationStatus = try await publish()
    }

    func exportArchive() async throws -> URL {
        guard let session = accountSession else { throw DictationLibraryError.accountUnavailable }
        let result = try await onExportRequested()
        try store.validateAccountSession(session)
        lastExportURL = result
        return result
    }

    private func retainOriginals(reader: DictationArchive, entries: [DictationArchiveEntry]) async throws {
        let currentBytes = try await CombinedArchiveExporter.allocatedBytes(at: rootDirectory)
        let missingBytes = entries.filter { $0.originalURL == nil }.reduce(Int64(0)) { $0 + ($1.capture.originalByteCount ?? 0) }
        guard currentBytes + 2 * missingBytes <= CombinedArchiveExporter.capacityBytes else {
            throw DictationLibraryError.capacityExceeded(limit: CombinedArchiveExporter.capacityBytes, used: currentBytes)
        }
        let report = try await reader.retainAllOriginals()
        guard !report.capacityExceeded, report.failures.isEmpty else {
            throw SpeechKitError.invalidRequest(String(localized: "The archival copy is incomplete: \(report.failures.count) originals could not be retained."))
        }
    }

    func exportUnifiedArchive() async throws -> URL {
        try await refreshArchive()
        let reader = try archiveReader()
        try await retainOriginals(reader: reader, entries: try await reader.entries())
        let manifest = try await reader.export(to: rootDirectory.appendingPathComponent("DictationLibraryExports", isDirectory: true))
        return manifest.directory
    }

    private func archiveReader() throws -> DictationArchive {
        if let reader { return reader }
        let reader = try DictationArchive(
            directory: rootDirectory.appendingPathComponent("UnifiedDictationArchive", isDirectory: true),
            capacityBytes: 64 * 1_024 * 1_024 * 1_024, containerIdentifier: MumlaDataStore.cloudContainerIdentifier
        )
        self.reader = reader
        return reader
    }
}

extension DictationProfile {
    init(languages: [String], dictionary: [String]) {
        self.init(
            archiveEnabled: false, preferredModel: TranscriptionProviderType.dictation.libraryModelID,
            languages: languages, dictionary: dictionary, cleanupEnabled: false, outputLanguage: nil, thinkingLevel: "low"
        )
    }
}
