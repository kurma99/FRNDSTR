import Fluent
import Vapor

/// A named collection of the owner's own moments, shown on their profile to friends.
/// Unlike moments these are kept: the owner's phone uploads the composites from its archive.
final class Highlight: Model, @unchecked Sendable {
    static let schema = "highlights"

    @ID(key: .id) var id: UUID?
    @Parent(key: "owner_id") var owner: User
    @Field(key: "title") var title: String
    @OptionalField(key: "cover_item_id") var coverItemID: UUID?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Children(for: \.$highlight) var items: [HighlightItem]

    init() {}

    init(ownerID: UUID, title: String) {
        self.$owner.id = ownerID
        self.title = title
    }
}

final class HighlightItem: Model, @unchecked Sendable {
    static let schema = "highlight_items"

    @ID(key: .id) var id: UUID?
    @Parent(key: "highlight_id") var highlight: Highlight
    /// The moment's ID in the owner's on-device archive.
    @Field(key: "source_id") var sourceID: UUID
    @OptionalField(key: "caption") var caption: String?
    @Field(key: "taken_at") var takenAt: Date

    init() {}

    init(id: UUID, highlightID: UUID, sourceID: UUID, caption: String?, takenAt: Date) {
        self.id = id
        self.$highlight.id = highlightID
        self.sourceID = sourceID
        self.caption = caption
        self.takenAt = takenAt
    }

    /// Holds `image.jpg` (the composite) and `thumb.jpg`.
    static func directory(for id: UUID, in app: Application) -> String {
        "\(app.appConfig.mediaDirectory)/highlights/\(id.uuidString)"
    }
}

struct CreateHighlights: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Highlight.schema)
            .id()
            .field("owner_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("title", .string, .required)
            .field("cover_item_id", .uuid)
            .field("created_at", .datetime)
            .create()
        try await database.schema(HighlightItem.schema)
            .id()
            .field("highlight_id", .uuid, .required, .references(Highlight.schema, "id", onDelete: .cascade))
            .field("source_id", .uuid, .required)
            .field("caption", .string)
            .field("taken_at", .datetime, .required)
            .unique(on: "highlight_id", "source_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(HighlightItem.schema).delete()
        try await database.schema(Highlight.schema).delete()
    }
}
