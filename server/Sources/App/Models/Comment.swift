import Fluent
import FriendsterAPI
import Vapor

final class Comment: Model, @unchecked Sendable {
    static let schema = "comments"

    @ID(key: .id) var id: UUID?
    @Parent(key: "post_id") var post: Post
    @Parent(key: "author_id") var author: User
    @Field(key: "text") var text: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(postID: UUID, authorID: UUID, text: String) {
        self.$post.id = postID
        self.$author.id = authorID
        self.text = text
    }

    /// Requires `author` to be eager-loaded.
    func toDTO() throws -> CommentDTO {
        CommentDTO(id: try requireID(), postID: $post.id, author: try author.toDTO(),
                   text: text, createdAt: createdAt ?? .now)
    }
}

struct CreateComments: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Comment.schema)
            .id()
            .field("post_id", .uuid, .required, .references(Post.schema, "id", onDelete: .cascade))
            .field("author_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("text", .string, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Comment.schema).delete()
    }
}
