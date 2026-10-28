import DictationLibrary
import SwiftData
import SwiftUI

struct DictationLibraryProfileView: View {
    let library: UnifiedDictationLibrary
    let dataStore: MumlaDataStore
    private let editingAccount: DictationAccountSession?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DictationProfile
    @State private var isSaving = false
    @State private var error: String?
    @Query(
        filter: #Predicate<VocabularyEntry> { !$0.isTombstone },
        sort: [SortDescriptor(\VocabularyEntry.createdAt), SortDescriptor(\VocabularyEntry.id)]
    ) private var vocabulary: [VocabularyEntry]

    init(library: UnifiedDictationLibrary, dataStore: MumlaDataStore, profile: DictationProfile) {
        self.library = library
        self.dataStore = dataStore
        editingAccount = library.accountSession
        _draft = State(initialValue: profile)
    }

    var body: some View {
        Group {
            if editingAccount == library.accountSession, editingAccount != nil {
                Form {
                    DictationProfileRecordingSection(profile: $draft)
                    Section {
                        NavigationLink {
                            DictationProfileDictionaryView(library: library, dataStore: dataStore, editingAccount: editingAccount)
                        } label: {
                            LabeledContent("Dictionary", value: vocabulary.count.formatted())
                        }
                    }
                    if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
                }
            } else {
                ContentUnavailableView("iCloud Account Changed", systemImage: "person.crop.circle.badge.exclamationmark", description: Text("Return to the library to load the current account."))
            }
        }
        .navigationTitle("Dictation Preferences")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        isSaving = true
                        defer { isSaving = false }
                        do {
                            guard let editingAccount else { throw DictationLibraryError.accountUnavailable }
                            try await library.updateProfile(.archiveEnabled(draft.archiveEnabled), account: editingAccount, creatingFrom: draft)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
                .disabled(isSaving || editingAccount == nil || editingAccount != library.accountSession)
            }
        }
    }
}

private struct DictationProfileRecordingSection: View {
    @Binding var profile: DictationProfile

    var body: some View {
        Section {
            Toggle("Save recordings to iCloud", isOn: $profile.archiveEnabled)
        } header: {
            Text("Connected Apps")
        } footer: {
            Text("Apps you connect can save original recordings and result versions in your private library.")
        }
    }
}

private struct DictationProfileDictionaryView: View {
    let library: UnifiedDictationLibrary
    let dataStore: MumlaDataStore
    let editingAccount: DictationAccountSession?
    @State private var isAdding = false
    @Query(
        filter: #Predicate<VocabularyEntry> { !$0.isTombstone },
        sort: [SortDescriptor(\VocabularyEntry.createdAt), SortDescriptor(\VocabularyEntry.id)]
    ) private var entries: [VocabularyEntry]

    var body: some View {
        Group {
            if library.accountSession == editingAccount {
                List {
                    ForEach(entries) { entry in
                        NavigationLink {
                            DictationProfileTermEditor(library: library, dataStore: dataStore, editingAccount: editingAccount, term: entry)
                        } label: {
                            Text(entry.text)
                        }
                    }
                    .onDelete { offsets in
                        guard library.accountSession == editingAccount else { return }
                        for index in offsets { dataStore.removeVocabularyTerm(entries[index]) }
                    }
                    Button("Add Word or Phrase", systemImage: "plus") { isAdding = true }
                }
            } else {
                ContentUnavailableView("iCloud Account Changed", systemImage: "person.crop.circle.badge.exclamationmark")
            }
        }
        .navigationTitle("Dictionary")
        .sheet(isPresented: $isAdding) {
            NavigationStack {
                DictationProfileTermEditor(library: library, dataStore: dataStore, editingAccount: editingAccount, term: nil)
            }
        }
    }
}

private struct DictationProfileTermEditor: View {
    let library: UnifiedDictationLibrary
    let dataStore: MumlaDataStore
    let editingAccount: DictationAccountSession?
    let term: VocabularyEntry?
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(library: UnifiedDictationLibrary, dataStore: MumlaDataStore, editingAccount: DictationAccountSession?, term: VocabularyEntry?) {
        self.library = library
        self.editingAccount = editingAccount
        self.dataStore = dataStore
        self.term = term
        _text = State(initialValue: term?.text ?? "")
    }

    var body: some View {
        Form {
            if library.accountSession == editingAccount {
                TextField("Word or phrase", text: $text).autocorrectionDisabled()
            } else {
                Label("iCloud account changed", systemImage: "person.crop.circle.badge.exclamationmark")
            }
        }
        .navigationTitle(term == nil ? "Add Term" : "Edit Term")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard library.accountSession == editingAccount else { return }
                    if let term { dataStore.updateVocabularyTerm(term, to: text) }
                    else { dataStore.addVocabularyTerm(text) }
                    dismiss()
                }
                .disabled(VocabularyTerm.displayText(from: text) == nil || library.accountSession != editingAccount)
            }
        }
    }
}
