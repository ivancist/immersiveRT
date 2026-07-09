---
phase: 05-sensor-fusion-and-packet-encoding
reviewed: 2026-07-09T00:00:00Z
depth: standard
files_reviewed: 10
files_reviewed_list:
  - client/src/phone.ts
  - client/src/room.ts
  - client/src/sensor/devOverlay.ts
  - client/src/sensor/encode.ts
  - client/src/sensor/kalman.ts
  - client/src/sensor/orientation.ts
  - client/src/sensor/zupt.ts
  - client/src/types.ts
  - client/vite.config.ts
  - client/tsconfig.json
findings:
  critical: 2
  warning: 6
  info: 3
  total: 11
status: issues_found
---

# Phase 05: Code Review Report

**Reviewed:** 2026-07-09  
**Depth:** standard  
**Files Reviewed:** 10  
**Status:** issues_found

## Summary

Phase 05 implements the sensor fusion pipeline (OS-orientation → ZUPT → Kalman dead-reckoning → binary encoding) and migrates signaling helpers to TypeScript. The packet encoding schema, Kalman filter, ZUPT detector, and binary layout are individually sound. Two blockers require fixes before this code ships: an XSS vector in the desktop room page and a zero-threshold edge case in calibration that silently disables ZUPT. Six warnings cover logic gaps (a dead `isRecovery` flag, an unvalidated server message field that can crash, a text-node removal bug) and code quality issues (dead code, duplication).

---

## Structural Findings (fallow)

No structural pre-pass was provided for this phase.

---

## Narrative Findings (AI reviewer)

## Critical Issues

### CR-01: XSS via `innerHTML` with server-controlled `pairingUrl`

**File:** `client/src/room.ts:641-644` and `client/src/room.ts:661-665`

**Issue:** `renderQR()` falls back to injecting raw HTML when the QRCode CDN is unavailable or when the `toCanvas` callback errors. In both branches `pairingUrl` — which comes directly from the server's WebSocket `join-ack` payload — is concatenated into an `innerHTML` assignment with no sanitization:

```js
canvas.parentElement.innerHTML =
  '<p style="...">Open: ' +
  pairingUrl + '</p>';   // ← server-controlled string
```

A server that sends `pairing_url: '"><img src=x onerror=alert(1)>'` trivially executes arbitrary script in the desktop player's browser context. The trust boundary here is "our server only", but the pattern is still wrong: server-originated strings must never flow into `innerHTML` unconditionally.

**Fix:** Replace both fallback branches with DOM construction:

```typescript
const p = document.createElement('p');
p.style.cssText =
  'color:#000;font-family:monospace;font-size:12px;word-break:break-all;padding:8px';
p.textContent = 'Open: ' + pairingUrl;
if (canvas.parentElement) {
  canvas.parentElement.replaceChildren(p);
}
```

---

### CR-02: `computeCalibration` returns `threshold: 0` for empty or uniform samples — ZUPT is permanently disabled

**File:** `client/src/sensor/encode.ts:146` and `client/src/sensor/encode.ts:152-155`

**Issue:** Two related paths both produce `threshold: 0`:

1. **Empty samples** (line 146): if `e.acceleration` is null during the entire 3-second window (devices that do not expose linear acceleration), the `if (ag)` guard in `runCalibration` skips every sample. `computeCalibration([])` early-returns `{ threshold: 0, kalmanQ: 0 }`.

2. **Uniform samples**: if the sensor returns the exact same value for all readings (e.g., a simulator), `variance = 0`, so `threshold = variance * 2 = 0` and `kalmanQ = variance * 0.1 = 0`.

The downstream effect in `ZUPTDetector._evaluate()` (zupt.ts:91):

```typescript
return variance < this.adaptiveThreshold;
```

With `adaptiveThreshold = 0`, this becomes `return variance < 0`, which is **always false** — ZUPT never fires. Dead-reckoning velocity and position accumulate without bound for the entire session. Position drift is already bounded by `POSITION_MAX = 100 m` but the Kalman covariance `P` also never resets, so `driftConfidence()` stays near zero. The encoded `px/py/pz` and `driftConfidence` values sent to the desktop are meaningless.

The zero `kalmanQ` feeds `new Kalman1D(0)`, which means `P` never grows (`this.P += 0 * dtSec`), so `driftConfidence()` oscillates only around the initial `P=1` value and never reflects actual filter quality.

**Fix:** Apply a minimum floor in both paths:

