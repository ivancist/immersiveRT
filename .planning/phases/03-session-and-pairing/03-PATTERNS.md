# Phase 3: Session and Pairing - Pattern Map

**Mapped:** 2026-07-07
**Files analyzed:** 8 new/modified files
**Analogs found:** 7 / 8

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `server/src/room_registry.rs` | service | CRUD + event-driven | `server/src/broker.rs` | role-match (same Arc<DashMap> pattern, different domain) |
| `server/src/pairing_token.rs` | utility | transform | `server/src/turn_creds.rs` | exact (same HMAC-sign-then-encode pattern) |
| `server/src/signaling.rs` | model | transform | `server/src/signaling.rs` (extend) | self (add new message types to existing struct) |
| `server/src/ws_server.rs` | middleware | request-response | `server/src/ws_server.rs` (extend) | self (add join-room interception before broker.route) |
| `server/src/wt_server.rs` | middleware | request-response | `server/src/ws_server.rs` | role-match (same relay loop pattern, different transport) |
| `server/src/main.rs` | config | request-response | `server/src/main.rs` (extend) | self (add env vars + Arc injection) |
| `client/dist/index.html` | component | request-response | `client/dist/index.html` (replace) | no analog — placeholder only |
| `client/dist/room.js` | component | event-driven | none | no analog (first JS module in project) |
| `docker/nginx/nginx.conf` | config | request-response | none | no analog (nginx not yet present) |

---

## Pattern Assignments

### `server/src/room_registry.rs` (service, CRUD + event-driven)

**Analog:** `server/src/broker.rs`

**Imports pattern** (broker.rs lines 1–3):
```rust
use dashmap::DashMap;
use tokio::sync::mpsc;
// RoomRegistry needs tokio::task::JoinHandle in addition:
use tokio::task::JoinHandle;
use std::sync::Arc;
```

**Core struct pattern** (broker.rs lines 15–18, 21–26):
```rust
// broker.rs — the established Arc<DashMap> clone pattern Phase 3 mirrors exactly
#[derive(Clone)]
pub struct SignalingBroker {
    clients: std::sync::Arc<DashMap<ClientId, mpsc::UnboundedSender<Vec<u8>>>>,
}

impl SignalingBroker {
    pub fn new() -> Self {
        Self {
            clients: std::sync::Arc::new(DashMap::new()),
        }
    }
```

**RoomRegistry should follow the same shape:**
```rust
#[derive(Clone)]
pub struct RoomRegistry {
    rooms: Arc<DashMap<RoomCode, Room>>,
    // Separate map prevents holding rooms lock across .await when aborting timers
    hold_timers: Arc<DashMap<(RoomCode, SlotId), JoinHandle<()>>>,
}
```

**Anti-deadlock pattern — clone out before .await** (broker.rs lines 61–66, with comment):
```rust
// broker.route() is safe because UnboundedSender::send() is synchronous:
// "Safety note: mpsc::UnboundedSender::send is synchronous (not .await),
//  so the DashMap shard guard is never held across an .await point"
pub fn route(&self, to: &str, payload: Vec<u8>) -> bool {
    match self.clients.get(to) {
        Some(sender) => sender.send(payload).is_ok(),
        None => false,
    }
}
// For bounded channels or async sends: clone value out, drop Ref, then .await
```

**Test pattern** (broker.rs lines 69–131):
```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_route_to_registered_client() {
        let broker = SignalingBroker::new();
        let mut rx = broker.register("id-A".into()).expect("first registration should succeed");
        // ... assert pattern
    }

    #[test]
    fn test_route_to_unknown_returns_false() {
        // sync tests don't need #[tokio::test]
    }
}
```

**Hold timer cancel pattern (RESEARCH.md Pattern 3 — no codebase analog exists yet):**
```rust
// START hold timer — spawn, store JoinHandle
let handle = tokio::spawn({
    let registry = room_registry.clone();
    let broker = broker.clone();
    let room_code = room_code.clone();
    async move {
        tokio::time::sleep(std::time::Duration::from_secs(hold_secs)).await;
        // Defense: check slot still disconnected before evicting
        if registry.is_slot_disconnected(&room_code, slot_id) {
            registry.release_slot(&room_code, slot_id);
            let event = make_room_event("player-left", slot_id, &username);
            broadcast_to_room(&broker, &registry, &room_code, event).await;
        }
    }
});
room_registry.hold_timers.insert((room_code.clone(), slot_id), handle);

// CANCEL on reconnect — remove() yields owned handle, abort() is synchronous
if let Some((_, handle)) = room_registry.hold_timers.remove(&(room_code.clone(), slot_id)) {
    handle.abort(); // &self — no lock held, no .await needed
}
```

