import Foundation

/// Transport-agnostic signaling dispatcher (D-04).
///
/// Both the WebSocket fallback (Plan 04) and WebTransport primary path
/// (Plan 05) conform to this single protocol. No code outside a conforming
/// type may call a transport-specific send function directly — every
/// signaling send, from heartbeats to WebRTC offer/answer/ICE exchange,
/// goes through this interface (Shared Pattern: envelope dispatch, ported
/// from `client/src/phone.ts`'s `signalSend`).
///
/// This file is pure API surface (Foundation only) — no networking code
/// lives here.
protocol SignalingTransport: AnyObject {
    /// Establishes the underlying connection and sends the initial
    /// `register` envelope. Mirrors `phone.ts`'s WT `.ready` + register
    /// sequence and `connectPhoneWS`'s `ws.onopen` register send.
    func connect() async throws

    /// Fire-and-forget send — mirrors `sendWtMessage`/`sendWsMsg`. Does not
    /// wait for or return a response.
    func send(_ envelope: SignalingEnvelope)

    /// Request/response send — mirrors `sendWtRequest` (WebTransport bidi
    /// stream round trip) and the WebSocket continuation-based
    /// pair/reconnect pattern. Returns the server's response envelope.
    func request(_ envelope: SignalingEnvelope) async throws -> SignalingEnvelope

    /// Invoked for every unsolicited message pushed by the server (anything
    /// that isn't a direct response to a `request(_:)` call) — mirrors
    /// `handleServerPush`.
    var onServerPush: ((SignalingEnvelope) -> Void)? { get set }

    /// Invoked when the underlying connection closes, carrying a reason
    /// string (mirrors the `'ws-closed'` / `'wt-net'` reason values used by
    /// the web client's reconnect-retryability classification).
    var onClosed: ((String) -> Void)? { get set }

    /// Closes the underlying connection.
    func close()

    /// `true` when this conformance is the WebTransport path, `false` for
    /// WebSocket — lets the manager log which transport is active (D-04).
    var isWebTransport: Bool { get }
}
