import AVFAudio
import CloudKit
@testable import DictationLibrary
import Foundation
import Testing

@MainActor
@Suite struct DictationPublicationTests {
    @Test func sealingAndLateResultsShareOneHoldThroughPublication() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let prepared = try #require(try await fixture.library.prepareCapture(context: .chat))
        let writer = try OriginalAudioWriter(dictation: prepared)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let audio = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        audio.frameLength = 4_800
        let samples = try #require(audio.floatChannelData?[0])
        for index in 0..<4_800 { samples[index] = Float(sin(Double(index) * 0.1)) * 0.2 }
        writer.write(audio)
        _ = try await writer.finishArchived()
        await fixture.cloud.waitUntilHeld()
        try await fixture.library.recordProviderOutput("Synthetic result", captureID: prepared.id, model: "synthetic")
        #expect(fixture.background.holds == 1)
        #expect(fixture.background.releases == 0)
        await fixture.cloud.release()
        let status = try await fixture.library.publish()
        #expect(status.pendingCaptureCount == 0)
        #expect(status.failures.isEmpty)
        #expect(fixture.background.releases == 1)
        #expect(await fixture.cloud.resultCount == 1)
    }

    @Test func expirationCancelsPublicationAndReleasesBackgroundTime() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let prepared = try #require(try await fixture.library.prepareCapture(context: .chat))
        let writer = try #require(prepared.writer)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let audio = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        audio.frameLength = 4_800
        let samples = try #require(audio.floatChannelData?[0])
        samples.initialize(repeating: 0.1, count: 4_800)
        try writer.configure(format: format)
        writer.append(audio)
        try await fixture.library.finish(writer)
        await fixture.cloud.waitUntilHeld()
        fixture.background.expire()
        #expect(fixture.background.releases == 1)
        await fixture.cloud.release()
        await #expect(throws: CancellationError.self) { try await fixture.library.publish() }
        let status = try await fixture.library.store.status()
        #expect(status.pendingCaptureCount == 1)
        #expect(status.failures.isEmpty)
        #expect(fixture.library.lastError == nil)
        #expect(fixture.library.publicationStatus?.pendingCaptureCount == 1)
        #expect(fixture.background.holds == 1)
        #expect(fixture.background.releases == 1)
    }

    @Test func expirationBeforeSealingFinishesDoesNotAdmitPublication() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let prepared = try #require(try await fixture.library.prepareCapture(context: .chat))
        let writer = try #require(prepared.writer)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let audio = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        audio.frameLength = 4_800
        let samples = try #require(audio.floatChannelData?[0])
        samples.initialize(repeating: 0.1, count: 4_800)
        try writer.configure(format: format)
        writer.append(audio)
        fixture.background.expireOnHold = true
        try await fixture.library.finish(writer)
        #expect(try await fixture.library.store.status().pendingCaptureCount == 1)
        #expect(await fixture.cloud.createCount == 0)
        #expect(fixture.background.holds == 1)
        #expect(fixture.background.releases == 1)
    }

    @Test func aCaptureSealedDuringAPassIsIncludedBeforePublishReturns() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try #require(try await fixture.library.prepareCapture(context: .chat))
        let second = try #require(try await fixture.library.prepareCapture(context: .chat))
        try appendAudio(to: #require(first.writer))
        try appendAudio(to: #require(second.writer))
        try await fixture.library.finish(#require(first.writer))
        await fixture.cloud.waitUntilHeld()
        try await fixture.library.finish(#require(second.writer))
        await fixture.cloud.release()
        let status = try await fixture.library.publish()
        #expect(status.pendingCaptureCount == 0)
        let names = await fixture.cloud.captureNames
        #expect(Set(names) == Set(["capture-\(first.id.uuidString)", "capture-\(second.id.uuidString)"]))
    }

    @Test func anOfflinePassPublishesItsCurrentPendingStatus() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let prepared = try #require(try await fixture.library.prepareCapture(context: .chat))
        let writer = try #require(prepared.writer)
        try appendAudio(to: writer)
        await fixture.cloud.failCreates(CKError(.networkUnavailable))
        try await fixture.library.finish(writer)
        await #expect(throws: DictationLibraryError.cloudFailure(domain: CKErrorDomain, code: CKError.networkUnavailable.rawValue)) { try await fixture.library.publish() }
        #expect(fixture.library.publicationStatus?.pendingCaptureCount == 1)
        #expect(fixture.library.publicationStatus?.failures.isEmpty == true)
    }

    @Test func anEmptyCaptureStillAcceptsTheResultAfterFinish() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let prepared = try #require(try await fixture.library.prepareCapture(context: .chat))
        await #expect(throws: DictationLibraryError.noAudio) { try await fixture.library.finish(#require(prepared.writer)) }
        await fixture.background.waitUntilReleased()
        try await fixture.library.recordProviderOutput("", captureID: prepared.id, model: "synthetic")
        _ = try await fixture.library.publish()
        #expect(try await fixture.library.store.capture(id: prepared.id) != nil)
        #expect(try await fixture.library.store.entries().first?.results.count == 1)
    }

    private func appendAudio(to writer: DictationCaptureWriter) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let audio = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        audio.frameLength = 4_800
        let samples = try #require(audio.floatChannelData?[0])
        for index in 0..<4_800 { samples[index] = Float(sin(Double(index) * 0.1)) * 0.2 }
        try writer.configure(format: format)
        writer.append(audio)
    }

    @Test func diagnosticsRetainTypedCodesWithoutRecordContent() {
        let sentinel = "synthetic-private-record-content"
        let cloud = DiagnosticError(DictationLibraryError.cloudFailure(domain: CKErrorDomain, code: CKError.networkUnavailable.rawValue))
        #expect(cloud.kind == "cloud_failure")
        #expect(cloud.domain == CKErrorDomain)
        #expect(cloud.code == CKError.networkUnavailable.rawValue)
        let storage = DiagnosticError(DictationLibraryError.storageFailure(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoSuchFile.rawValue))
        #expect(storage.kind == "storage_failure")
        #expect(storage.domain == NSCocoaErrorDomain)
        #expect(storage.code == CocoaError.fileReadNoSuchFile.rawValue)
        let conflict = DiagnosticError(DictationLibraryError.contentConflict(sentinel))
        #expect(conflict.kind == "content_conflict")
        #expect(!conflict.metadata.description.contains(sentinel))
    }

    private func fixture() async throws -> (root: URL, library: UnifiedDictationLibrary, cloud: PublicationCloud, background: TestDictationBackgroundExecution) {
        let root = URL.temporaryDirectory.appending(path: "SyntheticPublication-\(UUID())")
        var profile = DictationProfile(languages: ["en"], dictionary: [])
        profile.archiveEnabled = true
        let cloud = PublicationCloud(preferences: profile)
        let store = try DictationLibraryStore(directory: root.appending(path: "producer"), source: "synthetic", capacityBytes: 16 * 1_024 * 1_024, cloud: cloud)
        let background = TestDictationBackgroundExecution()
        let library = UnifiedDictationLibrary(store: store, rootDirectory: root, background: background, vocabulary: { [] }, onAccountChange: { _ in }, onExportRequested: { throw DictationLibraryError.profileUnavailable }, onArchiveRoleChanged: {})
        await library.refresh()
        background.reset()
        return (root, library, cloud, background)
    }
}

