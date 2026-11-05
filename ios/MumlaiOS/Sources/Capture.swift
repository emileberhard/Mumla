#if MUMLA_SCREENSHOTS
import SwiftData
import SwiftUI
import UIKit

enum CaptureScreen: String, CaseIterable {
    case home
    case homeRecording = "home-recording"
    case history
    case historyRecordings = "history-recordings"
    case historyStats = "history-stats"
    case settings
    case onboardingEnable = "onboarding-enable"
    case onboardingDictate = "onboarding-dictate"
    case keyboardStart = "keyboard-start"
    case keyboardIdle = "keyboard-idle"
    case keyboard
    case keyboardProcessing = "keyboard-processing"
    case keyboardError = "keyboard-error"

    var title: String {
        switch self {
        case .home: "Home"
        case .homeRecording: "Home · Recording"
        case .history: "History · Transcripts"
        case .historyRecordings: "History · Recordings"
        case .historyStats: "History · Stats"
        case .settings: "Settings"
        case .onboardingEnable: "Onboarding · Enable"
        case .onboardingDictate: "Onboarding · Dictate"
        case .keyboardStart: "Keyboard composite · Start Session"
        case .keyboardIdle: "Keyboard composite · Idle"
        case .keyboard: "Keyboard composite · Recording"
        case .keyboardProcessing: "Keyboard composite · Processing"
        case .keyboardError: "Keyboard composite · Error"
        }
    }

    static func style(_ appearance: String?) throws -> UIUserInterfaceStyle {
        switch appearance {
        case "light": .light
        case "dark", nil: .dark
        default: throw CaptureError("unknown appearance \(appearance!)")
        }
    }

