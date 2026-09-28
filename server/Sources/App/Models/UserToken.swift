import Fluent
import Vapor

/// Long-lived session token. Only the SHA-256 hash is stored, so a leaked database can't be used to log in.
final class UserToken: Model, @unchecked Sendable {
    static let schema = "user_tokens"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Field(key: "token_hash") var tokenHash: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(userID: UUID, tokenHash: String) {
        self.$user.id = userID
        self.tokenHash = tokenHash
    }

    /// Creates a token for `user`, returning the model and the raw token to hand to the client once.
    static func issue(for user: User) throws -> (model: UserToken, rawToken: String) {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let raw = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return (UserToken(userID: try user.requireID(), tokenHash: hash(raw)), raw)
    }

    static func hash(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct CreateUserTokens: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(UserToken.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("token_hash", .string, .required)
            .field("created_at", .datetime)
            .unique(on: "token_hash")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(UserToken.schema).delete()
    }
}
