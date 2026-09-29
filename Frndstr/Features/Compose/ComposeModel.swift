import FrndstrAPI
import Observation
import PhotosUI
import SwiftUI
import UIKit

/// State for creating a post: picked items are prepared in the background while the user writes the caption.
@Observable
final class ComposeModel {
    struct Item: Identifiable {
        enum State {
            case preparing
            case ready(PreparedMedia)
            case failed(String)
        }

        let id = UUID()
        /// The picker selection this came from, `nil` for camera captures.
        let pickerItem: PhotosPickerItem?
        var state: State = .preparing

        var prepared: PreparedMedia? {
            if case let .ready(media) = state { media } else { nil }
        }
    }

    enum CameraResult {
        case photo(UIImage)
        case video(URL)
    }

    enum LocationState: Equatable {
        case off
        case locating
        case found(PostLocation)
        case failed(String)
    }

    var items: [Item] = []
    var caption = ""
    private(set) var locationState: LocationState = .off
    private(set) var isUploading = false
    private(set) var uploadProgress: Double = 0
    var errorMessage: String?

    var canShare: Bool {
        !items.isEmpty && items.allSatisfy { $0.prepared != nil } && !isUploading
            && caption.count <= API.Limits.maxCaptionLength
    }

    var remainingSlots: Int { API.Limits.maxMediaPerPost - items.count }

    /// Whether cancelling would throw away work.
    var hasContent: Bool { !items.isEmpty || !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: Adding media

    /// Syncs with the PhotosPicker selection: imports new picks and drops deselected ones.
    func syncPickerSelection(_ selection: [PhotosPickerItem]) {
        // PhotosPickerItem is Equatable; its itemIdentifier is nil without photo library access, so don't rely on it.
        items.removeAll { item in
            guard let pickerItem = item.pickerItem else { return false }
            return !selection.contains(pickerItem)
        }

        let known = items.compactMap(\.pickerItem)
        for pickerItem in selection where items.count < API.Limits.maxMediaPerPost {
            guard !known.contains(pickerItem) else { continue }
            let item = Item(pickerItem: pickerItem)
            items.append(item)
            Task { await prepare(item.id) { try await Self.load(pickerItem) } }
        }
    }

    func add(_ result: CameraResult) {
        guard remainingSlots > 0 else { return }
        let item = Item(pickerItem: nil)
        items.append(item)
        Task {
            await prepare(item.id) {
                switch result {
                case let .photo(image): try await MediaPreparer.prepareImage(image)
                case let .video(url): try await MediaPreparer.prepareVideo(at: url)
                }
            }
        }
    }

    func remove(_ id: Item.ID) {
        items.removeAll { $0.id == id }
    }

    private func prepare(_ id: Item.ID, _ work: () async throws -> PreparedMedia) async {
        let state: Item.State
        do {
            state = .ready(try await work())
        } catch {
            state = .failed(error.localizedDescription)
        }
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].state = state
        }
    }

    private static func load(_ pickerItem: PhotosPickerItem) async throws -> PreparedMedia {
        if pickerItem.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
            guard let movie = try await pickerItem.loadTransferable(type: PickedMovie.self) else {
                throw MediaPreparationError.exportFailed
            }
            defer { try? FileManager.default.removeItem(at: movie.url) }
            return try await MediaPreparer.prepareVideo(at: movie.url)
        }
        guard let data = try await pickerItem.loadTransferable(type: Data.self) else {
            throw MediaPreparationError.unreadableImage
        }
        return try await MediaPreparer.prepareImage(data: data)
    }

    // MARK: Location

    /// Opt-in: uses the first photo's own GPS if it has one, otherwise the current location.
    func setLocationEnabled(_ enabled: Bool) async {
        guard enabled else {
            locationState = .off
            return
        }
        locationState = .locating
        do {
            let coordinate: PostLocation
            if let embedded = items.lazy.compactMap({ $0.prepared?.capturedLocation }).first {
                coordinate = embedded
            } else {
                let current = try await LocationProvider.currentLocation()
                coordinate = PostLocation(latitude: current.coordinate.latitude,
                                          longitude: current.coordinate.longitude, placeName: nil)
            }
            let named = await LocationProvider.named(coordinate)
            // The user may have switched it off meanwhile.
            if locationState == .locating { locationState = .found(named) }
        } catch {
            if locationState == .locating { locationState = .failed(error.localizedDescription) }
        }
    }

    private var postLocation: PostLocation? {
        if case let .found(location) = locationState { location } else { nil }
    }

    // MARK: Sharing

    /// Uploads each file, then creates the post. Returns the post on success.
    func share(using app: AppModel) async -> PostDTO? {
        guard canShare, let client = app.client else { return nil }
        isUploading = true
        uploadProgress = 0
        defer { isUploading = false }

        let files = items.compactMap(\.prepared)
        do {
            var mediaIDs: [UUID] = []
            for (index, file) in files.enumerated() {
                let media = try await client.uploadMedia(fileURL: file.fileURL, contentType: file.contentType)
                mediaIDs.append(media.id)
                uploadProgress = Double(index + 1) / Double(files.count + 1)
            }
            let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
            let request = CreatePostRequest(
                caption: trimmed.isEmpty ? nil : trimmed,
                mediaIDs: mediaIDs,
                location: postLocation,
                takenAt: files.lazy.compactMap(\.capturedAt).first
            )
            let post = try await client.createPost(request)
            uploadProgress = 1
            cleanUpFiles()
            return post
        } catch {
            app.handle(error)
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func cleanUpFiles() {
        for file in items.compactMap(\.prepared) {
            try? FileManager.default.removeItem(at: file.fileURL)
        }
    }
}
