import Foundation

nonisolated struct LegacyDataOwnership: Codable {
    struct Assignment: Codable {
        let ownerID: String
        var copied: Bool
    }
    private(set) var assignments: [String: Assignment] = [:]

    static func load(directory: URL) throws -> Self {
        let url = directory.appendingPathComponent("legacy-data-ownership.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func needsReconciliation(_ key: String, currentOwner: String?) -> Bool {
        guard let assignment = assignments[key] else { return true }
        return assignment.ownerID == currentOwner && !assignment.copied
    }

    mutating func assign(_ keys: [String], to ownerID: String, directory: URL) throws {
        for key in keys {
            if let existing = assignments[key], existing.ownerID != ownerID { throw AudioArchiveError.conflictingRecording }
            assignments[key] = assignments[key] ?? Assignment(ownerID: ownerID, copied: false)
        }
        try save(directory: directory)
    }

    mutating func markCopied(_ keys: [String], directory: URL) throws {
        for key in keys {
            guard var assignment = assignments[key] else { throw AudioArchiveError.invalidRecording }
            assignment.copied = true
            assignments[key] = assignment
        }
        try save(directory: directory)
    }

    private func save(directory: URL) throws {
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent("legacy-data-ownership.json"), options: .atomic)
    }
}
