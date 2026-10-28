import SwiftUI

nonisolated struct RecordingTimeSchedule: TimelineSchedule {
    let deadline: Date

    var countdownStart: Date { deadline.addingTimeInterval(-10) }

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> [Date] {
        startDate < countdownStart ? [startDate, countdownStart] : [startDate]
    }
}
