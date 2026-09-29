import Fluent
import FrndstrAPI
import Leaf
import Vapor

/// The admin web dashboard (server-rendered, no JavaScript):
/// first-run setup, admin login, storage stats, users, invites and instance settings.
struct WebController: RouteCollection {
    let sessions: SessionsMiddleware

    func boot(routes: any RoutesBuilder) throws {
        let web = routes.grouped(sessions)
        web.get(use: root)
        web.get("setup", use: setupPage)
        web.post("setup", use: setup)
        web.get("login", use: loginPage)
        web.post("login", use: login)

        let admin = web.grouped("admin").grouped(WebAdminMiddleware())
        admin.get(use: dashboard)
        admin.post("logout", use: logout)
        admin.post("invites", use: createInvites)
        admin.post("invites", ":inviteID", "revoke", use: revokeInvite)
        admin.post("users", ":userID", "kick", use: kickUser)
        admin.post("users", ":userID", "password", use: resetPassword)
        admin.post("users", ":userID", "admin", use: toggleAdmin)
        admin.post("users", ":userID", "delete", use: deleteUser)
        admin.post("settings", "reactions", use: saveReactions)
        admin.post("settings", "moment-window", use: saveMomentWindow)
        admin.post("maintenance", "cleanup", use: cleanUp)
    }

    // MARK: Entry, setup, login

    @Sendable
    func root(req: Request) async throws -> Response {
        if try await User.query(on: req.db).count() == 0 { return req.redirect(to: "/setup") }
        return req.redirect(to: WebSession.userID(req) == nil ? "/login" : "/admin")
    }

    struct FormContext: Encodable {
        var title: String
        var instanceName: String
        var csrf: String
        var error: String?
        var username: String?
        var displayName: String?
    }

    /// Only available while the server has no accounts at all.
    @Sendable
    func setupPage(req: Request) async throws -> Response {
        guard try await User.query(on: req.db).count() == 0 else { return req.redirect(to: "/login") }
        return try await render(req, "setup", FormContext(title: "Set up", instanceName: instanceName(req), csrf: WebSession.csrf(req)))
    }

    struct SetupForm: Content { var displayName: String; var username: String; var password: String }

    @Sendable
    func setup(req: Request) async throws -> Response {
        try WebSession.verifyCSRF(req)
        guard try await User.query(on: req.db).count() == 0 else { return req.redirect(to: "/login") }
        let form = try req.content.decode(SetupForm.self)
        let username = form.username.trimmingCharacters(in: .whitespaces).lowercased()
        let displayName = form.displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        var error: String?
        if username.wholeMatch(of: /[a-z0-9._]{3,30}/) == nil {
            error = "Username must be 3–30 characters: letters, numbers, dots or underscores."
        } else if !(1...50).contains(displayName.count) {
            error = "Please enter a name."
        } else if form.password.count < 8 {
            error = "Password must be at least 8 characters."
        }
        if let error {
            return try await render(req, "setup", FormContext(title: "Set up", instanceName: instanceName(req), csrf: WebSession.csrf(req),
                                                               error: error, username: username, displayName: displayName))
        }

        let admin = User(username: username, displayName: displayName, passwordHash: try await req.password.async.hash(form.password))
        admin.isAdmin = true
        try await admin.create(on: req.db)
        WebSession.logIn(try admin.requireID(), req: req)
        WebSession.flash("Welcome! Create invite codes below so your family can join from the app.", req: req)
        return req.redirect(to: "/admin")
    }

    @Sendable
    func loginPage(req: Request) async throws -> Response {
        if try await User.query(on: req.db).count() == 0 { return req.redirect(to: "/setup") }
        return try await render(req, "login", FormContext(title: "Log in", instanceName: instanceName(req), csrf: WebSession.csrf(req)))
    }

    struct LoginForm: Content { var username: String; var password: String }

    @Sendable
    func login(req: Request) async throws -> Response {
        try WebSession.verifyCSRF(req)
        let form = try req.content.decode(LoginForm.self)
        let username = form.username.trimmingCharacters(in: .whitespaces).lowercased()
        guard let user = try await User.query(on: req.db).filter(\.$username == username).first(),
              try await req.password.async.verify(form.password, created: user.passwordHash)
        else {
            return try await render(req, "login", FormContext(title: "Log in", instanceName: instanceName(req), csrf: WebSession.csrf(req),
                                                               error: "Wrong username or password.", username: username))
        }
        guard user.isAdmin else {
            return try await render(req, "login", FormContext(title: "Log in", instanceName: instanceName(req), csrf: WebSession.csrf(req),
                                                               error: "The dashboard is for admins only. Use the Frndstr app.", username: username))
        }
        WebSession.logIn(try user.requireID(), req: req)
        return req.redirect(to: "/admin")
    }

