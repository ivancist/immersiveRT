import XCTest
@testable import immersiveRT

final class WebSocketSignalingTests: XCTestCase {

    // MARK: - URL construction

    func test_url_isBuiltFromInjectedHost_neverHardcoded() {
        let transport = WebSocketSignaling(host: "192.168.1.42", myId: "test-id")
        XCTAssertEqual(transport.url.absoluteString, "wss://192.168.1.42:9090")
    }

    func test_url_usesDifferentInjectedHost() {
        let transport = WebSocketSignaling(host: "example.com", myId: "test-id")
        XCTAssertEqual(transport.url.absoluteString, "wss://example.com:9090")
    }

    func test_isWebTransport_isFalse() {
        let transport = WebSocketSignaling(host: "example.com", myId: "test-id")
        XCTAssertFalse(transport.isWebTransport)
    }

    // MARK: - myId persistence

    func test_myId_reusedAcrossSimulatedReconnect() {
        let transport = WebSocketSignaling(host: "example.com", myId: "persistent-uuid")

        let firstRegister = transport.makeRegisterEnvelope()
        let secondRegister = transport.makeRegisterEnvelope() // simulates a second register on reconnect

        XCTAssertEqual(firstRegister.from, "persistent-uuid")
        XCTAssertEqual(secondRegister.from, "persistent-uuid")
        XCTAssertEqual(firstRegister.from, secondRegister.from)
        XCTAssertEqual(firstRegister.type, SignalingEnvelope.SignalingType.register)
    }

    func test_myId_defaultsToGeneratedUUID_whenNotInjected() {
        let transport = WebSocketSignaling(host: "example.com")
        XCTAssertFalse(transport.myId.isEmpty)
        XCTAssertNotNil(UUID(uuidString: transport.myId))
    }

    // MARK: - pair-ack / pair-error resolve/reject the pair request

    func test_pairAck_resolvesPairRequest() async throws {
        let transport = WebSocketSignaling(host: "example.com", myId: "test-id")
        let requestEnvelope = SignalingEnvelope(
            type: SignalingEnvelope.SignalingType.pair, from: "test-id", to: "", payload: [:]
        )

        let task = Task { try await transport.request(requestEnvelope) }
        try await waitUntil { transport.hasPendingPairRequest }

        let ack = SignalingEnvelope(
            type: SignalingEnvelope.SignalingType.pairAck,
            from: "server",
            to: "test-id",
            payload: ["slot": AnyCodable(1), "room_code": AnyCodable("ABCD12")]
        )
        transport.handle(ack)

        let result = try await task.value
        XCTAssertEqual(result.type, SignalingEnvelope.SignalingType.pairAck)
        XCTAssertEqual(result.slot, 1)
        XCTAssertEqual(result.roomCode, "ABCD12")
    }

    func test_pairError_rejectsPairRequest_withServerReason() async throws {
        let transport = WebSocketSignaling(host: "example.com", myId: "test-id")
        let requestEnvelope = SignalingEnvelope(
            type: SignalingEnvelope.SignalingType.pair, from: "test-id", to: "", payload: [:]
        )

        let task = Task { try await transport.request(requestEnvelope) }
        try await waitUntil { transport.hasPendingPairRequest }

        let errorEnvelope = SignalingEnvelope(
            type: SignalingEnvelope.SignalingType.pairError,
            from: "server",
            to: "test-id",
            payload: ["reason": AnyCodable("token_used")]
        )
        transport.handle(errorEnvelope)

        do {
            _ = try await task.value
            XCTFail("expected pair request to throw")
        } catch let error as WebSocketSignalingError {
            XCTAssertEqual(error, .requestFailed(reason: "token_used"))
        }
    }

    // MARK: - join-ack / join-error resolve/reject the reconnect request

    func test_joinAck_resolvesReconnectRequest() async throws {
        let transport = WebSocketSignaling(host: "example.com", myId: "test-id")
        let requestEnvelope = SignalingEnvelope(
            type: SignalingEnvelope.SignalingType.reconnect, from: "test-id", to: "", payload: [:]
        )

        let task = Task { try await transport.request(requestEnvelope) }
        try await waitUntil { transport.hasPendingReconnectRequest }

        let ack = SignalingEnvelope(
            type: SignalingEnvelope.SignalingType.joinAck,
            from: "server",
            to: "test-id",
            payload: ["reconnect_token": AnyCodable("new-token")]
        )
        transport.handle(ack)

        let result = try await task.value
        XCTAssertEqual(result.type, SignalingEnvelope.SignalingType.joinAck)
        XCTAssertEqual(result.reconnectToken, "new-token")
    }

    func test_joinError_rejectsReconnectRequest_withServerReason() async throws {
        let transport = WebSocketSignaling(host: "example.com", myId: "test-id")
        let requestEnvelope = SignalingEnvelope(
            type: SignalingEnvelope.SignalingType.reconnect, from: "test-id", to: "", payload: [:]
        )

        let task = Task { try await transport.request(requestEnvelope) }
        try await waitUntil { transport.hasPendingReconnectRequest }

        let errorEnvelope = SignalingEnvelope(
            type: SignalingEnvelope.SignalingType.joinError,
            from: "server",
            to: "test-id",
            payload: ["reason": AnyCodable("slot_not_held")]
        )
        transport.handle(errorEnvelope)

        do {
            _ = try await task.value
            XCTFail("expected reconnect request to throw")
        } catch let error as WebSocketSignalingError {
            XCTAssertEqual(error, .requestFailed(reason: "slot_not_held"))
        }
    }

