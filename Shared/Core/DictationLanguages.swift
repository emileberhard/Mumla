import Foundation

/// The user's dictation languages as ordered ISO 639-1 codes. An unset
/// preference means "follow the system languages", so a fresh install works
/// without configuration; an explicit edit in Settings is synced across
/// devices and wins over the system list.
enum DictationLanguages {
    static func systemDefault() -> [String] {
        let codes = Locale.preferredLocales.compactMap { $0.language.languageCode?.identifier }
        var seen: Set<String> = []
        let unique = codes.filter { seen.insert($0).inserted }
        return unique.isEmpty ? ["en"] : unique
    }

    /// Returns nil for an empty stored value so callers fall back to the
    /// system languages instead of dictating with no language at all.
    static func decode(_ stored: String) -> [String]? {
        let codes = stored
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return codes.isEmpty ? nil : codes
    }

    static func encode(_ codes: [String]) -> String {
        codes.joined(separator: ",")
    }

    static func displayName(for code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    /// Every ISO 639-1 language the picker offers, sorted by display name.
    static func selectableCodes() -> [String] {
        Locale.LanguageCode.isoLanguageCodes
            .map(\.identifier)
            .filter { $0.count == 2 }
            .sorted { displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending }
    }
}
