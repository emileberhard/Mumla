#if DEBUG
import SwiftUI
import UIKit

enum KeyboardDebugSheet: Identifiable {
    case visual(KeyboardPreviewScenario)
    case host
    case hostProbe

    var id: String {
        switch self {
        case .visual(let scenario):
            "visual-\(scenario.rawValue)"
        case .host:
            "host"
        case .hostProbe:
            "hostProbe"
        }
    }
}

/// Reads the host-detection probe records the keyboard writes on every
/// appearance, so a device run can rank the strategies on the current OS.
struct KeyboardHostProbeView: View {
    @State private var entries: [String] = []

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No probe records",
                        systemImage: "magnifyingglass",
                        description: Text(
                            "Open the Mumla keyboard in another app, then come back."
                        )
                    )
                } else {
                    List(Array(entries.enumerated()), id: \.offset) { _, entry in
                        Text(entry)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Host probe")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") {
                        DictationBridge.sharedDefaults?.removeObject(
                            forKey: DictationBridge.DefaultsKey.hostProbeLog
                        )
                        entries = []
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reload", action: reload)
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        entries = DictationBridge.sharedDefaults?
            .stringArray(forKey: DictationBridge.DefaultsKey.hostProbeLog) ?? []
    }
}

enum KeyboardPreviewScenario: String, CaseIterable, Identifiable {
    case start
    case idle
    case recording
    case processing
    case error

    var id: String { rawValue }

    init?(url: URL) {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let value = components.queryItems?.first(where: { $0.name == "state" })?.value
        else {
            return nil
        }

        self.init(rawValue: value)
    }

    var title: String {
        switch self {
        case .start:
            "Start"
        case .idle:
            "Idle"
        case .recording:
            "Recording"
        case .processing:
            "Processing"
        case .error:
            "Error"
        }
    }

    var snapshot: KeyboardPreviewSnapshot {
        switch self {
        case .start:
            KeyboardPreviewSnapshot(
                phase: .idle,
                appIsAlive: false,
                sessionActive: false,
                audioLevel: 0,
                errorMessage: "",
                hasFullAccess: true,
                needsInputModeSwitchKey: false
            )
        case .idle:
            KeyboardPreviewSnapshot(
                phase: .idle,
                appIsAlive: true,
                sessionActive: true,
                audioLevel: 0,
                errorMessage: "",
                hasFullAccess: true,
                needsInputModeSwitchKey: false
            )
        case .recording:
            KeyboardPreviewSnapshot(
                phase: .recording,
                appIsAlive: true,
                sessionActive: true,
                audioLevel: 0.72,
                errorMessage: "",
                hasFullAccess: true,
                needsInputModeSwitchKey: false
            )
        case .processing:
            KeyboardPreviewSnapshot(
                phase: .processing,
                appIsAlive: true,
                sessionActive: true,
                audioLevel: 0,
                errorMessage: "",
                hasFullAccess: true,
                needsInputModeSwitchKey: false
            )
        case .error:
            KeyboardPreviewSnapshot(
                phase: .error,
                appIsAlive: true,
                sessionActive: true,
                audioLevel: 0,
                errorMessage: "Something went wrong",
                hasFullAccess: true,
                needsInputModeSwitchKey: false
            )
        }
    }
}

struct KeyboardVisualTestView: View {
    @Environment(\.dismiss) private var dismiss
    let scenario: KeyboardPreviewScenario
    @State private var selectedScenario: KeyboardPreviewScenario
    @State private var text = ""

    init(scenario: KeyboardPreviewScenario) {
        self.scenario = scenario
        _selectedScenario = State(initialValue: scenario)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("State", selection: $selectedScenario) {
                    ForEach(KeyboardPreviewScenario.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])

                KeyboardVisualTestInput(text: $text, scenario: selectedScenario)
                    .frame(height: 120)
                    .padding()

                Spacer(minLength: 0)
            }
            .navigationTitle("Keyboard Test")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .accessibilityIdentifier("keyboard-preview-\(selectedScenario.rawValue)")
        .onChange(of: scenario) { _, newScenario in
            selectedScenario = newScenario
        }
    }
}

