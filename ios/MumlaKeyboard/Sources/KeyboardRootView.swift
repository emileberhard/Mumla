import SwiftUI
import UIKit

struct KeyboardActions {
    let insert: @MainActor (String) -> Void
    let deleteBackward: @MainActor () -> Void
    let nextKeyboard: @MainActor () -> Void
    let dismissKeyboard: @MainActor () -> Void
    let playKeyFeedback: @MainActor (CGPoint) -> Void
    let playControlFeedback: @MainActor (CGPoint) -> Void
    let setDictationTextureActive: @MainActor (Bool) -> Void
    let playDictationStartFeedback: @MainActor () -> Void
    let playDictationStopFeedback: @MainActor () -> Void
    let prepareForStartSessionLaunch: @MainActor () -> Void
}

private enum KeyboardCoordinateSpace {
    static let inputView = "KeyboardInputView"
}

private enum KeyboardMetrics {
    static let rootHorizontalPadding: CGFloat = 2
    static let rootVerticalPadding: CGFloat = 3
    static let dictationToKeySpacing: CGFloat = 8
    static let dictationBarHeight: CGFloat = 52
    static let keyCellHeight: CGFloat = 48
    static let keyHorizontalInset: CGFloat = 3
    static let keyVerticalInset: CGFloat = 3
    static let keyCornerRadius: CGFloat = 8
    static let sideKeyWidth: CGFloat = 62
    static let switchKeyWidth: CGFloat = 54
    static let returnKeyWidth: CGFloat = 106
    static let dictationCircleSide: CGFloat = 50
}

private enum KeyboardPalette {
    private static let darkKeyFill = Color(
        .sRGB,
        red: 66.0 / 255.0,
        green: 66.0 / 255.0,
        blue: 66.0 / 255.0,
        opacity: 1
    )

    static func key(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? darkKeyFill
            : .white
    }

    static func specialKey(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? darkKeyFill
            : Color(red: 0.67, green: 0.70, blue: 0.75)
    }

    static func specialKeyUIColor(for colorScheme: ColorScheme) -> UIColor {
        colorScheme == .dark
            ? UIColor(red: 66.0 / 255.0, green: 66.0 / 255.0, blue: 66.0 / 255.0, alpha: 1)
            : UIColor(red: 0.67, green: 0.70, blue: 0.75, alpha: 1)
    }

    static func pressedKey(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.38, green: 0.38, blue: 0.40)
            : Color(red: 0.78, green: 0.80, blue: 0.84)
    }
}

struct KeyboardRootView: View {
    let bridge: KeyboardBridgeClient
    let actions: KeyboardActions

    var body: some View {
        VStack(spacing: KeyboardMetrics.dictationToKeySpacing) {
            DictationBar(bridge: bridge, actions: actions)
            KeyPlane(
                needsInputModeSwitchKey: bridge.needsInputModeSwitchKey,
                actions: actions
            )
        }
        .padding(.horizontal, KeyboardMetrics.rootHorizontalPadding)
        .padding(.vertical, KeyboardMetrics.rootVerticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .coordinateSpace(name: KeyboardCoordinateSpace.inputView)
        .onChange(of: bridge.phase) { oldPhase, newPhase in
            actions.setDictationTextureActive(newPhase == .recording)
            if newPhase == .recording {
                actions.playDictationStartFeedback()
            } else if oldPhase == .recording {
                actions.playDictationStopFeedback()
            }
        }
    }
}

// MARK: - Dictation bar

private struct DictationBar: View {
    @Environment(\.openURL) private var openURL

    let bridge: KeyboardBridgeClient
    let actions: KeyboardActions

    var body: some View {
        HStack(spacing: 12) {
            leadingAccessory
                .frame(width: KeyboardMetrics.dictationCircleSide, height: KeyboardMetrics.dictationCircleSide)
            Spacer(minLength: 0)
            dictationControl
            Spacer(minLength: 0)
            trailingAccessory
                .frame(width: KeyboardMetrics.dictationCircleSide, height: KeyboardMetrics.dictationCircleSide)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: KeyboardMetrics.dictationBarHeight, alignment: .center)
    }

