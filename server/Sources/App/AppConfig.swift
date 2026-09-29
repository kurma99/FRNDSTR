import Vapor

/// Runtime configuration, read from environment variables (see `.env.example`).
struct AppConfig: Sendable {
    var instanceName: String
    /// Holds the SQLite database and the media folder. Mounted as a volume in Docker.
    var dataDirectory: String
    var ffmpegPath: String
    var ffprobePath: String
    /// Defines "today" for the moments rule (and streaks later). Set `TIME_ZONE`, e.g. `Europe/Berlin`.
    var timeZone: TimeZone
    var zipPath: String = AppConfig.findExecutable("zip") ?? "/usr/bin/zip"
    /// Optional: writes caption/location into photos in takeout zips.
    var exiftoolPath: String? = AppConfig.findExecutable("exiftool")

    var databasePath: String { dataDirectory + "/friendster.sqlite" }
    var mediaDirectory: String { dataDirectory + "/media" }

    static func fromEnvironment() -> AppConfig {
        AppConfig(
            instanceName: Environment.get("INSTANCE_NAME") ?? "Frndstr",
            dataDirectory: Environment.get("DATA_DIR") ?? "./data",
            ffmpegPath: Environment.get("FFMPEG_PATH") ?? findExecutable("ffmpeg") ?? "/usr/bin/ffmpeg",
            ffprobePath: Environment.get("FFPROBE_PATH") ?? findExecutable("ffprobe") ?? "/usr/bin/ffprobe",
            timeZone: Environment.get("TIME_ZONE").flatMap(TimeZone.init(identifier:)) ?? Self.defaultTimeZone
        )
    }

    /// Used when `TIME_ZONE` is unset or invalid (Docker containers would otherwise run in UTC).
    static let defaultTimeZone = TimeZone(identifier: "Europe/Berlin") ?? .current

    /// Looks up an executable in `$PATH` (plus Homebrew's prefix, which is often missing for GUI launches).
    static func findExecutable(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let directories = path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        return directories
            .map { $0 + "/" + name }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

extension Application {
    private struct AppConfigKey: StorageKey {
        typealias Value = AppConfig
    }

    var appConfig: AppConfig {
        get {
            guard let config = storage[AppConfigKey.self] else {
                fatalError("AppConfig not set. Call configure(_:) first.")
            }
            return config
        }
        set { storage[AppConfigKey.self] = newValue }
    }
}
