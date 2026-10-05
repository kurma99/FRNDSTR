@testable import App
import Fluent
import FrndstrAPI
import Testing
import VaporTesting

@Suite(.enabled(if: ffmpegAvailable, "needs ffmpeg for the gradient photos"))
struct SeedTests {
    @Test func demoAccountSeesFriendsPostsAndLockedMoments() async throws {
        try await withTestApp { app, _ in
            _ = try await SeedCommand.seed(app, days: 2)

            var token = ""
            try await app.testing().test(.POST, API.Path.login, beforeRequest: { req in
                try req.content.encode(LoginRequest(username: "demo", password: SeedCommand.password), as: .json)
            }, afterResponse: { res in
                #expect(res.status == .ok)
                token = try API.makeDecoder().decode(AuthResponse.self, from: Data(buffer: res.body)).token
            })

            func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
                var value: T?
                try await app.testing().test(.GET, path, beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                }, afterResponse: { res in
                    #expect(res.status == .ok)
                    value = try API.makeDecoder().decode(T.self, from: Data(buffer: res.body))
                })
                return try #require(value)
            }

            let posts = try await get(API.Path.posts, as: FeedPage.self).posts
            #expect(posts.count == 3)
            #expect(posts.allSatisfy { !$0.media.isEmpty })
            let moments = try await get(API.Path.moments, as: MomentsFeed.self)
            #expect(moments.received.count == 3 && !moments.hasPostedToday)
        }
    }
}
