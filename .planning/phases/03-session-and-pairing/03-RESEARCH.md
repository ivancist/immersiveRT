# Phase 3: Session and Pairing - Research

**Researched:** 2026-07-07
**Domain:** Rust room/session state management, HMAC token signing, QR code rendering, nginx HTTPS + SPA routing
**Confidence:** MEDIUM (server patterns verified against existing codebase; library choices cross-checked via registry)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** Lobby has two explicit buttons: Create Room and Join Room. No combined single form.
- **D-02:** Create Room flow: user clicks Create → selects game/mode → server creates room with `game_type` field → client redirects to `/room/ABCD`. Phase 3 ships one placeholder game type.
- **D-03:** Join Room flow: user enters room code + username → server validates → client redirects to `/room/ABCD` if approved.
- **D-04:** Server auto-creates a room on first Create request — no explicit precursor API call. Server generates the room code.
- **D-05:** Room code format: short alphanumeric (~4–6 chars). Case-insensitive. Exclude ambiguous characters.
- **D-06:** Room identity expressed in URL path `/room/ABCD`. nginx serves same `index.html` for all paths (`try_files $uri /index.html`).
- **D-07:** Client navigates to `/room/ABCD` via `history.pushState` ONLY after server approval. Never before.
- **D-08:** Server enforces maximum 8 desktops per room. 9th join attempt is rejected.
- **D-09:** Join handshake uses the existing WS/WT connection. No separate HTTP round trip.
- **D-10:** Message format: `{"type": "join-room", "from": "<client-id>", "to": "", "payload": {"username": "...", "room_code": "...", "game_type": "..."}}`. Response: `{"type": "join-ack", "payload": {"slot": 2, "room_code": "ABCD", "reconnect_token": "...", "pairing_url": "https://..."}}` or `{"type": "join-error", "payload": {"reason": "room_full|room_not_found|..."}}`.
- **D-11 (UX):** Client may pre-open WS/WT connection while user is still typing. Optional optimization.
- **D-12:** QR code rendered client-side via a JS library. Server sends pairing URL string. No server-side QR image endpoint.
- **D-13:** QR code encodes full HTTPS URL: `https://host/phone?token=<signed-token>`. Camera-app scannable.
- **D-14:** Pairing token is HMAC-signed, single-use, short-lived (TTL ~60–120s). Encodes room + slot + expiry. Invalidated after first use.
- **D-15:** Desktop shows short alphanumeric code as fallback (SESS-03).
- **D-16:** On disconnect, server marks slot `status: disconnected` and starts 60-second hold timer.
- **D-17:** Reconnect identified by reconnect token stored in `sessionStorage`. On reconnect, client sends token; server reclaims slot within hold window.
- **D-18:** Hold window preserves reservation only — no message buffering.
- **D-19:** On hold expiry with no reconnect: slot released, `player-left` lifecycle event fired to all room desktops.
- **D-20:** Room lifecycle events pushed to all desktops in room over existing WS/WT connections.
- **D-21:** Event format: `{"type": "room-event", "payload": {"event": "player-joined|player-left|player-reconnected|room-full", "slot": 2, "username": "Alice"}}`.
- **D-22:** Events pushed proactively by server — no polling. Events fire on: slot assigned, disconnect (hold started), reconnect, hold expired, room-full rejection.

### Claude's Discretion
- Exact room code length and character set (exclude ambiguous chars like 0/O, 1/I/l).
- Hold timer implementation (tokio `sleep` per slot vs. periodic cleanup sweep).
- Room state data structure on server (extend `SignalingBroker` vs. separate `RoomRegistry`).
- Reconnect token format (HMAC vs. random opaque token with server-side lookup).
- HMAC secret management for pairing tokens (env var, generated at startup).

### Deferred Ideas (OUT OF SCOPE)
- Spectator mode (SESS-V2-01)
- Room password protection (SESS-V2-02)
- Session persistence across page reload via URL token (SESS-V2-03)
- Multiple concrete game types (UI scaffolded in Phase 3; implementations in Phase 8+)
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| SESS-01 | Desktop player can join a room by entering a username — server assigns a named slot and a room code | RoomRegistry design: slot assignment logic, room code generation with `rand` crate |
| SESS-02 | Desktop shows a QR code unique to its player slot — phone scans to pair exclusively to that desktop | Pairing token (HMAC-SHA256), QR rendering via `qrcode` JS CDN, HTTPS URL construction |
| SESS-03 | Desktop shows a short alphanumeric code as fallback for phones that cannot scan QR | Derived from room_code + slot_id, displayed alongside QR |
| SESS-04 | Server holds a player's slot for 60 seconds after disconnect — phone or desktop can reclaim same slot on reconnect | tokio JoinHandle::abort() hold-timer pattern, reconnect token verification |
| SESS-05 | Room supports 2–8 desktop players simultaneously | Slot array of fixed size 8, enforce max in join handler |
| SESS-06 | Server emits room lifecycle events: player joined, player left, player reconnected, room full | Broadcast via broker to all ClientIds in room's desktop list |
</phase_requirements>

---

## Summary

Phase 3 extends the existing Rust signaling server (ws_server.rs, wt_server.rs, broker.rs) with two major additions: a new `RoomRegistry` that manages room and slot state, and a small client-side HTML lobby + room UI. The server work is predominantly in-process state management — no new networking protocols or external services are introduced.

The existing `SignalingBroker` (Arc<DashMap<ClientId, Sender>>) already provides the routing foundation. Phase 3 adds a parallel `RoomRegistry` (Arc<DashMap<RoomCode, Room>>) that the same connection handlers consult on inbound `join-room` messages, intercepted before the generic routing path. Room lifecycle events reuse `broker.route()` to push messages back to registered desktop clients.

