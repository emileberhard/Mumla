import Foundation

nonisolated enum VoiceSelection: String, CaseIterable, Identifiable, Sendable {
    case onlyMine
    case everyone

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .onlyMine: "Only Mine"
        case .everyone: "Everyone"
        }
    }

    var systemImage: String {
        switch self {
        case .onlyMine: "person.wave.2"
        case .everyone: "person.2.wave.2"
        }
    }
}

nonisolated struct OnlyMyVoice: Sendable {
    let profile: VoiceProfile
    let store: VoiceProfileStore
    let modelURL: URL
    let startedAt: Date
    let onFailure: @Sendable (VoiceFilterStage, DiagnosticError) -> Void

    var speakers: AccessSpeakers? { profile.isTrusted ? .onRequest : nil }
}

nonisolated enum VoiceProfileStatus: Sendable {
    case learning
    case learned

    init(_ profile: VoiceProfile) { self = profile.isTrusted ? .learned : .learning }

    var title: LocalizedStringResource {
        switch self {
        case .learning: "Learning"
        case .learned: "Learned"
        }
    }
}

nonisolated enum VoiceFilterStage: String, Sendable {
    case filter
    case learning
}

nonisolated struct VoiceFilterOutcome: Sendable {
    enum Path: String, Sendable {
        case notHeard = "not_heard"
        case undecided
        case keptEveryone = "kept_everyone"
        case filtered
        case failed
    }

    let path: Path
    let labelCount: Int
    let droppedCount: Int
    let unfilteredText: String?

    static let notHeard = Self(path: .notHeard, labelCount: 0, droppedCount: 0, unfilteredText: nil)
    static let undecided = Self(path: .undecided, labelCount: 0, droppedCount: 0, unfilteredText: nil)
    static let failed = Self(path: .failed, labelCount: 0, droppedCount: 0, unfilteredText: nil)

    var metadata: [String: String] {
        ["voice_filter": path.rawValue, "voice_labels": String(labelCount), "voice_labels_dropped": String(droppedCount)]
    }
}

extension VoiceFilter {
    static func deadline(forSamples samples: Int) -> Duration {
        .seconds(2) + .milliseconds(samples * 5 / KaldiFilterbank.sampleRate)
    }

    static func apply(_ voices: AccessStreamReply, everyone: String, audio: SpeakerAudio, profile: SpeakerEmbedding)
        async throws -> (text: String, outcome: VoiceFilterOutcome)
    {
        let phrases = voices.phrases ?? []
        let labels = labels(in: phrases)
        var embeddings: [Int: SpeakerEmbedding] = [:]
        for label in labels where label.isJudged {
            embeddings[label.speaker] = try await audio.embedding(of: label.evidenceSamples(sampleRate: KaldiFilterbank.sampleRate))
        }
        guard let kept = keptSpeakers(of: labels, embeddings: embeddings, profile: profile) else {
            return (everyone, VoiceFilterOutcome(path: .keptEveryone, labelCount: labels.count, droppedCount: 0, unfilteredText: nil))
        }
        return (text(of: phrases, keeping: kept), VoiceFilterOutcome(path: .filtered, labelCount: labels.count,
                                                                    droppedCount: labels.count - kept.count, unfilteredText: everyone))
    }
}
