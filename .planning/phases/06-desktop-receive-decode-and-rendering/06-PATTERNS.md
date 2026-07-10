# Phase 6: Desktop Receive, Decode, and Rendering - Pattern Map

**Mapped:** 2026-07-10
**Files analyzed:** 6 new/modified files
**Analogs found:** 5 / 6

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `client/src/sensor/decode.ts` | utility | transform | `client/src/sensor/encode.ts` | exact-inverse |
| `client/src/scene.ts` | utility/renderer | event-driven + request-response | `client/src/phone.ts` (rAF loop concept) | partial |
| `client/src/room.ts` (modified) | controller | request-response + event-driven | `client/src/phone.ts` (WT dual-path) | role-match |
| `client/index.html` (modified) | config | — | `client/index.html` (existing) | self |
| `client/tests/decode.test.ts` | test | — | `client/tests/encode.test.ts` | exact |
| `client/tests/seq-drop.test.ts` | test | — | `client/tests/encode.test.ts` | role-match |
| `client/tests/target-state.test.ts` | test | — | `client/tests/encode.test.ts` | role-match |

---

## Pattern Assignments

### `client/src/sensor/decode.ts` (utility, transform)

**Analog:** `client/src/sensor/encode.ts`

**This file is the exact inverse of encode.ts. Read encode.ts first and mirror every field.**

**Imports pattern** (`encode.ts` lines 15–16):
```typescript
import { setFloat16 } from '@petamoriken/float16';
import type { SensorPacket } from '../types';
```
Mirror for decode.ts:
```typescript
import { getFloat16 } from '@petamoriken/float16';
import { SCHEMA_VERSION, BUF_SIZE } from './encode';
import type { SensorPacket } from '../types';
```

**Constants pattern** (`encode.ts` lines 23–26):
```typescript
export const SCHEMA_VERSION = 1;
export const BUF_SIZE = 36;
```
decode.ts imports these from encode.ts — do NOT redefine them.

**Core decode pattern** (mirrors `encode.ts` lines 81–126 field-by-field):
```typescript
export function decodePacket(buf: ArrayBuffer): SensorPacket | null {
  if (buf.byteLength < BUF_SIZE) return null;           // truncated packet
  const view = new DataView(buf);
  if (view.getUint8(0) !== SCHEMA_VERSION) return null; // version mismatch
  return {
    seq:             view.getUint16(1, true),
    timestamp:       view.getUint32(3, true),
    qw: getFloat16(view, 7,  true),
    qx: getFloat16(view, 9,  true),
    qy: getFloat16(view, 11, true),
    qz: getFloat16(view, 13, true),
    dx: getFloat16(view, 15, true),
    dy: getFloat16(view, 17, true),
    dz: getFloat16(view, 19, true),
    px: getFloat16(view, 21, true),
    py: getFloat16(view, 23, true),
    pz: getFloat16(view, 25, true),
    driftConfidence: view.getFloat32(27, true),
    touchActive:     view.getUint8(31) === 1,
    touchX:          view.getUint16(32, true) / 65535,
    touchY:          view.getUint16(34, true) / 65535,
  };
}
```

**Security pattern** — `isFinite()` guard after decode (from RESEARCH.md security domain):
```typescript
// After decodePacket returns, before applying to THREE.Quaternion:
function isSafePacket(pkt: SensorPacket): boolean {
  return isFinite(pkt.qw) && isFinite(pkt.qx) && isFinite(pkt.qy) && isFinite(pkt.qz);
}
```

**Seq-drop utility** (RFC 1982 half-distance, D-09):
```typescript
export function isNewerSeq(newSeq: number, lastSeq: number): boolean {
  const diff = (newSeq - lastSeq) & 0xFFFF;
  return diff > 0 && diff <= 32767;
}
```

---

### `client/src/scene.ts` (utility/renderer, event-driven)

**Analog:** No exact match in codebase — Three.js scene file is new. Use RESEARCH.md Pattern 5–8 as the primary reference.

**Module-level state pattern** (copy allocation-outside-loop approach from `phone.ts` lines 28–64):
```typescript
// Allocate THREE objects ONCE at module scope — never inside animate()
let renderer: THREE.WebGLRenderer;
let labelRenderer: CSS2DRenderer;
let scene: THREE.Scene;
let camera: THREE.PerspectiveCamera;
let animRunning = false;
let sceneInitialized = false;  // guard against multiple initScene() calls on player-ready

// Per-player objects allocated once in addPlayerToScene(), reused every frame
const playerObjects = new Map<string, PlayerObject>();
```

