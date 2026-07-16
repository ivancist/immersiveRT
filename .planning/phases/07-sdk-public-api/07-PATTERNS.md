# Phase 7: SDK Public API - Pattern Map

**Mapped:** 2026-07-16
**Files analyzed:** 15 (new/moved) across `packages/immersive-rt/` + workspace/config files
**Analogs found:** 12 / 15

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|--------------------|------|-----------|-----------------|----------------|
| `package.json` (repo root, NEW) | config | — | `Cargo.toml` (repo root workspace manifest) | role-match (only existing workspace config in repo) |
| `packages/immersive-rt/package.json` (NEW) | config | — | `client/package.json` | exact (same ecosystem: npm package manifest, same scripts shape) |
| `packages/immersive-rt/vite.config.ts` (NEW) | config | — | `client/vite.config.ts` | role-match (same tool, different build target: lib mode vs multi-entry app) |
| `packages/immersive-rt/tsconfig.json` (NEW) | config | — | `client/tsconfig.json` | exact |
| `packages/immersive-rt/src/index.ts` (NEW) | provider (public entry) | request-response | none (no existing barrel/entry file) | no analog |
| `packages/immersive-rt/src/platform.ts` (NEW) | provider / store | event-driven | `client/src/sensor/webxr.ts` (`XRPositionTracker` class: private state + `ingest()`/`getState()` shape) for class structure; event bus itself has no analog | role-match |
| `packages/immersive-rt/src/transport/connection.ts` (NEW, extracted) | service | request-response + streaming | `client/src/room.ts` (WT/WS dual-path connect block, `desktopPeers`/`pendingICE`/`desktopChannels` maps, `handleOffer`/`handleIceCandidate`, `connectDesktopWT`/`connectWS`) | exact (verbatim extraction target per D-06) |
| `packages/immersive-rt/src/sensor/decode.ts` (MOVED verbatim) | utility (transform) | transform | `client/src/sensor/decode.ts` | exact (byte-identical move) |
| `packages/immersive-rt/src/playerStore.ts` (MOVED verbatim) | store | CRUD | `client/src/playerStore.ts` | exact (byte-identical move) |
| `packages/immersive-rt/src/types.ts` (MOVED verbatim) | model | — | `client/src/types.ts` | exact (byte-identical move) |
| `packages/immersive-rt/src/tick.ts` (NEW) | service | event-driven (tick loop) | `client/src/scene.ts` (rAF loop + `SLERP_ALPHA` constant + per-frame quaternion slerp call, lines ~92-171) for the loop/SLERP-application shape; `client/src/sensor/webxr.ts` (freeze-on-loss convention) for the hold-last-value behavior | role-match, composite of two analogs |
| `packages/immersive-rt/src/slerp.ts` (NEW) | utility (transform) | transform | none (no existing plain-object quaternion math; `scene.ts` uses `THREE.Quaternion.slerp` which is exactly what D-07 says NOT to depend on) | no analog — hand-write per D-07 |
| `packages/immersive-rt/src/latencyOverlay.ts` (NEW) | component (DOM, dev-tool) | event-driven + request-response (`getStats()` async) | `client/src/room.ts` (`updateHud()`/`renderTabRoster()` — `textContent`-only DOM writes, live `RTCDataChannel`/`RTCPeerConnection` state reads) | role-match |
| `packages/immersive-rt/tests/*.test.ts` (NEW + moved) | test | — | `client/tests/decode.test.ts`, `client/tests/webxr.test.ts` | exact (Vitest `describe/it/expect` conventions) |
| `client/src/room.ts` (MODIFIED — shrinks) | controller | request-response | itself (pre-extraction version, this file) | exact (self-modification, not a new file) |

## Pattern Assignments

### `packages/immersive-rt/package.json` (config)

**Analog:** `client/package.json` (`/Users/ivancist/Documents/immersiveRT/client/package.json`)

**Full existing manifest** (lines 1-23):
```json
{
  "name": "immersivert-client",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "test": "vitest run",
    "typecheck": "tsc --noEmit"
  },
  "dependencies": {
    "@petamoriken/float16": "3.9.3",
    "ahrs": "1.3.3",
    "three": "0.185.1"
  },
  "devDependencies": {
    "@types/three": "0.185.1",
    "jsdom": "^29.1.1",
    "typescript": "^5.0.0",
    "vite": "8.1.4",
    "vitest": "^3.0.0"
  }
}
```

