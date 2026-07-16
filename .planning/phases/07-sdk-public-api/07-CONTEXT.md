# Phase 7: SDK Public API - Context

**Gathered:** 2026-07-16
**Status:** Ready for planning

<domain>
## Phase Boundary

The `immersive-rt` npm package: a headless (no DOM, no Three.js, no game rendering) TypeScript library that owns transport (WebTransport/WebSocket signaling + WebRTC data channels), packet decode, per-player target-state, and orientation smoothing — exposed through a clean imperative (`getPlayerInput`/`getRawInput`) + event-driven (`platform.on(...)`) public API, plus an opt-in developer latency overlay.

**Explicitly NOT this phase's job:** any Three.js scene, mesh, game rules, or room-join/lobby/QR-pairing UI. Each game (including the Phase 8 demo) builds its own rendering environment and its own join/pairing screen against the SDK's programmatic API. This is a hard boundary confirmed during discussion — see D-01.

Requirements: SDK-01, SDK-02, SDK-03, SDK-04, SDK-06 (SDK-05 already Complete — naming locked, carried forward not re-discussed).

</domain>

<decisions>
## Implementation Decisions

### SDK Scope Boundary
- **D-01:** The SDK is **headless** — no DOM, no Three.js, no game UI, no room-join/QR-pairing UI. Public surface is `connect()`/`joinRoom()` + `getPlayerInput()`/`getRawInput()` + `platform.on(...)` events only. Each game brings its own Three.js environment and its own rules; each game also builds its own lobby/pairing screen (the existing `client/src/room.ts` markup is a copy-paste reference, not an SDK dependency). Explicit user rationale: "Each game should have its own rules and threejs env."
- **D-02 (the one deliberate exception):** `platform.attachLatencyOverlay(container?)` renders a small fixed-position DOM overlay (rolling avg latency, jitter, packet-loss %, ICE state per player) — justified as a developer/debug tool, not game UI, in the same spirit as the existing debug HUD in `scene.ts`. `container` is optional, defaults to `document.body`.

### Package Layout & Distribution
- **D-03:** New npm workspace at `packages/immersive-rt/`, with a new root `package.json` declaring `"workspaces": ["packages/*", "client"]` — mirrors the existing Cargo workspace pattern (root `Cargo.toml` + `server/` member). `client/` becomes a workspace member and depends on `immersive-rt` via the workspace protocol, setting up cleanly for Phase 8's demo game to consume the package.
- **D-04:** Build tooling is **Vite library mode** (`build.lib` entry) — reuses the project's existing Vite 8.1.4 toolchain/config style rather than introducing a new bundler (e.g. tsup).
- **D-05:** Module format is **ESM only** — matches `client/`'s `"type": "module"` and Three.js r185 (itself ESM-only). No CJS dual-build.
- **D-06:** **Full extraction**, not a thin wrapper — the transport layer (WebTransport/WebSocket signaling, WebRTC data channel fan-out), `decode.ts`, `playerStore.ts` (target-state store), and the event bus move into `packages/immersive-rt/src/` as the real source of truth. `client/src/` stops owning this logic and becomes a consumer. `scene.ts`'s Three.js rendering code (mesh, SLERP-on-mesh, grid/axes/trail debug aids) stays behind in `client/` since it's game-specific, not SDK scope — it either gets deleted/left as a dev harness or becomes the seed for Phase 8's demo.
- **D-07:** The SDK has **zero dependency on the `three` npm package**. Internal SLERP math is a small (~15-line) hand-written function operating on plain `{w,x,y,z}` objects — matches the already-established pattern in `playerStore.ts` ("no THREE types, keeps store decoupled") and keeps the SDK engine-agnostic, consistent with D-01's "each game has its own env" boundary. Public `Quaternion`/`Vector3` types stay the existing plain-object interfaces from `client/src/types.ts` (already NOT `THREE.Quaternion`/`THREE.Vector3` — no change needed to the type shape, just its physical location after D-06's move).

