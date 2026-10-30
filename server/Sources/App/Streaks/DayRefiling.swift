import Fluent
import Foundation
import Vapor

/// Moves old streak days onto the date where each moment was actually taken.
///
/// Until this version, every `MomentDay` was filed under the server's `TIME_ZONE`, so a moment
/// taken at 05:00 in Tokyo landed on the previous Berlin date. Those rows are re-filed from the
/// sender's memory backups once their phone has looked up each place's zone. Moments without a
/// location stay on their `TIME_ZONE` date.
enum DayRefiling {
    /// When per-place days started. Rows filed on earlier `TIME_ZONE` dates are the old kind.
    static let cutoverKey = "day_rule.place_since"

    /// Records the first start of this version. A fresh server has no old rows, so "now" is right there too.
    static func markCutover(on db: any Database) async throws {
        guard try await InstanceSetting.find(cutoverKey, on: db) == nil else { return }
        try await InstanceSetting(key: cutoverKey, value: String(Date().timeIntervalSince1970)).create(on: db)
    }

    static func cutover(on db: any Database) async throws -> Date? {
        guard let setting = try await InstanceSetting.find(cutoverKey, on: db),
              let seconds = Double(setting.value) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Re-files the sender's rows for the old-style date `backup` was filed under. Safe to run again:
    /// it only ever moves rows off that date, and rows already on the right date stay put.
    static func refile(after backup: MemoryBackup, app: Application, on db: any Database) async throws {
        guard let cutover = try await cutover(on: db) else { return }
        let home = ServerDay(timeZone: app.appConfig.timeZone)
        let oldKey = home.key(for: backup.takenAt)
        // The cutover's own date may already hold new-style rows; never touch it or anything later.
        guard oldKey < home.key(for: cutover) else { return }

        let senderID = backup.$owner.id
        let rows = try await MomentDay.query(on: db)
            .filter(\.$senderID == senderID).filter(\.$day == oldKey).all()
        guard !rows.isEmpty else { return }

        // Every backed-up moment the sender took on that old date, with the date it belongs to.
        let backups = try await MemoryBackup.query(on: db).filter(\.$owner.$id == senderID).all()
            .filter { home.key(for: $0.takenAt) == oldKey }
        let placed: [(key: String, names: [String])] = backups.map { memory in
            let zone = memory.timeZoneName.flatMap(TimeZone.init(identifier:))
            let key = zone.map { ServerDay(timeZone: $0).key(for: memory.takenAt) } ?? oldKey
            let names = (try? JSONDecoder().decode([String].self, from: Data(memory.recipientNamesJSON.utf8))) ?? []
            return (key, names)
        }
        let allKeys = Set(placed.map(\.key))

        let recipients = try await User.query(on: db).filter(\.$id ~~ rows.map(\.recipientID)).all()
        let names = Dictionary(recipients.compactMap { user in user.id.map { ($0, user.displayName) } },
                               uniquingKeysWith: { first, _ in first })

        for row in rows {
            // The dates of the moments that went to this friend, by the name the archive recorded.
            var keys = Set(placed.filter { entry in names[row.recipientID].map(entry.names.contains) ?? false }.map(\.key))
            // A renamed friend can't be matched; if all that day's moments agree on a date, that's the one.
            if keys.isEmpty { keys = allKeys.count == 1 ? allKeys : [oldKey] }
            guard keys != [oldKey] else { continue }

            for key in keys where key != oldKey {
                let exists = try await MomentDay.query(on: db)
                    .filter(\.$senderID == senderID).filter(\.$recipientID == row.recipientID).filter(\.$day == key)
                    .count() > 0
                if !exists {
                    try await MomentDay(senderID: senderID, recipientID: row.recipientID, day: key).create(on: db)
                }
            }
            if !keys.contains(oldKey) { try await row.delete(on: db) }
        }
    }
}