```typescript
export function computeCalibration(
  samples: number[],
): { threshold: number; kalmanQ: number } {
  // Sensible defaults: these are safe starting values derived from RESEARCH §Pattern 9.
  // Used when e.acceleration is unavailable or sensor returns constant output.
  if (samples.length === 0) return { threshold: 0.01, kalmanQ: 0.001 };

  const n = samples.length;
  const mean = samples.reduce((sum, v) => sum + v, 0) / n;
  const variance = samples.reduce((sum, v) => sum + (v - mean) ** 2, 0) / n;

  return {
    threshold: Math.max(variance * 2, 0.001),   // never below 0.001 (m/s²)²
    kalmanQ:   Math.max(variance * 0.1, 0.0001), // never below 0.0001
  };
}
```

---

## Warnings

### WR-01: `isRecovery` flag is always `false` — `channel-recovered` state message is never sent

**File:** `client/src/phone.ts:609-614` (declaration) and `677` (use)

**Issue:** `openChannelToPeer` determines recovery by reading the current map entry before `peerConnections.set` overwrites it:

```typescript
const prev = peerConnections.get(peerId);
const isRecovery = prev && prev.dc &&
  (prev.dc.readyState === 'closed' || prev.dc.readyState === 'closing');
```

Every call site in the codebase that re-opens a peer calls `peerConnections.delete(peerId)` **before** calling `openChannelToPeer(peerId)`:

- Line 577-578 (attemptReconnect)
- Line 632-634 (pc.onconnectionstatechange 'failed')
- Line 1106-1107 (visibilitychange handler)

After the delete, `peerConnections.get(peerId)` returns `undefined`, so `isRecovery` is always `false` at runtime. The branch at line 677 (`sendPhoneState({ state: 'channel-recovered', ... })`) is dead code.

**Fix:** Either collect the entry before deleting it at each call site, or remove the `isRecovery` branch and send `channel-recovered` unconditionally on `dc.onopen` when appropriate. The minimal correct fix per call site:

```typescript
// in attemptReconnect (and the other two sites):
toReopen.forEach(function(peerId) {
  // do NOT delete first — openChannelToPeer reads the old entry for isRecovery
  openChannelToPeer(peerId);          // sets the new entry, closes old pc internally
});
// and inside openChannelToPeer, close the old pc if it exists before creating the new one
```

---

### WR-02: `safeFloat` duplicated verbatim between `encode.ts` and `orientation.ts`

**File:** `client/src/sensor/encode.ts:44-47` and `client/src/sensor/orientation.ts:59-62`

**Issue:** Identical implementations exist in both modules. `encode.ts` exports its copy; `orientation.ts` defines a private one. If the semantics ever diverge (e.g., a different fallback default), bugs will surface only on the Madgwick secondary path.

**Fix:** Remove the private copy from `orientation.ts` and import from `encode.ts`:

```typescript
import { safeFloat } from './encode';
```

---

### WR-03: `startMotionIndicator` is dead code — identical logic already inlined in `startSensorPipeline`

**File:** `client/src/phone.ts:1061-1079`

**Issue:** `startMotionIndicator()` is defined but never called anywhere in the codebase. The identical `devicemotion` handler logic (reading `e.acceleration`, computing `motionMag`, toggling `indicator`, managing `_motionIndicatorTimer`) already runs inline inside `startSensorPipeline()` at lines 906-919. If `startMotionIndicator()` were ever accidentally called, it would attach a **second** `devicemotion` listener, causing double-firing of the visual indicator and a stale `_motionIndicatorTimer` race.

**Fix:** Delete the `startMotionIndicator` function (lines 1061-1079) entirely.

---

### WR-04: `room.ts` `handleOffer` and `handleIceCandidate` do not null-check `msg.from` — potential TypeError crash

**File:** `client/src/room.ts:241-243` (`handleOffer`) and `client/src/room.ts:322` (`handleIceCandidate`)

**Issue:** Both functions cast `msg.from` to `string` without guarding against `undefined` or `null`:

```typescript
// handleOffer
const phoneId = msg.from as string;
const tag = phoneId.slice(0, 8);  // throws TypeError if phoneId is undefined
```

```typescript
// handleIceCandidate
const from = msg.from as string;
const pc = desktopPeers.get(from);  // undefined is a valid Map key — silent bug
```

A malformed or adversarially constructed WebSocket message with a missing `from` field causes an uncaught `TypeError` in `handleOffer` (crashing the handler chain) and a silently-missed ICE candidate in `handleIceCandidate`.

**Fix:**

```typescript
function handleOffer(msg: Record<string, unknown>): void {
  const phoneId = typeof msg.from === 'string' ? msg.from : '';
  if (!phoneId) {
    console.warn('[WebRTC] handleOffer: missing from field', msg);
    return;
  }
  // ...
}
```

---

### WR-05: `room.ts` event-log trim uses `firstChild` instead of `firstElementChild`

**File:** `client/src/room.ts:809`

**Issue:**

```typescript
if (log.children.length >= 50) {
  log.removeChild(log.firstChild!);  // firstChild includes text nodes
}
```

