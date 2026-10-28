import GrantKit
import SwiftUI
import UIKit

/// First-run setup. The app's root swaps to this screen at launch and stays
/// there until the first dictation lands in its field or the user skips; the
/// unfinished try-it is persisted, so a relaunch from Settings resumes it.
/// One screen whose phases mirror detected system state, so it reacts the
/// moment the user does something rather than asking:
///
/// - `.enable` — the keyboard is not known to be enabled
///   (``KeyboardEnablement``): one button to Settings plus the path hint.
/// - `.connect` — the keyboard is enabled but has never connected: an
///   auto-focused field; pressing 🌐 and picking Mumla makes the keyboard
///   stamp the App Group (only possible with Full Access), which is the
///   completion proof.
/// - `.keyboardUnconfirmed` — ``KeyboardConnectionCheck`` saw the Mumla
///   keyboard showing without a stamp: point to the Full Access toggle
///   without claiming it is off, and keep the keyboard up.
/// - `.dictate` — the stamp exists: the microphone is requested at this
///   moment of need and the user dictates into the field with the keyboard.
/// - `.done` — the words landed in this screen's field.
///
/// Phases derive from persistent state (the keyboard's App Group stamp and
/// the microphone grant), so the flow survives the process kill iOS performs
/// when a permission toggle flips in Settings. When enablement cannot be
/// told from the active input modes, returning from Settings after tapping
/// the button stands in as the enable→connect cue.
struct OnboardingView: View {
    static let tryItPendingKey = "onboardingTryItPending"

    private enum Phase {
        case enable
        case connect
        case keyboardUnconfirmed
        case dictate
        case done
    }

    let coordinator: DictationCoordinator
    let onFinished: () -> Void

