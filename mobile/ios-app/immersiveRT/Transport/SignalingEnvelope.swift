import Foundation

/// WebRTC signaling envelope (D-04), matching the Rust server's wire shape
/// (`server/src/signaling.rs::SignalingEnvelope`) byte-for-key.
///
/// Wire format: `{"type":"...","from":"...","to":"...","payload":{...}}`.
/// No key-case transformation is applied anywhere in this type — payload
/// keys such as `room_code`, `reconnect_token`, and `ice_servers` stay
/// snake_case, exactly matching the server and the existing web client
/// (`client/src/phone.ts`'s `signalSend`/`SignalingMessage` shape).
struct SignalingEnvelope: Codable {
    let type: String
    let from: String
    let to: String
    let payload: [String: AnyCodable]

    init(type: String, from: String, to: String, payload: [String: AnyCodable] = [:]) {
        self.type = type
        self.from = from
        self.to = to
        self.payload = payload
    }

    // The server's ack/error responses (pair-ack, pair-error, join-ack,
    // join-error, leave-ack) are built ad-hoc via `serde_json::json!()` in
    // `room_registry.rs`, not through the Rust `SignalingEnvelope` struct —
    // they omit `from`/`to` entirely, only ever sending `{"type", "payload"}`.
    // The existing JS client tolerates this since it's untyped; Swift's
    // default Codable synthesis does not, and would silently fail to decode
    // (via WebSocketSignaling's `try?`) every ack/error message, leaving the
    // waiting continuation hanging forever. Default missing `from`/`to` to
    // "" to match the real wire behavior rather than the struct's aspirational
    // shape (found during 06.2-09 on-device verification: pairing succeeded
    // server-side but the client never left "Connecting…").
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        from = try container.decodeIfPresent(String.self, forKey: .from) ?? ""
        to = try container.decodeIfPresent(String.self, forKey: .to) ?? ""
        payload = try container.decodeIfPresent([String: AnyCodable].self, forKey: .payload) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case type, from, to, payload
    }
}

extension SignalingEnvelope {
    /// Known `type` values exchanged with the signaling server (D-04),
    /// ported from `client/src/room.ts`/`client/src/phone.ts` usage.
    enum SignalingType {
        static let register = "register"
        static let pair = "pair"
        static let pairAck = "pair-ack"
        static let pairError = "pair-error"
        static let reconnect = "reconnect"
        static let joinAck = "join-ack"
        static let joinError = "join-error"
        static let heartbeat = "heartbeat"
        static let offer = "offer"
        static let answer = "answer"
        static let iceCandidate = "ice-candidate"
        static let rtcChannelReady = "rtc-channel-ready"
        static let phoneState = "phone-state"
        static let playerReady = "player-ready"
        static let peerJoined = "peer-joined"
        static let peerLeft = "peer-left"
    }
}

extension SignalingEnvelope {
    // Typed, defensive accessors for `pair-ack` payload fields — mirror
    // `phone.ts`'s `typeof payload['slot'] === 'number'` reads (T-06.2-05:
    // a malformed server payload must never crash the client via a
    // force-unwrap).

    /// `payload.slot` — the phone's assigned desktop slot (1-indexed).
    var slot: Int? {
        if let intValue = payload["slot"]?.value as? Int { return intValue }
        if let doubleValue = payload["slot"]?.value as? Double { return Int(doubleValue) }
        return nil
    }

    /// `payload.room_code` — the room code for this session.
    var roomCode: String? {
        payload["room_code"]?.value as? String
    }

    /// `payload.ice_servers` — STUN/TURN server configuration entries.
    var iceServers: [Any]? {
        payload["ice_servers"]?.value as? [Any]
    }

    /// `payload.peers` — the roster of connected desktop peers.
    var peers: [Any]? {
        payload["peers"]?.value as? [Any]
    }

    /// `payload.reconnect_token` — opaque token for reconnecting this slot.
    var reconnectToken: String? {
        payload["reconnect_token"]?.value as? String
    }
}
