# Phase 4: Phone Bootstrap and WebRTC Channels - Context

**Gathered:** 2026-07-07
**Status:** Ready for planning

<domain>
## Phase Boundary

Phone web app loads from QR-scan URL with no install. iOS users see a "Grant Motion Access" button before any sensor code runs. The phone establishes a WebRTC unreliable data channel to every desktop in the room, reports channel readiness back to the server, and the server fires `player-ready` to the whole room when all channels are confirmed open. Phone maintains heartbeats, activates Wake Lock after `player-ready`, and reports state changes (background/foreground, Wake Lock lost/reacquired, channel drops/recoveries) to the server for broadcast to desktops.

Requirements: PHONE-01, PHONE-02, PHONE-03, PHONE-06, PHONE-07

</domain>

<decisions>
## Implementation Decisions

### Signaling Transport
- **D-01:** Phone uses **WebTransport** (not WebSocket) for all signaling — pair flow, ICE exchange, state notifications, heartbeats. Consistent with server's WT endpoint on port 4433. WS fallback remains available but phone-primary path is WT.

### Trust Model
- **D-02:** **Room membership = authorization.** No per-pair pre-grant between phone and desktop. Server validates phone's HMAC pairing token at pair time; after that, any phone in the room is authorized to open WebRTC channels to any desktop in the room.
- **D-03:** Desktop verifies incoming WebRTC offer legitimacy via **server attestation in the routing envelope**: broker includes `{from: phone_id, room: ABCD}` in the signaling message. Desktop trusts the server's routing — no per-offer crypto, no token re-check.

### WebRTC Initiation Protocol
- **D-04:** Server includes **room roster in `pair-ack` payload**: `{slot, room_code, reconnect_token, pairing_url, peers: [{id, slot, username}]}`. Phone has the full desktop peer list immediately after pairing — no extra round trip.
- **D-05:** **Phone is the offer initiator.** After `pair-ack`, phone loops through `peers[]`, creates one `RTCPeerConnection` per desktop, creates WebRTC offer, sends via WT signaling with `to: desktop_id`. All channels use `{ ordered: false, maxRetransmits: 0 }` (locked from STATE.md).
- **D-06:** When a **new desktop joins while phone is connected**: server pushes `{type: 'peer-joined', peer: {id, slot, username}}` to the phone via WT. Phone immediately opens a new `RTCPeerConnection` + offer to the new desktop. Symmetric with initial fan-out.
- **D-07:** When a desktop **leaves**, server pushes `{type: 'peer-left', peer_id}` to the phone via WT. Phone closes the corresponding `RTCPeerConnection`.

### Channel Readiness and player-ready
- **D-08:** **Both sides report channel-open to server.** When `RTCDataChannel.readyState` hits `'open'`: phone sends `{type: 'rtc-channel-ready', with: desktop_id}`; desktop sends `{type: 'rtc-channel-ready', with: phone_id}`. Server requires confirmation from **both** sides before marking a channel established.
- **D-09:** When all channels for a player are confirmed established (both-sides confirmed, all desktops): server broadcasts `{type: 'player-ready', player_id, slot, username}` to **all room members** (all desktops + the phone). This is the game-start gate signal — games can listen for all expected `player-ready` events before beginning.

### Phone UI States
- **D-10:** Between `pair-ack` and `player-ready`: phone shows **"Connecting... X/Y channels"** with a spinner, counting up live as each channel opens.
- **D-11:** After `player-ready`: phone shows **minimal status screen** — player name, room code, channel count ("3/3 connected"), and a motion indicator that pulses on device movement (proves sensor is live, uses `devicemotion` event to drive the pulse even though full Madgwick pipeline is Phase 5).

### iOS Permission Gate
- **D-12:** "Grant Motion Access" button is the **first and only interactive element** on phone page load (before any connection attempt). `DeviceMotionEvent.requestPermission()` is called inside the synchronous click handler — no sensor code executes before the button tap. Android: feature-detect `requestPermission` existence before calling; fire immediately if absent.

