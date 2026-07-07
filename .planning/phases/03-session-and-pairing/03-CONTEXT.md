# Phase 3: Session and Pairing - Context

**Gathered:** 2026-07-07
**Status:** Ready for planning

<domain>
## Phase Boundary

Server gains room and slot management: desktops join named rooms, receive a slot assignment and a QR code / short code; phones scan to pair exclusively to their desktop slot. Server holds slots on disconnect (60s) and emits room lifecycle events to all room desktops.

Requirements: SESS-01, SESS-02, SESS-03, SESS-04, SESS-05, SESS-06

</domain>

<decisions>
## Implementation Decisions

### Lobby UI and Room Creation
- **D-01:** Lobby has two explicit buttons: **Create Room** and **Join Room**. No combined single form.
- **D-02:** **Create Room** flow: user clicks Create → selects game/mode → server creates room with `game_type` field → client redirects to `/room/ABCD`. Phase 3 ships one placeholder game type; actual game types populated in later phases.
- **D-03:** **Join Room** flow: user enters room code + username → server validates (room exists? slots available?) → client redirects to `/room/ABCD` if approved.
- **D-04:** Server **auto-creates** a room on first Create request — no explicit "create room" API call precedes it. Server generates the room code.
- **D-05:** Room code format: short alphanumeric (researcher/planner determine exact length, ~4–6 chars). Case-insensitive to avoid ambiguous characters.

### Room URL and Navigation
- **D-06:** Room identity is expressed in the **URL path**: `/room/ABCD`. Navigating to that URL means "join room ABCD". nginx serves the same `index.html` for all paths (`try_files $uri /index.html`).
- **D-07:** Client navigates to `/room/ABCD` via `history.pushState` (SPA, no full page reload) **only after server approval**. The redirect never happens before the server confirms the slot is available.
- **D-08:** Server **enforces maximum 8 desktops per room** — 9th join attempt is rejected with an error response before slot assignment.

### Join Handshake Protocol
- **D-09:** Join handshake uses the **existing WS/WT connection** (no separate HTTP round trip). Desktop opens WS or WT connection to server, sends a join-room message, waits for server approval response, then `pushState`. The HTTP layer (axum) is used only for TURN credentials (established Phase 2).
- **D-10:** Message format follows existing JSON envelope (D-04 from Phase 2): `{"type": "join-room", "from": "<client-id>", "to": "", "payload": {"username": "...", "room_code": "...", "game_type": "..."}}`. Server responds with `{"type": "join-ack", "payload": {"slot": 2, "room_code": "ABCD", "reconnect_token": "...", "pairing_url": "https://..."}}` on success or `{"type": "join-error", "payload": {"reason": "room_full|room_not_found|..."}}` on failure.
- **D-11 (UX optimization):** Client may pre-open the WS/WT connection while the user is still typing in the lobby form. By submit time the connection is warm; approval arrives nearly instantly.

### QR Code and Phone Pairing URL
- **D-12:** QR code is **rendered client-side** via a JS library (e.g., `qrcode.js` or `qr-creator`). Server sends the full pairing URL string to the desktop over WS/WT; desktop calls the library to render. No server-side QR image endpoint required.
- **D-13:** QR code encodes a **full HTTPS URL**: `https://host/phone?token=<signed-token>`. This allows iOS and Android camera apps to scan and auto-open the phone app in the browser without any intermediate step.
- **D-14:** The pairing token is **HMAC-signed, single-use, and short-lived** (TTL decided by planner, ~60–120s suggested). Token encodes room + slot + expiry. Server validates signature and expiry before granting the pair; token is invalidated after first successful use. This prevents QR screenshot replay attacks.
- **D-15:** Desktop also shows a **short alphanumeric code** as fallback (SESS-03): the room code + slot number, or a derived short string the phone user can type into the phone app URL manually.

### Slot Hold and Reconnect
- **D-16:** On disconnect (phone or desktop), server marks the slot as `status: disconnected` and starts a **60-second hold timer**.
- **D-17:** Reconnecting client is identified by a **reconnect token** issued at pairing/join time. Token is stored in `sessionStorage` on the client. On reconnect, client sends the token; server looks up room+slot and reclaims if within the hold window.
- **D-18:** During the hold window, **only the slot reservation is preserved** (room, slot number, player identity, status). No message buffering or game state is held server-side — that is the game's responsibility.
- **D-19:** When the 60s hold expires with no reconnect, slot is **released back to the room pool** and a `player-left` lifecycle event is fired to all remaining room desktops. The slot number may be reused by the next joiner.

### Room Lifecycle Events
- **D-20:** Server pushes lifecycle events to **all desktops in the room** over their existing WS/WT connections. Every desktop maintains a complete view of the room state.
- **D-21:** Event format (extends existing JSON envelope): `{"type": "room-event", "payload": {"event": "player-joined|player-left|player-reconnected|room-full", "slot": 2, "username": "Alice"}}`.
- **D-22:** Events are **pushed proactively** by the server — no polling. Events fire on: desktop slot assigned, desktop disconnected (with hold started), desktop reconnected, hold expired (permanent leave), room full rejection.

