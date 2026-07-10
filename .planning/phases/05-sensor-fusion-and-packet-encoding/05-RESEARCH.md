# Phase 05: Sensor Fusion and Packet Encoding — Research

**Researched:** 2026-07-09
**Domain:** Browser IMU sensor fusion, Vite/TypeScript migration, binary packet encoding
**Confidence:** MEDIUM

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Build Tooling and TypeScript Migration**
- **D-01:** Add **Vite build step** to the client. `client/` gets `package.json` + `vite.config.ts`. Both `phone.ts` (was `phone.js`) and `room.ts` (was `room.js`) are migrated to TypeScript and bundled via Vite to `dist/`. Unlocks npm ecosystem for `ahrs`, `msgpackr`, and future packages (Phase 6 Three.js, Phase 7 SDK).
- **D-02:** Migrate **both** `phone.js` and `room.js` to TypeScript in Phase 5 — one migration instead of two. Sensor types (`Quaternion`, `Vector3`, `SensorPacket`) defined once and shared; Phase 7 SDK inherits typed consumers.

**Orientation Pipeline**
- **D-03:** Run **both** orientation pipelines in parallel throughout Phase 5:
  - **Primary:** `DeviceOrientationEvent` (OS-fused) → α/β/γ converted to quaternion. Drift-free on modern devices.
  - **Secondary:** `DeviceMotionEvent` (raw IMU) → **Madgwick filter** via `ahrs` npm package → quaternion.
  - A dev overlay on the phone screen shows both quaternions live during testing. Real-device comparison determines which is better for Phase 6+.
- **D-04:** **OS-fused quaternion feeds the actual sensor packet by default.** URL param `?orient=madgwick` switches to Madgwick output. URL params are **dev-mode only** (`import.meta.env.DEV`) — Vite dead-code eliminates them from production bundle. Players cannot access params.
- **D-05:** Custom filter is **Madgwick** (not Mahony). Reliability over CPU savings — better magnetometer fusion, more reliable absolute heading. Mahony is 10–15% faster but drifts more on yaw; not worth the accuracy tradeoff.

**ZUPT and Dead-Reckoning**
- **D-06:** ZUPT fires **after** 300ms of detected stillness — it does not add latency to the live sensor stream. Packets flow at 60Hz uninterrupted; ZUPT is a background correction that resets velocity to 0 and raises `driftConfidence` to 1.0 during natural movement pauses.
- **D-07:** Position is dead-reckoning via Kalman filter. `driftConfidence` scalar (0–1) included in every packet. API uses `deadReckoningPosition` naming (never bare `position`) to make drift nature explicit.

**Calibration**
- **D-08:** **Basic hold-still calibration scene** runs once at session start (after `player-ready`, before sensor loop begins). Phone shows: `"Hold your phone still on a flat surface"` + 3-second countdown bar. During hold: phone measures accelerometer variance → auto-sets ZUPT threshold and initial Kalman noise params for that device's specific sensor characteristics. On complete: auto-advances to controller screen.
- **D-09:** Full guided calibration (rotate + flick steps) deferred to Phase 8 / SDK phase when demo game needs it. Phase 5 hold-still step covers highest-value case (ZUPT tuning for device noise floor).

**Packet Schema**
- **D-10:** **Array (positional) format** — no field names on wire. Smallest payload. Decode side must know schema version (enforced via version byte). Matches msgpackr record extension pattern for further compression.
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

**Dev Overlay**
- **D-15:** Dev overlay (dev-mode only, Vite dead-code eliminated in production) shows on phone screen: OS quaternion vs Madgwick quaternion (live), active filter param values, ZUPT fired/not indicator, drift confidence, packet Hz. Auto-hidden in production builds — players see nothing.

### Claude's Discretion
- Float16 encode/decode implementation (bit manipulation pattern — use a well-known reference implementation, not custom).
- Madgwick beta ramp logic at cold start (SENS-02): start at 0.2–0.3, ramp to 0.1 after convergence — implementation details.
- Kalman filter process/measurement noise defaults — empirically tuned during Phase 5 testing.
- Gesture displacement window gating (SENS-05): ZUPT-gated per-action delta — implementation details.
- msgpackr record extension usage for further compression (optional optimization if base encoding exceeds target).

### Deferred Ideas (OUT OF SCOPE)
- **Full guided calibration (rotate + flick steps)** — Phase 8 or SDK phase. Phase 5 hold-still covers highest-value case.
- **2+ touch points** — Schema version bump in a future phase when a game needs pinch or two-finger swipe. Schema v1 carries 1 touch point; version byte (D-11) enables expansion.
- **Mahony filter option** — Deferred. Madgwick locked for Phase 5 (D-05). Mahony re-evaluated if CPU becomes a bottleneck on low-end Android.
- **Touch UI on phone (virtual buttons, D-pad)** — Out of platform scope per REQUIREMENTS.md. Platform provides raw IMU + coordinates; game adds custom UI.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| SENS-01 | Phone runs Madgwick filter on-device to produce stable orientation quaternion from gyroscope + accelerometer + magnetometer — drift-free | ahrs npm package: `new AHRS({ sampleInterval: 60, algorithm: 'Madgwick', beta: 0.1 })`. Unit conversions critical: rotationRate deg/s → rad/s, acceleration m/s² → g |
| SENS-02 | Madgwick beta parameter is runtime-configurable; defaults to 0.1, ramps to 0.2–0.3 at cold start, ramps back down after convergence | ahrs constructor accepts `beta` param. Ramp implemented by mutating `ahrs.beta` over time; convergence detected when quaternion delta < threshold |
| SENS-03 | Phone runs ZUPT with adaptive variance + 300ms duration threshold — detects stationary moments and resets velocity accumulator | Sliding-window variance of accel magnitude. Adaptive threshold set during hold-still calibration. No library needed: ~25 lines |
| SENS-04 | Phone runs Kalman filter over linear acceleration to produce dead-reckoning position estimate with `driftConfidence` scalar (0–1) | 1D Kalman per axis on `event.acceleration` (linear, no gravity). ZUPT triggers velocity reset. Confidence decays with time since last ZUPT. ~30 lines |
| SENS-05 | Gesture displacement: ZUPT gates a per-action position delta window — each swing/throw/flick produces a discrete `gestureDisplacement` vector reset between actions | Position delta since last ZUPT reset. Non-zero only during active movement. Reset to [0,0,0] when ZUPT fires |
| SENS-06 | Touch input: phone captures tap events and configurable on-screen button states, included in each sensor packet | `touchstart`/`touchend` → raw normalized coordinates. Stored in module state; included in every packet. No gesture classification on phone |
| PHONE-04 | Phone sends sensor packets at maximum available device rate (~60–100Hz) over the unreliable data channel | `devicemotion` fires at OS rate (60Hz iOS, up to 100Hz Android). `dc.send(uint8Array)` in event handler. 36-byte packet well under 16KB data channel safe limit |
| PHONE-05 | Phone encodes each sensor packet as compact binary (~40 bytes) using MessagePack | **Critical finding:** msgpackr `pack([...])` adds ~2–5 bytes per field overhead; cannot fit float16 natively in MessagePack (no float16 type). Achieving 36-byte target requires **raw DataView binary encoding**, not msgpackr.pack(). See Architecture Patterns. |
</phase_requirements>

