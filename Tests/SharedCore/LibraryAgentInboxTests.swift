import Foundation
import Testing

@Suite("Private library agent commands")
@MainActor
struct LibraryAgentInboxTests {
    @Test func urlAloneCannotExecuteAndCompletedRequestCannotReplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let url = try #require(URL(string: "mumla://agent/" + id.uuidString))
        var executions = 0
        let inbox = LibraryAgentInbox(directory: directory) { _ in
            executions += 1
            return Data("{\"historyCount\":3}".utf8)
        }
        #expect(inbox.handle(url))
        #expect(executions == 0)
        let folder = directory.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(LibraryAgentRequest(formatVersion: 1, createdAt: .now, operation: "status", accountHash: nil, text: nil, limit: nil, offset: nil, id: nil)).write(to: folder.appendingPathComponent("request.json"))
        #expect(inbox.handle(url))
        await inbox.task?.value
        let response = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("response.json"))) as? [String: Any])
        #expect(response["ok"] as? Bool == true)
        #expect(executions == 1)
        #expect(inbox.handle(url))
        #expect(executions == 1)
    }

    @Test func expiredAndUnboundedRequestsAreRejected() {
        let old = LibraryAgentRequest(formatVersion: 1, createdAt: .distantPast, operation: "legacy-reconcile", accountHash: String(repeating: "a", count: 64), text: nil, limit: nil, offset: nil, id: nil)
        #expect(throws: LibraryAgentError.self) { try old.validate(now: .now) }
        let large = LibraryAgentRequest(formatVersion: 1, createdAt: .now, operation: "list", accountHash: nil, text: nil, limit: 201, offset: nil, id: nil)
        #expect(throws: LibraryAgentError.self) { try large.validate(now: .now) }
    }
}
