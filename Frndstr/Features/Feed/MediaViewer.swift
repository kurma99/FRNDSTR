import FrndstrAPI
import SwiftUI

/// Full-screen, uncropped view of a post's photos and videos (the feed crops them to one shape).
/// Swipe left/right between them; swipe down or tap ✕ to close.
struct MediaViewer: View {
    let media: [MediaDTO]
    /// Called with the item shown last, so the feed can stay on it.
    var onClose: (UUID?) -> Void = { _ in }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?

    init(media: [MediaDTO], startID: UUID, onClose: @escaping (UUID?) -> Void = { _ in }) {
        self.media = media
        self.onClose = onClose
        _selection = State(initialValue: startID)
    }

    private var selectedIndex: Int {
        media.firstIndex { $0.id == selection } ?? 0
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(media) { item in
                    page(for: item)
                        .containerRelativeFrame([.horizontal, .vertical])
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $selection)
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .top) { topBar }
        // Swipe down to close, like Photos; sideways swipes still page.
        .simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { value in
                if value.translation.height > 120, abs(value.translation.width) < 80 { dismiss() }
            }
        )
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onDisappear { onClose(selection) }
    }

    private var topBar: some View {
        HStack {
            if media.count > 1 {
                Text(verbatim: "\(selectedIndex + 1)/\(media.count)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                    .accessibilityLabel("\(selectedIndex + 1) of \(media.count)")
            }
            Spacer()
            Button("Close", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .font(.headline)
                .frame(width: 44, height: 44)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityIdentifier("closeMediaViewer")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func page(for item: MediaDTO) -> some View {
        switch item.kind {
        case .image:
            RemoteImage(path: item.displayPath, contentMode: .fit, showsFailureIcon: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Photo")
                .accessibilityAddTraits(.isImage)
        case .video:
            if let client = app.client {
                LoopingVideoView(url: client.tokenizedMediaURL(item.displayPath),
                                 isActive: selection == item.id, fillsFrame: false)
            }
        }
    }
}
