import Fluent
import FriendsterAPI
import Vapor

struct AuthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped("auth")
        auth.post("register", use: register)
        auth.post("login", use: login)

        let protected = routes.grouped(TokenAuthenticator(), User.guardMiddleware())
        protected.post("auth", "logout", use: logout)
        protected.get("me", use: me)
    }

    @Sendable
    func register(req: Request) async throws -> AuthResponse {
        let body = try req.content.decode(RegisterRequest.self)
        let username = body.username.trimmingCharacters(in: .whitespaces).lowercased()
        let displayName = body.displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard username.wholeMatch(of: /[a-z0-9._]{3,30}/) != nil else {
            throw Abort(.badRequest, reason: "Username must be 3–30 characters: letters, numbers, dots or underscores.")
        }
        guard (1...50).contains(displayName.count) else {
            throw Abort(.badRequest, reason: "Please enter a name (max 50 characters).")
        }
        guard body.password.count >= 8 else {
            throw Abort(.badRequest, reason: "Password must be at least 8 characters.")
        }

        let passwordHash = try await req.password.async.hash(body.password)
        let code = Invite.normalize(body.inviteCode)

        return try await req.db.transaction { db in
            guard let invite = try await Invite.query(on: db)
                .filter(\.$code == code)
                .filter(\.$usedBy.$id == nil)
                .first()
            else {
                throw Abort(.forbidden, reason: "This invite code is invalid or was already used.")
            }
            guard try await User.query(on: db).filter(\.$username == username).count() == 0 else {
                throw Abort(.conflict, reason: "This username is already taken.")
            }

            let user = User(username: username, displayName: displayName, passwordHash: passwordHash)
            // The first account on a fresh server runs it.
            user.isAdmin = try await User.query(on: db).filter(\.$isAdminValue == true).count() == 0
            try await user.save(on: db)

            invite.$usedBy.id = try user.requireID()
            invite.usedAt = .now
            try await invite.save(on: db)

            let (token, raw) = try UserToken.issue(for: user)
            try await token.save(on: db)
            return AuthResponse(token: raw, user: try user.toDTO())
        }
    }

    @Sendable
    func login(req: Request) async throws -> AuthResponse {
        let body = try req.content.decode(LoginRequest.self)
        let username = body.username.trimmingCharacters(in: .whitespaces).lowercased()

        guard let user = try await User.query(on: req.db).filter(\.$username == username).first(),
              try await req.password.async.verify(body.password, created: user.passwordHash)
        else {
            throw Abort(.unauthorized, reason: "Wrong username or password.")
        }

        let (token, raw) = try UserToken.issue(for: user)
        try await token.save(on: req.db)
        return AuthResponse(token: raw, user: try user.toDTO())
    }

    @Sendable
    func logout(req: Request) async throws -> HTTPStatus {
        if let token = req.auth.get(UserToken.self) {
            try await token.delete(on: req.db)
        }
        return .noContent
    }

    @Sendable
    func me(req: Request) async throws -> UserDTO {
        try req.auth.require(User.self).toDTO()
    }
}
