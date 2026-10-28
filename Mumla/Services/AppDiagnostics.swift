import AppKit
import Foundation
import OSLog
import Sentry

enum AppDiagnosticsLevel: String {
    case debug
    case info
    case warning
    case error
}

enum AppDiagnostics {
    static let subsystem = Bundle.main.bundleIdentifier ?? "emileberhard.WisprClone"

    private static let publicDSN = "https://792ca3680d241b3eb52958d0dc0fffca@o4507843025305601.ingest.de.sentry.io/4511274815914064"
    private static let bootstrapLock = OSAllocatedUnfairLock(initialState: false)
    private static let osLogger = Logger(subsystem: subsystem, category: "Diagnostics")
    private static let logStore = AppDiagnosticsLogStore()

    static func bootstrap() {
        let shouldBootstrap = bootstrapLock.withLock { started in
            if started {
                return false
            }
            started = true
            return true
        }

        guard shouldBootstrap else { return }

        let tags = defaultTags

        SentrySDK.start { options in
            options.dsn = publicDSN
            options.debug = false
            options.environment = isDebugBuild ? "debug" : "release"
            options.releaseName = releaseName
            options.attachStacktrace = true
            DiagnosticPrivacy.configure(options, tags: tags)
            options.tracesSampleRate = 0.2
            options.configureProfiling = { @Sendable in
                $0.sessionSampleRate = 0.0
            }
        }

        configureScope()
        NetworkPathDiagnostics.shared.start()
        info(
            "Diagnostics bootstrapped",
            category: "app",
            metadata: [
                "release": releaseName,
                "environment": isDebugBuild ? "debug" : "release",
                "local_log_retention_hours": "48",
                "local_log_cleanup_interval_minutes": "60",
            ].merging(networkPathMetadata()) { _, new in new }
        )

        Task {
            await logStore.startRetentionCleanup()
        }
    }

    static func debug(_ message: StaticString, category: String, metadata: [String: String] = [:]) {
        record(level: .debug, message: message.description, category: category, metadata: metadata)
    }

    static func info(_ message: StaticString, category: String, metadata: [String: String] = [:]) {
        record(level: .info, message: message.description, category: category, metadata: metadata)
    }

    static func warning(_ message: StaticString, category: String, metadata: [String: String] = [:]) {
        record(level: .warning, message: message.description, category: category, metadata: metadata)
    }

