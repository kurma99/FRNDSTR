import Fluent
import FrndstrAPI
import Vapor

/// Notification inbox, the shared daily moment time, and streaks.
struct InboxController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(TokenAuthenticator(), User.guardMiddleware())
        protected.get("inbox", use: inbox)
        protected.get("moment-time", use: momentTime)
        protected.get("streaks", use: streaks)
    }

    // MARK: Inbox

    /// Events newer than `since` (cursor from the last call), oldest first. Without `since`,
    /// returns no events but a cursor for "now", so a fresh install doesn't get flooded.
    @Sendable
    func inbox(req: Request) async throws -> InboxPage {
        let userID = try req.auth.require(User.self).requireID()
        guard let since = req.query[String.self, at: "since"].flatMap(Double.init) else {
            return InboxPage(events: [], cursor: String(Date().timeIntervalSince1970))
        }
        let events = try await Event.query(on: req.db)
            .filter(\.$user.$id == userID)
            // Dates lose a few ulps on the way through Date/SQLite (notably on Linux); without the
            // margin the last event of the previous call could come back and notify twice.
            .filter(\.$createdAt > Date(timeIntervalSince1970: since + 0.000_1))
            .with(\.$actor)
            .sort(\.$createdAt, .ascending)
            .limit(100)
            .all()
        let cursor = events.last?.createdAt.map { String($0.timeIntervalSince1970) } ?? String(since)
        return InboxPage(events: try events.compactMap { try $0.toDTO() }, cursor: cursor)
    }

    // MARK: Moment time

    /// Everyone shares one random time of day; each person gets it in their own zone, so a
    /// 14:37 moment is 14:37 in Berlin and 14:37 in Tokyo rather than 22:37 there.
    @Sendable
    func momentTime(req: Request) async throws -> MomentTimeDTO {
        let zone = try await req.rememberCallerTimeZone()
        let days = ServerDay(timeZone: zone)
        let today = days.startOfDay(.now)
        return MomentTimeDTO(
            today: try await MomentTime.time(for: today, in: zone, on: req.db),
            tomorrow: try await MomentTime.time(for: days.adding(days: 1, to: today), in: zone, on: req.db)
        )
    }

    // MARK: Streaks

    /// Day keys are calendar dates in the sender's own zone (see `MomentController.create`). For a
    /// pair, "today" is the earlier of the two people's dates: Tokyo's 9 Oct doesn't close 8 Oct
    /// while it's still 8 Oct in Berlin.
    @Sendable
    func streaks(req: Request) async throws -> [StreakDTO] {
        let userID = try req.auth.require(User.self).requireID()
        let friendIDs = try await MomentController.friendIDs(of: userID, on: req.db)
        guard !friendIDs.isEmpty else { return [] }

        let rows = try await MomentDay.query(on: req.db)
            .group(.or) { $0.filter(\.$senderID == userID).filter(\.$recipientID == userID) }
            .all()
        let friends = try await User.query(on: req.db).filter(\.$id ~~ Array(friendIDs)).all()

        let fallback = req.application.appConfig.timeZone
        let myTodayKey = ServerDay(timeZone: try await req.rememberCallerTimeZone()).key(for: .now)
        // Keys are plain dates, so any one calendar can do the arithmetic between them.
        let days = ServerDay(timeZone: fallback)
        let calculator = StreakCalculator(days: days)

        return try friends.map { friend in
            let friendID = try friend.requireID()
            let theirTodayKey = ServerDay(timeZone: friend.timeZone(default: fallback)).key(for: .now)
            let todayKey = min(myTodayKey, theirTodayKey)   // yyyy-MM-dd sorts chronologically
            let sent = Set(rows.filter { $0.senderID == userID && $0.recipientID == friendID }.map(\.day))
            let received = Set(rows.filter { $0.senderID == friendID && $0.recipientID == userID }.map(\.day))
            let result = calculator.streak(aToB: sent, bToA: received, today: days.date(forKey: todayKey) ?? .now)
            return StreakDTO(friend: try friend.toDTO(), count: result.count,
                             sentToday: sent.contains(todayKey), receivedToday: received.contains(todayKey),
                             graceUsedThisWeek: result.graceUsedThisWeek)
        }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.friend.displayName < $1.friend.displayName }
    }
}

/// The family's shared random "time for your moment", one per day, picked on first request.
///
/// What's stored is the *minute of the day* (0..<1440), not an instant, and it's keyed by the
/// calendar date alone. Two people on the same date therefore get the same reading on their own
/// clocks; whoever's date rolls over first picks it for everybody.
enum MomentTime {
    static let windowKey = "moment_window"

    /// `moment_minute.2026-10-29`. The old `moment_time.` keys held absolute instants and are
    /// simply left behind: a server that upgrades mid-day re-picks once, in everyone's own zone.
    static func key(forDay dayKey: String) -> String { "moment_minute.\(dayKey)" }

    /// Admin (web dashboard): tomorrow's time is re-picked in the new window; today's stays as announced.
    /// "Tomorrow" is the instance zone's — close enough for an admin action, and it only ever
    /// discards a time that hasn't been announced yet.
    static func setWindow(_ window: MomentWindow, app: Application) async throws {
        try await InstanceSetting.set(windowKey, to: window, on: app.db)
        let days = ServerDay(timeZone: app.appConfig.timeZone)
        let tomorrow = days.key(for: days.adding(days: 1, to: days.startOfDay(.now)))
        try await InstanceSetting.find(key(forDay: tomorrow), on: app.db)?.delete(on: app.db)
    }

    static func window(on db: any Database) async throws -> MomentWindow {
        try await InstanceSetting.get(windowKey, as: MomentWindow.self, on: db) ?? .default
    }

    /// The shared minute of the day for a calendar date, picked on first ask.
    static func minute(forDay dayKey: String, on db: any Database) async throws -> Int {
        let key = key(forDay: dayKey)
        if let stored = try await InstanceSetting.find(key, on: db), let minute = Int(stored.value) {
            return minute
        }
        let window = try await window(on: db)
        let minute = Int.random(in: (window.startHour * 60)..<(window.endHour * 60))
        do {
            try await InstanceSetting(key: key, value: String(minute)).create(on: db)
            return minute
        } catch {
            // Another request picked it at the same moment: use theirs so everyone gets the same time.
            guard let stored = try await InstanceSetting.find(key, on: db), let minute = Int(stored.value) else { throw error }
            return minute
        }
    }

    /// When the moment lands for someone in `timeZone`, on `day` as their own calendar sees it.
    static func time(for day: Date, in timeZone: TimeZone, on db: any Database) async throws -> Date {
        let days = ServerDay(timeZone: timeZone)
        let minute = try await minute(forDay: days.key(for: day), on: db)
        let startOfDay = days.startOfDay(day)
        // Setting the components rather than adding seconds keeps the wall-clock reading right
        // on the two days a year a zone shifts.
        return days.calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: startOfDay)
            ?? startOfDay.addingTimeInterval(TimeInterval(minute * 60))
    }
}
