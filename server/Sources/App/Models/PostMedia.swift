import Fluent
import FrndstrAPI
import Vapor

/// One image or video. Uploaded first (without a post), then attached when the post is created.
/// Files live in `<media dir>/<id>/`.
final class PostMedia: Model, @unchecked Sendable {
    static let schema = "post_media"

    @ID(key: .id) var id: UUID?
    @Parent(key: "owner_id") var owner: User
    @OptionalParent(key: "post_id") var post: Post?
    @Field(key: "kind") var kindRaw: String

    var kind: MediaKind { MediaKind(rawValue: kindRaw) ?? .image }
    @Field(key: "original_file") var originalFile: String
    @Field(key: "display_file") var displayFile: String
    @Field(key: "thumb_file") var thumbFile: String
    @Field(key: "width") var width: Int
    @Field(key: "height") var height: Int
    @OptionalField(key: "duration") var duration: Double?
    @Field(key: "position") var position: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(id: UUID, ownerID: UUID, kind: MediaKind, processed: ProcessedMedia) {
        self.id = id
        self.$owner.id = ownerID
        self.kindRaw = kind.rawValue
        self.originalFile = processed.originalFile
        self.displayFile = processed.displayFile
        self.thumbFile = processed.thumbFile
        self.width = processed.width
        self.height = processed.height
        self.duration = processed.duration
        self.position = 0
    }

    func toDTO() throws -> MediaDTO {
        let id = try requireID()
        return MediaDTO(
            id: id,
            kind: kind,
            displayPath: "\(API.Path.media)/\(id.uuidString)/display",
            thumbnailPath: "\(API.Path.media)/\(id.uuidString)/thumb",
            width: width,
            height: height,
            duration: duration
        )
    }
}

struct CreatePostMedia: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(PostMedia.schema)
            .id()
            .field("owner_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("post_id", .uuid, .references(Post.schema, "id", onDelete: .cascade))
            .field("kind", .string, .required)
            .field("original_file", .string, .required)
            .field("display_file", .string, .required)
            .field("thumb_file", .string, .required)
            .field("width", .int, .required)
            .field("height", .int, .required)
            .field("duration", .double)
            .field("position", .int, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(PostMedia.schema).delete()
    }
}
