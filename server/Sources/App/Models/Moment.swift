import Fluent
import FrndstrAPI
import Vapor

/// A BeReal-style front+back photo sent to chosen friends. The server only relays it:
/// files and rows are deleted when it expires (24h), so recipients can't keep it.
final class Moment: Model, @unchecked Sendable {
    static let schema = "moments"

    @ID(key: .id) var id: UUID?
    @Parent(key: "sender_id") var sender: User
    @OptionalField(key: "caption") var caption: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Field(key: "expires_at") var expiresAt: Date
    @Children(for: \.$moment) var recipients: [MomentRecipient]
    @OptionalField(key: "inset_corner") var insetCorner: String?
    @OptionalField(key: "swapped") var swapped: Bool?
    @OptionalField(key: "inset_size") var insetSize: Double?
    /// Unattached composite that becomes a post when the moment expires (opt-in).
    @OptionalField(key: "post_media_id") var postMediaID: UUID?
    /// JSON array of all the post's photos in order; `nil` for moments from before (then just `postMediaID`).
    @OptionalField(key: "post_media_ids") var postMediaIDsJSON: String?
    @OptionalField(key: "latitude") var latitude: Double?
    @OptionalField(key: "longitude") var longitude: Double?
    @OptionalField(key: "place_name") var placeName: String?

    var location: PostLocation? {
        guard let latitude, let longitude else { return nil }
        return PostLocation(latitude: latitude, longitude: longitude, placeName: placeName)
    }

    var postMediaIDs: [UUID] {
        if let postMediaIDsJSON, let ids = try? JSONDecoder().decode([UUID].self, from: Data(postMediaIDsJSON.utf8)), !ids.isEmpty {
            return ids
        }
        return postMediaID.map { [$0] } ?? []
    }

    var layout: MomentLayout {
        MomentLayout(insetCorner: insetCorner.flatMap(MomentLayout.Corner.init(rawValue:)) ?? .topLeading,
                     swapped: swapped ?? false, insetSize: insetSize)
    }

    init() {}

    init(id: UUID, senderID: UUID, caption: String?, expiresAt: Date) {
        self.id = id
        self.$sender.id = senderID
        self.caption = caption
        self.expiresAt = expiresAt
    }

    static func directory(for id: UUID, in app: Application) -> String {
        "\(app.appConfig.mediaDirectory)/moments/\(id.uuidString)"
    }
}

final class MomentRecipient: Model, @unchecked Sendable {
    static let schema = "moment_recipients"

    @ID(key: .id) var id: UUID?
    @Parent(key: "moment_id") var moment: Moment
    @Parent(key: "user_id") var user: User
    @OptionalField(key: "viewed_at") var viewedAt: Date?
    @OptionalField(key: "screenshot_at") var screenshotAt: Date?

    init() {}

    init(momentID: UUID, userID: UUID) {
        self.$moment.id = momentID
        self.$user.id = userID
    }
}

struct CreateMoments: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Moment.schema)
            .id()
            .field("sender_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("caption", .string)
            .field("created_at", .datetime)
            .field("expires_at", .datetime, .required)
            .create()
        try await database.schema(MomentRecipient.schema)
            .id()
            .field("moment_id", .uuid, .required, .references(Moment.schema, "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("viewed_at", .datetime)
            .field("screenshot_at", .datetime)
            .unique(on: "moment_id", "user_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(MomentRecipient.schema).delete()
        try await database.schema(Moment.schema).delete()
    }
}

struct AddMomentLayoutAndPost: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Moment.schema).field("inset_corner", .string).update()
        try await database.schema(Moment.schema).field("swapped", .bool).update()
        try await database.schema(Moment.schema).field("post_media_id", .uuid).update()
    }

    func revert(on database: any Database) async throws {
        for field in ["inset_corner", "swapped", "post_media_id"] {
            try await database.schema(Moment.schema).deleteField(.string(field)).update()
        }
    }
}

