import Fluent
import FrndstrAPI
import Vapor

/// Sending, listing and viewing moments.
struct MomentController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let moments = routes.grouped("moments").grouped(TokenAuthenticator(), User.guardMiddleware())
        moments.get(use: feed)
        moments.on(.POST, body: .collect(maxSize: ByteCount(value: 2 * API.Moments.maxPhotoBytes + 64 * 1024)), use: create)
        moments.post(":momentID", "view", use: markViewed)
        moments.post(":momentID", "screenshot", use: markScreenshot)

        // Photos are loaded like other media, so the query token is allowed.
        routes.grouped("moments").grouped(TokenAuthenticator(allowQueryToken: true), User.guardMiddleware())
            .get(":momentID", ":side", use: photo)
    }

    /// Multipart body: `back` and `front` JPEG files plus a JSON `payload` (`CreateMomentRequest`).
    struct Upload: Content {
        var back: File
        var front: File
        var payload: String
    }

    @Sendable
    func create(req: Request) async throws -> MomentDTO {
        let sender = try req.auth.require(User.self)
        let senderID = try sender.requireID()
        let upload = try req.content.decode(Upload.self)
        let body = try API.makeDecoder().decode(CreateMomentRequest.self, from: Data(upload.payload.utf8))

        let caption = body.caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (caption?.count ?? 0) <= API.Moments.maxCaptionLength else {
            throw Abort(.badRequest, reason: "Caption is too long.")
        }
        // No recipients is fine: a moment just for yourself (e.g. before you have friends).
        // It still counts as today's moment and can become a post when it's over.
        let recipientIDs = Array(Set(body.recipientIDs))

        // Only accepted friends may receive it.
        let friendIDs = try await Self.friendIDs(of: senderID, on: req.db)
        guard Set(recipientIDs).isSubset(of: friendIDs) else {
            throw Abort(.badRequest, reason: "Moments can only be sent to friends.")
        }
        if let mediaID = body.postMediaID {
            guard let media = try await PostMedia.find(mediaID, on: req.db),
                  media.$owner.id == senderID, media.$post.id == nil, media.kind == .image
            else { throw Abort(.badRequest, reason: "The photo for the post couldn't be found. Please try again.") }
        }
        for file in [upload.back, upload.front] {
            guard file.data.readableBytes <= API.Moments.maxPhotoBytes,
                  file.data.getBytes(at: file.data.readerIndex, length: 2) == [0xFF, 0xD8]
            else { throw Abort(.unsupportedMediaType, reason: "Moments must be JPEG photos.") }
        }

        let id = UUID()
        let directory = Moment.directory(for: id, in: req.application)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try await req.fileio.writeFile(upload.back.data, at: "\(directory)/back.jpg")
        try await req.fileio.writeFile(upload.front.data, at: "\(directory)/front.jpg")

        let moment = Moment(id: id, senderID: senderID, caption: (caption?.isEmpty ?? true) ? nil : caption,
                            expiresAt: Date().addingTimeInterval(API.Moments.lifetime))
        moment.insetCorner = body.layout?.insetCorner.rawValue
        moment.swapped = body.layout?.swapped
        moment.insetSize = body.layout?.insetSize.map { MomentLayout(insetSize: $0).resolvedInsetSize }
        moment.postMediaID = body.postMediaID
        let dayKey = ServerDay(timeZone: req.application.appConfig.timeZone).key(for: .now)
        try await req.db.transaction { db in
            try await moment.create(on: db)
            for recipient in recipientIDs {
                try await MomentRecipient(momentID: id, userID: recipient).create(on: db)
                // Streak history outlives the moment itself.
                let alreadyCounted = try await MomentDay.query(on: db)
                    .filter(\.$senderID == senderID).filter(\.$recipientID == recipient).filter(\.$day == dayKey)
                    .count() > 0
                if !alreadyCounted {
                    try await MomentDay(senderID: senderID, recipientID: recipient, day: dayKey).create(on: db)
                }
            }
            try await Event.record(.moment, for: recipientIDs, actor: senderID, ref: id, text: nil, on: db)
        }
        return try await Self.dto(for: id, viewerID: senderID, req: req)
    }

    @Sendable
    func feed(req: Request) async throws -> MomentsFeed {
        let viewerID = try req.auth.require(User.self).requireID()
        let now = Date()
        let postedToday = try await Self.hasPostedToday(viewerID, req: req)

        let receivedRows = try await MomentRecipient.query(on: req.db)
            .filter(\.$user.$id == viewerID)
            .with(\.$moment) { $0.with(\.$sender) }
            .all()
            .filter { $0.moment.expiresAt > now }
            .sorted { ($0.moment.createdAt ?? .distantPast) > ($1.moment.createdAt ?? .distantPast) }

        let received = try receivedRows.map { row in
            try Self.present(row.moment, viewerID: viewerID, postedToday: postedToday, recipients: nil, req: req)
        }

        let sentMoments = try await Moment.query(on: req.db)
            .filter(\.$sender.$id == viewerID)
            .filter(\.$expiresAt > now)
            .with(\.$sender)
            .with(\.$recipients) { $0.with(\.$user) }
            .sort(\.$createdAt, .descending)
            .all()
        let sent = try sentMoments.map { moment in
            try Self.present(moment, viewerID: viewerID, postedToday: true,
                             recipients: try moment.recipients.map(Self.recipientDTO), req: req)
        }
        return MomentsFeed(hasPostedToday: postedToday, received: received, sent: sent)
    }

    /// Serves `back` or `front` to the sender and unlocked recipients only.
    @Sendable
    func photo(req: Request) async throws -> Response {
        let viewerID = try req.auth.require(User.self).requireID()
        let moment = try await Self.accessibleMoment(req, viewerID: viewerID)
        if moment.$sender.id != viewerID,
           try await Self.isLocked(moment, viewerID: viewerID, postedToday: Self.hasPostedToday(viewerID, req: req), req: req) {
            throw Abort(.forbidden, reason: "Share your own moment today to see this one.")
        }
        guard let side = req.parameters.get("side"), ["back", "front"].contains(side) else { throw Abort(.notFound) }

        let response = try await req.fileio.asyncStreamFile(
            at: "\(Moment.directory(for: try moment.requireID(), in: req.application))/\(side).jpg")
        // Private and short-lived: never cache on disk.
        response.headers.replaceOrAdd(name: .cacheControl, value: "private, no-store")
        return response
    }

    @Sendable
    func markViewed(req: Request) async throws -> HTTPStatus {
        try await updateRecipient(req) { row in
            if row.viewedAt == nil { row.viewedAt = .now }
        }
    }

    /// iOS can't block screenshots, so the sender is told instead.
    @Sendable
    func markScreenshot(req: Request) async throws -> HTTPStatus {
        try await updateRecipient(req) { $0.screenshotAt = .now }
    }

    private func updateRecipient(_ req: Request, _ change: (MomentRecipient) -> Void) async throws -> HTTPStatus {
        let viewerID = try req.auth.require(User.self).requireID()
        let moment = try await Self.accessibleMoment(req, viewerID: viewerID)
        guard let row = try await MomentRecipient.query(on: req.db)
            .filter(\.$moment.$id == moment.requireID())
            .filter(\.$user.$id == viewerID)
            .first()
        else { throw Abort(.forbidden) }
        change(row)
        try await row.save(on: req.db)
        return .noContent
    }

    // MARK: Helpers

    static func friendIDs(of userID: UUID, on db: any Database) async throws -> Set<UUID> {
        let rows = try await Friendship.query(on: db)
            .filter(\.$statusRaw == Friendship.Status.accepted.rawValue)
            .group(.or) { $0.filter(\.$requester.$id == userID).filter(\.$addressee.$id == userID) }
            .all()
        return Set(rows.map { $0.$requester.id == userID ? $0.$addressee.id : $0.$requester.id })
    }

    /// Start of the current day in the server's time zone.
    static func startOfToday(_ req: Request) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = req.application.appConfig.timeZone
        return calendar.startOfDay(for: .now)
    }

    static func hasPostedToday(_ userID: UUID, req: Request) async throws -> Bool {
        try await Moment.query(on: req.db)
            .filter(\.$sender.$id == userID)
            .filter(\.$createdAt >= startOfToday(req))
            .count() > 0
    }

    /// BeReal rule: today's moments from friends stay locked until you've shared your own today.
    static func isLocked(_ moment: Moment, viewerID: UUID, postedToday: Bool, req: Request) throws -> Bool {
        guard moment.$sender.id != viewerID, !postedToday else { return false }
        return (moment.createdAt ?? .now) >= startOfToday(req)
    }

    /// The moment if it's unexpired and the viewer is its sender or a recipient; otherwise 404.
    static func accessibleMoment(_ req: Request, viewerID: UUID) async throws -> Moment {
        guard let id = req.parameters.get("momentID", as: UUID.self),
              let moment = try await Moment.find(id, on: req.db),
              moment.expiresAt > .now
        else { throw Abort(.notFound, reason: "This moment has expired.") }

        if moment.$sender.id != viewerID {
            let isRecipient = try await MomentRecipient.query(on: req.db)
                .filter(\.$moment.$id == id).filter(\.$user.$id == viewerID).count() > 0
            guard isRecipient else { throw Abort(.notFound, reason: "This moment has expired.") }
        }
        return moment
    }

    static func present(_ moment: Moment, viewerID: UUID, postedToday: Bool,
                        recipients: [MomentRecipientDTO]?, req: Request) throws -> MomentDTO {
        let id = try moment.requireID()
        let locked = try isLocked(moment, viewerID: viewerID, postedToday: postedToday, req: req)
        return MomentDTO(
            id: id,
            sender: try moment.sender.toDTO(),
            caption: moment.caption,
            createdAt: moment.createdAt ?? .now,
            expiresAt: moment.expiresAt,
            isLocked: locked,
            backPath: locked ? nil : "\(API.Path.moment(id))/back",
            frontPath: locked ? nil : "\(API.Path.moment(id))/front",
            recipients: recipients,
            layout: moment.layout,
            becomesPost: recipients == nil ? nil : moment.postMediaID != nil
        )
    }

    static func recipientDTO(_ row: MomentRecipient) throws -> MomentRecipientDTO {
        MomentRecipientDTO(user: try row.user.toDTO(), viewedAt: row.viewedAt, screenshotAt: row.screenshotAt)
    }

    static func dto(for id: UUID, viewerID: UUID, req: Request) async throws -> MomentDTO {
        guard let moment = try await Moment.query(on: req.db)
            .filter(\.$id == id)
            .with(\.$sender)
            .with(\.$recipients, { $0.with(\.$user) })
            .first()
        else { throw Abort(.notFound) }
        return try present(moment, viewerID: viewerID, postedToday: true,
                           recipients: try moment.recipients.map(recipientDTO), req: req)
    }
}
