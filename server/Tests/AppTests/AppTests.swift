@testable import App
import Fluent
import FriendsterAPI
import Testing
import VaporTesting

/// Each test gets an in-memory database and its own temporary media directory.
func withTestApp(_ test: (Application, URL) async throws -> Void) async throws {
    let dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("friendster-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dataDir) }
    var config = AppConfig.fromEnvironment()
    config.dataDirectory = dataDir.path

    // Leaf looks for Resources/Views relative to the working directory; point it at the package.
    let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().path + "/"
    try await withApp(configure: { app in
        app.directory = DirectoryConfiguration(workingDirectory: packageRoot)
        try await configure(app, config: config)
    }) { app in
        try await test(app, dataDir)
    }
}

let ffmpegAvailable = AppConfig.findExecutable("ffmpeg") != nil && AppConfig.findExecutable("ffprobe") != nil

/// Signs up with an unused invite (creating one if needed) and returns the token.
func signUp(_ app: Application, username: String = "anna") async throws -> String {
    if try await Invite.query(on: app.db).filter(\.$usedBy.$id == nil).count() == 0 {
        try await Invite(code: Invite.generateCode()).create(on: app.db)
    }
    let invite = try #require(try await Invite.query(on: app.db).filter(\.$usedBy.$id == nil).first())
    var token = ""
    try await app.testing().test(.POST, "api/auth/register", beforeRequest: { req in
        try req.content.encode(RegisterRequest(inviteCode: invite.displayCode.lowercased(), username: username,
                                               displayName: "Anna", password: "supersecret"))
    }, afterResponse: { res in
        #expect(res.status == .ok, "\(res.body.string)")
        token = try res.content.decode(AuthResponse.self).token
    })
    return token
}

/// Generates a sample file with ffmpeg's built-in test sources.
func makeSample(_ name: String, in dir: URL, args: [String]) async throws -> Data {
    let url = dir.appendingPathComponent(name)
    try await ProcessRunner.run(AppConfig.findExecutable("ffmpeg")!, ["-y", "-v", "error"] + args + [url.path])
    return try Data(contentsOf: url)
}

func upload(_ app: Application, token: String, data: Data, type: HTTPMediaType) async throws -> MediaDTO {
    var media: MediaDTO?
    try await app.testing(method: .running(port: 0)).test(.POST, "api/media", beforeRequest: { req in
        req.headers.bearerAuthorization = BearerAuthorization(token: token)
        req.headers.contentType = type
        req.body = ByteBuffer(data: data)
    }, afterResponse: { res in
        #expect(res.status == .ok, "\(res.body.string)")
        media = try res.content.decode(MediaDTO.self)
    })
    return try #require(media)
}

func createPost(_ app: Application, token: String, mediaIDs: [UUID], caption: String?) async throws -> PostDTO {
    var post: PostDTO?
    try await app.testing().test(.POST, "api/posts", beforeRequest: { req in
        req.headers.bearerAuthorization = BearerAuthorization(token: token)
        try req.content.encode(CreatePostRequest(caption: caption, mediaIDs: mediaIDs))
    }, afterResponse: { res in
        #expect(res.status == .ok, "\(res.body.string)")
        post = try res.content.decode(PostDTO.self)
    })
    return try #require(post)
}

@Suite struct AuthTests {
    @Test func healthIsPublic() async throws {
        try await withTestApp { app, _ in
            try await app.testing().test(.GET, "api/health") { res in
                #expect(res.status == .ok)
                let health = try res.content.decode(HealthResponse.self)
                #expect(health.apiVersion == API.version)
            }
        }
    }

    @Test func registerLoginMeLogout() async throws {
        try await withTestApp { app, _ in
            let token = try await signUp(app)

            try await app.testing().test(.GET, "api/me", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            }, afterResponse: { res in
                let user = try res.content.decode(UserDTO.self)
                #expect(user.username == "anna")
            })

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(LoginRequest(username: "Anna", password: "wrongpassword"))
            }, afterResponse: { res in
                #expect(res.status == .unauthorized)
            })

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(LoginRequest(username: "Anna", password: "supersecret"))
            }, afterResponse: { res in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.POST, "api/auth/logout", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            }, afterResponse: { res in
                #expect(res.status == .noContent)
            })
            try await app.testing().test(.GET, "api/me", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            }, afterResponse: { res in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test func inviteIsSingleUse() async throws {
        try await withTestApp { app, _ in
            _ = try await signUp(app)
            let invite = try #require(try await Invite.query(on: app.db).first())
            try await app.testing().test(.POST, "api/auth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(inviteCode: invite.code, username: "ben",
                                                       displayName: "Ben", password: "supersecret"))
            }, afterResponse: { res in
                #expect(res.status == .forbidden)
            })
        }
    }

    @Test func feedRequiresAuth() async throws {
        try await withTestApp { app, _ in
            try await app.testing().test(.GET, "api/posts") { res in
                #expect(res.status == .unauthorized)
            }
        }
    }
}

