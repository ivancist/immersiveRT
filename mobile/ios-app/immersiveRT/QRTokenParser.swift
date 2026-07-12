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
}
