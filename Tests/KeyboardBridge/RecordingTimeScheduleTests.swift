import Foundation
import SwiftUI
import Testing

@Suite("Recording timer schedule")
struct RecordingTimeScheduleTests {
    @Test(arguments: [
        (0.0, [0.0, 100.0]),
        (99.0, [99.0, 100.0]),
        (100.0, [100.0]),
        (105.0, [105.0]),
        (110.0, [110.0]),
        (120.0, [120.0]),
    ])
    func startsAtTheCurrentTimeAndSwitchesOnlyForTheFinalTenSeconds(
        nowOffset: TimeInterval, expectedOffsets: [TimeInterval]
    ) {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let schedule = RecordingTimeSchedule(deadline: start.addingTimeInterval(110))

        let entries = schedule.entries(from: start.addingTimeInterval(nowOffset), mode: .normal)

        #expect(entries.map { $0.timeIntervalSince(start) } == expectedOffsets)
    }

    @Test func aShortenedGrantStartsInsideTheCountdownAtTheCurrentTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let schedule = RecordingTimeSchedule(deadline: now.addingTimeInterval(4))

        #expect(schedule.entries(from: now, mode: .normal) == [now])
        #expect(schedule.countdownStart < now)
    }
}
