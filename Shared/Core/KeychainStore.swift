import Foundation
import Security

nonisolated struct KeychainStore {
    enum KeychainError: Error {
        case unexpectedData
        case unhandled(OSStatus)
    }

    static let access = KeychainStore(service: "emileberhard.WisprClone.access")

    private static let retiredAPIKeys = KeychainStore(service: "emileberhard.WisprClone.apiKeys")
    private static let retiredAPIKeyAccounts = [
        "LLM_ROUTER_KEY",
        "OPENAI_API_KEY",
        "ASSEMBLYAI_API_KEY",
        "ELEVENLABS_API_KEY",
        "GEMINI_API_KEY",
        "AZURE_SPEECH_KEY",
    ]

    let service: String

    func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
        guard let data = item as? Data else {
            throw KeychainError.unexpectedData
        }
        return String(data: data, encoding: .utf8)
    }

    func upsert(account: String, value: String) throws {
        let update: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
        ]

        let status = SecItemUpdate(baseQuery(account: account) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess {
            return
        }
        guard status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }

        var addQuery = baseQuery(account: account)
        addQuery[kSecValueData as String] = Data(value.utf8)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unhandled(addStatus)
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
        #if os(macOS)
        _ = SecItemDelete(legacyQuery(account: account) as CFDictionary)
        #endif
    }

    static func deleteRetiredAPIKeys() {
        for account in retiredAPIKeyAccounts {
            try? retiredAPIKeys.delete(account: account)
        }
    }

    /// Data-protection keychain query. Items land in the app's default
    /// keychain access group — the profile-injected application-identifier —
    /// and are gated on the code signature, never on per-item ACLs, so no
    /// build of the app can trigger a keychain password prompt. The macOS
    /// dev and Developer ID builds share one bundle ID, so they share the
    /// group; TN3137 requires their provisioning profiles for this to work.
    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    #if os(macOS)
    private func legacyQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: false,
        ]
    }
    #endif
}