### Claude's Discretion
- Exact room code length and character set (exclude ambiguous chars like 0/O, 1/I/l).
- Hold timer implementation (tokio `sleep` per slot vs. periodic cleanup sweep).
- Room state data structure on server (extend `SignalingBroker` vs. separate `RoomRegistry`).
- Reconnect token format (HMAC vs. random opaque token with server-side lookup).
- HMAC secret management for pairing tokens (env var, generated at startup).

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Requirements
- `.planning/REQUIREMENTS.md` — SESS-01 through SESS-06 are the phase requirements. Read for exact acceptance criteria.

### Prior Phase Artifacts
- `.planning/phases/02-signaling-turn-and-deployment/02-CONTEXT.md` — D-01 through D-07: signaling transport (WS port 9090, WT port 4433), JSON envelope format, in-process broker model. Phase 3 extends these decisions.
- `server/src/broker.rs` — existing `SignalingBroker` (`DashMap<ClientId, Sender>`). Phase 3 adds room/slot state; planner decides whether to extend this struct or add a separate `RoomRegistry`.
- `server/src/signaling.rs` — `SignalingEnvelope` struct and `parse_envelope`. New message types (`join-room`, `join-ack`, `join-error`, `room-event`) extend this.
- `server/src/ws_server.rs` — WebSocket handler that routes through broker. Phase 3 adds join-room handling here.
- `server/src/wt_server.rs` — WebTransport handler. Same join-room handling as WS.
- `server/src/main.rs` — env var config pattern; axum integration already exists for TURN endpoint (Phase 2).
- `server/src/turn_creds.rs` — HMAC credential generation pattern (TURN uses HMAC-SHA1 time-limited tokens). Phase 3 pairing token can follow the same pattern.

### Phase 2 State Notes
- `coturn must run with network_mode: host` (from STATE.md — do not change).
- Phase 1 WebSocket is plain `ws://` only; WSS deferred — Phase 3 must decide if static files are served over HTTPS (required for camera-app QR scanning and `DeviceMotionEvent`).

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `server/src/broker.rs::SignalingBroker` — register/unregister/route pattern. Room registry can wrap or extend this; the `Arc<DashMap>` clone pattern carries forward.
- `server/src/turn_creds.rs` — HMAC token generation. Pairing token (D-14) can reuse same HMAC approach with different payload schema.
- `server/src/echo.rs::now_ms()` — timestamp utility for token expiry checks.
- `serde_json`, `dashmap`, `tokio` already in `Cargo.toml` — no new core dependencies for session state.

### Established Patterns
- Env var config with `std::env::var` + fallback defaults — new config (hold TTL, HMAC secret, max room size) follows this pattern.
- `tokio::spawn` per connection task; errors in one task don't kill the accept loop.
- `tracing::warn!` / `tracing::info!` for all connection and routing events.
- `Arc<T>` passed into both WS and WT handlers — room registry follows same injection pattern as broker.

### Integration Points
- `ws_server.rs` and `wt_server.rs` both need access to the room registry (same `Arc<RoomRegistry>` injection as broker).
- `main.rs` constructs room registry, wraps in `Arc`, passes to both listeners alongside broker.
- Static file server (nginx in docker-compose) needs `try_files $uri /index.html` for SPA path routing.
- Desktop HTML needs a QR JS library (CDN or vendored) and a small JS module for lobby + room UI.

</code_context>

<specifics>
## Specific Ideas

- Phone pairing URL must be **HTTPS** so iOS/Android camera app auto-opens it in the browser (camera app only follows HTTPS links automatically). This implies the static file server must serve over HTTPS in any test environment, not just localhost HTTP.
- QR code must be camera-app scannable — not just in-browser QR scanner. Full HTTPS URL in QR is the requirement.
- Create Room flow intentionally has a **game/mode selection step** between clicking Create and being redirected. This step is a placeholder in Phase 3 but the UI scaffolding must support it for future game types.
- Lobby pre-warming the WS/WT connection is a UX optimization — not required but recommended for instant approval response.

</specifics>

<deferred>
## Deferred Ideas

- **Spectator mode** (SESS-V2-01) — desktop joins as observer only. Out of scope for v1; listed in v2 requirements.
- **Room password protection** (SESS-V2-02) — out of scope for v1.
- **Session persistence across page reload via URL token** (SESS-V2-03) — reconnect token covers tab-level reconnect; cross-reload persistence is v2.
- **Multiple concrete game types** — game/mode selection UI is scaffolded in Phase 3 but actual game implementations belong in Phase 8+.

</deferred>

---

*Phase: 3-Session and Pairing*
*Context gathered: 2026-07-07*
