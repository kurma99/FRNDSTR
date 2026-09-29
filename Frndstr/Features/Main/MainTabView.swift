import FrndstrAPI
import SwiftUI

/// Signed-in shell: Home, New Post (opens a sheet like Instagram) and Profile.
struct MainTabView: View {
    enum AppTab: Hashable {
        case home, moments, create, profile
    }

    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: AppTab = .home
    @State private var feed = FeedModel()
    @State private var friends = FriendsModel()
    @State private var moments = MomentsModel()
    @State private var showComposer = false
    @State private var routedPost: PostDTO?
    @State private var showFriendsSheet = false

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                FeedView(model: feed, friends: friends) { showComposer = true }
            }

            Tab("Moments", systemImage: "camera.aperture", value: AppTab.moments) {
                MomentsView(model: moments, friends: friends)
            }
            .badge(moments.unseenCount)

            Tab("New Post", systemImage: "plus.app", value: AppTab.create) {
                Color.clear
            }

            Tab("Profile", systemImage: "person.crop.circle", value: AppTab.profile) {
                NavigationStack {
                    if let user = app.currentUser {
                        ProfileView(user: user)
                            .frndstrDestinations()
                    }
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // Profiles (in every tab) show the person's live moments from here.
        .environment(moments)
        .onChange(of: selection) { oldValue, newValue in
            // The create tab is an action, not a destination.
            if newValue == .create {
                selection = oldValue
                showComposer = true
            }
        }
        .sheet(isPresented: $showComposer) {
            ComposeView { post in
                feed.insert(post)
                selection = .home
            }
        }
        .sheet(item: $routedPost) { post in
            NavigationStack {
                PostDetailView(post: post)
                    .frndstrDestinations()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close", systemImage: "xmark") { routedPost = nil }
                        }
                    }
            }
        }
        .sheet(isPresented: $showFriendsSheet) {
            NavigationStack {
                FriendsView(model: friends)
                    .frndstrDestinations()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close", systemImage: "xmark") { showFriendsSheet = false }
                        }
                    }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back to the app: show what happened meanwhile.
            guard phase == .active else { return }
            Task {
                async let posts: Void = feed.refresh(using: app)
                async let momentFeed: Void = moments.refresh(using: app)
                async let people: Void = friends.refresh(using: app)
                _ = await (posts, momentFeed, people)
            }
        }
        .onChange(of: app.pendingRoute) { _, route in
            if let route { open(route) }
        }
        .task {
            await app.refreshCurrentUser()
            await app.refreshConfig()
            await moments.refresh(using: app)
            await Notifier.shared.requestAuthorizationIfNeeded()
            await Notifier.shared.sync(using: app)
            if let route = app.pendingRoute { open(route) }
        }
    }

    /// Handles a tapped notification.
    private func open(_ route: NotificationRoute) {
        app.pendingRoute = nil
        switch route {
        case .moments:
            selection = .moments
            Task { await moments.refresh(using: app) }
        case .friends:
            showFriendsSheet = true
        case let .post(id):
            selection = .home
            Task { routedPost = try? await app.client?.post(id) }
        }
    }
}
