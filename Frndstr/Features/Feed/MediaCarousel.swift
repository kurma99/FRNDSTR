import FrndstrAPI
import SwiftUI

/// Swipeable photos/videos of a post. Uses the first item's aspect ratio,
/// clamped like Instagram between 3:4 portrait (moment composites) and 1.91:1 landscape.
/// Tap to see them uncropped in `MediaViewer`.
struct MediaCarousel: View {
    let media: [MediaDTO]

    @Environment(AppModel.self) private var app
    @State private var selection: UUID?
    @State private var isVisible = false
    @State private var viewer: ViewerStart?

    private struct ViewerStart: Identifiable {
        let id: UUID
    }

    private var aspectRatio: CGFloat {
        CGFloat(min(max(media.first?.aspectRatio ?? 1, 0.75), 1.91))
    }

    private var selectedIndex: Int {
        media.firstIndex { $0.id == selection } ?? 0
    }

    var body: some View {
        VStack(spacing: 8) {
            Color.clear
                .aspectRatio(aspectRatio, contentMode: .fit)
                .overlay { pages }
                .clipped()
                .overlay(alignment: .topTrailing) {
                    if media.count > 1 {
                        Text(verbatim: "\(selectedIndex + 1)/\(media.count)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .glassEffect(.regular, in: .capsule)
                            .padding(12)
                    }
                }
                .onScrollVisibilityChange(threshold: 0.6) { isVisible = $0 }
                .fullScreenCover(item: $viewer) { start in
                    MediaViewer(media: media, startID: start.id) { shown in
                        if media.count > 1, let shown { selection = shown }
                    }
                }

            if media.count > 1 {
                PageDots(count: media.count, selected: selectedIndex)
            }
        }
    }

    @ViewBuilder
    private var pages: some View {
        if media.count == 1, let item = media.first {
            page(for: item)
        } else {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(media) { item in
                        page(for: item)
                            .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $selection)
        }
    }

    private func page(for item: MediaDTO) -> some View {
        content(for: item)
            .contentShape(.rect)
            .onTapGesture { viewer = ViewerStart(id: item.id) }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Shows it full screen, uncropped")
    }

    @ViewBuilder
    private func content(for item: MediaDTO) -> some View {
        switch item.kind {
        case .image:
            RemoteImage(path: item.displayPath)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Photo")
                .accessibilityAddTraits(.isImage)
        case .video:
            if let client = app.client {
                LoopingVideoView(url: client.tokenizedMediaURL(item.displayPath),
                                 isActive: isVisible && (selection ?? media.first?.id) == item.id)
            }
        }
    }
}

private struct PageDots: View {
    let count: Int
    let selected: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == selected ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(.quaternary))
                    .frame(width: 6, height: 6)
            }
        }
        .animation(.snappy, value: selected)
        .accessibilityHidden(true)
    }
}
