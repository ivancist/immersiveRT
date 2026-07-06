# Phase 2: Signaling, TURN, and Deployment - Pattern Map

**Mapped:** 2026-07-06
**Files analyzed:** 11 (5 new, 6 modified/infrastructure)
**Analogs found:** 8 / 11

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `server/src/broker.rs` | service | event-driven (pub-sub) | `server/src/ws_server.rs` (Arc shared-state shape) | partial-match |
| `server/src/signaling.rs` | model/utility | request-response (JSON) | `server/src/echo.rs` | role-match |
| `server/src/turn_creds.rs` | utility | transform (compute) | `server/src/echo.rs` | role-match |
| `server/src/wt_server.rs` *(modified)* | controller/listener | streaming fan-in/fan-out | itself (Phase 1 echo loop) | self-analog |
| `server/src/ws_server.rs` *(modified)* | controller/listener | streaming fan-in/fan-out | itself (Phase 1 echo loop) | self-analog |
| `server/src/main.rs` *(modified)* | config/bootstrap | wiring | itself (Phase 1) | self-analog |
| `server/Cargo.toml` *(modified)* | config | — | itself | self-analog |
| `server/tests/broker_relay.rs` | test | integration | `server/tests/ws_echo.rs` | exact |
| `docker/Dockerfile.server` | config | build | none | no analog |
| `docker/coturn/turnserver.conf` | config | — | none | no analog |
| `docker-compose.yml` | config | — | none | no analog |

---

## Pattern Assignments

### `server/src/broker.rs` (service, event-driven pub-sub)

**Analog:** `server/src/ws_server.rs` (Arc shared-state + semaphore injection) and `server/src/echo.rs` (module/test skeleton)

**Arc shared-state injection pattern** (`ws_server.rs` lines 22–28):
```rust
let sem = Arc::new(Semaphore::new(MAX_WS_CONNECTIONS));
loop {
    match listener.accept().await {
        Ok((stream, addr)) => {
            let permit = sem.clone().acquire_owned().await.unwrap();
            tokio::spawn(async move {
                let _permit = permit; // Released when the connection closes
```
Copy: wrap the `DashMap` in `Arc`, derive `Clone` on the broker struct so callers just `.clone()` the handle into each `tokio::spawn`ed task — exactly how the semaphore is cloned above.

**Module/test skeleton** (`echo.rs` lines 27–55):
```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_now_ms_nonzero() { ... }

    #[test]
    fn test_echo_message_round_trip() { ... }
}
```
Mirror: `broker.rs` gets an inline `#[cfg(test)] mod tests` block with unit tests for `register`/`route`/`unregister`, including the D-05 unknown-target case.

**Core struct to implement** (from RESEARCH.md Architecture Patterns Pattern 1):
```rust
use dashmap::DashMap;
use tokio::sync::mpsc;

pub type ClientId = String;

#[derive(Clone)]
pub struct SignalingBroker {
    clients: std::sync::Arc<DashMap<ClientId, mpsc::UnboundedSender<Vec<u8>>>>,
}

impl SignalingBroker {
    pub fn new() -> Self {
        Self { clients: std::sync::Arc::new(DashMap::new()) }
    }

    pub fn register(&self, id: ClientId) -> mpsc::UnboundedReceiver<Vec<u8>> {
        let (tx, rx) = mpsc::unbounded_channel();
        self.clients.insert(id, tx);
        rx
    }

    pub fn unregister(&self, id: &str) { self.clients.remove(id); }

    /// Returns false if `to` is not connected — caller logs a warning per D-05.
    pub fn route(&self, to: &str, payload: Vec<u8>) -> bool {
        match self.clients.get(to) {
            Some(sender) => sender.send(payload).is_ok(),
            None => false,
        }
    }
}
```

**Critical:** Do NOT hold the `DashMap::get()` guard across any `.await`. `UnboundedSender::send()` is synchronous so this is safe by construction for unbounded channels, but be explicit: clone the sender out of the guard and drop it before any async operation.

---

### `server/src/signaling.rs` (model/utility, request-response JSON)

**Analog:** `server/src/echo.rs`

