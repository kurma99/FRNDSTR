import FrndstrAPI
import SwiftUI

struct PostDetailView: View {
    @State private var post: PostDTO
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    init(post: PostDTO) {
        _post = State(initialValue: post)
    }

    var body: some View {
        ScrollView {
            PostCardView(post: post, onUpdate: { post = $0 }, onDelete: { _ in dismiss() })
                .padding(.vertical, 8)
        }
        .task {
            // Grid tiles may be stale (reactions, comments); fetch the current state.
            if let fresh = try? await app.client?.post(post.id) { post = fresh }
        }
        .navigationTitle("Post")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Opens the friend list. It's a value (not a view link) so profiles opened from the list land on top:
/// mixing view- and value-based links in one stack puts the value screens underneath.
struct FriendsDestination: Hashable {}

extension View {
    /// Register once at the root of each NavigationStack.
    func frndstrDestinations() -> some View {
        navigationDestination(for: UserDTO.self) { user in
            ProfileView(user: user)
        }
        .navigationDestination(for: PostDTO.self) { post in
            PostDetailView(post: post)
        }
        .navigationDestination(for: FriendsDestination.self) { _ in
            FriendsScreen()
        }
    }
}

/// The shared friends model comes from `MainTabView`'s environment.
private struct FriendsScreen: View {
    @Environment(FriendsModel.self) private var friends

    var body: some View {
        FriendsView(model: friends)
    }
}
