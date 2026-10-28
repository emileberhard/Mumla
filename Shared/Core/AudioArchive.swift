import CloudKit
import CryptoKit
import Foundation
import SwiftData

/// Immutable capture metadata. Transcripts refer to this ID; retranscription
/// creates another history entry without changing the original recording.
nonisolated struct AudioRecordingInfo: Codable, Sendable, Equatable {
    let id: UUID
    let createdAt: Date
    let providerRawValue: String
    let providerDisplayName: String
    let deviceName: String
    let source: String
    let durationMilliseconds: Int?
    let byteCount: Int
    let sha256: String
    var fileType: AudioArchiveFileType

    // Separate small assets keep long dictations below CloudKit's per-asset
    // and request limits without imposing a recording or retention limit.
    static let chunkBytes = 8 * 1_024 * 1_024
    var chunkCount: Int { (byteCount - 1) / Self.chunkBytes + 1 }
    var fileName: String { "\(id.uuidString).\(fileType.rawValue)" }
}

nonisolated extension AudioRecordingInfo {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        providerRawValue = try container.decode(String.self, forKey: .providerRawValue)
        providerDisplayName = try container.decode(String.self, forKey: .providerDisplayName)
        deviceName = try container.decode(String.self, forKey: .deviceName)
        source = try container.decode(String.self, forKey: .source)
        durationMilliseconds = try container.decodeIfPresent(Int.self, forKey: .durationMilliseconds)
        byteCount = try container.decode(Int.self, forKey: .byteCount)
        sha256 = try container.decode(String.self, forKey: .sha256)
        fileType = try container.decodeIfPresent(AudioArchiveFileType.self, forKey: .fileType) ?? .wav
    }
}

@Model
nonisolated final class AudioRecording {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var metadata: Data = Data()
    var uploaded: Bool = false
    var syncError: String?
    #Index<AudioRecording>([\.id], [\.createdAt])

    init(info: AudioRecordingInfo, uploaded: Bool = false) throws {
        id = info.id
        createdAt = info.createdAt
        metadata = try JSONEncoder().encode(info)
        self.uploaded = uploaded
    }

    var info: AudioRecordingInfo? { try? JSONDecoder().decode(AudioRecordingInfo.self, from: metadata) }
}

@Model
nonisolated final class AudioSyncChange {
    var recordName: String = ""
    var recordingID: UUID = UUID()
    var chunkIndex: Int = 0
    #Index<AudioSyncChange>([\.recordName], [\.recordingID])

    init(recordingID: UUID, chunkIndex: Int) {
        self.recordingID = recordingID
        self.chunkIndex = chunkIndex
        recordName = AudioCloudSchema.recordName(id: recordingID, index: chunkIndex)
    }
}

nonisolated enum AudioArchiveError: LocalizedError {
    case invalidRecording, conflictingRecording, corruptAudio, transcriptNotSaved, audioUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidRecording: "The recording metadata or audio is invalid."
        case .conflictingRecording: "A different recording already has this recording ID."
        case .corruptAudio: "The saved audio does not match its original checksum."
        case .transcriptNotSaved: "The transcript could not be saved. Its original audio is retained."
        case .audioUnavailable: "The recording is stored in iCloud, which is unavailable."
        }
    }
}

