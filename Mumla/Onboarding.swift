import AppKit
import GrantKit
import SwiftUI

/// First-run setup. Shown at launch until the required permissions are
/// granted and the try-it has appeared once. One screen grants every
/// permission with live state (FlowCoordinator observes the same permissions,
/// so features light up live too), then the user dictates once into the
/// window itself. When the fn shortcut can't start even though its
/// permissions were granted before launch, a restart can't help, so the
/// screen marks it unavailable and lets the user finish setup without it.
///
/// The flow is built to survive a forced relaunch: granting Input Monitoring
/// makes macOS offer "Quit & Reopen" (the event tap only works in a freshly
/// launched process), so every phase derives from persistent state —
/// permission grants and a finished flag — and a relaunch resumes at the
/// first incomplete phase.
@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    static let shared = OnboardingController()

    static let requiredPermissions: [SystemPermission] = [.microphone, .accessibility, .inputMonitoring]

    static let finishedDefaultsKey = "onboardingWelcomeSeen"

    private var window: NSWindow?

    static var isSetupComplete: Bool {
        requiredPermissions.allSatisfy(\.isGranted)
    }

    private static var needsOnboarding: Bool {
        !isSetupComplete || !UserDefaults.standard.bool(forKey: finishedDefaultsKey)
    }

    func showIfNeeded(coordinator: FlowCoordinator) {
        guard Self.needsOnboarding else { return }
        // tccd can transiently report granted permissions as missing right
        // after launch; re-check once so fully-set-up users never see the
        // wizard flash open.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard Self.needsOnboarding else { return }
            show(coordinator: coordinator)
        }
    }

    private func show(coordinator: FlowCoordinator) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let hosting = NSHostingController(rootView: OnboardingView(coordinator: coordinator) { [weak self] in
            self?.close()
        })
        let window = NSWindow(contentViewController: hosting)
        window.title = "Set Up Mumla"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }

    private func close() {
        window?.close()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
        }
    }

    /// Relaunches the app so a fresh Input Monitoring grant takes effect for
    /// the hotkey's event tap. `open -n` runs after this process has exited;
    /// on relaunch the wizard resumes from persistent state.
    static func relaunchApp() {
        let path = Bundle.main.bundleURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.7; /usr/bin/open -n \"\(path)\""]
        do {
            try process.run()
        } catch {
            AppDiagnostics.error("Failed to schedule app relaunch", category: "onboarding", error: error)
            return
        }
        AppDiagnostics.info("Relaunching for Input Monitoring grant", category: "onboarding")
        NSApp.terminate(nil)
    }
}

// MARK: - Phases

struct OnboardingView: View {
    private enum Phase {
        case permissions
        case tryIt
    }

    let coordinator: FlowCoordinator
    let onClose: () -> Void

    @State private var phase: Phase = OnboardingController.isSetupComplete ? .tryIt : .permissions

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                content
                    .id(phase)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 48)
            .padding(.top, 8)
            .clipped()

            footer
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .frame(width: 560, height: 480)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .permissions:
            PermissionsStep(coordinator: coordinator) {
                if UserDefaults.standard.bool(forKey: OnboardingController.finishedDefaultsKey) {
                    onClose()
                } else {
                    show(.tryIt)
                }
            }
        case .tryIt:
            TryItStep(coordinator: coordinator, onFinished: onClose)
                .onAppear {
                    UserDefaults.standard.set(true, forKey: OnboardingController.finishedDefaultsKey)
                }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            if phase == .permissions {
                Button("Set Up Later", action: onClose)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .frame(height: 20)
    }

    private func show(_ next: Phase) {
        withAnimation(.spring(duration: 0.45, bounce: 0.12)) {
            phase = next
        }
        AccessibilityNotification.ScreenChanged(nil).post()
    }
}

// MARK: - Shared scaffolding

/// Common step layout: a hero graphic, a title, one short explanation, the
/// step's own controls, and a single prominent action. Everything centered
/// so each step reads as one focused card.
private struct StepScaffold<Hero: View, Controls: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var hero: Hero
    @ViewBuilder var controls: Controls

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            hero
                .frame(height: 84)

            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 18)

            controls
                .padding(.top, 22)

            Spacer(minLength: 0)
        }
    }
}

private struct HeroSymbol: View {
    let systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 44, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }
}

// MARK: - Permissions

private struct PermissionsStep: View {
    let coordinator: FlowCoordinator
    let onComplete: () -> Void

    @State private var granted: Set<SystemPermission> = Set(OnboardingController.requiredPermissions.filter(\.isGranted))
    @State private var requesting: SystemPermission?
    @State private var guide: Task<Void, Never>?

