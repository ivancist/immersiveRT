import Foundation

/// Extracts the session token from a scanned QR code payload,
/// expected in the form of a URL with a "token" query parameter
/// (e.g. "https://example.com/join?token=abc123").
enum QRTokenParser {
    static func token(from payload: String) -> String? {
        guard let components = URLComponents(string: payload),
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty else {
            return nil
        }
        return token
    }

    /// Extracts the server host (no port, no scheme, no path) from a scanned
    /// QR code payload, e.g. `"https://192.168.1.5/phone?token=abc"` ->
    /// `"192.168.1.5"`. The native app has no `location.hostname` equivalent
    /// (RESEARCH.md Pitfall 5) — this host string is threaded into WT/WS URL
    /// construction (`https://{host}:4433`, `wss://{host}:9090`) in later
    /// plans, replacing every `location.hostname` reference from `phone.ts`.
    static func host(from payload: String) -> String? {
        guard let host = URLComponents(string: payload)?.host, !host.isEmpty else {
            return nil
        }
        return host
    }
}
