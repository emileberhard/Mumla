import SwiftUI

struct ProStatusRow: View {
    let access: MumlaAccess

    var body: some View {
        if case .available(let allowance) = access.state {
            switch allowance.plan {
            case .free:
                Link("Get Mumla Pro on iPhone or iPad", destination: MumlaPro.appStoreURL)
            case .pro:
                Link("Manage Subscription", destination: MumlaPro.manageSubscriptionsURL)
            case .notOffered:
                EmptyView()
            }
        }
    }
}
