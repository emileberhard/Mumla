import Foundation
import Testing

@Suite("Archived original recovery")
struct ArchivedOriginalRecoveryTests {
    @Test @MainActor
    func transcribeAgainDerivesAWAVTheAccessServiceMeasures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArchivedOriginalRecovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MumlaDataStore(directoryURL: root, cloudSyncEnabled: false)
        let id = try await store.saveOriginalAudio(
            Result { try OriginalAudioWriter.encode(contentsOf: SyntheticSpeechFixture.url) },
            source: "realtime", durationMilliseconds: nil
        )
        #expect(try store.recordingInfo(for: id).fileType == .caf)

        let wav = try await store.providerWAV(for: id)

        let samples = try #require(PCM16WAVHeader.sampleCount(of: wav, sampleRate: AccessGrant.sampleRate))
        let expected = SyntheticSpeechFixture.durationSeconds * Double(AccessGrant.sampleRate)
        #expect(abs(Double(samples) - expected) < 0.1 * Double(AccessGrant.sampleRate))
    }
}
