import SwiftData
import SwiftUI

enum MainTab: Hashable {
    case transcripts
    case dictionary
    case search
}

enum TranscriptRoute: Hashable {
    case transcript(UUID)
}

enum ContentSheet: Identifiable {
    case dictation
    case account
    case pro

    var id: Self { self }
}

struct ContentView: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Namespace private var dictationTransition
    @State private var microphoneLevels = MicrophoneLevelHistory()

    var body: some View {
        @Bindable var coordinator = coordinator
        TabView(selection: $coordinator.selectedTab) {
            Tab("Transcripts", systemImage: "text.quote", value: MainTab.transcripts) {
                NavigationStack(path: $coordinator.transcriptsPath) {
                    TranscriptsView { coordinator.transcriptsPath.append(.transcript($0)) }
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                AccountButton(access: coordinator.access) { coordinator.presentedSheet = .account }
                            }
                        }
                        .transcriptDestinations()
                }
            }
            Tab("Dictionary", systemImage: "character.book.closed", value: MainTab.dictionary) {
                NavigationStack {
                    DictionaryView()
                }
            }
            Tab(value: MainTab.search, role: .search) {
                SearchView()
            }
        }
        .tabViewBottomAccessory {
            DictationStrip()
                .matchedTransitionSource(id: DictationStrip.transitionID, in: dictationTransition)
                .environment(microphoneLevels)
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .dictationFeedback(phase: coordinator.phase)
        .sheet(item: $coordinator.presentedSheet) { sheet in
            switch sheet {
            case .dictation:
                NowDictatingView()
                    .navigationTransition(.zoom(sourceID: DictationStrip.transitionID, in: dictationTransition))
                    .environment(microphoneLevels)
            case .account:
                AccountView()
            case .pro:
                ProOfferView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            coordinator.refreshCopiedTranscript()
        }
        .task(id: coordinator.phase == .recording) {
            await microphoneLevels.record(from: coordinator)
        }
    }
}

extension View {
    func transcriptDestinations() -> some View {
        navigationDestination(for: TranscriptRoute.self) { route in
            switch route {
            case .transcript(let id):
                TranscriptView(id: id)
            }
        }
    }
}

private struct AccountButton: View {
    let access: MumlaAccess
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if case .available(let allowance) = access.state {
                AllowanceRing(allowance: allowance)
            } else {
                Image(systemName: "person.crop.circle")
            }
        }
        .accessibilityLabel("Account")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: Text {
        guard case .available(let allowance) = access.state else { return Text(verbatim: "") }
        return allowance.showsProBadge ? Text("Mumla Pro") : Text(allowance.remainingSpokenText)
    }
}

private struct AllowanceRing: View {
    let allowance: MumlaAccess.Allowance
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 30

    var body: some View {
        ZStack {
            Circle()
                .stroke(.fill.tertiary, lineWidth: 3)
            Circle()
                .trim(from: 0, to: fractionLeft)
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(label)
                .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
                .minimumScaleFactor(0.6)
                .padding(4)
        }
        .frame(width: size, height: size)
        .animation(.smooth, value: allowance)
    }

    private var fractionLeft: Double {
        guard !allowance.showsProBadge else { return 1 }
        guard allowance.limit > .zero else { return 0 }
        return allowance.remaining / allowance.limit
    }

    private var label: String {
        allowance.showsProBadge ? String(localized: "PRO") : allowance.remainingShortText
    }

    private var tint: AnyShapeStyle {
        if allowance.isExhausted {
            AnyShapeStyle(.secondary)
        } else if allowance.isRunningLow {
            AnyShapeStyle(.orange)
        } else {
            AnyShapeStyle(.tint)
        }
    }
}
