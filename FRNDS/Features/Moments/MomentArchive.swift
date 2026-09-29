import Foundation
import FRNDSAPI
import ImageIO
import UniformTypeIdentifiers

/// The sender's permanent copy of their moments ("I keep it, my friends don't").
/// Stored in Application Support, never uploaded anywhere else.
nonisolated struct ArchivedMoment: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var createdAt: Date
    var caption: String?
    var recipientNames: [String]
    var layout: MomentLayout?
}

nonisolated final class MomentArchive: Sendable {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    /// Each account on this iPhone has its own archive.
    static func forUser(_ userID: UUID) -> MomentArchive {
        MomentArchive(root: URL.applicationSupportDirectory
            .appending(path: "Moments", directoryHint: .isDirectory)
            .appending(path: userID.uuidString, directoryHint: .isDirectory))
    }

    enum Variant: String {
        case back, front, composite
        /// Small composite for the calendar grid.
        case thumbnail = "thumb"
    }

    static let thumbnailPixelSize = 360

    func fileURL(for id: UUID, _ variant: Variant) -> URL {
        root.appending(path: id.uuidString).appending(path: "\(variant.rawValue).jpg")
    }

    func save(_ moment: ArchivedMoment, back: Data, front: Data, composite: Data) throws {
        let folder = root.appending(path: moment.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try back.write(to: fileURL(for: moment.id, .back))
        try front.write(to: fileURL(for: moment.id, .front))
        try composite.write(to: fileURL(for: moment.id, .composite))
        try? Self.makeThumbnail(from: fileURL(for: moment.id, .composite), to: fileURL(for: moment.id, .thumbnail))
        try API.makeEncoder().encode(moment).write(to: folder.appending(path: "moment.json"))
    }

    /// Newest first.
    func all() -> [ArchivedMoment] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders
            .compactMap { try? Data(contentsOf: $0.appending(path: "moment.json")) }
            .compactMap { try? API.makeDecoder().decode(ArchivedMoment.self, from: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// The grid thumbnail, created on first use for moments archived before thumbnails existed.
    func thumbnailURL(for id: UUID) -> URL {
        let url = fileURL(for: id, .thumbnail)
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try? Self.makeThumbnail(from: fileURL(for: id, .composite), to: url)
        }
        return url
    }

    static func makeThumbnail(from source: URL, to destination: URL) throws {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(image, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: thumbnailPixelSize,
              ] as CFDictionary),
              let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileReadCorruptFile) }
        CGImageDestinationAddImage(output, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
    }

    func delete(_ id: UUID) throws {
        try FileManager.default.removeItem(at: root.appending(path: id.uuidString))
    }
}
