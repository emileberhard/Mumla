import SwiftUI

/// Cassette mechanism shown inside the dictation pill while recording. The
/// pill itself is the shell: two identical spoked wheels slot into its
/// rounded ends, and the tape is a dashed band running just inside the
/// pill's border — a belt loop the wheels drive. Dash travel and wheel
/// rotation derive from one belt speed, so the whole mechanism moves
/// together. Monochrome by design: everything is the pill's foreground
/// color at varying opacity.
///
/// Rendering is deliberately plain SwiftUI shapes, not Canvas: Canvas draws
/// through RenderBox, whose GPU device is torn down while a memory-squeezed
/// keyboard extension backgrounds, and a purged Canvas can come back blank
/// (an empty red pill hiding the recording state). Shape strokes and
/// rotation transforms use the same rendering path as the keycaps, so the
/// worst possible degradation is a static cassette, never a blank one.
///
/// The mechanism ramps up like a motor engaging and freezes when Reduce
/// Motion is on. Visual counterpart of the dictaphone haptic texture
/// (docs/haptics.md).
struct CassetteMotifView: View {
    var color: Color = .white
    /// When set, the elapsed-recording timer is shown centered between the
    /// wheels, fading on the same pulse as the spindle lights.
    var recordingStartDate: Date?
    var recordingDeadline: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long the transport has been running. Advanced by an explicit task
    /// clock; every tick mutates state, so each frame is a fresh render and
    /// a suspension just pauses the mechanism in place.
    @State private var runningTime: TimeInterval = 0

    var body: some View {
        GeometryReader { proxy in
            let bandRadius = (proxy.size.height - CassetteMetrics.bandInset * 2) / 2
            let rimRadius = bandRadius - CassetteMetrics.wheelClearance
            let travel = CassetteMetrics.beltSpeed * Self.spunTime(runningTime)
            // Wheels turn clockwise like the band that wraps them; surface
            // speed matches belt travel. The half-spoke offset on the right
            // wheel keeps the pair from looking like a mirrored clone.
            let angle = travel / bandRadius
            // Both spindle lights breathe in sync on the mechanism's clock;
            // full brightness when Reduce Motion keeps the clock at zero.
            let pulse = reduceMotion
                ? 1.0
                : 0.5 + 0.5 * sin(runningTime / CassetteMetrics.pulsePeriod * 2 * .pi)

            ZStack {
                CassetteBandShape()
                    .stroke(
                        color.opacity(0.65),
                        style: StrokeStyle(
                            lineWidth: 1.5,
                            lineCap: .round,
                            dash: CassetteMetrics.dash,
                            dashPhase: -travel
                        )
                    )
                CassetteWheel(color: color, rimRadius: rimRadius, angle: angle, pulse: pulse)
                    .position(x: CassetteMetrics.bandInset + bandRadius, y: proxy.size.height / 2)
                CassetteWheel(
                    color: color,
                    rimRadius: rimRadius,
                    angle: angle + .pi / Double(CassetteMetrics.spokeCount),
                    pulse: pulse
                )
                .position(
                    x: proxy.size.width - CassetteMetrics.bandInset - bandRadius,
                    y: proxy.size.height / 2
                )
                if let recordingStartDate {
                    // System-driven timer text: updates itself each second
                    // without any timer or state churn here. Breathes on the
                    // same pulse as the spindle lights.
                    RecordingTimeText(start: recordingStartDate, deadline: recordingDeadline, pulse: pulse)
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(color)
                }
            }
        }
        .task(id: reduceMotion) {
            guard !reduceMotion else { return }
            let clock = ContinuousClock()
            var last = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(25))
                let now = clock.now
                let step = (now - last) / .seconds(1)
                last = now
                // Cap the step so a suspension pauses the mechanism in place
                // instead of jumping it forward on resume.
                runningTime += min(step, 0.1)
            }
        }
        .accessibilityHidden(true)
    }

    /// Belt time with the linear spin-up ramp integrated in, so speed
    /// (not position) eases from zero to full.
    private static func spunTime(_ elapsed: TimeInterval) -> TimeInterval {
        elapsed < CassetteMetrics.spinUpDuration
            ? elapsed * elapsed / (2 * CassetteMetrics.spinUpDuration)
            : elapsed - CassetteMetrics.spinUpDuration / 2
    }
}

private struct RecordingTimeText: View {
    let start: Date
    let deadline: Date?
    let pulse: Double

