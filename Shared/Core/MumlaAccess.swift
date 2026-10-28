import CloudKit
import Foundation
import Observation

@MainActor
@Observable
final class MumlaAccess {
    enum State: Equatable {
        case checking
        case available(Allowance)
        case iCloudUnavailable(CKAccountStatus)
        case serviceUnavailable

        var isICloudSignedOut: Bool { self == .iCloudUnavailable(.noAccount) }

        var blockingFailure: AccessFailure? {
            switch self {
            case .iCloudUnavailable(let status): .iCloudUnavailable(status)
            case .available(let allowance) where allowance.available == .zero:
                allowance.isExhausted ? .allowanceExhausted : .allowanceBusy
            case .available, .checking, .serviceUnavailable: nil
            }
        }

        var blocksDictation: Bool { blockingFailure != nil }
    }

    struct Allowance: Equatable, Sendable {
        let limit: Duration
        let used: Duration
        let reserved: Duration
        let resetsAt: Date

        var remaining: Duration { max(.zero, limit - used) }
        var available: Duration { max(.zero, remaining - reserved) }
        var isExhausted: Bool { used >= limit }
    }

    private(set) var state: State
    @ObservationIgnored private let client: AccessClient?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var accountObserver: (any NSObjectProtocol)?

    init(client: AccessClient? = .live()) {
        self.client = client
        state = client == nil ? .serviceUnavailable : .checking
        #if DEBUG
        if let preview = Self.debugState(named: UserDefaults.standard.string(forKey: "MumlaDebugAccessState")) {
            state = preview
            return
        }
        #endif
        guard client != nil else { return }
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.accountChanged() }
        }
        refreshInBackground()
    }

    var canDictate: Bool {
        guard case .available(let allowance) = state else { return false }
        return allowance.available > .zero
    }

    func refreshInBackground() {
        guard refreshTask == nil else { return }
        refreshTask = Task {
            await refresh()
            refreshTask = nil
        }
    }

    func refresh() async {
        guard let client else { return }
        if case .available = state {} else { state = .checking }
        do {
            state = .available(try await client.allowance())
        } catch let failure as AccessFailure {
            apply(failure)
        } catch is CancellationError {
        } catch {
            state = .serviceUnavailable
        }
    }

    func grant(maximumAudioSeconds: Int) async throws -> AccessGrant {
        guard let client else { throw AccessFailure.serviceUnavailable }
        do {
            let (grant, allowance) = try await client.reserve(maximumAudioSeconds: maximumAudioSeconds)
            state = .available(allowance)
            return grant
        } catch let failure as AccessFailure {
            apply(failure)
            throw failure
        }
    }

    private func apply(_ failure: AccessFailure) {
        switch failure {
        case .iCloudUnavailable(let status): state = .iCloudUnavailable(status)
        case .serviceUnavailable: state = .serviceUnavailable
        case .allowanceExhausted, .allowanceBusy: refreshInBackground()
        }
    }

    private func accountChanged() async {
        refreshTask?.cancel()
        refreshTask = nil
        state = .checking
        await client?.endSession()
        refreshInBackground()
    }

    #if DEBUG
    func preview(_ name: String) {
        state = Self.debugState(named: name) ?? .checking
    }

    private static func debugState(named name: String?) -> State? {
        let resetsAt = Calendar.current.dateInterval(of: .month, for: .now)?.end ?? .now
        func allowance(used minutes: Int, reserved: Int = 0) -> State {
            .available(Allowance(limit: .seconds(3600), used: .seconds(minutes * 60), reserved: .seconds(reserved * 60), resetsAt: resetsAt))
        }
        switch name {
        case "available": return allowance(used: 18)
        case "low": return allowance(used: 56)
        case "spent": return allowance(used: 60)
        case "busy": return allowance(used: 50, reserved: 10)
        case "noAccount": return .iCloudUnavailable(.noAccount)
        case "restricted": return .iCloudUnavailable(.restricted)
        case "temporarilyUnavailable": return .iCloudUnavailable(.temporarilyUnavailable)
        case "offline": return .serviceUnavailable
        default: return nil
        }
    }
    #endif
}
