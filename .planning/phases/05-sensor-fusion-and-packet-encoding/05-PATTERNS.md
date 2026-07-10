# Phase 05: Sensor Fusion and Packet Encoding — Pattern Map

**Mapped:** 2026-07-09
**Files analyzed:** 14 new/modified files
**Analogs found:** 4 / 14 (10 are new capability with no codebase analog — patterns sourced from RESEARCH.md)

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `client/package.json` | config | — | none | no analog |
| `client/tsconfig.json` | config | — | none | no analog |
| `client/vite.config.ts` | config | — | none | no analog |
| `client/phone.html` | UI shell | — | `client/dist/phone.html` | exact (add calibrating view) |
| `client/index.html` | UI shell | — | `client/dist/index.html` | exact (move + add module script) |
| `client/src/types.ts` | utility | transform | none | no analog |
| `client/src/phone.ts` | controller | event-driven | `client/dist/phone.js` | exact (TS migration + sensor hooks) |
| `client/src/room.ts` | controller | request-response | `client/dist/room.js` | exact (TS migration only) |
| `client/src/sensor/orientation.ts` | utility | transform | `client/dist/phone.js` lines 764–778 (startMotionIndicator) | partial (same devicemotion event, different purpose) |
| `client/src/sensor/zupt.ts` | utility | event-driven | none | no analog |
| `client/src/sensor/kalman.ts` | utility | transform | none | no analog |
| `client/src/sensor/encode.ts` | utility | transform | none | no analog |
| `client/src/ui/devOverlay.ts` | utility | event-driven | `client/dist/phone.js` lines 817–860 (initOnScreenLog/phoneLog) | role-match (dev-only UI overlay) |
| `client/tests/encode.test.ts` | test | — | none | no analog |
| `client/tests/orientation.test.ts` | test | — | none | no analog |
| `client/tests/zupt.test.ts` | test | — | none | no analog |
| `client/tests/kalman.test.ts` | test | — | none | no analog |

---

## Pattern Assignments

### `client/package.json` (config)

**Analog:** none — first npm project in repo

**Pattern from RESEARCH.md:**
```json
{
  "name": "immersivert-client",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "test": "vitest run"
  },
  "dependencies": {
    "ahrs": "1.3.3",
    "@petamoriken/float16": "3.9.3"
  },
  "devDependencies": {
    "vite": "8.1.4",
    "typescript": "^5.0.0",
    "vitest": "^3.0.0"
  }
}
```

**Note:** `ahrs` is flagged SUS (337/wk). Planner must add `checkpoint:human-verify` task before `npm install ahrs`.

---

### `client/tsconfig.json` (config)

**Analog:** none — first TypeScript config in repo

**Pattern from RESEARCH.md:**
```json
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "lib": ["ES2020", "DOM"],
    "noEmit": true
  },
  "include": ["src/**/*", "tests/**/*"]
}
```

**Key constraints:** `strict: true` (RESEARCH.md §Standard Stack); `target: ES2020` covers all target browsers; `moduleResolution: bundler` for Vite compatibility.

---

### `client/vite.config.ts` (config)

**Analog:** none — first Vite config in repo

**Pattern from RESEARCH.md (Pattern 1, lines 269–289):**
```typescript
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

**Pitfall (RESEARCH.md Pitfall 7):** HTML output filename mirrors the source filename, not the `rollupOptions` key. Name source files exactly as you want them served.

---

### `client/phone.html` (UI shell — modify existing)

**Analog:** `client/dist/phone.html` (exact — move and extend)

**Existing structure (lines 199–255):** Six views in `#phone-card`. View IDs: `view-permission`, `view-connecting`, `view-active`, `view-ended`, `view-error-denied`, `view-error-pair`.

**Phase 5 changes required:**
1. Replace `<script src="/phone.js" defer>` (line 254) with `<script type="module" src="./src/phone.ts"></script>` (Vite entry)
2. Add `#view-calibrating` view between `#view-connecting` and `#view-active` — calibration scene with hold-still instruction + 3-second countdown bar
3. Add `#dev-overlay` div to `#view-active` section (rendered only in `import.meta.env.DEV` builds via JS, but HTML hook must exist)

**Copy script tag pattern from RESEARCH.md:**
```html
<!-- phone.html — replaces <script src="/phone.js" defer> -->
<script type="module" src="./src/phone.ts"></script>
```

