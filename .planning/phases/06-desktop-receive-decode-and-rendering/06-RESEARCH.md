# Phase 6: Desktop Receive, Decode, and Rendering - Research

**Researched:** 2026-07-10
**Domain:** WebTransport signaling migration, binary packet decoding, Three.js rendering, SLERP interpolation
**Confidence:** MEDIUM

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Desktop WebTransport (DESK-01)**
- D-01: Full WT migration — room.ts replaces WebSocket with WebTransport for all signaling. Same dual-path pattern as phone.ts: try WebTransport first, fall back to WebSocket if QUIC is blocked.
- D-02: WS fallback kept — INFRA-05 server-side WS path already validated. Both paths carry full signaling message set.
- D-03: No split transport — all message types travel on a single active transport.

**Three.js Canvas Placement (DESK-01, DESK-05)**
- D-04: Embedded in existing index.html / room.ts — no new Vite entry, no new HTML file. Three.js renderer initialised inside room.ts when `player-ready` fires for the first player.
- D-05: Full-viewport canvas on `player-ready` — room UI hides, canvas fills viewport.
- D-06: Persistent minimal HUD — always visible: slots occupied / total count. Not hideable.
- D-07: TAB-held expanded overlay — holding TAB shows full roster with player name, slot number, channel state. Releases on TAB-up.

**Packet Decode (DESK-03)**
- D-08: decode.ts mirrors encode.ts — new `client/src/sensor/decode.ts` uses `getFloat16` from `@petamoriken/float16` (already in package.json) to read float16 fields at exact byte offsets from D-14. Returns `SensorPacket`.
- D-09: Sequence-drop via half-distance uint16 — `(newSeq - lastSeq) & 0xFFFF <= 32767` determines if `newSeq` is strictly newer. Drop if false. Per-sender lastSeq in target-state store.

**Target-State Store (DESK-04)**
- D-10: `Map<playerId, PlayerState>` where `PlayerState` holds latest SensorPacket fields plus `lastSeq: number` and `lastTimestamp: number`. Updated on every accepted packet. rAF loop reads from this map every frame.

**Three.js Scene (DESK-05)**
- D-11: Scene composition — ambient light + directional light, one solid-colored box per player (distinct HSL per-slot), player name label above each box, fixed perspective camera (no orbit controls).
- D-12: Rotation — object quaternion set from SensorPacket orientation via SLERP each frame. Default alpha 0.3.
- D-13: Position mode — keyboard key `P` cycles: gestureDisplacement → deadReckoningPosition → back. Current mode shown in HUD.
- D-14: Touch response — always-on color flash/pulse on touchActive=true; `D` key toggles motion trail (off by default).
- D-15: Precision aids (individually toggled via keyboard): `G` grid floor (default on), `A` axes gizmo per object (default on), `H` numeric HUD per player (default on), `T` motion trail (default off).

### Claude's Discretion
- Exact uint16 half-distance seq-drop implementation (standard 3-line math).
- Three.js `requestAnimationFrame` loop structure.
- Per-slot hue assignment (HSL evenly spaced across 8 slots).
- Motion trail implementation (trailing ghost geometry or BufferGeometry Line — whichever is lighter).
- SLERP: use `THREE.Quaternion.slerp()` between current and target quaternion each frame.
- Label rendering: `CSS2DRenderer` or `Sprite` — whichever integrates cleanly with the existing DOM structure.

### Deferred Ideas (OUT OF SCOPE)
- Orbit controls / camera pan (Phase 8)
- Per-player object shape variety (Phase 8)
- SLERP alpha UI control (Phase 7 SDK / Phase 8 demo)
- Gesture-triggered flick action DEMO-03 (Phase 8)
- Multi-desktop sync (Phase 8)
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| DESK-01 | Desktop connects to server via WebTransport (persistent connection for signaling and game state) | Phone.ts WT pattern is directly reusable in room.ts; `sendWtMessage` / `listenForServerPushes` / `setupTransportClosedHandler` patterns documented below |
| DESK-02 | Desktop establishes WebRTC P2P unreliable data channels to paired phone and accepts connections from all other players' phones | `ondatachannel` hook already in room.ts line 271; needs `dc.binaryType = 'arraybuffer'` and decode wiring |
| DESK-03 | Desktop decodes incoming binary sensor packets from all connected phones, drops out-of-order packets via uint16 seq comparison per-sender | decode.ts is the mirror of encode.ts; half-distance comparison documented with exact formula |
| DESK-04 | Desktop maintains per-player target-state store updated on every packet receipt | `Map<string, PlayerState>` pattern; state shape and update path documented |
| DESK-05 | Desktop applies SLERP interpolation on orientation quaternions in the Three.js render loop | THREE.Quaternion.slerp() API documented; full scene composition and rAF loop documented |
</phase_requirements>

---

## Summary

Phase 6 is the desktop side of the sensor hot-path. It has three vertically independent concerns that must be wired together:

**Transport migration:** room.ts currently uses WebSocket for all signaling. Phase 6 replaces this with the same dual-path pattern that phone.ts already uses (WebTransport preferred, WS fallback). The phone.ts implementation (`sendWtMessage`, `listenForServerPushes`, `setupTransportClosedHandler`) is a complete, battle-tested reference — the desktop migration is a direct port of this code, adjusted for the `join-room` / `join-ack` message flow instead of the `pair` flow.

**Decode pipeline:** `decode.ts` is the exact inverse of `encode.ts`. All byte offsets, data types, and endianness are already specified in D-14 (Phase 5 CONTEXT.md). The `@petamoriken/float16` package with `getFloat16` is already installed. The only new logic is the uint16 half-distance sequence-drop check, which is a 3-line formula defined by RFC 1982 serial number arithmetic.

