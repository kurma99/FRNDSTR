import Fluent
import FRNDSAPI
import Vapor

/// Reactions and comments on posts.
struct SocialController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(TokenAuthenticator(), User.guardMiddleware())

        let post = protected.grouped("posts", ":postID")
        post.put("reaction", use: react)
        post.delete("reaction", use: removeReaction)
        post.get("reactions", use: reactions)
        post.get("comments", use: comments)
        post.post("comments", use: addComment)

        protected.delete("comments", ":commentID", use: deleteComment)
    }

    // MARK: Reactions

    /// Sets (or replaces) the viewer's reaction.
    @Sendable
    func react(req: Request) async throws -> ReactionSummary {
        let userID = try req.auth.require(User.self).requireID()
        let postID = try await existingPostID(req)
        let emoji = try req.content.decode(ReactionRequest.self).emoji
        guard try await InstanceSetting.reactionPalette(on: req.db).contains(emoji) else {
            throw Abort(.badRequest, reason: "Unsupported reaction.")
        }

        let existing = try await Reaction.query(on: req.db)
            .filter(\.$post.$id == postID).filter(\.$user.$id == userID).first()
        if let existing {
            existing.emoji = emoji
            try await existing.save(on: req.db)
        } else {
            try await Reaction(postID: postID, userID: userID, emoji: emoji).create(on: req.db)
        }
        if existing?.emoji != emoji, let author = try await Post.find(postID, on: req.db)?.$author.id {
            try await Event.record(.reaction, for: [author], actor: userID, ref: postID, text: emoji, on: req.db)
        }
        return try await summary(postID: postID, viewerID: userID, on: req.db)
    }

    @Sendable
    func removeReaction(req: Request) async throws -> ReactionSummary {
        let userID = try req.auth.require(User.self).requireID()
        let postID = try await existingPostID(req)
        try await Reaction.query(on: req.db)
            .filter(\.$post.$id == postID).filter(\.$user.$id == userID)
            .delete()
        return try await summary(postID: postID, viewerID: userID, on: req.db)
    }

    /// Who reacted with what, newest first.
    @Sendable
    func reactions(req: Request) async throws -> [ReactionDTO] {
        let postID = try await existingPostID(req)
        return try await Reaction.query(on: req.db)
            .filter(\.$post.$id == postID)
            .with(\.$user)
            .sort(\.$createdAt, .descending)
            .all()
            .map { ReactionDTO(user: try $0.user.toDTO(), emoji: $0.emoji) }
    }

    private func summary(postID: UUID, viewerID: UUID, on db: any Database) async throws -> ReactionSummary {
        let all = try await Reaction.query(on: db).filter(\.$post.$id == postID).all()
        return ReactionSummary(reactions: PostPresenter.summarize(all),
                               myReaction: all.first { $0.$user.id == viewerID }?.emoji)
    }

    // MARK: Comments

    /// All comments, oldest first (conversation order).
    @Sendable
    func comments(req: Request) async throws -> [CommentDTO] {
        let postID = try await existingPostID(req)
        return try await Comment.query(on: req.db)
            .filter(\.$post.$id == postID)
            .with(\.$author)
            .sort(\.$createdAt, .ascending)
            .limit(1000)
            .all()
            .map { try $0.toDTO() }
    }

    @Sendable
    func addComment(req: Request) async throws -> CommentDTO {
        let user = try req.auth.require(User.self)
        let postID = try await existingPostID(req)
        let text = try req.content.decode(CreateCommentRequest.self).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...API.Limits.maxCommentLength).contains(text.count) else {
            throw Abort(.badRequest, reason: "Comments need 1–\(API.Limits.maxCommentLength) characters.")
        }

        let comment = Comment(postID: postID, authorID: try user.requireID(), text: text)
        try await comment.create(on: req.db)
        if let author = try await Post.find(postID, on: req.db)?.$author.id {
            try await Event.record(.comment, for: [author], actor: try user.requireID(), ref: postID, text: text, on: req.db)
        }
        comment.$author.value = user
        return try comment.toDTO()
    }

    /// The comment's author or the post's author may delete a comment.
    @Sendable
    func deleteComment(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(User.self).requireID()
        guard let id = req.parameters.get("commentID", as: UUID.self),
              let comment = try await Comment.query(on: req.db).filter(\.$id == id).with(\.$post).first()
        else { throw Abort(.notFound) }

        guard comment.$author.id == userID || comment.post.$author.id == userID else {
            throw Abort(.forbidden, reason: "You can't delete this comment.")
        }
        try await comment.delete(on: req.db)
        return .noContent
    }

    private func existingPostID(_ req: Request) async throws -> UUID {
        guard let id = req.parameters.get("postID", as: UUID.self),
              try await Post.find(id, on: req.db) != nil
        else { throw Abort(.notFound, reason: "This post doesn't exist anymore.") }
        return id
    }
}
