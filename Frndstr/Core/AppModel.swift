import Foundation
import FrndstrAPI
import Observation

/// App-wide session state: which server we talk to and who is signed in.
@Observable
final class AppModel {
    enum Phase {
        case connect
        case auth
        case signedIn
    }

    private(set) var serverURL: URL?
    private(set) var instanceName: String = "Frndstr"
    private(set) var currentUser: UserDTO?
    private(set) var token: String?
    /// Service token when the server sits behind Cloudflare Access.
    private(set) var cloudflareAccess: CloudflareAccess?
    /// Reaction palette configured by the server admin.
    private(set) var reactionEmojis: [String] = API.defaultReactionEmojis
    private(set) var momentWindow: MomentWindow = .default
    /// Where a tapped notification wants to go; `MainTabView` consumes it.
    var pendingRoute: NotificationRoute?

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let serverURL = "serverURL"
        static let instanceName = "instanceName"
        static let currentUser = "currentUser"
        static let token = "sessionToken"
        static let reactionEmojis = "reactionEmojis"
    }

    var phase: Phase {
        if serverURL == nil { return .connect }
        return token != nil && currentUser != nil ? .signedIn : .auth
    }

    /// Client for the current server, authenticated when signed in.
    var client: APIClient? {
        serverURL.map { APIClient(baseURL: $0, token: token, access: cloudflareAccess) }
    }

    init() {
        serverURL = defaults.url(forKey: Keys.serverURL)
        instanceName = defaults.string(forKey: Keys.instanceName) ?? "Frndstr"
        token = Keychain.get(Keys.token)
        cloudflareAccess = CloudflareAccess.load()
        if let palette = defaults.stringArray(forKey: Keys.reactionEmojis), !palette.isEmpty {
            reactionEmojis = palette
        }
        if let data = defaults.data(forKey: Keys.currentUser) {
            currentUser = try? API.makeDecoder().decode(UserDTO.self, from: data)
        }
    }

    // MARK: Server

    /// Pass `access` for servers behind Cloudflare Access (e.g. a Cloudflare Tunnel).
    func connect(to input: String, access: CloudflareAccess? = nil) async throws {
        guard let url = ServerAddress.parse(input) else {
            throw APIError.server(status: 0, reason: String(localized: "Please enter an address like 192.168.1.20:8080."))
        }
        let health = try await APIClient(baseURL: url, access: access).health()
        serverURL = url
        cloudflareAccess = access
        CloudflareAccess.save(access)
        instanceName = health.instanceName
        defaults.set(url, forKey: Keys.serverURL)
        defaults.set(health.instanceName, forKey: Keys.instanceName)
    }

    func disconnectServer() {
        clearSession()
        serverURL = nil
        cloudflareAccess = nil
        CloudflareAccess.save(nil)
        defaults.removeObject(forKey: Keys.serverURL)
    }

    // MARK: Auth

    func login(username: String, password: String) async throws {
        guard let client else { return }
        apply(try await client.login(LoginRequest(username: username, password: password)))
    }

    func register(inviteCode: String, username: String, displayName: String, password: String) async throws {
        guard let client else { return }
        let request = RegisterRequest(inviteCode: inviteCode, username: username, displayName: displayName, password: password)
        apply(try await client.register(request))
    }

    func logout() async {
        try? await client?.logout()
        Notifier.shared.removeAll()
        clearSession()
    }

    /// Refreshes the profile; signs out if the server no longer accepts the token.
    func refreshCurrentUser() async {
        guard phase == .signedIn, let client else { return }
        do {
            let user = try await client.me()
            store(user: user)
        } catch {
            handle(error)
        }
    }

    var isAdmin: Bool { currentUser?.isAdmin == true }

    /// Loads instance settings such as the reaction palette.
    func refreshConfig() async {
        guard phase == .signedIn, let client else { return }
        do {
            apply(try await client.config())
        } catch {
            handle(error)
        }
    }

    /// The server's web dashboard (admins manage users, invites and settings there).
    var adminDashboardURL: URL? { serverURL?.appending(path: "admin") }

    private func apply(_ config: InstanceConfig) {
        reactionEmojis = config.reactionEmojis
        momentWindow = config.momentWindow ?? .default
        instanceName = config.instanceName
        defaults.set(config.reactionEmojis, forKey: Keys.reactionEmojis)
        defaults.set(config.instanceName, forKey: Keys.instanceName)
    }

    /// Call with errors from authenticated requests.
    func handle(_ error: Error) {
        if case APIError.unauthorized = error {
            clearSession()
        }
    }

    private func apply(_ response: AuthResponse) {
        token = response.token
        Keychain.set(response.token, for: Keys.token)
        store(user: response.user)
    }

    /// Call after the user edited their profile.
    func updateCurrentUser(_ user: UserDTO) {
        store(user: user)
    }

    private func store(user: UserDTO) {
        currentUser = user
        defaults.set(try? API.makeEncoder().encode(user), forKey: Keys.currentUser)
    }

    private func clearSession() {
        token = nil
        currentUser = nil
        Keychain.set(nil, for: Keys.token)
        defaults.removeObject(forKey: Keys.currentUser)
    }
}
