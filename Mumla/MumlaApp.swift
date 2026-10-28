import CloudKit
import SwiftData
import SwiftUI
import DictationLibrary
import UniformTypeIdentifiers

@main
struct MumlaApp: App {
    @NSApplicationDelegateAdaptor(MumlaAppDelegate.self) private var appDelegate
    @State private var coordinator: FlowCoordinator

    // Keep Settings window smaller than typical display height.
    private let settingsWindowWidth: CGFloat = 520
    private let settingsWindowHeight: CGFloat = 650

    init() {
        if ProcessInfo.processInfo.arguments.contains("--dictation-library") {
            DictationLibraryCommand.runAndExit()
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["MUMLA_LIBRARY_PROBE"] == "1" {
            DictationLibraryCloudProbe.runAndExit()
        }
        if ProcessInfo.processInfo.environment["MUMLA_ACCESS_PROBE"] == "1" {
            AccessProbe.runAndExit()
        }
        if ProcessInfo.processInfo.environment["MUMLA_TRANSPORT_PROBE"] == "1" {
            ProjectedCloudTransportProbe.runAndExit()
        }
        if ProcessInfo.processInfo.environment["MUMLA_INIT_CLOUDKIT_SCHEMA"] == "1" {
            AppCloudKitSchemaBootstrap.runAndExit()
        }
        #endif
        Self.handleTestStateArguments()
        _coordinator = State(initialValue: FlowCoordinator.shared)
        AppDiagnostics.bootstrap()
    }

    /// `--delete-credentials` deletes this Mac's access session and retired
    /// keys, then exits without showing UI. The data-protection keychain is
    /// invisible to the `security` CLI, so test-state scripts
    /// (mac-fresh-user.sh) invoke the app binary with this flag instead.
    private static func handleTestStateArguments() {
        guard ProcessInfo.processInfo.arguments.contains("--delete-credentials") else { return }
        try? KeychainAccessSessionStore().delete()
        KeychainStore.deleteRetiredAPIKeys()
        exit(0)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(coordinator: coordinator)
        } label: {
            MenuBarStatusLabel(coordinator: coordinator)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(coordinator: coordinator)
                .frame(
                    minWidth: settingsWindowWidth,
                    maxWidth: settingsWindowWidth,
                    minHeight: settingsWindowHeight,
                    maxHeight: settingsWindowHeight
                )
                .modelContainer(coordinator.dataStore.container)
                .id(coordinator.dataStore.partitionID)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - Menu Bar

struct MenuBarStatusLabel: View {
    @Bindable var coordinator: FlowCoordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: 16, weight: .semibold))
            .onReceive(NotificationCenter.default.publisher(for: .mumlaOpenSettingsRequested)) { _ in
                openSettingsWindow()
            }
    }

    private func openSettingsWindow() {
        coordinator.settingsTab = .general
        NSApp.activate()
        openSettings()
    }
}

struct MenuBarContent: View {
    @Bindable var coordinator: FlowCoordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        AllowanceMenuItem(access: coordinator.access)

        Toggle("Auto-send", isOn: $coordinator.autoSend)

