import DictationLibrary
import SwiftData
import SwiftUI

struct AccountView: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ProPlanRows { AllowanceView(access: coordinator.access) }
                }

                Section {
                    NavigationLink {
                        LanguagesView()
                    } label: {
                        row("Languages", systemImage: "globe", color: .blue, value: languageSummary)
                    }
                    NavigationLink {
                        KeyboardSessionView()
                    } label: {
                        row("Keyboard", systemImage: "keyboard", color: .gray, value: sessionSummary)
                    }
                    NavigationLink {
                        ICloudView()
                    } label: {
                        row("iCloud", systemImage: "icloud.fill", color: .cyan, value: coordinator.access.state.isICloudSignedOut ? String(localized: "Signed Out") : nil)
                    }
                }

                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        row("About", systemImage: "info", color: .gray, value: nil)
                    }
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
    }

    private func row(_ title: LocalizedStringKey, systemImage: String, color: Color, value: String?) -> some View {
        LabeledContent {
            if let value {
                Text(value)
            }
        } label: {
            Label {
                Text(title)
            } icon: {
                SettingsIcon(systemImage: systemImage, color: color)
            }
        }
    }

    private var languageSummary: String {
        let names = coordinator.spokenLanguages.map(DictationLanguages.displayName(for:))
        return names.isEmpty ? String(localized: "Automatic") : names.formatted(.list(type: .and, width: .narrow))
    }

    private var sessionSummary: String {
        guard coordinator.sessionActive else { return String(localized: "Off") }
        guard let end = coordinator.sessionEndDate else { return String(localized: "On") }
        return String(localized: "Until \(end.formatted(date: .omitted, time: .shortened))")
    }
}

private struct SettingsIcon: View {
    let systemImage: String
    let color: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(color.gradient, in: .rect(cornerRadius: 7))
    }
}

private struct KeyboardSessionView: View {
    @Environment(DictationCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator
        Form {
            Section {
                Picker("End Session After", selection: $coordinator.sessionDuration) {
                    ForEach(SessionDuration.allCases) { duration in
                        Text(duration.displayName).tag(duration)
                    }
                }
            }
            if coordinator.sessionActive {
                Section {
                    Button("End Session Now", role: .destructive) {
                        coordinator.requestSessionEnd()
                    }
                }
            }
        }
        .navigationTitle("Keyboard")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ICloudView: View {
    @Environment(DictationCoordinator.self) private var coordinator

    var body: some View {
        Form {
            Section {
                NavigationLink("Recordings") {
                    AudioArchiveView(dataStore: coordinator.dataStore)
                        .navigationTitle("Recordings")
                        .navigationBarTitleDisplayMode(.inline)
                }
                if let library = coordinator.dataStore.library {
                    NavigationLink("Dictation Library") {
                        DictationLibraryView(
                            library: library, dataStore: coordinator.dataStore, transcriber: coordinator.transcriber,
                            initialProfile: DictationProfile(languages: coordinator.dictationLanguages, dictionary: coordinator.customVocabulary)
                        )
                    }
                }
            }
            StatisticsSection()
        }
        .navigationTitle("iCloud")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AboutView: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                Link("Privacy Policy", destination: MumlaPro.privacyPolicyURL)
                NavigationLink("Third-party Notices") {
                    ThirdPartyNoticesView()
                }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LanguagesView: View {
    @Environment(DictationCoordinator.self) private var coordinator

    private var isSaving: Bool {
        if case .saving = coordinator.dataStore.library?.languagesSave { true } else { false }
    }

    private var canRemoveLanguage: Bool {
        !isSaving && (coordinator.spokenLanguagesOwner != .local || coordinator.spokenLanguages.count > 1)
    }

    var body: some View {
        Form {
            if let library = coordinator.dataStore.library {
                SpokenLanguagesStatus(owner: coordinator.spokenLanguagesOwner, library: library)
            }

            switch coordinator.spokenLanguagesOwner {
            case .unavailable:
                EmptyView()
            case .local, .profile:
                Section {
                    if coordinator.spokenLanguages.isEmpty {
                        Text("Automatic")
                    }
                    ForEach(coordinator.spokenLanguages, id: \.self) { code in
                        Text(DictationLanguages.displayName(for: code))
                    }
                    .onDelete { offsets in
                        coordinator.removeDictationLanguages(at: offsets)
                    }
                    .deleteDisabled(!canRemoveLanguage)

                    NavigationLink {
                        AddDictationLanguageView()
                    } label: {
                        Label("Add Language", systemImage: "plus")
                    }
                    .disabled(isSaving)
                }
            }
        }
        .navigationTitle("Languages")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AddDictationLanguageView: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var candidates: [String] {
        let enabled = Set(coordinator.spokenLanguages)
        let available = DictationLanguages.selectableCodes().filter { !enabled.contains($0) }
        guard !searchText.isEmpty else { return available }
        return available.filter {
            DictationLanguages.displayName(for: $0).localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List(candidates, id: \.self) { code in
            Button {
                coordinator.addDictationLanguage(code)
                dismiss()
            } label: {
                Text(DictationLanguages.displayName(for: code))
                    .foregroundStyle(Color.primary)
            }
        }
        .searchable(text: $searchText)
        .overlay {
            if candidates.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .navigationTitle("Add Language")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StatisticsSection: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Query(filter: #Predicate<HistoryEntry> { !$0.isHidden }) private var entries: [HistoryEntry]
    @State private var stats: HistoryStats?

    var body: some View {
        Group {
            if let stats {
                Section("Statistics") {
                    LabeledContent("Transcripts", value: "\(stats.entryCount)")
                    LabeledContent("Words", value: "\(stats.wordCount)")
                    LabeledContent("On Disk", value: stats.storeSizeInBytes.formatted(.byteCount(style: .file)))
                    if let oldest = stats.oldest {
                        LabeledContent("Since", value: oldest.formatted(date: .abbreviated, time: .omitted))
                    }
                }
                if stats.entriesPerDevice.count > 1 {
                    Section("Devices") {
                        ForEach(stats.entriesPerDevice, id: \.name) { device in
                            LabeledContent(device.name, value: "\(device.count)")
                        }
                    }
                }
            }
        }
        .task(id: entries.count) {
#if MUMLA_SCREENSHOTS
            let storeSize: Int64 = 1_048_576
#else
            let storeSize = coordinator.dataStore.storeSizeInBytes
#endif
            stats = entries.isEmpty ? nil : HistoryStats(entries: entries, storeSizeInBytes: storeSize)
        }
    }
}
