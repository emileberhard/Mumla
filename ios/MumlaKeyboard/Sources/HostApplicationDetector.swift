import UIKit

enum HostApplicationDetector {
    static func detect(for controller: UIInputViewController) -> String? {
        WCResolveHostBundleIdentifier(controller)
    }

    static func hostProcessIdentifier(for controller: UIInputViewController) -> Int32 {
        WCResolveHostProcessIdentifier(controller)
    }

    #if DEBUG
    /// Runs every host-identity strategy and appends one App Group record per
    /// keyboard appearance, so the containing app can rank them on this OS.
    static func recordProbe(
        for controller: UIInputViewController,
        resolvedBundleIdentifier: String?
    ) {
        let results = WCProbeHostBundleIdentifiers(controller, resolvedBundleIdentifier)
        let ordered = results.keys.sorted()
            .map { "\($0)=\(results[$0] ?? "")" }
            .joined(separator: "\n")
        let entry = "[\(Self.timestamp)]\n\(ordered)"

        NSLog("[MumlaHostProbe]\n%@", entry)

        guard let defaults = DictationBridge.sharedDefaults else { return }
        var log = defaults.stringArray(forKey: DictationBridge.DefaultsKey.hostProbeLog) ?? []
        log.insert(entry, at: 0)
        defaults.set(
            Array(log.prefix(20)),
            forKey: DictationBridge.DefaultsKey.hostProbeLog
        )
        // The tap that opens the app suspends this process moments later; an
        // unflushed write would drop exactly the record worth reading.
        defaults.synchronize()
    }

    private static var timestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
    #endif
}
