import CryptoKit
import Darwin
import Foundation
import SwiftData

nonisolated struct LegacyArchiveExportManifest: Codable, Sendable {
    let formatVersion: Int
    let account: Account
    let createdAt: Date
    let complete: Bool
    let freshness: Freshness
    let completeness: Completeness

    nonisolated struct Account: Codable, Sendable {
        let hash: String
    }

    nonisolated struct Freshness: Codable, Sendable {
        let lastCatchUpAt: Date?
        let catchUpReachedEnd: Bool
        let scope: String
    }

    nonisolated struct Completeness: Codable, Sendable {
        let recordingCount: Int
        let historyCount: Int
        let vocabularyCount: Int
        let audioPresentCount: Int
        let missingAudioCaptureIDs: [UUID]
        let problems: [String]
    }
    let files: [File]

    nonisolated struct File: Codable, Equatable, Sendable {
        let path: String
        let byteCount: Int64
        let sha256: String
    }
}

nonisolated enum LegacyArchiveExportError: LocalizedError {
    case accountChanged
    case invalidRecording(UUID)
    case corruptOriginal(UUID)
    case cleanupFailed(original: any Error, cleanup: any Error)

    var errorDescription: String? {
        switch self {
        case .accountChanged: "The iCloud account changed before the export completed."
        case .invalidRecording: "A recording has unreadable metadata. The export is incomplete."
        case .corruptOriginal: "An original recording does not match its saved checksum. The export is incomplete."
        case .cleanupFailed: "The export failed and its incomplete staging files could not be removed."
        }
    }
}

@MainActor
enum LegacyArchiveExporter {
    nonisolated struct Snapshot: Sendable {
        let history: [History]
        let vocabulary: [Vocabulary]
        let recordings: [AudioRecordingInfo]
    }

    nonisolated struct History: Encodable, Sendable {
        let id: UUID
        let text: String
        let createdAt: Date
        let providerDisplayName: String
        let deviceName: String
        let audioRecordingID: UUID?
        let provenance = "unknown"
    }

    nonisolated struct Vocabulary: Encodable, Sendable {
        let id: String
        let text: String
        let normalizedText: String
        let createdAt: Date
        let modifiedAt: Date
        let isTombstone: Bool
    }

    static func export(dataStore: MumlaDataStore, to parent: URL, expectedAccount: String) async throws -> URL {
        guard dataStore.confirmedAccountID == expectedAccount else { throw LegacyArchiveExportError.accountChanged }
        let context = dataStore.container.mainContext
        let history = try context.fetch(FetchDescriptor<HistoryEntry>()).map {
            History(id: $0.id, text: $0.text, createdAt: $0.createdAt, providerDisplayName: $0.providerDisplayName, deviceName: $0.deviceName, audioRecordingID: $0.audioRecordingID)
        }
        let vocabulary = try context.fetch(FetchDescriptor<VocabularyEntry>()).map {
            Vocabulary(id: $0.id, text: $0.text, normalizedText: $0.normalizedText, createdAt: $0.createdAt, modifiedAt: $0.modifiedAt, isTombstone: $0.isTombstone)
        }
        let recordings = try context.fetch(FetchDescriptor<AudioRecording>()).map { recording in
            guard let info = recording.info else { throw LegacyArchiveExportError.invalidRecording(recording.id) }
            return info
        }
        let directory = try await export(
            snapshot: Snapshot(history: history, vocabulary: vocabulary, recordings: recordings),
            to: parent, expectedAccount: expectedAccount,
            currentAccount: { dataStore.confirmedAccountID },
            original: { try await dataStore.audioFile(for: $0) }
        )
        guard dataStore.confirmedAccountID == expectedAccount else { throw LegacyArchiveExportError.accountChanged }
        return directory
    }