    @State private var phase = Self.detectedPhase()
    @State private var hasOpenedSettings = false
    @State private var microphoneStatus = SystemPermission.microphone.status
    @State private var text = ""
    @State private var landing = TryItLanding()
    @State private var keyboardCheck = KeyboardConnectionCheck()
    @FocusState private var isFieldFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    private static func detectedPhase() -> Phase {
        if DictationBridge.keyboardHasBeenActive { return .dictate }
        if KeyboardEnablement.isKnownEnabled { return .connect }
        return .enable
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                StepScaffold(title: title, subtitle: subtitle) {
                    hero
                } controls: {
                    VStack(spacing: MumlaOnboardingStyle.controlSpacing) {
                        controls
                    }
                    .animation(.spring(duration: 0.35, bounce: 0.15), value: phase)
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .sensoryFeedback(trigger: phase, phaseFeedback)
        .onChange(of: phase) {
            AccessibilityNotification.ScreenChanged(nil).post()
        }
        .onChange(of: scenePhase, initial: true, handleScenePhaseChange)
        .onChange(of: isFieldFocused) {
            if isFieldFocused {
                keyboardCheck.evaluate()
            }
        }
        .onChange(of: coordinator.phase) { _, newPhase in
            switch newPhase {
            case .recording:
                landing.recordingStarted(fieldText: text)
            case .success where phase == .dictate || phase == .keyboardUnconfirmed:
                keyboardCheck.confirm()
                if phase == .keyboardUnconfirmed {
                    withAnimation(.spring(duration: 0.4, bounce: 0.25)) {
                        phase = .dictate
                    }
                }
                landing.transcriptPublishedHere(coordinator.transcript)
            default:
                break
            }
        }
        .task(id: hasLanded) {
            guard hasLanded else { return }
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, hasLanded, phase == .dictate else { return }
            isFieldFocused = false
            UserDefaults.standard.removeObject(forKey: Self.tryItPendingKey)
            withAnimation(.spring(duration: 0.45, bounce: 0.25)) {
                phase = .done
            }
        }
        .onAppear {
            UserDefaults.standard.set(true, forKey: Self.tryItPendingKey)
        }
        .task {
            if phase == .dictate {
                prepareDictation()
            }
            await runDetectionLoop()
        }
        .onReceive(NotificationCenter.default.publisher(for: UITextInputMode.currentInputModeDidChangeNotification)) { _ in
            keyboardCheck.evaluate()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            keyboardCheck.evaluate()
        }
    }

    private var hasLanded: Bool { landing.hasLanded(in: text) }

    // MARK: - Content

    @ViewBuilder
    private var hero: some View {
        switch phase {
        case .enable:
            if let icon = Self.appIcon {
                Image(uiImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .clipShape(.rect(cornerRadius: 21))
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                    .accessibilityHidden(true)
            } else {
                HeroSymbol(systemImage: "keyboard.fill")
            }
        case .connect:
            HeroSymbol(systemImage: "globe")
        case .keyboardUnconfirmed:
            HeroSymbol(systemImage: "keyboard.badge.ellipsis", tint: .orange)
        case .dictate:
            if microphoneStatus == .denied {
                HeroSymbol(systemImage: "mic.slash.fill", tint: .orange)
            } else {
                HeroSymbol(systemImage: "waveform")
                    .symbolEffect(.variableColor.iterative, isActive: coordinator.phase == .recording)
            }
        case .done:
            HeroSymbol(systemImage: "checkmark.seal.fill", tint: .green)
                .symbolEffect(.bounce, options: .nonRepeating)
        }
    }

    private var title: String {
        switch phase {
        case .enable: "Add the Mumla Keyboard"
        case .connect: "Switch to Mumla"
        case .keyboardUnconfirmed: "Check Full Access"
        case .dictate: microphoneStatus == .denied ? "Turn On the Microphone" : "Say Something"
        case .done: "You're All Set"
        }
    }

    private var subtitle: String {
        switch phase {
        case .enable:
            "It types what you say into any app."
        case .connect:
            "Press 🌐 and choose Mumla."
        case .keyboardUnconfirmed:
            "Mumla can't reach the keyboard yet. Check that Allow Full Access is on."
        case .dictate:
            switch coordinator.phase {
            case .recording: "Tap again when you're done."
            case .processing: "Transcribing…"
            default: microphoneStatus == .denied ? "" : "Tap Dictate on the keyboard and speak."
            }
        case .done:
            if case .available(let allowance) = coordinator.access.state {
                "\(allowance.limit.wholeMinutes) free minutes every month."
            } else {
                ""
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch phase {
        case .enable:
            settingsPathHint(navigation: "Keyboards", toggles: ["Mumla", "Allow Full Access"])
            OnboardingPrimaryButton("Open Settings", action: openSettings)
        case .connect, .keyboardUnconfirmed, .dictate:
            if phase == .keyboardUnconfirmed {
                settingsPathHint(navigation: "Keyboards", toggles: ["Allow Full Access"])
                OnboardingPrimaryButton("Open Settings", action: openSettings)
            }
            if phase == .dictate, microphoneStatus == .denied {
                OnboardingPrimaryButton("Open Settings") {
                    Task { await PermissionGuide.request(.microphone) }
                }
            } else {
                if phase == .dictate, coordinator.access.state.blocksDictation {
                    AllowanceView(access: coordinator.access)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                OnboardingTryItField(fieldPrompt, text: $text, isFocused: $isFieldFocused)
                    .padding(.top, phase == .keyboardUnconfirmed ? 8 : 0)
            }
            if phase == .connect {
                OnboardingSecondaryButton("Reopen Settings", action: openSettings)
            }
            if phase == .dictate, coordinator.setupComplete {
                OnboardingSecondaryButton("Skip", action: finish)
            }
        case .done:
            OnboardingTryItField("", text: $text, isFocused: $isFieldFocused)
                .disabled(true)
            OnboardingPrimaryButton("Done", action: finish)
        }
    }

    private var fieldPrompt: LocalizedStringKey {
        switch phase {
        case .keyboardUnconfirmed: "Then try again here"
        case .dictate: "Your words appear here"
        default: "Try it here"
        }
    }

    private func finish() {
        UserDefaults.standard.removeObject(forKey: Self.tryItPendingKey)
        onFinished()
    }

    private func phaseFeedback(from oldPhase: Phase, to newPhase: Phase) -> SensoryFeedback? {
        switch newPhase {
        case .enable: nil
        case .connect: .impact(weight: .light)
        case .keyboardUnconfirmed: nil
        case .dictate: .impact(weight: .medium)
        case .done: .success
        }
    }

    // MARK: - Detection

    private func handleScenePhaseChange(from oldScenePhase: ScenePhase, to newScenePhase: ScenePhase) {
        guard newScenePhase == .active else { return }
        microphoneStatus = SystemPermission.microphone.status
        switch phase {
        case .enable:
            // Fallback cue only when enablement cannot be told; otherwise
            // the poll advances on the real state.
            if hasOpenedSettings, !KeyboardEnablement.isKnownEnabled {
                enterConnect()
            }
        case .connect, .keyboardUnconfirmed:
            // Back from Settings, often in a process iOS relaunched after a
            // keyboard toggle: summon the keyboard so 🌐 is one tap away.
            focusField()
            keyboardCheck.evaluate()
        case .dictate:
            if microphoneStatus == .granted {
                focusField()
            }
        case .done:
            break
        }
    }

    private func runDetectionLoop() async {
        while !Task.isCancelled, phase != .done {
            coordinator.refreshKeyboardAccess()
            keyboardCheck.refresh()
            applyDetectedState()
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func applyDetectedState() {
        if keyboardCheck.isUnconfirmed {
            if phase != .keyboardUnconfirmed {
                withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
                    phase = .keyboardUnconfirmed
                }
            }
            return
        }
        if coordinator.keyboardHasBeenActive {
            if phase != .dictate {
                withAnimation(.spring(duration: 0.4, bounce: 0.25)) {
                    phase = .dictate
                }
                prepareDictation()
            }
            return
        }
        if phase == .keyboardUnconfirmed {
            enterConnect()
        }
        if phase == .enable, KeyboardEnablement.isKnownEnabled {
            enterConnect()
        }
    }

    private func prepareDictation() {
        focusField()
        switch SystemPermission.microphone.status {
        case .notDetermined:
            coordinator.requestMicrophonePermission()
        case .granted:
            if !coordinator.sessionActive {
                coordinator.requestSessionStart()
            }
        case .denied:
            microphoneStatus = .denied
        }
    }

    private func enterConnect() {
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
            phase = .connect
        }
        focusField()
    }

    private func focusField() {
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            guard phase != .enable, phase != .done else { return }
            isFieldFocused = true
        }
    }

    private func openSettings() {
        hasOpenedSettings = true
        // iOS offers no public deep link to the Keyboards sub-page; the
        // app's settings page is one tap away.
        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
    }

    /// The path through Settings: the first capsule is a navigation step and
    /// the remaining capsules mirror the switches the user turns on.
    private func settingsPathHint(navigation: String, toggles: [String]) -> some View {
        let accessibilityLabel = (["Open \(navigation)"] + toggles.map { "turn on \($0)" })
            .joined(separator: ", then ")

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                settingsPathSteps(navigation: navigation, toggles: toggles, chevron: "chevron.right")
            }
            VStack(spacing: 5) {
                settingsPathSteps(navigation: navigation, toggles: toggles, chevron: "chevron.down")
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .imageScale(.small)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    @ViewBuilder
    private func settingsPathSteps(navigation: String, toggles: [String], chevron: String) -> some View {
        SettingsHintCapsule(title: navigation)

        ForEach(toggles, id: \.self) { toggle in
            Image(systemName: chevron)
            SettingsHintCapsule(title: toggle, showsEnabledSwitch: true)
        }
    }

    private static var appIcon: UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let name = files.last
        else { return nil }
        return UIImage(named: name)
    }
}

private struct SettingsHintCapsule: View {
    let title: String
    var showsEnabledSwitch = false

    var body: some View {
        HStack(spacing: 5) {
            Text(title)

            if showsEnabledSwitch {
                Capsule()
                    .fill(.green)
                    .frame(width: 22, height: 13)
                    .overlay(alignment: .trailing) {
                        Circle()
                            .fill(.white)
                            .padding(1.5)
                    }
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 13))
    }
}
