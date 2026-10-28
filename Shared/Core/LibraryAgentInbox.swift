import Foundation
import DictationLibrary
#if os(iOS)
import UIKit
#endif

nonisolated struct LibraryAgentRequest: Codable, Sendable {
    let formatVersion: Int
    let createdAt: Date
    let operation: String
    let accountHash: String?
    let text: String?
    let limit: Int?
    let offset: Int?
    let id: UUID?

    func validate(now: Date) throws {
        guard formatVersion == 1, abs(createdAt.timeIntervalSince(now)) < 600,
              ["status", "list", "search", "audio", "export", "legacy-inspect", "legacy-reconcile"].contains(operation),
              (1...200).contains(limit ?? 50), (offset ?? 0) >= 0,
              (text?.utf8.count ?? 0) <= 4_096 else { throw LibraryAgentError.invalidRequest }
        if operation == "search", text?.isEmpty != false { throw LibraryAgentError.invalidRequest }
        if operation == "audio", id == nil { throw LibraryAgentError.invalidRequest }
        if operation == "legacy-reconcile", accountHash?.count != 64 { throw LibraryAgentError.invalidRequest }
    }
}

nonisolated enum LibraryAgentError: String, LocalizedError {
    case invalidRequest, busy, accountChanged, unavailable, responseTooLarge
    var errorDescription: String? {
        switch self {
        case .invalidRequest: "The request is invalid or expired. Create a new request."
        case .busy: "Another library command is running. Inspect its result before retrying."
        case .accountChanged: "The verified iCloud account changed. Inspect the library again."
        case .unavailable: "The library is unavailable. Open Mumla and check Settings."
        case .responseTooLarge: "The result exceeds the command budget. Request a smaller page."
        }
    }
}

@MainActor
final class LibraryAgentInbox {
    private let directory: URL
    private let execute: @MainActor (LibraryAgentRequest) async throws -> Data
    private(set) var task: Task<Void, Never>?
    private var runningID: UUID?
    #if os(iOS)
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    #endif

    init(directory: URL, execute: @escaping @MainActor (LibraryAgentRequest) async throws -> Data) {
        self.directory = directory
        self.execute = execute
    }

    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme == "mumla", url.host == "agent" else { return false }
        guard url.query == nil, url.fragment == nil,
              let id = UUID(uuidString: String(url.path.dropFirst())),
              url.path == "/" + id.uuidString else { return true }
        let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        let requestURL = folder.appendingPathComponent("request.json")
        let responseURL = folder.appendingPathComponent("response.json")
        guard isRegularDirectory(folder), isRegularFile(requestURL), !FileManager.default.fileExists(atPath: responseURL.path),
              runningID != id else { return true }
        if task != nil {
            try? respond(to: responseURL, id: id, result: .failure(LibraryAgentError.busy))
            return true
        }
        do {
            try prune(excluding: folder)
            let size = try requestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 16_384 else { throw LibraryAgentError.invalidRequest }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let request = try decoder.decode(LibraryAgentRequest.self, from: Data(contentsOf: requestURL))
            try request.validate(now: .now)
            runningID = id
            #if os(iOS)
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Library agent command") { [weak self] in
                self?.expire()
            }
            #endif
            task = Task { [self] in
                defer {
                    task = nil
                    runningID = nil
                    #if os(iOS)
                    endBackgroundTask()
                    #endif
                }
                let result: Result<Data, any Error>
                do {
                    let data = try await execute(request)
                    try Task.checkCancellation()
                    guard data.count <= 8 * 1_024 * 1_024 else { throw LibraryAgentError.responseTooLarge }
                    result = .success(data)
                } catch { result = .failure(error) }
                try? respond(to: responseURL, id: id, result: result)
            }
        } catch {
            try? respond(to: responseURL, id: id, result: .failure(error))
        }
        return true
    }

    #if os(iOS)
    private func expire() {
        task?.cancel()
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    #endif

    private func respond(to url: URL, id: UUID, result: Result<Data, any Error>) throws {
        var object: [String: Any] = ["formatVersion": 1, "requestID": id.uuidString]
        switch result {
        case .success(let data):
            object["ok"] = true
            object["data"] = try JSONSerialization.jsonObject(with: data)
        case .failure(let error):
            object["ok"] = false
            let value = error as NSError
            object["error"] = ["code": (error as? LibraryAgentError)?.rawValue ?? "libraryFailure",
                               "domain": value.domain, "number": value.code,
                               "message": (error as? LibraryAgentError)?.localizedDescription ?? "The library operation failed. Check Mumla Settings; no source data was removed."]
        }
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func prune(excluding active: URL) throws {
        let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        for folder in folders where folder != active && folder.lastPathComponent != runningID?.uuidString {
            guard UUID(uuidString: folder.lastPathComponent) != nil, isRegularDirectory(folder) else { continue }
            let date = try folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantFuture
            if date < Date.now.addingTimeInterval(-3_600) { try FileManager.default.removeItem(at: folder) }
        }
        let remaining = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard remaining.count <= 32 else { throw LibraryAgentError.busy }
    }

    private func isRegularDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}

nonisolated struct LibraryAgentHistory: Encodable, Sendable {
    let id: UUID
    let text: String
    let createdAt: Date
    let audioRecordingID: UUID?
    let source: String
    let providerDisplayName: String?
    let model: String?
    let kind: String?

    init(_ entry: HistoryEntry) {
        id = entry.id
        text = entry.text
        createdAt = entry.createdAt
        audioRecordingID = entry.audioRecordingID
        source = "wisprclone-legacy"
        providerDisplayName = entry.providerDisplayName
        model = nil
        kind = nil
    }

    init(capture: DictationCapture, result: DictationResultVersion) {
        id = result.id
        text = result.text
        createdAt = result.createdAt
        audioRecordingID = capture.id
        source = capture.source
        providerDisplayName = nil
        model = result.model
        kind = result.kind.rawValue
    }
}
