import FrndstrAPI
import SwiftUI

/// Who reacted to a post, and with what.
struct ReactionsListView: View {
    let post: PostDTO

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var reactions: [ReactionDTO] = []
    @State private var hasLoaded = false

    var body: some View {
        NavigationStack {
            List(reactions) { reaction in
                HStack(spacing: 12) {
                    AvatarView(user: reaction.user, size: 40, showsRing: false)
                    VStack(alignment: .leading) {
                        Text(reaction.user.displayName).font(.subheadline.weight(.semibold))
                        Text(verbatim: "@\(reaction.user.username)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(reaction.emoji).font(.title2)
                }
                .accessibilityElement(children: .combine)
            }
            .listStyle(.plain)
            .overlay {
                if !hasLoaded { ProgressView() }
            }
            .navigationTitle("Reactions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .task {
                if let client = app.client {
                    reactions = (try? await client.reactions(for: post.id)) ?? []
                }
                hasLoaded = true
            }
        }
        .presentationDetents([.medium, .large])
        // Half-height glass sheets let bright photos bleed through; keep text readable.
        .presentationBackground(.thickMaterial)
    }
}
