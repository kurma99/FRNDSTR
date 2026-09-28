@testable import App
import Fluent
import FriendsterAPI
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

private func addItem(_ app: Application, token: String, highlight: UUID, jpeg: Data,
                     sourceID: UUID = UUID(), takenAt: Date = .now) async throws -> (status: HTTPStatus, body: Data) {
    let boundary = "Boundary-\(UUID().uuidString)"
    var body = Data()
    func part(_ name: String, filename: String?, type: String, data: Data) {
        body.append(Data("--\(boundary)\r\n".utf8))
        let file = filename.map { "; filename=\"\($0)\"" } ?? ""
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\(file)\r\nContent-Type: \(type)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }
    part("image", filename: "image.jpg", type: "image/jpeg", data: jpeg)
    part("thumbnail", filename: "thumb.jpg", type: "image/jpeg", data: jpeg)
    part("payload", filename: nil, type: "application/json",
         data: try API.makeEncoder().encode(AddHighlightItemRequest(sourceID: sourceID, caption: "Beach", takenAt: takenAt)))
    body.append(Data("--\(boundary)--\r\n".utf8))

    var result: (HTTPStatus, Data) = (.internalServerError, Data())
    try await app.testing().test(.POST, API.Path.highlightItems(highlight), beforeRequest: { req in
        req.headers.bearerAuthorization = BearerAuthorization(token: token)
        req.headers.replaceOrAdd(name: .contentType, value: "multipart/form-data; boundary=\(boundary)")
        req.body = ByteBuffer(data: body)
    }, afterResponse: { res in
        result = (res.status, Data(buffer: res.body))
    })
    return result
}

@Suite(.enabled(if: ffmpegAvailable, "needs ffmpeg to make sample JPEGs"))
struct HighlightTests {
    @Test func friendsOnlyOwnerEditsAndFilesAreRemoved() async throws {
        try await withTestApp { app, dir in
            let anna = try await signUp(app, username: "anna")
            let ben = try await signUp(app, username: "ben")
            let cleo = try await signUp(app, username: "cleo")
            let annaID = try await userID(app, anna)
            let jpeg = try await makeSample("h.jpg", in: dir, args: ["-f", "lavfi", "-i", "color=blue:s=64x64", "-frames:v", "1"])
            _ = try await request(app, .POST, API.Path.friend(try await userID(app, ben)), token: anna)
            _ = try await request(app, .POST, API.Path.friend(annaID), token: ben)

            #expect(try await request(app, .POST, API.Path.highlights, token: anna,
                                      json: CreateHighlightRequest(title: "   ")).status == .badRequest)
            var highlight = try decoded(HighlightDTO.self, try await request(app, .POST, API.Path.highlights, token: anna,
                                                                               json: CreateHighlightRequest(title: " Summer ")))
            #expect(highlight.title == "Summer")

            let source = UUID()
            let older = Date(timeIntervalSinceNow: -86_400 * 30)
            highlight = try decoded(HighlightDTO.self, try await addItem(app, token: anna, highlight: highlight.id, jpeg: jpeg,
                                                                         sourceID: source))
            highlight = try decoded(HighlightDTO.self, try await addItem(app, token: anna, highlight: highlight.id, jpeg: jpeg,
                                                                         takenAt: older))
            // Same archived moment again is a no-op.
            highlight = try decoded(HighlightDTO.self, try await addItem(app, token: anna, highlight: highlight.id, jpeg: jpeg,
                                                                         sourceID: source))
            #expect(highlight.items.count == 2)
            // Dates travel as whole-second ISO 8601.
            #expect(abs((highlight.items.first?.takenAt ?? .distantFuture).timeIntervalSince(older)) < 1)
            #expect(highlight.cover?.sourceID == source)

            // Only the owner can change it.
            #expect(try await addItem(app, token: ben, highlight: highlight.id, jpeg: jpeg).status == .forbidden)
            #expect(try await request(app, .PATCH, API.Path.highlight(highlight.id), token: ben,
                                      json: UpdateHighlightRequest(title: "Mine")).status == .forbidden)

            // Friends see it, others don't.
            let seenByBen = try decoded([HighlightDTO].self, try await request(app, .GET, API.Path.highlights(of: annaID), token: ben))
            #expect(seenByBen.map(\.id) == [highlight.id])
            // The moment taken just now is still live: friends only get the 30-day-old one.
            #expect(seenByBen.first?.items.map(\.takenAt) == [highlight.items[0].takenAt])
            let fresh = try #require(highlight.items.last)
            #expect(try await request(app, .GET, fresh.imagePath, token: ben).status == .notFound)
            #expect(try await request(app, .GET, fresh.imagePath, token: anna).status == .ok)

            // A highlight with only live moments doesn't show up for friends yet; the owner sees it.
            let onlyFresh = try decoded(HighlightDTO.self, try await request(app, .POST, API.Path.highlights, token: anna,
                                                                             json: CreateHighlightRequest(title: "Heute")))
            // Future dates are clamped to now.
            _ = try decoded(HighlightDTO.self, try await addItem(app, token: anna, highlight: onlyFresh.id, jpeg: jpeg,
                                                                 takenAt: Date(timeIntervalSinceNow: 86_400 * 365)))
            #expect(try decoded([HighlightDTO].self, try await request(app, .GET, API.Path.highlights(of: annaID), token: ben))
                .map(\.id) == [highlight.id])
            #expect(try decoded([HighlightDTO].self, try await request(app, .GET, API.Path.highlights(of: annaID), token: anna))
                .count == 2)
            _ = try await request(app, .DELETE, API.Path.highlight(onlyFresh.id), token: anna)
            let seenByCleo = try decoded([HighlightDTO].self, try await request(app, .GET, API.Path.highlights(of: annaID), token: cleo))
            #expect(seenByCleo.isEmpty)
            let item = try #require(highlight.items.first)
            #expect(try await request(app, .GET, item.imagePath, token: ben).status == .ok)
            #expect(try await request(app, .GET, item.imagePath, token: cleo).status == .notFound)

            highlight = try decoded(HighlightDTO.self, try await request(app, .PATCH, API.Path.highlight(highlight.id), token: anna,
                                                                         json: UpdateHighlightRequest(title: "Sommer", coverItemID: item.id)))
            #expect(highlight.title == "Sommer")
            #expect(highlight.cover?.id == item.id)

            highlight = try decoded(HighlightDTO.self, try await request(app, .DELETE, API.Path.highlightItem(highlight.id, item.id), token: anna))
            #expect(highlight.items.count == 1)
            #expect(highlight.coverItemID == nil)
            #expect(!FileManager.default.fileExists(atPath: HighlightItem.directory(for: item.id, in: app)))

            let remaining = try #require(highlight.items.first)
            #expect(try await request(app, .DELETE, API.Path.highlight(highlight.id), token: anna).status == .noContent)
            #expect(!FileManager.default.fileExists(atPath: HighlightItem.directory(for: remaining.id, in: app)))
            #expect(try await HighlightItem.query(on: app.db).count() == 0)
        }
    }
}