**Three.js scene:** `three@0.185.1` must be added to package.json (not yet installed). The scene is a precision-evaluation viewer with fixed camera, per-player colored boxes, SLERP-driven rotation, and keyboard-toggleable diagnostic aids. CSS2DRenderer handles player name labels. The rAF loop reads from the target-state store every frame — there is no coupling between packet arrival rate and render rate.

**Primary recommendation:** Port phone.ts WT pattern to room.ts first (all signaling restored), then wire decode into the existing `ondatachannel` callback, then install Three.js and build the scene independently.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| WebTransport signaling (join, ICE, reconnect) | Browser / Client (room.ts) | Server (wt_server.rs — no change) | All signaling is client-initiated; server already handles multiple WT clients per room |
| WebRTC data channel receive (binary packets) | Browser / Client (room.ts ondatachannel) | — | Data arrives from phone via P2P; desktop is pure receiver here |
| Packet decode + seq-drop | Browser / Client (decode.ts) | — | Pure client-side computation; no server involvement |
| Target-state store | Browser / Client (room.ts module scope) | — | Read by rAF loop in same module; Map in module scope is the simplest correct approach |
| Three.js render loop | Browser / Client (room.ts or scene.ts) | — | WebGL rendering is browser-only; rAF is a browser API |
| Canvas + HUD DOM | Browser / Client (index.html + room.ts) | — | Canvas added to index.html; HUD as absolutely-positioned divs |
| SLERP interpolation | Browser / Client (rAF loop) | — | Per-frame quaternion blending happens in the render loop |

---

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| three | 0.185.1 | 3D rendering, scene graph, SLERP | Locked in CLAUDE.md; only 3D library in scope for v1 |
| @types/three | 0.185.1 | TypeScript types for Three.js | Ships in sync with three; required for strict TypeScript |
| @petamoriken/float16 | 3.9.3 (already installed) | `getFloat16` for decode.ts | Same package already used by encode.ts; no new dependency |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| three/examples/jsm/renderers/CSS2DRenderer | (included with three) | HTML label overlay positioned in 3D world-space | Player name labels above each box (D-11); ships with three.js, no separate install |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| CSS2DRenderer | THREE.Sprite (canvas texture) | Sprite requires re-rendering texture on name change; CSS2DRenderer renders live DOM elements — simpler for text labels |
| CSS2DRenderer | THREE.SpriteMaterial + canvas | Same downside as above; CSS2DRenderer is the established Three.js solution for 2D overlays tied to 3D positions |
| BufferGeometry Line for trail | TrailRendererJS | TrailRendererJS is an external third-party package, not part of three; a simple ring-buffer line is 30 lines and has zero deps |

**Installation:**
```bash
cd client && npm install three@0.185.1 @types/three@0.185.1 --save-dev-only-for-types
```
Actually, `three` is a runtime dependency (needed in the browser bundle); `@types/three` is a devDependency:
```bash
cd client && npm install three@0.185.1
npm install --save-dev @types/three@0.185.1
```

**Version verification:**
```bash
npm view three version          # 0.185.1 (verified 2026-07-10)
npm view @types/three version   # 0.185.1 (verified 2026-07-10)
```

---

## Package Legitimacy Audit

> The Package Legitimacy Gate was run via `gsd-tools query package-legitimacy check --ecosystem npm three @types/three @petamoriken/float16`.

| Package | Registry | Age | Downloads | Source Repo | Verdict | Disposition |
|---------|----------|-----|-----------|-------------|---------|-------------|
| three | npm | 13+ yrs (created 2012-12-07) | 11.5M/wk | github.com/mrdoob/three.js | SUS (too-new latest version) | Approved — SUS flag is due to latest version (0.185.1) being published 2026-07-01; the package itself is 13 years old, 11.5M weekly downloads, canonical Three.js library. Verified safe. |
| @types/three | npm | ~8 yrs | 7.1M/wk | github.com/DefinitelyTyped/DefinitelyTyped | SUS (too-new latest version) | Approved — SUS flag is recency of latest type release; DefinitelyTyped is the canonical TypeScript type source. Verified safe. |
| @petamoriken/float16 | npm | ~1 yr since current | 2.2M/wk | github.com/petamoriken/float16 | OK | Already installed in client/package.json 3.9.3 |

**Packages removed due to SLOP verdict:** none

**Packages flagged as suspicious SUS:** `three` and `@types/three` were mechanically flagged due to recent version publication date, not package identity. Both are canonical, well-established packages with overwhelming download signals and known authoritative repositories. Manual override: APPROVED.

*No postinstall scripts present on three or @types/three (verified: `npm view three scripts.postinstall` returned empty).*

---

## Architecture Patterns

### System Architecture Diagram

```
phone (60 Hz)
    │  WebRTC unreliable data channel (binary, 36 bytes)
    ▼
room.ts ondatachannel
    │  evt.data (ArrayBuffer)
    │  dc.binaryType = 'arraybuffer'
    ▼
decode.ts::decodePacket(buf)
    │  version check (byte 0 === 1)
    │  seq-drop check: diff = (newSeq - lastSeq) & 0xFFFF > 32767 → DROP
    ▼
targetStateStore Map<playerId, PlayerState>
    │  updated ~60 Hz (arrival-driven)
    │
    │  read ~60 Hz (rAF-driven, decoupled)
    ▼
Three.js rAF loop (scene.ts or inline in room.ts)
    │  for each player in targetStateStore:
    │    mesh.quaternion.slerp(state.targetQuat, 0.3)
    │    mesh.position.set(state.activePosition)
    │    update HUD label DOM
    │    color flash if state.touchActive
    │    update trail BufferGeometry if trail enabled
    │  renderer.render(scene, camera)
    │  labelRenderer.render(scene, camera)   [CSS2DRenderer]
    ▼
WebGL canvas (full viewport) + CSS2D label overlay
    │
    │  HUD overlay (always visible, absolute div): "N/8 connected" + position mode
    │  TAB overlay (keydown/keyup): full roster with channel state

Signaling path (separate from sensor hot-path):
phone.ts ─[WebTransport/WS]─► wt_server.rs ─[WebTransport/WS]─► room.ts
  (ICE candidates, offers, player-ready, room events)
```

