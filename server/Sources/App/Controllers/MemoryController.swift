import Fluent
import FrndstrAPI
import Vapor

/// The owner's private Memories backup: upload, list, load and delete. Nobody else can see any of it.
struct MemoryController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let memories = routes.grouped("memories").grouped(TokenAuthenticator(), User.guardMiddleware())
        memories.get(use: list)
        memories.on(.POST, body: .collect(maxSize: ByteCount(value: 3 * API.Memories.maxPhotoBytes
                                                                 + API.Memories.maxThumbnailBytes + 64 * 1024)),
                    use: upload)
        memories.delete(":memoryID", use: delete)

        // Photos are loaded like other media, so the query token is allowed.
        routes.grouped("memories").grouped(TokenAuthenticator(allowQueryToken: true), User.guardMiddleware())
            .get(":memoryID", ":variant", use: photo)
    }

    /// Multipart body: `back`, `front`, `composite` and `thumb` JPEGs plus a JSON `payload` (`MemoryDTO`).
    struct Upload: Content {
        var back: File
        var front: File
        var composite: File
        var thumb: File
        var payload: String
    }

    /// Oldest first.
    @Sendable
    func list(req: Request) async throws -> [MemoryDTO] {
        let ownerID = try req.auth.require(User.self).requireID()
        return try await MemoryBackup.query(on: req.db)
            .filter(\.$owner.$id == ownerID)
            .sort(\.$takenAt, .ascending)
            .all()
            .map { try $0.toDTO() }
    }

    /// Uploading the same memory again is a no-op, so the phone can simply retry.
    @Sendable
    func upload(req: Request) async throws -> MemoryDTO {
        let ownerID = try req.auth.require(User.self).requireID()
        let upload = try req.content.decode(Upload.self)
        var memory = try API.makeDecoder().decode(MemoryDTO.self, from: Data(upload.payload.utf8))

        if let existing = try await MemoryBackup.find(memory.id, on: req.db) {
            guard existing.$owner.id == ownerID else { throw Abort(.conflict) }
            return try existing.toDTO()
        }
        memory.caption = memory.caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        if memory.caption?.isEmpty == true { memory.caption = nil }
        guard (memory.caption?.count ?? 0) <= API.Moments.maxCaptionLength,
              memory.recipientNames.count <= 500, memory.recipientNames.allSatisfy({ $0.count <= 100 })
        else { throw Abort(.badRequest, reason: "Invalid memory details.") }
        if let location = memory.location, !location.isValid {
            throw Abort(.badRequest, reason: "Invalid location.")
        }
        let files = [("back", upload.back, API.Memories.maxPhotoBytes), ("front", upload.front, API.Memories.maxPhotoBytes),
                     ("composite", upload.composite, API.Memories.maxPhotoBytes), ("thumb", upload.thumb, API.Memories.maxThumbnailBytes)]
        for (_, file, limit) in files {
            guard file.data.readableBytes <= limit,
                  file.data.getBytes(at: file.data.readerIndex, length: 2) == [0xFF, 0xD8]
            else { throw Abort(.unsupportedMediaType, reason: "Memories must be JPEG photos.") }
        }

        // Written to a folder of its own first, so two uploads of the same memory at once (a retry while
        // the first is still running) can't delete or half-overwrite each other's photos.
        let directory = MemoryBackup.directory(for: memory.id, ownerID: ownerID, in: req.application)
        let staging = "\(directory).upload-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: staging) }
        for (name, file, _) in files {
            try await req.fileio.writeFile(file.data, at: "\(staging)/\(name).jpg")
        }
        let row = try MemoryBackup(memory, ownerID: ownerID)
        do {
            try await row.create(on: req.db)
        } catch {
            // The other upload won the race: same memory, already stored.
            if let existing = try await MemoryBackup.find(memory.id, on: req.db), existing.$owner.id == ownerID {
                return try existing.toDTO()
            }
            throw error
        }
        do {
            try? FileManager.default.removeItem(atPath: directory)
            try FileManager.default.moveItem(atPath: staging, toPath: directory)
        } catch {
            try? await row.delete(on: req.db)
            throw error
        }
        return try row.toDTO()
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        let ownerID = try req.auth.require(User.self).requireID()
        let row = try await Self.ownMemory(req, ownerID: ownerID)
        let id = try row.requireID()
        try await row.delete(on: req.db)
        try? FileManager.default.removeItem(atPath: MemoryBackup.directory(for: id, ownerID: ownerID, in: req.application))
        return .noContent
    }

    @Sendable
    func photo(req: Request) async throws -> Response {
        let ownerID = try req.auth.require(User.self).requireID()
        let row = try await Self.ownMemory(req, ownerID: ownerID)
        guard let variant = req.parameters.get("variant"), API.Memories.variants.contains(variant) else {
            throw Abort(.notFound)
        }
        let response = try await req.fileio.asyncStreamFile(
            at: "\(MemoryBackup.directory(for: try row.requireID(), ownerID: ownerID, in: req.application))/\(variant).jpg")
        response.headers.replaceOrAdd(name: .cacheControl, value: "private, no-store")
        return response
    }

    /// Someone else's memory looks exactly like a missing one.
    static func ownMemory(_ req: Request, ownerID: UUID) async throws -> MemoryBackup {
        guard let id = req.parameters.get("memoryID", as: UUID.self),
              let row = try await MemoryBackup.find(id, on: req.db),
              row.$owner.id == ownerID
        else { throw Abort(.notFound) }
        return row
    }
}