    @ViewBuilder
    private var leadingAccessory: some View {
        if bridge.hasFullAccess, bridge.phase == .recording || bridge.phase == .processing {
            circleButton(systemName: "xmark", action: bridge.requestCancel)
                .accessibilityLabel("Cancel dictation")
        } else {
            Menu {
                if bridge.recentTranscripts.isEmpty {
                    Button("No recent transcriptions") {}
                        .disabled(true)
                } else {
                    ForEach(Array(bridge.recentTranscripts.enumerated()), id: \.offset) { _, transcript in
                        Button {
                            actions.insert(transcript)
                        } label: {
                            Text(singleLinePreview(transcript))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
            } label: {
                circleLabel(systemName: "clock.arrow.circlepath")
            } primaryAction: {
                openURL(DictationBridge.historyURL)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Transcription history")
            .accessibilityHint("Opens history. Touch and hold for recent transcriptions")
        }
    }

    private func singleLinePreview(_ transcript: String) -> String {
        transcript.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        if bridge.phase == .processing {
            Color.clear
                .accessibilityHidden(true)
        } else {
            circleButton(systemName: "keyboard.chevron.compact.down", action: actions.dismissKeyboard)
                .accessibilityLabel("Dismiss keyboard")
        }
    }

    @ViewBuilder
    private var dictationControl: some View {
        if !bridge.hasFullAccess {
            DictationStatusPill(
                symbolName: "exclamationmark.triangle.fill",
                title: "Full Access",
                symbolColor: DictationPillPalette.warning,
                accessibilityLabel: "Allow Full Access in Settings"
            )
        } else if bridge.accessBlocksDictation {
            AccessStatusPill(access: bridge.access)
        } else if bridge.canDictateNow {
            MicButton(
                bridge: bridge,
                feedback: actions.playControlFeedback
            )
        } else {
            // A Link, not a Button: iOS 18 removed the openURL:-selector
            // responder-chain path for keyboard extensions, but SwiftUI's
            // Link still launches the containing app from a keyboard.
            Link(destination: DictationBridge.startSessionURL) {
                DictationPillContent(
                    symbolName: "mic.badge.plus",
                    title: "Start Session",
                    foregroundColor: .white
                )
                .dictationPillBackground(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start session")
            .accessibilityHint("Opens Mumla to start a dictation session")
            .accessibilityAddTraits(.startsMediaSession)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(KeyboardCoordinateSpace.inputView))
                    .onChanged { _ in
                        actions.prepareForStartSessionLaunch()
                    }
            )
        }
    }

    private func circleButton(systemName: String, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            circleLabel(systemName: systemName)
        }
        .buttonStyle(.plain)
        .pressFeedback(actions.playControlFeedback)
    }

    private func circleLabel(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .semibold))
            .frame(width: KeyboardMetrics.dictationCircleSide, height: KeyboardMetrics.dictationCircleSide)
            .background(Circle().fill(DictationPillPalette.control))
            .foregroundStyle(.primary)
    }
}

private struct MicButton: View {
    let bridge: KeyboardBridgeClient
    let feedback: @MainActor (CGPoint) -> Void

    var body: some View {
        Button(action: toggle) {
            DictationPillContent(
                symbolName: symbolName,
                title: title,
                foregroundColor: foregroundColor,
                symbolColor: symbolColor,
                showsProgress: bridge.phase == .processing,
                showsCassette: bridge.phase == .recording,
                recordingStartDate: bridge.recordingStartDate,
                recordingDeadline: bridge.recordingDeadline
            )
            .dictationPillBackground(backgroundColor)
        }
        .buttonStyle(.plain)
        .pressFeedback { location in
            if bridge.phase != .processing {
                feedback(location)
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.startsMediaSession)
    }

    private var backgroundColor: Color {
        switch bridge.phase {
        case .recording:
            DictationPillPalette.recording
        case .processing, .error:
            DictationPillPalette.control
        default:
            Color.accentColor
        }
    }

    private var foregroundColor: Color {
        switch bridge.phase {
        case .recording, .idle, .success:
            .white
        default:
            .primary
        }
    }

    private var symbolColor: Color? {
        bridge.phase == .error ? DictationPillPalette.warning : nil
    }

    private var symbolName: String? {
        switch bridge.phase {
        case .recording, .processing: nil
        case .error: "exclamationmark.triangle.fill"
        default: "mic.fill"
        }
    }

    // Recording shows only the spinning cassette: the running mechanism is
    // the state, and tapping it to stop needs no caption.
    private var title: String? {
        switch bridge.phase {
        case .recording: nil
        case .processing: "Transcribing"
        case .error: "Try Again"
        default: "Dictate"
        }
    }

    private var accessibilityLabel: String {
        switch bridge.phase {
        case .recording: "Finish dictation"
        case .processing: "Transcribing"
        case .error: "Try dictation again"
        default: "Start dictation"
        }
    }

    private var accessibilityValue: String {
        guard bridge.phase == .error else { return "" }
        return bridge.errorMessage.isEmpty ? "Something went wrong" : bridge.errorMessage
    }

    private func toggle() {
        switch bridge.phase {
        case .recording:
            bridge.requestStop()
        case .idle, .success, .error:
            bridge.requestStart()
        case .processing:
            break
        }
    }
}

private struct AccessStatusPill: View {
    let access: KeyboardAccessState

