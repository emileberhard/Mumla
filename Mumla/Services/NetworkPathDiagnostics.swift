import Foundation
import Network

@MainActor
final class NetworkPathDiagnostics {
    static let shared = NetworkPathDiagnostics()

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "emileberhard.WisprClone.network-path-monitor")

    private var isStarted = false
    private var snapshot = NetworkPathSnapshot.unknown

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true

        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.handlePathUpdate(path)
            }
        }
        monitor.start(queue: monitorQueue)

        handlePathUpdate(monitor.currentPath, forceLog: true)
    }

    func currentMetadata() -> [String: String] {
        snapshot.metadata
    }

    private func handlePathUpdate(_ path: NWPath, forceLog: Bool = false) {
        let nextSnapshot = NetworkPathSnapshot(path: path)
        let previousSnapshot = snapshot
        snapshot = nextSnapshot

        guard forceLog || nextSnapshot != previousSnapshot else { return }

        var metadata = nextSnapshot.metadata
        metadata["previous_network_path_status"] = previousSnapshot.status
        metadata["previous_network_path_active_interfaces"] = previousSnapshot.activeInterfaces

        AppDiagnostics.info(
            forceLog ? "Network path monitor started" : "Network path changed",
            category: "network",
            metadata: metadata
        )
    }
}

private struct NetworkPathSnapshot: Equatable, Sendable {
    static let unknown = NetworkPathSnapshot(
        observedAt: Date(),
        status: "unknown",
        unsatisfiedReason: "unknown",
        activeInterfaces: "unknown",
        availableInterfaces: "unknown",
        availableInterfaceNames: "unknown",
        isExpensive: "unknown",
        isConstrained: "unknown",
        supportsDNS: "unknown",
        supportsIPv4: "unknown",
        supportsIPv6: "unknown",
        gatewaysCount: "unknown",
        debugDescription: "unknown"
    )

    let observedAt: Date
    let status: String
    let unsatisfiedReason: String
    let activeInterfaces: String
    let availableInterfaces: String
    let availableInterfaceNames: String
    let isExpensive: String
    let isConstrained: String
    let supportsDNS: String
    let supportsIPv4: String
    let supportsIPv6: String
    let gatewaysCount: String
    let debugDescription: String

    static func == (lhs: NetworkPathSnapshot, rhs: NetworkPathSnapshot) -> Bool {
        lhs.status == rhs.status
            && lhs.unsatisfiedReason == rhs.unsatisfiedReason
            && lhs.activeInterfaces == rhs.activeInterfaces
            && lhs.availableInterfaces == rhs.availableInterfaces
            && lhs.availableInterfaceNames == rhs.availableInterfaceNames
            && lhs.isExpensive == rhs.isExpensive
            && lhs.isConstrained == rhs.isConstrained
            && lhs.supportsDNS == rhs.supportsDNS
            && lhs.supportsIPv4 == rhs.supportsIPv4
            && lhs.supportsIPv6 == rhs.supportsIPv6
            && lhs.gatewaysCount == rhs.gatewaysCount
            && lhs.debugDescription == rhs.debugDescription
    }

    init(path: NWPath) {
        self.observedAt = Date()
        self.status = String(describing: path.status)
        self.unsatisfiedReason = String(describing: path.unsatisfiedReason)
        self.activeInterfaces = Self.interfaceTypes
            .filter { path.usesInterfaceType($0) }
            .map(Self.displayName(for:))
            .joinedOrNone
        self.availableInterfaces = path.availableInterfaces
            .map { Self.displayName(for: $0.type) }
            .deduplicated()
            .joinedOrNone
        self.availableInterfaceNames = path.availableInterfaces
            .map { "\($0.name):\(Self.displayName(for: $0.type))" }
            .deduplicated()
            .joinedOrNone
        self.isExpensive = String(path.isExpensive)
        self.isConstrained = String(path.isConstrained)
        self.supportsDNS = String(path.supportsDNS)
        self.supportsIPv4 = String(path.supportsIPv4)
        self.supportsIPv6 = String(path.supportsIPv6)
        self.gatewaysCount = String(path.gateways.count)
        self.debugDescription = path.debugDescription
    }

    private init(
        observedAt: Date,
        status: String,
        unsatisfiedReason: String,
        activeInterfaces: String,
        availableInterfaces: String,
        availableInterfaceNames: String,
        isExpensive: String,
        isConstrained: String,
        supportsDNS: String,
        supportsIPv4: String,
        supportsIPv6: String,
        gatewaysCount: String,
        debugDescription: String
    ) {
        self.observedAt = observedAt
        self.status = status
        self.unsatisfiedReason = unsatisfiedReason
        self.activeInterfaces = activeInterfaces
        self.availableInterfaces = availableInterfaces
        self.availableInterfaceNames = availableInterfaceNames
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.supportsDNS = supportsDNS
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.gatewaysCount = gatewaysCount
        self.debugDescription = debugDescription
    }

    var metadata: [String: String] {
        [
            "network_path_active_interfaces": activeInterfaces,
            "network_path_age_ms": String(max(0, Int(Date().timeIntervalSince(observedAt) * 1_000))),
            "network_path_available_interface_names": availableInterfaceNames,
            "network_path_available_interfaces": availableInterfaces,
            "network_path_constrained": isConstrained,
            "network_path_debug": debugDescription,
            "network_path_expensive": isExpensive,
            "network_path_gateways_count": gatewaysCount,
            "network_path_status": status,
            "network_path_supports_dns": supportsDNS,
            "network_path_supports_ipv4": supportsIPv4,
            "network_path_supports_ipv6": supportsIPv6,
            "network_path_unsatisfied_reason": unsatisfiedReason,
        ]
    }

    private static let interfaceTypes: [NWInterface.InterfaceType] = [
        .wifi,
        .wiredEthernet,
        .cellular,
        .loopback,
        .other,
    ]

    private static func displayName(for interfaceType: NWInterface.InterfaceType) -> String {
        switch interfaceType {
        case .wifi:
            return "wifi"
        case .cellular:
            return "cellular"
        case .wiredEthernet:
            return "wiredEthernet"
        case .loopback:
            return "loopback"
        case .other:
            return "other"
        @unknown default:
            return "unknown"
        }
    }
}

private extension [String] {
    var joinedOrNone: String {
        isEmpty ? "none" : joined(separator: ",")
    }

    func deduplicated() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