---

### `server/src/pairing_token.rs` (utility, transform)

**Analog:** `server/src/turn_creds.rs`

**Imports pattern** (turn_creds.rs lines 1–7):
```rust
use base64::{engine::general_purpose::STANDARD, Engine};
use hmac::{Hmac, KeyInit, Mac};
use serde::Serialize;
use sha1::Sha1;
use std::time::{SystemTime, UNIX_EPOCH};

type HmacSha1 = Hmac<Sha1>;
// Pairing token uses SHA-256 instead — same shape:
// use sha2::Sha256;
// type HmacSha256 = Hmac<Sha256>;
// use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};  // URL-safe for query params
```

**Core HMAC pattern** (turn_creds.rs lines 31–47):
```rust
pub fn generate_turn_credentials(
    shared_secret: &str,
    userid: &str,
    ttl_seconds: u64,
) -> anyhow::Result<TurnCredentials> {
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    // EXPIRY timestamp: always add ttl — never use `now` alone (Pitfall 4 in RESEARCH.md)
    let expiry = now + ttl_seconds;
    let username = format!("{expiry}:{userid}");

    let mut mac = HmacSha1::new_from_slice(shared_secret.as_bytes())
        .map_err(|e| anyhow::anyhow!("HMAC key error: {e}"))?;
    mac.update(username.as_bytes());
    let password = STANDARD.encode(mac.finalize().into_bytes());

    Ok(TurnCredentials { username, password, ttl_seconds })
}
```

**Pairing token mirrors this exactly, with additions:**
- Payload: `format!("{room_code}:{slot_id}:{expiry}")` instead of `format!("{expiry}:{userid}")`
- Encoding: `URL_SAFE_NO_PAD` instead of `STANDARD` (token appears in URL query param)
- Verification: `mac.verify_slice(&expected_sig_bytes).ok()?` — constant-time (never `sig_a == sig_b`)
- Single-use tracking: `DashMap<String, ()>` keyed by token string; check + insert atomically

**Test pattern — known-vector test** (turn_creds.rs lines 51–91):
```rust
// Pre-compute expected HMAC with Python or CLI, assert exact match
// This is the only early warning for silent HMAC algorithm bugs
#[test]
fn test_pairing_token_known_vector() {
    // Pre-compute: python3 -c "import hmac,hashlib,base64; ..."
    let expected = "...";
    let actual = generate_pairing_token("secret", "ABCDEF", 1, 9999999999).unwrap();
    assert_eq!(actual, expected);
}
```

---

### `server/src/signaling.rs` (model, transform) — extend existing

**Analog:** `server/src/signaling.rs` (self — extend existing struct)

**Existing struct** (signaling.rs lines 1–27):
```rust
#[derive(Debug, Serialize, Deserialize)]
pub struct SignalingEnvelope {
    #[serde(rename = "type")]
    pub msg_type: String,
    pub from: String,
    #[serde(default)]
    pub to: String,
    #[serde(default)]
    pub payload: serde_json::Value,
}

pub fn parse_envelope(bytes: &[u8]) -> Option<SignalingEnvelope> {
    serde_json::from_slice(bytes).ok()
}
```

**Phase 3 extension — no struct change needed.** `msg_type` is already a `String`, so new message types (`join-room`, `join-ack`, `join-error`, `room-event`, `reconnect`, `pair`, `pair-ack`) all deserialize into the existing `SignalingEnvelope`. The `payload` field is `serde_json::Value` (opaque), so new payload schemas require no struct changes. Only the handler (ws_server.rs / wt_server.rs) needs to match on the new `msg_type` values.

**Optional typed payload structs (follow serde pattern):**
```rust
// Add alongside existing code — separate typed payload structs for new message types
#[derive(Debug, Serialize, Deserialize)]
pub struct JoinRoomPayload {
    pub username: String,
    pub room_code: String,    // empty string = create new room
    pub game_type: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct JoinAckPayload {
    pub slot: u8,
    pub room_code: String,
    pub reconnect_token: String,
    pub pairing_url: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct RoomEventPayload {
    pub event: String,   // "player-joined" | "player-left" | "player-reconnected" | "room-full"
    pub slot: u8,
    pub username: String,
}
```

---

### `server/src/ws_server.rs` (middleware, request-response) — extend existing

**Analog:** `server/src/ws_server.rs` (self — extend relay loop)

