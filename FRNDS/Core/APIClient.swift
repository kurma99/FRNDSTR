import Foundation
import FRNDSAPI

enum APIError: LocalizedError {
    case server(status: Int, reason: String)
    case unauthorized(reason: String)
    case notFRNDS
    /// Cloudflare Access answered instead of the server: no service token, or a wrong one.
    case cloudflareAccessDenied
    case transport(URLError)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case let .server(_, reason), let .unauthorized(reason):
            reason
        case .notFRNDS:
            String(localized: "That address answered, but it doesn't look like a FRNDS server.")
        case .cloudflareAccessDenied:
            String(localized: "Cloudflare Access blocked the connection. Check the service token's Client ID and Client Secret.")
        case let .transport(error):
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .notConnectedToInternet:
                String(localized: "Can't reach the server. Check the address and that you're on the same network or Tailscale.")
            case .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed:
                String(localized: "Secure connection failed. Try http:// instead of https://.")
            default:
                error.localizedDescription
            }
        case .invalidResponse:
            String(localized: "The server sent an unexpected response.")
        }
    }
}

/// Stateless HTTP client for one server + (optional) session token.
struct APIClient {
    let baseURL: URL
    var token: String?
    /// Service token for servers behind Cloudflare Access.
    var access: CloudflareAccess?

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    private static let uploadSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 30
        return URLSession(configuration: configuration)
    }()

    // MARK: URLs

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var url = baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        return url
    }

    /// Media URL with the token in the query, for players that can't send headers.
    func tokenizedMediaURL(_ path: String) -> URL {
        url(path, query: token.map { [URLQueryItem(name: API.mediaTokenQueryItem, value: $0)] } ?? [])
    }

    // MARK: Endpoints

    func health() async throws -> HealthResponse {
        do {
            return try await send("GET", API.Path.health)
        } catch APIError.invalidResponse, APIError.server(404, _) {
            throw APIError.notFRNDS
        }
    }

    func register(_ body: RegisterRequest) async throws -> AuthResponse {
        try await send("POST", API.Path.register, body: body)
    }

    func login(_ body: LoginRequest) async throws -> AuthResponse {
        try await send("POST", API.Path.login, body: body)
    }

    func logout() async throws {
        let _: Empty = try await send("POST", API.Path.logout)
    }

    func me() async throws -> UserDTO {
        try await send("GET", API.Path.me)
    }

    func feed(cursor: String?, author: UUID? = nil, limit: Int = 10) async throws -> FeedPage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let author { query.append(URLQueryItem(name: "author", value: author.uuidString)) }
        return try await send("GET", API.Path.posts, query: query)
    }

    func createPost(_ body: CreatePostRequest) async throws -> PostDTO {
        try await send("POST", API.Path.posts, body: body)
    }

    func post(_ id: UUID) async throws -> PostDTO {
        try await send("GET", API.Path.post(id))
    }

    func updateCaption(of id: UUID, to caption: String?) async throws -> PostDTO {
        try await send("PATCH", API.Path.post(id), body: UpdatePostRequest(caption: caption))
    }

    func deletePost(_ id: UUID) async throws {
        let _: Empty = try await send("DELETE", API.Path.post(id))
    }

    // MARK: Reactions & comments

    func react(to postID: UUID, with emoji: String) async throws -> ReactionSummary {
        try await send("PUT", API.Path.reaction(postID), body: ReactionRequest(emoji: emoji))
    }

    func removeReaction(from postID: UUID) async throws -> ReactionSummary {
        try await send("DELETE", API.Path.reaction(postID))
    }

    func reactions(for postID: UUID) async throws -> [ReactionDTO] {
        try await send("GET", API.Path.reactions(postID))
    }

    func comments(for postID: UUID) async throws -> [CommentDTO] {
        try await send("GET", API.Path.comments(postID))
    }

    func addComment(_ text: String, to postID: UUID) async throws -> CommentDTO {
        try await send("POST", API.Path.comments(postID), body: CreateCommentRequest(text: text))
    }

    func deleteComment(_ id: UUID) async throws {
        let _: Empty = try await send("DELETE", API.Path.comment(id))
    }

    // MARK: People

    func users() async throws -> [UserDTO] {
        try await send("GET", API.Path.users)
    }

    func profile(_ userID: UUID) async throws -> ProfileDTO {
        try await send("GET", API.Path.user(userID))
    }

    func updateProfile(displayName: String) async throws -> UserDTO {
        try await send("PATCH", API.Path.me, body: UpdateProfileRequest(displayName: displayName))
    }

    func uploadAvatar(jpeg: Data) async throws -> UserDTO {
        var request = makeRequest("PUT", url(API.Path.avatar))
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await perform { try await Self.uploadSession.upload(for: request, from: jpeg) }
        return try decode(data, response)
    }

    func deleteAvatar() async throws -> UserDTO {
        try await send("DELETE", API.Path.avatar)
    }

    func friends() async throws -> FriendsOverview {
        try await send("GET", API.Path.friends)
    }

    /// Sends a friend request, or accepts an incoming one.
    func addFriend(_ userID: UUID) async throws -> ProfileDTO {
        try await send("POST", API.Path.friend(userID))
    }

    /// Cancels, declines or unfriends.
    func removeFriend(_ userID: UUID) async throws -> ProfileDTO {
        try await send("DELETE", API.Path.friend(userID))
    }

    // MARK: Instance

    func config() async throws -> InstanceConfig {
        try await send("GET", API.Path.config)
    }

    // MARK: Notifications & streaks

    /// Without `since` the server only returns a starting cursor.
    func inbox(since cursor: String?) async throws -> InboxPage {
        try await send("GET", API.Path.inbox, query: cursor.map { [URLQueryItem(name: "since", value: $0)] } ?? [])
    }

    func momentTime() async throws -> MomentTimeDTO {
        try await send("GET", API.Path.momentTime)
    }

    func streaks() async throws -> [StreakDTO] {
        try await send("GET", API.Path.streaks)
    }

    // MARK: Moments

    func moments() async throws -> MomentsFeed {
        try await send("GET", API.Path.moments)
    }

    /// Multipart upload: `back` + `front` JPEGs and a JSON `payload`.
    func sendMoment(back: Data, front: Data, request body: CreateMomentRequest) async throws -> MomentDTO {
        try await sendMultipart(API.Path.moments, jpegs: [("back", back), ("front", front)], payload: body)
    }

    func markMomentViewed(_ id: UUID) async throws {
        let _: Empty = try await send("POST", "\(API.Path.moment(id))/view")
    }

    func reportMomentScreenshot(_ id: UUID) async throws {
        let _: Empty = try await send("POST", "\(API.Path.moment(id))/screenshot")
    }

    // MARK: Highlights

    /// Empty unless it's you or a friend.
    func highlights(of userID: UUID) async throws -> [HighlightDTO] {
        try await send("GET", API.Path.highlights(of: userID))
    }

    func createHighlight(title: String) async throws -> HighlightDTO {
        try await send("POST", API.Path.highlights, body: CreateHighlightRequest(title: title))
    }

    func updateHighlight(_ id: UUID, _ body: UpdateHighlightRequest) async throws -> HighlightDTO {
        try await send("PATCH", API.Path.highlight(id), body: body)
    }

    func deleteHighlight(_ id: UUID) async throws {
        let _: Empty = try await send("DELETE", API.Path.highlight(id))
    }

    /// Multipart upload: `image` (composite) + `thumbnail` JPEGs and a JSON `payload`.
    func addHighlightItem(to id: UUID, image: Data, thumbnail: Data, request body: AddHighlightItemRequest) async throws -> HighlightDTO {
        try await sendMultipart(API.Path.highlightItems(id), jpegs: [("image", image), ("thumbnail", thumbnail)], payload: body)
    }

    func removeHighlightItem(_ itemID: UUID, from id: UUID) async throws -> HighlightDTO {
        try await send("DELETE", API.Path.highlightItem(id, itemID))
    }

    /// Downloads a media file to a temporary location (for saving to Photos).
    func download(_ path: String) async throws -> URL {
        let request = makeRequest("GET", url(path))
        let temporary: URL, response: URLResponse
        do {
            (temporary, response) = try await Self.uploadSession.download(for: request)
        } catch let error as URLError {
            throw APIError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if Self.isCloudflareAccessResponse(http) { throw APIError.cloudflareAccessDenied }
        guard http.statusCode == 200 else { throw APIError.invalidResponse }

        let ext = switch response.mimeType {
        case "video/mp4": "mp4"
        case "video/quicktime": "mov"
        case "image/png": "png"
        case "application/zip": "zip"
        default: "jpg"
        }
        // Keep the server's file name (e.g. the takeout zip) when it sends one.
        let name = response.suggestedFilename.flatMap { $0.isEmpty ? nil : $0 } ?? "\(UUID().uuidString).\(ext)"
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name)
        try FileManager.default.moveItem(at: temporary, to: file)
        return file
    }

    // MARK: Uploads

    /// Streams a prepared file (JPEG or MP4) to the server.
    func uploadMedia(fileURL: URL, contentType: String) async throws -> MediaDTO {
        var request = makeRequest("POST", url(API.Path.media))
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await perform { try await Self.uploadSession.upload(for: request, fromFile: fileURL) }
        return try decode(data, response)
    }

    // MARK: Plumbing

    private struct Empty: Decodable {}

    private func send<Response: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = []) async throws -> Response {
        let request = makeRequest(method, url(path, query: query))
        let (data, response) = try await perform { try await Self.session.data(for: request) }
        return try decode(data, response)
    }

    private func send<Response: Decodable>(_ method: String, _ path: String, body: some Encodable) async throws -> Response {
        var request = makeRequest(method, url(path))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try API.makeEncoder().encode(body)
        let (data, response) = try await perform { try await Self.session.data(for: request) }
        return try decode(data, response)
    }

    /// JPEG parts (named `name`, file `name.jpg`) plus a JSON `payload` part.
    private func sendMultipart<Response: Decodable>(_ path: String, jpegs: [(name: String, data: Data)],
                                                    payload: some Encodable) async throws -> Response {
        let boundary = "FRNDS-\(UUID().uuidString)"
        var form = Data()
        func part(_ name: String, filename: String?, type: String, data: Data) {
            let file = filename.map { "; filename=\"\($0)\"" } ?? ""
            form.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\(file)\r\nContent-Type: \(type)\r\n\r\n".utf8))
            form.append(data)
            form.append(Data("\r\n".utf8))
        }
        for jpeg in jpegs { part(jpeg.name, filename: "\(jpeg.name).jpg", type: "image/jpeg", data: jpeg.data) }
        part("payload", filename: nil, type: "application/json", data: try API.makeEncoder().encode(payload))
        form.append(Data("--\(boundary)--\r\n".utf8))

        var request = makeRequest("POST", url(path))
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await perform { try await Self.uploadSession.upload(for: request, from: form) }
        return try decode(data, response)
    }

    private func makeRequest(_ method: String, _ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        for (field, value) in access?.headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    private func perform(_ operation: () async throws -> (Data, URLResponse)) async throws -> (Data, URLResponse) {
        do {
            return try await operation()
        } catch let error as URLError where error.code == .cancelled {
            // The view went away; callers treat this as "nothing happened", not an error.
            throw CancellationError()
        } catch let error as URLError {
            throw APIError.transport(error)
        }
    }

    /// Access either redirects to its login page (`*.cloudflareaccess.com`) or answers 403 itself.
    private static func isCloudflareAccessResponse(_ http: HTTPURLResponse) -> Bool {
        if http.url?.host()?.hasSuffix("cloudflareaccess.com") == true { return true }
        return http.statusCode == 403 && http.value(forHTTPHeaderField: "cf-ray") != nil
            && http.mimeType != "application/json"
    }

    private func decode<Response: Decodable>(_ data: Data, _ response: URLResponse) throws -> Response {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if Self.isCloudflareAccessResponse(http) { throw APIError.cloudflareAccessDenied }

        guard (200..<300).contains(http.statusCode) else {
            let reason = (try? API.makeDecoder().decode(APIErrorResponse.self, from: data))?.reason
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            if http.statusCode == 401 { throw APIError.unauthorized(reason: reason) }
            throw APIError.server(status: http.statusCode, reason: reason)
        }

        if Response.self == Empty.self, let empty = Empty() as? Response {
            return empty
        }
        do {
            return try API.makeDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }
}
