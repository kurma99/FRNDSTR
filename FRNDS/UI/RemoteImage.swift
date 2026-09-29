import SwiftUI

/// Shows an image from the FRNDS server (authenticated). Size it from the outside.
struct RemoteImage: View {
    let path: String
    var contentMode: ContentMode = .fill
    var showsFailureIcon = true

    @Environment(AppModel.self) private var app
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        // Avatars pass `showsFailureIcon: false` and keep their initials visible underneath.
        Rectangle()
            .fill(showsFailureIcon ? Color(.secondarySystemBackground) : .clear)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                } else if failed, showsFailureIcon {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
            .clipped()
            .contentShape(.rect)
            .task(id: path) { await load() }
    }

    private func load() async {
        guard let client = app.client else { return }
        let url = client.url(path)
        if let cached = ImagePipeline.shared.cachedImage(for: url) {
            image = cached
            return
        }
        do {
            let loaded = try await ImagePipeline.shared.image(for: url, token: client.token)
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}
