import SwiftData
import SwiftUI

@main
struct MumlaiOSApp: App {
    @State private var coordinator: DictationCoordinator
    /// True until first-run setup and its try-it are finished; the root shows
    /// the blocking onboarding wizard instead of the main view while set.
    @State private var isOnboarding: Bool
    @Environment(\.scenePhase) private var scenePhase
#if DEBUG
    @State private var keyboardDebugSheet: KeyboardDebugSheet?
#endif

    init() {
#if !MUMLA_SCREENSHOTS
        CrashReporting.bootstrap(process: "app")
#endif
        DictationBridge.setAppIsBackgrounded(false)
        let launchedFromKeyboard = DictationBridge.hasFreshKeyboardLaunchIntent()
        let coordinator = DictationCoordinator(showSwipeBackHint: launchedFromKeyboard)
        _coordinator = State(initialValue: coordinator)
        _isOnboarding = State(initialValue: !coordinator.setupComplete
            || UserDefaults.standard.bool(forKey: OnboardingView.tryItPendingKey))
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .modelContainer(coordinator.dataStore.container)
                .id(coordinator.dataStore.partitionID)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                coordinator.applicationDidBecomeActive()
            case .background:
                coordinator.applicationDidEnterBackground()
            case .inactive:
                coordinator.applicationDidBecomeInactive()
            @unknown default:
                break
            }
        }
    }

    @ViewBuilder
    private var rootView: some View {
        let base = Group {
            if isOnboarding {
                onboardingView
            } else {
                mainView
                    .transition(.opacity)
            }
        }
        .animation(.spring(duration: 0.5, bounce: 0.1), value: isOnboarding)
        .onOpenURL { url in
            guard !coordinator.dataStore.handleAgentURL(url) else { return }
#if DEBUG
            guard !handleDebugURL(url) else { return }
#endif
            coordinator.handle(url: url)
        }

#if DEBUG
        base.sheet(item: $keyboardDebugSheet) { sheet in
            switch sheet {
            case .visual(let scenario):
                KeyboardVisualTestView(scenario: scenario)
            case .host:
                KeyboardExtensionHostTestView()
            case .hostProbe:
                KeyboardHostProbeView()
            }
        }
#else
        base
#endif
    }

    private var onboardingView: some View {
        OnboardingView(coordinator: coordinator) {
            isOnboarding = false
            // Everything is configured now; bring the session up the same way
            // a normal foreground activation would.
            coordinator.applicationDidBecomeActive()
        }
        .transition(.opacity)
#if MUMLA_SCREENSHOTS
        .task { await Capture.onboarding() }
#endif
    }

    private var mainView: some View {
        ContentView()
            .environment(coordinator)
            .overlay {
                if coordinator.showSwipeBackHint {
                    KeyboardReturnHintView {
                        coordinator.dismissSwipeBackHint()
                    }
                    .transition(.opacity)
                }
            }
            .animation(.snappy(duration: 0.18), value: coordinator.showSwipeBackHint)
    }

#if DEBUG
    private func handleDebugURL(_ url: URL) -> Bool {
        guard url.scheme == "mumla",
              url.host == "debug"
        else {
            return false
        }

        switch url.path {
        case "/keyboard-test":
            keyboardDebugSheet = .visual(KeyboardPreviewScenario(url: url) ?? .start)
            return true
        case "/keyboard-host-test":
            applyDebugKeyboardState(KeyboardPreviewScenario(url: url))
            keyboardDebugSheet = .host
            return true
        case "/host-probe":
            keyboardDebugSheet = .hostProbe
            return true
        case "/onboarding":
            // Walk the whole wizard on an already-configured install: the
            // keyboard stamps the App Group again on its next appearance.
            coordinator.resetKeyboardAccessForOnboarding()
            isOnboarding = true
            return true
        case "/access":
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "state" }?.value
            coordinator.access.preview(state ?? "")
            return true
        default:
            return false
        }
    }

    private func applyDebugKeyboardState(_ scenario: KeyboardPreviewScenario?) {
        guard let scenario, let defaults = DictationBridge.sharedDefaults else { return }

        let snapshot = scenario.snapshot
        defaults.set(
            snapshot.appIsAlive ? Date().timeIntervalSince1970 : 0,
            forKey: DictationBridge.DefaultsKey.heartbeat
        )
        defaults.set(snapshot.sessionActive, forKey: DictationBridge.DefaultsKey.sessionActive)
        defaults.set(snapshot.phase.rawValue, forKey: DictationBridge.DefaultsKey.phase)
        defaults.set(snapshot.errorMessage, forKey: DictationBridge.DefaultsKey.errorMessage)
        defaults.set(snapshot.audioLevel, forKey: DictationBridge.DefaultsKey.audioLevel)
        defaults.removeObject(forKey: DictationBridge.DefaultsKey.transcriptID)
        defaults.removeObject(forKey: DictationBridge.DefaultsKey.transcriptText)
        defaults.removeObject(forKey: DictationBridge.DefaultsKey.transcriptTimestamp)
        defaults.synchronize()
        DarwinNotifications.post(DictationBridge.Event.stateChanged)
    }
#endif
}
