import DictationLibrary
import Foundation
import Testing

private actor FakeProfileRemote: DictationProfileRemote {
    private(set) var stored: DictationProfile?
    private(set) var savedAccounts: [String] = []
    private var failures: [any Error] = []
    private var holdsSaves = false
    private var heldSaves: [CheckedContinuation<Void, Never>] = []
    private var heldSaveWaiters: [CheckedContinuation<Void, Never>] = []
    private var cached: DictationProfile?
    private(set) var writes: [String] = []

    init(stored: DictationProfile?) {
        self.stored = stored
    }

    func failNextSaves(with errors: [any Error]) { failures = errors }

    func serveCachedProfile(_ profile: DictationProfile) { cached = profile }

    func holdSaves() { holdsSaves = true }

    func waitUntilASaveIsHeld() async {
        guard heldSaves.isEmpty else { return }
        await withCheckedContinuation { heldSaveWaiters.append($0) }
    }

    func releaseSaves() {
        holdsSaves = false
        heldSaves.forEach { $0.resume() }
        heldSaves = []
    }

    func latestProfile(for account: DictationAccountSession) -> DictationProfileSnapshot? {
        if let cached { return DictationProfileSnapshot(accountIdentifier: account.accountIdentifier, refreshedAt: .distantPast, profile: cached) }
        return stored.map { DictationProfileSnapshot(accountIdentifier: account.accountIdentifier, refreshedAt: .now, profile: $0) }
    }

    func restoreCachedProfile(for account: DictationAccountSession) {
        writes.append("restore")
    }

    func saveProfile(_ profile: DictationProfile, for account: DictationAccountSession) async throws {
        if holdsSaves {
            await withCheckedContinuation { continuation in
                heldSaves.append(continuation)
                heldSaveWaiters.forEach { $0.resume() }
                heldSaveWaiters = []
            }
        }
        if !failures.isEmpty { throw failures.removeFirst() }
        stored = profile
        savedAccounts.append(account.accountIdentifier)
        writes.append("save")
    }
}

