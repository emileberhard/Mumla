nonisolated struct KeyboardHostRecord: Equatable, Sendable {
    let bundleIdentifier: String
    let processIdentifier: Int32
}

nonisolated enum KeyboardHostRecordPolicy {
    static func updatedRecord(
        current: KeyboardHostRecord?,
        detectedBundleIdentifier: String?,
        processIdentifier: Int32
    ) -> KeyboardHostRecord? {
        guard processIdentifier > 0 else { return nil }

        if let detectedBundleIdentifier, !detectedBundleIdentifier.isEmpty {
            return KeyboardHostRecord(
                bundleIdentifier: detectedBundleIdentifier,
                processIdentifier: processIdentifier
            )
        }

        guard current?.processIdentifier == processIdentifier else { return nil }
        return current
    }
}
