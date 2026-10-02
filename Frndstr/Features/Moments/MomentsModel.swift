import Foundation
import FrndstrAPI
import Observation
import UIKit

/// Received and sent moments, plus sending.
@Observable
final class MomentsModel {
    private(set) var feed: MomentsFeed?
    /// Friends you have (or could keep) a streak with, longest first.
    private(set) var streaks: [StreakDTO] = []
    /// The family's shared moment time today.
    private(set) var momentTime: Date?
    private(set) var hasLoaded = false
    var errorMessage: String?

    /// Moments this device has already reported as viewed (kept across launches).
    private var viewedIDs: Set<UUID>
    private static let viewedKey = "moments.viewed"

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.viewedKey) ?? []
        viewedIDs = Set(stored.compactMap(UUID.init(uuidString:)))
    }

    var hasPostedToday: Bool { feed?.hasPostedToday ?? false }
    var received: [MomentDTO] { feed?.received ?? [] }
    var sent: [MomentDTO] { feed?.sent ?? [] }

    /// Received moments you haven't opened yet (tab badge).
    var unseenCount: Int { received.filter { !viewedIDs.contains($0.id) }.count }

    func refresh(using app: AppModel) async {
        guard let client = app.client else { return }
        do {
            async let moments = client.moments()
            async let streakList = client.streaks()
            async let time = client.momentTime()
            feed = try await moments
            streaks = (try? await streakList) ?? []
            momentTime = (try? await time)?.today
            errorMessage = nil
            // Keeps the server copy of Memories current (throttled inside).
            Task { await MemoryBackup.shared.sync(using: app) }
        } catch is CancellationError {
            return
        } catch {
            app.handle(error)
            errorMessage = error.localizedDescription
        }
        hasLoaded = true
    }

    func isViewed(_ id: UUID) -> Bool { viewedIDs.contains(id) }

    func markViewed(_ moment: MomentDTO, using app: AppModel) {
        guard !moment.isLocked, viewedIDs.insert(moment.id).inserted, let client = app.client else { return }
        UserDefaults.standard.set(viewedIDs.map(\.uuidString), forKey: Self.viewedKey)
        Task { try? await client.markMomentViewed(moment.id) }
    }

    /// Screenshots can't be blocked on iOS; the sender is told instead.
    func reportScreenshot(of ids: Set<UUID>, using app: AppModel) {
        guard let client = app.client else { return }
        for id in ids { Task { try? await client.reportMomentScreenshot(id) } }
    }

    struct SendResult {
        /// Non-fatal problems (e.g. saving to Photos failed).
        var warnings: [String]
    }

    /// Keeps a local copy first, then uploads. With `shareAsPost` the composite is uploaded too,
    /// but the server only publishes it as a post once the moment has expired.
    func send(_ moment: EditedMoment, to recipients: [UserDTO], location: PostLocation?, shareAsPost: Bool,
              saveToPhotos: Bool, using app: AppModel) async throws -> SendResult {
        guard let client = app.client, let me = app.currentUser else { throw APIError.invalidResponse }
        let caption = moment.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = await Self.prepare(back: moment.back, front: moment.front, layout: moment.layout)
        var warnings: [String] = []

        do {
            try MomentArchive.forUser(me.id).save(
                ArchivedMoment(id: UUID(), createdAt: .now, caption: caption.isEmpty ? nil : caption,
                               recipientNames: recipients.map(\.displayName), layout: moment.layout,
                               location: location),
                back: files.back, front: files.front, composite: files.composite)
        } catch {
            warnings.append(String(localized: "Your copy couldn't be kept on this iPhone."))
        }

        do {
            var postMediaID: UUID?
            if shareAsPost {
                let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).jpg")
                try files.composite.write(to: file)
                defer { try? FileManager.default.removeItem(at: file) }
                postMediaID = try await client.uploadMedia(fileURL: file, contentType: "image/jpeg").id
            }
            _ = try await client.sendMoment(back: files.back, front: files.front, request: CreateMomentRequest(
                caption: caption.isEmpty ? nil : caption, recipientIDs: recipients.map(\.id),
                layout: moment.layout, postMediaID: postMediaID, location: location))
        } catch {
            app.handle(error)
            throw error
        }

        if saveToPhotos {
            do {
                try await PhotoSaver.saveImage(files.composite, metadata: SaveMetadata(
                    caption: caption.isEmpty ? nil : caption, location: location, date: .now))
            } catch {
                warnings.append(error.localizedDescription)
            }
        }

        await refresh(using: app)
        Task { await MemoryBackup.shared.sync(using: app, force: true) }
        // Streak reminder may no longer be needed.
        await Notifier.shared.sync(using: app)
        return SendResult(warnings: warnings)
    }

    /// Resizing and compositing off the main actor.
    @concurrent
    private nonisolated static func prepare(back: UIImage, front: UIImage,
                                            layout: MomentLayout) async -> (back: Data, front: Data, composite: Data) {
        let composite = MomentComposer.composite(back: back, front: front, layout: layout)
        return (MomentComposer.jpeg(back, maxPixel: 2048),
                MomentComposer.jpeg(front, maxPixel: 1440),
                composite.jpegData(compressionQuality: 0.88) ?? Data())
    }
}
