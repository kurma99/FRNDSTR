import Foundation
import FrndstrAPI
import UserNotifications

/// Where a notification tap should take the user.
enum NotificationRoute: Equatable, Hashable {
    case moments
    case post(UUID)
    case friends

    var encoded: String {
        switch self {
        case .moments: "moments"
        case let .post(id): "post:\(id.uuidString)"
        case .friends: "friends"
        }
    }

    init?(encoded: String) {
        if encoded == "moments" { self = .moments }
        else if encoded == "friends" { self = .friends }
        else if encoded.hasPrefix("post:"), let id = UUID(uuidString: String(encoded.dropFirst(5))) { self = .post(id) }
        else { return nil }
    }
}

/// Which notifications the user wants (Settings › Notifications). Defaults decided 2026-09-27.
enum NotificationSettings {
    enum Kind: String, CaseIterable, Identifiable {
        case moments, posts, commentsAndReactions, friendRequests, dailyMomentTime, streakReminder
        var id: Self { self }

        var key: String { "notify.\(rawValue)" }

        var defaultValue: Bool {
            switch self {
            case .moments, .posts, .dailyMomentTime, .streakReminder: true
            case .commentsAndReactions, .friendRequests: false
            }
        }

        var title: LocalizedStringResource {
            switch self {
            case .moments: "New moments for me"
            case .posts: "New family posts"
            case .commentsAndReactions: "Comments & reactions on my posts"
            case .friendRequests: "Friend requests"
            case .dailyMomentTime: "Daily moment time"
            case .streakReminder: "Streak reminder (20:00)"
            }
        }
    }

    static func isEnabled(_ kind: Kind) -> Bool {
        UserDefaults.standard.object(forKey: kind.key) as? Bool ?? kind.defaultValue
    }

    static func kind(for type: EventType) -> Kind {
        switch type {
        case .moment: .moments
        case .post: .posts
        case .comment, .reaction: .commentsAndReactions
        case .friendRequest, .friendAccepted: .friendRequests
        }
    }
}

/// Text and destination of a notification. Pure, so it can be unit tested.
struct NotificationText: Equatable {
    var title: String
    var body: String
    var route: NotificationRoute
    /// Groups notifications in Notification Center.
    var thread: String

    static func make(for event: EventDTO) -> NotificationText {
        let name = event.actor?.displayName ?? String(localized: "Someone")
        switch event.type {
        case .moment:
            return .init(title: String(localized: "\(name) sent you a moment"),
                         body: String(localized: "Open Frndstr to see it before it disappears."),
                         route: .moments, thread: "moments")
        case .post:
            return .init(title: String(localized: "\(name) shared a new post"),
                         body: event.text ?? String(localized: "Tap to see it."),
                         route: event.refID.map(NotificationRoute.post) ?? .moments, thread: "posts")
        case .comment:
            return .init(title: String(localized: "\(name) commented on your post"),
                         body: event.text ?? "", route: event.refID.map(NotificationRoute.post) ?? .moments,
                         thread: "activity")
        case .reaction:
            return .init(title: String(localized: "\(name) reacted \(event.text ?? "") to your post"),
                         body: "", route: event.refID.map(NotificationRoute.post) ?? .moments, thread: "activity")
        case .friendRequest:
            return .init(title: String(localized: "\(name) wants to be friends"),
                         body: String(localized: "Friends share daily moments with each other."),
                         route: .friends, thread: "friends")
        case .friendAccepted:
            return .init(title: String(localized: "\(name) accepted your friend request"),
                         body: String(localized: "You can now send each other moments."),
                         route: .friends, thread: "friends")
        }
    }

    static func streakReminder(for streaks: [StreakDTO]) -> NotificationText? {
        let risky = streaks.filter { $0.isAtRisk && !$0.sentToday }
        guard let longest = risky.max(by: { $0.count < $1.count }) else { return nil }
        let title = risky.count == 1
            ? String(localized: "Your 🔥 \(longest.count) streak with \(longest.friend.displayName) ends at midnight")
            : String(localized: "\(risky.count) streaks end at midnight")
        return .init(title: title, body: String(localized: "Send a moment to keep it going."),
                     route: .moments, thread: "streaks")
    }
}

/// Local notifications for now (APNs comes in M9): polls the server inbox and schedules reminders.
@MainActor
final class Notifier: NSObject {
    static let shared = Notifier()
    static let refreshTaskID = "cloud.mallwitz.friendster.refresh"

    private let center = UNUserNotificationCenter.current()
    /// Set by the app so notification taps can route.
    weak var app: AppModel?

    override private init() {
        super.init()
        center.delegate = self
    }

    // MARK: Permission

    func requestAuthorizationIfNeeded() async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    // MARK: Sync

    /// Fetches new events and refreshes the scheduled reminders. Safe to call often.
    func sync(using app: AppModel) async {
        guard app.phase == .signedIn, let client = app.client, let userID = app.currentUser?.id else { return }
        let cursorKey = "inbox.cursor.\(userID.uuidString)"
        do {
            let stored = UserDefaults.standard.string(forKey: cursorKey)
            let page = try await client.inbox(since: stored)
            UserDefaults.standard.set(page.cursor, forKey: cursorKey)
            for event in page.events where NotificationSettings.isEnabled(NotificationSettings.kind(for: event.type)) {
                await post(NotificationText.make(for: event), id: "event-\(event.id.uuidString)")
            }
        } catch {
            app.handle(error)
        }

        if let time = try? await client.momentTime() {
            await scheduleMomentTime(time)
        }
        if let streaks = try? await client.streaks() {
            await scheduleStreakReminder(for: streaks)
        }
    }

    private func post(_ text: NotificationText, id: String, trigger: UNNotificationTrigger? = nil) async {
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.threadIdentifier = text.thread
        content.sound = .default
        content.userInfo = ["route": text.route.encoded]
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    /// "It's time for your moment" at the family's shared time today and tomorrow.
    func scheduleMomentTime(_ time: MomentTimeDTO) async {
        let ids = ["moment-time-today", "moment-time-tomorrow"]
        center.removePendingNotificationRequests(withIdentifiers: ids)
        guard NotificationSettings.isEnabled(.dailyMomentTime) else { return }

        let text = NotificationText(title: String(localized: "⚡️ Time for your moment"),
                                    body: String(localized: "Take it now – your family is taking theirs too."),
                                    route: .moments, thread: "moment-time")
        for (id, date) in zip(ids, [time.today, time.tomorrow]) where date > .now {
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            await post(text, id: id, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
        }
    }

    /// 20:00 today if a streak would end at midnight and you haven't sent that friend a moment yet.
    func scheduleStreakReminder(for streaks: [StreakDTO]) async {
        let id = "streak-reminder"
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard NotificationSettings.isEnabled(.streakReminder),
              let text = NotificationText.streakReminder(for: streaks),
              let reminder = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: .now),
              reminder > .now
        else { return }
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: reminder)
        await post(text, id: id, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
    }

    func removeAll() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// Show banners while the app is open too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let encoded = response.notification.request.content.userInfo["route"] as? String
        await MainActor.run {
            if let encoded, let route = NotificationRoute(encoded: encoded) {
                Notifier.shared.app?.pendingRoute = route
            }
        }
    }
}
