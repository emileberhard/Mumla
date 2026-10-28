import CloudKit
import Foundation
import Synchronization

nonisolated enum ProjectedZoneReceiver {
    static let desiredKeys = [
        "text", "createdAt", "providerDisplayName", "deviceName", "audioRecordingID",
        "normalizedText", "modifiedAt", "isDeleted", "metadata", "chunkIndex",
    ]

    struct Page: Sendable {
        var records: [CKRecord] = []
        var deletions: [CKRecord.ID] = []
        var token: CKServerChangeToken?
        var moreComing = false
        var error: (any Error)?
    }

    static func fetch(database: CKDatabase, token: CKServerChangeToken?) async throws -> Page {
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.previousServerChangeToken = token
        configuration.desiredKeys = desiredKeys
        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [HistoryCloudSchema.zoneID],
            configurationsByRecordZoneID: [HistoryCloudSchema.zoneID: configuration]
        )
        operation.fetchAllChanges = false
        let page = Mutex(Page())
        operation.recordWasChangedBlock = { _, result in
            page.withLock { value in
                switch result {
                case .success(let record): value.records.append(record)
                case .failure(let error): value.error = value.error ?? error
                }
            }
        }
        operation.recordWithIDWasDeletedBlock = { id, _ in
            page.withLock { $0.deletions.append(id) }
        }
        operation.recordZoneFetchResultBlock = { _, result in
            page.withLock { value in
                switch result {
                case .success(let result):
                    value.token = result.serverChangeToken
                    value.moreComing = result.moreComing
                case .failure(let error): value.error = value.error ?? error
                }
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.fetchRecordZoneChangesResultBlock = { result in
                    let value = page.withLock { $0 }
                    do {
                        try result.get()
                        if let error = value.error { throw error }
                        guard value.token != nil else { throw AudioArchiveError.invalidRecording }
                        continuation.resume(returning: value)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                database.add(operation)
            }
        } onCancel: {
            operation.cancel()
        }
    }
}
