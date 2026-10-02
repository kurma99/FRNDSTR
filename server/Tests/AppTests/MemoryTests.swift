@testable import App
import Fluent
import FrndstrAPI
import Testing
import VaporTesting

private func call(_ app: Application, _ method: HTTPMethod, _ path: String,
                  token: String) async throws -> (status: HTTPStatus, body: Data) {
    var result: (HTTPStatus, Data) = (.internalServerError, Data())
    try await app.testing().test(method, path, beforeRequest: { req in
        req.headers.bearerAuthorization = BearerAuthorization(token: token)
    }, afterResponse: { res in
        result = (res.status, Data(buffer: res.body))
    })
    return result
}

/// Multipart upload of a memory: four JPEGs + JSON payload.
private func uploadMemory(_ app: Application, token: String, jpeg: Data,
                          _ memory: MemoryDTO) async throws -> (status: HTTPStatus, body: Data) {
    let boundary = "Boundary-\(UUID().uuidString)"
    var body = Data()
    func part(_ name: String, filename: String?, type: String, data: Data) {
        body.append(Data("--\(boundary)\r\n".utf8))
        let file = filename.map { "; filename=\"\($0)\"" } ?? ""
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\(file)\r\nContent-Type: \(type)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }
    for name in API.Memories.variants { part(name, filename: "\(name).jpg", type: "image/jpeg", data: jpeg) }
    part("payload", filename: nil, type: "application/json", data: try API.makeEncoder().encode(memory))
    body.append(Data("--\(boundary)--\r\n".utf8))

    var result: (HTTPStatus, Data) = (.internalServerError, Data())
    try await app.testing().test(.POST, API.Path.memories, beforeRequest: { req in
        req.headers.bearerAuthorization = BearerAuthorization(token: token)
        req.headers.replaceOrAdd(name: .contentType, value: "multipart/form-data; boundary=\(boundary)")
        req.body = ByteBuffer(data: body)
    }, afterResponse: { res in
        result = (res.status, Data(buffer: res.body))
    })
    return result
}

private func list(_ app: Application, token: String) async throws -> [MemoryDTO] {
    let response = try await call(app, .GET, API.Path.memories, token: token)
    #expect(response.status == .ok)
    return try API.makeDecoder().decode([MemoryDTO].self, from: response.body)
}

@Suite(.enabled(if: ffmpegAvailable, "needs ffmpeg to make sample JPEGs"))
struct MemoryTests {
    private let memory = MemoryDTO(
        id: UUID(), takenAt: Date(timeIntervalSince1970: 1_790_000_000), caption: "Frühstück",
        recipientNames: ["Ben", "Cleo"], layout: MomentLayout(insetCorner: .bottomTrailing, swapped: true, insetSize: 0.4),
        location: PostLocation(latitude: 53.55, longitude: 9.99, placeName: "Hamburg, Germany"))

    @Test func ownerOnlyBackupRoundTripsAndRetriesAreHarmless() async throws {
        try await withTestApp { app, dir in
            let anna = try await signUp(app, username: "anna")
            let ben = try await signUp(app, username: "ben")
            let jpeg = try await makeSample("b.jpg", in: dir, args: ["-f", "lavfi", "-i", "color=green:s=32x32", "-frames:v", "1"])

            #expect(try await uploadMemory(app, token: anna, jpeg: jpeg, memory).status == .ok)
            // The phone retries after a lost connection: still one copy.
            #expect(try await uploadMemory(app, token: anna, jpeg: jpeg, memory).status == .ok)

            let annas = try await list(app, token: anna)
            #expect(annas == [memory])
            for variant in API.Memories.variants {
                let file = try await call(app, .GET, API.Path.memoryFile(memory.id, variant), token: anna)
                #expect(file.status == .ok && file.body.starts(with: [0xFF, 0xD8]))
            }

            // Nobody else sees it, can load it, overwrite it or delete it.
            #expect(try await list(app, token: ben).isEmpty)
            #expect(try await call(app, .GET, API.Path.memoryFile(memory.id, "composite"), token: ben).status == .notFound)
            #expect(try await uploadMemory(app, token: ben, jpeg: jpeg, memory).status == .conflict)
            #expect(try await call(app, .DELETE, API.Path.memory(memory.id), token: ben).status == .notFound)
            #expect(try await call(app, .GET, API.Path.memoryFile(memory.id, "secret"), token: anna).status == .notFound)
        }
    }

    @Test func deletingRemovesRowAndFiles() async throws {
        try await withTestApp { app, dir in
            let anna = try await signUp(app, username: "anna")
            let annaID = try #require(try await User.query(on: app.db).filter(\.$username == "anna").first()?.requireID())
            let jpeg = try await makeSample("d.jpg", in: dir, args: ["-f", "lavfi", "-i", "color=red:s=32x32", "-frames:v", "1"])
            #expect(try await uploadMemory(app, token: anna, jpeg: jpeg, memory).status == .ok)
            let folder = MemoryBackup.directory(for: memory.id, ownerID: annaID, in: app)
            #expect(FileManager.default.fileExists(atPath: folder))

            #expect(try await call(app, .DELETE, API.Path.memory(memory.id), token: anna).status == .noContent)
            #expect(try await list(app, token: anna).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: folder))
        }
    }

    @Test func rejectsNonJPEGAndBadLocation() async throws {
        try await withTestApp { app, dir in
            let anna = try await signUp(app, username: "anna")
            #expect(try await uploadMemory(app, token: anna, jpeg: Data("nope".utf8), memory).status == .unsupportedMediaType)
            let jpeg = try await makeSample("r.jpg", in: dir, args: ["-f", "lavfi", "-i", "color=blue:s=32x32", "-frames:v", "1"])
            var bad = memory
            bad.location = PostLocation(latitude: 300, longitude: 0, placeName: nil)
            #expect(try await uploadMemory(app, token: anna, jpeg: jpeg, bad).status == .badRequest)
            #expect(try await list(app, token: anna).isEmpty)
        }
    }

    @Test func deletingTheAccountRemovesTheBackup() async throws {
        try await withTestApp { app, dir in
            let anna = try await signUp(app, username: "anna")
            let user = try #require(try await User.query(on: app.db).filter(\.$username == "anna").first())
            let jpeg = try await makeSample("a.jpg", in: dir, args: ["-f", "lavfi", "-i", "color=white:s=32x32", "-frames:v", "1"])
            #expect(try await uploadMemory(app, token: anna, jpeg: jpeg, memory).status == .ok)
            let folder = MemoryBackup.ownerDirectory(try user.requireID(), in: app)

            try await UserAdmin.delete(user, app: app)
            #expect(try await MemoryBackup.query(on: app.db).count() == 0)
            #expect(!FileManager.default.fileExists(atPath: folder))
        }
    }
}
