import Foundation
import SpeechKit
import Testing

@Suite("Realtime capture tail policy")
struct RealtimeCaptureTailPolicyTests {
    @Test func waitsForOnePostStopBuffer() {
        let snapshot = RealtimeCaptureTailSnapshot(deliveredBufferCount: 4, level: 0)
        #expect(!RealtimeCaptureTailPolicy.shouldFinish(
            initialBufferCount: 4, currentSnapshot: snapshot, elapsed: .milliseconds(149)
        ))
        #expect(RealtimeCaptureTailPolicy.shouldFinish(
            initialBufferCount: 4, currentSnapshot: snapshot, elapsed: .milliseconds(150)
        ))
    }

    @Test func finishesWhenTheFirstPostStopBufferIsQuiet() {
        let snapshot = RealtimeCaptureTailSnapshot(deliveredBufferCount: 5, level: 0.01)
        #expect(RealtimeCaptureTailPolicy.shouldFinish(
            initialBufferCount: 4, currentSnapshot: snapshot, elapsed: .milliseconds(80)
        ))
    }

    @Test func keepsCapturingSpeechButNeverPastTheHardCap() {
        let snapshot = RealtimeCaptureTailSnapshot(deliveredBufferCount: 6, level: 0.2)
        #expect(!RealtimeCaptureTailPolicy.shouldFinish(
            initialBufferCount: 4, currentSnapshot: snapshot, elapsed: .milliseconds(499)
        ))
        #expect(RealtimeCaptureTailPolicy.shouldFinish(
            initialBufferCount: 4, currentSnapshot: snapshot, elapsed: .milliseconds(500)
        ))
    }
}

@Suite("Realtime fallback policy")
struct RealtimeFallbackPolicyTests {
    @Test func failedDictationSelectsSavedAudioFallback() async {
        let dictation = RealtimeDictation(session: FailingRealtimeSession())
        dictation.append(Data([0, 0]))
        let completion = await RealtimeDictationCompletion.finish(dictation)
        #expect(completion.text == nil)
        #expect(completion.fallbackReason == "realtime_connection_failed")
        #expect(completion.error is RealtimeDictationError)
    }

    @Test func finalizedTextKeepsPasteSpacing() {
        #expect(RealtimeDictationText.pasteable("Done.") == "Done. ")
        #expect(RealtimeDictationText.pasteable("") == nil)
    }
}

@Suite("Transcription upload limit")
struct TranscriptionUploadLimitTests {
    @Test func rejectsAudioBeyondTheEngineLimitBeforeUpload() throws {
        let engine = TranscriptionEngine(provider: LimitedTranscriptionProvider())
        let accepted = try TranscriptionUploadAudio.wav(
            data: Data(repeating: 0, count: 4), fileName: "audio.wav", engine: engine
        )
        #expect(accepted.data.count == 4)
        #expect(throws: SpeechKitError.self) {
            try TranscriptionUploadAudio.wav(
                data: Data(repeating: 0, count: 5), fileName: "audio.wav", engine: engine
            )
        }
    }
}

private struct LimitedTranscriptionProvider: TranscriptionProvider {
    let id = "limited-test"
    let maximumAudioByteCount = 4

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        throw SpeechKitError.invalidResponse
    }
}

private struct FailingRealtimeSession: RealtimeTranscriptionSession {
    let sampleRate = 16_000
    let finalizationTimeout: Duration = .seconds(1)

    func connectTranscription() async throws -> AsyncThrowingStream<RealtimeTranscriptionEvent, Error> {
        throw SpeechKitError.invalidResponse
    }

    func sendAudioChunk(_ audioData: Data) async throws {}

    func requestCommit() async throws {}

    func disconnect() async {}
}