**Current message dispatch pattern** (ws_server.rs lines 189–236):
```rust
if envelope.msg_type == "register" {
    let id = envelope.from.clone();
    match broker.register(id.clone()) {
        Ok(rx) => {
            my_id = Some(id.clone());
            broker_rx = Some(rx);
            tracing::info!(client_id = %id, "WS client registered from {addr}");
        }
        Err(e) => {
            tracing::warn!(client_id = %id,
                "WS registration rejected from {addr}: {e}, closing connection");
            break;
        }
    }
} else if my_id.is_none() {
    tracing::warn!("WS client from {addr} not yet registered, dropping message");
} else {
    // from-field spoof check (lines 214–222)
    let registered_id = my_id.as_ref().unwrap();
    if envelope.from != *registered_id {
        tracing::warn!(registered = %registered_id, claimed_from = %envelope.from,
            "WS client spoofed 'from' field, dropping message");
        continue;
    }
    // Route to target
    if !broker.route(&envelope.to, payload) {
        tracing::warn!(to = %envelope.to, "signaling target not connected, dropping");
    }
}
```

**Phase 3 extension — replace the final `else` block with a match:**
```rust
} else {
    // from-field spoof check (keep exactly as-is)
    ...
    // Replace single broker.route() call with type dispatch:
    match envelope.msg_type.as_str() {
        "join-room" => {
            let ack = room_registry.handle_join(
                &envelope.from, &envelope.payload, &broker, base_url, pairing_secret,
            ).await;
            let _ = write.send(Message::Text(
                serde_json::to_string(&ack).unwrap_or_default().into()
            )).await;
        }
        "reconnect" => {
            let ack = room_registry.handle_reconnect(
                &envelope.from, &envelope.payload, &broker,
            ).await;
            let _ = write.send(Message::Text(
                serde_json::to_string(&ack).unwrap_or_default().into()
            )).await;
        }
        "pair" => {
            let ack = room_registry.handle_pair(&envelope.payload).await;
            let _ = write.send(Message::Text(
                serde_json::to_string(&ack).unwrap_or_default().into()
            )).await;
        }
        _ => {
            // Existing broker routing (offer, answer, ice-candidate)
            if !broker.route(&envelope.to, payload) {
                tracing::warn!(to = %envelope.to, "signaling target not connected, dropping");
            }
        }
    }
}
```

**Function signature extension — add room_registry and config params:**
```rust
// Current signature (ws_server.rs line 49):
pub async fn run(port: u16, broker: Arc<SignalingBroker>, cert_path: &str, key_path: &str)

// Phase 3 extended signature:
pub async fn run(
    port: u16,
    broker: Arc<SignalingBroker>,
    room_registry: Arc<RoomRegistry>,
    cert_path: &str,
    key_path: &str,
    base_url: String,
    pairing_secret: String,
)
// Same Arc<T> injection pattern as broker — pass all the way down to relay_ws
```

**Unregister-on-disconnect pattern** (ws_server.rs lines 269–272):
```rust
// Keep this existing cleanup; Phase 3 adds a parallel room cleanup call:
if let Some(id) = &my_id {
    broker.unregister(id);
    tracing::info!(client_id = %id, "WS client unregistered");
    // Phase 3 addition:
    room_registry.on_client_disconnect(&id, &broker).await;
}
```

---

### `server/src/wt_server.rs` (middleware, request-response) — extend existing

**Analog:** `server/src/ws_server.rs` (role-match — same relay loop, different transport)

Read wt_server.rs to confirm the parallel structure, then apply identical message dispatch changes as ws_server.rs. The function signature extension and join-room/reconnect/pair dispatch blocks are identical — copy verbatim from the ws_server.rs pattern above.

---

### `server/src/main.rs` (config) — extend existing

**Analog:** `server/src/main.rs` (self)

**Required env var pattern** (main.rs lines 73–83):
```rust
// REQUIRED env vars — no default, descriptive error message:
let turn_shared_secret = std::env::var("TURN_SHARED_SECRET")
    .map_err(|_| anyhow::anyhow!(
        "TURN_SHARED_SECRET environment variable not set — \
         generate a random 32-char secret and set it before starting the server"
    ))?;
```

**Phase 3 new required env vars (follow identical pattern):**
```rust
let pairing_token_secret = std::env::var("PAIRING_TOKEN_SECRET")
    .map_err(|_| anyhow::anyhow!(
        "PAIRING_TOKEN_SECRET environment variable not set — \
         generate a random 32+ char secret and set it before starting the server"
    ))?;

let base_url = std::env::var("BASE_URL")
    .map_err(|_| anyhow::anyhow!(
        "BASE_URL environment variable not set — \
         set BASE_URL=https://<your-ip>:8443 before starting the server"
    ))?;
```