/// Audio and a sidecar survive independently of SQLite. The sidecar is written
/// last, so a failed database transaction can be recovered on the next launch.
nonisolated struct AudioArchive: Sendable {
    let directory: URL
    let offloadDirectory: URL

    init(directory: URL, offloadDirectory: URL) {
        self.directory = directory.appendingPathComponent("AudioArchive", isDirectory: true)
        self.offloadDirectory = offloadDirectory.appendingPathComponent("AudioArchive", isDirectory: true)
    }

    func localAudioURL(_ info: AudioRecordingInfo) -> URL? {
        [durableAudioURL(info), offloadedAudioURL(info), retainedAudioURL(info)].first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func hasDurableAudio(_ info: AudioRecordingInfo) -> Bool {
        FileManager.default.fileExists(atPath: durableAudioURL(info).path)
    }

    private func durableAudioURL(_ info: AudioRecordingInfo) -> URL { directory.appendingPathComponent(info.fileName) }
    private func offloadedAudioURL(_ info: AudioRecordingInfo) -> URL { offloadDirectory.appendingPathComponent(info.fileName) }
    private func retainedAudioURL(_ info: AudioRecordingInfo) -> URL {
        directory.deletingLastPathComponent().appendingPathComponent("RetainedAudio", isDirectory: true).appendingPathComponent(info.fileName)
    }

    func isRetained(_ info: AudioRecordingInfo) -> Bool {
        FileManager.default.fileExists(atPath: retainedAudioURL(info).path)
    }

    func retain(_ info: AudioRecordingInfo) throws {
        let destination = retainedAudioURL(info)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard Self.digest(try Data(contentsOf: destination, options: .mappedIfSafe)) == info.sha256 else { throw AudioArchiveError.corruptAudio }
            return
        }
        guard let source = localAudioURL(info) else { throw AudioArchiveError.audioUnavailable }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard data.count == info.byteCount, Self.digest(data) == info.sha256 else { throw AudioArchiveError.corruptAudio }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }

    private func metadataURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }
    private func chunkURL(_ id: UUID, _ index: Int) -> URL {
        directory.appendingPathComponent("\(id.uuidString)-\(index).part")
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func save(_ data: Data, info: AudioRecordingInfo) throws {
        guard !data.isEmpty, data.count == info.byteCount, Self.digest(data) == info.sha256 else {
            throw AudioArchiveError.corruptAudio
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: metadataURL(info.id).path) {
            let existing = try JSONDecoder().decode(AudioRecordingInfo.self, from: Data(contentsOf: metadataURL(info.id)))
            guard existing == info else { throw AudioArchiveError.conflictingRecording }
        }
        try data.write(to: durableAudioURL(info), options: .atomic)
        try JSONEncoder().encode(info).write(to: metadataURL(info.id), options: .atomic)
    }

    func offload(_ info: AudioRecordingInfo) throws {
        let source = durableAudioURL(info)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try FileManager.default.createDirectory(at: offloadDirectory, withIntermediateDirectories: true)
        let destination = offloadedAudioURL(info)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: source)
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    func relabelOpusStoredAsWAV(_ info: AudioRecordingInfo) throws -> AudioRecordingInfo? {
        guard info.fileType == .wav else { return nil }
        var opus = info
        opus.fileType = .caf
        var found = false
        for folder in [directory, offloadDirectory] {
            let mislabeled = folder.appendingPathComponent(info.fileName)
            let relabeled = folder.appendingPathComponent(opus.fileName)
            if FileManager.default.fileExists(atPath: relabeled.path) {
                found = true
            } else if try Self.isCAF(mislabeled) {
                try FileManager.default.moveItem(at: mislabeled, to: relabeled)
                found = true
            }
        }
        guard found else { return nil }
        try JSONEncoder().encode(opus).write(to: metadataURL(info.id), options: .atomic)
        return opus
    }

    private static func isCAF(_ url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: 4) == Data("caff".utf8)
    }

    func recordings() throws -> [AudioRecordingInfo] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(AudioRecordingInfo.self, from: Data(contentsOf: $0)) }
    }

    func uploadChunk(info: AudioRecordingInfo, index: Int) throws -> URL {
        guard (0..<info.chunkCount).contains(index) else { throw AudioArchiveError.invalidRecording }
        let handle = try FileHandle(forReadingFrom: durableAudioURL(info))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(index * AudioRecordingInfo.chunkBytes))
        let expected = min(AudioRecordingInfo.chunkBytes, info.byteCount - index * AudioRecordingInfo.chunkBytes)
        guard let data = try handle.read(upToCount: expected), data.count == expected else {
            throw AudioArchiveError.corruptAudio
        }
        let url = chunkURL(info.id, index)
        // CKSyncEngine may still be reading an earlier batch's file.
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        }
        return url
    }

    /// Copy CloudKit's disposable staging file before advancing the zone token.
    /// Publish the recording only after every part and the full hash verify.
    func receive(info: AudioRecordingInfo, index: Int, assetURL: URL) throws -> Bool {
        guard info.byteCount > 0, (0..<info.chunkCount).contains(index) else {
            throw AudioArchiveError.invalidRecording
        }
        if FileManager.default.fileExists(atPath: metadataURL(info.id).path) {
            let existing = try JSONDecoder().decode(AudioRecordingInfo.self, from: Data(contentsOf: metadataURL(info.id)))
            guard existing == info else { throw AudioArchiveError.conflictingRecording }
            if localAudioURL(info) != nil { return true }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Data(contentsOf: assetURL)
        let expected = min(AudioRecordingInfo.chunkBytes, info.byteCount - index * AudioRecordingInfo.chunkBytes)
        guard data.count == expected else { throw AudioArchiveError.corruptAudio }
        try data.write(to: chunkURL(info.id, index), options: .atomic)
        guard (0..<info.chunkCount).allSatisfy({ FileManager.default.fileExists(atPath: chunkURL(info.id, $0).path) }) else {
            return false
        }
        let assembling = directory.appendingPathComponent("\(info.id.uuidString).assembling")
        FileManager.default.createFile(atPath: assembling.path, contents: nil)
        let handle = try FileHandle(forWritingTo: assembling)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: assembling) }
        var hash = SHA256()
        var count = 0
        for part in 0..<info.chunkCount {
            let bytes = try Data(contentsOf: chunkURL(info.id, part))
            hash.update(data: bytes)
            count += bytes.count
            try handle.write(contentsOf: bytes)
        }
        try handle.synchronize()
        guard count == info.byteCount,
              hash.finalize().map({ String(format: "%02x", $0) }).joined() == info.sha256 else {
            throw AudioArchiveError.corruptAudio
        }
        // The audio persistence actor serializes receive and save. Replace only
        // the incomplete audio left by a crash before the sidecar commit.
        try FileManager.default.createDirectory(at: offloadDirectory, withIntermediateDirectories: true)
        let published = offloadedAudioURL(info)
        if FileManager.default.fileExists(atPath: published.path) {
            _ = try FileManager.default.replaceItemAt(published, withItemAt: assembling)
        } else {
            try FileManager.default.moveItem(at: assembling, to: published)
        }
        try JSONEncoder().encode(info).write(to: metadataURL(info.id), options: .atomic)
        removeChunks(info)
        return true
    }

    func removeChunks(_ info: AudioRecordingInfo) {
        for index in 0..<info.chunkCount { try? FileManager.default.removeItem(at: chunkURL(info.id, index)) }
    }
}

