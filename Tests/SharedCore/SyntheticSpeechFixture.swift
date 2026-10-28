import Foundation

enum SyntheticSpeechFixture {
    static let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Evaluations/RealtimeTranscription/fixtures/en-short-technical.wav")
    static let durationSeconds = 2.8
}
