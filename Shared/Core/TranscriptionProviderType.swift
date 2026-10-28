import Foundation

nonisolated enum TranscriptionProviderType: String, CaseIterable, Sendable {
    case openAIGpt4oMiniTranscribe = "openai-gpt-4o-mini-transcribe"
    case openAIRealtimeWhisper = "openai-gpt-realtime-whisper"
    case openAIGpt4oTranscribeRealtime = "openai-gpt-4o-transcribe-realtime"
    case openAIGpt4oMiniTranscribeRealtime = "openai-gpt-4o-mini-transcribe-realtime"
    case openAIGpt4oMiniTranscribe20250320Realtime = "openai-gpt-4o-mini-transcribe-2025-03-20-realtime"
    case openAIGpt4oMiniTranscribe20251215Realtime = "openai-gpt-4o-mini-transcribe-2025-12-15-realtime"
    case openAIWhisperRealtime = "openai-whisper-realtime"
    case assemblyAI = "assemblyai"
    case elevenLabsScribeV2 = "elevenlabs-scribe-v2"
    case elevenLabsScribeV2Realtime = "elevenlabs-scribe-v2-realtime"
    case gemini35Flash = "gemini-3-5-flash"
    case gemini35Transcribe = "gemini-3-5-transcribe"
    case gemini35TranscribeLive = "gemini-3-5-transcribe-live"
    case azureMAITranscribe2 = "azure-mai-transcribe-2"

    static let dictation = Self.azureMAITranscribe2
    static let dictationDisplayName = "Microsoft MAI-Transcribe-2 (Clean)"

    static func displayName(libraryModelID model: String) -> String {
        model == dictation.libraryModelID ? dictationDisplayName : model
    }

    var libraryModelID: String {
        switch self {
        case .openAIGpt4oMiniTranscribe:
            "openai/gpt-4o-mini-transcribe-2025-12-15/batch"
        case .openAIRealtimeWhisper:
            "openai/gpt-realtime-whisper/realtime"
        case .openAIGpt4oTranscribeRealtime:
            "openai/gpt-4o-transcribe/realtime"
        case .openAIGpt4oMiniTranscribeRealtime:
            "openai/gpt-4o-mini-transcribe/realtime"
        case .openAIGpt4oMiniTranscribe20250320Realtime:
            "openai/gpt-4o-mini-transcribe-2025-03-20/realtime"
        case .openAIGpt4oMiniTranscribe20251215Realtime:
            "openai/gpt-4o-mini-transcribe-2025-12-15/realtime"
        case .openAIWhisperRealtime:
            "openai/whisper-1/realtime"
        case .assemblyAI:
            "assemblyai/universal-3-5-pro+universal-2/batch"
        case .elevenLabsScribeV2:
            "elevenlabs/scribe_v2/batch"
        case .elevenLabsScribeV2Realtime:
            "elevenlabs/scribe_v2_realtime/realtime"
        case .gemini35Flash:
            "google/gemini-3.5-flash/batch"
        case .gemini35Transcribe:
            "google/gemini-3.5-transcribe/batch"
        case .gemini35TranscribeLive:
            "google/gemini-3.5-transcribe-live/realtime"
        case .azureMAITranscribe2:
            "azure/MAI-Transcribe-2/progressive"
        }
    }

    var batchResultModelID: String {
        switch self {
        case .openAIRealtimeWhisper: Self.openAIGpt4oMiniTranscribe.libraryModelID
        case .elevenLabsScribeV2Realtime: Self.elevenLabsScribeV2.libraryModelID
        case .gemini35TranscribeLive: Self.gemini35Transcribe.libraryModelID
        default: libraryModelID.replacingOccurrences(of: "/realtime", with: "/batch")
            .replacingOccurrences(of: "/progressive", with: "/batch")
        }
    }

    init?(libraryModelID: String) {
        guard let value = Self.allCases.first(where: { $0.libraryModelID == libraryModelID }) else { return nil }
        self = value
    }
}
