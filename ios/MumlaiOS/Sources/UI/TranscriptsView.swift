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
            if coordinator.access.state.isWorthNoticing {
                Section {
                    AllowanceView(access: coordinator.access)
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
    @State private var flash = false

    private var isCopied: Bool { coordinator.copiedTranscript?.id == entry.id }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: copy) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.text)
                        .lineLimit(3)
                        .foregroundStyle(.primary)
                    HStack(spacing: 8) {
                        Text(entry.createdAt, format: .dateTime.hour().minute())
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        if isCopied {
                            Label("Copied", systemImage: "checkmark")
                                .fontWeight(.semibold)
                                .foregroundStyle(.tint)
                                .transition(.symbolEffect(.drawOn))
                        }
                    }
                    .font(.subheadline)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Copies the transcript")
            Button("Details", systemImage: "info.circle", action: open)
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(.tint)
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.accentColor.opacity(flash ? 0.16 : 0))
        .animation(.smooth(duration: 0.3), value: isCopied)
        .sensoryFeedback(.impact(weight: .light), trigger: flash) { _, new in new }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc", action: copy)
            ShareLink(item: entry.text)
            Button("Details", systemImage: "info.circle", action: open)
            Button("Delete", systemImage: "trash", role: .destructive, action: delete)
        }
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive, action: delete)
        }
        .accessibilityAction(named: "Details", open)
        .accessibilityAction(named: "Delete", delete)
    }

    private func copy() {
        coordinator.copy(entry)
        withAnimation(.easeIn(duration: 0.08)) {
            flash = true
        } completion: {
            withAnimation(.easeOut(duration: 0.6)) {
                flash = false
            }
        }
        AccessibilityNotification.Announcement("Copied").post()
    }

    private func delete() {
        coordinator.dataStore.delete(entry)
    }
}

struct TranscriptView: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @Query private var matches: [HistoryEntry]
    @Query private var recordings: [AudioRecording]

    init(id: UUID) {
        _matches = Query(filter: #Predicate<HistoryEntry> { $0.id == id })
    }

    var body: some View {
        if let entry = matches.first {
            content(entry)
        } else {
            ContentUnavailableView("Transcript Deleted", systemImage: "trash")
        }
    }

    private func content(_ entry: HistoryEntry) -> some View {
        let recordingID = entry.audioRecordingID.flatMap { id in recordings.contains { $0.id == id } ? id : nil }
        let isCopied = coordinator.copiedTranscript?.id == entry.id
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(entry.text)
                    .font(entry.text.count > 280 ? .body : .title2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let recordingID {
                    AudioAttachmentControls(recordingID: recordingID, dataStore: coordinator.dataStore)
                        .buttonStyle(.bordered)
                }
                Text(details(entry))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .navigationTitle(TranscriptDay.title(for: entry.createdAt) + ", " + entry.createdAt.formatted(date: .omitted, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis") {
                    ShareLink(item: entry.text)
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        coordinator.dataStore.delete(entry)
                        dismiss()
                    }
                }
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    coordinator.copy(entry)
                    AccessibilityNotification.Announcement("Copied").post()
                } label: {
                    Label(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.titleOnly)
                }
                .buttonStyle(.glassProminent)
                .sensoryFeedback(.impact(weight: .light), trigger: isCopied) { _, new in new }
            }
        }
    }

    private func details(_ entry: HistoryEntry) -> String {
        let words = entry.text.split(whereSeparator: \.isWhitespace).count
        var parts = [
            entry.createdAt.formatted(date: .complete, time: .shortened),
            String(localized: "\(words) words"),
        ]
        if !entry.deviceName.isEmpty {
            parts.append(entry.deviceName)
        }
        return parts.joined(separator: " · ")
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
