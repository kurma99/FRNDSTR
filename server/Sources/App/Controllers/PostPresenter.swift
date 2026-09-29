import Fluent
import FRNDSAPI
import Vapor

/// Builds `PostDTO`s including reaction and comment counts, using one query per table for a whole page.
enum PostPresenter {
    static func dtos(for posts: [Post], viewerID: UUID, on db: any Database) async throws -> [PostDTO] {
        let ids = try posts.map { try $0.requireID() }
        guard !ids.isEmpty else { return [] }

        let reactions = try await Reaction.query(on: db).filter(\.$post.$id ~~ ids).all()
        let commentPostIDs = try await Comment.query(on: db)
            .filter(\.$post.$id ~~ ids)
            .field(\.$post.$id)
            .all()
            .map(\.$post.id)

        let reactionsByPost = Dictionary(grouping: reactions, by: \.$post.id)
        var commentCounts: [UUID: Int] = [:]
        for id in commentPostIDs { commentCounts[id, default: 0] += 1 }

        return try posts.map { post in
            let id = try post.requireID()
            let postReactions = reactionsByPost[id] ?? []
            return try post.toDTO(
                reactions: summarize(postReactions),
                myReaction: postReactions.first { $0.$user.id == viewerID }?.emoji,
                commentCount: commentCounts[id] ?? 0
            )
        }
    }

    static func dto(for post: Post, viewerID: UUID, on db: any Database) async throws -> PostDTO {
        try await dtos(for: [post], viewerID: viewerID, on: db)[0]
    }

    /// Most used emoji first; ties keep the palette order.
    static func summarize(_ reactions: [Reaction]) -> [ReactionCount] {
        var counts: [String: Int] = [:]
        for reaction in reactions { counts[reaction.emoji, default: 0] += 1 }
        let order = API.defaultReactionEmojis
        return counts
            .map { ReactionCount(emoji: $0.key, count: $0.value) }
            .sorted {
                $0.count != $1.count
                    ? $0.count > $1.count
                    : (order.firstIndex(of: $0.emoji) ?? .max) < (order.firstIndex(of: $1.emoji) ?? .max)
            }
    }

    /// Loads a post with author and media, or throws 404.
    static func load(_ id: UUID?, on db: any Database) async throws -> Post {
        guard let id,
              let post = try await Post.query(on: db)
                .filter(\.$id == id)
                .with(\.$author)
                .with(\.$media)
                .first()
        else { throw Abort(.notFound, reason: "This post doesn't exist anymore.") }
        return post
    }
}
