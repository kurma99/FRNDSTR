import Fluent
import FRNDSAPI
import Vapor

struct MediaController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let upload = routes.grouped("media").grouped(TokenAuthenticator(), User.guardMiddleware())
        // Streamed so large videos never sit in memory.
        upload.on(.POST, body: .stream, use: upload(req:))

        let files = routes.grouped("media").grouped(TokenAuthenticator(allowQueryToken: true), User.guardMiddleware())
        files.get(":mediaID", ":variant", use: file)
    }

    /// Raw body upload. `Content-Type` decides the kind: image/jpeg, image/png, video/mp4, video/quicktime.
    @Sendable
    func upload(req: Request) async throws -> MediaDTO {
        let user = try req.auth.require(User.self)
        guard let contentType = req.headers.contentType,
              let (kind, fileExtension) = Self.accepted(contentType)
        else {
            throw Abort(.unsupportedMediaType, reason: "Only JPEG, PNG, MP4 and MOV uploads are supported.")
        }

        let config = req.application.appConfig
        let mediaID = UUID()
        let directory = URL(fileURLWithPath: config.mediaDirectory).appendingPathComponent(mediaID.uuidString)
        let originalName = "original.\(fileExtension)"
        let originalURL = directory.appendingPathComponent(originalName)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await Self.write(body: req.body, to: originalURL, maxBytes: API.Limits.maxUploadBytes)

            let processor = MediaProcessor(ffmpeg: config.ffmpegPath, ffprobe: config.ffprobePath)
            let processed = switch kind {
            case .image: try await processor.processImage(in: directory, originalFile: originalName)
            case .video: try await processor.processVideo(in: directory, originalFile: originalName)
            }

            if let duration = processed.duration, duration > API.Limits.maxVideoSeconds + 1 {
                throw Abort(.payloadTooLarge, reason: "Videos can be at most \(Int(API.Limits.maxVideoSeconds)) seconds long.")
            }

            let media = PostMedia(id: mediaID, ownerID: try user.requireID(), kind: kind, processed: processed)
            try await media.create(on: req.db)
            return try media.toDTO()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if error is AbortError { throw error }
            req.logger.error("Media processing failed: \(String(describing: error))")
            throw Abort(.unprocessableEntity, reason: "The file could not be processed.")
        }
    }

    /// Serves `display`, `thumb` or `original`. Supports HTTP range requests (needed for video playback).
    @Sendable
    func file(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        guard let id = req.parameters.get("mediaID", as: UUID.self),
              let media = try await PostMedia.find(id, on: req.db)
        else { throw Abort(.notFound) }

        // Unattached uploads are only visible to their owner.
        if media.$post.id == nil, media.$owner.id != user.id {
            throw Abort(.notFound)
        }

        let fileName: String
        switch req.parameters.get("variant") {
        case "display": fileName = media.displayFile
        case "thumb": fileName = media.thumbFile
        case "original": fileName = media.originalFile
        default: throw Abort(.notFound)
        }

        let path = req.application.appConfig.mediaDirectory + "/\(id.uuidString)/\(fileName)"
        let response = try await req.fileio.asyncStreamFile(at: path)
        // Files never change once written.
        response.headers.replaceOrAdd(name: .cacheControl, value: "private, max-age=31536000, immutable")
        return response
    }

    private static func accepted(_ type: HTTPMediaType) -> (MediaKind, String)? {
        switch (type.type, type.subType) {
        case ("image", "jpeg"), ("image", "jpg"): (.image, "jpg")
        case ("image", "png"): (.image, "png")
        case ("video", "mp4"): (.video, "mp4")
        case ("video", "quicktime"): (.video, "mov")
        default: nil
        }
    }

    private static func write(body: Request.Body, to url: URL, maxBytes: Int) async throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url)
        else { throw Abort(.internalServerError, reason: "Could not store upload.") }
        defer { try? handle.close() }

        var written = 0
        for try await chunk in body {
            written += chunk.readableBytes
            guard written <= maxBytes else {
                throw Abort(.payloadTooLarge, reason: "Files can be at most \(maxBytes / 1024 / 1024) MB.")
            }
            try handle.write(contentsOf: Data(buffer: chunk))
        }
        guard written > 0 else { throw Abort(.badRequest, reason: "Empty upload.") }
    }
}