### Recommended Project Structure

```
client/src/
├── sensor/
│   ├── encode.ts        # (existing) phone-side encoder
│   ├── decode.ts        # (new) desktop decoder — mirrors encode.ts
│   └── ...
├── scene.ts             # (new) Three.js scene init + rAF loop (or inline in room.ts)
├── room.ts              # (modified) adds WT transport + ondatachannel decode + showGameView()
├── types.ts             # (existing, no change) SensorPacket, Quaternion, Vector3
└── ...
client/index.html        # (modified) add <canvas id="game-canvas">, HUD divs, TAB overlay
```

**Recommendation on scene.ts vs inline in room.ts:**
The CONTEXT.md decision (D-04) says to embed in room.ts. For planning purposes: if the scene code exceeds ~150 lines, extract to `scene.ts` and import into `room.ts`. This keeps room.ts manageable and makes scene code unit-testable. The planner should structure this as a separate file that exports `initScene(container)` and `updateScene(store)`.

### Pattern 1: WebTransport Migration in room.ts (D-01)

**What:** Replace WebSocket with WebTransport as the primary signaling transport, with WS fallback. Copy the pattern from phone.ts exactly.

**When to use:** On DOMContentLoaded, in initDesktopPage.

**Key structural change:** The existing `connectWS()` / `sendMessage()` / `sendTo()` helpers become transport-agnostic wrappers. Add module-level `transport: WebTransport | null` and `useWt = false`. Replace `ws.send(...)` calls in `sendMessage` and `sendTo` with `if (useWt) { sendWtMessage(...) } else { ws.send(...) }`.

```typescript
// Source: phone.ts pattern (project codebase, existing)
let transport: WebTransport | null = null;
let useWt = false;

async function connectDesktopWT(): Promise<boolean> {
  if (typeof WebTransport === 'undefined') return false;
  const wtUrl = 'https://' + location.hostname + ':4433';
  try {
    transport = new WebTransport(wtUrl);
    await transport.ready;
    // Verify getReader() available (iOS compat — desktop Chrome doesn't need this but keep consistent)
    if (typeof (transport.incomingBidirectionalStreams as ReadableStream).getReader !== 'function') {
      throw new Error('getReader not supported');
    }
    listenForServerPushes(transport);
    myId = crypto.randomUUID();
    await sendWtMessage(transport, { type: 'register', from: myId, to: '', payload: {} });
    useWt = true;
    setupTransportClosedHandler(transport);
    return true;
  } catch (err) {
    console.warn('[WT] Desktop connect failed, falling back to WS:', err);
    transport = null;
    useWt = false;
    return false;
  }
}
```

### Pattern 2: Binary Packet Decode (DESK-03)

**What:** decode.ts reads the 36-byte D-14 layout in reverse of encode.ts. Uses `getFloat16` from `@petamoriken/float16`.

**Key points:**
- Must check `view.byteLength < 36` and `view.getUint8(0) !== SCHEMA_VERSION` — drop on either condition
- All float16 reads are little-endian (`true` as third arg to `getFloat16`)
- Touch coordinates: `view.getUint16(32, true) / 65535` to recover normalized [0,1]
- `touchActive`: `view.getUint8(31) === 1`

```typescript
// Source: encode.ts D-14 layout (project codebase), mirrors encode with getFloat16
import { getFloat16 } from '@petamoriken/float16';
import { SCHEMA_VERSION, BUF_SIZE } from './encode';
import type { SensorPacket } from '../types';

export function decodePacket(buf: ArrayBuffer): SensorPacket | null {
  if (buf.byteLength < BUF_SIZE) return null;  // V5: truncated packet
  const view = new DataView(buf);
  if (view.getUint8(0) !== SCHEMA_VERSION) return null; // V5: version mismatch
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

### Pattern 3: Uint16 Sequence-Drop (DESK-03, D-09)

**What:** Half-distance serial number comparison (RFC 1982). Correct for wraparound at 65535→0.

**The exact 3-line implementation:**

```typescript
// Source: RFC 1982 serial number arithmetic (ASSUMED — standard algorithm, widely documented)
function isNewerSeq(newSeq: number, lastSeq: number): boolean {
  const diff = (newSeq - lastSeq) & 0xFFFF;
  return diff > 0 && diff <= 32767;
}
// Usage in ondatachannel handler:
// const state = targetStateStore.get(phoneId);
// if (state && !isNewerSeq(pkt.seq, state.lastSeq)) return; // drop out-of-order
```

This handles:
- `newSeq === lastSeq`: diff=0 → false (duplicate, drop)
- Normal increment: diff=1..32767 → true (accept)
- Wraparound: e.g. lastSeq=65534, newSeq=1: diff=(1-65534)&0xFFFF=3 → true (accept)
- Delayed old packet: e.g. lastSeq=100, newSeq=50: diff=(50-100)&0xFFFF=65486 > 32767 → false (drop)

### Pattern 4: RTCDataChannel Binary Receive

**What:** In the existing `ondatachannel` handler in room.ts (line 271), wire up decode.

**Critical:** Set `dc.binaryType = 'arraybuffer'` BEFORE the channel opens. Default in Chrome is already arraybuffer, but must be set explicitly for Firefox compatibility. [CITED: developer.mozilla.org/en-US/docs/Web/API/RTCDataChannel/binaryType]

```typescript
// Source: room.ts line 271 (project codebase), extended for Phase 6
pc.ondatachannel = function (evt: RTCDataChannelEvent) {
  const dc = evt.channel;
  dc.binaryType = 'arraybuffer'; // MUST set before open — Firefox default is 'blob'
  dc.onopen = function () {
    console.info('[WebRTC] data channel open phone=' + tag);
    sendMessage('rtc-channel-ready', { with: phoneId });
  };
  dc.onmessage = function (msgEvt: MessageEvent<ArrayBuffer>) {
    const pkt = decodePacket(msgEvt.data);
    if (!pkt) return;                              // malformed or version mismatch
    const state = targetStateStore.get(phoneId);
    if (state && !isNewerSeq(pkt.seq, state.lastSeq)) return; // out-of-order drop
    updateTargetState(phoneId, pkt);
  };
};
```

### Pattern 5: Three.js Scene Init + rAF Loop (DESK-05)

**What:** Standard Three.js scene setup. Initialised once on first `player-ready`. Canvas goes full-viewport.

**Import path for CSS2DRenderer:**
```typescript
import { CSS2DRenderer, CSS2DObject } from 'three/examples/jsm/renderers/CSS2DRenderer.js';
```

**Full-viewport canvas CSS (add to index.html `<style>`):**
```css
#game-canvas {
  position: fixed;
  top: 0; left: 0;
  width: 100vw; height: 100vh;
  display: none;   /* hidden until showGameView() */
}
#game-hud {
  position: fixed;
  top: 12px; left: 16px;
  z-index: 10;
  color: #fff;
  font-family: monospace;
  font-size: 14px;
  pointer-events: none;
  display: none;
}
#game-tab-overlay {
  position: fixed;
  top: 0; left: 0;
  width: 100%; height: 100%;
  background: rgba(0,0,0,0.6);
  z-index: 20;
  display: none;
  padding: 32px;
  font-family: monospace;
  color: #fff;
}
```

**Scene init:**
```typescript
// Source: Three.js r185 docs pattern (ASSUMED — standard setup, see threejs.org/docs)
import * as THREE from 'three';
import { CSS2DRenderer, CSS2DObject } from 'three/examples/jsm/renderers/CSS2DRenderer.js';