**Init-guard pattern** (mirrors `phone.ts` `registered` flag usage throughout):
```typescript
export function initScene(canvas: HTMLCanvasElement, container: HTMLElement): void {
  if (sceneInitialized) return;  // player-ready fires N times; init only once
  sceneInitialized = true;
  // ... scene setup
}
```

**rAF loop pattern** (standard; `animRunning` flag mirrors phone.ts pattern for preventing double-start):
```typescript
function animate(): void {
  requestAnimationFrame(animate);
  updateSceneFromStore();
  renderer.render(scene, camera);
  labelRenderer.render(scene, camera);
}
// Start only once:
if (!animRunning) { animRunning = true; animate(); }
```

**SLERP pattern** (THREE.Quaternion instance method; do NOT use deprecated static form):
```typescript
const SLERP_ALPHA = 0.3;
// Inside updateSceneFromStore(), using pre-allocated targetQuat on PlayerState:
obj.mesh.quaternion.slerp(state.targetQuat, SLERP_ALPHA);
```

**CSS2DRenderer label pattern**:
```typescript
import { CSS2DRenderer, CSS2DObject } from 'three/examples/jsm/renderers/CSS2DRenderer.js';

const labelDiv = document.createElement('div');
labelDiv.className = 'player-label';
labelDiv.textContent = username;  // textContent, NOT innerHTML (XSS prevention)
const label = new CSS2DObject(labelDiv);
label.position.set(0, 1.2, 0);   // above the box
mesh.add(label);                  // child of mesh — follows it automatically
```

**Per-slot HSL color pattern**:
```typescript
function slotColor(slot: number): THREE.Color {
  return new THREE.Color().setHSL((slot - 1) / 8, 0.7, 0.55);
}
```

**Motion trail pattern** (BufferGeometry ring buffer — no external dep):
```typescript
const TRAIL_POINTS = 30;
function createTrail(color: THREE.Color): TrailHandle {
  const positions = new Float32Array(TRAIL_POINTS * 3);
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute('position', new THREE.BufferAttribute(positions, 3));
  const material = new THREE.LineBasicMaterial({ color, transparent: true, opacity: 0.5 });
  return { line: new THREE.Line(geometry, material), positions, head: 0 };
}
// Per-frame update (no new allocations):
function updateTrail(trail: TrailHandle, x: number, y: number, z: number): void {
  trail.positions[trail.head * 3]     = x;
  trail.positions[trail.head * 3 + 1] = y;
  trail.positions[trail.head * 3 + 2] = z;
  trail.head = (trail.head + 1) % TRAIL_POINTS;
  (trail.line.geometry.attributes['position'] as THREE.BufferAttribute).needsUpdate = true;
}
```

