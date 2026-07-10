# Phase 5: Sensor Fusion and Packet Encoding - Context

**Gathered:** 2026-07-09
**Status:** Ready for planning

<domain>
## Phase Boundary

Phone runs a full on-device sensor pipeline — OS-fused orientation (DeviceOrientationEvent) as primary with Madgwick filter on raw DeviceMotionEvent as parallel comparison — and encodes every output into a compact binary MessagePack packet transmitted over the WebRTC unreliable data channel at 60Hz. Phase 5 also introduces: Vite build tooling + TypeScript migration for all client code, a dev-mode tuning overlay, and a basic hold-still calibration scene at session start.

Requirements: SENS-01, SENS-02, SENS-03, SENS-04, SENS-05, SENS-06, PHONE-04, PHONE-05

</domain>

<decisions>
## Implementation Decisions

### Build Tooling and TypeScript Migration
- **D-01:** Add **Vite build step** to the client. `client/` gets `package.json` + `vite.config.ts`. Both `phone.ts` (was `phone.js`) and `room.ts` (was `room.js`) are migrated to TypeScript and bundled via Vite to `dist/`. Unlocks npm ecosystem for `ahrs`, `msgpackr`, and future packages (Phase 6 Three.js, Phase 7 SDK).
- **D-02:** Migrate **both** `phone.js` and `room.js` to TypeScript in Phase 5 — one migration instead of two. Sensor types (`Quaternion`, `Vector3`, `SensorPacket`) defined once and shared; Phase 7 SDK inherits typed consumers.

### Orientation Pipeline
- **D-03:** Run **both** orientation pipelines in parallel throughout Phase 5:
  - **Primary:** `DeviceOrientationEvent` (OS-fused) → α/β/γ converted to quaternion. Drift-free on modern devices.
  - **Secondary:** `DeviceMotionEvent` (raw IMU) → **Madgwick filter** via `ahrs` npm package → quaternion.
  - A dev overlay on the phone screen shows both quaternions live during testing. Real-device comparison determines which is better for Phase 6+.
- **D-04:** **OS-fused quaternion feeds the actual sensor packet by default.** URL param `?orient=madgwick` switches to Madgwick output. URL params are **dev-mode only** (`import.meta.env.DEV`) — Vite dead-code eliminates them from production bundle. Players cannot access params.
- **D-05:** Custom filter is **Madgwick** (not Mahony). Reliability over CPU savings — better magnetometer fusion, more reliable absolute heading. Mahony is 10–15% faster but drifts more on yaw; not worth the accuracy tradeoff.

### ZUPT and Dead-Reckoning
- **D-06:** ZUPT fires **after** 300ms of detected stillness — it does not add latency to the live sensor stream. Packets flow at 60Hz uninterrupted; ZUPT is a background correction that resets velocity to 0 and raises `driftConfidence` to 1.0 during natural movement pauses.
- **D-07:** Position is dead-reckoning via Kalman filter. `driftConfidence` scalar (0–1) included in every packet. API uses `deadReckoningPosition` naming (never bare `position`) to make drift nature explicit.

### Calibration
- **D-08:** **Basic hold-still calibration scene** runs once at session start (after `player-ready`, before sensor loop begins). Phone shows: `"Hold your phone still on a flat surface"` + 3-second countdown bar. During hold: phone measures accelerometer variance → auto-sets ZUPT threshold and initial Kalman noise params for that device's specific sensor characteristics. On complete: auto-advances to controller screen.
- **D-09:** Full guided calibration (rotate + flick steps) deferred to Phase 8 / SDK phase when demo game needs it. Phase 5 hold-still step covers highest-value case (ZUPT tuning for device noise floor).

### Packet Schema
- **D-10:** **Array (positional) format** for MessagePack encoding — no field names on wire. Smallest payload. Decode side must know schema version (enforced via version byte). Matches msgpackr record extension pattern for further compression.
- **D-11:** **uint8 schema version as first byte** (starts at 1). Phase 6 decoder reads version, derives field layout. Future phases increment version and append fields — zero breaking change.
- **D-12:** **Float precision:** `float16` for quaternion components (4 values) and position/displacement fields (9 values = 3×Vector3). `float32` for `driftConfidence`. Float16 saves ~14 bytes per packet; 3 decimal digits of precision is sufficient for quaternion components. Encode/decode bit-math required on both ends (no native JS float16).
- **D-13:** **Touch encoding:** 1 primary touch point for Phase 5. Stream raw normalized (x, y) coordinates every packet as uint16 each + 1 byte active flag. Swipe direction, long-press duration, velocity are derived on the desktop from the 60Hz coordinate stream — no gesture detection on phone. Expandable to 2+ touch points in future phases via schema version bump.
- **D-14:** **Provisional packet layout (schema v1):**
  ```
  [0]  version      uint8      1 byte
  [1]  seq          uint16     2 bytes
  [3]  timestamp    uint32     4 bytes  (ms since session start)
  [7]  qw,qx,qy,qz float16×4  8 bytes  (orientation quaternion)
  [15] dx,dy,dz     float16×3  6 bytes  (gesture displacement)
  [21] px,py,pz     float16×3  6 bytes  (dead-reckoning position)
  [27] driftConf    float32    4 bytes
  [31] touchActive  uint8      1 byte   (bit 0 = active)
  [32] touchX       uint16     2 bytes  (normalized 0–65535)
  [34] touchY       uint16     2 bytes  (normalized 0–65535)
  Total: 36 bytes — within 45-byte target
  ```

