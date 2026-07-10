# Phase 6: Desktop Receive, Decode, and Rendering - Context

**Gathered:** 2026-07-10
**Status:** Ready for planning

<domain>
## Phase Boundary

The desktop side of the sensor hot path. room.ts gains a WebTransport connection (migrated from WebSocket, WS fallback kept), accepts WebRTC data channels from all phones, decodes incoming 36-byte binary packets (schema v1), drops out-of-order packets via uint16 sequence comparison, maintains a per-player target-state store, and drives a Three.js scene embedded in the existing page. The scene goes full-viewport when all phones are ready, with a persistent slot-count HUD and a TAB-held roster overlay. The 3D scene is precision-evaluation-grade: object rotation via SLERP, runtime-toggleable position mode, all-hideable precision aids, touch feedback.

Requirements: DESK-01, DESK-02, DESK-03, DESK-04, DESK-05

</domain>

<decisions>
## Implementation Decisions

### Desktop WebTransport (DESK-01)
- **D-01:** **Full WT migration** — room.ts replaces WebSocket with WebTransport for all signaling (join-room, pair-ack, ICE/offer/answer, ice-candidate, room lifecycle events). Same dual-path pattern as phone.ts (Phase 4 D-01): try WebTransport first, fall back to WebSocket if QUIC is blocked.
- **D-02:** **WS fallback kept** — INFRA-05 server-side WS path is already validated. Desktop falls back to WS automatically; no user-visible difference. Both paths carry the full signaling message set.
- **D-03:** **No split transport** — all message types (ICE/WebRTC signaling + game state events) travel on a single active transport. No simultaneous WS + WT connections.

### Three.js Canvas Placement (DESK-01, DESK-05)
- **D-04:** **Embedded in existing index.html / room.ts** — no new Vite entry, no new HTML file. Three.js renderer is initialised inside room.ts when `player-ready` fires for the first player.
- **D-05:** **Full-viewport canvas on `player-ready`** — room UI (lobby, QR column, roster, events) hides when game view activates. Canvas fills the browser viewport.
- **D-06:** **Persistent minimal HUD** — always visible over canvas: slots occupied / total count (e.g. "2/4 connected"). Not hideable — always-on orientation reference.
- **D-07:** **TAB-held expanded overlay** — holding TAB renders full roster over canvas: player name, slot number, connection status (WebRTC channel state) per player. Releases on TAB-up.