let renderer: THREE.WebGLRenderer;
let labelRenderer: CSS2DRenderer;
let scene: THREE.Scene;
let camera: THREE.PerspectiveCamera;
let animRunning = false;

function initScene(canvas: HTMLCanvasElement, container: HTMLElement): void {
  scene = new THREE.Scene();
  scene.background = new THREE.Color(0x111111);

  camera = new THREE.PerspectiveCamera(60, canvas.clientWidth / canvas.clientHeight, 0.1, 1000);
  camera.position.set(0, 1.5, 4);
  camera.lookAt(0, 0, 0);

  renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
  renderer.setSize(canvas.clientWidth, canvas.clientHeight);
  renderer.setPixelRatio(window.devicePixelRatio);

  labelRenderer = new CSS2DRenderer();
  labelRenderer.setSize(canvas.clientWidth, canvas.clientHeight);
  labelRenderer.domElement.style.position = 'absolute';
  labelRenderer.domElement.style.top = '0';
  labelRenderer.domElement.style.pointerEvents = 'none';
  container.appendChild(labelRenderer.domElement);

  // Lights
  scene.add(new THREE.AmbientLight(0xffffff, 0.6));
  const dirLight = new THREE.DirectionalLight(0xffffff, 0.8);
  dirLight.position.set(5, 10, 5);
  scene.add(dirLight);

  // Grid floor (G toggleable, default on)
  const grid = new THREE.GridHelper(10, 10, 0x444444, 0x333333);
  scene.add(grid);

  window.addEventListener('resize', onWindowResize);

  if (!animRunning) { animRunning = true; animate(); }
}

function onWindowResize(): void {
  const w = window.innerWidth, h = window.innerHeight;
  camera.aspect = w / h;
  camera.updateProjectionMatrix();
  renderer.setSize(w, h);
  labelRenderer.setSize(w, h);
}

function animate(): void {
  requestAnimationFrame(animate);
  updateSceneFromStore();
  renderer.render(scene, camera);
  labelRenderer.render(scene, camera);
}
```

### Pattern 6: SLERP Rotation in rAF Loop (DESK-05, D-12)

**What:** Each frame, for every player with a mesh, interpolate toward the target quaternion from the latest decoded packet.

**API:** `THREE.Quaternion.slerp(qb, t)` — modifies `this` quaternion in place toward `qb` by factor `t`. Returns `this`. [CITED: threejs.org/docs/#api/en/math/Quaternion]

```typescript
// Source: Three.js Quaternion docs (CITED: threejs.org/docs/#api/en/math/Quaternion)
const SLERP_ALPHA = 0.3; // D-12: configurable in code, not exposed in UI for Phase 6

