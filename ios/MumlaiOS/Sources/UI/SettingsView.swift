import DictationLibrary
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var coordinator = coordinator

        NavigationStack {
            Form {
                Section {
                    AllowanceView(access: coordinator.access)
                }

                SpokenLanguagesSection()

                DictionarySection()

                Section("Session") {
                    Picker("End After", selection: $coordinator.sessionDuration) {
                        ForEach(SessionDuration.allCases) { duration in
                            Text(duration.displayName).tag(duration)
                        }
                    }
                }

                Section {
                    if let library = coordinator.dataStore.library {
                        NavigationLink {
                            DictationLibraryView(
                                library: library, dataStore: coordinator.dataStore, transcriber: coordinator.transcriber,
                                initialProfile: DictationProfile(languages: coordinator.dictationLanguages, dictionary: coordinator.customVocabulary)
                            )
                        } label: {
                            Label("Dictation Library", systemImage: "waveform.and.magnifyingglass")
                        }
                    }
                    NavigationLink {
                        ThirdPartyNoticesView()
                    } label: {
                        Label("Third-party Notices", systemImage: "doc.text")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct SpokenLanguagesSection: View {
    @Environment(DictationCoordinator.self) private var coordinator

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
}

private struct DictionarySection: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Query(
        filter: #Predicate<VocabularyEntry> { !$0.isTombstone },
        sort: [SortDescriptor(\VocabularyEntry.createdAt), SortDescriptor(\VocabularyEntry.id)]
    ) private var entries: [VocabularyEntry]

    var body: some View {
        Section("Dictionary") {
            ForEach(entries, id: \.id) { entry in
                NavigationLink {
                    EditVocabularyTermView(entry: entry)
                } label: {
                    Text(entry.text)
                }
            }
            .onDelete { offsets in
                coordinator.removeVocabularyTerms(at: offsets, from: entries)
            }

            NavigationLink {
                AddVocabularyTermView()
            } label: {
                Label("Add Word or Phrase", systemImage: "plus")
            }
        }
    }
}

private struct AddVocabularyTermView: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        Form {
            TextField("Word or phrase", text: $text)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
        }
        .navigationTitle("Add Term")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    coordinator.addVocabularyTerm(text)
                    dismiss()
                }
                .disabled(VocabularyTerm.displayText(from: text) == nil)
            }
        }
    }
}

private struct EditVocabularyTermView: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    let entry: VocabularyEntry
    @State private var text: String

    init(entry: VocabularyEntry) {
        self.entry = entry
        _text = State(initialValue: entry.text)
    }

    var body: some View {
        Form {
            TextField("Word or phrase", text: $text)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()

            Button("Delete Term", role: .destructive) {
                coordinator.dataStore.removeVocabularyTerm(entry)
                dismiss()
            }
        }
        .navigationTitle("Edit Term")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    coordinator.updateVocabularyTerm(entry, to: text)
                    dismiss()
                }
                .disabled(VocabularyTerm.displayText(from: text) == nil)
            }
        }
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