### Packet Decode (DESK-03)
- **D-08:** **decode.ts mirrors encode.ts** — new `client/src/sensor/decode.ts` uses `getFloat16` from `@petamoriken/float16` (already in package.json) to read float16 fields at the exact byte offsets defined in D-14 (Phase 5 CONTEXT.md). Returns a `SensorPacket` (existing type in `types.ts`). No new dependency needed.
- **D-09:** **Sequence-drop via half-distance uint16** — `(newSeq - lastSeq) & 0xFFFF <= 32767` determines if `newSeq` is strictly newer. Drop packet silently if false. Handles wraparound at 65535→0 correctly. Per-sender last-seq stored in target-state store. (Claude's discretion on exact implementation.)

### Target-State Store (DESK-04)
- **D-10:** `Map<playerId, PlayerState>` where `PlayerState` holds: latest `SensorPacket` fields (orientation quaternion, gestureDisplacement, deadReckoningPosition, driftConfidence, touch), plus `lastSeq: number` and `lastTimestamp: number`. Updated on every accepted packet (after seq-drop check). Downstream Three.js loop reads from this map every `requestAnimationFrame`.

### Three.js Scene (DESK-05)
- **D-11:** **Scene composition** — ambient light + directional light, one solid-colored box per player (distinct per-slot hue, e.g. HSL evenly spaced), player name label floating above each box, fixed perspective camera (no orbit controls — precision evaluation needs a stable viewpoint).
- **D-12:** **Rotation** — object quaternion set from `SensorPacket` orientation via SLERP each frame. Default alpha 0.3 (configurable in code, not exposed in UI for Phase 6).
- **D-13:** **Position mode — runtime-toggleable** — keyboard key `P` cycles: `gestureDisplacement` → `deadReckoningPosition` → back. Current mode shown in HUD label. One mode active at a time; both are available for evaluation without reloading.
- **D-14:** **Touch response** — two layers, independently toggled:
  - **Always on:** color flash/pulse on the object when `touchActive = true` (immediate, latency-visible).
  - **Drama toggle (`D` key):** motion trail behind the object. Off by default.
- **D-15:** **Precision aids — all individually toggleable via keyboard:**
  - `G` — grid floor (GridHelper). Default: on.
  - `A` — axes gizmo per object (AxesHelper attached to each mesh). Default: on.
  - `H` — numeric HUD per player: quaternion (w,x,y,z), active displacement/position vector, driftConfidence scalar, active position mode label. Default: on.
  - `T` — motion trail (also the drama-mode toggle from D-14). Default: off.

### Claude's Discretion
- Exact uint16 half-distance seq-drop implementation (standard 3-line math).
- Three.js `requestAnimationFrame` loop structure (standard `animate()` recursion).
- Per-slot hue assignment (HSL evenly spaced across 8 slots).
- Motion trail implementation (trailing ghost geometry or `TrailRenderer` pattern — whichever is lighter).
- SLERP: use `THREE.Quaternion.slerp()` between current and target quaternion each frame.
- Label rendering: `CSS2DRenderer` or `Sprite` — whichever integrates cleanly with the existing DOM structure.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Requirements
- `.planning/REQUIREMENTS.md` — DESK-01 through DESK-05. Read for exact acceptance criteria (WT session visible in DevTools, no server relay of sensor packets after channel open, seq-drop verified, SLERP visible, two phones / two objects).
- `.planning/ROADMAP.md` §Phase 6 — 5 success criteria. All 5 must be TRUE.

### Prior Phase Context
- `.planning/phases/05-sensor-fusion-and-packet-encoding/05-CONTEXT.md` — D-14: exact byte layout of schema v1 packet (36 bytes, all offsets). D-11: version byte at offset 0. D-12: float16 precision for quaternion + displacement + position fields. D-13: touch encoding (uint8 active, uint16 x/y normalized 0–65535). **Phase 6 decode.ts must implement the exact inverse of encode.ts.**
- `.planning/phases/04-phone-bootstrap-and-webrtc-channels/04-CONTEXT.md` — D-01: phone uses WT (now desktop must match). D-05: phone is offer initiator; desktop is answerer. D-08/D-09: both-sides `rtc-channel-ready` → server broadcasts `player-ready`.

### Client Source Files
- `client/src/room.ts` — existing desktop SPA. Phase 6 migrates WS→WT here and adds Three.js init + render loop. Key existing assets: `desktopPeers` Map (WebRTC answerer), `sendMessage()`/`sendTo()` helpers, `showView()`, all WS signaling handlers (to be ported to WT).
- `client/src/types.ts` — `SensorPacket`, `Quaternion`, `Vector3`, `TouchState` interfaces. Phase 6 decode.ts returns `SensorPacket` — no new types needed.
- `client/src/sensor/encode.ts` — D-14 byte layout reference. Phase 6 decode.ts is the exact inverse; read this file first.
- `client/index.html` — existing HTML shell. Phase 6 adds: `<canvas id="game-canvas">` inside or alongside `#view-room`, HUD overlay div, TAB overlay div. Existing views (`#view-lobby`, `#view-room`) stay; game canvas activates on top.
- `client/vite.config.ts` — single `room` entry point. No change needed for Phase 6 (embed approach, no new entry).

### Dependencies
- `@petamoriken/float16` (already in `client/package.json`) — `getFloat16(view, offset, littleEndian)` for decoding float16 fields in decode.ts.
- `three` (NOT yet installed) — must be added to `client/package.json` dependencies. Use r185 (0.185.x) per CLAUDE.md tech stack.
- `@types/three` — matching version, devDependency.

### Server Source Files
- `server/src/wt_server.rs` — existing WT handler. Phase 6 desktop connects here (same as phone). No server changes needed for Phase 6 — server already supports multiple WT clients per room.
- `server/src/ws_server.rs` — WS fallback. Desktop falls back here if QUIC blocked. Already handles all required message types.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `room.ts::desktopPeers` Map — already stores `RTCPeerConnection` per phoneId; Phase 6 wires `dc.onmessage` to decode + target-state-store update inside the existing `ondatachannel` handler (line 271).
- `room.ts::sendMessage()` / `sendTo()` — currently call `ws.send()`. Phase 6 replaces the underlying transport but these helper shapes stay the same.
- `room.ts::showView()` — used to toggle between lobby/room/phone views. Phase 6 adds a `showGameView()` that hides all existing views and shows the canvas.
- `client/src/types.ts::SensorPacket` — already fully typed with all fields Phase 6 needs. decode.ts returns this type directly.
- `client/src/sensor/encode.ts::SCHEMA_VERSION`, `BUF_SIZE` — export constants Phase 6 decode.ts should import for version-check guard.

### Established Patterns
- `phone.ts` WT connection pattern (lines ~100–200 of phone.ts): `new WebTransport(url)`, `.ready`, `listenForServerPushes()`, `sendToServer()`. Desktop WT migration copies this pattern exactly.
- `phone.ts` WS fallback: `window.location.protocol === 'https:'` guard, try WT first, catch → WS. Same logic for desktop.
- `phone.ts::peerConnections` Map per peer — same pattern as `desktopPeers` in room.ts. Already battle-tested.
- `encode.ts` DataView + `setFloat16` pattern — decode.ts uses `getFloat16` from same package, same little-endian convention, same offsets.

### Integration Points
- `dc.onmessage` handler in `room.ts` `ondatachannel` callback (line 271–277): currently only calls `sendMessage('rtc-channel-ready', ...)`. Phase 6 adds `decode(evt.data)` → update target-state store → (rendering handled by rAF loop).
- `player-ready` message handler in `room.ts`: currently adds a roster entry. Phase 6 also triggers Three.js init and canvas activation on first `player-ready`.
- Three.js `requestAnimationFrame` loop reads target-state store each frame — no coupling to WebRTC message timing. Clean separation: WebRTC updates state; rAF reads state.

</code_context>

<specifics>
## Specific Ideas

- **Precision-evaluation scene intent** — Phase 6 is not just a plumbing proof; the user wants to evaluate motion precision directly. Scene design (grid floor, axes gizmo, numeric HUD, stable camera) is intentional for this purpose. Phase 8 replaces scene content with the real demo game.
- **Position mode toggle** — `P` key cycles gestureDisplacement ↔ deadReckoningPosition. Mode label visible in HUD. Lets user compare the two position pipelines side-by-side across separate test runs without code changes.
- **Touch latency legibility** — color flash/pulse on touch is specifically chosen because it makes phone-to-screen latency perceptible at a glance. This is a diagnostic feature, not just UX polish.
- **TAB overlay** — persistent minimal HUD (slot count) plus TAB-held expanded roster mirrors a game-style "score overlay" pattern. Designed so user can check connection state without leaving the precision-eval view.

</specifics>

<deferred>
## Deferred Ideas

- **Orbit controls / camera pan** — fixed camera chosen for Phase 6 (precision eval needs stable reference). Interactive camera is Phase 8 demo game scope.
- **Per-player object shape variety** — all players get boxes in Phase 6. Custom geometry per player is Phase 8.
- **SLERP alpha UI control** — alpha hardcoded at 0.3 in Phase 6. Exposing it as a runtime slider is Phase 7 SDK / Phase 8 demo.
- **Gesture-triggered flick action** — DEMO-03 (flick launches object). Phase 8.
- **Multi-desktop sync** — all desktops in same room see same positions. Phase 8 (DEMO-02 / DEMO-03).

</deferred>

---

*Phase: 6-Desktop Receive, Decode, and Rendering*
*Context gathered: 2026-07-10*