**Optional env var pattern with default** (main.rs lines 62–65):
```rust
let wt_port: u16 = std::env::var("WT_PORT")
    .unwrap_or_else(|_| "4433".into())
    .parse()
    .map_err(|e| anyhow::anyhow!("WT_PORT must be a valid u16 port number: {e}"))?;
// Phase 3 optional: HOLD_TTL_SECS (default 60), PAIRING_TOKEN_TTL_SECS (default 90)
```

**Arc injection pattern** (main.rs lines 93–108):
```rust
let broker = Arc::new(broker::SignalingBroker::new());
// Phase 3 addition — construct and inject alongside broker:
let room_registry = Arc::new(room_registry::RoomRegistry::new());

tokio::try_join!(
    wt_server::run(&cert_path, &key_path, wt_port, broker.clone(), room_registry.clone(), base_url.clone(), pairing_token_secret.clone()),
    ws_server::run(ws_port, broker.clone(), room_registry.clone(), &cert_path, &key_path, base_url, pairing_token_secret),
    async { axum::serve(http_listener, http_app).await.map_err(anyhow::Error::from) },
)?;
```

**mod declaration pattern** (main.rs lines 1–5):
```rust
mod broker;
mod signaling;
mod turn_creds;
mod wt_server;
mod ws_server;
// Phase 3 additions:
mod room_registry;
mod pairing_token;
```

---

### `client/dist/index.html` (component, request-response) — replace placeholder

**Analog:** `client/dist/index.html` (replace — current file is a placeholder with no real patterns)

**Phase 3 structure (no existing analog; follow RESEARCH.md Pattern 7):**
```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>ImmersiveRT</title>
  <!-- qrcode CDN — no npm install; approved by package legitimacy audit -->
  <script src="https://cdn.jsdelivr.net/npm/qrcode@1.5.4/build/qrcode.min.js"></script>
</head>
<body>
  <!-- Lobby view (shown on / path) -->
  <div id="view-lobby">
    <button id="btn-create-room">Create Room</button>
    <button id="btn-join-room">Join Room</button>
  </div>
  <!-- Join form (shown after clicking Join Room) -->
  <div id="view-join-form" hidden>...</div>
  <!-- Game type selection (shown after clicking Create Room) -->
  <div id="view-game-select" hidden>...</div>
  <!-- Room view (shown after join-ack, pushState to /room/XXXX) -->
  <div id="view-room" hidden>
    <canvas id="pairing-qr"></canvas>
    <p id="short-code"></p>
  </div>
  <script src="room.js"></script>
</body>
</html>
```

---

### `client/dist/room.js` (component, event-driven)

**Analog:** None — first JS module in the project.

**Use RESEARCH.md Pattern (JS WS + SPA pattern):**
```javascript
// WS connection and join-room flow (RESEARCH.md Code Examples)
const serverWsUrl = `wss://${location.hostname}:9090`;
let ws = null;
let myId = null;

function connect() {
    ws = new WebSocket(serverWsUrl);
    ws.onopen = () => {
        myId = crypto.randomUUID();
        ws.send(JSON.stringify({ type: 'register', from: myId, to: '', payload: {} }));
    };
    ws.onmessage = (evt) => {
        const msg = JSON.parse(evt.data);
        if (msg.type === 'join-ack') handleJoinAck(msg.payload);
        if (msg.type === 'join-error') showError(msg.payload.reason);
        if (msg.type === 'room-event') handleRoomEvent(msg.payload);
    };
}

function handleJoinAck(payload) {
    const { slot, room_code, reconnect_token, pairing_url } = payload;
    // Store reconnect token (D-17)
    sessionStorage.setItem('reconnect_token', reconnect_token);
    sessionStorage.setItem('room_code', room_code);
    // Navigate ONLY after server approval (D-07)
    history.pushState({ slot, room_code }, '', `/room/${room_code}`);
    renderRoomPage(slot, room_code, pairing_url);
}

function renderRoomPage(slot, roomCode, pairingUrl) {
    // QR via CDN library (D-12, RESEARCH.md Pattern 7)
    QRCode.toCanvas(document.getElementById('pairing-qr'), pairingUrl, { width: 256, margin: 2 });
    // Short code fallback (D-15, SESS-03): room_code + slot_id
    document.getElementById('short-code').textContent = `${roomCode}-${slot}`;
}
```

---

### `docker/nginx/nginx.conf` (config, request-response)

**Analog:** None — nginx not yet present in the project.

**Use RESEARCH.md Pattern 6 directly:**
```nginx
# docker/nginx/nginx.conf
server {
    listen 80;
    listen 443 ssl;

    ssl_certificate     /certs/localhost+2.pem;
    ssl_certificate_key /certs/localhost+2-key.pem;

    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files $uri /index.html;
    }
}
```

**docker-compose addition (follow existing service pattern in docker-compose.yml):**
```yaml
static-files:
  image: nginx:alpine
  ports:
    - "8090:80"
    - "8443:443"
  volumes:
    - ./client/dist:/usr/share/nginx/html:ro
    - ./docker/nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    - ./certs:/certs:ro
