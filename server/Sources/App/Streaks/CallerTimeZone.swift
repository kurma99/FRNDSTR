import FrndstrAPI
import Vapor

extension Request {
    /// Where the signed-in caller is: the zone their app reports (`Frndstr-Time-Zone`), else the
    /// last one it reported, else the instance's `TIME_ZONE`. Older builds send no header, so
    /// people the server has never heard from count as being in the instance zone.
    var callerTimeZone: TimeZone {
        if let reported = reportedTimeZone { return reported }
        let fallback = application.appConfig.timeZone
        return auth.get(User.self)?.timeZone(default: fallback) ?? fallback
    }

    /// `callerTimeZone`, and remembers a newly reported zone on the user so the server still knows
    /// where someone is between requests (their friends' streaks need it).
    func rememberCallerTimeZone() async throws -> TimeZone {
        if let reported = reportedTimeZone, let user = auth.get(User.self), user.timeZoneName != reported.identifier {
            user.timeZoneName = reported.identifier
            try await user.save(on: db)
        }
        return callerTimeZone
    }

    private var reportedTimeZone: TimeZone? {
        headers.first(name: API.timeZoneHeader).flatMap(TimeZone.init(identifier:))
    }
}
