# Phase 2: Signaling, TURN, and Deployment - Context

**Gathered:** 2026-07-06
**Status:** Ready for planning

<domain>
## Phase Boundary

Server brokers a full WebRTC offer/answer/ICE exchange between phone and desktop; coturn provides STUN/TURN reachability; full stack (Rust server + coturn + static file server) ships in a single `docker compose up`.

Requirements: INFRA-02, INFRA-03, INFRA-04, INFRA-06, INFRA-07

</domain>

<decisions>
## Implementation Decisions

### Signaling Transport
- **D-01:** Both WebSocket and WebTransport carry signaling — WebTransport (port 4433) is primary, WebSocket (port 9090) is fallback. Clients use whichever they connected on.
- **D-02:** Default WebSocket port changed from 8080 to **9090** (avoid common port conflicts). Env var `WS_PORT` controls this.
- **D-03:** Cross-transport routing uses a **shared in-process broker** — a `tokio` `DashMap` or `RwLock<HashMap>` mapping client IDs to `mpsc::Sender`. Both WS and WT handlers post into it. Transport-agnostic relay.

### Signaling Message Format
- **D-04:** JSON envelope: `{ "type": "offer"|"answer"|"ice-candidate"|"register", "from": "<client-id>", "to": "<client-id>", "payload": {...} }`. Standard WebRTC signaling convention. ICE signaling is low-frequency (<10 messages/session) so JSON overhead is irrelevant.

### Broker State Model
- **D-05:** **Minimal stateful broker** — server maintains a connected-client map. Forwards only to known connected IDs. Drops messages to unknown targets (does not silently discard without logging — logs a warning). Consistent with the in-process broker structure.

### TURN Credentials
- **D-06:** (Not discussed — defaults from REQUIREMENTS.md apply): INFRA-04 requires ephemeral credentials generated at connection-start using coturn `use-auth-secret` with HMAC-SHA1 time-limited tokens. Researcher and planner determine endpoint placement.

### Docker Compose
- **D-07:** (Not discussed — defaults from REQUIREMENTS.md apply): coturn runs with `network_mode: host` and `external-ip` configured. Planner determines dev/prod compose strategy.

### Claude's Discretion
- Endpoint structure for TURN credential delivery (HTTP sub-path on existing WS port vs new listener) — not specified, planner decides.
- coturn Docker Compose platform compatibility handling (Linux-only vs dev/prod split) — not specified, planner decides.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Requirements
- `.planning/REQUIREMENTS.md` — INFRA-02, INFRA-03, INFRA-04, INFRA-06, INFRA-07 are the phase requirements. Read for exact acceptance criteria.

### Prior Phase Artifacts
- `.planning/phases/01-server-and-transport-foundation/01-RESEARCH.md` — WebTransport + WebSocket architecture from Phase 1; crate versions and patterns reused here.
- `server/src/ws_server.rs` — existing WebSocket fallback listener (currently echo-only, becomes signaling relay in this phase)
- `server/src/wt_server.rs` — existing WebTransport listener (currently echo-only, becomes signaling relay in this phase)
- `server/src/main.rs` — server entry point; env var config pattern (`WS_PORT`, `WT_PORT`, `CERT_PATH`, `KEY_PATH`)
- `server/Cargo.toml` — current dependency versions

### State Notes (from STATE.md)
- `coturn must run with network_mode: host — bridge mode silently breaks STUN` (recorded in STATE.md accumulated decisions)
- `Phase 1: Plain ws:// only for WebSocket fallback — WSS with TLS deferred to Phase 2 Docker deployment` — Phase 2 must address WSS for the WS fallback inside Docker

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `ws_server.rs::run_with_listener` — accepts a `TcpListener`; reuse this split for testability. The semaphore connection limit pattern (`MAX_WS_CONNECTIONS`) carries forward.
- `wt_server.rs::run` — WebTransport accept loop pattern. Connection tasks are `tokio::spawn`ed; error in one task doesn't kill the accept loop. Same pattern for signaling relay.
- `server/src/echo.rs::now_ms()` — timestamp utility already available.
- `serde_json` already in `Cargo.toml` — no new dependency for JSON envelope parsing.

### Established Patterns
- Env var config with `std::env::var` + fallback defaults — all new ports/config follow this pattern.
- `tokio::try_join!` in `main.rs` — add broker initialization before the join; pass `Arc<Broker>` into both listeners.
- `tracing::warn!` / `tracing::info!` for all connection events — established logging style.

### Integration Points
- Both `wt_server::run` and `ws_server::run` signatures need an `Arc<SignalingBroker>` parameter added.
- `main.rs` constructs the broker, wraps it in `Arc`, passes to both listeners.
- WS port env var default changes from `"8080"` to `"9090"` in `main.rs`.

</code_context>

<specifics>
## Specific Ideas

- WS default port: **9090** (not 8080) to avoid conflicts with common local services.
- Both WT and WS are live signaling channels — not WT-only. A phone that cannot use QUIC falls back to WS seamlessly.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 2-Signaling, TURN, and Deployment*
*Context gathered: 2026-07-06*