---

## Summary

Phase 5 has three parallel workstreams that must coordinate: (1) Vite/TypeScript migration of the client build system, (2) browser IMU sensor pipeline implementation on the phone client, and (3) binary packet encoding for the WebRTC data channel.

The **Vite migration** restructures `client/` from a flat `dist/` folder of static files to a proper source tree with `src/phone.ts`, `src/room.ts`, and an `npm run build` step that outputs to `dist/`. Vite natively understands TypeScript — no Babel or ts-loader needed. Multi-page mode uses `build.rollupOptions.input` with both HTML files as entry points. The docker-compose nginx volume (`./client/dist`) is unchanged.

The **sensor pipeline** has two quaternion paths running in parallel: OS-fused quaternion from DeviceOrientationEvent (Z-X-Y Euler → quaternion via W3C spec formula) and Madgwick quaternion from the `ahrs` npm package fed raw DeviceMotionEvent data. The OS-fused path feeds the actual packet by default; Madgwick feeds a dev overlay comparison. ZUPT uses a 300ms sliding-window variance of accelerometer magnitude — when variance falls below an adaptive threshold (set during hold-still calibration), velocity resets to zero and `driftConfidence` rises to 1.0. A 1D Kalman filter per axis accumulates linear acceleration into position; ZUPT events reset the velocity state.

The **packet encoding** is a critical finding: the 36-byte target (D-14) requires **raw DataView binary encoding**, not msgpackr `pack([])`. MessagePack has no float16 type and its per-value framing overhead (~2–5 bytes/value) would push the packet to ~60–70 bytes. The DataView approach writes fixed-offset fields directly, achieving exactly 36 bytes. Float16 encoding uses the `@petamoriken/float16` ponyfill (2.1M weekly downloads, Baseline 2025, OK legitimacy verdict), which provides `setFloat16`/`getFloat16` for DataView and works down to ES2015 for older iOS devices.

**Primary recommendation:** Build the 36-byte packet as a fixed-layout ArrayBuffer using DataView + `@petamoriken/float16` for float16 fields. Use Vite multi-page build with TypeScript strict mode. Keep `ahrs` for the secondary Madgwick pipeline (SUS verdict but CLAUDE.md approved). Implement ZUPT and 1D Kalman as small inline classes — no library needed.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Build system (Vite/TS) | Build tool (CI/dev only) | — | No runtime tier; outputs to `dist/` served by nginx |
| OS-fused orientation quaternion | Browser (phone) | — | DeviceOrientationEvent lives in browser; conversion is math in-process |
| Madgwick secondary pipeline | Browser (phone) | — | ahrs runs on device; dev comparison only, no server involvement |
| ZUPT detection | Browser (phone) | — | Requires raw sensor samples; 60Hz detection loop |
| Kalman dead-reckoning position | Browser (phone) | — | Integrates linear acceleration in-process |
| Calibration scene (hold-still) | Browser (phone) UI | — | Activates existing `#view-calibrating` view; no server call |
| Binary packet encoding (DataView) | Browser (phone) | — | Runs in `devicemotion` handler before `dc.send()` |
| Touch coordinate capture | Browser (phone) | — | `touchstart`/`touchmove`/`touchend` listeners on phone screen |
| Dev overlay | Browser (phone) dev-only | — | `import.meta.env.DEV` gated; dead-code eliminated in production |
| WebRTC data channel send | Browser (phone) | — | `dc.send(Uint8Array)` — uses existing data channel from Phase 4 |
| Packet decode (Phase 6) | Browser (desktop) | — | Not implemented in Phase 5 — schema v1 documented here for Phase 6 |
| TypeScript shared types | Build artifact | — | `Quaternion`, `Vector3`, `SensorPacket` types defined in `src/types.ts` |

