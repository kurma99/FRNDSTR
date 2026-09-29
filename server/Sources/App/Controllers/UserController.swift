import Fluent
import FRNDSAPI
import Vapor

/// Family member list, profiles, profile editing and avatars.
struct UserController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(TokenAuthenticator(), User.guardMiddleware())
        protected.get("users", use: list)
        protected.get("users", ":userID", use: profile)
        protected.patch("me", use: updateProfile)
        protected.on(.PUT, "me", "avatar", body: .collect(maxSize: ByteCount(value: API.Limits.maxAvatarBytes)), use: uploadAvatar)
        protected.delete("me", "avatar", use: deleteAvatar)
        protected.get("takeout", use: takeout)

        // Avatars are loaded like other media, so the query token is allowed.
        routes.grouped(TokenAuthenticator(allowQueryToken: true), User.guardMiddleware())
            .get("users", ":userID", "avatar", ":file", use: avatar)
    }

    @Sendable
    func list(req: Request) async throws -> [UserDTO] {
        try await User.query(on: req.db).sort(\.$displayName).all().map { try $0.toDTO() }
    }

    @Sendable
    func profile(req: Request) async throws -> ProfileDTO {
        let viewerID = try req.auth.require(User.self).requireID()
        guard let id = req.parameters.get("userID", as: UUID.self),
              let user = try await User.find(id, on: req.db)
        else { throw Abort(.notFound) }

        return ProfileDTO(
            user: try user.toDTO(),
            postCount: try await Post.query(on: req.db).filter(\.$author.$id == id).count(),
            friendCount: try await Friendship.friendCount(of: id, on: req.db),
            friendship: try await Friendship.status(viewer: viewerID, other: id, on: req.db)
        )
    }

    @Sendable
    func updateProfile(req: Request) async throws -> UserDTO {
        let user = try req.auth.require(User.self)
        let name = try req.content.decode(UpdateProfileRequest.self).displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...50).contains(name.count) else {
            throw Abort(.badRequest, reason: "Please enter a name (max 50 characters).")
        }
        user.displayName = name
        try await user.save(on: req.db)
        return try user.toDTO()
    }

    /// Raw JPEG/PNG body. The app sends a square, downscaled image.
    @Sendable
    func uploadAvatar(req: Request) async throws -> UserDTO {
        let user = try req.auth.require(User.self)
        let fileExtension: String
        switch req.headers.contentType?.subType {
        case "jpeg", "jpg": fileExtension = "jpg"
        case "png": fileExtension = "png"
        default: throw Abort(.unsupportedMediaType, reason: "Profile photos must be JPEG or PNG.")
        }
        guard let body = req.body.data, body.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "Empty upload.")
        }

        let directory = avatarDirectory(for: try user.requireID(), req: req)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let fileName = "avatar-\(Int(Date().timeIntervalSince1970 * 1000)).\(fileExtension)"
        try await req.fileio.writeFile(body, at: "\(directory)/\(fileName)")

        if let old = user.avatarFile { try? FileManager.default.removeItem(atPath: "\(directory)/\(old)") }
        user.avatarFile = fileName
        try await user.save(on: req.db)
        return try user.toDTO()
    }

    @Sendable
    func deleteAvatar(req: Request) async throws -> UserDTO {
        let user = try req.auth.require(User.self)
        if let old = user.avatarFile {
            try? FileManager.default.removeItem(atPath: "\(avatarDirectory(for: try user.requireID(), req: req))/\(old)")
        }
        user.avatarFile = nil
        try await user.save(on: req.db)
        return try user.toDTO()
    }

    @Sendable
    func avatar(req: Request) async throws -> Response {
        guard let id = req.parameters.get("userID", as: UUID.self),
              let user = try await User.find(id, on: req.db),
              let file = user.avatarFile,
              req.parameters.get("file") == file   // only the current file; also prevents path traversal
        else { throw Abort(.notFound) }

        let response = try await req.fileio.asyncStreamFile(at: "\(avatarDirectory(for: id, req: req))/\(file)")
        response.headers.replaceOrAdd(name: .cacheControl, value: "private, max-age=31536000, immutable")
        return response
    }

    /// Zip of the caller's posts (media + posts.json with comments and reactions). Deleted after sending.
    @Sendable
    func takeout(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let zip = try await Takeout.build(for: user, app: req.application)
        let folder = (zip as NSString).deletingLastPathComponent
        let response = try await req.fileio.asyncStreamFile(at: zip, mediaType: .zip) { _ in
            try? FileManager.default.removeItem(atPath: folder)
        }
        response.headers.contentDisposition = .init(.attachment, filename: (zip as NSString).lastPathComponent)
        return response
    }

    private func avatarDirectory(for userID: UUID, req: Request) -> String {
        "\(req.application.appConfig.mediaDirectory)/avatars/\(userID.uuidString)"
    }
}
