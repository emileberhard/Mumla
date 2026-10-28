import Foundation

/// Darwin notifications are the only push-style IPC between the keyboard
/// extension and the containing app. They carry no payload — data goes
/// through the App Group container (see `DictationBridge`).
nonisolated enum DarwinNotifications {
    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }
}

/// Observes a single Darwin notification for the lifetime of the instance
/// and delivers callbacks on the main actor.
nonisolated final class DarwinNotificationObserver: Sendable {
    private let name: String
    private let handler: @Sendable @MainActor () -> Void

    init(name: String, handler: @escaping @Sendable @MainActor () -> Void) {
        self.name = name
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let instance = Unmanaged<DarwinNotificationObserver>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                Task { @MainActor in
                    instance.handler()
                }
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name as CFString),
            nil
        )
    }
}
