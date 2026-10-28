import Testing

@Suite("Try-it landing")
struct TryItLandingTests {
    private static func dictated(_ transcript: String, startingFrom start: String = "") -> TryItLanding {
        var landing = TryItLanding()
        landing.recordingStarted(fieldText: start)
        landing.transcriptPublishedHere(transcript)
        return landing
    }

    @Test func theTranscriptLandingInTheTutorialFieldCompletes() {
        #expect(Self.dictated("Hello there.").hasLanded(in: "Hello there."))
        #expect(Self.dictated(" Hello there. ").hasLanded(in: "Hello there. "))
        #expect(Self.dictated("again", startingFrom: "Hello").hasLanded(in: "Hello again"))
    }

    @Test func dictatingElsewhereThenTypingHereDoesNotComplete() {
        #expect(!Self.dictated("Hello there.").hasLanded(in: "a"))
        #expect(!Self.dictated("Hello", startingFrom: "Hello").hasLanded(in: "Hellox"))
    }

    @Test func aKeyboardThatFailedToInsertThenTypingDoesNotComplete() {
        #expect(!Self.dictated("Hello from the keyboard.").hasLanded(in: "Hi"))
    }

    @Test func anEmptyTranscriptOrNoDictationNeverCompletes() {
        #expect(!Self.dictated(" \n").hasLanded(in: "Typed"))
        #expect(!TryItLanding().hasLanded(in: "Typed by hand"))
        var recording = TryItLanding()
        recording.recordingStarted(fieldText: "")
        #expect(!recording.hasLanded(in: "Typed while recording"))
    }

    @Test func aNewRecordingWithdrawsAPendingCompletion() {
        var landing = Self.dictated("Hello")
        #expect(landing.hasLanded(in: "Hello"))
        landing.recordingStarted(fieldText: "Hello")
        #expect(!landing.hasLanded(in: "Hello"))
    }
}