@MainActor
@Suite("Dictation profile writer")
struct DictationProfileWriterTests {
    private static func account(_ identifier: String) throws -> DictationAccountSession {
        try JSONDecoder().decode(DictationAccountSession.self, from: Data(#"{"accountIdentifier":"\#(identifier)","epoch":"\#(UUID().uuidString)"}"#.utf8))
    }

    private static func profile(languages: [String], archiveEnabled: Bool) -> DictationProfile {
        var profile = DictationProfile(languages: languages, dictionary: [])
        profile.archiveEnabled = archiveEnabled
        return profile
    }

    @Test func savingShowsBeforeAnyCloudWorkAndClearsOnSuccess() async throws {
        let remote = FakeProfileRemote(stored: Self.profile(languages: ["sv"], archiveEnabled: true))
        let writer = DictationProfileWriter(remote: remote) { _ in }
        let save = writer.saveLanguages(["sv", "en"], account: try Self.account("synthetic-a"))
        #expect(writer.languagesSave == .saving(["sv", "en"]))
        await save.value
        #expect(writer.languagesSave == nil)
        #expect(await remote.stored?.languages == ["sv", "en"])
    }

    @Test func aFailedSaveShowsTheRetryRowAndRetryWritesTheSameLanguages() async throws {
        let remote = FakeProfileRemote(stored: Self.profile(languages: ["sv"], archiveEnabled: true))
        await remote.failNextSaves(with: [URLError(.notConnectedToInternet)])
        let writer = DictationProfileWriter(remote: remote) { _ in }
        await writer.saveLanguages(["en"], account: try Self.account("synthetic-a")).value
        #expect(writer.languagesSave == .failed(["en"]))
        #expect(await remote.stored?.languages == ["sv"])

        await writer.retryLanguages(account: nil)?.value
        #expect(writer.languagesSave == nil)
        #expect(await remote.stored?.languages == ["en"])
    }

    @Test func removingTheLastLanguageOfASharedProfileReachesAutomatic() async throws {
        #expect(SpokenLanguagesOwner.profile(["sv"]).edit([]) == .profile([]))
        let remote = FakeProfileRemote(stored: Self.profile(languages: ["sv"], archiveEnabled: true))
        let writer = DictationProfileWriter(remote: remote) { _ in }
        await writer.saveLanguages([], account: try Self.account("synthetic-a")).value
        #expect(await remote.stored?.languages == [])
    }

    @Test func aLanguageSaveInFlightCannotReenableRecordingStorage() async throws {
        let remote = FakeProfileRemote(stored: Self.profile(languages: ["sv"], archiveEnabled: true))
        await remote.holdSaves()
        let account = try Self.account("synthetic-a")
        let writer = DictationProfileWriter(remote: remote) { _ in }
        let languages = writer.saveLanguages(["sv", "en"], account: account)
        await remote.waitUntilASaveIsHeld()
        let archive = writer.submit(.archiveEnabled(false), account: account, creatingFrom: nil)
        await remote.releaseSaves()
        await languages.value
        try await archive.value
        #expect(await remote.stored == Self.profile(languages: ["sv", "en"], archiveEnabled: false))
    }

    @Test func aStorageChangeInFlightCannotDropALanguageChange() async throws {
        let remote = FakeProfileRemote(stored: Self.profile(languages: ["sv"], archiveEnabled: true))
        await remote.holdSaves()
        let account = try Self.account("synthetic-a")
        let writer = DictationProfileWriter(remote: remote) { _ in }
        let archive = writer.submit(.archiveEnabled(false), account: account, creatingFrom: nil)
        await remote.waitUntilASaveIsHeld()
        let languages = writer.saveLanguages(["en"], account: account)
        await remote.releaseSaves()
        try await archive.value
        await languages.value
        #expect(await remote.stored == Self.profile(languages: ["en"], archiveEnabled: false))
    }

    @Test func aCachedProfileServedAfterAFailedCloudReadIsNeverWrittenBack() async throws {
        let remote = FakeProfileRemote(stored: Self.profile(languages: ["sv"], archiveEnabled: false))
        await remote.serveCachedProfile(Self.profile(languages: ["sv"], archiveEnabled: true))
        let writer = DictationProfileWriter(remote: remote) { _ in }
        await writer.saveLanguages(["sv", "en"], account: try Self.account("synthetic-a")).value
        #expect(writer.languagesSave == .failed(["sv", "en"]))
        #expect(await remote.stored == Self.profile(languages: ["sv"], archiveEnabled: false))
        #expect(await remote.savedAccounts.isEmpty)
    }

    @Test func aRestorationRunsAfterTheEditQueuedBeforeIt() async throws {
        let remote = FakeProfileRemote(stored: Self.profile(languages: ["sv"], archiveEnabled: true))
        await remote.holdSaves()
        let account = try Self.account("synthetic-a")
        let writer = DictationProfileWriter(remote: remote) { _ in }
        let archive = writer.submit(.archiveEnabled(false), account: account, creatingFrom: nil)
        await remote.waitUntilASaveIsHeld()
        let restore = writer.restoreCachedProfile(account: account)
        await remote.releaseSaves()
        try await archive.value
        try await restore.value
        #expect(await remote.writes == ["save", "restore"])
    }

    @Test func anEditWithoutAnAccountSurvivesTheAccountArrivingAndTryAgainSavesItThere() async throws {
        let remote = FakeProfileRemote(stored: Self.profile(languages: ["sv"], archiveEnabled: true))
        let writer = DictationProfileWriter(remote: remote) { _ in }
        writer.failWithoutAccount(["en"])
        #expect(writer.languagesSave == .failed(["en"]))
        #expect(writer.retryLanguages(account: nil) == nil)

        writer.accountChanged()
        #expect(writer.languagesSave == .failed(["en"]))
        await writer.retryLanguages(account: try Self.account("synthetic-a"))?.value
        #expect(writer.languagesSave == nil)
        #expect(await remote.stored?.languages == ["en"])
        #expect(await remote.savedAccounts == ["synthetic-a"])
    }

    @Test func aConflictIsRetriedOnceFromTheLatestProfile() async throws {
        let remote = FakeProfileRemote(stored: Self.profile(languages: ["sv"], archiveEnabled: true))
        await remote.failNextSaves(with: [DictationProfileConflict()])
        let writer = DictationProfileWriter(remote: remote) { _ in }
        try await writer.submit(.archiveEnabled(false), account: try Self.account("synthetic-a"), creatingFrom: nil).value
        #expect(await remote.stored?.archiveEnabled == false)

        await remote.failNextSaves(with: [DictationProfileConflict(), DictationProfileConflict()])
        await #expect(throws: DictationProfileConflict.self) {
            try await writer.submit(.archiveEnabled(true), account: try Self.account("synthetic-a"), creatingFrom: nil).value
        }
    }

    @Test func anAccountSwitchDropsAFailedEditSoTryAgainCannotWriteItToTheNewAccount() async throws {
        let remote = FakeProfileRemote(stored: Self.profile(languages: ["sv"], archiveEnabled: true))
        await remote.failNextSaves(with: [URLError(.notConnectedToInternet)])
        let writer = DictationProfileWriter(remote: remote) { _ in }
        await writer.saveLanguages(["en"], account: try Self.account("synthetic-a")).value
        #expect(writer.languagesSave == .failed(["en"]))

        writer.accountChanged()
        #expect(writer.languagesSave == nil)
        #expect(writer.retryLanguages(account: try Self.account("synthetic-b")) == nil)
        #expect(await remote.savedAccounts.isEmpty)
    }

    @Test func aCompletionFromTheOldAccountDoesNotRestoreItsEdit() async throws {
        let remote = FakeProfileRemote(stored: Self.profile(languages: ["sv"], archiveEnabled: true))
        await remote.holdSaves()
        await remote.failNextSaves(with: [URLError(.notConnectedToInternet)])
        let writer = DictationProfileWriter(remote: remote) { _ in }
        let oldAccount = try Self.account("synthetic-a")
        let failing = writer.saveLanguages(["en"], account: oldAccount)
        let queued = writer.submit(.archiveEnabled(false), account: oldAccount, creatingFrom: nil)
        await remote.waitUntilASaveIsHeld()

        writer.accountChanged()
        await remote.releaseSaves()
        await failing.value
        await #expect(throws: DictationLibraryError.accountChanged) { try await queued.value }
        #expect(writer.languagesSave == nil)
        #expect(await remote.stored?.archiveEnabled == true)
    }
}
