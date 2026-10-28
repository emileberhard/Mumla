import SwiftUI

struct FloatingIndicatorView: View {
    @State private var coordinator = FlowCoordinator.shared
    @State private var isHovering = false
    @Namespace private var animationNamespace

    private var isIdle: Bool { coordinator.state == .idle }
    private var isRecording: Bool { coordinator.state == .recording }
    private var isLocked: Bool { coordinator.isLockedRecording }

    static let idleWidth: CGFloat = 48
    static let idleHoverWidth: CGFloat = 59
    static let activeWidth: CGFloat = 128
    static let errorWidth: CGFloat = 320
    static let idleHeight: CGFloat = 10.5
    static let idleHoverHeight: CGFloat = 14.5
    static let activeHeight: CGFloat = 44
    static let cornerRadius: CGFloat = 18
    static let tooltipHeight: CGFloat = 24
    static let verticalSpacing: CGFloat = 6

    static var windowSize: CGSize {
        CGSize(width: errorWidth, height: activeHeight + tooltipHeight + verticalSpacing)
    }

    static func capsuleSize(isIdle: Bool, isHovering: Bool) -> CGSize {
        if isIdle {
            return CGSize(
                width: isHovering ? idleHoverWidth : idleWidth,
                height: isHovering ? idleHoverHeight : idleHeight
            )
        }

        return CGSize(width: activeWidth, height: activeHeight)
    }

    static func capsuleRect(in bounds: CGRect, isIdle: Bool, isHovering: Bool) -> CGRect {
        let size = capsuleSize(isIdle: isIdle, isHovering: isHovering)
        return CGRect(
            x: bounds.midX - (size.width / 2),
            y: bounds.minY,
            width: size.width,
            height: size.height
        )
    }

    static func containsPointInVisibleCapsule(_ point: CGPoint, bounds: CGRect, isIdle: Bool, isHovering: Bool) -> Bool {
        let rect = capsuleRect(in: bounds, isIdle: isIdle, isHovering: isHovering)
        guard rect.contains(point) else {
            return false
        }

        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        return CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ).contains(point)
    }

    private var containerWidth: CGFloat {
        if isIdle {
            return isHovering ? Self.idleHoverWidth : Self.idleWidth
        }
        if case .error = coordinator.state {
            return Self.errorWidth
        }
        return Self.activeWidth
    }

    private var containerHeight: CGFloat {
        if isIdle {
            return isHovering ? Self.idleHoverHeight : Self.idleHeight
        }
        return Self.activeHeight
    }

    private var stateColor: Color {
        switch coordinator.state {
        case .idle:
            return .clear
        case .recording:
            return isLocked ? .red.opacity(0.8) : .red.opacity(0.5)
        case .processing:
            return .yellow.opacity(0.5)
        case .success:
            return .green.opacity(0.5)
        case .error:
            return .orange.opacity(0.5)
        }
    }

    private var capsuleGlass: Glass {
        isIdle ? .clear.tint(.white.opacity(0.04)) : .clear
    }

    private var strokeWidth: CGFloat {
        isRecording && isLocked ? 1.5 : 0.5
    }

    var body: some View {
        VStack(spacing: 6) {
            // Tooltip above the pill
            if isIdle && isHovering {
                Text("Click to record")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: .capsule)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .allowsHitTesting(false)
            }

            if isRecording, let startTime = coordinator.recordingStartTime {
                RecordingTimerView(startTime: startTime, deadline: coordinator.recordingDeadline)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .allowsHitTesting(false)
            }

            ZStack {
                // Colored background that changes with state
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .fill(stateColor)

                HStack(spacing: 4) {
                    content
                }
            }
            .frame(width: containerWidth, height: containerHeight)
            .contentShape(.rect(cornerRadius: Self.cornerRadius))
            .glassEffect(capsuleGlass, in: .rect(cornerRadius: Self.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .strokeBorder(
                        isLocked && isRecording ? Color.white.opacity(0.8) : Color.black.opacity(isIdle && isHovering ? 0.4 : 0.2),
                        lineWidth: strokeWidth
                    )
            )
            .onHover { hovering in
                isHovering = hovering
            }
            .onTapGesture {
                handleTap()
            }
        }
        .frame(height: Self.windowSize.height, alignment: .bottom)
        .frame(width: Self.windowSize.width)
        .animation(.spring(response: 0.12, dampingFraction: 0.95), value: coordinator.state)
        .animation(.spring(response: 0.18, dampingFraction: 0.75), value: isHovering)
        .animation(.spring(response: 0.15, dampingFraction: 0.8), value: isLocked)
        .onChange(of: coordinator.state) {
            FloatingWindowController.shared.refreshMouseEventHandling()
        }
    }

    private func handleTap() {
        if isIdle {
            coordinator.startRecording()
        } else if isRecording {
            coordinator.stopRecording()
        }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let seconds = Int(interval) % 60
        let minutes = Int(interval) / 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.state {
        case .idle:
            Image(systemName: "mic.fill")
                .font(.system(size: 8, weight: .regular))
                .foregroundStyle(.secondary)
                .matchedGeometryEffect(id: "icon", in: animationNamespace)

        case .recording:
            SpeechWaveformView(isActive: true)
                .frame(height: Self.activeHeight * 0.8)
                .transition(.opacity)

        case .processing:
            ProgressView()
                .controlSize(.small)
                .matchedGeometryEffect(id: "icon", in: animationNamespace)

        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
                .symbolEffect(.bounce, options: .nonRepeating)
                .matchedGeometryEffect(id: "icon", in: animationNamespace)

        case .error(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                    .symbolEffect(.wiggle, options: .nonRepeating)
                    .matchedGeometryEffect(id: "icon", in: animationNamespace)

                Text(message)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
            .padding(.horizontal, 14)
        }
    }
}

private struct RecordingTimerView: View {
    static let countdownLead: TimeInterval = 10

    let startTime: Date
    let deadline: Date?

    var body: some View {
        TimelineView(.periodic(from: startTime, by: 1.0)) { context in
            Group {
                if let remaining = deadline?.timeIntervalSince(context.date), remaining <= Self.countdownLead {
                    Text("\u{2212}\(formatDuration(max(0, remaining).rounded(.up)))")
                        .foregroundStyle(.orange)
                } else {
                    Text("Recording: \(formatDuration(context.date.timeIntervalSince(startTime)))")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: .capsule)
        }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let seconds = Int(interval) % 60
        let minutes = Int(interval) / 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
