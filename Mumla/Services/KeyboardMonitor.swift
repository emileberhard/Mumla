import Cocoa
@preconcurrency import ApplicationServices
import IOKit.hid
import os
import os.lock

@MainActor
final class KeyboardMonitor {
    struct InputMonitoringStatus {
        let state: InputMonitoringPermissionState
        let detail: String
    }

    var onGlobePressed: (() -> Void)?
    var onGlobeReleased: (() -> Void)?
    var onEscapePressed: (() -> Void)?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Mumla", category: "KeyboardMonitor")

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastGlobePress: Date = .distantPast
    private var globePressTime: Date?
    private var isGlobeHeld = false
    private var isToggleMode = false
    private var holdRecordingStarted = false

    // Track state for blocking - thread-safe access from CGEvent callback
    private let fnStateLock = OSAllocatedUnfairLock(initialState: false)
    private let holdRecordingLock = OSAllocatedUnfairLock(initialState: false)
    private let shortcutModeLock = OSAllocatedUnfairLock(initialState: KeyboardShortcutMode.holdToTalk)
    private var isMonitoringRecordingKeys = false

    var shortcutMode: KeyboardShortcutMode {
        get { shortcutModeLock.withLock { $0 } }
        set {
            shortcutModeLock.withLock { $0 = newValue }
            resetShortcutState()
        }
    }

    func hasInputMonitoringPermission() -> Bool {
        let cgAllowed = CGPreflightListenEventAccess()
        let hidAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        logger.info("InputMonitoring preflight: cg=\(cgAllowed, privacy: .public) hid=\(self.describe(hidAccess), privacy: .public)")
        return cgAllowed || hidAccess == kIOHIDAccessTypeGranted
    }

    func inputMonitoringStatus() -> InputMonitoringStatus {
        let cgAllowed = CGPreflightListenEventAccess()
        let hidAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        let state: InputMonitoringPermissionState
        if cgAllowed || hidAccess == kIOHIDAccessTypeGranted {
            state = .granted
        } else if hidAccess == kIOHIDAccessTypeDenied {
            state = .denied
        } else {
            state = .unknown
        }
        let detail = "cg=\(cgAllowed ? "true" : "false") hid=\(describe(hidAccess))"
        return InputMonitoringStatus(state: state, detail: detail)
    }

    @discardableResult
    func requestInputMonitoringPermission(prompt: Bool) -> Bool {
        let cgAllowed: Bool
        let hidAllowed: Bool
        if prompt {
            logger.info("Requesting InputMonitoring permission (prompt=true)")
            cgAllowed = CGRequestListenEventAccess()
            hidAllowed = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        } else {
            logger.info("Requesting InputMonitoring permission (prompt=false)")
            cgAllowed = CGPreflightListenEventAccess()
            hidAllowed = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        }
        logger.info("InputMonitoring request result: cg=\(cgAllowed, privacy: .public) hid=\(hidAllowed, privacy: .public)")
        return cgAllowed || hidAllowed
    }

    var isRunning: Bool { eventTap != nil }

    @discardableResult
    func start() -> Bool {
        logger.info("Starting keyboard monitor")
        return installEventTap(includeRecordingKeys: isMonitoringRecordingKeys)
    }

    func setRecordingKeyHandlingEnabled(_ isEnabled: Bool) {
        guard isMonitoringRecordingKeys != isEnabled else { return }
        isMonitoringRecordingKeys = isEnabled

        guard eventTap != nil else { return }

        removeEventTap()
        if !installEventTap(includeRecordingKeys: isEnabled) {
            logger.error("Failed to update keyboard monitor event mask")
            isMonitoringRecordingKeys = false
            _ = installEventTap(includeRecordingKeys: false)
        }
    }

    private func eventMask(includeRecordingKeys: Bool) -> CGEventMask {
        var mask = 1 << CGEventType.flagsChanged.rawValue
        if includeRecordingKeys {
            mask |= 1 << CGEventType.keyDown.rawValue
            mask |= 1 << CGEventType.keyUp.rawValue
        }
        return CGEventMask(mask)
    }

    @discardableResult
    private func installEventTap(includeRecordingKeys: Bool) -> Bool {
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handleEvent(type: type, event: event)
        }

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask(includeRecordingKeys: includeRecordingKeys),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap else {
            let cgAllowed = CGPreflightListenEventAccess()
            let hidAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
            logger.error("Failed to create event tap. InputMonitoring cg=\(cgAllowed, privacy: .public) hid=\(self.describe(hidAccess), privacy: .public)")
            return false
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        logger.info("Keyboard monitor started. recordingKeys=\(includeRecordingKeys, privacy: .public)")
        return true
    }

