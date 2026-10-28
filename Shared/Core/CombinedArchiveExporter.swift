import CryptoKit
import Darwin
import Foundation

nonisolated enum CombinedArchiveExporter {
    static let capacityBytes: Int64 = 64 * 1_024 * 1_024 * 1_024

    struct Manifest: Codable, Sendable {
        struct Account: Codable, Sendable { let hash: String }
        struct Freshness: Codable, Sendable { let lastCatchUpAt: Date; let catchUpReachedEnd: Bool }
        struct Completeness: Codable, Sendable { let sections: [String]; let problems: [String] }
        struct File: Codable, Sendable { let path: String; let byteCount: Int64; let sha256: String }
        let formatVersion: Int
        let account: Account
        let createdAt: Date
        let complete: Bool
        let freshness: Freshness
        let completeness: Completeness
        let files: [File]
    }

    private struct SectionManifest: Decodable {
        let complete: Bool
        let account: Manifest.Account
        let files: [Manifest.File]
    }

    @concurrent static func allocatedBytes(at directory: URL) async throws -> Int64 {
        try allocatedBytesSynchronously(at: directory)
    }

    private static func allocatedBytesSynchronously(at directory: URL) throws -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        var seen = Set<String>()
        var count: Int64 = 0
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let inode = attributes[.systemFileNumber] as? NSNumber,
                  let device = attributes[.systemNumber] as? NSNumber,
                  let bytes = attributes[.size] as? NSNumber else { throw AudioArchiveError.invalidRecording }
            if seen.insert("\(device)-\(inode)").inserted { count += bytes.int64Value }
        }
        return count
    }

    @concurrent static func seal(sections: [String: URL], parent: URL, lease: AccountPartitionLease) async throws -> URL {
        try sealSynchronously(sections: sections, parent: parent, lease: lease)
    }

    private static func sealSynchronously(sections: [String: URL], parent: URL, lease: AccountPartitionLease) throws -> URL {
        guard lease.isActive else { throw CancellationError() }
        let accountHash = AccountPartition.directory(root: parent, ownerID: lease.ownerID).lastPathComponent
        let accountDirectory = parent.appendingPathComponent(accountHash, isDirectory: true)
        try FileManager.default.createDirectory(at: accountDirectory, withIntermediateDirectories: true)
        let staging = accountDirectory.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: staging) } }
        var files: [Manifest.File] = []
        for (name, section) in sections.sorted(by: { $0.key < $1.key }) {
            guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { throw AudioArchiveError.invalidRecording }
            let sectionValues = try section.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let sectionManifest = section.appendingPathComponent("manifest.json")
            guard sectionValues.isDirectory == true, sectionValues.isSymbolicLink != true,
                  try sectionManifest.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw AudioArchiveError.invalidRecording }
            let section = section.resolvingSymlinksInPath().standardizedFileURL
            let manifest = try JSONDecoder().decode(SectionManifest.self, from: Data(contentsOf: sectionManifest))
            guard manifest.complete, manifest.account.hash == accountHash else { throw AudioArchiveError.audioUnavailable }
            var remaining: [String: Manifest.File] = [:]
            for file in manifest.files {
                guard remaining.updateValue(file, forKey: file.path) == nil else { throw AudioArchiveError.invalidRecording }
            }
            guard let enumerator = FileManager.default.enumerator(at: section, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]) else { throw AudioArchiveError.invalidRecording }
            for case let source as URL in enumerator {
                guard lease.isActive else { throw CancellationError() }
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw AudioArchiveError.invalidRecording }
                if values.isDirectory == true { continue }
                let source = source.resolvingSymlinksInPath().standardizedFileURL
                guard values.isRegularFile == true, source.path.hasPrefix(section.path + "/") else { throw AudioArchiveError.invalidRecording }
                let relative = name + "/" + source.path.dropFirst(section.path.count + 1)
                let target = staging.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.linkItem(at: source, to: target)
                let handle = try FileHandle(forReadingFrom: target)
                var hash = SHA256()
                var bytes: Int64 = 0
                do {
                    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                        hash.update(data: data)
                        bytes += Int64(data.count)
                    }
                    try handle.close()
                } catch { try? handle.close(); throw error }
                let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                let sectionPath = String(source.path.dropFirst(section.path.count + 1))
                if sectionPath != "manifest.json" {
                    guard let expected = remaining.removeValue(forKey: sectionPath),
                          expected.byteCount == bytes, expected.sha256 == digest else {
                        throw NSError(domain: "CombinedArchiveChecksum", code: 1, userInfo: [NSLocalizedDescriptionKey: "Export section checksum verification failed: \(relative)"])
                    }
                }
                files.append(Manifest.File(path: relative, byteCount: bytes, sha256: digest))
            }
            guard remaining.isEmpty else { throw AudioArchiveError.audioUnavailable }
        }
        guard lease.isActive else { throw CancellationError() }
        let now = Date()
        let manifest = Manifest(formatVersion: 1, account: .init(hash: accountHash), createdAt: now, complete: true,
            freshness: .init(lastCatchUpAt: now, catchUpReachedEnd: true),
            completeness: .init(sections: sections.keys.sorted(), problems: []), files: files.sorted { $0.path < $1.path })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let manifestURL = staging.appendingPathComponent("manifest.json")
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        let handle = try FileHandle(forWritingTo: manifestURL)
        try handle.synchronize()
        try handle.close()
        if let directories = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: [.isDirectoryKey]) {
            let values = try directories.compactMap { value -> URL? in
                guard let url = value as? URL else { return nil }
                return try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true ? url : nil
            }.sorted { $0.path.count > $1.path.count }
            for directory in values { try synchronize(directory) }
        }
        try synchronize(staging)
        guard lease.isActive else { throw CancellationError() }
        let name = snapshotName(createdAt: now, id: UUID())
        let destination = accountDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.moveItem(at: staging, to: destination)
        published = true
        try synchronize(accountDirectory)
        try retainLatestTwoSynchronously(in: accountDirectory, preserving: destination)
        return destination
    }

    static func snapshotName(createdAt: Date, id: UUID) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let fraction = Int64(createdAt.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) * 1_000_000_000)
        return formatter.string(from: createdAt) + String(format: "-%09lld-", fraction) + id.uuidString
    }

    @concurrent static func retainLatestTwo(in accountDirectory: URL, preserving latest: URL) async throws {
        try retainLatestTwoSynchronously(in: accountDirectory, preserving: latest)
    }

    private static func retainLatestTwoSynchronously(in accountDirectory: URL, preserving latest: URL) throws {
        let directories = try FileManager.default.contentsOfDirectory(at: accountDirectory, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey])
            .filter { url in
                let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                return !url.lastPathComponent.hasPrefix(".") && isDirectory && url.lastPathComponent != latest.lastPathComponent
            }
            .sorted {
                let a = try $0.resourceValues(forKeys: [.creationDateKey]).creationDate
                let b = try $1.resourceValues(forKeys: [.creationDateKey]).creationDate
                return a == b ? $0.lastPathComponent > $1.lastPathComponent : (a ?? .distantPast) > (b ?? .distantPast)
            }
        for old in directories.dropFirst(1) { try FileManager.default.removeItem(at: old) }
    }

    private static func synchronize(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }
}
