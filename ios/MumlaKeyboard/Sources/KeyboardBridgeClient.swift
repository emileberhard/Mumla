import Foundation
import Observation

/// Keyboard-side view of the dictation bridge: mirrors the main app's
/// published state and forwards start/stop/cancel commands.
@MainActor
@Observable
final class KeyboardBridgeClient {
    enum OwnershipReason: String {
        case appeared
        case startRequested = "start_requested"
        case stopRequested = "stop_requested"
    }

    private(set) var phase: DictationPhase = .idle
    private(set) var appPhase: DictationPhase = .idle
    private(set) var recordingStartDate: Date?
    private(set) var recordingDeadline: Date?
    private(set) var appIsAlive = false
    private(set) var appIsBackgrounded = false
    private(set) var sessionActive = false
    private(set) var audioLevel: Double = 0
    private(set) var errorMessage = ""
    private(set) var access: KeyboardAccessState = .checking
    private(set) var recentTranscripts: [String] = []
    var hasFullAccess = false
    var needsInputModeSwitchKey = true

    /// Inserts each fresh transcript at most once while this keyboard owns
    /// transcripts; returning false leaves the transcript uninserted.
    var onTranscript: ((String) -> Bool)?

    let clientID = String(UUID().uuidString.prefix(8))

    private static var activeClientCount = 0

    private let sharedDefaults: UserDefaults?
    private var isActive = false
    private var stateObserver: DarwinNotificationObserver?
    private var levelTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var reportedDeliveryDecision: String?

    init(sharedDefaults: UserDefaults? = DictationBridge.sharedDefaults) {
        self.sharedDefaults = sharedDefaults
    }

    var canDictateNow: Bool {
        hasFullAccess && appIsAlive && sessionActive && !accessBlocksDictation
    }

    var accessBlocksDictation: Bool {
        appIsAlive && access.blocksDictation()
    }

#if DEBUG
    func applyPreviewSnapshot(_ snapshot: KeyboardPreviewSnapshot) {
        phase = snapshot.phase
        appPhase = snapshot.phase
        recordingStartDate = snapshot.phase == .recording ? Date() : nil
        appIsAlive = snapshot.appIsAlive
        sessionActive = snapshot.sessionActive
        audioLevel = snapshot.audioLevel
        errorMessage = snapshot.errorMessage
        access = snapshot.access
        hasFullAccess = snapshot.hasFullAccess
        needsInputModeSwitchKey = snapshot.needsInputModeSwitchKey
    }
#endif

