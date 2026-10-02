import Fluent
import FrndstrAPI
import Vapor

/// A private copy of one of the owner's Memories (their own moments), uploaded by their phone.
/// Only the owner can ever list or load it; it exists so a new phone or a reinstall gets Memories back.
final class MemoryBackup: Model, @unchecked Sendable {
    static let schema = "memory_backups"

    /// The moment's ID in the owner's on-device archive.
    @ID(key: .id) var id: UUID?
    @Parent(key: "owner_id") var owner: User
    @Field(key: "taken_at") var takenAt: Date
    @OptionalField(key: "caption") var caption: String?
    /// JSON array of display names, as shown in the app ("Sent to …").
    @Field(key: "recipient_names") var recipientNamesJSON: String
    @OptionalField(key: "inset_corner") var insetCorner: String?
    @OptionalField(key: "swapped") var swapped: Bool?
    @OptionalField(key: "inset_size") var insetSize: Double?
    @OptionalField(key: "latitude") var latitude: Double?
    @OptionalField(key: "longitude") var longitude: Double?
    @OptionalField(key: "place_name") var placeName: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(_ memory: MemoryDTO, ownerID: UUID) throws {
        self.id = memory.id
        self.$owner.id = ownerID
        self.takenAt = memory.takenAt
        self.caption = memory.caption
        self.recipientNamesJSON = String(decoding: try JSONEncoder().encode(memory.recipientNames), as: UTF8.self)
        self.insetCorner = memory.layout?.insetCorner.rawValue
        self.swapped = memory.layout?.swapped
        self.insetSize = memory.layout?.insetSize
        self.latitude = memory.location?.latitude
        self.longitude = memory.location?.longitude
        self.placeName = memory.location?.placeName
    }

    func toDTO() throws -> MemoryDTO {
        let names = (try? JSONDecoder().decode([String].self, from: Data(recipientNamesJSON.utf8))) ?? []
        let layout = insetCorner.flatMap(MomentLayout.Corner.init(rawValue:)).map {
            MomentLayout(insetCorner: $0, swapped: swapped ?? false, insetSize: insetSize)
        }
        let location = latitude.flatMap { lat in longitude.map { PostLocation(latitude: lat, longitude: $0, placeName: placeName) } }
        return MemoryDTO(id: try requireID(), takenAt: takenAt, caption: caption, recipientNames: names,
                         layout: layout, location: location)
    }

    /// All of an owner's backups live under one folder, so deleting the account removes them in one go.
    static func ownerDirectory(_ ownerID: UUID, in app: Application) -> String {
        "\(app.appConfig.mediaDirectory)/memories/\(ownerID.uuidString)"
    }

    /// Holds `back.jpg`, `front.jpg`, `composite.jpg` and `thumb.jpg`.
    static func directory(for id: UUID, ownerID: UUID, in app: Application) -> String {
        "\(ownerDirectory(ownerID, in: app))/\(id.uuidString)"
    }
}

struct CreateMemoryBackups: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(MemoryBackup.schema)
            .id()
            .field("owner_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("taken_at", .datetime, .required)
            .field("caption", .string)
            .field("recipient_names", .string, .required)
            .field("inset_corner", .string)
            .field("swapped", .bool)
            .field("inset_size", .double)
            .field("latitude", .double)
            .field("longitude", .double)
            .field("place_name", .string)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(MemoryBackup.schema).delete()
    }
}
