import Foundation

struct TryItLanding: Equatable {
    private var textBeforeDictation = ""
    private var transcript: String?

    mutating func recordingStarted(fieldText: String) {
        textBeforeDictation = fieldText
        transcript = nil
    }

    mutating func transcriptPublishedHere(_ text: String) {
        transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func hasLanded(in fieldText: String) -> Bool {
        guard let transcript, !transcript.isEmpty else { return false }
        return Self.occurrences(of: transcript, in: fieldText) > Self.occurrences(of: transcript, in: textBeforeDictation)
    }

    private static func occurrences(of transcript: String, in text: String) -> Int {
        text.components(separatedBy: transcript).count - 1
    }
}