    func activate() {
        if !isActive {
            isActive = true
            Self.activeClientCount += 1
            reportLifecycle("Keyboard bridge activated")
        }
        if stateObserver == nil {
            stateObserver = DarwinNotificationObserver(name: DictationBridge.Event.stateChanged) { [weak self] in
                self?.refresh()
            }
        }
        refresh()
        // The app can die (force quit, crash) without a final state
        // notification; poll the heartbeat so the UI flips back to
        // "Start Session" instead of leaving a dead mic key.
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func deactivate() {
        if isActive {
            isActive = false
            Self.activeClientCount -= 1
            reportLifecycle("Keyboard bridge deactivated")
        }
        stateObserver = nil
        refreshTask?.cancel()
        refreshTask = nil
        levelTask?.cancel()
        levelTask = nil
        appPhase = .idle
        publishPhase(.idle)
    }

    func claimTranscripts(_ reason: OwnershipReason) {
        guard isActive, hasFullAccess, let defaults = sharedDefaults else { return }

        let previousOwner = defaults.string(forKey: DictationBridge.DefaultsKey.transcriptOwnerID)
        defaults.set(clientID, forKey: DictationBridge.DefaultsKey.transcriptOwnerID)
        defaults.set(reason.rawValue, forKey: DictationBridge.DefaultsKey.transcriptOwnerReason)
        defaults.set(Date().timeIntervalSince1970, forKey: DictationBridge.DefaultsKey.transcriptOwnerTimestamp)
        defaults.synchronize()
        if previousOwner != clientID {
            CrashReporting.breadcrumb(
                "Keyboard took transcript ownership",
                category: "keyboard_delivery",
                metadata: deliveryMetadata([
                    "previous_owner": previousOwner ?? "none",
                    "reason": reason.rawValue,
                ])
            )
        }
        refresh()
    }

    func requestStart() {
        claimTranscripts(.startRequested)
        guard let defaults = sharedDefaults else { return }
        DictationBridge.writeCommand(.start, defaults: defaults, now: Date())
        DarwinNotifications.post(DictationBridge.Event.startRequested)
    }

    func requestStop() {
        claimTranscripts(.stopRequested)
        guard let defaults = sharedDefaults else { return }
        DictationBridge.writeCommand(.stop, defaults: defaults, now: Date())
        DarwinNotifications.post(DictationBridge.Event.stopRequested)
    }

    func requestCancel() {
        guard let defaults = sharedDefaults else { return }
        DictationBridge.writeCommand(.cancel, defaults: defaults, now: Date())
        DarwinNotifications.post(DictationBridge.Event.cancelRequested)
    }

    func prepareForStartSessionLaunch() {
        guard hasFullAccess else { return }
        DictationBridge.markKeyboardLaunchIntent()
    }

    func requestStartAfterSessionLaunchIfNeeded() -> Bool {
        guard canDictateNow, DictationBridge.consumeKeyboardLaunchIntent() else { return false }
        DictationBridge.markAutomaticStartHapticPending()
        requestStart()
        return true
    }

    func refresh() {
        // Queued notifications and automatic-start tasks can outlive the visible controller.
        guard isActive else { return }
        guard hasFullAccess, let defaults = sharedDefaults else {
            appIsAlive = false
            appIsBackgrounded = false
            sessionActive = false
            appPhase = .idle
            recordingStartDate = nil
            recordingDeadline = nil
            recentTranscripts = []
            publishPhase(.idle)
            return
        }

        let heartbeat = defaults.double(forKey: DictationBridge.DefaultsKey.heartbeat)
        appIsAlive = Date().timeIntervalSince1970 - heartbeat < DictationBridge.heartbeatStaleAfter
        appIsBackgrounded = appIsAlive && defaults.bool(forKey: DictationBridge.DefaultsKey.appIsBackgrounded)
        sessionActive = defaults.bool(forKey: DictationBridge.DefaultsKey.sessionActive) && appIsAlive
        // An app killed mid-dictation (force quit, crash, reinstall) leaves
        // its last phase behind in shared defaults; trusting a stale
        // `.recording` would run the recording UI and the dictation haptic
        // texture while the keyboard is actually idle.
        appPhase = appIsAlive
            ? DictationPhase(
                rawValue: defaults.string(forKey: DictationBridge.DefaultsKey.phase) ?? ""
            ) ?? .idle
            : .idle
        let recordingStart = defaults.double(forKey: DictationBridge.DefaultsKey.recordingStartTimestamp)
        recordingStartDate = appPhase == .recording && recordingStart > 0
            ? Date(timeIntervalSince1970: recordingStart)
            : nil
        let deadline = defaults.double(forKey: DictationBridge.DefaultsKey.recordingDeadlineTimestamp)
        recordingDeadline = recordingStartDate != nil && deadline > 0
            ? Date(timeIntervalSince1970: deadline)
            : nil
        let displayedPhase: DictationPhase = if appPhase == .recording,
                                                DictationBridge.hasFreshAutomaticStartHapticPending(defaults: defaults) {
            .idle
        } else {
            appPhase
        }
        publishPhase(displayedPhase)
        errorMessage = defaults.string(forKey: DictationBridge.DefaultsKey.errorMessage) ?? ""
        access = KeyboardAccessState(defaults: defaults)
        recentTranscripts = Array(
            (defaults.stringArray(forKey: DictationBridge.DefaultsKey.recentTranscripts) ?? [])
                .prefix(DictationBridge.recentTranscriptLimit)
        )

        updateLevelPolling()
        deliverTranscriptIfNeeded(from: defaults)
    }

    private func deliverTranscriptIfNeeded(from defaults: UserDefaults) {
        guard let onTranscript else { return }
        let insertedID = defaults.string(forKey: DictationBridge.DefaultsKey.transcriptInsertedID)
        guard
            let id = defaults.string(forKey: DictationBridge.DefaultsKey.transcriptID),
            id != insertedID,
            let text = defaults.string(forKey: DictationBridge.DefaultsKey.transcriptText),
            !text.isEmpty
        else { return }

        let age = Date().timeIntervalSince1970 - defaults.double(forKey: DictationBridge.DefaultsKey.transcriptTimestamp)
        // Never insert stale text into whatever field happens to be focused now.
        guard age < DictationBridge.transcriptFreshnessWindow else { return }

        let owner = defaults.string(forKey: DictationBridge.DefaultsKey.transcriptOwnerID)
        guard owner == clientID else {
            reportDeliveryDecisionOnce("left_for_owner", transcriptID: id) {
                CrashReporting.breadcrumb(
                    "Transcript left for owning keyboard",
                    category: "keyboard_delivery",
                    metadata: deliveryMetadata(["owner": owner ?? "none", "transcript_id": id])
                )
            }
            return
        }

        defaults.set(id, forKey: DictationBridge.DefaultsKey.transcriptInsertedID)
        guard onTranscript(text) else {
            defaults.set(insertedID, forKey: DictationBridge.DefaultsKey.transcriptInsertedID)
            reportDeliveryDecisionOnce("insertion_refused", transcriptID: id) {
                CrashReporting.capture(
                    message: "Owning keyboard could not insert transcript",
                    context: "keyboard_delivery",
                    metadata: deliveryMetadata(["transcript_id": id])
                )
            }
            return
        }
        defaults.synchronize()
        CrashReporting.breadcrumb(
            "Transcript inserted",
            category: "keyboard_delivery",
            metadata: deliveryMetadata([
                "age_ms": String(Int(age * 1_000)),
                "character_count": String(text.count),
                "transcript_id": id,
            ])
        )
    }

    private func reportDeliveryDecisionOnce(_ decision: String, transcriptID: String, report: () -> Void) {
        let key = "\(transcriptID)|\(decision)"
        guard reportedDeliveryDecision != key else { return }
        reportedDeliveryDecision = key
        report()
    }

    private func reportLifecycle(_ message: StaticString) {
        CrashReporting.breadcrumb(message, category: "keyboard_delivery", metadata: deliveryMetadata())
    }

    private func deliveryMetadata(_ extra: [String: String] = [:]) -> [String: String] {
        [
            "active_bridges": String(Self.activeClientCount),
            "client": clientID,
        ].merging(extra) { _, new in new }
    }

    private func updateLevelPolling() {
        if phase == .recording {
            guard levelTask == nil else { return }
            levelTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    self.audioLevel = self.sharedDefaults?
                        .double(forKey: DictationBridge.DefaultsKey.audioLevel) ?? 0
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        } else {
            levelTask?.cancel()
            levelTask = nil
            audioLevel = 0
        }
    }

    private func publishPhase(_ newPhase: DictationPhase) {
        guard phase != newPhase else { return }
        phase = newPhase
    }
}

#if DEBUG
nonisolated struct KeyboardPreviewSnapshot: Equatable, Sendable {
    var phase: DictationPhase = .idle
    var appIsAlive = true
    var sessionActive = true
    var audioLevel: Double = 0
    var errorMessage = ""
    var access: KeyboardAccessState = .available
    var hasFullAccess = true
    var needsInputModeSwitchKey = true
}
#endif
