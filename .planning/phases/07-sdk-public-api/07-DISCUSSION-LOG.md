# Phase 7: SDK Public API - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-07-16
**Phase:** 7-SDK Public API
**Areas discussed:** SDK extraction boundary / UI scope, Package layout & distribution, Orientation interpolation ownership, Event API design, Latency overlay implementation

---

## SDK Extraction Boundary / UI Scope

| Option | Description | Selected |
|--------|-------------|----------|
| SDK is headless | No DOM/UI at all — connect()/joinRoom() + getPlayerInput()/events only; each game builds its own lobby/QR/pairing screen | ✓ |
| SDK ships pairing UI as opt-in widget | Mountable lobby/QR-pairing component (platform.mountLobby(el)) | |

**User's choice:** SDK is headless.
**Notes:** User's opening clarification — "Each game should have its own rules and threejs env" — reframed the entire phase before this question was even fully asked. This established that no Three.js scene/mesh/rules and no pairing UI live inside the SDK.

---

## Package Layout & Distribution

### Where does the package live?

| Option | Description | Selected |
|--------|-------------|----------|
| npm workspace: packages/immersive-rt/ | Root package.json with workspaces field, mirrors Cargo workspace pattern | ✓ |
| sdk/ at repo root | Same workspace mechanics, different folder name | |
| In-place inside client/src/sdk/ | No monorepo changes, simpler short-term | |

**User's choice:** npm workspace: packages/immersive-rt/

### Build tooling

| Option | Description | Selected |
|--------|-------------|----------|
| Vite library mode | Reuses existing Vite 8.1.4 toolchain | ✓ |
| tsup | Purpose-built for TS libraries, new dependency | |

**User's choice:** Vite library mode

### Module format

| Option | Description | Selected |
|--------|-------------|----------|
| ESM only | Matches client/'s "type": "module" and Three.js r185 | ✓ |
| ESM + CJS dual build | Broader compatibility, more build complexity | |

**User's choice:** ESM only

### Extraction strategy for existing client/src/ logic

| Option | Description | Selected |
|--------|-------------|----------|
| Full extraction into packages/immersive-rt/src/ | Transport, decode, store, event bus move into the package; client/ becomes a consumer | ✓ |
| Thin wrapper, defer full migration | Package re-exports client/src/ modules for now | |

**User's choice:** Full extraction into packages/immersive-rt/src/

### three.js dependency

| Option | Description | Selected |
|--------|-------------|----------|
| Zero-dependency, no `three` import | Hand-written SLERP over plain objects, matches playerStore.ts pattern | ✓ |
| Depend on `three` for the math | Import THREE.Quaternion internally, convert at boundary | |

**User's choice:** Zero-dependency, no `three` import

**Notes:** Confirmed after discussing that playerStore.ts already avoids THREE types by design, and this extends naturally from D-01's "each game has its own env" boundary.

---

## Orientation Interpolation Ownership

### Tick model

| Option | Description | Selected |
|--------|-------------|----------|
| SDK runs its own internal rAF/setInterval tick | Advances smoothed quaternion independent of consumer render loop | ✓ |
| Interpolate lazily on getPlayerInput() call | No background work, but inconsistent within a frame | |

**User's choice:** SDK runs its own internal tick

### SLERP alpha configurability

| Option | Description | Selected |
|--------|-------------|----------|
| Configurable per-connect() call, global default | connect({ slerpAlpha: 0.3 }), defaults to current 0.5 | ✓ |
| Fixed at 0.5, not configurable this phase | Deferred again | |

**User's choice:** Configurable per-connect() call, global default

### Interpolation scope (orientation-only vs. also position)

| Option | Description | Selected |
|--------|-------------|----------|
| Orientation only | SLERP smooths quaternion jitter only; gestureDisplacement/deadReckoningPosition pass through raw | ✓ |
| Interpolate orientation + position (lerp) | Smooth all fields for visual consistency | |

