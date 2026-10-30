import Foundation
import FrndstrAPI
import Network
import Observation

/// One moment waiting to be sent. Its `id` is also the moment's ID on the server and in Memories,
/// so sending it twice (a lost response, two triggers at once) never makes a copy.
nonisolated struct OutboxEntry: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var takenAt: Date
    var caption: String?
    var layout: MomentLayout
    /// Whoever is a friend when it arrives; `recipientIDs` is then only for older servers.
    var allFriends: Bool
    var recipientIDs: [UUID]
    var recipientNames: [String]
    var location: PostLocation?
    var shareAsPost: Bool
    /// Post photos already uploaded by an earlier attempt, and when (the server drops unused ones after a day).
    var postMediaIDs: [UUID]?
    var postMediaUploadedAt: Date?
    /// Set when the server refused it (not a connection problem). It stays until discarded.
    var failure: String?
}

/// Outbox entries on disk: `<root>/<id>/entry.json`, `back.jpg`, `front.jpg`.
nonisolated struct OutboxStore: Sendable {
    let root: URL

    static func forUser(_ userID: UUID) -> OutboxStore {
        OutboxStore(root: URL.applicationSupportDirectory
            .appending(path: "Outbox", directoryHint: .isDirectory)
            .appending(path: userID.uuidString, directoryHint: .isDirectory))
    }

    func photoURL(for id: UUID, _ name: String) -> URL {
        root.appending(path: id.uuidString).appending(path: "\(name).jpg")
    }

    func save(_ entry: OutboxEntry, back: Data, front: Data) throws {
        let folder = root.appending(path: entry.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try back.write(to: photoURL(for: entry.id, "back"))
        try front.write(to: photoURL(for: entry.id, "front"))
        try update(entry)
    }

    /// Rewrites just the details (the photos don't change).
    func update(_ entry: OutboxEntry) throws {
        try API.makeEncoder().encode(entry)
            .write(to: root.appending(path: entry.id.uuidString).appending(path: "entry.json"), options: .atomic)
    }

    /// Oldest first, so they arrive in the order they were taken.
    func all() -> [OutboxEntry] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders
            .compactMap { try? Data(contentsOf: $0.appending(path: "entry.json")) }
            .compactMap { try? API.makeDecoder().decode(OutboxEntry.self, from: $0) }
            .sorted { $0.takenAt < $1.takenAt }
    }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: root.appending(path: id.uuidString, directoryHint: .isDirectory))
    }

    /// No connection, server down or a proxy in the way: try again later. Anything else the server
    /// said no to won't get better by retrying.
    static func isWorthRetrying(_ error: Error) -> Bool {
        switch error {
        case is CancellationError, APIError.transport, APIError.cloudflareAccessDenied,
             APIError.notFrndstr, APIError.invalidResponse, APIError.unauthorized:
            true
        case let APIError.server(status, _):
            status >= 500 || status == 408 || status == 429
        default:
            true
        }
    }
}

/// Moments that couldn't be sent yet. They're sent, oldest first, as soon as the server answers:
/// when the connection comes back while the app is open, when it's opened, or in a background refresh.
@Observable
final class MomentOutbox {
    static let shared = MomentOutbox()

    /// The signed-in person's waiting moments, oldest first.
    private(set) var entries: [OutboxEntry] = []

    @ObservationIgnored private var userID: UUID?
    @ObservationIgnored private var inFlight: Set<UUID> = []
    @ObservationIgnored private var flushing: Task<Void, Never>?
    @ObservationIgnored private var monitor: NWPathMonitor?

    private var store: OutboxStore? { userID.map(OutboxStore.forUser) }

    /// Loads the waiting moments of whoever is signed in (call on launch and after signing in).
    func load(for userID: UUID?) {
        self.userID = userID
        entries = store?.all() ?? []
    }

    func photoURL(for id: UUID, _ name: String) -> URL? { store?.photoURL(for: id, name) }

    func enqueue(_ entry: OutboxEntry, back: Data, front: Data, for userID: UUID) throws {
        if self.userID != userID { load(for: userID) }
        try OutboxStore.forUser(userID).save(entry, back: back, front: front)
        entries = store?.all() ?? []
    }

