import Foundation
import SwiftData

enum RecordingRecoverySource: String, Codable, Sendable {
    case batch
    case realtime

    var displayName: String {
        switch self {
        case .batch: "Batch"
        case .realtime: "Realtime"
        }
    }
}

enum RecordingRecoveryStatus: String, Codable, Sendable {
    case recorded
    case transcribed
    case failed

    var displayName: String {
        switch self {
        case .recorded: "Recorded"
        case .transcribed: "Transcribed"
        case .failed: "Failed"
        }
    }
}

struct RecoverableRecording: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let source: RecordingRecoverySource
    let providerRawValue: String
    let providerDisplayName: String
    let durationMilliseconds: Int?
    let audioFileName: String
    let audioMimeType: String
    let audioByteCount: Int
    let diagnosticsSessionID: String?
    var transcript: String?
    var lastError: String?
    var status: RecordingRecoveryStatus
}

/// macOS recovery UI adapter. The shared audio archive owns files and sync.
final class RecordingRecoveryStore {
    private let dataStore: MumlaDataStore

    init(dataStore: MumlaDataStore) { self.dataStore = dataStore }

    func recording(with id: UUID, diagnosticsSessionID: String? = nil) throws -> RecoverableRecording? {
        var query = FetchDescriptor<AudioRecording>(predicate: #Predicate { $0.id == id })
        query.fetchLimit = 1
        guard let entry = try dataStore.container.mainContext.fetch(query).first else { return nil }
        let info = try JSONDecoder().decode(AudioRecordingInfo.self, from: entry.metadata)
        guard let source = RecordingRecoverySource(rawValue: info.source.hasPrefix("unified/") ? String(info.source.dropFirst(8)) : info.source) else {
            throw AudioArchiveError.invalidRecording
        }
        return RecoverableRecording(
            id: info.id, createdAt: info.createdAt, source: source,
            providerRawValue: info.providerRawValue, providerDisplayName: info.providerDisplayName,
            durationMilliseconds: info.durationMilliseconds,
            audioFileName: info.fileName,
            audioMimeType: info.fileType == .caf ? "audio/x-caf" : "audio/wav", audioByteCount: info.byteCount,
            diagnosticsSessionID: diagnosticsSessionID, transcript: nil, lastError: nil, status: .recorded
        )
    }

    func saveRecording(
        _ originalAudio: Result<URL, any Error>,
        source: RecordingRecoverySource,
        durationMilliseconds: Int?,
        diagnosticsSessionID: String? = nil
    ) async throws -> RecoverableRecording {
        let id = try await dataStore.saveOriginalAudio(
            originalAudio, source: source.rawValue,
            durationMilliseconds: durationMilliseconds
        )
        guard let recording = try recording(with: id, diagnosticsSessionID: diagnosticsSessionID) else {
            throw AudioArchiveError.invalidRecording
        }
        return recording
    }

    /// Import old recovery files once. Keep the source files as a rollback copy;
    /// stable recording IDs make an interrupted migration safe to repeat.
    func importLegacyRecordings() async throws {
        let target = dataStore.legacyDataStore
        let folder = target.audioArchive.directory.deletingLastPathComponent()
            .appendingPathComponent("RecoverableRecordings")
        let metadata = folder.appendingPathComponent("recordings.json")
        let marker = folder.appendingPathComponent("audio-archive-imported")
        guard !FileManager.default.fileExists(atPath: marker.path),
              FileManager.default.fileExists(atPath: metadata.path) else { return }
        let legacy = try await Self.readLegacy(metadata)
        for recording in legacy {
            let id = try await target.saveAudio(
                .file(folder.appendingPathComponent(recording.audioFileName)),
                id: recording.id, createdAt: recording.createdAt,
                providerRawValue: recording.providerRawValue,
                providerDisplayName: recording.providerDisplayName,
                source: recording.source.rawValue,
                durationMilliseconds: recording.durationMilliseconds,
                fileType: .wav
            )
            if let text = recording.transcript, !text.isEmpty {
                let linked = try target.container.mainContext.fetch(FetchDescriptor<HistoryEntry>(
                    predicate: #Predicate { $0.audioRecordingID == id }
                ))
                if linked.isEmpty {
                    guard target.record(
                        text: text, audioRecordingID: id, createdAt: recording.createdAt
                    ) != nil else { throw AudioArchiveError.transcriptNotSaved }
                }
            }
        }
        try Data().write(to: marker, options: .atomic)
    }

    @concurrent
    private static func readLegacy(_ url: URL) async throws -> [RecoverableRecording] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([RecoverableRecording].self, from: Data(contentsOf: url))
    }
}
