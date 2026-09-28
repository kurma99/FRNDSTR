@testable import App
import Fluent
import FriendsterAPI
import Testing
import VaporTesting

/// A tiny browser: keeps the session cookie and the form's CSRF token.
private final class Browser {
    let app: Application
    var cookie: String?
    var csrf = ""

    init(_ app: Application) { self.app = app }

    @discardableResult
    func get(_ path: String) async throws -> (status: HTTPStatus, body: String, location: String?) {
        var result: (HTTPStatus, String, String?) = (.internalServerError, "", nil)
        try await app.testing().test(.GET, path, beforeRequest: { req in
            if let cookie { req.headers.replaceOrAdd(name: .cookie, value: cookie) }
        }, afterResponse: { res in
            self.remember(res)
            let body = res.body.string
            if let match = body.firstMatch(of: /name="csrf" value="([^"]+)"/) { self.csrf = String(match.1) }
            result = (res.status, body, res.headers.first(name: .location))
        })
        return result
    }

    @discardableResult
    func post(_ path: String, _ fields: [String: String], includeCSRF: Bool = true) async throws -> (status: HTTPStatus, location: String?) {
        var result: (HTTPStatus, String?) = (.internalServerError, nil)
        var form = fields
        if includeCSRF { form["csrf"] = csrf }
        try await app.testing().test(.POST, path, beforeRequest: { req in
            if let cookie { req.headers.replaceOrAdd(name: .cookie, value: cookie) }
            try req.content.encode(form, as: .urlEncodedForm)
        }, afterResponse: { res in
            self.remember(res)
            result = (res.status, res.headers.first(name: .location))
        })
        return result
    }

    private func remember(_ res: TestingHTTPResponse) {
        if let value = res.headers.setCookie?["friendster-admin"]?.string {
            cookie = "friendster-admin=\(value)"
        }
    }

    /// Sets up the admin through the web and stays logged in.
    func setUpAdmin() async throws {
        try await get("/setup")
        let response = try await post("/setup", ["displayName": "Alex", "username": "alex", "password": "family1234"])
        #expect(response.location == "/admin")
    }
}

@Suite struct WebSetupTests {
    @Test func firstStartGoesToSetupAndCreatesTheAdmin() async throws {
        try await withTestApp { app, _ in
            let browser = Browser(app)
            #expect(try await browser.get("/").location == "/setup")
            #expect(try await browser.get("/login").location == "/setup")

            try await browser.get("/setup")
            #expect(try await browser.post("/setup", ["displayName": "L", "username": "alex", "password": "x"], includeCSRF: false).status == .forbidden)
            let short = try await browser.post("/setup", ["displayName": "L", "username": "alex", "password": "short"])
            #expect(short.status == .ok) // re-rendered with an error
            try await browser.setUpAdmin()

            let admin = try #require(try await User.query(on: app.db).filter(\.$username == "alex").first())
            #expect(admin.isAdmin)
            let dashboard = try await browser.get("/admin")
            #expect(dashboard.status == .ok && dashboard.body.contains("Storage"))
            // Setup is gone once an account exists.
            #expect(try await Browser(app).get("/setup").location == "/login")
        }
    }

    @Test func onlyAdminsCanLogIn() async throws {
        try await withTestApp { app, _ in
            let admin = Browser(app)
            try await admin.setUpAdmin()
            _ = try await signUp(app, username: "ben")

            let visitor = Browser(app)
            #expect(try await visitor.get("/admin").location == "/login")
            try await visitor.get("/login")
            try await visitor.post("/login", ["username": "ben", "password": "supersecret"])
            #expect(try await visitor.get("/admin").location == "/login")
            try await visitor.post("/login", ["username": "alex", "password": "family1234"])
            #expect(try await visitor.get("/admin").status == .ok)
        }
    }
}

