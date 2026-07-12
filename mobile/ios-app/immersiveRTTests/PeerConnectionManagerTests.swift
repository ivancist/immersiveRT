import XCTest
import WebRTC
@testable import immersiveRT

/// Records envelopes handed to `send`/`request` so tests can assert on what
/// `PeerConnectionManager` dispatches, without a real signaling connection —
/// a minimal fake conforming to `SignalingTransport` (Plan 01).
final class FakeSignalingTransport: SignalingTransport {
    var sentEnvelopes: [SignalingEnvelope] = []
    var onServerPush: ((SignalingEnvelope) -> Void)?
    var onClosed: ((String) -> Void)?
    var isWebTransport: Bool = false

    func connect() async throws {}

    func send(_ envelope: SignalingEnvelope) {
        sentEnvelopes.append(envelope)
    }

    func request(_ envelope: SignalingEnvelope) async throws -> SignalingEnvelope {
        sentEnvelopes.append(envelope)
        return envelope
    }

    func close() {}
}

/// Verifies `PeerConnectionManager`'s data-channel config (PHONE-03, D-05
/// locked contract) and the per-peer fan-out shape. Real multi-desktop
/// fan-out + DTLS-role behavior against a live desktop is deferred to the
/// Plan 09 on-device checkpoint — not claimed here (see plan acceptance
/// criteria). What IS exercisable offline: local `RTCDataChannelConfiguration`
/// field values, and local peer-connection/data-channel object construction
/// (no network/ICE negotiation required to construct these objects).
final class PeerConnectionManagerTests: XCTestCase {

    // MARK: - Locked data channel config (D-05)

    func test_makeDataChannelConfig_isOrderedFalse() {
        XCTAssertFalse(PeerConnectionManager.makeDataChannelConfig().isOrdered)
    }

    func test_makeDataChannelConfig_maxRetransmitsZero() {
        XCTAssertEqual(PeerConnectionManager.makeDataChannelConfig().maxRetransmits, 0)
    }

    func test_makeDataChannelConfig_maxPacketLifeTimeLeftAtDefault_notSubstituted() {
        // -1 is WebRTC's documented "unset" sentinel for maxPacketLifeTime
        // (RTCDataChannelConfiguration.h). Asserting it stays at the default
        // proves maxPacketLifeTime was never touched as a substitute for
        // maxRetransmits (RESEARCH.md Anti-Patterns / mutually exclusive
        // per spec).
        XCTAssertEqual(PeerConnectionManager.makeDataChannelConfig().maxPacketLifeTime, -1)
    }

    // MARK: - Per-peer fan-out (one pc + one "sensor" channel per peer)

    func test_openChannel_createsOnePeerConnectionAndSensorDataChannel() {
        let transport = FakeSignalingTransport()
        let manager = PeerConnectionManager(transport: transport, myId: "phone-1")

        manager.openChannel(toPeer: "desktop-1")

        XCTAssertEqual(manager.peerCount, 1)
        let dc = manager.dataChannel(for: "desktop-1")
        XCTAssertEqual(dc?.label, "sensor")
        XCTAssertEqual(dc?.isOrdered, false)
        XCTAssertEqual(dc?.maxRetransmits, 0)
    }

    func test_openChannel_forMultiplePeers_fansOutOnePerPeer() {
        let transport = FakeSignalingTransport()
        let manager = PeerConnectionManager(transport: transport, myId: "phone-1")

        manager.openChannel(toPeer: "desktop-1")
        manager.openChannel(toPeer: "desktop-2")
        manager.openChannel(toPeer: "desktop-3")

        XCTAssertEqual(manager.peerCount, 3)
        XCTAssertNotNil(manager.dataChannel(for: "desktop-1"))
        XCTAssertNotNil(manager.dataChannel(for: "desktop-2"))
        XCTAssertNotNil(manager.dataChannel(for: "desktop-3"))
    }

    // MARK: - closePeer (WR-11 intentional-close path)

    func test_closePeer_removesPeerFromRoster() {
        let transport = FakeSignalingTransport()
        let manager = PeerConnectionManager(transport: transport, myId: "phone-1")
        manager.openChannel(toPeer: "desktop-1")
        XCTAssertEqual(manager.peerCount, 1)

        manager.closePeer("desktop-1")

        XCTAssertEqual(manager.peerCount, 0)
        XCTAssertNil(manager.dataChannel(for: "desktop-1"))
    }

    func test_closePeer_unknownPeer_isNoOp() {
        let transport = FakeSignalingTransport()
        let manager = PeerConnectionManager(transport: transport, myId: "phone-1")

        manager.closePeer("never-opened")

        XCTAssertEqual(manager.peerCount, 0)
    }

    // MARK: - reopenStaleChannels (Plan 07 reconnect path) is a no-op when nothing is stale

    func test_reopenStaleChannels_withNoStalePeers_isNoOp() {
        let transport = FakeSignalingTransport()
        let manager = PeerConnectionManager(transport: transport, myId: "phone-1")
        manager.openChannel(toPeer: "desktop-1")

        manager.reopenStaleChannels()

        // A freshly-opened channel is .connecting, not closed/closing/failed —
        // reopenStaleChannels must not tear down peers that aren't actually stale.
        XCTAssertEqual(manager.peerCount, 1)
    }
}
