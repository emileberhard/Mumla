import Foundation
import SpeechKit

enum TranscriptionEngineFactory {
    static func makeBatchEngine(access: SpeechProviderAccess) throws -> TranscriptionEngine {
        TranscriptionEngine(provider: AzureSpeechTranscriptionProvider(configuration: try .init(
            access: access,
            modelOptions: .init(transcribeStyle: .clean)
        )))
    }
}
