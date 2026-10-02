import Foundation

// MARK: - Health

public struct HealthResponse: Codable, Sendable, Equatable {
    public var status: String
    public var instanceName: String
    public var apiVersion: Int

    public init(status: String, instanceName: String, apiVersion: Int) {
        self.status = status
        self.instanceName = instanceName
        self.apiVersion = apiVersion
    }
}

// MARK: - Auth

public struct RegisterRequest: Codable, Sendable, Equatable {
    public var inviteCode: String
    public var username: String
    public var displayName: String
    public var password: String

    public init(inviteCode: String, username: String, displayName: String, password: String) {
        self.inviteCode = inviteCode
        self.username = username
        self.displayName = displayName
        self.password = password
    }
}

public struct LoginRequest: Codable, Sendable, Equatable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

public struct AuthResponse: Codable, Sendable, Equatable {
    public var token: String
    public var user: UserDTO

    public init(token: String, user: UserDTO) {
        self.token = token
        self.user = user
    }
}

public struct UserDTO: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var username: String
    public var displayName: String
    public var createdAt: Date
    /// Server-relative path of the profile photo; changes whenever a new photo is uploaded.
    public var avatarPath: String?
    /// Admins can change instance settings such as the reaction palette. Optional for older cached copies.
    public var isAdmin: Bool?

    public init(id: UUID, username: String, displayName: String, createdAt: Date,
                avatarPath: String? = nil, isAdmin: Bool? = nil) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.createdAt = createdAt
        self.avatarPath = avatarPath
        self.isAdmin = isAdmin
    }
}

// MARK: - Instance configuration

/// Settings shared by everyone on the server; admins can change them.
public struct InstanceConfig: Codable, Sendable, Equatable {
    public var instanceName: String
    public var reactionEmojis: [String]
    /// Hours (server time zone) between which the daily moment time is picked.
    public var momentWindow: MomentWindow?

    public init(instanceName: String, reactionEmojis: [String], momentWindow: MomentWindow? = nil) {
        self.instanceName = instanceName
        self.reactionEmojis = reactionEmojis
        self.momentWindow = momentWindow
    }
}

/// e.g. 9–21: the shared moment time falls between 09:00 and 21:00.
public struct MomentWindow: Codable, Sendable, Equatable {
    public var startHour: Int
    public var endHour: Int

    public init(startHour: Int, endHour: Int) {
        self.startHour = startHour
        self.endHour = endHour
    }

    public static let `default` = MomentWindow(startHour: 9, endHour: 21)

    public var isValid: Bool { (0...23).contains(startHour) && (1...24).contains(endHour) && endHour - startHour >= 1 }
}


public struct UpdateProfileRequest: Codable, Sendable, Equatable {
    public var displayName: String

    public init(displayName: String) {
        self.displayName = displayName
    }
}

// MARK: - Profiles & friends

public enum FriendshipStatus: String, Codable, Sendable {
    /// The profile belongs to the viewer.
    case me
    case none
    /// The viewer sent a request that is still pending.
    case outgoing
    /// The other person sent the viewer a request.
    case incoming
    case friends
}

public struct ProfileDTO: Codable, Sendable, Equatable {
    public var user: UserDTO
    public var postCount: Int
    public var friendCount: Int
    public var friendship: FriendshipStatus

    public init(user: UserDTO, postCount: Int, friendCount: Int, friendship: FriendshipStatus) {
        self.user = user
        self.postCount = postCount
        self.friendCount = friendCount
        self.friendship = friendship
    }
}

public struct FriendsOverview: Codable, Sendable, Equatable {
    public var friends: [UserDTO]
    /// Requests others sent to the viewer.
    public var incoming: [UserDTO]
    /// Requests the viewer sent.
    public var outgoing: [UserDTO]

    public init(friends: [UserDTO], incoming: [UserDTO], outgoing: [UserDTO]) {
        self.friends = friends
        self.incoming = incoming
        self.outgoing = outgoing
    }
}

