import Foundation

enum KeyboardShortcutMode: String, CaseIterable, Identifiable, Sendable {
    case holdToTalk = "holdToTalk"
    case toggleOnly = "toggleOnly"

    var id: String { rawValue }

    var displayName: LocalizedStringResource {
        switch self {
        case .holdToTalk:
            "Push-to-talk"
        case .toggleOnly:
            "Toggle only"
        }
    }
}
