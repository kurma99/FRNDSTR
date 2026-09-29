import FrndstrAPI
import SwiftUI

/// Instagram-style profile: avatar, counts, friend/edit button and a 3-column grid of posts.
struct ProfileView: View {
    let user: UserDTO

    @Environment(AppModel.self) private var app
    @Environment(MomentsModel.self) private var moments
    @State private var model: FeedModel
    @State private var profile: ProfileDTO?
    @State private var friends = FriendsModel()
    @State private var showEditProfile = false
    @State private var showLiveMoments = false
    @State private var highlights: [HighlightDTO] = []
    @State private var playingHighlight: HighlightDTO?
    @State private var editingHighlight: HighlightEditTarget?
    @State private var errorMessage: String?

    init(user: UserDTO) {
        self.user = user
        _model = State(initialValue: FeedModel(authorID: user.id))
    }

    private var isCurrentUser: Bool { app.currentUser?.id == user.id }
    /// The freshest copy of the user (own profile follows edits immediately).
    private var shownUser: UserDTO { isCurrentUser ? (app.currentUser ?? user) : (profile?.user ?? user) }
    /// This person's moments that haven't expired yet: your own sent ones, or the ones they sent you.
    private var liveMoments: [MomentDTO] {
        let list = isCurrentUser ? moments.sent : moments.received.filter { $0.sender.id == user.id }
        return list.sorted { $0.createdAt > $1.createdAt }
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                actionButtons
                    .padding(.horizontal, 16)

                if isCurrentUser || !highlights.isEmpty {
                    HighlightsRow(highlights: highlights, isOwner: isCurrentUser) { highlight in
                        playingHighlight = highlight
                    } onNew: {
                        editingHighlight = HighlightEditTarget(highlight: nil)
                    } onEdit: { highlight in
                        editingHighlight = HighlightEditTarget(highlight: highlight)
                    }
                }

                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(model.posts) { post in
                        NavigationLink(value: post) {
                            GridTile(post: post)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(post.caption ?? String(localized: "Post"))
                        .accessibilityValue(Text("^[\(post.media.count) item](inflect: true)"))
                    }
                    if model.canLoadMore {
                        ProgressView()
                            .task { await model.loadMore(using: app) }
                    }
                }

                if model.hasLoaded && model.posts.isEmpty {
                    ContentUnavailableView("No posts yet", systemImage: "camera",
                                           description: Text(isCurrentUser ? "Your posts will appear here." : "\(shownUser.displayName) hasn't posted yet."))
                }
            }
        }
        .navigationTitle(shownUser.username)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .onAppear { Task { await reload() } }
        .toolbar {
            if isCurrentUser {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("settingsButton")
                }
            }
        }
        .sheet(isPresented: $showEditProfile) {
            EditProfileView()
        }
        .fullScreenCover(isPresented: $showLiveMoments) {
            LiveMomentsPlayer(moments: liveMoments, model: moments)
        }
        .fullScreenCover(item: $playingHighlight) { highlight in
            HighlightPlayer(highlight: highlight)
        }
        .sheet(item: $editingHighlight) { target in
            HighlightEditorView(highlight: target.highlight) { saved in
                if let saved {
                    // Edited ones stay in place; new ones go first (newest first, like the server).
                    if let index = highlights.firstIndex(where: { $0.id == saved.id }) {
                        highlights[index] = saved
                    } else {
                        highlights.insert(saved, at: 0)
                    }
                } else if let deleted = target.highlight {
                    highlights.removeAll { $0.id == deleted.id }
                }
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 20) {
                avatar
                HStack(spacing: 0) {
                    stat(profile?.postCount ?? model.posts.count, label: "posts")
                    if isCurrentUser {
                        NavigationLink {
                            FriendsView(model: friends)
                        } label: {
                            stat(profile?.friendCount ?? 0, label: "friends")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("friendsCount")
                    } else {
                        stat(profile?.friendCount ?? 0, label: "friends")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(shownUser.displayName)
                    .font(.headline)
                Text(verbatim: "@\(shownUser.username)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// Like Instagram stories: a thick ring means there are live moments; tap to watch them.
    @ViewBuilder
    private var avatar: some View {
        if liveMoments.isEmpty {
            AvatarView(user: shownUser, size: 88)
        } else {
            Button { showLiveMoments = true } label: {
                AvatarView(user: shownUser, size: 80, showsRing: false)
                    .padding(5)
                    .overlay { Circle().strokeBorder(Theme.brandGradient, lineWidth: 3.5) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(shownUser.displayName)'s moments")
            .accessibilityHint("^[\(liveMoments.count) moment](inflect: true) from the last 24 hours")
            .accessibilityIdentifier("liveMomentsAvatar")
        }
    }

    private func stat(_ value: Int, label: LocalizedStringKey) -> some View {
        VStack(spacing: 2) {
            Text(value, format: .number).font(.headline)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Buttons

    @ViewBuilder
    private var actionButtons: some View {
        if isCurrentUser {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button { showEditProfile = true } label: {
                        Text("Edit profile").frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("editProfileButton")
                    NavigationLink {
                        FriendsView(model: friends)
                    } label: {
                        Label("Friends", systemImage: "person.2")
                            .frame(maxWidth: .infinity)
                    }
                    .overlay(alignment: .topTrailing) { RequestBadge(count: friends.incomingCount) }
                    .accessibilityIdentifier("friendsButton")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        } else if let status = profile?.friendship {
            friendButton(for: status)
        }
    }

    @ViewBuilder
    private func friendButton(for status: FriendshipStatus) -> some View {
        switch status {
        case .none:
            Button { changeFriendship(add: true) } label: {
                Label("Add friend", systemImage: "person.badge.plus").frame(maxWidth: .infinity)
            }
            .primaryButtonStyle()
            .controlSize(.large)
            .accessibilityIdentifier("addFriendButton")
        case .outgoing:
            Button { changeFriendship(add: false) } label: {
                Label("Requested", systemImage: "clock").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .accessibilityHint("Cancels your friend request")
        case .incoming:
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button { changeFriendship(add: true) } label: {
                        Text("Accept request").frame(maxWidth: .infinity)
                    }
                    .primaryButtonStyle()
                    .accessibilityIdentifier("acceptFriendButton")
                    Button { changeFriendship(add: false) } label: {
                        Text("Decline").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
                .controlSize(.large)
            }
        case .friends:
            Menu {
                Button("Remove friend", systemImage: "person.badge.minus", role: .destructive) {
                    changeFriendship(add: false)
                }
            } label: {
                Label("Friends", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .accessibilityIdentifier("friendsMenu")
        case .me:
            EmptyView()
        }
    }

    // MARK: Loading

    private func reload() async {
        guard let client = app.client else { return }
        async let posts: Void = model.refresh(using: app)
        async let requests: Void = isCurrentUser ? friends.refresh(using: app) : ()
        async let live: Void = moments.refresh(using: app)
        async let highlightList = try? client.highlights(of: user.id)
        do {
            profile = try await client.profile(user.id)
        } catch {
            app.handle(error)
        }
        if let list = await highlightList { highlights = list }
        _ = await (posts, requests, live)
    }

    private func changeFriendship(add: Bool) {
        guard let client = app.client else { return }
        Task {
            do {
                profile = add ? try await client.addFriend(user.id) : try await client.removeFriend(user.id)
            } catch {
                app.handle(error)
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Which highlight the editor sheet is for (`nil` = a new one).
struct HighlightEditTarget: Identifiable {
    let id = UUID()
    let highlight: HighlightDTO?
}

/// Small count bubble for pending friend requests.
struct RequestBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(count, format: .number)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.red, in: .capsule)
                .offset(x: 4, y: -4)
                .accessibilityLabel("^[\(count) friend request](inflect: true)")
        }
    }
}

private struct GridTile: View {
    let post: PostDTO

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let first = post.media.first {
                    RemoteImage(path: first.thumbnailPath)
                }
            }
            .clipped()
            .overlay(alignment: .topTrailing) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(6)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
    }

    private var icon: String? {
        if post.media.count > 1 { return "square.fill.on.square.fill" }
        if post.media.first?.kind == .video { return "play.fill" }
        return nil
    }
}