    static func export(
        snapshot: Snapshot,
        to parent: URL,
        expectedAccount: String,
        currentAccount: @MainActor () -> String?,
        original: @MainActor (UUID) async throws -> URL
    ) async throws -> URL {
        func checkAccount() throws {
            try Task.checkCancellation()
            guard !expectedAccount.isEmpty, currentAccount() == expectedAccount else { throw LegacyArchiveExportError.accountChanged }
        }
        try checkAccount()
        let accountHash = SHA256.hash(data: Data(expectedAccount.utf8)).map { String(format: "%02x", $0) }.joined()
        let accountDirectory = parent.appendingPathComponent(accountHash, isDirectory: true)
        try FileManager.default.createDirectory(at: accountDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let identifier = UUID()
        let staging = accountDirectory.appendingPathComponent(".staging-\(identifier)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let excluded = Set(snapshot.recordings.filter { $0.source.hasPrefix("unified/") }.map(\.id))
            let history = snapshot.history.filter { $0.audioRecordingID.map { !excluded.contains($0) } ?? true }.sorted {
                $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
            }
            let recordings = snapshot.recordings.filter { !excluded.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
            let missingAudio = Set(history.compactMap(\.audioRecordingID)).subtracting(Set(recordings.map(\.id)))
                .sorted { $0.uuidString < $1.uuidString }
            var files: [LegacyArchiveExportManifest.File] = []
            try checkAccount()
            files.append(try await writeJSON(history, path: "history.json", directory: staging))
            try checkAccount()
            files.append(try await writeJSON(snapshot.vocabulary.sorted { $0.id < $1.id }, path: "vocabulary.json", directory: staging))
            try checkAccount()
            files.append(try await writeJSON(recordings, path: "recordings.json", directory: staging))
            try checkAccount()
            let audioDirectory = staging.appendingPathComponent("audio", isDirectory: true)
            try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for info in recordings {
                try checkAccount()
                let source = try await original(info.id)
                try checkAccount()
                files.append(try await copyOriginal(source, info: info, directory: staging))
                try checkAccount()
            }
            let manifest = LegacyArchiveExportManifest(
                formatVersion: 1, account: .init(hash: accountHash), createdAt: .now, complete: missingAudio.isEmpty,
                freshness: .init(lastCatchUpAt: nil, catchUpReachedEnd: false, scope: "localSnapshot"),
                completeness: .init(recordingCount: recordings.count, historyCount: history.count,
                                    vocabularyCount: snapshot.vocabulary.count, audioPresentCount: recordings.count,
                                    missingAudioCaptureIDs: missingAudio, problems: missingAudio.isEmpty ? [] : ["Some legacy transcripts reference missing recording metadata."]),
                files: files.sorted { $0.path < $1.path }
            )
            try checkAccount()
            _ = try await writeJSON(manifest, path: "manifest.json", directory: staging)
            try checkAccount()
            try syncDirectory(audioDirectory)
            try syncDirectory(staging)
            try checkAccount()
            let destination = accountDirectory.appendingPathComponent(CombinedArchiveExporter.snapshotName(createdAt: manifest.createdAt, id: identifier), isDirectory: true)
            try FileManager.default.moveItem(at: staging, to: destination)
            try syncDirectory(accountDirectory)
            return destination
        } catch {
            if FileManager.default.fileExists(atPath: staging.path) {
                do { try FileManager.default.removeItem(at: staging) }
                catch let cleanup { throw LegacyArchiveExportError.cleanupFailed(original: error, cleanup: cleanup) }
            }
            throw error
        }
    }

    @concurrent nonisolated private static func writeJSON<Value: Encodable & Sendable>(_ value: Value, path: String, directory: URL) async throws -> LegacyArchiveExportManifest.File {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = path == "manifest.json" ? .secondsSince1970 : .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(value)
        let url = directory.appendingPathComponent(path)
        try bytes.write(to: url, options: .atomic)
        try synchronizeFile(url)
        return LegacyArchiveExportManifest.File(path: path, byteCount: Int64(bytes.count), sha256: digest(bytes))
    }

    @concurrent nonisolated private static func copyOriginal(_ source: URL, info: AudioRecordingInfo, directory: URL) async throws -> LegacyArchiveExportManifest.File {
        let path = "audio/" + info.fileName
        let destination = directory.appendingPathComponent(path)
        try FileManager.default.copyItem(at: source, to: destination)
        try synchronizeFile(destination)
        let handle = try FileHandle(forReadingFrom: destination)
        defer { try? handle.close() }
        var hash = SHA256()
        var byteCount: Int64 = 0
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes)
            byteCount += Int64(bytes.count)
        }
        let checksum = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard byteCount == Int64(info.byteCount), checksum == info.sha256 else { throw LegacyArchiveExportError.corruptOriginal(info.id) }
        return LegacyArchiveExportManifest.File(path: path, byteCount: byteCount, sha256: checksum)
    }

    nonisolated private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func synchronizeFile(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