// MARK: - Media & Posts

public enum MediaKind: String, Codable, Sendable {
    case image
    case video
}

public struct MediaDTO: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var kind: MediaKind
    /// Server-relative path of the display rendition (JPEG or H.264 MP4).
    public var displayPath: String
    /// Server-relative path of a small JPEG thumbnail.
    public var thumbnailPath: String
    public var width: Int
    public var height: Int
    /// Duration in seconds, videos only.
    public var duration: Double?

    public init(id: UUID, kind: MediaKind, displayPath: String, thumbnailPath: String,
                width: Int, height: Int, duration: Double?) {
        self.id = id
        self.kind = kind
        self.displayPath = displayPath
        self.thumbnailPath = thumbnailPath
        self.width = width
        self.height = height
        self.duration = duration
    }

    /// Width / height, guarded against zero.
    public var aspectRatio: Double {
        guard width > 0, height > 0 else { return 1 }
        return Double(width) / Double(height)
    }
}

/// Where a post was taken. Only sent when the author opts in.
public struct PostLocation: Codable, Sendable, Equatable, Hashable {
    public var latitude: Double
    public var longitude: Double
    /// Human-readable place, e.g. "Hamburg, Germany".
    public var placeName: String?

    public init(latitude: Double, longitude: Double, placeName: String?) {
        self.latitude = latitude
        self.longitude = longitude
        self.placeName = placeName
    }
}

/// `PATCH /api/posts/{id}`: the author changes the caption. `nil` or blank removes it.
public struct UpdatePostRequest: Codable, Sendable, Equatable {
    public var caption: String?

    public init(caption: String?) {
        self.caption = caption
    }
}

public struct CreatePostRequest: Codable, Sendable, Equatable {
    public var caption: String?
    /// IDs returned by `POST /api/media`, in display order.
    public var mediaIDs: [UUID]
    public var location: PostLocation?
    /// Capture date of the first photo/video, if known.
    public var takenAt: Date?

    public init(caption: String?, mediaIDs: [UUID], location: PostLocation? = nil, takenAt: Date? = nil) {
        self.caption = caption
        self.mediaIDs = mediaIDs
        self.location = location
        self.takenAt = takenAt
    }
}

// MARK: - Reactions & comments

public struct ReactionCount: Codable, Sendable, Equatable, Hashable {
    public var emoji: String
    public var count: Int

    public init(emoji: String, count: Int) {
        self.emoji = emoji
        self.count = count
    }
}

public struct ReactionRequest: Codable, Sendable, Equatable {
    public var emoji: String

    public init(emoji: String) {
        self.emoji = emoji
    }
}

/// Returned after reacting or removing a reaction.
public struct ReactionSummary: Codable, Sendable, Equatable {
    public var reactions: [ReactionCount]
    public var myReaction: String?

    public init(reactions: [ReactionCount], myReaction: String?) {
        self.reactions = reactions
        self.myReaction = myReaction
    }
}

public struct ReactionDTO: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var user: UserDTO
    public var emoji: String
    public var id: UUID { user.id }

    public init(user: UserDTO, emoji: String) {
        self.user = user
        self.emoji = emoji
    }
}

public struct CommentDTO: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var postID: UUID
    public var author: UserDTO
    public var text: String
    public var createdAt: Date

    public init(id: UUID, postID: UUID, author: UserDTO, text: String, createdAt: Date) {
        self.id = id
        self.postID = postID
        self.author = author
        self.text = text
        self.createdAt = createdAt
    }
}

public struct CreateCommentRequest: Codable, Sendable, Equatable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