@Suite(.enabled(if: ffmpegAvailable, "needs ffmpeg"))
struct WebAdminActionTests {
    @Test func invitesSettingsAndUserManagement() async throws {
        try await withTestApp { app, dir in
            let browser = Browser(app)
            try await browser.setUpAdmin()
            try await browser.get("/admin")

            // Invites
            try await browser.post("/admin/invites", ["count": "3"])
            #expect(try await Invite.query(on: app.db).count() == 3)
            let flash = try await browser.get("/admin").body
            #expect(flash.contains("New invite codes:"))
            let invite = try #require(try await Invite.query(on: app.db).first())
            try await browser.post("/admin/invites/\(invite.requireID())/revoke", [:])
            #expect(try await Invite.query(on: app.db).count() == 2)

            // Settings
            try await browser.post("/admin/settings/reactions", ["emojis": "🎉 🥰 abc 🎉"])
            #expect(try await InstanceSetting.reactionPalette(on: app.db) == ["🎉", "🥰"])
            try await browser.post("/admin/settings/moment-window", ["startHour": "18", "endHour": "19"])
            #expect(try await MomentTime.window(on: app.db) == MomentWindow(startHour: 18, endHour: 19))

            // A user with a post, then reset, kick and delete them.
            let ben = try await signUp(app, username: "ben")
            let jpeg = try await makeSample("w.jpg", in: dir, args: ["-f", "lavfi", "-i", "color=olive:s=32x32", "-frames:v", "1"])
            let media = try await upload(app, token: ben, data: jpeg, type: .jpeg)
            _ = try await createPost(app, token: ben, mediaIDs: [media.id], caption: "Bens Post")
            let benUser = try #require(try await User.query(on: app.db).filter(\.$username == "ben").first())
            let benID = try benUser.requireID()

            try await browser.post("/admin/users/\(benID)/password", [:])
            let page = try await browser.get("/admin").body
            let password = try #require(page.firstMatch(of: /New password for [^:]+: ([a-z0-9]{12})/)?.1)
            #expect(try await UserToken.query(on: app.db).filter(\.$user.$id == benID).count() == 0)
            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(LoginRequest(username: "ben", password: String(password)))
            }, afterResponse: { res in #expect(res.status == .ok) })

            try await browser.post("/admin/users/\(benID)/kick", [:])
            #expect(try await UserToken.query(on: app.db).filter(\.$user.$id == benID).count() == 0)

            try await browser.post("/admin/users/\(benID)/delete", ["confirm": "wrong"])
            #expect(try await User.find(benID, on: app.db) != nil)
            try await browser.post("/admin/users/\(benID)/delete", ["confirm": "ben"])
            #expect(try await User.find(benID, on: app.db) == nil)
            #expect(try await Post.query(on: app.db).count() == 0)
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("media/\(media.id.uuidString)").path))

            // The last admin can't remove their own admin rights.
            let alex = try #require(try await User.query(on: app.db).filter(\.$username == "alex").first())
            try await browser.post("/admin/users/\(alex.requireID())/admin", [:])
            #expect(try await User.find(alex.requireID(), on: app.db)?.isAdmin == true)
        }
    }

    @Test func storageStatsCountFiles() async throws {
        try await withTestApp { app, dir in
            let anna = try await signUp(app, username: "anna")
            let jpeg = try await makeSample("s.jpg", in: dir, args: ["-f", "lavfi", "-i", "color=teal:s=64x64", "-frames:v", "1"])
            let media = try await upload(app, token: anna, data: jpeg, type: .jpeg)
            _ = try await createPost(app, token: anna, mediaIDs: [media.id], caption: nil)
            _ = try await upload(app, token: anna, data: jpeg, type: .jpeg) // never posted

            let stats = try await StorageStats.collect(on: app)
            let originals = try #require(stats.buckets.first { $0.label == "Originals" })
            let thumbs = try #require(stats.buckets.first { $0.label == "Thumbnails" })
            #expect(originals.count == 2 && originals.bytes > 0)
            #expect(thumbs.count == 2)
            #expect(stats.unpostedUploads == 1)
            #expect(stats.users.first?.posts == 1 && stats.users.first?.images == 2)
        }
    }
}

