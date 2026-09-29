@testable import App
import Fluent
import FRNDSAPI
import Testing
import VaporTesting

private func call(_ app: Application, _ method: HTTPMethod, _ path: String, token: String,
                  json: (any Encodable)? = nil) async throws -> (status: HTTPStatus, body: Data) {
    var result: (HTTPStatus, Data) = (.internalServerError, Data())
    try await app.testing().test(method, path, beforeRequest: { req in
        req.headers.bearerAuthorization = BearerAuthorization(token: token)
        if let json {
            req.headers.contentType = .json
            req.body = ByteBuffer(data: try API.makeEncoder().encode(json))
        }
    }, afterResponse: { res in result = (res.status, Data(buffer: res.body)) })
    return result
}

private func value<T: Decodable>(_ type: T.Type, _ response: (status: HTTPStatus, body: Data)) throws -> T {
    #expect(response.status == .ok, "\(String(decoding: response.body, as: UTF8.self))")
    return try API.makeDecoder().decode(T.self, from: response.body)
}

private func id(_ app: Application, _ token: String) async throws -> UUID {
    try value(UserDTO.self, try await call(app, .GET, API.Path.me, token: token)).id
}

@Suite struct StreakCalculatorTests {
    private let days = ServerDay(timeZone: TimeZone(identifier: "Europe/Berlin")!)
    private var calculator: StreakCalculator { StreakCalculator(days: days) }

    /// Wednesday 30 Sep 2026, noon.
    private var today: Date { days.date(forKey: "2026-09-30")!.addingTimeInterval(12 * 3600) }
    private func keys(_ offsets: [Int]) -> Set<String> {
        Set(offsets.map { days.key(for: days.adding(days: -$0, to: today)) })
    }

    @Test func countsConsecutiveMutualDaysAndTodayDoesNotBreak() {
        // Both sent on the last 4 days before today; today only one side so far.
        let result = calculator.streak(aToB: keys([0, 1, 2, 3, 4]), bToA: keys([1, 2, 3, 4]), today: today)
        #expect(result == .init(count: 4, graceUsedThisWeek: false))
        let complete = calculator.streak(aToB: keys([0, 1, 2]), bToA: keys([0, 1, 2]), today: today)
        #expect(complete.count == 3)
    }

    @Test func oneMissedDayPerWeekIsForgiven() {
        // Missed Monday 28 Sep (offset 2), otherwise mutual Tue 29 and Fri 25 … Sun 27.
        let mutual = keys([1, 3, 4, 5])
        let result = calculator.streak(aToB: mutual, bToA: mutual, today: today)
        #expect(result == .init(count: 4, graceUsedThisWeek: true))
    }

    @Test func secondMissInTheSameWeekBreaks() {
        // Week of 28 Sep: missed Mon 28 and Tue 29 → only today's streak counts (none yet).
        let mutual = keys([3, 4, 5])
        #expect(calculator.streak(aToB: mutual, bToA: mutual, today: today).count == 0)
    }

    @Test func missesInDifferentWeeksAreEachForgiven() {
        // Missed Sun 27 (week 39) and Mon 28 (week 40); mutual Tue 29 and Thu 24 … Sat 26.
        let mutual = keys([1, 4, 5, 6])
        #expect(calculator.streak(aToB: mutual, bToA: mutual, today: today).count == 4)
    }

    @Test func oneSidedDaysDoNotCount() {
        #expect(calculator.streak(aToB: keys([1, 2, 3]), bToA: [], today: today).count == 0)
    }
}

