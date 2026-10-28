import Foundation
import Testing

@Suite("Dictation interruption policy")
struct DictationInterruptionPolicyTests {
    @Test func dictationPausesAndAutoResumes() {
        #expect(DictationInterruptionPolicy.actionForInterruptionBegan(isStaleSuspensionNotice: false) == .pauseAndAutoResume)
    }

    @Test func staleSuspensionNoticeFinalizes() {
        #expect(DictationInterruptionPolicy.actionForInterruptionBegan(isStaleSuspensionNotice: true) == .finalize)
    }

    @Test func resumeWindowStaysInsideBackgroundTaskBudget() {
        // iOS grants roughly 30 seconds of background-task time; the probe
        // schedule must finalize the capture before that budget expires.
        let total = DictationInterruptionPolicy.resumeProbeDelays.reduce(Duration.zero, +)
        #expect(!DictationInterruptionPolicy.resumeProbeDelays.isEmpty)
        #expect(total <= .seconds(28))
    }
}
