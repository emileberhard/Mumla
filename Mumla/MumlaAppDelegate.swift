import AppKit
import Foundation

extension Notification.Name {
    static let mumlaOpenSettingsRequested = Notification.Name("MumlaOpenSettingsRequested")
}

final class MumlaAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { FlowCoordinator.shared.dataStore.handleAgentURL(url) }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        FlowCoordinator.shared.dataStore.fetchRemoteChanges()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        AppDiagnostics.info(
            "Received app reopen request",
            category: "lifecycle",
            metadata: ["hasVisibleWindows": String(hasVisibleWindows)]
        )
        NotificationCenter.default.post(name: .mumlaOpenSettingsRequested, object: sender)
        return false
    }
}