    static func named(_ list: String?) throws -> [CaptureScreen] {
        guard let list else {
            return allCases
        }
        let screens = try list.split(separator: ",", omittingEmptySubsequences: false).map { id in
            guard let screen = CaptureScreen(rawValue: String(id)) else {
                throw CaptureError("there is no screen \"\(id)\"; the screens are \(allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return screen
        }
        guard Set(screens).count == screens.count else {
            throw CaptureError("\(list) names a screen more than once")
        }
        return screens
    }
}

struct CaptureView: View {
    let coordinator: DictationCoordinator
    @State private var screen: CaptureScreen?
    @State private var appeared = AsyncStream.makeStream(of: CaptureScreen.self)
    @State private var cleared = AsyncStream.makeStream(of: Void.self)

    var body: some View {
        Group {
            switch screen {
            case .keyboard:
                KeyboardScene(scenario: .recording)
            case .keyboardStart:
                KeyboardScene(scenario: .start)
            case .keyboardIdle:
                KeyboardScene(scenario: .idle)
            case .keyboardProcessing:
                KeyboardScene(scenario: .processing)
            case .keyboardError:
                KeyboardScene(scenario: .error)
            case .settings, .home, .homeRecording, .history, .historyRecordings, .historyStats:
                ContentView()
            case .onboardingEnable:
                OnboardingView(coordinator: coordinator, capturePhase: .enable)
            case .onboardingDictate:
                OnboardingView(coordinator: coordinator, capturePhase: .dictate)
            case nil:
                Color.clear.onAppear { cleared.continuation.yield(()) }
            }
        }
        .onAppear {
            if let screen { appeared.continuation.yield(screen) }
        }
        .id(screen)
        .environment(coordinator)
        .modelContainer(coordinator.dataStore.container)
        .task {
            do {
                try await capture()
                exit(0)
            } catch {
                if let error = error as? CaptureError {
                    print("capture failed: \(error)")
                } else {
                    print("capture failed: \(DiagnosticError(error).metadata)")
                }
                exit(1)
            }
        }
    }

    private func capture() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["MUMLA_CAPTURE"].map({ URL(filePath: $0) }) else {
            throw CaptureError("MUMLA_CAPTURE names no output directory")
        }
        let screens = try CaptureScreen.named(env["MUMLA_CAPTURE_SCREENS"])
        let style = try CaptureScreen.style(env["MUMLA_CAPTURE_APPEARANCE"])
        UIView.setAnimationsEnabled(false)
        try CaptureFixture.seed(coordinator)
        let window = try await keyWindow()
        var shown = appeared.stream.makeAsyncIterator()
        var blank = cleared.stream.makeAsyncIterator()
        _ = await blank.next(isolation: #isolation)
        let jpgDirectory = directory.appending(path: "jpg", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: jpgDirectory, withIntermediateDirectories: true)

        window.overrideUserInterfaceStyle = style
        let captured = try await withThrowingTaskGroup(of: (CaptureScreen, UIImage).self) { group in
            for next in screens {
                CaptureFixture.configure(coordinator, for: next)
                screen = next
                guard await shown.next(isolation: #isolation) == next else {
                    throw CaptureError("the \(next.rawValue) screen did not appear")
                }
                if [.history, .historyRecordings, .historyStats].contains(next) {
                    coordinator.navigationPath = [.history]
                    try await settle(window, screen: next)
                }
                if next == .historyRecordings {
                    coordinator.captureShowsRecordings = false
                    let previous = try await drawnFrame(of: window)
                    try selectSegment(1, in: window)
                    try await waitForRecordings(from: previous, in: window)
                }
                if next == .settings || next == .historyStats {
                    try activateToolbarButton(in: window)
                }
                try await settle(window, screen: next)
                let image = try await screenshot(next, in: directory)
                group.addTask { (next, try await CaptureFiles.write(image, named: next.rawValue, into: jpgDirectory)) }
                screen = nil
                _ = await blank.next(isolation: #isolation)
                try await settle(window, screen: next)
            }
            var images: [CaptureScreen: UIImage] = [:]
            for try await (screen, image) in group {
                images[screen] = image
            }
            return screens.map { (screen: $0, image: images[$0]!) }
        }

        let sheet = try composeContactSheet(captured)
        try sheet.write(to: directory.appending(path: "sheet.jpg"), options: .atomic)
        try JSONEncoder().encode(screens.map(\.rawValue)).write(to: directory.appending(path: "manifest.json"), options: .atomic)
    }

    private func keyWindow() async throws -> UIWindow {
        while true {
            let scene = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            if let window = scene?.keyWindow {
                return window
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func settle(_ window: UIWindow, screen: CaptureScreen) async throws {
        var previous = try await drawnFrame(of: window)
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(33))
            let next = try await drawnFrame(of: window)
            if next == previous {
                return
            }
            previous = next
        }
        throw CaptureError("the \(screen.rawValue) screen did not settle")
    }

    private func waitForRecordings(from previous: Data?, in window: UIWindow) async throws {
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(33))
            if coordinator.captureShowsRecordings {
                if try await drawnFrame(of: window) != previous { return }
            }
        }
        throw CaptureError("the history-recordings screen did not appear")
    }

    private func activateToolbarButton(in window: UIWindow) throws {
        func navigationBar(in view: UIView) -> UINavigationBar? {
            if let bar = view as? UINavigationBar { return bar }
            return view.subviews.lazy.compactMap(navigationBar).first
        }
        func controls(in view: UIView) -> [UIControl] {
            let own = (view as? UIControl).map { [$0] } ?? []
            return own + view.subviews.flatMap(controls)
        }
        guard let bar = navigationBar(in: window) else {
            throw CaptureError("the navigation bar did not appear")
        }
        let trailing = controls(in: bar).filter {
            !$0.allTargets.isEmpty && $0.convert($0.bounds, to: bar).midX > bar.bounds.midX
        }
        guard trailing.count == 1, let button = trailing.first else {
            throw CaptureError("expected one trailing toolbar button, found \(trailing.count)")
        }
        button.sendActions(for: .touchUpInside)
    }

    private func selectSegment(_ index: Int, in window: UIWindow) throws {
        guard let control = segmentedControl(in: window) else {
            throw CaptureError("the screen has no segmented control")
        }
        control.selectedSegmentIndex = index
        control.sendActions(for: .valueChanged)
    }

    private func segmentedControl(in view: UIView) -> UISegmentedControl? {
        if let control = view as? UISegmentedControl {
            return control
        }
        return view.subviews.lazy.compactMap(segmentedControl).first
    }

    private func screenshot(_ screen: CaptureScreen, in directory: URL) async throws -> UIImage {
        let file = directory.appending(path: "\(screen.rawValue).png")
        try Data(screen.rawValue.utf8).write(to: directory.appending(path: "ready"), options: .atomic)
        for _ in 0..<15_000 {
            if let image = UIImage(contentsOfFile: file.path()) {
                return image
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CaptureError("the driver took no screenshot of \(screen.rawValue)")
    }

    private func drawnFrame(of window: UIWindow) async throws -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.traitCollection.displayScale
        format.opaque = true
        while true {
            var complete = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                complete = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            if complete {
                return image.cgImage?.dataProvider?.data as Data?
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func composeContactSheet(_ items: [(screen: CaptureScreen, image: UIImage)]) throws -> Data {
        let cellHeight: CGFloat = 760
        let first = items[0].image
        let cellWidth = (first.size.width * cellHeight / first.size.height).rounded()
        let columns = min(items.count, 4)
        let rows = (items.count + columns - 1) / columns
        let padding: CGFloat = 36
        let labelHeight: CGFloat = 64
        let sheetSize = CGSize(
            width: padding + CGFloat(columns) * (cellWidth + padding),
            height: padding + CGFloat(rows) * (cellHeight + labelHeight)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: UIColor(white: 0.93, alpha: 1),
        ]
        let sheet = UIGraphicsImageRenderer(size: sheetSize, format: format).image { context in
            UIColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: sheetSize))
            for (index, item) in items.enumerated() {
                let col = index % columns
                let row = index / columns
                let x = padding + CGFloat(col) * (cellWidth + padding)
                let y = padding + CGFloat(row) * (cellHeight + labelHeight)
                item.image.draw(in: CGRect(x: x, y: y, width: cellWidth, height: cellHeight))
                let labelRect = CGRect(x: x + 4, y: y + cellHeight + 14, width: cellWidth - 8, height: labelHeight - 14)
                (item.screen.title as NSString).draw(in: labelRect, withAttributes: attributes)
            }
        }
        guard let jpg = sheet.jpegData(compressionQuality: 0.85) else {
            throw CaptureError("could not encode contact sheet JPEG")
        }
        return jpg
    }
}

nonisolated private enum CaptureFiles {
    @concurrent static func write(_ image: UIImage, named id: String, into directory: URL) async throws -> UIImage {
        let height: CGFloat = 900 / image.scale
        guard let thumbnail = image.preparingThumbnail(of: CGSize(width: image.size.width * height / image.size.height, height: height)),
              let jpeg = thumbnail.jpegData(compressionQuality: 0.82) else {
            throw CaptureError("could not make the \(id) thumbnail")
        }
        try jpeg.write(to: directory.appending(path: "\(id).jpg"), options: .atomic)
        return thumbnail
    }
}

private enum CaptureFixture {
    static let languages = ["es"]
    static let terms = ["Saoirse", "Joaquín", "Dr. Okonkwo", "Kubernetes", "Figma", "Bergström"]
    static let transcripts: [(minutesAgo: Int, durationMs: Int?, bytes: Int?, text: String)] = [
        (2, 5400, 68_420, "Running ten minutes late, save me a seat by the window."),
        (24, 6200, 79_104, "Remind Saoirse to send the Figma file before Thursday’s review."),
        (70, 5800, 74_880, "Pick up oat milk, basil, two lemons and something for dessert."),
        (190, nil, nil, "The Kubernetes upgrade went smoothly. Rolling out to production tomorrow morning."),
        (320, nil, nil, "Happy birthday, Joaquín! Hope you get some sun this weekend."),
        (1500, nil, nil, "Notes from the call with Dr. Okonkwo: start the new routine on Monday and check in after two weeks."),
    ]

    static func seed(_ coordinator: DictationCoordinator) throws {
        coordinator.access.preview("available")
        coordinator.dictationLanguages = ["en"]
        for language in languages {
            coordinator.addDictationLanguage(language)
        }
        for term in terms {
            coordinator.dataStore.addVocabularyTerm(term)
        }
        let context = coordinator.dataStore.container.mainContext
        for transcript in transcripts.reversed() {
            let createdAt = Date.now - Double(transcript.minutesAgo * 60)
            var recordingID: UUID?
            if let durationMs = transcript.durationMs, let bytes = transcript.bytes {
                let id = UUID()
                let info = AudioRecordingInfo(
                    id: id,
                    createdAt: createdAt,
                    providerRawValue: TranscriptionProviderType.dictation.rawValue,
                    providerDisplayName: TranscriptionProviderType.dictationDisplayName,
                    deviceName: "iPhone",
                    source: "ios/keyboard",
                    durationMilliseconds: durationMs,
                    byteCount: bytes,
                    sha256: String(repeating: "a", count: 64),
                    fileType: .caf
                )
                context.insert(try AudioRecording(info: info, uploaded: true))
                recordingID = id
            }
            coordinator.dataStore.record(
                text: transcript.text,
                audioRecordingID: recordingID,
                createdAt: createdAt
            )
        }
        try context.save()
    }

    static func configure(_ coordinator: DictationCoordinator, for screen: CaptureScreen) {
        coordinator.navigationPath = []
        switch screen {
        case .homeRecording:
            coordinator.access.preview("low")
            coordinator.setCapturePhase(.recording)
        default:
            coordinator.access.preview("available")
            coordinator.setCapturePhase(.idle)
        }
    }


}

private struct KeyboardScene: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var bridge: KeyboardBridgeClient

    init(scenario: KeyboardPreviewScenario) {
        let client = KeyboardBridgeClient(sharedDefaults: nil)
        client.applyPreviewSnapshot(scenario.snapshot)
        _bridge = State(initialValue: client)
    }

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
    }

    private var dockBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.17, green: 0.17, blue: 0.18)
            : Color(red: 0.82, green: 0.84, blue: 0.86)
    }

    private var dockForeground: Color {
        colorScheme == .dark
            ? Color(white: 0.72)
            : Color(white: 0.32)
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
            .foregroundStyle(dockForeground)
            .padding(.horizontal, 30)
            .frame(height: 30)
            .padding(.bottom, 4)
        }
        .padding(.top, 6)
        .background(dockBackground, ignoresSafeAreaEdges: .bottom)
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

nonisolated private struct CaptureError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
#endif
