import Testing

@Suite("Idle session policy")
struct IdleSessionPolicyTests {
    @Test func onboardingBeforeTheDictationStepStartsNoSession() {
        #expect(!IdleSessionPolicy.startsOnActivation(
            microphoneAuthorized: true, keyboardHasBeenActive: false, dictationAllowed: true, sessionActive: false))
    }

    @Test func theDictationStepOrFinishedSetupStartsTheSession() {
        #expect(IdleSessionPolicy.startsOnActivation(
            microphoneAuthorized: true, keyboardHasBeenActive: true, dictationAllowed: true, sessionActive: false))
    }

    @Test func withoutMicrophoneAccessOrWithARunningSessionNothingStarts() {
        #expect(!IdleSessionPolicy.startsOnActivation(
            microphoneAuthorized: false, keyboardHasBeenActive: true, dictationAllowed: true, sessionActive: false))
        #expect(!IdleSessionPolicy.startsOnActivation(
            microphoneAuthorized: true, keyboardHasBeenActive: true, dictationAllowed: false, sessionActive: false))
        #expect(!IdleSessionPolicy.startsOnActivation(
            microphoneAuthorized: true, keyboardHasBeenActive: true, dictationAllowed: true, sessionActive: true))
    }
}
