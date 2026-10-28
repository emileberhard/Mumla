import SwiftUI
import Combine

@MainActor
final class FrameClock: ObservableObject {
    static let shared = FrameClock()
    @Published var timestamp: TimeInterval = Date().timeIntervalSinceReferenceDate
    private var timer: AnyCancellable?

    func start() {
        guard timer == nil else { return }
        // 60 FPS target
        timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in
                self?.timestamp = date.timeIntervalSinceReferenceDate
            }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
