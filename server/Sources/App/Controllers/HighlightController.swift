import Fluent
import FRNDSAPI
import Vapor

/// Highlights: named collections of your own moments on your profile, visible to friends only.
struct HighlightController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped(TokenAuthenticator(), User.guardMiddleware())
        auth.get("users", ":userID", "highlights", use: list)

        let highlights = auth.grouped("highlights")
        highlights.post(use: create)
        highlights.patch(":highlightID", use: update)
        highlights.delete(":highlightID", use: delete)
        highlights.on(.POST, ":highlightID", "items",
                      body: .collect(maxSize: ByteCount(value: API.Highlights.maxPhotoBytes + API.Highlights.maxThumbnailBytes + 64 * 1024)),
                      use: addItem)
        highlights.delete(":highlightID", "items", ":itemID", use: removeItem)

        // Photos are loaded like other media, so the query token is allowed.
        routes.grouped("highlights").grouped(TokenAuthenticator(allowQueryToken: true), User.guardMiddleware())
            .get(":highlightID", "items", ":itemID", ":variant", use: photo)
    }

    /// Multipart body: `image` (composite) and `thumbnail` JPEGs plus a JSON `payload` (`AddHighlightItemRequest`).
    struct Upload: Content {
        var image: File
        var thumbnail: File
        var payload: String
    }

    /// The owner's highlights, newest first. Empty for people who aren't friends.
    /// Friends only get moments whose 24 hours are over, and no highlights that have none yet.
    @Sendable
    func list(req: Request) async throws -> [HighlightDTO] {
        let viewerID = try req.auth.require(User.self).requireID()
        guard let ownerID = req.parameters.get("userID", as: UUID.self) else { throw Abort(.badRequest) }
        guard try await Self.canView(ownerID: ownerID, viewerID: viewerID, on: req.db) else { return [] }
        let highlights = try await Highlight.query(on: req.db)
            .filter(\.$owner.$id == ownerID)
            .with(\.$items)
            .sort(\.$createdAt, .descending)
            .all()
        let dtos = try highlights.map(Self.dto)
        guard ownerID != viewerID else { return dtos }
        let now = Date()
        return dtos.compactMap { highlight in
            var visible = highlight
            visible.items = highlight.items.filter { $0.visibleToFriendsFrom <= now }
            return visible.items.isEmpty ? nil : visible
        }
    }

    @Sendable
    func create(req: Request) async throws -> HighlightDTO {
        let userID = try req.auth.require(User.self).requireID()
        let body = try req.content.decode(CreateHighlightRequest.self)
        let highlight = Highlight(ownerID: userID, title: try Self.validTitle(body.title))
        try await highlight.create(on: req.db)
        return try await Self.reloadedDTO(try highlight.requireID(), on: req.db)
    }

    @Sendable
    func update(req: Request) async throws -> HighlightDTO {
        let highlight = try await Self.ownHighlight(req)
        let body = try req.content.decode(UpdateHighlightRequest.self)
        if let title = body.title { highlight.title = try Self.validTitle(title) }
        if let cover = body.coverItemID {
            guard highlight.items.contains(where: { $0.id == cover }) else {
                throw Abort(.badRequest, reason: "The cover must be one of the highlight's moments.")
            }
            highlight.coverItemID = cover
        }
        try await highlight.save(on: req.db)
        return try Self.dto(highlight)
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        let highlight = try await Self.ownHighlight(req)
        let itemIDs = highlight.items.compactMap(\.id)
        try await req.db.transaction { db in
            try await HighlightItem.query(on: db).filter(\.$highlight.$id == highlight.requireID()).delete()
            try await highlight.delete(on: db)
        }
        for id in itemIDs { try? FileManager.default.removeItem(atPath: HighlightItem.directory(for: id, in: req.application)) }
        return .noContent
    }

    /// Adds one of the owner's archived moments. Adding the same moment again is a no-op.
    @Sendable
    func addItem(req: Request) async throws -> HighlightDTO {
        let highlight = try await Self.ownHighlight(req)
        let highlightID = try highlight.requireID()
        let upload = try req.content.decode(Upload.self)
        let body = try API.makeDecoder().decode(AddHighlightItemRequest.self, from: Data(upload.payload.utf8))

        if highlight.items.contains(where: { $0.sourceID == body.sourceID }) { return try Self.dto(highlight) }
        guard highlight.items.count < API.Highlights.maxItems else {
            throw Abort(.badRequest, reason: "A highlight can hold up to \(API.Highlights.maxItems) moments.")
        }
        let caption = body.caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (caption?.count ?? 0) <= API.Moments.maxCaptionLength else {
            throw Abort(.badRequest, reason: "Caption is too long.")
        }
        for (file, limit) in [(upload.image, API.Highlights.maxPhotoBytes), (upload.thumbnail, API.Highlights.maxThumbnailBytes)] {
            guard file.data.readableBytes <= limit,
                  file.data.getBytes(at: file.data.readerIndex, length: 2) == [0xFF, 0xD8]
            else { throw Abort(.unsupportedMediaType, reason: "Highlights must be JPEG photos.") }
        }

        let id = UUID()
        let directory = HighlightItem.directory(for: id, in: req.application)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try await req.fileio.writeFile(upload.image.data, at: "\(directory)/image.jpg")
        try await req.fileio.writeFile(upload.thumbnail.data, at: "\(directory)/thumb.jpg")
        do {
            try await HighlightItem(id: id, highlightID: highlightID, sourceID: body.sourceID,
                                    caption: (caption?.isEmpty ?? true) ? nil : caption,
                                    // A future date would never become visible; clamp it.
                                    takenAt: min(body.takenAt, .now))
                .create(on: req.db)
        } catch {
            try? FileManager.default.removeItem(atPath: directory)
            throw error
        }
        return try await Self.reloadedDTO(highlightID, on: req.db)
    }

    @Sendable
    func removeItem(req: Request) async throws -> HighlightDTO {
        let highlight = try await Self.ownHighlight(req)
        guard let itemID = req.parameters.get("itemID", as: UUID.self),
              let item = highlight.items.first(where: { $0.id == itemID })
        else { throw Abort(.notFound) }
        try await item.delete(on: req.db)
        try? FileManager.default.removeItem(atPath: HighlightItem.directory(for: itemID, in: req.application))
        if highlight.coverItemID == itemID {
            highlight.coverItemID = nil
            try await highlight.save(on: req.db)
        }
        return try await Self.reloadedDTO(try highlight.requireID(), on: req.db)
    }

    /// Serves `image` or `thumb` to the owner and their friends.
    @Sendable
    func photo(req: Request) async throws -> Response {
        let viewerID = try req.auth.require(User.self).requireID()
        guard let highlightID = req.parameters.get("highlightID", as: UUID.self),
              let itemID = req.parameters.get("itemID", as: UUID.self),
              let variant = req.parameters.get("variant"), ["image", "thumb"].contains(variant),
              let item = try await HighlightItem.query(on: req.db)
                  .filter(\.$id == itemID).filter(\.$highlight.$id == highlightID)
                  .with(\.$highlight).first(),
              try await Self.canView(ownerID: item.highlight.$owner.id, viewerID: viewerID, on: req.db),
              item.highlight.$owner.id == viewerID || API.Highlights.visibleToFriendsFrom(takenAt: item.takenAt) <= .now
        else { throw Abort(.notFound) }

        let response = try await req.fileio.asyncStreamFile(
            at: "\(HighlightItem.directory(for: itemID, in: req.application))/\(variant).jpg")
        // Files never change for an item ID; private so shared caches don't keep them.
        response.headers.replaceOrAdd(name: .cacheControl, value: "private, max-age=604800")
        return response
    }

    // MARK: Helpers

    static func canView(ownerID: UUID, viewerID: UUID, on db: any Database) async throws -> Bool {
        if ownerID == viewerID { return true }
        return try await MomentController.friendIDs(of: viewerID, on: db).contains(ownerID)
    }

    static func validTitle(_ raw: String) throws -> String {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...API.Highlights.maxTitleLength).contains(title.count) else {
            throw Abort(.badRequest, reason: "Give the highlight a name of up to \(API.Highlights.maxTitleLength) characters.")
        }
        return title
    }

    static func load(_ id: UUID, on db: any Database) async throws -> Highlight? {
        try await Highlight.query(on: db).filter(\.$id == id).with(\.$items).first()
    }

    static func reloadedDTO(_ id: UUID, on db: any Database) async throws -> HighlightDTO {
        guard let highlight = try await load(id, on: db) else { throw Abort(.notFound) }
        return try dto(highlight)
    }

    /// The caller's own highlight from `:highlightID`, with its items.
    static func ownHighlight(_ req: Request) async throws -> Highlight {
        let userID = try req.auth.require(User.self).requireID()
        guard let id = req.parameters.get("highlightID", as: UUID.self),
              let highlight = try await load(id, on: req.db)
        else { throw Abort(.notFound) }
        guard highlight.$owner.id == userID else { throw Abort(.forbidden, reason: "You can only change your own highlights.") }
        return highlight
    }

    static func dto(_ highlight: Highlight) throws -> HighlightDTO {
        let id = try highlight.requireID()
        let items = try highlight.items
            .sorted { $0.takenAt < $1.takenAt }
            .map { item in
                let itemID = try item.requireID()
                let base = API.Path.highlightItem(id, itemID)
                return HighlightItemDTO(id: itemID, sourceID: item.sourceID, caption: item.caption, takenAt: item.takenAt,
                                        imagePath: "\(base)/image", thumbnailPath: "\(base)/thumb")
            }
        return HighlightDTO(id: id, ownerID: highlight.$owner.id, title: highlight.title,
                            coverItemID: highlight.coverItemID, items: items, createdAt: highlight.createdAt ?? .now)
    }
}
