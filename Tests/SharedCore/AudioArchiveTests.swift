import AVFAudio
import CloudKit
import Foundation
import SwiftData
import Testing

@Suite("Original audio archive")
struct AudioArchiveTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AudioArchiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func info(for data: Data, id: UUID = UUID()) -> AudioRecordingInfo {
        AudioRecordingInfo(
            id: id, createdAt: Date(timeIntervalSince1970: 1_000), providerRawValue: "test",
            providerDisplayName: "Test", deviceName: "Test device", source: "batch",
            durationMilliseconds: 2_000, byteCount: data.count, sha256: AudioArchive.digest(data),
            fileType: .wav
        )
    }

    private func archive(_ root: URL) -> AudioArchive {
        AudioArchive(directory: root, offloadDirectory: root.appendingPathComponent("Offloaded"))
    }

    private func chunkRecords(for data: Data, info: AudioRecordingInfo, in root: URL) throws -> [CKRecord] {
        try (0..<info.chunkCount).map { index in
            let start = index * AudioRecordingInfo.chunkBytes
            let url = root.appendingPathComponent("asset-\(index)")
            try data.subdata(in: start..<min(start + AudioRecordingInfo.chunkBytes, data.count)).write(to: url)
            return try AudioCloudSchema.makeRecord(info: info, index: index, fileURL: url)
        }
    }

    @Test func reconstructsOutOfOrderChunksWithoutChangingAnyBytes() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = archive(root.appendingPathComponent("source"))
        let destination = archive(root.appendingPathComponent("destination"))
        var data = Data(repeating: 7, count: AudioRecordingInfo.chunkBytes + 123)
        data[data.count - 1] = 42
        let info = info(for: data)
        try source.save(data, info: info)
        #expect(info.chunkCount == 2)
        let last = try source.uploadChunk(info: info, index: 1)
        #expect(try !destination.receive(info: info, index: 1, assetURL: last))
        #expect(try destination.recordings().isEmpty)
        // Recreating the archive simulates a process restart between downloads.
        let restarted = archive(root.appendingPathComponent("destination"))
        let first = try source.uploadChunk(info: info, index: 0)
        #expect(try restarted.receive(info: info, index: 0, assetURL: first))
        let published = try #require(restarted.localAudioURL(info))
        #expect(published.deletingLastPathComponent() == restarted.offloadDirectory)
        #expect(try Data(contentsOf: published) == data)
        #expect(try restarted.recordings() == [info])
        #expect(try restarted.receive(info: info, index: 0, assetURL: first))
    }

    @Test func detectsCorruptedTransferBeforePublishingRecording() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = archive(root)
        let original = Data([1, 2, 3])
        let corrupt = root.appendingPathComponent("corrupt.part")
        try Data([1, 9, 3]).write(to: corrupt)
        #expect(throws: AudioArchiveError.self) {
            try archive.receive(info: info(for: original), index: 0, assetURL: corrupt)
        }
        #expect(try archive.recordings().isEmpty)
    }

    @Test func resumesAfterAudioCommitBeforeSidecarCommit() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = archive(root)
        try FileManager.default.createDirectory(at: archive.offloadDirectory, withIntermediateDirectories: true)
        let data = Data([1, 2, 3])
        let info = info(for: data)
        try Data([1, 2]).write(to: archive.offloadDirectory.appendingPathComponent(info.fileName))
        let part = root.appendingPathComponent("part")
        try data.write(to: part)
        #expect(try archive.receive(info: info, index: 0, assetURL: part))
        #expect(try archive.recordings() == [info])
        #expect(try Data(contentsOf: #require(archive.localAudioURL(info))) == data)
    }

    @Test func refusesToReplaceAnOriginalRecordingWithDifferentAudio() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = archive(root)
        let original = Data([1, 2, 3])
        let originalInfo = info(for: original)
        try archive.save(original, info: originalInfo)
        let replacement = Data([9, 8, 7])
        #expect(throws: AudioArchiveError.self) {
            try archive.save(replacement, info: info(for: replacement, id: originalInfo.id))
        }
        #expect(try Data(contentsOf: #require(archive.localAudioURL(originalInfo))) == original)
    }

    @Test func chunkCloudMetadataIsEncryptedAndIdentityIsValidated() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data([1, 2])
        let info = info(for: data)
        let url = root.appendingPathComponent("audio.wav")
        try data.write(to: url)
        let record = try AudioCloudSchema.makeRecord(info: info, index: 0, fileURL: url)
        #expect(record["audio"] is CKAsset)
        #expect(record.encryptedValues["metadata"] is Data)
        let (decoded, index) = try AudioCloudSchema.metadata(from: record)
        #expect(decoded == info)
        #expect(index == 0)
        record.encryptedValues["chunkIndex"] = 1
        #expect(throws: AudioArchiveError.self) { try AudioCloudSchema.metadata(from: record) }
    }

    @Test @MainActor func retainsAudioWithoutTranscriptAndAcrossRestart() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MumlaDataStore(directoryURL: root, cloudSyncEnabled: false)
        var ids: [UUID] = []
        for _ in 0..<7 {
            ids.append(try await store.saveAudio(
                .data(Data([1, 2, 3])), providerRawValue: "test", providerDisplayName: "Test",
                source: "batch", durationMilliseconds: 1_000, fileType: .wav
            ))
        }
        let reopened = MumlaDataStore(directoryURL: root, cloudSyncEnabled: false)
        #expect(try reopened.container.mainContext.fetchCount(FetchDescriptor<AudioRecording>()) == 7)
        #expect(try reopened.container.mainContext.fetchCount(FetchDescriptor<AudioSyncChange>()) == 7)
        #expect(try reopened.container.mainContext.fetchCount(FetchDescriptor<HistoryEntry>()) == 0)
        for id in ids { #expect(try await Data(contentsOf: reopened.audioFile(for: id)) == Data([1, 2, 3])) }
    }

    @Test @MainActor func multipleTranscriptsReferToOneImmutableRecording() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MumlaDataStore(directoryURL: root, cloudSyncEnabled: false)
        let id = try await store.saveAudio(
            .data(Data([1, 2, 3])), providerRawValue: "test", providerDisplayName: "Test",
            source: "batch", durationMilliseconds: 1_000, fileType: .wav
        )
        store.record(text: "Original transcript", audioRecordingID: id)
        store.record(text: "Improved transcript", audioRecordingID: id)
        let entries = try store.container.mainContext.fetch(FetchDescriptor<HistoryEntry>())
        #expect(entries.count == 2)
        for entry in entries {
            #expect(entry.audioRecordingID == id)
            let record = HistoryCloudSchema.makeRecord(from: HistoryCloudRecord(entry: entry))
            #expect(HistoryCloudSchema.value(from: record)?.audioRecordingID == id)
        }
        store.clear()
        #expect(try store.container.mainContext.fetchCount(FetchDescriptor<AudioRecording>()) == 1)
        #expect(try await Data(contentsOf: store.audioFile(for: id)) == Data([1, 2, 3]))
    }

    @Test @MainActor func recoversFileCommittedBeforeDatabaseAndQueuesEachChunkOnce() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MumlaDataStore(directoryURL: root, cloudSyncEnabled: false)
        let data = Data(repeating: 1, count: AudioRecordingInfo.chunkBytes + 1)
        let info = info(for: data)
        try store.audioArchive.save(data, info: info)
        try await store.recoverAudioArchive()
        try await store.recoverAudioArchive()
        #expect(try store.container.mainContext.fetchCount(FetchDescriptor<AudioRecording>()) == 1)
        #expect(try store.container.mainContext.fetchCount(FetchDescriptor<AudioSyncChange>()) == 2)
    }
    @Test @MainActor func clearsUploadOutboxOnlyAfterEveryChunkIsAcknowledged() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(
            for: AudioRecording.self, AudioSyncChange.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let writer = AudioRecordingPersistence(container: container, archive: archive(root))
        let id = UUID()
        _ = try await writer.save(
            .data(Data(repeating: 3, count: AudioRecordingInfo.chunkBytes + 17)),
            id: id, createdAt: .now, providerRawValue: "test", providerDisplayName: "Test",
            deviceName: "Test", source: "batch", durationMilliseconds: nil, fileType: .wav
        )
        let names = try await writer.pendingRecordNames().sorted()
        #expect(names.count == 2)
        let first = try #require(await writer.recordToUpload(named: names[0]))
        try await writer.acknowledge(first)
        #expect(try await writer.pendingRecordNames().count == 1)
        let before = try #require(container.mainContext.fetch(FetchDescriptor<AudioRecording>()).first)
        #expect(!before.uploaded)
        let second = try #require(await writer.recordToUpload(named: names[1]))
        try await writer.acknowledge(second)
        #expect(try await writer.pendingRecordNames().isEmpty)
        // Read through a fresh context, as a second app process would.
        let after = try #require(ModelContext(container).fetch(FetchDescriptor<AudioRecording>()).first)
        #expect(after.uploaded)
        try await writer.acknowledge(second)
        #expect(try await writer.pendingRecordNames().isEmpty)
    }

    @Test @MainActor func conflictingServerCaptureNeverAcknowledgesPendingAudio() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(
            for: AudioRecording.self, AudioSyncChange.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let writer = AudioRecordingPersistence(container: container, archive: archive(root))
        let id = UUID()
        _ = try await writer.save(
            .data(Data([1, 2, 3])), id: id, createdAt: .now, providerRawValue: "test",
            providerDisplayName: "Test", deviceName: "Test", source: "batch", durationMilliseconds: nil,
            fileType: .wav
        )
        let name = try #require(await writer.pendingRecordNames().first)
        let record = try #require(await writer.recordToUpload(named: name))
        record.encryptedValues["metadata"] = try JSONEncoder().encode(info(for: Data([9, 8, 7]), id: id))
        await #expect(throws: AudioArchiveError.self) { try await writer.acknowledge(record) }
        #expect(try await writer.pendingRecordNames() == [name])
    }

    @Test func metadataWrittenBeforeOriginalAudioDecodesAsWAV() throws {
        let caf = AudioRecordingInfo(
            id: UUID(), createdAt: Date(timeIntervalSince1970: 1_000), providerRawValue: "test",
            providerDisplayName: "Test", deviceName: "Test", source: "realtime", durationMilliseconds: nil,
            byteCount: 3, sha256: "abc", fileType: .caf
        )
        #expect(try JSONDecoder().decode(AudioRecordingInfo.self, from: JSONEncoder().encode(caf)) == caf)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(caf)) as? [String: Any])
        legacy.removeValue(forKey: "fileType")
        let decoded = try JSONDecoder().decode(AudioRecordingInfo.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.fileType == .wav)
        #expect(decoded.fileName == "\(caf.id.uuidString).wav")
    }

    @Test @MainActor func acknowledgedAudioMovesToPurgeableStorageAndRestoresFromCloudRecords() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(
            for: AudioRecording.self, AudioSyncChange.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let archive = archive(root)
        let writer = AudioRecordingPersistence(container: container, archive: archive)
        var data = Data(repeating: 5, count: AudioRecordingInfo.chunkBytes + 9)
        data[0] = 1
        let id = try await writer.save(
            .data(data), id: UUID(), createdAt: .now, providerRawValue: "test", providerDisplayName: "Test",
            deviceName: "Test", source: "batch", durationMilliseconds: nil, fileType: .caf
        )
        let info = try #require(try container.mainContext.fetch(FetchDescriptor<AudioRecording>()).first?.info)
        #expect(info.id == id)
        #expect(archive.hasDurableAudio(info))
        for name in try await writer.pendingRecordNames() {
            try await writer.acknowledge(try #require(await writer.recordToUpload(named: name)))
        }
        #expect(!archive.hasDurableAudio(info))
        let offloaded = try #require(archive.localAudioURL(info))
        #expect(offloaded.deletingLastPathComponent() == archive.offloadDirectory)
        #expect(try Data(contentsOf: offloaded) == data)

        try FileManager.default.removeItem(at: offloaded)
        #expect(archive.localAudioURL(info) == nil)
        for record in try chunkRecords(for: data, info: info, in: root) {
            try await writer.receive(record)
        }
        #expect(try Data(contentsOf: #require(archive.localAudioURL(info))) == data)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<AudioRecording>()) == 1)
        #expect(try await writer.pendingRecordNames().isEmpty)
    }

    @Test @MainActor func startupOffloadsUploadedAudioAndReindexingOffloadedAudioNeverReuploads() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MumlaDataStore(directoryURL: root, cloudSyncEnabled: false)
        let id = try await store.saveAudio(
            .data(Data([4, 5, 6])), providerRawValue: "test", providerDisplayName: "Test",
            source: "batch", durationMilliseconds: nil, fileType: .wav
        )
        let info = try store.recordingInfo(for: id)
        let recording = try #require(try store.container.mainContext.fetch(FetchDescriptor<AudioRecording>()).first)
        recording.uploaded = true
        try store.container.mainContext.save()
        try await store.recoverAudioArchive()
        #expect(!store.audioArchive.hasDurableAudio(info))
        #expect(try await Data(contentsOf: store.audioFile(for: id)) == Data([4, 5, 6]))

        let restored = root.appendingPathComponent("restored")
        try FileManager.default.createDirectory(at: restored, withIntermediateDirectories: true)
        for folder in ["AudioArchive", "Offloaded"] {
            try FileManager.default.copyItem(at: root.appendingPathComponent(folder), to: restored.appendingPathComponent(folder))
        }
        let reopened = MumlaDataStore(directoryURL: restored, cloudSyncEnabled: false)
        try await reopened.recoverAudioArchive()
        let reindexed = try #require(try reopened.container.mainContext.fetch(FetchDescriptor<AudioRecording>()).first)
        #expect(reindexed.uploaded)
        #expect(try reopened.container.mainContext.fetchCount(FetchDescriptor<AudioSyncChange>()) == 0)
    }

    @Test @MainActor func opusReceivedByOlderClientIsRelabeledAndRestoresFromCloudRecords() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encoded = try OriginalAudioWriter.encode(contentsOf: SyntheticSpeechFixture.url)
        defer { try? FileManager.default.removeItem(at: encoded) }
        let data = try Data(contentsOf: encoded)
        var opus = info(for: data)
        opus.fileType = .caf
        var olderClientInfo = opus
        olderClientInfo.fileType = .wav

        let store = MumlaDataStore(directoryURL: root, cloudSyncEnabled: false)
        let folder = store.audioArchive.directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(olderClientInfo.fileName))
        var sidecar = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(opus)) as? [String: Any])
        sidecar["fileType"] = nil
        try JSONSerialization.data(withJSONObject: sidecar).write(to: folder.appendingPathComponent("\(opus.id.uuidString).json"))
        let olderClient = ModelContext(store.container)
        olderClient.insert(try AudioRecording(info: olderClientInfo, uploaded: true))
        try olderClient.save()

        try await store.recoverAudioArchive()
        #expect(try store.recordingInfo(for: opus.id) == opus)
        let relabeled = try #require(store.audioArchive.localAudioURL(opus))
        #expect(relabeled.deletingLastPathComponent() == store.audioArchive.offloadDirectory)
        #expect(try await store.providerWAV(for: opus.id).prefix(4) == Data("RIFF".utf8))

        try FileManager.default.removeItem(at: relabeled)
        let receiver = AudioRecordingPersistence(container: store.container, archive: store.audioArchive)
        for record in try chunkRecords(for: data, info: opus, in: root) {
            try await receiver.receive(record)
        }
        #expect(try Data(contentsOf: #require(store.audioArchive.localAudioURL(opus))) == data)
    }

    @Test func originalAudioIsCompactOpusAndDecodesToProviderWAV() async throws {
        let writer = try OriginalAudioWriter()
        for (format, seconds) in [
            (OriginalAudioWriter.format, 2),
            (try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)), 1),
        ] {
            let frames = AVAudioFrameCount(format.sampleRate) * AVAudioFrameCount(seconds)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(frames) {
                    buffer.floatChannelData![channel][frame] = 0.3 * sinf(Float(frame) * 2 * .pi * 220 / Float(format.sampleRate))
                }
            }
            writer.write(buffer)
        }
        let url = try writer.finish()
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatOpus)
        #expect(file.fileFormat.sampleRate == 48_000)
        #expect(file.length == 3 * 48_000)
        let bytes = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(bytes < 3 * Int(OriginalAudioWriter.bitRate) / 8 + 16_384)

        let wav = try await OriginalAudio.providerWAV(from: url, fileType: .caf)
        #expect(wav.count == 44 + 3 * OriginalAudio.batchProviderSampleRate * 2)
        #expect(throws: OriginalAudioError.self) { try writer.finish() }
    }

    @Test func emptyOriginalAudioIsRejectedAndRemoved() throws {
        let writer = try OriginalAudioWriter()
        #expect(throws: OriginalAudioError.self) { try writer.finish() }
        #expect(!FileManager.default.fileExists(atPath: writer.url.path))
    }
}
