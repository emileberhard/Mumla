enum KeyboardSymbolPage: String, CaseIterable {
    case numbers
    case symbols

    var rows: [[String]] {
        switch self {
        case .numbers:
            [
                ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
                ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
                [".", ",", "?", "!", "'"],
            ]
        case .symbols:
            [
                ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
                ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"],
                [".", ",", "?", "!", "'"],
            ]
        }
    }

    var switchTitle: String {
        switch self {
        case .numbers: "#+="
        case .symbols: "123"
        }
    }

    var switchAccessibilityLabel: String {
        switch self {
        case .numbers: "More symbols"
        case .symbols: "Numbers"
        }
    }

    var next: KeyboardSymbolPage {
        switch self {
        case .numbers: .symbols
        case .symbols: .numbers
        }
    }
}
