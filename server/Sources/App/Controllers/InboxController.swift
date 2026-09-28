import Fluent
import FriendsterAPI
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

    @Sendable
    func momentTime(req: Request) async throws -> MomentTimeDTO {
        let days = ServerDay(timeZone: req.application.appConfig.timeZone)
        let today = days.startOfDay(.now)
        return MomentTimeDTO(
            today: try await MomentTime.time(for: today, days: days, on: req.db),
            tomorrow: try await MomentTime.time(for: days.adding(days: 1, to: today), days: days, on: req.db)
        )
    }

    // MARK: Streaks

    @Sendable
    func streaks(req: Request) async throws -> [StreakDTO] {
        let userID = try req.auth.require(User.self).requireID()
        let friendIDs = try await MomentController.friendIDs(of: userID, on: req.db)
        guard !friendIDs.isEmpty else { return [] }

        let rows = try await MomentDay.query(on: req.db)
            .group(.or) { $0.filter(\.$senderID == userID).filter(\.$recipientID == userID) }
            .all()
        let friends = try await User.query(on: req.db).filter(\.$id ~~ Array(friendIDs)).all()

        let days = ServerDay(timeZone: req.application.appConfig.timeZone)
        let todayKey = days.key(for: .now)
        let calculator = StreakCalculator(days: days)

        return try friends.map { friend in
            let friendID = try friend.requireID()
            let sent = Set(rows.filter { $0.senderID == userID && $0.recipientID == friendID }.map(\.day))
            let received = Set(rows.filter { $0.senderID == friendID && $0.recipientID == userID }.map(\.day))
            let result = calculator.streak(aToB: sent, bToA: received, today: .now)
            return StreakDTO(friend: try friend.toDTO(), count: result.count,
                             sentToday: sent.contains(todayKey), receivedToday: received.contains(todayKey),
                             graceUsedThisWeek: result.graceUsedThisWeek)
        }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.friend.displayName < $1.friend.displayName }
    }
}

/// The family's shared random "time for your moment", one per day, picked on first request.
enum MomentTime {
    static let windowKey = "moment_window"

    static func key(for day: Date, days: ServerDay) -> String { "moment_time.\(days.key(for: day))" }

    /// Admin (web dashboard): tomorrow's time is re-picked in the new window; today's stays as announced.
    static func setWindow(_ window: MomentWindow, app: Application) async throws {
        try await InstanceSetting.set(windowKey, to: window, on: app.db)
        let days = ServerDay(timeZone: app.appConfig.timeZone)
        let tomorrow = days.adding(days: 1, to: days.startOfDay(.now))
        try await InstanceSetting.find(key(for: tomorrow, days: days), on: app.db)?.delete(on: app.db)
    }

    static func window(on db: any Database) async throws -> MomentWindow {
        try await InstanceSetting.get(windowKey, as: MomentWindow.self, on: db) ?? .default
    }

    static func time(for day: Date, days: ServerDay, on db: any Database) async throws -> Date {
        let key = key(for: day, days: days)
        if let stored = try await InstanceSetting.find(key, on: db), let seconds = Double(stored.value) {
            return Date(timeIntervalSince1970: seconds)
        }
        let window = try await window(on: db)
        let minute = Int.random(in: (window.startHour * 60)..<(window.endHour * 60))
        let time = days.startOfDay(day).addingTimeInterval(TimeInterval(minute * 60))
        do {
            try await InstanceSetting(key: key, value: String(time.timeIntervalSince1970)).create(on: db)
            return time
        } catch {
            // Another request picked it at the same moment: use theirs so everyone gets the same time.
            guard let stored = try await InstanceSetting.find(key, on: db), let seconds = Double(stored.value) else { throw error }
            return Date(timeIntervalSince1970: seconds)
        }
    }
}
