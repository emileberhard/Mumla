import Foundation
import SwiftData
import Testing

@Suite("Account persistence boundaries")
struct AccountPartitionTests {
    @Test func accountsAndUnconfirmedDataHaveSeparateDirectories() {
        let root = URL(fileURLWithPath: "/tmp/dictation-account-test")
        let a = AccountPartition.directory(root: root, ownerID: "synthetic-account-a")
        let b = AccountPartition.directory(root: root, ownerID: "synthetic-account-b")
        let unconfirmed = AccountPartition.directory(root: root, ownerID: nil)
        #expect(a != b)
        #expect(a != unconfirmed)
        #expect(b != unconfirmed)
        #expect(a == AccountPartition.directory(root: root, ownerID: "synthetic-account-a"))
        #expect(!a.path.contains("synthetic-account-a"))
    }

    @Test func invalidatingAnAccountLeaseFencesAllReferences() {
        let lease = AccountPartitionLease(ownerID: "synthetic-account")
        let pendingOperationLease = lease
        #expect(pendingOperationLease.isActive)
        lease.invalidate()
        #expect(!pendingOperationLease.isActive)
        lease.invalidate()
        #expect(!lease.isActive)
    }

    @Test @MainActor func staleModelsCannotMutateAnotherPartition() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = MumlaDataStore(directoryURL: root.appendingPathComponent("a"), cloudSyncEnabled: false)
        let b = MumlaDataStore(directoryURL: root.appendingPathComponent("b"), cloudSyncEnabled: false)
        let term = try #require(a.addVocabularyTerm("Synthetic term"))
        _ = b.addVocabularyTerm("Synthetic term")
        let historyID = try #require(a.record(text: "Synthetic history"))
        let history = try #require(a.container.mainContext.fetch(FetchDescriptor<HistoryEntry>()).first { $0.id == historyID })
        let pendingBefore = try b.container.mainContext.fetchCount(FetchDescriptor<VocabularySyncChange>())
        b.updateVocabularyTerm(term, to: "Wrong account")
        b.removeVocabularyTerm(term)
        b.delete(history)
        #expect(a.vocabularyTerms == ["Synthetic term"])
        #expect(b.vocabularyTerms == ["Synthetic term"])
        #expect(try b.container.mainContext.fetchCount(FetchDescriptor<VocabularySyncChange>()) == pendingBefore)
        #expect(try b.container.mainContext.fetchCount(FetchDescriptor<HistorySyncChange>()) == 0)
        #expect(try a.container.mainContext.fetchCount(FetchDescriptor<HistoryEntry>()) == 1)
    }

}