function updateSceneFromStore(): void {
  for (const [playerId, state] of targetStateStore) {
    const obj = playerObjects.get(playerId);
    if (!obj) continue;

    // SLERP quaternion toward target (never set directly — avoids jitter)
    const tq = state.targetQuat;  // THREE.Quaternion updated from decoded packet
    obj.mesh.quaternion.slerp(tq, SLERP_ALPHA);

    // Position (mode toggled by P key)
    if (positionMode === 'gesture') {
      obj.mesh.position.set(state.dx, state.dy, state.dz);
    } else {
      obj.mesh.position.set(state.px, state.py, state.pz);
    }

    // Touch flash: set material emissive, clear after 100ms
    if (state.touchActive && !obj.flashing) {
      obj.flashing = true;
      (obj.mesh.material as THREE.MeshStandardMaterial).emissive.setHex(0xffffff);
      setTimeout(() => {
        (obj.mesh.material as THREE.MeshStandardMaterial).emissive.setHex(0x000000);
        obj.flashing = false;
      }, 100);
    }
  }
}
```

### Pattern 7: Per-Slot HSL Color Assignment

**What:** Evenly spaced hues across 8 slots. THREE.Color.setHSL(h, s, l) where h is in [0,1].

```typescript
// Source: ASSUMED — standard HSL evenly-spaced palette
function slotColor(slot: number): THREE.Color {
  // slot is 1-based (1..8), map to 0-based for hue
  return new THREE.Color().setHSL((slot - 1) / 8, 0.7, 0.55);
}
// Results: hues at 0°, 45°, 90°, 135°, 180°, 225°, 270°, 315°
// Colors: red, orange-yellow, yellow-green, cyan-green, cyan, blue, violet, magenta
```

### Pattern 8: Motion Trail (D-14, D-15, T key)

**What:** Ring buffer of N past positions stored as a Float32Array, rendered as a THREE.Line with BufferGeometry. Updated each frame. No external dependency.

**Approach:** Keep a ring buffer of the last N positions (e.g. N=30). Each frame, push current position to ring buffer, update Float32Array in BufferGeometry via `geometry.attributes.position.needsUpdate = true`.

```typescript
// Source: ASSUMED — standard BufferGeometry Line trail pattern
const TRAIL_POINTS = 30;

function createTrail(color: THREE.Color): { line: THREE.Line; positions: Float32Array; head: number } {
  const positions = new Float32Array(TRAIL_POINTS * 3); // xyz per point
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute('position', new THREE.BufferAttribute(positions, 3));
  const material = new THREE.LineBasicMaterial({ color, transparent: true, opacity: 0.5 });
  const line = new THREE.Line(geometry, material);
  return { line, positions, head: 0 };
}

