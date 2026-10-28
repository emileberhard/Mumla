import UIKit

/// Whether the Mumla keyboard is enabled, from the active input modes
/// (required reason 54BD.1). Enabled is claimed only when exactly one active
/// mode carries Mumla's primary language; any other answer means the app
/// cannot tell, never that the keyboard is off. Full Access is not visible
/// here; the keyboard's App Group stamp remains the only Full Access proof.
enum KeyboardEnablement {
    static let primaryLanguage: String? = Bundle.main.builtInPlugInsURL
        .flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }?
        .compactMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "NSExtension") as? [String: Any] }
        .first { $0["NSExtensionPointIdentifier"] as? String == "com.apple.keyboard-service" }
        .flatMap { ($0["NSExtensionAttributes"] as? [String: Any])?["PrimaryLanguage"] as? String }

    static var isKnownEnabled: Bool {
        guard let primaryLanguage else { return false }
        return UITextInputMode.activeInputModes.count(where: { $0.primaryLanguage == primaryLanguage }) == 1
    }
}
