import Foundation
import SpeechKit

enum SimulatedDictation {
    static var transcript: String? {
#if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["MUMLA_FAKE_TRANSCRIPT"]
#else
        nil
#endif
    }
}

#if DEBUG && targetEnvironment(simulator)
actor SimulatedRealtimeTranscriptionSession: RealtimeTranscriptionSession {
    nonisolated let sampleRate = AccessGrant.sampleRate
    nonisolated var finalizationTimeout: Duration { .seconds(10) }

    private let transcript: String
    private var continuation: AsyncThrowingStream<RealtimeTranscriptionEvent, any Error>.Continuation?

    init(transcript: String) {
        self.transcript = transcript
    }

    func connectTranscription() async throws -> AsyncThrowingStream<RealtimeTranscriptionEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: RealtimeTranscriptionEvent.self, throwing: (any Error).self)
        self.continuation = continuation
        return stream
    }

    func sendAudioChunk(_ audioData: Data) async throws {}

    func requestCommit() async throws {
        try await Task.sleep(for: .milliseconds(700))
        continuation?.yield(.committedTranscript(transcript))
        continuation?.yield(.finalizationCompleted)
        continuation?.finish()
    }

    func disconnect() async {
        continuation?.finish()
    }
}
#endif