    @Sendable
    func logout(req: Request) async throws -> Response {
        try WebSession.verifyCSRF(req)
        req.session.destroy()
        return req.redirect(to: "/login")
    }

    // MARK: Dashboard

    struct InviteRow: Encodable {
        var id: String
        var code: String
        var created: String
        var usedBy: String?
        var usedAt: String?
    }

    struct DashboardContext: Encodable {
        var title: String
        var instanceName: String
        var csrf: String
        var flash: String?
        var me: String
        var myID: String
        var stats: StorageStats
        var openInvites: [InviteRow]
        var usedInvites: [InviteRow]
        var hasOpenInvites: Bool
        var hasUsedInvites: Bool
        var reactions: String
        var windowStart: Int
        var windowEnd: Int
        var startHours: [Int]
        var endHours: [Int]
        var timeZone: String
        var serverAddress: String
    }

    @Sendable
    func dashboard(req: Request) async throws -> View {
        let me = try req.auth.require(User.self)
        let format = Date.FormatStyle(date: .abbreviated, time: .shortened)
        let invites = try await Invite.query(on: req.db).with(\.$usedBy).sort(\.$createdAt, .descending).all()
        let rows = try invites.map { invite in
            InviteRow(id: try invite.requireID().uuidString, code: invite.displayCode,
                      created: invite.createdAt?.formatted(format) ?? "–",
                      usedBy: invite.usedBy.map { "\($0.displayName) (@\($0.username))" },
                      usedAt: invite.usedAt?.formatted(format))
        }
        let window = try await MomentTime.window(on: req.db)
        let host = req.headers.first(name: .host) ?? "this-server:8080"

        let context = DashboardContext(
            title: "Dashboard", instanceName: instanceName(req), csrf: WebSession.csrf(req),
            flash: WebSession.takeFlash(req), me: me.displayName, myID: try me.requireID().uuidString,
            stats: try await StorageStats.collect(on: req.application),
            openInvites: rows.filter { $0.usedBy == nil }, usedInvites: rows.filter { $0.usedBy != nil },
            hasOpenInvites: rows.contains { $0.usedBy == nil }, hasUsedInvites: rows.contains { $0.usedBy != nil },
            reactions: try await InstanceSetting.reactionPalette(on: req.db).joined(separator: " "),
            windowStart: window.startHour, windowEnd: window.endHour,
            startHours: Array(0...23), endHours: Array(1...24),
            timeZone: req.application.appConfig.timeZone.identifier,
            serverAddress: "http://\(host)"
        )
        return try await req.view.render("dashboard", context)
    }

    // MARK: Invites

    struct InviteForm: Content { var count: Int? }

    @Sendable
    func createInvites(req: Request) async throws -> Response {
        try WebSession.verifyCSRF(req)
        let count = min(max((try? req.content.decode(InviteForm.self))?.count ?? 1, 1), 20)
        var codes: [String] = []
        for _ in 0..<count {
            let invite = Invite(code: Invite.generateCode())
            try await invite.create(on: req.db)
            codes.append(invite.displayCode)
        }
        WebSession.flash("New invite code\(count == 1 ? "" : "s"): \(codes.joined(separator: ", "))", req: req)
        return req.redirect(to: "/admin#invites")
    }

    @Sendable
    func revokeInvite(req: Request) async throws -> Response {
        try WebSession.verifyCSRF(req)
        if let id = req.parameters.get("inviteID", as: UUID.self),
           let invite = try await Invite.find(id, on: req.db), invite.$usedBy.id == nil {
            try await invite.delete(on: req.db)
            WebSession.flash("Invite \(invite.displayCode) revoked.", req: req)
        }
        return req.redirect(to: "/admin#invites")
    }

    // MARK: Users

    @Sendable
    func kickUser(req: Request) async throws -> Response {
        try WebSession.verifyCSRF(req)
        let user = try await targetUser(req)
        try await UserAdmin.kick(try user.requireID(), on: req.db)
        WebSession.flash("\(user.displayName) was logged out on all devices.", req: req)
        return req.redirect(to: "/admin#users")
    }

    @Sendable
    func resetPassword(req: Request) async throws -> Response {
        try WebSession.verifyCSRF(req)
        let user = try await targetUser(req)
        let password = try await UserAdmin.resetPassword(user, req: req)
        WebSession.flash("New password for \(user.displayName) (@\(user.username)): \(password) — they were logged out and can sign in with it now.", req: req)
        return req.redirect(to: "/admin#users")
    }

    @Sendable
    func toggleAdmin(req: Request) async throws -> Response {
        try WebSession.verifyCSRF(req)
        let user = try await targetUser(req)
        if user.isAdmin {
            let admins = try await User.query(on: req.db).filter(\.$isAdminValue == true).count()
            guard admins > 1 else {
                WebSession.flash("There must always be at least one admin.", req: req)
                return req.redirect(to: "/admin#users")
            }
        }
        user.isAdmin.toggle()
        try await user.save(on: req.db)
        WebSession.flash("\(user.displayName) is \(user.isAdmin ? "now an admin" : "no longer an admin").", req: req)
        return req.redirect(to: try req.auth.require(User.self).isAdmin ? "/admin#users" : "/login")
    }

