import FrndstrAPI
import SwiftUI

/// Plays a month's moments one after another, story style (see `StoryPlayer` for the controls).
struct MemoriesPlayerView: View {
    let startIndex: Int
    let archive: MomentArchive

    static let secondsPerMoment: Double = 3

    @Environment(AppModel.self) private var app
    @State private var memories: [ArchivedMoment]
    @State private var pendingDelete: ArchivedMoment?
    @State private var message: String?

    init(memories: [ArchivedMoment], startIndex: Int, archive: MomentArchive) {
        _memories = State(initialValue: memories)
        self.startIndex = startIndex
        self.archive = archive
    }

    var body: some View {
        StoryPlayer(items: memories, startIndex: startIndex, secondsPerItem: Self.secondsPerMoment,
                    isHeld: pendingDelete != nil || message != nil) { memory in
            ArchivedMomentImage(memory: memory, archive: archive)
                .accessibilityElement()
                .accessibilityLabel(memory.caption ?? String(localized: "Moment"))
                .accessibilityValue(Text(memory.createdAt, format: .dateTime.day().month().year()))
        } header: { memory in
            StoryHeader(date: memory.createdAt, caption: memory.caption, place: memory.location?.placeName)
        } actions: { memory in
            // Days with several moments open here, so this is where duplicates get removed.
            Button("Save to Photos", systemImage: "square.and.arrow.down") {
                Task { message = await archive.saveToPhotos(memory) }
            }
            Button("Delete memory", systemImage: "trash", role: .destructive) { pendingDelete = memory }
        }
        .confirmationDialog("Delete this memory?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible, presenting: pendingDelete) { memory in
            Button("Delete", role: .destructive) {
                archive.deleteEverywhere(memory, using: app)
                memories.removeAll { $0.id == memory.id }
            }
        } message: { _ in
            Text("It's removed from this iPhone and from your backup on the server, so it can't be recovered.")
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {}
    }
}

/// An archived moment's composite; the thumbnail shows instantly, the full image replaces it once decoded.
struct ArchivedMomentImage: View {
    let memory: ArchivedMoment
    let archive: MomentArchive

    var body: some View {
        ZStack {
            LocalImage(url: archive.thumbnailURL(for: memory.id), maxPixel: 360)
            LocalImage(url: archive.fileURL(for: memory.id, .composite), maxPixel: 1600)
        }
    }
}
