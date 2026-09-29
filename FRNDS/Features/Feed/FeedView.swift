import FRNDSAPI
import SwiftUI

/// Home tab: everyone's posts, newest first.
struct FeedView: View {
    let model: FeedModel
    let friends: FriendsModel
    var onCreatePost: () -> Void = {}

    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 28) {
                    ForEach(model.posts) { post in
                        PostCardView(post: post, onUpdate: model.update, onDelete: model.remove)
                    }

                    if model.canLoadMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding()
                            .task { await model.loadMore(using: app) }
                    }
                }
                .padding(.vertical, 8)
            }
            .overlay { emptyState }
            .refreshable {
                async let posts: Void = model.refresh(using: app)
                async let requests: Void = friends.refresh(using: app)
                _ = await (posts, requests)
            }
            .task {
                if !model.hasLoaded { await model.refresh(using: app) }
                await friends.refresh(using: app)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Wordmark(size: 30)
                        .fixedSize()
                }
                .sharedBackgroundVisibility(.hidden)

                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        FriendsView(model: friends)
                    } label: {
                        Label("Friends", systemImage: "person.2")
                    }
                    .badge(friends.incomingCount)
                    .accessibilityValue(friends.incomingCount > 0 ? Text("^[\(friends.incomingCount) friend request](inflect: true)") : Text(""))
                    .accessibilityIdentifier("friendsToolbarButton")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New post", systemImage: "plus", action: onCreatePost)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .frndsDestinations()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.posts.isEmpty {
            if !model.hasLoaded, model.errorMessage == nil {
                ProgressView()
            } else if let error = model.errorMessage {
                ContentUnavailableView {
                    Label("Couldn't load the feed", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await model.refresh(using: app) } }
                        .buttonStyle(.glass)
                }
            } else {
                ContentUnavailableView {
                    Label("No posts yet", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Share the first photo with your family.")
                } actions: {
                    Button("New post", systemImage: "plus", action: onCreatePost)
                        .primaryButtonStyle()
                }
            }
        }
    }
}
