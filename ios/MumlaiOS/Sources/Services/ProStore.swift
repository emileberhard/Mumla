import CloudKit
import Observation
import StoreKit

@MainActor
@Observable
final class ProStore {
    enum Activation: Equatable {
        case idle
        case activating
        case pending
        case ownedElsewhere
    }

    enum RestoreOutcome {
        case restored
        case ownedElsewhere
        case nothingFound
        case failed
    }

    private(set) var activation: Activation = .idle
    let access: MumlaAccess
    @ObservationIgnored private var pending: VerificationResult<Transaction>?
    @ObservationIgnored private var answered: Set<Answer> = []
    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private var accountObserver: (any NSObjectProtocol)?

    private struct Answer: Hashable {
        let transactionID: UInt64
        let revoked: Bool
    }

    init(access: MumlaAccess) {
        self.access = access
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.deliver(result)
            }
        }
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.accountChanged() }
        }
    }

    isolated deinit {
        updates?.cancel()
        if let accountObserver {
            NotificationCenter.default.removeObserver(accountObserver)
        }
    }

    var plan: MumlaAccess.Plan? {
        guard case .available(let allowance) = access.state else { return nil }
        return allowance.plan
    }

    var isPro: Bool { plan == .pro }

    func accountToken() async throws -> UUID {
        try await access.accountToken()
    }

    func reconcile() async {
        if let pending {
            await deliver(pending)
        }
        guard let statuses = try? await Product.SubscriptionInfo.status(for: MumlaPro.subscriptionGroupID) else { return }
        for status in statuses where status.state == .subscribed {
            guard case .verified(let transaction) = status.transaction, !answered.contains(Self.answer(for: transaction)) else { continue }
            await deliver(status.transaction)
        }
    }

    func retry() async {
        guard let pending else { return }
        await deliver(pending)
    }

    func restore() async -> RestoreOutcome {
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            return isPro ? .restored : .nothingFound
        } catch {
            return .failed
        }
        answered.removeAll()
        if activation == .ownedElsewhere { activation = .idle }
        await reconcile()
        if isPro { return .restored }
        switch activation {
        case .ownedElsewhere: return .ownedElsewhere
        case .pending: return .failed
        case .idle, .activating: return .nothingFound
        }
    }

    private func deliver(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else {
            CrashReporting.breadcrumb("Pro transaction failed verification", category: "pro")
            return
        }
        guard transaction.subscriptionGroupID == MumlaPro.subscriptionGroupID else { return }
        activation = .activating
        let outcome: String
        do {
            try await access.submitPurchase(signedTransaction: result.jwsRepresentation)
            activation = .idle
            outcome = "accepted"
        } catch PurchaseRejection.ownedElsewhere {
            activation = .ownedElsewhere
            outcome = "owned_elsewhere"
        } catch PurchaseRejection.invalid {
            activation = .idle
            outcome = "invalid"
        } catch {
            pending = result
            activation = .pending
            CrashReporting.breadcrumb("Pro activation pending", category: "pro", metadata: DiagnosticError(error).metadata)
            return
        }
        CrashReporting.breadcrumb("Pro transaction answered", category: "pro", metadata: ["outcome": outcome])
        if case .verified(let held)? = pending, held.id == transaction.id { pending = nil }
        answered.insert(Self.answer(for: transaction))
        await transaction.finish()
    }

    private func accountChanged() {
        answered.removeAll()
        if activation == .ownedElsewhere { activation = .idle }
    }

    private static func answer(for transaction: Transaction) -> Answer {
        Answer(transactionID: transaction.id, revoked: transaction.revocationDate != nil)
    }
}
