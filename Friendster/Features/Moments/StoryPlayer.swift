import FriendsterAPI
import SwiftUI
import UIKit

/// Full-screen, story-style player shared by Memories, live moments on a profile and highlights.
/// Each item is shown for `secondsPerItem`, then the next one follows; after the last it closes.
/// Tap the right side or swipe left for the next item, tap the left side or swipe right for the
/// previous one, swipe down to close, touch and hold to pause.
struct StoryPlayer<Item: Identifiable, Content: View, Header: View>: View {
    let items: [Item]
    var secondsPerItem: Double = 3
    /// Called whenever an item comes on screen (e.g. to mark a moment as viewed).
    var onShow: (Item) -> Void = { _ in }
    @ViewBuilder var content: (Item) -> Content
    @ViewBuilder var header: (Item) -> Header

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var progress: Double = 0
    @State private var isPaused = false
    /// Bumped to restart the timer when "previous" is used on the first item.
    @State private var restartToken = 0
    @State private var width: CGFloat = 0

    init(items: [Item], startIndex: Int = 0, secondsPerItem: Double = 3, onShow: @escaping (Item) -> Void = { _ in },
         @ViewBuilder content: @escaping (Item) -> Content, @ViewBuilder header: @escaping (Item) -> Header) {
        self.items = items
        self.secondsPerItem = secondsPerItem
        self.onShow = onShow
        self.content = content
        self.header = header
        _index = State(initialValue: min(max(startIndex, 0), max(items.count - 1, 0)))
    }

    private var current: Item? { items.indices.contains(index) ? items[index] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let current {
                content(current)
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 24))
                    .padding(.horizontal, 12)
                    .id(current.id)
                    .transition(.opacity)
                    // Taps and swipes belong to the player, not to the photo.
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) { headerBar }
        .overlay(alignment: .bottom) {
            SegmentedProgressBar(count: items.count, index: index, progress: progress)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .contentShape(.rect)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // Left third goes back (like Instagram stories), the rest goes forward.
        .onTapGesture { location in
            if location.x < width / 3 { previous() } else { next() }
        }
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.width < -40 { next() }
                    else if value.translation.width > 40 { previous() }
                    else if value.translation.height > 120 { dismiss() }
                }
        )
        .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 20) {} onPressingChanged: { isPaused = $0 }
        .accessibilityAction(named: "Next") { next() }
        .accessibilityAction(named: "Previous") { previous() }
        .task(id: "\(index)-\(restartToken)") {
            if let current { onShow(current) }
            await runTimer()
        }
        .statusBarHidden()
    }

    private var headerBar: some View {
        HStack(alignment: .top) {
            if let current {
                header(current)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4)
            }
            Spacer()
            Button("Close", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityIdentifier("closePlayerButton")
        }
        .padding(16)
    }

    /// Fills the current segment over `secondsPerItem`, then advances.
    private func runTimer() async {
        progress = 0
        let step = 0.03
        while progress < 1 {
            try? await Task.sleep(for: .seconds(step))
            if Task.isCancelled { return }
            if !isPaused { progress = min(1, progress + step / secondsPerItem) }
        }
        next()
    }

    private func next() {
        if index < items.count - 1 {
            withAnimation(.easeInOut(duration: 0.2)) { index += 1 }
        } else {
            dismiss()
        }
    }

    private func previous() {
        if index > 0 {
            withAnimation(.easeInOut(duration: 0.2)) { index -= 1 }
        } else {
            restartToken += 1
        }
    }
}

/// One capsule per item: finished ones full, the current one filling, upcoming ones empty.
struct SegmentedProgressBar: View {
    let count: Int
    let index: Int
    let progress: Double

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { segment in
                Capsule()
                    .fill(.white.opacity(0.3))
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(.white)
                                .frame(width: proxy.size.width * fill(for: segment))
                        }
                    }
                    .frame(height: 3)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Moment \(index + 1) of \(count)")
        .accessibilityIdentifier("playerProgress")
    }

    func fill(for segment: Int) -> Double {
        if segment < index { return 1 }
        if segment == index { return progress }
        return 0
    }
}

/// Date, time and caption shown at the top of the player.
struct StoryHeader: View {
    let date: Date
    var title: String?
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title {
                Text(title).font(.headline)
                Text(date, format: .relative(presentation: .named))
                    .font(.subheadline)
                    .opacity(0.8)
            } else {
                Text(date, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.headline)
                Text(date, format: .dateTime.hour().minute())
                    .font(.subheadline)
                    .opacity(0.8)
            }
            if let caption {
                Text(caption).font(.subheadline).padding(.top, 2)
            }
        }
    }
}

/// Someone's moments that haven't expired yet, played story style (opened from their profile avatar).
/// Locked moments stay locked; opened ones count as viewed and screenshots are reported to the sender.
struct LiveMomentsPlayer: View {
    let moments: [MomentDTO]
    let model: MomentsModel

    @Environment(AppModel.self) private var app
    @State private var shownID: UUID?

    var body: some View {
        StoryPlayer(items: moments, secondsPerItem: 5, onShow: { moment in
            shownID = moment.id
            model.markViewed(moment, using: app)
        }) { moment in
            if moment.isLocked {
                LockedMomentPlaceholder(senderName: moment.sender.displayName)
            } else if let back = moment.backPath, let front = moment.frontPath {
                MomentPhotos(source: .remote(back: back, front: front), layout: moment.layout)
            }
        } header: { moment in
            StoryHeader(date: moment.createdAt, title: moment.sender.displayName,
                        caption: moment.isLocked ? nil : moment.caption)
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: UIApplication.userDidTakeScreenshotNotification) {
                guard let shownID, let moment = moments.first(where: { $0.id == shownID }),
                      !moment.isLocked, moment.sender.id != app.currentUser?.id
                else { continue }
                model.reportScreenshot(of: [shownID], using: app)
            }
        }
    }
}