// Per frame update:
function updateTrail(trail: ReturnType<typeof createTrail>, x: number, y: number, z: number): void {
  trail.positions[trail.head * 3]     = x;
  trail.positions[trail.head * 3 + 1] = y;
  trail.positions[trail.head * 3 + 2] = z;
  trail.head = (trail.head + 1) % TRAIL_POINTS;
  (trail.line.geometry.attributes['position'] as THREE.BufferAttribute).needsUpdate = true;
}
```

### Anti-Patterns to Avoid

- **Setting mesh.quaternion.set() directly from packet each frame:** Causes visible jitter when packets arrive at 60 Hz but rendering drops to 30 Hz, or vice versa. Always SLERP — never assign directly.
- **Creating new THREE objects inside the rAF loop:** Any `new THREE.Vector3()`, `new THREE.Quaternion()`, or `new THREE.Color()` inside `animate()` causes GC pressure at 60 Hz. Allocate all objects outside the loop.
- **Listening for packets on the same thread as the render loop without decoupling:** The design decision to separate packet reception (updates target-state store) from rendering (reads store per rAF) is correct — do not change this to synchronous processing.
- **Forgetting `dc.binaryType = 'arraybuffer'`:** Firefox defaults to `'blob'`, making `evt.data` a Blob instead of ArrayBuffer. The decode step will fail silently. Set binaryType before the channel opens.
- **CSS2DRenderer domElement appended to document.body while canvas is inside a sub-container:** The CSS2DRenderer element must be in the same relative-positioned container as the WebGL canvas or it will be offset incorrectly. Use a shared wrapper `div` with `position: relative`.
- **Starting the rAF loop multiple times:** If `player-ready` fires for N players, initScene should guard against multiple `animate()` calls. Use the `animRunning` flag shown above.
- **Setting `labelRenderer.domElement.style.pointerEvents = 'auto'`:** Labels will intercept mouse events and the user cannot interact with the canvas. Keep `pointer-events: none`.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Float16 decode | Custom float16 bit manipulation | `getFloat16` from `@petamoriken/float16` (already installed) | Float16 IEEE 754 bit manipulation is error-prone; the library already handles sign, exponent, mantissa, subnormals |
| Quaternion SLERP | Custom slerp math | `THREE.Quaternion.slerp()` | Three.js slerp handles edge cases (antipodalcorrection when dot product < 0) — hand-rolled slerp flips rotation direction |
| Player name label in 3D space | Manual DOM positioning via screen-space projection | `CSS2DRenderer + CSS2DObject` | CSS2DRenderer handles camera transform, projection, and DOM sync every frame automatically |
| Motion trail ring buffer | External library | 30-line BufferGeometry ring buffer (see Pattern 8) | TrailRendererJS is not a three.js official addon; ring buffer approach is simpler and zero-dep |
| Quaternion normalization after slerp | Manual normalize step | None — Three.js slerp always returns normalized result | THREE.Quaternion.slerp normalizes the result; adding a manual `.normalize()` call is unnecessary but harmless |

**Key insight:** Three.js ships batteries-included for this phase. Every geometric primitive, helper, and math utility needed is already in the `three` package. No additional 3D libraries are needed.

---

## Common Pitfalls

### Pitfall 1: WebTransport listenForServerPushes Must Start BEFORE Sending

**What goes wrong:** Desktop registers with the server, then starts the push listener. Any server push that arrives between registration and listener start is permanently dropped (the stream already consumed).

**Why it happens:** `incomingBidirectionalStreams` is a `ReadableStream` — if you don't consume it, streams accumulate in the internal queue. But the reader must be started before messages arrive, not after.

**How to avoid:** In `startPhoneClient()` (phone.ts line 365), `listenForServerPushes(transport)` is called BEFORE `sendWtMessage(register)`. Desktop must do the same. The register message is sent after the listener starts.

**Warning signs:** Missing `player-ready` events; ICE candidates dropped; `offer` messages not received.

### Pitfall 2: `player-ready` Fires Multiple Times (Once Per Player)

**What goes wrong:** Calling `initScene()` on every `player-ready` event creates multiple renderers, multiple rAF loops, and multiple `window.resize` listeners.

**Why it happens:** The server broadcasts `player-ready` for each player that completes the channel handshake. If there are 3 phones, `handlePlayerReady` fires 3 times.

**How to avoid:** Guard `initScene()` with a module-level flag `let sceneInitialized = false`. Call `initScene()` only when `!sceneInitialized`, then set the flag. Subsequent `player-ready` events call `addPlayerToScene(playerId, slot, username)` only.

**Warning signs:** Multiple canvas elements in the DOM; console shows multiple "starting rAF" logs; frame rate halves with each new player.

### Pitfall 3: `dc.binaryType` Must Be Set Before `onopen` Fires

**What goes wrong:** `dc.binaryType = 'arraybuffer'` is set in the `onopen` handler, not in `ondatachannel`. On Firefox, the first few messages may arrive as Blob objects before the assignment takes effect.

**Why it happens:** The browser decides the binary type at channel creation time. Setting it after the channel is open is technically valid but race-prone on Firefox.

**How to avoid:** Set `dc.binaryType = 'arraybuffer'` immediately in the `ondatachannel` callback, BEFORE `dc.onopen` or `dc.onmessage` assignments:
```typescript
pc.ondatachannel = (evt) => {
  const dc = evt.channel;
  dc.binaryType = 'arraybuffer';  // ← FIRST line, before any other handlers
  dc.onopen = ...;
  dc.onmessage = ...;
};
```

**Warning signs:** `decodePacket` receives a Blob object; `buf.byteLength` throws TypeError; Firefox-only decode failures.

### Pitfall 4: Three.js AxesHelper is Additive — Must Track and Remove

**What goes wrong:** Adding a new `THREE.AxesHelper` to a mesh every time `A` is pressed results in multiple overlapping helpers. Only removal works reliably if you hold a reference.

**Why it happens:** Three.js `scene.add()` / `mesh.add()` is additive.

**How to avoid:** Store a reference to each AxesHelper per player object. Toggle via `if (axesVisible) { mesh.add(axes); } else { mesh.remove(axes); }` using the stored reference.

**Warning signs:** Axes gizmo grows brighter with each toggle press; performance drops after multiple toggles.

### Pitfall 5: CSS2DRenderer Element Must Be Inside the Same Positioned Container

**What goes wrong:** `labelRenderer.domElement` is appended to `document.body` while the Three.js canvas is inside a `position: fixed` div. Label positions are offset by the container's scroll position or transform.

**Why it happens:** The CSS2DRenderer positions its child elements relative to its own domElement. If the domElement is not in the same stacking context as the canvas, coordinate transforms mismatch.

**How to avoid:** Create a shared `<div id="game-container" style="position: relative; width: 100vw; height: 100vh">` that contains both the `<canvas id="game-canvas">` and the labelRenderer domElement appended into it. Both renderers are then in the same coordinate space.

**Warning signs:** Player name labels are visually offset from the player's 3D box; label position drifts when scrolling.

### Pitfall 6: Allocating THREE Objects Inside the rAF Loop

**What goes wrong:** `new THREE.Quaternion()` or `new THREE.Vector3()` inside `animate()` allocates a new object every frame (60/s). At 3 players this is 180 object allocations/second. GC pauses manifest as frame spikes.

**Why it happens:** JavaScript GC is triggered by allocation pressure. Three.js geometry updates are frequent.

**How to avoid:** Allocate all scratch quaternions and vectors once at module scope (or in `initScene`), then reuse them. The target-state store's `PlayerState.targetQuat` should be a single `THREE.Quaternion` instance that gets `.set(w,x,y,z)` on each packet, not replaced with a new instance.

**Warning signs:** Frame time spikes visible in DevTools Performance tab; `%MinorGC` and `%MajorGC` entries in the timeline.

---

## Code Examples

### Verified patterns from official/codebase sources:

### 1. Quaternion SLERP (Three.js Quaternion API)
```typescript
// Source: CITED threejs.org/docs/#api/en/math/Quaternion
// mesh.quaternion.slerp(qb, t) — mutates 'this' toward qb by factor t [0,1]
// Must NOT create new Quaternion inside rAF — reuse playerState.targetQuat
mesh.quaternion.slerp(playerState.targetQuat, 0.3);
```

### 2. CSS2DObject Label (Three.js CSS2DRenderer)
```typescript
// Source: CITED threejs.org/docs/#examples/en/renderers/CSS2DRenderer
import { CSS2DObject } from 'three/examples/jsm/renderers/CSS2DRenderer.js';

const labelDiv = document.createElement('div');
labelDiv.className = 'player-label';
labelDiv.textContent = username;
const label = new CSS2DObject(labelDiv);
label.position.set(0, 1.2, 0);  // above the box (which is 1 unit tall)
mesh.add(label);  // child of mesh so it follows the mesh
```

### 3. DataView decode using @petamoriken/float16
```typescript
// Source: project codebase encode.ts (verified), mirrored for decode
import { getFloat16 } from '@petamoriken/float16';
const view = new DataView(arrayBuffer);
const qw = getFloat16(view, 7, true);  // littleEndian=true matches encode.ts
```

### 4. GridHelper (toggleable)
```typescript
// Source: ASSUMED — standard Three.js pattern
const grid = new THREE.GridHelper(10, 10, 0x555555, 0x333333);
scene.add(grid);
// Toggle:
grid.visible = gridVisible;
```

### 5. AxesHelper per mesh (toggleable)
```typescript
// Source: ASSUMED — standard Three.js pattern
const axes = new THREE.AxesHelper(0.5);
mesh.add(axes);  // child of mesh, moves with it
// Toggle:
axes.visible = axesVisible;
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `THREE.Geometry` (deprecated) | `THREE.BufferGeometry` | r125 (2021) | All Three.js r185 APIs use BufferGeometry; never use old Geometry |
| Static `THREE.Quaternion.slerp(qa, qb, t, result)` | Instance `mesh.quaternion.slerp(qb, t)` | r121 (static deprecated) | Use instance method; static was removed in r150+ |
| `renderer.domElement` appended via `document.body.appendChild` | Append to a scoped container for CSS2D compat | — | Required for correct CSS2DRenderer positioning |
| `THREE.WebGLRenderer` `gammaOutput` | `renderer.outputColorSpace = THREE.SRGBColorSpace` | r150 | Use SRGBColorSpace, not gammaOutput |