The critical sub-problem with the highest risk is the hold timer: a 60-second per-slot task that must be cancelled (not just abandoned) on reconnect, because an abandoned timer will fire and evict a successfully-reconnected player. The correct pattern is `JoinHandle::abort()`, not dropping the handle. A parallel `DashMap<(RoomCode, SlotId), JoinHandle<()>>` holds live timers; `remove()` gives ownership, enabling abort() without any lock held across an await.

The client-side work is plain HTML/CSS/JS served by nginx (no npm build step for Phase 3). The QR library (`qrcode` via jsDelivr CDN) generates a canvas QR from the pairing URL received in `join-ack`. A critical nginx constraint: the static file server must serve HTTPS (not plain HTTP) for iOS/Android camera apps to auto-open QR-scanned URLs. This requires mounting the mkcert certs into the nginx container and adding an SSL server block. For LAN testing with a real phone, the mkcert cert must include the machine's LAN IP.

**Primary recommendation:** Implement `RoomRegistry` as a separate `server/src/room_registry.rs` struct wrapping `Arc<DashMap<RoomCode, Room>>`, inject it alongside `broker` into both WS and WT handlers via the established `Arc<T>` pattern, and intercept `join-room` and `reconnect` message types before generic routing.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Room creation and slot assignment | API / Backend (Rust server) | — | Server owns authoritative room state; client is dumb terminal |
| QR code rendering | Browser / Client (JS) | — | D-12 explicitly: client renders QR from URL string sent by server |
| Pairing token generation and validation | API / Backend (Rust server) | — | HMAC secret lives server-side only; single-use tracking requires server state |
| Reconnect token issuance | API / Backend (Rust server) | Browser / Client (sessionStorage) | Server issues token at join; client stores for reconnect |
| Hold timer lifecycle | API / Backend (Rust server) | — | Server owns slot reservation state |
| Room lifecycle event broadcast | API / Backend (Rust server) | — | Server pushes to all desktops via existing broker channels |
| Lobby and room UI | Browser / Client (static HTML/JS) | — | Plain HTML served by nginx; no server-side rendering |
| Static file serving with SPA routing | CDN / Static (nginx) | — | D-06: nginx serves index.html for all paths |
| HTTPS for QR pairing URL | CDN / Static (nginx) | — | nginx with TLS, mkcert certs; required for camera-app auto-open |

---

## Standard Stack

### Core (Server — existing, no new crates required except sha2)

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| dashmap | 6.2 (already in Cargo.toml) | Concurrent room + slot map | Already proven in broker; same `Arc<DashMap>` clone pattern |
| tokio | 1.x (already in Cargo.toml) | Async runtime, sleep, JoinHandle | `tokio::time::sleep` for hold timers; `JoinHandle::abort()` for cancellation |
| hmac | 0.13 (already in Cargo.toml) | HMAC-SHA256 pairing token signing | Reuse established TURN credential pattern with SHA256 instead of SHA1 |
| sha2 | 0.11.x | SHA-256 digest for HMAC | Needed with `hmac` crate for SHA-256 (sha1 is already present for TURN) |
| rand | 0.10.2 | Room code generation | Cryptographic random character selection from custom charset |
| serde_json | 1.x (already) | New message type payloads | No change |
| base64 | 0.22 (already) | Pairing token encoding | Reuse existing pattern from turn_creds.rs |

### Supporting (Client — CDN, no npm install)

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| qrcode (npm/CDN) | 1.5.4 | Client-side QR code rendering | Desktop room page: render QR from pairing URL received in join-ack |

**Version verification (Rust crates):**

```bash
cargo search sha2 --limit 1   # Returns: sha2 = "0.11.0"
cargo search rand --limit 1   # Returns: rand = "0.10.2"
```

**New Cargo.toml additions:**

```toml
sha2 = "0.11"
rand = { version = "0.10", features = ["std"] }
```

**Existing crates that cover Phase 3 without additions:**
- `hmac = "0.13"` — already present; works with sha2 via `Hmac::<Sha256>`
- `base64 = "0.22"` — already present; reuse `STANDARD.encode()` for token
- `dashmap = "6.2"` — already present; RoomRegistry wraps the same pattern
- `tokio = "1"` — already present; JoinHandle and sleep already in the runtime feature set

**Note on `rand` features:** `rand = "0.10"` with `features = ["std"]` is required for `thread_rng()`. The `getrandom` dependency is pulled in transitively for `OsRng`. No `features = ["getrandom"]` flag needed separately.

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `rand` for room code | `uuid` v4 truncated | UUID is 36 chars, not human-readable; rand with custom charset produces 6-char codes |
| HMAC-SHA256 pairing token | Random opaque token (server-side lookup) | Opaque token requires another DashMap lookup table; HMAC is self-validating (room+slot+expiry in payload, no extra lookup), simpler at scale |
| `qrcode` CDN | Inline SVG hand-generated | Hand-rolling QR encoding is ~1000 lines; qrcode is MIT, 15.7M weekly downloads, trivial CDN include |
| `qrcode` CDN | `qr-creator` CDN | qr-creator has 133k vs 15.7M weekly downloads; qrcode is the clear standard |
| Per-slot JoinHandle timer | Periodic cleanup sweep | Per-slot handle is simpler for <100 concurrent rooms; sweep is better for large scale; gaming session scale justifies per-slot |

---

## Package Legitimacy Audit

> Packages verified via `gsd-tools query package-legitimacy check`.

| Package | Registry | Age | Downloads | Source Repo | Verdict | Disposition |
|---------|----------|-----|-----------|-------------|---------|-------------|
| qrcode | npm | 12+ yrs (pub 2024-08-05) | 15.7M/wk | github.com/soldair/node-qrcode | OK | Approved (CDN only, no install) |
| qr-creator | npm | 6 yrs | 133k/wk | github.com/nimiq/qr-creator | OK | Approved (alternative, not primary) |

**Packages removed due to SLOP verdict:** none

