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

    enum RestoreProblem {
        case nothingFound
        case failed
    }

    private enum Answer: String {
        case accepted
        case ownedElsewhere = "owned_elsewhere"
        case invalid
    }

    let access: MumlaAccess
    private var activating = 0
    private var pending: (account: Int, result: VerificationResult<Transaction>)?
    private var conflict: Int?
    @ObservationIgnored private var answers: (account: Int, byJWS: [String: Answer]) = (0, [:])
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var updates: Task<Void, Never>?

    init(access: MumlaAccess) {
        self.access = access
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.deliver(result)
            }
        }
    }

    isolated deinit {
        updates?.cancel()
    }

    var activation: Activation {
        let account = access.accountGeneration
        if activating > 0 { return .activating }
        if pending?.account == account { return .pending }
        if conflict == account { return .ownedElsewhere }
        return .idle
    }

    var plan: MumlaAccess.Plan? {
        guard case .available(let allowance) = access.state else { return nil }
        return allowance.plan
    }

    var isPro: Bool { plan == .pro }

    func reconcile() async {
        guard let statuses = try? await Product.SubscriptionInfo.status(for: MumlaPro.subscriptionGroupID) else { return }
        await reconcile(statuses)
    }

    func reconcile(_ statuses: [Product.SubscriptionInfo.Status]) async {
        let account = access.accountGeneration
        if let pending, pending.account == account {
            await deliver(pending.result)
        }
        var ownedElsewhere = false
        var settled = true
        for status in statuses {
            let answer = await deliver(status.transaction)
            guard case .verified(let transaction) = status.transaction, Self.entitles(transaction) else { continue }
            switch answer {
            case .ownedElsewhere?: ownedElsewhere = true
            case nil: settled = false
            case .accepted?, .invalid?: break
            }
        }
        guard account == access.accountGeneration else { return }
        if ownedElsewhere {
            conflict = account
        } else if settled, conflict == account {
            conflict = nil
        }
    }

    func restore() async -> RestoreProblem? {
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            return nil
        } catch {
            return .failed
        }
        guard let statuses = try? await Product.SubscriptionInfo.status(for: MumlaPro.subscriptionGroupID) else { return .failed }
        answers.byJWS.removeAll()
        await reconcile(statuses)
        switch activation {
        case .pending: return .failed
        case .idle where !isPro: return .nothingFound
        case .idle, .activating, .ownedElsewhere: return nil
        }
    }

    @discardableResult
    private func deliver(_ result: VerificationResult<Transaction>) async -> Answer? {
        guard case .verified(let transaction) = result else {
            CrashReporting.breadcrumb("Pro transaction failed verification", category: "pro")
            return nil
        }
        guard transaction.subscriptionGroupID == MumlaPro.subscriptionGroupID else { return nil }
        let account = access.accountGeneration
        if answers.account != account { answers = (account, [:]) }
        let jws = result.jwsRepresentation
        if let answer = answers.byJWS[jws] { return answer }
        guard inFlight.insert(jws).inserted else { return nil }
        defer { inFlight.remove(jws) }
        let entitles = Self.entitles(transaction)
        if entitles { activating += 1 }
        defer { if entitles { activating -= 1 } }
        let answer: Answer
        do {
            try await access.submitPurchase(signedTransaction: jws)
            answer = .accepted
        } catch PurchaseRejection.ownedElsewhere {
            answer = .ownedElsewhere
        } catch PurchaseRejection.invalid {
            answer = .invalid
        } catch {
            guard !(error is CancellationError), account == access.accountGeneration else { return nil }
            if entitles { pending = (account, result) }
            CrashReporting.breadcrumb("Pro activation pending", category: "pro", metadata: DiagnosticError(error).metadata)
            return nil
        }
        await transaction.finish()
        guard account == access.accountGeneration else { return nil }
        CrashReporting.breadcrumb("Pro transaction answered", category: "pro", metadata: ["outcome": answer.rawValue])
        answers.byJWS[jws] = answer
        if case .verified(let held)? = pending?.result, held.id == transaction.id { pending = nil }
        if answer == .ownedElsewhere, entitles { conflict = account }
        return answer
    }

    private static func entitles(_ transaction: Transaction) -> Bool {
        transaction.revocationDate == nil && (transaction.expirationDate ?? .distantPast) > .now
    }
}
