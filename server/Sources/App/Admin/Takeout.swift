import Fluent
import FRNDSAPI
import Vapor

/// Builds a zip of everything a user posted: the media files (photos get caption, location and date
/// written into them when exiftool is available) plus `posts.json` with the comments and reactions,
/// and their highlights. The app adds the moments from the phone's archive under `moments/`.
enum Takeout {
    struct ExportedComment: Codable { var author: String; var text: String; var createdAt: Date }
    struct ExportedReaction: Codable { var user: String; var emoji: String }
    struct ExportedPost: Codable {
        var id: UUID
        var caption: String?
        var createdAt: Date
        var takenAt: Date?
        var location: PostLocation?
        var files: [String]
        var comments: [ExportedComment]
        var reactions: [ExportedReaction]
    }
    struct ExportedHighlight: Codable {
        var title: String
        var createdAt: Date
        var moments: [ExportedHighlightMoment]
    }
    struct ExportedHighlightMoment: Codable { var file: String; var caption: String?; var takenAt: Date }
    struct Profile: Codable {
        var username: String
        var displayName: String
        var joined: Date?
        var exportedAt: Date
        var server: String
    }

    /// Returns the path of the finished zip in a temporary folder (caller deletes it).
    static func build(for user: User, app: Application) async throws -> String {
        let userID = try user.requireID()
        let db = app.db
        let config = app.appConfig
        let stamp = ISO8601DateFormatter().string(from: .now).prefix(10)
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("takeout-\(UUID().uuidString)")
        let rootName = "frnds-\(user.username)-\(stamp)"
        let root = workDir.appendingPathComponent(rootName)
        let postsDir = root.appendingPathComponent("posts")
        try FileManager.default.createDirectory(at: postsDir, withIntermediateDirectories: true)

        let posts = try await Post.query(on: db)
            .filter(\.$author.$id == userID)
            .with(\.$media)
            .sort(\.$createdAt, .ascending)
            .all()
        let postIDs = posts.compactMap(\.id)
        let comments = postIDs.isEmpty ? [] : try await Comment.query(on: db).filter(\.$post.$id ~~ postIDs).with(\.$author).all()
        let reactions = postIDs.isEmpty ? [] : try await Reaction.query(on: db).filter(\.$post.$id ~~ postIDs).with(\.$user).all()

        let folderFormat = DateFormatter()
        folderFormat.locale = Locale(identifier: "en_US_POSIX")
        folderFormat.timeZone = config.timeZone
        folderFormat.dateFormat = "yyyy-MM-dd_HHmm"

        var exported: [ExportedPost] = []
        for post in posts {
            let postID = try post.requireID()
            let date = post.takenAt ?? post.createdAt ?? .now
            let folderName = "\(folderFormat.string(from: date))_\(postID.uuidString.prefix(8))"
            let folder = postsDir.appendingPathComponent(folderName)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            var files: [String] = []
            for (index, item) in post.media.sorted(by: { $0.position < $1.position }).enumerated() {
                guard let mediaID = item.id else { continue }
                let source = "\(config.mediaDirectory)/\(mediaID.uuidString)/\(item.originalFile)"
                let ext = (item.originalFile as NSString).pathExtension
                let name = String(format: "%02d.%@", index + 1, ext.isEmpty ? "jpg" : ext)
                let target = folder.appendingPathComponent(name)
                guard (try? FileManager.default.copyItem(atPath: source, toPath: target.path)) != nil else { continue }
                if item.kind == .image, let exiftool = config.exiftoolPath {
                    try? await embedMetadata(exiftool: exiftool, file: target.path, caption: post.caption,
                                             location: post.location, date: date, timeZone: config.timeZone)
                }
                files.append("posts/\(folderName)/\(name)")
            }

            exported.append(ExportedPost(
                id: postID, caption: post.caption, createdAt: post.createdAt ?? .now, takenAt: post.takenAt,
                location: post.location, files: files,
                comments: comments.filter { $0.$post.id == postID }
                    .sorted { ($0.createdAt ?? .now) < ($1.createdAt ?? .now) }
                    .map { ExportedComment(author: $0.author.displayName, text: $0.text, createdAt: $0.createdAt ?? .now) },
                reactions: reactions.filter { $0.$post.id == postID }
                    .map { ExportedReaction(user: $0.user.displayName, emoji: $0.emoji) }
            ))
        }

        let highlights = try await exportHighlights(of: userID, to: root, app: app, folderFormat: folderFormat)

        let encoder = API.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(exported).write(to: root.appendingPathComponent("posts.json"))
        try encoder.encode(highlights).write(to: root.appendingPathComponent("highlights.json"))
        try encoder.encode(Profile(username: user.username, displayName: user.displayName, joined: user.createdAt,
                                   exportedAt: .now, server: config.instanceName))
            .write(to: root.appendingPathComponent("profile.json"))
        try Data("""
        FRNDS export for \(user.displayName) (@\(user.username))

        posts/        one folder per post with its photos and videos (original files).
                      Photos have the caption, location and date written into them, so apps
                      like Apple Photos show them.
        posts.json    every post with caption, dates, location, comments and reactions.
        highlights/   one folder per highlight with its moments (the photo your friends saw).
        highlights.json  every highlight with its moments' captions and dates.
        profile.json  your account details.
        moments/      your moments from your iPhone's archive (added by the app; missing if you
                      downloaded this zip another way).

        """.utf8).write(to: root.appendingPathComponent("README.txt"))

        let zipPath = workDir.appendingPathComponent("\(rootName).zip").path
        try await ProcessRunner.run(config.zipPath, ["-r", "-q", zipPath, rootName], currentDirectory: workDir)
        try? FileManager.default.removeItem(at: root)
        return zipPath
    }