---

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| vite | 8.1.4 (latest) | Build bundler + dev server | Native ESM, TypeScript without config, multi-page MPA mode, `import.meta.env.DEV` dead-code elimination for dev overlay |
| typescript | 5.x (vite peer) | Type safety for sensor code | Enables `SensorPacket` interface shared between phone + room; Vite processes TS natively |
| ahrs | 1.3.3 (latest) | Madgwick filter on raw DeviceMotionEvent | Only npm package with both Madgwick and Mahony algorithms, browser-compatible, configurable beta — CLAUDE.md approved |
| @petamoriken/float16 | 3.9.3 (latest) | float16 read/write on DataView | Ponyfill for DataView.getFloat16/setFloat16; works down to ES2015 (covers iOS pre-18.2); 2.1M weekly downloads; OK legitimacy verdict |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| msgpackr | 2.0.4 (latest) | MessagePack binary codec | Available for future signaling messages or schema v2+ if hot-path encoding is revisited; NOT used for Phase 5 sensor packets (see Don't Hand-Roll) |
| vitest | 3.x (vite peer) | Unit test runner | Co-located with Vite config; tests float16 round-trip, quaternion math, ZUPT logic, packet byte count |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| @petamoriken/float16 | Manual IEEE 754 bit math | Bit-math is ~15 lines but error-prone; ponyfill tested against spec, well-maintained, zero dependencies |
| @petamoriken/float16 | Native DataView.setFloat16 | Native requires Chrome 135+, iOS Safari 18.2+; ponyfill covers older devices too |
| Raw DataView encoding | msgpackr.pack([...]) | msgpackr cannot represent float16 natively; each float32 costs 5 bytes in MessagePack vs 2 in DataView; impossible to meet 45-byte target with msgpackr |
| ahrs Madgwick | Custom Madgwick implementation | ahrs is battle-tested; custom impl error-prone for quaternion normalization and numerical stability |
| Vite | esbuild / webpack | Vite has first-class MPA + `import.meta.env.DEV` + TS; project complexity doesn't warrant raw esbuild |

**Installation:**
```bash
# In client/
npm install --save-dev vite typescript vitest
npm install ahrs @petamoriken/float16
# msgpackr optional for future phases:
# npm install msgpackr
```

**Version verification:** [VERIFIED: npm registry]
```
ahrs:                   1.3.3   (2023-10-28)
msgpackr:               2.0.4   (2026-06-09)
vite:                   8.1.4   (2026-07-09)
@petamoriken/float16:   3.9.3   (2025-10-10)
```

---

## Package Legitimacy Audit

| Package | Registry | Age | Downloads | Source Repo | Verdict | Disposition |
|---------|----------|-----|-----------|-------------|---------|-------------|
| ahrs | npm | 2.8 yrs | 337/wk | github.com/psiphi75/ahrs | SUS | **Approved** — CLAUDE.md explicitly recommends this package as the only npm package with both Madgwick and Mahony algorithms; no postinstall script; planner must add `checkpoint:human-verify` task before install |
| msgpackr | npm | ~5 yrs | 26.5M/wk | github.com/kriszyp/msgpackr | OK | Approved |
| vite | npm | ~5 yrs | 147M/wk | github.com/vitejs/vite | SUS* | **Approved** — *"too-new" flag is false positive: 147M weekly downloads, published new version on 2026-07-09 (same day); major well-known build tool |
| @petamoriken/float16 | npm | ~0.8 yrs | 2.1M/wk | github.com/petamoriken/float16 | OK | Approved |

**Packages removed due to [SLOP] verdict:** none

**Packages flagged as suspicious [SUS]:**
- `ahrs` — low downloads (337/wk). CLAUDE.md confirms this is the correct package for this use case. Planner must add `checkpoint:human-verify` task before `npm install ahrs`.
- `vite` — false positive "too-new" (published new version same day as research). Do not gate; proceed normally.

---

## Architecture Patterns

### System Architecture Diagram

```
DeviceMotionEvent                       DeviceOrientationEvent
(raw gyro/accel/gravity)                (OS sensor fusion output)
         │                                        │
         ▼                                        ▼
   [Unit convert]                     [α/β/γ → Quaternion]
  deg/s→rad/s, m/s²→g               (W3C Z-X-Y Euler formula)
         │                                        │
         ▼                                        │
  [ahrs Madgwick]                                │ (primary)
  (secondary/dev)                                │
         │                                        │
         ├──── DEV OVERLAY ◄───────────────────────┤
         │     (both quats live,                   │
         │      ZUPT state, Hz)                    │
         │                                        │
         │         ┌──────── ZUPT (300ms window) ──┤
         │         │         accel variance < T   │
         │         ▼                              │
         │   velocity = 0, driftConfidence = 1.0  │
         │         │                              │
         │         ▼                              │
         │   [1D Kalman per axis]                  │
         │   accel→velocity→position              │
         │         │                              │
         ▼         ▼                              ▼
  ┌──────────── SensorPacket Builder ────────────────┐
  │  version=1, seq++, ts, quaternion,               │
  │  gestureDisplacement, deadReckoningPosition,     │
  │  driftConfidence, touchActive, touchX, touchY    │
  └──────────────────────┬───────────────────────────┘
                         │
                         ▼
              [DataView binary encode]
             (@petamoriken/float16 for float16 fields)
                         │
                         ▼
              Uint8Array(36 bytes)
                         │
                         ▼
              dc.send(uint8Array)          ← unreliable WebRTC data channel
              (for each peer in peerConnections)
```

### Recommended Project Structure

```
client/
├── package.json          # NEW: npm project manifest
├── tsconfig.json         # NEW: TypeScript config (strict, target ES2020)
├── vite.config.ts        # NEW: Vite multi-page config
├── phone.html            # MOVED from dist/ — Vite entry (module script tag)
├── index.html            # MOVED from dist/ — Vite entry for room
├── src/
│   ├── types.ts          # NEW: Quaternion, Vector3, SensorPacket interfaces
│   ├── phone.ts          # MIGRATED from dist/phone.js + Phase 5 sensor pipeline
│   ├── room.ts           # MIGRATED from dist/room.js
│   ├── sensor/
│   │   ├── orientation.ts  # NEW: OS-fused euler→quat + Madgwick pipeline
│   │   ├── zupt.ts         # NEW: ZUPTDetector class
│   │   ├── kalman.ts       # NEW: Kalman1D class
│   │   └── encode.ts       # NEW: encodePacket() → Uint8Array(36)
│   └── ui/
│       └── devOverlay.ts   # NEW: Dev overlay (import.meta.env.DEV gated)
├── dist/                 # VITE BUILD OUTPUT — served by nginx (unchanged volume)
│   ├── phone.html
│   ├── index.html
│   └── assets/
│       ├── phone-[hash].js
│       └── room-[hash].js
└── tests/
    ├── encode.test.ts    # Packet byte count, float16 round-trip
    ├── orientation.test.ts # Quaternion conversion correctness
    └── zupt.test.ts      # ZUPT triggering logic
```

### Pattern 1: Vite Multi-Page Configuration

**What:** Two HTML entry points (phone.html and index.html) produce two separate JS bundles in `dist/`.
**When to use:** Any project with multiple distinct page-level entry points.

```typescript
// client/vite.config.ts
// Source: https://vite.dev/guide/build#multi-page-app [CITED: vite.dev/guide/build]
import { defineConfig } from 'vite'
import { resolve } from 'path'

export default defineConfig({
  root: __dirname,
  build: {
    outDir: 'dist',
    rollupOptions: {
      input: {
        phone: resolve(__dirname, 'phone.html'),
        room: resolve(__dirname, 'index.html'),
      },
    },
  },
  test: {
    environment: 'jsdom',
  },
})
```

HTML entry script tag for phone.html:
```html
<!-- phone.html — replaces <script src="/phone.js" defer> -->
<script type="module" src="./src/phone.ts"></script>
```

### Pattern 2: OS-Fused Quaternion (Primary Path)

**What:** Convert DeviceOrientationEvent α/β/γ (Z-X-Y Euler) to quaternion [w, x, y, z].
**When to use:** Default packet quaternion source. OS does magnetometer fusion — don't run Madgwick on top of it.

```typescript
// Source: W3C DeviceOrientation Event Specification (Z-X-Y rotation order)
// [CITED: https://www.w3.org/TR/orientation-event/]
const DEG_TO_RAD = Math.PI / 180;

export function eulerToQuat(alpha: number, beta: number, gamma: number): Quaternion {
  const _x = beta  * DEG_TO_RAD;  // pitch
  const _y = gamma * DEG_TO_RAD;  // roll
  const _z = alpha * DEG_TO_RAD;  // yaw

  const cX = Math.cos(_x / 2), sX = Math.sin(_x / 2);
  const cY = Math.cos(_y / 2), sY = Math.sin(_y / 2);
  const cZ = Math.cos(_z / 2), sZ = Math.sin(_z / 2);

  return {
    w: cX * cY * cZ - sX * sY * sZ,
    x: sX * cY * cZ - cX * sY * sZ,
    y: cX * sY * cZ + sX * cY * sZ,
    z: cX * cY * sZ + sX * sY * cZ,
  };
}
```

### Pattern 3: Madgwick Filter via ahrs (Secondary/Dev Path)

**What:** Feed raw DeviceMotionEvent data into the Madgwick filter. Used for dev comparison only.
**When to use:** Runs in parallel with OS-fused path when D-03 dual pipeline is active.

```typescript
// Source: https://github.com/psiphi75/ahrs [CITED: github.com/psiphi75/ahrs]
import AHRS from 'ahrs';

const ahrs = new AHRS({
  sampleInterval: 60,       // Hz — iOS max is 60; Android can be up to 100
  algorithm: 'Madgwick',
  beta: 0.3,                // Start high (0.2–0.3) at cold start; ramp to 0.1 after convergence
});

window.addEventListener('devicemotion', (e: DeviceMotionEvent) => {
  const rr = e.rotationRate;
  const a  = e.accelerationIncludingGravity; // includes gravity for sensor fusion
  if (!rr || !a) return;

  // CRITICAL unit conversions:
  // rotationRate is in deg/s on both iOS and Android → must convert to rad/s
  // accelerationIncludingGravity is in m/s² → must convert to g (÷ 9.81)
  ahrs.update(
    (rr.alpha ?? 0) * Math.PI / 180,
    (rr.beta  ?? 0) * Math.PI / 180,
    (rr.gamma ?? 0) * Math.PI / 180,
    (a.x ?? 0) / 9.81,
    (a.y ?? 0) / 9.81,
    (a.z ?? 0) / 9.81,
    // No magnetometer (mx, my, mz) — DeviceMotionEvent does not provide it
  );

  const q = ahrs.getQuaternion(); // Returns { x, y, z, w }
  // Note: ahrs getQuaternion() returns { x, y, z, w }; packet schema is [qw, qx, qy, qz]
});
```

### Pattern 4: ZUPT Detector

**What:** Sliding-window variance of accelerometer magnitude. Fires after 300ms of stillness.
**When to use:** Background correction — triggered in `devicemotion` handler alongside main pipeline.

```typescript
// [ASSUMED] — standard algorithm, no specific npm library
export class ZUPTDetector {
  private readonly window: Array<{ v: number; t: number }> = [];
  private readonly windowMs: number;
  public adaptiveThreshold: number; // set during calibration

  constructor(windowMs = 300, threshold = 0.01) {
    this.windowMs = windowMs;
    this.adaptiveThreshold = threshold;
  }

  update(accelMag: number, nowMs: number): boolean {
    this.window.push({ v: accelMag, t: nowMs });
    // Evict samples older than window
    while (this.window.length > 0 && nowMs - this.window[0].t > this.windowMs) {
      this.window.shift();
    }
    if (this.window.length < 5) return false;

    const vals = this.window.map(s => s.v);
    const mean = vals.reduce((a, b) => a + b, 0) / vals.length;
    const variance = vals.reduce((a, v) => a + (v - mean) ** 2, 0) / vals.length;
    return variance < this.adaptiveThreshold;
  }
}
```

### Pattern 5: 1D Kalman Filter for Dead-Reckoning

**What:** Per-axis Kalman filter integrating linear acceleration into position.
**When to use:** Called per `devicemotion` event for each axis (x, y, z separately).

```typescript
// [ASSUMED] — standard algorithm, no specific npm library
export class Kalman1D {
  private pos = 0;    // position estimate (m)
  private vel = 0;    // velocity estimate (m/s)
  private P = 1;      // covariance

  constructor(
    private Q = 0.001,  // process noise — set during calibration
    private R = 0.1,    // measurement noise — set during calibration
  ) {}

  predict(accelMs2: number, dtSec: number): number {
    this.vel += accelMs2 * dtSec;
    this.pos += this.vel * dtSec;
    this.P  += this.Q * dtSec;
    return this.pos;
  }

  // Call when ZUPT fires — velocity is known to be 0
  resetVelocity(): void {
    const K = this.P / (this.P + this.R);
    this.vel = 0;
    this.P  *= (1 - K);
  }

  // driftConfidence: 1.0 immediately after ZUPT, decays with accumulated P
  driftConfidence(): number {
    return Math.max(0, 1 - Math.min(1, this.P));
  }
}
```

### Pattern 6: Packet Encoding (DataView, 36 bytes)

**What:** Encode `SensorPacket` into 36-byte ArrayBuffer using DataView + float16 ponyfill.
**When to use:** Called in `devicemotion` handler before each `dc.send()`.

```typescript
// [ASSUMED] — standard DataView pattern; @petamoriken/float16 ponyfill
// [CITED: https://github.com/petamoriken/float16]
import { setFloat16 } from '@petamoriken/float16';

// Schema v1 byte offsets (from CONTEXT.md D-14)
const SCHEMA_VERSION = 1;
const BUF_SIZE = 36;

export function encodePacket(pkt: SensorPacket, buf: ArrayBuffer): Uint8Array {
  const view = new DataView(buf);
  const le = true; // little-endian throughout

  view.setUint8(0,  SCHEMA_VERSION);
  view.setUint16(1, pkt.seq % 65536, le);
  view.setUint32(3, pkt.timestamp, le);

  // Quaternion (4× float16)
  setFloat16(view, 7,  pkt.qw, le);
  setFloat16(view, 9,  pkt.qx, le);
  setFloat16(view, 11, pkt.qy, le);
  setFloat16(view, 13, pkt.qz, le);

  // Gesture displacement (3× float16)
  setFloat16(view, 15, pkt.dx, le);
  setFloat16(view, 17, pkt.dy, le);
  setFloat16(view, 19, pkt.dz, le);

  // Dead-reckoning position (3× float16)
  setFloat16(view, 21, pkt.px, le);
  setFloat16(view, 23, pkt.py, le);
  setFloat16(view, 25, pkt.pz, le);

  // Drift confidence (float32 — higher precision needed)
  view.setFloat32(27, pkt.driftConfidence, le);

  // Touch
  view.setUint8(31,  pkt.touchActive ? 1 : 0);
  view.setUint16(32, Math.round(pkt.touchX * 65535), le);
  view.setUint16(34, Math.round(pkt.touchY * 65535), le);

  return new Uint8Array(buf);
}

// Allocate once, reuse every packet (avoid GC pressure at 60Hz)
const _packetBuf = new ArrayBuffer(BUF_SIZE);
```

### Pattern 7: Send on Data Channel

```typescript
// Send to all open data channels (same as phase 4 fan-out pattern)
// [CITED: MDN RTCDataChannel.send()]
function broadcastPacket(uint8: Uint8Array): void {
  peerConnections.forEach(({ dc, channelOpen }) => {
    if (channelOpen && dc.readyState === 'open') {
      dc.send(uint8); // dc.send() accepts Uint8Array directly
    }
  });
}
```

### Pattern 8: Gesture Displacement (ZUPT-gated delta)

```typescript
// [ASSUMED] — ZUPT-gated per-action position delta
let gestureOrigin: Vector3 = { x: 0, y: 0, z: 0 };

// When ZUPT fires: capture current position as new gesture origin
function onZUPTFired(currentPos: Vector3): void {
  gestureOrigin = { ...currentPos };
}

// Each packet: displacement = current_pos − gesture_origin
function getGestureDisplacement(currentPos: Vector3): Vector3 {
  return {
    x: currentPos.x - gestureOrigin.x,
    y: currentPos.y - gestureOrigin.y,
    z: currentPos.z - gestureOrigin.z,
  };
}
```

### Pattern 9: Hold-Still Calibration

```typescript
// [ASSUMED] — variance measurement during hold-still scene
export function runCalibration(onComplete: (threshold: number, Q: number) => void): void {
  const samples: number[] = [];
  const DURATION_MS = 3000;
  const startTime = Date.now();

  const handler = (e: DeviceMotionEvent) => {
    const a = e.accelerationIncludingGravity;
    if (!a) return;
    const mag = Math.sqrt((a.x ?? 0) ** 2 + (a.y ?? 0) ** 2 + (a.z ?? 0) ** 2);
    samples.push(mag);

    if (Date.now() - startTime >= DURATION_MS) {
      window.removeEventListener('devicemotion', handler);
      const mean = samples.reduce((a, b) => a + b, 0) / samples.length;
      const variance = samples.reduce((a, v) => a + (v - mean) ** 2, 0) / samples.length;
      // Adaptive threshold: 2× measured noise floor (conservative headroom)
      const zuptThreshold = variance * 2;
      // Process noise Q correlates with measured variance
      const kalmanQ = variance * 0.1;
      onComplete(zuptThreshold, kalmanQ);
    }
  };

  window.addEventListener('devicemotion', handler);
}
```

### Anti-Patterns to Avoid

- **Running Madgwick on OS-fused output:** `DeviceOrientationEvent` already fuses magnetometer at OS level. Running ahrs on α/β/γ values (not raw gyro) adds no accuracy and introduces latency. Feed ahrs only raw `DeviceMotionEvent.rotationRate` + `accelerationIncludingGravity`.
- **Allocating a new ArrayBuffer per packet at 60Hz:** Creates GC pressure. Allocate once (`const _packetBuf = new ArrayBuffer(36)`) and reuse by overwriting fields every frame.
- **Using msgpackr pack([...]) for sensor packets:** MessagePack has no float16 type. Using msgpackr for 13 float fields at 5 bytes/float = 65+ bytes — impossible to hit 45-byte target. Reserve msgpackr for non-hot-path encoding only.
- **Native DataView.setFloat16 without ponyfill:** Requires Chrome 135+, iOS Safari 18.2+. Many phones in the field run older versions. Always use the ponyfill.
- **Putting URL param dev switches outside import.meta.env.DEV guard:** Vite tree-shakes `if (import.meta.env.DEV)` blocks. Without this guard, the URL param check ships to production — a tuning surface for players.
- **Calling ahrs.update() with acceleration in m/s² (not g):** ahrs expects g-force units. Passing m/s² values (9.81× too large) produces wildly incorrect quaternions. Always divide by 9.81.
- **Using integer seq wrapping without modulo:** `seq` is uint16 (max 65535). Without `% 65536`, TypeScript number grows indefinitely. Desktop decoder detects dropped packets via uint16 sequence delta.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| float16 encode/decode | Custom IEEE 754 bit-shift code | `@petamoriken/float16` | Spec-compliant rounding ("round-to-nearest even"); cross-browser; well-tested; zero deps |
| Madgwick sensor filter | Custom quaternion integration | `ahrs` npm package | Numerical stability, beta convergence, quaternion normalization handled correctly |
| Quaternion normalization | Custom | `ahrs.getQuaternion()` already normalizes | Avoids quaternion drift from floating-point accumulation |
| TypeScript build | Custom esbuild config | Vite native TypeScript | Vite handles TS transpilation natively; no config needed for basic usage |
| Dead-reckoning double-integrate | Custom without Kalman | 1D Kalman per axis | Raw double integration diverges quadratically. Kalman + ZUPT is the minimum viable path |

**Key insight:** Float16 encoding and Madgwick filter both have subtle edge cases (denormal floats, quaternion drift, dead-reckoning initialization) where proven libraries save significant debugging time on real hardware.

---

## Common Pitfalls

### Pitfall 1: ahrs unit inputs — rotationRate is deg/s, not rad/s

**What goes wrong:** ahrs.update() receives degrees/second from DeviceMotionEvent.rotationRate. Filter produces wildly incorrect orientation; quaternion flips randomly.
**Why it happens:** DeviceMotionEvent specifies rotationRate in deg/s on all browsers. ahrs expects rad/s.
**How to avoid:** Multiply all rotationRate values by `Math.PI / 180` before passing to ahrs.update().
**Warning signs:** Quaternion components exceed [-1, 1] range; orientation "spins" at rest.

### Pitfall 2: ahrs acceleration units — m/s², not g-force

**What goes wrong:** ahrs.update() receives raw m/s² values (~9.81 at rest). Filter treats these as ~9.81g, producing incorrect tilt compensation.
**Why it happens:** DeviceMotionEvent specifies acceleration in m/s². ahrs expects g-force units.
**How to avoid:** Divide all accelerationIncludingGravity values by 9.81 before passing to ahrs.update().
**Warning signs:** Madgwick quaternion shows constant ~84° tilt pitch error at rest.

### Pitfall 3: DeviceOrientationEvent quaternion uses Z-X-Y rotation order

**What goes wrong:** Using Z-Y-X (aerospace convention) formula instead of Z-X-Y produces wrong orientation mapping.
**Why it happens:** W3C spec explicitly uses Z-X-Y (alpha=yaw around Z, then beta=pitch around X', then gamma=roll around Y''). Different from aerospace or Three.js Euler conventions.
**How to avoid:** Use the exact formula from the W3C DeviceOrientation spec (see Pattern 2 above). Do not use Three.js Euler or other library conversions without verifying rotation order.
**Warning signs:** Roll and pitch axes are swapped during testing.

### Pitfall 4: msgpackr cannot represent float16

**What goes wrong:** Using `msgpackr.pack([qw, qx, qy, qz, ...])` with floating point values encodes each float as 5 bytes (msgpack float32) or 9 bytes (float64). Total packet grows to 60–70 bytes, exceeding the 45-byte target.
**Why it happens:** MessagePack specification has no float16 type. msgpackr encodes JavaScript floats as float32 or float64.
**How to avoid:** Use raw DataView binary encoding for sensor packets. Reserve msgpackr for signaling (non-hot-path) if needed.
**Warning signs:** Packet byte count log shows 60+ bytes instead of ~36.

### Pitfall 5: Allocating ArrayBuffer per 60Hz tick causes GC jitter

**What goes wrong:** `new ArrayBuffer(36)` in the `devicemotion` handler allocates 3,600 short-lived objects per minute. GC pauses cause dropped sensor frames and irregular Hz.
**Why it happens:** JavaScript GC collects short-lived heap allocations; at 60Hz the allocation rate overwhelms minor GC.
**How to avoid:** Allocate `const _packetBuf = new ArrayBuffer(36)` once at module scope. Reuse by overwriting DataView fields every frame.
**Warning signs:** Packet Hz drops from 60 to ~45–50 intermittently; Chrome DevTools heap shows many 36-byte collections.

### Pitfall 6: ZUPT threshold calibrated from device with accelerometer bias

**What goes wrong:** Calibration measurement includes sensor DC bias (constant offset), making the variance threshold too small. Device later triggers false ZUPT during slow movement.
**Why it happens:** Accelerometer bias is device-specific and not normalized by DeviceMotionEvent.
**How to avoid:** Measure variance of accel MAGNITUDE (not individual axes) — magnitude is more robust to static bias. Use 2× measured variance as threshold (conservative headroom). Madgwick warm-up should complete before calibration begins.
**Warning signs:** driftConfidence stays near 1.0 even during movement; velocity never accumulates.

### Pitfall 7: Vite MPA — HTML output respects source filename, not rollupOptions key

**What goes wrong:** In Vite MPA mode, the output HTML filename mirrors the source HTML filename, not the key in `rollupOptions.input`. Setting key to `'phoneApp'` does not change `phone.html` → `dist/phoneApp.html`; it stays `dist/phone.html`.
**Why it happens:** Vite resolves HTML entry paths and preserves relative directory structure in output.
**How to avoid:** Name source HTML files exactly as you want them served: `phone.html` → `dist/phone.html`, `index.html` → `dist/index.html`. No renaming magic needed.

### Pitfall 8: import.meta.env.DEV check does not apply to runtime URL params unless wrapped

**What goes wrong:** `new URLSearchParams(location.search).get('orient')` compiles into production bundle even when behind `if (import.meta.env.DEV)`, because the condition is evaluated at runtime not build time in some configurations.
**Why it happens:** Vite replaces `import.meta.env.DEV` with `true` in dev and `false` in prod; a nested ternary or class property may not be tree-shaken properly.
**How to avoid:** Put the entire URL-param-dependent block — including variable declarations — inside `if (import.meta.env.DEV) { ... }`. Verify production bundle with `grep 'orient' dist/assets/phone-*.js` returns nothing.

---

## Code Examples

### Sensor pipeline entry point in phone.ts

```typescript
// [ASSUMED] — integration of the above patterns
let sessionStart: number;
let seq = 0;
const _packetBuf = new ArrayBuffer(36);

function startSensorPipeline(zuptThreshold: number, kalmanQ: number): void {
  sessionStart = Date.now();
  const kalmans = [new Kalman1D(kalmanQ), new Kalman1D(kalmanQ), new Kalman1D(kalmanQ)];
  const zupt = new ZUPTDetector(300, zuptThreshold);
  let gestureOrigin: Vector3 = { x: 0, y: 0, z: 0 };
  let lastTs = performance.now();

  window.addEventListener('deviceorientation', (e) => {
    // Primary quaternion
    primaryQuat = eulerToQuat(e.alpha ?? 0, e.beta ?? 0, e.gamma ?? 0);
  });

  window.addEventListener('devicemotion', (e) => {
    const now = performance.now();
    const dtSec = (now - lastTs) / 1000;
    lastTs = now;

    // Raw linear acceleration for dead-reckoning
    const la = e.acceleration;
    const accelX = la?.x ?? 0;
    const accelY = la?.y ?? 0;
    const accelZ = la?.z ?? 0;

    // ZUPT check on total magnitude
    const ag = e.accelerationIncludingGravity;
    const mag = Math.sqrt((ag?.x ?? 0) ** 2 + (ag?.y ?? 0) ** 2 + (ag?.z ?? 0) ** 2);
    const isStill = zupt.update(mag, Date.now());

    // Kalman integration per axis
    const px = kalmans[0].predict(accelX, dtSec);
    const py = kalmans[1].predict(accelY, dtSec);
    const pz = kalmans[2].predict(accelZ, dtSec);

    if (isStill) {
      kalmans.forEach(k => k.resetVelocity());
      gestureOrigin = { x: px, y: py, z: pz };
    }

    // Build and send packet
    const pkt: SensorPacket = {
      seq: seq++,
      timestamp: Date.now() - sessionStart,
      qw: primaryQuat.w, qx: primaryQuat.x, qy: primaryQuat.y, qz: primaryQuat.z,
      dx: px - gestureOrigin.x,
      dy: py - gestureOrigin.y,
      dz: pz - gestureOrigin.z,
      px, py, pz,
      driftConfidence: kalmans[0].driftConfidence(),
      touchActive: currentTouch.active,
      touchX: currentTouch.x,
      touchY: currentTouch.y,
    };

    broadcastPacket(encodePacket(pkt, _packetBuf));
  });
}
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Manual IEEE 754 bit math for float16 | `@petamoriken/float16` ponyfill | ES2025 shipped Float16Array (Chrome 135, Firefox 129, Safari 18.2 — April 2025) | Reliable across all target devices including older iOS |
| JSON encoding for binary sensor data | Raw DataView binary at fixed byte offsets | N/A for this project — use DataView from the start | 3–10× smaller packets vs JSON |
| var + 'use strict' in phone.js | TypeScript + const/let with strict mode | Phase 5 migration | Type safety for sensor interfaces; IDE autocomplete for SensorPacket fields |
| Single flat JS file | `src/sensor/` module tree | Phase 5 migration | Unit-testable Kalman/ZUPT in isolation; sensor code separated from signaling plumbing |

**Deprecated/outdated:**
- `phone.js` / `room.js` as plain scripts: migrated to TypeScript modules in Phase 5. The old files in `client/dist/` become build artifacts, not source files.
- `<script src="/phone.js" defer>`: replaced with Vite's injected `<script type="module">` in the built HTML.

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | DeviceMotionEvent.rotationRate is in degrees/second on all target browsers (iOS Safari, Android Chrome) | Pattern 3, Pitfall 1 | Wrong unit would invalidate Madgwick output; detectable in first on-device test |
| A2 | ZUPT adaptive threshold of 2× measured variance is a good starting default | Pattern 9 | Too tight → false ZUPT during slow movement. Too loose → no ZUPT. Empirical tuning required on device |
| A3 | 1D Kalman per-axis with driftConfidence = 1 − P is a reasonable confidence signal for game developers | Pattern 5 | Alternative: explicit step-counter or hold-duration count. Low risk — confidence is decorative until Phase 8 demo game uses it |
| A4 | Vite 8.x maintains the same MPA API as Vite 5 (rollupOptions.input) | Pattern 1 | Breaking change in Vite 8 major could require config update. Check CHANGELOG before pinning version |
| A5 | ahrs.getQuaternion() returns { x, y, z, w } component ordering | Pattern 3 | Packet schema uses [qw, qx, qy, qz]. Wrong component order → silent orientation bug. Verify against ahrs source before shipping |
| A6 | The `@petamoriken/float16` setFloat16/getFloat16 ponyfill maintains the same function signature as native DataView methods | Pattern 6 | Signature mismatch would break encoding. Covered by unit test of round-trip encode/decode |

**If this table is empty:** All claims in this research were verified or cited — no user confirmation needed. (Not the case here — A1–A6 require device or code verification.)

---

## Open Questions

1. **ahrs rotationRate ordering (A5)**
   - What we know: ahrs.getQuaternion() documented as returning { x, y, z, w }
   - What's unclear: Whether x=pitch, y=roll, z=yaw in the ahrs quaternion convention matches Three.js and the Phase 6 decoder expectation
   - Recommendation: Write a unit test that calls ahrs.update() with a known rotation (90° yaw around Z) and asserts expected w/x/y/z components

2. **Madgwick convergence time at beta=0.3 → 0.1 ramp**
   - What we know: Higher beta = faster convergence, more noise. Lower beta = smoother, slower to converge.
   - What's unclear: On a real mid-range Android at 60Hz, how many seconds does beta=0.3 need before quaternion is stable enough to ramp down?
   - Recommendation: Log quaternion delta per frame during ramp; threshold "convergence" at delta < 0.005 per frame; measure empirically during Phase 5 testing

3. **iOS DeviceMotionEvent.acceleration vs accelerationIncludingGravity nullability**
   - What we know: `event.acceleration` may be null on some iOS versions (gravitational component not subtracted). `event.accelerationIncludingGravity` is always present.
   - What's unclear: Whether `event.acceleration` (linear, no gravity) is reliable on all target iOS 13+ Safari versions
   - Recommendation: Fallback: if `event.acceleration` is null, use `event.accelerationIncludingGravity` and subtract 9.81 from the expected gravity axis based on current quaternion. Flag as known limitation.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Node.js | `npm install`, `vite build` | ✓ | (system node) | — |
| npm | Package install | ✓ | (system npm) | — |
| Physical phone (Android or iOS) | Sensor pipeline validation | ? | — | Cannot be tested without real device; Chrome DevTools motion emulation available for basic smoke tests |
| mkcert TLS certs (already set up) | HTTPS required for DeviceMotionEvent | ✓ | From Phase 1 | — |

**Missing dependencies with no fallback:**
- A real phone is needed to validate the 60Hz sensor rate, ZUPT timing, and Madgwick convergence. Unit tests can cover encoding and math, but sensor behavior requires on-device testing.

**Missing dependencies with fallback:**
- None beyond the phone hardware requirement.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Vitest 3.x (Vite-native) |
| Config file | `client/vite.config.ts` (add `test: { environment: 'jsdom' }` key) |
| Quick run command | `npm run test` (alias for `vitest run`) |
| Full suite command | `vitest run --reporter=verbose` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| SENS-01 | ahrs.getQuaternion() returns unit quaternion after 10+ known-rotation updates | unit | `vitest run tests/orientation.test.ts` | Wave 0 gap |
| SENS-02 | Beta ramp: constructor starts at 0.3, property mutates to 0.1 after convergence criterion | unit | `vitest run tests/orientation.test.ts` | Wave 0 gap |
| SENS-03 | ZUPTDetector.update() returns false at low variance for <300ms, true after 300ms of still input | unit | `vitest run tests/zupt.test.ts` | Wave 0 gap |
| SENS-04 | Kalman1D.predict() accumulates; .resetVelocity() zeroes velocity; .driftConfidence() returns 0–1 | unit | `vitest run tests/kalman.test.ts` | Wave 0 gap |
| SENS-05 | gestureDisplacement resets to [0,0,0] after ZUPT; non-zero after movement | unit | `vitest run tests/encode.test.ts` | Wave 0 gap |
| SENS-06 | Touch fields appear in every encoded packet (touchActive, touchX, touchY) | unit | `vitest run tests/encode.test.ts` | Wave 0 gap |
| PHONE-04 | 60Hz on real device | manual/smoke | On-device: byte-count logger shows Hz ≥ 55 | manual only |
| PHONE-05 | Encoded packet is exactly 36 bytes | unit | `vitest run tests/encode.test.ts` | Wave 0 gap |

### Sampling Rate

- **Per task commit:** `npm run test` (all unit tests, < 5 seconds)
- **Per wave merge:** `vitest run --reporter=verbose`
- **Phase gate:** All unit tests green + on-device Hz verification before `/gsd-verify-work`

### Wave 0 Gaps

- [ ] `client/tests/encode.test.ts` — covers PHONE-05 (byte count = 36), float16 round-trip, SENS-05, SENS-06
- [ ] `client/tests/orientation.test.ts` — covers SENS-01 (quaternion unit-norm), SENS-02 (beta ramp), quaternion formula correctness
- [ ] `client/tests/zupt.test.ts` — covers SENS-03 (300ms window, variance threshold)
- [ ] `client/tests/kalman.test.ts` — covers SENS-04 (integration, reset, confidence)
- [ ] Framework install: `npm install --save-dev vitest` inside `client/` — Vite already in devDeps
- [ ] `client/tsconfig.json` — required before TypeScript compiles
- [ ] `client/package.json` — required before `npm install`

---

## Security Domain

### Applicable ASVS Categories (Level 1)

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No | Phase 5 is client-side sensor code only; no auth changes |
| V3 Session Management | No | Session management unchanged from Phase 4 |
| V4 Access Control | No | No new server endpoints in Phase 5 |
| V5 Input Validation | Yes | Guard NaN/null/Infinity in DeviceMotionEvent values before encoding |
| V6 Cryptography | No | No crypto in sensor path; DataView encoding is not cryptographic |

### NaN/Null Guard (V5 — required)

```typescript
// All sensor values from DeviceMotionEvent must be guarded before encoding
function safeFloat(v: number | null | undefined, fallback = 0): number {
  if (v == null || !isFinite(v)) return fallback;
  return v;
}
```

Apply `safeFloat()` to all DeviceMotionEvent.rotationRate and acceleration fields before passing to ahrs.update() or encodePacket(). An NaN propagated into a float16 DataView write produces an undefined byte pattern that could confuse the Phase 6 decoder.

### Known Threat Patterns

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| NaN/Infinity sensor values crash decoder | Tampering/DoS | safeFloat() guard before encode; decoder also validates range |
| Dev overlay URL param exposed in production | Information Disclosure | Wrap entire URL-param block in `if (import.meta.env.DEV)` |
| Production bundle includes Madgwick debug paths | Information Disclosure | `import.meta.env.DEV` + Vite tree-shaking; verify with `grep` on dist |
| ArrayBuffer reuse with stale data | Tampering | DataView overwrites all 36 bytes every frame; no stale-field risk |

---

## Sources

### Primary (MEDIUM confidence — context7/official docs)
- [W3C DeviceOrientation Event Specification](https://www.w3.org/TR/orientation-event/) — Z-X-Y quaternion conversion formula
- [MDN Float16Array](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Float16Array) — Browser support table (Baseline 2025, Chrome 135+, Safari 18.2+, iOS Safari 18.2+)
- [MDN DataView.getFloat16](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/DataView/getFloat16) — Native API (Baseline 2025)
- [Vite Build Guide — Multi-Page App](https://vite.dev/guide/build#multi-page-app) — rollupOptions.input pattern

### Secondary (LOW confidence — web search)
- [GitHub psiphi75/ahrs](https://github.com/psiphi75/ahrs) — Constructor API, update() signature, unit expectations
- [GitHub petamoriken/float16](https://github.com/petamoriken/float16) — Ponyfill API: setFloat16/getFloat16 for DataView
- [RTCDataChannel — MDN](https://developer.mozilla.org/en-US/docs/Web/API/RTCDataChannel) — dc.send() accepts Uint8Array; 16KB cross-browser safe limit
- [npm ahrs 1.3.3](https://www.npmjs.com/package/ahrs) — Package metadata, SUS verdict (337/wk)
- [npm msgpackr 2.0.4](https://www.npmjs.com/package/msgpackr) — OK verdict, 26M/wk
- [npm @petamoriken/float16 3.9.3](https://www.npmjs.com/package/@petamoriken/float16) — OK verdict, 2.1M/wk

### Tertiary (LOW confidence — assumed from training)
- ZUPT sliding-window variance algorithm — standard algorithm; no authoritative JS source found
- 1D Kalman filter implementation — standard algorithm; no JS-specific authoritative source found
- Madgwick beta ramp strategy — documented in ahrs README as config option; ramp timing is empirical

---

## Metadata

**Confidence breakdown:**
- Standard stack: MEDIUM — ahrs and @petamoriken/float16 verified via npm registry and GitHub; Vite and msgpackr are well-established
- Architecture (sensor pipeline, ZUPT, Kalman): LOW — algorithms are well-established but JavaScript implementations are assumed; no authoritative library or tutorial source found
- Packet encoding (DataView approach): MEDIUM — calculation of byte counts is deterministic; float16 encoding via ponyfill is verified
- Pitfalls: MEDIUM — unit conversion pitfalls verified against DeviceMotionEvent spec; msgpackr float16 limitation is calculated fact

**Research date:** 2026-07-09
**Valid until:** 2026-08-09 (30 days; vite version may update; ahrs is unlikely to change)
