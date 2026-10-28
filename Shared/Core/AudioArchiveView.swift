import QuickLook
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct AudioArchiveView: View {
    let dataStore: MumlaDataStore
    var retry: ((UUID) -> Void)?
    @Query(sort: \AudioRecording.createdAt, order: .reverse) private var recordings: [AudioRecording]
    @Query(filter: #Predicate<HistoryEntry> { !$0.isHidden }, sort: \HistoryEntry.createdAt, order: .reverse) private var history: [HistoryEntry]

    private var latestTranscripts: [UUID: String] {
        var values: [UUID: String] = [:]
        for entry in history {
            if let id = entry.audioRecordingID, values[id] == nil { values[id] = entry.text }
        }
        return values
    }

    var body: some View {
        let transcripts = latestTranscripts
        List {
            Section {
                ForEach(recordings) { recording in
                    if let info = recording.info {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(info.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.headline)
                            Text(transcripts[info.id] ?? "Audio saved without a transcript")
                                .lineLimit(3)
                                .textSelection(.enabled)
                            Text("\(info.deviceName) · \(info.byteCount.formatted(.byteCount(style: .file)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let error = recording.syncError {
                                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                            }
                            HStack {
                                AudioAttachmentControls(recordingID: info.id, dataStore: dataStore)
                                if let retry {
                                    Button("Transcribe Again", systemImage: "arrow.clockwise") { retry(info.id) }
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    } else {
                        Label("Recording metadata could not be read", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Original Recordings")
            } footer: {
                Text("Deleting transcript history keeps its original audio.")
            }
        }
        .overlay {
            if recordings.isEmpty {
                ContentUnavailableView("No Recordings", systemImage: "waveform", description: Text("Your original audio will appear here as you dictate."))
            }
        }
        .task { await dataStore.refreshRemoteChangesWhileVisible() }
    }
}

struct AudioAttachmentControls: View {
    let recordingID: UUID
    let dataStore: MumlaDataStore
    @State private var previewURL: URL?
    @State private var isDownloading = false
    @State private var downloadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Listen", systemImage: "play.circle") { Task { await listen() } }
                    .disabled(isDownloading)
                ShareLink(
                    item: ArchivedAudioFile(recordingID: recordingID, dataStore: dataStore),
                    preview: SharePreview("Recording")
                ) { Label("Export Audio", systemImage: "square.and.arrow.up") }
                if isDownloading { ProgressView().controlSize(.small) }
            }
            if let downloadError {
                Text(downloadError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .quickLookPreview($previewURL)
    }

    private func listen() async {
        isDownloading = true
        defer { isDownloading = false }
        do {
            previewURL = try await dataStore.audioFile(for: recordingID)
            downloadError = nil
        } catch {
            downloadError = error.localizedDescription
        }
    }
}

nonisolated struct ArchivedAudioFile: Transferable {
    let recordingID: UUID
    let dataStore: MumlaDataStore

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .audio) { file in
            SentTransferredFile(try await file.dataStore.audioFile(for: file.recordingID))
        }
    }
}
