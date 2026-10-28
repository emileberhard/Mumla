import Foundation
import Sentry

nonisolated enum DiagnosticPrivacy {
    static func configure(_ options: Options, tags: [String: String]) {
        options.sendDefaultPii = false
        options.enableAutoSessionTracking = false
        options.cacheDirectoryPath = (options.cacheDirectoryPath as NSString)
            .appendingPathComponent("MumlaUnlinkedDiagnostics")
        // Sentry invokes this from its own threads (e.g. the app-hang
        // tracker). It must not inherit MainActor isolation or the
        // runtime isolation check traps and crashes the app.
        options.beforeSend = { @Sendable event in
            event.tags = (event.tags ?? [:]).merging(tags) { _, new in new }
            event.user = nil
            event.context?["app"]?.removeValue(forKey: "device_app_hash")
            return event
        }
        options.beforeSendLog = { @Sendable log in
            log.attributes.removeValue(forKey: "user.id")
            return log
        }
    }
}