struct KeyboardExtensionHostTestView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                KeyboardHostTestInput(text: $text)
                    .frame(height: 120)
                    .padding()

                Spacer(minLength: 0)
            }
            .navigationTitle("Keyboard Host Test")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .accessibilityIdentifier("keyboard-host-test")
    }
}

private struct KeyboardVisualTestInput: UIViewRepresentable {
    @Binding var text: String
    let scenario: KeyboardPreviewScenario

    func makeUIView(context: Context) -> KeyboardPreviewTextView {
        let textView = KeyboardPreviewTextView()
        textView.delegate = context.coordinator
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .secondarySystemBackground
        textView.layer.cornerRadius = 12
        textView.layer.borderWidth = 1
        textView.layer.borderColor = UIColor.separator.cgColor
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        textView.accessibilityLabel = "Keyboard visual test input"
        context.coordinator.attach(to: textView)
        context.coordinator.apply(scenario)

        DispatchQueue.main.async {
            textView.becomeFirstResponder()
        }

        return textView
    }

    func updateUIView(_ textView: KeyboardPreviewTextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
        context.coordinator.apply(scenario)
        textView.reloadInputViews()
        if textView.window != nil, !textView.isFirstResponder {
            DispatchQueue.main.async {
                textView.becomeFirstResponder()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String
        private let bridge = KeyboardBridgeClient()
        private var host: UIHostingController<KeyboardRootView>?
        private weak var textView: KeyboardPreviewTextView?

        init(text: Binding<String>) {
            _text = text
        }

        func attach(to textView: KeyboardPreviewTextView) {
            self.textView = textView

            guard host == nil else { return }

            let inputView = KeyboardInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 256), inputViewStyle: .keyboard)
            inputView.allowsSelfSizing = true
            let height = inputView.heightAnchor.constraint(equalToConstant: 256)
            height.priority = UILayoutPriority(999)
            height.isActive = true

            let actions = KeyboardActions(
                insert: { [weak textView] text in textView?.insertText(text) },
                deleteBackward: { [weak textView] in textView?.deleteBackward() },
                nextKeyboard: {},
                dismissKeyboard: { [weak textView] in textView?.resignFirstResponder() },
                playKeyFeedback: { _ in },
                playControlFeedback: { _ in },
                setDictationTextureActive: { _ in },
                playDictationStartFeedback: {},
                playDictationStopFeedback: {},
                prepareForStartSessionLaunch: {}
            )

            let host = UIHostingController(rootView: KeyboardRootView(bridge: bridge, actions: actions))
            host.safeAreaRegions = []
            host.view.translatesAutoresizingMaskIntoConstraints = false
            host.view.isOpaque = false
            host.view.backgroundColor = .clear
            inputView.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.topAnchor.constraint(equalTo: inputView.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: inputView.bottomAnchor),
                host.view.leadingAnchor.constraint(equalTo: inputView.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: inputView.trailingAnchor),
            ])
            self.host = host
            textView.hostedInputView = inputView
        }

        func apply(_ scenario: KeyboardPreviewScenario) {
            bridge.applyPreviewSnapshot(scenario.snapshot)
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }
    }
}

private struct KeyboardHostTestInput: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .secondarySystemBackground
        textView.layer.cornerRadius = 12
        textView.layer.borderWidth = 1
        textView.layer.borderColor = UIColor.separator.cgColor
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        textView.accessibilityLabel = "Keyboard host test input"

        DispatchQueue.main.async {
            textView.becomeFirstResponder()
        }

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
        if textView.window != nil, !textView.isFirstResponder {
            DispatchQueue.main.async {
                textView.becomeFirstResponder()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }
    }
}

private final class KeyboardPreviewTextView: UITextView {
    var hostedInputView: UIView?

    override var inputView: UIView? {
        get { hostedInputView }
        set { hostedInputView = newValue }
    }
}
#endif