`log.children.length` counts only element children, but `log.firstChild` returns any node type including `Text` and `Comment` nodes. If any whitespace text node exists inside `#event-log` (e.g., from an HTML template formatter or an accidental textContent assignment), `removeChild(firstChild)` removes the text node instead of the oldest event entry, allowing elements to grow past 50 and ultimately throwing when `firstChild` is null.

**Fix:**

```typescript
if (log.children.length >= 50) {
  const oldest = log.firstElementChild;
  if (oldest) { log.removeChild(oldest); }
}
```

---

### WR-06: `runCalibration` measures `e.acceleration` variance but ZUPT uses `accelerationIncludingGravity` variance

**File:** `client/src/sensor/encode.ts:179` and `client/src/phone.ts:839`

**Issue:** The calibration listener collects `Math.hypot(ag.x, ag.y, ag.z)` from `e.acceleration` (gravity-removed, mean ≈ 0 m/s² at rest). The ZUPT update in phone.ts line 839 computes the same magnitude from `e.accelerationIncludingGravity` (mean ≈ 9.81 m/s² at rest). While variance is translation-invariant (subtracting the mean before squaring means the noise-floor variance is the same regardless of the gravity offset), there are two risks:

1. On browsers that do not implement `e.acceleration` (some older Android WebViews), `ag` is null for the entire calibration window, `samples` is empty, and `computeCalibration([])` returns `threshold: 0` (see CR-02).
2. The pairing is non-obvious and makes the system harder to audit: a reader expecting ZUPT to use the same signal as calibration must trace both files to verify correctness.

**Fix:** Either have `runCalibration` collect from `accelerationIncludingGravity` (matching what ZUPT measures) and document the choice, or explicitly handle the null-`e.acceleration` case with a fallback to `accelerationIncludingGravity` during calibration.

---

## Info

### IN-01: `lastCompletedGesture` is written but never read — dead write

**File:** `client/src/phone.ts:798` and `862`

**Issue:** `lastCompletedGesture` is declared and updated on each ZUPT event but never consumed anywhere in this or any imported module. The comment says "retained for Phase 6/8 gesture-trigger consumers — do not remove," which is a reasonable forward-compatibility hold. However, TypeScript strict mode (`noUnusedLocals`) will not flag it because the variable IS assigned, and ESLint rules differ. Future readers should be aware this is intentional dead state.

**Fix:** Add a `// eslint-disable-next-line @typescript-eslint/no-unused-vars` comment or a brief `void lastCompletedGesture;` reference so the intent is machine-checkable, or accept as-is until Phase 6/8.

---

### IN-02: `seq` packet counter is not reset when `startSensorPipeline` is restarted

**File:** `client/src/phone.ts:48` and `client/src/phone.ts:790`

**Issue:** `sessionStart` (line 790) is reset to `Date.now()` on each pipeline start, which means packet timestamps restart at 0. But the module-level `seq` counter (line 48) is never reset, so after a reconnect the desktop decoder receives packets where `timestamp` restarts from 0 while `seq` continues from where it left off. This may confuse a decoder that uses `seq` as a monotonic stream identifier and `timestamp` as a session-relative time.

**Fix:** Reset `seq = 0` alongside `sessionStart = Date.now()` at the top of `startSensorPipeline()`, or document that seq is intentionally session-spanning.

---

### IN-03: `Object.assign` wrapping `ahrs` instance adds redundant own property

**File:** `client/src/sensor/orientation.ts:112-115`

**Issue:**

```typescript
export const ahrs = Object.assign(
  new AHRS({ sampleInterval: 60, algorithm: 'Madgwick', beta: 0.3 }),
  { beta: 0.3 as number },
);
```

The `ahrs` npm Madgwick implementation stores `this.beta` as an own property in its constructor, so the `Object.assign({ beta: 0.3 })` call overwrites the same own property with the same value — a no-op. The comment ("The Madgwick closure was initialized with beta=0.3 at construction") appears to hedge against uncertainty about whether the library exposes `this.beta` vs a closure variable; if the latter were true, `rampBeta()` would silently fail to affect filter convergence. Since the library does use `this.beta` internally, `rampBeta` works correctly as written, but the comment should be updated to reflect confirmed behavior rather than leaving uncertainty.

**Fix:** Remove the `Object.assign` wrapper and the comment hedge. Simply:

```typescript
export const ahrs = new AHRS({ sampleInterval: 60, algorithm: 'Madgwick', beta: 0.3 });
```

`rampBeta()` can set `ahrs.beta = ...` directly, and `ahrs.update()` reads `this.beta` from the same object.

---

_Reviewed: 2026-07-09_  
_Reviewer: Claude (gsd-code-reviewer)_  
_Depth: standard_
