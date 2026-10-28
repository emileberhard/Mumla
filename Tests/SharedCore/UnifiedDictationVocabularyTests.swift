import CloudKit
@testable import DictationLibrary
import Foundation
import Testing

private actor UploadedVocabularyCloud: LibraryCloud {
    private var preferences: DictationProfile
    private let uploadedTerms: [String]
    private var holdsNextProfileRead = false
    private var heldProfileRead: CheckedContinuation<Void, Never>?
    private var profileReadHeldWaiter: CheckedContinuation<Void, Never>?

    init(preferences: DictationProfile, uploadedTerms: [String]) {
        self.preferences = preferences
        self.uploadedTerms = uploadedTerms
    }

    func accountIdentifier() -> String? { "synthetic-account" }

    func holdNextProfileRead() {
        holdsNextProfileRead = true
    }

    func waitUntilProfileReadHeld() async {
        guard heldProfileRead == nil else { return }
        await withCheckedContinuation { profileReadHeldWaiter = $0 }
    }

    func releaseProfileRead() {
        heldProfileRead?.resume()
        heldProfileRead = nil
    }

    func profile() async -> DictationProfile? {
        if holdsNextProfileRead {
            holdsNextProfileRead = false
            await withCheckedContinuation { continuation in
                heldProfileRead = continuation
                profileReadHeldWaiter?.resume()
                profileReadHeldWaiter = nil
            }
        }
        var profile = preferences
        profile.dictionary = uploadedTerms
        return profile
    }

    func saveProfile(_ profile: DictationProfile) {
        preferences = profile
        preferences.dictionary = []
    }

    func create(_ record: CKRecord) {}

    func changes(since token: Data?, desiredKeys: [String]) -> LibraryCloudPage {
        LibraryCloudPage(records: [], deletedCount: 0, token: Data(), moreComing: false)
    }

    func originalChunk(_ id: CKRecord.ID) throws -> Data { throw DictationLibraryError.profileUnavailable }
}

@MainActor
@Suite("Unified dictation vocabulary")
struct UnifiedDictationVocabularyTests {
    private static let uploadedAt = Date(timeIntervalSince1970: 1_000)
    private static let pendingAt = Date(timeIntervalSince1970: 2_000)

    private struct Fixture {
        let root: URL
        let dataStore: MumlaDataStore
        let cloud: UploadedVocabularyCloud
        let library: UnifiedDictationLibrary
    }

    private static func refreshedLibrary() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UnifiedVocabulary-\(UUID().uuidString)", isDirectory: true)
        let dataStore = MumlaDataStore(directoryURL: root.appendingPathComponent("data"), cloudSyncEnabled: false)
        dataStore.addVocabularyTerm("Synthetic Uploaded", now: uploadedAt)
        var preferences = DictationProfile(languages: ["sv"], dictionary: [])
        preferences.archiveEnabled = true
        let cloud = UploadedVocabularyCloud(preferences: preferences, uploadedTerms: ["Synthetic Uploaded"])
        let store = try DictationLibraryStore(directory: root.appendingPathComponent("library"), source: "synthetic-vocabulary", capacityBytes: 16 * 1_024 * 1_024, cloud: cloud)
        let library = UnifiedDictationLibrary(store: store, rootDirectory: root, vocabulary: { dataStore.vocabularyTerms },
            onAccountChange: { _ in }, onExportRequested: { throw DictationLibraryError.profileUnavailable }, onArchiveRoleChanged: {})
        await library.refresh()
        return Fixture(root: root, dataStore: dataStore, cloud: cloud, library: library)
    }

    private static func remove(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.root)
        UserDefaults.standard.removeObject(forKey: "dictationArchiveConsent")
    }

    @Test func aPreferenceSaveKeepsAPendingVocabularyEditInTheNextCapture() async throws {
        let fixture = try await Self.refreshedLibrary()
        defer { Self.remove(fixture) }
        let library = fixture.library
        let account = try #require(library.accountSession)
        let profile = try #require(library.profile)

        fixture.dataStore.addVocabularyTerm("Synthetic Pending", now: Self.pendingAt)
        try await library.updateProfile(.archiveEnabled(false), account: account, creatingFrom: profile)
        let capture = try #require(try await library.prepareCapture(context: .prose))

        #expect(library.profile?.dictionary == ["Synthetic Uploaded"])
        #expect(!capture.plan.archiveEnabled)
        #expect(capture.plan.dictionary == ["Synthetic Uploaded", "Synthetic Pending"])
    }

    @Test func aRefreshLandingDuringPlanCreationKeepsAPendingVocabularyEdit() async throws {
        let fixture = try await Self.refreshedLibrary()
        defer { Self.remove(fixture) }
        let library = fixture.library
        fixture.dataStore.addVocabularyTerm("Synthetic Pending", now: Self.pendingAt)

        await fixture.cloud.holdNextProfileRead()
        let refresh = Task { await library.refresh() }
        await fixture.cloud.waitUntilProfileReadHeld()
        let duringRefresh = try #require(try await library.prepareCapture(context: .prose))
        await fixture.cloud.releaseProfileRead()
        await refresh.value
        let afterRefresh = try #require(try await library.prepareCapture(context: .prose))

        #expect(library.profile?.dictionary == ["Synthetic Uploaded"])
        #expect(duringRefresh.plan.dictionary == ["Synthetic Uploaded", "Synthetic Pending"])
        #expect(afterRefresh.plan.dictionary == ["Synthetic Uploaded", "Synthetic Pending"])
    }
}
