import FRNDSAPI
import SwiftUI

/// Comment sheet: caption on top, conversation, and a glass composer pinned to the bottom.
struct CommentsView: View {
    let post: PostDTO
    var onCountChange: (Int) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var comments: [CommentDTO] = []
    @State private var hasLoaded = false
    @State private var text = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                if let caption = post.caption {
                    CommentRow(author: post.author, text: caption, date: post.createdAt)
                        .listRowSeparator(.hidden)
                }
                ForEach(comments) { comment in
                    CommentRow(author: comment.author, text: comment.text, date: comment.createdAt)
                        .swipeActions(edge: .trailing) {
                            if canDelete(comment) {
                                Button("Delete", systemImage: "trash", role: .destructive) { delete(comment) }
                            }
                        }
                        .contextMenu {
                            if canDelete(comment) {
                                Button("Delete", systemImage: "trash", role: .destructive) { delete(comment) }
                            }
                        }
                }
            }
            .listStyle(.plain)
            .overlay {
                if !hasLoaded {
                    ProgressView()
                } else if comments.isEmpty {
                    ContentUnavailableView("No comments yet", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Start the conversation."))
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .task { await load() }
            .alert("Something went wrong", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // Half-height glass sheets let bright photos bleed through; keep text readable.
        .presentationBackground(.thickMaterial)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if let me = app.currentUser {
                AvatarView(user: me, size: 32, showsRing: false)
            }
            TextField("Add a comment…", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .focused($composerFocused)
                .padding(.vertical, 6)
                .accessibilityIdentifier("commentField")
            Button(action: send) {
                Group {
                    if isSending {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.bold))
                    }
                }
                .frame(width: 32, height: 32)
            }
            .primaryButtonStyle()
            .buttonBorderShape(.circle)
            .disabled(trimmed.isEmpty || isSending)
            .accessibilityLabel("Post comment")
            .accessibilityIdentifier("sendCommentButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func canDelete(_ comment: CommentDTO) -> Bool {
        guard let me = app.currentUser?.id else { return false }
        return comment.author.id == me || post.author.id == me
    }

    private func load() async {
        guard let client = app.client else { return }
        do {
            comments = try await client.comments(for: post.id)
            onCountChange(comments.count)
        } catch {
            app.handle(error)
            errorMessage = error.localizedDescription
        }
        hasLoaded = true
    }

    private func send() {
        guard let client = app.client, !trimmed.isEmpty else { return }
        let body = trimmed
        isSending = true
        Task {
            defer { isSending = false }
            do {
                let comment = try await client.addComment(body, to: post.id)
                withAnimation(.snappy) { comments.append(comment) }
                text = ""
                onCountChange(comments.count)
            } catch {
                app.handle(error)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func delete(_ comment: CommentDTO) {
        guard let client = app.client else { return }
        withAnimation(.snappy) { comments.removeAll { $0.id == comment.id } }
        onCountChange(comments.count)
        Task {
            do {
                try await client.deleteComment(comment.id)
            } catch {
                app.handle(error)
                errorMessage = error.localizedDescription
                await load()
            }
        }
    }
}

private struct CommentRow: View {
    let author: UserDTO
    let text: String
    let date: Date

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(user: author, size: 32, showsRing: false)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(Text(author.username).fontWeight(.semibold)) \(text)")
                    .font(.subheadline)
                Text(date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
