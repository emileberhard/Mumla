import SwiftUI

struct SpeechWaveformView: View {
    var isActive: Bool

    var body: some View {
        TimelineView(.animation) { context in
            ScrollingWaveformCanvas(
                isActive: isActive,
                date: context.date
            )
        }
    }
}

struct ScrollingWaveformCanvas: View {
    let isActive: Bool
    let date: Date

    @State private var samples: [CGFloat] = Array(repeating: 0, count: 120)
    @State private var lastUpdateTime: Date = .distantPast

    // Config
    private let barWidth: CGFloat = 1.5
    private let barSpacing: CGFloat = 1.0
    private let updateInterval: TimeInterval = 0.025  // 40 updates per second
    private let maxBars = 120

    var body: some View {
        Canvas { context, size in
            let totalBarWidth = barWidth + barSpacing
            let midY = size.height / 2
            let height = size.height

            // Draw bars from right (newest) to left (oldest)
            for (index, level) in samples.enumerated().reversed() {
                let reverseIndex = samples.count - 1 - index
                let xPos = size.width - (CGFloat(reverseIndex) * totalBarWidth)

                // Optimization: stop drawing if off-screen
                if xPos < -totalBarWidth { continue }

                let barHeight = max(4, level * height * 0.8)
                let rect = CGRect(
                    x: xPos,
                    y: midY - (barHeight / 2),
                    width: barWidth,
                    height: barHeight
                )

                context.fill(
                    Path(roundedRect: rect, cornerRadius: 0.75),
                    with: .color(.white.opacity(isActive ? 0.9 : 0.3))
                )
            }
        }
        .onChange(of: date) {
            // Throttle: only update every 100ms instead of every frame
            guard date.timeIntervalSince(lastUpdateTime) >= updateInterval else { return }

            DispatchQueue.main.async {
                lastUpdateTime = date
                updateSamples()
            }
        }
    }

    private func updateSamples() {
        let rawLevel = isActive ? CGFloat(AudioAnalyzer.shared.currentLevel) : 0.0

        // Smooth interpolation to prevent jitter
        let processedLevel: CGFloat
        if let last = samples.last {
            processedLevel = last + (rawLevel - last) * 0.5
        } else {
            processedLevel = rawLevel
        }

        samples.append(processedLevel)

        if samples.count > maxBars {
            samples.removeFirst(samples.count - maxBars)
        }
    }
}
