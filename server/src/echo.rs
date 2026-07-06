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
