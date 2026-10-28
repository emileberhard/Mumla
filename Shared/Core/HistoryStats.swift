import Foundation

extension [HistoryEntry] {
    /// The one definition of what history search matches: case- and
    /// diacritic-insensitive substring of the transcript text.
    func matching(_ searchText: String) -> [HistoryEntry] {
        guard !searchText.isEmpty else { return self }
        return filter { $0.text.localizedStandardContains(searchText) }
    }
}

/// Aggregates shown in the history UI on both platforms. A pure function of
/// the already-fetched entries plus the store's size on disk.
struct HistoryStats {
    let entryCount: Int
    let wordCount: Int
    let oldest: Date?
    let storeSizeInBytes: Int64
    let entriesPerDevice: [(name: String, count: Int)]

    init(entries: [HistoryEntry], storeSizeInBytes: Int64) {
        entryCount = entries.count
        wordCount = entries.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        oldest = entries.map(\.createdAt).min()
        self.storeSizeInBytes = storeSizeInBytes
        entriesPerDevice = Dictionary(grouping: entries, by: \.deviceName)
            .map { (name: $0.key.isEmpty ? "Unknown" : $0.key, count: $0.value.count) }
            .sorted {
                $0.count == $1.count
                    ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    : $0.count > $1.count
            }
    }
}