public struct PostDTO: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var author: UserDTO
    public var caption: String?
    public var createdAt: Date
    public var media: [MediaDTO]
    public var location: PostLocation?
    public var takenAt: Date?
    /// Counts per emoji, most used first.
    public var reactions: [ReactionCount]
    /// The viewer's own reaction, if any.
    public var myReaction: String?
    public var commentCount: Int

    public init(id: UUID, author: UserDTO, caption: String?, createdAt: Date, media: [MediaDTO],
                location: PostLocation? = nil, takenAt: Date? = nil,
                reactions: [ReactionCount] = [], myReaction: String? = nil, commentCount: Int = 0) {
        self.id = id
        self.author = author
        self.caption = caption
        self.createdAt = createdAt
        self.media = media
        self.location = location
        self.takenAt = takenAt
        self.reactions = reactions
        self.myReaction = myReaction
        self.commentCount = commentCount
    }

    public var totalReactions: Int { reactions.reduce(0) { $0 + $1.count } }
}

public struct FeedPage: Codable, Sendable, Equatable {
    public var posts: [PostDTO]
    /// Pass as `cursor` to fetch the next (older) page. `nil` means the end was reached.
    public var nextCursor: String?

    public init(posts: [PostDTO], nextCursor: String?) {
        self.posts = posts
        self.nextCursor = nextCursor
    }
}

/// Error body produced by Vapor's default error middleware.
public struct APIErrorResponse: Codable, Sendable, Equatable {
    public var error: Bool
    public var reason: String

    public init(error: Bool = true, reason: String) {
        self.error = error
        self.reason = reason
    }
}

// MARK: - Moments

/// How the sender arranged the two photos; recipients see this arrangement first.
public struct MomentLayout: Codable, Sendable, Equatable, Hashable {
    public enum Corner: String, Codable, Sendable, CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing
    }

    /// Where the small photo sits.
    public var insetCorner: Corner
    /// `true` if the front photo is the big one.
    public var swapped: Bool
    /// Width of the small photo as a fraction of the big one (pinch to resize).
    /// `nil` = the default size, so older moments and clients keep working.
    public var insetSize: Double?

    public static let defaultInsetSize = 0.3
    public static let insetSizeRange: ClosedRange<Double> = 0.2...0.5

    public init(insetCorner: Corner = .topLeading, swapped: Bool = false, insetSize: Double? = nil) {
        self.insetCorner = insetCorner
        self.swapped = swapped
        self.insetSize = insetSize.map { min(max($0, Self.insetSizeRange.lowerBound), Self.insetSizeRange.upperBound) }
    }

    /// The small photo's width fraction, clamped to `insetSizeRange`.
    public var resolvedInsetSize: Double {
        min(max(insetSize ?? Self.defaultInsetSize, Self.insetSizeRange.lowerBound), Self.insetSizeRange.upperBound)
    }
}

public struct CreateMomentRequest: Codable, Sendable, Equatable {
    public var caption: String?
    /// Friends who receive this moment. Must be accepted friends of the sender.
    public var recipientIDs: [UUID]
    public var layout: MomentLayout?
    /// Opt-in: an already uploaded photo (`POST /api/media`) that the server publishes as a post
    /// once the moment expires, dated to when the moment was taken. With `postMediaIDs` this is their first
    /// entry, so older servers still publish the main photo.
    public var postMediaID: UUID?
    /// Opt-in: all photos of that post in order (the big photo, then the small one).
    public var postMediaIDs: [UUID]?
    /// Opt-in place where the moment was taken.
    public var location: PostLocation?

    public init(caption: String?, recipientIDs: [UUID], layout: MomentLayout? = nil, postMediaID: UUID? = nil,
                postMediaIDs: [UUID]? = nil, location: PostLocation? = nil) {
        self.caption = caption
        self.recipientIDs = recipientIDs
        self.layout = layout
        self.postMediaID = postMediaID ?? postMediaIDs?.first
        self.postMediaIDs = postMediaIDs
        self.location = location
    }

    /// The photos to publish, in order (`postMediaIDs`, falling back to the single `postMediaID`).
    public var resolvedPostMediaIDs: [UUID] {
        if let postMediaIDs, !postMediaIDs.isEmpty { return postMediaIDs }
        return postMediaID.map { [$0] } ?? []
    }
}

