import Foundation
import FrndstrAPI
import Testing
@testable import Frndstr

@MainActor
@Suite struct NotificationTests {
    private let anna = UserDTO(id: UUID(), username: "anna", displayName: "Anna", createdAt: .now)

    private func event(_ type: EventType, text: String? = nil, ref: UUID? = UUID()) -> EventDTO {
        EventDTO(id: UUID(), type: type, actor: anna, refID: ref, text: text, createdAt: .now)
    }

    @Test func momentAndPostTextsRouteCorrectly() {
        let moment = NotificationText.make(for: event(.moment))
        #expect(moment.title == "Anna sent you a moment")
        #expect(moment.route == .moments)

        let postID = UUID()
        let post = NotificationText.make(for: event(.post, text: "Kuchen!", ref: postID))
        #expect(post.title == "Anna shared a new post")
        #expect(post.body == "Kuchen!")
        #expect(post.route == .post(postID))

        let reaction = NotificationText.make(for: event(.reaction, text: "🔥", ref: postID))
        #expect(reaction.title == "Anna reacted 🔥 to your post")
        #expect(NotificationText.make(for: event(.friendRequest, ref: nil)).route == .friends)
    }

    @Test(arguments: [NotificationRoute.moments, .friends, .post(UUID())])
    func routesSurviveUserInfoEncoding(route: NotificationRoute) {
        #expect(NotificationRoute(encoded: route.encoded) == route)
    }

    @Test func defaultsMatchTheDecision() {
        // On: moments, posts, reminders. Off: comments/reactions, friend requests.
        let on = NotificationSettings.Kind.allCases.filter(\.defaultValue)
        #expect(Set(on) == [.moments, .posts, .dailyMomentTime, .streakReminder])
        #expect(NotificationSettings.kind(for: .reaction) == .commentsAndReactions)
        #expect(NotificationSettings.kind(for: .friendAccepted) == .friendRequests)
    }

    @Test func streakReminderOnlyForStreaksYouStillNeedToSend() {
        let ben = UserDTO(id: UUID(), username: "ben", displayName: "Ben", createdAt: .now)
        let waitingOnThem = StreakDTO(friend: anna, count: 5, sentToday: true, receivedToday: false, graceUsedThisWeek: false)
        let needsMe = StreakDTO(friend: ben, count: 3, sentToday: false, receivedToday: true, graceUsedThisWeek: false)
        let noStreak = StreakDTO(friend: ben, count: 0, sentToday: false, receivedToday: false, graceUsedThisWeek: false)

        #expect(NotificationText.streakReminder(for: [waitingOnThem, noStreak]) == nil)
        let reminder = NotificationText.streakReminder(for: [waitingOnThem, needsMe])
        #expect(reminder?.title == "Your 🔥 3 streak with Ben ends at midnight")
        #expect(reminder?.route == .moments)
    }
}
