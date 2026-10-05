import Fluent
import FrndstrAPI
import Vapor

/// `./App seed` fills an empty server with demo users, friendships, two weeks of posts, comments,
/// reactions, streaks and live moments. All photos are plain colour gradients made with ffmpeg.
/// Meant for `scripts/demo.sh`, never for a real family server: it refuses to run once accounts exist.
struct SeedCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "days", help: "How many days of posts to create (default 14).")
        var days: Int?

        init() {}
    }

    var help: String { "Fills an empty server with demo data (users, posts, moments). Password for everyone: \(Self.password)" }

    static let password = "demodemo"
    /// The first one is the admin and the account to sign in with.
    static let people = [("demo", "Demo"), ("anna", "Anna"), ("ben", "Ben"), ("cleo", "Cleo"), ("dani", "Dani")]
    /// Sent a friend request to `demo` that is still open.
    static let stranger = ("emil", "Emil")

    private static let captions = [
        "Sunday walk", "Breakfast on the balcony", "Look at this sky", "New plant!", "Rainy day inside",
        "Finally finished the puzzle", "Beach day", "Grandma's cake", nil, "Cozy evening", "First snow",
        "Market haul", nil, "Game night", "Road trip, day 1", "Sunset again",
    ]
    private static let comments = ["So nice!", "Wow 😍", "Where is that?", "Miss you all", "Next time I'm coming too",
                                   "Haha", "Beautiful", "Save me a piece"]

    func run(using context: CommandContext, signature: Signature) async throws {
        guard try await User.query(on: context.application.db).count() == 0 else {
            context.console.error("This server already has accounts. Seed only runs on an empty data directory.")
            return
        }
        let summary = try await Self.seed(context.application, days: signature.days ?? 14)
        context.console.print(summary)
        context.console.print("Sign in as \(Self.people[0].0) / \(Self.password) (also: \(Self.people.dropFirst().map(\.0).joined(separator: ", "))).")
    }

    /// Returns a one-line summary of what was created.
    static func seed(_ app: Application, days: Int) async throws -> String {
        let db = app.db
        var random = SeededRandom(seed: 42)
        let images = GradientMaker(app: app)
        let day: TimeInterval = 24 * 3600
        let now = Date()

        // People: everyone is friends with everyone, Emil is still waiting for an answer.
        var users: [User] = []
        for (index, (username, name)) in (Self.people + [stranger]).enumerated() {
            let user = User(username: username, displayName: name, passwordHash: try app.password.hash(Self.password))
            user.isAdmin = index == 0
            try await user.create(on: db)
            try await images.avatar(for: user, random: &random)
            users.append(user)
        }
        let family = Array(users.prefix(people.count))
        let ids = try family.map { try $0.requireID() }
        for (i, a) in ids.enumerated() {
            for b in ids[(i + 1)...] {
                let friendship = Friendship(requesterID: a, addresseeID: b)
                friendship.status = .accepted
                try await friendship.create(on: db)
            }
        }
        try await Friendship(requesterID: try users[people.count].requireID(), addresseeID: ids[0]).create(on: db)

        // Posts spread over the last days, oldest first, each with 1–3 photos.
        let palette = try await InstanceSetting.reactionPalette(on: db)
        let days = max(days, 1)
        let postCount = days + days / 2
        for index in 0..<postCount {
            let author = ids[random.next(below: ids.count)]
            let takenAt = now.addingTimeInterval(-Double(days) * day * Double(postCount - index) / Double(postCount)
                                                 + Double(random.next(below: 3600)))
            let post = Post(authorID: author, caption: captions[index % captions.count])
            post.takenAt = takenAt
            if random.next(below: 3) == 0 {
                post.latitude = 53.55 + Double(random.next(below: 100)) / 1000
                post.longitude = 9.99 + Double(random.next(below: 100)) / 1000
                post.placeName = "Hamburg, Germany"
            }
            try await post.create(on: db)
            let postID = try post.requireID()
            try await Post.query(on: db).filter(\.$id == postID).set(\.$createdAt, to: takenAt).update()

            for position in 0..<(1 + random.next(below: 3)) {
                let media = try await images.postPhoto(ownerID: author, random: &random)
                media.$post.id = postID
                media.position = position
                try await media.save(on: db)
            }
            for (offset, friend) in ids.filter({ $0 != author }).enumerated() {
                if random.next(below: 3) > 0 {
                    try await Reaction(postID: postID, userID: friend, emoji: palette[random.next(below: palette.count)])
                        .create(on: db)
                }
                if random.next(below: 4) == 0 {
                    let comment = Comment(postID: postID, authorID: friend,
                                          text: comments[random.next(below: comments.count)])
                    try await comment.create(on: db)
                    try await Comment.query(on: db).filter(\.$id == comment.requireID())
                        .set(\.$createdAt, to: takenAt.addingTimeInterval(Double(offset + 1) * 1800)).update()
                }
            }
        }

        // Streaks: Demo and Anna have sent each other a moment every day for the last few days.
        let serverDay = ServerDay(timeZone: app.appConfig.timeZone)
        for back in 1...4 {
            let key = serverDay.key(for: now.addingTimeInterval(-Double(back) * day))
            try await MomentDay(senderID: ids[0], recipientID: ids[1], day: key).create(on: db)
            try await MomentDay(senderID: ids[1], recipientID: ids[0], day: key).create(on: db)
        }

        // Live moments from three friends to everyone; Demo hasn't sent one yet, so they start locked.
        for (hoursAgo, sender) in [(1, ids[1]), (3, ids[2]), (5, ids[3])] {
            let id = UUID()
            let directory = Moment.directory(for: id, in: app)
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try await images.gradient(width: 1080, height: 1440, to: "\(directory)/back.jpg", random: &random)
            try await images.gradient(width: 720, height: 960, to: "\(directory)/front.jpg", random: &random)
            let createdAt = now.addingTimeInterval(-Double(hoursAgo) * 3600)
            let moment = Moment(id: id, senderID: sender, caption: hoursAgo == 1 ? "Hi from the demo" : nil,
                                expiresAt: createdAt.addingTimeInterval(API.Moments.lifetime))
            try await moment.create(on: db)
            try await Moment.query(on: db).filter(\.$id == id).set(\.$createdAt, to: createdAt).update()
            for recipient in ids where recipient != sender {
                try await MomentRecipient(momentID: id, userID: recipient).create(on: db)
            }
        }

        return "Seeded \(users.count) users, \(postCount) posts and 3 live moments."
    }
}

