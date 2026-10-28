import Foundation
import Testing

@MainActor
@Suite("Keyboard transcript delivery")
struct KeyboardBridgeClientTests {
    @Test func replacedKeyboardThatNeverDisappearedCannotTakeTheVisibleKeyboardsTranscript() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let replaced = fixture.makeClient()
        let visible = fixture.makeClient()
        defer { replaced.deactivate(); visible.deactivate() }
        var replacedSubmissions: [String] = []
        var visibleSubmissions: [String] = []
        replaced.onTranscript = { replacedSubmissions.append($0); return true }
        visible.onTranscript = { visibleSubmissions.append($0); return true }

        fixture.show(replaced)
        fixture.show(visible)
        fixture.publish()
        replaced.refresh()
        visible.refresh()

        #expect(replacedSubmissions.isEmpty)
        #expect(visibleSubmissions == [Fixture.text])
        #expect(fixture.insertedID == Fixture.transcriptID)
    }

    @Test func ownerWhoseControllerIsGoneLeavesTranscriptForTheNextKeyboard() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let released = fixture.makeClient()
        let next = fixture.makeClient()
        defer { released.deactivate(); next.deactivate() }
        var releasedAttempts = 0
        var nextSubmissions: [String] = []
        released.onTranscript = { _ in releasedAttempts += 1; return false }
        next.onTranscript = { nextSubmissions.append($0); return true }

        fixture.show(released)
        fixture.publish()
        released.refresh()
        released.refresh()
        #expect(releasedAttempts == 2)
        #expect(fixture.insertedID == nil)
        fixture.show(next)

        #expect(nextSubmissions == [Fixture.text])
        #expect(fixture.insertedID == Fixture.transcriptID)
    }

    @Test func mostRecentClaimOwnsTranscripts() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let first = fixture.makeClient()
        let second = fixture.makeClient()
        defer { first.deactivate(); second.deactivate() }
        var firstSubmissions: [String] = []
        var secondSubmissions: [String] = []
        first.onTranscript = { firstSubmissions.append($0); return true }
        second.onTranscript = { secondSubmissions.append($0); return true }

        fixture.show(first)
        fixture.show(second)
        first.claimTranscripts(.stopRequested)
        fixture.publish()
        second.refresh()
        first.refresh()

        #expect(firstSubmissions == [Fixture.text])
        #expect(secondSubmissions.isEmpty)
        #expect(fixture.owner == first.clientID)
    }

    @Test func inactiveControllerCanNeitherClaimNorConsume() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let old = fixture.makeClient()
        let current = fixture.makeClient()
        defer { old.deactivate(); current.deactivate() }
        var oldSubmissions: [String] = []
        var currentSubmissions: [String] = []
        old.onTranscript = { oldSubmissions.append($0); return true }
        current.onTranscript = { currentSubmissions.append($0); return true }

        fixture.show(old)
        old.deactivate()
        fixture.publish()
        // Reproduce a queued notification or surviving automatic-start refresh.
        old.refresh()
        old.claimTranscripts(.appeared)
        #expect(fixture.insertedID == nil)
        #expect(old.phase == .idle)
        fixture.show(current)
        old.refresh()
        current.refresh()

        #expect(oldSubmissions.isEmpty)
        #expect(currentSubmissions == [Fixture.text])
    }

    @Test func activationWithoutAppearanceLeavesTranscriptPending() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let client = fixture.makeClient()
        defer { client.deactivate() }
        var submissions: [String] = []
        client.onTranscript = { submissions.append($0); return true }
        fixture.publish()

        client.refresh()
        client.activate()
        #expect(submissions.isEmpty)
        #expect(fixture.insertedID == nil)
        client.claimTranscripts(.appeared)

        #expect(submissions == [Fixture.text])
    }

    @Test func reappearanceDeliversPendingTranscriptOnlyOnce() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let client = fixture.makeClient()
        defer { client.deactivate() }
        var submissions: [String] = []
        client.onTranscript = { submissions.append($0); return true }
        fixture.show(client)
        client.deactivate()
        fixture.publish()
        client.refresh()
        fixture.show(client)
        client.refresh()
        client.deactivate()
        fixture.show(client)

        #expect(submissions == [Fixture.text])
    }

    @Test func submissionIsNotRepeatedByReentrantRefreshOrNewClient() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let client = fixture.makeClient()
        let replacement = fixture.makeClient()
        defer { client.deactivate(); replacement.deactivate() }
        var submissions: [String] = []
        client.onTranscript = { [weak client] text in
            submissions.append(text)
            client?.refresh()
            return true
        }
        replacement.onTranscript = { submissions.append($0); return true }
        fixture.publish()
        fixture.show(client)
        client.deactivate()
        fixture.show(replacement)

        #expect(submissions == [Fixture.text])
    }

    @Test func missingConsumerDoesNotAcknowledgeTranscript() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let client = fixture.makeClient()
        defer { client.deactivate() }
        fixture.publish()
        fixture.show(client)
        #expect(fixture.insertedID == nil)
        var submissions: [String] = []
        client.onTranscript = { submissions.append($0); return true }
        client.refresh()

        #expect(submissions == [Fixture.text])
    }

    @Test func expiredTranscriptIsNeitherInsertedNorAcknowledged() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let client = fixture.makeClient()
        defer { client.deactivate() }
        var submissions: [String] = []
        client.onTranscript = { submissions.append($0); return true }
        fixture.publish(age: 60)
        fixture.show(client)
        client.deactivate()
        fixture.show(client)

        #expect(submissions.isEmpty)
        #expect(fixture.insertedID == nil)
    }

    @Test func fullAccessIsRequiredBeforeClaimingOrConsuming() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let client = fixture.makeClient()
        defer { client.deactivate() }
        var submissions: [String] = []
        client.onTranscript = { submissions.append($0); return true }
        client.hasFullAccess = false
        fixture.publish()
        fixture.show(client)
        #expect(submissions.isEmpty)
        #expect(fixture.owner == nil)
        client.hasFullAccess = true
        client.claimTranscripts(.appeared)

        #expect(submissions == [Fixture.text])
    }

    @Test(arguments: [
        (KeyboardAccessState.allowanceSpent(resetsAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded() + 3_600)), true),
        (.allowanceSpent(resetsAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded() - 60)), false),
        (.iCloudSignedOut, true),
        (.iCloudUnavailable, true),
        (.serviceUnavailable, false),
        (.checking, false),
        (.available, false),
    ])
    func onlyAKnownAccessReasonPublishedByTheAppBlocksDictation(state: KeyboardAccessState, blocks: Bool) {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let client = fixture.makeClient()
        defer { client.deactivate() }
        state.write(to: fixture.shared)

        fixture.show(client)
        client.refresh()

        #expect(client.access == state)
        #expect(client.accessBlocksDictation == blocks)
        #expect(client.canDictateNow == !blocks)
    }

    @Test(arguments: [(DictationPhase.recording, true), (.processing, false)])
    func theAppsRecordingDeadlineReachesTheKeyboardOnlyWhileItRecords(phase: DictationPhase, shown: Bool) {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let client = fixture.makeClient()
        defer { client.deactivate() }
        let start = Date().timeIntervalSince1970.rounded()
        fixture.shared.set(phase.rawValue, forKey: DictationBridge.DefaultsKey.phase)
        fixture.shared.set(start, forKey: DictationBridge.DefaultsKey.recordingStartTimestamp)
        fixture.shared.set(start + 110, forKey: DictationBridge.DefaultsKey.recordingDeadlineTimestamp)

        fixture.show(client)
        client.refresh()

        #expect(client.recordingDeadline == (shown ? Date(timeIntervalSince1970: start + 110) : nil))
    }

    private struct Fixture {
        static let transcriptID = "synthetic-transcript"
        static let text = "Synthetic dictation."
        let sharedSuite = "test.Mumla.shared.\(UUID().uuidString)"
        let shared: UserDefaults

        init() {
            shared = UserDefaults(suiteName: sharedSuite)!
            shared.set(Date().timeIntervalSince1970, forKey: DictationBridge.DefaultsKey.heartbeat)
            shared.set(true, forKey: DictationBridge.DefaultsKey.sessionActive)
            shared.set(DictationPhase.success.rawValue, forKey: DictationBridge.DefaultsKey.phase)
        }

        var insertedID: String? { shared.string(forKey: DictationBridge.DefaultsKey.transcriptInsertedID) }
        var owner: String? { shared.string(forKey: DictationBridge.DefaultsKey.transcriptOwnerID) }

        func makeClient() -> KeyboardBridgeClient {
            let client = KeyboardBridgeClient(sharedDefaults: shared)
            client.hasFullAccess = true
            return client
        }

        func show(_ client: KeyboardBridgeClient) {
            client.activate()
            client.claimTranscripts(.appeared)
        }

        func publish(age: TimeInterval = 0) {
            shared.set(Self.transcriptID, forKey: DictationBridge.DefaultsKey.transcriptID)
            shared.set(Self.text, forKey: DictationBridge.DefaultsKey.transcriptText)
            shared.set(Date().timeIntervalSince1970 - age, forKey: DictationBridge.DefaultsKey.transcriptTimestamp)
        }

        func cleanUp() {
            shared.removePersistentDomain(forName: sharedSuite)
        }
    }
}
