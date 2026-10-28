import Foundation
import SpeechKit

@MainActor
final class RealtimeDictationController {
    let diagnosticsSessionID = UUID().uuidString

    private let providerConfiguration: RealtimeDictationProviderConfiguration
    private let dictation: RealtimeDictation

    init(providerConfiguration: RealtimeDictationProviderConfiguration) {
        self.providerConfiguration = providerConfiguration
        self.dictation = RealtimeDictation(session: providerConfiguration.makeSession())
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
        let metadata = diagnosticsMetadata(extra: [
            "fallback_reason": completion.fallbackReason ?? "none",
            "recording_duration_ms": String(recordingDurationMilliseconds),
            "final_character_count": String(completion.text?.count ?? 0),
        ])
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
            failure: completion.error
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
