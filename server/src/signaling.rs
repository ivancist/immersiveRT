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
