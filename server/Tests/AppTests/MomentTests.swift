@testable import App
import Fluent
import FrndstrAPI
import Testing
import VaporTesting

private func request(_ app: Application, _ method: HTTPMethod, _ path: String, token: String,
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

private func decoded<T: Decodable>(_ type: T.Type, _ response: (status: HTTPStatus, body: Data)) throws -> T {
    #expect(response.status == .ok, "\(String(decoding: response.body, as: UTF8.self))")
    return try API.makeDecoder().decode(T.self, from: response.body)
}

private func userID(_ app: Application, _ token: String) async throws -> UUID {
    try decoded(UserDTO.self, try await request(app, .GET, API.Path.me, token: token)).id
}

private func befriend(_ app: Application, _ a: String, _ b: String) async throws {
    _ = try await request(app, .POST, API.Path.friend(try await userID(app, b)), token: a)
    _ = try await request(app, .POST, API.Path.friend(try await userID(app, a)), token: b)
}

/// Multipart upload of a moment (two JPEGs + JSON payload).
private func sendMoment(_ app: Application, token: String, jpeg: Data, to recipients: [UUID],
                        caption: String? = nil, layout: MomentLayout? = nil,
                        postMediaID: UUID? = nil,
                        location: PostLocation? = nil) async throws -> (status: HTTPStatus, body: Data) {
    let boundary = "Boundary-\(UUID().uuidString)"
    var body = Data()
    func part(_ name: String, filename: String?, type: String, data: Data) {
        body.append(Data("--\(boundary)\r\n".utf8))
        let file = filename.map { "; filename=\"\($0)\"" } ?? ""
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\(file)\r\nContent-Type: \(type)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }
    part("back", filename: "back.jpg", type: "image/jpeg", data: jpeg)
    part("front", filename: "front.jpg", type: "image/jpeg", data: jpeg)
    part("payload", filename: nil, type: "application/json",
         data: try API.makeEncoder().encode(CreateMomentRequest(caption: caption, recipientIDs: recipients,
                                                                layout: layout, postMediaID: postMediaID,
                                                                location: location)))
    body.append(Data("--\(boundary)--\r\n".utf8))

    var result: (HTTPStatus, Data) = (.internalServerError, Data())
    try await app.testing().test(.POST, API.Path.moments, beforeRequest: { req in
        req.headers.bearerAuthorization = BearerAuthorization(token: token)
        req.headers.replaceOrAdd(name: .contentType, value: "multipart/form-data; boundary=\(boundary)")
        req.body = ByteBuffer(data: body)
    }, afterResponse: { res in
        result = (res.status, Data(buffer: res.body))
    })
    return result
}

@Suite(.enabled(if: ffmpegAvailable, "needs ffmpeg to make sample JPEGs"))
struct MomentTests {
    @Test func friendsOnlyPostToSeeAndViewTracking() async throws {
        try await withTestApp { app, dir in
            let anna = try await signUp(app, username: "anna")
            let ben = try await signUp(app, username: "ben")
            let cleo = try await signUp(app, username: "cleo")
            let jpeg = try await makeSample("m.jpg", in: dir, args: ["-f", "lavfi", "-i", "color=green:s=64x64", "-frames:v", "1"])
            let benID = try await userID(app, ben)

            // Not friends yet → rejected.
            #expect(try await sendMoment(app, token: anna, jpeg: jpeg, to: [benID]).status == .badRequest)

            try await befriend(app, anna, ben)
            let moment = try decoded(MomentDTO.self, try await sendMoment(app, token: anna, jpeg: jpeg, to: [benID], caption: "Kaffee"))
            #expect(moment.isLocked == false)
            #expect(moment.recipients?.map(\.user.id) == [benID])
            #expect(abs(moment.expiresAt.timeIntervalSince(moment.createdAt) - API.Moments.lifetime) < 5)

            // Ben hasn't posted today → locked, no media paths, photo forbidden.
            var benFeed = try decoded(MomentsFeed.self, try await request(app, .GET, API.Path.moments, token: ben))
            #expect(benFeed.hasPostedToday == false)
            #expect(benFeed.received.map(\.id) == [moment.id])
            #expect(benFeed.received[0].isLocked && benFeed.received[0].backPath == nil)
            #expect(try await request(app, .GET, "\(API.Path.moment(moment.id))/back", token: ben).status == .forbidden)

            // Cleo isn't a recipient → can't even see it exists.
            #expect(try decoded(MomentsFeed.self, try await request(app, .GET, API.Path.moments, token: cleo)).received.isEmpty)
            #expect(try await request(app, .GET, "\(API.Path.moment(moment.id))/back", token: cleo).status == .notFound)

            // Ben posts his own → unlocked.
            _ = try decoded(MomentDTO.self, try await sendMoment(app, token: ben, jpeg: jpeg, to: [try await userID(app, anna)]))
            benFeed = try decoded(MomentsFeed.self, try await request(app, .GET, API.Path.moments, token: ben))
            #expect(benFeed.hasPostedToday)
            #expect(benFeed.received[0].isLocked == false)
            let photo = try await request(app, .GET, "\(API.Path.moment(moment.id))/front", token: ben)
            #expect(photo.status == .ok && photo.body.starts(with: [0xFF, 0xD8]))

            #expect(try await request(app, .POST, "\(API.Path.moment(moment.id))/view", token: ben).status == .noContent)
            #expect(try await request(app, .POST, "\(API.Path.moment(moment.id))/screenshot", token: ben).status == .noContent)
            let annaFeed = try decoded(MomentsFeed.self, try await request(app, .GET, API.Path.moments, token: anna))
            let recipient = try #require(annaFeed.sent.first { $0.id == moment.id }?.recipients?.first)
            #expect(recipient.viewedAt != nil && recipient.screenshotAt != nil)
        }
    }

    @Test func expiredMomentsArePurgedWithFiles() async throws {
        try await withTestApp { app, dir in
            let anna = try await signUp(app, username: "anna")
            let ben = try await signUp(app, username: "ben")
            try await befriend(app, anna, ben)
            let jpeg = try await makeSample("e.jpg", in: dir, args: ["-f", "lavfi", "-i", "color=red:s=32x32", "-frames:v", "1"])
            let moment = try decoded(MomentDTO.self, try await sendMoment(app, token: anna, jpeg: jpeg, to: [try await userID(app, ben)]))

            let folder = Moment.directory(for: moment.id, in: app)
            #expect(FileManager.default.fileExists(atPath: folder))
            #expect(try await MomentJanitor.purge(on: app, now: .now) == 0)
            #expect(try await MomentJanitor.purge(on: app, now: .now.addingTimeInterval(API.Moments.lifetime + 60)) == 1)
            #expect(!FileManager.default.fileExists(atPath: folder))
            #expect(try await MomentRecipient.query(on: app.db).count() == 0)
            #expect(try await request(app, .GET, "\(API.Path.moment(moment.id))/back", token: ben).status == .notFound)
        }
    }

    @Test func optInPostIsPublishedOnlyAfterExpiryWithCaptureDate() async throws {
        try await withTestApp { app, dir in
            let anna = try await signUp(app, username: "anna")
            let ben = try await signUp(app, username: "ben")
            try await befriend(app, anna, ben)
            let jpeg = try await makeSample("p.jpg", in: dir, args: ["-f", "lavfi", "-i", "color=yellow:s=48x64", "-frames:v", "1"])
            let composite = try await upload(app, token: anna, data: jpeg, type: .jpeg)
            let layout = MomentLayout(insetCorner: .bottomTrailing, swapped: true)

            let moment = try decoded(MomentDTO.self, try await sendMoment(
                app, token: anna, jpeg: jpeg, to: [try await userID(app, ben)], caption: "Sonnenuntergang",
                layout: layout, postMediaID: composite.id))
            #expect(moment.layout == layout)
            #expect(moment.becomesPost == true)

            // Not in the feed while the moment is live.
            #expect(try decoded(FeedPage.self, try await request(app, .GET, API.Path.posts, token: ben)).posts.isEmpty)
            // Recipients see the sender's arrangement but not whether it becomes a post.
            let received = try decoded(MomentsFeed.self, try await request(app, .GET, API.Path.moments, token: ben)).received[0]
            #expect(received.layout == layout && received.becomesPost == nil)

            try await MomentJanitor.purge(on: app, now: .now.addingTimeInterval(API.Moments.lifetime + 60))
            let posts = try decoded(FeedPage.self, try await request(app, .GET, API.Path.posts, token: ben)).posts
            let post = try #require(posts.first)
            #expect(posts.count == 1)
            #expect(post.caption == "Sonnenuntergang")
            #expect(post.media.map(\.id) == [composite.id])
            #expect(abs(post.createdAt.timeIntervalSince(moment.createdAt)) < 2)
            #expect(abs((post.takenAt ?? .distantPast).timeIntervalSince(moment.createdAt)) < 2)
        }
    }

    @Test func locationIsHiddenWhileLockedAndCarriedIntoThePost() async throws {
        try await withTestApp { app, dir in
            let anna = try await signUp(app, username: "anna")
            let ben = try await signUp(app, username: "ben")
            try await befriend(app, anna, ben)
            let benID = try await userID(app, ben)
            let jpeg = try await makeSample("l.jpg", in: dir, args: ["-f", "lavfi", "-i", "color=orange:s=48x64", "-frames:v", "1"])
            let composite = try await upload(app, token: anna, data: jpeg, type: .jpeg)
            let place = PostLocation(latitude: 50.73, longitude: 7.10, placeName: "Bonn, Germany")

            // Out-of-range coordinates are rejected.
            let invalid = PostLocation(latitude: 120, longitude: 7.10, placeName: nil)
            #expect(try await sendMoment(app, token: anna, jpeg: jpeg, to: [benID], location: invalid).status == .badRequest)

            let moment = try decoded(MomentDTO.self, try await sendMoment(
                app, token: anna, jpeg: jpeg, to: [benID], postMediaID: composite.id, location: place))
            #expect(moment.location == place)

            // Locked for Ben → no place either.
            var received = try decoded(MomentsFeed.self, try await request(app, .GET, API.Path.moments, token: ben)).received[0]
            #expect(received.isLocked && received.location == nil)

            _ = try decoded(MomentDTO.self, try await sendMoment(app, token: ben, jpeg: jpeg, to: [try await userID(app, anna)]))
            received = try decoded(MomentsFeed.self, try await request(app, .GET, API.Path.moments, token: ben)).received[0]
            #expect(received.location == place)

            try await MomentJanitor.purge(on: app, now: .now.addingTimeInterval(API.Moments.lifetime + 60))
            let post = try #require(try decoded(FeedPage.self, try await request(app, .GET, API.Path.posts, token: ben)).posts.first)
            #expect(post.location == place)
        }
    }

    @Test func rejectsSomeoneElsesPostMedia() async throws {
        try await withTestApp { app, dir in
            let anna = try await signUp(app, username: "anna")
            let ben = try await signUp(app, username: "ben")
            try await befriend(app, anna, ben)
            let jpeg = try await makeSample("o.jpg", in: dir, args: ["-f", "lavfi", "-i", "color=white:s=32x32", "-frames:v", "1"])
            let bensMedia = try await upload(app, token: ben, data: jpeg, type: .jpeg)
            let response = try await sendMoment(app, token: anna, jpeg: jpeg, to: [try await userID(app, ben)], postMediaID: bensMedia.id)
            #expect(response.status == .badRequest)
        }
    }

    @Test func rejectsNonJPEG() async throws {
        try await withTestApp { app, _ in
            let anna = try await signUp(app, username: "anna")
            let ben = try await signUp(app, username: "ben")
            try await befriend(app, anna, ben)
            #expect(try await sendMoment(app, token: anna, jpeg: Data("hello".utf8), to: [try await userID(app, ben)]).status == .unsupportedMediaType)
        }
    }

    @Test func momentWithoutFriendsIsJustForYou() async throws {
        try await withTestApp { app, dir in
            let anna = try await signUp(app, username: "anna")
            let ben = try await signUp(app, username: "ben")
            let jpeg = try await makeSample("s.jpg", in: dir, args: ["-f", "lavfi", "-i", "color=blue:s=48x64", "-frames:v", "1"])
            let composite = try await upload(app, token: anna, data: jpeg, type: .jpeg)

            // Anna has no friends yet, but can still take one.
            let moment = try decoded(MomentDTO.self, try await sendMoment(
                app, token: anna, jpeg: jpeg, to: [], caption: "Nur für mich", postMediaID: composite.id))
            #expect(moment.recipients?.isEmpty == true)

            let annaFeed = try decoded(MomentsFeed.self, try await request(app, .GET, API.Path.moments, token: anna))
            #expect(annaFeed.hasPostedToday)
            #expect(annaFeed.sent.map(\.id) == [moment.id])
            #expect(try await request(app, .GET, "\(API.Path.moment(moment.id))/back", token: anna).status == .ok)

            // Nobody else sees it or gets notified.
            #expect(try decoded(MomentsFeed.self, try await request(app, .GET, API.Path.moments, token: ben)).received.isEmpty)
            #expect(try await request(app, .GET, "\(API.Path.moment(moment.id))/back", token: ben).status == .notFound)
            #expect(try await Event.query(on: app.db).count() == 0)

            // It still becomes a post when it's over, if chosen.
            try await MomentJanitor.purge(on: app, now: .now.addingTimeInterval(API.Moments.lifetime + 60))
            let posts = try decoded(FeedPage.self, try await request(app, .GET, API.Path.posts, token: ben)).posts
            #expect(posts.map(\.caption) == ["Nur für mich"])
        }
    }
}
