# Phase 2: Signaling, TURN, and Deployment - Research

**Researched:** 2026-07-06
**Domain:** Rust WebRTC signaling relay, coturn ephemeral TURN credentials (HMAC-SHA1 REST API mechanism), Docker Compose multi-container orchestration
**Confidence:** MEDIUM

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** Both WebSocket and WebTransport carry signaling — WebTransport (port 4433) is primary, WebSocket (port 9090) is fallback. Clients use whichever they connected on.
- **D-02:** Default WebSocket port changed from 8080 to **9090** (avoid common port conflicts). Env var `WS_PORT` controls this.
- **D-03:** Cross-transport routing uses a **shared in-process broker** — a `tokio` `DashMap` or `RwLock<HashMap>` mapping client IDs to `mpsc::Sender`. Both WS and WT handlers post into it. Transport-agnostic relay.
- **D-04:** JSON envelope: `{ "type": "offer"|"answer"|"ice-candidate"|"register", "from": "<client-id>", "to": "<client-id>", "payload": {...} }`. Standard WebRTC signaling convention. ICE signaling is low-frequency (<10 messages/session) so JSON overhead is irrelevant.
- **D-05:** **Minimal stateful broker** — server maintains a connected-client map. Forwards only to known connected IDs. Drops messages to unknown targets (does not silently discard without logging — logs a warning). Consistent with the in-process broker structure.
- **D-06:** (Not discussed — defaults from REQUIREMENTS.md apply): INFRA-04 requires ephemeral credentials generated at connection-start using coturn `use-auth-secret` with HMAC-SHA1 time-limited tokens. Researcher and planner determine endpoint placement.
- **D-07:** (Not discussed — defaults from REQUIREMENTS.md apply): coturn runs with `network_mode: host` and `external-ip` configured. Planner determines dev/prod compose strategy.

### Claude's Discretion

- Endpoint structure for TURN credential delivery (HTTP sub-path on existing WS port vs new listener) — not specified, planner decides.
- coturn Docker Compose platform compatibility handling (Linux-only vs dev/prod split) — not specified, planner decides.

### Deferred Ideas (OUT OF SCOPE)

None — discussion stayed within phase scope.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| INFRA-02 | Server brokers WebRTC signaling (offer/answer/ICE) between phone and its paired desktop | Broker pattern (Architecture Patterns Pattern 1) — `DashMap<ClientId, mpsc::Sender<Message>>` shared between WT/WS handlers |
| INFRA-03 | Server brokers WebRTC signaling between desktop and all other desktops in the same room | Same broker — `to` field in JSON envelope is transport-agnostic; broker doesn't care if target is a phone or desktop (room semantics arrive in Phase 3, this phase just needs N:N relay to work) |
| INFRA-04 | Server provides a TURN credential endpoint that generates ephemeral credentials at connection-start (not page load) | HMAC-SHA1 credential generation (Code Examples) — `hmac` 0.13 + `sha1` 0.11 + `base64` 0.22, exact algorithm verified against coturn README.turnserver |
| INFRA-06 | coturn STUN/TURN server runs in Docker with `network_mode: host` and `external-ip` configured | Docker Compose Pattern (Architecture Patterns Pattern 4) — `network_mode: host` is mandatory, not optional, per official coturn Docker guidance |
| INFRA-07 | Full stack deployable with a single `docker compose up` (Rust server + coturn + static file server) | Three-service compose file (Code Examples) — Rust server (multi-stage build), coturn (official image), static file server (nginx:alpine per CLAUDE.md) |
</phase_requirements>

---

## Summary

This phase turns the two echo-only listeners from Phase 1 into a real WebRTC signaling relay, adds a TURN credential endpoint implementing coturn's `use-auth-secret` REST API mechanism, and packages the whole stack (Rust server + coturn + static file server) into a single `docker compose up`.

The signaling relay is the most code-heavy part: both `wt_server.rs` and `ws_server.rs` need to register connections into a shared `DashMap<String, mpsc::UnboundedSender<Message>>` broker, and each transport's read loop must both (a) forward inbound JSON envelopes to the broker for routing to another client, and (b) drain its own `mpsc::Receiver` to push outbound messages to its client. This is a fan-in/fan-out pattern, not a simple echo — both wt_server and ws_server need a `tokio::select!` loop that races "read from socket" against "read from broker channel."

The TURN credential piece is narrow but exacting: coturn's `use-auth-secret` mechanism requires `username = "<unix-timestamp>:<userid>"` and `password = base64(HMAC-SHA1(shared-secret, username))`. This is a well-documented, unambiguous algorithm (verified directly against `coturn/coturn` README.turnserver) — there is no room for creative interpretation. Get the exact byte-for-byte input to HMAC right (the username string as UTF-8 bytes) or coturn will silently reject every allocation with 401.

The deployment piece has one hard constraint carried over from Phase 1's STATE.md: coturn **must** run with `network_mode: host` — bridge-mode Docker networking breaks NAT reflection for STUN because coturn needs to see the real external-facing UDP socket, and Docker's large ephemeral port range (49152-65535) performs badly under bridge NAT translation regardless. This is not a preference, it's a documented requirement across every coturn Docker guide.

