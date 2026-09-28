import Fluent
import FriendsterAPI
import Vapor

/// Key/value store for settings admins can change in the app.
final class InstanceSetting: Model, @unchecked Sendable {
    static let schema = "instance_settings"

    @ID(custom: "key", generatedBy: .user) var id: String?
    @Field(key: "value") var value: String

    init() {}

    init(key: String, value: String) {
        self.id = key
        self.value = value
    }

    static let reactionPaletteKey = "reaction_palette"

    /// JSON-encoded setting, or `nil` if unset/unreadable.
    static func get<T: Decodable>(_ key: String, as type: T.Type, on db: any Database) async throws -> T? {
        guard let setting = try await InstanceSetting.find(key, on: db) else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(setting.value.utf8))
    }

    static func set(_ key: String, to value: some Encodable, on db: any Database) async throws {
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        if let existing = try await InstanceSetting.find(key, on: db) {
            existing.value = json
            try await existing.save(on: db)
        } else {
            try await InstanceSetting(key: key, value: json).create(on: db)
        }
    }

    /// The current reaction palette (JSON array), falling back to the default.
    static func reactionPalette(on db: any Database) async throws -> [String] {
        guard let setting = try await InstanceSetting.find(reactionPaletteKey, on: db),
              let palette = try? JSONDecoder().decode([String].self, from: Data(setting.value.utf8)),
              !palette.isEmpty
        else { return API.defaultReactionEmojis }
        return palette
    }

    static func setReactionPalette(_ palette: [String], on db: any Database) async throws {
        let json = String(decoding: try JSONEncoder().encode(palette), as: UTF8.self)
        if let existing = try await InstanceSetting.find(reactionPaletteKey, on: db) {
            existing.value = json
            try await existing.save(on: db)
        } else {
            try await InstanceSetting(key: reactionPaletteKey, value: json).create(on: db)
        }
    }
}

struct CreateInstanceSettings: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(InstanceSetting.schema)
            .field("key", .string, .identifier(auto: false))
            .field("value", .string, .required)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(InstanceSetting.schema).delete()
    }
}

/// Adds `is_admin` and makes the earliest existing user the admin.
struct AddUserAdmin: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(User.schema).field("is_admin", .bool).update()
        if let first = try await User.query(on: database).sort(\.$createdAt, .ascending).first() {
            first.isAdmin = true
            try await first.save(on: database)
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(User.schema).deleteField("is_admin").update()
    }
}
