import Foundation

/// "Days" as the family experiences them: calendar days in the server's `TIME_ZONE`, weeks starting Monday.
struct ServerDay: Sendable {
    let calendar: Calendar

    init(timeZone: TimeZone) {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    /// `yyyy-MM-dd`
    func key(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func date(forKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    func startOfDay(_ date: Date) -> Date { calendar.startOfDay(for: date) }

    func adding(days: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date
    }

    /// ISO week identifier, e.g. 202639.
    func week(of date: Date) -> Int {
        let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return (parts.yearForWeekOfYear ?? 0) * 100 + (parts.weekOfYear ?? 0)
    }
}

/// Streak rule (decided 2026-09-27): a day counts when both friends sent each other a moment.
/// One missed day per calendar week (Mon–Sun) is forgiven; a second miss in the same week ends it.
/// Today never breaks a streak while it's still in progress.
struct StreakCalculator: Sendable {
    let days: ServerDay

    struct Result: Equatable {
        var count: Int
        var graceUsedThisWeek: Bool
    }

    /// `aToB` / `bToA`: day keys on which each side sent the other at least one moment.
    func streak(aToB: Set<String>, bToA: Set<String>, today: Date) -> Result {
        let complete = aToB.intersection(bToA)
        guard let earliestKey = complete.min(), let earliest = days.date(forKey: earliestKey) else {
            return Result(count: 0, graceUsedThisWeek: false)
        }

        let todayStart = days.startOfDay(today)
        var count = complete.contains(days.key(for: todayStart)) ? 1 : 0
        var graceWeeks: Set<Int> = []
        var day = days.adding(days: -1, to: todayStart)

        while day >= earliest {
            if complete.contains(days.key(for: day)) {
                count += 1
            } else {
                let week = days.week(of: day)
                if graceWeeks.contains(week) { break }
                graceWeeks.insert(week)
            }
            day = days.adding(days: -1, to: day)
        }
        return Result(count: count, graceUsedThisWeek: count > 0 && graceWeeks.contains(days.week(of: todayStart)))
    }
}
