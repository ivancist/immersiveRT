use serde::{Deserialize, Serialize};

/// WebRTC signaling envelope (D-04).
///
/// Wire format: `{"type":"offer"|"answer"|"ice-candidate"|"register",
/// "from":"<client-id>","to":"<client-id>","payload":{...}}`
#[derive(Debug, Serialize, Deserialize)]
pub struct SignalingEnvelope {
    /// Message type. Serialised as `"type"` on the wire per D-04.
    #[serde(rename = "type")]
    pub msg_type: String,
    /// Sender's client ID.
    pub from: String,
    /// Recipient's client ID. Empty string for `"register"` messages.
    #[serde(default)]
    pub to: String,
    /// Opaque payload (SDP offer/answer body or ICE candidate object).
    #[serde(default)]
    pub payload: serde_json::Value,
}

/// Parse a signaling envelope from raw bytes.
///
/// Returns `None` on malformed input — never panics (T-01-06 precedent).
pub fn parse_envelope(bytes: &[u8]) -> Option<SignalingEnvelope> {
    serde_json::from_slice(bytes).ok()
}

// ---------------------------------------------------------------------------
// Phase 3: typed payload structs for room-aware message types (D-10, SESS-01)
// ---------------------------------------------------------------------------

/// Typed payload for `join-room` messages (D-10).
///
/// Sent by the desktop client to join or create a room.
#[derive(Debug, Serialize, Deserialize)]
pub struct JoinRoomPayload {
    pub username: String,
    /// Empty string means create a new room (D-04).
    pub room_code: String,
    pub game_type: String,
}

/// Typed payload for `join-ack` responses sent back to the joining desktop (D-10).
#[derive(Debug, Serialize, Deserialize)]
pub struct JoinAckPayload {
    pub slot: u8,
    pub room_code: String,
    pub reconnect_token: String,
    pub pairing_url: String,
}

/// Typed payload for `join-error` responses (D-10).
///
/// Reason values: `"room_full"` | `"room_not_found"` | `"invalid_payload"` | `"invalid_username"`.
#[derive(Debug, Serialize, Deserialize)]
pub struct JoinErrorPayload {
    pub reason: String,
}

/// Typed payload for `room-event` broadcasts to all desktops in the room (D-22, SESS-06).
///
/// Event values: `"player-joined"` | `"player-disconnected"` | `"player-left"` |
/// `"player-reconnected"` | `"room-full"`.
/// `"player-disconnected"` indicates hold-started state (D-21).
#[derive(Debug, Serialize, Deserialize)]
pub struct RoomEventPayload {
    pub event: String,
    pub slot: u8,
    pub username: String,
}

/// Typed payload for `pair` messages sent by phone clients.
#[derive(Debug, Serialize, Deserialize)]
pub struct PairPayload {
    pub token: String,
}

/// Typed payload for `pair-ack` responses sent back to the phone client.
#[derive(Debug, Serialize, Deserialize)]
pub struct PairAckPayload {
    /// The `client_id` of the desktop that owns this slot.
    pub desktop_id: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    /// SignalingEnvelope serialises with wire key "type" (not "msg_type") per D-04.
    #[test]
    fn test_signaling_envelope_wire_key_is_type() {
        let env = SignalingEnvelope {
            msg_type: "offer".into(),
            from: "client-A".into(),
            to: "client-B".into(),
            payload: serde_json::Value::Null,
        };
        let json = serde_json::to_string(&env).expect("serialization failed");
        assert!(
            json.contains("\"type\""),
            "wire key must be 'type', got: {json}"
        );
        assert!(
            !json.contains("\"msg_type\""),
            "wire must NOT contain 'msg_type', got: {json}"
        );
    }

    /// parse_envelope round-trips valid JSON to a SignalingEnvelope.
    #[test]
    fn test_parse_envelope_valid_json() {
        let json = br#"{"type":"offer","from":"A","to":"B","payload":{}}"#;
        let env = parse_envelope(json).expect("valid JSON should parse to Some");
        assert_eq!(env.msg_type, "offer");
        assert_eq!(env.from, "A");
        assert_eq!(env.to, "B");
    }

    /// parse_envelope returns None on invalid bytes — never panics.
    #[test]
    fn test_parse_envelope_invalid_returns_none() {
        let result = parse_envelope(b"not json at all {{{{");
        assert!(result.is_none(), "malformed bytes should return None");
    }
}
