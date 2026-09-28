import Fluent
import Vapor

/// Single-use sign-up code created by the admin (`invite` command) or on first boot.
final class Invite: Model, @unchecked Sendable {
    static let schema = "invites"

    @ID(key: .id) var id: UUID?
    /// Stored normalized: uppercase, no dash (e.g. `K7PQ2MXA`).
    @Field(key: "code") var code: String
    @OptionalParent(key: "used_by") var usedBy: User?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @OptionalField(key: "used_at") var usedAt: Date?

    init() {}

    init(code: String) {
        self.code = code
    }

    /// Human-friendly form, e.g. `K7PQ-2MXA`.
    var displayCode: String {
        code.count == 8 ? "\(code.prefix(4))-\(code.suffix(4))" : code
    }

    /// Unambiguous alphabet (no 0/O, 1/I).
    static func generateCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<8).map { _ in alphabet.randomElement(using: &generator)! })
    }

    /// Accepts `k7pq-2mxa`, `K7PQ 2MXA`, … and returns the stored form.
    static func normalize(_ input: String) -> String {
        input.uppercased().filter { $0.isLetter || $0.isNumber }
    }
}

struct CreateInvites: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Invite.schema)
            .id()
            .field("code", .string, .required)
            .field("used_by", .uuid, .references(User.schema, "id", onDelete: .setNull))
            .field("created_at", .datetime)
            .field("used_at", .datetime)
            .unique(on: "code")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Invite.schema).delete()
    }
}