### File Structure
- **D-13:** Phone client is a **separate artifact**: `phone.html` + `phone.js` in the static dir. No lobby/desktop/QR code on the phone. Served via nginx `try_files $uri $uri.html /index.html` (one-word change to existing nginx config from `try_files $uri /index.html`).
- **D-14:** The existing `#view-phone` stub in `index.html` (which currently shows "Phone app coming in Phase 4") becomes a simple redirect to `/phone?token=...` — or is removed and the QR URL encodes `/phone?token=...` directly (already the case from Phase 3 D-13).

### Wake Lock
- **D-15:** Wake Lock (`WakeLock.request('screen')`) is requested **after `player-ready` fires** — not during connecting phase. Player is in active game session at this point.
- **D-16:** Wake Lock is released automatically by the browser on backgrounding (browser restriction). On `visibilitychange` → visible: phone (1) re-requests Wake Lock, (2) sends `{type: 'phone-state', state: 'foreground'}` via WT, (3) checks each `RTCDataChannel.readyState` — if any closed, re-initiates offer to that desktop. Full self-healing.

### Phone State Notifications
- **D-17:** Phone proactively sends state change messages to server via WT; server broadcasts to room desktops. State transitions that notify:
  - `visibilitychange` → hidden: `{type: 'phone-state', state: 'background'}`
  - `visibilitychange` → visible: `{type: 'phone-state', state: 'foreground'}`
  - WakeLock sentinel `release` event: `{type: 'phone-state', state: 'wake-lock-lost'}`
  - WakeLock reacquired: `{type: 'phone-state', state: 'wake-lock-active'}`
  - `RTCDataChannel` closed: `{type: 'phone-state', state: 'channel-lost', with: desktop_id}`
  - `RTCDataChannel` reopened: `{type: 'phone-state', state: 'channel-recovered', with: desktop_id}`
  - Heartbeat miss (server-driven): server detects missed heartbeat and broadcasts `{type: 'phone-state', state: 'heartbeat-miss', slot}` to desktops — no phone-side action needed for this one.
- **D-18:** Server relays all `phone-state` events to **all room desktops** so games can react (e.g., pause input expectation, show "player X disconnected" UI).

### Heartbeat
- **D-19:** Phone sends heartbeat `{type: 'heartbeat'}` via WT every 5 seconds. If backgrounded and heartbeat stops, server marks slot `disconnected` (holds for 60s). On foreground return, phone immediately sends a heartbeat to reset the timer.

### Claude's Discretion
- Exact `phone-state` event naming on the wire (keep it consistent with existing JSON envelope pattern from Phase 2/3).
- How server tracks "all channels confirmed" state — data structure per room/player.
- WakeLock feature detection (Safari partial support on older iOS — graceful degradation if `navigator.wakeLock` is absent).
- Motion indicator animation implementation (CSS pulse driven by devicemotion event magnitude threshold).

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Requirements
- `.planning/REQUIREMENTS.md` — PHONE-01, PHONE-02, PHONE-03, PHONE-06, PHONE-07 are the phase requirements. Read for exact acceptance criteria.

### Prior Phase Context
- `.planning/phases/03-session-and-pairing/03-CONTEXT.md` — D-01 through D-22: pairing token format, pair-ack structure, room lifecycle events, reconnect token, QR URL format (`https://host/phone?token=...`). Phase 4 extends pair-ack payload (D-04 above adds `peers[]`).
- `.planning/phases/02-signaling-turn-and-deployment/02-CONTEXT.md` — JSON envelope format `{type, from, to, payload}`, signaling transport decisions, broker routing pattern.

