import FRNDSAPI
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

extension View {
    /// Register once at the root of each NavigationStack.
    func frndsDestinations() -> some View {
        navigationDestination(for: UserDTO.self) { user in
            ProfileView(user: user)
        }
        .navigationDestination(for: PostDTO.self) { post in
            PostDetailView(post: post)
        }
    }
}
