import Foundation
import FRNDSAPI
import Testing
@testable import FRNDS

@MainActor
@Suite struct ServerAddressTests {
    @Test(arguments: [
        ("192.168.1.20:8080", "http://192.168.1.20:8080"),
        ("  nas.tail1234.ts.net:8080/ ", "http://nas.tail1234.ts.net:8080"),
        ("https://photos.example.com/", "https://photos.example.com"),
        ("HTTP://100.71.61.43:8080", "http://100.71.61.43:8080"),
    ])
    func parsesAddresses(input: String, expected: String) {
        #expect(ServerAddress.parse(input)?.absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "ftp://example.com", "http://"])
    func rejectsInvalid(input: String) {
        #expect(ServerAddress.parse(input) == nil)
    }
}

@MainActor
@Suite struct ReactionPredictionTests {
    private func post(reactions: [ReactionCount], mine: String?) -> PostDTO {
        let user = UserDTO(id: UUID(), username: "anna", displayName: "Anna", createdAt: .now)
        return PostDTO(id: UUID(), author: user, caption: nil, createdAt: .now, media: [],
                       reactions: reactions, myReaction: mine)
    }

    @Test func reactingAddsOne() {
        let updated = PostCardView.applying("❤️", to: post(reactions: [], mine: nil))
        #expect(updated.reactions == [ReactionCount(emoji: "❤️", count: 1)])
        #expect(updated.myReaction == "❤️")
    }

    @Test func switchingMovesTheCount() {
        let start = post(reactions: [ReactionCount(emoji: "❤️", count: 2)], mine: "❤️")
        let updated = PostCardView.applying("😂", to: start)
        #expect(Set(updated.reactions) == [ReactionCount(emoji: "❤️", count: 1), ReactionCount(emoji: "😂", count: 1)])
        #expect(updated.totalReactions == 2)
    }

    @Test func removingDropsEmptyEntries() {
        let updated = PostCardView.applying(nil, to: post(reactions: [ReactionCount(emoji: "🔥", count: 1)], mine: "🔥"))
        #expect(updated.reactions.isEmpty)
        #expect(updated.myReaction == nil)
    }
}