    private func describe(_ access: IOHIDAccessType) -> String {
        switch access {
        case kIOHIDAccessTypeGranted:
            return "granted"
        case kIOHIDAccessTypeDenied:
            return "denied"
        case kIOHIDAccessTypeUnknown:
            return "unknown"
        default:
            return "unknown(\(access))"
        }
    }

    func stop() {
        removeEventTap()
    }

    private func removeEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    func resetToggleMode() {
        resetShortcutState()
    }

    private func resetShortcutState() {
        isToggleMode = false
        isGlobeHeld = false
        globePressTime = nil
        holdRecordingStarted = false
        holdRecordingLock.withLock { $0 = false }
    }

    var inToggleMode: Bool { isToggleMode }

    // MARK: - CGEvent Handling

    private nonisolated func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if disabled
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async { [weak self] in
                if let eventTap = self?.eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isGlobeKey = keyCode == 63 || keyCode == 179

        // Block globe key keyDown/keyUp events
        if type == .keyDown || type == .keyUp {
            // Detect escape key (don't block, just notify)
            if type == .keyDown && keyCode == 53 {
                DispatchQueue.main.async { [weak self] in
                    self?.onEscapePressed?()
                }
            }

            // Space-to-pin: while in hold-recording, press space to switch to toggle mode immediately.
            if type == .keyDown && keyCode == 49 && shortcutModeLock.withLock({ $0 }) == .holdToTalk {
                let inHoldRecording = holdRecordingLock.withLock { $0 }
                if inHoldRecording {
                    DispatchQueue.main.async { [weak self] in
                        self?.isToggleMode = true
                    }
                    return nil  // Block space from going to app
                }
            }

            return isGlobeKey ? nil : Unmanaged.passUnretained(event)
        }

        // Handle flagsChanged
        let isFnPressed = event.flags.contains(.maskSecondaryFn)
        let fnState = fnStateLock.withLock { lastFnState -> (changed: Bool, shouldBlock: Bool) in
            let wasPressed = lastFnState
            let changed = wasPressed != isFnPressed
            lastFnState = isFnPressed
            return (changed, isFnPressed || wasPressed)
        }

        if fnState.changed {
            DispatchQueue.main.async { [weak self] in
                self?.handleFlagChange(isFnPressed: isFnPressed)
            }
        }

        // Block Fn key events (both press and release)
        return fnState.shouldBlock ? nil : Unmanaged.passUnretained(event)
    }

    private func handleFlagChange(isFnPressed: Bool) {
        switch shortcutMode {
        case .holdToTalk:
            handleHoldToTalkFlagChange(isFnPressed: isFnPressed)
        case .toggleOnly:
            handleToggleOnlyFlagChange(isFnPressed: isFnPressed)
        }
    }

    private func handleHoldToTalkFlagChange(isFnPressed: Bool) {
        if isFnPressed {
            let now = Date()
            let timeSinceLast = now.timeIntervalSince(lastGlobePress)

            if isToggleMode {
                onGlobeReleased?()
                isToggleMode = false
                holdRecordingStarted = false
                holdRecordingLock.withLock { $0 = false }
            } else if timeSinceLast < 0.3 {
                isToggleMode = true
                onGlobePressed?()
            } else {
                // Start recording immediately (no delay)
                isGlobeHeld = true
                globePressTime = Date()
                holdRecordingStarted = true
                holdRecordingLock.withLock { $0 = true }
                onGlobePressed?()
            }
            lastGlobePress = now
        } else {
            isGlobeHeld = false
            let duration = globePressTime.map { Date().timeIntervalSince($0) } ?? 0

            if holdRecordingStarted && duration < 0.5 && !isToggleMode {
                // Too short - cancel like Escape (only for hold mode, not toggle)
                onEscapePressed?()
            } else if !isToggleMode {
                onGlobeReleased?()
            }

            holdRecordingStarted = false
            holdRecordingLock.withLock { $0 = false }
        }
    }

    private func handleToggleOnlyFlagChange(isFnPressed: Bool) {
        guard isFnPressed else { return }

        if isToggleMode {
            isToggleMode = false
            holdRecordingStarted = false
            holdRecordingLock.withLock { $0 = false }
            onGlobeReleased?()
        } else {
            isToggleMode = true
            isGlobeHeld = true
            globePressTime = Date()
            holdRecordingStarted = false
            holdRecordingLock.withLock { $0 = false }
            onGlobePressed?()
        }
    }
}
