import CloudKit
import DictationLibrary
import Observation
import CryptoKit
import Foundation
import OSLog
import SwiftData
#if os(iOS)
import UIKit
#endif

/// A single transcription in the history. Immutable once recorded.
@Model
nonisolated final class HistoryEntry {
    var id: UUID = UUID()
    var text: String = ""
    var createdAt: Date = Date()
    var providerDisplayName: String = ""
    var deviceName: String = ""
    var audioRecordingID: UUID?
    var isHidden: Bool = false

    #Index<HistoryEntry>([\.createdAt], [\.id])

    init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        providerDisplayName: String,
        deviceName: String,
        audioRecordingID: UUID? = nil
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.providerDisplayName = providerDisplayName
        self.deviceName = deviceName
        self.audioRecordingID = audioRecordingID
    }
}

nonisolated enum HistorySyncChangeKind: String, Codable, Sendable {
    case save
    case delete
}

/// Durable handoff between local SwiftData writes and CKSyncEngine.
@Model
nonisolated final class HistorySyncChange {
    var entryID: UUID = UUID()
    var kind: HistorySyncChangeKind = HistorySyncChangeKind.save

    #Index<HistorySyncChange>([\.entryID])

    init(entryID: UUID, kind: HistorySyncChangeKind) {
        self.entryID = entryID
        self.kind = kind
    }
}

