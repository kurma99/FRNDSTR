import Foundation

/// Groups archived moments into BeReal-style month grids (weeks start on Monday).
nonisolated struct MemoriesCalendar: Sendable {
    struct Day: Identifiable, Hashable, Sendable {
        /// Start of the day.
        let date: Date
        let number: Int
        /// That day's moments, oldest first.
        let memories: [ArchivedMoment]
        var id: Date { date }
    }

    struct Month: Identifiable, Hashable, Sendable {
        /// First day of the month.
        let start: Date
        /// Empty cells before the 1st so it lands under the right weekday.
        let leadingBlanks: Int
        let days: [Day]
        var id: Date { start }

        /// All moments of the month in playback order (oldest first).
        var memories: [ArchivedMoment] { days.flatMap(\.memories) }
    }

    let calendar: Calendar

    init(timeZone: TimeZone = .current, locale: Locale = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        calendar.firstWeekday = 2 // Monday, as in "MON TUE …"
        self.calendar = calendar
    }

    /// Weekday headers in display order: MON … SUN (localized, uppercased).
    var weekdaySymbols: [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols // Sunday first
        let start = calendar.firstWeekday - 1
        return (0..<7).map { symbols[(start + $0) % 7].uppercased(with: calendar.locale) }
    }

    /// Months that contain at least one moment, oldest month first, so the newest is at the bottom.
    func months(for memories: [ArchivedMoment]) -> [Month] {
        let byMonth = Dictionary(grouping: memories) { memory in
            calendar.dateInterval(of: .month, for: memory.createdAt)?.start ?? memory.createdAt
        }
        return byMonth.keys.sorted(by: <).map { start in
            month(starting: start, memories: byMonth[start] ?? [])
        }
    }

    private func month(starting start: Date, memories: [ArchivedMoment]) -> Month {
        let byDay = Dictionary(grouping: memories) { calendar.startOfDay(for: $0.createdAt) }
        let dayCount = calendar.range(of: .day, in: .month, for: start)?.count ?? 30
        let days: [Day] = (0..<dayCount).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let items = (byDay[date] ?? []).sorted { $0.createdAt < $1.createdAt }
            return Day(date: date, number: offset + 1, memories: items)
        }
        // Weekday of the 1st relative to Monday (0 = Monday … 6 = Sunday).
        let weekday = calendar.component(.weekday, from: start)
        let blanks = (weekday - calendar.firstWeekday + 7) % 7
        return Month(start: start, leadingBlanks: blanks, days: days)
    }
}