public struct MomentRecipientDTO: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var user: UserDTO
    public var viewedAt: Date?
    public var screenshotAt: Date?
    public var id: UUID { user.id }

    public init(user: UserDTO, viewedAt: Date?, screenshotAt: Date?) {
        self.user = user
        self.viewedAt = viewedAt
        self.screenshotAt = screenshotAt
    }
}

public struct MomentDTO: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var sender: UserDTO
    public var caption: String?
    public var createdAt: Date
    public var expiresAt: Date
    /// `true` for a received moment from today while the viewer hasn't posted their own today.
    /// Locked moments come without media paths.
    public var isLocked: Bool
    public var backPath: String?
    public var frontPath: String?
    /// Only filled in for the sender's own moments.
    public var recipients: [MomentRecipientDTO]?
    public var layout: MomentLayout?
    /// Sender only: whether it becomes a post when it expires.
    public var becomesPost: Bool?
    /// Where it was taken, if the sender added it. Not sent while the moment is locked.
    public var location: PostLocation?

    public init(id: UUID, sender: UserDTO, caption: String?, createdAt: Date, expiresAt: Date, isLocked: Bool,
                backPath: String?, frontPath: String?, recipients: [MomentRecipientDTO]?,
                layout: MomentLayout? = nil, becomesPost: Bool? = nil, location: PostLocation? = nil) {
        self.id = id
        self.sender = sender
        self.caption = caption
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.isLocked = isLocked
        self.backPath = backPath
        self.frontPath = frontPath
        self.recipients = recipients
        self.layout = layout
        self.becomesPost = becomesPost
        self.location = location
    }
}

public struct MomentsFeed: Codable, Sendable, Equatable {
    /// Whether the viewer has sent a moment today (server day). Unlocks today's received moments.
    public var hasPostedToday: Bool
    /// Moments friends sent to the viewer, newest first, not yet expired.
    public var received: [MomentDTO]
    /// The viewer's own unexpired moments, newest first.
    public var sent: [MomentDTO]

    public init(hasPostedToday: Bool, received: [MomentDTO], sent: [MomentDTO]) {
        self.hasPostedToday = hasPostedToday
        self.received = received
        self.sent = sent
    }
}

// MARK: - Highlights

/// One moment inside a highlight. Only the composite (what friends saw) is kept on the server.
public struct HighlightItemDTO: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: UUID
    /// The moment's ID in the sender's on-device archive, so the app knows what's already added.
    public var sourceID: UUID
    public var caption: String?
    /// When the moment was taken.
    public var takenAt: Date
    public var imagePath: String
    public var thumbnailPath: String

    public init(id: UUID, sourceID: UUID, caption: String?, takenAt: Date, imagePath: String, thumbnailPath: String) {
        self.id = id
        self.sourceID = sourceID
        self.caption = caption
        self.takenAt = takenAt
        self.imagePath = imagePath
        self.thumbnailPath = thumbnailPath
    }

    /// Friends only see it once the moment's own 24 hours are over (the owner always sees it).
    public var visibleToFriendsFrom: Date { API.Highlights.visibleToFriendsFrom(takenAt: takenAt) }
}

/// A named collection of moments on someone's profile (like Instagram highlights).
/// Friends only, and only moments older than 24 hours; viewers can't save them.
public struct HighlightDTO: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var ownerID: UUID
    public var title: String
    /// The item whose thumbnail is the round cover; `nil` = the newest item.
    public var coverItemID: UUID?
    /// Oldest first.
    public var items: [HighlightItemDTO]
    public var createdAt: Date

    public init(id: UUID, ownerID: UUID, title: String, coverItemID: UUID?, items: [HighlightItemDTO], createdAt: Date) {
        self.id = id
        self.ownerID = ownerID
        self.title = title
        self.coverItemID = coverItemID
        self.items = items
        self.createdAt = createdAt
    }

    public var cover: HighlightItemDTO? {
        items.first { $0.id == coverItemID } ?? items.last
    }
}

