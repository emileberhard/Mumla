import DictationLibrary
import Foundation
import SpeakerRecognition

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
    let startedAt: Date
    let onFailure: @Sendable (VoiceFilterStage, DiagnosticError) -> Void

    var speakers: AccessSpeakers? { profile.isTrusted ? .onRequest : nil }
}

struct VoiceProfiles {
    let preferences: CloudPreferenceStore
    let dataStore: MumlaDataStore

    func voice(onFailure: @escaping @Sendable (VoiceFilterStage, DiagnosticError) -> Void) async throws -> OnlyMyVoice? {
        guard let store = try await forgettingStore() else { return nil }
        return OnlyMyVoice(profile: try await store.profile(), store: store, startedAt: .now, onFailure: onFailure)
    }

    func learnFromHistory() async throws -> VoiceHistoryOutcome? {
        let partition = dataStore.partitionID
        guard let store = try await forgettingStore(), let window = try await store.beginHistory() else { return nil }
        let started = ContinuousClock.now
        let recordings: [VoiceHistoryRecording]
        do { recordings = try await dataStore.localOriginals() } catch DictationLibraryError.accountChanged {
            throw CancellationError()
        } catch where dataStore.partitionID != partition {
            throw CancellationError()
        }
        guard dataStore.partitionID == partition else { throw CancellationError() }
        let history = try await VoiceHistory.learn(from: recordings, in: window, decode: { try await OriginalAudio.pcm16(from: $0) })
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

nonisolated struct VoiceHistoryOutcome: Sendable {
    let checked: Int
    let learned: Int
    let unreadable: Int
    let isTrusted: Bool
    let elapsed: Duration

    var measurements: [String: Int] {
        ["voice_history_checked": checked, "voice_history_learned": learned, "voice_history_unreadable": unreadable,
         "voice_history_trusted": isTrusted ? 1 : 0, "voice_history_ms": Int(elapsed / .milliseconds(1))]
    }
}

nonisolated struct VoiceHistoryTrigger: Hashable {
    let partition: UUID
    let voices: VoiceSelection
}

extension VoiceFilterOutcome {
    nonisolated var metadata: [String: String] {
        ["voice_filter": path.rawValue, "voice_labels": String(labelCount), "voice_labels_dropped": String(droppedCount)]
    }
}
