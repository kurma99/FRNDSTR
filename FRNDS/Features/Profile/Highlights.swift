import FRNDSAPI
import SwiftUI

// Highlights: named collections of your own moments on your profile (like Instagram).
// They're the only moments the server keeps; friends can watch them (once the moment's 24 hours
// are over, so a live moment stays with the friends it was sent to) but not save them.

/// Round covers under the profile header. The owner also gets a "New" button.
struct HighlightsRow: View {
    let highlights: [HighlightDTO]
    let isOwner: Bool
    var onOpen: (HighlightDTO) -> Void
    var onNew: () -> Void
    var onEdit: (HighlightDTO) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 16) {
                if isOwner {
                    Button(action: onNew) {
                        VStack(spacing: 6) {
                            Circle()
                                .strokeBorder(.secondary.opacity(0.5), lineWidth: 1)
                                .frame(width: 64, height: 64)
                                .overlay { Image(systemName: "plus").font(.title2) }
                            Text("New").font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New highlight")
                    .accessibilityIdentifier("newHighlightButton")
                }
                ForEach(highlights) { highlight in
                    Button { onOpen(highlight) } label: {
                        VStack(spacing: 6) {
                            HighlightCover(highlight: highlight, size: 64)
                            Text(highlight.title)
                                .font(.caption)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .frame(width: 80)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if isOwner {
                            Button("Edit highlight", systemImage: "pencil") { onEdit(highlight) }
                        }
                    }
                    .accessibilityLabel(highlight.title)
                    .accessibilityValue(Text("^[\(highlight.items.count) moment](inflect: true)"))
                    .accessibilityAction(named: "Edit") { if isOwner { onEdit(highlight) } }
                    .accessibilityIdentifier("highlightCover")
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }
}

struct HighlightCover: View {
    let highlight: HighlightDTO
    var size: CGFloat = 64

    var body: some View {
        Circle()
            .fill(Color(.secondarySystemBackground))
            .overlay {
                if let cover = highlight.cover {
                    RemoteImage(path: cover.thumbnailPath, showsFailureIcon: false)
                        .clipShape(.circle)
                } else {
                    Image(systemName: "sparkles").foregroundStyle(.secondary)
                }
            }
            .padding(3)
            .overlay { Circle().strokeBorder(.secondary.opacity(0.35), lineWidth: 1) }
            .frame(width: size, height: size)
    }
}

/// Plays a highlight's moments, oldest first. No save or share action (friends can't keep them).
struct HighlightPlayer: View {
    let highlight: HighlightDTO

    var body: some View {
        StoryPlayer(items: highlight.items) { item in
            RemoteImage(path: item.imagePath)
                .accessibilityElement()
                .accessibilityLabel(item.caption ?? String(localized: "Moment"))
        } header: { item in
            VStack(alignment: .leading, spacing: 2) {
                Text(highlight.title).font(.headline)
                StoryHeader(date: item.takenAt, caption: item.caption)
                    .font(.subheadline)
            }
        }
    }
}

// MARK: - Editor

/// Create or edit a highlight: name, which moments (from your Memories), cover. Changes are sent on Save.
struct HighlightEditorView: View {
    /// `nil` = a new highlight.
    let highlight: HighlightDTO?
    /// Called with the saved highlight, or `nil` after deleting it.
    var onDone: (HighlightDTO?) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    /// Chosen moments, oldest first.
    @State private var entries: [Entry]
    @State private var coverSourceID: UUID?
    @State private var showPicker = false
    @State private var confirmDelete = false
    @State private var progress: String?
    @State private var errorMessage: String?

    /// A moment in the highlight: already uploaded, or picked from the archive and not uploaded yet.
    enum Entry: Identifiable, Hashable {
        case uploaded(HighlightItemDTO)
        case local(ArchivedMoment)

        var id: UUID {
            switch self {
            case let .uploaded(item): item.sourceID
            case let .local(memory): memory.id
            }
        }

        var date: Date {
            switch self {
            case let .uploaded(item): item.takenAt
            case let .local(memory): memory.createdAt
            }
        }

        var visibleToFriendsFrom: Date { API.Highlights.visibleToFriendsFrom(takenAt: date) }
    }

    init(highlight: HighlightDTO?, onDone: @escaping (HighlightDTO?) -> Void) {
        self.highlight = highlight
        self.onDone = onDone
        _title = State(initialValue: highlight?.title ?? "")
        _entries = State(initialValue: highlight?.items.map(Entry.uploaded) ?? [])
        _coverSourceID = State(initialValue: highlight?.cover?.sourceID)
    }

    private var archive: MomentArchive? { app.currentUser.map { MomentArchive.forUser($0.id) } }
    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedTitle.isEmpty && !entries.isEmpty && progress == nil }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Summer 2026", text: $title)
                        .accessibilityIdentifier("highlightTitleField")
                        .onChange(of: title) { _, new in
                            if new.count > API.Highlights.maxTitleLength { title = String(new.prefix(API.Highlights.maxTitleLength)) }
                        }
                }

                Section {
                    if !entries.isEmpty {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(entries) { entry in
                                tile(for: entry)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Button("Add moments", systemImage: "plus.circle") { showPicker = true }
                        .accessibilityIdentifier("addHighlightMomentsButton")
                } header: {
                    Text("Moments")
                } footer: {
                    Text("All your friends can watch these on your profile until you remove them — each moment only once its 24 hours are over, so until then only the friends you sent it to see it. Touch and hold a moment to make it the cover or remove it.")
                }

                if highlight != nil {
                    Section {
                        Button("Delete highlight", systemImage: "trash", role: .destructive) { confirmDelete = true }
                            .tint(.red)
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle(highlight == nil ? "New highlight" : "Edit highlight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                        .disabled(progress != nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let progress {
                        HStack(spacing: 6) {
                            ProgressView()
                            Text(progress).font(.caption).monospacedDigit()
                        }
                    } else {
                        Button("Save", systemImage: "checkmark", action: save)
                            .disabled(!canSave)
                            .accessibilityIdentifier("saveHighlightButton")
                    }
                }
            }
            .sheet(isPresented: $showPicker) {
                if let archive {
                    ArchivePickerView(archive: archive, excluded: Set(entries.map(\.id))) { picked in
                        entries = (entries + picked.map(Entry.local)).sorted { $0.date < $1.date }
                    }
                }
            }
            .confirmationDialog("Delete this highlight?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive, action: delete)
            } message: {
                Text("Your friends won't see it anymore. The moments stay in your Memories.")
            }
            .interactiveDismissDisabled(progress != nil)
        }
    }

    private func tile(for entry: Entry) -> some View {
        Color.clear
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay {
                switch entry {
                case let .uploaded(item):
                    RemoteImage(path: item.thumbnailPath)
                case let .local(memory):
                    if let archive { LocalImage(url: archive.thumbnailURL(for: memory.id), maxPixel: 360) }
                }
            }
            .clipShape(.rect(cornerRadius: 8))
            .overlay(alignment: .topLeading) {
                if entry.id == (coverSourceID ?? entries.last?.id) {
                    Text("Cover")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .glassEffect(.regular, in: .capsule)
                        .padding(4)
                }
            }
            .overlay(alignment: .bottom) {
                // Still a live moment: friends get it once its 24 hours are over.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    if entry.visibleToFriendsFrom > context.date {
                        Label {
                            Text(entry.visibleToFriendsFrom, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                        } icon: {
                            Image(systemName: "eye.slash")
                        }
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .glassEffect(.regular, in: .capsule)
                        .padding(4)
                        .accessibilityLabel(Text("Friends see it \(entry.visibleToFriendsFrom, format: .relative(presentation: .named))"))
                    }
                }
            }
            .contextMenu {
                Button("Use as cover", systemImage: "circle.inset.filled") { coverSourceID = entry.id }
                Button("Remove", systemImage: "minus.circle", role: .destructive) {
                    entries.removeAll { $0.id == entry.id }
                    if coverSourceID == entry.id { coverSourceID = nil }
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text(entry.date, format: .dateTime.day().month().year()))
            .accessibilityAction(named: "Use as cover") { coverSourceID = entry.id }
            .accessibilityAction(named: "Remove") { entries.removeAll { $0.id == entry.id } }
    }

    // MARK: Saving

    private func save() {
        guard let client = app.client, let archive else { return }
        errorMessage = nil
        progress = ""
        Task {
            defer { progress = nil }
            do {
                var saved = if let highlight {
                    trimmedTitle == highlight.title ? highlight
                        : try await client.updateHighlight(highlight.id, UpdateHighlightRequest(title: trimmedTitle))
                } else {
                    try await client.createHighlight(title: trimmedTitle)
                }

                // Removed moments.
                let kept = Set(entries.map(\.id))
                for item in saved.items where !kept.contains(item.sourceID) {
                    saved = try await client.removeHighlightItem(item.id, from: saved.id)
                }

                // New moments: upload the composite your friends saw, plus its thumbnail.
                let new = entries.compactMap { entry -> ArchivedMoment? in
                    if case let .local(memory) = entry { memory } else { nil }
                }
                for (index, memory) in new.enumerated() {
                    progress = "\(index + 1)/\(new.count)"
                    let (image, thumbnail) = try await Self.files(for: memory, in: archive)
                    saved = try await client.addHighlightItem(
                        to: saved.id, image: image, thumbnail: thumbnail,
                        request: AddHighlightItemRequest(sourceID: memory.id, caption: memory.caption, takenAt: memory.createdAt))
                }

                if let coverSourceID, let cover = saved.items.first(where: { $0.sourceID == coverSourceID }),
                   cover.id != saved.coverItemID {
                    saved = try await client.updateHighlight(saved.id, UpdateHighlightRequest(coverItemID: cover.id))
                }
                onDone(saved)
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                app.handle(error)
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Reads the archived composite and thumbnail off the main actor.
    @concurrent
    private nonisolated static func files(for memory: ArchivedMoment, in archive: MomentArchive) async throws -> (Data, Data) {
        let image = try Data(contentsOf: archive.fileURL(for: memory.id, .composite))
        let thumbnail = try Data(contentsOf: archive.thumbnailURL(for: memory.id))
        return (image, thumbnail)
    }

    private func delete() {
        guard let client = app.client, let highlight else { return }
        Task {
            do {
                try await client.deleteHighlight(highlight.id)
                onDone(nil)
                dismiss()
            } catch {
                app.handle(error)
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Multi-select grid of your archived moments, newest first.
struct ArchivePickerView: View {
    let archive: MomentArchive
    /// Already in the highlight; not shown.
    let excluded: Set<UUID>
    var onPick: ([ArchivedMoment]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var memories: [ArchivedMoment] = []
    @State private var selection: Set<UUID> = []
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(memories) { memory in
                        let isSelected = selection.contains(memory.id)
                        Button {
                            if isSelected { selection.remove(memory.id) } else { selection.insert(memory.id) }
                        } label: {
                            Color.clear
                                .aspectRatio(3 / 4, contentMode: .fit)
                                .overlay { LocalImage(url: archive.thumbnailURL(for: memory.id), maxPixel: 360) }
                                .clipped()
                                .overlay(alignment: .bottomLeading) {
                                    Text(memory.createdAt, format: .dateTime.day().month(.abbreviated))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .shadow(radius: 2)
                                        .padding(6)
                                }
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(isSelected ? Theme.accent : .white)
                                        .shadow(radius: 2)
                                        .padding(6)
                                }
                                .overlay { if isSelected { Color.black.opacity(0.15) } }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(memory.createdAt, format: .dateTime.day().month().year()))
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
            .overlay {
                if memories.isEmpty {
                    ContentUnavailableView("No moments to add", systemImage: "calendar",
                                           description: Text("Moments you send are kept in your Memories and can be added here."))
                }
            }
            .navigationTitle(selection.isEmpty ? "Add moments" : "\(selection.count) selected")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", systemImage: "checkmark") {
                        onPick(memories.filter { selection.contains($0.id) })
                        dismiss()
                    }
                    .disabled(selection.isEmpty)
                    .accessibilityIdentifier("pickMomentsDoneButton")
                }
            }
            .onAppear { memories = archive.all().filter { !excluded.contains($0.id) } }
        }
    }
}
