import Testing

@Suite("Keyboard symbol layout")
struct KeyboardSymbolLayoutTests {
    @Test func numbersPageMatchesFamiliarIOSSymbolRows() {
        #expect(KeyboardSymbolPage.numbers.rows == [
            ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
            ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
            [".", ",", "?", "!", "'"],
        ])
    }

    @Test func alternateSymbolsPageIncludesStandardSecondarySymbols() {
        #expect(KeyboardSymbolPage.symbols.rows == [
            ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
            ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"],
            [".", ",", "?", "!", "'"],
        ])
    }

    @Test func symbolPagesToggleBetweenNativeLabels() {
        #expect(KeyboardSymbolPage.numbers.switchTitle == "#+=")
        #expect(KeyboardSymbolPage.numbers.switchAccessibilityLabel == "More symbols")
        #expect(KeyboardSymbolPage.numbers.next == .symbols)
        #expect(KeyboardSymbolPage.symbols.switchTitle == "123")
        #expect(KeyboardSymbolPage.symbols.switchAccessibilityLabel == "Numbers")
        #expect(KeyboardSymbolPage.symbols.next == .numbers)
    }

    @Test func eachPageHasStableNonEmptyKeysWithoutPageLocalDuplicates() {
        for page in KeyboardSymbolPage.allCases {
            let characters = page.rows.flatMap(\.self)

            #expect(page.rows.map(\.count) == [10, 10, 5])
            #expect(characters.allSatisfy { !$0.isEmpty })
            #expect(Set(characters).count == characters.count)
        }
    }
}