**View pattern from existing phone.html (lines 207–213):**
```html
<!-- ── View N: Calibrating (hidden) ── -->
<div id="view-calibrating" hidden>
  <p class="size-heading">Hold your phone still</p>
  <p class="size-body text-secondary mt-md">Place it flat on a surface.</p>
  <div id="calibration-bar" class="mt-lg"><!-- countdown bar --></div>
</div>
```

---

### `client/src/types.ts` (utility — new)

**Analog:** none — first shared type file in repo

**Pattern (RESEARCH.md §Architectural Responsibility Map):**
```typescript
export interface Quaternion {
  w: number;
  x: number;
  y: number;
  z: number;
}

export interface Vector3 {
  x: number;
  y: number;
  z: number;
}

export interface SensorPacket {
  seq: number;
  timestamp: number;       // ms since session start
  qw: number; qx: number; qy: number; qz: number;  // orientation
  dx: number; dy: number; dz: number;               // gesture displacement
  px: number; py: number; pz: number;               // dead-reckoning position
  driftConfidence: number; // 0–1
  touchActive: boolean;
  touchX: number;  // normalized 0–1
  touchY: number;  // normalized 0–1
}
```

---

### `client/src/phone.ts` (controller — migrate + extend)

**Analog:** `client/dist/phone.js` (exact match — TypeScript migration + sensor pipeline addition)

**Migration pattern:** Convert `var` → `const`/`let`, add explicit types, replace `'use strict'` with TypeScript module semantics. Keep all existing logic intact.

**Imports pattern (new — no existing analog):**
```typescript
import { eulerToQuat } from './sensor/orientation';
import { ZUPTDetector } from './sensor/zupt';
import { Kalman1D } from './sensor/kalman';
import { encodePacket } from './sensor/encode';
import type { Quaternion, Vector3, SensorPacket } from './types';
```

**Existing transport state pattern** (`client/dist/phone.js` lines 15–32):
```javascript
var transport = null;    // WebTransport if useWt
var ws = null;           // WebSocket if !useWt
var useWt = false;
var peerConnections = new Map(); // peerId → { pc, dc, flagClose }
var openChannelCount = 0;
```
Migrate to typed TypeScript:
```typescript
let transport: WebTransport | null = null;
let ws: WebSocket | null = null;
let useWt = false;
const peerConnections = new Map<string, { pc: RTCPeerConnection; dc: RTCDataChannel; channelOpen: boolean; flagClose: () => void }>();
let openChannelCount = 0;
```

**Existing signalSend pattern** (`client/dist/phone.js` lines 92–98 — carry forward unchanged):
```typescript
function signalSend(type: string, to: string, payload: object): void {
  if (useWt && transport) {
    sendWtMessage(transport, { type, from: myId, to: to || '', payload: payload || {} });
  } else {
    sendWsMsg(type, to, payload);
  }
}
```

**Existing WebRTC data channel fan-out pattern** (`client/dist/phone.js` lines 565–648 — `openChannelToPeer`):
- `{ ordered: false, maxRetransmits: 0 }` on line 575 — locked per Phase 4 D-05, must not change
- `dc.onopen` / `dc.onclose` handlers on lines 626–645 — carry forward

**Sensor pipeline hook — activates after `player-ready`** (`client/dist/phone.js` lines 655–677 `onPlayerReady`):
```typescript
// Phase 5: add after existing onPlayerReady logic
function onPlayerReady(msg: MessageEvent): void {
  // ... existing view/UI setup ...
  showView('view-calibrating');   // Phase 5: show calibration before view-active
  runCalibration((threshold, kalmanQ) => {
    showView('view-active');
    startSensorPipeline(threshold, kalmanQ);
  });
}
```

**Broadcast packet pattern** (RESEARCH.md Pattern 7):
```typescript
function broadcastPacket(uint8: Uint8Array): void {
  peerConnections.forEach(({ dc, channelOpen }) => {
    if (channelOpen && dc.readyState === 'open') {
      dc.send(uint8);
    }
  });
}
```

**Dev-only URL param pattern** (RESEARCH.md D-04, Pitfall 8):
```typescript
let useMADGWICK = false;
if (import.meta.env.DEV) {
  useMADGWICK = new URLSearchParams(location.search).get('orient') === 'madgwick';
}
```

