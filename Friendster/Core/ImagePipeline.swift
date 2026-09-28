import UIKit

/// Loads authenticated images with an in-memory cache on top of a large on-disk URL cache.
final class ImagePipeline {
    static let shared = ImagePipeline()

    private let memory = NSCache<NSURL, UIImage>()
    private var inFlight: [URL: Task<UIImage, Error>] = [:]
    private let session: URLSession

    private init() {
        memory.totalCostLimit = 150 * 1024 * 1024
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 30 * 1024 * 1024, diskCapacity: 1024 * 1024 * 1024)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: configuration)
    }

    func cachedImage(for url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    func image(for url: URL, token: String?) async throws -> UIImage {
        if let cached = cachedImage(for: url) { return cached }
        if let running = inFlight[url] { return try await running.value }

        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let session = session
        let task = Task {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            return try await Self.decode(data)
        }
        inFlight[url] = task
        defer { inFlight[url] = nil }

        let image = try await task.value
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        memory.setObject(image, forKey: url as NSURL, cost: cost)
        return image
    }

    /// Decodes off the main actor so scrolling stays smooth.
    @concurrent
    private nonisolated static func decode(_ data: Data) async throws -> UIImage {
        guard let image = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
        return await image.byPreparingForDisplay() ?? image
    }
}
