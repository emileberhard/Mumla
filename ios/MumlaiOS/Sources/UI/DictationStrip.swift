import SwiftUI

struct DictationStrip: View {
    static let transitionID = "dictation"

    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 12) {
            Button(action: primaryAction) {
                label
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(coordinator.phase == .processing)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
            .accessibilityAddTraits(.startsMediaSession)
            .accessibilityHint(offersPro ? Text("Shows Mumla Pro") : Text(verbatim: ""))
            .accessibilityShowsLargeContentViewer()
            if coordinator.phase == .recording {
                Button {
                    coordinator.requestDictationStop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .foregroundStyle(.red)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, coordinator.phase == .recording ? 4 : 16)
        .contextMenu {
            if coordinator.sessionActive {
                Button("End Session", systemImage: "stop.circle", role: .destructive) {
                    coordinator.requestSessionEnd()
                }
            }
        }
        .animation(.snappy, value: coordinator.phase)
        .onChange(of: coordinator.phase) { _, phase in
            if phase == .error, !coordinator.lastErrorMessage.isEmpty {
                AccessibilityNotification.Announcement(coordinator.lastErrorMessage).post()
            }
        }
    }

    @ViewBuilder
    private var label: some View {
        HStack(spacing: 10) {
            switch coordinator.phase {
            case .recording:
                Circle()
                    .fill(.red)
                    .frame(width: 9, height: 9)
                RecordingTime(start: coordinator.recordingStartDate, deadline: nil)
                    .font(.body.monospacedDigit().weight(.semibold))
                if placement != .inline {
                    MicrophoneLevelBars(spacing: 2.5, barWidth: 2.5)
                        .foregroundStyle(.red)
                        .frame(height: 18)
                }
            case .processing:
                ProcessingIndicator()
                Text("Transcribing")
                    .font(.headline)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Try Again")
                    .font(.headline)
            case .idle, .success:
                if let blocked {
                    Image(systemName: blocked.systemImage)
                        .foregroundStyle(.orange)
                    Text(blocked.title)
                        .font(.headline)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                    Text("Dictate")
                        .font(.headline)
                    if placement != .inline, !dynamicTypeSize.isAccessibilitySize, let lowMinutes {
                        Spacer(minLength: 8)
                        Text("\(lowMinutes) min left")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .contentTransition(.numericText(countsDown: true))
                    }
                }
            }
        }
        .lineLimit(1)
    }

    private var lowMinutes: Int? {
        guard case .available(let allowance) = coordinator.access.state, allowance.isRunningLow else { return nil }
        return allowance.remaining.wholeMinutes
    }

    private var blocked: DictationBlock? {
        coordinator.access.state.blocksDictation ? DictationBlock(coordinator.access.state) : nil
    }

    private var offersPro: Bool {
        guard case .available(let allowance) = coordinator.access.state else { return false }
        return allowance.isExhausted && allowance.offersPro
    }

    private var accessibilityLabel: Text {
        switch coordinator.phase {
        case .recording: Text("Recording")
        case .processing: Text("Transcribing")
        case .error: Text("Try dictation again")
        case .idle, .success: blocked.map { Text($0.title) } ?? Text("Dictate")
        }
    }

    private var accessibilityValue: Text {
        if coordinator.phase == .error {
            return Text(coordinator.lastErrorMessage)
        }
        if let lowMinutes {
            return Text("\(lowMinutes) minutes left")
        }
        return Text(verbatim: "")
    }

    private func primaryAction() {
        switch coordinator.phase {
        case .recording:
            coordinator.presentedSheet = .dictation
        case .processing:
            break
        case .idle where blocked != nil, .success where blocked != nil:
            coordinator.presentedSheet = offersPro ? .pro : .account
        case .idle, .success, .error:
            let canRecord = coordinator.microphoneAuthorized
            coordinator.startDictation()
            if canRecord { coordinator.presentedSheet = .dictation }
        }
    }
}

struct NowDictatingView: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .largeTitle) private var timerSize: CGFloat = 64

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 32)
            Group {
                if coordinator.phase == .processing {
                    Text("Transcribing")
                } else {
                    RecordingTime(start: coordinator.recordingStartDate, deadline: coordinator.recordingDeadline)
                }
            }
            .font(.system(size: timerSize, weight: .light, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .accessibilityAddTraits(.updatesFrequently)
            Spacer(minLength: 24)
            MicrophoneLevelBars(spacing: 3.5, barWidth: 4)
                .foregroundStyle(.red)
                .frame(height: 160)
                .mask {
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.35)], startPoint: .leading, endPoint: .trailing)
                }
            Spacer(minLength: 24)
            controls
                .padding(.horizontal, 28)
        }
        .padding(.top, 20)
        .padding(.bottom, 12)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onChange(of: coordinator.phase) { old, new in
            if old == .recording || new == .error { dismiss() }
        }
    }

    private var controls: some View {
        HStack {
            sideButton("Cancel", systemImage: "xmark") {
                coordinator.requestDictationCancel()
                dismiss()
            }
            Spacer()
            Button {
                coordinator.requestDictationStop()
                dismiss()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 30, weight: .semibold))
                    .frame(width: 76, height: 76)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(.red)
            .disabled(coordinator.phase != .recording)
            Spacer()
            sideButton("Minimize", systemImage: "chevron.down") {
                dismiss()
            }
        }
    }

    private func sideButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .frame(width: 56, height: 56)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }
}

