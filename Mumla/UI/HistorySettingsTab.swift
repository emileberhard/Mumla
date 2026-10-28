import SwiftData
import SwiftUI

struct HistorySettingsTab: View {
    @Bindable var coordinator: FlowCoordinator
    @Query(filter: #Predicate<HistoryEntry> { !$0.isHidden }, sort: \HistoryEntry.createdAt, order: .reverse) private var entries: [HistoryEntry]
    @State private var searchText = ""
    @Query private var recordings: [AudioRecording]
    // Cached so the full-history word count runs once per history change,
    // not on every body evaluation while typing in the search field.
    @State private var stats: HistoryStats?

    private var filteredEntries: [HistoryEntry] {
        entries.matching(searchText)
    }

    var body: some View {
        let availableAudio = Set(recordings.map(\.id))
        VStack(spacing: 0) {
            header
                .padding([.horizontal, .top])
                .padding(.bottom, 10)

            TextField("Search transcriptions", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.bottom, 10)

            if entries.isEmpty {
                ContentUnavailableView {
                    Label("No Transcriptions", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Transcriptions appear here as you dictate.")
                }
                .frame(maxHeight: .infinity)
            } else if filteredEntries.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxHeight: .infinity)
            } else {
                List(filteredEntries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        HistoryEntryRow(coordinator: coordinator, entry: entry)
                        if let id = entry.audioRecordingID {
                            if availableAudio.contains(id) {
                                AudioAttachmentControls(recordingID: id, dataStore: coordinator.dataStore)
                            }
                        }
                    }
                }
            }
        }
        .task(id: entries.count) {
            stats = HistoryStats(
                entries: entries,
                storeSizeInBytes: coordinator.dataStore.storeSizeInBytes
            )
        }
        .task(id: coordinator.settingsTab) {
            guard coordinator.settingsTab == .history else { return }
            await coordinator.dataStore.refreshRemoteChangesWhileVisible()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcription History")
                    .font(.headline)
                if let stats {
                    HistoryStatsSummary(stats: stats)
                }
            }

            Spacer()

            Button(role: .destructive) {
                coordinator.dataStore.clear()
            } label: {
                Label("Clear Transcripts", systemImage: "trash")
            }
            .disabled(entries.isEmpty)
        }
    }
}

private struct HistoryStatsSummary: View {
    let stats: HistoryStats

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Synced across your devices with iCloud.")
            if stats.entryCount > 0 {
                Text(totalsLine)
                Text(devicesLine)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var totalsLine: String {
        var parts = [
            "\(stats.entryCount) transcriptions",
            "\(stats.wordCount) words",
            stats.storeSizeInBytes.formatted(.byteCount(style: .file)),
        ]
        if let oldest = stats.oldest {
            parts.append("since \(oldest.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.joined(separator: " · ")
    }

    private var devicesLine: String {
        stats.entriesPerDevice
            .map { "\($0.name) \($0.count)" }
            .joined(separator: " · ")
    }
}

private struct HistoryEntryRow: View {
    @Bindable var coordinator: FlowCoordinator
    let entry: HistoryEntry
    @State private var justCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                Text(entry.deviceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Text(entry.text)
                .font(.body)
                .lineLimit(4)
                .textSelection(.enabled)

            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                    justCopied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        justCopied = false
                    }
                } label: {
                    Label(justCopied ? "Copied" : "Copy", systemImage: justCopied ? "checkmark" : "doc.on.doc")
                }

                Spacer()

                Button(role: .destructive) {
                    coordinator.dataStore.delete(entry)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 6)
    }
}