nonisolated enum VocabularyTerm {
    private static let normalizationLocale = Locale(identifier: "en_US_POSIX")

    static func displayText(from text: String) -> String? {
        let collapsed = text.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    static func normalizedText(from text: String) -> String? {
        displayText(from: text)?
            .precomposedStringWithCanonicalMapping
            .lowercased(with: normalizationLocale)
    }

    static func identifier(forNormalizedText normalizedText: String) -> String {
        let digest = SHA256.hash(data: Data(normalizedText.utf8))
        return "vocabulary-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func identifier(for text: String) -> String? {
        normalizedText(from: text).map(identifier(forNormalizedText:))
    }
}

/// A canonical dictionary term. Deletions remain as tombstones so an older
/// device or legacy KVS snapshot cannot resurrect a removed term.
@Model
nonisolated final class VocabularyEntry {
    var id: String = ""
    var text: String = ""
    var normalizedText: String = ""
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    // `PersistentModel` already owns `isDeleted`; using that name for the
    // durable CloudKit tombstone silently reads SwiftData's context-deletion
    // state on newer SDKs. Keep the stored column name for migration safety.
    @Attribute(originalName: "isDeleted") var isTombstone: Bool = false
    var cloudSystemFields: Data?

    #Index<VocabularyEntry>([\.id], [\.createdAt], [\.isTombstone])

    init(
        id: String,
        text: String,
        normalizedText: String,
        createdAt: Date,
        modifiedAt: Date,
        isTombstone: Bool = false,
        cloudSystemFields: Data? = nil
    ) {
        self.id = id
        self.text = text
        self.normalizedText = normalizedText
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isTombstone = isTombstone
        self.cloudSystemFields = cloudSystemFields
    }
}

/// Durable handoff between a vocabulary transaction and CKSyncEngine.
@Model
nonisolated final class VocabularySyncChange {
    var entryID: String = ""

    #Index<VocabularySyncChange>([\.entryID])

    init(entryID: String) {
        self.entryID = entryID
    }
}

/// Full history of transcriptions so a failed paste never loses text and all
/// devices share the same history. Immutable audio is archived separately so
/// multiple transcripts can refer to the same original recording.
///
/// Backed locally by SwiftData and synced through the CloudKit private database
/// by `AppCloudSyncCoordinator`. Persistence is best-effort: failures are
/// reported through `onPersistenceError`, never thrown into the dictation flow.
///
/// Writes go through this store; views read live results with `@Query`
/// against `container` so remote imports appear without manual refresh.
@MainActor
@Observable
final class MumlaDataStore {
    nonisolated static let cloudContainerIdentifier = "iCloud.emileberhard.WisprClone"

    private(set) var container: ModelContainer
    private(set) var audioArchive: AudioArchive
    private var audioPersistence: AudioRecordingPersistence
    private var sharedHistoryProjection: SharedHistoryProjection
    private var sharedHistoryTask: Task<Void, any Error>?
    private var sharedHistoryTaskID: UUID?
    private var sharedProjectionWrites: [UUID: Task<Void, Never>] = [:]
    private var cloudSync: AppCloudSyncCoordinator?
    private(set) var partitionID = UUID()
    private(set) var confirmedAccountID: String?
    private(set) var cloudDeletionNeedsDecision = false
    private var accountLease: AccountPartitionLease?
    private(set) var library: UnifiedDictationLibrary?
    private var captureContexts: [UUID: ModelContainer] = [:]
    private struct CaptureDestination {
        let recordingID: UUID?
        let container: ModelContainer
        let persistence: AudioRecordingPersistence
        let sync: AppCloudSyncCoordinator?
    }
    private var originalDestinations: [URL: CaptureDestination] = [:]
    private var legacyImportStore: MumlaDataStore?
    private var archiveMaintenanceTask: Task<Void, Never>?
    private var exportTask: Task<URL, any Error>?
    private var exportTaskID: UUID?
    @ObservationIgnored private lazy var agentInbox = LibraryAgentInbox(
        directory: rootDirectory.appendingPathComponent("AgentCommands", isDirectory: true)
    ) { [weak self] request in
        guard let self else { throw LibraryAgentError.unavailable }
        return try await self.executeAgentRequest(request)
    }
    private var accountTask: Task<Void, Never>?
    private let rootDirectory: URL
    private let offloadRootDirectory: URL
    private let accountPartitioningEnabled: Bool
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "emileberhard.WisprClone",
        category: "CloudSync"
    )
    private let onPersistenceError: (@MainActor @Sendable (Error) -> Void)?
    private var context: ModelContext { container.mainContext }

    /// - Parameters:
    ///   - directoryURL: Override for tests; defaults to
    ///     `Application Support/WisprClone`.
    ///   - cloudSyncEnabled: Tests pass `false` so they never attempt CloudKit.
    ///   - onPersistenceError: Platform logging hook (Sentry on iOS,
    ///     AppDiagnostics on macOS).
    init(
        directoryURL: URL? = nil,
        cloudSyncEnabled: Bool = true,
        onPersistenceError: (@MainActor @Sendable (Error) -> Void)? = nil
    ) {
        let root = directoryURL ?? Self.defaultDirectoryURL()
        self.rootDirectory = root
        self.offloadRootDirectory = directoryURL?.appendingPathComponent("Offloaded", isDirectory: true)
            ?? Self.defaultOffloadDirectoryURL()
        #if DEBUG
        self.accountPartitioningEnabled = cloudSyncEnabled
            && ProcessInfo.processInfo.environment["MUMLA_INIT_CLOUDKIT_SCHEMA"] != "1"
        #else
        self.accountPartitioningEnabled = cloudSyncEnabled
        #endif
        let directory = accountPartitioningEnabled ? AccountPartition.directory(root: root, ownerID: nil) : root
        self.onPersistenceError = onPersistenceError
        let initialContainer = Self.makeContainer(directory: directory, onPersistenceError: onPersistenceError)
        let initialArchive = AudioArchive(
            directory: directory,
            offloadDirectory: accountPartitioningEnabled
                ? AccountPartition.directory(root: offloadRootDirectory, ownerID: nil) : offloadRootDirectory
        )
        self.container = initialContainer
        self.sharedHistoryProjection = SharedHistoryProjection(container: initialContainer)
        self.audioArchive = initialArchive
        self.audioPersistence = AudioRecordingPersistence(container: initialContainer, archive: initialArchive)
        initialContainer.mainContext.autosaveEnabled = false
        if accountPartitioningEnabled {
            do {
                library = UnifiedDictationLibrary(store: try UnifiedDictationLibrary.makeStore(rootDirectory: root), rootDirectory: root,
                    vocabulary: { [weak self] in self?.vocabularyTerms ?? [] },
                    onAccountChange: { [weak self] session in
                        self?.accountLease?.invalidate()
                        self?.activatePartition(ownerID: session?.accountIdentifier)
                    },
                    onExportRequested: { [weak self] in
                        guard let self else { throw CancellationError() }
                        return try await self.exportCombinedArchive()
                    },
                    onArchiveRoleChanged: { [weak self] in self?.startArchivalMaintenance() }
                )
                refreshAccount(invalidate: false)
            } catch { onPersistenceError?(error) }
        } else {
            importLegacyHistoryIfNeeded(from: directory)
            Task { try? await recoverAudioArchive() }
        }
    }

    @discardableResult
    func handleAgentURL(_ url: URL) -> Bool { agentInbox.handle(url) }

    private func executeAgentRequest(_ request: LibraryAgentRequest) async throws -> Data {
        await accountTask?.value
        guard container.configurations.allSatisfy({ !$0.isStoredInMemoryOnly }) else { throw LibraryAgentError.unavailable }
        guard let library, let session = library.accountSession else { throw LibraryAgentError.unavailable }
        try await library.store.validateAccountSession(session)
        guard let lease = accountLease, lease.isActive, lease.ownerID == session.accountIdentifier,
              let sync = cloudSync else { throw LibraryAgentError.accountChanged }
        let hash = AccountPartition.directory(root: rootDirectory, ownerID: lease.ownerID).lastPathComponent
        if let expected = request.accountHash, hash != expected { throw LibraryAgentError.accountChanged }
        try await sync.catchUpForArchive()
        try await refreshSharedHistory()
        guard lease.isActive else { throw LibraryAgentError.accountChanged }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        var output: [String: Any] = ["accountHash": hash, "metadataCaughtUpAt": Date.now.timeIntervalSince1970]
        switch request.operation {
        case "legacy-inspect", "legacy-reconcile":
            let before = try inspectLegacyData(lease: lease)
            output["before"] = try JSONSerialization.jsonObject(with: encoder.encode(before))
            if request.operation == "legacy-reconcile" {
                guard before.conflictingIDs.isEmpty else { throw AudioArchiveError.conflictingRecording }
                try await reconcileLegacyData(expectedOwnerID: lease.ownerID)
                guard lease.isActive else { throw LibraryAgentError.accountChanged }
                output["after"] = try JSONSerialization.jsonObject(with: encoder.encode(inspectLegacyData(lease: lease)))
            }
        case "status":
            output["historyCount"] = try context.fetchCount(FetchDescriptor<HistoryEntry>(predicate: #Predicate { !$0.isHidden }))
            output["recordingCount"] = try context.fetchCount(FetchDescriptor<AudioRecording>())
            output["pendingHistoryChanges"] = try context.fetchCount(FetchDescriptor<HistorySyncChange>())
            output["pendingAudioChunks"] = try context.fetchCount(FetchDescriptor<AudioSyncChange>())
            output["legacy"] = try JSONSerialization.jsonObject(with: encoder.encode(inspectLegacyData(lease: lease)))
        case "list", "search":
            guard lease.isActive else { throw LibraryAgentError.accountChanged }
            let recordings = try context.fetch(FetchDescriptor<AudioRecording>())
            let sharedIDs = Set(recordings.filter { $0.info?.source.hasPrefix("unified/") == true }.map(\.id))
            var entries = try context.fetch(FetchDescriptor<HistoryEntry>()).filter {
                !($0.audioRecordingID.map(sharedIDs.contains) ?? false)
            }.map(LibraryAgentHistory.init)
            let hidden = Set(try context.fetch(FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.isHidden })).map(\.id))
            entries += library.entries.flatMap { entry in entry.results.filter { !hidden.contains($0.id) }.map { LibraryAgentHistory(capture: entry.capture, result: $0) } }
            if let text = request.text {
                entries = entries.filter { $0.text.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
            entries.sort { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
            let offset = request.offset ?? 0
            let page = Array(entries.dropFirst(offset).prefix(request.limit ?? 50))
            output["totalCount"] = entries.count
            output["offset"] = offset
            output["hasMore"] = offset + page.count < entries.count
            output["entries"] = try JSONSerialization.jsonObject(with: encoder.encode(page))
        case "export":
            #if os(macOS)
            output["exportDirectory"] = try await exportCombinedArchive().path
            #else
            throw LibraryAgentError.unavailable
            #endif
        case "audio":
            guard let id = request.id else { throw LibraryAgentError.invalidRequest }
            let original: URL
            let expectedHash: String
            let expectedBytes: Int64
            if let info = try? recordingInfo(for: id) {
                original = try await audioFile(for: id)
                expectedHash = info.sha256
                expectedBytes = Int64(info.byteCount)
            } else {
                    guard let entry = library.entries.first(where: { $0.id == id }),
                      let sha = entry.capture.originalSHA256, let bytes = entry.capture.originalByteCount else { throw AudioArchiveError.invalidRecording }
                original = try await library.original(for: id)
                expectedHash = sha
                expectedBytes = bytes
            }
            try await Task.detached(priority: .utility) {
                let bytes = try Data(contentsOf: original, options: .mappedIfSafe)
                guard Int64(bytes.count) == expectedBytes, AudioArchive.digest(bytes) == expectedHash else { throw AudioArchiveError.corruptAudio }
            }.value
            let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL.path + "/"
            guard original.standardizedFileURL.path.hasPrefix(home) else { throw AudioArchiveError.invalidRecording }
            output["path"] = original.path
            output["containerRelativePath"] = String(original.standardizedFileURL.path.dropFirst(home.count))
            output["sha256"] = expectedHash
            output["byteCount"] = expectedBytes
        default: throw LibraryAgentError.invalidRequest
        }
        guard lease.isActive else { throw LibraryAgentError.accountChanged }
        try await library.store.validateAccountSession(session)
        guard lease.isActive else { throw LibraryAgentError.accountChanged }
        output["pendingHistoryChanges"] = try context.fetchCount(FetchDescriptor<HistorySyncChange>())
        output["pendingAudioChunks"] = try context.fetchCount(FetchDescriptor<AudioSyncChange>())
        return try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    }

    private func inspectLegacyData(lease: AccountPartitionLease) throws -> LegacyLibraryReport {
        guard lease.isActive else { throw LibraryAgentError.accountChanged }
        var report = LegacyLibraryReport()
        for (directory, _) in legacySourceDirectories {
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("TranscriptionHistory.store").path) else { continue }
            let source = try Self.persistentContainer(directory: directory)
            let plan = try LegacyLibraryReconciliation(source: ModelContext(source), destination: context,
                ownership: LegacyDataOwnership.load(directory: directory), ownerID: lease.ownerID)
            report.append(plan.report)
        }
        return report
    }

    func refreshAccount(invalidate: Bool) {
        guard accountPartitioningEnabled else { return }
        accountTask?.cancel()
        if invalidate {
            accountLease?.invalidate()
            activatePartition(ownerID: nil)
        }
        let library = library
        accountTask = Task {
            await library?.refresh()
        }
    }

    private func activatePartition(ownerID: String?) {
        guard confirmedAccountID != ownerID || accountLease?.isActive == false else { return }
        let previousOwner = confirmedAccountID
        archiveMaintenanceTask?.cancel()
        archiveMaintenanceTask = nil
        exportTask?.cancel()
        exportTask = nil
        exportTaskID = nil
        accountLease?.invalidate()
        if previousOwner != nil {
            NotificationCenter.default.post(name: .mumlaAccountInvalidated, object: nil)
        }
        confirmedAccountID = ownerID
        cloudDeletionNeedsDecision = false
        cloudSync = nil
        let directory = AccountPartition.directory(root: rootDirectory, ownerID: ownerID)
        container = Self.makeContainer(directory: directory, onPersistenceError: onPersistenceError)
        container.mainContext.autosaveEnabled = false
        audioArchive = AudioArchive(
            directory: directory,
            offloadDirectory: AccountPartition.directory(root: offloadRootDirectory, ownerID: ownerID)
        )
        audioPersistence = AudioRecordingPersistence(container: container, archive: audioArchive)
        for task in sharedProjectionWrites.values { task.cancel() }
        sharedProjectionWrites = [:]
        sharedHistoryTask?.cancel()
        sharedHistoryTask = nil
        sharedHistoryTaskID = nil
        sharedHistoryProjection = SharedHistoryProjection(container: container)
        partitionID = UUID()
        accountLease = ownerID.map(AccountPartitionLease.init)
        if let lease = accountLease {
            let sync = AppCloudSyncCoordinator(
                container: container, directoryURL: directory, audioPersistence: audioPersistence,
                accountLease: lease,
                onCloudDeletion: { [weak self] in
                    guard lease.isActive else { return }
                    self?.cloudDeletionNeedsDecision = true
                },
                onEncryptionReset: { [weak self] in
                    guard lease.isActive else { throw CancellationError() }
                    try await self?.library?.reseedRetainedLibrary()
                },
                onPersistenceError: onPersistenceError
            )
            cloudSync = sync
            Task {
                await sync.start()
                if lease.isActive {
                    do { try await refreshSharedHistory() }
                    catch { onPersistenceError?(error) }
                    startArchivalMaintenance()
                }
            }
        }
        let persistence = audioPersistence
        Task {
            do { try await persistence.recoverUnindexedRecordings() }
            catch { onPersistenceError?(error) }
        }
    }

    func exportCombinedArchive() async throws -> URL {
        if let exportTask { return try await exportTask.value }
        guard let lease = accountLease, lease.isActive, let sync = cloudSync, let library else { throw AudioArchiveError.audioUnavailable }
        let persistence = audioPersistence
        let archive = audioArchive
        let target = container
        let root = rootDirectory
        let task = Task { @MainActor in
            try await sync.resumeRetainedLibraryRestoration()
            try await sync.catchUpForArchive()
            guard lease.isActive else { throw CancellationError() }
            let recordings = try target.mainContext.fetch(FetchDescriptor<AudioRecording>()).compactMap(\.info)
                .filter { !$0.source.hasPrefix("unified/") }
            var bytes = try await CombinedArchiveExporter.allocatedBytes(at: root)
            for info in recordings {
                guard lease.isActive else { throw CancellationError() }
                if !archive.isRetained(info) {
                    let required = Int64(info.byteCount) * (archive.localAudioURL(info) == nil ? 2 : 1)
                    guard bytes + required <= CombinedArchiveExporter.capacityBytes else {
                        throw DictationLibraryError.capacityExceeded(limit: CombinedArchiveExporter.capacityBytes, used: bytes)
                    }
                    if archive.localAudioURL(info) == nil { try await sync.downloadAudio(info) }
                    try await persistence.retainOriginal(info)
                    bytes += required
                }
            }
            let unified = try await library.exportUnifiedArchive()
            guard lease.isActive else { throw CancellationError() }
            let currentBytes = try await CombinedArchiveExporter.allocatedBytes(at: root)
            let snapshotBytes = recordings.reduce(Int64(0)) { $0 + Int64($1.byteCount) }
            guard currentBytes + snapshotBytes <= CombinedArchiveExporter.capacityBytes else {
                throw DictationLibraryError.capacityExceeded(limit: CombinedArchiveExporter.capacityBytes, used: currentBytes)
            }
            let legacyRoot = root.appendingPathComponent("LegacyDictationExports", isDirectory: true)
            let legacy = try await LegacyArchiveExporter.export(dataStore: self, to: legacyRoot, expectedAccount: lease.ownerID)
            let accountHash = AccountPartition.directory(root: root, ownerID: lease.ownerID).lastPathComponent
            try await CombinedArchiveExporter.retainLatestTwo(in: legacyRoot.appendingPathComponent(accountHash, isDirectory: true), preserving: legacy)
            return try await CombinedArchiveExporter.seal(sections: ["unified": unified, "legacy": legacy],
                parent: root.appendingPathComponent("CombinedDictationExports", isDirectory: true), lease: lease)
        }
        let taskID = UUID()
        exportTask = task
        exportTaskID = taskID
        defer {
            if exportTaskID == taskID { exportTask = nil; exportTaskID = nil }
        }
        return try await task.value
    }

    private func startArchivalMaintenance() {
        guard library?.archiveRoleEnabled == true, confirmedAccountID != nil else {
            archiveMaintenanceTask?.cancel()
            archiveMaintenanceTask = nil
            return
        }
        guard archiveMaintenanceTask == nil else { return }
        archiveMaintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.library?.archiveRoleEnabled == true else { return }
                do { _ = try await self.exportCombinedArchive() }
                catch { self.library?.lastError = error.localizedDescription }
                do { try await Task.sleep(for: .seconds(3_600)) }
                catch { return }
            }
        }
    }

    var legacyDataStore: MumlaDataStore {
        guard accountPartitioningEnabled else { return self }
        if let legacyImportStore { return legacyImportStore }
        let store = MumlaDataStore(directoryURL: rootDirectory, cloudSyncEnabled: false, onPersistenceError: onPersistenceError)
        legacyImportStore = store
        return store
    }

    func restoreIntentionallyDeletedCloudLibrary(expectedOwnerID: String) async throws {
        guard confirmedAccountID == expectedOwnerID else { throw CancellationError() }
        guard let sync = cloudSync else { throw AudioArchiveError.audioUnavailable }
        try await sync.restoreAfterIntentionalDeletion()
        guard confirmedAccountID == expectedOwnerID else { throw CancellationError() }
        cloudDeletionNeedsDecision = false
    }

    func reconcileLegacyData(expectedOwnerID: String) async throws {
        guard let lease = accountLease, lease.ownerID == expectedOwnerID, lease.isActive else { throw CancellationError() }
        let target = container
        let destination = target.mainContext
        let persistence = audioPersistence
        let sync = cloudSync
        for (directory, cache) in legacySourceDirectories {
            try Task.checkCancellation()
            guard lease.isActive else { throw CancellationError() }
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("TranscriptionHistory.store").path) else { continue }
            let legacy = try Self.persistentContainer(directory: directory)
            let source = ModelContext(legacy)
            source.autosaveEnabled = false
            var ownership = try LegacyDataOwnership.load(directory: directory)
            let plan = try LegacyLibraryReconciliation(source: source, destination: destination, ownership: ownership, ownerID: lease.ownerID)
            guard plan.report.conflictingIDs.isEmpty else { throw AudioArchiveError.conflictingRecording }
            let history = plan.history
            let vocabulary = plan.vocabulary
            let recordings = plan.recordings
            let keys = plan.keys
            try ownership.assign(keys, to: lease.ownerID, directory: directory)
            let archive = AudioArchive(directory: directory, offloadDirectory: cache)
            for entry in history {
                destination.insert(HistoryEntry(
                    id: entry.id, text: entry.text, createdAt: entry.createdAt,
                    providerDisplayName: entry.providerDisplayName, deviceName: entry.deviceName,
                    audioRecordingID: entry.audioRecordingID
                ))
                try enqueueSyncChange(for: entry.id, kind: .save)
            }
            for entry in vocabulary {
                if let current = try vocabularyEntry(with: entry.id) {
                    guard entry.modifiedAt > current.modifiedAt else { continue }
                    current.text = entry.text
                    current.normalizedText = entry.normalizedText
                    current.modifiedAt = entry.modifiedAt
                    current.isTombstone = entry.isTombstone
                } else {
                    destination.insert(VocabularyEntry(
                        id: entry.id, text: entry.text, normalizedText: entry.normalizedText,
                        createdAt: entry.createdAt, modifiedAt: entry.modifiedAt,
                        isTombstone: entry.isTombstone
                    ))
                }
                try enqueueVocabularySyncChange(for: entry.id)
            }
            do { try destination.save() }
            catch { destination.rollback(); throw error }
            for info in recordings {
                try Task.checkCancellation()
                guard lease.isActive else { throw CancellationError() }
                guard let url = archive.localAudioURL(info) else {
                    guard let sync else { throw AudioArchiveError.audioUnavailable }
                    try await sync.downloadAudio(info)
                    try Task.checkCancellation()
                    guard lease.isActive else { throw CancellationError() }
                    continue
                }
                let verifiedBytes = try await Task.detached(priority: .utility) {
                    let bytes = try Data(contentsOf: url)
                    guard bytes.count == info.byteCount, AudioArchive.digest(bytes) == info.sha256 else { throw AudioArchiveError.corruptAudio }
                    return bytes
                }.value
                try Task.checkCancellation()
                guard lease.isActive else { throw CancellationError() }
                _ = try await persistence.save(
                        .data(verifiedBytes), id: info.id, createdAt: info.createdAt,
                        providerRawValue: info.providerRawValue, providerDisplayName: info.providerDisplayName,
                        deviceName: info.deviceName, source: info.source,
                        durationMilliseconds: info.durationMilliseconds, fileType: info.fileType
                    )
            }
            try Task.checkCancellation()
            guard lease.isActive else { throw CancellationError() }
            try ownership.markCopied(keys, directory: directory)
        }
        await sync?.uploadPendingChanges()
    }

    private var legacySourceDirectories: [(URL, URL)] {
        [
            (rootDirectory, offloadRootDirectory),
            (AccountPartition.directory(root: rootDirectory, ownerID: nil), AccountPartition.directory(root: offloadRootDirectory, ownerID: nil)),
        ]
    }

    func makeOriginalAudioWriter(context: DictationContext) async throws -> OriginalAudioWriter {
        let partition = partitionID
        let target = container
        let persistence = audioPersistence
        let sync = cloudSync
        let prepared = try await library?.prepareCapture(context: context)
        let destination = CaptureDestination(recordingID: prepared?.id, container: target, persistence: persistence, sync: sync)
        let writer = try OriginalAudioWriter(dictation: prepared)
        guard partitionID == partition else {
            writer.discard()
            throw CancellationError()
        }
        originalDestinations[writer.url] = destination
        if let prepared { captureContexts[prepared.id] = destination.container }
        return writer
    }

    @discardableResult
    func record(
        text: String,
        audioRecordingID: UUID? = nil,
        createdAt: Date = .now
    ) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let audioRecordingID, let result = library?.historyResult(for: audioRecordingID, text: text),
           captureContexts[audioRecordingID] === container, let lease = accountLease, lease.isActive {
            let projection = sharedHistoryProjection
            if sharedProjectionWrites[result.id] == nil {
                sharedProjectionWrites[result.id] = Task {
                    defer { sharedProjectionWrites.removeValue(forKey: result.id) }
                    do { try await projection.insert(result, deviceName: Self.deviceName, lease: lease) }
                    catch { onPersistenceError?(error) }
                }
            }
            return result.id
        }
        if let audioRecordingID, let captureContainer = captureContexts[audioRecordingID] {
            let entry = HistoryEntry(text: text, createdAt: createdAt, providerDisplayName: TranscriptionProviderType.dictationDisplayName,
                                     deviceName: Self.deviceName, audioRecordingID: audioRecordingID)
            let destination = captureContainer.mainContext
            do {
                destination.insert(entry)
                if try !Self.isUnifiedRecording(audioRecordingID, in: destination) {
                    destination.insert(HistorySyncChange(entryID: entry.id, kind: .save))
                }
                try destination.save()
                if let sync = cloudSync { Task { await sync.uploadPendingChanges() } }
                return entry.id
            } catch { destination.rollback(); onPersistenceError?(error); return nil }
        }
        let entry = HistoryEntry(
            text: text,
            createdAt: createdAt,
            providerDisplayName: TranscriptionProviderType.dictationDisplayName,
            deviceName: Self.deviceName,
            audioRecordingID: audioRecordingID
        )
        do {
            if try !Self.isUnifiedRecording(audioRecordingID, in: context) {
                try enqueueSyncChange(for: entry.id, kind: .save)
            }
            context.insert(entry)
            try saveAndSync()
            logger.info("Queued history change kind=save id=\(entry.id.uuidString, privacy: .public)")
            return entry.id
        } catch {
            context.rollback()
            onPersistenceError?(error)
            return nil
        }
    }

    /// Commits the encoded original before starting transcription. Failures stay
    /// visible and never cause the captured input to be deleted.
    func saveOriginalAudio(
        _ original: Result<URL, any Error>,
        source: String,
        durationMilliseconds: Int?
    ) async throws -> UUID {
        let url: URL
        do { url = try original.get() } catch {
            onPersistenceError?(error)
            throw error
        }
        let providerRawValue = TranscriptionProviderType.dictation.rawValue
        let destination = originalDestinations.removeValue(forKey: url)
        if let id = library?.captureID(for: url), let target = captureContexts[id] {
            library?.originalDidFinish()
            let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
            let info = AudioRecordingInfo(
                id: id, createdAt: .now, providerRawValue: providerRawValue,
                providerDisplayName: TranscriptionProviderType.dictationDisplayName, deviceName: Self.deviceName,
                source: "unified/" + source, durationMilliseconds: durationMilliseconds,
                byteCount: bytes.count, sha256: AudioArchive.digest(bytes), fileType: .caf
            )
            let destination = target.mainContext
            let existingID = id
            if try destination.fetch(FetchDescriptor<AudioRecording>(predicate: #Predicate { $0.id == existingID })).isEmpty {
                destination.insert(try AudioRecording(info: info))
                try destination.save()
            }
            return id
        }
        let id: UUID
        if let destination {
            id = try await destination.persistence.save(
                .file(url), id: destination.recordingID ?? UUID(), createdAt: .now,
                providerRawValue: providerRawValue, providerDisplayName: TranscriptionProviderType.dictationDisplayName,
                deviceName: Self.deviceName, source: source,
                durationMilliseconds: durationMilliseconds, fileType: .caf
            )
            captureContexts[id] = destination.container
            if let sync = destination.sync { Task { await sync.uploadPendingChanges() } }
        } else {
            id = try await saveAudio(
                .file(url), providerRawValue: providerRawValue, providerDisplayName: TranscriptionProviderType.dictationDisplayName,
                source: source, durationMilliseconds: durationMilliseconds, fileType: .caf
            )
        }
        try? FileManager.default.removeItem(at: url)
        return id
    }

    func saveAudio(
        _ input: AudioRecordingPersistence.Input,
        id: UUID = UUID(),
        createdAt: Date = .now,
        providerRawValue: String,
        providerDisplayName: String,
        source: String,
        durationMilliseconds: Int?,
        fileType: AudioArchiveFileType
    ) async throws -> UUID {
        let persistence = audioPersistence
        let sync = cloudSync
        do {
            let savedID = try await persistence.save(
                input, id: id, createdAt: createdAt,
                providerRawValue: providerRawValue, providerDisplayName: providerDisplayName,
                deviceName: Self.deviceName, source: source,
                durationMilliseconds: durationMilliseconds, fileType: fileType
            )
            if let sync { Task { await sync.uploadPendingChanges() } }
            return savedID
        } catch {
            onPersistenceError?(error)
            throw error
        }
    }

    func recoverAudioArchive() async throws {
        try await audioPersistence.recoverUnindexedRecordings()
        try await audioPersistence.relabelOpusReceivedByOlderClients()
        try await audioPersistence.offloadUploadedRecordings()
    }

    func audioFile(for id: UUID) async throws -> URL {
        let info = try recordingInfo(for: id)
        if info.source.hasPrefix("unified/"), let library { return try await library.original(for: id) }
        if let url = audioArchive.localAudioURL(info) { return url }
        guard let cloudSync else { throw AudioArchiveError.audioUnavailable }
        try await cloudSync.downloadAudio(info)
        guard let url = audioArchive.localAudioURL(info) else { throw AudioArchiveError.audioUnavailable }
        return url
    }

    func providerWAV(for id: UUID) async throws -> Data {
        let info = try recordingInfo(for: id)
        return try await OriginalAudio.providerWAV(from: audioFile(for: id), fileType: info.fileType)
    }

    func recordingInfo(for id: UUID) throws -> AudioRecordingInfo {
        var query = FetchDescriptor<AudioRecording>(predicate: #Predicate { $0.id == id })
        query.fetchLimit = 1
        guard let info = try context.fetch(query).first?.info else { throw AudioArchiveError.invalidRecording }
        return info
    }

    func recentHistoryTexts(limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var descriptor = FetchDescriptor<HistoryEntry>(
            predicate: #Predicate { !$0.isHidden },
            sortBy: [SortDescriptor(\HistoryEntry.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        do {
            return try context.fetch(descriptor).map(\.text)
        } catch {
            onPersistenceError?(error)
            return []
        }
    }

    func delete(_ entry: HistoryEntry) {
        guard entry.modelContext === context else { return }
        do {
            if try Self.isUnifiedRecording(entry.audioRecordingID, in: context) {
                entry.isHidden = true
            } else {
                try enqueueSyncChange(for: entry.id, kind: .delete)
                context.delete(entry)
            }
            try saveAndSync()
            logger.info("Queued history change kind=delete id=\(entry.id.uuidString, privacy: .public)")
        } catch {
            onPersistenceError?(error)
        }
    }

    func clear() {
        do {
            let entries = try context.fetch(FetchDescriptor<HistoryEntry>())
            let pending = try context.fetch(FetchDescriptor<HistorySyncChange>())
            var pendingByID = Dictionary(
                pending.map { ($0.entryID, $0) },
                uniquingKeysWith: { _, last in last }
            )
            for entry in entries {
                if try Self.isUnifiedRecording(entry.audioRecordingID, in: context) {
                    if let pending = pendingByID[entry.id] { context.delete(pending) }
                    entry.isHidden = true
                    continue
                }
                if let change = pendingByID[entry.id] {
                    change.kind = .delete
                } else {
                    let change = HistorySyncChange(entryID: entry.id, kind: .delete)
                    context.insert(change)
                    pendingByID[entry.id] = change
                }
                context.delete(entry)
            }
            try saveAndSync()
        } catch {
            onPersistenceError?(error)
        }
    }

    // MARK: - Vocabulary

    var vocabularyTerms: [String] {
        (try? activeVocabularyEntries().map(\.text)) ?? []
    }

    @discardableResult
    func addVocabularyTerm(_ rawText: String, now: Date = .now) -> VocabularyEntry? {
        guard let text = VocabularyTerm.displayText(from: rawText),
              let normalizedText = VocabularyTerm.normalizedText(from: text)
        else { return nil }

        let id = VocabularyTerm.identifier(forNormalizedText: normalizedText)
        do {
            if let existing = try vocabularyEntry(with: id) {
                guard existing.isTombstone else { return existing }
                existing.text = text
                existing.normalizedText = normalizedText
                existing.modifiedAt = now
                existing.isTombstone = false
                try enqueueVocabularySyncChange(for: id)
                try saveAndSync()
                return existing
            }

            let entry = VocabularyEntry(
                id: id,
                text: text,
                normalizedText: normalizedText,
                createdAt: now,
                modifiedAt: now
            )
            context.insert(entry)
            try enqueueVocabularySyncChange(for: id)
            try saveAndSync()
            return entry
        } catch {
            onPersistenceError?(error)
            return nil
        }
    }

    func updateVocabularyTerm(_ entry: VocabularyEntry, to rawText: String, now: Date = .now) {
        guard entry.modelContext === context else { return }
        guard let text = VocabularyTerm.displayText(from: rawText),
              let normalizedText = VocabularyTerm.normalizedText(from: text)
        else {
            removeVocabularyTerm(entry, now: now)
            return
        }

        let newID = VocabularyTerm.identifier(forNormalizedText: normalizedText)
        do {
            if newID == entry.id {
                guard entry.text != text || entry.isTombstone else { return }
                entry.text = text
                entry.normalizedText = normalizedText
                entry.modifiedAt = now
                entry.isTombstone = false
                try enqueueVocabularySyncChange(for: entry.id)
            } else {
                entry.modifiedAt = now
                entry.isTombstone = true
                try enqueueVocabularySyncChange(for: entry.id)

                if let target = try vocabularyEntry(with: newID) {
                    target.text = text
                    target.normalizedText = normalizedText
                    target.modifiedAt = now
                    target.isTombstone = false
                } else {
                    context.insert(VocabularyEntry(
                        id: newID,
                        text: text,
                        normalizedText: normalizedText,
                        createdAt: entry.createdAt,
                        modifiedAt: now
                    ))
                }
                try enqueueVocabularySyncChange(for: newID)
            }
            try saveAndSync()
        } catch {
            onPersistenceError?(error)
        }
    }

    func removeVocabularyTerm(_ entry: VocabularyEntry, now: Date = .now) {
        guard entry.modelContext === context else { return }
        guard !entry.isTombstone else { return }
        do {
            entry.isTombstone = true
            entry.modifiedAt = now
            try enqueueVocabularySyncChange(for: entry.id)
            try saveAndSync()
        } catch {
            onPersistenceError?(error)
        }
    }

    /// Replaces the active dictionary while retaining tombstones and creation
    /// order for unchanged terms. Used by the macOS JSON import.
    func replaceVocabulary(with rawTerms: [String], now: Date = .now) {
        let terms = canonicalVocabularyTerms(rawTerms)
        do {
            let entries = try context.fetch(FetchDescriptor<VocabularyEntry>())
            let desiredIDs = Set(terms.map(\.id))

            for entry in entries where !entry.isTombstone && !desiredIDs.contains(entry.id) {
                entry.isTombstone = true
                entry.modifiedAt = now
                try enqueueVocabularySyncChange(for: entry.id)
            }

            for (index, term) in terms.enumerated() {
                if let entry = entries.first(where: { $0.id == term.id }) {
                    guard entry.isTombstone || entry.text != term.text else { continue }
                    entry.text = term.text
                    entry.normalizedText = term.normalizedText
                    entry.modifiedAt = now
                    entry.isTombstone = false
                } else {
                    context.insert(VocabularyEntry(
                        id: term.id,
                        text: term.text,
                        normalizedText: term.normalizedText,
                        createdAt: now.addingTimeInterval(Double(index) * 0.000_001),
                        modifiedAt: now
                    ))
                }
                try enqueueVocabularySyncChange(for: term.id)
            }

            guard context.hasChanges else { return }
            try saveAndSync()
        } catch {
            onPersistenceError?(error)
        }
    }

    /// Imports each legacy newline dictionary once per deterministic term ID.
    /// Existing active entries and tombstones both win, so repeating this when
    /// iCloud KVS finishes its initial download is safe.
    func importLegacyVocabulary(_ values: [String]) {
        if accountPartitioningEnabled {
            legacyDataStore.importLegacyVocabulary(values)
                return
        }
        let terms = values.flatMap { $0.components(separatedBy: .newlines) }
        do {
            let existingIDs = Set(try context.fetch(FetchDescriptor<VocabularyEntry>()).map(\.id))
            var importedIDs = existingIDs
            let now = Date()
            for (index, term) in canonicalVocabularyTerms(terms).enumerated()
                where importedIDs.insert(term.id).inserted {
                context.insert(VocabularyEntry(
                    id: term.id,
                    text: term.text,
                    normalizedText: term.normalizedText,
                    createdAt: now.addingTimeInterval(Double(index) * 0.000_001),
                    modifiedAt: now
                ))
                try enqueueVocabularySyncChange(for: term.id)
            }
            guard context.hasChanges else { return }
            try saveAndSync()
        } catch {
            onPersistenceError?(error)
        }
    }

    /// Checks the custom zone directly instead of waiting for CKSyncEngine's
    /// push-triggered automatic fetch. Useful when the app returns to the
    /// foreground.
    func fetchRemoteChanges() {
        refreshAccount(invalidate: false)
        let cloudSync = cloudSync
        Task {
            await cloudSync?.fetchRemoteChanges()
            do { try await refreshSharedHistory() }
            catch { onPersistenceError?(error) }
        }
    }

    private func refreshSharedHistory() async throws {
        if let sharedHistoryTask { return try await sharedHistoryTask.value }
        guard let library, let lease = accountLease, lease.isActive else { return }
        let projection = sharedHistoryProjection
        let taskID = UUID()
        let task = Task {
            try await library.refreshCatalog()
            guard lease.isActive else { throw LibraryAgentError.accountChanged }
            try await projection.apply(library.entries, lease: lease)
        }
        sharedHistoryTask = task
        sharedHistoryTaskID = taskID
        defer {
            if sharedHistoryTaskID == taskID { sharedHistoryTask = nil; sharedHistoryTaskID = nil }
        }
        try await task.value
    }

    /// Keeps a visible cloud-backed view current using a persisted CloudKit zone
    /// change token. SwiftUI cancels this task when the view disappears, so
    /// polling never runs app-wide.
    func refreshRemoteChangesWhileVisible() async {
        guard let cloudSync else { return }
        while !Task.isCancelled {
            await cloudSync.fetchRemoteChanges()
            do { try await refreshSharedHistory() }
            catch { onPersistenceError?(error) }
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
    }

    /// Size of the SQLite store on disk, including the WAL/SHM sidecars.
    var storeSizeInBytes: Int64 {
        guard let storeURL = container.configurations.first?.url else { return 0 }
        return [storeURL.path, storeURL.path + "-wal", storeURL.path + "-shm"]
            .compactMap { try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? Int64 }
            .reduce(0, +)
    }

    private func enqueueSyncChange(for entryID: UUID, kind: HistorySyncChangeKind) throws {
        let descriptor = FetchDescriptor<HistorySyncChange>(
            predicate: #Predicate { $0.entryID == entryID }
        )
        if let existing = try context.fetch(descriptor).first {
            existing.kind = kind
        } else {
            context.insert(HistorySyncChange(entryID: entryID, kind: kind))
        }
    }

    private func enqueueVocabularySyncChange(for entryID: String) throws {
        var descriptor = FetchDescriptor<VocabularySyncChange>(
            predicate: #Predicate { $0.entryID == entryID }
        )
        descriptor.fetchLimit = 1
        if try context.fetch(descriptor).isEmpty {
            context.insert(VocabularySyncChange(entryID: entryID))
        }
    }

    private func activeVocabularyEntries() throws -> [VocabularyEntry] {
        let descriptor = FetchDescriptor<VocabularyEntry>(
            predicate: #Predicate { !$0.isTombstone },
            sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]
        )
        return try context.fetch(descriptor)
    }

    private static func isUnifiedRecording(_ id: UUID?, in context: ModelContext) throws -> Bool {
        guard let id else { return false }
        var query = FetchDescriptor<AudioRecording>(predicate: #Predicate { $0.id == id })
        query.fetchLimit = 1
        return try context.fetch(query).first?.info?.source.hasPrefix("unified/") == true
    }

    private func vocabularyEntry(with id: String) throws -> VocabularyEntry? {
        var descriptor = FetchDescriptor<VocabularyEntry>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private struct CanonicalVocabularyTerm {
        let id: String
        let text: String
        let normalizedText: String
    }

    private func canonicalVocabularyTerms(_ rawTerms: [String]) -> [CanonicalVocabularyTerm] {
        var seen = Set<String>()
        return rawTerms.compactMap { rawText in
            guard let text = VocabularyTerm.displayText(from: rawText),
                  let normalizedText = VocabularyTerm.normalizedText(from: text)
            else { return nil }
            let id = VocabularyTerm.identifier(forNormalizedText: normalizedText)
            guard seen.insert(id).inserted else { return nil }
            return CanonicalVocabularyTerm(id: id, text: text, normalizedText: normalizedText)
        }
    }

    private func saveAndSync() throws {
        try context.save()
        guard let cloudSync else { return }
        Task { await cloudSync.uploadPendingChanges() }
    }

    // MARK: - Container

    private static func makeContainer(
        directory: URL,
        onPersistenceError: (@MainActor @Sendable (Error) -> Void)?
    ) -> ModelContainer {
        do {
            return try persistentContainer(directory: directory)
        } catch {
            onPersistenceError?(error)
            // Last resort so history failures never take down dictation;
            // creating an in-memory container for a valid schema cannot fail.
            return try! ModelContainer(
                for: HistoryEntry.self, HistorySyncChange.self, VocabularyEntry.self, VocabularySyncChange.self,
                    AudioRecording.self, AudioSyncChange.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }
    }

    private static func persistentContainer(directory: URL) throws -> ModelContainer {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try ModelContainer(
            for: HistoryEntry.self, HistorySyncChange.self, VocabularyEntry.self, VocabularySyncChange.self,
                AudioRecording.self, AudioSyncChange.self,
            configurations: ModelConfiguration(url: directory.appendingPathComponent("TranscriptionHistory.store"), cloudKitDatabase: .none)
        )
    }

    // MARK: - Legacy JSON import

    /// Pre-sync releases kept the last 100 transcriptions in a JSON file.
    /// Import it once, keyed by a marker file next to the data so wiping
    /// UserDefaults never triggers a re-import. The JSON itself is left
    /// untouched as a rollback backup for downgrades.
    private func importLegacyHistoryIfNeeded(from directory: URL) {
        let legacyURL = directory.appendingPathComponent("transcription-history.json")
        let markerURL = directory.appendingPathComponent("transcription-history.imported")
        guard !FileManager.default.fileExists(atPath: markerURL.path),
              FileManager.default.fileExists(atPath: legacyURL.path)
        else { return }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let legacy = try decoder.decode(
                [LegacyHistoryEntry].self,
                from: try Data(contentsOf: legacyURL)
            )
            var idsOnly = FetchDescriptor<HistoryEntry>()
            idsOnly.propertiesToFetch = [\.id]
            let existingIDs = Set(try context.fetch(idsOnly).map(\.id))
            for entry in legacy where !existingIDs.contains(entry.id) {
                try enqueueSyncChange(for: entry.id, kind: .save)
                context.insert(HistoryEntry(
                    id: entry.id,
                    text: entry.text,
                    createdAt: entry.createdAt,
                    providerDisplayName: entry.providerDisplayName,
                    deviceName: Self.deviceName
                ))
            }
            try saveAndSync()
            FileManager.default.createFile(atPath: markerURL.path, contents: nil)
        } catch {
            // No marker written: the import retries on next launch rather
            // than risking silent history loss.
            onPersistenceError?(error)
        }
    }

    private struct LegacyHistoryEntry: Codable {
        let id: UUID
        let text: String
        let createdAt: Date
        let providerDisplayName: String
    }

    // MARK: - Environment

    private static let deviceName: String = {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }()

    private static func defaultDirectoryURL() -> URL {
        let supportFolder = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return supportFolder.appendingPathComponent("WisprClone", isDirectory: true)
    }

    private static func defaultOffloadDirectoryURL() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WisprClone", isDirectory: true)
    }
}

extension Notification.Name {
    static let mumlaAccountInvalidated = Notification.Name("MumlaAccountInvalidated")
}