    var body: some View {
        StepScaffold(
            title: "Welcome to Mumla",
            subtitle: "Hold fn, speak, and your words appear wherever you type."
        ) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                .accessibilityHidden(true)
        } controls: {
            VStack(spacing: 8) {
                ForEach(OnboardingController.requiredPermissions) { permission in
                    row(for: permission)
                        .task(id: permission) {
                            for await isGranted in PermissionMonitor.updates(for: permission) {
                                withAnimation(.spring(duration: 0.4, bounce: 0.25)) {
                                    if isGranted {
                                        granted.insert(permission)
                                    } else {
                                        granted.remove(permission)
                                    }
                                }
                            }
                        }
                }
                if canContinueWithoutShortcut {
                    Button("Continue", action: continueWithoutShortcut)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .padding(.top, 8)
                }
            }
        }
        .task(id: isReady) {
            guard isReady else { return }
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            onComplete()
        }
        .onDisappear { guide?.cancel() }
    }

    private var needsRestart: Bool {
        coordinator.shortcutStatus == .needsRestart
    }

    private var allGranted: Bool {
        granted.count == OnboardingController.requiredPermissions.count
    }

    private var isReady: Bool {
        allGranted && coordinator.shortcutStatus == .running
    }

    private var canContinueWithoutShortcut: Bool {
        allGranted && coordinator.shortcutStatus == .unavailable
    }

    private func continueWithoutShortcut() {
        UserDefaults.standard.set(true, forKey: OnboardingController.finishedDefaultsKey)
        onComplete()
    }

    private var nextPermission: SystemPermission? {
        OnboardingController.requiredPermissions.first { !granted.contains($0) }
    }

    private func row(for permission: SystemPermission) -> some View {
        let isGranted = granted.contains(permission)
        let isUnavailable = permission == .inputMonitoring && isGranted && coordinator.shortcutStatus == .unavailable
        return HStack(spacing: 12) {
            Image(systemName: symbol(for: permission))
                .font(.title3)
                .foregroundStyle(isUnavailable ? Color.orange : isGranted ? Color.green : Color.accentColor)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(name(for: permission))
                    .font(.body.weight(.medium))
                Text(isUnavailable ? "Mumla couldn't turn on the fn shortcut." : detail(for: permission))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if permission == .inputMonitoring, needsRestart {
                Button("Restart Mumla") {
                    OnboardingController.relaunchApp()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else if isUnavailable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("\(name(for: permission)) unavailable")
            } else if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("\(name(for: permission)) allowed")
            } else {
                allowButton(for: permission)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func allowButton(for permission: SystemPermission) -> some View {
        let button = Button("Allow") { request(permission) }
            .disabled(requesting == permission)
            .accessibilityLabel("Allow \(name(for: permission))")

        if permission == nextPermission, !needsRestart {
            button
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        } else {
            button
                .buttonStyle(.bordered)
        }
    }

    private func request(_ permission: SystemPermission) {
        guide?.cancel()
        requesting = permission
        guide = Task {
            await PermissionGuide.request(permission)
            guard !Task.isCancelled else { return }
            requesting = nil
        }
    }

    private func name(for permission: SystemPermission) -> String {
        switch permission {
        case .microphone: "Microphone"
        case .accessibility: "Auto-Paste"
        case .inputMonitoring: "Dictation Shortcut"
        case .screenRecording: "Screen Recording"
        }
    }

    private func detail(for permission: SystemPermission) -> String {
        switch permission {
        case .microphone: "Mumla listens only while you dictate."
        case .accessibility: "Puts your words where the cursor is."
        case .inputMonitoring: "Lets fn start dictation in any app."
        case .screenRecording: ""
        }
    }

    private func symbol(for permission: SystemPermission) -> String {
        switch permission {
        case .microphone: "mic.fill"
        case .accessibility: "text.cursor"
        case .inputMonitoring: "keyboard.fill"
        case .screenRecording: "rectangle.dashed.badge.record"
        }
    }
}

// MARK: - Try it

private struct TryItStep: View {
    let coordinator: FlowCoordinator
    let onFinished: () -> Void

    @State private var text = ""
    @State private var landing = TryItLanding()
    @State private var landed = false
    @FocusState private var isFieldFocused: Bool

    private var hasLanded: Bool { landing.hasLanded(in: text) }

    var body: some View {
        StepScaffold(title: landed ? "You're All Set" : "Say Something", subtitle: landed ? freeMinutes : "") {
            if landed {
                HeroSymbol(systemImage: "checkmark.seal.fill", tint: .green)
                    .symbolEffect(.bounce, options: .nonRepeating)
            } else {
                HeroSymbol(systemImage: "waveform")
                    .symbolEffect(.variableColor.iterative, isActive: coordinator.state == .recording)
            }
        } controls: {
            VStack(spacing: 14) {
                if !landed {
                    instruction
                    if coordinator.access.state.blocksDictation {
                        AllowanceView(access: coordinator.access)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                TextField("Your words appear here", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...4)
                    .focused($isFieldFocused)
                    .disabled(landed)
                    .padding(12)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))

                if landed {
                    Button("Done", action: onFinished)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Skip", action: onFinished)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            .animation(.spring(duration: 0.4, bounce: 0.2), value: landed)
        }
        .onAppear { isFieldFocused = true }
        .onChange(of: coordinator.state) { _, newState in
            switch newState {
            case .recording:
                landing.recordingStarted(fieldText: text)
            case .success:
                landing.transcriptPublishedHere(coordinator.transcript)
            default:
                break
            }
        }
        .task(id: hasLanded) {
            guard hasLanded else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, hasLanded else { return }
            landed = true
            AccessibilityNotification.ScreenChanged(nil).post()
        }
    }

    private var instruction: some View {
        HStack(spacing: 6) {
            switch (coordinator.state, coordinator.keyboardShortcutMode) {
            case (.recording, .holdToTalk):
                Text("Let go of")
                KeyCap(key: "fn")
                Text("when you're done")
            case (.recording, .toggleOnly):
                Text("Press")
                KeyCap(key: "fn")
                Text("again when you're done")
            case (.processing, _), (.success, _):
                Text("Transcribing…")
            case (.error(let message), _):
                Text(message)
                    .foregroundStyle(.orange)
            case (.idle, .holdToTalk):
                Text("Hold")
                KeyCap(key: "fn")
                Text("and speak")
            case (.idle, .toggleOnly):
                Text("Press")
                KeyCap(key: "fn")
                Text("and speak")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var freeMinutes: String {
        if case .available(let allowance) = coordinator.access.state {
            "\(allowance.limit.wholeMinutes) free minutes every month."
        } else {
            ""
        }
    }
}
