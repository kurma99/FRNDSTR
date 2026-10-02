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

    /// Where a post's or moment's location comes from, shown so it's never a surprise.
    enum LocationSource: Equatable {
        /// The GPS position saved in the photo or video itself.
        case photo
        /// Where the phone is right now.
        case currentPosition
    }

    enum LocationState: Equatable {
        case off
        /// Photos are still loading; one of them may carry its own location.
        case checkingPhotos
        case locating(LocationSource)
        case found(PostLocation, LocationSource)
        case failed(String)
    }

    var items: [Item] = []
    var caption = ""
    private(set) var locationState: LocationState = .off
    private var wantsLocation = false
    @ObservationIgnored private var locationTask: Task<Void, Never>?
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
        updateLocation()
    }

    func add(_ result: CameraResult) {
        guard remainingSlots > 0 else { return }
        let item = Item(pickerItem: nil)
        items.append(item)
        updateLocation()
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
        updateLocation()
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
        updateLocation()
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

    func setLocationEnabled(_ enabled: Bool) {
        wantsLocation = enabled
        updateLocation()
    }

    /// Opt-in: uses the first photo's own GPS if it has one, otherwise the current position.
    /// Re-checked whenever photos are added, removed or finish loading.
    private func updateLocation() {
        guard wantsLocation else {
            locationTask?.cancel()
            locationState = .off
            return
        }
        if items.contains(where: { if case .preparing = $0.state { true } else { false } }) {
            locationTask?.cancel()
            locationState = .checkingPhotos
            return
        }

        let embedded = items.lazy.compactMap { $0.prepared?.capturedLocation }.first
        let source: LocationSource = embedded == nil ? .currentPosition : .photo
        // Already showing (or looking up) the right place: don't start over.
        switch locationState {
        case let .found(location, current) where current == source:
            if source == .currentPosition
                || (location.latitude == embedded?.latitude && location.longitude == embedded?.longitude) { return }
        case .locating(.currentPosition) where source == .currentPosition:
            return
        default:
            break
        }

        locationTask?.cancel()
        locationState = .locating(source)
        locationTask = Task {
            do {
                let coordinate: PostLocation
                if let embedded {
                    coordinate = embedded
                } else {
                    let current = try await LocationProvider.currentLocation()
                    coordinate = PostLocation(latitude: current.coordinate.latitude,
                                              longitude: current.coordinate.longitude, placeName: nil)
                }
                let named = await LocationProvider.named(coordinate)
                guard !Task.isCancelled else { return }
                locationState = .found(named, source)
            } catch {
                guard !Task.isCancelled else { return }
                locationState = .failed(error.localizedDescription)
            }
        }
    }

    private var postLocation: PostLocation? {
        if case let .found(location, _) = locationState { location } else { nil }
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
