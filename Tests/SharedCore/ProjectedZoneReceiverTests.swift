import CloudKit
import Foundation
import SwiftData
import Testing

@Suite("Projected archive receiving")
struct ProjectedZoneReceiverTests {
    @Test func projectionRetainsMetadataAndExcludesAssetBytes() {
        #expect(!ProjectedZoneReceiver.desiredKeys.contains("audio"))
        #expect(ProjectedZoneReceiver.desiredKeys.contains("metadata"))
        #expect(ProjectedZoneReceiver.desiredKeys.contains("text"))
        #expect(ProjectedZoneReceiver.desiredKeys.contains("normalizedText"))
    }

    @Test @MainActor func metadataIsDurableWithoutDownloadingAnAsset() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MumlaDataStore(directoryURL: directory, cloudSyncEnabled: false)
        let persistence = AudioRecordingPersistence(container: store.container, archive: store.audioArchive)
        let info = AudioRecordingInfo(
            id: UUID(), createdAt: Date(timeIntervalSince1970: 1), providerRawValue: "synthetic",
            providerDisplayName: "Synthetic", deviceName: "Test", source: "test",
            durationMilliseconds: 100, byteCount: 1_024, sha256: "synthetic", fileType: .caf
        )
        let record = CKRecord(recordType: AudioCloudSchema.recordType, recordID: AudioCloudSchema.recordID(AudioCloudSchema.recordName(id: info.id, index: 0)))
        record.encryptedValues["metadata"] = try JSONEncoder().encode(info)
        record.encryptedValues["chunkIndex"] = 0
        try await persistence.receiveMetadata(record)
        try await persistence.receiveMetadata(record)
        let independentContext = ModelContext(store.container)
        let values = try independentContext.fetch(FetchDescriptor<AudioRecording>())
        #expect(values.count == 1)
        #expect(values.first?.info == info)
        #expect(store.audioArchive.localAudioURL(info) == nil)
        #expect(try await persistence.pendingRecordNames().isEmpty)
    }

    @Test @MainActor func restorationReportsMissingLegacyAudioWithoutDuplicatingSharedCaptures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MumlaDataStore(directoryURL: directory, cloudSyncEnabled: false)
        let persistence = AudioRecordingPersistence(container: store.container, archive: store.audioArchive)
        for source in ["legacy", "unified/batch"] {
            let info = AudioRecordingInfo(id: UUID(), createdAt: .now, providerRawValue: "synthetic",
                providerDisplayName: "Synthetic", deviceName: "Test", source: source,
                durationMilliseconds: 100, byteCount: 1_024, sha256: "synthetic", fileType: .caf)
            let record = CKRecord(recordType: AudioCloudSchema.recordType,
                recordID: AudioCloudSchema.recordID(AudioCloudSchema.recordName(id: info.id, index: 0)))
            record.encryptedValues["metadata"] = try JSONEncoder().encode(info)
            record.encryptedValues["chunkIndex"] = 0
            try await persistence.receiveMetadata(record)
        }
        #expect(try await persistence.reseedRetainedOriginals() == 1)
        #expect(try await persistence.pendingRecordNames().isEmpty)
        let values = try ModelContext(store.container).fetch(FetchDescriptor<AudioRecording>())
        #expect(values.first(where: { $0.info?.source == "legacy" })?.syncError != nil)
        #expect(values.first(where: { $0.info?.source == "unified/batch" })?.syncError == nil)
        let sharedID = try #require(values.first(where: { $0.info?.source == "unified/batch" })?.id)
        let historyID = try #require(store.record(text: "Synthetic shared read model", audioRecordingID: sharedID))
        #expect(try store.container.mainContext.fetchCount(FetchDescriptor<HistorySyncChange>()) == 0)
        let entry = try #require(store.container.mainContext.fetch(FetchDescriptor<HistoryEntry>()).first { $0.id == historyID })
        store.delete(entry)
        #expect(try store.container.mainContext.fetchCount(FetchDescriptor<HistorySyncChange>()) == 0)
        _ = store.record(text: "Synthetic shared read model", audioRecordingID: sharedID)
        store.clear()
        #expect(try store.container.mainContext.fetchCount(FetchDescriptor<HistorySyncChange>()) == 0)
    }

}