    /// Copies each highlight's composites into `highlights/<title>/` (dated names, caption and date embedded).
    private static func exportHighlights(of userID: UUID, to root: URL, app: Application,
                                         folderFormat: DateFormatter) async throws -> [ExportedHighlight] {
        let config = app.appConfig
        let highlights = try await Highlight.query(on: app.db)
            .filter(\.$owner.$id == userID).with(\.$items).sort(\.$createdAt, .ascending).all()
        var exported: [ExportedHighlight] = []
        var usedNames = Set<String>()
        for highlight in highlights {
            // File-system safe, unique folder name.
            var name = String(highlight.title.map { "/\\:".contains($0) ? "-" : $0 }).trimmingCharacters(in: .whitespaces)
            if name.isEmpty || name.hasPrefix(".") { name = "Highlight" }
            var unique = name, counter = 2
            while !usedNames.insert(unique.lowercased()).inserted { unique = "\(name) \(counter)"; counter += 1 }

            let folder = root.appendingPathComponent("highlights").appendingPathComponent(unique)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var moments: [ExportedHighlightMoment] = []
            for item in highlight.items.sorted(by: { $0.takenAt < $1.takenAt }) {
                guard let itemID = item.id else { continue }
                let fileName = "\(folderFormat.string(from: item.takenAt))_\(itemID.uuidString.prefix(8)).jpg"
                let target = folder.appendingPathComponent(fileName)
                guard (try? FileManager.default.copyItem(atPath: "\(HighlightItem.directory(for: itemID, in: app))/image.jpg",
                                                         toPath: target.path)) != nil else { continue }
                if let exiftool = config.exiftoolPath {
                    try? await embedMetadata(exiftool: exiftool, file: target.path, caption: item.caption,
                                             location: nil, date: item.takenAt, timeZone: config.timeZone)
                }
                moments.append(ExportedHighlightMoment(file: "highlights/\(unique)/\(fileName)", caption: item.caption,
                                                       takenAt: item.takenAt))
            }
            exported.append(ExportedHighlight(title: highlight.title, createdAt: highlight.createdAt ?? .now, moments: moments))
        }
        return exported
    }

    private static func embedMetadata(exiftool: String, file: String, caption: String?, location: PostLocation?,
                                      date: Date, timeZone: TimeZone) async throws {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = timeZone
        format.dateFormat = "yyyy:MM:dd HH:mm:ss"
        var args = ["-q", "-overwrite_original", "-charset", "iptc=UTF8", "-codedcharacterset=utf8",
                    "-EXIF:DateTimeOriginal=\(format.string(from: date))"]
        if let caption, !caption.isEmpty {
            args += ["-IPTC:Caption-Abstract=\(caption)", "-XMP-dc:Description=\(caption)", "-EXIF:ImageDescription=\(caption)"]
        }
        if let location {
            args += ["-GPSLatitude=\(abs(location.latitude))", "-GPSLatitudeRef=\(location.latitude >= 0 ? "N" : "S")",
                     "-GPSLongitude=\(abs(location.longitude))", "-GPSLongitudeRef=\(location.longitude >= 0 ? "E" : "W")"]
        }
        try await ProcessRunner.run(exiftool, args + [file])
    }
}