```

---

## Shared Patterns

### Arc<DashMap> Clone Injection
**Source:** `server/src/broker.rs` lines 15–26
**Apply to:** `room_registry.rs` struct definition and `main.rs` injection

The pattern: inner state is `Arc<DashMap<K, V>>` inside the outer struct. The outer struct derives `Clone` so that cloning it cheaply shares the same map. `main.rs` wraps in `Arc::new()` once and passes `.clone()` to each spawned handler. New `RoomRegistry` follows this exactly with two inner DashMaps (rooms + hold_timers).

### HMAC Token Pattern
**Source:** `server/src/turn_creds.rs` lines 27–47
**Apply to:** `server/src/pairing_token.rs`

Steps: compute expiry (now + ttl), format payload string, `new_from_slice(secret)`, `.update(payload)`, `.finalize()`, `engine.encode(bytes)`. Error handling: `.map_err(|e| anyhow::anyhow!("HMAC key error: {e}"))`. The only change for pairing tokens: use `Hmac<Sha256>` + `URL_SAFE_NO_PAD` instead of `Hmac<Sha1>` + `STANDARD`.

### Required Env Var with Remediation Message
**Source:** `server/src/main.rs` lines 73–83
**Apply to:** `PAIRING_TOKEN_SECRET` and `BASE_URL` in `main.rs`

Pattern: `std::env::var("VAR_NAME").map_err(|_| anyhow::anyhow!("VAR_NAME not set — <remediation>"))?`

### Malformed Payload Drop
**Source:** `server/src/ws_server.rs` lines 182–188
**Apply to:** All new message type handlers in `ws_server.rs` and `wt_server.rs`

```rust
let envelope = match parse_envelope(bytes) {
    Some(e) => e,
    None => {
        tracing::warn!("Malformed signaling envelope from {addr}, dropping");
        continue;
    }
};
```
Same pattern applies when deserializing typed payloads from `envelope.payload`: use `serde_json::from_value(envelope.payload).ok()` and drop + warn on None.

### tracing Structured Logging
**Source:** `server/src/ws_server.rs` lines 56–60, 197–204
**Apply to:** All new Rust modules

```rust
tracing::info!(client_id = %id, "WS client registered from {addr}");
tracing::warn!(to = %envelope.to, "signaling target not connected, dropping");
```
Structured fields use `field = %value` syntax. Log level: `info!` for normal lifecycle events, `warn!` for protocol violations or routing misses, `error!` only for server-fatal conditions.

### tokio::spawn Per-Connection Task
**Source:** `server/src/ws_server.rs` lines 83–88
**Apply to:** Hold timer spawns in `room_registry.rs`

```rust
tokio::spawn(async move {
    let _permit = permit; // Released when the connection closes
    if let Err(e) = handle_ws_connection(stream, addr, broker, tls).await {
        tracing::warn!("WS connection error from {addr}: {e}");
    }
});
```
Each spawned task owns its data via `move` closure. Errors in one task do not kill the accept loop. Hold timer tasks follow the same pattern.

### #[tokio::test] Unit Test Structure
**Source:** `server/src/broker.rs` lines 69–131
**Apply to:** Tests in `room_registry.rs` and `pairing_token.rs`

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]        // for async tests
    async fn test_name() { ... }

    #[test]               // for sync-only tests (no .await)
    fn test_name() { ... }
}
```
Inline `mod tests` inside the source file. No separate test files. Test names follow `test_<what>_<expected_outcome>` naming pattern.

---

## No Analog Found

| File | Role | Data Flow | Reason |
|------|------|-----------|--------|
| `client/dist/room.js` | component | event-driven | No JS modules exist in the project yet; use RESEARCH.md Code Examples |
| `docker/nginx/nginx.conf` | config | request-response | nginx not yet in docker-compose; use RESEARCH.md Pattern 6 directly |

---

## Metadata

**Analog search scope:** `server/src/` (all .rs files read), `client/dist/` (existing placeholder HTML)
**Files scanned:** 7 (broker.rs, turn_creds.rs, signaling.rs, ws_server.rs, wt_server.rs, main.rs, client/dist/index.html)
**Pattern extraction date:** 2026-07-07
