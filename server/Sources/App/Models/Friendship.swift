import Fluent
import FrndstrAPI
import Vapor

/// A friend request (`pending`) or an accepted friendship. At most one row per pair of users.
final class Friendship: Model, @unchecked Sendable {
    static let schema = "friendships"

    enum Status: String {
        case pending
        case accepted
    }

    @ID(key: .id) var id: UUID?
    @Parent(key: "requester_id") var requester: User
    @Parent(key: "addressee_id") var addressee: User
    @Field(key: "status") var statusRaw: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    var status: Status {
        get { Status(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    init() {}

    init(requesterID: UUID, addresseeID: UUID) {
        self.$requester.id = requesterID
        self.$addressee.id = addresseeID
        self.statusRaw = Status.pending.rawValue
    }

    /// The row connecting two users, in either direction.
    static func between(_ a: UUID, _ b: UUID, on db: any Database) async throws -> Friendship? {
        try await Friendship.query(on: db)
            .group(.or) { either in
                either.group(.and) { $0.filter(\.$requester.$id == a).filter(\.$addressee.$id == b) }
                either.group(.and) { $0.filter(\.$requester.$id == b).filter(\.$addressee.$id == a) }
            }
            .first()
    }

    /// Status of `other` as seen by `viewer`.
    static func status(viewer: UUID, other: UUID, on db: any Database) async throws -> FriendshipStatus {
        if viewer == other { return .me }
        guard let row = try await between(viewer, other, on: db) else { return .none }
        switch row.status {
        case .accepted: return .friends
        case .pending: return row.$requester.id == viewer ? .outgoing : .incoming
        }
    }

    static func friendCount(of user: UUID, on db: any Database) async throws -> Int {
        try await Friendship.query(on: db)
            .filter(\.$statusRaw == Status.accepted.rawValue)
            .group(.or) { $0.filter(\.$requester.$id == user).filter(\.$addressee.$id == user) }
            .count()
    }
}

struct CreateFriendships: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Friendship.schema)
            .id()
            .field("requester_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("addressee_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("status", .string, .required)
            .field("created_at", .datetime)
            .unique(on: "requester_id", "addressee_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Friendship.schema).delete()
    }
}
