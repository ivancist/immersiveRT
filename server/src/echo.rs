use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

/// Returns the current time as milliseconds since Unix epoch.
#[allow(dead_code)]
pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

/// Latency echo probe message.
///
/// Client sends:  `{"type":"ping","client_ts":<ms>}`
/// Server replies: `{"type":"pong","client_ts":<ms>,"server_ts":<ms>}`
#[allow(dead_code)]
#[derive(Debug, Serialize, Deserialize)]
pub struct EchoMessage {
    #[serde(rename = "type")]
    pub msg_type: String,
    pub client_ts: u64,
    pub server_ts: Option<u64>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_now_ms_nonzero() {
        let ms = now_ms();
        // 1_700_000_000_000 ms = 2023-11-14 — any plausible 2024+ system clock exceeds this
        assert!(ms > 1_700_000_000_000, "now_ms() returned {ms}, expected > 1_700_000_000_000");
    }

    #[test]
    fn test_echo_message_round_trip() {
        let original = EchoMessage {
            msg_type: "ping".into(),
            client_ts: 12345,
            server_ts: None,
        };
        let json = serde_json::to_string(&original).expect("serialization failed");
        let decoded: EchoMessage = serde_json::from_str(&json).expect("deserialization failed");

        assert_eq!(decoded.client_ts, 12345);
        assert_eq!(decoded.msg_type, "ping");
        assert_eq!(decoded.server_ts, None);

        // Verify "type" key is used in JSON (not "msg_type")
        assert!(json.contains("\"type\""), "JSON key should be 'type', got: {json}");
    }
}