    var body: some View {
        switch access {
        case .allowanceSpent(let resetsAt):
            DictationStatusPill(
                symbolName: "hourglass",
                title: "No Minutes Left",
                symbolColor: .secondary,
                accessibilityLabel: "No minutes left. They reset \(resetsAt.formatted(.dateTime.month(.wide).day()))"
            )
        case .iCloudSignedOut:
            DictationStatusPill(
                symbolName: "icloud.slash",
                title: "Sign In to iCloud",
                symbolColor: DictationPillPalette.warning,
                accessibilityLabel: "Sign in to iCloud in Settings to dictate"
            )
        default:
            DictationStatusPill(
                symbolName: "icloud.slash",
                title: "iCloud Unavailable",
                symbolColor: DictationPillPalette.warning,
                accessibilityLabel: "iCloud isn't available right now"
            )
        }
    }
}

private struct DictationStatusPill: View {
    let symbolName: String
    let title: String
    let symbolColor: Color
    let accessibilityLabel: String

    var body: some View {
        DictationPillContent(
            symbolName: symbolName,
            title: title,
            foregroundColor: .primary,
            symbolColor: symbolColor
        )
        .dictationPillBackground(DictationPillPalette.control, shadowOpacity: 0.06)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Key plane

private struct KeyPlane: View {
    let needsInputModeSwitchKey: Bool
    let actions: KeyboardActions

    @State private var page: KeyboardSymbolPage = .numbers

    var body: some View {
        VStack(spacing: 0) {
            CharacterRow(characters: page.rows[0], feedback: actions.playKeyFeedback, insert: insert)
            CharacterRow(characters: page.rows[1], feedback: actions.playKeyFeedback, insert: insert)

            HStack(spacing: 0) {
                ModeSwitchKey(
                    title: page.switchTitle,
                    accessibilityLabel: page.switchAccessibilityLabel,
                    feedback: actions.playKeyFeedback
                ) {
                    page = page.next
                }
                CharacterRow(characters: page.rows[2], feedback: actions.playKeyFeedback, insert: insert)
                RepeatSpecialKey(symbol: "delete.left", width: KeyboardMetrics.sideKeyWidth, feedback: actions.playKeyFeedback) {
                    actions.deleteBackward()
                }
            }

            HStack(spacing: 0) {
                if needsInputModeSwitchKey {
                    SpecialKey(
                        symbol: "globe",
                        width: KeyboardMetrics.switchKeyWidth,
                        accessibilityLabel: "Next keyboard",
                        feedback: actions.playKeyFeedback
                    ) {
                        actions.nextKeyboard()
                    }
                }
                // iOS has no public API for selecting a specific keyboard.
                // Use the system's next-input-mode selection as the closest
                // supported behavior.
                ModeSwitchKey(
                    title: "ABC",
                    accessibilityLabel: "Next keyboard",
                    feedback: actions.playKeyFeedback
                ) {
                    actions.nextKeyboard()
                }
                Button {
                    insert(" ")
                } label: {
                    SpaceKeyLabel()
                }
                .buttonStyle(KeyButtonStyle(prominent: false, feedback: actions.playKeyFeedback))
                .accessibilityLabel("Space")
                .accessibilityAddTraits(.isKeyboardKey)
                SpecialKey(
                    symbol: "return.left",
                    width: KeyboardMetrics.returnKeyWidth,
                    accessibilityLabel: "Return",
                    feedback: actions.playKeyFeedback
                ) {
                    actions.insert("\n")
                }
            }
        }
    }

    private func insert(_ character: String) {
        actions.insert(character)
    }
}

private struct CharacterRow: View {
    let characters: [String]
    let feedback: @MainActor (CGPoint) -> Void
    let insert: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(characters, id: \.self) { character in
                SpecialCharacterKey(
                    character: character,
                    feedback: feedback,
                    insert: insert
                )
            }
        }
    }
}

private struct SpecialCharacterKey: View {
    let character: String
    let feedback: @MainActor (CGPoint) -> Void
    let insert: (String) -> Void