        Picker("Shortcut Mode", selection: $coordinator.keyboardShortcutMode) {
            ForEach(KeyboardShortcutMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.inline)

        Divider()

        Button("Settings...") {
            coordinator.settingsTab = .general
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Recover Recordings...") {
            coordinator.settingsTab = .recovery
            NSApp.activate()
            openSettings()
        }

        Button("Copy Diagnostics") {
            coordinator.copyDiagnostics()
        }

        Button("Open Logs Folder") {
            coordinator.openDiagnosticsLogsFolder()
        }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

private struct AllowanceMenuItem: View {
    let access: MumlaAccess
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch access.state {
        case .checking:
            EmptyView()
        case .available(let allowance):
            if allowance.isExhausted {
                Text("No minutes left until \(allowance.resetsAt, format: .dateTime.month(.wide).day())")
            } else if allowance.available == .zero {
                Text("In use on another device")
            } else {
                Text("\(allowance.remaining.wholeMinutes) of \(allowance.limit.wholeMinutes) min left")
            }
            Divider()
        case .iCloudUnavailable(.noAccount):
            Button("Sign In to iCloud to Dictate…") {
                openURL(URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings")!)
            }
            Divider()
        case .iCloudUnavailable:
            Text("iCloud is unavailable")
            Divider()
        case .serviceUnavailable:
            Text("Can't reach Mumla")
            Divider()
        }
    }
}

// MARK: - Settings Window

struct SettingsView: View {
    @Bindable var coordinator: FlowCoordinator

    var body: some View {
        TabView(selection: $coordinator.settingsTab) {
            GeneralSettingsTab(coordinator: coordinator)
                .tag(SettingsTab.general)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            DictionarySettingsTab(coordinator: coordinator)
                .tag(SettingsTab.dictionary)
                .tabItem {
                    Label("Dictionary", systemImage: "text.book.closed")
                }

            HistorySettingsTab(coordinator: coordinator)
                .tag(SettingsTab.history)
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }

            RecoverySettingsTab(coordinator: coordinator)
                .tag(SettingsTab.recovery)
                .tabItem {
                    Label("Recovery", systemImage: "waveform")
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scenePadding()
    }
}

struct GeneralSettingsTab: View {
    @Bindable var coordinator: FlowCoordinator
    @State private var showDictationLibrary = false
    @State private var showThirdPartyNotices = false

    var body: some View {
        Form {
            Section {
                AllowanceView(access: coordinator.access)
            }

            ShortcutSettingsSection(coordinator: coordinator)

            SpokenLanguagesSection(coordinator: coordinator)

            Section("Permissions") {
                PermissionStatusRow(
                    title: "Dictation Shortcut",
                    isGranted: coordinator.inputMonitoringPermissionState == .granted
                ) {
                    await coordinator.guideInputMonitoringAccess()
                }
                PermissionStatusRow(
                    title: "Auto-Paste",
                    isGranted: coordinator.accessibilityPermissionGranted
                ) {
                    await coordinator.guideAccessibilityAccess()
                }
            }

            Section {
                Toggle("Launch at Login", isOn: $coordinator.launchAtLogin)
            }

            Section {
                if coordinator.dataStore.library != nil {
                    Button("Dictation Library", systemImage: "waveform.and.magnifyingglass") {
                        showDictationLibrary = true
                    }
                }
                Button("Third-party Notices", systemImage: "doc.text") { showThirdPartyNotices = true }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showThirdPartyNotices) {
            NavigationStack {
                ThirdPartyNoticesView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showThirdPartyNotices = false }
                        }
                    }
            }
            .frame(minWidth: 520, minHeight: 500)
        }
        .sheet(isPresented: $showDictationLibrary) {
            if let library = coordinator.dataStore.library {
                NavigationStack {
                    DictationLibraryView(
                        library: library, dataStore: coordinator.dataStore, transcriber: coordinator.transcriber,
                        initialProfile: DictationProfile(languages: coordinator.dictationLanguages, dictionary: coordinator.customVocabulary)
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showDictationLibrary = false }
                        }
                    }
                }
                .frame(minWidth: 640, minHeight: 560)
            }
        }
    }
}

private struct ShortcutSettingsSection: View {
    @Bindable var coordinator: FlowCoordinator

    var body: some View {
        Section("Shortcut") {
            Picker("Mode", selection: $coordinator.keyboardShortcutMode) {
                ForEach(KeyboardShortcutMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            switch coordinator.keyboardShortcutMode {
            case .holdToTalk:
                LabeledContent("Talk") {
                    KeyGesture(action: "Hold", key: "fn")
                }
                LabeledContent("Keep listening") {
                    KeyGesture(action: "Double-tap", key: "fn")
                }
            case .toggleOnly:
                LabeledContent("Start or stop") {
                    KeyGesture(action: "Press", key: "fn")
                }
            }
        }
    }
}

private struct SpokenLanguagesSection: View {
    @Bindable var coordinator: FlowCoordinator

    private var addableLanguageCodes: [String] {
        let enabled = Set(coordinator.spokenLanguages)
        return DictationLanguages.selectableCodes().filter { !enabled.contains($0) }
    }

    private var isSaving: Bool {
        if case .saving = coordinator.dataStore.library?.languagesSave { true } else { false }
    }

    private var canRemoveLanguage: Bool {
        !isSaving && (coordinator.spokenLanguagesOwner != .local || coordinator.spokenLanguages.count > 1)
    }

    var body: some View {
        Section("Spoken Languages") {
            if let library = coordinator.dataStore.library {
                SpokenLanguagesStatus(owner: coordinator.spokenLanguagesOwner, library: library)
            }

            switch coordinator.spokenLanguagesOwner {
            case .unavailable:
                EmptyView()
            case .local, .profile:
                if coordinator.spokenLanguages.isEmpty {
                    Text("Automatic")
                }
                ForEach(coordinator.spokenLanguages, id: \.self) { code in
                    LabeledContent(DictationLanguages.displayName(for: code)) {
                        Button("Remove", systemImage: "minus.circle.fill") {
                            coordinator.removeDictationLanguage(code)
                        }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.borderless)
                        .disabled(!canRemoveLanguage)
                    }
                }

                Menu {
                    ForEach(addableLanguageCodes, id: \.self) { code in
                        Button(DictationLanguages.displayName(for: code)) {
                            coordinator.addDictationLanguage(code)
                        }
                    }
                } label: {
                    Label("Add Language", systemImage: "plus")
                }
                .disabled(isSaving)
            }
        }
    }
}

private struct PermissionStatusRow: View {
    let title: LocalizedStringKey
    let isGranted: Bool
    let grant: () async -> Void

