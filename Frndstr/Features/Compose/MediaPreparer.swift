import AVFoundation
import CoreTransferable
import ImageIO
import UIKit
import UniformTypeIdentifiers
import FrndstrAPI

/// A file ready for upload plus a preview image.
nonisolated struct PreparedMedia: Sendable {
    var fileURL: URL
    var contentType: String
    var kind: MediaKind
    var preview: UIImage
    var duration: Double?
    /// Location/date embedded in the picked original; used only if the user adds a location to the post.
    var capturedLocation: PostLocation?
    var capturedAt: Date?
}

enum MediaPreparationError: LocalizedError {
    case unreadableImage
    case exportFailed
    case videoTooLong

    var errorDescription: String? {
        switch self {
        case .unreadableImage: String(localized: "This photo couldn't be read.")
        case .exportFailed: String(localized: "This video couldn't be converted.")
        case .videoTooLong: String(localized: "Videos can be at most \(Int(API.Limits.maxVideoSeconds)) seconds long.")
        }
    }
}

/// Converts picked media into what the server expects. Runs off the main actor.
/// - Photos: upright JPEG, max 2048 px, **no metadata** (no GPS). Capture location/date are read first and
///   only sent to the server if the user explicitly adds a location to the post.
/// - Videos: H.264 MP4 up to 1080p with location metadata stripped.
nonisolated enum MediaPreparer {
    static let maxImagePixelSize = 2048

    @concurrent
    static func prepareImage(data: Data) async throws -> PreparedMedia {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw MediaPreparationError.unreadableImage
        }
        let capture = MetadataWriter.readCapture(fromImage: source)
        // The thumbnail API applies EXIF orientation and downsamples in one pass.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImagePixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw MediaPreparationError.unreadableImage
        }

        let url = temporaryURL(extension: "jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw MediaPreparationError.unreadableImage
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MediaPreparationError.unreadableImage }

        return PreparedMedia(fileURL: url, contentType: "image/jpeg", kind: .image, preview: UIImage(cgImage: image),
                             capturedLocation: capture.location, capturedAt: capture.date)
    }

    @concurrent
    static func prepareImage(_ image: UIImage) async throws -> PreparedMedia {
        guard let data = image.jpegData(compressionQuality: 0.95) else { throw MediaPreparationError.unreadableImage }
        return try await prepareImage(data: data)
    }

    @concurrent
    static func prepareVideo(at sourceURL: URL) async throws -> PreparedMedia {
        let asset = AVURLAsset(url: sourceURL)
        let capture = await MetadataWriter.readCapture(fromVideo: sourceURL)
        let duration = try await asset.load(.duration).seconds
        guard duration <= API.Limits.maxVideoSeconds + 0.5 else { throw MediaPreparationError.videoTooLong }

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else {
            throw MediaPreparationError.exportFailed
        }
        export.metadataItemFilter = .forSharing()
        export.metadata = []
        export.shouldOptimizeForNetworkUse = true

        let url = temporaryURL(extension: "mp4")
        do {
            try await export.export(to: url, as: .mp4)
        } catch {
            throw MediaPreparationError.exportFailed
        }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)
        let preview = (try? await generator.image(at: .zero).image).map(UIImage.init(cgImage:)) ?? UIImage()

        return PreparedMedia(fileURL: url, contentType: "video/mp4", kind: .video, preview: preview, duration: duration,
                             capturedLocation: capture.location, capturedAt: capture.date)
    }

    /// Center-cropped, 512 px square JPEG for profile photos.
    @concurrent
    static func prepareAvatar(data: Data) async throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1024,
              ] as CFDictionary)
        else { throw MediaPreparationError.unreadableImage }

        let side = min(image.width, image.height)
        let crop = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        guard let square = image.cropping(to: crop) else { throw MediaPreparationError.unreadableImage }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let output = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512), format: format).jpegData(withCompressionQuality: 0.85) { _ in
            UIImage(cgImage: square).draw(in: CGRect(x: 0, y: 0, width: 512, height: 512))
        }
        return output
    }

    static func temporaryURL(extension ext: String) -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Uploads", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(UUID().uuidString).\(ext)")
    }
}

/// Imports a picked video as a file (PhotosPicker hands out a temporary copy we must move).
nonisolated struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = MediaPreparer.temporaryURL(extension: ext)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}
