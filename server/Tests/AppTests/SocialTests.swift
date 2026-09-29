@testable import App
import Fluent
import FRNDSAPI
import Testing
import VaporTesting

/// Sends a JSON request and returns status + raw body.
@discardableResult
private func send(_ app: Application, _ method: HTTPMethod, _ path: String, token: String,
                  json: (any Encodable)? = nil) async throws -> (status: HTTPStatus, body: Data) {
    var result: (HTTPStatus, Data) = (.internalServerError, Data())
    try await app.testing().test(method, path, beforeRequest: { req in
        req.headers.bearerAuthorization = BearerAuthorization(token: token)
        if let json {
            req.headers.contentType = .json
            req.body = ByteBuffer(data: try API.makeEncoder().encode(json))
        }
    }, afterResponse: { res in
        result = (res.status, Data(buffer: res.body))
    })
    return result
}

private func decode<T: Decodable>(_ type: T.Type, _ response: (status: HTTPStatus, body: Data)) throws -> T {
    #expect(response.status == .ok, "\(String(decoding: response.body, as: UTF8.self))")
    return try API.makeDecoder().decode(T.self, from: response.body)
}

/// Two users and one image post by the first.
private func withFamily(_ test: (Application, URL, _ anna: String, _ ben: String, _ post: PostDTO) async throws -> Void) async throws {
    try await withTestApp { app, dir in
        let anna = try await signUp(app, username: "anna")
        let ben = try await signUp(app, username: "ben")
        let jpeg = try await makeSample("p.jpg", in: dir, args: ["-f", "lavfi", "-i", "color=orange:s=64x64", "-frames:v", "1"])
        let media = try await upload(app, token: anna, data: jpeg, type: .jpeg)
        let post = try await createPost(app, token: anna, mediaIDs: [media.id], caption: "Hi")
        try await test(app, dir, anna, ben, post)
    }
}

@Suite(.enabled(if: ffmpegAvailable, "needs ffmpeg + ffprobe"))
struct SocialTests {
    @Test func reactionsReplaceAndSummarize() async throws {
        try await withFamily { app, _, anna, ben, post in
            let path = API.Path.reaction(post.id)
            _ = try decode(ReactionSummary.self, try await send(app, .PUT, path, token: ben, json: ReactionRequest(emoji: "❤️")))
            var summary = try decode(ReactionSummary.self, try await send(app, .PUT, path, token: ben, json: ReactionRequest(emoji: "😂")))
            #expect(summary.reactions == [ReactionCount(emoji: "😂", count: 1)])
            #expect(summary.myReaction == "😂")

            summary = try decode(ReactionSummary.self, try await send(app, .PUT, path, token: anna, json: ReactionRequest(emoji: "❤️")))
            #expect(summary.reactions.map(\.count).reduce(0, +) == 2)
            #expect(summary.myReaction == "❤️")

            let invalid = try await send(app, .PUT, path, token: ben, json: ReactionRequest(emoji: "💩"))
            #expect(invalid.status == .badRequest)

            let feed = try decode(FeedPage.self, try await send(app, .GET, API.Path.posts, token: ben))
            #expect(feed.posts.first?.myReaction == "😂")
            #expect(feed.posts.first?.totalReactions == 2)

            let who = try decode([ReactionDTO].self, try await send(app, .GET, API.Path.reactions(post.id), token: anna))
            #expect(Set(who.map(\.user.username)) == ["anna", "ben"])

            summary = try decode(ReactionSummary.self, try await send(app, .DELETE, path, token: ben))
            #expect(summary.reactions == [ReactionCount(emoji: "❤️", count: 1)])
            #expect(summary.myReaction == nil)
        }
    }

