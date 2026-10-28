#if os(macOS)
import CloudKit
import CryptoKit
import DictationLibrary
import Foundation

nonisolated enum DictationLibraryCommand {
    private enum Command {
        case list(limit: Int, offset: Int)
        case search(String, limit: Int, offset: Int)
        case audio(UUID, URL)
    }

    private enum Failure: Error { case arguments, accountChanged }

    private struct Catalog: Encodable {
        let formatVersion = 1
        let accountHash: String
        let refreshedAt: Date
        let complete: Bool
        let problemCount: Int
        let totalCount: Int
        let offset: Int
        let hasMore: Bool
        let entries: [DictationArchiveEntry]
    }

    private struct Original: Encodable {
        let captureID: UUID
        let path: String
        let byteCount: Int
        let sha256: String
    }

    static func runAndExit() -> Never {
        Task.detached {
            do {
                try await run()
                exit(0)
            } catch {
                let value = error as NSError
                let message = error is Failure ? "Use --dictation-library list|search|audio with explicit valid arguments; the iCloud account must remain unchanged." : error.localizedDescription
                let data = try? JSONSerialization.data(withJSONObject: ["error": ["domain": value.domain, "code": value.code, "message": message]], options: [.sortedKeys])
                if let data { FileHandle.standardOutput.write(data + Data([10])) }
                exit(1)
            }
        }
        dispatchMain()
    }

    private static func run() async throws {
        let command = try parse()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MumlaArchiveReader-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = CKContainer(identifier: MumlaDataStore.cloudContainerIdentifier)
        guard try await container.accountStatus() == .available else { throw DictationLibraryError.accountUnavailable }
        let owner = try await container.userRecordID()
        let archive = try DictationArchive(directory: root, capacityBytes: 128 * 1_024 * 1_024, containerIdentifier: MumlaDataStore.cloudContainerIdentifier)
        let report = try await archive.refresh()
        let output: Data
        var pendingOriginal: (staging: URL, destination: URL)?
        defer { if let pendingOriginal { try? FileManager.default.removeItem(at: pendingOriginal.staging) } }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        switch command {
        case .list(let limit, let offset), .search(_, let limit, let offset):
            var entries = try await archive.entries()
            if case .search(let query, _, _) = command {
                entries = entries.filter { entry in entry.results.contains { $0.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
            }
            let page = Array(entries.dropFirst(offset).prefix(limit))
            let hash = SHA256.hash(data: Data(owner.recordName.utf8)).map { String(format: "%02x", $0) }.joined()
            output = try encoder.encode(Catalog(accountHash: hash, refreshedAt: .now, complete: report.problems.isEmpty, problemCount: report.problems.count, totalCount: entries.count, offset: offset, hasMore: offset + page.count < entries.count, entries: page))
        case .audio(let id, let destination):
            let original = try await archive.original(for: id)
            let bytes = try Data(contentsOf: original)
            guard try await container.userRecordID() == owner else { throw Failure.accountChanged }
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent)-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: original, to: staging)
            pendingOriginal = (staging, destination)
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            output = try encoder.encode(Original(captureID: id, path: destination.path, byteCount: bytes.count, sha256: hash))
        }
        guard try await container.userRecordID() == owner else { throw Failure.accountChanged }
        if let pendingOriginal { try FileManager.default.moveItem(at: pendingOriginal.staging, to: pendingOriginal.destination) }
        FileHandle.standardOutput.write(output + Data([10]))
    }

    private static func parse() throws -> Command {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--dictation-library"), args.count > index + 1 else { throw Failure.arguments }
        let operation = args[index + 1]
        let tail = Array(args.dropFirst(index + 2))
        guard tail.count.isMultiple(of: 2) else { throw Failure.arguments }
        var options: [String: String] = [:]
        for index in stride(from: 0, to: tail.count, by: 2) {
            guard options.updateValue(tail[index + 1], forKey: tail[index]) == nil else { throw Failure.arguments }
        }
        switch operation {
        case "list", "search":
            let allowed: Set<String> = operation == "search" ? ["--text", "--limit", "--offset"] : ["--limit", "--offset"]
            guard Set(options.keys).isSubset(of: allowed), let limit = Int(options["--limit"] ?? "50"), (1...200).contains(limit),
                  let offset = Int(options["--offset"] ?? "0"), offset >= 0 else { throw Failure.arguments }
            if operation == "list" { return .list(limit: limit, offset: offset) }
            guard let text = options["--text"], !text.isEmpty else { throw Failure.arguments }
            return .search(text, limit: limit, offset: offset)
        case "audio":
            guard Set(options.keys) == ["--id", "--output"], let value = options["--id"], let id = UUID(uuidString: value),
                  let output = options["--output"], output.hasPrefix("/") else { throw Failure.arguments }
            return .audio(id, URL(fileURLWithPath: output))
        default: throw Failure.arguments
        }
    }
}
#endif
