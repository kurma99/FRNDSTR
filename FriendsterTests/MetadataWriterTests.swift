import AVFoundation
import Foundation
import FriendsterAPI
import ImageIO
import Testing
import UIKit
@testable import Friendster

/// A small real JPEG without any metadata (like the ones the server stores).
private func makeJPEG() -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30), format: format).jpegData(withCompressionQuality: 0.9) { context in
        UIColor.systemPink.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
    }
}

private func properties(of data: Data) throws -> [CFString: Any] {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
}

/// A 1-second H.264 movie without metadata.
private func makeVideo() async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<10 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        adaptor.append(try #require(buffer), withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
    }
    input.markAsFinished()
    await writer.finishWriting()
    return url
}

private let hamburg = PostLocation(latitude: 53.5511, longitude: 9.9937, placeName: "Hamburg, Germany")
private let berlin = TimeZone(identifier: "Europe/Berlin")!
private let sampleDate = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 16:13:20 +02:00

@Suite struct ImageMetadataTests {
    @Test func captionLocationAndDateAreEmbedded() throws {
        let caption = "Grillen im Garten 🌭"
        let output = try MetadataWriter.writeImage(makeJPEG(), metadata: SaveMetadata(caption: caption, location: hamburg, date: sampleDate),
                                                   timeZone: berlin)
        let props = try properties(of: output)

        let iptc = try #require(props[kCGImagePropertyIPTCDictionary] as? [CFString: Any])
        #expect(iptc[kCGImagePropertyIPTCCaptionAbstract] as? String == caption)
        let tiff = try #require(props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        #expect(tiff[kCGImagePropertyTIFFImageDescription] as? String == caption)

        let exif = try #require(props[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:09:21 16:13:20")
        #expect(exif[kCGImagePropertyExifOffsetTimeOriginal] as? String == "+02:00")

        let gps = try #require(props[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        #expect(abs((gps[kCGImagePropertyGPSLatitude] as? Double ?? 0) - 53.5511) < 0.0001)
        #expect(gps[kCGImagePropertyGPSLatitudeRef] as? String == "N")
        #expect(abs((gps[kCGImagePropertyGPSLongitude] as? Double ?? 0) - 9.9937) < 0.0001)
        #expect(gps[kCGImagePropertyGPSLongitudeRef] as? String == "E")

        // Apple Photos reads the XMP description.
        let source = try #require(CGImageSourceCreateWithData(output as CFData, nil))
        let xmp = try #require(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
        #expect(CGImageMetadataCopyTagWithPath(xmp, nil, "dc:description" as CFString) != nil)

        // Pixels are untouched (lossless copy).
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 40)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == 30)
    }

    @Test func optedOutFieldsAreAbsent() throws {
        let output = try MetadataWriter.writeImage(makeJPEG(), metadata: SaveMetadata(caption: nil, location: nil, date: sampleDate))
        let props = try properties(of: output)
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        #expect(iptc?[kCGImagePropertyIPTCCaptionAbstract] == nil)
        // The date is always kept.
        let exif = try #require(props[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] != nil)
    }

    @Test(arguments: [
        PostLocation(latitude: -33.8688, longitude: 151.2093, placeName: nil), // Sydney
        PostLocation(latitude: 40.7128, longitude: -74.0060, placeName: nil),  // New York
    ])
    func captureRoundTripKeepsHemispheres(location: PostLocation) throws {
        let output = try MetadataWriter.writeImage(makeJPEG(), metadata: SaveMetadata(caption: nil, location: location, date: sampleDate),
                                                   timeZone: berlin)
        let source = try #require(CGImageSourceCreateWithData(output as CFData, nil))
        let capture = MetadataWriter.readCapture(fromImage: source)
        let read = try #require(capture.location)
        #expect(abs(read.latitude - location.latitude) < 0.0001)
        #expect(abs(read.longitude - location.longitude) < 0.0001)
        #expect(capture.date == sampleDate)
    }
}

@Suite struct VideoMetadataTests {
    @Test func descriptionLocationAndDateAreEmbedded() async throws {
        let source = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: source) }

        let output = try await MetadataWriter.writeVideo(at: source, metadata: SaveMetadata(caption: "Erster Schritt!", location: hamburg, date: sampleDate))
        defer { try? FileManager.default.removeItem(at: output) }

        let metadata = try await AVURLAsset(url: output).load(.metadata)
        let description = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .quickTimeMetadataDescription).first
        #expect(try await description?.load(.stringValue) == "Erster Schritt!")

        let capture = await MetadataWriter.readCapture(fromVideo: output)
        let location = try #require(capture.location)
        #expect(abs(location.latitude - hamburg.latitude) < 0.001)
        #expect(abs(location.longitude - hamburg.longitude) < 0.001)
    }
}

@Suite struct FormattingTests {
    @Test func iso6709RoundTrip() throws {
        #expect(MetadataWriter.iso6709(hamburg) == "+53.5511+009.9937/")
        let parsed = try #require(MetadataWriter.parseISO6709("-33.8688+151.2093+012.000/"))
        #expect(parsed.latitude == -33.8688)
        #expect(parsed.longitude == 151.2093)
        #expect(MetadataWriter.parseISO6709("garbage") == nil)
    }

    @Test func offsetStringHandlesNegativeZones() {
        let newYork = TimeZone(identifier: "America/New_York")!
        #expect(MetadataWriter.offsetString(sampleDate, timeZone: newYork) == "-04:00")
        #expect(MetadataWriter.offsetString(sampleDate, timeZone: .gmt) == "+00:00")
    }
}