    @Test func commentsAndDeletionRights() async throws {
        try await withFamily { app, _, anna, ben, post in
            let path = API.Path.comments(post.id)
            let bens = try decode(CommentDTO.self, try await send(app, .POST, path, token: ben, json: CreateCommentRequest(text: "  Schön!  ")))
            #expect(bens.text == "Schön!")
            #expect(bens.author.username == "ben")
            let annas = try decode(CommentDTO.self, try await send(app, .POST, path, token: anna, json: CreateCommentRequest(text: "Danke")))

            let empty = try await send(app, .POST, path, token: ben, json: CreateCommentRequest(text: "   "))
            #expect(empty.status == .badRequest)

            let list = try decode([CommentDTO].self, try await send(app, .GET, path, token: ben))
            #expect(list.map(\.id) == [bens.id, annas.id])
            let shown = try decode(PostDTO.self, try await send(app, .GET, API.Path.post(post.id), token: ben))
            #expect(shown.commentCount == 2)

            // Ben can't delete Anna's comment, but Anna (post author) may delete Ben's.
            #expect(try await send(app, .DELETE, API.Path.comment(annas.id), token: ben).status == .forbidden)
            #expect(try await send(app, .DELETE, API.Path.comment(bens.id), token: anna).status == .noContent)
            let remaining = try decode([CommentDTO].self, try await send(app, .GET, path, token: anna))
            #expect(remaining.map(\.id) == [annas.id])
        }
    }

    @Test func onlyAuthorCanEditCaption() async throws {
        try await withFamily { app, _, anna, ben, post in
            let path = API.Path.post(post.id)
            let forbidden = try await send(app, .PATCH, path, token: ben, json: UpdatePostRequest(caption: "Mine now"))
            #expect(forbidden.status == .forbidden)

            let edited = try decode(PostDTO.self, try await send(app, .PATCH, path, token: anna, json: UpdatePostRequest(caption: "  Hallo  ")))
            #expect(edited.caption == "Hallo")
            let seen = try decode(PostDTO.self, try await send(app, .GET, path, token: ben))
            #expect(seen.caption == "Hallo")

            let tooLong = String(repeating: "a", count: API.Limits.maxCaptionLength + 1)
            #expect(try await send(app, .PATCH, path, token: anna, json: UpdatePostRequest(caption: tooLong)).status == .badRequest)

            let cleared = try decode(PostDTO.self, try await send(app, .PATCH, path, token: anna, json: UpdatePostRequest(caption: "   ")))
            #expect(cleared.caption == nil)
        }
    }

    @Test func onlyAuthorCanDeletePostAndFilesAreRemoved() async throws {
        try await withFamily { app, dir, anna, ben, post in
            _ = try await send(app, .POST, API.Path.comments(post.id), token: ben, json: CreateCommentRequest(text: "x"))
            _ = try await send(app, .PUT, API.Path.reaction(post.id), token: ben, json: ReactionRequest(emoji: "🔥"))

            #expect(try await send(app, .DELETE, API.Path.post(post.id), token: ben).status == .forbidden)
            #expect(try await send(app, .DELETE, API.Path.post(post.id), token: anna).status == .noContent)
            #expect(try await send(app, .GET, API.Path.post(post.id), token: anna).status == .notFound)

            let mediaDir = dir.appendingPathComponent("media/\(post.media[0].id.uuidString)").path
            #expect(!FileManager.default.fileExists(atPath: mediaDir))
            #expect(try await Comment.query(on: app.db).count() == 0)
            #expect(try await Reaction.query(on: app.db).count() == 0)
        }
    }

    @Test func postLocationIsStoredAndValidated() async throws {
        try await withTestApp { app, dir in
            let anna = try await signUp(app)
            let jpeg = try await makeSample("l.jpg", in: dir, args: ["-f", "lavfi", "-i", "color=blue:s=32x32", "-frames:v", "1"])
            let taken = Date(timeIntervalSince1970: 1_780_000_000)
            let location = PostLocation(latitude: 53.5511, longitude: 9.9937, placeName: "Hamburg, Germany")

            var media = try await upload(app, token: anna, data: jpeg, type: .jpeg)
            let post = try decode(PostDTO.self, try await send(app, .POST, API.Path.posts, token: anna,
                json: CreatePostRequest(caption: nil, mediaIDs: [media.id], location: location, takenAt: taken)))
            #expect(post.location == location)
            #expect(post.takenAt == taken)

            media = try await upload(app, token: anna, data: jpeg, type: .jpeg)
            let invalid = try await send(app, .POST, API.Path.posts, token: anna,
                json: CreatePostRequest(caption: nil, mediaIDs: [media.id], location: PostLocation(latitude: 123, longitude: 0, placeName: nil)))
            #expect(invalid.status == .badRequest)
        }
    }
}

