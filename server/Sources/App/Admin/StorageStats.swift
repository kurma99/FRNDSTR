import Fluent
import Vapor

/// What the admin dashboard shows about disk usage, per category and per user.
struct StorageStats: Content {
    struct Bucket: Content {
        var label: String
        var count: Int
        var bytes: Int64
        var size: String
    }

    struct UserRow: Content {
        var id: UUID
        var displayName: String
        var username: String
        var isAdmin: Bool
        var joined: String
        var posts: Int
        var images: Int
        var videos: Int
        var liveMoments: Int
        var bytes: Int64
        var size: String
        var sessions: Int
    }

    var buckets: [Bucket]
    var totalSize: String
    var users: [UserRow]
    var postCount: Int
    var commentCount: Int
    var reactionCount: Int
    /// Uploads that never became a post (e.g. a cancelled share).
    var unpostedUploads: Int

    static func collect(on app: Application) async throws -> StorageStats {
        let db = app.db
        let mediaDir = app.appConfig.mediaDirectory
        let media = try await PostMedia.query(on: db).all()
        let posts = try await Post.query(on: db).all()
        let users = try await User.query(on: db).sort(\.$createdAt).all()
        let tokens = try await UserToken.query(on: db).all()
        let liveMoments = try await Moment.query(on: db).filter(\.$expiresAt > Date()).all()

        var originals = Bucket(label: "Originals", count: 0, bytes: 0, size: "")
        var display = Bucket(label: "Display copies (web-ready video)", count: 0, bytes: 0, size: "")
        var thumbs = Bucket(label: "Thumbnails", count: 0, bytes: 0, size: "")
        var bytesByUser: [UUID: Int64] = [:]
        var unposted = 0

        for item in media {
            guard let id = item.id else { continue }
            let folder = "\(mediaDir)/\(id.uuidString)"
            let original = fileSize("\(folder)/\(item.originalFile)")
            let thumb = fileSize("\(folder)/\(item.thumbFile)")
            // Images use the original as display file; only count separate display files.
            let displayBytes = item.displayFile == item.originalFile ? 0 : fileSize("\(folder)/\(item.displayFile)")
            originals.count += 1; originals.bytes += original
            thumbs.count += 1; thumbs.bytes += thumb
            if displayBytes > 0 { display.count += 1; display.bytes += displayBytes }
            bytesByUser[item.$owner.id, default: 0] += original + thumb + displayBytes
            if item.$post.id == nil { unposted += 1 }
        }

        let momentsFolder = directoryUsage("\(mediaDir)/moments")
        let avatarsFolder = directoryUsage("\(mediaDir)/avatars")
        let highlightsFolder = directoryUsage("\(mediaDir)/highlights")
        let highlights = Bucket(label: "Highlights (kept moments)", count: try await HighlightItem.query(on: db).count(),
                                bytes: highlightsFolder.bytes, size: "")
        let moments = Bucket(label: "Moments (live, deleted after 24h)", count: liveMoments.count, bytes: momentsFolder.bytes, size: "")
        let avatars = Bucket(label: "Profile photos", count: avatarsFolder.files, bytes: avatarsFolder.bytes, size: "")
        let database = Bucket(label: "Database", count: 1,
                              bytes: fileSize(app.appConfig.databasePath) + fileSize(app.appConfig.databasePath + "-wal"), size: "")

        var buckets = [originals, display, thumbs, moments, highlights, avatars, database]
        for index in buckets.indices { buckets[index].size = formatBytes(buckets[index].bytes) }
        let total = buckets.reduce(Int64(0)) { $0 + $1.bytes }

        let postsByUser = Dictionary(grouping: posts, by: \.$author.id)
        let mediaByUser = Dictionary(grouping: media, by: \.$owner.id)
        let momentsByUser = Dictionary(grouping: liveMoments, by: \.$sender.id)
        let sessionsByUser = Dictionary(grouping: tokens, by: \.$user.id)
        let dateFormat = Date.FormatStyle(date: .abbreviated, time: .omitted)

        let rows: [UserRow] = users.compactMap { user in
            guard let id = user.id else { return nil }
            let items = mediaByUser[id] ?? []
            return UserRow(id: id, displayName: user.displayName, username: user.username, isAdmin: user.isAdmin,
                           joined: user.createdAt?.formatted(dateFormat) ?? "–",
                           posts: postsByUser[id]?.count ?? 0,
                           images: items.filter { $0.kind == .image }.count,
                           videos: items.filter { $0.kind == .video }.count,
                           liveMoments: momentsByUser[id]?.count ?? 0,
                           bytes: bytesByUser[id] ?? 0, size: formatBytes(bytesByUser[id] ?? 0),
                           sessions: sessionsByUser[id]?.count ?? 0)
        }

        return StorageStats(buckets: buckets, totalSize: formatBytes(total), users: rows,
                            postCount: posts.count,
                            commentCount: try await Comment.query(on: db).count(),
                            reactionCount: try await Reaction.query(on: db).count(),
                            unpostedUploads: unposted)
    }

    static func fileSize(_ path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func directoryUsage(_ path: String) -> (files: Int, bytes: Int64) {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return (0, 0) }
        var files = 0, bytes: Int64 = 0
        while let relative = enumerator.nextObject() as? String {
            let full = "\(path)/\(relative)"
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory), !isDirectory.boolValue {
                files += 1
                bytes += fileSize(full)
            }
        }
        return (files, bytes)
    }

    /// "1.24 GB", "318 MB", "12 KB" (decimal units, like Finder).
    static func formatBytes(_ bytes: Int64) -> String {
        let value = Double(bytes)
        switch value {
        case 1_000_000_000...: return String(format: "%.2f GB", value / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1f MB", value / 1_000_000)
        case 1_000...: return String(format: "%.0f KB", value / 1_000)
        default: return "\(bytes) B"
        }
    }
}