struct AddMomentInsetSize: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Moment.schema).field("inset_size", .double).update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Moment.schema).deleteField("inset_size").update()
    }
}

struct AddMomentLocation: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Moment.schema).field("latitude", .double).update()
        try await database.schema(Moment.schema).field("longitude", .double).update()
        try await database.schema(Moment.schema).field("place_name", .string).update()
    }

    func revert(on database: any Database) async throws {
        for field in ["latitude", "longitude", "place_name"] {
            try await database.schema(Moment.schema).deleteField(.string(field)).update()
        }
    }
}

struct AddMomentPostMediaList: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Moment.schema).field("post_media_ids", .string).update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Moment.schema).deleteField("post_media_ids").update()
    }
}

/// Deletes expired moments (rows + files) and publishes the opted-in ones as posts.
/// Runs at startup and every 10 minutes.
struct MomentJanitor: LifecycleHandler {
    static let interval: Duration = .seconds(600)

    func didBootAsync(_ application: Application) async throws {
        _ = try? await Self.purge(on: application)
        let app = application
        let task = Task {
            // Stop as soon as the sleep is cancelled: one more purge after shutdown would hit closed databases.
            while (try? await Task.sleep(for: Self.interval)) != nil {
                _ = try? await Self.purge(on: app)
            }
        }
        application.storage[TaskKey.self] = task
    }

    func shutdownAsync(_ application: Application) async {
        application.storage[TaskKey.self]?.cancel()
    }

    private struct TaskKey: StorageKey { typealias Value = Task<Void, Never> }

    /// Returns the number of removed moments.
    @discardableResult
    static func purge(on app: Application, now: Date = .now) async throws -> Int {
        let expired = try await Moment.query(on: app.db).filter(\.$expiresAt <= now).all()
        for moment in expired {
            let id = try moment.requireID()
            try await publishAsPost(moment, on: app.db)
            try await MomentRecipient.query(on: app.db).filter(\.$moment.$id == id).delete()
            try await moment.delete(on: app.db)
            try? FileManager.default.removeItem(atPath: Moment.directory(for: id, in: app))
        }
        if !expired.isEmpty { app.logger.info("Purged \(expired.count) expired moment(s).") }
        // Old notification events aren't needed anymore.
        try await Event.query(on: app.db).filter(\.$createdAt < now.addingTimeInterval(-30 * 24 * 3600)).delete()
        // Uploads from cancelled or failed posts would otherwise stay on disk forever.
        try await UserAdmin.removeStaleUploads(app: app)
        return expired.count
    }

    /// Only now, after the moment is over, does the composite become a (permanent) post.
    /// Its date is when the moment was taken, not when it was published.
    static func publishAsPost(_ moment: Moment, on db: any Database) async throws {
        let ids = moment.postMediaIDs
        guard !ids.isEmpty else { return }
        let found = try await PostMedia.query(on: db).filter(\.$id ~~ ids).all()
        // Keep the sender's order (big photo first); skip anything that went missing or was used meanwhile.
        let media = ids.compactMap { id in
            found.first { $0.id == id && $0.$post.id == nil && $0.$owner.id == moment.$sender.id }
        }
        guard !media.isEmpty else { return }

        let takenAt = moment.createdAt ?? .now
        try await db.transaction { db in
            let post = Post(authorID: moment.$sender.id, caption: moment.caption)
            post.takenAt = takenAt
            post.latitude = moment.latitude
            post.longitude = moment.longitude
            post.placeName = moment.placeName
            try await post.create(on: db)
            let postID = try post.requireID()
            try await Post.query(on: db).filter(\.$id == postID).set(\.$createdAt, to: takenAt).update()
            for (position, item) in media.enumerated() {
                item.$post.id = postID
                item.position = position
                try await item.save(on: db)
            }
            let sender = moment.$sender.id
            try await Event.record(.post, for: try await Event.everyone(except: sender, on: db),
                                   actor: sender, ref: postID, text: moment.caption, on: db)
        }
    }
}
