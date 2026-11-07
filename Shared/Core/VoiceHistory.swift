import Foundation

nonisolated struct VoiceHistoryRecording: Sendable {
    let url: URL
    let startedAt: Date
    let finishedAt: Date
}

nonisolated struct VoiceHistoryCandidate: Sendable {
    let embedding: SpeakerEmbedding
    let startedAt: Date
}

nonisolated struct VoiceHistory: Sendable {
    private static let recordingLimit = 100
    private static let candidateLimit = 30
    private static let longestRecording: TimeInterval = 120

    private(set) var candidates: [VoiceHistoryCandidate] = []
    private(set) var checked = 0
    private(set) var unreadable = 0

    @concurrent
    static func learn(
        from recordings: [VoiceHistoryRecording], startedAfter start: Date, finishedBefore end: Date, modelURL: URL
    ) async throws -> VoiceHistory {
        let eligible = recordings
            .filter { $0.startedAt >= start && $0.finishedAt < end && $0.finishedAt.timeIntervalSince($0.startedAt) <= longestRecording }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(recordingLimit)
        var history = VoiceHistory()
        guard !eligible.isEmpty else { return history }
        let embedder = try SpeakerEmbedder(modelURL: modelURL)
        for recording in eligible where history.candidates.count < candidateLimit {
            try Task.checkCancellation()
            history.checked += 1
            let pcm: Data
            do { pcm = try await OriginalAudio.pcm16(from: recording.url) } catch {
                history.unreadable += 1
                continue
            }
            var listener = VoiceListener(embedder: embedder)
            try await listener.append(pcm)
            if let embedding = try await listener.finish().learningCandidate() {
                history.candidates.insert(VoiceHistoryCandidate(embedding: embedding, startedAt: recording.startedAt), at: 0)
            }
        }
        return history
    }
}

nonisolated struct VoiceHistoryOutcome: Sendable {
    let history: VoiceHistory
    let isTrusted: Bool
    let elapsed: Duration

    var measurements: [String: Int] {
        ["voice_history_checked": history.checked, "voice_history_learned": history.candidates.count,
         "voice_history_unreadable": history.unreadable, "voice_history_trusted": isTrusted ? 1 : 0,
         "voice_history_ms": Int(elapsed / .milliseconds(1))]
    }
}

nonisolated struct VoiceHistoryTrigger: Hashable {
    let partition: UUID
    let voices: VoiceSelection
}