    static func error(
        _ message: StaticString,
        category: String,
        metadata: [String: String] = [:],
        error: Error? = nil
    ) {
        let event = DiagnosticEvent(
            message: message,
            metadata: networkPathMetadata().merging(metadata) { _, new in new },
            error: error
        )
        let message = event.message
        let diagnosticMetadata = event.metadata
        record(level: .error, message: message, category: category, metadata: diagnosticMetadata)

        if let error = event.error {
            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: category, key: "diagnostics.category")
                diagnosticMetadata.forEach { scope.setExtra(value: $0.value, key: $0.key) }
            }
        } else {
            SentrySDK.capture(message: message) { scope in
                scope.setTag(value: category, key: "diagnostics.category")
                diagnosticMetadata.forEach { scope.setExtra(value: $0.value, key: $0.key) }
            }
        }
    }

    static func setTag(_ key: String, value: String) {
        SentrySDK.configureScope { scope in
            scope.setTag(value: value, key: key)
        }
        osLogger.debug("[tags] Updated tag \(key, privacy: .public)=\(value, privacy: .public)")
    }

    static func openLogsFolder() {
        let url = logStore.folderURL
        Task {
            await logStore.ensurePrepared()
            await MainActor.run {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    static func copyRecentDiagnostics() {
        Task {
            let text = await logStore.recentText(maxLines: 1_000)
            await MainActor.run {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        }
    }

    static func networkPathMetadata() -> [String: String] {
        NetworkPathDiagnostics.shared.currentMetadata()
    }

    private static func record(
        level: AppDiagnosticsLevel,
        message: String,
        category: String,
        metadata: [String: String]
    ) {
        let rendered = render(message: message, metadata: metadata)

        switch level {
        case .debug:
            osLogger.debug("[\(category, privacy: .public)] \(rendered, privacy: .public)")
        case .info:
            osLogger.info("[\(category, privacy: .public)] \(rendered, privacy: .public)")
        case .warning:
            osLogger.warning("[\(category, privacy: .public)] \(rendered, privacy: .public)")
        case .error:
            osLogger.error("[\(category, privacy: .public)] \(rendered, privacy: .public)")
        }

        if shouldAddBreadcrumb(level: level) {
            let breadcrumb = Breadcrumb()
            breadcrumb.level = sentryLevel(for: level)
            breadcrumb.category = category
            breadcrumb.type = "debug"
            breadcrumb.message = message
            breadcrumb.data = metadata.isEmpty ? nil : metadata
            SentrySDK.addBreadcrumb(breadcrumb)
        }

        if shouldPersistToLocalLog(level: level) {
            Task {
                await logStore.append(
                    timestamp: Date(),
                    level: level,
                    category: category,
                    message: message,
                    metadata: metadata
                )
            }
        }
    }

    private static func render(message: String, metadata: [String: String]) -> String {
        guard !metadata.isEmpty else { return message }
        let suffix = metadata
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        return "\(message) \(suffix)"
    }

    private static func sentryLevel(for level: AppDiagnosticsLevel) -> SentryLevel {
        switch level {
        case .debug:
            .debug
        case .info:
            .info
        case .warning:
            .warning
        case .error:
            .error
        }
    }

    private static func shouldAddBreadcrumb(level: AppDiagnosticsLevel) -> Bool {
        level != .debug
    }

    private static func shouldPersistToLocalLog(level: AppDiagnosticsLevel) -> Bool {
        level != .debug
    }

    private static func configureScope() {
        SentrySDK.configureScope { scope in
            defaultTags.forEach { scope.setTag(value: $0.value, key: $0.key) }
        }
    }

    private static var defaultTags: [String: String] {
        [
            "bundle_id": subsystem,
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build_number": Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "unknown",
        ]
    }

    private static var releaseName: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "unknown"
        return "\(subsystem)@\(version)+\(build)"
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}

actor AppDiagnosticsLogStore {
    let folderURL: URL

    private let fileURL: URL
    private let dateFormatter: ISO8601DateFormatter
    private let fallbackLogger = Logger(subsystem: "emileberhard.WisprClone", category: "Diagnostics")
    private let maximumFileSizeBytes = 5_000_000
    private let maxRotations = 10
    private let logRetentionAgeSeconds: TimeInterval = 48 * 60 * 60
    private let logRetentionCleanupInterval: Duration = .seconds(60 * 60)
    private var isPrepared = false
    private var retentionCleanupTask: Task<Void, Never>?

    init(fileManager: FileManager = .default) {
        let libraryURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        self.folderURL = libraryURL
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("WisprClone", isDirectory: true)
        self.fileURL = folderURL.appendingPathComponent("diagnostics.log", isDirectory: false)
        self.dateFormatter = ISO8601DateFormatter()
        self.dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func ensurePrepared() async {
        guard !isPrepared else { return }

        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path()) {
                let didCreateFile = FileManager.default.createFile(atPath: fileURL.path(), contents: Data())
                guard didCreateFile || FileManager.default.fileExists(atPath: fileURL.path()) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            isPrepared = true
        } catch {
            fallbackLogger.error("Failed to prepare diagnostics directory: \(DiagnosticError(error).metadata.description, privacy: .public)")
        }
    }

    func append(
        timestamp: Date,
        level: AppDiagnosticsLevel,
        category: String,
        message: String,
        metadata: [String: String]
    ) async {
        await ensurePrepared()
        await rotateIfNeeded()

        let metadataText = metadata
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let line = "\(dateFormatter.string(from: timestamp)) [\(level.rawValue.uppercased())] [\(category)] \(message)\(metadataText.isEmpty ? "" : " \(metadataText)")\n"

        guard let data = line.data(using: .utf8) else { return }

        do {
            let fileHandle = try FileHandle(forWritingTo: fileURL)
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: data)
            try fileHandle.close()
        } catch {
            fallbackLogger.error("Failed to append diagnostics log: \(DiagnosticError(error).metadata.description, privacy: .public)")
        }
    }

    func startRetentionCleanup() {
        guard retentionCleanupTask == nil else { return }

        retentionCleanupTask = Task {
            await self.runRetentionCleanupLoop()
        }
    }

    func recentText(maxLines: Int) async -> String {
        await ensurePrepared()

        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8)
        else {
            return "No diagnostics log available."
        }

        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(maxLines)
        return lines.joined(separator: "\n")
    }

    private func runRetentionCleanupLoop() async {
        while !Task.isCancelled {
            await pruneExpiredLogs(referenceDate: Date())

            do {
                try await Task.sleep(for: logRetentionCleanupInterval)
            } catch {
                return
            }
        }
    }

    private func pruneExpiredLogs(referenceDate: Date) async {
        await ensurePrepared()

        let cutoff = referenceDate.addingTimeInterval(-logRetentionAgeSeconds)
        var removedLines = 0
        var rewrittenFiles = 0
        var deletedFiles = 0

        do {
            for logURL in diagnosticsLogFileURLs() {
                let result = try pruneLogFile(at: logURL, cutoff: cutoff)
                removedLines += result.removedLines

                switch result.fileAction {
                case .none:
                    break
                case .rewritten:
                    rewrittenFiles += 1
                case .deleted:
                    deletedFiles += 1
                }
            }

            guard removedLines > 0 || rewrittenFiles > 0 || deletedFiles > 0 else { return }

            fallbackLogger.info(
                "Pruned diagnostics logs older than \(Int(self.logRetentionAgeSeconds / 3600), privacy: .public)h: removed_lines=\(removedLines, privacy: .public) rewritten_files=\(rewrittenFiles, privacy: .public) deleted_files=\(deletedFiles, privacy: .public)"
            )
        } catch {
            fallbackLogger.error("Failed to prune diagnostics logs: \(DiagnosticError(error).metadata.description, privacy: .public)")
        }
    }

    private func rotateIfNeeded() async {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path())
        let currentSize = attributes?[.size] as? NSNumber
        guard currentSize?.intValue ?? 0 > maximumFileSizeBytes else { return }

        do {
            for index in stride(from: maxRotations, through: 1, by: -1) {
                let source = rotatedFileURL(index: index)
                let destination = rotatedFileURL(index: index + 1)
                if FileManager.default.fileExists(atPath: destination.path()) {
                    try? FileManager.default.removeItem(at: destination)
                }
                if FileManager.default.fileExists(atPath: source.path()) {
                    try FileManager.default.moveItem(at: source, to: destination)
                }
            }

            let firstRotation = rotatedFileURL(index: 1)
            if FileManager.default.fileExists(atPath: firstRotation.path()) {
                try? FileManager.default.removeItem(at: firstRotation)
            }
            try FileManager.default.moveItem(at: fileURL, to: firstRotation)
            FileManager.default.createFile(atPath: fileURL.path(), contents: nil)
        } catch {
            fallbackLogger.error("Failed to rotate diagnostics log: \(DiagnosticError(error).metadata.description, privacy: .public)")
        }
    }

    private func rotatedFileURL(index: Int) -> URL {
        folderURL.appendingPathComponent("diagnostics.\(index).log")
    }

    private func diagnosticsLogFileURLs() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil
        )) ?? []

        return contents
            .filter(isDiagnosticsLogFile)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func isDiagnosticsLogFile(_ url: URL) -> Bool {
        let fileName = url.lastPathComponent
        guard fileName != "diagnostics.log" else { return true }
        guard fileName.hasPrefix("diagnostics."), fileName.hasSuffix(".log") else { return false }

        let rotationStart = fileName.index(fileName.startIndex, offsetBy: "diagnostics.".count)
        let rotationEnd = fileName.index(fileName.endIndex, offsetBy: -".log".count)
        return Int(fileName[rotationStart..<rotationEnd]) != nil
    }

    private func pruneLogFile(at url: URL, cutoff: Date) throws -> LogPruneResult {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return LogPruneResult(removedLines: 0, fileAction: .none) }
        guard let text = String(data: data, encoding: .utf8) else {
            return LogPruneResult(removedLines: 0, fileAction: .none)
        }

        var keptLines: [String] = []
        var removedLines = 0
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        for (index, line) in lines.enumerated() {
            if index == lines.count - 1, line.isEmpty, text.hasSuffix("\n") {
                continue
            }

            if shouldKeepLogLine(String(line), cutoff: cutoff) {
                keptLines.append(String(line))
            } else {
                removedLines += 1
            }
        }

        guard removedLines > 0 else { return LogPruneResult(removedLines: 0, fileAction: .none) }

        if keptLines.isEmpty, url != fileURL {
            try FileManager.default.removeItem(at: url)
            return LogPruneResult(removedLines: removedLines, fileAction: .deleted)
        }

        let prunedText = keptLines.isEmpty ? "" : keptLines.joined(separator: "\n") + "\n"
        try Data(prunedText.utf8).write(to: url, options: .atomic)
        return LogPruneResult(removedLines: removedLines, fileAction: .rewritten)
    }

    private func shouldKeepLogLine(_ line: String, cutoff: Date) -> Bool {
        guard let timestamp = timestamp(fromLogLine: line) else { return true }
        return timestamp >= cutoff
    }

    private func timestamp(fromLogLine line: String) -> Date? {
        guard let separatorIndex = line.firstIndex(of: " ") else { return nil }
        let timestampText = String(line[..<separatorIndex])
        return dateFormatter.date(from: timestampText)
    }
}

private struct LogPruneResult {
    let removedLines: Int
    let fileAction: LogPruneFileAction
}

private enum LogPruneFileAction {
    case none
    case rewritten
    case deleted
}
