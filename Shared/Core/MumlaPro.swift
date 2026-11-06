import Foundation

nonisolated enum MumlaPro {
    static let subscriptionGroupID = "22248259"
    static let appStoreURL = URL(string: "https://apps.apple.com/app/id6779234657")!
    static let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!
    static let privacyPolicyURL = URL(string: "https://github.com/emileberhard/Mumla/blob/main/PRIVACY.md")!
    static let termsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
}

extension MumlaAccess.Allowance {
    var showsProBadge: Bool {
        plan == .pro && !isRunningLow
    }

    var offersPro: Bool {
        if case .free = plan { true } else { false }
    }
}

extension MumlaAccess.Plan {
    var proHours: Int? {
        guard case .free(let proLimit) = self else { return nil }
        return Int(proLimit.components.seconds / 3600)
    }
}
