import SwiftData
import SwiftUI

struct TranscriptsView: View {
    let open: (UUID) -> Void
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase
    @Query(filter: #Predicate<HistoryEntry> { !$0.isHidden }, sort: \HistoryEntry.createdAt, order: .reverse)
    private var entries: [HistoryEntry]

    var body: some View {
        List {
            if !coordinator.lastErrorMessage.isEmpty {
                Section {
                    Label(coordinator.lastErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            ForEach(TranscriptDay.grouping(entries.latestPerRecording())) { day in
                Section {
                    ForEach(day.entries) { entry in
                        TranscriptRow(entry: entry) { open(entry.id) }
                    }
                } header: {
                    Text(day.title)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Transcripts")
        .toolbarTitleDisplayMode(.inlineLarge)
        .animation(.smooth, value: entries.first?.id)
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("No Transcripts", systemImage: "waveform")
            }
        }
        .task(id: scenePhase) {
            guard RemoteChangePollingPolicy.shouldPoll(in: scenePhase) else { return }
            await coordinator.dataStore.refreshRemoteChangesWhileVisible()
        }
    }
}

extension [HistoryEntry] {
    func latestPerRecording() -> [HistoryEntry] {
        var seen = Set<UUID>()
        return filter { entry in
            guard let recording = entry.audioRecordingID else { return true }
            return seen.insert(recording).inserted
        }
    }
}

struct TranscriptRow: View {
    let entry: HistoryEntry
    let open: () -> Void
    @Environment(DictationCoordinator.self) private var coordinator
    @State private var copies = 0

    private var isCopied: Bool { coordinator.copiedTranscript?.id == entry.id }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.text)
                        .lineLimit(3)
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(entry.createdAt, format: .dateTime.hour().minute())
                            .monospacedDigit()
                        if entry.unfilteredText != nil {
                            Image(systemName: "person.2.slash")
                                .accessibilityLabel("Other voices left out")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            Button(action: copy) {
                Label(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.medium))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tint)
            .animation(.smooth(duration: 0.3), value: isCopied)
            .sensoryFeedback(.impact(weight: .light), trigger: copies)
        }
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc", action: copy)
            ShareLink(item: entry.text)
            Button("Delete", systemImage: "trash", role: .destructive, action: delete)
        }
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive, action: delete)
        }
    }

    private var accessibilityLabel: Text {
        let preview = entry.text.count > 120 ? String(entry.text.prefix(120)) + "…" : entry.text
        let time = entry.createdAt.formatted(date: .omitted, time: .shortened)
        return Text("\(preview), \(time)")
    }

    private func copy() {
        coordinator.copy(entry)
        copies += 1
        AccessibilityNotification.Announcement("Copied").post()
    }

    private func delete() {
        coordinator.dataStore.deleteAllVersions(of: entry)
    }
}

struct TranscriptView: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @Query private var matches: [HistoryEntry]
    @State private var copies = 0
    @State private var showsEveryone = false

    init(id: UUID) {
        _matches = Query(filter: #Predicate<HistoryEntry> { $0.id == id })
    }

    var body: some View {
        if let entry = matches.first {
            RecordingAvailability(recordingID: entry.audioRecordingID) { recordingID in
                content(entry, recordingID: recordingID)
            }
        } else {
            ContentUnavailableView("Transcript Deleted", systemImage: "trash")
        }
    }

    private func content(_ entry: HistoryEntry, recordingID: UUID?) -> some View {
        let isCopied = coordinator.copiedTranscript?.id == entry.id
        let shown = showsEveryone ? entry.unfilteredText ?? entry.text : entry.text
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(shown)
                    .font(shown.count > 280 ? .body : .title2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
                    .animation(.smooth, value: showsEveryone)
                HStack {
                    if let recordingID {
                        ListenButton(recordingID: recordingID, dataStore: coordinator.dataStore)
                    }
                    if entry.unfilteredText != nil {
                        Toggle(isOn: $showsEveryone) {
                            Label("Show Everyone", systemImage: "person.2")
                        }
                        .toggleStyle(.button)
                        .onChange(of: showsEveryone) { _, shows in
                            if shows { CrashReporting.breadcrumb("Showed everyone's words", category: "voice_filter") }
                        }
                    }
                }
                .buttonStyle(.bordered)
                Text(details(entry))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .navigationTitle(String(localized: "\(TranscriptDay.title(for: entry.createdAt)), \(entry.createdAt.formatted(date: .omitted, time: .shortened))"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis") {
                    ShareLink(item: entry.text)
                    if let everyone = entry.unfilteredText {
                        Button("Copy Everything", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = everyone
                            CrashReporting.breadcrumb("Copied everyone's words", category: "voice_filter")
                        }
                    }
                    if let recordingID {
                        ExportAudioLink(recordingID: recordingID, dataStore: coordinator.dataStore)
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        coordinator.dataStore.deleteAllVersions(of: entry)
                        dismiss()
                    }
                }
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    coordinator.copy(entry)
                    copies += 1
                    AccessibilityNotification.Announcement("Copied").post()
                } label: {
                    Label(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.titleOnly)
                }
                .buttonStyle(.glassProminent)
                .sensoryFeedback(.impact(weight: .light), trigger: copies)
            }
        }
    }

    private func details(_ entry: HistoryEntry) -> String {
        let words = entry.text.split(whereSeparator: \.isWhitespace).count
        var parts = [String(localized: "\(words) words")]
        if !entry.deviceName.isEmpty {
            parts.append(entry.deviceName)
        }
        if entry.unfilteredText != nil {
            parts.append(String(localized: "Other voices left out"))
        }
        return parts.joined(separator: " · ")
    }
}

private struct RecordingAvailability<Content: View>: View {
    @Query private var recordings: [AudioRecording]
    @ViewBuilder let content: (UUID?) -> Content

    init(recordingID: UUID?, @ViewBuilder content: @escaping (UUID?) -> Content) {
        self.content = content
        var query = FetchDescriptor<AudioRecording>(
            predicate: recordingID.map { id in #Predicate<AudioRecording> { $0.id == id } } ?? #Predicate<AudioRecording> { _ in false }
        )
        query.fetchLimit = 1
        _recordings = Query(query)
    }

    var body: some View {
        content(recordings.first?.id)
    }
}

struct TranscriptDay: Identifiable {
    let id: Date
    let title: String
    private(set) var entries: [HistoryEntry]

    static func grouping(_ entries: [HistoryEntry], calendar: Calendar = .current, now: Date = .now) -> [TranscriptDay] {
        var days: [TranscriptDay] = []
        for entry in entries {
            let day = calendar.startOfDay(for: entry.createdAt)
            if days.last?.id == day {
                days[days.count - 1].entries.append(entry)
            } else {
                days.append(TranscriptDay(id: day, title: title(for: day, calendar: calendar, now: now), entries: [entry]))
            }
        }
        return days
    }

    static func title(for date: Date, calendar: Calendar = .current, now: Date = .now) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return String(localized: "Today")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= weekAgo {
            return date.formatted(.dateTime.weekday(.wide))
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
        return date.formatted(.dateTime.day().month(.wide).year())
    }
}