### Server Source Files
- `server/src/broker.rs` — `SignalingBroker` (`DashMap<ClientId, Sender>`). Phase 4 adds room-aware routing: `route_to_room()` for broadcasts, peer-joined/peer-left pushes to phone.
- `server/src/wt_server.rs` — WebTransport handler. Phase 4 adds handling for `rtc-channel-ready`, `phone-state`, `heartbeat` message types.
- `server/src/ws_server.rs` — WebSocket handler (same new message types as wt_server).
- `server/src/signaling.rs` — `SignalingEnvelope` and `parse_envelope`. New message types extend this.
- `server/src/turn_creds.rs` — HMAC pattern reference for any new credential work.

### Client Source Files
- `client/dist/index.html` — Existing SPA with `#view-phone` stub. Phase 4 creates separate `phone.html`; this stub may become a redirect.
- `client/dist/room.js` — 793-line SPA: WebSocket client, QR render, room lifecycle. Phone client (`phone.js`) is a separate file — do NOT add phone WebRTC code here.

### Deployment Config
- `docker-compose.yml` — nginx static file server config. Phase 4 changes `try_files $uri /index.html` → `try_files $uri $uri.html /index.html` to serve `phone.html` at `/phone` path.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `server/src/broker.rs::SignalingBroker::route()` — routes message to single peer by ID. Phase 4 needs a new `route_to_room(room_code, msg)` that broadcasts to all room desktops, and `route_to_phone(room_code, msg)` for server-→-phone pushes.
- `server/src/turn_creds.rs` — HMAC pattern. Pairing token validation reuses same approach.
- `client/dist/room.js::showView()` / `showError()` / `clearError()` — UI helpers. Phone.js can implement similar lightweight helpers without the full SPA machinery.
- Existing `slot-row` CSS classes in `index.html` — phone.html can share the design token CSS variables (copy the `:root` custom properties block) for visual consistency.

### Established Patterns
- `tokio::spawn` per connection task; errors don't kill the accept loop.
- `Arc<T>` threaded through both WS and WT handlers — `Arc<RoomRegistry>` follows same injection pattern.
- Env var config with `std::env::var` + fallback defaults — any new config (channel-ready timeout, etc.) follows this.
- `tracing::warn!` / `tracing::info!` for all connection and routing events.

### Integration Points
- `pair-ack` message (server → phone): extend payload to add `peers: [{id, slot, username}]`.
- New server-side message types to handle: `rtc-channel-ready`, `phone-state`, `heartbeat` (from phone), `peer-joined`, `peer-left`, `player-ready`, `phone-state` broadcast (server → desktops).
- nginx `default.conf` in static file server container: one-line change to `try_files`.
- Phone's WT connection uses same port (4433) and TLS cert as desktop — no new cert work.

</code_context>

<specifics>
## Specific Ideas

- Phone connects via **WebTransport** (not WebSocket) — this is a firm user decision, not a fallback choice. WS fallback exists for phone too if WT fails, but primary path is WT.
- **Room membership = trust** — no extra per-pair authorization. Server's routing envelope is the attestation. Researcher/planner should NOT add per-offer token validation.
- **`player-ready` event is a game-start gate** — game developers will listen for this. The signal must be reliable: both sides confirmed, all channels open. Not a best-effort hint.
- Phone screen stays landscape or portrait as user holds it — no forced orientation lock in Phase 4 (game controls this in later phases).

</specifics>

<deferred>
## Deferred Ideas

- Full sensor display on phone (orientation indicator, position values) — Phase 5.
- Phone reconnect UI / reconnect flow in phone.js — server holds slot 60s; Phase 4 lets it lapse and phone shows a "session ended" state. Reconnect UX is Phase 5 scope.
- WakeLock on older Safari (partial support) — graceful degradation noted in Claude's Discretion; detailed cross-browser polyfill is out of Phase 4 scope.
- Touch input capture (tap, on-screen buttons) — Phase 5 (SENS-06).

</deferred>

---

*Phase: 4-Phone Bootstrap and WebRTC Channels*
*Context gathered: 2026-07-07*
