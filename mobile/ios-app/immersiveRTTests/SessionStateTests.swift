import XCTest
@testable import immersiveRT

/// Covers every documented transition in `SessionState.reduce(state:event:)`
/// (Task 1, PLAN 06.2-08): pair-ack → paired, first-open-channel → active
/// (with counts), transport-close → reconnecting, terminal → ended,
/// pair-error → error(message) — plus the reconnected → paired and
/// channel-count-carrying behavior called out in the acceptance criteria.
final class SessionStateTests: XCTestCase {

    func testPairAckMovesConnectingToPaired() {
        let next = SessionState.reduce(state: .connecting, event: .pairAck)
        XCTAssertEqual(next, .paired)
    }

    func testFirstOpenChannelMovesPairedToActive() {
        let next = SessionState.reduce(state: .paired, event: .channelOpen(open: 1, total: 3))
        XCTAssertEqual(next, .active(SessionState.ActiveChannels(openChannels: 1, totalPeers: 3)))
    }

    func testActiveStateCarriesOpenAndTotalChannelCounts() {
        let next = SessionState.reduce(state: .connecting, event: .channelOpen(open: 2, total: 5))
        guard case .active(let channels) = next else {
            return XCTFail("Expected .active, got \(next)")
        }
        XCTAssertEqual(channels.openChannels, 2)
        XCTAssertEqual(channels.totalPeers, 5)
    }

    func testChannelCloseUpdatesActiveCounts() {
        let active = SessionState.active(SessionState.ActiveChannels(openChannels: 2, totalPeers: 3))
        let next = SessionState.reduce(state: active, event: .channelClose(open: 1, total: 3))
        XCTAssertEqual(next, .active(SessionState.ActiveChannels(openChannels: 1, totalPeers: 3)))
    }

    func testTransportCloseMovesActiveToReconnecting() {
        let active = SessionState.active(SessionState.ActiveChannels(openChannels: 2, totalPeers: 3))
        let next = SessionState.reduce(state: active, event: .transportClosed)
        XCTAssertEqual(next, .reconnecting)
    }

    func testReconnectedMovesReconnectingToPaired() {
        let next = SessionState.reduce(state: .reconnecting, event: .reconnected)
        XCTAssertEqual(next, .paired)
    }

    func testTerminalMovesReconnectingToEnded() {
        let next = SessionState.reduce(state: .reconnecting, event: .terminal)
        XCTAssertEqual(next, .ended)
    }

    func testTerminalMovesConnectingToEnded() {
        // No reconnectToken at all (never paired) also ends the session.
        let next = SessionState.reduce(state: .connecting, event: .terminal)
        XCTAssertEqual(next, .ended)
    }

    func testPairErrorMovesConnectingToError() {
        let next = SessionState.reduce(state: .connecting, event: .pairError("This pairing link is invalid or has expired."))
        XCTAssertEqual(next, .error("This pairing link is invalid or has expired."))
    }

    func testPairErrorCarriesTlsTrustMessage() {
        // Pitfall 2: the TLS-trust-specific message must survive intact,
        // not be replaced by a generic string.
        let message = "Cannot reach the server. Make sure this device trusts the TLS certificate."
        let next = SessionState.reduce(state: .connecting, event: .pairError(message))
        XCTAssertEqual(next, .error(message))
    }
}
