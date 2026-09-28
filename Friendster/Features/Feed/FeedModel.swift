import Foundation
import FriendsterAPI
import Observation

/// Paginated list of posts: the whole family feed, or one user's posts when `authorID` is set.
@Observable
final class FeedModel {
    let authorID: UUID?

    private(set) var posts: [PostDTO] = []
    private(set) var nextCursor: String?
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    var errorMessage: String?

    var canLoadMore: Bool { hasLoaded && nextCursor != nil && !isLoading }

    init(authorID: UUID? = nil) {
        self.authorID = authorID
    }

    /// Reloads the first page (pull to refresh).
    func refresh(using app: AppModel) async {
        await load(cursor: nil, using: app)
    }

    func loadMore(using app: AppModel) async {
        guard canLoadMore else { return }
        await load(cursor: nextCursor, using: app)
    }

    /// Shows a freshly created post immediately without refetching.
    func insert(_ post: PostDTO) {
        guard authorID == nil || authorID == post.author.id else { return }
        posts.removeAll { $0.id == post.id }
        posts.insert(post, at: 0)
    }

    /// Applies local changes (reactions, comment counts) to the cached post.
    func update(_ post: PostDTO) {
        if let index = posts.firstIndex(where: { $0.id == post.id }) {
            posts[index] = post
        }
    }

    func remove(_ postID: UUID) {
        posts.removeAll { $0.id == postID }
    }

    private func load(cursor: String?, using app: AppModel) async {
        guard let client = app.client, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let page = try await client.feed(cursor: cursor, author: authorID, limit: authorID == nil ? 10 : 30)
            if cursor == nil {
                posts = page.posts
            } else {
                let known = Set(posts.map(\.id))
                posts += page.posts.filter { !known.contains($0.id) }
            }
            nextCursor = page.nextCursor
            hasLoaded = true
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            app.handle(error)
            errorMessage = error.localizedDescription
        }
    }
}
