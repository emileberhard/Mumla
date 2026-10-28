import Foundation

nonisolated enum HostApplicationReturnRoutes {
    private static let schemesByBundleIdentifier: [String: [String]] = [
        "ai.x.GrokApp": ["grok://"],
        "com.anthropic.claude": ["claude://"],
        "com.apple.MobileSMS": ["sms:"],
        "com.apple.mobilemail": ["message:"],
        "com.apple.mobilenotes": ["mobilenotes://"],
        "com.burbn.instagram": ["instagram://"],
        "com.google.Gmail": ["googlegmail://"],
        "com.google.chrome.ios": ["googlechrome://"],
        "com.google.gemini": ["gemini://", "google-gemini://"],
        "com.hammerandchisel.discord": ["discord://"],
        "com.linkedin.LinkedIn": ["linkedin://"],
        "com.openai.chat": ["chatgpt://"],
        "com.tinyspeck.chatlyio": ["slack://"],
        "net.whatsapp.WhatsApp": ["whatsapp://"],
        "net.whatsapp.WhatsAppSMB": ["whatsapp-smb://"],
        "ph.telegra.Telegraph": ["tg://"],
    ]

    static func urls(for bundleIdentifier: String) -> [URL] {
        schemesByBundleIdentifier[bundleIdentifier, default: []].compactMap(URL.init(string:))
    }
}
