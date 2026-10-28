import Foundation
#if os(macOS)
import Security
#endif

enum SharedPreferenceKey {
    static let dictationLanguages = "dictationLanguages"
    static let customVocabulary = "customVocabulary"
}

@MainActor
final class CloudPreferenceStore {
    private let defaults: UserDefaults
    private let cloudStore: NSUbiquitousKeyValueStore?
    private var observer: (any NSObjectProtocol)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.cloudStore = Self.makeCloudStoreIfAvailable()
    }

    isolated deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func string(forKey key: String, default defaultValue: String = "") -> String {
        guard let cloudValue = cloudStore?.string(forKey: key) else {
            return defaults.string(forKey: key) ?? defaultValue
        }
        defaults.set(cloudValue, forKey: key)
        return cloudValue
    }

    /// Reads both sides without applying the usual cloud-wins behavior. This
    /// is only for one-way migration of legacy representations where either
    /// device may contain terms absent from the other.
    func legacyStringValues(forKey key: String) -> [String] {
        [defaults.string(forKey: key), cloudStore?.string(forKey: key)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
    }

    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        guard let cloudValue = cloudStore?.object(forKey: key) as? Bool else {
            return defaults.object(forKey: key) as? Bool ?? defaultValue
        }
        defaults.set(cloudValue, forKey: key)
        return cloudValue
    }

    func set(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
        cloudStore?.set(value, forKey: key)
    }

    func set(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
        cloudStore?.set(value, forKey: key)
    }

    func pushCurrentValues(keys: [String]) {
        guard let cloudStore else { return }
        for key in keys {
            guard let value = defaults.object(forKey: key) else { continue }
            cloudStore.set(value, forKey: key)
        }
        cloudStore.synchronize()
    }

    func observeRemoteChanges(_ handler: @escaping @MainActor (_ changedKeys: Set<String>?) -> Void) {
        guard let cloudStore else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloudStore,
            queue: .main
        ) { notification in
            let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            Task { @MainActor in
                handler(keys.map(Set.init))
            }
        }
        cloudStore.synchronize()
    }

    private nonisolated static func makeCloudStoreIfAvailable() -> NSUbiquitousKeyValueStore? {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        let entitlement = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.ubiquity-kvstore-identifier" as CFString,
            nil
        )
        guard entitlement != nil else { return nil }
        #endif
        return NSUbiquitousKeyValueStore.default
    }
}
