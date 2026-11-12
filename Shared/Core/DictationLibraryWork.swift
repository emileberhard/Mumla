import Foundation
#if os(iOS)
import UIKit
#endif

@MainActor
protocol DictationBackgroundExecution: AnyObject {
    func hold(onExpiration: @escaping @MainActor () -> Void)
    func release()
}

@MainActor
final class AppDictationBackgroundExecution: DictationBackgroundExecution {
    #if os(iOS)
    private var identifier = UIBackgroundTaskIdentifier.invalid
    #endif

    func hold(onExpiration: @escaping @MainActor () -> Void) {
        #if os(iOS)
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Save dictation library") { onExpiration() }
        #endif
    }

    func release() {
        #if os(iOS)
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
        #endif
    }
}

@MainActor
final class DictationLibraryWork {
    private let background: any DictationBackgroundExecution
    private let onExpiration: @MainActor () -> Void
    private var active = 0
    private var expired = false
    var canPublish: Bool { !expired }

    init(background: any DictationBackgroundExecution, onExpiration: @escaping @MainActor () -> Void) {
        self.background = background
        self.onExpiration = onExpiration
    }

    func begin() {
        if active == 0 {
            expired = false
            background.hold { [weak self] in
                guard let self else { return }
                expired = true
                onExpiration()
                background.release()
            }
        }
        active += 1
    }

    func end() {
        precondition(active > 0)
        active -= 1
        if active == 0, !expired { background.release() }
    }

    func perform<T: Sendable>(_ operation: () async throws -> T) async rethrows -> T {
        begin()
        defer { end() }
        return try await operation()
    }
}
