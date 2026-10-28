import Foundation
import os
import Sentry

/// Crash reporting and diagnostics for the app and the keyboard extension.
/// Reports to the same Sentry project as the macOS app; events are
/// distinguished by release (bundle ID) and the `process` tag.
nonisolated enum CrashReporting {
    private static let dsn = "https://792ca3680d241b3eb52958d0dc0fffca@o4507843025305601.ingest.de.sentry.io/4511274815914064"
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "emileberhard.WisprClone.ios",
        category: "Diagnostics"
    )

    static func bootstrap(process: String) {
        let environment = isDebugBuild ? "ios-debug" : "ios-release"
        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = environment
            options.attachStacktrace = true
            DiagnosticPrivacy.configure(options, tags: [:])
            options.enableLogs = true
            // Keyboard extensions run under a tight memory ceiling; keep the
            // SDK lean and skip tracing/profiling in both processes.
            options.tracesSampleRate = 0
            if process == "keyboard" {
                options.enableAppHangTracking = false
                // iOS kills keyboard extensions routinely; the SDK's unclean-exit
                // heuristic would report those as watchdog terminations.
                options.enableWatchdogTerminationTracking = false
            }
        }
        SentrySDK.configureScope { scope in
            scope.setTag(value: process, key: "process")
        }
        breadcrumb(
            "Crash reporting bootstrapped",
            category: "diagnostics",
            metadata: [
                "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
                "bundle_id": Bundle.main.bundleIdentifier ?? "unknown",
                "environment": environment,
                "app_hang_tracking": process == "keyboard" ? "disabled" : "enabled",
                "watchdog_tracking": process == "keyboard" ? "disabled" : "enabled",
                "process": process,
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            ]
        )
    }

    static func capture(
        message: StaticString,
        context: String,
        error: Error? = nil,
        metadata: [String: String] = [:]
    ) {
        let event = DiagnosticEvent(message: message, metadata: metadata, error: error)
        let message = event.message
        let metadata = event.metadata
        logger.error("\(context, privacy: .public): \(message, privacy: .public) \(metadata.description, privacy: .public)")
        SentrySDK.logger.error(message, attributes: logAttributes(metadata, category: context))
        if let error = event.error {
            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: context, key: "context")
                scope.setExtra(value: message, key: "message")
                setExtras(metadata, on: scope)
            }
        } else {
            SentrySDK.capture(message: message) { scope in
                scope.setTag(value: context, key: "context")
                setExtras(metadata, on: scope)
            }
        }
    }

    static func breadcrumb(
        _ message: StaticString,
        category: String,
        metadata: [String: String] = [:]
    ) {
        let message = message.description
        logger.notice("\(category, privacy: .public): \(message, privacy: .public) \(metadata.description, privacy: .public)")
        SentrySDK.logger.info(message, attributes: logAttributes(metadata, category: category))
        let crumb = Breadcrumb()
        crumb.message = message
        crumb.category = category
        crumb.level = .info
        if !metadata.isEmpty {
            crumb.data = metadata
        }
        SentrySDK.addBreadcrumb(crumb)
    }

    private static func logAttributes(_ metadata: [String: String], category: String) -> [String: Any] {
        metadata.merging(["category": category]) { _, category in category }
    }

    private static func setExtras(_ metadata: [String: String], on scope: Scope) {
        for (key, value) in metadata.sorted(by: { $0.key < $1.key }) {
            scope.setExtra(value: value, key: "diag_\(key)")
        }
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