extension DictationCoordinator {
    func startDictation() {
        guard microphoneAuthorized else {
            requestMicrophonePermission()
            return
        }
        if !sessionActive {
            requestSessionStart()
        }
        requestDictationStart()
    }
}

extension View {
    func dictationFeedback(phase: DictationPhase) -> some View {
        sensoryFeedback(trigger: phase) { old, new in
            switch (old, new) {
            case (_, .recording): .impact(weight: .medium)
            case (.recording, _): .impact(weight: .light)
            case (_, .success): .success
            case (_, .error): .error
            default: nil
            }
        }
    }
}

private struct DictationBlock {
    let title: LocalizedStringKey
    let systemImage: String

    init(_ state: MumlaAccess.State) {
        switch state {
        case .iCloudUnavailable where state.isICloudSignedOut:
            title = "Sign In to iCloud"
            systemImage = "icloud.slash"
        case .iCloudUnavailable:
            title = "iCloud Isn't Available"
            systemImage = "exclamationmark.icloud"
        case .serviceUnavailable:
            title = "Can't Reach Mumla"
            systemImage = "wifi.exclamationmark"
        case .available, .checking:
            title = "No Minutes Left"
            systemImage = "hourglass"
        }
    }
}

private struct RecordingTime: View {
    let start: Date?
    let deadline: Date?

    var body: some View {
#if MUMLA_SCREENSHOTS
        Text("0:14")
#else
        if let start, let deadline {
            let schedule = RecordingTimeSchedule(deadline: deadline)
            TimelineView(schedule) { context in
                if context.date >= schedule.countdownStart {
                    Text("\u{2212}\(Text(timerInterval: min(context.date, deadline)...deadline, countsDown: true, showsHours: false))")
                        .foregroundStyle(.orange)
                } else {
                    elapsed(since: start)
                }
            }
        } else if let start {
            elapsed(since: start)
        } else {
            Text("0:00")
        }
#endif
    }

    private func elapsed(since start: Date) -> Text {
        Text(timerInterval: start...Date.distantFuture, countsDown: false, showsHours: false)
    }
}

private struct ProcessingIndicator: View {
    var body: some View {
#if MUMLA_SCREENSHOTS
        Image(systemName: "progress.indicator")
            .accessibilityHidden(true)
#else
        ProgressView()
            .accessibilityHidden(true)
#endif
    }
}

@Observable
final class MicrophoneLevelHistory {
    private(set) var levels: [Double] = []

    private static let length = 96

    func record(from coordinator: DictationCoordinator) async {
        levels = []
        guard coordinator.phase == .recording else { return }
#if MUMLA_SCREENSHOTS
        levels = (0..<Self.length).map { 0.22 + 0.6 * abs(sin(Double($0) * 0.7)) * (0.55 + 0.45 * cos(Double($0) * 0.29)) }
#else
        while !Task.isCancelled {
            levels = Array((levels + [coordinator.microphoneLevel]).suffix(Self.length))
            try? await Task.sleep(for: .milliseconds(60))
        }
#endif
    }
}

private struct MicrophoneLevelBars: View {
    let spacing: CGFloat
    let barWidth: CGFloat
    @Environment(MicrophoneLevelHistory.self) private var history

    var body: some View {
        GeometryReader { proxy in
            let levels = history.levels
            let count = max(1, Int((proxy.size.width + spacing) / (barWidth + spacing)))
            let shown = Array(repeating: 0, count: max(0, count - levels.count)) + levels.suffix(count)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(shown.indices, id: \.self) { index in
                    Capsule()
                        .frame(width: barWidth, height: max(barWidth, proxy.size.height * shown[index]))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .trailing)
        }
        .accessibilityHidden(true)
    }
}
