#if MUMLA_SCREENSHOTS
import SwiftData
import SwiftUI
import UIKit

enum CaptureScreen: String, CaseIterable {
    case home
    case homeRecording = "home-recording"
    case homeDark = "home-dark"
    case history
    case historyRecordings = "history-recordings"
    case historyStats = "history-stats"
    case dictionary
    case settings
    case onboardingEnable = "onboarding-enable"
    case onboardingDictate = "onboarding-dictate"
    case keyboardStart = "keyboard-start"
    case keyboardIdle = "keyboard-idle"
    case keyboard
    case keyboardProcessing = "keyboard-processing"
    case keyboardError = "keyboard-error"
    case keyboardDark = "keyboard-dark"

    var title: String {
        switch self {
        case .home: "Home · App Store"
        case .homeRecording: "Home · Recording"
        case .homeDark: "Home · Dark"
        case .history: "History · Transcripts"
        case .historyRecordings: "History · Recordings"
        case .historyStats: "History · Stats"
        case .dictionary: "Settings · App Store"
        case .settings: "Settings"
        case .onboardingEnable: "Onboarding · Enable"
        case .onboardingDictate: "Onboarding · Dictate"
        case .keyboardStart: "Keyboard · Start Session"
        case .keyboardIdle: "Keyboard · Idle"
        case .keyboard: "Keyboard · Recording"
        case .keyboardProcessing: "Keyboard · Processing"
        case .keyboardError: "Keyboard · Error"
        case .keyboardDark: "Keyboard · Dark"
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .home, .dictionary, .keyboard, .keyboardStart, .keyboardIdle, .keyboardProcessing, .keyboardError:
            .light
        default:
            .dark
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

    var body: some View {
        Group {
            switch screen {
            case .keyboard, .keyboardDark:
                KeyboardScene(scenario: .recording)
            case .keyboardStart:
                KeyboardScene(scenario: .start)
            case .keyboardIdle:
                KeyboardScene(scenario: .idle)
            case .keyboardProcessing:
                KeyboardScene(scenario: .processing)
            case .keyboardError:
                KeyboardScene(scenario: .error)
            case .dictionary:
                SettingsView()
            case .settings:
                ContentView()
                    .sheet(isPresented: .constant(true)) { SettingsView() }
            case .home, .homeRecording, .homeDark, .history:
                ContentView()
            case .historyRecordings:
                PushedOnAppear {
                    TranscriptionHistoryView(showsRecordings: true)
                }
            case .historyStats:
                ContentView()
                    .sheet(isPresented: .constant(true)) {
                        HistoryStatsView(stats: try! CaptureFixture.makeStats(coordinator))
                    }
            case .onboardingEnable:
                OnboardingView(coordinator: coordinator, capturePhase: .enable)
            case .onboardingDictate:
                OnboardingView(coordinator: coordinator, capturePhase: .dictate)
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
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["MUMLA_CAPTURE"].map({ URL(filePath: $0) }) else {
            throw CaptureError("MUMLA_CAPTURE names no output directory")
        }
        let screens = try CaptureScreen.named(env["MUMLA_CAPTURE_SCREENS"])
        UIView.setAnimationsEnabled(false)
        try CaptureFixture.seed(coordinator)
        let window = try await keyWindow()
        var shown = appeared.stream.makeAsyncIterator()
        var captured: [(screen: CaptureScreen, image: UIImage)] = []
        let jpgDirectory = directory.appending(path: "jpg", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: jpgDirectory, withIntermediateDirectories: true)

        for next in screens {
            CaptureFixture.configure(coordinator, for: next)
            window.overrideUserInterfaceStyle = next.colorScheme == .dark ? .dark : .light
            screen = next
            guard await shown.next(isolation: #isolation) == next else {
                throw CaptureError("the \(next.rawValue) screen did not appear")
            }
            if [.history, .historyStats].contains(next) {
                coordinator.navigationPath = [.history]
            }
            try await settle(window)
            let image = try await screenshot(next, in: directory)
            let jpg = try downscaledJPEG(of: image, maxHeight: 900)
            try jpg.write(to: jpgDirectory.appending(path: "\(next.rawValue).jpg"), options: .atomic)
            captured.append((next, image))
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

    private func settle(_ window: UIWindow) async throws {
        var previous = try await drawnFrame(of: window)
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(33))
            let next = try await drawnFrame(of: window)
            if next == previous {
                return
            }
            previous = next
        }
    }

    private func screenshot(_ screen: CaptureScreen, in directory: URL) async throws -> UIImage {
        let file = directory.appending(path: "\(screen.rawValue).png")
        try Data(screen.rawValue.utf8).write(to: directory.appending(path: "ready"), options: .atomic)
        for _ in 0..<500 {
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

    private func downscaledJPEG(of image: UIImage, maxHeight: CGFloat) throws -> Data {
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let targetWidth = (pixelSize.width * maxHeight / pixelSize.height).rounded()
        let targetSize = CGSize(width: targetWidth, height: maxHeight)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let scaled = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard let jpg = scaled.jpegData(compressionQuality: 0.82) else {
            throw CaptureError("could not encode resized JPEG")
        }
        return jpg
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
            .font: UIFont.systemFont(ofSize: 24, weight: .semibold),
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

    static func makeStats(_ coordinator: DictationCoordinator) throws -> HistoryStats {
        let entries = try coordinator.dataStore.container.mainContext.fetch(
            FetchDescriptor<HistoryEntry>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        )
        return HistoryStats(entries: entries, storeSizeInBytes: coordinator.dataStore.storeSizeInBytes)
    }
}

private struct PushedOnAppear<Destination: View>: View {
    @ViewBuilder let destination: Destination
    @State private var path: [Int] = []

    var body: some View {
        NavigationStack(path: $path) {
            Color(uiColor: .systemGroupedBackground)
                .navigationDestination(for: Int.self) { _ in destination }
                .task { path = [0] }
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

private struct CaptureError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
#endif