**Deprecated/outdated:**
- `THREE.Geometry`: Removed r125. Use `THREE.BufferGeometry`.
- Static `THREE.Quaternion.slerp()`: Removed post-r150. Use instance `.slerp()`.
- `mesh.quaternion.copy(pkt.orientation)` without slerp: Valid for debug-only, but will cause visual jitter in production.

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | SLERP alpha 0.3 produces visually smooth result at 60 Hz without overshooting | Standard Stack / Code Examples | If too high → quaternion snaps; if too low → lag visible. Empirical tuning required during Phase 6 UAT |
| A2 | Per-slot HSL `setHSL((slot-1)/8, 0.7, 0.55)` produces visually distinct colors for all 8 slots | Code Examples (Pattern 7) | At 0.55 lightness on a dark background, some adjacent hues (e.g. yellow-green vs cyan-green) may be hard to distinguish; lightness or saturation may need adjustment |
| A3 | Motion trail ring buffer of N=30 points at 60 Hz renders without per-frame GC at 8 players | Code Examples (Pattern 8) | If 8×30×3 Float32Array updates per frame causes GC pressure, reduce trail length or use a worker |
| A4 | `CSS2DRenderer` renders player name labels without z-fighting against the box geometry | Architecture Patterns | If labels clip through boxes, need to adjust CSS `z-index` or label 3D position |
| A5 | `window.addEventListener('deviceorientation')` on desktop receives no events (desktop has no IMU) | Architecture | If some DeviceOrientationEvent fires on desktop (e.g. Surface), it must not contaminate the target-state store which is only written by decoded WebRTC packets |

---

## Open Questions

1. **scene.ts vs inline in room.ts**
   - What we know: CONTEXT.md D-04 says "embedded in room.ts". room.ts is already ~966 lines. Three.js scene code will add ~300+ more lines.
   - What's unclear: Whether the planner should split to scene.ts for maintainability.
   - Recommendation: Planner should extract to `client/src/scene.ts` with `initScene()` / `addPlayerToScene()` / `removePlayerFromScene()` / `updateScene()` exports. This makes the scene independently testable and keeps room.ts focused on transport.

2. **Numeric HUD per-player (H key, D-15)**
   - What we know: HUD shows quaternion (w,x,y,z), active displacement/position vector, driftConfidence scalar, active position mode label.
   - What's unclear: Whether the HUD is a CSS2DObject (follows the player box) or a fixed DOM element outside the canvas.
   - Recommendation: Use a fixed `<div id="game-hud-players">` positioned outside the canvas (absolute, overlaid). Update its `textContent` each rAF iteration. CSS2D labels (Pattern 2) are for the player name only, which must track the 3D object. Numeric data is clearer in a separate fixed panel.

3. **TAB overlay DOM construction**
   - What we know: TAB-held shows full roster with player name, slot, channel state.
   - What's unclear: Whether channel state ("WebRTC channel state") means `RTCDataChannel.readyState` or `RTCPeerConnection.connectionState`.
   - Recommendation: Use `RTCDataChannel.readyState` (the actual data channel state: 'connecting' / 'open' / 'closing' / 'closed'). This is more directly relevant to sensor data flow than the peer connection state.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Node.js | npm install three | Yes | v25.6.1 | — |
| npm | package install | Yes | 11.15.0 | — |
| Docker | Server (existing) | Yes | 29.6.0 | — |
| three npm package | DESK-05 | Not installed | 0.185.1 available | None — must install |
| @types/three npm package | TypeScript types | Not installed | 0.185.1 available | None — must install |
| @petamoriken/float16 | decode.ts | Installed (3.9.3) | — | — |
| WebTransport browser API | DESK-01 | Chrome 97+ (desktop development environment) | — | WS fallback (already implemented) |

**Missing dependencies with no fallback:**
- `three@0.185.1` — must be added to `client/package.json` dependencies and installed
- `@types/three@0.185.1` — must be added to devDependencies

**Missing dependencies with fallback:**
- WebTransport blocked by firewall → automatic WebSocket fallback (same pattern as phone.ts)

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | vitest 3.x |
| Config file | `client/vite.config.ts` (test.environment = 'jsdom') |
| Quick run command | `cd client && npm test -- --run tests/decode.test.ts tests/seq-drop.test.ts` |
| Full suite command | `cd client && npm test` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| DESK-03 | decodePacket mirrors encodePacket roundtrip | unit | `npm test -- --run tests/decode.test.ts` | ❌ Wave 0 |
| DESK-03 | isNewerSeq drops out-of-order, wraps at 65535→0 | unit | `npm test -- --run tests/seq-drop.test.ts` | ❌ Wave 0 |
| DESK-04 | updateTargetState stores latest packet, updates lastSeq | unit | `npm test -- --run tests/target-state.test.ts` | ❌ Wave 0 |
| DESK-01 | WT connect → register → listenForServerPushes | manual-only | N/A — WebTransport requires real TLS + server | manual |
| DESK-02 | RTCDataChannel onmessage fires with ArrayBuffer | manual-only | N/A — requires live WebRTC peer | manual |
| DESK-05 | SLERP alpha 0.3 produces visually smooth rotation | manual-only | N/A — visual inspection during UAT | manual |

