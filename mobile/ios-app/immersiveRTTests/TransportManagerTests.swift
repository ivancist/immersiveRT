import XCTest
import WebRTC
@testable import immersiveRT

// MARK: - Test doubles

/// Error thrown by test-configured `ScriptedSignalingTransport.connect()` /
/// `requestHandler` closures to simulate a generic (non-domain-specific)
/// network failure — distinct from `WebSocketSignalingError`, which carries
/// a server-provided `reason` and must be unwrapped, not collapsed.
private enum TestError: Error {
    case generic
}

/// A fully scriptable `SignalingTransport` conformance — configure
/// `connectError` and/or `requestHandler` per test to simulate WT/WS
/// success, network failure, or a structured server response (pair-ack,
/// pair-error, join-ack, join-error), without a real network connection.
private final class ScriptedSignalingTransport: SignalingTransport {
    let isWebTransport: Bool

    var onServerPush: ((SignalingEnvelope) -> Void)?
    var onClosed: ((String) -> Void)?

    /// When non-nil, `connect()` throws this instead of succeeding.
    var connectError: Error?
    /// When non-nil, `request(_:)` returns/throws whatever this returns —
    /// defaults to echoing the input envelope's `type` back (which is never
    /// `pair-ack`/`join-ack`, so an unconfigured request reads as a failure
    /// with an empty `reason`, matching "server sent something unexpected").
    var requestHandler: ((SignalingEnvelope) throws -> SignalingEnvelope)?

    private(set) var connectCallCount = 0
    private(set) var closeCallCount = 0
    private(set) var sentEnvelopes: [SignalingEnvelope] = []
    private(set) var requestedEnvelopes: [SignalingEnvelope] = []

    init(isWebTransport: Bool) {
        self.isWebTransport = isWebTransport
    }

    func connect() async throws {
        connectCallCount += 1
        if let connectError { throw connectError }
    }

    func send(_ envelope: SignalingEnvelope) {
        sentEnvelopes.append(envelope)
    }

    func request(_ envelope: SignalingEnvelope) async throws -> SignalingEnvelope {
        requestedEnvelopes.append(envelope)
        guard let requestHandler else {
            return SignalingEnvelope(type: envelope.type, from: "", to: "", payload: [:])
        }
        return try requestHandler(envelope)
    }

    func close() {
        closeCallCount += 1
    }
}

/// Records every `makeWebTransport`/`makeWebSocket` factory call
/// `TransportManager` makes (host + myId + call order), and hands back a
/// freshly test-configured `ScriptedSignalingTransport` each time — mirrors
/// production's "fresh transport per attempt" shape (each WT/WS reconnect
/// attempt constructs a brand-new transport instance, never reuses one).
private final class TransportFactorySpy {
    private(set) var callOrder: [String] = []
    private(set) var webTransportCalls: [(host: String, myId: String)] = []
    private(set) var webSocketCalls: [(host: String, myId: String)] = []

    var makeWT: () -> ScriptedSignalingTransport = { ScriptedSignalingTransport(isWebTransport: true) }
    var makeWS: () -> ScriptedSignalingTransport = { ScriptedSignalingTransport(isWebTransport: false) }

    func webTransport(host: String, myId: String) -> SignalingTransport {
        webTransportCalls.append((host, myId))
        callOrder.append("wt")
        return makeWT()
    }

    func webSocket(host: String, myId: String) -> SignalingTransport {
        webSocketCalls.append((host, myId))
        callOrder.append("ws")
        return makeWS()
    }

    /// Clears every recorded call without discarding the spy identity —
    /// lets a single test drive `start()` once to reach a paired state,
    /// then reconfigure `makeWT`/`makeWS` and measure ONLY the calls made
    /// by a subsequent `attemptReconnect()`.
    func resetCallCounts() {
        callOrder = []
        webTransportCalls = []
        webSocketCalls = []
    }
}

/// Spy `PeerFanOut` — tracks fan-out calls without constructing any real
/// `RTCPeerConnection`/`RTCDataChannel` (no network/ICE negotiation needed
/// to verify `TransportManager`'s call shape).
private final class SpyPeerFanOut: PeerFanOut {
    var iceServers: [RTCIceServer] = []
    var registered: Bool = false
    var peerCount: Int { openedPeers.count }
    var openDataChannels: [RTCDataChannel] = []

