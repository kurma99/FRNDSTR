import CoreLocation
import Foundation
import FRNDSAPI
import Photos

/// What the user chose to embed when saving.
struct SaveOptions: Equatable {
    var includeCaption: Bool
    var includeLocation: Bool
}

/// Persisted choices for "Save to Photos" (see Settings).
enum SaveSettings {
    static let askEachTimeKey = "save.askEachTime"
    static let includeCaptionKey = "save.includeCaption"
    static let includeLocationKey = "save.includeLocation"

    static var askEachTime: Bool { UserDefaults.standard.object(forKey: askEachTimeKey) as? Bool ?? true }

    static var defaults: SaveOptions {
        let store = UserDefaults.standard
        return SaveOptions(includeCaption: store.object(forKey: includeCaptionKey) as? Bool ?? true,
                           includeLocation: store.object(forKey: includeLocationKey) as? Bool ?? true)
    }

    static func remember(_ options: SaveOptions) {
        let store = UserDefaults.standard
        store.set(false, forKey: askEachTimeKey)
        store.set(options.includeCaption, forKey: includeCaptionKey)
        store.set(options.includeLocation, forKey: includeLocationKey)
    }
}

enum PhotoSaverError: LocalizedError {
    case notAuthorized

    var errorDescription: String? {
        String(localized: "FRNDS isn't allowed to add to your photo library. You can change this in Settings › Privacy › Photos.")
    }
}

/// Downloads a post's media and adds it to the photo library with the chosen metadata.
/// Uses add-only access, so FRNDS never reads the user's library.
enum PhotoSaver {
    /// Returns the number of saved items.
    @discardableResult
    static func save(_ post: PostDTO, options: SaveOptions, client: APIClient) async throws -> Int {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw PhotoSaverError.notAuthorized }

        let metadata = SaveMetadata(
            caption: options.includeCaption ? post.caption : nil,
            location: options.includeLocation ? post.location : nil,
            date: post.takenAt ?? post.createdAt
        )
        let clLocation = metadata.location.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }

        for media in post.media {
            let downloaded = try await client.download(media.displayPath)
            defer { try? FileManager.default.removeItem(at: downloaded) }

            switch media.kind {
            case .image:
                let data = try MetadataWriter.writeImage(try Data(contentsOf: downloaded), metadata: metadata)
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: data, options: nil)
                    request.creationDate = metadata.date
                    request.location = clLocation
                }
            case .video:
                let movie = try await MetadataWriter.writeVideo(at: downloaded, metadata: metadata)
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    let resourceOptions = PHAssetResourceCreationOptions()
                    resourceOptions.shouldMoveFile = true
                    request.addResource(with: .video, fileURL: movie, options: resourceOptions)
                    request.creationDate = metadata.date
                    request.location = clLocation
                }
            }
        }
        return post.media.count
    }

    /// Saves an image the app already has (e.g. the sender's own moment).
    static func saveImage(_ data: Data, metadata: SaveMetadata) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw PhotoSaverError.notAuthorized }
        let tagged = try MetadataWriter.writeImage(data, metadata: metadata)
        let location = metadata.location.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: tagged, options: nil)
            request.creationDate = metadata.date
            request.location = location
        }
    }
}
