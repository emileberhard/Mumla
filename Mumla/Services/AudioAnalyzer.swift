import Foundation
import Observation
import os

// Thread-safe storage - explicitly nonisolated for cross-thread access
private final class AtomicLevel: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Float(0.0))

    nonisolated func store(_ level: Float) {
        lock.withLock { $0 = level }
    }

    nonisolated func load() -> Float {
        lock.withLock { $0 }
    }
}

// Adaptive normalizer with fast attack, slow decay
private final class AdaptiveNormalizer: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Float(0.015))

    nonisolated func normalize(_ rms: Float) -> Float {
        lock.withLock { peakRMS in
            // Fast attack, slow decay
            if rms > peakRMS {
                peakRMS = rms
            } else {
                peakRMS *= 0.995  // Slow decay
            }

            // Clamp peak to reasonable range (higher floor = less sensitive)
            peakRMS = max(0.015, min(0.5, peakRMS))

            // Normalize with soft compression and output scaling
            let normalized = rms / peakRMS
            return min(1.0, sqrt(normalized) * 0.7)
        }
    }

    nonisolated func reset() {
        lock.withLock { $0 = 0.015 }
    }
}

private nonisolated(unsafe) let sharedLevel = AtomicLevel()
private nonisolated(unsafe) let sharedNormalizer = AdaptiveNormalizer()

@MainActor
@Observable
final class AudioAnalyzer {
    static let shared = AudioAnalyzer()

    private init() {}

    var currentLevel: Float {
        sharedLevel.load()
    }

    nonisolated static func pushExternalRMS(_ rms: Float) {
        guard rms.isFinite else { return }
        let normalized = sharedNormalizer.normalize(max(0, rms))
        sharedLevel.store(normalized)
    }

    nonisolated static func pushRecorderAveragePower(_ averagePower: Float) {
        guard averagePower.isFinite else { return }
        let clamped = max(-160, min(0, averagePower))
        let rms = pow(10, clamped / 20)
        pushExternalRMS(rms)
    }

    nonisolated static func resetLevel() {
        sharedLevel.store(0)
        sharedNormalizer.reset()
    }
}
