#if MUMLA_SCREENSHOTS
import SwiftData
import SwiftUI
import UIKit

enum CaptureScreen: String, CaseIterable {
    case keyboard
    case dictionary
    case home
}

struct CaptureView: View {
    let coordinator: DictationCoordinator
    @State private var screen: CaptureScreen?
    @State private var appeared = AsyncStream.makeStream(of: CaptureScreen.self)

    var body: some View {
        Group {
            switch screen {
            case .keyboard:
                KeyboardScene()
            case .dictionary:
                SettingsView()
            case .home:
                ContentView()
            case nil:
                Color.clear
            }
        }
        .onAppear {
            if let screen { appeared.continuation.yield(screen) }
        }
        .id(screen)
        .environment(coordinator)
        .modelContainer(coordinator.dataStore.container)
        .preferredColorScheme(.light)
        .task {
            do {
                try await capture()
                exit(0)
            } catch {
                print("capture failed: \(DiagnosticError(error).metadata)")
                exit(1)
            }
        }
    }

    private func capture() async throws {
        guard let directory = ProcessInfo.processInfo.environment["MUMLA_CAPTURE"].map({ URL(filePath: $0) }) else {
            throw CaptureError("MUMLA_CAPTURE names no output directory")
        }
        CaptureFixture.seed(coordinator)
        let window = try await keyWindow()
        var shown = appeared.stream.makeAsyncIterator()
        for next in CaptureScreen.allCases {
            screen = next
            guard await shown.next() == next else { throw CaptureError("the \(next.rawValue) screen did not appear") }
            let png = try await snapshot(of: window)
            try png.write(to: directory.appending(path: "\(next.rawValue).png"), options: .atomic)
        }
    }

    private func keyWindow() async throws -> UIWindow {
        while true {
            let scene = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            if let window = scene?.keyWindow {
                return window
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func snapshot(of window: UIWindow) async throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.traitCollection.displayScale
        format.opaque = true
        while true {
            var complete = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                complete = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            if complete {
                guard let png = image.pngData() else { throw CaptureError("could not encode the screen as PNG") }
                return png
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

private enum CaptureFixture {
    static let languages = ["es"]
    static let terms = ["Saoirse", "Joaquín", "Dr. Okonkwo", "Kubernetes", "Figma", "Bergström"]
    static let transcripts: [(minutesAgo: Int, text: String)] = [
        (2, "Running ten minutes late, save me a seat by the window."),
        (24, "Remind Saoirse to send the Figma file before Thursday’s review."),
        (70, "Pick up oat milk, basil, two lemons and something for dessert."),
        (190, "The Kubernetes upgrade went smoothly. Rolling out to production tomorrow morning."),
        (320, "Happy birthday, Joaquín! Hope you get some sun this weekend."),
        (1500, "Notes from the call with Dr. Okonkwo: start the new routine on Monday and check in after two weeks."),
    ]

    static func seed(_ coordinator: DictationCoordinator) {
        coordinator.access.preview("available")
        for language in languages {
            coordinator.addDictationLanguage(language)
        }
        for term in terms {
            coordinator.dataStore.addVocabularyTerm(term)
        }
        for transcript in transcripts.reversed() {
            coordinator.dataStore.record(text: transcript.text, createdAt: .now - Double(transcript.minutesAgo * 60))
        }
    }
}

private struct KeyboardScene: View {
    @State private var bridge = KeyboardBridgeClient(sharedDefaults: nil)

    var body: some View {
        VStack(spacing: 0) {
            ConversationHeader()
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                Bubble(text: "How was the flight?", isOutgoing: false)
                Bubble(text: "Long, but I slept most of the way.", isOutgoing: true)
                Bubble(text: "Are we still on for dinner tonight?", isOutgoing: false)
                Bubble(text: "Yes! Table for two at 7.", isOutgoing: true)
                Bubble(text: "Perfect. What’s the address again?", isOutgoing: false)
            }
            .padding(.horizontal, 12)
            ComposeField(text: "It’s the little place on Elm Street, right next to the bakery.")
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 8)
            keyboard
        }
        .background(Color(uiColor: .systemBackground))
        .onAppear {
            bridge.applyPreviewSnapshot(KeyboardPreviewScenario.recording.snapshot)
        }
    }

    private var keyboard: some View {
        VStack(spacing: 0) {
            KeyboardRootView(bridge: bridge, actions: KeyboardActions(
                insert: { _ in },
                deleteBackward: {},
                nextKeyboard: {},
                dismissKeyboard: {},
                playKeyFeedback: { _ in },
                playControlFeedback: { _ in },
                setDictationTextureActive: { _ in },
                playDictationStartFeedback: {},
                playDictationStopFeedback: {},
                prepareForStartSessionLaunch: {}
            ))
            .frame(height: 256)
            HStack {
                Image(systemName: "globe")
                Spacer()
                Image(systemName: "mic")
            }
            .font(.system(size: 24))
            .foregroundStyle(Color(white: 0.32))
            .padding(.horizontal, 30)
            .frame(height: 30)
            .padding(.bottom, 4)
        }
        .padding(.top, 6)
        .background(Color(red: 0.82, green: 0.84, blue: 0.86), ignoresSafeAreaEdges: .bottom)
    }
}

private struct ConversationHeader: View {
    var body: some View {
        HStack(alignment: .top) {
            glassCircle("chevron.left")
            Spacer()
            VStack(spacing: 6) {
                Text("A")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(LinearGradient(colors: [Color(white: 0.66), Color(white: 0.52)], startPoint: .top, endPoint: .bottom), in: .circle)
                Text("Alex")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(uiColor: .secondarySystemBackground), in: .capsule)
            }
            Spacer()
            glassCircle("video")
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private func glassCircle(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .semibold))
            .frame(width: 44, height: 44)
            .background(Color(uiColor: .secondarySystemBackground), in: .circle)
    }
}

private struct Bubble: View {
    let text: String
    let isOutgoing: Bool

    var body: some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(isOutgoing ? .white : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(isOutgoing ? Color.blue : Color(uiColor: .systemGray5), in: .rect(cornerRadius: 19))
            .frame(maxWidth: 290, alignment: isOutgoing ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
    }
}

private struct ComposeField: View {
    let text: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 38, height: 38)
                .background(Color(uiColor: .secondarySystemBackground), in: .circle)
            Text("\(text)\(Text("|").foregroundStyle(.blue))")
                .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .overlay(RoundedRectangle(cornerRadius: 19).stroke(Color(uiColor: .systemGray4)))
        }
    }
}

private struct CaptureError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
#endif