**Packages flagged as suspicious (SUS):** none

**Note:** `qrcode` has no `postinstall` script (confirmed via `npm view qrcode scripts`). Used via CDN only — no `npm install` in Phase 3.

**Rust crates `sha2` and `rand`:** Discovered via `cargo search` (authoritative Rust registry). Both are members of the `rust-random` and `RustCrypto` organizations respectively — long-established, foundational crates. [ASSUMED: authoritative source verification; Context7 lookup not performed this session.]

---

## Architecture Patterns

### System Architecture Diagram

```
Desktop Browser                  Rust Server (ws_server / wt_server)       Room State
      |                                      |                                  |
      |-- WS/WT connect ------------------>  |                                  |
      |-- {type:"register", from:id} -----> broker.register(id)                |
      |                                      |                                  |
      |-- {type:"join-room", ...} --------> INTERCEPT (before broker.route)    |
      |                                      |--- room_registry.join() ------> DashMap<RoomCode, Room>
      |                                      |<-- Slot assigned, token gen'd   |
      |<-- {type:"join-ack", slot, token}    |                                  |
      |                                      |--- broker.route(id, room-event) -> other desktops
      |                                      |
      |   [disconnect]                       |
      |  (WS/WT task ends)                   |--- room_registry.on_disconnect(id)
      |                                      |--- spawn hold_timer (JoinHandle)
      |                                      |--- hold_timers.insert((code,slot), handle)
      |                                      |
      |-- WS/WT reconnect ----------------> |
      |-- {type:"reconnect", token} ------> INTERCEPT
      |                                      |--- hold_timers.remove() -> handle.abort()
      |                                      |--- room_registry.reclaim_slot(token)
      |<-- {type:"join-ack", slot, ...}      |
      |                                      |--- broadcast player-reconnected to room

Phone Browser                    Rust Server                                  Room State
      |                                      |                                  |
      | [scans QR: https://host/phone?token=X]                                 |
      |-- WS/WT connect ----------------->  |                                  |
      |-- {type:"pair", token:X} --------->  INTERCEPT                        |
      |                                      |--- validate HMAC + expiry ----> used_tokens DashMap
      |                                      |--- mark token used              |
      |                                      |--- pair phone to desktop slot   |
      |<-- {type:"pair-ack", desktop_id}     |
```

### Recommended Project Structure (new files for Phase 3)

```
server/src/
├── broker.rs           # (existing) SignalingBroker — no changes
├── signaling.rs        # (extend) add join-room, join-ack, join-error, room-event, reconnect, pair types
├── room_registry.rs    # (NEW) RoomRegistry, Room, Slot, SlotStatus, hold timer logic
├── pairing_token.rs    # (NEW) HMAC-SHA256 pairing token gen + validation; single-use tracking
├── ws_server.rs        # (extend) intercept join-room, reconnect, pair before generic route
├── wt_server.rs        # (extend) same interception as ws_server
└── main.rs             # (extend) construct RoomRegistry + hold_timers DashMap, inject into handlers

client/dist/
├── index.html          # (replace placeholder) lobby + room UI (plain HTML/JS, no build step)
└── room.js             # (NEW) SPA router + room/lobby logic (vanilla JS)

docker/nginx/
└── nginx.conf          # (NEW) nginx config with try_files + HTTPS SSL block
```

### Pattern 1: Separate RoomRegistry from SignalingBroker

**What:** A dedicated `RoomRegistry` wraps `Arc<DashMap<RoomCode, Room>>`. Both WS and WT handlers receive `Arc<RoomRegistry>` alongside `Arc<SignalingBroker>`.

**When to use:** When multiple connection handlers need concurrent access to the same shared mutable state. Follows the established broker injection pattern from Phase 2.

**Example (sketch — implementation detail for planner):**

```rust
// server/src/room_registry.rs
use dashmap::DashMap;
use std::sync::Arc;
use tokio::task::JoinHandle;

pub type RoomCode = String;
pub type SlotId = u8; // 1–8

#[derive(Debug, Clone, PartialEq)]
pub enum SlotStatus {
    Connected,
    Disconnected,
    Empty,
}

#[derive(Debug, Clone)]
pub struct SlotInfo {
    pub slot_id: SlotId,
    pub client_id: String,
    pub username: String,
    pub status: SlotStatus,
    pub reconnect_token: String,
}

pub struct Room {
    pub code: RoomCode,
    pub game_type: String,
    pub slots: Vec<Option<SlotInfo>>,  // len=8, index = slot_id-1
    pub max_slots: usize,
}

#[derive(Clone)]
pub struct RoomRegistry {
    rooms: Arc<DashMap<RoomCode, Room>>,
    // Separate map prevents holding rooms lock across .await when aborting timers
    hold_timers: Arc<DashMap<(RoomCode, SlotId), JoinHandle<()>>>,
}

// Source: established Arc<DashMap> pattern from broker.rs (same project)
```

**Why separate RoomRegistry from SignalingBroker:** The broker is a pure routing map (ClientId → Sender). Mixing room state into it would couple two orthogonal concerns, complicate unregistration, and break the broker's single-responsibility guarantee. The CONTEXT.md also explicitly notes this as Claude's discretion (separate struct vs extend).

### Pattern 2: Join-Room Message Interception

**What:** WS and WT handlers check `envelope.msg_type` before calling `broker.route()`. Messages of type `join-room`, `reconnect`, and `pair` are handled locally; all other types continue to `broker.route()`.

**When to use:** When the server needs to respond to specific message types with server-generated payloads rather than simply forwarding.

**Example (sketch):**