**Sensor pipeline entry point** (RESEARCH.md §Code Examples, lines 642–702):
```typescript
let sessionStart: number;
let seq = 0;
const _packetBuf = new ArrayBuffer(36);  // allocate ONCE — reuse at 60Hz

function startSensorPipeline(zuptThreshold: number, kalmanQ: number): void {
  sessionStart = Date.now();
  const kalmans = [new Kalman1D(kalmanQ), new Kalman1D(kalmanQ), new Kalman1D(kalmanQ)];
  const zupt = new ZUPTDetector(300, zuptThreshold);
  let gestureOrigin: Vector3 = { x: 0, y: 0, z: 0 };
  let lastTs = performance.now();
  let primaryQuat: Quaternion = { w: 1, x: 0, y: 0, z: 0 };

  window.addEventListener('deviceorientation', (e: DeviceOrientationEvent) => {
    primaryQuat = eulerToQuat(e.alpha ?? 0, e.beta ?? 0, e.gamma ?? 0);
  });

  window.addEventListener('devicemotion', (e: DeviceMotionEvent) => {
    const now = performance.now();
    const dtSec = (now - lastTs) / 1000;
    lastTs = now;

    const la = e.acceleration;
    const accelX = safeFloat(la?.x);
    const accelY = safeFloat(la?.y);
    const accelZ = safeFloat(la?.z);

    const ag = e.accelerationIncludingGravity;
    const mag = Math.sqrt((ag?.x ?? 0) ** 2 + (ag?.y ?? 0) ** 2 + (ag?.z ?? 0) ** 2);
    const isStill = zupt.update(mag, Date.now());

    const px = kalmans[0].predict(accelX, dtSec);
    const py = kalmans[1].predict(accelY, dtSec);
    const pz = kalmans[2].predict(accelZ, dtSec);

    if (isStill) {
      kalmans.forEach(k => k.resetVelocity());
      gestureOrigin = { x: px, y: py, z: pz };
    }

    const pkt: SensorPacket = {
      seq: seq++,
      timestamp: Date.now() - sessionStart,
      qw: primaryQuat.w, qx: primaryQuat.x, qy: primaryQuat.y, qz: primaryQuat.z,
      dx: px - gestureOrigin.x, dy: py - gestureOrigin.y, dz: pz - gestureOrigin.z,
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

### `client/src/room.ts` (controller — migrate only)

**Analog:** `client/dist/room.js` (exact — TypeScript migration, no new logic)

**Migration approach:** Same `var` → `const`/`let` conversion as phone.ts. `'use strict'` removed (TypeScript modules are strict by default). No new sensor code in Phase 5 — desktop packet decoding is Phase 6.

**Script tag change in index.html:** Replace `<script src="/room.js" defer>` with `<script type="module" src="./src/room.ts"></script>`

---

### `client/src/sensor/orientation.ts` (utility — new)

**Analog (partial):** `client/dist/phone.js` lines 762–778 (`startMotionIndicator`) — same `devicemotion` event, different purpose

**Existing devicemotion pattern to migrate from** (`client/dist/phone.js` lines 764–778):
```javascript
window.addEventListener('devicemotion', function(e) {
  var a = e.linearAcceleration || e.accelerationIncludingGravity;
  if (!a) { return; }
  var mag = Math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
  // ... UI update
});
```

**OS-fused quaternion pattern** (RESEARCH.md Pattern 2 — W3C Z-X-Y spec formula):
```typescript
import type { Quaternion } from '../types';

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

**Madgwick secondary pipeline pattern** (RESEARCH.md Pattern 3):
```typescript
import AHRS from 'ahrs';
import type { Quaternion } from '../types';

// Exported so phone.ts can mutate beta during ramp
export const ahrs = new AHRS({
  sampleInterval: 60,
  algorithm: 'Madgwick',
  beta: 0.3,  // cold-start high; ramp to 0.1 after convergence
});

// CRITICAL unit conversions (RESEARCH.md Pitfalls 1 & 2):
//   rotationRate: deg/s → rad/s (multiply by Math.PI/180)
//   accelerationIncludingGravity: m/s² → g  (divide by 9.81)
export function updateMadgwick(e: DeviceMotionEvent): Quaternion {
  const rr = e.rotationRate;
  const a  = e.accelerationIncludingGravity;
  if (!rr || !a) return { w: 1, x: 0, y: 0, z: 0 };

  ahrs.update(
    (rr.alpha ?? 0) * Math.PI / 180,
    (rr.beta  ?? 0) * Math.PI / 180,
    (rr.gamma ?? 0) * Math.PI / 180,
    (a.x ?? 0) / 9.81,
    (a.y ?? 0) / 9.81,
    (a.z ?? 0) / 9.81,
  );

  const q = ahrs.getQuaternion(); // Returns { x, y, z, w } — note component order
  return { w: q.w, x: q.x, y: q.y, z: q.z };
}
```