    private(set) var openedPeers: [(peerId: String, isRecovery: Bool)] = []
    private(set) var closedPeers: [String] = []
    private(set) var reopenStaleChannelsCallCount = 0

    func openChannel(toPeer peerId: String, isRecovery: Bool) {
        openedPeers.append((peerId, isRecovery))
    }

    func closePeer(_ peerId: String) {
        closedPeers.append(peerId)
    }

    func reopenStaleChannels() {
        reopenStaleChannelsCallCount += 1
    }

    func applyRemoteAnswer(_ envelope: SignalingEnvelope, for peerId: String) {}
    func addRemoteCandidate(_ envelope: SignalingEnvelope, for peerId: String) {}
}

/// A `TransportManagerClock` that returns immediately — the "fast/virtual
/// clock" the plan requires so reconnect-loop tests never wait on real
/// 3s/10s delays.
private final class InstantClock: TransportManagerClock {
    private(set) var sleepCalls: [TimeInterval] = []
    func sleep(_ seconds: TimeInterval) async {
        sleepCalls.append(seconds)
    }
}

// MARK: - Envelope builders

private func pairAckEnvelope(
    peerIds: [String] = [],
    reconnectToken: String = "rtok-1",
    slot: Int = 1,
    roomCode: String = "ROOM1",
    username: String = "phone"
) -> SignalingEnvelope {
    SignalingEnvelope(
        type: SignalingEnvelope.SignalingType.pairAck,
        from: "", to: "",
        payload: [
            "slot": AnyCodable(slot),
            "room_code": AnyCodable(roomCode),
            "username": AnyCodable(username),
            "ice_servers": AnyCodable([[String: Any]]()),
            "peers": AnyCodable(peerIds.map { ["id": $0] }),
            "reconnect_token": AnyCodable(reconnectToken),
        ]
    )
}

private func failureEnvelope(type: String, reason: String) -> SignalingEnvelope {
    SignalingEnvelope(type: type, from: "", to: "", payload: ["reason": AnyCodable(reason)])
}

private func joinAckEnvelope(reconnectToken: String = "rtok-2") -> SignalingEnvelope {
    SignalingEnvelope(
        type: SignalingEnvelope.SignalingType.joinAck,
        from: "", to: "",
        payload: [
            "reconnect_token": AnyCodable(reconnectToken),
            "ice_servers": AnyCodable([[String: Any]]()),
        ]
    )
}

// MARK: - TransportManagerTests

/// Exercises `TransportManager`'s control flow with fake `SignalingTransport`
/// conformances (no real network) — the offline-testable half of PATTERNS.md's
/// D-04/D-05 obligation. Real connection is on-device (Plan 09).
final class TransportManagerTests: XCTestCase {

    private func makeManager(
        myId: String = "phone-fixed-id",
        spy: TransportFactorySpy,
        fanOut: SpyPeerFanOut = SpyPeerFanOut(),
        heartbeatScheduler: HeartbeatScheduler = FakeHeartbeatScheduler(),
        clock: TransportManagerClock = InstantClock(),
        maxReconnectAttempts: Int = 13
    ) -> TransportManager {
        TransportManager(
            myId: myId,
            makeWebTransport: { host, id in spy.webTransport(host: host, myId: id) },
            makeWebSocket: { host, id in spy.webSocket(host: host, myId: id) },
            makePeerFanOut: { _, _ in fanOut },
            heartbeatScheduler: heartbeatScheduler,
            clock: clock,
            reconnectInitialDelay: 0,
            reconnectBetweenDelay: 0,
            maxReconnectAttempts: maxReconnectAttempts
        )
    }

