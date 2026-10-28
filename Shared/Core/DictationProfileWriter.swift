import CloudKit
import DictationLibrary
import Foundation
import Observation

nonisolated protocol DictationProfileRemote: Sendable {
    func latestProfile(for account: DictationAccountSession) async throws -> DictationProfileSnapshot?
    func saveProfile(_ profile: DictationProfile, for account: DictationAccountSession) async throws
    func restoreCachedProfile(for account: DictationAccountSession) async throws
}

nonisolated struct DictationProfileConflict: Error {}

enum SpokenLanguagesSave: Equatable {
    case saving([String])
    case failed([String])
}

nonisolated enum DictationProfileEdit: Equatable, Sendable {
    case languages([String])
    case archiveEnabled(Bool)

    func applied(to profile: DictationProfile) -> DictationProfile {
        var profile = profile
        switch self {
        case .languages(let languages): profile.languages = languages
        case .archiveEnabled(let enabled): profile.archiveEnabled = enabled
        }
        return profile
    }
}

@MainActor
@Observable
final class DictationProfileWriter {
    private(set) var languagesSave: SpokenLanguagesSave?
    private var failedLanguagesAccount: DictationAccountSession?
    private var latestLanguagesEdit: UUID?
    private var generation = UUID()
    private var tail: Task<Void, Never>?
    private let remote: any DictationProfileRemote
    private let onSaved: @MainActor (DictationAccountSession) async -> Void

    init(remote: any DictationProfileRemote, onSaved: @escaping @MainActor (DictationAccountSession) async -> Void) {
        self.remote = remote
        self.onSaved = onSaved
    }

    @discardableResult
    func saveLanguages(_ languages: [String], account: DictationAccountSession) -> Task<Void, Never> {
        let id = UUID()
        latestLanguagesEdit = id
        failedLanguagesAccount = nil
        languagesSave = .saving(languages)
        let write = submit(.languages(languages), account: account, creatingFrom: nil)
        let generation = generation
        return Task {
            let result = await write.result
            guard generation == self.generation, latestLanguagesEdit == id else { return }
            switch result {
            case .success:
                languagesSave = nil
            case .failure:
                languagesSave = .failed(languages)
                failedLanguagesAccount = account
            }
        }
    }

    @discardableResult
    func retryLanguages(account: DictationAccountSession?) -> Task<Void, Never>? {
        guard case .failed(let languages) = languagesSave, let target = failedLanguagesAccount ?? account else { return nil }
        return saveLanguages(languages, account: target)
    }

    func submit(_ edit: DictationProfileEdit, account: DictationAccountSession, creatingFrom base: DictationProfile?) -> Task<Void, any Error> {
        enqueue(account: account) { [self] in
            do {
                try await apply(edit, account: account, creatingFrom: base)
            } catch is DictationProfileConflict {
                try await apply(edit, account: account, creatingFrom: base)
            }
        }
    }

    func restoreCachedProfile(account: DictationAccountSession) -> Task<Void, any Error> {
        enqueue(account: account) { [remote] in
            try await remote.restoreCachedProfile(for: account)
        }
    }

    func failWithoutAccount(_ languages: [String]) {
        latestLanguagesEdit = nil
        failedLanguagesAccount = nil
        languagesSave = .failed(languages)
    }

    func accountChanged() {
        generation = UUID()
        if !hasAccountlessFailure { languagesSave = nil }
        failedLanguagesAccount = nil
        latestLanguagesEdit = nil
    }

    private var hasAccountlessFailure: Bool {
        guard case .failed = languagesSave else { return false }
        return failedLanguagesAccount == nil
    }

    private func enqueue(account: DictationAccountSession, _ write: @escaping @MainActor () async throws -> Void) -> Task<Void, any Error> {
        let previous = tail
        let generation = generation
        let task = Task {
            await previous?.value
            guard generation == self.generation else { throw DictationLibraryError.accountChanged }
            try await write()
            guard generation == self.generation else { throw DictationLibraryError.accountChanged }
            await onSaved(account)
        }
        tail = Task { _ = await task.result }
        return task
    }

    private func apply(_ edit: DictationProfileEdit, account: DictationAccountSession, creatingFrom base: DictationProfile?) async throws {
        let requestedAt = Date.now
        let latest = try await remote.latestProfile(for: account)
        if let latest, latest.refreshedAt < requestedAt { throw DictationLibraryError.profileUnavailable }
        guard let current = latest?.profile ?? base else { throw DictationLibraryError.profileUnavailable }
        try await remote.saveProfile(edit.applied(to: current), for: account)
    }
}

extension DictationLibraryStore: DictationProfileRemote {
    func latestProfile(for account: DictationAccountSession) async throws -> DictationProfileSnapshot? {
        try validateAccountSession(account)
        let snapshot = try await refresh()
        try validateAccountSession(account)
        return snapshot
    }

    func saveProfile(_ profile: DictationProfile, for account: DictationAccountSession) async throws {
        do {
            try await saveProfile(profile, session: account)
        } catch let error as CKError where error.code == .serverRecordChanged {
            throw DictationProfileConflict()
        }
    }

    func restoreCachedProfile(for account: DictationAccountSession) async throws {
        _ = try await restoreCachedProfile(session: account)
    }
}