@Suite(.enabled(if: ffmpegAvailable, "needs ffmpeg"))
struct InboxTests {
    @Test func eventsReachTheRightPeople() async throws {
        try await withTestApp { app, dir in
            let anna = try await signUp(app, username: "anna")
            let ben = try await signUp(app, username: "ben")
            let annaID = try await id(app, anna), benID = try await id(app, ben)

            // First call only returns a cursor (no flood on a fresh install).
            let start = try value(InboxPage.self, try await call(app, .GET, API.Path.inbox, token: anna))
            #expect(start.events.isEmpty)
            let benStart = try value(InboxPage.self, try await call(app, .GET, API.Path.inbox, token: ben))

            // Friend request → anna; post by ben → anna; comment + reaction by ben on anna's post → anna.
            _ = try await call(app, .POST, API.Path.friend(annaID), token: ben)
            let jpeg = try await makeSample("i.jpg", in: dir, args: ["-f", "lavfi", "-i", "color=gray:s=32x32", "-frames:v", "1"])
            let bensMedia = try await upload(app, token: ben, data: jpeg, type: .jpeg)
            _ = try await createPost(app, token: ben, mediaIDs: [bensMedia.id], caption: "Hallo")
            let annasMedia = try await upload(app, token: anna, data: jpeg, type: .jpeg)
            let annasPost = try await createPost(app, token: anna, mediaIDs: [annasMedia.id], caption: nil)
            _ = try await call(app, .POST, API.Path.comments(annasPost.id), token: ben, json: CreateCommentRequest(text: "Toll"))
            _ = try await call(app, .PUT, API.Path.reaction(annasPost.id), token: ben, json: ReactionRequest(emoji: "🔥"))
            // Changing to the same emoji again must not notify twice.
            _ = try await call(app, .PUT, API.Path.reaction(annasPost.id), token: ben, json: ReactionRequest(emoji: "🔥"))

            let inbox = try value(InboxPage.self, try await call(app, .GET, "\(API.Path.inbox)?since=\(start.cursor)", token: anna))
            #expect(inbox.events.map(\.type) == [.friendRequest, .post, .comment, .reaction])
            #expect(inbox.events.allSatisfy { $0.actor?.id == benID })
            #expect(inbox.events[2].text == "Toll" && inbox.events[3].text == "🔥")

            // Cursor moves on: nothing new next time.
            let again = try value(InboxPage.self, try await call(app, .GET, "\(API.Path.inbox)?since=\(inbox.cursor)", token: anna))
            #expect(again.events.isEmpty)

            // Ben only hears about anna's post, not his own actions.
            let bens = try value(InboxPage.self, try await call(app, .GET, "\(API.Path.inbox)?since=\(benStart.cursor)", token: ben))
            #expect(bens.events.map(\.type) == [.post])
        }
    }
}

@Suite struct MomentTimeTests {
    @Test func sharedTimeIsStableAndInsideTheWindow() async throws {
        try await withTestApp { app, _ in
            let anna = try await signUp(app, username: "anna")
            let ben = try await signUp(app, username: "ben")
            let first = try value(MomentTimeDTO.self, try await call(app, .GET, API.Path.momentTime, token: anna))
            let second = try value(MomentTimeDTO.self, try await call(app, .GET, API.Path.momentTime, token: ben))
            #expect(first == second)

            let days = ServerDay(timeZone: app.appConfig.timeZone)
            for time in [first.today, first.tomorrow] {
                let hour = days.calendar.component(.hour, from: time)
                #expect((9..<21).contains(hour))
            }
            #expect(days.key(for: first.tomorrow) == days.key(for: days.adding(days: 1, to: .now)))
        }
    }
}

@Suite struct StreakEndpointTests {
    @Test func reportsStreaksPerFriend() async throws {
        try await withTestApp { app, _ in
            let anna = try await signUp(app, username: "anna")
            let ben = try await signUp(app, username: "ben")
            let annaID = try await id(app, anna), benID = try await id(app, ben)
            _ = try await call(app, .POST, API.Path.friend(benID), token: anna)
            _ = try await call(app, .POST, API.Path.friend(annaID), token: ben)

            let days = ServerDay(timeZone: app.appConfig.timeZone)
            // Mutual on the previous 3 days; today only anna sent.
            for offset in 1...3 {
                let key = days.key(for: days.adding(days: -offset, to: .now))
                try await MomentDay(senderID: annaID, recipientID: benID, day: key).create(on: app.db)
                try await MomentDay(senderID: benID, recipientID: annaID, day: key).create(on: app.db)
            }
            try await MomentDay(senderID: annaID, recipientID: benID, day: days.key(for: .now)).create(on: app.db)

            let annas = try value([StreakDTO].self, try await call(app, .GET, API.Path.streaks, token: anna))
            #expect(annas.count == 1)
            #expect(annas[0].friend.id == benID && annas[0].count == 3)
            #expect(annas[0].sentToday && !annas[0].receivedToday && annas[0].isAtRisk)
            let bens = try value([StreakDTO].self, try await call(app, .GET, API.Path.streaks, token: ben))
            #expect(!bens[0].sentToday && bens[0].receivedToday)
        }
    }
}