    func test_requestingUnsupportedType_throwsImmediately() async {
        let transport = WebSocketSignaling(host: "example.com", myId: "test-id")
        let envelope = SignalingEnvelope(type: "heartbeat", from: "test-id", to: "", payload: [:])

        do {
            _ = try await transport.request(envelope)
            XCTFail("expected unsupported request type to throw")
        } catch let error as WebSocketSignalingError {
            XCTAssertEqual(error, .unsupportedRequestType("heartbeat"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - Non-request messages route to onServerPush

    func test_unknownMessage_routesToOnServerPush() {
        let transport = WebSocketSignaling(host: "example.com", myId: "test-id")
        var pushed: SignalingEnvelope?
        transport.onServerPush = { pushed = $0 }

        let peerJoined = SignalingEnvelope(
            type: SignalingEnvelope.SignalingType.peerJoined, from: "server", to: "test-id", payload: [:]
        )
        transport.handle(peerJoined)

        XCTAssertEqual(pushed?.type, SignalingEnvelope.SignalingType.peerJoined)
    }

    func test_heartbeatPush_doesNotResolveAnyContinuation_routesToOnServerPush() {
        let transport = WebSocketSignaling(host: "example.com", myId: "test-id")
        var pushed: SignalingEnvelope?
        transport.onServerPush = { pushed = $0 }

        let heartbeat = SignalingEnvelope(
            type: SignalingEnvelope.SignalingType.heartbeat, from: "server", to: "test-id", payload: [:]
        )
        transport.handle(heartbeat)

        XCTAssertEqual(pushed?.type, SignalingEnvelope.SignalingType.heartbeat)
        XCTAssertFalse(transport.hasPendingPairRequest)
        XCTAssertFalse(transport.hasPendingReconnectRequest)
    }

    // MARK: - Close behavior

    func test_simulatedClose_rejectsInFlightPairRequest_withWsClosed() async throws {
        let transport = WebSocketSignaling(host: "example.com", myId: "test-id")
        let requestEnvelope = SignalingEnvelope(
            type: SignalingEnvelope.SignalingType.pair, from: "test-id", to: "", payload: [:]
        )

        let task = Task { try await transport.request(requestEnvelope) }
        try await waitUntil { transport.hasPendingPairRequest }

        transport.handleClosure()

        do {
            _ = try await task.value
            XCTFail("expected pair request to be rejected on close")
        } catch let error as WebSocketSignalingError {
            XCTAssertEqual(error, .requestFailed(reason: "ws-closed"))
        }
    }

    func test_simulatedClose_rejectsInFlightReconnectRequest_withWsClosed() async throws {
        let transport = WebSocketSignaling(host: "example.com", myId: "test-id")
        let requestEnvelope = SignalingEnvelope(
            type: SignalingEnvelope.SignalingType.reconnect, from: "test-id", to: "", payload: [:]
        )

        let task = Task { try await transport.request(requestEnvelope) }
        try await waitUntil { transport.hasPendingReconnectRequest }

        transport.handleClosure()

        do {
            _ = try await task.value
            XCTFail("expected reconnect request to be rejected on close")
        } catch let error as WebSocketSignalingError {
            XCTAssertEqual(error, .requestFailed(reason: "ws-closed"))
        }
    }

    func test_simulatedClose_firesOnClosed_whenNotManagedReconnecting() {
        let transport = WebSocketSignaling(host: "example.com", myId: "test-id")
        var closedReason: String?
        transport.onClosed = { closedReason = $0 }

        transport.handleClosure()

        XCTAssertEqual(closedReason, "ws-closed")
    }

    func test_simulatedClose_suppressesOnClosed_whileManagedReconnectInProgress() {
        let transport = WebSocketSignaling(host: "example.com", myId: "test-id")
        transport.isReconnecting = true
        var closedFired = false
        transport.onClosed = { _ in closedFired = true }

        transport.handleClosure()

        XCTAssertFalse(closedFired, "onClosed must be suppressed during a managed reconnect")
    }

    func test_simulatedClose_stillRejectsInFlightRequest_whileManagedReconnecting() async throws {
        let transport = WebSocketSignaling(host: "example.com", myId: "test-id")
        transport.isReconnecting = true
        let requestEnvelope = SignalingEnvelope(
            type: SignalingEnvelope.SignalingType.pair, from: "test-id", to: "", payload: [:]
        )

        let task = Task { try await transport.request(requestEnvelope) }
        try await waitUntil { transport.hasPendingPairRequest }

        transport.handleClosure()

        do {
            _ = try await task.value
            XCTFail("expected pair request to still be rejected during a managed reconnect")
        } catch let error as WebSocketSignalingError {
            XCTAssertEqual(error, .requestFailed(reason: "ws-closed"))
        }
    }
}

// MARK: - Test helpers

/// Polls `condition` until it returns `true` or a bounded timeout elapses.
/// Used instead of a fixed `Task.sleep` to deterministically wait for an
/// async continuation to register itself, without a real socket.
private func waitUntil(
    timeout: TimeInterval = 2.0,
    pollInterval: UInt64 = 5_000_000, // 5ms
    _ condition: @escaping () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("waitUntil: condition not met within \(timeout)s")
            return
        }
        try await Task.sleep(nanoseconds: pollInterval)
    }
}
