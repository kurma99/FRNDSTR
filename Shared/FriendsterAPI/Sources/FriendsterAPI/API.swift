import Foundation

/// Endpoint paths and wire-format settings shared by app and server.
public enum API {
    public static let version = 1

    public enum Path {
        public static let health = "/api/health"
        public static let register = "/api/auth/register"
        public static let login = "/api/auth/login"
        public static let logout = "/api/auth/logout"
        public static let me = "/api/me"
        public static let media = "/api/media"
        public static let posts = "/api/posts"

        public static let users = "/api/users"
        public static let friends = "/api/friends"
        public static let avatar = "/api/me/avatar"
        public static let config = "/api/config"
        public static let moments = "/api/moments"
        public static let inbox = "/api/inbox"
        public static let momentTime = "/api/moment-time"
        public static let takeout = "/api/takeout"
        public static let streaks = "/api/streaks"
        public static let highlights = "/api/highlights"

        public static func post(_ id: UUID) -> String { "\(posts)/\(id.uuidString)" }
        public static func reaction(_ postID: UUID) -> String { "\(post(postID))/reaction" }
        public static func reactions(_ postID: UUID) -> String { "\(post(postID))/reactions" }
        public static func comments(_ postID: UUID) -> String { "\(post(postID))/comments" }
        public static func comment(_ id: UUID) -> String { "/api/comments/\(id.uuidString)" }
        public static func user(_ id: UUID) -> String { "\(users)/\(id.uuidString)" }
        public static func friend(_ userID: UUID) -> String { "\(friends)/\(userID.uuidString)" }
        public static func moment(_ id: UUID) -> String { "\(moments)/\(id.uuidString)" }
        public static func highlights(of userID: UUID) -> String { "\(user(userID))/highlights" }
        public static func highlight(_ id: UUID) -> String { "\(highlights)/\(id.uuidString)" }
        public static func highlightItems(_ id: UUID) -> String { "\(highlight(id))/items" }
        public static func highlightItem(_ id: UUID, _ itemID: UUID) -> String { "\(highlightItems(id))/\(itemID.uuidString)" }
    }

    /// Palette a fresh server starts with. Admins can change it (`InstanceConfig.reactionEmojis`).
    public static let defaultReactionEmojis = ["❤️", "😂", "😮", "😢", "🔥", "👏"]

    public enum Moments {
        /// Moments disappear from the server this long after sending.
        public static let lifetime: TimeInterval = 24 * 60 * 60
        public static let maxPhotoBytes = 10 * 1024 * 1024
        public static let maxCaptionLength = 200
    }

    /// Named collections of the sender's own moments, kept on the server and shown on their profile.
    public enum Highlights {
        public static let maxTitleLength = 40
        public static let maxItems = 100
        public static let maxPhotoBytes = 10 * 1024 * 1024
        public static let maxThumbnailBytes = 1024 * 1024

        /// A highlighted moment stays private to its recipients for its normal lifetime;
        /// after that all the owner's friends can see it.
        public static func visibleToFriendsFrom(takenAt: Date) -> Date {
            takenAt.addingTimeInterval(Moments.lifetime)
        }
    }

    public static let maxReactionEmojis = 12

    /// Normalizes an admin-entered palette: trims, drops duplicates, keeps only single emoji.
    /// Returns `nil` if the result is empty or longer than `maxReactionEmojis`.
    public static func normalizedPalette(_ emojis: [String]) -> [String]? {
        var seen = Set<String>()
        var result: [String] = []
        for raw in emojis {
            let emoji = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard emoji.count == 1, let character = emoji.first, character.isEmojiLike,
                  seen.insert(emoji).inserted
            else { continue }
            result.append(emoji)
        }
        return (1...maxReactionEmojis).contains(result.count) ? result : nil
    }

    /// Upload limits enforced by the server; the app checks them before uploading.
    public enum Limits {
        public static let maxMediaPerPost = 10
        public static let maxUploadBytes = 250 * 1024 * 1024
        public static let maxVideoSeconds: Double = 180
        public static let maxCaptionLength = 2_200
        public static let maxCommentLength = 1_000
        public static let maxAvatarBytes = 5 * 1024 * 1024
    }

    /// Query parameter that can carry the bearer token for media URLs (used by AVPlayer).
    public static let mediaTokenQueryItem = "token"

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension Character {
    /// True for emoji presentation characters (😀, ❤️, 👍🏽, 🇩🇪 …), false for plain letters/digits.
    var isEmojiLike: Bool {
        unicodeScalars.contains { $0.properties.isEmojiPresentation }
            || (unicodeScalars.count > 1 && unicodeScalars.contains { $0.properties.isEmoji })
    }
}
