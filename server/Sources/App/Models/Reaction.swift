import Fluent
import Vapor

/// One emoji reaction per user and post (reacting again replaces it).
final class Reaction: Model, @unchecked Sendable {
    static let schema = "reactions"

    @ID(key: .id) var id: UUID?
    @Parent(key: "post_id") var post: Post
    @Parent(key: "user_id") var user: User
    @Field(key: "emoji") var emoji: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(postID: UUID, userID: UUID, emoji: String) {
        self.$post.id = postID
        self.$user.id = userID
        self.emoji = emoji
    }
}

struct CreateReactions: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Reaction.schema)
            .id()
            .field("post_id", .uuid, .required, .references(Post.schema, "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("emoji", .string, .required)
            .field("created_at", .datetime)
            .unique(on: "post_id", "user_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Reaction.schema).delete()
    }
}
