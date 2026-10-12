import Foundation

enum ClockTicker {
    static func nextMinuteBoundary(after date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .minute, for: date)?.end
            ?? Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60 + 60)
    }

    static func nextSecondBoundary(after date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.down) + 1)
    }
}
