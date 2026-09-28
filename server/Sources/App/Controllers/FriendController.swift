import Fluent
import FriendsterAPI
import Vapor

/// Friend requests. Friends are who you'll share Moments with (M4); the feed stays family-wide.
struct FriendController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let friends = routes.grouped("friends").grouped(TokenAuthenticator(), User.guardMiddleware())
        friends.get(use: overview)
        friends.post(":userID", use: request)
        friends.delete(":userID", use: remove)
    }

    @Sendable
    func overview(req: Request) async throws -> FriendsOverview {
        let viewerID = try req.auth.require(User.self).requireID()
        let rows = try await Friendship.query(on: req.db)
            .group(.or) { $0.filter(\.$requester.$id == viewerID).filter(\.$addressee.$id == viewerID) }
            .with(\.$requester)
            .with(\.$addressee)
            .sort(\.$createdAt, .descending)
            .all()

        var friends: [UserDTO] = [], incoming: [UserDTO] = [], outgoing: [UserDTO] = []
        for row in rows {
            let viewerIsRequester = row.$requester.id == viewerID
            let other = try (viewerIsRequester ? row.addressee : row.requester).toDTO()
            switch row.status {
            case .accepted: friends.append(other)
            case .pending: viewerIsRequester ? outgoing.append(other) : incoming.append(other)
            }
        }
        friends.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return FriendsOverview(friends: friends, incoming: incoming, outgoing: outgoing)
    }

    /// Sends a request, or accepts the other person's pending request. Returns the new status.
    @Sendable
    func request(req: Request) async throws -> ProfileDTO {
        let viewerID = try req.auth.require(User.self).requireID()
        let (otherID, other) = try await target(req, viewerID: viewerID)

        if let row = try await Friendship.between(viewerID, otherID, on: req.db) {
            if row.status == .pending, row.$addressee.id == viewerID {
                row.status = .accepted
                try await row.save(on: req.db)
                try await Event.record(.friendAccepted, for: [otherID], actor: viewerID, ref: nil, text: nil, on: req.db)
            }
            // Already friends or already requested: idempotent.
        } else {
            try await Friendship(requesterID: viewerID, addresseeID: otherID).create(on: req.db)
            try await Event.record(.friendRequest, for: [otherID], actor: viewerID, ref: nil, text: nil, on: req.db)
        }
        return try await profile(of: other, viewerID: viewerID, on: req.db)
    }

    /// Cancels a request, declines one, or unfriends.
    @Sendable
    func remove(req: Request) async throws -> ProfileDTO {
        let viewerID = try req.auth.require(User.self).requireID()
        let (otherID, other) = try await target(req, viewerID: viewerID)
        try await Friendship.between(viewerID, otherID, on: req.db)?.delete(on: req.db)
        return try await profile(of: other, viewerID: viewerID, on: req.db)
    }

    private func target(_ req: Request, viewerID: UUID) async throws -> (UUID, User) {
        guard let id = req.parameters.get("userID", as: UUID.self),
              let user = try await User.find(id, on: req.db)
        else { throw Abort(.notFound) }
        guard id != viewerID else { throw Abort(.badRequest, reason: "You can't befriend yourself.") }
        return (id, user)
    }

    private func profile(of user: User, viewerID: UUID, on db: any Database) async throws -> ProfileDTO {
        let id = try user.requireID()
        return ProfileDTO(
            user: try user.toDTO(),
            postCount: try await Post.query(on: db).filter(\.$author.$id == id).count(),
            friendCount: try await Friendship.friendCount(of: id, on: db),
            friendship: try await Friendship.status(viewer: viewerID, other: id, on: db)
        )
    }
}
