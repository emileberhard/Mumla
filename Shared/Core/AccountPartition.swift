import CryptoKit
import Foundation
import Synchronization

nonisolated final class AccountPartitionLease: Sendable {
    let ownerID: String
    private let active = Mutex(true)

    init(ownerID: String) { self.ownerID = ownerID }
    var isActive: Bool { active.withLock { $0 } }
    func invalidate() { active.withLock { $0 = false } }
}

nonisolated enum AccountPartition {
    static func directory(root: URL, ownerID: String?) -> URL {
        let name = ownerID.map {
            SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
        } ?? "unconfirmed"
        return root.appendingPathComponent("Accounts", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }
}