**Anti-pattern:** Do NOT run Madgwick on DeviceOrientationEvent α/β/γ output — that is already OS-fused. Feed ahrs only raw `DeviceMotionEvent.rotationRate` + `accelerationIncludingGravity`.

---

### `client/src/sensor/zupt.ts` (utility — new)

**Analog:** none

**Pattern from RESEARCH.md (Pattern 4):**
```typescript
export class ZUPTDetector {
  private readonly window: Array<{ v: number; t: number }> = [];
  private readonly windowMs: number;
  public adaptiveThreshold: number; // set during hold-still calibration

  constructor(windowMs = 300, threshold = 0.01) {
    this.windowMs = windowMs;
    this.adaptiveThreshold = threshold;
  }

  update(accelMag: number, nowMs: number): boolean {
    this.window.push({ v: accelMag, t: nowMs });
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

---

### `client/src/sensor/kalman.ts` (utility — new)

**Analog:** none

**Pattern from RESEARCH.md (Pattern 5):**
```typescript
export class Kalman1D {
  private pos = 0;
  private vel = 0;
  private P   = 1;

  constructor(
    private Q = 0.001,  // process noise — set from calibration
    private R = 0.1,    // measurement noise — set from calibration
  ) {}

  predict(accelMs2: number, dtSec: number): number {
    this.vel += accelMs2 * dtSec;
    this.pos += this.vel * dtSec;
    this.P  += this.Q * dtSec;
    return this.pos;
  }

  // Call when ZUPT fires
  resetVelocity(): void {
    const K = this.P / (this.P + this.R);
    this.vel = 0;
    this.P  *= (1 - K);
  }

  // 1.0 immediately after ZUPT; decays as P grows
  driftConfidence(): number {
    return Math.max(0, 1 - Math.min(1, this.P));
  }
}
```

---

### `client/src/sensor/encode.ts` (utility — new)

**Analog:** none — first binary encoding in codebase

**Pattern from RESEARCH.md (Patterns 6, 8, 9):**
```typescript
import { setFloat16 } from '@petamoriken/float16';
import type { SensorPacket, Vector3 } from '../types';

const SCHEMA_VERSION = 1;
const BUF_SIZE = 36;

// Allocate ONCE at module scope — reuse every packet (RESEARCH.md Pitfall 5: no per-frame allocation)
export const _packetBuf = new ArrayBuffer(BUF_SIZE);

export function encodePacket(pkt: SensorPacket, buf: ArrayBuffer): Uint8Array {
  const view = new DataView(buf);
  const le = true; // little-endian throughout

  view.setUint8(0,  SCHEMA_VERSION);
  view.setUint16(1, pkt.seq % 65536, le);  // uint16 wrap (RESEARCH.md anti-patterns)
  view.setUint32(3, pkt.timestamp, le);

  // Quaternion (4× float16) — offsets 7–14
  setFloat16(view, 7,  pkt.qw, le);
  setFloat16(view, 9,  pkt.qx, le);
  setFloat16(view, 11, pkt.qy, le);
  setFloat16(view, 13, pkt.qz, le);

  // Gesture displacement (3× float16) — offsets 15–20
  setFloat16(view, 15, pkt.dx, le);
  setFloat16(view, 17, pkt.dy, le);
  setFloat16(view, 19, pkt.dz, le);

  // Dead-reckoning position (3× float16) — offsets 21–26
  setFloat16(view, 21, pkt.px, le);
  setFloat16(view, 23, pkt.py, le);
  setFloat16(view, 25, pkt.pz, le);

  // Drift confidence (float32 — higher precision) — offset 27
  view.setFloat32(27, pkt.driftConfidence, le);

  // Touch — offsets 31–35
  view.setUint8(31,  pkt.touchActive ? 1 : 0);
  view.setUint16(32, Math.round(pkt.touchX * 65535), le);
  view.setUint16(34, Math.round(pkt.touchY * 65535), le);

  return new Uint8Array(buf);
}

