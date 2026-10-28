import Foundation
import Testing

@Suite("Legacy library ownership reconciliation")
struct LegacyDataOwnershipTests {
    @Test func ownershipIsRecordedBeforeCopyAndCannotMoveToAnotherAccount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var ownership = try LegacyDataOwnership.load(directory: directory)
        #expect(ownership.needsReconciliation("audio-synthetic", currentOwner: "a"))
        try ownership.assign(["audio-synthetic"], to: "a", directory: directory)
        let afterInterruptedCopy = try LegacyDataOwnership.load(directory: directory)
        #expect(afterInterruptedCopy.needsReconciliation("audio-synthetic", currentOwner: "a"))
        #expect(!afterInterruptedCopy.needsReconciliation("audio-synthetic", currentOwner: "b"))
        #expect(throws: AudioArchiveError.self) {
            try ownership.assign(["audio-synthetic"], to: "b", directory: directory)
        }
        try ownership.markCopied(["audio-synthetic"], directory: directory)
        let complete = try LegacyDataOwnership.load(directory: directory)
        #expect(!complete.needsReconciliation("audio-synthetic", currentOwner: "a"))
        #expect(complete.needsReconciliation("new-offline-capture", currentOwner: "a"))
    }
}