**Serde struct pattern** (`echo.rs` lines 18–25):
```rust
#[derive(Debug, Serialize, Deserialize)]
pub struct EchoMessage {
    #[serde(rename = "type")]
    pub msg_type: String,
    pub client_ts: u64,
    pub server_ts: Option<u64>,
}
```
Copy the `#[serde(rename = "type")]` convention for the `type` field. The `SignalingEnvelope` struct follows this exact shape:
```rust
#[derive(Debug, Serialize, Deserialize)]
pub struct SignalingEnvelope {
    #[serde(rename = "type")]
    pub msg_type: String,          // "offer" | "answer" | "ice-candidate" | "register"
    pub from: String,
    #[serde(default)]
    pub to: String,                // empty for "register"
    #[serde(default)]
    pub payload: serde_json::Value,
}
```

**Malformed-payload drop pattern** (`wt_server.rs` lines 86–93):
```rust
let msg: EchoMessage = match serde_json::from_slice(&buf) {
    Ok(m) => m,
    Err(e) => {
        tracing::warn!("Malformed echo message ({e}), dropping");
        continue;
    }
};
```
Use verbatim in both `ws_server.rs` and `wt_server.rs` when parsing `SignalingEnvelope` — T-01-06 precedent (never panic on malformed network input).

---

### `server/src/turn_creds.rs` (utility, transform/compute)

**Analog:** `server/src/echo.rs` (`now_ms()` utility function shape + inline test module)

**Utility function shape** (`echo.rs` lines 5–12):
```rust
/// Returns the current time as milliseconds since Unix epoch.
#[allow(dead_code)]
pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}
```
Mirror: `pub fn generate_turn_credentials(...)` with a leading `///` doc comment, plain `pub fn` (no struct wrapper), returning `anyhow::Result<TurnCredentials>`. For seconds-precision use `as_secs()` rather than `as_millis()` — or reuse `echo::now_ms() / 1000`.

**Known-answer unit test shape** (`echo.rs` lines 38–54): `assert_eq!(decoded.client_ts, 12345)` deterministic assertion style — for turn_creds the test fixes `shared_secret`, `userid`, `ttl_seconds`, and a known timestamp, asserts the exact `password` string. Do not use range checks (`assert!(value > ...)`); HMAC is deterministic and must be tested with a fixed vector.

**Core implementation** (from RESEARCH.md Architecture Patterns Pattern 3):
```rust
use base64::{engine::general_purpose::STANDARD, Engine};
use hmac::{Hmac, Mac};
use sha1::Sha1;
use std::time::{SystemTime, UNIX_EPOCH};

type HmacSha1 = Hmac<Sha1>;

pub struct TurnCredentials {
    pub username: String,
    pub password: String,
    pub ttl_seconds: u64,
}

pub fn generate_turn_credentials(
    shared_secret: &str,
    userid: &str,
    ttl_seconds: u64,
) -> anyhow::Result<TurnCredentials> {
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    let expiry = now + ttl_seconds;    // EXPIRY timestamp — not issue time (see Pitfall 1)
    let username = format!("{expiry}:{userid}");

    let mut mac = HmacSha1::new_from_slice(shared_secret.as_bytes())
        .map_err(|e| anyhow::anyhow!("HMAC key error: {e}"))?;
    mac.update(username.as_bytes());
    let password = STANDARD.encode(mac.finalize().into_bytes());

    Ok(TurnCredentials { username, password, ttl_seconds })
}
```

---

### `server/src/wt_server.rs` *(modified)* (controller/listener, fan-in/fan-out)

**Analog:** itself — Phase 1 version (`server/src/wt_server.rs` lines 1–116), evolves in place.

**Imports to extend** (lines 1–5):
```rust
use anyhow::Context;
use wtransport::endpoint::IncomingSession;
use wtransport::{Endpoint, Identity, ServerConfig};
use crate::echo::{now_ms, EchoMessage};  // ← replace with crate::broker + crate::signaling
```
Replace the last import with `crate::broker::SignalingBroker` and `crate::signaling::SignalingEnvelope`; keep all `anyhow::Context` usage.

