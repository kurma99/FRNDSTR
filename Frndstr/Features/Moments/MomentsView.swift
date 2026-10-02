import FrndstrAPI
import SwiftUI
import UIKit

/// Moments tab, Instagram-stories style: a row of live moments (yours first, then friends'),
/// today's status, streaks, then friends' moments (locked until you post) and your own.
/// "+" in the top right takes a new moment.
struct MomentsView: View {
    let model: MomentsModel
    let friends: FriendsModel

    @Environment(AppModel.self) private var app
    @State private var showCapture = false
    /// Whose live moments the story player shows.
    @State private var playing: StoryGroup?
    /// Unlocked received moments currently on screen (for screenshot reports).
    @State private var visibleIDs: Set<UUID> = []
    @State private var isTimeRevealed = false

    /// One person's live moments, newest first.
    struct StoryGroup: Identifiable {
        let user: UserDTO
        let moments: [MomentDTO]
        var id: UUID { user.id }
    }

    private var hasFriends: Bool { !(friends.hasLoaded && friends.overview.friends.isEmpty) }

    /// Friends with moments for you, in the order of their newest one.
    private var friendGroups: [StoryGroup] {
        var order: [UUID] = []
        var byUser: [UUID: [MomentDTO]] = [:]
        for moment in model.received.sorted(by: { $0.createdAt > $1.createdAt }) {
            if byUser[moment.sender.id] == nil { order.append(moment.sender.id) }
            byUser[moment.sender.id, default: []].append(moment)
        }
        return order.compactMap { id in
            byUser[id].flatMap { list in list.first.map { StoryGroup(user: $0.sender, moments: list) } }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    storiesRow
                    statusCard
                    if model.streaks.contains(where: { $0.count > 0 }) { streakSection }
                    receivedSection
                    if !model.sent.isEmpty { sentSection }
                }
                .padding(.vertical, 12)
            }
            // Same header as Home: the title in the wordmark's script, top left. The plain title
            // stays for back buttons ("< Moments") but isn't drawn in the bar.
            .navigationTitle("Moments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Wordmark(text: String(localized: "Moments"), size: 30)
                        .fixedSize()
                }
                .sharedBackgroundVisibility(.hidden)

                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        MemoriesView()
                    } label: {
                        Label("Memories", systemImage: "clock.arrow.circlepath")
                    }
                    .accessibilityIdentifier("memoriesButton")
                }
                // Same grouped glass pair as Home (Friends + New post).
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New moment", systemImage: "plus") { showCapture = true }
                        .accessibilityIdentifier("newMomentButton")
                }
            }
            .refreshable { await model.refresh(using: app) }
            .task {
                await model.refresh(using: app)
                await friends.refresh(using: app)
            }
            .task {
                // iOS can't prevent screenshots; tell the sender instead.
                for await _ in NotificationCenter.default.notifications(named: UIApplication.userDidTakeScreenshotNotification) {
                    model.reportScreenshot(of: visibleIDs, using: app)
                }
            }
            .fullScreenCover(isPresented: $showCapture) {
                MomentFlowView(model: model, friends: friends)
            }
            .fullScreenCover(item: $playing) { group in
                LiveMomentsPlayer(moments: group.moments, model: model)
            }
            .frndstrDestinations()
        }
    }

    // MARK: Stories

    private var storiesRow: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                if let me = app.currentUser {
                    StoryBubble(user: me, title: String(localized: "Your moment"),
                                state: model.sent.isEmpty ? .empty : .seen, showsAdd: true) {
                        if model.sent.isEmpty {
                            showCapture = true
                        } else {
                            playing = StoryGroup(user: me, moments: model.sent.sorted { $0.createdAt > $1.createdAt })
                        }
                    }
                    .accessibilityIdentifier("ownStoryBubble")
                }
                ForEach(friendGroups) { group in
                    StoryBubble(user: group.user, title: group.user.displayName, state: state(of: group)) {
                        playing = group
                    }
                    .accessibilityIdentifier("friendStoryBubble")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    private func state(of group: StoryGroup) -> StoryBubble.RingState {
        if group.moments.allSatisfy(\.isLocked) { return .locked }
        return group.moments.contains { !$0.isLocked && !model.isViewed($0.id) } ? .unseen : .seen
    }

    // MARK: Sections

    /// The shared moment time stays blurred (it's meant to be a surprise) until tapped.
    private func momentTimeLabel(_ time: Date) -> some View {
        let formatted = time.formatted(date: .omitted, time: .shortened)
        return Button {
            withAnimation(.smooth) { isTimeRevealed.toggle() }
        } label: {
            Label {
                HStack(spacing: 4) {
                    Text(time > .now ? "Today's moment time:" : "Today's moment time was")
                    Text(formatted)
                        .blur(radius: isTimeRevealed ? 0 : 6)
                    if !isTimeRevealed {
                        Image(systemName: "eye")
                    }
                }
            } icon: {
                Image(systemName: "bell.badge")
            }
            .font(.footnote.weight(.medium))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Replaces the visible text, so VoiceOver can't read the blurred time.
        .accessibilityLabel(isTimeRevealed
                            ? Text(time > .now ? "Today's moment time: \(formatted)" : "Today's moment time was \(formatted)")
                            : Text("Reveal today's moment time"))
        .accessibilityIdentifier("momentTimeLabel")
    }

    /// Yellow-tinted Liquid Glass card: today's status and the shared moment time.
    private var statusCard: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: model.hasPostedToday ? "checkmark.seal.fill" : "camera.aperture")
                .font(.system(size: 30))
                .foregroundStyle(Theme.onPrimary)
                .frame(width: 52, height: 52)
                .glassEffect(.regular.tint(Theme.primary), in: .circle)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.hasPostedToday ? "You shared your moment today" : "Time for your moment")
                    .font(.headline)
                Text(model.hasPostedToday
                     ? "Tap + to share another whenever you like."
                     : hasFriends ? "Your friends' moments unlock once you share yours."
                                  : "Until you add friends, your moments are just for you.")
                    .font(.subheadline)
                    // Grey is too faint on the yellow glass.
                    .foregroundStyle(.primary.opacity(0.75))
                if let time = model.momentTime {
                    momentTimeLabel(time)
                }
                if !model.hasPostedToday {
                    Button { showCapture = true } label: {
                        Label("Take your moment", systemImage: "camera.fill").font(.headline)
                    }
                    .primaryButtonStyle()
                    .padding(.top, 4)
                    .accessibilityIdentifier("takeMomentButton")
                }
                if !hasFriends {
                    NavigationLink(value: FriendsDestination()) {
                        Label("Add friends", systemImage: "person.badge.plus")
                    }
                    .buttonStyle(.glass)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .glassEffect(.regular.tint(Theme.primary.opacity(0.28)), in: .rect(cornerRadius: 28))
        .padding(.horizontal, 16)
    }

    private var streakSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Streaks").font(.headline).padding(.horizontal, 16)
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(model.streaks.filter { $0.count > 0 }) { streak in
                            VStack(spacing: 6) {
                                AvatarView(user: streak.friend, size: 48)
                                Text(streak.friend.displayName)
                                    .font(.caption)
                                    .lineLimit(1)
                                StreakBadge(streak: streak)
                                if streak.isAtRisk {
                                    Text(streak.sentToday ? "Waiting for them" : "Send today")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            .frame(width: 84)
                            .padding(.vertical, 10)
                            .glassEffect(.regular, in: .rect(cornerRadius: 20))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityIdentifier("streakSection")
    }

    private var sentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Today's moments").font(.headline).padding(.horizontal, 16)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(model.sent) { moment in
                        SentMomentCard(moment: moment)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private var receivedSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("From friends").font(.headline).padding(.horizontal, 16)
            if model.hasLoaded && model.received.isEmpty {
                Text("Nothing yet today. Moments from friends show up here for 24 hours.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
            ForEach(model.received) { moment in
                ReceivedMomentCard(moment: moment)
                    .padding(.horizontal, 16)
                    .onScrollVisibilityChange(threshold: 0.5) { visible in
                        guard !moment.isLocked else { return }
                        if visible {
                            visibleIDs.insert(moment.id)
                            model.markViewed(moment, using: app)
                        } else {
                            visibleIDs.remove(moment.id)
                        }
                    }
            }
        }
    }
}

/// Round avatar with a story ring, like Instagram: gradient = new, grey = seen, lock = post first.
struct StoryBubble: View {
    enum RingState { case unseen, seen, locked, empty }

    let user: UserDTO
    let title: String
    let state: RingState
    var showsAdd = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                AvatarView(user: user, size: 62, showsRing: false)
                    .padding(4)
                    .overlay { ring }
                    .overlay(alignment: .bottomTrailing) {
                        if showsAdd {
                            Image(systemName: "plus")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.onPrimary)
                                .frame(width: 22, height: 22)
                                .glassEffect(.regular.tint(Theme.primary), in: .circle)
                        } else if state == .locked {
                            Image(systemName: "lock.fill")
                                .font(.caption2.weight(.bold))
                                .frame(width: 22, height: 22)
                                .glassEffect(.regular, in: .circle)
                        }
                    }
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(maxWidth: 76)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityState)
    }

    @ViewBuilder
    private var ring: some View {
        switch state {
        case .unseen, .locked:
            Circle().strokeBorder(Theme.brandGradient, lineWidth: 3)
        case .seen:
            Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 1.5)
        case .empty:
            Circle().strokeBorder(.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
        }
    }

    private var accessibilityState: String {
        switch state {
        case .unseen: String(localized: "New moments")
        case .seen: String(localized: "Seen")
        case .locked: String(localized: "Locked until you share yours")
        case .empty: String(localized: "No moment yet, tap to take one")
        }
    }
}