### Sampling Rate

- **Per task commit:** `cd client && npm test -- --run tests/decode.test.ts tests/seq-drop.test.ts`
- **Per wave merge:** `cd client && npm test`
- **Phase gate:** Full suite green before `/gsd-verify-work`

### Wave 0 Gaps

- [ ] `client/tests/decode.test.ts` — roundtrip: encodePacket → decodePacket returns identical fields; truncated buffer returns null; wrong version returns null
- [ ] `client/tests/seq-drop.test.ts` — isNewerSeq: normal increment, duplicate, backwards, wraparound 65535→0, wraparound 0→1
- [ ] `client/tests/target-state.test.ts` — updateTargetState updates PlayerState.lastSeq and all SensorPacket fields

*(If no gaps: "None — existing test infrastructure covers all phase requirements")*

---

## Security Domain

> security_enforcement is enabled in config.json. ASVS level 1.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No — no new auth surface; WebTransport uses existing reconnect token from Phase 3 | — |
| V3 Session Management | No — session management is unchanged from Phases 3-4 | — |
| V4 Access Control | No — no new access control decisions | — |
| V5 Input Validation | Yes — `decodePacket` must validate all incoming binary fields | See decode.ts Pattern 2: byteLength check + version check + null return on invalid input |
| V6 Cryptography | No — no new cryptographic operations | — |

### Known Threat Patterns for This Stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Malformed binary packet (truncated / garbage bytes) | Tampering | `buf.byteLength < BUF_SIZE` check returns null before any DataView reads |
| Wrong schema version (future phone, old desktop) | Tampering | `view.getUint8(0) !== SCHEMA_VERSION` returns null |
| Replay / out-of-order packet injection | Spoofing | Half-distance uint16 seq-drop rejects old packets |
| Float16 NaN/Infinity in decoded fields | Tampering | getFloat16 can produce NaN/Infinity from certain bit patterns; downstream usage must guard. SensorPacket fields used for THREE.Quaternion.set() — NaN quaternion breaks rendering. Mitigation: `isFinite()` guard on qw/qx/qy/qz before applying to mesh |
| CSS injection via player username in label DOM | Injection | CSS2DObject labelDiv.textContent (not innerHTML) — text assignment, not HTML injection |
| High-frequency packet flood (DoS on rAF performance) | DoS | Packets update a single Map entry per sender; no accumulation. rAF loop reads once per frame regardless of packet rate. Inherently rate-limited by render tick. |

---

## Sources

### Primary (MEDIUM confidence)
- Three.js GitHub (github.com/mrdoob/three.js) — r185 release, package metadata
- npm registry: `npm view three` — version 0.185.1, published 2026-07-01, 11.5M/wk downloads, created 2012-12-07
- project codebase: `client/src/sensor/encode.ts` — D-14 byte layout (exact offsets used to derive decode.ts)
- project codebase: `client/src/phone.ts` — WT dual-path pattern (directly reusable for room.ts migration)

### Secondary (MEDIUM confidence)
- [threejs.org/docs/#api/en/math/Quaternion](https://threejs.org/docs/#api/en/math/Quaternion) — slerp() and slerpQuaternions() API
- [threejs.org/docs/#examples/en/renderers/CSS2DRenderer](https://threejs.org/docs/#examples/en/renderers/CSS2DRenderer) — CSS2DRenderer setup and CSS2DObject
- [developer.mozilla.org/en-US/docs/Web/API/RTCDataChannel/binaryType](https://developer.mozilla.org/en-US/docs/Web/API/RTCDataChannel/binaryType) — binaryType must be set to 'arraybuffer'

### Tertiary (LOW confidence — training knowledge)
- RFC 1982 serial number arithmetic (uint16 seq-drop formula) — standard algorithm, cited in Wikipedia and RFC documentation
- Three.js motion trail via BufferGeometry ring buffer — community pattern, not official Three.js docs

---

## Project Constraints (from CLAUDE.md)

The following CLAUDE.md directives directly apply to Phase 6 implementation:

| Constraint | Impact on Phase 6 |
|------------|-------------------|
| Three.js r185 (0.185.x) is the locked version | Install exactly `three@0.185.1`, not latest |
| msgpackr is listed as serialization stack BUT Phase 5 established DataView + float16 (not msgpackr) — see STATE.md note "Phase 5 Plan 03: DataView + @petamoriken/float16 setFloat16 used for packet encoding — NOT msgpackr" | decode.ts uses DataView + getFloat16, NOT msgpackr |
| DeviceMotionEvent / Sensor rate constraint 60-100Hz | Target-state store may receive up to 100 updates/second per player; rAF loop runs at monitor refresh rate (60Hz typical); the decoupled architecture handles this correctly |
| iOS DeviceMotionEvent requestPermission — handled on phone side only | Desktop has no sensor permission concerns |
| mkcert for local dev TLS | Existing certs are already set up from Phase 1; WebTransport on desktop uses same cert |
| Rust server binary serves as both WT and WS endpoint | No server changes needed in Phase 6; both transport paths are already operational |

---

## Metadata

**Confidence breakdown:**
- Standard stack: MEDIUM — three@0.185.1 verified on npm registry, 13-year established package
- Packet decode architecture: HIGH — derived from exact encode.ts source in codebase (verified by direct file read)
- Seq-drop algorithm: MEDIUM — RFC 1982 cited, formula is standard, but not verified against an authoritative code source in this session
- Three.js SLERP/CSS2DRenderer API: MEDIUM — WebSearch confirmed against threejs.org/docs
- Motion trail implementation: LOW — standard community pattern, not verified in official docs

**Research date:** 2026-07-10
**Valid until:** 2026-08-10 (Three.js docs stable; Three.js r186+ may add features but r185 API is stable)