### Orientation Interpolation Ownership
- **D-08:** The SDK runs its **own internal tick** (requestAnimationFrame when available, else `setInterval` fallback) started by `connect()`, independent of any consumer's render loop. The tick advances each connected player's smoothed orientation quaternion toward the latest raw packet every tick. `getPlayerInput()` reads the current interpolated value synchronously whenever called — no lazy per-call computation.
- **D-09:** SLERP alpha is **configurable per `connect()` call with a global default** — e.g. `connect({ slerpAlpha: 0.3 })` sets one alpha for the whole session. Default value carries forward the current `scene.ts` value (0.5). No per-player override. This directly resolves the item Phase 6 CONTEXT.md flagged as deferred: "Exposing it as a runtime slider is Phase 7 SDK."
- **D-10:** Interpolation (SLERP) applies **only to the orientation quaternion**. `gestureDisplacement` and `deadReckoningPosition` pass through as the latest raw packet value, unsmoothed. Rationale (discussed explicitly): orientation jitter is a pure network/packet-timing artifact worth smoothing away, but `gestureDisplacement` is a trigger signal meant to snap to near-zero after a gesture window closes (Phase 8's flick-launch action depends on that crispness) and `deadReckoningPosition` is drift-prone and reset-driven (ZUPT/ARKit recenter/R-key reset are meant to be visible corrections, not eased into) — smoothing either would fight their design intent.
- **D-11:** On packet gaps (phone lag/disconnect), the internal tick **holds at the last interpolated value** — no extrapolation, no snapping. Matches the freeze-on-loss convention already used elsewhere in the project (`webxr.ts`, ARKit D-07 in Phase 06.3 CONTEXT.md).

### Event API Design
- **D-12:** Event mechanism is **native `EventTarget`** (the `Platform`/SDK root object extends or wraps one internally behind a typed `.on()`/`.off()` facade) — zero dependencies, built into every modern JS runtime, and matches the roadmap's literal `platform.on(...)` shape.
- **D-13:** `imuUpdate` payload is `(playerId, data)` where `data` is the **exact same shape** `getPlayerInput()` returns (`{ orientation, gestureDisplacement, deadReckoningPosition, driftConfidence, touch }`) — one mental model for the data shape whether a game polls or subscribes.
- **D-14:** `imuUpdate` fires **on every internal interpolation tick** (D-08's rAF-paced cadence), not on every raw packet arrival — subscribers see the same interpolated values `getPlayerInput()` would return at that instant, roughly once per rendered frame, rather than at the network's jittery/bursty packet cadence.
- **D-15:** `playerJoin`/`playerLeave`/`playerReconnect` payload is **just `playerId`** — `cb(playerId)`, matching the roadmap's literal signature exactly. No bundled metadata (username, slot); the game calls `getPlayerInput(id)` itself if/when it needs data.

### Latency Overlay Implementation
- **D-16:** (See D-02 for the API shape — `attachLatencyOverlay()`.) Metrics source is **`RTCPeerConnection.getStats()`** (native WebRTC transport stats: jitter, packetsLost, roundTripTime) combined with the **existing `timestamp` field already present in every `SensorPacket`** (compared against `Date.now()` on receipt) for phone→render latency. **No changes to the wire schema** — `client/src/sensor/encode.ts`/`decode.ts` and the iOS native `SensorPacketEncoder.swift` all stay exactly as they are (36-byte packet, locked since Phase 5). This was explicitly confirmed after discussion: the wire schema is shared across two platforms (web + native iOS) and `getStats()` already provides everything the overlay needs without touching it.

### Claude's Discretion
- Exact internal SLERP function implementation (~15 lines, standard quaternion SLERP over plain objects).
- Exact `EventTarget` wrapping approach (subclass vs. internal instance + facade methods).
- Whether `scene.ts`'s existing debug/precision-eval Three.js code is deleted from `client/` or repurposed as a dev harness during this phase (Phase 8 owns the real demo game either way).
- Exact internal tick fallback logic (feature-detecting `requestAnimationFrame` vs Node/non-browser environments).
- `getRawInput(playerId).orientationRaw` implementation — the latest raw (non-interpolated) packet quaternion, trivially available since D-08's tick already tracks both raw-latest and smoothed state.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Requirements & Roadmap
- `.planning/REQUIREMENTS.md` §SDK — SDK-01 through SDK-06 (SDK-05 already Complete, naming locked). Exact acceptance criteria for `getPlayerInput()`/`getRawInput()` return shapes, event signatures, and the latency overlay's required fields.
- `.planning/ROADMAP.md` §Phase 7 — 6 success criteria, all must be TRUE. Success criterion 1 requires `tsc --strict` to compile cleanly against the published types.

### Prior Phase Context (data this phase wraps)
- `.planning/phases/06-desktop-receive-decode-and-rendering/06-CONTEXT.md` — D-12 (SLERP alpha 0.3 hardcoded, later changed to 0.5 in code — see below), D-13 (position mode toggle), Deferred Ideas section explicitly flags "SLERP alpha UI control ... is Phase 7 SDK."
- `.planning/phases/05-sensor-fusion-and-packet-encoding/05-CONTEXT.md` — D-14: exact 36-byte wire layout this phase's transport/decode extraction must preserve byte-for-byte. Wire schema is locked (D-16 above depends on this staying untouched).
- `.planning/phases/06.3-ios-native-client-arkit-world-tracking/06.3-CONTEXT.md` — D-07: `driftConfidence` freeze-on-loss convention this phase's D-11 (hold-at-last-value) mirrors; confirms the same 36-byte wire schema is shared with the native iOS client (relevant to D-16's "no wire schema changes" decision).

### Client Source Files (extraction targets — D-06)
- `client/src/room.ts` — current WebTransport/WebSocket signaling + WebRTC peer/data-channel management (`desktopPeers` Map, `ondatachannel` handler, `dc.onmessage` → decode wiring). This is the primary extraction source for the SDK's transport layer.
- `client/src/playerStore.ts` — `targetStateStore` Map + `PlayerState` interface + `updateTargetState`/`removePlayerState`. Extraction target for the SDK's internal state store; already dependency-free per its own docstring ("no THREE types").
- `client/src/sensor/decode.ts` — binary packet decoder (inverse of `encode.ts`). Extraction target, unchanged internals.
- `client/src/types.ts` — `Quaternion`, `Vector3`, `TouchState`, `SensorPacket` interfaces — the plain-object types D-07 confirms stay as the SDK's public type shapes.
- `client/src/scene.ts` — current SLERP-on-`THREE.Quaternion` implementation (line ~95: `SLERP_ALPHA = 0.5`) is the reference for D-08/D-09's new engine-agnostic internal tick; NOT itself moved into the SDK (D-06) since it's Three.js-coupled game code.
- `client/vite.config.ts` — existing Vite config for the `client` app; `packages/immersive-rt/vite.config.ts` (new file) follows the same tool/style per D-04 but with `build.lib` instead of `rollupOptions.input` multi-entry.
- `client/package.json` — current single-package manifest; becomes a workspace member per D-03, gains a `"immersive-rt": "workspace:*"` dependency.

### Server Source Files (unchanged, referenced for transport contract)
- `server/src/wt_server.rs` / `server/src/ws_server.rs` — signaling message contract the extracted transport layer in `packages/immersive-rt/` must continue to speak exactly as `room.ts` does today. No server changes this phase.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `client/src/playerStore.ts::targetStateStore`/`PlayerState` — already dependency-free (plain numbers, no THREE types) per its own docstring; near-directly portable into the SDK's internal state store (D-06).
- `client/src/sensor/decode.ts` — already the exact inverse of `encode.ts` with no external deps beyond `@petamoriken/float16`; portable as-is.
- `client/src/room.ts::desktopPeers` Map + WT/WS dual-path connect pattern — the transport logic to extract, already battle-tested through Phase 6.
- `client/src/types.ts::Quaternion`/`Vector3`/`TouchState`/`SensorPacket` — already the plain-object shapes the public SDK API needs (D-07); no redesign needed, only relocation.

### Established Patterns
- "No THREE types in the data layer" (`playerStore.ts` docstring) — directly extends to "no `three` dependency in the SDK at all" (D-07).
- WT-first/WS-fallback dual-path pattern (`phone.ts`, ported to `room.ts` in Phase 6 D-01/D-02) — the extracted SDK transport layer keeps this exact pattern.
- Freeze-on-loss / hold-last-value convention (`webxr.ts`, ARKit D-07) — extended to network packet gaps in this phase's D-11.

### Integration Points
- `client/src/room.ts`'s `dc.onmessage` → `decode()` → `updateTargetState()` chain is the exact seam D-06's extraction cuts along — this becomes internal-to-the-SDK, with `getPlayerInput()`/events as the new external seam.
- `RTCPeerConnection.getStats()` (not currently called anywhere in the codebase) is a new integration point for D-16's latency overlay — called against the existing `RTCPeerConnection` objects the extracted transport layer manages.

</code_context>

<specifics>
## Specific Ideas

- "Each game should have its own rules and threejs env" — user's explicit correction that reframed the entire SDK boundary question: this is a headless data/transport library, not a game engine or scene wrapper (D-01).
- User confirmed the SDK is headless (no lobby/pairing UI either) rather than shipping a mountable pairing widget — the only UI exception is the latency dev-tool overlay (D-02).
- On interpolation scope: user asked "Why do you wanna apply only on orientation?" — prompted an explicit rationale walkthrough (gesture-trigger crispness, drift-correction legibility) before confirming orientation-only SLERP (D-10).
- On latency metrics: user initially selected "needs new wire-level tracking," which surfaced that `RTCPeerConnection.getStats()` already provides jitter/packet-loss/RTT without touching the two-platform-shared wire schema — reconsidered and confirmed no schema change needed (D-16).

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope. (Game-specific concerns — Three.js scene, meshes, gesture-launch visuals, multi-desktop sync — remain correctly out of scope per D-01 and belong to Phase 8, already noted as deferred in Phase 6's CONTEXT.md.)

</deferred>

---

*Phase: 7-SDK Public API*
*Context gathered: 2026-07-16*
