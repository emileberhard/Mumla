import Foundation
import Testing

@Suite("Keyboard command authentication")
struct DictationCommandTests {
    @Test(arguments: [DictationBridge.Command.start, .stop, .cancel])
    func consumesEachNewRecordOnce(command: DictationBridge.Command) {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let now = Date(timeIntervalSince1970: 1_000)

        let missingRecord = DictationBridge.consumeCommand(command, defaults: fixture.defaults, now: now)
        #expect(!missingRecord)
        DictationBridge.writeCommand(command, defaults: fixture.defaults, now: now)
        let firstDelivery = DictationBridge.consumeCommand(command, defaults: fixture.defaults, now: now.addingTimeInterval(4))
        #expect(firstDelivery)
        let repeatedDelivery = DictationBridge.consumeCommand(command, defaults: fixture.defaults, now: now.addingTimeInterval(4))
        #expect(!repeatedDelivery)

        DictationBridge.writeCommand(command, defaults: fixture.defaults, now: now)
        let newRecord = DictationBridge.consumeCommand(command, defaults: fixture.defaults, now: now.addingTimeInterval(4))
        #expect(newRecord)
    }

    @Test func aConsumedRecordStaysConsumedAfterTheAppRelaunches() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let now = Date(timeIntervalSince1970: 1_000)

        DictationBridge.writeCommand(.start, defaults: fixture.defaults, now: now)
        let firstLaunch = DictationBridge.consumeCommand(.start, defaults: fixture.defaults, now: now.addingTimeInterval(1))
        #expect(firstLaunch)
        let relaunchedDefaults = UserDefaults(suiteName: fixture.suite)!
        let replayAfterRelaunch = DictationBridge.consumeCommand(.start, defaults: relaunchedDefaults, now: now.addingTimeInterval(2))
        #expect(!replayAfterRelaunch)
    }

    @Test(arguments: [-1.0, 5.0, 60.0])
    func rejectsRecordsOutsideTheFreshnessWindow(age: TimeInterval) {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let writtenAt = Date(timeIntervalSince1970: 1_000)

        DictationBridge.writeCommand(.start, defaults: fixture.defaults, now: writtenAt)

        let outsideWindow = DictationBridge.consumeCommand(.start, defaults: fixture.defaults, now: writtenAt.addingTimeInterval(age))
        #expect(!outsideWindow)
    }

    @Test func backToBackStartAndStopRemainIndependentlyConsumable() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let now = Date(timeIntervalSince1970: 1_000)

        DictationBridge.writeCommand(.start, defaults: fixture.defaults, now: now)
        DictationBridge.writeCommand(.stop, defaults: fixture.defaults, now: now.addingTimeInterval(0.1))

        let start = DictationBridge.consumeCommand(.start, defaults: fixture.defaults, now: now.addingTimeInterval(1))
        #expect(start)
        let stop = DictationBridge.consumeCommand(.stop, defaults: fixture.defaults, now: now.addingTimeInterval(1))
        #expect(stop)
        let repeatedStart = DictationBridge.consumeCommand(.start, defaults: fixture.defaults, now: now.addingTimeInterval(1))
        #expect(!repeatedStart)
        let repeatedStop = DictationBridge.consumeCommand(.stop, defaults: fixture.defaults, now: now.addingTimeInterval(1))
        #expect(!repeatedStop)
    }

    private struct Fixture {
        let suite = "test.Mumla.commands.\(UUID().uuidString)"
        let defaults: UserDefaults

        init() {
            defaults = UserDefaults(suiteName: suite)!
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
        }
    }
}
