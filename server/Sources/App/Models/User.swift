import Fluent
import FrndstrAPI
import Vapor

final class User: Model, Authenticatable, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id) var id: UUID?
    /// Lowercased, unique.
    @Field(key: "username") var username: String
    @Field(key: "display_name") var displayName: String
    @Field(key: "password_hash") var passwordHash: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    /// File name inside `<media dir>/avatars/<user id>/`; a new name per upload busts caches.
    @OptionalField(key: "avatar_file") var avatarFile: String?
    @OptionalField(key: "is_admin") var isAdminValue: Bool?

    var isAdmin: Bool {
        get { isAdminValue ?? false }
        set { isAdminValue = newValue }
    }

    init() {}

    init(id: UUID? = nil, username: String, displayName: String, passwordHash: String) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.passwordHash = passwordHash
    }

    func toDTO() throws -> UserDTO {
        let id = try requireID()
        return UserDTO(id: id, username: username, displayName: displayName, createdAt: createdAt ?? .now,
                       avatarPath: avatarFile.map { "\(API.Path.user(id))/avatar/\($0)" },
                       isAdmin: isAdmin)
    }
}

struct CreateUsers: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(User.schema)
            .id()
            .field("username", .string, .required)
            .field("display_name", .string, .required)
            .field("password_hash", .string, .required)
            .field("created_at", .datetime)
            .unique(on: "username")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(User.schema).delete()
    }
}
