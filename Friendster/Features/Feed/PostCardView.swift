import FriendsterAPI
import SwiftUI

/// One post in the feed: author header, media carousel, actions, reactions, caption, comments, date.
struct PostCardView: View {
    let post: PostDTO
    /// Called with the locally changed post (reactions, comment count) so the owning list can update.
    var onUpdate: (PostDTO) -> Void = { _ in }
    var onDelete: (UUID) -> Void = { _ in }

    @Environment(AppModel.self) private var app
    @State private var captionExpanded = false
    @State private var showComments = false
    @State private var showReactions = false
    @State private var showReactionPicker = false
    @State private var showSaveOptions = false
    @State private var confirmDelete = false
    @State private var showEditCaption = false
    @State private var toast: String?

    private var isOwnPost: Bool { app.currentUser?.id == post.author.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
                .padding(.horizontal, 12)

            MediaCarousel(media: post.media)

            VStack(alignment: .leading, spacing: 8) {
                actionRow
                reactionSummary
                caption
                if post.commentCount > 0 {
                    Button {
                        showComments = true
                    } label: {
                        Text(post.commentCount == 1 ? "View 1 comment" : "View all \(post.commentCount) comments")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                // Re-render every minute so "2 minutes ago" stays current.
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Text(post.createdAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
        }
        .overlay(alignment: .top) { toastView }
        .sheet(isPresented: $showComments) {
            CommentsView(post: post) { count in
                var updated = post
                updated.commentCount = count
                onUpdate(updated)
            }
        }
        .sheet(isPresented: $showReactions) {
            ReactionsListView(post: post)
        }
        .sheet(isPresented: $showSaveOptions) {
            SaveOptionsSheet(post: post) { options in save(with: options) }
        }
        .sheet(isPresented: $showEditCaption) {
            EditCaptionSheet(post: post, onSaved: onUpdate)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            NavigationLink(value: post.author) {
                HStack(spacing: 10) {
                    AvatarView(user: post.author, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(post.author.displayName)
                            .font(.subheadline.weight(.semibold))
                        if let place = post.location?.placeName {
                            Label(place, systemImage: "mappin")
                                .labelStyle(.titleOnly)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(verbatim: "@\(post.author.username)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Spacer()

            Menu {
                Button("Save to Photos", systemImage: "square.and.arrow.down", action: startSave)
                if isOwnPost {
                    Button("Edit caption", systemImage: "pencil") { showEditCaption = true }
                        .accessibilityIdentifier("editCaptionButton")
                    Button("Delete post", systemImage: "trash", role: .destructive) {
                        // Let the menu finish dismissing before presenting the confirmation.
                        Task {
                            try? await Task.sleep(for: .milliseconds(350))
                            confirmDelete = true
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .foregroundStyle(.primary)
            .accessibilityLabel("More")
            // Anchored to the "…" button so the popover points at it.
            .confirmationDialog("Delete this post?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { delete() }
            } message: {
                Text("It will be removed for everyone, including comments and reactions.")
            }
        }
    }

    // MARK: Actions

    private var actionRow: some View {
        HStack(spacing: 18) {
            // Actions sit on the right; saving lives in the "…" menu.
            Spacer()

            // Reactions only (no separate "like"): shows your current emoji, tap to pick or change.
            Button {
                showReactionPicker = true
            } label: {
                Group {
                    if let emoji = post.myReaction {
                        Text(emoji)
                    } else {
                        Image(systemName: "face.smiling")
                    }
                }
                .font(.title2)
            }
            .accessibilityLabel(post.myReaction.map { "Your reaction \($0)" } ?? "React")
            .accessibilityIdentifier("reactButton")
            .popover(isPresented: $showReactionPicker) {
                ReactionPicker(emojis: app.reactionEmojis, selected: post.myReaction) { emoji in
                    showReactionPicker = false
                    setReaction(emoji == post.myReaction ? nil : emoji)
                }
                .presentationCompactAdaptation(.popover)
            }

            Button {
                showComments = true
            } label: {
                Image(systemName: "bubble.right").font(.title2)
            }
            .accessibilityLabel("Comments")
            .accessibilityIdentifier("commentButton")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private var reactionSummary: some View {
        if post.totalReactions > 0 {
            Button {
                showReactions = true
            } label: {
                HStack(spacing: 4) {
                    Text(post.reactions.prefix(3).map(\.emoji).joined())
                    Text("^[\(post.totalReactions) reaction](inflect: true)")
                        .fontWeight(.semibold)
                }
                .font(.subheadline)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reactionSummary")
        }
    }

    @ViewBuilder
    private var caption: some View {
        if let caption = post.caption {
            Text("\(Text(post.author.username).fontWeight(.semibold)) \(caption)")
                .font(.subheadline)
                .lineLimit(captionExpanded ? nil : 3)
                .onTapGesture { withAnimation(.snappy) { captionExpanded.toggle() } }
        }
    }

    // MARK: Overlays

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 60)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityIdentifier("toast")
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.snappy) { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.snappy) { if toast == text { toast = nil } }
        }
    }

    // MARK: Behaviour

    /// Optimistic update, then the server's authoritative summary.
    private func setReaction(_ emoji: String?) {
        guard let client = app.client else { return }
        let original = post
        onUpdate(Self.applying(emoji, to: post))
        Task {
            do {
                let summary = if let emoji {
                    try await client.react(to: original.id, with: emoji)
                } else {
                    try await client.removeReaction(from: original.id)
                }
                var updated = original
                updated.reactions = summary.reactions
                updated.myReaction = summary.myReaction
                onUpdate(updated)
            } catch {
                onUpdate(original)
                app.handle(error)
                showToast(error.localizedDescription)
            }
        }
    }

    /// Local prediction of the reaction change.
    static func applying(_ emoji: String?, to post: PostDTO) -> PostDTO {
        var counts = Dictionary(uniqueKeysWithValues: post.reactions.map { ($0.emoji, $0.count) })
        if let old = post.myReaction { counts[old, default: 1] -= 1 }
        if let emoji { counts[emoji, default: 0] += 1 }
        var updated = post
        updated.myReaction = emoji
        updated.reactions = counts.filter { $0.value > 0 }
            .map { ReactionCount(emoji: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
        return updated
    }

    private func startSave() {
        if SaveSettings.askEachTime {
            showSaveOptions = true
        } else {
            save(with: SaveSettings.defaults)
        }
    }

    private func save(with options: SaveOptions) {
        guard let client = app.client else { return }
        showToast(String(localized: "Saving…"))
        Task {
            do {
                let count = try await PhotoSaver.save(post, options: options, client: client)
                // Inflection only applies when going through AttributedString.
                showToast(String(AttributedString(localized: "^[\(count) item](inflect: true) saved to Photos").characters))
            } catch {
                app.handle(error)
                showToast(error.localizedDescription)
            }
        }
    }

    private func delete() {
        guard let client = app.client else { return }
        Task {
            do {
                try await client.deletePost(post.id)
                onDelete(post.id)
            } catch {
                app.handle(error)
                showToast(error.localizedDescription)
            }
        }
    }
}

/// Row of emoji reactions in a glass capsule.
struct ReactionPicker: View {
    let emojis: [String]
    let selected: String?
    let onPick: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(emojis, id: \.self) { emoji in
                Button {
                    onPick(emoji)
                } label: {
                    Text(emoji)
                        .font(.system(size: 30))
                        .padding(6)
                        .background {
                            if emoji == selected {
                                Circle().fill(.tint.opacity(0.25))
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(emoji)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// Lets the author change or remove a post's caption.
struct EditCaptionSheet: View {
    let post: PostDTO
    var onSaved: (PostDTO) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    init(post: PostDTO, onSaved: @escaping (PostDTO) -> Void) {
        self.post = post
        self.onSaved = onSaved
        _text = State(initialValue: post.caption ?? "")
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasChanges: Bool { trimmed != (post.caption ?? "") }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Write a caption…", text: $text, axis: .vertical)
                        .lineLimit(3...10)
                        .focused($focused)
                        .accessibilityIdentifier("editCaptionField")
                        .onChange(of: text) { _, new in
                            if new.count > API.Limits.maxCaptionLength { text = String(new.prefix(API.Limits.maxCaptionLength)) }
                        }
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    } else {
                        Text("Leave it empty to remove the caption.")
                    }
                }
            }
            .navigationTitle("Edit caption")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save", systemImage: "checkmark", action: save)
                            .disabled(!hasChanges)
                            .accessibilityIdentifier("saveCaptionButton")
                    }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        guard let client = app.client else { return }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                let updated = try await client.updateCaption(of: post.id, to: trimmed.isEmpty ? nil : trimmed)
                onSaved(updated)
                dismiss()
            } catch {
                app.handle(error)
                errorMessage = error.localizedDescription
            }
        }
    }
}