// Hold-still calibration — 3-second measurement window
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
      onComplete(variance * 2, variance * 0.1); // threshold, kalmanQ
    }
  };
  window.addEventListener('devicemotion', handler);
}
```

**Anti-pattern (RESEARCH.md Pitfall 4):** Do NOT use `msgpackr.pack([...])` for sensor packets. MessagePack has no float16 type; float32 costs 5 bytes/field vs 2 bytes in DataView. 13 float fields via msgpackr = 65+ bytes, impossible to reach 45-byte target.

---

### `client/src/ui/devOverlay.ts` (utility — new, dev-only)

**Analog (role-match):** `client/dist/phone.js` lines 817–860 (`initOnScreenLog` / `phoneLog`)

**Existing on-screen log pattern** (`client/dist/phone.js` lines 822–847):
```javascript
function initOnScreenLog() {
  _logEl = document.createElement('div');
  _logEl.style.cssText =
    'position:fixed;bottom:0;left:0;right:0;z-index:9999;' +
    'background:rgba(0,0,0,0.85);border-top:2px solid #0f0;' +
    'font:11px/1.5 monospace;';
  // ... header + body divs appended to document.body
}
```

**Phase 5 dev overlay extends this pattern:**
```typescript
// Only imported when import.meta.env.DEV is true
// Full block must be inside if (import.meta.env.DEV) in phone.ts to enable tree-shaking
// (RESEARCH.md Pitfall 8)

export function initDevOverlay(): void {
  const el = document.createElement('div');
  el.style.cssText =
    'position:fixed;top:0;left:0;right:0;z-index:9998;' +
    'background:rgba(0,0,0,0.8);font:10px/1.4 monospace;color:#0f0;padding:4px 8px;';
  document.body.appendChild(el);
  // expose updater for 60Hz sensor loop
  (window as any).__devOverlayEl = el;
}

