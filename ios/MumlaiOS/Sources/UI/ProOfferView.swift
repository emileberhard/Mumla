import StoreKit
import SwiftUI

struct ProOfferView: View {
    @Environment(ProStore.self) private var pro
    @Environment(\.dismiss) private var dismiss
    @State private var token: Result<UUID, any Error>?
    @State private var isManaging = false

    init() {}

    #if MUMLA_SCREENSHOTS
    init(previewToken: UUID) {
        _token = State(initialValue: .success(previewToken))
    }
    #endif

    var body: some View {
        content
            .onChange(of: pro.isPro) { _, isPro in
                if isPro { dismiss() }
            }
            .onChange(of: pro.access.accountGeneration) { token = nil }
            .manageSubscriptionsSheet(isPresented: $isManaging, subscriptionGroupID: MumlaPro.subscriptionGroupID)
    }

    @ViewBuilder
    private var content: some View {
        switch (pro.activation, token) {
        case (.activating, _):
            closable { ProgressView("Activating Mumla Pro") }
        case (.pending, _):
            closable {
                ContentUnavailableView {
                    Label("Mumla Pro Isn't Active Yet", systemImage: "clock.badge.exclamationmark")
                } description: {
                    Text("Your purchase went through.")
                } actions: {
                    Button("Try Again") { Task { await pro.reconcile() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        case (.ownedElsewhere, _):
            closable {
                ContentUnavailableView {
                    Label("Mumla Pro Belongs to Another iCloud Account", systemImage: "person.crop.circle.badge.exclamationmark")
                } actions: {
                    Button("Manage Subscription") { isManaging = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        case (.idle, nil):
            closable {
                ProgressView()
                    .task { await loadToken() }
            }
        case (.idle, .failure?):
            closable {
                ContentUnavailableView {
                    Label("Can't Reach Mumla", systemImage: "wifi.exclamationmark")
                } actions: {
                    Button("Try Again") { token = nil }
                        .buttonStyle(.borderedProminent)
                }
            }
        case (.idle, .success(let token)?):
            store(purchasingFor: token)
        }
    }

    private func store(purchasingFor token: UUID) -> some View {
        SubscriptionStoreView(groupID: MumlaPro.subscriptionGroupID) {
            ProOfferHeader(hours: pro.plan?.proHours)
        }
        .storeButton(.visible, for: .restorePurchases)
        .subscriptionStorePolicyDestination(url: MumlaPro.privacyPolicyURL, for: .privacyPolicy)
        .subscriptionStorePolicyDestination(url: MumlaPro.termsOfUseURL, for: .termsOfService)
        .inAppPurchaseOptions { _ in [.appAccountToken(token)] }
        .subscriptionStatusTask(for: MumlaPro.subscriptionGroupID) { state in
            if let statuses = state.value { await pro.reconcile(statuses) }
        }
    }

    private func closable(@ViewBuilder _ content: () -> some View) -> some View {
        NavigationStack {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    }
                }
        }
    }

    private func loadToken() async {
        do {
            token = .success(try await pro.access.accountToken())
        } catch is CancellationError {
        } catch {
            token = .failure(error)
        }
    }
}

private struct ProOfferHeader: View {
    let hours: Int?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeat(.continuous))
                .accessibilityHidden(true)
            Text("Mumla Pro")
                .font(.largeTitle.bold())
            if let hours {
                Text("\(hours) hours of dictation a month")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.top, 40)
        .padding(.horizontal)
    }
}

struct ProUpgradeRow<Content: View>: View {
    @Environment(ProStore.self) private var pro
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isOffering = false
    @ViewBuilder let content: Content

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            content
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            action
        }
        .sheet(isPresented: $isOffering) { ProOfferView() }
    }

    @ViewBuilder
    private var action: some View {
        if pro.activation == .activating {
            ProgressView()
        } else if pro.activation == .idle, case .available(let allowance) = pro.access.state, allowance.offersPro, allowance.isRunningLow {
            Button("Get Pro") { isOffering = true }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
        }
    }
}

struct ProPlanRows<Allowance: View>: View {
    @Environment(ProStore.self) private var pro
    @State private var isOffering = false
    @State private var isManaging = false
    @State private var isRestoring = false
    @State private var restoreProblem: ProStore.RestoreProblem?
    @ViewBuilder let allowance: Allowance

    var body: some View {
        allowance
            .sheet(isPresented: $isOffering) { ProOfferView() }
            .manageSubscriptionsSheet(isPresented: $isManaging, subscriptionGroupID: MumlaPro.subscriptionGroupID)
            .alert(restoreProblem.map(Self.title) ?? "", isPresented: .init(get: { restoreProblem != nil }, set: { if !$0 { restoreProblem = nil } })) {}
        rows
    }

    @ViewBuilder
    private var rows: some View {
        switch (pro.plan, pro.activation) {
        case (nil, _), (.notOffered?, _):
            EmptyView()
        case (.pro?, _):
            Button("Manage Subscription") { isManaging = true }
        case (_, .activating):
            LabeledContent("Activating Mumla Pro") { ProgressView() }
        case (_, .pending):
            LabeledContent("Mumla Pro Isn't Active Yet") {
                Button("Try Again") { Task { await pro.reconcile() } }
            }
        case (_, .ownedElsewhere):
            Text("Mumla Pro belongs to another iCloud account.")
            Button("Manage Subscription") { isManaging = true }
        case (.free?, .idle):
            Button("Get Mumla Pro") { isOffering = true }
            Button {
                Task { await restore() }
            } label: {
                LabeledContent("Restore Purchases") {
                    if isRestoring { ProgressView() }
                }
            }
            .disabled(isRestoring)
        }
    }

    private func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        restoreProblem = await pro.restore()
    }

    private static func title(_ problem: ProStore.RestoreProblem) -> LocalizedStringKey {
        switch problem {
        case .nothingFound: "No Mumla Pro Subscription Found"
        case .failed: "Couldn't Restore Purchases"
        }
    }
}