@Suite(.enabled(if: ffmpegAvailable && AppConfig.findExecutable("unzip") != nil, "needs ffmpeg + unzip"))
struct TakeoutTests {
    @Test func zipContainsMediaAndCommentsOfOwnPostsOnly() async throws {
        try await withTestApp { app, dir in
            let anna = try await signUp(app, username: "anna")
            let ben = try await signUp(app, username: "ben")
            let jpeg = try await makeSample("t.jpg", in: dir, args: ["-f", "lavfi", "-i", "color=orange:s=64x64", "-frames:v", "1"])
            let media = try await upload(app, token: anna, data: jpeg, type: .jpeg)
            let post = try await createPost(app, token: anna, mediaIDs: [media.id], caption: "Sommerfest")
            _ = try await createPost(app, token: ben, mediaIDs: [try await upload(app, token: ben, data: jpeg, type: .jpeg).id], caption: "Bens")
            try await app.testing().test(.POST, "api/posts/\(post.id)/comments", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: ben)
                try req.content.encode(CreateCommentRequest(text: "Super Fest!"))
            }, afterResponse: { _ in })
            // A highlight with one kept moment.
            let annaUser = try #require(try await User.query(on: app.db).filter(\.$username == "anna").first())
            let highlight = Highlight(ownerID: try annaUser.requireID(), title: "Urlaub/2026")
            try await highlight.create(on: app.db)
            let itemID = UUID()
            try FileManager.default.createDirectory(atPath: HighlightItem.directory(for: itemID, in: app), withIntermediateDirectories: true)
            try jpeg.write(to: URL(fileURLWithPath: "\(HighlightItem.directory(for: itemID, in: app))/image.jpg"))
            try await HighlightItem(id: itemID, highlightID: try highlight.requireID(), sourceID: UUID(),
                                    caption: "Am Meer", takenAt: .now).create(on: app.db)

            let zipURL = dir.appendingPathComponent("takeout.zip")
            try await app.testing(method: .running(port: 0)).test(.GET, "api/takeout", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: anna)
            }, afterResponse: { res in
                #expect(res.status == .ok)
                #expect(res.headers.contentType == .zip)
                try Data(buffer: res.body).write(to: zipURL)
            })

            let listing = String(decoding: try await ProcessRunner.run(AppConfig.findExecutable("unzip")!, ["-Z1", zipURL.path]), as: UTF8.self)
            #expect(listing.contains("posts.json") && listing.contains("README.txt") && listing.contains("/01.jpg"))
            let json = try await ProcessRunner.run(AppConfig.findExecutable("unzip")!, ["-p", zipURL.path, "*/posts.json"])
            let text = String(decoding: json, as: UTF8.self)
            #expect(text.contains("Sommerfest") && text.contains("Super Fest!"))
            #expect(!text.contains("Bens"))
            #expect(listing.contains("highlights/Urlaub-2026/") && listing.contains("highlights.json"))
            let highlightsJSON = try await ProcessRunner.run(AppConfig.findExecutable("unzip")!, ["-p", zipURL.path, "*/highlights.json"])
            #expect(String(decoding: highlightsJSON, as: UTF8.self).contains("Am Meer"))

            if let exiftool = AppConfig.findExecutable("exiftool") {
                let extract = dir.appendingPathComponent("x")
                _ = try await ProcessRunner.run(AppConfig.findExecutable("unzip")!, ["-q", zipURL.path, "-d", extract.path])
                let photo = try #require(FileManager.default.enumerator(atPath: extract.path)?.allObjects
                    .compactMap { $0 as? String }.first { $0.hasSuffix("01.jpg") })
                let caption = try await ProcessRunner.run(exiftool, ["-s3", "-Caption-Abstract", extract.appendingPathComponent(photo).path])
                #expect(String(decoding: caption, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "Sommerfest")
            }
        }
    }
}
