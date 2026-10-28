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
         vocabulary: @escaping @MainActor () -> [String],
         onAccountChange: @escaping @MainActor (DictationAccountSession?) -> Void,
         onExportRequested: @escaping @MainActor () async throws -> URL,
         onArchiveRoleChanged: @escaping @MainActor () -> Void) {
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
            _ = try await store.recoverInterruptedCaptures()
            heldCaptures = try await store.heldCaptures().filter { $0.reason == .unverifiedPlan }
            let snapshot = try await store.refresh()
            let session = await store.accountSession()
            let state = await store.profileState()
            if let session { try await store.validateAccountSession(session) }
            guard await store.accountSession() == session else { throw DictationLibraryError.accountChanged }
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
            try await store.publishPending()
            publicationStatus = try await store.status()
            heldCaptures = try await store.heldCaptures().filter { $0.reason == .unverifiedPlan }
            lastError = nil
        } catch {
            profileState = await store.profileState()
            publicationStatus = try? await store.status()
            lastError = error.localizedDescription
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
        do { try await store.validateAccountSession(account) } catch { return }
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
        try await store.publishPending()
        publicationStatus = try await store.status()
        try await refreshArchive()
    }

    static func capabilities() throws -> DictationCapabilities {
        let model = TranscriptionProviderType.dictation.libraryModelID
        return try DictationCapabilities(
            models: [model], fallbackModel: model, supportsCleanup: false,
            modelOptions: [model: ["transcribeStyle": "clean"]]
        )
    }

    struct PreparedCapture: Sendable {
        let id: UUID
        let plan: DictationPlan
        let writer: DictationCaptureWriter?
    }

    func prepareCapture(context: DictationContext) async throws -> PreparedCapture? {
        let frozenSession = accountSession
        let capabilities = try Self.capabilities()
        let plan: DictationPlan
        switch Self.dictationProfileSource(for: await store.profileState(), archivalConsentKnown: archivalConsentKnown) {
        case .sharedProfile:
            plan = try await currentPlan(context: context)
            guard await store.accountSession() == frozenSession, accountSession == frozenSession else { throw DictationLibraryError.accountChanged }
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
        return PreparedCapture(id: id, plan: plan, writer: writer)
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
        try await store.validateAccountSession(session)
        let reader = try archiveReader()
        try await reader.refresh()
        try await reader.publishPendingResults(session: session)
        let remote = try await reader.entries()
        let local = try await store.entries()
        try await store.validateAccountSession(session)
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
        try await store.validateAccountSession(session)
        if try await store.ownership(ofCapture: id) == .otherAccount { throw DictationLibraryError.accountChanged }
        if let writer = captures[id], FileManager.default.fileExists(atPath: writer.originalURL.path) { return writer.originalURL }
        if let entry = try await store.entries().first(where: { $0.id == id }), let url = entry.originalURL,
           FileManager.default.fileExists(atPath: url.path) { return url }
        return try await archiveReader().original(for: id)
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

    func originalDidFinish() {
        Task {
            do {
                try await store.publishPending()
                publicationStatus = try await store.status()
            } catch { lastError = error.localizedDescription }
        }
    }

    func releaseUploadedOriginals(session: DictationAccountSession) async throws {
        try await store.validateAccountSession(session)
        _ = try await store.releasePublishedOriginals(finishedBefore: .now, session: session)
        publicationStatus = try await store.status()
        try await refreshArchive()
    }

    private enum ResultDestination {
        case producer
        case archive(DictationArchive, DictationAccountSession)
    }

    private func recordProviderResult(destination: ResultDestination, captureID: UUID, text: String, model: String, plan: DictationPlan) async throws {
        let result = DictationResultVersion(
            id: UUID(), captureID: captureID, createdAt: .now, kind: .providerOutput,
            text: text, model: model, contextWasUsed: false, parentResultID: nil, plan: plan
        )
        switch destination {
        case .producer:
            try await store.addResult(result)
        case .archive(let archive, let session):
            try await archive.addResult(result, session: session)
        }
        historyResults[captureID] = result
        Task {
            do {
                switch destination {
                case .producer: try await store.publishPending()
                case .archive(let archive, let session): try await archive.publishPendingResults(session: session)
                }
                publicationStatus = try await store.status()
            } catch { lastError = error.localizedDescription }
        }
    }

    func validateProviderCapture(_ id: UUID) async throws {
        if let prepared = plans[id], !prepared.plan.archiveEnabled {
            guard let session = prepared.session else { throw DictationLibraryError.accountUnavailable }
            try await store.validateAccountSession(session)
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

    func retranscribe(_ id: UUID, using transcriber: AccessTranscriber) async throws {
        guard let session = accountSession else { throw DictationLibraryError.accountUnavailable }
        try await store.validateAccountSession(session)
        let destination: ResultDestination
        switch try await store.ownership(ofCapture: id) {
        case .current, .held: destination = .producer
        case .unknown: destination = .archive(try archiveReader(), session)
        case .otherAccount: throw DictationLibraryError.accountChanged
        }
        guard let entry = entries.first(where: { $0.id == id }) else { throw DictationLibraryError.invalidCapture(id) }
        let plan = profile != nil ? try await currentPlan(context: entry.capture.plan.context) : entry.capture.plan
        let wav = try await OriginalAudio.providerWAV(from: original(for: id), fileType: .caf)
        try await store.validateAccountSession(session)
        try Task.checkCancellation()
        let result = try await transcriber.transcribe(wav: wav, languageHints: plan.languages, customVocabulary: plan.dictionary)
        try await recordProviderResult(destination: destination, captureID: id, text: result.text, model: TranscriptionProviderType.dictation.batchResultModelID, plan: plan)
        try await store.validateAccountSession(session)
        try Task.checkCancellation()
        try await refreshArchive()
    }

    func reseedRetainedLibrary() async throws {
        guard let session = accountSession else { throw DictationLibraryError.accountUnavailable }
        try await store.validateAccountSession(session)
        _ = try await store.reseedPublication(session: session)
        try await store.validateAccountSession(session)
        let report = try await archiveReader().reseedPublication(session: session)
        guard report.missingOriginalCaptureIDs.isEmpty else {
            throw SpeechKitError.invalidRequest("Restoration is incomplete: \(report.missingOriginalCaptureIDs.count) original recordings are unavailable.")
        }
        try await profileWriter.restoreCachedProfile(account: session).value
        try await store.publishPending()
    }

    func exportArchive() async throws -> URL {
        guard let session = accountSession else { throw DictationLibraryError.accountUnavailable }
        let result = try await onExportRequested()
        try await store.validateAccountSession(session)
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
            throw SpeechKitError.invalidRequest("The archival copy is incomplete: \(report.failures.count) originals could not be retained.")
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
