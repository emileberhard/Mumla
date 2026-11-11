import Foundation
import SpeechKit

@MainActor
final class RealtimeDictationController {
    let diagnosticsSessionID = UUID().uuidString

    private let providerConfiguration: RealtimeDictationProviderConfiguration
    private let dictation: RealtimeDictation
    private let session: GrantedRealtimeTranscriptionSession?

    init(providerConfiguration: RealtimeDictationProviderConfiguration) {
        self.providerConfiguration = providerConfiguration
#if DEBUG && targetEnvironment(simulator)
        if let transcript = SimulatedDictation.transcript {
            session = nil
            dictation = RealtimeDictation(session: SimulatedRealtimeTranscriptionSession(transcript: transcript))
            return
        }
#endif
        let session = providerConfiguration.makeSession()
        self.session = session
        dictation = RealtimeDictation(session: session)
    }

    var captureSampleRate: Int {
        dictation.sampleRate
    }

    var audioInput: @Sendable (Data) -> Void {
        { [dictation] pcmData in
            dictation.append(pcmData)
        }
    }

    func stop(recordingDurationMilliseconds: Int) async -> RealtimeDictationResult {
        let completion = await RealtimeDictationCompletion.finish(dictation)
        let voices = await session?.voices
        let unfilteredText = await session?.unfilteredText
        let metadata = diagnosticsMetadata(extra: [
            "fallback_reason": completion.fallbackReason ?? "none",
            "recording_duration_ms": String(recordingDurationMilliseconds),
            "final_character_count": String(completion.text?.count ?? 0),
        ].merging(voices?.metadata ?? [:]) { _, new in new })
        if completion.error != nil {
            CrashReporting.capture(
                message: "Realtime transcription failed; using saved audio",
                context: "realtime",
                metadata: metadata
            )
        } else {
            CrashReporting.breadcrumb("Realtime session stopped", category: "realtime", metadata: metadata)
        }
        return RealtimeDictationResult(
            diagnosticsSessionID: diagnosticsSessionID,
            text: completion.text,
            originalAudio: nil,
            fallbackReason: completion.fallbackReason,
            failure: completion.error,
            timing: await session?.timing,
            voices: voices,
            unfilteredText: unfilteredText
        )
    }

    func cancel() async {
        CrashReporting.breadcrumb(
            "Realtime session canceled",
            category: "realtime",
            metadata: diagnosticsMetadata()
        )
        await dictation.cancel()
    }

    private func diagnosticsMetadata(extra: [String: String] = [:]) -> [String: String] {
        var metadata = providerConfiguration.diagnosticsMetadata
        metadata["diagnostics_session_id"] = diagnosticsSessionID
        metadata["sample_rate"] = String(dictation.sampleRate)
        metadata.merge(extra) { _, new in new }
        return metadata
    }
}