**Toggle pattern** (AxesHelper, GridHelper — store ref, don't re-add):
```typescript
// Allocated once in addPlayerToScene / initScene:
const axes = new THREE.AxesHelper(0.5);
mesh.add(axes);
const grid = new THREE.GridHelper(10, 10, 0x444444, 0x333333);
scene.add(grid);
// Toggled via .visible (never add/remove repeatedly):
axes.visible = axesVisible;
grid.visible = gridVisible;
```

**Exports shape** (consumed by room.ts):
```typescript
export function initScene(canvas: HTMLCanvasElement, container: HTMLElement): void
export function addPlayerToScene(playerId: string, slot: number, username: string): void
export function removePlayerFromScene(playerId: string): void
export function updateScene(store: Map<string, PlayerState>): void  // called from rAF
```

---

### `client/src/room.ts` (modified — controller, request-response + event-driven)

**Analog:** `client/src/phone.ts` (WT dual-path pattern, lines 139–430)

**Transport state pattern** (`phone.ts` lines 28–44 — copy these module-level declarations):
```typescript
// phone.ts lines 28-30
let transport: WebTransport | null = null;
let ws: WebSocket | null = null;
let useWt = false;
let wsReady = false;
```

**WT helper functions to copy verbatim from phone.ts** (lines 142–223):
- `sendWtRequest()` — lines 142–159: one-shot bidi stream request/response
- `sendWtMessage()` — lines 162–173: fire-and-forget bidi stream send
- `listenForServerPushes()` — lines 179–194: uses `.getReader()` NOT `for-await-of` (iOS compat)
- `processWtPush()` — lines 196–223: buffer chunks, parse JSON, dispatch

**WT connect + fallback pattern** (`phone.ts` lines 350–404 — adapt for `join-room` instead of `pair`):
```typescript
// Start push listener BEFORE sending anything (phone.ts line 365 comment)
listenForServerPushes(transport);
// Then register:
await sendWtMessage(transport, { type: 'register', from: myId, to: '', payload: {} });
```

**Transport-agnostic send abstraction** (`phone.ts` lines 131–137):
```typescript
function signalSend(type: string, to: string, payload: object): void {
  if (useWt && transport) {
    sendWtMessage(transport, { type, from: myId ?? '', to: to || '', payload: payload as Record<string, unknown> });
  } else {
    ws!.send(JSON.stringify({ type, from: myId, to, payload }));
  }
}
```
Replace existing `sendMessage()` / `sendTo()` in room.ts with this pattern.

**Target-state store** (new module-level, follows same pattern as `peerConnections` Map in `phone.ts` line 38 and `desktopPeers` Map in `room.ts` line 37):
```typescript
interface PlayerState {
  // SensorPacket fields
  targetQuat: THREE.Quaternion;  // pre-allocated, updated via .set()
  dx: number; dy: number; dz: number;
  px: number; py: number; pz: number;
  driftConfidence: number;
  touchActive: boolean; touchX: number; touchY: number;
  // Seq tracking
  lastSeq: number;
  lastTimestamp: number;
}
const targetStateStore = new Map<string, PlayerState>();
```

**ondatachannel wiring** (room.ts lines 271–277 — extend, do not replace):
```typescript
// room.ts line 271 — current:
pc.ondatachannel = function (evt: RTCDataChannelEvent) {
  const dc = evt.channel;
  // Phase 6: set binaryType FIRST, before any other handler
  dc.binaryType = 'arraybuffer';
  dc.onopen = function () {
    console.info('[WebRTC] data channel open phone=' + tag);
    sendMessage('rtc-channel-ready', { with: phoneId });
  };
  // Phase 6: add onmessage
  dc.onmessage = function (msgEvt: MessageEvent<ArrayBuffer>) {
    const pkt = decodePacket(msgEvt.data);
    if (!pkt || !isSafePacket(pkt)) return;
    const state = targetStateStore.get(phoneId);
    if (state && !isNewerSeq(pkt.seq, state.lastSeq)) return;
    updateTargetState(phoneId, pkt);
  };
};
```

**handlePlayerReady extension** (room.ts lines 343–347 — add scene init trigger):
```typescript
function handlePlayerReady(msg: Record<string, unknown>): void {
  // ... existing roster logic ...
  // Phase 6 additions:
  initScene(canvas, container);          // guarded by sceneInitialized flag
  addPlayerToScene(playerId, slot, username);
}
```

---

### `client/index.html` (modified — config)

**Analog:** Existing `client/index.html` (self-referential — add to existing structure)

**Canvas + overlay DOM additions** (add inside or alongside `#view-room`):
```html
<!-- game canvas — hidden until showGameView() -->
<div id="game-container" style="position: relative; width: 100vw; height: 100vh; display: none;">
  <canvas id="game-canvas" style="display: block; width: 100%; height: 100%;"></canvas>
  <!-- CSS2DRenderer labelRenderer.domElement appended here by scene.ts -->
</div>

<!-- Persistent HUD — always visible over canvas -->
<div id="game-hud" style="position: fixed; top: 12px; left: 16px; z-index: 10;
     color: #fff; font-family: monospace; font-size: 14px; pointer-events: none; display: none;">
  <span id="hud-slots">0/0 connected</span> | <span id="hud-mode">gesture</span>
</div>

<!-- TAB overlay — keydown TAB shows, keyup TAB hides -->
<div id="game-tab-overlay" style="position: fixed; top: 0; left: 0; width: 100%; height: 100%;
     background: rgba(0,0,0,0.6); z-index: 20; display: none; padding: 32px;
     font-family: monospace; color: #fff;">
  <div id="tab-roster"></div>
</div>
```

---

### `client/tests/decode.test.ts` (test)

**Analog:** `client/tests/encode.test.ts`

**Test file structure pattern** (`encode.test.ts` lines 1–36):
```typescript
import { describe, it, expect } from 'vitest';
import { getFloat16 } from '@petamoriken/float16';
import { decodePacket, isNewerSeq } from '../src/sensor/decode';
import { encodePacket, SCHEMA_VERSION, BUF_SIZE } from '../src/sensor/encode';
import type { SensorPacket } from '../src/types';

const basePkt: SensorPacket = {
  seq: 1, timestamp: 1000,
  qw: 1.0, qx: 0.0, qy: 0.0, qz: 0.0,
  dx: 0.0, dy: 0.0, dz: 0.0,
  px: 0.0, py: 0.0, pz: 0.0,
  driftConfidence: 1.0,
  touchActive: false, touchX: 0.0, touchY: 0.0,
};
```

**Roundtrip test shape** (mirror of `encode.test.ts` field-by-field tests):
```typescript
describe('decodePacket — roundtrip', () => {
  it('decodes an encoded packet with qw round-trip within ±0.002', () => {
    const pkt = { ...basePkt, qw: 0.707 };
    const encoded = encodePacket(pkt);
    const decoded = decodePacket(encoded.buffer);
    expect(decoded).not.toBeNull();
    expect(decoded!.qw).toBeCloseTo(0.707, 2);
  });
  it('returns null for truncated buffer', () => {
    expect(decodePacket(new ArrayBuffer(10))).toBeNull();
  });
  it('returns null for wrong schema version', () => {
    const buf = encodePacket(basePkt).buffer.slice(0);
    new DataView(buf).setUint8(0, 99);
    expect(decodePacket(buf)).toBeNull();
  });
});
```

---

### `client/tests/seq-drop.test.ts` (test)

**Analog:** `client/tests/encode.test.ts` (structure only; logic derived from RESEARCH.md Pattern 3)

**Test cases to cover** (derived from RESEARCH.md seq-drop analysis):
```typescript
describe('isNewerSeq', () => {
  it('accepts normal increment', () => expect(isNewerSeq(2, 1)).toBe(true));
  it('drops duplicate (same seq)', () => expect(isNewerSeq(5, 5)).toBe(false));
  it('drops backwards packet', () => expect(isNewerSeq(50, 100)).toBe(false));
  it('accepts wraparound 65535→0', () => expect(isNewerSeq(0, 65535)).toBe(true));
  it('accepts wraparound 65535→1', () => expect(isNewerSeq(1, 65534)).toBe(true));
  it('drops large jump (>32767) treated as old', () => expect(isNewerSeq(200, 33000)).toBe(false));
});
```

---

## Shared Patterns

### WT Dual-Path Transport (apply to room.ts migration)
**Source:** `client/src/phone.ts` lines 139–223 and 350–404
**Apply to:** `room.ts` transport layer only

Key ordering constraint (phone.ts line 365 comment — "Start push listener BEFORE sending anything"):
```typescript
listenForServerPushes(transport);  // FIRST
await sendWtMessage(transport, { type: 'register', ... });  // THEN register
```

### No-Allocation Pattern in Hot Loop
**Source:** `client/src/sensor/encode.ts` lines 29–33 (`_packetBuf` allocated once at module scope)
**Apply to:** `scene.ts` rAF loop, `decode.ts` (reuse DataView over incoming ArrayBuffer)

Rule: Never call `new THREE.Quaternion()`, `new THREE.Vector3()`, `new THREE.Color()`, or `new DataView()` inside `animate()` or `dc.onmessage`. Allocate once; mutate in place.

### textContent over innerHTML (XSS prevention)
**Source:** RESEARCH.md security domain — "CSS2DObject labelDiv.textContent (not innerHTML)"
**Apply to:** All DOM writes in scene.ts (label names) and room.ts (TAB overlay roster)

### Error/Null Guard Pattern
**Source:** `client/src/sensor/encode.ts` `safeFloat()` lines 44–47
**Apply to:** `decodePacket()` — null on truncated/bad-version buffer; `isSafePacket()` — isFinite guard on quaternion fields before THREE apply

---

## No Analog Found

| File | Role | Data Flow | Reason |
|------|------|-----------|--------|
| `client/src/scene.ts` | renderer | event-driven | No Three.js scene file exists in codebase yet; use RESEARCH.md Patterns 5–8 as primary reference |

---

## Metadata

**Analog search scope:** `client/src/`, `client/tests/`
**Files scanned:** `phone.ts`, `room.ts`, `sensor/encode.ts`, `types.ts`, `tests/encode.test.ts`
**Pattern extraction date:** 2026-07-10
