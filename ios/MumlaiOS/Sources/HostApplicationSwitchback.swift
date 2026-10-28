import UIKit

@MainActor
enum HostApplicationSwitchback {
    static func open(bundleIdentifier: String) async -> Bool {
        for url in HostApplicationReturnRoutes.urls(for: bundleIdentifier) {
            if await UIApplication.shared.open(url) {
                return true
            }
        }
        return false
    }
}
