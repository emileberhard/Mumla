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

@Suite("Dictation timing")
struct DictationTimingTests {
    let start = ContinuousClock.now

    @Test func splitsTheWaitAfterStopIntoItsPhases() {
        let timing = DictationTiming(
            captureStartedAt: start,
            streamOpenedAt: start + .milliseconds(180),
            finishSentAt: start + .milliseconds(4_150),
            resultReceivedAt: start + .milliseconds(4_620)
        )

        let measurements = DictationTiming.measurements(
            of: timing, stoppedAt: start + .milliseconds(4_000), handedOffAt: start + .milliseconds(5_230)
        )

        #expect(measurements == [
            "stop_to_handoff_ms": 1_230,
            "stream_open_ms": 180,
            "stop_to_finish_ms": 150,
            "finish_to_result_ms": 470,
            "result_to_handoff_ms": 610,
        ])
    }

    @Test func reportsOnlyTheTotalWithoutStreamMarks() {
        let measurements = DictationTiming.measurements(
            of: DictationTiming(captureStartedAt: start), stoppedAt: start, handedOffAt: start + .milliseconds(90)
        )

        #expect(measurements == ["stop_to_handoff_ms": 90])
    }

    @Test func isSlowOnlyPastTwoSeconds() {
        #expect(!DictationTiming.isSlow(stoppedAt: start, handedOffAt: start + .seconds(2)))
        #expect(DictationTiming.isSlow(stoppedAt: start, handedOffAt: start + .milliseconds(2_001)))
    }
}
