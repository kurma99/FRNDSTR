import Foundation

struct ProcessedMedia: Sendable {
    var originalFile: String
    var displayFile: String
    var thumbFile: String
    var width: Int
    var height: Int
    var duration: Double?
}

enum MediaProcessingError: Error, CustomStringConvertible {
    case noVideoStream
    case toolFailed(tool: String, status: Int32, stderr: String)

    var description: String {
        switch self {
        case .noVideoStream: "No image/video stream found."
        case let .toolFailed(tool, status, stderr): "\(tool) exited with \(status): \(stderr)"
        }
    }
}

/// Uses ffprobe/ffmpeg to read dimensions, create thumbnails and produce web-compatible video.
struct MediaProcessor: Sendable {
    let ffmpeg: String
    let ffprobe: String

    static let thumbnailWidth = 640
    static let maxVideoEdge = 1920

    /// The app uploads orientation-normalized, metadata-free JPEGs, so the original doubles as the display file.
    func processImage(in directory: URL, originalFile: String) async throws -> ProcessedMedia {
        let original = directory.appendingPathComponent(originalFile).path
        let info = try await probe(original)
        guard let stream = info.videoStream else { throw MediaProcessingError.noVideoStream }

        let thumb = "thumb.jpg"
        try await ProcessRunner.run(ffmpeg, [
            "-y", "-v", "error", "-i", original,
            "-vf", "scale='min(\(Self.thumbnailWidth),iw)':-2", "-q:v", "4",
            directory.appendingPathComponent(thumb).path,
        ])

        let (width, height) = stream.displaySize
        return ProcessedMedia(originalFile: originalFile, displayFile: originalFile, thumbFile: thumb,
                              width: width, height: height, duration: nil)
    }

    /// H.264 videos are only remuxed to MP4 (fast); everything else is transcoded.
    func processVideo(in directory: URL, originalFile: String) async throws -> ProcessedMedia {
        let original = directory.appendingPathComponent(originalFile).path
        let display = "display.mp4"
        let displayPath = directory.appendingPathComponent(display).path

        let sourceInfo = try await probe(original)
        guard let sourceStream = sourceInfo.videoStream else { throw MediaProcessingError.noVideoStream }

        var remuxed = false
        if sourceStream.codecName == "h264" {
            do {
                try await ProcessRunner.run(ffmpeg, [
                    "-y", "-v", "error", "-i", original,
                    "-map", "0:v:0", "-map", "0:a:0?", "-c", "copy", "-movflags", "+faststart", displayPath,
                ])
                remuxed = true
            } catch {
                // e.g. PCM audio that MP4 can't hold: fall through to a full transcode.
            }
        }
        if !remuxed {
            let edge = Self.maxVideoEdge
            try await ProcessRunner.run(ffmpeg, [
                "-y", "-v", "error", "-i", original,
                "-map", "0:v:0", "-map", "0:a:0?",
                "-vf", "scale='if(gt(iw,ih),min(\(edge),iw),-2)':'if(gt(iw,ih),-2,min(\(edge),ih))'",
                "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", displayPath,
            ])
        }

        // A remuxed MP4 holds the same streams as the uploaded MP4 (what the app sends), so keeping
        // both would store every video twice. The remux (with faststart) then serves as the original too.
        var storedOriginal = originalFile
        if remuxed, originalFile.hasSuffix(".mp4") {
            try FileManager.default.removeItem(atPath: original)
            storedOriginal = display
        }

        let thumb = "thumb.jpg"
        try await ProcessRunner.run(ffmpeg, [
            "-y", "-v", "error", "-i", displayPath, "-frames:v", "1",
            "-vf", "scale=\(Self.thumbnailWidth):-2", "-q:v", "4",
            directory.appendingPathComponent(thumb).path,
        ])

        let displayInfo = try await probe(displayPath)
        guard let stream = displayInfo.videoStream else { throw MediaProcessingError.noVideoStream }
        let (width, height) = stream.displaySize
        return ProcessedMedia(originalFile: storedOriginal, displayFile: display, thumbFile: thumb,
                              width: width, height: height,
                              duration: displayInfo.format?.duration.flatMap(Double.init))
    }

    private func probe(_ path: String) async throws -> ProbeResult {
        let output = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-print_format", "json", "-show_streams", "-show_format", path,
        ])
        return try JSONDecoder().decode(ProbeResult.self, from: output)
    }
}

// MARK: - ffprobe JSON

struct ProbeResult: Decodable {
    struct Stream: Decodable {
        struct SideData: Decodable { var rotation: Double? }
        var codecType: String?
        var codecName: String?
        var width: Int?
        var height: Int?
        var tags: [String: String]?
        var sideDataList: [SideData]?

        enum CodingKeys: String, CodingKey {
            case codecType = "codec_type", codecName = "codec_name", width, height, tags
            case sideDataList = "side_data_list"
        }

        /// Width/height as shown to the viewer (swapped for 90°/270° rotated phone videos).
        var displaySize: (Int, Int) {
            let sideDataRotation: Double? = sideDataList?.compactMap(\.rotation).first
            let tagRotation: Double? = tags?["rotate"].flatMap { Double($0) }
            let rotation: Double = sideDataRotation ?? tagRotation ?? 0
            let w = width ?? 0, h = height ?? 0
            let quarterTurns = Int(rotation.magnitude.rounded()) % 180
            return quarterTurns == 90 ? (h, w) : (w, h)
        }
    }

    struct Format: Decodable { var duration: String? }

    var streams: [Stream]
    var format: Format?

    var videoStream: Stream? { streams.first { $0.codecType == "video" } }
}

// MARK: - Process helper

enum ProcessRunner {
    /// Runs a tool off the cooperative thread pool and returns its stdout. Throws on non-zero exit.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], currentDirectory: URL? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let currentDirectory { process.currentDirectoryURL = currentDirectory }
                let stdout = Pipe(), stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Drain stderr concurrently so a chatty tool can't block on a full pipe.
                let errorOutput = OutputBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errorOutput.data = stderr.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let output = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                group.wait()

                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    let message = String(decoding: errorOutput.data, as: UTF8.self)
                    continuation.resume(throwing: MediaProcessingError.toolFailed(
                        tool: URL(fileURLWithPath: executable).lastPathComponent,
                        status: process.terminationStatus, stderr: message))
                }
            }
        }
    }

    private final class OutputBox: @unchecked Sendable {
        var data = Data()
    }
}
