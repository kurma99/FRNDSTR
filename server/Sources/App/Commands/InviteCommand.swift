import Fluent
import Vapor

/// `docker compose exec frndstr ./App invite [--count 3]`
struct InviteCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "count", short: "n", help: "Number of invite codes to create (default 1).")
        var count: Int?

        init() {}
    }

    var help: String { "Creates single-use invite codes for new family members." }

    func run(using context: CommandContext, signature: Signature) async throws {
        let db = context.application.db
        for _ in 0..<max(signature.count ?? 1, 1) {
            let invite = Invite(code: Invite.generateCode())
            try await invite.create(on: db)
            context.console.print("Invite code: \(invite.displayCode)")
        }
    }
}

/// `docker compose exec frndstr ./App admin <username> [--revoke]`
struct AdminCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Argument(name: "username", help: "The account to change.")
        var username: String

        @Flag(name: "revoke", help: "Remove admin rights instead of granting them.")
        var revoke: Bool

        init() {}
    }

    var help: String { "Grants (or revokes) admin rights, e.g. editing the reaction emoji." }

    func run(using context: CommandContext, signature: Signature) async throws {
        let db = context.application.db
        guard let user = try await User.query(on: db).filter(\.$username == signature.username.lowercased()).first() else {
            context.console.error("No user named \(signature.username).")
            return
        }
        user.isAdmin = !signature.revoke
        try await user.save(on: db)
        context.console.print("\(user.username) is \(user.isAdmin ? "now an admin" : "no longer an admin").")
    }
}

enum Bootstrap {
    /// A fresh server has no accounts: point the admin to the web setup page.
    static func announceSetup(on app: Application) async throws {
        guard try await User.query(on: app.db).count() == 0 else { return }
        app.logger.notice("No admin account yet. Open this server's address (e.g. http://<server>:8080/) in a browser to set it up.")
    }
}
