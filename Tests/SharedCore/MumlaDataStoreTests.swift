import Foundation
import SwiftData
import Testing

@Suite("Mumla data store")
@MainActor
struct MumlaDataStoreTests {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MumlaDataStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore(in directory: URL) -> MumlaDataStore {
        MumlaDataStore(directoryURL: directory, cloudSyncEnabled: false)
    }

    private func entries(in store: MumlaDataStore) throws -> [HistoryEntry] {
        try store.container.mainContext.fetch(FetchDescriptor<HistoryEntry>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        ))
    }

    private func pendingChanges(in store: MumlaDataStore) throws -> [HistorySyncChange] {
        try store.container.mainContext.fetch(FetchDescriptor<HistorySyncChange>())
    }

    private func vocabularyEntries(
        in store: MumlaDataStore,
        includingDeleted: Bool = false
    ) throws -> [VocabularyEntry] {
        let entries = try store.container.mainContext.fetch(FetchDescriptor<VocabularyEntry>(
            sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]
        ))
        return includingDeleted ? entries : entries.filter { !$0.isTombstone }
    }

    private func vocabularyChanges(in store: MumlaDataStore) throws -> [VocabularySyncChange] {
        try store.container.mainContext.fetch(FetchDescriptor<VocabularySyncChange>())
    }

    @Test func recordsNewestFirst() throws {
        let store = makeStore(in: try makeTemporaryDirectory())
        store.record(text: "first")
        store.record(text: "second")

        #expect(try entries(in: store).map(\.text) == ["second", "first"])
    }

    @Test func keepsUnlimitedHistory() throws {
        let store = makeStore(in: try makeTemporaryDirectory())
        for index in 1...105 {
            store.record(text: "entry \(index)")
        }

        #expect(try entries(in: store).count == 105)
    }

    @Test func returnsLimitedRecentHistoryTexts() throws {
        let store = makeStore(in: try makeTemporaryDirectory())
        for index in 1...7 {
            store.container.mainContext.insert(HistoryEntry(
                text: "entry \(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                providerDisplayName: "Provider",
                deviceName: "Device"
            ))
        }
        try store.container.mainContext.save()

        #expect(store.recentHistoryTexts(limit: 5) == [
            "entry 7", "entry 6", "entry 5", "entry 4", "entry 3",
        ])
        #expect(store.recentHistoryTexts(limit: 0).isEmpty)
    }

    @Test func skipsEmptyAndWhitespaceOnlyText() throws {
        let store = makeStore(in: try makeTemporaryDirectory())
        store.record(text: "")
        store.record(text: "  \n\t ")

        #expect(try entries(in: store).isEmpty)
    }

    @Test func persistsAcrossInstances() throws {
        let directory = try makeTemporaryDirectory()
        let store = makeStore(in: directory)
        store.record(text: "hello från Lund")

        let reloaded = makeStore(in: directory)
        let persisted = try entries(in: reloaded)
        #expect(persisted.count == 1)
        #expect(persisted.first?.text == "hello från Lund")
        #expect(persisted.first?.deviceName.isEmpty == false)
    }

    @Test func additiveVocabularySchemaMigratesExistingHistoryStore() throws {
        let directory = try makeTemporaryDirectory()
        let storeURL = directory.appendingPathComponent("TranscriptionHistory.store")
        let historyID = UUID()

        do {
            let legacyContainer = try ModelContainer(
                for: HistoryEntry.self, HistorySyncChange.self,
                configurations: ModelConfiguration(url: storeURL, cloudKitDatabase: .none)
            )
            legacyContainer.mainContext.autosaveEnabled = false
            legacyContainer.mainContext.insert(HistoryEntry(
                id: historyID,
                text: "before vocabulary schema",
                providerDisplayName: "Provider",
                deviceName: "Device"
            ))
            try legacyContainer.mainContext.save()
        }

        let migrated = makeStore(in: directory)
        #expect(try entries(in: migrated).map(\.id) == [historyID])
        migrated.addVocabularyTerm("after migration")
        #expect(migrated.vocabularyTerms == ["after migration"])
    }

    @Test func vocabularyMigrationReplaysZoneExactlyOnce() throws {
        let directory = try makeTemporaryDirectory()
        let tokenURL = directory.appendingPathComponent("history-cloud-poll-token.data")
        let markerURL = directory.appendingPathComponent("vocabulary-cloud-zone-replayed-v3")
        try Data("old token".utf8).write(to: tokenURL)

        #expect(try AppCloudSyncMigration.prepareVocabularyZoneReplayIfNeeded(
            pollingTokenURL: tokenURL,
            markerURL: markerURL
        ))
        #expect(!FileManager.default.fileExists(atPath: tokenURL.path))
        #expect(FileManager.default.fileExists(atPath: markerURL.path))

        try Data("new token".utf8).write(to: tokenURL)
        #expect(try !AppCloudSyncMigration.prepareVocabularyZoneReplayIfNeeded(
            pollingTokenURL: tokenURL,
            markerURL: markerURL
        ))
        #expect(FileManager.default.fileExists(atPath: tokenURL.path))
    }

    @Test func deleteRemovesOnlyThatEntry() throws {
        let directory = try makeTemporaryDirectory()
        let store = makeStore(in: directory)
        store.record(text: "keep me")
        store.record(text: "delete me")

        let target = try #require(try entries(in: store).first { $0.text == "delete me" })
        store.delete(target)

        #expect(try entries(in: store).map(\.text) == ["keep me"])
        let reloaded = makeStore(in: directory)
        #expect(try entries(in: reloaded).map(\.text) == ["keep me"])
    }

    @Test func recordsDurablePendingSave() throws {
        let store = makeStore(in: try makeTemporaryDirectory())
        store.record(text: "sync me")

        let entry = try #require(try entries(in: store).first)
        let changes = try pendingChanges(in: store)
        let change = try #require(changes.first)
        #expect(changes.count == 1)
        #expect(change.entryID == entry.id)
        #expect(change.kind == .save)
        #expect(entry.providerDisplayName == "Microsoft MAI-Transcribe-2 (Clean)")
    }

    @Test func deleteReplacesPendingSaveWithDelete() throws {
        let store = makeStore(in: try makeTemporaryDirectory())
        store.record(text: "delete me")
        let entry = try #require(try entries(in: store).first)
        let entryID = entry.id

        store.delete(entry)

        let changes = try pendingChanges(in: store)
        #expect(changes.count == 1)
        #expect(changes.first?.entryID == entryID)
        #expect(changes.first?.kind == .delete)
    }

    @Test func clearEmptiesHistoryAndPersists() throws {
        let directory = try makeTemporaryDirectory()
        let store = makeStore(in: directory)
        store.record(text: "something")
        store.record(text: "something else")
        store.clear()

        #expect(try entries(in: store).isEmpty)
        let reloaded = makeStore(in: directory)
        #expect(try entries(in: reloaded).isEmpty)
        let changes = try pendingChanges(in: reloaded)
        #expect(changes.count == 2)
        #expect(changes.allSatisfy { $0.kind == .delete })
    }

    @Test func cloudRecordRoundTripsEncryptedHistoryFields() throws {
        let value = HistoryCloudRecord(
            id: UUID(),
            text: "hello från Lund",
            createdAt: Date(timeIntervalSince1970: 1_788_000_000),
            providerDisplayName: "Provider",
            deviceName: "Device"
        )

        let record = HistoryCloudSchema.makeRecord(from: value)
        let decoded = try #require(HistoryCloudSchema.value(from: record))
        #expect(decoded.id == value.id)
        #expect(decoded.text == value.text)
        #expect(decoded.createdAt == value.createdAt)
        #expect(decoded.providerDisplayName == value.providerDisplayName)
        #expect(decoded.deviceName == value.deviceName)
    }

    // MARK: - Vocabulary

    @Test func vocabularyNormalizationCollapsesWhitespaceAndUsesStableCaseInsensitiveIDs() throws {
        #expect(VocabularyTerm.displayText(from: "  Mumla\n  Pro  ") == "Mumla Pro")
        #expect(VocabularyTerm.normalizedText(from: "  Mumla\n  Pro  ") == "mumla pro")
        #expect(VocabularyTerm.identifier(for: "MUMLA") == VocabularyTerm.identifier(for: "mumla"))
        #expect(VocabularyTerm.identifier(for: "Cafe\u{301}") == VocabularyTerm.identifier(for: "Café"))
        #expect(VocabularyTerm.identifier(for: "  \n ") == nil)
    }

    @Test func vocabularyDeduplicatesAndPreservesCreationOrder() throws {
        let store = makeStore(in: try makeTemporaryDirectory())
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)

        store.addVocabularyTerm("Mumla", now: firstDate)
        store.addVocabularyTerm("Lund", now: secondDate)
        store.addVocabularyTerm("mumla", now: secondDate)

        let entries = try vocabularyEntries(in: store)
        #expect(entries.map(\.text) == ["Mumla", "Lund"])
        #expect(store.vocabularyTerms == ["Mumla", "Lund"])
        #expect(try vocabularyChanges(in: store).count == 2)
    }

    @Test func vocabularyEditUsesTombstoneWhenIdentityChanges() throws {
        let store = makeStore(in: try makeTemporaryDirectory())
        let entry = try #require(store.addVocabularyTerm("old term", now: Date(timeIntervalSince1970: 100)))

        store.updateVocabularyTerm(entry, to: "new   term", now: Date(timeIntervalSince1970: 200))

        #expect(store.vocabularyTerms == ["new term"])
        let allEntries = try vocabularyEntries(in: store, includingDeleted: true)
        #expect(allEntries.count == 2)
        #expect(allEntries.first { $0.text == "old term" }?.isTombstone == true)
        #expect(allEntries.first { $0.text == "new term" }?.isTombstone == false)
        #expect(Set(try vocabularyChanges(in: store).map(\.entryID)) == Set(allEntries.map(\.id)))
    }

    @Test func vocabularyDeletePersistsTombstoneAndOutbox() throws {
        let directory = try makeTemporaryDirectory()
        let store = makeStore(in: directory)
        let entry = try #require(store.addVocabularyTerm("delete me"))
        let id = entry.id

        store.removeVocabularyTerm(entry)

        #expect(store.vocabularyTerms.isEmpty)
        let reloaded = makeStore(in: directory)
        let tombstone = try #require(try vocabularyEntries(in: reloaded, includingDeleted: true).first)
        #expect(tombstone.id == id)
        #expect(tombstone.isTombstone)
        #expect(try vocabularyChanges(in: reloaded).map(\.entryID) == [id])
    }

    @Test func legacyVocabularyUnionDoesNotResurrectTombstones() throws {
        let store = makeStore(in: try makeTemporaryDirectory())
        store.importLegacyVocabulary(["Mac only\nShared", "iPhone only\nshared"])

        #expect(store.vocabularyTerms == ["Mac only", "Shared", "iPhone only"])
        let shared = try #require(try vocabularyEntries(in: store).first { $0.text == "Shared" })
        store.removeVocabularyTerm(shared)
        store.importLegacyVocabulary(["Shared"])

        #expect(store.vocabularyTerms == ["Mac only", "iPhone only"])
    }

    @Test func replacingVocabularyRetainsUnchangedCreationOrder() throws {
        let store = makeStore(in: try makeTemporaryDirectory())
        store.addVocabularyTerm("first", now: Date(timeIntervalSince1970: 100))
        store.addVocabularyTerm("second", now: Date(timeIntervalSince1970: 200))

        store.replaceVocabulary(with: ["second", "third", "SECOND"], now: Date(timeIntervalSince1970: 300))

        #expect(store.vocabularyTerms == ["second", "third"])
        let first = try #require(try vocabularyEntries(in: store, includingDeleted: true).first { $0.text == "first" })
        #expect(first.isTombstone)
    }

    @Test func vocabularyCloudRecordRoundTripsEncryptedFields() throws {
        let value = VocabularyCloudRecord(
            id: try #require(VocabularyTerm.identifier(for: "Mumla")),
            text: "Mumla",
            normalizedText: "mumla",
            createdAt: Date(timeIntervalSince1970: 100),
            modifiedAt: Date(timeIntervalSince1970: 200),
            isDeleted: false,
            systemFields: nil
        )

        let record = VocabularyCloudSchema.makeRecord(from: value)
        let decoded = try #require(VocabularyCloudSchema.value(from: record))
        #expect(decoded.id == value.id)
        #expect(decoded.text == value.text)
        #expect(decoded.normalizedText == value.normalizedText)
        #expect(decoded.createdAt == value.createdAt)
        #expect(decoded.modifiedAt == value.modifiedAt)
        #expect(decoded.isDeleted == value.isDeleted)
        #expect(decoded.systemFields?.isEmpty == false)
    }

    @Test func vocabularyConflictResolutionIsLastWriterWinsWithRemoteTieBreak() {
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)

        #expect(VocabularyConflictResolution.resolve(localModifiedAt: newer, remoteModifiedAt: older) == .keepLocal)
        #expect(VocabularyConflictResolution.resolve(localModifiedAt: older, remoteModifiedAt: newer) == .acceptRemote)
        #expect(VocabularyConflictResolution.resolve(localModifiedAt: newer, remoteModifiedAt: newer) == .acceptRemote)
    }

    // MARK: - Legacy JSON import

    private let legacyID = UUID()

    private func writeLegacyJSON(in directory: URL) throws {
        let json = """
        [{"id":"\(legacyID.uuidString)","text":"legacy transcript","createdAt":"2026-07-01T10:00:00Z","providerDisplayName":"ElevenLabs Scribe v2"}]
        """
        try json.write(
            to: directory.appendingPathComponent("transcription-history.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    @Test func importsLegacyJSONOnceAndKeepsFile() throws {
        let directory = try makeTemporaryDirectory()
        try writeLegacyJSON(in: directory)

        let store = makeStore(in: directory)
        let imported = try entries(in: store)
        #expect(imported.map(\.id) == [legacyID])
        #expect(imported.first?.text == "legacy transcript")

        // The JSON stays on disk as a rollback backup for downgrades.
        let legacyURL = directory.appendingPathComponent("transcription-history.json")
        #expect(FileManager.default.fileExists(atPath: legacyURL.path))

        // A second launch must not duplicate the imported entries.
        let relaunched = makeStore(in: directory)
        #expect(try entries(in: relaunched).count == 1)
    }

    @Test func importDoesNotResurrectClearedHistory() throws {
        let directory = try makeTemporaryDirectory()
        try writeLegacyJSON(in: directory)

        let store = makeStore(in: directory)
        store.clear()

        let relaunched = makeStore(in: directory)
        #expect(try entries(in: relaunched).isEmpty)
    }
}
