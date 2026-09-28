import Foundation
import ImageIO
import Testing
import UIKit
import FriendsterAPI
@testable import Friendster

private func solidImage(_ color: UIColor, size: CGSize) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image { context in
        color.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }
}

@Suite struct MomentComposerTests {
    @Test func compositeKeepsBackSizeAndInsetsFrontTopLeft() throws {
        let back = solidImage(.blue, size: CGSize(width: 1200, height: 1600))
        let front = solidImage(.red, size: CGSize(width: 600, height: 800))
        let composite = MomentComposer.composite(back: back, front: front)
        #expect(composite.size == CGSize(width: 1200, height: 1600))

        let cgImage = try #require(composite.cgImage)
        let data = try #require(cgImage.dataProvider?.data as Data?)
        func pixel(_ x: Int, _ y: Int) -> (r: UInt8, b: UInt8) {
            let offset = y * cgImage.bytesPerRow + x * (cgImage.bitsPerPixel / 8)
            // Renderer output is BGRA (little-endian premultiplied).
            return (data[offset + 2], data[offset])
        }
        let insideInset = pixel(200, 200)          // inset spans ~48…432 × 48…560
        let outsideInset = pixel(900, 1200)
        #expect(insideInset.r > 200 && insideInset.b < 50)
        #expect(outsideInset.b > 200 && outsideInset.r < 50)
    }

    @Test func jpegIsDownscaledAndMetadataFree() throws {
        let image = solidImage(.green, size: CGSize(width: 4000, height: 3000))
        let data = MomentComposer.jpeg(image, maxPixel: 2048)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 2048)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == 1536)
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test func smallImagesAreNotUpscaled() {
        #expect(MomentComposer.scaledSize(CGSize(width: 800, height: 600), maxPixel: 2048) == CGSize(width: 800, height: 600))
    }
}

@Suite struct MomentArchiveTests {
    @Test func saveListAndDelete() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = MomentArchive(root: root)

        let older = ArchivedMoment(id: UUID(), createdAt: Date(timeIntervalSince1970: 1_000), caption: "alt", recipientNames: ["Anna"])
        let newer = ArchivedMoment(id: UUID(), createdAt: Date(timeIntervalSince1970: 2_000), caption: nil, recipientNames: [])
        for moment in [older, newer] {
            try archive.save(moment, back: Data([1]), front: Data([2]), composite: Data([3]))
        }

        #expect(archive.all().map(\.id) == [newer.id, older.id])
        #expect(try Data(contentsOf: archive.fileURL(for: older.id, .composite)) == Data([3]))

        try archive.delete(older.id)
        #expect(archive.all() == [newer])
    }
}

@MainActor
@Suite struct MomentLayoutTests {
    private func pixel(_ image: UIImage, _ x: Int, _ y: Int) throws -> (r: UInt8, b: UInt8) {
        let cgImage = try #require(image.cgImage)
        let data = try #require(cgImage.dataProvider?.data as Data?)
        let offset = y * cgImage.bytesPerRow + x * (cgImage.bitsPerPixel / 8)
        return (data[offset + 2], data[offset])
    }

    @Test func compositeFollowsCornerAndSwap() throws {
        let back = solidImage(.blue, size: CGSize(width: 900, height: 1200))
        let front = solidImage(.red, size: CGSize(width: 600, height: 800))
        let layout = MomentLayout(insetCorner: .bottomTrailing, swapped: true)
        let composite = MomentComposer.composite(back: back, front: front, layout: layout)

        // Swapped: the front (red) photo is the big one, the back (blue) sits bottom-right.
        let bottomRight = try pixel(composite, 1100, 1450)
        let topLeft = try pixel(composite, 100, 100)
        #expect(bottomRight.b > 200 && bottomRight.r < 50)
        #expect(topLeft.r > 200 && topLeft.b < 50)
    }

    @Test(arguments: [
        (CGPoint(x: 10, y: 10), MomentLayout.Corner.topLeading),
        (CGPoint(x: 290, y: 20), .topTrailing),
        (CGPoint(x: 20, y: 390), .bottomLeading),
        (CGPoint(x: 280, y: 380), .bottomTrailing),
    ])
    func dragSnapsToNearestCorner(point: CGPoint, corner: MomentLayout.Corner) {
        #expect(DualPhotoView.nearestCorner(to: point, in: CGSize(width: 300, height: 400)) == corner)
    }

