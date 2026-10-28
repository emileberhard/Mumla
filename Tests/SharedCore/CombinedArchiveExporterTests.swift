import CryptoKit
import Foundation
import Testing

@Suite struct CombinedArchiveExporterTests {
    @Test func snapshotNamesOrderCapturesWithinTheSameSecond() {
        let earlier = CombinedArchiveExporter.snapshotName(createdAt: Date(timeIntervalSince1970: 1_790_000_000.125), id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!)
        let later = CombinedArchiveExporter.snapshotName(createdAt: Date(timeIntervalSince1970: 1_790_000_000.25), id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
        #expect(earlier < later)
    }

    @Test func sealsBothSectionsAndRejectsCorruption() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = AccountPartitionLease(ownerID: "synthetic-account")
        let accountHash = AccountPartition.directory(root: root, ownerID: lease.ownerID).lastPathComponent
        let payload = Data([1, 2, 3, 4])
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        var sections: [String: URL] = [:]
        for name in ["unified", "legacy"] {
            let section = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: section, withIntermediateDirectories: true)
            try payload.write(to: section.appendingPathComponent("original.wav"))
            let manifest: [String: Any] = ["complete": true, "account": ["hash": accountHash], "files": [["path": "original.wav", "byteCount": payload.count, "sha256": hash]]]
            try JSONSerialization.data(withJSONObject: manifest).write(to: section.appendingPathComponent("manifest.json"))
            sections[name] = section
        }
        let parent = root.appendingPathComponent("sealed")
        let result = try await CombinedArchiveExporter.seal(sections: sections, parent: parent, lease: lease)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let manifest = try decoder.decode(CombinedArchiveExporter.Manifest.self, from: Data(contentsOf: result.appendingPathComponent("manifest.json")))
        #expect(abs(manifest.createdAt.timeIntervalSinceNow) < 30)
        #expect(manifest.complete)
        #expect(manifest.files.count == 4)
        #expect(manifest.files.contains { $0.path == "legacy/original.wav" && $0.sha256 == hash })
        try Data([5]).write(to: sections["legacy"]!.appendingPathComponent("original.wav"), options: .atomic)
        await #expect(throws: (any Error).self) {
            try await CombinedArchiveExporter.seal(sections: sections, parent: parent, lease: lease)
        }
        #expect(try Data(contentsOf: result.appendingPathComponent("legacy/original.wav")) == payload)
        try payload.write(to: sections["legacy"]!.appendingPathComponent("original.wav"), options: .atomic)
        for _ in 0..<3 {
            let latest = try await CombinedArchiveExporter.seal(sections: sections, parent: parent, lease: lease)
            #expect(FileManager.default.fileExists(atPath: latest.path))
        }
        #expect(try FileManager.default.contentsOfDirectory(at: result.deletingLastPathComponent(), includingPropertiesForKeys: nil).count == 2)
        lease.invalidate()
        await #expect(throws: CancellationError.self) {
            try await CombinedArchiveExporter.seal(sections: sections, parent: parent, lease: lease)
        }
    }
}
