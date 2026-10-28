import Foundation
import SpeechKit

enum TranscriptionUploadAudio {
    static func wav(data: Data, fileName: String, engine: TranscriptionEngine) throws -> TranscriptionAudio {
        guard data.count <= engine.maximumAudioByteCount else {
            throw SpeechKitError.invalidRequest("Recording exceeds this provider's upload limit")
        }
        return try TranscriptionAudio(
            data: data,
            fileName: fileName,
            mimeType: "audio/wav",
            fileExtension: "wav"
        )
    }
}