@Suite(.enabled(if: ffmpegAvailable, "needs ffmpeg + ffprobe"))
struct PostTests {
    @Test func imagePostAppearsInFeedAndThumbIsServed() async throws {
        try await withTestApp { app, dir in
            let token = try await signUp(app)
            let jpeg = try await makeSample("red.jpg", in: dir,
                                            args: ["-f", "lavfi", "-i", "color=red:s=1200x800", "-frames:v", "1"])
            let media = try await upload(app, token: token, data: jpeg, type: .jpeg)
            #expect(media.kind == .image)
            #expect(media.width == 1200 && media.height == 800)

            let post = try await createPost(app, token: token, mediaIDs: [media.id], caption: "  Hello  ")
            #expect(post.caption == "Hello")

            try await app.testing().test(.GET, "api/posts", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            }, afterResponse: { res in
                let page = try res.content.decode(FeedPage.self)
                #expect(page.posts.map(\.id) == [post.id])
                #expect(page.nextCursor == nil)
            })

            // Query-token auth for media (what AVPlayer uses).
            let path = String(media.thumbnailPath.dropFirst()) + "?token=\(token)"
            try await app.testing().test(.GET, path) { res in
                #expect(res.status == .ok)
                #expect(res.headers.contentType == .jpeg)
            }
        }
    }

    @Test func nonH264VideoIsTranscoded() async throws {
        try await withTestApp { app, dir in
            let token = try await signUp(app)
            // Portrait video with rotation metadata, encoded as MPEG-4 Part 2 so the server must transcode.
            let mov = try await makeSample("clip.mov", in: dir, args: [
                "-display_rotation", "90", "-f", "lavfi", "-i", "testsrc=duration=2:size=640x360:rate=30",
                "-f", "lavfi", "-i", "sine=duration=2",
                "-c:v", "mpeg4", "-c:a", "pcm_s16le", "-shortest",
            ])
            let media = try await upload(app, token: token, data: mov, type: HTTPMediaType(type: "video", subType: "quicktime"))
            #expect(media.kind == .video)
            #expect(media.width == 360 && media.height == 640)
            #expect(abs((media.duration ?? 0) - 2) < 0.3)

            let displayFile = dir.appendingPathComponent("media/\(media.id.uuidString)/display.mp4").path
            let probe = try await ProcessRunner.run(AppConfig.findExecutable("ffprobe")!, [
                "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name", "-of", "csv=p=0", displayFile,
            ])
            #expect(String(decoding: probe, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "h264")
        }
    }

    @Test func feedPaginatesNewestFirst() async throws {
        try await withTestApp { app, dir in
            let token = try await signUp(app)
            let jpeg = try await makeSample("blue.jpg", in: dir,
                                            args: ["-f", "lavfi", "-i", "color=blue:s=64x64", "-frames:v", "1"])
            var created: [UUID] = []
            for index in 0..<3 {
                let media = try await upload(app, token: token, data: jpeg, type: .jpeg)
                created.append(try await createPost(app, token: token, mediaIDs: [media.id], caption: "\(index)").id)
            }

            var cursor: String?
            try await app.testing().test(.GET, "api/posts?limit=2", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            }, afterResponse: { res in
                let page = try res.content.decode(FeedPage.self)
                #expect(page.posts.map(\.id) == [created[2], created[1]])
                cursor = page.nextCursor
            })
            let next = try #require(cursor)
            try await app.testing().test(.GET, "api/posts?limit=2&cursor=\(next)", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            }, afterResponse: { res in
                let page = try res.content.decode(FeedPage.self)
                #expect(page.posts.map(\.id) == [created[0]])
                #expect(page.nextCursor == nil)
            })
        }
    }

    @Test func cannotAttachSomeoneElsesMediaTwice() async throws {
        try await withTestApp { app, dir in
            let token = try await signUp(app)
            let jpeg = try await makeSample("green.jpg", in: dir,
                                            args: ["-f", "lavfi", "-i", "color=green:s=64x64", "-frames:v", "1"])
            let media = try await upload(app, token: token, data: jpeg, type: .jpeg)
            _ = try await createPost(app, token: token, mediaIDs: [media.id], caption: nil)

            try await app.testing().test(.POST, "api/posts", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(CreatePostRequest(caption: nil, mediaIDs: [media.id]))
            }, afterResponse: { res in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test func rejectsUnsupportedType() async throws {
        try await withTestApp { app, _ in
            let token = try await signUp(app)
            try await app.testing(method: .running(port: 0)).test(.POST, "api/media", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                req.headers.contentType = .plainText
                req.body = ByteBuffer(string: "hello")
            }, afterResponse: { res in
                #expect(res.status == .unsupportedMediaType)
            })
        }
    }
}
