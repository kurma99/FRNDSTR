import FrndstrAPI
import SwiftUI

/// Your own moments as a BeReal-style calendar: one grid per month, MON … SUN,
/// a thumbnail on every day you shared something. Kept on this iPhone only.
struct MemoriesView: View {
    @Environment(AppModel.self) private var app
    @State private var memories: [ArchivedMoment] = []
    @State private var selected: ArchivedMoment?
    @State private var playback: Playback?

    private let calendar = MemoriesCalendar()
    private var archive: MomentArchive? { app.currentUser.map { MomentArchive.forUser($0.id) } }
    private var months: [MemoriesCalendar.Month] { calendar.months(for: memories) }

    /// What the player shows: a month's moments, starting at one of them.
    struct Playback: Identifiable {
        let id = UUID()
        let memories: [ArchivedMoment]
        let startIndex: Int
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                if let archive {
                    ForEach(months) { month in
                        MonthGrid(month: month, weekdays: calendar.weekdaySymbols, calendar: calendar.calendar,
                                  archive: archive) {
                            playback = Playback(memories: month.memories, startIndex: 0)
                        } onSelect: { day in
                            select(day, in: month)
                        }
                    }
                }
            }
            .padding(16)
        }
        // Chronological top to bottom, so open at the newest month; short content still starts at the top.
        .defaultScrollAnchor(.top, for: .alignment)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .overlay {
            if memories.isEmpty {
                ContentUnavailableView("No memories yet", systemImage: "calendar",
                                       description: Text("Moments you send are kept here, even after they disappear for your friends."))
            }
        }
        .navigationTitle("Memories")
        .onAppear { memories = archive?.all() ?? [] }
        .sheet(item: $selected) { memory in
            if let archive {
                MemoryDetailView(memory: memory, archive: archive) {
                    memories = archive.all()
                }
            }
        }
        .fullScreenCover(item: $playback) { playback in
            if let archive {
                MemoriesPlayerView(memories: playback.memories, startIndex: playback.startIndex, archive: archive)
            }
        }
    }

    /// One moment → details; several → play the month starting at that day.
    private func select(_ day: MemoriesCalendar.Day, in month: MemoriesCalendar.Month) {
        if day.memories.count == 1 {
            selected = day.memories[0]
        } else if let first = day.memories.first, let index = month.memories.firstIndex(of: first) {
            playback = Playback(memories: month.memories, startIndex: index)
        }
    }
}

// MARK: - Month grid

private struct MonthGrid: View {
    let month: MemoriesCalendar.Month
    let weekdays: [String]
    let calendar: Calendar
    let archive: MomentArchive
    var onPlay: () -> Void
    var onSelect: (MemoriesCalendar.Day) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(month.start, format: .dateTime.month(.wide).year())
                    .font(.title3.bold())
                Spacer()
                Button(action: onPlay) {
                    Label("Play \(month.start.formatted(.dateTime.month(.wide)))", systemImage: "play.fill")
                        .labelStyle(.iconOnly)
                        .font(.subheadline.weight(.bold))
                        .frame(width: 36, height: 36)
                }
                .primaryButtonStyle()
                .buttonBorderShape(.circle)
                .accessibilityIdentifier("playMonthButton")
            }

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                ForEach(0..<month.leadingBlanks, id: \.self) { _ in
                    Color.clear.aspectRatio(3 / 4, contentMode: .fit)
                }
                ForEach(month.days) { day in
                    DayCell(day: day, isToday: calendar.isDateInToday(day.date), archive: archive)
                        .onTapGesture { if !day.memories.isEmpty { onSelect(day) } }
                }
            }
        }
    }
}

private struct DayCell: View {
    let day: MemoriesCalendar.Day
    let isToday: Bool
    let archive: MomentArchive

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.fill.quaternary)
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay { thumbnail }
            .overlay { number }
            .overlay(alignment: .topTrailing) { countBadge }
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent, lineWidth: 2)
                }
            }
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(day.date, format: .dateTime.weekday(.wide).day().month(.wide)))
            .accessibilityValue(day.memories.isEmpty ? Text("") : Text("^[\(day.memories.count) moment](inflect: true)"))
            .accessibilityAddTraits(day.memories.isEmpty ? [] : .isButton)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let newest = day.memories.last {
            LocalImage(url: archive.thumbnailURL(for: newest.id), maxPixel: 240)
                .clipShape(.rect(cornerRadius: 8))
        }
    }

    private var number: some View {
        Text("\(day.number)")
            .font(.caption.weight(.bold).monospacedDigit())
            .foregroundStyle(day.memories.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
            .shadow(color: day.memories.isEmpty ? .clear : .black.opacity(0.6), radius: 2)
    }

    @ViewBuilder
    private var countBadge: some View {
        if day.memories.count > 1 {
            Text("\(day.memories.count)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.onPrimary)
                .padding(3)
                .background(Theme.primary, in: .circle)
                .padding(2)
        }
    }
}

// MARK: - Detail

struct MemoryDetailView: View {
    let memory: ArchivedMoment
    let archive: MomentArchive
    var onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var status: String?
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let back = UIImage(contentsOfFile: archive.fileURL(for: memory.id, .back).path(percentEncoded: false)),
                       let front = UIImage(contentsOfFile: archive.fileURL(for: memory.id, .front).path(percentEncoded: false)) {
                        MomentPhotos(source: .local(back: back, front: front), layout: memory.layout)
                    }
                    if let caption = memory.caption {
                        Text(caption).font(.body)
                    }
                    Text(memory.createdAt, format: .dateTime.day().month().year().hour().minute())
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let place = memory.location?.placeName {
                        Label(place, systemImage: "mappin")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if !memory.recipientNames.isEmpty {
                        Text("Sent to \(memory.recipientNames.formatted(.list(type: .and)))")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let status {
                        Text(status).font(.subheadline.weight(.medium))
                    }
                }
                .padding(20)
            }
            .navigationTitle("Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Save to Photos", systemImage: "square.and.arrow.down", action: save)
                        Button("Delete from iPhone", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .confirmationDialog("Delete this memory?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Delete", role: .destructive) {
                            try? archive.delete(memory.id)
                            onDelete()
                            dismiss()
                        }
                    } message: {
                        Text("It's only stored on this iPhone, so it can't be recovered.")
                    }
                }
            }
        }
    }

    private func save() {
        guard let data = try? Data(contentsOf: archive.fileURL(for: memory.id, .composite)) else { return }
        Task {
            do {
                try await PhotoSaver.saveImage(data, metadata: SaveMetadata(caption: memory.caption, location: memory.location, date: memory.createdAt))
                status = String(localized: "Saved to Photos")
            } catch {
                status = error.localizedDescription
            }
        }
    }
}

// MARK: - Local images

/// Loads and downsamples a local JPEG off the main thread.
struct LocalImage: View {
    let url: URL?
    var maxPixel: CGFloat = 600
    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .task(id: url) {
                if let url { image = await Self.load(url, maxPixel: maxPixel) }
            }
    }

    @concurrent
    private nonisolated static func load(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        guard let image = UIImage(contentsOfFile: url.path(percentEncoded: false)) else { return nil }
        let scale = min(1, maxPixel / max(image.size.width, image.size.height, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return await image.byPreparingThumbnail(ofSize: size) ?? image
    }
}
