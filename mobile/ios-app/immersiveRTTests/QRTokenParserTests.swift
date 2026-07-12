import XCTest
@testable import immersiveRT

/// Covers `QRTokenParser.host(from:)` (new, threads the scanned host into
/// WT/WS URL construction — RESEARCH.md Pitfall 5) and confirms the existing
/// `token(from:)` behavior is unchanged.
final class QRTokenParserTests: XCTestCase {

    // MARK: - host(from:)

    func test_host_extractsHostOnly_noPort() {
        XCTAssertEqual(
            QRTokenParser.host(from: "https://192.168.1.5/phone?token=abc"),
            "192.168.1.5"
        )
    }

    func test_host_extractsHostOnly_excludesPort() {
        XCTAssertEqual(
            QRTokenParser.host(from: "https://demo.local:8443/phone?token=abc"),
            "demo.local"
        )
    }

    func test_host_returnsNil_forGarbageInput() {
        XCTAssertNil(QRTokenParser.host(from: "not a url"))
    }

    // MARK: - token(from:) — unchanged existing behavior

    func test_token_stillExtractsToken() {
        XCTAssertEqual(
            QRTokenParser.token(from: "https://192.168.1.5/phone?token=abc123"),
            "abc123"
        )
    }

    func test_token_returnsNil_whenMissing() {
        XCTAssertNil(QRTokenParser.token(from: "https://192.168.1.5/phone"))
    }

    func test_token_returnsNil_forGarbageInput() {
        XCTAssertNil(QRTokenParser.token(from: "not a url"))
    }
}