**Apply:** Same `scripts` block verbatim (`dev`/`build`/`test`/`typecheck`). New package is `"private": false` (publishable per SDK-01) with `"type": "module"` unchanged. `dependencies` gets only `@petamoriken/float16` (D-06's `decode.ts` extraction target) — NOT `three`/`ahrs` (D-07: zero `three` dependency; `ahrs` is phone-side, untouched). See RESEARCH.md Pattern 2 for the full `exports`/`types`/`files` field additions this analog doesn't need (client is an app, not a published package).

---

### `packages/immersive-rt/vite.config.ts` (config)

**Analog:** `client/vite.config.ts` (`/Users/ivancist/Documents/immersiveRT/client/vite.config.ts`)

**Full existing config** (lines 1-19):
```typescript
import { defineConfig } from 'vite'
import { resolve } from 'path'

export default defineConfig({
  root: __dirname,
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    rollupOptions: {
      input: {
        room: resolve(__dirname, 'index.html'),
        phone: resolve(__dirname, 'phone.html'),
      },
    },
  },
  test: {
    environment: 'jsdom',
  },
})
```

**Apply:** Keep `root: __dirname`, `build.outDir: 'dist'`, `build.emptyOutDir: true`, and the `test: { environment: 'jsdom' }` block verbatim — this is the project's established test-environment convention (also matches Pitfall 2's note that jsdom lacks `requestAnimationFrame`, which the SDK's `tick.ts` fallback must handle). Replace `rollupOptions.input` (multi-entry HTML) with `build.lib` (`entry: resolve(__dirname, 'src/index.ts')`, `formats: ['es']`) plus `vite-plugin-dts({ bundleTypes: true, tsconfigPath: './tsconfig.json' })` and `rollupOptions.external: ['@petamoriken/float16']` — see RESEARCH.md Pattern 1 for the exact block (already verified against installed Vite 8.1.5 types).

---

### `packages/immersive-rt/src/transport/connection.ts` (service, request-response + streaming)

**Analog:** `client/src/room.ts` (`/Users/ivancist/Documents/immersiveRT/client/src/room.ts`)

**Imports pattern** (lines 26-28):
```typescript
// Sensor packet decode pipeline (plan 04: decode→guard→seq-drop→store in ondatachannel)
import * as decode from './sensor/decode';
import * as playerStore from './playerStore';
```
Apply: same relative-import style inside the SDK (now `./sensor/decode` and `./playerStore` are siblings within `packages/immersive-rt/src/`), no path aliases used anywhere in this repo — keep that convention.

**WT-first/WS-fallback connect pattern** (lines 515-611, `connectDesktopWT`/`connectWS`):
```typescript
async function connectDesktopWT(): Promise<boolean> {
  if (useWt && transport) { return true; }
  if (typeof WebTransport === 'undefined') { return false; }
  const wtUrl = 'https://' + location.hostname + ':4433';
  try {
    transport = new WebTransport(wtUrl);
    await transport.ready;
    if (typeof (transport.incomingBidirectionalStreams as ReadableStream).getReader !== 'function') {
      throw new Error('incomingBidirectionalStreams.getReader not supported');
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
Apply: this dual-path pattern (`connectDesktopWT()` tried first, `connectWS()` as fallback via `.then(function(ok) { if (!ok) connectWS(null); })`) is the exact shape `transport/connection.ts`'s `connect()`/exported API should follow internally — D-08's `connect()` public entry point kicks this same sequence off, then also starts the internal tick.

**RTCPeerConnection + data channel setup + decode→guard→store pipeline** (lines 688-831, `handleOffer`):
```typescript
pc.ondatachannel = function (evt: RTCDataChannelEvent) {
  const dc = evt.channel;
  dc.binaryType = 'arraybuffer'; // MUST be set before onopen/onmessage (Firefox defaults to 'blob')
  desktopChannels.set(phoneId, dc);
  dc.onmessage = function (msgEvt: MessageEvent<ArrayBuffer>) {
    const pkt = decode.decodePacket(msgEvt.data);
    if (!pkt) { return; }                              // T-06-03/T-06-04
    if (!decode.isSafePacket(pkt)) { return; }          // T-06-09
    const state = playerStore.targetStateStore.get(phoneId);
    if (state && !decode.isNewerSeq(pkt.seq, state.lastSeq)) { return; } // T-06-05b
    playerStore.updateTargetState(phoneId, pkt);
  };
};
```
Apply: this exact decode→isSafePacket→isNewerSeq→updateTargetState chain is the seam D-06 extracts — preserve all three guards verbatim (security-critical, ASVS V5 per RESEARCH.md). In the SDK, this `dc.onmessage` handler is also where `playerJoin`/`imuUpdate`-adjacent bookkeeping (not `imuUpdate` itself — that fires from the tick per D-14) and the jitter/loss tracker (Pitfall 1) should hook in, since it's the only place raw packet arrival timing is observed.

**ICE candidate queueing pattern** (lines 792-830):
```typescript
pendingICE.set(phoneId, []); // init BEFORE async chain — buffers ICE arriving during setRemoteDescription
pc.setRemoteDescription(offerDesc).then(function () {
  desktopPeers.set(phoneId, pc);
  const queued = pendingICE.get(phoneId) || [];
  pendingICE.delete(phoneId);
  queued.forEach(function (c) { pc.addIceCandidate(c).catch(...); });
  return pc.createAnswer();
})
```
Apply: preserve this ICE-buffering pattern verbatim — it's a known race-condition fix (candidates arriving before `setRemoteDescription` resolves must not be dropped).

**Connection state logging → latency overlay integration point** (lines 709-717):
```typescript
pc.onconnectionstatechange = function () {
  console.info('[WebRTC] connectionState=' + pc.connectionState + ' phone=' + tag);
};
pc.oniceconnectionstatechange = function () {
  console.info('[WebRTC] iceConnectionState=' + pc.iceConnectionState + ' phone=' + tag);
};
```
Apply: per RESEARCH.md Pitfall 1, `latencyOverlay.ts` should read `pc.iceConnectionState`/`pc.connectionState` as a live property (no `getStats()` call needed for ICE state) — the transport layer should expose these live per-`RTCPeerConnection` objects (e.g. a `getPeerConnection(playerId)` accessor) rather than duplicating state tracking.

---

### `packages/immersive-rt/src/sensor/decode.ts` (utility, transform) — MOVED VERBATIM

**Analog:** `client/src/sensor/decode.ts` (`/Users/ivancist/Documents/immersiveRT/client/src/sensor/decode.ts`)

No transformation needed — copy the file unchanged (D-06: "extraction target, unchanged internals"). Only the import path changes: `import type { SensorPacket } from '../types';` stays relative-correct since `types.ts` moves to the same relative position inside `packages/immersive-rt/src/`. Preserve the three exported guards verbatim:
- `decodePacket(buf)` — truncation guard (`byteLength < BUF_SIZE`) + schema version guard (line 54-56)
- `isNewerSeq(newSeq, lastSeq)` — RFC 1982 half-distance uint16 comparison (lines 94-97)
- `isSafePacket(pkt)` — `isFinite` guard on qw/qx/qy/qz (lines 112-114)

These are ASVS V5 input-validation controls (T-06-03/T-06-04/T-06-06/T-06-09) — the plan must not weaken them during the move.

---

### `packages/immersive-rt/src/playerStore.ts` (store, CRUD) — MOVED VERBATIM

**Analog:** `client/src/playerStore.ts` (`/Users/ivancist/Documents/immersiveRT/client/src/playerStore.ts`)

**Core pattern** (lines 75-107) — module-level singleton `Map`, upsert function, delete function:
```typescript
export const targetStateStore = new Map<string, PlayerState>();

export function updateTargetState(phoneId: string, pkt: SensorPacket): void {
  targetStateStore.set(phoneId, {
    qw: pkt.qw, qx: pkt.qx, qy: pkt.qy, qz: pkt.qz,
    dx: pkt.dx, dy: pkt.dy, dz: pkt.dz,
    px: pkt.px, py: pkt.py, pz: pkt.pz,
    driftConfidence: pkt.driftConfidence,
    touchActive: pkt.touchActive, touchX: pkt.touchX, touchY: pkt.touchY,
    lastSeq: pkt.seq, lastTimestamp: pkt.timestamp,
  });
}

export function removePlayerState(phoneId: string): void {
  targetStateStore.delete(phoneId);
}
```
Apply: move unchanged. The docstring's "no THREE types" rule (lines 8-17) is the direct precedent for D-07's stricter "SDK has zero dependency on `three` at all" — the `slerp.ts`/`tick.ts` new files must follow this same discipline. `PlayerState.lastSeq`/`lastTimestamp` fields are exactly what `tick.ts` reads to determine "latest raw packet" for D-08's SLERP-toward-target loop, and what `getRawInput()` (D-06/SDK-06) exposes as `orientationRaw`.

---

### `packages/immersive-rt/src/types.ts` (model) — MOVED VERBATIM

**Analog:** `client/src/types.ts` (`/Users/ivancist/Documents/immersiveRT/client/src/types.ts`)

Move `Quaternion`, `Vector3`, `TouchState`, `SensorPacket` interfaces unchanged (D-07 confirms these plain-object shapes are already the SDK's public type shapes, no redesign). Preserve the docstring note that wire layout is controlled by `encode.ts` byte offsets, not field order here (lines 8-11) — relevant context for anyone reading the moved file in its new location.

---

### `packages/immersive-rt/src/tick.ts` (service, event-driven tick loop) — NEW

**Analog 1 (SLERP application + alpha constant):** `client/src/scene.ts` (`/Users/ivancist/Documents/immersiveRT/client/src/scene.ts`)

```typescript
// lines 92, 95, 168-171
const scratchQuat = new THREE.Quaternion();
const SLERP_ALPHA = 0.5;
// ...
// qz (W3C yaw, alpha) ended up in Three.js z (roll) → visually swapped (Fix 6).
obj.mesh.quaternion.slerp(
  scratchQuat.set(state.qx, state.qz, -state.qy, state.qw),
  SLERP_ALPHA
);
```
Apply: `tick.ts` reproduces the *shape* of this (per-tick SLERP-toward-latest-target-state at a configurable alpha, default 0.5 per D-09) but MUST NOT copy the axis remap (`state.qx, state.qz, -state.qy, state.qw`) — that is the W3C-earth-frame → Three.js-frame conversion, explicitly Three.js-coupled (RESEARCH.md Pitfall 4). `tick.ts` operates on the raw W3C-frame quaternion via the hand-written `slerp.ts` (plain `{w,x,y,z}` objects, D-07), not `THREE.Quaternion`. The alpha value becomes a `connect({ slerpAlpha })` parameter with default `0.5` (D-09), not a hardcoded module constant.

**Analog 2 (freeze/hold-on-loss convention):** `client/src/sensor/webxr.ts` (`/Users/ivancist/Documents/immersiveRT/client/src/sensor/webxr.ts`)

```typescript
// lines 100-114
ingest(frame: XRFrame, refSpace: XRReferenceSpace, nowMs: number = performance.now()): void {
  const { pos, driftConfidence } = readPoseAndConfidence(frame, refSpace);
  if (pos === null) {
    // Pitfall 5 / D-06: freeze — never mutate last-known-good on tracking loss.
    this._driftConfidence = 0;
    return;
  }
  this._lastGood = pos;
  this._driftConfidence = driftConfidence;
  this._window.push({ t: nowMs, x: pos.x, y: pos.y, z: pos.z });
  this._evict(nowMs);
}
```
Apply: D-11 ("on packet gaps, hold at last interpolated value — no extrapolation, no snapping") mirrors this exact freeze-on-loss shape — `tick.ts`'s per-player tick step should early-return (or simply not advance) when no new packet has arrived since the last tick, leaving the last computed smoothed quaternion untouched, matching this class's `if (pos === null) { ...; return; }` guard structure. Also note the constructor-injectable `nowMs` parameter pattern here (`= performance.now()`) — reuse for `tick.ts`'s own timestamp handling to keep it unit-testable (relevant to RESEARCH.md Pitfall 2's `vi.useFakeTimers()` requirement).

---

### `packages/immersive-rt/src/slerp.ts` (utility, transform) — NEW, no analog

No existing hand-written plain-object quaternion SLERP exists in the codebase — `scene.ts` uses `THREE.Quaternion.slerp()` directly, which is exactly the dependency D-07 forbids. Write from scratch (~15 lines) per CONTEXT.md's "Claude's Discretion" note. Follow `playerStore.ts`'s "no THREE types" discipline: operate purely on `{w,x,y,z}` plain objects.

---

### `packages/immersive-rt/src/platform.ts` (provider, event-driven) — NEW

**Analog:** No direct analog in the codebase for the `EventTarget` facade itself (D-12 mandates a hand-rolled zero-dependency wrapper — see RESEARCH.md Pattern 3 for the full synthesized implementation, already vetted against D-13/D-15's exact payload shapes). Structurally closest existing class for "private state + public read method" shape is `client/src/sensor/webxr.ts`'s `XRPositionTracker` (constructor/private fields/public `ingest()`+`getState()` split) — reuse that private-field (`#`-prefixed) convention:

```typescript
// client/src/sensor/webxr.ts pattern (private fields, public accessor)
private _lastGood: { x: number; y: number; z: number } = { x: 0, y: 0, z: 0 };
...
getState(): { x: number; y: number; z: number; dx: number; dy: number; dz: number; driftConfidence: 0 | 0.5 | 1 } { ... }
```
Apply: `Platform` should follow this same "private state, narrow public accessor" shape for `getPlayerInput()`/`getRawInput()` (synchronous reads of tick-maintained state, per D-08), composed with RESEARCH.md's Pattern 3 `EventTarget` facade for `.on()`/`.off()`.

---

### `packages/immersive-rt/src/latencyOverlay.ts` (component, DOM dev-tool exception D-02) — NEW

**Analog:** `client/src/room.ts`'s `updateHud()` (lines 209-241) and `renderTabRoster()` (lines 251-320)

```typescript
// lines 226-240 — textContent-only DOM writes (XSS guard convention, T-06-10b)
if (hudSlots) {
  hudSlots.textContent = connectedCount + '/' + maxCount + ' connected';
}
if (hudMode) {
  hudMode.textContent = 'pos: ' + states.positionModeLabel + '  [P to cycle]';
}
```
```typescript
// lines 255-256 — clearing a container before rebuild
rosterEl.textContent = ''; // XSS-safe: removes all descendants without innerHTML
```
Apply: per RESEARCH.md's Security Domain section, the overlay must use `textContent`-only writes exactly like this — no `innerHTML`, matching the project's established convention (explicitly called "no injection risk — T-06-10b" in `room.ts`). Use `readPeerMetrics()`'s `getStats()` → `candidate-pair` lookup from RESEARCH.md's Code Examples section for RTT, and read `pc.iceConnectionState` as a live property (no `getStats()` needed) exactly as `room.ts`'s `pc.oniceconnectionstatechange` logger already demonstrates is available. Jitter/packet-loss are computed application-side (Pitfall 1) from `playerStore`'s `lastSeq`/`lastTimestamp` fields, not from `getStats()`.

---

### `packages/immersive-rt/tests/*.test.ts` (test) — NEW + MOVED

**Analog:** `client/tests/decode.test.ts` (`/Users/ivancist/Documents/immersiveRT/client/tests/decode.test.ts`)

```typescript
// lines 1-17 — header docstring + import + fixture object convention
import { describe, it, expect } from 'vitest';
import { decodePacket, isSafePacket } from '../src/sensor/decode';
import { encodePacket } from '../src/sensor/encode';
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
Apply: `decode.test.ts`/`target-state.test.ts` relocate unchanged (adjusting only relative import depth) alongside their source files (D-06). New tests (`slerp.test.ts`, `tick.test.ts`, `platform.test.ts`, `latencyOverlay.test.ts`) should follow the same `describe/it/expect` + shared fixture-object convention. For `tick.test.ts`'s dual rAF/setInterval coverage (RESEARCH.md Pitfall 2), mirror `webxr.ts`'s testable-timestamp-injection pattern (`nowMs: number = performance.now()` parameter) so `vi.useFakeTimers()` can drive ticks deterministically.

---

### Root `package.json` (config) — NEW

**Analog:** Root `Cargo.toml` (`/Users/ivancist/Documents/immersiveRT/Cargo.toml`)

```toml
[workspace]
members = ["server"]
resolver = "2"
```
Apply: the npm workspace root config mirrors this exact "root manifest declares members, no other content" shape:
```jsonc
{
  "private": true,
  "workspaces": ["packages/*", "client"]
}
```
Per RESEARCH.md's Pitfall 3, `client/package.json`'s new `immersive-rt` dependency must use a plain semver range (`"*"` or `"^0.1.0"`), NOT `"workspace:*"` (npm doesn't support that pnpm/Yarn-only syntax).

## Shared Patterns

### Guard-first / early-return input validation
**Source:** `client/src/sensor/decode.ts` lines 53-56, 112-114 and `client/src/room.ts` lines 754-771 (`handleOffer`'s `dc.onmessage`)
**Apply to:** `transport/connection.ts`'s packet-receipt path — every decode/guard check returns/drops early on failure, never throws into caller code. Preserve this exact three-guard sequence (`decodePacket` truncation/version guard → `isSafePacket` finite guard → `isNewerSeq` replay guard) verbatim; do not reorder or weaken (ASVS V5, T-06-03/04/05b/06/09).

### `textContent`-only DOM writes (XSS guard)
**Source:** `client/src/room.ts` lines 226-240, 255-256 (explicitly labeled "T-06-10b — no injection risk" in the source)
**Apply to:** `latencyOverlay.ts` — all DOM text writes (latency ms, jitter ms, loss %, ICE state string) must use `element.textContent = ...`, never `innerHTML`, even though current metrics are all numeric/enum (defense in depth / consistency, per RESEARCH.md's Known Threat Patterns table).

### Freeze-on-loss / hold-last-value
**Source:** `client/src/sensor/webxr.ts` lines 100-114 (`ingest()`'s `if (pos === null) { freeze; return; }` guard)
**Apply to:** `tick.ts`'s per-tick advance step (D-11) — on a packet gap, do not extrapolate or reset; leave the previously computed interpolated orientation untouched and simply skip advancing that player this tick.

### No-THREE-types-in-data-layer discipline
**Source:** `client/src/playerStore.ts` docstring lines 8-17 ("Plain numbers only — no THREE types... keeps store jsdom-testable, decoupled from Three.js")
**Apply to:** Every new SDK module (`slerp.ts`, `tick.ts`, `platform.ts`, `transport/connection.ts`) — zero imports of `three` anywhere in `packages/immersive-rt/src/` (D-07). Only `client/src/scene.ts` (unmoved, stays in `client/`) is allowed to import `three` and apply the W3C→Three.js axis remap (Pitfall 4).

### WT-first / WS-fallback dual transport path
**Source:** `client/src/room.ts` lines 515-611, 936-937 (`connectDesktopWT()` tried first via `wtConnectPromise`, `.then(function(ok) { if (!ok) connectWS(null); })` fallback)
**Apply to:** `transport/connection.ts`'s exported `connect()`/internal connection-establishment logic — same ordering and fallback-on-failure behavior, extracted verbatim per D-06.

## No Analog Found

| File | Role | Data Flow | Reason |
|------|------|-----------|--------|
| `packages/immersive-rt/src/index.ts` | provider (barrel entry) | request-response | No existing barrel/public-entry file pattern in the repo (`client/` has no `index.ts`, it's a multi-HTML-entry Vite app) — planner should follow RESEARCH.md's Pattern 2 (`package.json` `exports`/`main`/`types` fields) to determine what this file must export |
| `packages/immersive-rt/src/slerp.ts` | utility (transform) | transform | No plain-object quaternion math exists anywhere in the codebase (`scene.ts` uses `THREE.Quaternion.slerp` directly) — hand-write per D-07/CONTEXT.md's "Claude's Discretion" note; standard SLERP algorithm, not project-specific |
| `packages/immersive-rt/src/platform.ts` (EventTarget facade portion specifically) | provider | event-driven | No existing typed-`EventTarget` wrapper in the codebase — use RESEARCH.md's Pattern 3 (already a complete, ready-to-copy implementation synthesized for D-12's zero-dependency constraint) as the primary source instead of a codebase analog |

## Metadata

**Analog search scope:** `client/src/` (all files), `client/vite.config.ts`, `client/package.json`, `client/tsconfig.json`, `client/tests/`, repo root `Cargo.toml` (for workspace-config precedent)
**Files scanned:** `room.ts`, `playerStore.ts`, `types.ts`, `sensor/decode.ts`, `sensor/webxr.ts`, `scene.ts` (targeted grep for SLERP/remap lines), `vite.config.ts`, `package.json`, `tests/decode.test.ts`, `Cargo.toml`
**Pattern extraction date:** 2026-07-16
