import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private let bridge = KeyboardBridgeClient()
    private var keyboardFeedback: KeyboardFeedback?
    private var postAppearRefreshTask: Task<Void, Never>?
    private var automaticStartTask: Task<Void, Never>?
    private var keyboardViewIsVisible = false

    // Removes the system dictation key from the strip below the keyboard.
    // UIKit reads this before viewDidLoad, so it must be set at init and
    // re-asserted on every appearance; a viewDidLoad-only set leaves the
    // key visible.
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        hasDictationKey = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        hasDictationKey = true
    }

    isolated deinit {
        CrashReporting.breadcrumb(
            "Keyboard controller released",
            category: "keyboard_delivery",
            metadata: ["client": bridge.clientID]
        )
        bridge.deactivate()
        keyboardFeedback?.deactivate()
    }

    override func loadView() {
        view = KeyboardInputView(frame: .zero, inputViewStyle: .keyboard)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        CrashReporting.bootstrap(process: "keyboard")

        let keyboardFeedback = KeyboardFeedback(inputView: view)
        self.keyboardFeedback = keyboardFeedback

        bridge.onTranscript = { [weak self] text in
            guard let self, self.keyboardViewIsVisible else { return false }
            self.textDocumentProxy.insertText(text)
            return true
        }

        let actions = KeyboardActions(
            insert: { [weak self] text in self?.textDocumentProxy.insertText(text) },
            deleteBackward: { [weak self] in self?.textDocumentProxy.deleteBackward() },
            nextKeyboard: { [weak self] in self?.advanceToNextInputMode() },
            dismissKeyboard: { [weak self] in self?.dismissKeyboard() },
            playKeyFeedback: { location in keyboardFeedback.keyPressed(at: location) },
            playControlFeedback: { location in keyboardFeedback.controlPressed(at: location) },
            setDictationTextureActive: { active in keyboardFeedback.setDictationTextureActive(active) },
            // Deactivation publishes a synthetic .idle; only real phase
            // transitions while the keyboard is on screen should click the
            // mechanism.
            playDictationStartFeedback: { [weak self] in
                guard let self, self.keyboardViewIsVisible else { return }
                keyboardFeedback.dictationStarted(recordingStart: self.bridge.recordingStartDate)
            },
            playDictationStopFeedback: { [weak self] in
                guard let self, self.keyboardViewIsVisible else { return }
                keyboardFeedback.dictationStopped()
            },
            // Fires repeatedly for one tap (touch-down plus finger jitter), so
            // it must stay idempotent: refresh the host record, never clear it.
            prepareForStartSessionLaunch: { [weak self] in
                guard let self else { return }
                self.inspectHostApplication()
                self.bridge.prepareForStartSessionLaunch()
            }
        )

        let host = UIHostingController(rootView: KeyboardRootView(bridge: bridge, actions: actions))
        host.safeAreaRegions = []
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.isOpaque = false
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)

        let height = view.heightAnchor.constraint(equalToConstant: 258)
        height.priority = UILayoutPriority(999)
        height.isActive = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hasDictationKey = true
        refreshBridgeContext()
        bridge.activate()
        keyboardFeedback?.activate()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        keyboardViewIsVisible = true
        inspectHostApplication()
        bridge.claimTranscripts(.appeared)
        refreshBridgeAndLayout()
        // onChange in the root view only sees transitions; reappearing
        // mid-dictation needs an explicit sync to restart the texture.
        keyboardFeedback?.setDictationTextureActive(bridge.phase == .recording)
        startDictationAfterSessionLaunchWhenReady()

        postAppearRefreshTask?.cancel()
        postAppearRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard let self, self.view.window != nil else { return }
            self.inspectHostApplication()
            self.refreshBridgeAndLayout()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        keyboardViewIsVisible = false
        postAppearRefreshTask?.cancel()
        postAppearRefreshTask = nil
        bridge.deactivate()
        keyboardFeedback?.deactivate()
    }

    private func refreshBridgeAndLayout() {
        refreshBridgeContext()
        bridge.refresh()
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    // The resolved bundle identifier is only intermittently correct — the
    // arbiter names SpringBoard, or nothing, while the App Switcher or Home
    // Screen has been on screen, even though the same app still hosts the
    // keyboard — whereas the host process ID stays stable for as long as that
    // host lives. So a good reading is remembered against that process ID and
    // an unusable one can no longer erase it. The record lives in the App Group
    // because iOS replaces this controller while the extension process lives on,
    // and because the app reads it to know where to switch back to.
    private func inspectHostApplication() {
        let processIdentifier = HostApplicationDetector.hostProcessIdentifier(for: self)
        let bundleIdentifier = HostApplicationDetector.detect(for: self)
        #if DEBUG
        HostApplicationDetector.recordProbe(
            for: self,
            resolvedBundleIdentifier: bundleIdentifier
        )
        #endif

        DictationBridge.rememberKeyboardHost(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: processIdentifier
        )
    }

    private func startDictationAfterSessionLaunchWhenReady() {
        guard automaticStartTask == nil else { return }
        let hapticAlreadyPending = DictationBridge.hasFreshAutomaticStartHapticPending()
        let launchIntentPending = DictationBridge.hasFreshKeyboardLaunchIntent()
        guard hapticAlreadyPending || launchIntentPending else { return }
        CrashReporting.breadcrumb(
            "Automatic-start workflow claimed",
            category: "keyboard",
            metadata: [
                "launch_intent": launchIntentPending.description,
                "haptic_pending": hapticAlreadyPending.description,
            ]
        )

        automaticStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { automaticStartTask = nil }
            let deadline = Date().addingTimeInterval(DictationBridge.keyboardLaunchIntentFreshnessWindow)
            var requestedStart = hapticAlreadyPending
            var lastHapticError: Error?
            var hapticAttempt = 0

            if !requestedStart {
                while !Task.isCancelled, Date() < deadline {
                    bridge.refresh()
                    if keyboardViewIsVisible,
                       bridge.requestStartAfterSessionLaunchIfNeeded() {
                        CrashReporting.breadcrumb(
                            "Automatic-start dictation requested",
                            category: "keyboard"
                        )
                        requestedStart = true
                        break
                    }
                    do {
                        try await Task.sleep(for: .milliseconds(25))
                    } catch {
                        return
                    }
                }
            }
            guard requestedStart else { return }

            while !Task.isCancelled, Date() < deadline {
                bridge.refresh()
                if keyboardViewIsVisible,
                   bridge.appIsBackgrounded,
                   bridge.appPhase == .recording {
                    do {
                        try await Task.sleep(for: .milliseconds(250))
                    } catch {
                        return
                    }
                    bridge.refresh()
                    guard Date() < deadline,
                          keyboardViewIsVisible,
                          bridge.appIsBackgrounded,
                          bridge.appPhase == .recording,
                          DictationBridge.hasFreshAutomaticStartHapticPending()
                    else { continue }
                    hapticAttempt += 1
                    CrashReporting.breadcrumb(
                        "Automatic-start haptic attempt",
                        category: "keyboard",
                        metadata: ["attempt": String(hapticAttempt)]
                    )
                    do {
                        if try await keyboardFeedback?.automaticDictationStarted() == true {
                            DictationBridge.clearAutomaticStartHapticPending()
                            bridge.refresh()
                            CrashReporting.breadcrumb(
                                "Automatic-start haptic submitted",
                                category: "keyboard",
                                metadata: ["attempt": String(hapticAttempt)]
                            )
                            return
                        }
                        DictationBridge.clearAutomaticStartHapticPending()
                        bridge.refresh()
                        return
                    } catch {
                        lastHapticError = error
                        let nsError = error as NSError
                        CrashReporting.breadcrumb(
                            "Automatic-start haptic retrying",
                            category: "keyboard",
                            metadata: [
                                "attempt": String(hapticAttempt),
                                "error_code": String(nsError.code),
                                "error_domain": nsError.domain,
                            ]
                        )
                    }
                }
                do {
                    try await Task.sleep(for: .milliseconds(25))
                } catch {
                    return
                }
            }

            guard !Task.isCancelled else { return }
            DictationBridge.clearAutomaticStartHapticPending()
            bridge.refresh()

            if let lastHapticError {
                CrashReporting.capture(
                    message: "Automatic-start haptic retries expired",
                    context: "automatic_start_haptic",
                    error: lastHapticError
                )
            }
        }
    }

    private func refreshBridgeContext() {
        bridge.hasFullAccess = hasFullAccess
        bridge.needsInputModeSwitchKey = shouldShowInputModeSwitchKey
        DictationBridge.recordKeyboardActive()
    }

    private var shouldShowInputModeSwitchKey: Bool {
        // iOS 27 beta can crash inside UIKit when this property is read as the
        // extension reappears. Use UIKit's current answer on iOS 26 so Face ID
        // iPhones don't get a duplicate custom Globe above the system one.
        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard version.majorVersion < 27 else {
            return false
        }

        return needsInputModeSwitchKey
    }

}
