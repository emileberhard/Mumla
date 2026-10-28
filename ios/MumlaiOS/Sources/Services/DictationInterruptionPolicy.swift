import Foundation

/// Decides how an in-flight dictation reacts to an audio session interruption.
///
/// Siri-class announcements (Watch workout voice feedback, AirPods notification
/// readouts) deliver short `.began` interruptions whose `.ended` notification
/// is not guaranteed and frequently omits `.shouldResume`, so dictation pauses
/// in place and force-resumes on a probe schedule instead of finalizing.
/// Platform-neutral on purpose: compiled into the macOS unit-test target.
enum DictationInterruptionPolicy {
    enum InterruptionBeganAction: Equatable {
        case pauseAndAutoResume
        case finalize
    }

    /// Delays between resume attempts after an interruption begins. Reactivation
    /// is rejected until the interrupting system audio ends, so early probes are
    /// cheap failures. Cumulative wait (~25 s) stays inside one UIApplication
    /// background-task window so an answered phone call finalizes the capture
    /// instead of stranding it when iOS suspends the app.
    static let resumeProbeDelays: [Duration] = [
        .seconds(1),
        .seconds(2),
        .seconds(3),
        .seconds(4),
        .seconds(5),
        .seconds(10),
    ]

    static func actionForInterruptionBegan(isStaleSuspensionNotice: Bool) -> InterruptionBeganAction {
        // A delayed notification after app suspension describes an interruption
        // that already happened; there is nothing live to wait out.
        if isStaleSuspensionNotice {
            return .finalize
        }
        return .pauseAndAutoResume
    }
}
