import CloudKit
import Foundation
import OSLog
import SwiftData

nonisolated struct HistoryCloudRecord: Sendable {
    let id: UUID
    let text: String
    let createdAt: Date
    let providerDisplayName: String
    let deviceName: String
    let audioRecordingID: UUID?

    init(entry: HistoryEntry) {
        self.init(
            id: entry.id,
            text: entry.text,
            createdAt: entry.createdAt,
            providerDisplayName: entry.providerDisplayName,
            deviceName: entry.deviceName,
            audioRecordingID: entry.audioRecordingID
        )
    }

    init(
        id: UUID,
        text: String,
        createdAt: Date,
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

nonisolated enum HistoryCloudSchema {
    static let zoneID = CKRecordZone.ID(zoneName: "TranscriptionHistory")
    static let recordType = "HistoryEntry"

    private enum Field {
        static let text = "text"
        static let createdAt = "createdAt"
        static let providerDisplayName = "providerDisplayName"
        static let deviceName = "deviceName"
        static let audioRecordingID = "audioRecordingID"
    }

    static func recordID(for id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    }

    static func makeRecord(from value: HistoryCloudRecord) -> CKRecord {
        let record = CKRecord(recordType: recordType, recordID: recordID(for: value.id))
        record.encryptedValues[Field.text] = value.text
        record.encryptedValues[Field.createdAt] = value.createdAt
        record.encryptedValues[Field.providerDisplayName] = value.providerDisplayName
        record.encryptedValues[Field.deviceName] = value.deviceName
        record.encryptedValues[Field.audioRecordingID] = value.audioRecordingID?.uuidString
        return record
    }

    static func value(from record: CKRecord) -> HistoryCloudRecord? {
        guard record.recordType == recordType,
              record.recordID.zoneID == zoneID,
              let id = UUID(uuidString: record.recordID.recordName),
              let text = record.encryptedValues[Field.text] as? String,
              let createdAt = record.encryptedValues[Field.createdAt] as? Date
        else { return nil }

        return HistoryCloudRecord(
            id: id,
            text: text,
            createdAt: createdAt,
            providerDisplayName: record.encryptedValues[Field.providerDisplayName] as? String ?? "",
            deviceName: record.encryptedValues[Field.deviceName] as? String ?? "",
            audioRecordingID: (record.encryptedValues[Field.audioRecordingID] as? String).flatMap(UUID.init(uuidString:))
        )
    }
}

nonisolated struct VocabularyCloudRecord: Sendable, Equatable {
    let id: String
    let text: String
    let normalizedText: String
    let createdAt: Date
    let modifiedAt: Date
    let isDeleted: Bool
    let systemFields: Data?

    init(
        id: String,
        text: String,
        normalizedText: String,
        createdAt: Date,
        modifiedAt: Date,
        isDeleted: Bool,
        systemFields: Data?
    ) {
        self.id = id
        self.text = text
        self.normalizedText = normalizedText
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isDeleted = isDeleted
        self.systemFields = systemFields
    }

    init(entry: VocabularyEntry) {
        self.init(
            id: entry.id,
            text: entry.text,
            normalizedText: entry.normalizedText,
            createdAt: entry.createdAt,
            modifiedAt: entry.modifiedAt,
            isDeleted: entry.isTombstone,
            systemFields: entry.cloudSystemFields
        )
    }
}

nonisolated enum VocabularyConflictResolution: Equatable {
    case keepLocal
    case acceptRemote

    static func resolve(localModifiedAt: Date, remoteModifiedAt: Date) -> Self {
        localModifiedAt > remoteModifiedAt ? .keepLocal : .acceptRemote
    }
}

nonisolated enum VocabularyCloudSchema {
    static let recordType = "VocabularyEntry"
    static let recordNamePrefix = "vocabulary-"

    private enum Field {
        static let text = "text"
        static let normalizedText = "normalizedText"
        static let createdAt = "createdAt"
        static let modifiedAt = "modifiedAt"
        static let isDeleted = "isDeleted"
    }

    static func recordID(for entryID: String) -> CKRecord.ID {
        CKRecord.ID(recordName: entryID, zoneID: HistoryCloudSchema.zoneID)
    }

    static func entryID(from recordID: CKRecord.ID) -> String? {
        guard recordID.zoneID == HistoryCloudSchema.zoneID,
              recordID.recordName.hasPrefix(recordNamePrefix)
        else { return nil }
        return recordID.recordName
    }

    static func makeRecord(from value: VocabularyCloudRecord) -> CKRecord {
        let recordID = recordID(for: value.id)
        let record = restoredRecord(from: value.systemFields, expectedID: recordID)
            ?? CKRecord(recordType: recordType, recordID: recordID)
        record.encryptedValues[Field.text] = value.text
        record.encryptedValues[Field.normalizedText] = value.normalizedText
        record.encryptedValues[Field.createdAt] = value.createdAt
        record.encryptedValues[Field.modifiedAt] = value.modifiedAt
        record.encryptedValues[Field.isDeleted] = value.isDeleted
        return record
    }

    static func value(from record: CKRecord) -> VocabularyCloudRecord? {
        guard record.recordType == recordType,
              let id = entryID(from: record.recordID),
              let text = record.encryptedValues[Field.text] as? String,
              let normalizedText = record.encryptedValues[Field.normalizedText] as? String,
              let createdAt = record.encryptedValues[Field.createdAt] as? Date,
              let modifiedAt = record.encryptedValues[Field.modifiedAt] as? Date,
              let isDeleted = record.encryptedValues[Field.isDeleted] as? Bool
        else { return nil }

        return VocabularyCloudRecord(
            id: id,
            text: text,
            normalizedText: normalizedText,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            isDeleted: isDeleted,
            systemFields: encodedSystemFields(for: record)
        )
    }

    private static func encodedSystemFields(for record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    private static func restoredRecord(from data: Data?, expectedID: CKRecord.ID) -> CKRecord? {
        guard let data,
              let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data)
        else { return nil }
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        guard let record = CKRecord(coder: unarchiver),
              record.recordType == recordType,
              record.recordID == expectedID
        else { return nil }
        return record
    }
}

enum AppCloudSyncMigration {
    nonisolated static func prepareVocabularyZoneReplayIfNeeded(
        pollingTokenURL: URL,
        markerURL: URL
    ) throws -> Bool {
        guard !FileManager.default.fileExists(atPath: markerURL.path) else { return false }

        if FileManager.default.fileExists(atPath: pollingTokenURL.path) {
            try FileManager.default.removeItem(at: pollingTokenURL)
        }
        try Data().write(to: markerURL, options: .atomic)
        return true
    }
}

/// Owns every CloudKit and background SwiftData operation for app-data sync.
/// The main actor only commits local UI writes and wakes this actor afterward.
actor AppCloudSyncCoordinator: CKSyncEngineDelegate {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "emileberhard.WisprClone",
        category: "CloudSync"
    )
    private let accountLease: AccountPartitionLease
    private var stopped = false
    private let container: ModelContainer
    private let audioPersistence: AudioRecordingPersistence
    private let database: CKDatabase
    private let deletionMarkerURL: URL
    private let restorationMarkerURL: URL
    private let onCloudDeletion: @MainActor @Sendable () -> Void
    private let onEncryptionReset: @MainActor @Sendable () async throws -> Void
    private var recoveringReset = false
    private let stateURL: URL
    private let pollingTokenURL: URL
    private let seedMarkerURL: URL
    private let vocabularySeedMarkerURL: URL
    private let audioZoneReplayMarkerURL: URL
    private let onPersistenceError: (@MainActor @Sendable (Error) -> Void)?

    private var syncEngine: CKSyncEngine?
    private var isSending = false
    private var shouldSendAgain = false
    private var isFetching = false
    private var shouldFetchAgain = false
    private var pollingChangeToken: CKServerChangeToken?
    private var archiveFetchWaiters: [CheckedContinuation<Void, any Error>] = []
    #if DEBUG
    nonisolated struct TransportProbeSnapshot: Codable, Sendable {
        var scheduledFetchCompletions = 0
        var projectedPages = 0
        var projectedRecords = 0
        var engineFetchedRecords = 0
        var deliveredAssetBytes: Int64 = 0
    }
    private var probeSnapshot = TransportProbeSnapshot()
    func transportProbeSnapshot() -> TransportProbeSnapshot { probeSnapshot }
    func stopTransportProbe() async {
        accountLease.invalidate()
        stopped = true
        await syncEngine?.cancelOperations()
    }
    #endif

    private lazy var context: ModelContext = {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }()

    init(
        container: ModelContainer,
        directoryURL: URL,
        audioPersistence: AudioRecordingPersistence,
        accountLease: AccountPartitionLease,
        onCloudDeletion: @escaping @MainActor @Sendable () -> Void,
        onEncryptionReset: @escaping @MainActor @Sendable () async throws -> Void,
        onPersistenceError: (@MainActor @Sendable (Error) -> Void)?
    ) {
        self.onEncryptionReset = onEncryptionReset
        self.accountLease = accountLease
        self.onCloudDeletion = onCloudDeletion
        self.deletionMarkerURL = directoryURL.appendingPathComponent("cloud-intentionally-deleted")
        self.restorationMarkerURL = directoryURL.appendingPathComponent("retained-library-restoration-pending")
        self.container = container
        self.audioPersistence = audioPersistence
        self.database = CKContainer(
            identifier: MumlaDataStore.cloudContainerIdentifier
        ).privateCloudDatabase
        self.stateURL = directoryURL.appendingPathComponent("history-cloud-sync-state.json")
        self.pollingTokenURL = directoryURL.appendingPathComponent("history-cloud-poll-token.data")
        self.seedMarkerURL = directoryURL.appendingPathComponent("history-cloud-sync-seeded")
        self.vocabularySeedMarkerURL = directoryURL.appendingPathComponent(
            "vocabulary-cloud-sync-seeded-v2"
        )
        self.audioZoneReplayMarkerURL = directoryURL.appendingPathComponent(
            "audio-cloud-zone-replayed-v1"
        )
        self.onPersistenceError = onPersistenceError
    }

    func start() async {
        guard syncEngine == nil, accountLease.isActive, !stopped else { return }
        if FileManager.default.fileExists(atPath: deletionMarkerURL.path) {
            stopped = true
            await onCloudDeletion()
            return
        }
        do {
            let cloud = CKContainer(identifier: MumlaDataStore.cloudContainerIdentifier)
            guard try await cloud.userRecordID().recordName == accountLease.ownerID,
                  accountLease.isActive, !stopped else { return }
        } catch { await reportIfActionable(error); return }

        do {
            try seedExistingHistoryIfNeeded()
            try seedExistingVocabularyIfNeeded()
        } catch {
            await report(error)
        }

        let savedState: CKSyncEngine.State.Serialization?
        do {
            savedState = try loadState()
        } catch {
            await report(error)
            try? FileManager.default.removeItem(at: stateURL)
            savedState = nil
        }

        let canLoadPollingToken: Bool
        do {
            let replayed = try AppCloudSyncMigration.prepareVocabularyZoneReplayIfNeeded(
                pollingTokenURL: pollingTokenURL,
                markerURL: audioZoneReplayMarkerURL
            )
            if replayed {
                logger.info("Reset Cloud polling token for the one-time audio zone replay")
            }
            canLoadPollingToken = true
        } catch {
            await report(error)
            canLoadPollingToken = false
        }

        do {
            pollingChangeToken = canLoadPollingToken ? try loadPollingToken() : nil
        } catch {
            await report(error)
            try? FileManager.default.removeItem(at: pollingTokenURL)
            pollingChangeToken = nil
        }

        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: savedState,
            delegate: self
        )
        configuration.automaticallySync = true
        let syncEngine = CKSyncEngine(configuration)
        self.syncEngine = syncEngine
        ensureZoneIsPending(in: syncEngine)
        logger.info(
            "Cloud sync engine started pollingTokenLoaded=\(self.pollingChangeToken != nil, privacy: .public)"
        )

        do { try await resumeRetainedLibraryRestoration() }
        catch { await report(error) }
        await uploadPendingChanges()
        await fetchRemoteChanges()
    }

    func uploadPendingChanges() async {
        guard accountLease.isActive, !stopped else { return }
        guard let syncEngine else {
            await start()
            return
        }
        guard !isSending else {
            shouldSendAgain = true
            return
        }

        isSending = true
        repeat {
            shouldSendAgain = false
            do {
                try await addOutboxChanges(to: syncEngine)
                guard accountLease.isActive, !stopped else { break }
                guard hasPendingChanges(in: syncEngine) else { break }
                let pendingCount = syncEngine.state.pendingRecordZoneChanges.count {
                    $0.recordID?.zoneID == HistoryCloudSchema.zoneID
                }
                if pendingCount > 0 {
                    logger.info("Sending app-data changes pending=\(pendingCount, privacy: .public)")
                }
                try await syncEngine.sendChanges(.init(scope: .zoneIDs([HistoryCloudSchema.zoneID])))
            } catch {
                await reportIfActionable(error)
            }
        } while shouldSendAgain
        isSending = false
    }

    func fetchRemoteChanges() async {
        guard accountLease.isActive, !stopped else { return }
        guard let syncEngine else {
            await start()
            return
        }
        guard !isFetching else {
            shouldFetchAgain = true
            return
        }

        isFetching = true
        var finalError: (any Error)?
        repeat {
            finalError = nil
            shouldFetchAgain = false
            do {
                let counts = try await pollRemoteChanges(syncEngine: syncEngine)
                if counts.modifications > 0 || counts.deletions > 0 {
                    logger.info(
                        "Polled app-data changes modifications=\(counts.modifications, privacy: .public) deletions=\(counts.deletions, privacy: .public)"
                    )
                } else {
                    logger.debug("Polled app-data changes modifications=0 deletions=0")
                }
            } catch {
                finalError = error
                await reportIfActionable(error)
            }
        } while shouldFetchAgain
        isFetching = false
        let waiters = archiveFetchWaiters
        archiveFetchWaiters = []
        for waiter in waiters {
            if let finalError { waiter.resume(throwing: finalError) }
            else if !accountLease.isActive || stopped { waiter.resume(throwing: CancellationError()) }
            else { waiter.resume() }
        }
    }

    func catchUpForArchive() async throws {
        guard syncEngine != nil, accountLease.isActive, !stopped else { throw AudioArchiveError.audioUnavailable }
        try await withCheckedThrowingContinuation { continuation in
            archiveFetchWaiters.append(continuation)
            Task { await self.fetchRemoteChanges() }
        }
    }

    // MARK: - CKSyncEngineDelegate

    func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        var options = context.options
        options.scope = .zoneIDs([])
        return options
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard accountLease.isActive, !stopped else { return }
        do {
            switch event {
            case .stateUpdate(let event):
                try persist(event.stateSerialization)
            case .accountChange(let event):
                if case .signIn(let currentUser) = event.changeType,
                   currentUser.recordName == accountLease.ownerID {
                    ensureZoneIsPending(in: syncEngine)
                    return
                }
                accountLease.invalidate()
                stopped = true
                Task { await syncEngine.cancelOperations() }
                Task { @MainActor in
                    NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
                }
            case .fetchedRecordZoneChanges(let event):
                try await handleFetchedRecordZoneChanges(event, syncEngine: syncEngine)
            case .sentDatabaseChanges(let event):
                for failure in event.failedZoneSaves {
                    await reportIfActionable(failure.error)
                }
            case .sentRecordZoneChanges(let event):
                try await handleSentRecordZoneChanges(event, syncEngine: syncEngine)
            case .didFetchRecordZoneChanges(let event):
                if let error = event.error {
                    await reportIfActionable(error)
                }
            case .didFetchChanges(let event):
                #if DEBUG
                if event.context.reason == .scheduled { probeSnapshot.scheduledFetchCompletions += 1 }
                #endif
                Task { await self.fetchRemoteChanges() }
            case .fetchedDatabaseChanges,
                 .willFetchChanges,
                 .willFetchRecordZoneChanges,
                 .willSendChanges,
                 .didSendChanges:
                break
            @unknown default:
                break
            }
        } catch {
            await report(error)
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard accountLease.isActive, !stopped else { return nil }
        let scoped = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0) && $0.recordID?.zoneID == HistoryCloudSchema.zoneID
        }
        let textChanges = scoped.filter { $0.recordID?.recordName.hasPrefix("audio-") != true }.prefix(100)
        let audioChanges = scoped.filter { $0.recordID?.recordName.hasPrefix("audio-") == true }.prefix(4)
        // Text does not wait behind an audio backlog; asset batches stay bounded.
        let changes = Array(textChanges) + Array(audioChanges)
        guard !changes.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            await self.recordToSave(with: recordID, syncEngine: syncEngine)
        }
    }

    // MARK: - Events

    private func handleFetchedRecordZoneChanges(
        _ event: CKSyncEngine.Event.FetchedRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) async throws {
        #if DEBUG
        probeSnapshot.engineFetchedRecords += event.modifications.count
        for modification in event.modifications {
            let record = modification.record
            for key in record.allKeys() {
                if let url = (record[key] as? CKAsset)?.fileURL,
                   let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    probeSnapshot.deliveredAssetBytes += Int64(bytes)
                }
            }
        }
        #endif
        try await applyFetchedChanges(
            modifications: event.modifications.map(\.record),
            deletions: event.deletions.map(\.recordID),
            syncEngine: syncEngine
        )
        let fetchedCount = event.modifications.count + event.deletions.count
        if fetchedCount > 0 {
            logger.info(
                "Engine-fetched app-data changes modifications=\(event.modifications.count, privacy: .public) deletions=\(event.deletions.count, privacy: .public)"
            )
        }
    }

    private func applyFetchedChanges(
        modifications: [CKRecord],
        deletions: [CKRecord.ID],
        syncEngine: CKSyncEngine
    ) async throws {
        guard accountLease.isActive, !stopped else { throw CancellationError() }
        // Persist disposable asset URLs before processing text transactions or
        // advancing the polling token. One actor owns every audio mutation.
        for record in modifications where record.recordType == AudioCloudSchema.recordType {
            try await audioPersistence.receiveMetadata(record)
        }
        let pendingHistory = try context.fetch(FetchDescriptor<HistorySyncChange>())
        let pendingHistoryByID = Dictionary(
            pendingHistory.map { ($0.entryID, $0) },
            uniquingKeysWith: { _, last in last }
        )
        let pendingVocabulary = try context.fetch(FetchDescriptor<VocabularySyncChange>())
        let pendingVocabularyByID = Dictionary(
            pendingVocabulary.map { ($0.entryID, $0) },
            uniquingKeysWith: { _, last in last }
        )

        for record in modifications {
            if let value = HistoryCloudSchema.value(from: record) {
                if pendingHistoryByID[value.id]?.kind == .delete { continue }

                try upsertHistory(value)
                if let change = pendingHistoryByID[value.id], change.kind == .save {
                    context.delete(change)
                    syncEngine.state.remove(pendingRecordZoneChanges: [
                        .saveRecord(HistoryCloudSchema.recordID(for: value.id)),
                    ])
                }
                continue
            }

            guard let value = VocabularyCloudSchema.value(from: record) else { continue }
            if let local = try vocabularyEntry(with: value.id),
               pendingVocabularyByID[value.id] != nil,
               VocabularyConflictResolution.resolve(
                   localModifiedAt: local.modifiedAt,
                   remoteModifiedAt: value.modifiedAt
               ) == .keepLocal {
                local.cloudSystemFields = value.systemFields
                syncEngine.state.add(pendingRecordZoneChanges: [
                    .saveRecord(VocabularyCloudSchema.recordID(for: value.id)),
                ])
            } else {
                try upsertVocabulary(value)
                if let change = pendingVocabularyByID[value.id] {
                    context.delete(change)
                }
                syncEngine.state.remove(pendingRecordZoneChanges: [
                    .saveRecord(VocabularyCloudSchema.recordID(for: value.id)),
                ])
            }
        }

        for recordID in deletions where recordID.zoneID == HistoryCloudSchema.zoneID {
            if let id = UUID(uuidString: recordID.recordName) {
                if let entry = try historyEntry(with: id) {
                    context.delete(entry)
                }
                if let change = pendingHistoryByID[id] {
                    context.delete(change)
                }
            } else if let id = VocabularyCloudSchema.entryID(from: recordID) {
                if let entry = try vocabularyEntry(with: id) {
                    context.delete(entry)
                }
                if let change = pendingVocabularyByID[id] {
                    context.delete(change)
                }
            }
            syncEngine.state.remove(pendingRecordZoneChanges: [
                .saveRecord(recordID),
                .deleteRecord(recordID),
            ])
        }

        if context.hasChanges {
            try context.save()
        }
    }

    private func handleSentRecordZoneChanges(
        _ event: CKSyncEngine.Event.SentRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) async throws {
        for record in event.savedRecords where record.recordType == AudioCloudSchema.recordType {
            try await audioPersistence.acknowledge(record)
        }
        var completedHistory: [UUID: HistorySyncChangeKind] = [:]
        var completedVocabulary = Set<String>()

        for record in event.savedRecords where record.recordID.zoneID == HistoryCloudSchema.zoneID {
            if let id = UUID(uuidString: record.recordID.recordName) {
                completedHistory[id] = .save
            } else if let value = VocabularyCloudSchema.value(from: record),
                      let local = try vocabularyEntry(with: value.id) {
                local.cloudSystemFields = value.systemFields
                if local.modifiedAt <= value.modifiedAt {
                    completedVocabulary.insert(value.id)
                } else {
                    syncEngine.state.add(pendingRecordZoneChanges: [
                        .saveRecord(VocabularyCloudSchema.recordID(for: value.id)),
                    ])
                }
            }
        }
        for recordID in event.deletedRecordIDs where recordID.zoneID == HistoryCloudSchema.zoneID {
            if let id = UUID(uuidString: recordID.recordName) {
                completedHistory[id] = .delete
            }
        }

        for failure in event.failedRecordSaves {
            let recordID = failure.record.recordID
            guard recordID.zoneID == HistoryCloudSchema.zoneID else { continue }
            if failure.record.recordType == AudioCloudSchema.recordType,
               failure.error.code != .serverRecordChanged {
                try await audioPersistence.noteUploadFailure(failure.record, message: failure.error.localizedDescription)
            }

            switch failure.error.code {
            case .serverRecordChanged:
                guard let serverRecord = failure.error.serverRecord else {
                    await report(failure.error)
                    continue
                }
                if serverRecord.recordType == AudioCloudSchema.recordType {
                    try await audioPersistence.acknowledge(serverRecord)
                    syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                } else if let id = UUID(uuidString: recordID.recordName),
                   let value = HistoryCloudSchema.value(from: serverRecord) {
                    try upsertHistory(value)
                    completedHistory[id] = .save
                } else if let value = VocabularyCloudSchema.value(from: serverRecord),
                          let local = try vocabularyEntry(with: value.id) {
                    if VocabularyConflictResolution.resolve(
                        localModifiedAt: local.modifiedAt,
                        remoteModifiedAt: value.modifiedAt
                    ) == .keepLocal {
                        local.cloudSystemFields = value.systemFields
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                    } else {
                        try upsertVocabulary(value)
                        completedVocabulary.insert(value.id)
                    }
                } else {
                    await report(failure.error)
                }
            case .zoneNotFound:
                if failure.error.userInfo[CKErrorUserDidResetEncryptedDataKey] as? Bool == true {
                    try await recoverEncryptionReset(syncEngine: syncEngine)
                } else {
                    ensureZoneIsPending(in: syncEngine)
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                }
            case .unknownItem:
                if let id = VocabularyCloudSchema.entryID(from: recordID),
                   let local = try vocabularyEntry(with: id) {
                    local.cloudSystemFields = nil
                }
                syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
            default:
                await reportIfActionable(failure.error)
            }
        }

        for (recordID, error) in event.failedRecordDeletes where recordID.zoneID == HistoryCloudSchema.zoneID {
            guard let id = UUID(uuidString: recordID.recordName) else { continue }
            switch error.code {
            case .unknownItem:
                completedHistory[id] = .delete
            case .zoneNotFound:
                completedHistory[id] = .delete
                ensureZoneIsPending(in: syncEngine)
            default:
                await reportIfActionable(error)
            }
        }

        let pendingHistory = try context.fetch(FetchDescriptor<HistorySyncChange>())
        for change in pendingHistory where completedHistory[change.entryID] == change.kind {
            context.delete(change)
        }
        let pendingVocabulary = try context.fetch(FetchDescriptor<VocabularySyncChange>())
        for change in pendingVocabulary where completedVocabulary.contains(change.entryID) {
            context.delete(change)
        }
        if context.hasChanges {
            try context.save()
        }
        if !completedHistory.isEmpty || !completedVocabulary.isEmpty
            || !event.failedRecordSaves.isEmpty || !event.failedRecordDeletes.isEmpty {
            let savedCount = completedHistory.values.count { $0 == .save }
            let deletedCount = completedHistory.values.count { $0 == .delete }
            logger.info(
                "Sent cloud changes historySaves=\(savedCount, privacy: .public) historyDeletes=\(deletedCount, privacy: .public) vocabularySaves=\(completedVocabulary.count, privacy: .public) failedSaves=\(event.failedRecordSaves.count, privacy: .public) failedDeletes=\(event.failedRecordDeletes.count, privacy: .public)"
            )
        }
    }

    func downloadAudio(_ info: AudioRecordingInfo) async throws {
        guard accountLease.isActive, !stopped else { throw CancellationError() }
        let recordIDs = (0..<info.chunkCount).map {
            AudioCloudSchema.recordID(AudioCloudSchema.recordName(id: info.id, index: $0))
        }
        let results = try await database.records(for: recordIDs)
        guard accountLease.isActive, !stopped else { throw CancellationError() }
        for recordID in recordIDs {
            guard let result = results[recordID] else { throw AudioArchiveError.audioUnavailable }
            try await audioPersistence.receive(try result.get())
        }
    }

    private func pollRemoteChanges(
        syncEngine: CKSyncEngine
    ) async throws -> (modifications: Int, deletions: Int) {
        var modificationCount = 0
        var deletionCount = 0
        var resetExpiredToken = false

        while true {
            do {
                let page = try await ProjectedZoneReceiver.fetch(database: database, token: pollingChangeToken)
                guard accountLease.isActive, !stopped else { throw CancellationError() }
                let records = page.records
                #if DEBUG
                probeSnapshot.projectedPages += 1
                probeSnapshot.projectedRecords += records.count
                for record in records {
                    for key in record.allKeys() {
                        if let url = (record[key] as? CKAsset)?.fileURL,
                           let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                            probeSnapshot.deliveredAssetBytes += Int64(bytes)
                        }
                    }
                }
                #endif
                let deletedRecordIDs = page.deletions

                if !records.isEmpty || !deletedRecordIDs.isEmpty {
                    try await applyFetchedChanges(
                        modifications: records,
                        deletions: deletedRecordIDs,
                        syncEngine: syncEngine
                    )
                }
                guard let token = page.token else { throw AudioArchiveError.invalidRecording }
                pollingChangeToken = token
                try persistPollingToken(token)
                modificationCount += records.count
                deletionCount += deletedRecordIDs.count

                if !page.moreComing {
                    return (modificationCount, deletionCount)
                }
            } catch let error as CKError where error.code == .changeTokenExpired && !resetExpiredToken {
                resetExpiredToken = true
                pollingChangeToken = nil
                try? FileManager.default.removeItem(at: pollingTokenURL)
                logger.info("Cloud polling token expired; refetching the zone")
            }
        }
    }

    // MARK: - Local persistence

    private func seedExistingHistoryIfNeeded() throws {
        guard !FileManager.default.fileExists(atPath: seedMarkerURL.path) else { return }

        let existingChanges = try context.fetch(FetchDescriptor<HistorySyncChange>())
        let queuedIDs = Set(existingChanges.map(\.entryID))
        let sharedIDs = try sharedCaptureIDs()
        for entry in try context.fetch(FetchDescriptor<HistoryEntry>()) where !queuedIDs.contains(entry.id) && !(entry.audioRecordingID.map(sharedIDs.contains) ?? false) {
            context.insert(HistorySyncChange(entryID: entry.id, kind: .save))
        }
        if context.hasChanges {
            try context.save()
        }
        try Data().write(to: seedMarkerURL, options: .atomic)
    }

    private func seedExistingVocabularyIfNeeded() throws {
        guard !FileManager.default.fileExists(atPath: vocabularySeedMarkerURL.path) else { return }

        let existingChanges = try context.fetch(FetchDescriptor<VocabularySyncChange>())
        let queuedIDs = Set(existingChanges.map(\.entryID))
        for entry in try context.fetch(FetchDescriptor<VocabularyEntry>()) where !queuedIDs.contains(entry.id) {
            context.insert(VocabularySyncChange(entryID: entry.id))
        }
        if context.hasChanges {
            try context.save()
        }
        try Data().write(to: vocabularySeedMarkerURL, options: .atomic)
    }

    private func addOutboxChanges(to syncEngine: CKSyncEngine) async throws {
        let audioChanges = Set(try await audioPersistence.pendingRecordNames().map {
            CKSyncEngine.PendingRecordZoneChange.saveRecord(AudioCloudSchema.recordID($0))
        })
        let historyChanges: Set<CKSyncEngine.PendingRecordZoneChange> = Set(
            try context.fetch(FetchDescriptor<HistorySyncChange>()).map { change in
                let recordID = HistoryCloudSchema.recordID(for: change.entryID)
                return change.kind == .save
                    ? CKSyncEngine.PendingRecordZoneChange.saveRecord(recordID)
                    : CKSyncEngine.PendingRecordZoneChange.deleteRecord(recordID)
            }
        )
        let vocabularyChanges = Set(
            try context.fetch(FetchDescriptor<VocabularySyncChange>()).map { change in
                CKSyncEngine.PendingRecordZoneChange.saveRecord(
                    VocabularyCloudSchema.recordID(for: change.entryID)
                )
            }
        )
        let desired = historyChanges.union(vocabularyChanges).union(audioChanges)
        let desiredByID: [CKRecord.ID: CKSyncEngine.PendingRecordZoneChange] = Dictionary(
            desired.compactMap { change in change.recordID.map { ($0, change) } },
            uniquingKeysWith: { _, last in last }
        )
        let obsolete = syncEngine.state.pendingRecordZoneChanges.filter { change in
            guard let recordID = change.recordID, let replacement = desiredByID[recordID] else { return false }
            return change != replacement
        }
        syncEngine.state.remove(pendingRecordZoneChanges: obsolete)

        let existing = Set(syncEngine.state.pendingRecordZoneChanges)
        syncEngine.state.add(pendingRecordZoneChanges: Array(desired.subtracting(existing)))
    }

    private func recordToSave(with recordID: CKRecord.ID, syncEngine: CKSyncEngine) async -> CKRecord? {
        do {
            guard accountLease.isActive, !stopped else { return nil }
            if recordID.recordName.hasPrefix("audio-") {
                let record = try await audioPersistence.recordToUpload(named: recordID.recordName)
                if record == nil { syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)]) }
                return record
            }
            if let id = UUID(uuidString: recordID.recordName) {
                guard let entry = try historyEntry(with: id) else {
                    syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                    return nil
                }
                return HistoryCloudSchema.makeRecord(from: HistoryCloudRecord(entry: entry))
            }
            if let id = VocabularyCloudSchema.entryID(from: recordID),
               let entry = try vocabularyEntry(with: id) {
                return VocabularyCloudSchema.makeRecord(from: VocabularyCloudRecord(entry: entry))
            }
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
        } catch {
            await report(error)
            return nil
        }
    }

    private func historyEntry(with id: UUID) throws -> HistoryEntry? {
        var descriptor = FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func vocabularyEntry(with id: String) throws -> VocabularyEntry? {
        var descriptor = FetchDescriptor<VocabularyEntry>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func upsertHistory(_ value: HistoryCloudRecord) throws {
        if let entry = try historyEntry(with: value.id) {
            entry.text = value.text
            entry.createdAt = value.createdAt
            entry.providerDisplayName = value.providerDisplayName
            entry.deviceName = value.deviceName
            // An old client may echo the original text-only record.
            if let audioID = value.audioRecordingID { entry.audioRecordingID = audioID }
        } else {
            context.insert(HistoryEntry(
                id: value.id,
                text: value.text,
                createdAt: value.createdAt,
                providerDisplayName: value.providerDisplayName,
                deviceName: value.deviceName,
                audioRecordingID: value.audioRecordingID
            ))
        }
    }

    private func upsertVocabulary(_ value: VocabularyCloudRecord) throws {
        if let entry = try vocabularyEntry(with: value.id) {
            entry.text = value.text
            entry.normalizedText = value.normalizedText
            entry.createdAt = value.createdAt
            entry.modifiedAt = value.modifiedAt
            entry.isTombstone = value.isDeleted
            entry.cloudSystemFields = value.systemFields
        } else {
            context.insert(VocabularyEntry(
                id: value.id,
                text: value.text,
                normalizedText: value.normalizedText,
                createdAt: value.createdAt,
                modifiedAt: value.modifiedAt,
                isTombstone: value.isDeleted,
                cloudSystemFields: value.systemFields
            ))
        }
    }


    private func loadState() throws -> CKSyncEngine.State.Serialization? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        return try JSONDecoder().decode(
            CKSyncEngine.State.Serialization.self,
            from: Data(contentsOf: stateURL)
        )
    }

    private func loadPollingToken() throws -> CKServerChangeToken? {
        guard FileManager.default.fileExists(atPath: pollingTokenURL.path) else { return nil }
        return try NSKeyedUnarchiver.unarchivedObject(
            ofClass: CKServerChangeToken.self,
            from: Data(contentsOf: pollingTokenURL)
        )
    }

    private func persist(_ state: CKSyncEngine.State.Serialization) throws {
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    private func persistPollingToken(_ token: CKServerChangeToken) throws {
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: token,
            requiringSecureCoding: true
        )
        try data.write(to: pollingTokenURL, options: .atomic)
    }

    // MARK: - Engine state

    private func ensureZoneIsPending(in syncEngine: CKSyncEngine) {
        guard accountLease.isActive, !stopped else { return }
        let alreadyPending = syncEngine.state.pendingDatabaseChanges.contains { change in
            if case .saveZone(let zone) = change {
                return zone.zoneID == HistoryCloudSchema.zoneID
            }
            return false
        }
        if !alreadyPending {
            syncEngine.state.add(pendingDatabaseChanges: [
                .saveZone(CKRecordZone(zoneID: HistoryCloudSchema.zoneID)),
            ])
        }
    }

    private func hasPendingChanges(in syncEngine: CKSyncEngine) -> Bool {
        !syncEngine.state.pendingDatabaseChanges.isEmpty
            || syncEngine.state.pendingRecordZoneChanges.contains {
                $0.recordID?.zoneID == HistoryCloudSchema.zoneID
            }
    }

    func restoreAfterIntentionalDeletion() async throws {
        guard accountLease.isActive else { throw CancellationError() }
        if FileManager.default.fileExists(atPath: deletionMarkerURL.path) {
            try FileManager.default.removeItem(at: deletionMarkerURL)
        }
        try Data().write(to: restorationMarkerURL, options: .atomic)
        stopped = false
        if let syncEngine {
            ensureZoneIsPending(in: syncEngine)
            await uploadPendingChanges()
        } else {
            await start()
        }
        try await resumeRetainedLibraryRestoration()
    }

    func resumeRetainedLibraryRestoration() async throws {
        guard accountLease.isActive, !stopped else { throw CancellationError() }
        guard FileManager.default.fileExists(atPath: restorationMarkerURL.path) else { return }
        try reseedTextAndVocabulary()
        let missing = try await audioPersistence.reseedRetainedOriginals()
        try await onEncryptionReset()
        await uploadPendingChanges()
        guard accountLease.isActive else { throw CancellationError() }
        guard missing == 0 else {
            throw NSError(domain: "CloudLibraryRestoration", code: 1, userInfo: [NSLocalizedDescriptionKey: "Restoration is incomplete: \(missing) legacy original recordings are unavailable."])
        }
        guard try context.fetchCount(FetchDescriptor<HistorySyncChange>()) == 0,
              try context.fetchCount(FetchDescriptor<VocabularySyncChange>()) == 0,
              try await audioPersistence.pendingRecordNames().isEmpty else { throw AudioArchiveError.audioUnavailable }
        try FileManager.default.removeItem(at: restorationMarkerURL)
    }

    private func sharedCaptureIDs() throws -> Set<UUID> {
        Set(try context.fetch(FetchDescriptor<AudioRecording>()).filter { $0.info?.source.hasPrefix("unified/") == true }.map(\.id))
    }

    private func reseedTextAndVocabulary() throws {
        let pendingHistory = try context.fetch(FetchDescriptor<HistorySyncChange>())
        let pendingIDs = Set(pendingHistory.map(\.entryID))
        let sharedIDs = try sharedCaptureIDs()
        for entry in try context.fetch(FetchDescriptor<HistoryEntry>()) where !pendingIDs.contains(entry.id) && !(entry.audioRecordingID.map(sharedIDs.contains) ?? false) {
            context.insert(HistorySyncChange(entryID: entry.id, kind: .save))
        }
        let pendingTerms = Set(try context.fetch(FetchDescriptor<VocabularySyncChange>()).map(\.entryID))
        for entry in try context.fetch(FetchDescriptor<VocabularyEntry>()) {
            entry.cloudSystemFields = nil
            if !pendingTerms.contains(entry.id) { context.insert(VocabularySyncChange(entryID: entry.id)) }
        }
        try context.save()
    }

    private func recoverEncryptionReset(syncEngine: CKSyncEngine) async throws {
        guard !recoveringReset, accountLease.isActive, !stopped else { return }
        recoveringReset = true
        defer { recoveringReset = false }
        let cloud = CKContainer(identifier: MumlaDataStore.cloudContainerIdentifier)
        guard try await cloud.userRecordID().recordName == accountLease.ownerID,
              accountLease.isActive else { throw CancellationError() }
        try Data().write(to: restorationMarkerURL, options: .atomic)
        _ = try await database.deleteRecordZone(withID: HistoryCloudSchema.zoneID)
        guard accountLease.isActive else { throw CancellationError() }
        pollingChangeToken = nil
        if FileManager.default.fileExists(atPath: pollingTokenURL.path) {
            try FileManager.default.removeItem(at: pollingTokenURL)
        }
        ensureZoneIsPending(in: syncEngine)
        shouldSendAgain = true
        try await resumeRetainedLibraryRestoration()
    }

    private func reportIfActionable(_ error: Error) async {
        if let cloudError = error as? CKError {
            if cloudError.code == .userDeletedZone {
                stopped = true
                do { try Data().write(to: deletionMarkerURL, options: .atomic) }
                catch { await report(error) }
                if let syncEngine { Task { await syncEngine.cancelOperations() } }
                await onCloudDeletion()
                return
            }
            if cloudError.code == .zoneNotFound,
               cloudError.userInfo[CKErrorUserDidResetEncryptedDataKey] as? Bool == true,
               let syncEngine {
                do { try await recoverEncryptionReset(syncEngine: syncEngine) }
                catch { await report(error) }
                return
            }
        }
        let cloudErrorCode = (error as? CKError)?.code.rawValue ?? -1
        logger.error(
            "Cloud sync error type=\(String(reflecting: type(of: error)), privacy: .public) cloudCode=\(cloudErrorCode, privacy: .public)"
        )
        guard let cloudError = error as? CKError else {
            await report(error)
            return
        }
        switch cloudError.code {
        case .networkFailure,
             .networkUnavailable,
             .missingEntitlement,
             .notAuthenticated,
             .operationCancelled,
             .partialFailure,
             .requestRateLimited,
             .serviceUnavailable,
             .zoneBusy,
             .zoneNotFound:
            break
        default:
            await report(error)
        }
    }

    private func report(_ error: Error) async {
        await onPersistenceError?(error)
    }
}

private nonisolated extension CKSyncEngine.PendingRecordZoneChange {
    var recordID: CKRecord.ID? {
        switch self {
        case .saveRecord(let recordID), .deleteRecord(let recordID):
            recordID
        @unknown default:
            nil
        }
    }
}