public struct CreateHighlightRequest: Codable, Sendable, Equatable {
    public var title: String

    public init(title: String) {
        self.title = title
    }
}

/// Fields left `nil` stay unchanged.
public struct UpdateHighlightRequest: Codable, Sendable, Equatable {
    public var title: String?
    public var coverItemID: UUID?

    public init(title: String? = nil, coverItemID: UUID? = nil) {
        self.title = title
        self.coverItemID = coverItemID
    }
}

/// JSON `payload` part of `POST /api/highlights/{id}/items` (next to the `image` and `thumbnail` JPEGs).
public struct AddHighlightItemRequest: Codable, Sendable, Equatable {
    public var sourceID: UUID
    public var caption: String?
    public var takenAt: Date

    public init(sourceID: UUID, caption: String?, takenAt: Date) {
        self.sourceID = sourceID
        self.caption = caption
        self.takenAt = takenAt
    }
}

// MARK: - Memories backup

/// One of your own moments as kept in Memories. Also the JSON `payload` when uploading one.
public struct MemoryDTO: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// The moment's ID in the owner's on-device archive.
    public var id: UUID
    public var takenAt: Date
    public var caption: String?
    public var recipientNames: [String]
    public var layout: MomentLayout?
    public var location: PostLocation?

    public init(id: UUID, takenAt: Date, caption: String?, recipientNames: [String],
                layout: MomentLayout?, location: PostLocation?) {
        self.id = id
        self.takenAt = takenAt
        self.caption = caption
        self.recipientNames = recipientNames
        self.layout = layout
        self.location = location
    }
}

// MARK: - Notifications inbox

public enum EventType: String, Codable, Sendable, CaseIterable {
    /// A friend sent you a moment.
    case moment
    /// Someone on the server posted (including moments released as posts).
    case post
    case comment
    case reaction
    case friendRequest
    case friendAccepted
}

/// Something the app turns into a local notification.
public struct EventDTO: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var type: EventType
    public var actor: UserDTO?
    /// Post or moment the event is about.
    public var refID: UUID?
    /// Short preview, e.g. the comment text or reaction emoji.
    public var text: String?
    public var createdAt: Date

    public init(id: UUID, type: EventType, actor: UserDTO?, refID: UUID?, text: String?, createdAt: Date) {
        self.id = id
        self.type = type
        self.actor = actor
        self.refID = refID
        self.text = text
        self.createdAt = createdAt
    }
}

public struct InboxPage: Codable, Sendable, Equatable {
    /// Oldest first.
    public var events: [EventDTO]
    /// Pass as `since` next time.
    public var cursor: String

    public init(events: [EventDTO], cursor: String) {
        self.events = events
        self.cursor = cursor
    }
}

/// The family's shared "time for your moment" (same for everyone).
public struct MomentTimeDTO: Codable, Sendable, Equatable {
    public var today: Date
    public var tomorrow: Date

    public init(today: Date, tomorrow: Date) {
        self.today = today
        self.tomorrow = tomorrow
    }
}

// MARK: - Streaks

public struct StreakDTO: Codable, Sendable, Equatable, Identifiable {
    public var friend: UserDTO
    /// Consecutive days on which you both sent each other a moment (one forgiven miss per week).
    public var count: Int
    /// You already sent this friend a moment today.
    public var sentToday: Bool
    /// This friend already sent you a moment today.
    public var receivedToday: Bool
    /// The one forgiven missed day of this week is already used.
    public var graceUsedThisWeek: Bool
    public var id: UUID { friend.id }

    public init(friend: UserDTO, count: Int, sentToday: Bool, receivedToday: Bool, graceUsedThisWeek: Bool) {
        self.friend = friend
        self.count = count
        self.sentToday = sentToday
        self.receivedToday = receivedToday
        self.graceUsedThisWeek = graceUsedThisWeek
    }

    /// The streak ends at midnight unless both send today (and no grace day is left).
    public var isAtRisk: Bool { count > 0 && !(sentToday && receivedToday) }
}
