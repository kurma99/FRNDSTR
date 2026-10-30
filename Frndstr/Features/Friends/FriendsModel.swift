import Foundation
import FrndstrAPI
import Observation

/// Friends, pending requests and everyone else on the server.
@Observable
final class FriendsModel {
    private(set) var overview = FriendsOverview(friends: [], incoming: [], outgoing: [])
    private(set) var everyone: [UserDTO] = []
    /// Streaks by friend ID.
    private(set) var streaks: [UUID: StreakDTO] = [:]
    private(set) var hasLoaded = false
    var errorMessage: String?

    var incomingCount: Int { overview.incoming.count }

    /// Family members who aren't friends and have no pending request either way.
    func others(excluding me: UUID?) -> [UserDTO] {
        let connected = Set((overview.friends + overview.incoming + overview.outgoing).map(\.id))
        return everyone.filter { $0.id != me && !connected.contains($0.id) }
    }

    func status(of userID: UUID) -> FriendshipStatus {
        if overview.friends.contains(where: { $0.id == userID }) { return .friends }
        if overview.incoming.contains(where: { $0.id == userID }) { return .incoming }
        if overview.outgoing.contains(where: { $0.id == userID }) { return .outgoing }
        return .none
    }

    func refresh(using app: AppModel) async {
        guard let client = app.client else { return }
        // Offline, the last list stands in, so a moment can still be addressed and queued.
        if !hasLoaded, let me = app.currentUser, let cached = Self.cachedOverview(for: me.id) {
            overview = cached
        }
        do {
            async let overview = client.friends()
            async let everyone = client.users()
            (self.overview, self.everyone) = try await (overview, everyone)
            if let me = app.currentUser { Self.cache(self.overview, for: me.id) }
            let streakList = (try? await client.streaks()) ?? []
            streaks = Dictionary(uniqueKeysWithValues: streakList.map { ($0.friend.id, $0) })
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            app.handle(error)
            errorMessage = error.localizedDescription
        }
        hasLoaded = true
    }

    /// Request, or accept if they already asked.
    func add(_ user: UserDTO, using app: AppModel) async {
        await mutate(using: app) { try await $0.addFriend(user.id) }
    }

    /// Cancel, decline or unfriend.
    func remove(_ user: UserDTO, using app: AppModel) async {
        await mutate(using: app) { try await $0.removeFriend(user.id) }
    }

    private static func cacheKey(for userID: UUID) -> String { "friends.overview.\(userID.uuidString)" }

    private static func cachedOverview(for userID: UUID) -> FriendsOverview? {
        UserDefaults.standard.data(forKey: cacheKey(for: userID))
            .flatMap { try? API.makeDecoder().decode(FriendsOverview.self, from: $0) }
    }

    private static func cache(_ overview: FriendsOverview, for userID: UUID) {
        UserDefaults.standard.set(try? API.makeEncoder().encode(overview), forKey: cacheKey(for: userID))
    }

    private func mutate(using app: AppModel, _ work: (APIClient) async throws -> ProfileDTO) async {
        guard let client = app.client else { return }
        do {
            _ = try await work(client)
            overview = try await client.friends()
        } catch {
            app.handle(error)
            errorMessage = error.localizedDescription
        }
    }
}
