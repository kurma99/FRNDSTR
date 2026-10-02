import Fluent
import FrndstrAPI
import Vapor

extension PostLocation {
    /// Coordinates in range and a reasonably short place name (posts and moments).
    var isValid: Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude) && (placeName?.count ?? 0) <= 120
    }
}

final class Post: Model, @unchecked Sendable {
    static let schema = "posts"

    @ID(key: .id) var id: UUID?
    @Parent(key: "author_id") var author: User
    @OptionalField(key: "caption") var caption: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Children(for: \.$post) var media: [PostMedia]
    @OptionalField(key: "latitude") var latitude: Double?
    @OptionalField(key: "longitude") var longitude: Double?
    @OptionalField(key: "place_name") var placeName: String?
    @OptionalField(key: "taken_at") var takenAt: Date?

    init() {}

    init(authorID: UUID, caption: String?) {
        self.$author.id = authorID
        self.caption = caption
    }

    var location: PostLocation? {
        guard let latitude, let longitude else { return nil }
        return PostLocation(latitude: latitude, longitude: longitude, placeName: placeName)
    }

    /// Requires `author` and `media` to be eager-loaded. Social counts come from `PostPresenter`.
    func toDTO(reactions: [ReactionCount] = [], myReaction: String? = nil, commentCount: Int = 0) throws -> PostDTO {
        PostDTO(
            id: try requireID(),
            author: try author.toDTO(),
            caption: caption,
            createdAt: createdAt ?? .now,
            media: try media.sorted { $0.position < $1.position }.map { try $0.toDTO() },
            location: location,
            takenAt: takenAt,
            reactions: reactions,
            myReaction: myReaction,
            commentCount: commentCount
        )
    }
}

struct CreatePosts: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Post.schema)
            .id()
            .field("author_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("caption", .string)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Post.schema).delete()
    }
}