**Primary recommendation:** Build the broker as a `DashMap<String, mpsc::UnboundedSender<ServerMsg>>` wrapped in `Arc`, shared between `wt_server::run` and `ws_server::run` via an added parameter (mirroring the existing `Arc<T>` injection pattern the codebase already uses). Implement TURN credentials as a plain HTTP endpoint (a minimal `hyper` or raw-TCP-based JSON responder, or piggyback on the WS listener's upgrade path) — do not add a new port; extend one of the two existing listeners. For coturn, use the official `coturn/coturn:4.6` image (already locked in CLAUDE.md) with `network_mode: host`, `use-auth-secret` + `lt-cred-mech` + `static-auth-secret` in `turnserver.conf`, mounted read-only. For WSS, terminate TLS **inside the Rust binary** using `tokio-rustls` + `rustls-pemfile` reusing the same mkcert/production PEM files already loaded for WebTransport — do NOT introduce a reverse proxy for signaling (Caddy cannot proxy WebTransport per CLAUDE.md, and adding a proxy in front of only the WS listener would fragment the TLS story).

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| WebRTC signaling relay (broker) | API / Backend (Rust binary) | — | Both WT and WS handlers live in the same process; broker is in-memory shared state, no external dependency |
| TURN credential generation (HMAC-SHA1) | API / Backend (Rust binary) | — | Must be generated server-side (shared secret never reaches the client); exposed via HTTP-ish endpoint on an existing listener |
| STUN/TURN relay + NAT traversal | External Service (coturn container) | — | coturn is a separate, independently-deployed process; Rust server only issues credentials, never touches the actual STUN/TURN protocol |
| WSS TLS termination for WS fallback | API / Backend (Rust binary) | — | Terminate in-process with tokio-rustls reusing existing PEM certs; no reverse proxy in the loop for signaling traffic |
| Static file serving (desktop game client) | CDN / Static | — | Separate container (nginx:alpine); no dynamic logic, pure asset serving |
| Docker Compose orchestration | Build / Config | — | Declarative multi-container wiring; not application logic |

---

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| dashmap | 6.2.1 | Concurrent client-id → sender map for the signaling broker | Lock-free-ish sharded map; avoids holding a `RwLock` across `.await` points, which is the standard failure mode for async broker state. 5.1M weekly downloads. [VERIFIED: crates.io registry] |
| hmac | 0.13.0 | HMAC-SHA1 computation for coturn ephemeral credentials | RustCrypto's canonical HMAC implementation; generic over any `Digest` impl (used here with `sha1::Sha1`). 8M weekly downloads. [VERIFIED: crates.io registry] |
| sha1 | 0.11.0 | SHA-1 digest backing the HMAC (coturn's REST API mechanism hard-requires SHA-1, not SHA-256) | RustCrypto's canonical SHA-1; pairs with `hmac` via the shared `digest` trait ecosystem (both require `digest ^0.11`). 7.2M weekly downloads. [VERIFIED: crates.io registry] |
| base64 | 0.22.1 | Base64-encode the HMAC output into the TURN password | De-facto standard base64 crate; `Engine` trait API (not the deprecated free-function API from 0.12 and earlier). 20M weekly downloads. [VERIFIED: crates.io registry] |
| tokio-rustls | 0.26.4 | TLS termination for the WSS (WebSocket-over-TLS) fallback listener | Wraps `rustls::ServerConfig` for tokio streams; already transitively present via wtransport→quinn, so no crypto-provider conflict if configured correctly (see Pitfall 3). 11.2M weekly downloads. [VERIFIED: crates.io registry] |
| rustls-pemfile | 2.2.0 | Parse the same mkcert/production PEM files into `rustls` cert/key types | Standard companion to `rustls`/`tokio-rustls`; produces `CertificateDer`/`PrivateKeyDer` matching rustls-pki-types 1.x used across the workspace's existing `rustls` dependency. 5.9M weekly downloads. [VERIFIED: crates.io registry] |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| rand | 0.10.2 | Generate ephemeral client IDs (userid portion of TURN username; broker client IDs) if not supplied by the client | Only if the planner chooses server-generated IDs over client-generated `crypto.randomUUID()`; either is valid, see Open Questions |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| dashmap | `Arc<RwLock<HashMap<...>>>` | Simpler, zero new dependency, but risks holding the lock across an `.await` if not careful (send to a possibly-full mpsc channel while holding the lock) — dashmap's per-shard locking + explicit `.get()`/drop semantics make this mistake harder to make by accident. Either is acceptable for the connection counts in this phase (single-digit to low-hundreds clients); dashmap is the current idiomatic choice for shared broker maps in async Rust servers [CITED via WebSearch]. |
| tokio-rustls (in-process WSS) | nginx/Caddy TLS-terminating reverse proxy in front of the WS port only | Would introduce an extra container + extra network hop solely for the WS fallback path, while WT still needs its own TLS in-process. Splits the TLS story across two mechanisms for no benefit — CLAUDE.md already rejected Caddy for WebTransport, and the codebase already loads PEM certs in-process for WT. |
| hmac 0.13 + sha1 0.11 (RustCrypto) | `ring::hmac` | `ring` bundles BoringSSL/C code and its own crypto provider; RustCrypto crates are pure-Rust, smaller, and the project doesn't need `ring`'s TLS-oriented API surface for a single HMAC computation. |
| Custom HTTP responder for TURN creds | Add `axum` or `hyper` as a full HTTP framework | A full framework is justified if Phase 3+ adds more REST endpoints (room join, QR code, etc. — SESS-01..06 in Phase 3 will very likely need this). Planner should weigh: a minimal hand-parsed HTTP GET on the existing WS TCP listener works for exactly one endpoint, but Phase 3 will almost certainly want a real router. Recommend introducing a lightweight HTTP layer (`axum` is the standard choice, pairs natively with tokio) now rather than hand-rolling raw HTTP parsing that gets thrown away next phase. |

**Installation (Cargo.toml additions):**
```toml
[dependencies]
dashmap = "6.2"
hmac = "0.13"
sha1 = "0.11"
base64 = "0.22"
tokio-rustls = "0.26"
rustls-pemfile = "2.2"
# If planner adopts axum for the TURN credential endpoint (recommended — see Alternatives):
axum = "0.8"
```

**Version verification (crates.io registry API — 2026-07-06):**
- dashmap = "6.2.1" (max_stable_version; 7.0.0-rc2 exists but is a pre-release, do NOT use) [VERIFIED: crates.io registry]
- hmac = "0.13.0" [VERIFIED: crates.io registry]
- sha1 = "0.11.0" [VERIFIED: crates.io registry]
- base64 = "0.22.1" [VERIFIED: crates.io registry]
- tokio-rustls = "0.26.4" [VERIFIED: crates.io registry]
- rustls-pemfile = "2.2.0" [VERIFIED: crates.io registry]
- rustls = "0.23.41" — already present transitively via `quinn 0.11.11` ← `wtransport 0.7.1` (confirmed via `cargo tree -i rustls` against the actual workspace) [VERIFIED: cargo tree against server/Cargo.toml]

---

## Package Legitimacy Audit

| Package | Registry | Age | Downloads/wk | Source Repo | Verdict | Disposition |
|---------|----------|-----|--------------|-------------|---------|-------------|
| dashmap | crates.io | ~6 yrs (Aug 2019) | 5,167,969 | github.com/xacrimon/dashmap | OK | Approved (pin to 6.2.1, NOT 7.0.0-rc2) |
| hmac | crates.io | ~9 yrs (Oct 2016) | 8,020,334 | github.com/RustCrypto/MACs | OK | Approved |
| sha1 | crates.io | ~11 yrs (Nov 2014) | 7,234,645 | github.com/RustCrypto/hashes | OK | Approved |
| base64 | crates.io | ~10 yrs (Dec 2015) | 20,199,991 | github.com/marshallpierce/rust-base64 | OK | Approved |
| tokio-rustls | crates.io | ~9 yrs (Feb 2017) | 11,266,304 | github.com/rustls/tokio-rustls | OK | Approved |
| rustls-pemfile | crates.io | ~5 yrs (Dec 2020) | 5,910,597 | github.com/rustls/pemfile | OK | Approved |
| rustls | crates.io | ~9 yrs (Aug 2016) | 13,206,621 | github.com/rustls/rustls | OK | Already a transitive dependency — no new install needed unless planner wants a direct dependency for the `ServerConfig` builder call |
| rand | crates.io | ~11 yrs (Feb 2015) | 25,202,448 | github.com/rust-random/rand | OK | Approved (only if server-generated client/user IDs are chosen) |

**Packages removed due to [SLOP] verdict:** none
**Packages flagged as suspicious [SUS]:** none

*coturn Docker image (`coturn/coturn:4.6`) is not a crates.io package — it is a locked decision from CLAUDE.md (official image, maintained by the coturn project). Not subject to the crates.io legitimacy gate.*

---

## Architecture Patterns

### System Architecture Diagram

```
                         ┌───────────────────────────────────────────────────┐
                         │        docker compose up  (3 containers)         │
                         │                                                   │
  Phone Browser          │  ┌─────────────────────────────────────────┐     │
  Desktop Browser        │  │   immersive-rt-server (Rust)            │     │
                         │  │                                          │     │
  WebTransport ──UDP────►│  │  wt_server::run  ──┐                    │     │
  :4433                  │  │  (accept loop)      │                   │     │
                         │  │                     ▼                   │     │
  WebSocket(S) ──TCP────►│  │  ws_server::run  ─►  SignalingBroker     │     │
  :9090                  │  │  (TLS via                (Arc<DashMap    │     │
                         │  │   tokio-rustls)         <ClientId,       │     │
  HTTP GET  ────────────►│  │  turn_creds::handler    Sender<Msg>>>)   │     │
  /turn-credentials      │  │  (HMAC-SHA1 gen)         │        ▲     │     │
                         │  │                          ▼        │     │     │
                         │  │              register/forward/route      │     │
                         │  └─────────────────────────────────────────┘     │
                         │                                                   │
                         │  ┌─────────────────────┐                        │
                         │  │  coturn (official)   │◄── STUN bind / TURN   │
                         │  │  network_mode: host   │    allocate (using    │
                         │  │  :3478 UDP+TCP        │    ephemeral creds    │
                         │  │  :5349 TLS            │    from server above) │
                         │  │  :49152-65535 UDP     │                        │
                         │  └─────────────────────┘                        │
                         │                                                   │
                         │  ┌─────────────────────┐                        │
                         │  │  static-files (nginx) │◄── Desktop client HTML/JS
                         │  │  :80                  │                        │
                         │  └─────────────────────┘                        │
                         └───────────────────────────────────────────────────┘

  Flow for a signaling message (phone → desktop):
  1. Phone connects WT or WS, sends {"type":"register","from":"phone-1"}
  2. wt_server/ws_server inserts ("phone-1", sender) into SignalingBroker
  3. Desktop sends {"type":"offer","from":"desktop-1","to":"phone-1",...}
  4. Handler looks up "phone-1" in broker, forwards payload via its mpsc::Sender
  5. Phone's read-loop (via tokio::select!) receives it from the broker channel,
     writes it out over ITS OWN transport (WT stream or WS frame)
  6. ICE candidates flow the same way until RTCPeerConnection reaches "connected"
  7. Once P2P data channel is open, the broker is no longer in the data path —
     it only relayed the ~10 signaling messages needed to establish the connection
```

### Recommended Project Structure

```
server/
├── Cargo.toml              # + dashmap, hmac, sha1, base64, tokio-rustls, rustls-pemfile
├── src/
│   ├── main.rs              # constructs Arc<SignalingBroker>, passes to both listeners
│   ├── broker.rs            # NEW — SignalingBroker: DashMap<String, mpsc::UnboundedSender<Message>>
│   ├── signaling.rs         # NEW — shared JSON envelope struct + relay logic (transport-agnostic)
│   ├── turn_creds.rs        # NEW — HMAC-SHA1 ephemeral credential generation
│   ├── wt_server.rs         # MODIFIED — signaling relay instead of echo; select! over recv+broker
│   ├── ws_server.rs         # MODIFIED — signaling relay + WSS TLS + TURN creds HTTP endpoint
│   └── echo.rs              # unchanged (still used by tests / can be retired later)
└── tests/
    ├── ws_echo.rs            # existing — may need updating if ws_server::run signature changes
    └── broker_relay.rs        # NEW — integration test: two WS clients, offer/answer routed correctly

docker/
├── Dockerfile.server         # multi-stage: rust:1-slim builder → debian:bookworm-slim runtime
├── coturn/
│   └── turnserver.conf       # use-auth-secret, static-auth-secret, network config
└── docker-compose.yml        # 3 services: server, coturn, static-files
```

### Pattern 1: Signaling broker as shared `DashMap<String, mpsc::UnboundedSender<Message>>`

**What:** A process-wide map from client ID to that client's outbound message channel. Any handler (WT or WS) that wants to send a message to a given client ID looks it up and pushes onto the channel; the owning handler's task drains its own receiver and writes to its actual transport.

**When to use:** This is the central data structure for INFRA-02/INFRA-03 — required for any cross-transport (WT↔WS) or cross-connection relay.

**Example:**
```rust
// broker.rs
// Source: pattern verified against async-Rust broker conventions [CITED: WebSearch — dashmap avoids holding
// a lock across .await, matches the existing "no blocking in tokio tasks" pattern from Phase 1 RESEARCH.md]
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

    /// Register a client, returning the receiver half this handler must drain.
    pub fn register(&self, id: ClientId) -> mpsc::UnboundedReceiver<Vec<u8>> {
        let (tx, rx) = mpsc::unbounded_channel();
        self.clients.insert(id, tx);
        rx
    }

    pub fn unregister(&self, id: &str) {
        self.clients.remove(id);
    }

    /// Route a message to `to`. Returns false (and the caller should log a
    /// warning per D-05) if `to` is not currently connected.
    pub fn route(&self, to: &str, payload: Vec<u8>) -> bool {
        match self.clients.get(to) {
            Some(sender) => sender.send(payload).is_ok(),
            None => false,
        }
    }
}
```

### Pattern 2: `tokio::select!` fan-in/fan-out loop (both WT and WS handlers need this)

**What:** Each connection handler must simultaneously (a) read incoming frames from its own transport and route them via the broker, and (b) drain its own broker-assigned receiver and write those out to its transport. This replaces the simple read-then-echo loop from Phase 1.

**When to use:** Both `handle_ws_connection` and `handle_wt_connection` need this restructuring — this is the core behavioral change of the phase.

**Example:**
```rust
// Source: standard tokio::select! bidirectional relay pattern [ASSUMED — no single official doc page,
// but this is the canonical shape for a bidirectional relay task in tokio; verify against tokio::select! docs]
loop {
    tokio::select! {
        // Inbound from this client's own transport
        msg = read_next_frame(&mut socket) => {
            match msg {
                Some(envelope) => {
                    match envelope.msg_type.as_str() {
                        "register" => { /* already registered at connection start */ }
                        _ => {
                            let bytes = serde_json::to_vec(&envelope)?;
                            if !broker.route(&envelope.to, bytes) {
                                tracing::warn!(to = %envelope.to, "signaling target not connected, dropping");
                            }
                        }
                    }
                }
                None => break, // client disconnected
            }
        }
        // Outbound — another client routed a message to us
        Some(payload) = rx.recv() => {
            write_frame(&mut socket, &payload).await?;
        }
    }
}
broker.unregister(&my_id);
```

### Pattern 3: coturn ephemeral credential generation (HMAC-SHA1, exact algorithm)

**What:** Implements coturn's `use-auth-secret` TURN REST API mechanism. This is the ONLY part of this phase with zero room for approximation — coturn computes the same HMAC server-side and rejects any mismatch.

**Verified algorithm** [CITED: github.com/coturn/coturn/blob/master/README.turnserver]:
- `username = "{unix_timestamp_seconds + ttl}:{userid}"` (timestamp is the credential's **expiry** time, not issue time — coturn checks `now < timestamp` from the username)
- `password = base64_encode(HMAC-SHA1(key = shared_secret, message = username))`

**Example:**
```rust
// turn_creds.rs
// Source: hmac 0.13 docs.rs usage pattern [CITED: docs.rs/hmac/0.13.0] +
// algorithm verified against coturn/coturn README.turnserver [CITED]
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

pub fn generate_turn_credentials(shared_secret: &str, userid: &str, ttl_seconds: u64) -> anyhow::Result<TurnCredentials> {
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    let expiry = now + ttl_seconds;
    let username = format!("{expiry}:{userid}");

    let mut mac = HmacSha1::new_from_slice(shared_secret.as_bytes())
        .map_err(|e| anyhow::anyhow!("HMAC key error: {e}"))?;
    mac.update(username.as_bytes());
    let password = STANDARD.encode(mac.finalize().into_bytes());

    Ok(TurnCredentials { username, password, ttl_seconds })
}
```

**Corresponding coturn config (`turnserver.conf`)** [CITED: github.com/coturn/coturn README.turnserver + Turnix.io guide]:
```conf
listening-port=3478
tls-listening-port=5349
listening-ip=0.0.0.0
realm=immersivert.local
lt-cred-mech
use-auth-secret
static-auth-secret=<SAME SECRET the Rust server uses — inject via env var, never hardcode>
fingerprint
no-multicast-peers
# relay-ip / external-ip filled in per environment — see Pattern 4
```

### Pattern 4: Docker Compose — coturn `network_mode: host` + `external-ip`

**What:** The three-service compose stack. `network_mode: host` on coturn is not optional — every official coturn deployment guide and CLAUDE.md/STATE.md flag it as mandatory (Docker's default bridge networking cannot reflect the real external UDP-facing address needed for STUN, and the large 49152-65535 relay port range performs badly through bridge NAT translation regardless of STUN correctness).

**Example:**
```yaml
# docker-compose.yml
services:
  server:
    build:
      context: .
      dockerfile: docker/Dockerfile.server
    ports:
      - "4433:4433/udp"   # WebTransport
      - "9090:9090/tcp"   # WebSocket(S) signaling + TURN credential endpoint
    environment:
      - CERT_PATH=/certs/fullchain.pem
      - KEY_PATH=/certs/privkey.pem
      - WT_PORT=4433
      - WS_PORT=9090
      - TURN_SHARED_SECRET=${TURN_SHARED_SECRET}
    volumes:
      - ./certs:/certs:ro
    depends_on:
      - coturn

  coturn:
    image: coturn/coturn:4.6
    network_mode: host   # REQUIRED — bridge mode breaks STUN reflection (STATE.md, prior phase decision)
    volumes:
      - ./docker/coturn/turnserver.conf:/etc/coturn/turnserver.conf:ro
    environment:
      - TURN_SHARED_SECRET=${TURN_SHARED_SECRET}
    command: ["-c", "/etc/coturn/turnserver.conf", "--external-ip=${COTURN_EXTERNAL_IP}"]

  static-files:
    image: nginx:alpine
    ports:
      - "8081:80"
    volumes:
      - ./client/dist:/usr/share/nginx/html:ro
```

**Important:** `network_mode: host` and the `ports:` mapping are mutually exclusive for the same service — a host-mode service ignores `ports:` entirely and binds directly to host interfaces using whatever ports are in its own config/command. Do not add a `ports:` block under `coturn:`.

### Anti-Patterns to Avoid

- **Holding the broker's DashMap `Ref` guard across an `.await`:** `DashMap::get()` returns a guard that holds a shard lock. Extract what you need (clone the sender, or call `.send()` while still holding it since `mpsc::Sender::send` on an unbounded channel doesn't await-block on backpressure) and drop the guard before any `.await` that isn't the channel send itself.
- **Putting `network_mode: host` and `ports:` on the same compose service:** Silently ignored by Docker Compose; the port mapping simply does nothing, leading to "coturn isn't reachable" confusion.
- **Using the *issue* timestamp instead of the *expiry* timestamp in the TURN username:** coturn's algorithm treats the timestamp in the username as an absolute expiry, not an issue time. `username = "{now}:{id}"` with no added TTL means the credential is already expired by the time coturn's own clock skew is accounted for, in some configurations. Always add the desired TTL: `username = "{now + ttl}:{id}"`.
- **Building a reverse-proxy TLS layer in front of only the WS port:** Fragments the TLS story (WT handles its own TLS via wtransport's `Identity`, WS would use a completely different mechanism). Terminate WSS in-process with `tokio-rustls` using the same cert files.
- **Enabling both `ring` and `aws_lc_rs` rustls crypto-provider features across the workspace:** See Pitfall 3 — will panic at runtime with "Could not automatically determine the process-level CryptoProvider."

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Concurrent client registry | Custom sharded-lock hashmap | dashmap 6.2.1 | Sharded locking with correct lock-ordering to avoid deadlocks is a solved, well-tested problem; dashmap has 5M+ weekly downloads and is the de-facto standard for this exact use case in async Rust servers |
| HMAC computation | Hand-rolled HMAC using raw SHA-1 | hmac 0.13 + sha1 0.11 (RustCrypto) | HMAC has a specific inner/outer-padding construction (RFC 2104); getting padding wrong silently produces a value that "looks like" a MAC but isn't interoperable with coturn's implementation — coturn will reject 100% of requests with no useful error beyond 401 |
| TLS handshake for WSS | Raw socket + manual TLS record parsing | tokio-rustls 0.26 (already have rustls 0.23 transitively via wtransport) | TLS 1.2/1.3 handshake state machines are exactly the kind of protocol complexity Phase 1's RESEARCH.md already flagged as "not hand-rolled even by experienced teams" |
| WebRTC ICE/STUN/TURN protocol itself | Custom NAT-traversal negotiation | Browser's native `RTCPeerConnection` (client-side) + coturn (server-side) | This phase's server code never touches the STUN/TURN wire protocol — it only issues credentials. The browser and coturn do all ICE negotiation. Do not build any STUN/TURN packet handling in the Rust server. |
| STUN/TURN server itself | Custom Rust STUN/TURN implementation | coturn (official Docker image, already locked in CLAUDE.md) | RFC 5766/8656 compliance, DoS mitigations, and channel-binding optimizations represent years of hardening; coturn is battle-tested at Internet scale |

**Key insight:** Every "don't hand-roll" item in this phase is a case where getting the algorithm 99% right produces silent, hard-to-debug failures (wrong HMAC padding, wrong TLS record framing, wrong STUN packet format) rather than a compile error. Use the verified libraries and verified algorithm exactly as documented.

---

## Common Pitfalls

### Pitfall 1: TURN username uses expiry timestamp, not issue timestamp

**What goes wrong:** Developer writes `username = format!("{}:{}", now_unix_seconds(), userid)` without adding a TTL. coturn either rejects immediately (if its clock is even slightly ahead) or the credential is unusable within seconds.
**Why it happens:** The coturn README's phrasing ("temporary-username... timestamp") reads ambiguously between "when issued" and "when expires" on a skim.
**How to avoid:** Always compute `expiry = now + ttl_seconds` and use `expiry` in the username. Recommended TTL: 60-300 seconds, since INFRA-04 explicitly requires generation "at connection-start, not page load" — short TTLs are the whole point.
**Warning signs:** coturn logs `"stun_attr_get_change_request_str: check REALM/ttl mismatch"` or a 401 despite the shared secret matching; `turnutils_uclient` reports allocation failure with STALE_NONCE or forbidden.

### Pitfall 2: coturn `network_mode: host` + `ports:` both present in compose

**What goes wrong:** Developer adds `ports: ["3478:3478/udp", ...]` to the coturn service "for clarity" alongside `network_mode: host`. Docker Compose silently ignores the `ports:` block for host-mode services — no error, no warning.
**Why it happens:** Every other service in the compose file uses `ports:`, so it feels inconsistent not to for coturn; the silent-ignore behavior is non-obvious.
**How to avoid:** Do not add `ports:` under a `network_mode: host` service. Document the actual bound ports in a comment instead. Bind addresses/ports are controlled entirely by `turnserver.conf` / command-line args in host mode.
**Warning signs:** `docker compose config` shows the ports block accepted with no error, but `turnutils_uclient` from outside the host still can't reach the server on a port that "should" be mapped — because it never needed mapping, it's already on the host's real interface.

### Pitfall 3: rustls crypto-provider conflict when adding tokio-rustls alongside wtransport/quinn

**What goes wrong:** Adding `tokio-rustls` (or `rustls` directly) with the `ring` feature enabled, when `quinn` (via `wtransport`) already pulls `rustls` with its default `aws_lc_rs` feature, causes a runtime panic the first time `rustls::ServerConfig::builder()` (or equivalent) is called: `"Could not automatically determine the process-level CryptoProvider from Rustls crate features"`.
**Why it happens:** rustls 0.23 requires exactly one crypto backend to be unambiguous across the whole dependency graph. `cargo tree -i rustls` against this exact workspace (verified 2026-07-06) shows `rustls v0.23.41` is already pulled in via `quinn v0.11.11 ← wtransport v0.7.1`, using rustls's **default** feature set (which includes `aws_lc_rs`). Adding a second consumer of `rustls`/`tokio-rustls` with the `ring` feature turned on creates two candidate providers with no explicit selection.
**How to avoid:** Do NOT enable the `ring` feature on any new `rustls`/`tokio-rustls` dependency. Rely on the `aws_lc_rs` provider already active from the wtransport→quinn chain, OR explicitly call `rustls::crypto::aws_lc_rs::default_provider().install_default().ok();` once at the top of `main()` before either listener starts, to make the selection unambiguous and explicit regardless of future dependency changes.
**Warning signs:** Panic message containing "process-level CryptoProvider"; this will surface at the exact moment the WSS listener's `ServerConfig::builder()` runs, which may be well after `cargo build` succeeds (a runtime panic, not a compile error).

### Pitfall 4: `DashMap` guard held across an `.await` point causes shard-lock contention/deadlock risk

**What goes wrong:** Code does `if let Some(sender) = broker.clients.get(id) { sender.send(msg).await... }` where the `.await` is on something other than the immediate unbounded-channel send (e.g., awaiting a downstream network write while still holding the `Ref` guard). Under load, this serializes access to that DashMap shard and can produce subtle contention bugs.
**Why it happens:** `DashMap::get()` returns a guard, not an owned value; it's easy to forget the guard's lifetime extends until the end of the block/expression.
**How to avoid:** Clone the `mpsc::UnboundedSender` (cheap — it's an `Arc`-backed handle) out of the guard immediately, let the guard drop, then `.send()` on the owned clone. `mpsc::UnboundedSender::send` is synchronous (not `async`) anyway, so this specific case is actually safe by construction if using `unbounded_channel` — but be deliberate if a bounded channel is chosen instead, since `send().await` on a bounded channel absolutely must not happen while a DashMap guard is held.
**Warning signs:** Occasional latency spikes or apparent hangs under concurrent connect/disconnect load; not usually a hard deadlock with this specific map (dashmap doesn't have the classic same-thread-reentrant-lock deadlock), but is a correctness smell worth avoiding regardless.

### Pitfall 5: WebTransport server-push requires understanding wtransport's `Connection::open_bi()`, not just `accept_bi()`

**What goes wrong:** Phase 1's `wt_server.rs` only ever calls `conn.accept_bi()` (waiting for the client to open a stream). For signaling, the server also needs to *push* a message to a client that isn't currently mid-request — e.g., relaying an offer from a desktop to a phone that's just sitting idle waiting for signaling. If the code only ever responds within an `accept_bi()`-opened stream, there's no way to push unsolicited messages.
**Why it happens:** Phase 1's echo pattern was purely request/response (client always opens the stream). Signaling is fundamentally push-capable in both directions.
**How to avoid:** Use `conn.open_bi()` (or a single long-lived bidirectional stream opened once at connection start, kept open for the connection's lifetime, with both sides writing whenever they have something to send) rather than a new stream per exchange. A single long-lived stream per WT connection, framed with a length-prefix or newline-delimited JSON, mirrors how the WS connection naturally already works (one persistent connection, multiple messages).
**Warning signs:** Messages routed via the broker to a WT-connected client never arrive because the handler is blocked in `conn.accept_bi().await` waiting for the *client* to initiate, with no code path listening on the broker's `mpsc::Receiver` concurrently.

---

## Code Examples

### Cargo.toml additions (verified versions, 2026-07-06)
```toml
[dependencies]
# existing deps unchanged (wtransport, tokio, tokio-tungstenite, futures-util, anyhow, tracing, tracing-subscriber, serde, serde_json)
dashmap = "6.2"
hmac = "0.13"
sha1 = "0.11"
base64 = "0.22"
tokio-rustls = "0.26"
rustls-pemfile = "2.2"
```

### tokio-rustls server-side TLS acceptor (for WSS on the WS fallback listener)
```rust
// Source: tokio-rustls examples/server.rs pattern [CITED: github.com/rustls/tokio-rustls/blob/main/examples/server.rs]
// + rustls-pemfile 2.x cert/key parsing pattern [CITED]
use rustls_pemfile::{certs, private_key};
use std::io::BufReader;
use tokio_rustls::TlsAcceptor;
use tokio_rustls::rustls::ServerConfig;

fn load_tls_acceptor(cert_path: &str, key_path: &str) -> anyhow::Result<TlsAcceptor> {
    let cert_file = &mut BufReader::new(std::fs::File::open(cert_path)?);
    let key_file = &mut BufReader::new(std::fs::File::open(key_path)?);

    let cert_chain = certs(cert_file).collect::<Result<Vec<_>, _>>()?;
    let key = private_key(key_file)?.ok_or_else(|| anyhow::anyhow!("no private key found in {key_path}"))?;

    let config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(cert_chain, key)?;

    Ok(TlsAcceptor::from(std::sync::Arc::new(config)))
}

// In the accept loop:
// let tls_stream = acceptor.accept(tcp_stream).await?;
// let ws = tokio_tungstenite::accept_async(tls_stream).await?;
```

### turnutils_uclient validation command (Success Criterion 2)
```bash
# Source: coturn manpages + turnix.io guide [CITED]
# Run from a machine that can reach the coturn host (or `docker exec` into a
# sidecar/the coturn container itself if turnutils binaries are bundled — verify, see Open Questions)
turnutils_uclient -u test -w test -p 3478 <server-host>
# Exit code 0 + "allocate sent" / "TURN allocate ok" style log lines indicate success.
# For STUN-only binding check: turnutils_stunclient -p 3478 <server-host>
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Long-term static TURN credentials (one username/password baked into client) | Ephemeral REST-API credentials via `use-auth-secret` + HMAC-SHA1 | Standard practice for years, formalized as "TURN REST API" | Client never holds a long-lived secret; credential leak window is bounded to the TTL |
| `native-tls`/OpenSSL for Rust TLS servers | `rustls` (pure Rust, no OpenSSL dependency) | rustls has been the modern default for several years | No system OpenSSL version drift issues in Docker images; smaller attack surface |
| rustls 0.22 and earlier: single implicit crypto provider | rustls 0.23+: explicit `CryptoProvider` selection required | rustls 0.23 (2024) | New failure mode (Pitfall 3) that didn't exist in older rustls-based tutorials found via web search — training-data-era examples may not show this |
| dashmap 5.x / early 6.x tutorials | dashmap 6.2.1 (current stable); 7.0.0-rc2 exists but is pre-release | ongoing | Do not follow a tutorial pinning `dashmap = "5"` without checking — API is largely stable across 5→6 but always verify against the registry |

**Deprecated/outdated:**
- Baking a static TURN username/password into client-side JS: superseded by ephemeral REST-API credentials industry-wide; this phase's INFRA-04 explicitly requires the ephemeral approach.
- `base64::encode()` free function: removed in base64 0.21+; must use the `Engine` trait (`STANDARD.encode(...)`) as shown in Code Examples.

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | The official `coturn/coturn` Docker image bundles `turnutils_uclient`/`turnutils_stunclient` binaries (same source tree, typically built together) | Environment Availability, Code Examples | If the binaries are NOT bundled, Success Criterion 2 validation needs a separate coturn-utils install (e.g., `apt install coturn` on a test host, or a `coturn/coturn` image `docker exec` check) — low effort to resolve but must be verified in Wave 0 before relying on `docker exec coturn turnutils_uclient ...` |
| A2 | `tokio::select!` fan-in/fan-out is the correct restructuring for both `wt_server.rs` and `ws_server.rs` connection handlers | Architecture Patterns Pattern 2 | If wtransport's `Connection` type doesn't cleanly support concurrent `accept_bi()`-style reads alongside a broker-receiver drain in one `select!`, the WT handler may need a different concurrency shape (e.g., two `tokio::spawn`ed sub-tasks with an internal channel) — moderate refactor risk, not a blocker |
| A3 | Adding `axum` now (rather than hand-rolling one HTTP GET endpoint) is worth the new dependency, given Phase 3 will need real room/session HTTP endpoints | Standard Stack, Alternatives Considered | If planner instead hand-rolls the TURN credential endpoint on the raw WS TCP listener to avoid scope creep, Phase 3 will likely re-introduce this exact question — low risk either way, purely a sequencing decision |
| A4 | Client IDs for the broker (the `from`/`to` fields in D-04's JSON envelope) are either client-generated UUIDs or arbitrary test strings for this phase, since real room/slot assignment is Phase 3 (SESS-01..06) | Phase Requirements, Open Questions | If the planner assumes Phase 2 must implement real pairing/room logic, scope balloons far beyond INFRA-02..07; Phase 3's existence in the roadmap confirms this is intentionally deferred |
| A5 | `hmac 0.13.0` + `sha1 0.11.0` (both very recently bumped RustCrypto majors) are API-compatible with each other via the shared `digest ^0.11` trait bound, and `cargo build` will not hit a diamond-dependency version conflict | Standard Stack, Code Examples | If `digest` version bounds don't line up (e.g., another transitive dep pins `digest 0.10`), `cargo build` will fail with a trait-mismatch error; low risk since both were pulled from the crates.io registry on the same research date and `docs.rs/hmac/0.13.0` explicitly documents the `digest ^0.11.2` requirement matching `sha1 0.11.0`'s use of the same major |

**Overall confidence:** Everything in this table is a reasonable engineering assumption grounded in verified library facts, not blind guesses about compliance/security requirements — the HMAC algorithm itself, coturn's `network_mode: host` requirement, and all package versions are [CITED]/[VERIFIED], not [ASSUMED].

---

## Open Questions

1. **Where does the TURN credential HTTP endpoint live — new listener, or piggybacked on the WS port?**
   - What we know: D-06 explicitly defers this to research/planner. The WS listener already exists as a raw TCP + tokio-tungstenite accept loop; adding a plain HTTP GET responder alongside the WebSocket upgrade path on the same port is possible but requires manually distinguishing "this is an HTTP GET for /turn-credentials" vs "this is a WebSocket upgrade request" before calling `accept_async`.
   - What's unclear: Whether hand-parsing this distinction is simpler than adding `axum` (or `hyper` directly) as a proper router on either the same port (via protocol sniffing) or a dedicated new port.
   - Recommendation: Add `axum` bound to a new port (e.g., `HTTP_PORT` env var, default 8081) dedicated to REST-style endpoints. This avoids protocol-sniffing complexity on the WS port and gives Phase 3 (room join, QR code generation) a natural home for its endpoints too.

2. **Does the `coturn/coturn` official Docker image include `turnutils_uclient`?**
   - What we know: `turnutils_uclient` and `turnserver` are both part of the same coturn source distribution and Debian package.
   - What's unclear: Whether the official Docker Hub image's build strips test utilities to reduce image size (common for production images).
   - Recommendation: Verify in Wave 0 with `docker run --rm coturn/coturn:4.6 which turnutils_uclient`. If absent, either add a tiny sidecar container built `FROM coturn/coturn:4.6` with the same binary reused, or install `coturn` package (which includes turnutils) on the CI/test host directly for validation purposes only (not part of the deployed stack).

3. **Client ID assignment scheme for this phase's broker (`from`/`to` in the JSON envelope)**
   - What we know: Phase 3 owns real room/slot/pairing logic (SESS-01..06). This phase only needs the relay mechanism to work end-to-end for Success Criterion 1.
   - What's unclear: Whether Phase 2's manual/dev-testing harness should use hardcoded test IDs, a query-param-supplied ID (`?id=phone-1`), or a server-generated UUID returned on `register`.
   - Recommendation: Accept a client-supplied ID via the `register` message payload for this phase (simplest, keeps the broker transport/session agnostic); Phase 3 will layer real assignment logic on top without needing to change the broker's core `DashMap<String, Sender>` shape.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Docker | `docker compose up` (INFRA-07) | Yes | 29.6.0 | — |
| Docker Compose | Multi-container orchestration | Yes | v5.2.0 (Compose V2 plugin) | — |
| rustc / cargo | Building the Rust server image and running `cargo test` | Yes | rustc 1.93.1, cargo 1.93.1 | — |
| turnutils_uclient (host) | Manual validation of Success Criterion 2 | No (not installed on this dev machine) | — | Run via `docker run --rm --network host coturn/coturn:4.6 turnutils_uclient ...` if bundled (see Open Question 2), or `apt install coturn` on a Linux test host for the utilities only |
| coturn/coturn:4.6 Docker image | INFRA-06 | Not pulled yet (requires network at build/verify time) | — | Pull as part of Wave 0 / first `docker compose up` |

**Missing dependencies with no fallback:**
- None — `turnutils_uclient` has a documented fallback path (Docker-based invocation or coturn package install on the test host).

**Missing dependencies with fallback:**
- `turnutils_uclient` on host — use containerized invocation instead.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Rust built-in (`cargo test`), same as Phase 1 |
| Config file | none — cargo test runs automatically |
| Quick run command | `cargo test -p immersive-rt-server` |
| Full suite command | `cargo test --workspace` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| INFRA-02 | Broker routes a JSON envelope from client A to client B over two WS connections | integration | `cargo test test_broker_relay_ws` | ❌ Wave 0 — new `server/tests/broker_relay.rs` |
| INFRA-02 | HMAC-SHA1 credential generation produces coturn-compatible output for a known fixture (secret, userid, ttl) → expected password | unit | `cargo test test_turn_credential_known_vector` | ❌ Wave 0 — new `server/src/turn_creds.rs` `#[cfg(test)]` module |
| INFRA-03 | Broker routes correctly when both sender and receiver are on the SAME transport (WS↔WS) and CROSS transport (WT↔WS) | integration | `cargo test test_broker_relay_cross_transport` | ❌ Wave 0 |
| INFRA-04 | TURN credential HTTP endpoint returns username+password that changes on every request (not cached) | integration | `cargo test test_turn_creds_endpoint_ephemeral` | ❌ Wave 0 |
| INFRA-06 | `docker compose up` brings up coturn; `turnutils_uclient` STUN+TURN check passes | manual (documented in Open Question 2 re: tool availability) | Manual — `turnutils_uclient -u test -w test <host>:3478` | Manual only |
| INFRA-07 | `docker compose up` cold start brings up 3 containers with no manual steps | manual/smoke | `docker compose up --build` then `docker compose ps` shows 3 healthy services | Manual only (or a CI smoke-test script if planner adds one) |
| Success Criterion 1 (full ICE handshake phone↔desktop) | E2E, requires real browsers | manual | Manual — two browser tabs/devices, DevTools `RTCPeerConnection` state | Manual only |
| Success Criterion 5 (TURN relay-only path via simulated symmetric NAT) | manual, requires coturn `no-udp`/relay-only test config | manual | Manual — configure a second coturn test profile or use `relay-only` in test client flags | Manual only |

**Note on manual tests:** Full WebRTC ICE handshake (Success Criterion 1) and Docker Compose cold-start (Success Criteria 3, 5) require real browsers and real network conditions respectively — outside the scope of `cargo test`. The broker relay logic, HMAC credential algorithm, and JSON envelope parsing are all unit/integration-testable and should be, since they're the parts most prone to silent logic bugs (see Common Pitfalls).

### Sampling Rate

- **Per task commit:** `cargo test -p immersive-rt-server`
- **Per wave merge:** `cargo test --workspace`
- **Phase gate:** Full suite green + manual `turnutils_uclient` validation + manual browser ICE handshake before `/gsd-verify-work`

### Wave 0 Gaps

- [ ] `server/src/broker.rs` — SignalingBroker implementation, covers INFRA-02/03
- [ ] `server/src/turn_creds.rs` — HMAC-SHA1 credential generation + known-answer unit test, covers INFRA-04
- [ ] `server/tests/broker_relay.rs` — integration test for cross-client, cross-transport routing
- [ ] `docker/Dockerfile.server`, `docker/coturn/turnserver.conf`, `docker-compose.yml` — none exist yet, all net-new for INFRA-06/07
- [ ] Verify `turnutils_uclient` availability inside `coturn/coturn:4.6` (Open Question 2) before writing the manual validation step into VERIFICATION.md

---

## Security Domain

### Applicable ASVS Categories (Level 1)

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | Yes (narrow) | TURN credentials are short-lived bearer-style tokens, not user authentication — still apply V2-style "credentials expire" discipline: TTL enforced via the expiry timestamp embedded in the username (Pattern 3) |
| V3 Session Management | No | No user sessions yet — Phase 3 owns SESS-01..06 |
| V4 Access Control | No | No authorization tiers in this phase; the broker forwards to any registered client ID with no ownership check yet (acceptable for this phase's scope — Phase 3 adds real pairing/room boundaries) |
| V5 Input Validation | Yes | JSON envelope parsing must reject malformed `type`/`from`/`to` fields without panicking (same discipline already established in `echo.rs`'s malformed-payload handling from Phase 1) |
| V6 Cryptography | Yes | HMAC-SHA1 is coturn's REQUIRED algorithm for this specific REST-API mechanism — this is not "rolling your own crypto," it's implementing a documented third-party protocol exactly as specified. Note: SHA-1's *collision* weakness is irrelevant to HMAC-SHA1's security as a MAC (HMAC security depends on PRF properties, not collision resistance) — do not substitute SHA-256 unilaterally, coturn will reject it unless coturn is also reconfigured, which is out of scope. |
| V9 Communications | Yes | WSS (TLS) required for the WS fallback in any non-LAN-dev deployment; reuse the same cert discipline as Phase 1 (mkcert for dev, real TLS for prod) |

### Known Threat Patterns for This Phase's Stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Shared TURN secret leaked (env var exposure, log leakage) | Information Disclosure | Never log `TURN_SHARED_SECRET`; inject via env var / Docker secret, never hardcode in `turnserver.conf` committed to git |
| Signaling relay used to spam/DoS an arbitrary connected client ID | Denial of Service | D-05's "drop + log warning for unknown targets" already mitigates unknown-ID spam; consider a per-client rate limit on `route()` calls in a later hardening pass (not required for this phase's success criteria) |
| Overly long TURN credential TTL increases replay window if password is intercepted | Tampering / Elevation of Privilege | Keep TTL short (60-300s per Pitfall 1's recommendation); INFRA-04's "generate at connection-start, not page load" requirement already enforces freshness |
| Malformed JSON signaling envelope crashes a connection handler | Denial of Service | `serde_json::from_slice` with a `match`/log-and-continue pattern, exactly as `wt_server.rs`'s existing malformed-echo-message handling already does (T-01-06 precedent) |
| coturn exposed to the public internet without `fingerprint` / with weak `static-auth-secret` | Spoofing | Use a cryptographically random secret (32+ bytes) for `static-auth-secret`; enable `fingerprint` in `turnserver.conf` as shown in Pattern 3 |

---

## Sources

### Primary (MEDIUM confidence — cross-checked WebFetch of official docs, verified via `--verified` classify-confidence tier)

- [github.com/coturn/coturn/blob/master/README.turnserver](https://github.com/coturn/coturn/blob/master/README.turnserver) — `use-auth-secret`, `static-auth-secret`, exact HMAC-SHA1 credential formula, `external-ip`/`relay-ip`/`min-port`/`max-port` options
- [hub.docker.com/r/coturn/coturn](https://hub.docker.com/r/coturn/coturn) — official image usage, `network_mode: host` recommendation, `DETECT_EXTERNAL_IP` env var, config mounting options
- [docs.rs/hmac/0.13.0](https://docs.rs/hmac/0.13.0/hmac/) — exact `Hmac<Sha1>::new_from_slice` / `update` / `finalize` usage pattern, `digest ^0.11.2` requirement
- crates.io registry API (`https://crates.io/api/v1/crates/<name>`, queried directly 2026-07-06) — verified exact stable versions for dashmap, hmac, sha1, base64, tokio-rustls, rustls-pemfile, rustls
- `cargo tree -i rustls` run directly against `server/Cargo.toml` — confirmed rustls 0.23.41 is already a transitive dependency via `quinn 0.11.11 ← wtransport 0.7.1`, informing Pitfall 3

### Secondary (MEDIUM confidence — WebSearch cross-checked against multiple independent guides)

- [turnix.io/guides/setup-coturn-server](https://turnix.io/guides/setup-coturn-server) — docker-compose.yml example, `turnutils_uclient`/`turnutils_stunclient` command syntax
- [github.com/rustls/tokio-rustls/blob/main/examples/server.rs](https://github.com/rustls/tokio-rustls/blob/main/examples/server.rs) — `TlsAcceptor` server-side pattern
- [github.com/johanhelsing/matchbox](https://github.com/johanhelsing/matchbox) — precedent Rust WebRTC signaling server architecture (offer/answer/ICE relay by client ID)
- WebSearch: "coturn use-auth-secret ephemeral TURN credentials HMAC-SHA1" — cross-checked against README.turnserver directly, confirms formula
- WebSearch: "rustls 0.23 tokio-rustls CryptoProvider ring aws-lc-rs" — confirms the crypto-provider ambiguity panic and its fix

### Tertiary (LOW confidence — single WebSearch pass, not independently cross-checked)

- WebSearch: "turnutils_uclient usage examples" — general tool description, specific flag behavior not verified against a real run in this session (no coturn instance running yet)
- WebSearch: "docker compose static file server nginx alpine" — generic pattern, low domain-specificity risk

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all crate versions confirmed directly against the crates.io registry API (not training data), and the rustls transitive-dependency conflict was confirmed against this exact workspace's `cargo tree` output
- Architecture (broker + select! pattern): MEDIUM — the DashMap broker shape is well-supported by cross-checked sources, but the exact `tokio::select!` restructuring of `wt_server.rs`/`ws_server.rs` handlers is a reasoned design (informed by wtransport's `open_bi`/`accept_bi` API and standard tokio patterns), not copied from a single authoritative example
- TURN credential algorithm: HIGH — directly verified against the `coturn/coturn` GitHub README, the single most authoritative source for this exact mechanism
- Docker Compose deployment: MEDIUM — `network_mode: host` requirement is confirmed across multiple independent sources and consistent with prior-phase STATE.md notes; exact `turnserver.conf` field set is a reasonable synthesis, not copied verbatim from one canonical example
- Pitfalls: MEDIUM-HIGH — Pitfall 3 (rustls crypto provider) is directly verified against this project's actual dependency tree, the strongest-grounded pitfall in this document; others are cross-checked against 2+ independent sources

**Research date:** 2026-07-06
**Valid until:** 2026-08-06 (crate versions stable at 30-day horizon; coturn's REST API mechanism has been stable for years and is unlikely to change; rustls crypto-provider requirements have been stable since rustls 0.23's 2024 release)
