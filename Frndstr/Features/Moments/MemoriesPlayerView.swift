import FrndstrAPI
import SwiftUI

/// Plays a month's moments one after another, story style (see `StoryPlayer` for the controls).
struct MemoriesPlayerView: View {
    let memories: [ArchivedMoment]
    let startIndex: Int
    let archive: MomentArchive

    static let secondsPerMoment: Double = 3

    var body: some View {
        StoryPlayer(items: memories, startIndex: startIndex, secondsPerItem: Self.secondsPerMoment) { memory in
            ArchivedMomentImage(memory: memory, archive: archive)
                .accessibilityElement()
                .accessibilityLabel(memory.caption ?? String(localized: "Moment"))
                .accessibilityValue(Text(memory.createdAt, format: .dateTime.day().month().year()))
        } header: { memory in
            StoryHeader(date: memory.createdAt, caption: memory.caption, place: memory.location?.placeName)
        }
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