nonisolated enum AudioCloudSchema {
    static let recordType = "DictationAudioChunk"
    static func recordName(id: UUID, index: Int) -> String { "audio-\(id.uuidString)-\(index)" }
    static func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: HistoryCloudSchema.zoneID) }
    static func makeRecord(info: AudioRecordingInfo, index: Int, fileURL: URL) throws -> CKRecord {
        let record = CKRecord(recordType: recordType, recordID: recordID(recordName(id: info.id, index: index)))
        record.encryptedValues["metadata"] = try JSONEncoder().encode(info)
        record.encryptedValues["chunkIndex"] = index
        record["audio"] = CKAsset(fileURL: fileURL)
        return record
    }
    static func metadata(from record: CKRecord) throws -> (AudioRecordingInfo, Int) {
        guard record.recordType == recordType, record.recordID.zoneID == HistoryCloudSchema.zoneID,
              let data = record.encryptedValues["metadata"] as? Data,
              let index = record.encryptedValues["chunkIndex"] as? Int else {
            throw AudioArchiveError.invalidRecording
        }
        let info = try JSONDecoder().decode(AudioRecordingInfo.self, from: data)
        guard info.byteCount > 0, (0..<info.chunkCount).contains(index),
              record.recordID.recordName == recordName(id: info.id, index: index) else {
            throw AudioArchiveError.invalidRecording
        }
        return (info, index)
    }
}