    var body: some View {
        Button {
            insert(character)
        } label: {
            Text(character)
                .font(.system(size: 21))
                .frame(maxWidth: .infinity, minHeight: KeyboardMetrics.keyCellHeight)
        }
        .buttonStyle(KeyButtonStyle(prominent: false, feedback: feedback))
        .accessibilityLabel(character)
        .accessibilityAddTraits(.isKeyboardKey)
    }
}

private struct ModeSwitchKey: View {
    let title: String
    let accessibilityLabel: String
    let feedback: @MainActor (CGPoint) -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .medium))
                .frame(width: KeyboardMetrics.sideKeyWidth, height: KeyboardMetrics.keyCellHeight)
        }
        .buttonStyle(KeyButtonStyle(prominent: true, feedback: feedback))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isKeyboardKey)
    }
}

private struct SpaceKeyLabel: View {
    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: KeyboardMetrics.keyCellHeight)
    }
}

private struct SpecialKey: View {
    let symbol: String
    let width: CGFloat
    let accessibilityLabel: String
    let feedback: @MainActor (CGPoint) -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: width, height: KeyboardMetrics.keyCellHeight)
        }
        .buttonStyle(KeyButtonStyle(prominent: true, feedback: feedback))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isKeyboardKey)
    }
}

private struct RepeatSpecialKey: View {
    private static let initialRepeatDelay: UInt64 = 420_000_000
    private static let repeatInterval: UInt64 = 75_000_000

    let symbol: String
    let width: CGFloat
    let feedback: @MainActor (CGPoint) -> Void
    let action: @MainActor () -> Void

    @State private var isPressed = false
    @State private var repeatTask: Task<Void, Never>?
    @State private var latestLocation: CGPoint?

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .medium))
            .frame(width: width, height: KeyboardMetrics.keyCellHeight)
            .keyChrome(prominent: true, pressed: isPressed)
            .accessibilityLabel("Delete")
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(.isKeyboardKey)
            .accessibilityAction {
                action()
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(KeyboardCoordinateSpace.inputView))
                    .onChanged { value in
                        latestLocation = value.location
                        guard !isPressed else { return }
                        startRepeating(from: value.location)
                    }
                    .onEnded { _ in
                        stopRepeating()
                    }
            )
            .onDisappear {
                stopRepeating()
            }
    }

    private func startRepeating(from location: CGPoint) {
        isPressed = true
        delete(at: location)

        repeatTask?.cancel()
        repeatTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.initialRepeatDelay)

            while !Task.isCancelled {
                delete(at: latestLocation ?? location)
                try? await Task.sleep(nanoseconds: Self.repeatInterval)
            }
        }
    }

    private func stopRepeating() {
        isPressed = false
        latestLocation = nil
        repeatTask?.cancel()
        repeatTask = nil
    }

    private func delete(at location: CGPoint) {
        feedback(location)
        action()
    }
}

private struct KeyButtonStyle: ButtonStyle {
    let prominent: Bool
    let feedback: @MainActor (CGPoint) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .keyChrome(prominent: prominent, pressed: configuration.isPressed)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onChange(of: configuration.isPressed) { _, isPressed in
                            if isPressed {
                                let frame = proxy.frame(in: .named(KeyboardCoordinateSpace.inputView))
                                feedback(CGPoint(x: frame.midX, y: frame.midY))
                            }
                        }
                }
            }
    }
}

private struct KeyChromeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let prominent: Bool
    let pressed: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.primary)
            .background(
                RoundedRectangle(cornerRadius: KeyboardMetrics.keyCornerRadius, style: .continuous)
                    .fill(keyColor)
                    .padding(.horizontal, KeyboardMetrics.keyHorizontalInset)
                    .padding(.vertical, KeyboardMetrics.keyVerticalInset)
                    .shadow(color: .black.opacity(0.25), radius: 0, y: 1)
            )
            .contentShape(Rectangle())
    }

    private var keyColor: Color {
        if pressed {
            KeyboardPalette.pressedKey(for: colorScheme)
        } else if prominent {
            KeyboardPalette.specialKey(for: colorScheme)
        } else {
            KeyboardPalette.key(for: colorScheme)
        }
    }
}

private extension View {
    func keyChrome(prominent: Bool, pressed: Bool) -> some View {
        modifier(KeyChromeModifier(prominent: prominent, pressed: pressed))
    }
}

private struct PressFeedbackModifier: ViewModifier {
    let feedback: @MainActor (CGPoint) -> Void

    @State private var isPressing = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(KeyboardCoordinateSpace.inputView))
                    .onChanged { value in
                        guard !isPressing else { return }
                        isPressing = true
                        feedback(value.location)
                    }
                    .onEnded { _ in
                        isPressing = false
                    }
            )
    }
}

private extension View {
    func pressFeedback(_ feedback: @escaping @MainActor (CGPoint) -> Void) -> some View {
        modifier(PressFeedbackModifier(feedback: feedback))
    }
}
