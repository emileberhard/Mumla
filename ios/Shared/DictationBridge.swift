import Foundation

/// Cross-process contract between the main app and the keyboard extension.
/// State flows through App Group UserDefaults; wake-ups flow through Darwin notifications.
nonisolated enum DictationBridge {
    // NB: lowercase — must match the portal-registered App Group ID exactly
    // (provisioning profiles only carry the lowercase form).
    static let appGroupID = "group.emileberhard.wisprclone"

    /// Darwin notification names (global namespace, so they carry the bundle prefix).
    enum Event {
        static let startRequested = "emileberhard.WisprClone.dictation.startRequested"
        static let stopRequested = "emileberhard.WisprClone.dictation.stopRequested"
        static let cancelRequested = "emileberhard.WisprClone.dictation.cancelRequested"
        static let stateChanged = "emileberhard.WisprClone.dictation.stateChanged"
    }

    enum Command: String {
        case start
        case stop
        case cancel

        fileprivate var recordKey: String { "dictation.command.\(rawValue)" }
        fileprivate var consumedKey: String { "dictation.command.\(rawValue).consumed" }
    }

    static func consumeCommand(_ command: Command, defaults: UserDefaults, now: Date) -> Bool {
        guard let record = defaults.dictionary(forKey: command.recordKey),
              let id = record["id"] as? String,
              UUID(uuidString: id) != nil,
              let timestamp = record["timestamp"] as? TimeInterval,
              defaults.string(forKey: command.consumedKey) != id else { return false }
        let age = now.timeIntervalSince1970 - timestamp
        guard age >= 0, age < 5 else { return false }
        defaults.set(id, forKey: command.consumedKey)
        defaults.synchronize()
        return true
    }

    static func writeCommand(_ command: Command, defaults: UserDefaults, now: Date) {
        defaults.set([
            "id": UUID().uuidString,
            "timestamp": now.timeIntervalSince1970,
        ], forKey: command.recordKey)
        defaults.synchronize()
    }

    enum DefaultsKey {
        static let phase = "dictation.phase"
        static let recordingStartTimestamp = "dictation.recordingStartTimestamp"
        static let recordingDeadlineTimestamp = "dictation.recordingDeadlineTimestamp"
        static let audioLevel = "dictation.audioLevel"
        static let heartbeat = "app.heartbeatTimestamp"
        static let appIsBackgrounded = "app.isBackgrounded"
        static let sessionActive = "session.active"
        static let sessionEndTimestamp = "session.endTimestamp"
        static let transcriptID = "dictation.transcript.id"
        static let transcriptText = "dictation.transcript.text"
        static let transcriptTimestamp = "dictation.transcript.timestamp"
        static let transcriptInsertedID = "dictation.transcript.insertedID"
        static let recentTranscripts = "dictation.recentTranscripts"
        static let errorMessage = "dictation.errorMessage"
        static let accessState = "access.state"
        static let accessResetTimestamp = "access.resetTimestamp"
        static let keyboardLaunchIntentTimestamp = "keyboard.launchIntent.timestamp"
        static let automaticStartHapticTimestamp = "keyboard.automaticStartHaptic.timestamp"
        static let keyboardLastActiveTimestamp = "keyboard.lastActive.timestamp"
        /// Host that owns `keyboardHostProcessIdentifier`. Kept in the App Group
        /// rather than on the keyboard controller because iOS replaces that
        /// controller while the extension process lives on.
        static let keyboardHostBundleIdentifier = "keyboard.host.bundleIdentifier"
        static let keyboardHostProcessIdentifier = "keyboard.host.processIdentifier"
        static let transcriptOwnerID = "keyboard.transcriptOwner.id"
        static let transcriptOwnerReason = "keyboard.transcriptOwner.reason"
        static let transcriptOwnerTimestamp = "keyboard.transcriptOwner.timestamp"
        #if DEBUG
        /// Debug-only host-detection probe records, newest first.
        static let hostProbeLog = "keyboard.hostProbe.log"
        #endif
    }

    /// Deep link the keyboard opens to make the user foreground the app and
    /// start a dictation session (iOS requires the app to be opened to
    /// activate the microphone; the user then swipes back to the host app).
    static let startSessionURL = URL(string: "mumla://dictation/start")!

    /// Deep link the keyboard opens to show transcription history in the app.
    static let historyURL = URL(string: "mumla://history")!

    /// The main app refreshes its heartbeat every second while running and
    /// zeroes it from willTerminate (force quit during an active session keeps
    /// the app running, so iOS delivers the callback → instant detection).
    /// The stale window only matters for hard crashes, where no callback runs.
    static let heartbeatInterval: TimeInterval = 1
    static let heartbeatStaleAfter: TimeInterval = 3

    /// Transcripts older than this are never auto-inserted by the keyboard.
    static let transcriptFreshnessWindow: TimeInterval = 30

    static let keyboardInsertionReportDelay: TimeInterval = 5

    /// Small enough for the native keyboard menu while retaining useful context.
    static let recentTranscriptLimit = 5

    /// Keyboard launch intent markers are short-lived touch-down hints. The app
    /// reads them to show its return guidance; the keyboard consumes them when
    /// it reappears and the session is ready.
    static let keyboardLaunchIntentFreshnessWindow: TimeInterval = 10

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static var appIsBackgrounded: Bool {
        sharedDefaults?.bool(forKey: DefaultsKey.appIsBackgrounded) ?? false
    }

    static func setRecentTranscripts(_ transcripts: [String]) {
        guard let defaults = sharedDefaults else { return }
        defaults.set(Array(transcripts.prefix(recentTranscriptLimit)), forKey: DefaultsKey.recentTranscripts)
        defaults.synchronize()
    }

    static func setAppIsBackgrounded(_ isBackgrounded: Bool) {
        guard let defaults = sharedDefaults else { return }
        defaults.set(isBackgrounded, forKey: DefaultsKey.appIsBackgrounded)
        defaults.synchronize()
        DarwinNotifications.post(Event.stateChanged)
    }

    static func isStartSessionURL(_ url: URL) -> Bool {
        url.scheme == startSessionURL.scheme
            && url.host == startSessionURL.host
            && url.path == startSessionURL.path
    }

    static func isHistoryURL(_ url: URL) -> Bool {
        url.scheme == historyURL.scheme
            && url.host == historyURL.host
            && url.path == historyURL.path
    }

    /// Stamped by the keyboard on every appearance. iOS has no public
    /// "is my keyboard enabled" API, and only a Full Access keyboard can
    /// write to the App Group — so a stamp means enabled with Full Access.
    static func recordKeyboardActive(now: Date = Date()) {
        guard let defaults = sharedDefaults else { return }
        defaults.set(now.timeIntervalSince1970, forKey: DefaultsKey.keyboardLastActiveTimestamp)
        defaults.synchronize()
    }

    static var keyboardLastActive: Date? {
        guard let defaults = sharedDefaults else { return nil }
        let timestamp = defaults.double(forKey: DefaultsKey.keyboardLastActiveTimestamp)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    static var keyboardHasBeenActive: Bool {
        keyboardLastActive != nil
    }

    /// Records which app owns the keyboard right now. Host identity resolves
    /// only intermittently — the arbiter names SpringBoard, or nothing, while
    /// the App Switcher or Home Screen has been on screen — so a good reading
    /// is kept against the host process ID and reused until that process
    /// changes. A failed reading under a *different* process ID clears the
    /// record instead of leaving the previous host's name in place, so the app
    /// never returns to an app the keyboard has already left.
    static func rememberKeyboardHost(bundleIdentifier: String?, processIdentifier: Int32) {
        guard let defaults = sharedDefaults else { return }

        let updatedRecord = KeyboardHostRecordPolicy.updatedRecord(
            current: keyboardHostRecord(in: defaults),
            detectedBundleIdentifier: bundleIdentifier,
            processIdentifier: processIdentifier
        )
        if let updatedRecord {
            defaults.set(
                updatedRecord.bundleIdentifier,
                forKey: DefaultsKey.keyboardHostBundleIdentifier
            )
            defaults.set(
                Int(updatedRecord.processIdentifier),
                forKey: DefaultsKey.keyboardHostProcessIdentifier
            )
        } else {
            defaults.removeObject(forKey: DefaultsKey.keyboardHostBundleIdentifier)
            defaults.removeObject(forKey: DefaultsKey.keyboardHostProcessIdentifier)
        }
        defaults.synchronize()
    }

    /// App-side read for the launch handoff. The app cannot see the keyboard's
    /// host process, so it trusts the keyboard's own answer: the record is
    /// either the host that was on screen at launch, or absent.
    static var rememberedKeyboardHost: String? {
        guard let defaults = sharedDefaults else { return nil }
        return keyboardHostRecord(in: defaults)?.bundleIdentifier
    }

    private static func keyboardHostRecord(in defaults: UserDefaults) -> KeyboardHostRecord? {
        guard let bundleIdentifier = defaults.string(
            forKey: DefaultsKey.keyboardHostBundleIdentifier
        ), !bundleIdentifier.isEmpty,
        let processIdentifier = Int32(
            exactly: defaults.integer(forKey: DefaultsKey.keyboardHostProcessIdentifier)
        ), processIdentifier > 0
        else {
            return nil
        }

        return KeyboardHostRecord(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: processIdentifier
        )
    }

    static func markKeyboardLaunchIntent(now: Date = Date()) {
        guard let defaults = sharedDefaults else { return }
        defaults.set(now.timeIntervalSince1970, forKey: DefaultsKey.keyboardLaunchIntentTimestamp)
        defaults.synchronize()
    }

    /// Read before the handoff is acted on, so a skipped switchback says why.
    static func keyboardHostDiagnostics(now: Date = Date()) -> [String: String] {
        guard let defaults = sharedDefaults else { return ["defaults": "unavailable"] }

        let lastActive = defaults.double(forKey: DefaultsKey.keyboardLastActiveTimestamp)
        return [
            "remembered_host": defaults.string(forKey: DefaultsKey.keyboardHostBundleIdentifier) ?? "unset",
            "remembered_host_pid": String(defaults.integer(forKey: DefaultsKey.keyboardHostProcessIdentifier)),
            "keyboard_last_active_age": lastActive > 0
                ? String(format: "%.3f", now.timeIntervalSince1970 - lastActive)
                : "unset",
        ]
    }

    static func keyboardTranscriptDiagnostics(transcriptID: String, now: Date = Date()) -> [String: String] {
        guard let defaults = sharedDefaults else { return ["defaults": "unavailable"] }

        let ownerTimestamp = defaults.double(forKey: DefaultsKey.transcriptOwnerTimestamp)
        let transcriptTimestamp = defaults.double(forKey: DefaultsKey.transcriptTimestamp)
        return keyboardHostDiagnostics(now: now).merging([
            "transcript_current": (defaults.string(forKey: DefaultsKey.transcriptID) == transcriptID).description,
            "transcript_inserted": (defaults.string(forKey: DefaultsKey.transcriptInsertedID) == transcriptID).description,
            "transcript_age": transcriptTimestamp > 0
                ? String(format: "%.3f", now.timeIntervalSince1970 - transcriptTimestamp)
                : "unset",
            "transcript_owner": defaults.string(forKey: DefaultsKey.transcriptOwnerID) ?? "unset",
            "transcript_owner_reason": defaults.string(forKey: DefaultsKey.transcriptOwnerReason) ?? "unset",
            "transcript_owner_age": ownerTimestamp > 0
                ? String(format: "%.3f", now.timeIntervalSince1970 - ownerTimestamp)
                : "unset",
        ]) { _, new in new }
    }

    static func hasFreshKeyboardLaunchIntent(now: Date = Date()) -> Bool {
        guard let defaults = sharedDefaults else { return false }

        let timestamp = defaults.double(forKey: DefaultsKey.keyboardLaunchIntentTimestamp)
        guard timestamp > 0 else { return false }

        let age = now.timeIntervalSince1970 - timestamp
        return age >= 0 && age < keyboardLaunchIntentFreshnessWindow
    }

    static func consumeKeyboardLaunchIntent(now: Date = Date()) -> Bool {
        guard let defaults = sharedDefaults else { return false }
        defer {
            defaults.removeObject(forKey: DefaultsKey.keyboardLaunchIntentTimestamp)
            defaults.synchronize()
        }

        return hasFreshKeyboardLaunchIntent(now: now)
    }

    static func markAutomaticStartHapticPending(now: Date = Date()) {
        guard let defaults = sharedDefaults else { return }
        defaults.set(now.timeIntervalSince1970, forKey: DefaultsKey.automaticStartHapticTimestamp)
        defaults.synchronize()
    }

    static func hasFreshAutomaticStartHapticPending(
        now: Date = Date(),
        defaults: UserDefaults? = sharedDefaults
    ) -> Bool {
        guard let defaults else { return false }

        let timestamp = defaults.double(forKey: DefaultsKey.automaticStartHapticTimestamp)
        guard timestamp > 0 else { return false }

        let age = now.timeIntervalSince1970 - timestamp
        return age >= 0 && age < keyboardLaunchIntentFreshnessWindow
    }

    static func clearAutomaticStartHapticPending() {
        guard let defaults = sharedDefaults else { return }
        defaults.removeObject(forKey: DefaultsKey.automaticStartHapticTimestamp)
        defaults.synchronize()
    }
}

nonisolated enum KeyboardAccessState: Equatable, Sendable {
    case checking
    case available
    case allowanceSpent(resetsAt: Date)
    case iCloudSignedOut
    case iCloudUnavailable
    case serviceUnavailable

    func write(to defaults: UserDefaults) {
        let (name, resetsAt): (String, Date?) = switch self {
        case .checking: ("checking", nil)
        case .available: ("available", nil)
        case .allowanceSpent(let date): ("allowanceSpent", date)
        case .iCloudSignedOut: ("iCloudSignedOut", nil)
        case .iCloudUnavailable: ("iCloudUnavailable", nil)
        case .serviceUnavailable: ("serviceUnavailable", nil)
        }
        defaults.set(name, forKey: DictationBridge.DefaultsKey.accessState)
        defaults.set(resetsAt?.timeIntervalSince1970 ?? 0, forKey: DictationBridge.DefaultsKey.accessResetTimestamp)
    }

    init(defaults: UserDefaults) {
        let resetsAt = Date(timeIntervalSince1970: defaults.double(forKey: DictationBridge.DefaultsKey.accessResetTimestamp))
        self = switch defaults.string(forKey: DictationBridge.DefaultsKey.accessState) {
        case "available": .available
        case "allowanceSpent": .allowanceSpent(resetsAt: resetsAt)
        case "iCloudSignedOut": .iCloudSignedOut
        case "iCloudUnavailable": .iCloudUnavailable
        case "serviceUnavailable": .serviceUnavailable
        default: .checking
        }
    }

    func blocksDictation(now: Date = Date()) -> Bool {
        switch self {
        case .allowanceSpent(let resetsAt): now < resetsAt
        case .iCloudSignedOut, .iCloudUnavailable: true
        case .checking, .available, .serviceUnavailable: false
        }
    }
}

nonisolated enum DictationPhase: String, Sendable {
    case idle
    case recording
    case processing
    case success
    case error
}
