import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class KeyboardConnectionCheck {
    static let stampDeadline: TimeInterval = 1.5

    private(set) var isUnconfirmed = false
    @ObservationIgnored private var isConfirmed = false
    @ObservationIgnored private var shownAt: Date?
    @ObservationIgnored private var deadline: Task<Void, Never>?

    func evaluate() {
        guard !isConfirmed else { return }
        switch Self.currentKeyboard() {
        case nil:
            return
        case .other:
            deadline?.cancel()
            shownAt = nil
            if isUnconfirmed { isUnconfirmed = false }
        case .mumla:
            guard shownAt == nil else { return }
            let shownAt = Date.now
            self.shownAt = shownAt
            deadline = Task {
                try? await Task.sleep(for: .seconds(Self.stampDeadline))
                guard !Task.isCancelled else { return }
                refresh()
                guard self.shownAt == shownAt else { return }
                isUnconfirmed = true
            }
        }
    }

    func refresh() {
        guard let shownAt, let lastActive = DictationBridge.keyboardLastActive,
              lastActive.timeIntervalSince(shownAt) > -Self.stampDeadline else { return }
        confirm()
    }

    func confirm() {
        isConfirmed = true
        shownAt = nil
        deadline?.cancel()
        if isUnconfirmed { isUnconfirmed = false }
    }

    private enum Keyboard {
        case mumla
        case other
    }

    private static func currentKeyboard() -> Keyboard? {
        guard let mode = FirstResponderProbe.current?.textInputMode else { return nil }
        guard mode.primaryLanguage == KeyboardEnablement.primaryLanguage, KeyboardEnablement.isKnownEnabled
        else { return .other }
        return .mumla
    }
}

private final class FirstResponderProbe: NSObject {
    weak var responder: UIResponder?

    static var current: UIResponder? {
        let probe = FirstResponderProbe()
        UIApplication.shared.sendAction(#selector(UIResponder.mumlaReportFirstResponder(to:)), to: nil, from: probe, for: nil)
        return probe.responder
    }
}

private extension UIResponder {
    @objc func mumlaReportFirstResponder(to probe: FirstResponderProbe) {
        probe.responder = self
    }
}
