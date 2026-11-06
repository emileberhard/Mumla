import SwiftData
import SwiftUI

struct DictionaryView: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Query(
        filter: #Predicate<VocabularyEntry> { !$0.isTombstone },
        sort: [SortDescriptor(\VocabularyEntry.text, comparator: .localizedStandard), SortDescriptor(\VocabularyEntry.id)]
    ) private var entries: [VocabularyEntry]
    @State private var isAdding = false
    @State private var newTerm = ""

    var body: some View {
        List {
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
        }
        .navigationTitle("Dictionary")
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add Word", systemImage: "plus") {
                    newTerm = ""
                    isAdding = true
                }
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("No Words", systemImage: "character.book.closed")
                } actions: {
                    Button("Add Word") {
                        newTerm = ""
                        isAdding = true
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        }
        .alert("Add Word", isPresented: $isAdding) {
            TextField("Word or phrase", text: $newTerm)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                coordinator.addVocabularyTerm(newTerm)
            }
            .disabled(VocabularyTerm.displayText(from: newTerm) == nil)
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

            Button("Delete Word", role: .destructive) {
                coordinator.dataStore.removeVocabularyTerm(entry)
                dismiss()
            }
        }
        .navigationTitle("Edit Word")
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
