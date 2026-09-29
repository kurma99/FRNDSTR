import Foundation

/// A Cloudflare Access service token, for servers published through a Cloudflare Tunnel behind Access.
/// Cloudflare checks it at the edge, so the FRNDS server itself never sees it.
nonisolated struct CloudflareAccess: Equatable, Sendable {
    var clientID: String
    var clientSecret: String

    /// Sent with every request so Cloudflare lets it through to the server.
    var headers: [String: String] {
        ["CF-Access-Client-Id": clientID, "CF-Access-Client-Secret": clientSecret]
    }

    /// Returns nil unless both parts are filled in.
    init?(clientID: String, clientSecret: String) {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty else { return nil }
        self.clientID = id
        self.clientSecret = secret
    }

    // MARK: Storage

    private static let idAccount = "cfAccessClientID"
    private static let secretAccount = "cfAccessClientSecret"

    static func load() -> CloudflareAccess? {
        guard let id = Keychain.get(idAccount), let secret = Keychain.get(secretAccount) else { return nil }
        return CloudflareAccess(clientID: id, clientSecret: secret)
    }

    static func save(_ access: CloudflareAccess?) {
        Keychain.set(access?.clientID, for: idAccount)
        Keychain.set(access?.clientSecret, for: secretAccount)
    }

    /// Cookies for players that can't send custom headers. After a request with a valid service token,
    /// Cloudflare sets a `CF_Authorization` cookie, which `URLSession` keeps in the shared cookie storage.
    static func cookies(for url: URL) -> [HTTPCookie] {
        HTTPCookieStorage.shared.cookies(for: url) ?? []
    }
}
