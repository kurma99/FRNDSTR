import Fluent
import FriendsterAPI
import Vapor

/// Something a user should be told about. The app polls `/api/inbox` and shows local notifications;
/// APNs (M9) will push the same rows later.
final class Event: Model, @unchecked Sendable {
    static let schema = "events"

    @ID(key: .id) var id: UUID?
    /// Who gets told.
    @Parent(key: "user_id") var user: User
    @OptionalParent(key: "actor_id") var actor: User?
    @Field(key: "type") var typeRaw: String
    @OptionalField(key: "ref_id") var refID: UUID?
    @OptionalField(key: "text") var text: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(userID: UUID, actorID: UUID?, type: EventType, refID: UUID?, text: String?) {
        self.$user.id = userID
        self.$actor.id = actorID
        self.typeRaw = type.rawValue
        self.refID = refID
        self.text = text
    }

    func toDTO() throws -> EventDTO? {
        guard let type = EventType(rawValue: typeRaw) else { return nil }
        return EventDTO(id: try requireID(), type: type, actor: try actor?.toDTO(), refID: refID,
                        text: text, createdAt: createdAt ?? .now)
    }

    /// Records one event per recipient (never for the actor themself).
    static func record(_ type: EventType, for recipients: [UUID], actor: UUID?, ref: UUID?, text: String?,
                       on db: any Database) async throws {
        let preview = text.map { $0.count > 100 ? String($0.prefix(99)) + "…" : $0 }
        for recipient in Set(recipients) where recipient != actor {
            try await Event(userID: recipient, actorID: actor, type: type, refID: ref, text: preview).create(on: db)
        }
    }

    /// Everyone except `actor` (for "new post" events).
    static func everyone(except actor: UUID, on db: any Database) async throws -> [UUID] {
        try await User.query(on: db).filter(\.$id != actor).all().compactMap(\.id)
    }
}

struct CreateEvents: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Event.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("actor_id", .uuid, .references(User.schema, "id", onDelete: .setNull))
            .field("type", .string, .required)
            .field("ref_id", .uuid)
            .field("text", .string)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Event.schema).delete()
    }
}

/// Permanent record of "A sent B a moment on day D" (moments themselves are deleted after 24h).
final class MomentDay: Model, @unchecked Sendable {
    static let schema = "moment_days"

    @ID(key: .id) var id: UUID?
    @Field(key: "sender_id") var senderID: UUID
    @Field(key: "recipient_id") var recipientID: UUID
    /// `yyyy-MM-dd` in the server time zone.
    @Field(key: "day") var day: String

    init() {}

    init(senderID: UUID, recipientID: UUID, day: String) {
        self.senderID = senderID
        self.recipientID = recipientID
        self.day = day
    }
}

struct CreateMomentDays: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(MomentDay.schema)
            .id()
            .field("sender_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("recipient_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("day", .string, .required)
            .unique(on: "sender_id", "recipient_id", "day")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(MomentDay.schema).delete()
    }
}