@MainActor
final class TestDictationBackgroundExecution: DictationBackgroundExecution {
    var holds = 0
    var releases = 0
    var expireOnHold = false
    private var expiration: (@MainActor () -> Void)?
    private var releasedWaiter: CheckedContinuation<Void, Never>?
    func waitUntilReleased() async {
        if releases > 0 { return }
        await withCheckedContinuation { releasedWaiter = $0 }
    }
    func hold(onExpiration: @escaping @MainActor () -> Void) {
        holds += 1
        expiration = onExpiration
        if expireOnHold { onExpiration() }
    }
    func release() { releases += 1; expiration = nil; releasedWaiter?.resume(); releasedWaiter = nil }
    func expire() { expiration?() }
    func reset() { holds = 0; releases = 0 }
}

private actor PublicationCloud: LibraryCloud {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var hasHeld = false
    private(set) var resultCount = 0
    private(set) var createCount = 0
    private(set) var captureNames: [String] = []
    private var createError: CKError?
    func failCreates(_ error: CKError) { createError = error; hasHeld = true }
    func accountIdentifier() -> String? { "synthetic-account" }
    private let preferences: DictationProfile
    init(preferences: DictationProfile) { self.preferences = preferences }
    func profile() -> DictationProfile? { preferences }
    func saveProfile(_ profile: DictationProfile) {}
    func create(_ record: CKRecord) async throws {
        createCount += 1
        if let createError { throw createError }
        if !hasHeld {
            hasHeld = true
            await withCheckedContinuation { continuation = $0; waiter?.resume(); waiter = nil }
        }
        try Task.checkCancellation()
        if record.recordType == DictationLibrarySchema.captureRecordType { captureNames.append(record.recordID.recordName) }
        if record.recordType == DictationLibrarySchema.resultRecordType { resultCount += 1 }
    }
    func waitUntilHeld() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
    func missing(_ ids: [CKRecord.ID]) -> Set<CKRecord.ID> { [] }
    func changes(since token: Data?, desiredKeys: [String]) -> LibraryCloudPage { LibraryCloudPage(records: [], deletedCount: 0, token: Data(), moreComing: false) }
    func originalChunk(_ id: CKRecord.ID) throws -> Data { throw DictationLibraryError.invalidRecord(id.recordName) }
}
