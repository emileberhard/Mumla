import AVFAudio
import DictationLibrary
import Foundation
import SpeechKit
import Testing

@Suite("Unified dictation archive")
struct UnifiedDictationArchiveTests {
    @Test @MainActor func archivedJournalYieldsAMeasurableWAVAndMergesResultVersions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UnifiedAppIntegration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try DictationLibraryStore(directory: directory, source: "synthetic-app-integration", capacityBytes: 16 * 1_024 * 1_024, containerIdentifier: MumlaDataStore.cloudContainerIdentifier)
        var profile = DictationProfile(languages: ["en", "sv"], dictionary: ["Mumla"])
        profile.archiveEnabled = true
        let plan = DictationPlan(unverifiedProfile: profile, context: .prose, capabilities: try UnifiedDictationLibrary.capabilities())
        let capture = try await library.beginCapture(plan: plan)
        let writer = try OriginalAudioWriter(dictation: .init(id: capture.id, plan: plan, writer: capture))
        let file = try AVAudioFile(forReading: SyntheticSpeechFixture.url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        writer.write(buffer)
        let original = try await writer.finishArchived()
        let wav = try await OriginalAudio.providerWAV(from: original, fileType: .caf)
        #expect(PCM16WAVHeader.sampleCount(of: wav, sampleRate: AccessGrant.sampleRate) != nil)
        let text = "Synthetic transcript."
        let raw = DictationResultVersion(id: UUID(), captureID: capture.id, createdAt: .now, kind: .providerOutput,
            text: text, model: TranscriptionProviderType.dictation.batchResultModelID, contextWasUsed: false, parentResultID: nil, plan: plan)
        try await library.addResult(raw)
        let retranscribed = DictationResultVersion(id: UUID(), captureID: capture.id, createdAt: .now, kind: .providerOutput,
            text: text, model: TranscriptionProviderType.dictation.batchResultModelID, contextWasUsed: false, parentResultID: nil, plan: plan)
        try await library.addResult(retranscribed)
        let held = try await library.heldCaptures()
        #expect(held.count == 1)
        #expect(held.first?.originalURL == original)
        let sealed = try #require(held.first?.capture)
        let merged = try UnifiedDictationLibrary.merge(
            local: DictationArchiveEntry(capture: sealed, results: [raw], originalURL: original, published: false),
            remote: DictationArchiveEntry(capture: sealed, results: [raw, retranscribed], originalURL: nil, published: true)
        )
        #expect(Set(merged.results.map(\.id)) == [raw.id, retranscribed.id])
        #expect(merged.originalURL == original)
        #expect(merged.published)
    }
}