export function updateDevOverlay(
  osQuat: { w: number; x: number; y: number; z: number },
  madgwickQuat: { w: number; x: number; y: number; z: number },
  isStill: boolean,
  driftConf: number,
  hz: number,
): void {
  const el = (window as any).__devOverlayEl;
  if (!el) return;
  el.textContent =
    `OS:  w=${osQuat.w.toFixed(3)} x=${osQuat.x.toFixed(3)} y=${osQuat.y.toFixed(3)} z=${osQuat.z.toFixed(3)}\n` +
    `MWK: w=${madgwickQuat.w.toFixed(3)} x=${madgwickQuat.x.toFixed(3)} y=${madgwickQuat.y.toFixed(3)} z=${madgwickQuat.z.toFixed(3)}\n` +
    `ZUPT:${isStill ? 'YES' : 'no'}  drift:${driftConf.toFixed(2)}  hz:${hz.toFixed(1)}`;
}
```

---

### `client/tests/*.test.ts` (tests — new)

**Analog:** none — first test files in repo

**Framework:** Vitest 3.x (configured in `vite.config.ts` as `test: { environment: 'jsdom' }`)

**Test structure pattern (standard Vitest):**
```typescript
// client/tests/encode.test.ts
import { describe, it, expect } from 'vitest';
import { encodePacket, _packetBuf } from '../src/sensor/encode';
import { getFloat16 } from '@petamoriken/float16';
import type { SensorPacket } from '../src/types';

describe('encodePacket', () => {
  it('produces exactly 36 bytes', () => {
    const pkt: SensorPacket = { seq: 0, timestamp: 0, qw: 1, qx: 0, qy: 0, qz: 0,
      dx: 0, dy: 0, dz: 0, px: 0, py: 0, pz: 0,
      driftConfidence: 1.0, touchActive: false, touchX: 0, touchY: 0 };
    const result = encodePacket(pkt, _packetBuf);
    expect(result.byteLength).toBe(36);
  });

  it('version byte is 1', () => {
    const pkt = /* ... */ {} as SensorPacket;
    const result = encodePacket(pkt, _packetBuf);
    expect(result[0]).toBe(1);
  });

  it('float16 round-trips quaternion within ±0.001', () => {
    const qw = 0.707;
    const pkt = { /* ... qw */ } as SensorPacket;
    const result = encodePacket(pkt, _packetBuf);
    const view = new DataView(result.buffer);
    const decoded = getFloat16(view, 7, true);
    expect(Math.abs(decoded - qw)).toBeLessThan(0.002);
  });
});
```

---

## Shared Patterns

### NaN/Null Guard (V5 Input Validation)

**Source:** RESEARCH.md §Security Domain
**Apply to:** All `sensor/*.ts` files that read `DeviceMotionEvent` values

```typescript
function safeFloat(v: number | null | undefined, fallback = 0): number {
  if (v == null || !isFinite(v)) return fallback;
  return v;
}
```

Apply before `ahrs.update()` arguments and before `encodePacket()` arguments. NaN in float16 DataView write produces undefined byte pattern that confuses the Phase 6 decoder.

---

### Dev-Mode Gating Pattern

**Source:** RESEARCH.md §D-04, Pitfall 8
**Apply to:** `devOverlay.ts` import in `phone.ts`, URL param reading, Madgwick overlay comparison

```typescript
// Entire block must be inside the if — not just the condition
if (import.meta.env.DEV) {
  const useMADGWICK = new URLSearchParams(location.search).get('orient') === 'madgwick';
  initDevOverlay();
  // ... all dev-only setup
}
```

Verify in production: `grep 'orient\|devOverlay\|updateDevOverlay' client/dist/assets/phone-*.js` should return nothing.

---

### Existing `phoneLog` Debug Pattern (carry forward)

**Source:** `client/dist/phone.js` lines 849–860
**Apply to:** `phone.ts` — keep existing `phoneLog` for signaling/WebRTC events; dev overlay is separate

```typescript
function phoneLog(msg: string): void {
  if (!_logBody) { return; }
  const now = new Date();
  const ts = String(now.getMinutes()).padStart(2, '0') + ':' +
             String(now.getSeconds()).padStart(2, '0') + '.' +
             String(now.getMilliseconds()).padStart(3, '0');
  const line = document.createElement('div');
  line.textContent = ts + ' ' + msg;
  _logBody.appendChild(line);
  while (_logBody.children.length > 40) { _logBody.removeChild(_logBody.firstChild!); }
  if (!_logCollapsed) { _logBody.scrollTop = _logBody.scrollHeight; }
}
```

---

### Buffer Reuse at 60Hz

**Source:** RESEARCH.md Pattern 6 + Pitfall 5
**Apply to:** `encode.ts` and `phone.ts`

```typescript
// WRONG — allocates 3,600 objects/minute, causes GC jitter:
// const buf = new ArrayBuffer(36); // inside devicemotion handler

// CORRECT — allocate once at module scope:
export const _packetBuf = new ArrayBuffer(36);
// Pass to encodePacket() every frame; DataView overwrites all bytes each time
```

---

## No Analog Found

| File | Role | Data Flow | Reason |
|------|------|-----------|--------|
| `client/package.json` | config | — | First npm project in repo |
| `client/tsconfig.json` | config | — | First TypeScript config in repo |
| `client/vite.config.ts` | config | — | First build config in repo |
| `client/src/types.ts` | utility | transform | First shared type file |
| `client/src/sensor/zupt.ts` | utility | event-driven | No existing ZUPT or signal-processing code |
| `client/src/sensor/kalman.ts` | utility | transform | No existing Kalman or estimation code |
| `client/src/sensor/encode.ts` | utility | transform | No existing binary encoding code |
| `client/tests/*.test.ts` | test | — | No existing test files in repo |

All above use patterns from RESEARCH.md exclusively.

---

## Metadata

**Analog search scope:** `client/dist/` (only client source in repo; no server-side TS/JS; no existing test files)
**Files scanned:** `client/dist/phone.js` (869 lines), `client/dist/phone.html` (257 lines)
**Pattern extraction date:** 2026-07-09

**Key finding:** The project has no existing TypeScript, no build tooling, and no test infrastructure. Phase 5 introduces all of these simultaneously. The strongest analog is `client/dist/phone.js` — nearly every pattern in `phone.ts` migrates directly from it, with sensor pipeline slots added. All `src/sensor/` modules are net-new with no codebase analog; RESEARCH.md patterns are authoritative for those files.
