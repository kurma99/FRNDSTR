import FrndstrAPI
import SwiftUI
import UIKit

/// Settings › Your data: one zip with everything you own — your posts and highlights (from the server)
/// and your moments (from this iPhone's Memories archive).
struct DataExportSection: View {
    @Environment(AppModel.self) private var app
    @State private var isWorking = false
    @State private var shareItem: ShareItem?
    @State private var errorMessage: String?

    struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        Section {
            Button(action: export) {
                HStack {
                    Label("Download my data", systemImage: "square.and.arrow.down.on.square")
                    Spacer()
                    if isWorking { ProgressView() }
                }
            }
            .disabled(isWorking)
            .accessibilityIdentifier("exportDataButton")
            .sheet(item: $shareItem) { item in
                ShareSheet(url: item.url)
                    .ignoresSafeArea()
            }
            .alert("Export failed", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        } header: {
            Text("Your data")
        } footer: {
            Text("One zip with your posts (caption, place and date written into the photos, comments and reactions in posts.json), your highlights, and all your moments from this iPhone.")
        }
    }

    private func export() {
        guard let client = app.client, let user = app.currentUser else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let serverZip = try await client.download(API.Path.takeout)
                let url = try await Takeout.build(serverZip: serverZip, archive: MomentArchive.forUser(user.id),
                                                  username: user.username)
                shareItem = ShareItem(url: url)
            } catch is CancellationError {
                return
            } catch {
                app.handle(error)
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Puts the server's zip and a readable copy of the Memories archive into one folder and zips it.
/// iOS has no unzip API, so the server part stays a zip inside the zip.
nonisolated enum Takeout {
    struct ExportedMoment: Codable {
        var takenAt: Date
        var caption: String?
        var sentTo: [String]
        var files: [String]
    }

    /// Returns the finished zip in a temporary folder.
    @concurrent
    static func build(serverZip: URL, archive: MomentArchive, username: String, now: Date = .now) async throws -> URL {
        let stamp = now.formatted(.iso8601.year().month().day())
        let name = "frndstr-\(username)-\(stamp)"
        let work = FileManager.default.temporaryDirectory.appending(path: "takeout-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = work.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.moveItem(at: serverZip, to: root.appending(path: "posts-and-highlights.zip"))
        let moments = try exportMoments(from: archive, to: root.appending(path: "moments", directoryHint: .isDirectory))

        let encoder = API.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(moments).write(to: root.appending(path: "moments.json"))
        try Data("""
        Frndstr export for @\(username)

        posts-and-highlights.zip  from the server: your posts (photos and videos with caption,
                                  place and date written into them), posts.json with comments
                                  and reactions, your highlights and profile.json.
        moments/                  every moment you sent, from this iPhone: moment.jpg (as your
                                  friends saw it, with caption and date) plus back.jpg and front.jpg.
        moments.json              date, caption and recipients of each moment.

        """.utf8).write(to: root.appending(path: "README.txt"))

        return try zip(root, to: work.appending(path: "\(name).zip"))
    }

    /// One dated folder per moment. Returns what was exported, oldest first.
    static func exportMoments(from archive: MomentArchive, to folder: URL) throws -> [ExportedMoment] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let format = Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)_\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)",
            timeZone: .current, calendar: Calendar(identifier: .gregorian))

        var exported: [ExportedMoment] = []
        for memory in archive.all().reversed() {
            let folderName = "\(memory.createdAt.formatted(format))_\(memory.id.uuidString.prefix(8))"
            let target = folder.appending(path: folderName, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            var files: [String] = []
            let parts: [(MomentArchive.Variant, String)] = [(.composite, "moment.jpg"), (.back, "back.jpg"), (.front, "front.jpg")]
            for (variant, fileName) in parts {
                guard var data = try? Data(contentsOf: archive.fileURL(for: memory.id, variant)) else { continue }
                if variant == .composite {
                    data = (try? MetadataWriter.writeImage(data, metadata: SaveMetadata(
                        caption: memory.caption, location: nil, date: memory.createdAt))) ?? data
                }
                try data.write(to: target.appending(path: fileName))
                files.append("moments/\(folderName)/\(fileName)")
            }
            exported.append(ExportedMoment(takenAt: memory.createdAt, caption: memory.caption,
                                           sentTo: memory.recipientNames, files: files))
        }
        return exported
    }

    /// Uses the system's "zip for uploading" coordination, so no zip library is needed.
    static func zip(_ folder: URL, to destination: URL) throws -> URL {
        var coordinationError: NSError?
        var result: Result<URL, Error> = .failure(CocoaError(.fileWriteUnknown))
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { zipped in
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: zipped, to: destination)
                result = .success(destination)
            } catch {
                result = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
}

/// The system share sheet (AirDrop, Files, …).
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
