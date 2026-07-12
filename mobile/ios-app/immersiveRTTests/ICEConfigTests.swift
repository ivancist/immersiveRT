import XCTest
import WebRTC
@testable import immersiveRT

/// Verifies `ICEConfig.iceServers(from:)` maps the pair-ack payload's
/// `ice_servers` JSON (decoded via `SignalingEnvelope.iceServers`, an
/// `[Any]?` of `[String: Any]` entries) into `[RTCIceServer]`, matching the
/// shape the server emits in `room_registry.rs` (`{urls, username?,
/// credential?}`, `urls` always a single string on this server).
final class ICEConfigTests: XCTestCase {

    // MARK: - TURN entry (urls + username + credential)

    func test_turnEntry_mapsWithUsernameAndCredential() {
        let entries: [Any] = [
            [
                "urls": "turn:example.com:3478",
                "username": "1234567890:anonymous",
                "credential": "base64-hmac-value",
            ] as [String: Any]
        ]

        let servers = ICEConfig.iceServers(from: entries)

        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].urlStrings, ["turn:example.com:3478"])
        XCTAssertEqual(servers[0].username, "1234567890:anonymous")
        XCTAssertEqual(servers[0].credential, "base64-hmac-value")
    }

    // MARK: - STUN-only entry (urls only, no credentials)

    func test_stunOnlyEntry_mapsWithNilCredentials() {
        let entries: [Any] = [
            ["urls": "stun:example.com:3478"] as [String: Any]
        ]

        let servers = ICEConfig.iceServers(from: entries)

        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].urlStrings, ["stun:example.com:3478"])
        XCTAssertNil(servers[0].username)
        XCTAssertNil(servers[0].credential)
    }

    // MARK: - Mixed STUN + TURN (matches room_registry.rs's real payload shape)

    func test_mixedStunAndTurnEntries_bothMapCorrectly() {
        let entries: [Any] = [
            ["urls": "stun:example.com:3478"] as [String: Any],
            [
                "urls": "turn:example.com:3478",
                "username": "user",
                "credential": "pass",
            ] as [String: Any],
        ]

        let servers = ICEConfig.iceServers(from: entries)

        XCTAssertEqual(servers.count, 2)
        XCTAssertNil(servers[0].username)
        XCTAssertEqual(servers[1].username, "user")
        XCTAssertEqual(servers[1].credential, "pass")
    }

    // MARK: - Empty / missing input never crashes

    func test_emptyArray_mapsToEmptyArray() {
        XCTAssertEqual(ICEConfig.iceServers(from: []).count, 0)
    }

    func test_nilInput_mapsToEmptyArray() {
        XCTAssertEqual(ICEConfig.iceServers(from: nil).count, 0)
    }

    // MARK: - Malformed entry (missing urls) is skipped, not force-unwrapped

    func test_entryMissingUrls_isSkippedNotCrashed() {
        let entries: [Any] = [
            ["username": "orphan", "credential": "orphan"] as [String: Any]
        ]

        XCTAssertEqual(ICEConfig.iceServers(from: entries).count, 0)
    }

    // MARK: - End-to-end from SignalingEnvelope.iceServers accessor

    func test_fromSignalingEnvelopePairAck_mapsCorrectly() throws {
        let json = """
        {
            "type": "pair-ack",
            "from": "server",
            "to": "phone-uuid",
            "payload": {
                "ice_servers": [
                    { "urls": "stun:example.com:3478" },
                    { "urls": "turn:example.com:3478", "username": "u", "credential": "c" }
                ]
            }
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder().decode(SignalingEnvelope.self, from: json)
        let servers = ICEConfig.iceServers(from: envelope.iceServers)

        XCTAssertEqual(servers.count, 2)
        XCTAssertEqual(servers[0].urlStrings, ["stun:example.com:3478"])
        XCTAssertEqual(servers[1].username, "u")
    }
}