**Accept-loop + spawn pattern to preserve** (lines 25–33):
```rust
loop {
    let incoming = server.accept().await;
    tokio::spawn(async move {
        if let Err(e) = handle_wt_connection(incoming).await {
            tracing::error!("WT connection error: {e:#}");
        }
    });
}
```
Add `broker: Arc<SignalingBroker>` to `run()` signature and clone into spawn. No other structural change to the accept loop.

**Three-step WT handshake to preserve exactly** (lines 41–54):
```rust
let request = incoming.await.context("WebTransport session request failed")?;
tracing::info!(authority = %request.authority(), path = %request.path(), "WT session request received");
let conn = request.accept().await.context("WT session accept failed")?;
tracing::info!("WT session accepted");
```

**Core structural change — Pitfall 5 (RESEARCH.md lines 457–462):** Current code loops on `conn.accept_bi()` (line 57) — the client always opens the stream, so the server can never push unsolicited signaling messages. Replace with a single long-lived bidirectional stream opened once:
```rust
// Open one persistent stream for the entire connection lifetime
let (mut send, mut recv) = conn.open_bi().await.context("open_bi failed")?;
// ... then tokio::select! loop over recv + broker mpsc::Receiver
```
Then apply the `tokio::select!` fan-in/fan-out loop from RESEARCH.md Pattern 2 (lines 273–302).

**Buffer accumulation guard to adapt** (lines 66–79): the 64KiB oversized-guard (`buf.len() > 65_536`) and `tracing::warn!` + `buf.clear()` recovery carry forward, but framing changes from per-stream to length-prefixed or newline-delimited on the persistent stream.

**Malformed-payload handling to preserve** (lines 86–93) — see `signaling.rs` section.

---

### `server/src/ws_server.rs` *(modified)* (controller/listener, fan-in/fan-out + WSS TLS)

**Analog:** itself — Phase 1 version (`server/src/ws_server.rs` lines 1–84), evolves in place.

**`run` → `run_with_listener` split to preserve** (lines 15–19):
```rust
pub async fn run(port: u16) -> anyhow::Result<()> {
    let listener = TcpListener::bind(format!("0.0.0.0:{}", port)).await?;
    tracing::info!("WebSocket fallback listening on :{}", port);
    run_with_listener(listener).await
}
```
The existing integration test (`tests/ws_echo.rs` line 14) imports `run_with_listener` directly — this split must be preserved. Add `broker: Arc<SignalingBroker>` to both `run` and `run_with_listener`.

**Connection-limit semaphore to preserve** (lines 22–28) — same pattern as broker.rs section above.

**WSS TLS insertion point** — between raw `TcpStream` accept and `accept_async_with_config`, insert TLS wrapping (from RESEARCH.md Code Examples):
```rust
use rustls_pemfile::{certs, private_key};
use std::io::BufReader;
use tokio_rustls::TlsAcceptor;
use tokio_rustls::rustls::ServerConfig;

fn load_tls_acceptor(cert_path: &str, key_path: &str) -> anyhow::Result<TlsAcceptor> {
    let cert_chain = certs(&mut BufReader::new(std::fs::File::open(cert_path)?))
        .collect::<Result<Vec<_>, _>>()?;
    let key = private_key(&mut BufReader::new(std::fs::File::open(key_path)?))?
        .ok_or_else(|| anyhow::anyhow!("no private key found in {key_path}"))?;
    let config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(cert_chain, key)?;
    Ok(TlsAcceptor::from(std::sync::Arc::new(config)))
}
// In accept loop:
// let tls_stream = acceptor.accept(tcp_stream).await?;
// let ws = accept_async_with_config(tls_stream, Some(ws_config)).await?;
```

**Control-frame filter to preserve** (lines 69–72):
```rust
match &msg {
    Message::Text(_) | Message::Binary(_) => {}
    _ => continue,
}
```
Keep this guard before any `serde_json::from_slice` attempt.

**Echo loop to replace** (lines 57–76): replace `while let Some(result) = read.next().await { ... write.send(msg) }` with the `tokio::select!` fan-in/fan-out from RESEARCH.md Pattern 2, substituting `read.next()` / `write.send()` for the tungstenite-specific frame I/O.

