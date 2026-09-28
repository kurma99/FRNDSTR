import Foundation

enum ServerAddress {
    /// Turns user input like `192.168.1.20:8080`, `nas.tail1234.ts.net:8080` or `https://photos.example.com`
    /// into a base URL. Plain `http` is the default because Tailscale/LAN setups usually have no certificate.
    static func parse(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "http://" + text
        }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty
        else { return nil }

        components.scheme = scheme
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Short form for display, e.g. `192.168.1.20:8080`.
    static func displayString(for url: URL) -> String {
        var text = url.host() ?? url.absoluteString
        if let port = url.port { text += ":\(port)" }
        return url.scheme == "https" ? "https://" + text : text
    }
}
