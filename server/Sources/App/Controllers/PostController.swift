import Fluent
import FluentSQL
import FriendsterAPI
import Vapor

struct PostController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let posts = routes.grouped("posts").grouped(TokenAuthenticator(), User.guardMiddleware())
        posts.get(use: feed)
        posts.post(use: create)
        posts.get(":postID", use: show)
        posts.patch(":postID", use: update)
        posts.delete(":postID", use: delete)
    }

    /// Everyone on the instance sees all posts, newest first. `?author=<uuid>` limits to one user.
    /// The cursor is the ID of the last post of the previous page. Comparing against that post's
    /// stored `created_at` inside SQL keeps pages exact: a date sent as text and parsed back can be
    /// off by a few ulps (it was on Linux), which repeated the last post on the next page.
    @Sendable
    func feed(req: Request) async throws -> FeedPage {
        let viewerID = try req.auth.require(User.self).requireID()
        let limit = min(max(req.query[Int.self, at: "limit"] ?? 10, 1), 30)

        var query = Post.query(on: req.db)
            .with(\.$author)
            .with(\.$media)
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
            .limit(limit + 1)

        // Optional filter for profile pages.
        if let author = req.query[UUID.self, at: "author"] {
            query = query.filter(\.$author.$id == author)
        }
        if let cursor = req.query[String.self, at: "cursor"] {
            guard let lastID = UUID(uuidString: cursor) else { throw Abort(.badRequest, reason: "Invalid cursor.") }
            // Same order as the sort: older, or same time and smaller ID. A deleted cursor post ends the feed.
            let lastDate: SQLQueryString = "(SELECT \(ident: "created_at") FROM \(ident: Post.schema) WHERE \(ident: "id") = \(bind: lastID))"
            let createdAt: SQLQueryString = "\(ident: Post.schema).\(ident: "created_at")"
            let id: SQLQueryString = "\(ident: Post.schema).\(ident: "id")"
            query = query.filter(.sql(embed: "(\(createdAt) < \(lastDate) OR (\(createdAt) = \(lastDate) AND \(id) < \(bind: lastID)))"))
        }

        let posts = try await query.all()
        let page = Array(posts.prefix(limit))
        let nextCursor = posts.count > limit ? page.last?.id?.uuidString : nil

        return FeedPage(posts: try await PostPresenter.dtos(for: page, viewerID: viewerID, on: req.db),
                        nextCursor: nextCursor)
    }

    @Sendable
    func show(req: Request) async throws -> PostDTO {
        let viewerID = try req.auth.require(User.self).requireID()
        let post = try await PostPresenter.load(req.parameters.get("postID", as: UUID.self), on: req.db)
        return try await PostPresenter.dto(for: post, viewerID: viewerID, on: req.db)
    }

    /// Attaches previously uploaded, unattached media owned by the caller to a new post.
    @Sendable
    func create(req: Request) async throws -> PostDTO {
        let userID = try req.auth.require(User.self).requireID()
        let body = try req.content.decode(CreatePostRequest.self)

        let caption = body.caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (caption?.count ?? 0) <= API.Limits.maxCaptionLength else {
            throw Abort(.badRequest, reason: "Caption is too long.")
        }
        guard (1...API.Limits.maxMediaPerPost).contains(body.mediaIDs.count),
              Set(body.mediaIDs).count == body.mediaIDs.count
        else {
            throw Abort(.badRequest, reason: "A post needs 1–\(API.Limits.maxMediaPerPost) photos or videos.")
        }
        if let location = body.location {
            guard (-90...90).contains(location.latitude), (-180...180).contains(location.longitude),
                  (location.placeName?.count ?? 0) <= 120
            else { throw Abort(.badRequest, reason: "Invalid location.") }
        }

        let postID = try await req.db.transaction { db -> UUID in
            let media = try await PostMedia.query(on: db)
                .filter(\.$id ~~ body.mediaIDs)
                .filter(\.$owner.$id == userID)
                .filter(\.$post.$id == nil)
                .all()
            guard media.count == body.mediaIDs.count else {
                throw Abort(.badRequest, reason: "Some media could not be found. Please upload again.")
            }

            let post = Post(authorID: userID, caption: (caption?.isEmpty ?? true) ? nil : caption)
            post.latitude = body.location?.latitude
            post.longitude = body.location?.longitude
            post.placeName = body.location?.placeName
            post.takenAt = body.takenAt
            try await post.save(on: db)
            let postID = try post.requireID()

            for item in media {
                item.$post.id = postID
                item.position = body.mediaIDs.firstIndex(of: try item.requireID()) ?? 0
                try await item.save(on: db)
            }
            try await Event.record(.post, for: try await Event.everyone(except: userID, on: db),
                                   actor: userID, ref: postID, text: post.caption, on: db)
            return postID
        }

        let post = try await PostPresenter.load(postID, on: req.db)
        return try await PostPresenter.dto(for: post, viewerID: userID, on: req.db)
    }

    /// Authors can change the caption of their own posts. No notification is sent.
    @Sendable
    func update(req: Request) async throws -> PostDTO {
        let userID = try req.auth.require(User.self).requireID()
        let post = try await PostPresenter.load(req.parameters.get("postID", as: UUID.self), on: req.db)
        guard post.$author.id == userID else {
            throw Abort(.forbidden, reason: "You can only edit your own posts.")
        }
        let body = try req.content.decode(UpdatePostRequest.self)
        let caption = body.caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (caption?.count ?? 0) <= API.Limits.maxCaptionLength else {
            throw Abort(.badRequest, reason: "Caption is too long.")
        }
        post.caption = (caption?.isEmpty ?? true) ? nil : caption
        try await post.save(on: req.db)
        return try await PostPresenter.dto(for: post, viewerID: userID, on: req.db)
    }

    /// Authors can delete their own posts; media files are removed from disk.
    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(User.self).requireID()
        let post = try await PostPresenter.load(req.parameters.get("postID", as: UUID.self), on: req.db)
        guard post.$author.id == userID else {
            throw Abort(.forbidden, reason: "You can only delete your own posts.")
        }

        let mediaIDs = try post.media.map { try $0.requireID() }
        let postID = try post.requireID()
        try await req.db.transaction { db in
            try await Reaction.query(on: db).filter(\.$post.$id == postID).delete()
            try await Comment.query(on: db).filter(\.$post.$id == postID).delete()
            try await PostMedia.query(on: db).filter(\.$post.$id == postID).delete()
            try await post.delete(on: db)
        }

        let mediaDirectory = req.application.appConfig.mediaDirectory
        for id in mediaIDs {
            try? FileManager.default.removeItem(atPath: "\(mediaDirectory)/\(id.uuidString)")
        }
        return .noContent
    }
}