    /// Gives up on a moment the server refused. It stays in Memories.
    func discard(_ id: UUID) {
        store?.remove(id)
        entries.removeAll { $0.id == id }
    }

    /// Sends one moment right away. `true` once it arrived, `false` if it has to wait for a connection.
    /// If the server refuses it, it's taken out of the outbox again and the error is thrown, so the
    /// send screen can show it.
    func sendNow(_ id: UUID, using app: AppModel) async throws -> Bool {
        await flushing?.value
        guard let entry = entries.first(where: { $0.id == id }) else { return true }
        do {
            try await send(entry, using: app)
            return true
        } catch let error where OutboxStore.isWorthRetrying(error) {
            return false
        } catch {
            discard(id)
            throw error
        }
    }

    /// Tries everything that's waiting. Safe to call often; concurrent calls share one run.
    func flush(using app: AppModel) async {
        if let flushing { return await flushing.value }
        guard app.phase == .signedIn, entries.contains(where: { $0.failure == nil }) else { return }
        let run = Task {
            var sentAny = false
            for entry in entries where entry.failure == nil {
                do {
                    try await send(entry, using: app)
                    sentAny = true
                } catch let error where OutboxStore.isWorthRetrying(error) {
                    break   // still offline: the rest would fail the same way
                } catch {
                    var refused = entry
                    refused.failure = error.localizedDescription
                    try? store?.update(refused)
                    entries = store?.all() ?? []
                }
            }
            if sentAny { await Self.afterSending(using: app) }
        }
        flushing = run
        await run.value
        flushing = nil
    }

    /// Flushes whenever the connection comes back while the app is running.
    func startWatchingConnection(using app: AppModel) {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak app] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let app else { return }
                await MomentOutbox.shared.flush(using: app)
            }
        }
        monitor.start(queue: DispatchQueue(label: "cloud.mallwitz.frndstr.outbox"))
        self.monitor = monitor
    }

    // MARK: Sending

    private func send(_ entry: OutboxEntry, using app: AppModel) async throws {
        guard let client = app.client, let store, !inFlight.contains(entry.id) else { throw CancellationError() }
        inFlight.insert(entry.id)
        defer { inFlight.remove(entry.id) }
        var entry = entry

        do {
            // Taken offline: the place name and its time zone need the internet, so they're added now.
            if let location = entry.location, location.placeName == nil || location.timeZone == nil {
                entry.location = await LocationProvider.named(location)
            }

            var postMediaIDs: [UUID] = []
            if entry.shareAsPost {
                let fresh = entry.postMediaUploadedAt.map { Date.now.timeIntervalSince($0) < 12 * 3600 } ?? false
                if fresh, let uploaded = entry.postMediaIDs, !uploaded.isEmpty {
                    postMediaIDs = uploaded
                } else {
                    // The post gets both photos uncropped: the big one first, then the small one.
                    let order = entry.layout.swapped ? ["front", "back"] : ["back", "front"]
                    for name in order {
                        postMediaIDs.append(try await client.uploadMedia(fileURL: store.photoURL(for: entry.id, name),
                                                                         contentType: "image/jpeg").id)
                    }
                    entry.postMediaIDs = postMediaIDs
                    entry.postMediaUploadedAt = .now
                    try? store.update(entry)
                }
            }

            let back = try Data(contentsOf: store.photoURL(for: entry.id, "back"))
            let front = try Data(contentsOf: store.photoURL(for: entry.id, "front"))
            _ = try await client.sendMoment(back: back, front: front, request: CreateMomentRequest(
                caption: entry.caption, recipientIDs: entry.recipientIDs, layout: entry.layout,
                postMediaIDs: postMediaIDs.isEmpty ? nil : postMediaIDs, location: entry.location,
                clientID: entry.id, takenAt: entry.takenAt, allFriends: entry.allFriends ? true : nil))
        } catch {
            app.handle(error)
            throw error
        }
        store.remove(entry.id)
        entries.removeAll { $0.id == entry.id }
    }

    /// What a sent moment changes: the feed, the Memories backup, streak reminders.
    private static func afterSending(using app: AppModel) async {
        Task { await MemoryBackup.shared.sync(using: app, force: true) }
        await Notifier.shared.sync(using: app)
    }
}
