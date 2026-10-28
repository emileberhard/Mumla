import Foundation
import SwiftData
import Testing

@Suite("Legacy library duplicate inspection")
@MainActor
struct LegacyLibraryReconciliationTests {
    @Test func exactDuplicatesAreSkippedAndRepeatedDictationsAreKept() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = MumlaDataStore(directoryURL: root.appendingPathComponent("source"), cloudSyncEnabled: false)
        let destination = MumlaDataStore(directoryURL: root.appendingPathComponent("destination"), cloudSyncEnabled: false)
        let existingID = UUID()
        let date = Date(timeIntervalSince1970: 100)
        destination.container.mainContext.insert(HistoryEntry(id: existingID, text: "Same idea", createdAt: date, providerDisplayName: "Provider", deviceName: "Device"))
        source.container.mainContext.insert(HistoryEntry(id: existingID, text: "Same idea", createdAt: date, providerDisplayName: "Provider", deviceName: "Device"))
        source.container.mainContext.insert(HistoryEntry(text: "Same idea", createdAt: date, providerDisplayName: "Provider", deviceName: "Device"))
        let repeatedID = UUID()
        source.container.mainContext.insert(HistoryEntry(id: repeatedID, text: "Same idea", createdAt: date.addingTimeInterval(10), providerDisplayName: "Provider", deviceName: "Device"))
        try source.container.mainContext.save()
        try destination.container.mainContext.save()
        let plan = try LegacyLibraryReconciliation(source: source.container.mainContext, destination: destination.container.mainContext, ownership: LegacyDataOwnership(), ownerID: "synthetic")
        #expect(plan.report.historyCount == 3)
        #expect(plan.report.duplicateHistoryCount == 2)
        #expect(plan.report.uniqueHistoryIDs == [repeatedID])
        #expect(plan.report.conflictingIDs.isEmpty)
        #expect(plan.history.map(\.id) == [repeatedID])
        #expect(plan.keys.count == 3)
    }

    @Test func conflictingIdentityIsNeverAcceptedAsDuplicate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = MumlaDataStore(directoryURL: root.appendingPathComponent("source"), cloudSyncEnabled: false)
        let destination = MumlaDataStore(directoryURL: root.appendingPathComponent("destination"), cloudSyncEnabled: false)
        let id = UUID()
        for (store, text) in [(source, "First"), (destination, "Different")] {
            store.container.mainContext.insert(HistoryEntry(id: id, text: text, createdAt: Date(timeIntervalSince1970: 100), providerDisplayName: "Provider", deviceName: "Device"))
            try store.container.mainContext.save()
        }
        let plan = try LegacyLibraryReconciliation(source: source.container.mainContext, destination: destination.container.mainContext, ownership: LegacyDataOwnership(), ownerID: "synthetic")
        #expect(plan.report.conflictingIDs == ["history-" + id.uuidString])
        #expect(plan.history.isEmpty)
        #expect(plan.report.duplicateHistoryCount == 0)
    }
}