@Suite(.enabled(if: ffmpegAvailable, "needs ffmpeg + ffprobe"))
struct FriendAndProfileTests {
    @Test func friendRequestLifecycle() async throws {
        try await withFamily { app, _, anna, ben, post in
            let benID = try decode(UserDTO.self, try await send(app, .GET, API.Path.me, token: ben)).id
            let annaID = post.author.id

            var profile = try decode(ProfileDTO.self, try await send(app, .POST, API.Path.friend(benID), token: anna))
            #expect(profile.friendship == .outgoing)

            var overview = try decode(FriendsOverview.self, try await send(app, .GET, API.Path.friends, token: ben))
            #expect(overview.incoming.map(\.id) == [annaID])
            #expect(try decode(ProfileDTO.self, try await send(app, .GET, API.Path.user(annaID), token: ben)).friendship == .incoming)

            profile = try decode(ProfileDTO.self, try await send(app, .POST, API.Path.friend(annaID), token: ben))
            #expect(profile.friendship == .friends)
            #expect(profile.friendCount == 1)
            overview = try decode(FriendsOverview.self, try await send(app, .GET, API.Path.friends, token: anna))
            #expect(overview.friends.map(\.id) == [benID])
            #expect(overview.incoming.isEmpty && overview.outgoing.isEmpty)

            profile = try decode(ProfileDTO.self, try await send(app, .DELETE, API.Path.friend(annaID), token: ben))
            #expect(profile.friendship == FriendshipStatus.none)
            #expect(try await send(app, .POST, API.Path.friend(benID), token: ben).status == .badRequest)

            let own = try decode(ProfileDTO.self, try await send(app, .GET, API.Path.user(annaID), token: anna))
            #expect(own.friendship == .me)
            #expect(own.postCount == 1)
        }
    }

    @Test func profileEditAndAvatarVersions() async throws {
        try await withTestApp { app, dir in
            let anna = try await signUp(app)
            let renamed = try decode(UserDTO.self, try await send(app, .PATCH, API.Path.me, token: anna,
                                                                  json: UpdateProfileRequest(displayName: " Anna M. ")))
            #expect(renamed.displayName == "Anna M.")

            let jpeg = try await makeSample("a.jpg", in: dir, args: ["-f", "lavfi", "-i", "color=red:s=64x64", "-frames:v", "1"])
            func uploadAvatar() async throws -> UserDTO {
                var user: UserDTO?
                try await app.testing().test(.PUT, "api/me/avatar", beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: anna)
                    req.headers.contentType = .jpeg
                    req.body = ByteBuffer(data: jpeg)
                }, afterResponse: { res in
                    #expect(res.status == .ok)
                    user = try res.content.decode(UserDTO.self)
                })
                return try #require(user)
            }

            let first = try #require(try await uploadAvatar().avatarPath)
            try await Task.sleep(for: .milliseconds(5))
            let second = try #require(try await uploadAvatar().avatarPath)
            #expect(first != second)

            try await app.testing().test(.GET, String(second.dropFirst()) + "?token=\(anna)") { res in
                #expect(res.status == .ok)
            }
            try await app.testing().test(.GET, String(first.dropFirst()) + "?token=\(anna)") { res in
                #expect(res.status == .notFound)
            }

            let cleared = try decode(UserDTO.self, try await send(app, .DELETE, API.Path.avatar, token: anna))
            #expect(cleared.avatarPath == nil)
        }
    }
}
