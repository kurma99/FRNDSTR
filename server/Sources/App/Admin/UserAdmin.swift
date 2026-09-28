import Fluent
import Vapor

/// Admin actions on accounts.
enum UserAdmin {
    /// Logs the user out everywhere (all app sessions).
    static func kick(_ userID: UUID, on db: any Database) async throws {
        try await UserToken.query(on: db).filter(\.$user.$id == userID).delete()
    }

    /// Sets a new random password, logs the user out everywhere and returns the password to hand over.
    static func resetPassword(_ user: User, req: Request) async throws -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        var generator = SystemRandomNumberGenerator()
        let password = String((0..<12).map { _ in alphabet.randomElement(using: &generator)! })
        user.passwordHash = try await req.password.async.hash(password)
        try await user.save(on: req.db)
        try await kick(try user.requireID(), on: req.db)
        return password
    }

    /// Removes the account and everything it owns: posts and their media files, uploads, moments,
    /// highlights, avatar, comments, reactions, friendships, sessions and notifications.
    static func delete(_ user: User, app: Application) async throws {
        let userID = try user.requireID()
        let db = app.db
        let mediaDir = app.appConfig.mediaDirectory

        let mediaIDs = try await PostMedia.query(on: db).filter(\.$owner.$id == userID).all().compactMap(\.id)
        let momentIDs = try await Moment.query(on: db).filter(\.$sender.$id == userID).all().compactMap(\.id)
        let postIDs = try await Post.query(on: db).filter(\.$author.$id == userID).all().compactMap(\.id)
        let highlightIDs = try await Highlight.query(on: db).filter(\.$owner.$id == userID).all().compactMap(\.id)
        let highlightItemIDs = highlightIDs.isEmpty ? [] :
            try await HighlightItem.query(on: db).filter(\.$highlight.$id ~~ highlightIDs).all().compactMap(\.id)

        try await db.transaction { db in
            // Explicit deletes (not only FK cascades) so this works regardless of SQLite FK settings.
            if !postIDs.isEmpty {
                try await Reaction.query(on: db).filter(\.$post.$id ~~ postIDs).delete()
                try await Comment.query(on: db).filter(\.$post.$id ~~ postIDs).delete()
            }
            try await Reaction.query(on: db).filter(\.$user.$id == userID).delete()
            try await Comment.query(on: db).filter(\.$author.$id == userID).delete()
            try await PostMedia.query(on: db).filter(\.$owner.$id == userID).delete()
            try await Post.query(on: db).filter(\.$author.$id == userID).delete()
            if !momentIDs.isEmpty {
                try await MomentRecipient.query(on: db).filter(\.$moment.$id ~~ momentIDs).delete()
            }
            try await MomentRecipient.query(on: db).filter(\.$user.$id == userID).delete()
            try await Moment.query(on: db).filter(\.$sender.$id == userID).delete()
            try await MomentDay.query(on: db)
                .group(.or) { $0.filter(\.$senderID == userID).filter(\.$recipientID == userID) }
                .delete()
            if !highlightIDs.isEmpty {
                try await HighlightItem.query(on: db).filter(\.$highlight.$id ~~ highlightIDs).delete()
            }
            try await Highlight.query(on: db).filter(\.$owner.$id == userID).delete()
            try await Friendship.query(on: db)
                .group(.or) { $0.filter(\.$requester.$id == userID).filter(\.$addressee.$id == userID) }
                .delete()
            try await Event.query(on: db).filter(\.$user.$id == userID).delete()
            try await Event.query(on: db).filter(\.$actor.$id == userID).delete()
            try await UserToken.query(on: db).filter(\.$user.$id == userID).delete()
            try await Invite.query(on: db).filter(\.$usedBy.$id == userID).set(\.$usedBy.$id, to: nil).update()
            try await user.delete(on: db)
        }

        for id in mediaIDs { try? FileManager.default.removeItem(atPath: "\(mediaDir)/\(id.uuidString)") }
        for id in momentIDs { try? FileManager.default.removeItem(atPath: Moment.directory(for: id, in: app)) }
        for id in highlightItemIDs { try? FileManager.default.removeItem(atPath: HighlightItem.directory(for: id, in: app)) }
        try? FileManager.default.removeItem(atPath: "\(mediaDir)/avatars/\(userID.uuidString)")
    }

    /// Deletes uploads that never became a post and are older than a day.
    @discardableResult
    static func removeStaleUploads(app: Application, olderThan age: TimeInterval = 24 * 3600) async throws -> Int {
        let stale = try await PostMedia.query(on: app.db)
            .filter(\.$post.$id == nil)
            .filter(\.$createdAt < Date().addingTimeInterval(-age))
            .all()
        // Keep composites that a pending moment will still publish.
        let reserved = Set(try await Moment.query(on: app.db).all().compactMap(\.postMediaID))
        var removed = 0
        for item in stale {
            guard let id = item.id, !reserved.contains(id) else { continue }
            try await item.delete(on: app.db)
            try? FileManager.default.removeItem(atPath: "\(app.appConfig.mediaDirectory)/\(id.uuidString)")
            removed += 1
        }
        return removed
    }
}