    var body: some View {
        LabeledContent(title) {
            if isGranted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Grant Access…") {
                    Task { await grant() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Dictionary Tab
struct DictionarySettingsTab: View {
    @Bindable var coordinator: FlowCoordinator
    @Query(
        filter: #Predicate<VocabularyEntry> { !$0.isTombstone },
        sort: [SortDescriptor(\VocabularyEntry.createdAt), SortDescriptor(\VocabularyEntry.id)]
    ) private var entries: [VocabularyEntry]
    @State private var newWord = ""
    @State private var isAddingWord = false
    @State private var editingID: String?
    @State private var editingText = ""
    @FocusState private var isNewWordFocused: Bool
    @FocusState private var isEditingFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty && !isAddingWord {
                ContentUnavailableView {
                    Label("No Terms", systemImage: "text.book.closed")
                } description: {
                    Text("Add words or phrases to improve transcription accuracy.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(entries, id: \.id) { entry in
                        if editingID == entry.id {
                            HStack {
                                TextField("Word or phrase", text: $editingText)
                                    .textFieldStyle(.plain)
                                    .focused($isEditingFocused)
                                    .onSubmit { saveEdit(entry) }

                                Button("Save") { saveEdit(entry) }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)

                                Button("Cancel") { cancelEdit() }
                                    .controlSize(.small)
                            }
                        } else {
                            HStack {
                                Text(entry.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Button {
                                    startEditing(entry)
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)

                                Button(role: .destructive) {
                                    coordinator.removeVocabularyTerm(entry)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }

            Divider()

            // Add new word section
            HStack {
                if isAddingWord {
                    TextField("Word or phrase", text: $newWord)
                        .textFieldStyle(.roundedBorder)
                        .focused($isNewWordFocused)
                        .onSubmit { addWord() }

                    Button("Add") { addWord() }
                        .buttonStyle(.borderedProminent)
                        .disabled(VocabularyTerm.displayText(from: newWord) == nil)

                    Button("Cancel") { cancelAdding() }
                } else {
                    Button {
                        isAddingWord = true
                        isNewWordFocused = true
                    } label: {
                        Label("Add Word or Phrase", systemImage: "plus")
                    }

                    Spacer()

                    Button {
                        importVocabulary()
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        exportVocabulary()
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(entries.isEmpty)
                }
            }
            .padding()
        }
        .task {
            await coordinator.dataStore.refreshRemoteChangesWhileVisible()
        }
    }

    private func addWord() {
        coordinator.addVocabularyTerm(newWord)
        newWord = ""
        isAddingWord = false
    }

    private func cancelAdding() {
        newWord = ""
        isAddingWord = false
    }

    private func startEditing(_ entry: VocabularyEntry) {
        editingID = entry.id
        editingText = entry.text
        isEditingFocused = true
    }

    private func saveEdit(_ entry: VocabularyEntry) {
        coordinator.updateVocabularyTerm(entry, to: editingText)
        editingID = nil
        editingText = ""
    }

    private func cancelEdit() {
        editingID = nil
        editingText = ""
    }

    private func importVocabulary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a vocabulary JSON file to import"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(VocabularyFile.self, from: data)
            coordinator.replaceVocabulary(with: decoded.words)
        } catch {
            print("Import failed: \(DiagnosticError(error).metadata)")
        }
    }

    private func exportVocabulary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "vocabulary.json"
        panel.message = "Choose where to save your vocabulary"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let file = VocabularyFile(words: entries.map(\.text))
            let data = try JSONEncoder().encode(file)
            try data.write(to: url)
        } catch {
            print("Export failed: \(DiagnosticError(error).metadata)")
        }
    }
}

private struct VocabularyFile: Codable {
    let words: [String]
}
