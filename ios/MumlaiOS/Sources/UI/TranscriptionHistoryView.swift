import SwiftData
import SwiftUI

/// Full synced history of transcriptions, newest first, with search and stats.
struct TranscriptionHistoryView: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Query(filter: #Predicate<HistoryEntry> { !$0.isHidden }, sort: \HistoryEntry.createdAt, order: .reverse) private var entries: [HistoryEntry]
    @State private var searchText = ""
    @State private var showsRecordings = false
    @Query private var recordings: [AudioRecording]
    @State private var isShowingStats = false
    // Cached so the full-history word count runs once per history change,
    // not on every body evaluation.
    @State private var stats: HistoryStats?

    private var filteredEntries: [HistoryEntry] {
        entries.matching(searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("History", selection: $showsRecordings) {
                Text("Transcripts").tag(false)
                Text("Recordings").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            if showsRecordings {
                AudioArchiveView(dataStore: coordinator.dataStore)
            } else {
                transcriptList
            }
        }
        .navigationTitle("History")
    }

    private var transcriptList: some View {
        let availableAudio = Set(recordings.map(\.id))
        return List {
            ForEach(filteredEntries) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    TranscriptionHistoryRow(entry: entry)
                    if let id = entry.audioRecordingID {
                        if availableAudio.contains(id) {
                            AudioAttachmentControls(recordingID: id, dataStore: coordinator.dataStore)
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .onDelete(perform: delete)
        }
        .searchable(text: $searchText, prompt: "Search transcriptions")
        .task { await coordinator.dataStore.refreshRemoteChangesWhileVisible() }
        .task(id: entries.count) {
            stats = entries.isEmpty ? nil : HistoryStats(
                entries: entries,
                storeSizeInBytes: coordinator.dataStore.storeSizeInBytes
            )
        }
        .navigationTitle("History")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let stats {
                    Button("Stats", systemImage: "chart.bar.xaxis") {
                        isShowingStats = true
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingStats) {
            if let stats {
                HistoryStatsView(stats: stats)
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No Transcriptions",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Transcriptions appear here as you dictate.")
                )
            } else if filteredEntries.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        let doomed = offsets.map { filteredEntries[$0] }
        for entry in doomed {
            coordinator.dataStore.delete(entry)
        }
    }
}

private struct HistoryStatsView: View {
    @Environment(\.dismiss) private var dismiss
    let stats: HistoryStats

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Transcriptions", value: "\(stats.entryCount)")
                    LabeledContent("Words", value: "\(stats.wordCount)")
                    LabeledContent("On disk", value: stats.storeSizeInBytes.formatted(.byteCount(style: .file)))
                    if let oldest = stats.oldest {
                        LabeledContent("Since", value: oldest.formatted(date: .abbreviated, time: .omitted))
                    }
                    ForEach(stats.entriesPerDevice, id: \.name) { device in
                        LabeledContent(device.name, value: "\(device.count)")
                    }
                } footer: {
                    Text("Synced across your devices with iCloud.")
                }
            }
            .navigationTitle("Stats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct TranscriptionHistoryRow: View {
    let entry: HistoryEntry
    @State private var justCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.text)
                .textSelection(.enabled)
            HStack(spacing: 12) {
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                copyButton
            }
        }
        .padding(.vertical, 2)
    }

    private var metadata: String {
        var parts = [entry.createdAt.formatted(.relative(presentation: .named))]
        let wordCount = entry.text.split(whereSeparator: \.isWhitespace).count
        parts.append(wordCount == 1 ? "1 word" : "\(wordCount) words")
        return parts.joined(separator: " · ")
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = entry.text
            withAnimation {
                justCopied = true
            }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation {
                    justCopied = false
                }
            }
        } label: {
            Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                .font(.footnote.weight(.medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(justCopied ? .green : .accentColor)
        .sensoryFeedback(.success, trigger: justCopied) { _, isCopied in isCopied }
        .accessibilityLabel(justCopied ? "Copied" : "Copy")
    }
}