**Error logging convention to preserve** (lines 30, 35, 62, 80):
```rust
tracing::warn!("WS connection error from {addr}: {e}");
tracing::error!("WS accept error: {e}");
tracing::warn!("WS read error from {addr}: {e}");
tracing::warn!("WS upgrade failed from {addr}: {e}");
```

---

### `server/src/main.rs` *(modified)* (bootstrap/config)

**Analog:** itself — Phase 1 version (lines 1–32).

**Env var + typed-default pattern to copy exactly** (lines 9–20):
```rust
let cert_path = std::env::var("CERT_PATH")
    .unwrap_or_else(|_| "certs/localhost+2.pem".into());
let wt_port: u16 = std::env::var("WT_PORT")
    .unwrap_or_else(|_| "4433".into())
    .parse()
    .map_err(|e| anyhow::anyhow!("WT_PORT must be a valid u16 port number: {e}"))?;
let ws_port: u16 = std::env::var("WS_PORT")
    .unwrap_or_else(|_| "8080".into())   // ← change default to "9090" (D-02)
    .parse()
    .map_err(|e| anyhow::anyhow!("WS_PORT must be a valid u16 port number: {e}"))?;
```
Apply identical pattern for `TURN_SHARED_SECRET` (string, no parse step; should fail loudly if absent — use `std::env::var("TURN_SHARED_SECRET")?` with no `.unwrap_or_else` since there is no safe default for a crypto secret) and optional `HTTP_PORT` (numeric, default `"8081"`).

**Broker construction insertion point** — before line 26's `tokio::try_join!`:
```rust
let broker = std::sync::Arc::new(broker::SignalingBroker::new());
```
Then pass `broker.clone()` into both listener `run()` calls.

**CryptoProvider fix (RESEARCH.md Pitfall 3)** — add as first statement after `tracing_subscriber::fmt::init()`:
```rust
rustls::crypto::aws_lc_rs::default_provider()
    .install_default()
    .ok(); // ok() because it fails silently if already installed — idempotent
```

**`tokio::try_join!` pattern to preserve** (lines 26–29) — extend arg lists, do not change the join structure.

---

### `server/Cargo.toml` *(modified)* (config)

**Analog:** itself (lines 1–16).

**Current deps style to match** (lines 6–16):
```toml
[dependencies]
wtransport = "0.7"
tokio = { version = "1", features = ["macros", "rt-multi-thread", "fs", "io-util", "net", "sync"] }
tokio-tungstenite = "0.29"
...
serde_json = "1"
```
Append new deps using the same bare-version-string style (no inline `# comments` unless a pitfall note is needed):
```toml
dashmap = "6.2"
hmac = "0.13"
sha1 = "0.11"
base64 = "0.22"
tokio-rustls = "0.26"
rustls-pemfile = "2.2"
axum = "0.8"    # TURN credential HTTP endpoint; Phase 3 room/session endpoints will extend this
```
Do NOT add a `ring` feature to any rustls-related crate (Pitfall 3: must rely on the `aws_lc_rs` provider already active via `wtransport` → `quinn`).

---

### `server/tests/broker_relay.rs` (integration test)

**Analog:** `server/tests/ws_echo.rs` (full file, 39 lines) — exact structural match.

**Port-0 bind pattern** (`ws_echo.rs` lines 9–12):
```rust
let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
    .await
    .expect("failed to bind test listener");
let addr = listener.local_addr().expect("no local addr");
```
Copy verbatim — bind a listener at port 0, then spawn `run_with_listener(listener, broker.clone())`.

**Server spawn pattern** (`ws_echo.rs` line 14):
```rust
tokio::spawn(immersive_rt_server::ws_server::run_with_listener(listener));
```
Update to pass broker: `tokio::spawn(immersive_rt_server::ws_server::run_with_listener(listener, broker.clone()))`.