**User's choice:** Orientation only.
**Notes:** User asked "Why do you wanna apply only on orientation?" before deciding. Claude explained: (1) current scene.ts behavior already only SLERPs the mesh quaternion, (2) gestureDisplacement is a trigger signal meant to snap to zero after a gesture window — smoothing would blunt Phase 8's flick-launch trigger, (3) deadReckoningPosition is drift-prone/reset-driven (ZUPT/ARKit recenter/R-key reset are meant to be visible corrections), (4) orientation jitter is a pure network artifact, the classic interpolation use case. User confirmed this reasoning matched their thinking.

### Packet-gap behavior

| Option | Description | Selected |
|--------|-------------|----------|
| Hold at last interpolated value | No extrapolation, matches freeze-on-loss convention elsewhere in project | ✓ |
| Extrapolate using last angular velocity | Smoother during brief drops, risk of wrong guesses | |

**User's choice:** Hold at last interpolated value

---

## Event API Design

### Event mechanism

| Option | Description | Selected |
|--------|-------------|----------|
| Native EventTarget | Zero dependencies, built into JS runtimes | ✓ |
| Node-style EventEmitter (via mitt) | Familiar API, small new dependency | |

**User's choice:** Native EventTarget

### imuUpdate payload shape

| Option | Description | Selected |
|--------|-------------|----------|
| (playerId, data) matching getPlayerInput() shape | One mental model whether polling or subscribing | ✓ |
| Thinner delta payload | Smaller payload, second shape to learn | |

**User's choice:** (playerId, data) matching getPlayerInput() shape

### imuUpdate fire rate

| Option | Description | Selected |
|--------|-------------|----------|
| On every internal interpolation tick | Same cadence as smoothed orientation updates, ~once per rendered frame | ✓ |
| On every raw packet received | Rawest timing but irregular, duplicates getRawInput() | |

**User's choice:** On every internal interpolation tick

### Lifecycle event payload (playerJoin/playerLeave/playerReconnect)

| Option | Description | Selected |
|--------|-------------|----------|
| Just playerId | Matches roadmap's literal signature | ✓ |
| playerId + metadata (username, slot) | Saves a lookup, diverges from roadmap signature | |

**User's choice:** Just playerId

---

## Latency Overlay Implementation

### Overlay API shape

| Option | Description | Selected |
|--------|-------------|----------|
| platform.attachLatencyOverlay(container?) | One method call renders a DOM overlay; the one deliberate UI exception | ✓ |
| Standalone <latency-overlay> web component | New pattern not used elsewhere in codebase | |

**User's choice:** platform.attachLatencyOverlay(container?)

### Metrics source

| Option | Description | Selected |
|--------|-------------|----------|
| SDK computes internally from existing signals (getStats() + timestamp) | No wire schema changes | ✓ (after follow-up) |
| Needs new wire-level tracking added to the packet schema | Touches 36-byte schema shared by web + iOS native encoders | (initially selected, reconsidered) |

**User's choice:** RTCPeerConnection.getStats() + existing packet timestamp — no wire schema changes.
**Notes:** User initially selected "needs new wire-level tracking." Claude flagged that this would touch a wire schema shared across two platforms (client/src/sensor/encode.ts AND mobile/ios-app/immersiveRT/Sensor/SensorPacketEncoder.swift, both locked at 36 bytes since Phase 5) and pointed out that `RTCPeerConnection.getStats()` already exposes jitter/packetsLost/roundTripTime at the WebRTC transport level without any wire changes, combined with the packet's existing `timestamp` field for phone→render latency. Asked whether there was a specific metric getStats() + timestamp couldn't cover; user confirmed no such gap and selected the no-schema-change option.

---

## Claude's Discretion

- Exact internal SLERP function implementation (~15 lines, standard quaternion SLERP over plain objects).
- Exact EventTarget wrapping approach (subclass vs. internal instance + facade methods).
- Whether scene.ts's existing debug/precision-eval Three.js code is deleted from client/ or repurposed as a dev harness this phase.
- Exact internal tick fallback logic (requestAnimationFrame feature-detection).
- getRawInput(playerId).orientationRaw implementation details.

## Deferred Ideas

None — discussion stayed within phase scope. Game-specific concerns (Three.js scene, meshes, gesture-launch visuals, multi-desktop sync) remain correctly out of scope per the headless-SDK decision and belong to Phase 8, as already noted in Phase 6's CONTEXT.md deferred section.
