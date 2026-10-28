import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @State private var isShowingSettings = false

    var body: some View {
        @Bindable var coordinator = coordinator
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                RecentTranscriptionsCard()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 10) {
                    if coordinator.access.state.isWorthNoticing {
                        AllowanceView(access: coordinator.access)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if !coordinator.lastErrorMessage.isEmpty {
                        Label(coordinator.lastErrorMessage, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    DictationPill()
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
                .animation(.smooth, value: coordinator.access.state.isWorthNoticing)
                .background(Color(uiColor: .systemGroupedBackground))
            }
            .navigationDestination(isPresented: $coordinator.showTranscriptionHistory) {
                TranscriptionHistoryView()
            }
            .navigationTitle("Mumla")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") {
                        isShowingSettings = true
                    }
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsView()
            }
        }
    }
}

/// Fills the space between the navigation bar and the dictation pill with the
/// newest transcriptions. The rows live in a disabled ScrollView so overflow
/// is clipped (drawing and touches) instead of scrolling; the last visible
/// row may truncate. See All is pinned at the card's bottom edge.
private struct RecentTranscriptionsCard: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \HistoryEntry.createdAt, order: .reverse) private var entries: [HistoryEntry]
    private static let maxPreviewEntries = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent Transcriptions")
                .font(.title3.bold())
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 4)
            if entries.isEmpty {
                Text("Transcriptions appear here as you dictate.")
                    .foregroundStyle(.secondary)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                previewRows
                Divider()
                    .padding(.leading, 20)
                seeAllRow
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
        .task(id: scenePhase) {
            guard RemoteChangePollingPolicy.shouldPoll(in: scenePhase) else { return }
            await coordinator.dataStore.refreshRemoteChangesWhileVisible()
        }
    }

    private var previewRows: some View {
        let shown = Array(entries.prefix(Self.maxPreviewEntries))
        return ScrollView {
            VStack(spacing: 0) {
                ForEach(shown) { entry in
                    TranscriptionHistoryRow(entry: entry)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    if entry.id != shown.last?.id {
                        Divider()
                            .padding(.leading, 20)
                    }
                }
            }
        }
        .scrollDisabled(true)
        .mask(bottomFade)
    }

    /// Fades the clipped edge so a cut-off row reads as "continues below".
    private var bottomFade: some View {
        VStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 28)
        }
    }

    private var seeAllRow: some View {
        NavigationLink {
            TranscriptionHistoryView()
        } label: {
            HStack {
                Label {
                    Text("See All (\(entries.count))")
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.tint)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .contentShape(.rect)
        }
    }
}

/// The same pill the keyboard shows, state-mapped to the in-app coordinator,
/// so the app control matches what the keyboard has made familiar.
private struct DictationPill: View {
    private static let height: CGFloat = 56

    @Environment(DictationCoordinator.self) private var coordinator

    var body: some View {
        Button(action: toggle) {
            DictationPillContent(
                symbolName: symbolName,
                title: title,
                foregroundColor: foregroundColor,
                symbolColor: symbolColor,
                showsProgress: coordinator.phase == .processing,
                showsCassette: coordinator.phase == .recording,
                recordingStartDate: coordinator.recordingStartDate,
                recordingDeadline: coordinator.recordingDeadline,
                fillsWidth: true,
                height: Self.height
            )
            .dictationPillBackground(backgroundColor)
        }
        .buttonStyle(ControlPressButtonStyle(playsFeedback: coordinator.phase != .processing))
        .disabled(isBlocked)
        .opacity(isBlocked ? 0.4 : 1)
        .contextMenu {
            if coordinator.sessionActive {
                Button("End Session", systemImage: "stop.circle", role: .destructive) {
                    coordinator.requestSessionEnd()
                }
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.startsMediaSession)
    }

    private var isBlocked: Bool {
        coordinator.access.state.blocksDictation && coordinator.phase != .recording && coordinator.phase != .processing
    }

    private var backgroundColor: Color {
        switch coordinator.phase {
        case .recording:
            DictationPillPalette.recording
        case .processing, .error:
            DictationPillPalette.control
        default:
            Color.accentColor
        }
    }

    private var foregroundColor: Color {
        switch coordinator.phase {
        case .recording, .idle, .success:
            .white
        default:
            .primary
        }
    }

    private var symbolColor: Color? {
        coordinator.phase == .error ? DictationPillPalette.warning : nil
    }

    private var symbolName: String? {
        switch coordinator.phase {
        case .recording, .processing: nil
        case .error: "exclamationmark.triangle.fill"
        default: "mic.fill"
        }
    }

    private var title: String? {
        switch coordinator.phase {
        case .recording: nil
        case .processing: "Transcribing"
        case .error: "Try Again"
        default: "Dictate"
        }
    }

    private var accessibilityLabel: String {
        switch coordinator.phase {
        case .recording: "Finish dictation"
        case .processing: "Transcribing"
        case .error: "Try dictation again"
        default: "Start dictation"
        }
    }

    private func toggle() {
        switch coordinator.phase {
        case .recording:
            coordinator.requestDictationStop()
        case .processing:
            break
        default:
            guard coordinator.microphoneAuthorized else {
                coordinator.requestMicrophonePermission()
                return
            }
            if !coordinator.sessionActive {
                coordinator.requestSessionStart()
            }
            coordinator.requestDictationStart()
        }
    }
}

/// Press-down feedback matching KeyboardFeedback.controlPressed, so the app
/// pill feels like the keyboard's.
@MainActor
private enum ControlHaptics {
    private static let impact: UIImpactFeedbackGenerator = {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        return generator
    }()

    static func controlPressed() {
        impact.impactOccurred(intensity: 0.75)
        impact.prepare()
    }
}

private struct ControlPressButtonStyle: ButtonStyle {
    let playsFeedback: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed, playsFeedback {
                    ControlHaptics.controlPressed()
                }
            }
    }
}
