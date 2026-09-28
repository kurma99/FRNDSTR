import Fluent

// SQLite can only add one column per ALTER TABLE, hence one `update()` per field.

/// Optional location and capture date on posts (M3).
struct AddPostLocation: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Post.schema).field("latitude", .double).update()
        try await database.schema(Post.schema).field("longitude", .double).update()
        try await database.schema(Post.schema).field("place_name", .string).update()
        try await database.schema(Post.schema).field("taken_at", .datetime).update()
    }

    func revert(on database: any Database) async throws {
        for field in ["latitude", "longitude", "place_name", "taken_at"] {
            try await database.schema(Post.schema).deleteField(.string(field)).update()
        }
    }
}

/// Profile photo file name (M2).
struct AddUserAvatar: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(User.schema).field("avatar_file", .string).update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(User.schema).deleteField("avatar_file").update()
    }
}
