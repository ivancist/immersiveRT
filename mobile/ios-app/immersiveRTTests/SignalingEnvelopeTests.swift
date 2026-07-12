import XCTest
@testable import immersiveRT

final class SignalingEnvelopeTests: XCTestCase {

    // MARK: - Encoding

    func test_encodeRegisterEnvelope_producesExactWireShape() throws {
        let envelope = SignalingEnvelope(type: "register", from: "uuid", to: "", payload: [:])
        let data = try JSONEncoder().encode(envelope)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(json["type"] as? String, "register")
        XCTAssertEqual(json["from"] as? String, "uuid")
        XCTAssertEqual(json["to"] as? String, "")
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        XCTAssertTrue(payload.isEmpty)
        // Exactly these four top-level keys — no camelCase transformation, no extras.
        XCTAssertEqual(Set(json.keys), Set(["type", "from", "to", "payload"]))
    }

    // MARK: - Decoding pair-ack

    private let pairAckFixture = """
    {
        "type": "pair-ack",
        "from": "server",
        "to": "phone-uuid",
        "payload": {
            "slot": 2,
            "room_code": "ABCD12",
            "ice_servers": [
                { "urls": "stun:example.com:3478" }
            ],
            "peers": [
                { "id": "desktop-1", "slot": 1, "username": "alice" }
            ],
            "reconnect_token": "opaque-token-value"
        }
    }
    """.data(using: .utf8)!

    func test_decodePairAck_roundTripsWithoutLoss() throws {
        let envelope = try JSONDecoder().decode(SignalingEnvelope.self, from: pairAckFixture)

        XCTAssertEqual(envelope.type, "pair-ack")
        XCTAssertEqual(envelope.from, "server")
        XCTAssertEqual(envelope.to, "phone-uuid")
    }

    func test_decodePairAck_exposesTypedAccessors() throws {
        let envelope = try JSONDecoder().decode(SignalingEnvelope.self, from: pairAckFixture)

        XCTAssertEqual(envelope.slot, 2)
        XCTAssertEqual(envelope.roomCode, "ABCD12")
        XCTAssertEqual(envelope.iceServers?.count, 1)
        XCTAssertEqual(envelope.peers?.count, 1)
        XCTAssertEqual(envelope.reconnectToken, "opaque-token-value")
    }

    func test_decodePairAck_keysStaySnakeCase_notCamelCase() throws {
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: pairAckFixture) as? [String: Any]
        )
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])

        // Verbatim snake_case keys must be present — camelCase transformation would drop these.
        XCTAssertNotNil(payload["reconnect_token"], "reconnect_token must survive verbatim, not reconnectToken")
        XCTAssertNil(payload["reconnectToken"], "no camelCase transformation should be applied")
        XCTAssertNotNil(payload["room_code"])
        XCTAssertNil(payload["roomCode"])
        XCTAssertNotNil(payload["ice_servers"])
        XCTAssertNil(payload["iceServers"])
    }

    // MARK: - Known message types

    func test_signalingType_knownConstants() {
        XCTAssertEqual(SignalingEnvelope.SignalingType.register, "register")
        XCTAssertEqual(SignalingEnvelope.SignalingType.pair, "pair")
        XCTAssertEqual(SignalingEnvelope.SignalingType.pairAck, "pair-ack")
        XCTAssertEqual(SignalingEnvelope.SignalingType.pairError, "pair-error")
        XCTAssertEqual(SignalingEnvelope.SignalingType.reconnect, "reconnect")
        XCTAssertEqual(SignalingEnvelope.SignalingType.joinAck, "join-ack")
        XCTAssertEqual(SignalingEnvelope.SignalingType.joinError, "join-error")
        XCTAssertEqual(SignalingEnvelope.SignalingType.heartbeat, "heartbeat")
        XCTAssertEqual(SignalingEnvelope.SignalingType.offer, "offer")
        XCTAssertEqual(SignalingEnvelope.SignalingType.answer, "answer")
        XCTAssertEqual(SignalingEnvelope.SignalingType.iceCandidate, "ice-candidate")
        XCTAssertEqual(SignalingEnvelope.SignalingType.rtcChannelReady, "rtc-channel-ready")
        XCTAssertEqual(SignalingEnvelope.SignalingType.phoneState, "phone-state")
        XCTAssertEqual(SignalingEnvelope.SignalingType.playerReady, "player-ready")
        XCTAssertEqual(SignalingEnvelope.SignalingType.peerJoined, "peer-joined")
        XCTAssertEqual(SignalingEnvelope.SignalingType.peerLeft, "peer-left")
    }
}

// MARK: - AnyCodable

final class AnyCodableTests: XCTestCase {

    func test_roundTrips_nestedObject() throws {
        let json = """
        { "a": 1, "b": { "c": "hello", "d": true } }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode([String: AnyCodable].self, from: json)
        let reencoded = try JSONEncoder().encode(decoded)
        let roundTripped = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        )

        XCTAssertEqual(roundTripped["a"] as? Int, 1)
        let nested = try XCTUnwrap(roundTripped["b"] as? [String: Any])
        XCTAssertEqual(nested["c"] as? String, "hello")
        XCTAssertEqual(nested["d"] as? Bool, true)
    }

    func test_roundTrips_array() throws {
        let json = "[1, 2, 3, \"four\"]".data(using: .utf8)!
        let decoded = try JSONDecoder().decode([AnyCodable].self, from: json)
        let reencoded = try JSONEncoder().encode(decoded)
        let roundTripped = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: reencoded) as? [Any]
        )

        XCTAssertEqual(roundTripped.count, 4)
        XCTAssertEqual(roundTripped[0] as? Int, 1)
        XCTAssertEqual(roundTripped[3] as? String, "four")
    }

    func test_roundTrips_string() throws {
        let value = AnyCodable("hello world")
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.value as? String, "hello world")
    }

    func test_roundTrips_intAndDouble() throws {
        let intValue = AnyCodable(42)
        let intData = try JSONEncoder().encode(intValue)
        let intDecoded = try JSONDecoder().decode(AnyCodable.self, from: intData)
        XCTAssertEqual(intDecoded.value as? Int, 42)

        let doubleValue = AnyCodable(3.14)
        let doubleData = try JSONEncoder().encode(doubleValue)
        let doubleDecoded = try JSONDecoder().decode(AnyCodable.self, from: doubleData)
        XCTAssertEqual(doubleDecoded.value as? Double, 3.14)
    }

    func test_roundTrips_bool() throws {
        let value = AnyCodable(true)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.value as? Bool, true)
    }

    func test_roundTrips_null() throws {
        let data = "null".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        let reencoded = try JSONEncoder().encode(decoded)
        XCTAssertEqual(String(data: reencoded, encoding: .utf8), "null")
    }
}