// MARK: - Cards

private struct ReceivedMomentCard: View {
    let moment: MomentDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                NavigationLink(value: moment.sender) {
                    HStack(spacing: 10) {
                        AvatarView(user: moment.sender, size: 36)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(moment.sender.displayName).font(.subheadline.weight(.semibold))
                            Group {
                                if let place = moment.location?.placeName, !moment.isLocked {
                                    Text("\(moment.createdAt, format: .relative(presentation: .named)) · \(place)")
                                } else {
                                    Text(moment.createdAt, format: .relative(presentation: .named))
                                }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                TimeLeftBadge(expiresAt: moment.expiresAt)
            }

            if moment.isLocked {
                LockedMomentPlaceholder(senderName: moment.sender.displayName)
            } else if let back = moment.backPath, let front = moment.frontPath {
                MomentPhotos(source: .remote(back: back, front: front), layout: moment.layout)
            }

            if let caption = moment.caption, !moment.isLocked {
                Text(caption).font(.subheadline)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Stands in for a friend's moment until you've shared your own today.
struct LockedMomentPlaceholder: View {
    let senderName: String

    var body: some View {
        Theme.brandGradient
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay(.ultraThinMaterial)
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "lock.fill").font(.largeTitle)
                    Text("Share your own moment today to unlock this one from \(senderName)")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .foregroundStyle(.primary)
            }
            .clipShape(.rect(cornerRadius: 24))
            .accessibilityIdentifier("lockedMoment")
    }
}

private struct SentMomentCard: View {
    let moment: MomentDTO

    private var recipients: [MomentRecipientDTO] { moment.recipients ?? [] }
    private var viewed: Int { recipients.filter { $0.viewedAt != nil }.count }
    private var screenshotters: [String] { recipients.filter { $0.screenshotAt != nil }.map(\.user.displayName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let back = moment.backPath, let front = moment.frontPath {
                MomentPhotos(source: .remote(back: back, front: front), layout: moment.layout,
                             cornerRadius: 16, insetFraction: 0.34)
                    .frame(width: 150)
            }
            if let caption = moment.caption {
                Text(caption).font(.caption).lineLimit(2)
            }
            if let place = moment.location?.placeName {
                Label(place, systemImage: "mappin")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if recipients.isEmpty {
                Label("Just for you", systemImage: "person.fill")
                    .font(.caption.weight(.medium))
            } else {
                Label("Seen by \(viewed) of \(recipients.count)", systemImage: "eye")
                    .font(.caption.weight(.medium))
            }
            if !screenshotters.isEmpty {
                Label("\(screenshotters.formatted(.list(type: .and))) took a screenshot", systemImage: "camera.viewfinder")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .accessibilityIdentifier("screenshotNotice")
            }
            if moment.becomesPost == true {
                Label("Becomes a post when it's over", systemImage: "square.and.arrow.up.on.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            TimeLeftBadge(expiresAt: moment.expiresAt)
        }
        .frame(width: 150, alignment: .leading)
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

private struct TimeLeftBadge: View {
    let expiresAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let hours = max(0, Int(expiresAt.timeIntervalSince(context.date) / 3600))
            Text(hours >= 1 ? "\(hours)h left" : "<1h left")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
        }
    }
}