/// Plain two-colour gradient JPEGs from ffmpeg's `gradients` source.
private struct GradientMaker {
    let app: Application

    func gradient(width: Int, height: Int, to path: String, random: inout SeededRandom) async throws {
        let config = app.appConfig
        let colors = (random.color(), random.color())
        try await ProcessRunner.run(config.ffmpegPath, [
            "-y", "-v", "error", "-f", "lavfi",
            "-i", "gradients=s=\(width)x\(height):c0=\(colors.0):c1=\(colors.1):n=2:seed=\(random.next(below: 1_000_000))",
            "-frames:v", "1", "-q:v", "3", path,
        ])
    }

    /// Goes through the same processing as an upload, so thumbnails and sizes are real.
    func postPhoto(ownerID: UUID, random: inout SeededRandom) async throws -> PostMedia {
        let config = app.appConfig
        let id = UUID()
        let directory = URL(fileURLWithPath: config.mediaDirectory).appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let portrait = random.next(below: 3) > 0
        try await gradient(width: portrait ? 1080 : 1440, height: portrait ? 1350 : 1080,
                           to: directory.appendingPathComponent("original.jpg").path, random: &random)
        let processed = try await MediaProcessor(ffmpeg: config.ffmpegPath, ffprobe: config.ffprobePath)
            .processImage(in: directory, originalFile: "original.jpg")
        let media = PostMedia(id: id, ownerID: ownerID, kind: .image, processed: processed)
        try await media.create(on: app.db)
        return media
    }

    func avatar(for user: User, random: inout SeededRandom) async throws {
        let directory = "\(app.appConfig.mediaDirectory)/avatars/\(try user.requireID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try await gradient(width: 512, height: 512, to: "\(directory)/avatar.jpg", random: &random)
        user.avatarFile = "avatar.jpg"
        try await user.save(on: app.db)
    }
}

/// Same demo data on every run (SplitMix64).
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next(below bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(max(bound, 1)))
    }

    /// A bright, saturated colour as ffmpeg's `0xRRGGBB`.
    mutating func color() -> String {
        let hue = Double(next(below: 360)) / 60
        let x = 1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1)
        let (r, g, b): (Double, Double, Double) = switch Int(hue) {
        case 0: (1, x, 0)
        case 1: (x, 1, 0)
        case 2: (0, 1, x)
        case 3: (0, x, 1)
        case 4: (x, 0, 1)
        default: (1, 0, x)
        }
        let channel = { (value: Double) in Int(55 + value * 200) }
        return String(format: "0x%02X%02X%02X", channel(r), channel(g), channel(b))
    }
}
