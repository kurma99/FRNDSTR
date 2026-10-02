import Foundation
import FrndstrAPI

/// Keeps a private copy of your Memories on your own server, so a new iPhone, a reinstall
/// or a changed app ID brings them back instead of losing them. Only you can see the copy.
///
/// Sync is two-way by ID: memories only on this iPhone are uploaded, memories only on the
/// server are downloaded. Deletions are sent right away and retried until the server confirms.
final class MemoryBackup {
    static let shared = MemoryBackup()

    static let enabledKey = "memories.backupToServer"
    private static let pendingDeletesKey = "memories.pendingServerDeletes"
    /// Automatic syncs (on refresh) at most this often; opening Memories always syncs.
    private static let minimumInterval: TimeInterval = 10 * 60

    /// On unless turned off in Settings.
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private var running: Task<Int, Never>?
    private var lastSync: Date?

    /// Returns how many memories were restored from the server (so the caller can reload).
    @discardableResult
    func sync(using app: AppModel, force: Bool = false) async -> Int {
        if let running { return await running.value }
        if !force, let lastSync, Date.now.timeIntervalSince(lastSync) < Self.minimumInterval { return 0 }
        guard Self.isEnabled, let client = app.client, let me = app.currentUser else { return 0 }

        let task = Task { await Self.run(client: client, archive: MomentArchive.forUser(me.id)) }
        running = task
        let restored = await task.value
        running = nil
        lastSync = .now
        return restored
    }

    /// Removes a memory from the server too (even with backup turned off, so nothing lingers there).
    func delete(_ id: UUID, using app: AppModel) {
        Self.pendingDeletes.insert(id)
        guard let client = app.client else { return }
        Task { await Self.flushDeletes(client: client) }
    }

    // MARK: Work

    private static func run(client: APIClient, archive: MomentArchive) async -> Int {
        await flushDeletes(client: client)
        guard let remote = try? await client.memories() else { return 0 }
        let pending = pendingDeletes
        let remoteIDs = Set(remote.map(\.id))
        let local = archive.all()
        let localIDs = Set(local.map(\.id))

        // Up: memories only this iPhone has (new ones, and everything from before the backup existed).
        for memory in local where !remoteIDs.contains(memory.id) && !pending.contains(memory.id) {
            guard let files = try? archive.files(for: memory.id) else { continue }
            do {
                try await client.uploadMemory(MemoryDTO(memory), back: files.back, front: files.front,
                                              composite: files.composite, thumbnail: files.thumbnail)
            } catch is CancellationError {
                return 0
            } catch {
                continue
            }
        }

        // Down: memories this iPhone is missing (new phone, reinstall).
        var restored = 0
        for memory in remote where !localIDs.contains(memory.id) && !pending.contains(memory.id) {
            do {
                async let back = client.memoryFile(memory.id, "back")
                async let front = client.memoryFile(memory.id, "front")
                async let composite = client.memoryFile(memory.id, "composite")
                try archive.save(ArchivedMoment(memory), back: try await back, front: try await front,
                                 composite: try await composite)
                restored += 1
            } catch is CancellationError {
                break
            } catch {
                continue
            }
        }
        return restored
    }

    private static func flushDeletes(client: APIClient) async {
        for id in pendingDeletes {
            do {
                try await client.deleteMemory(id)
                pendingDeletes.remove(id)
            } catch APIError.server(status: 404, _) {
                pendingDeletes.remove(id)
            } catch {
                // Offline or server down: try again on the next sync.
            }
        }
    }

    private static var pendingDeletes: Set<UUID> {
        get { Set((UserDefaults.standard.stringArray(forKey: pendingDeletesKey) ?? []).compactMap(UUID.init(uuidString:))) }
        set { UserDefaults.standard.set(newValue.map(\.uuidString), forKey: pendingDeletesKey) }
    }
}

extension MemoryDTO {
    init(_ memory: ArchivedMoment) {
        self.init(id: memory.id, takenAt: memory.createdAt, caption: memory.caption,
                  recipientNames: memory.recipientNames, layout: memory.layout, location: memory.location)
    }
}

extension ArchivedMoment {
    init(_ memory: MemoryDTO) {
        self.init(id: memory.id, createdAt: memory.takenAt, caption: memory.caption,
                  recipientNames: memory.recipientNames, layout: memory.layout, location: memory.location)
    }
}