**Client connect + assert pattern** (`ws_echo.rs` lines 16–38):
```rust
let url = format!("ws://{}", addr);
let (mut ws, _response) = connect_async(&url).await.expect("WebSocket connect failed");
ws.send(Message::Text(payload.into())).await.expect("send failed");
let reply = ws.next().await.expect("no reply received").expect("reply was an error");
match reply {
    Message::Text(text) => { assert_eq!(text, payload, "echo mismatch: ..."); }
    other => panic!("unexpected message type: {other:?}"),
}
```
Extend to two clients: connect client A + client B, send `register` from each, send `offer` from A `to` B's ID, assert B's `ws.next()` returns the offer JSON. Use the same `match reply { Message::Text(text) => assert_eq!(...), other => panic!(...) }` exhaustive-match style.

---

## Shared Patterns

### Env Var Config
**Source:** `server/src/main.rs` lines 9–20
**Apply to:** `main.rs` (all new vars follow this pattern)
```rust
let var: u16 = std::env::var("VAR_NAME")
    .unwrap_or_else(|_| "default".into())
    .parse()
    .map_err(|e| anyhow::anyhow!("VAR_NAME must be a valid u16: {e}"))?;
```

### Tracing / Structured Logging
**Source:** `server/src/wt_server.rs` lines 46–50 and `server/src/ws_server.rs` lines 17, 30, 62
**Apply to:** All new and modified Rust source files
```rust
tracing::info!(field = %value, "Event description");
tracing::warn!(to = %target_id, "signaling target not connected, dropping");
tracing::error!("WT connection error: {e:#}");  // {e:#} for verbose chain in top-level errors
```

### Malformed Input — Never Panic
**Source:** `server/src/wt_server.rs` lines 86–93 (T-01-06 precedent)
**Apply to:** `wt_server.rs` (modified), `ws_server.rs` (modified), anywhere `serde_json::from_slice` is called
```rust
let msg: SignalingEnvelope = match serde_json::from_slice(&buf) {
    Ok(m) => m,
    Err(e) => {
        tracing::warn!("Malformed signaling envelope ({e}), dropping");
        continue;
    }
};
```

### `anyhow::Context` on Every Fallible `.await`
**Source:** `server/src/wt_server.rs` lines 13–15, 43–44, 52
**Apply to:** `wt_server.rs` (modified), `ws_server.rs` (TLS loading), `turn_creds.rs`
```rust
let identity = Identity::load_pemfiles(cert_path, key_path)
    .await
    .with_context(|| format!("Failed to load TLS certs from {cert_path} / {key_path}"))?;
```

### Doc Comment + Inline Test Module
**Source:** `server/src/echo.rs` (full file)
**Apply to:** `broker.rs`, `signaling.rs`, `turn_creds.rs`
```rust
/// Brief description of what this item does.
pub fn or_struct_name(...) { ... }

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn test_subject_behavior() { ... assert_eq!(...) }
}
```

---

## No Analog Found

Files with no close codebase match — use RESEARCH.md sections directly:

| File | Role | Reason | RESEARCH.md Reference |
|------|------|--------|----------------------|
| `docker/Dockerfile.server` | config/build | No Dockerfiles exist in repo | CLAUDE.md `rust:1-slim` → `debian:bookworm-slim` multi-stage pattern |
| `docker/coturn/turnserver.conf` | config | No coturn config exists | RESEARCH.md Architecture Patterns Pattern 3 lines 344–356 (exact fields) |
| `docker-compose.yml` | config | No compose file exists | RESEARCH.md Architecture Patterns Pattern 4 lines 358–399 (3-service stack) |

For these three files, RESEARCH.md is the primary reference. Key hard constraints carried into the plan:
- `coturn` service: `network_mode: host` mandatory, NO `ports:` block (Pitfall 2)
- `turnserver.conf`: `lt-cred-mech` + `use-auth-secret` + `static-auth-secret` + `fingerprint` required fields
- Dockerfile: multi-stage `rust:1-slim` builder → `debian:bookworm-slim` runtime (CLAUDE.md-locked base images)

---

## Metadata

**Analog search scope:** `server/src/`, `server/tests/`, `server/Cargo.toml`, repo root (confirmed: no `docker/` directory, no `docker-compose.yml`)
**Files scanned:** 6 (`main.rs`, `ws_server.rs`, `wt_server.rs`, `echo.rs`, `Cargo.toml`, `tests/ws_echo.rs`)
**Pattern extraction date:** 2026-07-06