/// Serializes durable audio commits away from the main actor. This context is
/// never passed to the UI or the CloudKit actor.
actor AudioRecordingPersistence {
    private let archive: AudioArchive
    private let container: ModelContainer
    private lazy var context: ModelContext = {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }()

    init(container: ModelContainer, archive: AudioArchive) {
        self.container = container
        self.archive = archive
    }

    enum Input: Sendable {
        case data(Data)
        case file(URL)
    }

    func save(
        _ input: Input,
        id: UUID,
        createdAt: Date,
        providerRawValue: String,
        providerDisplayName: String,
        deviceName: String,
        source: String,
        durationMilliseconds: Int?,
        fileType: AudioArchiveFileType
    ) throws -> UUID {
        let data: Data
        switch input {
        case .data(let value): data = value
        case .file(let url): data = try Data(contentsOf: url, options: .mappedIfSafe)
        }
        guard !data.isEmpty else { throw AudioArchiveError.invalidRecording }
        let info = AudioRecordingInfo(
            id: id, createdAt: createdAt, providerRawValue: providerRawValue,
            providerDisplayName: providerDisplayName, deviceName: deviceName,
            source: source, durationMilliseconds: durationMilliseconds,
            byteCount: data.count, sha256: AudioArchive.digest(data), fileType: fileType
        )
        try archive.save(data, info: info)
        try index(info)
        return id
    }

    func recoverUnindexedRecordings() throws {
        for info in try archive.recordings() { try index(info) }
    }

    func relabelOpusReceivedByOlderClients() throws {
        let marker = archive.directory.appendingPathComponent("opus-received-as-wav-relabeled")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        do {
            for recording in try context.fetch(FetchDescriptor<AudioRecording>()) {
                guard let info = recording.info, let opus = try archive.relabelOpusStoredAsWAV(info) else { continue }
                recording.metadata = try JSONEncoder().encode(opus)
            }
            try context.save()
        } catch { context.rollback(); throw error }
        try FileManager.default.createDirectory(at: archive.directory, withIntermediateDirectories: true)
        try Data().write(to: marker, options: .atomic)
    }

    func offloadUploadedRecordings() throws {
        let uploaded = try context.fetch(FetchDescriptor<AudioRecording>(predicate: #Predicate { $0.uploaded == true }))
        var firstFailure: (any Error)?
        for recording in uploaded {
            guard let info = recording.info else { continue }
            do { try archive.offload(info) } catch { firstFailure = firstFailure ?? error }
        }
        if let firstFailure { throw firstFailure }
    }

    func retainOriginal(_ info: AudioRecordingInfo) throws { try archive.retain(info) }

    func reseedRetainedOriginals() throws -> Int {
        var missing = 0
        do {
            for recording in try context.fetch(FetchDescriptor<AudioRecording>()) {
                guard let info = recording.info else { throw AudioArchiveError.invalidRecording }
                guard !info.source.hasPrefix("unified/") else { continue }
                guard let url = archive.localAudioURL(info) else {
                    recording.uploaded = false
                    recording.syncError = "iCloud was reset; this original is not retained on this device. Restore it from an archival copy."
                    missing += 1
                    continue
                }
                try archive.save(Data(contentsOf: url, options: .mappedIfSafe), info: info)
                let id = info.id
                let existing = Set(try context.fetch(FetchDescriptor<AudioSyncChange>(predicate: #Predicate { $0.recordingID == id })).map(\.chunkIndex))
                for index in 0..<info.chunkCount where !existing.contains(index) {
                    context.insert(AudioSyncChange(recordingID: id, chunkIndex: index))
                }
                recording.uploaded = false
                recording.syncError = nil
            }
            try context.save()
        } catch { context.rollback(); throw error }
        return missing
    }

    func pendingRecordNames() throws -> [String] {
        try context.fetch(FetchDescriptor<AudioSyncChange>()).map(\.recordName)
    }

    func recordToUpload(named name: String) throws -> CKRecord? {
        var query = FetchDescriptor<AudioSyncChange>(predicate: #Predicate { $0.recordName == name })
        query.fetchLimit = 1
        guard let change = try context.fetch(query).first else { return nil }
        guard let local = try recording(with: change.recordingID) else {
            throw AudioArchiveError.invalidRecording
        }
        let info = try JSONDecoder().decode(AudioRecordingInfo.self, from: local.metadata)
        return try AudioCloudSchema.makeRecord(
            info: info, index: change.chunkIndex,
            fileURL: archive.uploadChunk(info: info, index: change.chunkIndex)
        )
    }

    func receiveMetadata(_ record: CKRecord) throws {
        let (info, _) = try AudioCloudSchema.metadata(from: record)
        if let existing = try recording(with: info.id) {
            guard existing.info == info else { throw AudioArchiveError.conflictingRecording }
            return
        }
        do {
            context.insert(try AudioRecording(info: info, uploaded: true))
            try context.save()
        } catch { context.rollback(); throw error }
    }

    func receive(_ record: CKRecord) throws {
        let (info, index) = try AudioCloudSchema.metadata(from: record)
        guard let url = (record["audio"] as? CKAsset)?.fileURL else {
            throw AudioArchiveError.invalidRecording
        }
        if try archive.receive(info: info, index: index, assetURL: url),
           try recording(with: info.id) == nil {
            do {
                context.insert(try AudioRecording(info: info, uploaded: true))
                try context.save()
            } catch { context.rollback(); throw error }
        }
    }

    /// Used for both successful saves and immutable-record conflicts after a
    /// crash/retry. Conflicts have no downloaded CKAsset URL; metadata must match.
    func acknowledge(_ record: CKRecord) throws {
        let (info, _) = try AudioCloudSchema.metadata(from: record)
        guard let local = try recording(with: info.id), local.info == info else {
            throw AudioArchiveError.conflictingRecording
        }
        let id = info.id
        let changes = try context.fetch(FetchDescriptor<AudioSyncChange>(predicate: #Predicate { $0.recordingID == id }))
        do {
            for change in changes where change.recordName == record.recordID.recordName { context.delete(change) }
            if changes.allSatisfy({ $0.recordName == record.recordID.recordName }) {
                local.uploaded = true
                local.syncError = nil
            }
            try context.save()
        } catch { context.rollback(); throw error }
        if local.uploaded {
            archive.removeChunks(info)
            try? archive.offload(info)
        }
    }

    func noteUploadFailure(_ record: CKRecord, message: String) throws {
        let (info, _) = try AudioCloudSchema.metadata(from: record)
        if let local = try recording(with: info.id) {
            local.syncError = message
            do { try context.save() }
            catch { context.rollback(); throw error }
        }
    }

    private func recording(with id: UUID) throws -> AudioRecording? {
        var query = FetchDescriptor<AudioRecording>(predicate: #Predicate { $0.id == id })
        query.fetchLimit = 1
        return try context.fetch(query).first
    }

    private func index(_ info: AudioRecordingInfo) throws {
        let id = info.id
        var query = FetchDescriptor<AudioRecording>(predicate: #Predicate { $0.id == id })
        query.fetchLimit = 1
        guard try context.fetch(query).isEmpty else { return }
        let pendingUpload = archive.hasDurableAudio(info)
        do {
            context.insert(try AudioRecording(info: info, uploaded: !pendingUpload))
            for index in 0..<info.chunkCount where pendingUpload {
                context.insert(AudioSyncChange(recordingID: id, chunkIndex: index))
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}