    struct DeleteForm: Content { var confirm: String }

    @Sendable
    func deleteUser(req: Request) async throws -> Response {
        try WebSession.verifyCSRF(req)
        let user = try await targetUser(req)
        guard user.id != req.auth.get(User.self)?.id else {
            WebSession.flash("You can't delete your own account here.", req: req)
            return req.redirect(to: "/admin#users")
        }
        guard (try? req.content.decode(DeleteForm.self))?.confirm.lowercased() == user.username else {
            WebSession.flash("Type the username \(user.username) to confirm deleting the account.", req: req)
            return req.redirect(to: "/admin#users")
        }
        try await UserAdmin.delete(user, app: req.application)
        WebSession.flash("\(user.displayName)'s account and all their posts, media and moments were deleted.", req: req)
        return req.redirect(to: "/admin#users")
    }

    private func targetUser(_ req: Request) async throws -> User {
        guard let id = req.parameters.get("userID", as: UUID.self), let user = try await User.find(id, on: req.db) else {
            throw Abort(.notFound)
        }
        return user
    }

    // MARK: Settings

    struct ReactionsForm: Content { var emojis: String }

    @Sendable
    func saveReactions(req: Request) async throws -> Response {
        try WebSession.verifyCSRF(req)
        let input = try req.content.decode(ReactionsForm.self).emojis
        guard let palette = API.normalizedPalette(input.map(String.init)) else {
            WebSession.flash("Enter 1–\(API.maxReactionEmojis) different emoji.", req: req)
            return req.redirect(to: "/admin#settings")
        }
        try await InstanceSetting.setReactionPalette(palette, on: req.db)
        WebSession.flash("Reactions updated: \(palette.joined(separator: " "))", req: req)
        return req.redirect(to: "/admin#settings")
    }

    @Sendable
    func saveMomentWindow(req: Request) async throws -> Response {
        try WebSession.verifyCSRF(req)
        let window = try req.content.decode(MomentWindow.self)
        guard window.isValid else {
            WebSession.flash("The moment time window needs to be at least one hour.", req: req)
            return req.redirect(to: "/admin#settings")
        }
        try await MomentTime.setWindow(window, app: req.application)
        WebSession.flash("Moment time window set to \(window.startHour):00–\(window.endHour):00 (from tomorrow).", req: req)
        return req.redirect(to: "/admin#settings")
    }

    @Sendable
    func cleanUp(req: Request) async throws -> Response {
        try WebSession.verifyCSRF(req)
        let removed = try await UserAdmin.removeStaleUploads(app: req.application)
        WebSession.flash("Removed \(removed) unposted upload\(removed == 1 ? "" : "s").", req: req)
        return req.redirect(to: "/admin#storage")
    }

    // MARK: Helpers

    private func instanceName(_ req: Request) -> String { req.application.appConfig.instanceName }

    private func render(_ req: Request, _ template: String, _ context: some Encodable) async throws -> Response {
        try await req.view.render(template, context).encodeResponse(for: req)
    }
}

/// Session helpers for the dashboard: login state, CSRF token and one-time flash messages.
enum WebSession {
    static func userID(_ req: Request) -> UUID? { req.session.data["userID"].flatMap(UUID.init(uuidString:)) }

    static func logIn(_ id: UUID, req: Request) {
        req.session.data["userID"] = id.uuidString
    }

    /// Per-session token every form posts back, so other sites can't submit forms on the admin's behalf.
    static func csrf(_ req: Request) -> String {
        if let token = req.session.data["csrf"] { return token }
        let token = [UInt8].random(count: 24).base64
        req.session.data["csrf"] = token
        return token
    }

    struct CSRFForm: Content { var csrf: String }

    static func verifyCSRF(_ req: Request) throws {
        guard let expected = req.session.data["csrf"],
              let sent = try? req.content.decode(CSRFForm.self).csrf,
              sent == expected
        else { throw Abort(.forbidden, reason: "This form expired. Please reload the page and try again.") }
    }

    static func flash(_ message: String, req: Request) { req.session.data["flash"] = message }

    static func takeFlash(_ req: Request) -> String? {
        defer { req.session.data["flash"] = nil }
        return req.session.data["flash"]
    }
}

/// Lets only logged-in admins through; everyone else goes to the login page.
struct WebAdminMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let id = WebSession.userID(request),
              let user = try await User.find(id, on: request.db),
              user.isAdmin
        else {
            request.session.data["userID"] = nil
            return request.redirect(to: "/login")
        }
        request.auth.login(user)
        return try await next.respond(to: request)
    }
}