    var body: some View {
        if let deadline {
            let schedule = RecordingTimeSchedule(deadline: deadline)
            TimelineView(schedule) { context in
                if context.date >= schedule.countdownStart {
                    Text("\u{2212}\(Text(timerInterval: min(context.date, deadline)...deadline, countsDown: true, showsHours: false))")
                } else {
                    elapsed
                }
            }
        } else {
            elapsed
        }
    }

    private var elapsed: some View {
        Text(timerInterval: start...Date.distantFuture, countsDown: false, showsHours: false)
            .opacity(0.5 + 0.5 * pulse)
    }
}

private nonisolated enum CassetteMetrics {
    /// Inset of the tape band from the pill edge.
    static let bandInset: CGFloat = 6
    /// Gap between each wheel's rim and the band around it.
    static let wheelClearance: CGFloat = 3
    static let hubRadius: CGFloat = 4.5
    static let spokeCount = 6
    static let dash: [CGFloat] = [4.5, 5.5]

    /// Linear speed of the tape band in points per second; wheel angular
    /// speed follows from it, so band and wheels stay in mechanical sync.
    static let beltSpeed: Double = 26

    /// The mechanism accelerates linearly to full speed over this long.
    static let spinUpDuration: TimeInterval = 0.9

    /// Breathing period of the spindle lights in the wheel hubs.
    static let pulsePeriod: TimeInterval = 1.8
    /// Fills the hub hole (inner radius 3.7 for the 4.5 hub ring at 1.6
    /// stroke) and tucks under the ring, so the lamp reads as one piece
    /// with the hub and can never show an off-center sliver.
    static let spindleDotDiameter: CGFloat = 8
}

/// The dashed tape loop just inside the pill border, traversed visually
/// clockwise; a negative dash phase makes the dashes travel along that
/// direction.
private nonisolated struct CassetteBandShape: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = CassetteMetrics.bandInset
        let radius = (rect.height - inset * 2) / 2
        let leftX = rect.minX + inset + radius
        let rightX = rect.maxX - inset - radius
        var path = Path()
        path.move(to: CGPoint(x: leftX, y: rect.minY + inset))
        path.addLine(to: CGPoint(x: rightX, y: rect.minY + inset))
        path.addArc(
            center: CGPoint(x: rightX, y: rect.midY),
            radius: radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: leftX, y: rect.maxY - inset))
        path.addArc(
            center: CGPoint(x: leftX, y: rect.midY),
            radius: radius,
            startAngle: .degrees(90),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

private struct CassetteWheel: View {
    let color: Color
    let rimRadius: CGFloat
    let angle: Double
    let pulse: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.45), lineWidth: 1.2)
            WheelSpokes()
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            Circle()
                .stroke(color, lineWidth: 1.6)
                .frame(
                    width: CassetteMetrics.hubRadius * 2,
                    height: CassetteMetrics.hubRadius * 2
                )
            // Spindle light: a glowing record indicator inside the hub.
            Circle()
                .fill(color)
                .frame(
                    width: CassetteMetrics.spindleDotDiameter,
                    height: CassetteMetrics.spindleDotDiameter
                )
                .opacity(0.5 + 0.5 * pulse)
                // Trough scale keeps the dot radius above the hub's inner
                // edge, so the hole stays filled through the whole breath.
                .scaleEffect(0.95 + 0.05 * pulse)
                .shadow(color: color.opacity(0.35 + 0.45 * pulse), radius: 3)
        }
        .frame(width: rimRadius * 2, height: rimRadius * 2)
        .rotationEffect(.radians(angle))
    }
}

/// Six spokes from the hub to just inside the rim, drawn unrotated; the
/// wheel view's rotation transform spins them.
private nonisolated struct WheelSpokes: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = min(rect.width, rect.height) / 2 - 1.5
        var path = Path()
        for spoke in 0..<CassetteMetrics.spokeCount {
            let angle = Double(spoke) * 2 * .pi / Double(CassetteMetrics.spokeCount)
            path.move(to: CGPoint(
                x: center.x + CassetteMetrics.hubRadius * cos(angle),
                y: center.y + CassetteMetrics.hubRadius * sin(angle)
            ))
            path.addLine(to: CGPoint(
                x: center.x + outerRadius * cos(angle),
                y: center.y + outerRadius * sin(angle)
            ))
        }
        return path
    }
}