    @Test func insetSizeIsClampedAndOptional() throws {
        #expect(MomentLayout().resolvedInsetSize == MomentLayout.defaultInsetSize)
        #expect(MomentLayout(insetSize: 0.9).insetSize == MomentLayout.insetSizeRange.upperBound)
        #expect(MomentLayout(insetSize: 0.05).resolvedInsetSize == MomentLayout.insetSizeRange.lowerBound)
        // Older clients/servers send no size and still decode.
        let old = try API.makeDecoder().decode(MomentLayout.self, from: Data(#"{"insetCorner":"topLeading","swapped":false}"#.utf8))
        #expect(old.insetSize == nil)
    }

    @Test func compositeUsesPinchedInsetSize() throws {
        let back = solidImage(.blue, size: CGSize(width: 900, height: 1200))
        let front = solidImage(.red, size: CGSize(width: 600, height: 800))
        // 1200×1600 canvas, margin 48. Default inset is 360 wide (to x 408); at 0.5 it's 600 wide (to x 648).
        let big = MomentComposer.composite(back: back, front: front, layout: MomentLayout(insetSize: 0.5))
        let small = MomentComposer.composite(back: back, front: front, layout: MomentLayout())
        #expect(try pixel(big, 550, 300).r > 200)
        #expect(try pixel(small, 550, 300).b > 200)
    }

    @Test func insetOriginsKeepMargins() {
        let size = CGSize(width: 300, height: 400), inset = CGSize(width: 90, height: 120)
        #expect(DualPhotoView.origin(of: .topLeading, in: size, inset: inset) == CGPoint(x: 12, y: 12))
        #expect(DualPhotoView.origin(of: .bottomTrailing, in: size, inset: inset) == CGPoint(x: 198, y: 268))
    }
}

@MainActor
@Suite struct MemoriesCalendarTests {
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = berlin
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func memory(_ date: Date) -> ArchivedMoment {
        ArchivedMoment(id: UUID(), createdAt: date, caption: nil, recipientNames: [])
    }

    @Test func weekdaysStartOnMonday() {
        let calendar = MemoriesCalendar(timeZone: berlin, locale: Locale(identifier: "en_US"))
        #expect(calendar.weekdaySymbols == ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"])
    }

    @Test func groupsByMonthNewestFirstWithCorrectOffsets() throws {
        let calendar = MemoriesCalendar(timeZone: berlin, locale: Locale(identifier: "en_US"))
        let augustMorning = memory(date(2026, 8, 15, 8))
        let augustEvening = memory(date(2026, 8, 15, 21))
        let september = memory(date(2026, 9, 27))
        let months = calendar.months(for: [augustEvening, september, augustMorning])

        #expect(months.count == 2)
        let sep = months[0], aug = months[1]
        // 1 Sep 2026 is a Tuesday → one blank (Monday) before it; 1 Aug 2026 is a Saturday → five blanks.
        #expect(sep.leadingBlanks == 1)
        #expect(aug.leadingBlanks == 5)
        #expect(sep.days.count == 30 && aug.days.count == 31)
        #expect(sep.days[26].number == 27 && sep.days[26].memories == [september])
        // Same day: oldest first, and the month plays in chronological order.
        #expect(aug.days[14].memories == [augustMorning, augustEvening])
        #expect(aug.memories == [augustMorning, augustEvening])
    }

    @Test func progressSegmentsFillInOrder() {
        let bar = SegmentedProgressBar(count: 4, index: 2, progress: 0.4)
        #expect((0..<4).map(bar.fill(for:)) == [1, 1, 0.4, 0])
    }

    @Test func thumbnailIsCreatedOnDemandAndSmall() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "thumbs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = MomentArchive(root: root)
        let composite = try #require(solidImage(.yellow, size: CGSize(width: 1200, height: 1600)).jpegData(compressionQuality: 0.9))
        let moment = ArchivedMoment(id: UUID(), createdAt: .now, caption: nil, recipientNames: [])
        try archive.save(moment, back: composite, front: composite, composite: composite)

        // Simulate an older archive without thumbnails.
        try FileManager.default.removeItem(at: archive.fileURL(for: moment.id, .thumbnail))
        let url = archive.thumbnailURL(for: moment.id)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyPixelHeight] as? Int == MomentArchive.thumbnailPixelSize)
    }
}

@Suite struct TakeoutTests {
    @Test func momentsAreExportedOldestFirstWithReadableNames() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "takeout-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let archive = MomentArchive(root: base.appending(path: "archive"))
        let jpeg = try #require(solidImage(.red, size: CGSize(width: 30, height: 40)).jpegData(compressionQuality: 0.8))
        let older = ArchivedMoment(id: UUID(), createdAt: Date(timeIntervalSince1970: 1_000_000), caption: "Am See", recipientNames: ["Anna"])
        let newer = ArchivedMoment(id: UUID(), createdAt: Date(timeIntervalSince1970: 2_000_000), caption: nil, recipientNames: [])
        for moment in [older, newer] { try archive.save(moment, back: jpeg, front: jpeg, composite: jpeg) }

        let exported = try Takeout.exportMoments(from: archive, to: base.appending(path: "out/moments"))
        #expect(exported.map(\.takenAt) == [older.createdAt, newer.createdAt])
        #expect(exported[0].sentTo == ["Anna"])
        let files = try #require(exported.first?.files)
        #expect(files.count == 3 && files.allSatisfy { $0.hasPrefix("moments/1970-") })
        #expect(files.contains { $0.hasSuffix("/moment.jpg") })

        // The caption is written into the exported composite.
        let composite = base.appending(path: "out").appending(path: try #require(files.first { $0.hasSuffix("moment.jpg") }))
        let source = try #require(CGImageSourceCreateWithURL(composite as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        #expect(iptc?[kCGImagePropertyIPTCCaptionAbstract] as? String == "Am See")
    }

    @Test func highlightCoverFallsBackToNewest() {
        let items = (0..<3).map { index in
            HighlightItemDTO(id: UUID(), sourceID: UUID(), caption: nil, takenAt: Date(timeIntervalSince1970: Double(index)),
                             imagePath: "/i\(index)", thumbnailPath: "/t\(index)")
        }
        var highlight = HighlightDTO(id: UUID(), ownerID: UUID(), title: "x", coverItemID: nil, items: items, createdAt: .now)
        #expect(highlight.cover == items.last)
        highlight.coverItemID = items[0].id
        #expect(highlight.cover == items[0])
    }
}
