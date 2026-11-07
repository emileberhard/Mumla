import DictationLibrary
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

struct VoiceProfiles {
    let preferences: CloudPreferenceStore
    let dataStore: MumlaDataStore

    func voice(onFailure: @escaping @Sendable (VoiceFilterStage, DiagnosticError) -> Void) async throws -> OnlyMyVoice? {
        guard let store = try await forgettingStore() else { return nil }
        guard let modelURL = SpeakerEmbedder.bundledModelURL else { throw VoiceFilterError.modelMissing }
        return OnlyMyVoice(profile: try await store.profile(), store: store, modelURL: modelURL, startedAt: .now, onFailure: onFailure)
    }

    func learnFromHistory() async throws -> VoiceHistoryOutcome? {
        let partition = dataStore.partitionID
        guard let store = try await forgettingStore(), let window = try await store.beginHistory() else { return nil }
        guard let modelURL = SpeakerEmbedder.bundledModelURL else { throw VoiceFilterError.modelMissing }
        let started = ContinuousClock.now
        let recordings: [VoiceHistoryRecording]
        do { recordings = try await dataStore.localOriginals() } catch DictationLibraryError.accountChanged {
            throw CancellationError()
        } catch where dataStore.partitionID != partition {
            throw CancellationError()
        }
        guard dataStore.partitionID == partition else { throw CancellationError() }
        let history = try await VoiceHistory.learn(from: recordings, in: window, modelURL: modelURL)
        try Task.checkCancellation()
        guard let learned = try await store.learnHistory(history.candidates, in: window) else { return nil }
        return VoiceHistoryOutcome(checked: history.checked, learned: history.candidates.count, unreadable: history.unreadable,
                                   isTrusted: learned.isTrusted, elapsed: ContinuousClock.now - started)
    }

    func status() async throws -> VoiceProfileStatus? {
        guard let store = try await forgettingStore() else { return nil }
        return VoiceProfileStatus(try await store.profile())
    }

    func forget() async throws {
        let date = max(forgottenAt ?? .distantPast, .now)
        preferences.set(date, forKey: SharedPreferenceKey.voiceForgottenAt)
        do { try await dataStore.voiceProfiles?.forget(learnedBefore: date) } catch VoiceFilterError.profileUnreadable {}
    }

    func applyForget() async throws {
        _ = try await forgettingStore()
    }

    private var forgottenAt: Date? { preferences.date(forKey: SharedPreferenceKey.voiceForgottenAt) }

    private func forgettingStore() async throws -> VoiceProfileStore? {
        guard let store = dataStore.voiceProfiles else { return nil }
        if let forgottenAt { try await store.forget(learnedBefore: forgottenAt) }
        return store
    }
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
        case tooLong = "too_long"
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
    static let tooLong = Self(path: .tooLong, labelCount: 0, droppedCount: 0, unfilteredText: nil)
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