```rust
// In ws_server.rs relay loop, after parse_envelope:
match envelope.msg_type.as_str() {
    "register" => { /* existing registration */ }
    "join-room" => {
        let ack = room_registry.handle_join(
            &envelope.from,
            &envelope.payload,
            &broker,
            base_url,
            pairing_secret,
        ).await;
        // Send ack directly to this connection's write half
        let _ = write.send(Message::Text(serde_json::to_string(&ack)?.into())).await;
    }
    "reconnect" => {
        let ack = room_registry.handle_reconnect(
            &envelope.from,
            &envelope.payload,
            &broker,
        ).await;
        let _ = write.send(Message::Text(serde_json::to_string(&ack)?.into())).await;
    }
    _ => {
        // Existing broker routing (offer, answer, ice-candidate, pair)
        if !broker.route(&envelope.to, payload) {
            tracing::warn!(to = %envelope.to, "signaling target not connected");
        }
    }
}
// Source: [ASSUMED] — extension of ws_server.rs pattern from this project
```

### Pattern 3: Hold Timer with JoinHandle::abort()

**What:** Each occupied slot spawns a hold timer when the client disconnects. The JoinHandle is stored in a separate `DashMap<(RoomCode, SlotId), JoinHandle<()>>`. On reconnect, `remove()` gives ownership of the handle; `handle.abort()` cancels the timer without holding any lock across an await.

**When to use:** Per-entity cancellable timers in async Rust. The key invariant: `JoinHandle::abort()` is synchronous (takes `&self`), so it can be called while briefly holding a local variable — but `DashMap::remove()` is the cleanest pattern since it yields ownership.

**Example:**

```rust
// Start hold timer
let hold_arc = room_registry.hold_timers.clone();
let broker_arc = broker.clone();
let room_code_clone = room_code.clone();
let handle = tokio::spawn(async move {
    tokio::time::sleep(std::time::Duration::from_secs(hold_secs)).await;
    // Timer fired — release slot
    room_arc.release_slot(&room_code_clone, slot_id);
    // Broadcast player-left to remaining desktops
    let event = make_room_event("player-left", slot_id, &username);
    broker_arc_inner.broadcast_room(&room_code_clone, event);
});
room_registry.hold_timers.insert((room_code.clone(), slot_id), handle);

// Cancel on reconnect
if let Some((_, handle)) = room_registry.hold_timers.remove(&(room_code.clone(), slot_id)) {
    handle.abort();  // Synchronous — safe, no lock held
}
// Source: [ASSUMED] — derived from tokio JoinHandle docs; abort() is &self
```

### Pattern 4: HMAC-SHA256 Pairing Token

**What:** Self-validating token encodes `{room_code}:{slot_id}:{expiry_unix}`, signed with HMAC-SHA256, base64-URL encoded. Server validates signature + expiry, marks used in `DashMap<String, ()>`.

**When to use:** Single-use short-lived tokens where the payload must survive without a database lookup. Follows the existing `turn_creds.rs` HMAC-SHA1 pattern.

**Example:**

```rust
// pairing_token.rs — reuses hmac + base64 pattern from turn_creds.rs
use hmac::{Hmac, Mac, KeyInit};
use sha2::Sha256;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};

type HmacSha256 = Hmac<Sha256>;

pub fn generate_pairing_token(
    secret: &str,
    room_code: &str,
    slot_id: u8,
    ttl_secs: u64,
) -> anyhow::Result<String> {
    let expiry = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs() + ttl_secs;
    let payload = format!("{room_code}:{slot_id}:{expiry}");
    let mut mac = HmacSha256::new_from_slice(secret.as_bytes())?;
    mac.update(payload.as_bytes());
    let sig = URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes());
    // Token = base64url(payload) + "." + base64url(sig)
    let encoded_payload = URL_SAFE_NO_PAD.encode(payload.as_bytes());
    Ok(format!("{encoded_payload}.{sig}"))
}

// Validation: parse payload, check expiry, verify HMAC with verify_slice (constant-time),
// then check + mark used in used_tokens DashMap.
// Source: [ASSUMED] — modelled on turn_creds.rs (same project) + hmac crate docs
```

### Pattern 5: Room Code Generation

**What:** 6-character uppercase code from a 32-character unambiguous charset. Uses `rand::Rng` with a custom byte slice.

**When to use:** Human-readable short codes where visual ambiguity must be eliminated.