### Dev Overlay
- **D-15:** Dev overlay (dev-mode only, Vite dead-code eliminated in production) shows on phone screen: OS quaternion vs Madgwick quaternion (live), active filter param values, ZUPT fired/not indicator, drift confidence, packet Hz. Auto-hidden in production builds — players see nothing.

### Claude's Discretion
- Float16 encode/decode implementation (bit manipulation pattern — use a well-known reference implementation, not custom).
- Madgwick beta ramp logic at cold start (SENS-02): start at 0.2–0.3, ramp to 0.1 after convergence — implementation details.
- Kalman filter process/measurement noise defaults — empirically tuned during Phase 5 testing.
- Gesture displacement window gating (SENS-05): ZUPT-gated per-action delta — implementation details.
- msgpackr record extension usage for further compression (optional optimization if base encoding exceeds target).

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Requirements
- `.planning/REQUIREMENTS.md` — SENS-01 through SENS-06, PHONE-04, PHONE-05 are the phase requirements. Read for exact acceptance criteria including the 45-byte / 55Hz targets.
- `.planning/ROADMAP.md` §Phase 5 — Success criteria (5 items). All 5 must be TRUE.

### Prior Phase Context
- `.planning/phases/04-phone-bootstrap-and-webrtc-channels/04-CONTEXT.md` — D-05: data channel `{ ordered: false, maxRetransmits: 0 }` (locked). D-13: phone client is `phone.html` + `phone.js` in static dir. D-15: Wake Lock active after `player-ready`. D-19: heartbeat via WT every 5s.

### Client Source Files
- `client/dist/phone.js` — Plain JS phone client (Phase 5 migrates this to `phone.ts` with Vite). Contains: permission gate, WT signaling, WebRTC fan-out, Wake Lock, heartbeat. Sensor pipeline hooks in here.
- `client/dist/room.js` — Desktop SPA (Phase 5 migrates to `room.ts` with Vite).
- `client/dist/phone.html` — Phone HTML shell. Phase 5 adds calibration view (hold-still scene) before controller screen.

### Deployment Config
- `docker-compose.yml` — nginx static file server. Phase 5 changes served files from `dist/` (plain JS) to Vite build output. No other nginx changes needed.

### External Library Docs
- `ahrs` npm (psiphi75/ahrs) — Madgwick + Mahony. Use Madgwick (D-05). Read npm README for constructor params (`sampleInterval`, `beta`).
- `msgpackr` npm (kriszyp/msgpackr) — Binary encoding. Array format via `pack([...])`. Review record extension for optional further compression.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `client/dist/phone.js` — `signalSend()`, transport state, `peerConnections` Map, `heartbeatInterval` — all carry forward unchanged. Sensor pipeline slots in alongside existing WebRTC code.
- `client/dist/phone.html` — Six-view shell already exists (loading, permission, calibrating, connecting, connected, error). Phase 5 activates the `#view-calibrating` view for hold-still scene; `#view-connected` gets dev overlay and motion indicator.
- `client/dist/room.js` — 793-line desktop SPA. Phase 5 migrates to TypeScript but adds no new desktop sensor code (that's Phase 6).

### Established Patterns
- Plain `var` + `'use strict'` in current phone.js — migration to TypeScript replaces with `const`/`let` and proper types.
- `tokio::spawn` per connection / `Arc<T>` threading in Rust server — unchanged in Phase 5.
- `tracing::warn!` / `tracing::info!` for all server events — unchanged.
- `import.meta.env.DEV` (Vite) — standard pattern for dev-only code blocks.

### Integration Points
- Sensor pipeline activates **after** `player-ready` fires (Phase 4 D-09). ZUPT calibration scene runs in this window.
- Sensor packets go over existing WebRTC data channel (`dc` in `peerConnections` Map, already `{ ordered: false, maxRetransmits: 0 }`).
- Desktop side (Phase 6) will read packets from the data channel `onmessage` handler — schema v1 layout (D-14) must be documented for Phase 6 planner.

</code_context>

<specifics>
## Specific Ideas

- **Dual pipeline comparison as evaluation** — OS-fused vs Madgwick run in parallel with live overlay. Phase 5 is the evaluation phase; Phase 6 planning locks which source wins based on real-device data.
- **Calibration scene as onboarding** — hold-still step is UX, not just engineering. Simple instruction + countdown bar. Auto-advances; user has no choices to make.
- **Touch as coordinate stream, not gesture events** — raw (x, y) at 60Hz; game derives swipe/long-press from trajectory. Maximum game flexibility, zero phone-side classification logic.
- **Dev tuning in dev-mode only** — `import.meta.env.DEV` gates overlay and URL params. Production build has zero tuning surface for players.
- **ZUPT = background correction, not latency source** — 300ms stillness window fires after natural movement pause. Explained and confirmed: no live path impact.

</specifics>

<deferred>
## Deferred Ideas

- **Full guided calibration (rotate + flick steps)** — Phase 8 or SDK phase. Phase 5 hold-still covers highest-value case.
- **2+ touch points** — Schema version bump in a future phase when a game needs pinch or two-finger swipe. Schema v1 carries 1 touch point; version byte (D-11) enables expansion.
- **Mahony filter option** — Deferred. Madgwick locked for Phase 5 (D-05). Mahony re-evaluated if CPU becomes a bottleneck on low-end Android.
- **Touch UI on phone (virtual buttons, D-pad)** — Out of platform scope per REQUIREMENTS.md. Platform provides raw IMU + coordinates; game adds custom UI.

</deferred>

---

*Phase: 5-Sensor Fusion and Packet Encoding*
*Context gathered: 2026-07-09*
