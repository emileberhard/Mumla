import SwiftData
import SwiftUI

struct SearchView: View {
    @Query(filter: #Predicate<HistoryEntry> { !$0.isHidden }, sort: \HistoryEntry.createdAt, order: .reverse)
    private var entries: [HistoryEntry]
    @Query(
        filter: #Predicate<VocabularyEntry> { !$0.isTombstone },
        sort: [SortDescriptor(\VocabularyEntry.text, comparator: .localizedStandard)]
    ) private var terms: [VocabularyEntry]
    @State private var query = ""
    @State private var path: [TranscriptRoute] = []

    var body: some View {
        let results = query.isEmpty ? [] : entries.latestPerRecording().matching(query)
        NavigationStack(path: $path) {
            List {
                if query.isEmpty {
                    if !terms.isEmpty {
                        Section("Dictionary") {
                            ForEach(terms, id: \.id) { term in
                                Button {
                                    query = term.text
                                } label: {
                                    Label(term.text, systemImage: "magnifyingglass")
                                        .foregroundStyle(.primary)
                                }
                            }
                        }
                    }
                } else {
                    ForEach(results) { entry in
                        TranscriptRow(entry: entry) { path.append(.transcript(entry.id)) }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Search")
            .toolbarTitleDisplayMode(.inlineLarge)
            .overlay {
                if !query.isEmpty && results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .transcriptDestinations()
        }
        .searchable(text: $query, prompt: "Search transcripts")
    }
}