**Recommended charset (Claude's discretion):**

```
ABCDEFGHJKLMNPQRSTUVWXYZ23456789
```

Excluded: `0` (like O), `O` (like 0), `1` (like I/l), `I` (like 1/l), `L` (like 1/I). 32 chars → 32^6 ≈ 1 billion combinations.

**Example:**

```rust
use rand::Rng;

const CHARSET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const CODE_LEN: usize = 6;

pub fn generate_room_code() -> String {
    let mut rng = rand::thread_rng();
    (0..CODE_LEN)
        .map(|_| {
            let idx = rng.gen_range(0..CHARSET.len());
            CHARSET[idx] as char
        })
        .collect()
}
// Source: [ASSUMED] — standard Rust custom-charset pattern from Rust Cookbook
```

Collision check: after generation, check `room_registry.rooms.contains_key(&code)`; regenerate if collision (probability: ~6e-9 at 1000 concurrent rooms, effectively zero).

### Pattern 6: nginx HTTPS + SPA Routing

**What:** nginx serves static HTML with `try_files $uri /index.html` for SPA routing, and listens on HTTPS using the mkcert certs already generated for the Rust server.

**nginx.conf:**

```nginx
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

**docker-compose addition for nginx:**

```yaml
static-files:
  image: nginx:alpine
  ports:
    - "8090:80"
    - "8443:443"       # HTTPS for QR camera-app auto-open
  volumes:
    - ./client/dist:/usr/share/nginx/html:ro
    - ./docker/nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    - ./certs:/certs:ro                # same mkcert certs as server
```

[ASSUMED] — nginx SSL config pattern is standard; docker-compose volume mount pattern follows existing service.

### Pattern 7: Client-side QR Code Rendering

**What:** Desktop room page includes the `qrcode` library via CDN, renders a QR canvas from the `pairing_url` received in `join-ack`.

```html
<!-- In index.html head -->
<script src="https://cdn.jsdelivr.net/npm/qrcode@1.5.4/build/qrcode.min.js"></script>

<!-- Room page QR rendering -->
<canvas id="pairing-qr"></canvas>
<script>
  function renderQR(pairingUrl) {
    QRCode.toCanvas(
      document.getElementById('pairing-qr'),
      pairingUrl,
      { width: 256, margin: 2 },
      (err) => { if (err) console.error('QR render error:', err); }
    );
  }
  // Called after join-ack received via WS/WT
</script>
```

[CITED: https://www.npmjs.com/package/qrcode] — standard QRCode.toCanvas API.

### Anti-Patterns to Avoid

- **Hold DashMap Ref across .await:** If a DashMap Ref or RefMut is alive when an `.await` fires, the tokio thread pool shard lock is held across the await — this can deadlock if another task on the same thread tries to access the same shard. Clone data out before any `.await`.
- **Drop JoinHandle without aborting:** `drop(handle)` detaches the task, it keeps running. If the hold timer task is dropped without `.abort()`, it fires 60s later and evicts a reconnected player.
- **HMAC comparison with `==`:** Byte-slice equality (`sig == expected`) is not constant-time and leaks timing information. Use `hmac::Mac::verify_slice()` which is constant-time.
- **HTTP pairing URL in QR:** If the QR encodes `http://` instead of `https://`, iOS/Android camera apps will NOT auto-open the link in a browser. Must be HTTPS.
- **mkcert cert for localhost only on LAN:** The generated cert covers `localhost 127.0.0.1 ::1`. A real phone on the same LAN needs the machine's LAN IP in the cert SAN. See Pitfall 3.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| QR code generation | Custom QR encoding | `qrcode` npm CDN | QR encoding is ~3000 lines of Reed-Solomon error correction; 15.7M/wk downloads, MIT |
| HMAC token signing | Custom token format | `hmac` + `sha2` crates (already used) | Replay attack vectors, timing attack surfaces — crypto is not DIY |
| Random code generation | `rand() % 32` modulo bias | `rand::Rng::gen_range(0..N)` | Simple modulo creates statistical bias toward low values; gen_range is bias-free |
| Constant-time comparison | `sig_a == sig_b` | `hmac::Mac::verify_slice()` | Timing attack on string equality is a real exploit vector for HMAC verification |
| SPA routing fallback | Custom server-side URL rewriting | `try_files $uri /index.html` in nginx | nginx handles this in one directive; hand-rolling breaks static asset serving |

**Key insight:** The crypto primitives (`hmac`, `sha2`) and QR encoding (`qrcode`) are both domains where hand-rolling introduces subtle, hard-to-detect vulnerabilities or compatibility failures. Reuse the established patterns.

---

## Common Pitfalls

### Pitfall 1: DashMap Deadlock with Async Code

**What goes wrong:** A DashMap `Ref` (returned by `get()`) or `RefMut` (returned by `get_mut()`) holds a shard RwLock. If `.await` fires while the Ref is still in scope, the thread yields but the lock is not released. If another task on the same tokio thread tries to access the same shard, deadlock occurs.

**Why it happens:** DashMap is designed for synchronous code. The shard lock is not async-aware.

**How to avoid:** Clone or copy the needed value immediately after getting it, then drop the Ref before any `.await`. For JoinHandle removal, use `DashMap::remove()` which returns `Option<V>` (owned) without holding a guard.

```rust
// WRONG: holds Ref across .await
if let Some(sender) = broker.clients.get(&id) {
    sender.send(data).await; // guard still alive here
}

// RIGHT: clone out, drop guard immediately
let sender = broker.clients.get(&id).map(|r| r.value().clone());
drop(sender_ref); // implicit drop of Ref before await
if let Some(s) = sender {
    s.send(data).await;
}
```

**Warning signs:** Occasional hangs under concurrent load but not in single-client tests.

### Pitfall 2: Abandoned JoinHandle on Disconnect

**What goes wrong:** When a slot's hold timer fires after the player has successfully reconnected, the timer sees `SlotStatus::Connected` and either ignores it (if coded defensively) or wrongly evicts the reconnected player.

**Why it happens:** `drop(handle)` detaches the task — it continues running. The reconnect path forgot to abort the timer.

**How to avoid:** Always call `handle.abort()` on successful reconnect. The `hold_timers.remove()` pattern ensures the handle is taken out of the map (preventing double-abort) and then aborted.

**Defense in depth:** Even if abort is missed, the timer task should check `SlotStatus::Connected` before evicting — refuse to fire if the player already reconnected. This is belt-and-suspenders, not a substitute for abort().

**Warning signs:** Players randomly disconnected exactly 60 seconds after a prior disconnect, even though they successfully reconnected.

### Pitfall 3: mkcert Certificate Does Not Cover LAN IP

**What goes wrong:** The phone scans the QR code, the URL contains the machine's LAN IP (e.g., `192.168.1.10`), the phone browser opens it but gets `NET::ERR_CERT_AUTHORITY_INVALID` because the mkcert cert SAN covers only `localhost 127.0.0.1 ::1`.

**Why it happens:** `make dev-certs` generates certs for localhost only. Phone-on-LAN needs the machine's LAN IP in the cert.

**How to avoid:** When running the full stack for phone testing, regenerate the cert including the LAN IP:

```bash
mkcert -key-file certs/localhost+2-key.pem \
       -cert-file certs/localhost+2.pem \
       localhost 127.0.0.1 ::1 192.168.1.10
```

OR install the mkcert CA on the phone (`mkcert -CAROOT` shows path; transfer and install as trusted CA).

The `make dev-certs` target should be updated to accept an optional `LAN_IP` argument, or the Makefile should auto-detect the LAN IP via `ip route get 1.1.1.1 | awk '{print $7}'`.

**Warning signs:** QR code works when scanning from desktop browser (localhost) but fails when scanned with a real phone.

### Pitfall 4: TURN Credential Expiry Pattern (Already Known)

**What goes wrong:** `username = format!("{now}:{userid}")` instead of `format!("{expiry}:{userid}")` produces immediately-expiring credentials.

**Why it happens:** coturn interprets the timestamp in the username as the expiry time, not the issue time.

**How to avoid:** Always `expiry = now + ttl`. Already implemented correctly in `turn_creds.rs`. Pairing tokens must follow the same pattern: expiry is `now + ttl`, not `now`.

**Warning signs:** TURN authentication fails immediately after credential generation.

### Pitfall 5: Plain HTTP Pairing URL

**What goes wrong:** Pairing URL encodes `http://host:8090/phone?token=...`. iOS/Android camera apps do NOT auto-open HTTP links — they open only HTTPS links automatically.

**Why it happens:** nginx is currently serving plain HTTP on port 8090. If `BASE_URL` env var defaults to HTTP, all QR codes will be HTTP.

**How to avoid:** Set `BASE_URL=https://localhost:8443` (or the machine's HTTPS address). nginx must be configured with TLS on port 443/8443. Never let `BASE_URL` default to `http://`.

**Warning signs:** Phone camera app shows a preview of the URL but doesn't open the browser automatically; user must tap manually and then gets a cert error.

---

## Code Examples

### Room code generation (Rust)

```rust
// Source: [ASSUMED] — Rust Cookbook random alphanumeric pattern, adapted for custom charset
const CHARSET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // 32 chars, no ambiguous
const CODE_LEN: usize = 6;

pub fn generate_room_code() -> String {
    let mut rng = rand::thread_rng();
    (0..CODE_LEN)
        .map(|_| CHARSET[rng.gen_range(0..CHARSET.len())] as char)
        .collect()
}
```

### HMAC-SHA256 token generation (Rust)

```rust
// Source: [ASSUMED] — follows turn_creds.rs pattern with sha2 instead of sha1
use hmac::{Hmac, Mac, KeyInit};
use sha2::Sha256;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};

type HmacSha256 = Hmac<Sha256>;

pub fn generate_pairing_token(
    secret: &str,
    room_code: &str,
    slot_id: u8,
    expiry_unix: u64,
) -> anyhow::Result<String> {
    let payload = format!("{room_code}:{slot_id}:{expiry_unix}");
    let mut mac = HmacSha256::new_from_slice(secret.as_bytes())
        .map_err(|e| anyhow::anyhow!("HMAC key error: {e}"))?;
    mac.update(payload.as_bytes());
    let sig = URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes());
    let encoded_payload = URL_SAFE_NO_PAD.encode(payload.as_bytes());
    Ok(format!("{encoded_payload}.{sig}"))
}

pub fn validate_pairing_token(secret: &str, token: &str) -> Option<(String, u8)> {
    let (enc_payload, sig) = token.split_once('.')?;
    let payload_bytes = URL_SAFE_NO_PAD.decode(enc_payload).ok()?;
    let payload = std::str::from_utf8(&payload_bytes).ok()?;

    // Constant-time HMAC verification
    let mut mac = HmacSha256::new_from_slice(secret.as_bytes()).ok()?;
    mac.update(payload.as_bytes());
    let expected_sig_bytes = URL_SAFE_NO_PAD.decode(sig).ok()?;
    mac.verify_slice(&expected_sig_bytes).ok()?; // constant-time

    // Parse payload
    let parts: Vec<&str> = payload.splitn(3, ':').collect();
    if parts.len() != 3 { return None; }
    let room_code = parts[0].to_string();
    let slot_id: u8 = parts[1].parse().ok()?;
    let expiry: u64 = parts[2].parse().ok()?;

    let now = SystemTime::now().duration_since(UNIX_EPOCH).ok()?.as_secs();
    if now > expiry { return None; } // expired

    Some((room_code, slot_id))
}
```

### Hold timer cancel pattern (Rust)

```rust
// Source: [ASSUMED] — derived from tokio JoinHandle abort() docs
// START hold timer
let handle = tokio::spawn({
    let registry = room_registry.clone();
    let broker = broker.clone();
    let room_code = room_code.clone();
    async move {
        tokio::time::sleep(std::time::Duration::from_secs(hold_secs)).await;
        // Guard: check slot still disconnected (not already reconnected)
        if registry.is_slot_disconnected(&room_code, slot_id) {
            registry.release_slot(&room_code, slot_id);
            let event = make_room_event("player-left", slot_id, &username);
            broadcast_to_room(&broker, &registry, &room_code, event).await;
        }
    }
});
room_registry.hold_timers.insert((room_code.clone(), slot_id), handle);

// CANCEL hold timer on reconnect
if let Some((_, handle)) = room_registry.hold_timers.remove(&(room_code.clone(), slot_id)) {
    handle.abort(); // synchronous, no lock held
}
```

### nginx SPA + HTTPS config

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
# Source: [ASSUMED] — standard nginx SPA + SSL configuration pattern
```

### Client-side WS connection and join-room flow (JS)

```javascript
// room.js — vanilla JS SPA router + WS signaling client
// Source: [ASSUMED] — browser WebSocket API, standard SPA pushState pattern

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

function joinRoom(roomCode, username, gameType) {
    ws.send(JSON.stringify({
        type: 'join-room',
        from: myId,
        to: '',
        payload: { room_code: roomCode, username, game_type: gameType }
    }));
}

function handleJoinAck(payload) {
    const { slot, room_code, reconnect_token, pairing_url } = payload;
    sessionStorage.setItem('reconnect_token', reconnect_token);
    sessionStorage.setItem('room_code', room_code);
    // Navigate to room URL only after server approval (D-07)
    history.pushState({ slot, room_code }, '', `/room/${room_code}`);
    renderRoomPage(slot, room_code, pairing_url);
}

function renderRoomPage(slot, roomCode, pairingUrl) {
    // Render QR code using the qrcode CDN library
    QRCode.toCanvas(document.getElementById('pairing-qr'), pairingUrl, { width: 256 });
    // Short code fallback: room_code + slot_id
    document.getElementById('short-code').textContent = `${roomCode}-${slot}`;
}
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Server-side QR image generation (PNG endpoint) | Client-side QR rendering from URL string | 2020+ | Eliminates server image generation overhead; URL is the data, library is tiny |
| Polling for room state updates | Server-push events over persistent connection | 2015+ (WS era) | Established pattern; no polling needed with WS/WT |
| Signed JWTs for pairing tokens | HMAC-signed structured token (same idea, simpler format) | N/A | JWTs add header+alg metadata overhead; for a single-purpose short-lived token, raw HMAC payload is sufficient |

**Not deprecated in this stack:** `history.pushState` — still the canonical SPA routing primitive; no framework needed for Phase 3's scope.

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `rand = "0.10"` with `features = ["std"]` provides `thread_rng()` and `gen_range()` | Standard Stack | If API changed in 0.10, room code generation needs adjustment; low risk given stable crate |
| A2 | `sha2 = "0.11"` is compatible with `hmac = "0.13"` from the same RustCrypto organization | Standard Stack | Crate version mismatch causes compile error; confirmed by cargo dependency resolution at build time |
| A3 | `JoinHandle::abort()` takes `&self` (synchronous, not async) | Pattern 3, Pitfall 2 | If it were async, the hold_timer abort pattern would need restructuring |
| A4 | `DashMap::remove()` returns owned value without holding a shard guard | Pattern 3 | If this is wrong, we'd need to restructure to avoid deadlock |
| A5 | `qrcode@1.5.4` jsDelivr CDN URL is stable and accessible | Standard Stack, Pattern 7 | CDN outage would block QR rendering; fallback: vendor the file in client/dist/ |
| A6 | nginx `try_files $uri /index.html` without trailing slash on directory serves index.html for paths like `/room/ABCD` | Pattern 6 | Misconfigured nginx could return 404 for room paths; easy to verify at runtime |
| A7 | mkcert certs are compatible with nginx SSL config (PEM format with full chain) | Pattern 6, Pitfall 3 | nginx SSL errors at startup if cert format is wrong; recoverable |
| A8 | iOS/Android camera apps auto-open HTTPS URLs from QR codes | Pitfall 5, D-13 | If this assumption is wrong, the phone pairing UX requires a different approach |
| A9 | `tokio::time::sleep` in a spawned task is cancelled when `JoinHandle::abort()` is called | Pattern 3 | If sleep is not cancellable, hold timers cannot be stopped; this is documented tokio behavior |

---

## Open Questions

1. **LAN IP in dev cert for phone testing**
   - What we know: `make dev-certs` generates for localhost/127.0.0.1/::1 only
   - What's unclear: Should Phase 3 update the Makefile to auto-detect LAN IP and include it, or leave this as a documented manual step?
   - Recommendation: Update `make dev-certs` to detect LAN IP via `ip route` and include it. This removes the most common dev friction when testing with a real phone.

2. **BASE_URL env var for pairing URL construction**
   - What we know: Server constructs `https://host/phone?token=...` (D-13); needs to know its own hostname
   - What's unclear: Should `BASE_URL` default to `https://localhost:8443` or be required (like `TURN_SHARED_SECRET`)? For multi-machine LAN testing, the user must override it.
   - Recommendation: Required env var (no default) following the `TURN_SHARED_SECRET` precedent. Error message: "Set BASE_URL=https://<your-ip>:8443".

3. **Short code format for SESS-03**
   - What we know: D-15 says "room code + slot number, or a derived short string"
   - What's unclear: Is `ABCD-2` (room_code dash slot) the right format, or a separate 6-char derived code?
   - Recommendation: `{room_code}-{slot_id}` (e.g., `ABCD23-2`). Simple, unique, human-typeable. The phone app URL would accept both token and this fallback code.

4. **PAIRING_TOKEN_SECRET env var management**
   - What we know: Pairing token is HMAC-signed, needs a server-side secret (D-14, Claude's discretion)
   - What's unclear: Generated at startup (random, ephemeral) or required env var (persistent across restarts)?
   - Recommendation: Required env var (32+ char random secret). Ephemeral startup-generated secrets invalidate all tokens on server restart — bad for hold-window reconnects when the server crashes and restarts. Persistent env var allows tokens to survive server restarts within TTL.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Docker | docker-compose stack (nginx TLS, server) | ✓ | 29.6.0 | — |
| cargo | Rust server build | ✓ | 1.93.1 (2025-12-15) | — |
| Node.js | npm view for package verification (dev only) | ✓ | v25.6.1 | — |
| nginx | Static file serving + TLS | ✓ (via Docker) | alpine image | — |
| mkcert | TLS cert generation | already generated (certs/ exist) | — | Regenerate with `make dev-certs` |

**Missing dependencies with no fallback:** None.

**Missing dependencies with fallback:** None.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Rust built-in test harness + `#[tokio::test]` |
| Config file | `server/Cargo.toml` (no separate config; `cargo test` invokes) |
| Quick run command | `cargo test -p immersive-rt-server room_registry` |
| Full suite command | `cargo test -p immersive-rt-server` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| SESS-01 | join-room message assigns slot and returns join-ack with room_code | unit | `cargo test -p immersive-rt-server room_registry::tests::test_join_creates_room` | ❌ Wave 0 |
| SESS-01 | 9th join attempt returns join-error (room_full) | unit | `cargo test -p immersive-rt-server room_registry::tests::test_room_full_rejection` | ❌ Wave 0 |
| SESS-02 | pairing token validates HMAC + expiry, fails on replay | unit | `cargo test -p immersive-rt-server pairing_token::tests::test_token_single_use` | ❌ Wave 0 |
| SESS-02 | pairing token expired token returns None | unit | `cargo test -p immersive-rt-server pairing_token::tests::test_token_expiry` | ❌ Wave 0 |
| SESS-04 | hold timer fires after 60s and releases slot | unit | `cargo test -p immersive-rt-server room_registry::tests::test_hold_timer_fires` | ❌ Wave 0 |
| SESS-04 | abort on reconnect cancels hold timer (slot stays assigned) | unit | `cargo test -p immersive-rt-server room_registry::tests::test_reconnect_cancels_timer` | ❌ Wave 0 |
| SESS-05 | room accepts 8 desktops, rejects 9th | unit | `cargo test -p immersive-rt-server room_registry::tests::test_max_slots_enforced` | ❌ Wave 0 |
| SESS-06 | player-left event broadcast to remaining desktops | unit | `cargo test -p immersive-rt-server room_registry::tests::test_lifecycle_events` | ❌ Wave 0 |

### Sampling Rate

- **Per task commit:** `cargo test -p immersive-rt-server`
- **Per wave merge:** `cargo test -p immersive-rt-server && cargo clippy -p immersive-rt-server -- -D warnings`
- **Phase gate:** Full suite green before `/gsd-verify-work`

### Wave 0 Gaps

- [ ] `server/src/room_registry.rs` — covers SESS-01, SESS-04, SESS-05, SESS-06
- [ ] `server/src/pairing_token.rs` — covers SESS-02
- [ ] Tests follow existing `#[tokio::test]` pattern from broker.rs and main.rs

*(No new test framework needed — tokio is already wired.)*

---

## Security Domain

> `security_enforcement = true`, ASVS level 1.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No | No user auth in Phase 3 (slot-based pairing, not account-based) |
| V3 Session Management | Yes | Reconnect token in `sessionStorage` (not cookies); short TTL pairing token; hold timer bounds session lifetime |
| V4 Access Control | Yes | Slot claimed only by bearer of valid pairing token; `from` spoofing already prevented by registered-ID check in ws_server.rs |
| V5 Input Validation | Yes | `username` length limit (server-side: 64 chars max), `room_code` sanitize to CHARSET only (reject unknown chars), `game_type` enum validation |
| V6 Cryptography | Yes | HMAC-SHA256 for pairing tokens; constant-time verify via `hmac::Mac::verify_slice()`; `rand::thread_rng()` for reconnect token; never hand-roll crypto |

### Known Threat Patterns for This Stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| QR token replay (screenshot + rescan) | Spoofing | Single-use tracking in `used_tokens` DashMap; short TTL (60–120s) |
| Slot squatting (malicious client sends join-room repeatedly) | Denial of Service | Room max 8 slots enforced; rate limit join-room per client (1 attempt per 5s sufficient) |
| HMAC timing side-channel | Information Disclosure | `hmac::Mac::verify_slice()` is constant-time |
| `from` field spoofing in messages | Spoofing | Already mitigated in ws_server.rs (registered ID vs claimed `from` comparison) |
| Malformed `join-room` payload | Tampering | `serde_json` parse failure returns None → drop message, log warning (established T-01-06 pattern) |
| Username injection | Tampering | Validate username is printable, 1–64 chars; strip control characters before storing or broadcasting |

---

## Sources

### Primary (MEDIUM confidence — context7 provider)

*Context7 library lookups were routed to websearch provider this session (no Context7 MCP available). All Rust patterns are derived from existing project source code.*

### Secondary (MEDIUM confidence — existing project source)

- `server/src/broker.rs` — Arc<DashMap> pattern, register/unregister, route; Phase 3 RoomRegistry follows exactly this structure
- `server/src/turn_creds.rs` — HMAC-SHA1 token generation; pairing token mirrors this with SHA-256
- `server/src/ws_server.rs` — message interception pattern for `register`; Phase 3 extends to `join-room`
- `server/src/main.rs` — env var config pattern; `Arc<T>` injection into both listeners

### Tertiary (LOW confidence — websearch)

- [qrcode npm](https://www.npmjs.com/package/qrcode) — package legitimacy + API verified
- [jsDelivr qrcode CDN](https://www.jsdelivr.com/package/npm/qrcode) — CDN URL confirmed
- [tokio JoinHandle docs](https://docs.rs/tokio/latest/tokio/task/struct.JoinHandle.html) — abort() is synchronous, takes &self
- [DashMap deadlock issue](https://github.com/xacrimon/dashmap/issues/79) — async deadlock risk documented
- [nginx SPA try_files](https://apipark.com/techblog/en/configure-nginx-history-mode-spa-routing-made-easy/) — standard directive confirmed
- [Rust Cookbook randomness](https://rust-lang-nursery.github.io/rust-cookbook/algorithms/randomness.html) — custom charset pattern

---

## Metadata

**Confidence breakdown:**

- Standard stack (Rust crates): MEDIUM — verified via cargo search and existing Cargo.toml; sha2+rand versions confirmed from registry
- Architecture patterns: HIGH — directly derived from existing ws_server.rs, broker.rs, turn_creds.rs code in this project
- QR library: MEDIUM — verified via npm registry legitimacy check (15.7M/wk, MIT, no postinstall)
- Pitfalls: MEDIUM — DashMap deadlock and JoinHandle abort patterns are documented in tokio/dashmap docs
- Security controls: MEDIUM — ASVS L1 controls mapped to standard Rust crypto crates

**Research date:** 2026-07-07
**Valid until:** 2026-08-07 (stable Rust ecosystem; 30 days)
