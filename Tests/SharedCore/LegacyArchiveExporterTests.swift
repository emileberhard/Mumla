import CryptoKit
import Foundation
import Testing

@Suite("Legacy archive export")
@MainActor
struct LegacyArchiveExporterTests {
    @Test(arguments: [AudioArchiveFileType.wav, .caf])
    func sealsOriginalsAndUnknownTextProvenance(fileType: AudioArchiveFileType) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data([11, 22, 33, 44])
        let info = recording(bytes, fileType: fileType)
        let original = root.appendingPathComponent(info.fileName)
        try bytes.write(to: original)
        let snapshot = LegacyArchiveExporter.Snapshot(
            history: [history(recordingID: info.id)],
            vocabulary: [.init(id: "term", text: "NuGet", normalizedText: "nuget", createdAt: .distantPast, modifiedAt: .distantPast, isTombstone: true)],
            recordings: [info]
        )
        let output = try await LegacyArchiveExporter.export(
            snapshot: snapshot, to: root.appendingPathComponent("exports"), expectedAccount: "synthetic-a",
            currentAccount: { "synthetic-a" }, original: { id in
                #expect(id == info.id)
                return original
            }
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let manifest = try decoder.decode(LegacyArchiveExportManifest.self, from: Data(contentsOf: output.appendingPathComponent("manifest.json")))
        #expect(abs(manifest.createdAt.timeIntervalSinceNow) < 30)
        #expect(manifest.formatVersion == 1)
        #expect(manifest.account.hash == digest(Data("synthetic-a".utf8)))
        #expect(manifest.complete)
        #expect(!manifest.freshness.catchUpReachedEnd)
        #expect(manifest.freshness.scope == "localSnapshot")
        #expect(manifest.completeness.audioPresentCount == 1)
        let rawManifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("manifest.json"))) as? [String: Any])
        #expect(rawManifest["createdAt"] is NSNumber)
        #expect(manifest.files.count == 4)
        #expect(!output.path.contains("synthetic-a"))
        #expect(try Data(contentsOf: output.appendingPathComponent("audio/" + info.fileName)) == bytes)
        for file in manifest.files {
            let data = try Data(contentsOf: output.appendingPathComponent(file.path))
            #expect(file.byteCount == Int64(data.count))
            #expect(file.sha256 == digest(data))
        }
        let rows = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("history.json"))) as? [[String: Any]])
        #expect(rows.first?["provenance"] as? String == "unknown")
        #expect(rows.first?["kind"] == nil)
        #expect(rows.first?["settings"] == nil)
        let vocabulary = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("vocabulary.json"))) as? [[String: Any]])
        #expect(vocabulary.first?["isTombstone"] as? Bool == true)
        #expect(try Data(contentsOf: original) == bytes)
    }

    @Test
    func excludesUnifiedCopiesWithoutLosingTextOnlyLegacyHistory() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let unified = recording(Data([1]), source: "unified/remotecoder")
        let textOnly = history(recordingID: nil)
        let snapshot = LegacyArchiveExporter.Snapshot(history: [history(recordingID: unified.id), textOnly], vocabulary: [], recordings: [unified])
        let output = try await LegacyArchiveExporter.export(
            snapshot: snapshot, to: root, expectedAccount: "synthetic-a", currentAccount: { "synthetic-a" },
            original: { _ in Issue.record("Unified copies must use their shared archive export"); throw AudioArchiveError.invalidRecording }
        )
        let rows = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("history.json"))) as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows.first?["id"] as? String == textOnly.id.uuidString)
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.appendingPathComponent("audio").path).isEmpty)
    }

    @Test
    func missingReferencedRecordingCannotBeMarkedComplete() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingID = UUID()
        let output = try await LegacyArchiveExporter.export(
            snapshot: .init(history: [history(recordingID: missingID)], vocabulary: [], recordings: []),
            to: root, expectedAccount: "synthetic-a", currentAccount: { "synthetic-a" },
            original: { _ in Issue.record("Missing metadata must not invent an audio file"); throw AudioArchiveError.invalidRecording }
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let manifest = try decoder.decode(LegacyArchiveExportManifest.self, from: Data(contentsOf: output.appendingPathComponent("manifest.json")))
        #expect(!manifest.complete)
        #expect(manifest.completeness.missingAudioCaptureIDs == [missingID])
        #expect(!manifest.completeness.problems.isEmpty)
    }

    @Test
    func accountChangeDuringAudioRetrievalRemovesOnlyItsIncompleteExport() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = root.appendingPathComponent("keep.txt")
        try Data([99]).write(to: sentinel)
        let info = recording(Data([1]))
        var account = "synthetic-a"
        await #expect(throws: LegacyArchiveExportError.self) {
            _ = try await LegacyArchiveExporter.export(
                snapshot: .init(history: [], vocabulary: [], recordings: [info]), to: root,
                expectedAccount: "synthetic-a", currentAccount: { account }, original: { _ in
                    account = "synthetic-b"
                    return sentinel
                }
            )
        }
        #expect(try Data(contentsOf: sentinel) == Data([99]))
        #expect(try sealedAndStagingFiles(root).isEmpty)
    }

    @Test
    func corruptOriginalCannotProduceASealedManifest() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("corrupt.wav")
        try Data([8, 9]).write(to: original)
        let info = recording(Data([1, 2]))
        await #expect(throws: LegacyArchiveExportError.self) {
            _ = try await LegacyArchiveExporter.export(
                snapshot: .init(history: [], vocabulary: [], recordings: [info]), to: root,
                expectedAccount: "synthetic-a", currentAccount: { "synthetic-a" }, original: { _ in original }
            )
        }
        #expect(try sealedAndStagingFiles(root).isEmpty)
        #expect(try Data(contentsOf: original) == Data([8, 9]))
    }

    @Test
    func publicEntryPointRejectsUnconfirmedOfflineStores() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MumlaDataStore(directoryURL: root.appendingPathComponent("store"), cloudSyncEnabled: false)
        let target = root.appendingPathComponent("exports")
        await #expect(throws: LegacyArchiveExportError.self) {
            _ = try await LegacyArchiveExporter.export(dataStore: store, to: target, expectedAccount: "synthetic-a")
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LegacyArchiveExportTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func recording(_ bytes: Data, fileType: AudioArchiveFileType = .wav, source: String = "batch") -> AudioRecordingInfo {
        AudioRecordingInfo(id: UUID(), createdAt: Date(timeIntervalSince1970: 1_000), providerRawValue: "legacy", providerDisplayName: "Legacy Provider", deviceName: "Synthetic device", source: source, durationMilliseconds: nil, byteCount: bytes.count, sha256: digest(bytes), fileType: fileType)
    }

    private func history(recordingID: UUID?) -> LegacyArchiveExporter.History {
        .init(id: UUID(), text: "Synthetic legacy text", createdAt: Date(timeIntervalSince1970: 1_000), providerDisplayName: "Legacy Provider", deviceName: "Synthetic device", audioRecordingID: recordingID)
    }

    private func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func sealedAndStagingFiles(_ root: URL) throws -> [URL] {
        let enumeration = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        return enumeration.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "manifest.json" || $0.lastPathComponent.hasPrefix(".staging-") }
    }
}