    /// Polls `condition` until it's `true` or `timeout` elapses — used only
    /// for the one test that exercises the fire-and-forget
    /// `handleTransportClosed` → `Task { attemptReconnect() }` wiring,
    /// where there is no `await`-able handle from the production API.
    /// Every other reconnect test calls `attemptReconnect()` directly
    /// (it is not `private`), so it needs no polling.
    private func waitUntil(timeout: TimeInterval = 2.0, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Task 1: WT-first / WS-fallback connect ordering (D-04)

    func test_start_wtSucceeds_activeTransportIsWT_wsNeverAttempted() async {
        let spy = TransportFactorySpy()
        spy.makeWT = {
            let t = ScriptedSignalingTransport(isWebTransport: true)
            t.requestHandler = { _ in pairAckEnvelope() }
            return t
        }
        let manager = makeManager(spy: spy)

        await manager.start(token: "tok", host: "example.com")

        XCTAssertEqual(spy.webTransportCalls.count, 1)
        XCTAssertEqual(spy.webSocketCalls.count, 0, "WS must never be attempted when WT succeeds (D-04)")
        XCTAssertEqual(manager.activeTransport?.isWebTransport, true)
        XCTAssertEqual(manager.state, .paired)
    }

    func test_start_wtFails_wsSucceeds_activeTransportIsWS() async {
        let spy = TransportFactorySpy()
        spy.makeWT = {
            let t = ScriptedSignalingTransport(isWebTransport: true)
            t.connectError = TestError.generic
            return t
        }
        spy.makeWS = {
            let t = ScriptedSignalingTransport(isWebTransport: false)
            t.requestHandler = { _ in pairAckEnvelope() }
            return t
        }
        let manager = makeManager(spy: spy)

        await manager.start(token: "tok", host: "example.com")

        XCTAssertEqual(spy.webTransportCalls.count, 1, "WT is still attempted first, even though it fails (D-04)")
        XCTAssertEqual(spy.webSocketCalls.count, 1)
        XCTAssertEqual(manager.activeTransport?.isWebTransport, false)
        XCTAssertEqual(manager.state, .paired)
    }

    func test_start_bothTransportsFail_surfacesTLSTrustMessage() async {
        let spy = TransportFactorySpy()
        spy.makeWT = { let t = ScriptedSignalingTransport(isWebTransport: true); t.connectError = TestError.generic; return t }
        spy.makeWS = { let t = ScriptedSignalingTransport(isWebTransport: false); t.connectError = TestError.generic; return t }
        let manager = makeManager(spy: spy)

        await manager.start(token: "tok", host: "example.com")

        XCTAssertEqual(manager.state, .error("Cannot reach the server. Make sure this device trusts the TLS certificate."))
    }

    // MARK: - Task 1: pair-ack fan-out

    func test_start_pairAck_fanOutOnePerPeer() async {
        let spy = TransportFactorySpy()
        spy.makeWT = {
            let t = ScriptedSignalingTransport(isWebTransport: true)
            t.requestHandler = { _ in pairAckEnvelope(peerIds: ["desktop-1", "desktop-2", "desktop-3"]) }
            return t
        }
        let fanOut = SpyPeerFanOut()
        let manager = makeManager(spy: spy, fanOut: fanOut)

        await manager.start(token: "tok", host: "example.com")

        XCTAssertEqual(fanOut.openedPeers.count, 3)
        XCTAssertEqual(fanOut.openedPeers.map(\.peerId), ["desktop-1", "desktop-2", "desktop-3"])
        XCTAssertTrue(fanOut.openedPeers.allSatisfy { !$0.isRecovery }, "initial fan-out is never a recovery reopen")
    }

    func test_start_pairAck_storesReconnectTokenAndMarksRegistered() async {
        let spy = TransportFactorySpy()
        spy.makeWT = {
            let t = ScriptedSignalingTransport(isWebTransport: true)
            t.requestHandler = { _ in pairAckEnvelope(reconnectToken: "secret-token-abc") }
            return t
        }
        let manager = makeManager(spy: spy)

        await manager.start(token: "tok", host: "example.com")

        XCTAssertEqual(manager.reconnectToken, "secret-token-abc")
        XCTAssertTrue(manager.registered)
    }

    func test_start_pairAckTypeMismatch_surfacesServerReason() async {
        let spy = TransportFactorySpy()
        spy.makeWT = {
            let t = ScriptedSignalingTransport(isWebTransport: true)
            t.requestHandler = { _ in failureEnvelope(type: SignalingEnvelope.SignalingType.pairError, reason: "invalid or expired token") }
            return t
        }
        let manager = makeManager(spy: spy)

        await manager.start(token: "tok", host: "example.com")

        XCTAssertEqual(manager.state, .error("invalid or expired token"))
    }

    func test_start_wtPairRequestNetworkFailure_genericMessage() async {
        let spy = TransportFactorySpy()
        spy.makeWT = {
            let t = ScriptedSignalingTransport(isWebTransport: true)
            t.requestHandler = { _ in throw TestError.generic }
            return t
        }
        let manager = makeManager(spy: spy)

        await manager.start(token: "tok", host: "example.com")

        XCTAssertEqual(manager.state, .error("Server connection dropped during pairing."))
    }

    /// Regression: `WebSocketSignaling.request(_:)` rejects a pending `pair`
    /// continuation by THROWING `WebSocketSignalingError.requestFailed`
    /// (unlike WebTransport, which returns `pair-error` as an ordinary
    /// envelope) — `start()` must unwrap that thrown error's `reason`
    /// rather than collapsing every WS pairing failure into the generic
    /// "connection dropped" message, matching phone.ts's
    /// `.catch(reason => ({ type: 'pair-error', payload: { reason } }))`.
    func test_start_wsPairError_surfacesServerProvidedReason() async {
        let spy = TransportFactorySpy()
        spy.makeWT = { let t = ScriptedSignalingTransport(isWebTransport: true); t.connectError = TestError.generic; return t }
        spy.makeWS = {
            let t = ScriptedSignalingTransport(isWebTransport: false)
            t.requestHandler = { _ in throw WebSocketSignalingError.requestFailed(reason: "room_full") }
            return t
        }
        let manager = makeManager(spy: spy)

        await manager.start(token: "tok", host: "example.com")

        XCTAssertEqual(manager.state, .error("room_full"))
    }

    // MARK: - Task 1: myId persistence

    func test_myId_reused_acrossTwoConnectAttempts() async {
        let spy = TransportFactorySpy()
        spy.makeWT = {
            let t = ScriptedSignalingTransport(isWebTransport: true)
            t.requestHandler = { _ in pairAckEnvelope() }
            return t
        }
        let manager = makeManager(myId: "stable-id-123", spy: spy)

        // Simulate the phone reconnecting from scratch (e.g. re-invoking the
        // connect flow) — myId is a `let`, generated once at construction,
        // so both attempts must hand the SAME value to the transport
        // factories (Shared Pattern: myId persistence, phone.ts:257).
        await manager.start(token: "tok", host: "example.com")
        await manager.start(token: "tok", host: "example.com")

        let allMyIds = spy.webTransportCalls.map(\.myId)
        XCTAssertEqual(allMyIds.count, 2)
        XCTAssertTrue(allMyIds.allSatisfy { $0 == "stable-id-123" })
    }

    // MARK: - Task 1: sensor loop only touches orientation fields (D-09)

    /// Source-contract proof (real device-motion delivery is exercised
    /// on-device, Plan 09): `handleOrientation` must never assign
    /// `dx`/`dy`/`dz`/`px`/`py`/`pz`/`driftConfidence` — those stay at
    /// `SensorPacket`'s zero defaults per D-01/D-09. Mirrors the
    /// `PeerConnectionManagerTests` "source contract" pattern used for
    /// `maxPacketLifeTime`.
    func test_sensorLoop_neverSetsPositionGestureOrDrift_sourceContract() throws {
        let source = try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "immersiveRTTests/TransportManagerTests.swift",
                with: "immersiveRT/Transport/TransportManager.swift"
            ),
            encoding: .utf8
        )
        guard let range = source.range(of: "func handleOrientation") else {
            XCTFail("handleOrientation not found in TransportManager.swift")
            return
        }
        let body = source[range.lowerBound...]
        for field in ["dx:", "dy:", "dz:", "px:", "py:", "pz:", "driftConfidence:"] {
            XCTAssertFalse(
                body.contains(field),
                "handleOrientation must never set \(field) — D-09 requires these stay zero via SensorPacket's defaults"
            )
        }
    }

    // MARK: - Task 2: attemptReconnect() guard + retry shape (attemptReconnect(), phone.ts:507-631)

    func test_attemptReconnect_noReconnectToken_endsImmediately() async {
        let spy = TransportFactorySpy()
        let manager = makeManager(spy: spy)
        // Never paired — reconnectToken stays nil.

        await manager.attemptReconnect()

        XCTAssertEqual(manager.state, .ended)
        XCTAssertEqual(spy.webTransportCalls.count, 0)
        XCTAssertEqual(spy.webSocketCalls.count, 0)
    }

    func test_attemptReconnect_retryCeilingIs13Attempts() async {
        let spy = TransportFactorySpy()
        spy.makeWT = { let t = ScriptedSignalingTransport(isWebTransport: true); t.requestHandler = { _ in pairAckEnvelope() }; return t }
        let manager = makeManager(spy: spy)
        await manager.start(token: "tok", host: "example.com")
        XCTAssertEqual(manager.state, .paired)
        spy.resetCallCounts()

        // Always network-fail on both transports (retryable "wt-net"/"ws-closed").
        spy.makeWT = { let t = ScriptedSignalingTransport(isWebTransport: true); t.connectError = TestError.generic; return t }
        spy.makeWS = { let t = ScriptedSignalingTransport(isWebTransport: false); t.connectError = TestError.generic; return t }

        await manager.attemptReconnect()

        XCTAssertEqual(spy.webTransportCalls.count, 13, "WT tried every iteration, up to the 13-attempt ceiling")
        XCTAssertEqual(spy.webSocketCalls.count, 13, "WS is the sub-attempt fallback in each of the 13 iterations")
        XCTAssertEqual(manager.state, .ended)
        XCTAssertNil(manager.reconnectToken)
    }

    func test_attemptReconnect_triesWTBeforeWS_everyIteration() async {
        let spy = TransportFactorySpy()
        spy.makeWT = { let t = ScriptedSignalingTransport(isWebTransport: true); t.requestHandler = { _ in pairAckEnvelope() }; return t }
        let manager = makeManager(spy: spy, maxReconnectAttempts: 3)
        await manager.start(token: "tok", host: "example.com")
        spy.resetCallCounts()

        spy.makeWT = { let t = ScriptedSignalingTransport(isWebTransport: true); t.connectError = TestError.generic; return t }
        spy.makeWS = { let t = ScriptedSignalingTransport(isWebTransport: false); t.connectError = TestError.generic; return t }

        await manager.attemptReconnect()

        XCTAssertEqual(spy.callOrder.count, 6)
        for pairStart in stride(from: 0, to: 6, by: 2) {
            XCTAssertEqual(spy.callOrder[pairStart], "wt", "iteration \(pairStart / 2 + 1): WT must be tried first")
            XCTAssertEqual(spy.callOrder[pairStart + 1], "ws", "iteration \(pairStart / 2 + 1): WS follows WT")
        }
    }

    func test_attemptReconnect_slotNotHeld_skipsWSSubAttempt() async {
        let spy = TransportFactorySpy()
        spy.makeWT = { let t = ScriptedSignalingTransport(isWebTransport: true); t.requestHandler = { _ in pairAckEnvelope() }; return t }
        let manager = makeManager(spy: spy, maxReconnectAttempts: 3)
        await manager.start(token: "tok", host: "example.com")
        spy.resetCallCounts()

        spy.makeWT = {
            let t = ScriptedSignalingTransport(isWebTransport: true)
            t.requestHandler = { _ in failureEnvelope(type: SignalingEnvelope.SignalingType.joinError, reason: "slot_not_held") }
            return t
        }
        spy.makeWS = { let t = ScriptedSignalingTransport(isWebTransport: false); t.connectError = TestError.generic; return t }

        await manager.attemptReconnect()

        XCTAssertEqual(spy.webTransportCalls.count, 3, "WT retried on slot_not_held up to the ceiling")
        XCTAssertEqual(spy.webSocketCalls.count, 0, "slot_not_held must skip the WS sub-attempt entirely — both transports would return the same result")
        XCTAssertEqual(manager.state, .ended)
    }

    func test_attemptReconnect_nonRetryableReason_isTerminalOnFirstIteration() async {
        let spy = TransportFactorySpy()
        spy.makeWT = { let t = ScriptedSignalingTransport(isWebTransport: true); t.requestHandler = { _ in pairAckEnvelope() }; return t }
        let manager = makeManager(spy: spy, maxReconnectAttempts: 13)
        await manager.start(token: "tok", host: "example.com")
        spy.resetCallCounts()

        // WT fails with a network error ("wt-net") → falls through to WS,
        // which returns a genuine, non-retryable join-error reason.
        spy.makeWT = { let t = ScriptedSignalingTransport(isWebTransport: true); t.connectError = TestError.generic; return t }
        spy.makeWS = {
            let t = ScriptedSignalingTransport(isWebTransport: false)
            t.requestHandler = { _ in failureEnvelope(type: SignalingEnvelope.SignalingType.joinError, reason: "banned") }
            return t
        }

        await manager.attemptReconnect()

        XCTAssertEqual(spy.webTransportCalls.count, 1, "a non-retryable reason must stop the loop on the very first iteration")
        XCTAssertEqual(spy.webSocketCalls.count, 1)
        XCTAssertEqual(manager.state, .ended)
        XCTAssertNil(manager.reconnectToken)
    }

    /// Regression: `WebSocketSignaling.request(_:)` rejects a pending
    /// `reconnect` continuation by THROWING
    /// `WebSocketSignalingError.requestFailed(reason:)` on a structured
    /// `join-error` response (unlike WebTransport, which returns
    /// `join-error` as a normal envelope) — the WS reconnect sub-attempt
    /// must unwrap that thrown error's `reason` rather than collapsing
    /// every WS failure into the always-retryable "ws-closed" bucket, or a
    /// genuine terminal join-error would incorrectly retry to the ceiling.
    func test_attemptReconnect_wsJoinError_preservesReason_notCollapsedToWsClosed() async {
        let spy = TransportFactorySpy()
        spy.makeWT = { let t = ScriptedSignalingTransport(isWebTransport: true); t.requestHandler = { _ in pairAckEnvelope() }; return t }
        let manager = makeManager(spy: spy, maxReconnectAttempts: 13)
        await manager.start(token: "tok", host: "example.com")
        spy.resetCallCounts()

        spy.makeWT = { let t = ScriptedSignalingTransport(isWebTransport: true); t.connectError = TestError.generic; return t }
        spy.makeWS = {
            let t = ScriptedSignalingTransport(isWebTransport: false)
            t.requestHandler = { _ in throw WebSocketSignalingError.requestFailed(reason: "banned") }
            return t
        }

        await manager.attemptReconnect()

        XCTAssertEqual(spy.webTransportCalls.count, 1, "a genuine non-retryable join-error reason must terminate on the first iteration, not retry to the 13-attempt ceiling")
        XCTAssertEqual(manager.state, .ended)
    }

    func test_attemptReconnect_joinAck_updatesTokenRestartsHeartbeatAndReopensStalePeers() async {
        let spy = TransportFactorySpy()
        let fanOut = SpyPeerFanOut()
        let scheduler = FakeHeartbeatScheduler()
        spy.makeWT = { let t = ScriptedSignalingTransport(isWebTransport: true); t.requestHandler = { _ in pairAckEnvelope() }; return t }
        let manager = makeManager(spy: spy, fanOut: fanOut, heartbeatScheduler: scheduler)
        await manager.start(token: "tok", host: "example.com")
        let heartbeatTokenCountAfterPair = scheduler.tokens.count
        spy.resetCallCounts()

        spy.makeWT = { let t = ScriptedSignalingTransport(isWebTransport: true); t.requestHandler = { _ in joinAckEnvelope(reconnectToken: "new-token") }; return t }

        await manager.attemptReconnect()

        XCTAssertEqual(manager.state, .paired)
        XCTAssertEqual(manager.reconnectToken, "new-token")
        XCTAssertEqual(fanOut.reopenStaleChannelsCallCount, 1, "successful reconnect must reopen stale peer channels")
        XCTAssertGreaterThan(scheduler.tokens.count, heartbeatTokenCountAfterPair, "heartbeat must be restarted on successful reconnect")
    }

    func test_transportOnClosed_triggersReconnectLoop() async {
        let spy = TransportFactorySpy()
        var wtFake: ScriptedSignalingTransport?
        spy.makeWT = {
            let t = ScriptedSignalingTransport(isWebTransport: true)
            t.requestHandler = { _ in pairAckEnvelope() }
            wtFake = t
            return t
        }
        let manager = makeManager(spy: spy)
        await manager.start(token: "tok", host: "example.com")
        XCTAssertEqual(manager.state, .paired)

        // Every fresh reconnect attempt (via `spy.makeWT`) also pair-acks
        // rather than join-acks, so the loop fails fast (reason "") and
        // reaches `.ended` — this test only proves `onClosed` actually
        // kicks off the reconnect loop end-to-end, not the retry shape
        // itself (covered by the dedicated tests above).
        wtFake?.onClosed?("wt-net")

        await waitUntil { manager.state == .ended }

        XCTAssertEqual(manager.state, .ended)
    }
}
