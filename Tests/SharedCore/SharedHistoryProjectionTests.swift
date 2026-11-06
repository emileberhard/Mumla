import DictationLibrary
import Foundation
import SwiftData
import Testing

@Suite("Shared dictations in normal History")
@MainActor
struct SharedHistoryProjectionTests {
    @Test func remoteResultAppearsInHistoryWithAudioWithoutCloudOutboxAndSurvivesRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MumlaDataStore(directoryURL: root, cloudSyncEnabled: false)
        let entry = try fixture()
        let result = try #require(entry.results.first)
        let local = HistoryEntry(text: result.text + " ", providerDisplayName: "Provider", deviceName: "Device", audioRecordingID: entry.id)
        local.unfilteredText = "Synthetic everyone"
        store.container.mainContext.insert(local)
        try store.container.mainContext.save()
        let projection = SharedHistoryProjection(container: store.container)
        let lease = AccountPartitionLease(ownerID: "synthetic")
        try await projection.apply([entry], unfilteredTexts: [:], lease: lease)
        try await projection.insert(result, deviceName: "Device", unfilteredText: nil, lease: lease)
        try await projection.apply([entry], unfilteredTexts: [:], lease: lease)
        let reader = ModelContext(store.container)
        let history = try reader.fetch(FetchDescriptor<HistoryEntry>())
        #expect(history.map(\.id) == [result.id])
        #expect(try store.container.mainContext.fetch(FetchDescriptor<HistoryEntry>()).map(\.id) == [result.id])
        #expect(history.first?.text == result.text)
        #expect(history.first?.audioRecordingID == entry.id)
        #expect(history.first?.unfilteredText == "Synthetic everyone")
        let audio = try #require(reader.fetch(FetchDescriptor<AudioRecording>()).first)
        #expect(audio.info?.source == "unified/RemoteCoder")
        #expect(audio.info?.sha256 == entry.capture.originalSHA256)
        #expect(audio.info?.fileType == .caf)
        #expect(try reader.fetchCount(FetchDescriptor<HistorySyncChange>()) == 0)
        #expect(try reader.fetchCount(FetchDescriptor<AudioSyncChange>()) == 0)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("AudioArchive/" + entry.id.uuidString + ".caf").path))
        let restarted = SharedHistoryProjection(container: store.container)
        try await restarted.apply([entry], unfilteredTexts: [:], lease: lease)
        #expect(try ModelContext(store.container).fetchCount(FetchDescriptor<HistoryEntry>()) == 1)
    }

    @Test func aRetranscribedResultKeepsEveryonesWords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MumlaDataStore(directoryURL: root, cloudSyncEnabled: false)
        let entry = try fixture()
        let result = try #require(entry.results.first)
        try await SharedHistoryProjection(container: store.container)
            .apply([entry], unfilteredTexts: [result.id: "Synthetic everyone"], lease: AccountPartitionLease(ownerID: "synthetic"))
        #expect(try ModelContext(store.container).fetch(FetchDescriptor<HistoryEntry>()).map(\.unfilteredText) == ["Synthetic everyone"])
    }

    @Test func localCanonicalWriteAndRefreshShareOneOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MumlaDataStore(directoryURL: root, cloudSyncEnabled: false)
        let entry = try fixture()
        let result = try #require(entry.results.first)
        let projection = SharedHistoryProjection(container: store.container)
        let lease = AccountPartitionLease(ownerID: "synthetic")
        async let local: Void = projection.insert(result, deviceName: "Device", unfilteredText: nil, lease: lease)
        async let remote: Void = projection.apply([entry], unfilteredTexts: [:], lease: lease)
        try await local
        try await remote
        #expect(try store.container.mainContext.fetch(FetchDescriptor<HistoryEntry>()).map(\.id) == [result.id])
    }

    @Test func deletedSharedResultStaysHiddenAfterRestartAndNewResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MumlaDataStore(directoryURL: root, cloudSyncEnabled: false)
        let entry = try fixture()
        let result = try #require(entry.results.first)
        let lease = AccountPartitionLease(ownerID: "synthetic")
        try await SharedHistoryProjection(container: store.container).apply([entry], unfilteredTexts: [:], lease: lease)
        let visible = try #require(store.container.mainContext.fetch(FetchDescriptor<HistoryEntry>()).first)
        store.delete(visible)
        #expect(try store.container.mainContext.fetchCount(FetchDescriptor<HistoryEntry>(predicate: #Predicate { !$0.isHidden })) == 0)
        let cleanup = DictationResultVersion(id: UUID(), captureID: entry.id, createdAt: result.createdAt.addingTimeInterval(1), kind: .cleanup,
            text: "A separately saved cleanup result", model: "synthetic-cleanup", contextWasUsed: false, parentResultID: result.id, plan: result.plan)
        let updated = DictationArchiveEntry(capture: entry.capture, results: [result, cleanup], originalURL: nil, published: true)
        try await SharedHistoryProjection(container: store.container).apply([updated], unfilteredTexts: [:], lease: lease)
        let reader = ModelContext(store.container)
        #expect(try reader.fetch(FetchDescriptor<HistoryEntry>(predicate: #Predicate { !$0.isHidden })).map(\.id) == [cleanup.id])
        #expect(try reader.fetchCount(FetchDescriptor<AudioRecording>()) == 1)
        #expect(try reader.fetchCount(FetchDescriptor<HistorySyncChange>()) == 0)
        store.clear()
        try await SharedHistoryProjection(container: store.container).apply([updated], unfilteredTexts: [:], lease: lease)
        #expect(try ModelContext(store.container).fetchCount(FetchDescriptor<HistoryEntry>(predicate: #Predicate { !$0.isHidden })) == 0)
    }

    @Test func invalidatedAccountCannotProjectAnotherAccountHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MumlaDataStore(directoryURL: root, cloudSyncEnabled: false)
        let lease = AccountPartitionLease(ownerID: "synthetic")
        lease.invalidate()
        await #expect(throws: LibraryAgentError.self) {
            try await SharedHistoryProjection(container: store.container).apply([fixture()], unfilteredTexts: [:], lease: lease)
        }
        #expect(try store.container.mainContext.fetchCount(FetchDescriptor<HistoryEntry>()) == 0)
    }

    private func fixture() throws -> DictationArchiveEntry {
        let model = TranscriptionProviderType.azureMAITranscribe2.libraryModelID
        let profile = DictationProfile(archiveEnabled: true, preferredModel: model, languages: ["en", "sv"], dictionary: [], cleanupEnabled: false, outputLanguage: nil, thinkingLevel: "low")
        let capabilities = try DictationCapabilities(models: [model], fallbackModel: model, supportsCleanup: true)
        let plan = DictationPlan(unverifiedProfile: profile, context: .chat, capabilities: capabilities)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let id = UUID()
        let object: [String: Any] = ["formatVersion": 1, "id": id.uuidString, "source": "RemoteCoder", "startedAt": 1_000, "finishedAt": 1_001,
            "sampleRate": 48_000, "interrupted": false, "originalSHA256": String(repeating: "a", count: 64), "originalByteCount": 100,
            "plan": try JSONSerialization.jsonObject(with: encoder.encode(plan))]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let capture = try decoder.decode(DictationCapture.self, from: JSONSerialization.data(withJSONObject: object))
        let result = DictationResultVersion(id: UUID(), captureID: id, createdAt: Date(timeIntervalSince1970: 1_001), kind: .providerOutput,
            text: "Synthetic shared history", model: model, contextWasUsed: false, parentResultID: nil, plan: plan)
        return DictationArchiveEntry(capture: capture, results: [result], originalURL: nil, published: true)
    }
}
