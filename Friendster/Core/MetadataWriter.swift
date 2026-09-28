import AVFoundation
import Foundation
import FriendsterAPI
import ImageIO
import UniformTypeIdentifiers

/// What to embed when saving to Photos. `nil` fields are left out entirely.
nonisolated struct SaveMetadata: Sendable, Equatable {
    var caption: String?
    var location: PostLocation?
    var date: Date
}

/// Embeds caption, location and capture date into image/video files so Apple Photos
/// (and any other app) can read them. Also reads capture metadata from picked files.
nonisolated enum MetadataWriter {

    // MARK: Images

    /// Losslessly rewrites the image's metadata (no re-encoding).
    /// Caption → IPTC Caption/Abstract (= XMP dc:description, what Photos shows), TIFF ImageDescription, EXIF UserComment.
    static func writeImage(_ data: Data, metadata: SaveMetadata, timeZone: TimeZone = .current) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source)
        else { throw MetadataError.unreadable }

        let xmp = CGImageMetadataCreateMutable()
        func set(_ dictionary: CFString, _ key: CFString, _ value: Any) {
            CGImageMetadataSetValueMatchingImageProperty(xmp, dictionary, key, value as CFTypeRef)
        }

        let exifDate = exifDateString(metadata.date, timeZone: timeZone)
        set(kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal, exifDate)
        set(kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeDigitized, exifDate)
        set(kCGImagePropertyExifDictionary, kCGImagePropertyExifOffsetTimeOriginal, offsetString(metadata.date, timeZone: timeZone))
        set(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFDateTime, exifDate)

        if let caption = metadata.caption, !caption.isEmpty {
            set(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCaptionAbstract, caption)
            set(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription, caption)
            set(kCGImagePropertyExifDictionary, kCGImagePropertyExifUserComment, caption)
        }

        if let location = metadata.location {
            set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitude, abs(location.latitude))
            set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitudeRef, location.latitude >= 0 ? "N" : "S")
            set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitude, abs(location.longitude))
            set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitudeRef, location.longitude >= 0 ? "E" : "W")
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else {
            throw MetadataError.unwritable
        }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: xmp,
            kCGImageDestinationMergeMetadata: true,
        ]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? MetadataError.unwritable
        }
        return output as Data
    }

    /// Location and capture date embedded in a picked photo (read before we strip metadata for upload).
    static func readCapture(fromImage source: CGImageSource) -> (location: PostLocation?, date: Date?) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (nil, nil)
        }
        var location: PostLocation?
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
           let longitude = gps[kCGImagePropertyGPSLongitude] as? Double {
            let south = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S"
            let west = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W"
            location = PostLocation(latitude: south ? -latitude : latitude,
                                    longitude: west ? -longitude : longitude, placeName: nil)
        }
        var date: Date?
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            date = parseExifDate(text, offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String)
        }
        return (location, date)
    }

    // MARK: Videos

    /// Re-wraps the video (passthrough, no re-encoding) as a QuickTime movie with description, location and date.
    static func writeVideo(at sourceURL: URL, metadata: SaveMetadata) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw MetadataError.unwritable
        }

        var items: [AVMetadataItem] = []
        func add(_ identifier: AVMetadataIdentifier, _ value: String) {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            items.append(item)
        }
        let date = ISO8601DateFormatter().string(from: metadata.date)
        add(.quickTimeMetadataCreationDate, date)
        add(.commonIdentifierCreationDate, date)
        if let caption = metadata.caption, !caption.isEmpty {
            add(.quickTimeMetadataDescription, caption)
            add(.commonIdentifierDescription, caption)
        }
        if let location = metadata.location {
            add(.quickTimeMetadataLocationISO6709, iso6709(location))
        }
        export.metadata = items

        let output = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mov")
        try await export.export(to: output, as: .mov)
        return output
    }

    /// Location and creation date embedded in a picked video.
    static func readCapture(fromVideo url: URL) async -> (location: PostLocation?, date: Date?) {
        let asset = AVURLAsset(url: url)
        let metadata = (try? await asset.load(.metadata)) ?? []
        var location: PostLocation?
        for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .quickTimeMetadataLocationISO6709)
            + AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierLocation) {
            if let text = try? await item.load(.stringValue), let parsed = parseISO6709(text) {
                location = parsed
                break
            }
        }
        let date = try? await asset.load(.creationDate)?.load(.dateValue)
        return (location, date ?? nil)
    }

    // MARK: Formatting helpers

    /// `yyyy:MM:dd HH:mm:ss` in local time, as EXIF expects.
    static func exifDateString(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// `+02:00`
    static func offsetString(_ date: Date, timeZone: TimeZone) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        return String(format: "%@%02d:%02d", seconds < 0 ? "-" : "+", abs(seconds) / 3600, abs(seconds) % 3600 / 60)
    }

    static func parseExifDate(_ text: String, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let offset, !offset.isEmpty {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssZZZZZ"
            if let date = formatter.date(from: text + offset) { return date }
        }
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }

    /// ISO 6709 as used by QuickTime, e.g. `+53.5511+009.9937/`.
    static func iso6709(_ location: PostLocation) -> String {
        String(format: "%+08.4f%+09.4f/", location.latitude, location.longitude)
    }

    static func parseISO6709(_ text: String) -> PostLocation? {
        guard let match = text.firstMatch(of: /^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)/),
              let latitude = Double(match.1), let longitude = Double(match.2)
        else { return nil }
        return PostLocation(latitude: latitude, longitude: longitude, placeName: nil)
    }
}

enum MetadataError: LocalizedError {
    case unreadable
    case unwritable

    var errorDescription: String? {
        switch self {
        case .unreadable: String(localized: "The file couldn't be read.")
        case .unwritable: String(localized: "The file couldn't be written.")
        }
    }
}
