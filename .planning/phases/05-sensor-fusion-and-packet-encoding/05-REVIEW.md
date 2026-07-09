---
phase: 05-sensor-fusion-and-packet-encoding
reviewed: 2026-07-09T00:00:00Z
depth: standard
files_reviewed: 16
files_reviewed_list:
  - client/index.html
  - client/package.json
  - client/phone.html
  - client/src/phone.ts
  - client/src/room.ts
  - client/src/sensor/devOverlay.ts
  - client/src/sensor/encode.ts
  - client/src/sensor/kalman.ts
  - client/src/sensor/orientation.ts
  - client/src/sensor/zupt.ts
  - client/src/types.ts
  - client/tests/encode.test.ts
  - client/tests/kalman.test.ts
  - client/tests/orientation.test.ts
  - client/tests/zupt.test.ts
  - client/tsconfig.json
  - client/vite.config.ts
findings:
  critical: 3
  warning: 6
  info: 2
  total: 11
status: issues_found
---

# Phase 05: Code Review Report

**Reviewed:** 2026-07-09
**Depth:** standard
**Files Reviewed:** 16
**Status:** issues_found

## Summary

Reviewed all 16 files changed during Phase 05. Core data-path logic — eulerToQuat
W3C Z-X-Y formula, Kalman1D mechanics, ZUPTDetector sliding-window variance, binary
packet layout, touch encoding — is mathematically correct and well-tested.

Three blockers require fixes before this code ships. The most surprising is CR-01:
inspection of the installed `ahrs@1.3.3` package source shows that the Madgwick
algorithm stores `beta` as a **closure-captured local variable** never exposed in
its return interface. `rampBeta()` silently writes to an inert JavaScript property;
the filter always runs at the construction-time beta of 0.3. Note: a previous review
pass concluded the opposite in what was labeled IN-03 — that conclusion was incorrect.
This review supersedes it.

CR-02 and CR-03 together cover the calibration signal-mismatch bug that can
permanently disable ZUPT on gyro-less Android devices.

## Structural Findings (fallow)

No structural pre-pass was provided for this phase.

## Narrative Findings (AI reviewer)

---

## Critical Issues

### CR-01: `rampBeta()` is a complete no-op — the Madgwick filter ignores the beta property

**Files:** `client/src/sensor/orientation.ts:112-114, 168-171`
**Confirmed by source:** `client/node_modules/ahrs/Madgwick.js:33, 346-357`
and `client/node_modules/ahrs/index.js:41-46`

**Issue:** The Madgwick factory in `ahrs@1.3.3` stores its gain as a
**closure-local variable**, not as an instance property:

```js
// Madgwick.js line 33
let beta = options.beta || 0.4;
```

The factory's return object contains only `{ update, init, getQuaternion }` — `beta`
is absent (confirmed at Madgwick.js:346). The `AHRS` constructor copies these three
methods onto `this` via `Object.keys` (index.js:45), so no `beta` property ever
exists on the AHRS instance from the library itself.

`orientation.ts` then applies:

```typescript
export const ahrs = Object.assign(
  new AHRS({ sampleInterval: 60, algorithm: 'Madgwick', beta: 0.3 }),
  { beta: 0.3 as number },       // creates a NEW JavaScript property on the wrapper
);
```

`rampBeta` writes to this property:

```typescript
ahrs.beta = Math.max(BETA_FLOOR, ahrs.beta - BETA_STEP);
```

The Madgwick `update()` reads the closure variable `beta`, not `ahrs.beta`. Every
call to `ahrs.update()` uses the original `beta = 0.3` forever, regardless of what
`ahrs.beta` holds. The dev overlay displays a convincingly ramping value via
`ahrs.beta.toFixed(3)`, but this has zero effect on the filter.

Consequence: SENS-02 (beta convergence ramp) is entirely non-functional. The
Madgwick secondary path (`?orient=madgwick`) runs with permanent high-gain beta=0.3,
meaning high responsiveness noise after initial convergence for the lifetime of the
session. Test coverage does not catch this because the tests verify `ahrs.beta`
changes as a property, not that the filter output changes.

**Fix:** Replace the Object.assign shim with a true proxy that re-creates the
algorithm when beta changes, or inline the ~150-line Madgwick implementation
(giving direct access to the closure variable), or wrap `update()` to inject the
current beta via the `deltaTimeSec` overload. Minimal working approach:

```typescript
// orientation.ts — replace ahrs export and rampBeta
let _beta = 0.3;
let _ahrsInner = new AHRS({ sampleInterval: 60, algorithm: 'Madgwick', beta: _beta });

export const ahrs = {
  get beta() { return _beta; },
  set beta(v: number) {
    if (v === _beta) { return; }
    _beta = v;
    // ahrs 1.3.3 has no runtime setter; rebuild the filter with updated beta.
    // State (q0-q3) is lost on rebuild — acceptable during convergence period.
    _ahrsInner = new AHRS({ sampleInterval: 60, algorithm: 'Madgwick', beta: _beta });
  },
  getQuaternion() { return _ahrsInner.getQuaternion(); },
  update(...args: Parameters<typeof _ahrsInner.update>) { return _ahrsInner.update(...args); },
};
```

---

### CR-02: `computeCalibration([])` returns `threshold: 0` — ZUPTDetector permanently disabled

**Files:** `client/src/sensor/encode.ts:146-147`, `client/src/sensor/zupt.ts:91`

**Issue:** When `samples.length === 0`, `computeCalibration` returns:

```typescript
if (samples.length === 0) return { threshold: 0, kalmanQ: 0 };
```

The ZUPT detector receives `adaptiveThreshold = 0`. Inside `_evaluate()`:

```typescript
return variance < this.adaptiveThreshold;  // variance >= 0 always → 0 < 0 = false
```

ZUPT **never fires** for the entire session. Gesture displacement (`dx/dy/dz`)
never resets. Dead-reckoning position drifts without Kalman correction (velocity
is never zeroed). `driftConfidence` stays near zero. The `kalmanQ = 0` also means
covariance `P` never grows (`this.P += 0 * dtSec`), so confidence never reflects
filter quality.

When does `samples.length === 0`? When `e.acceleration` is null throughout the
3-second calibration window — see CR-03 for why this is a realistic device path.

Also: when the phone is held perfectly still in a simulator, variance is exactly 0,
producing `threshold = 0 * 2 = 0` — the same defect.

**Fix:** Apply a safe minimum floor:

```typescript
export function computeCalibration(
  samples: number[],
): { threshold: number; kalmanQ: number } {
  if (samples.length === 0) return { threshold: 0.01, kalmanQ: 0.001 };

  const n = samples.length;
  const mean = samples.reduce((sum, v) => sum + v, 0) / n;
  const variance = samples.reduce((sum, v) => sum + (v - mean) ** 2, 0) / n;

  return {
    threshold: Math.max(variance * 2, 0.001),
    kalmanQ:   Math.max(variance * 0.1, 0.0001),
  };
}
```

---

### CR-03: `runCalibration` collects `e.acceleration` samples but ZUPT runtime uses `e.accelerationIncludingGravity`

**Files:** `client/src/sensor/encode.ts:179`, `client/src/phone.ts:838-839`

**Issue:** The calibration listener reads `e.acceleration` (linear, gravity-removed;
mean ≈ 0 m/s² at rest):

```typescript
// encode.ts:179
const ag = e.acceleration;
if (ag) { ... samples.push(mag); }
```

The ZUPT runtime path reads `e.accelerationIncludingGravity` (mean ≈ 9.81 m/s²
at rest):

```typescript
// phone.ts:838-839
const ag = e.accelerationIncludingGravity;
const mag = Math.hypot(safeFloat(ag?.x), safeFloat(ag?.y), safeFloat(ag?.z));
```

`e.acceleration` (gravity-subtracted linear acceleration) requires a gyroscope for
the device to decompose gravity from total acceleration. On gyro-less Android devices
and on some mobile browsers, `e.acceleration` is `null` while
`e.accelerationIncludingGravity` is available. In those cases every calibration
sample is silently dropped by the `if (ag)` guard, producing 0 samples, and
triggering the CR-02 defect.

Even on devices where both are available, calibrating on the linear signal but
operating ZUPT on the gravity-including signal is a latent mismatch that makes the
variance threshold harder to reason about.

**Fix:** Use `e.accelerationIncludingGravity` in `runCalibration` to exactly match
the runtime path:

```typescript
const handler = (e: DeviceMotionEvent): void => {
  const ag = e.accelerationIncludingGravity;   // always available; matches ZUPT
  if (ag) {
    const mag = Math.hypot(safeFloat(ag.x), safeFloat(ag.y), safeFloat(ag.z));
    samples.push(mag);
  }
};
```

---

## Warnings

### WR-01: `isRecovery` flag is always `false` — `channel-recovered` state message is never sent

**File:** `client/src/phone.ts:611-614` (declaration), `677` (use)

**Issue:** `openChannelToPeer` captures the existing map entry to detect a reconnect:

```typescript
const prev = peerConnections.get(peerId);
const isRecovery = prev && prev.dc &&
  (prev.dc.readyState === 'closed' || prev.dc.readyState === 'closing');
```

Every call site that re-opens a failed peer calls `peerConnections.delete(peerId)`
**before** invoking `openChannelToPeer`, so `prev` is always `undefined`:

- `attemptReconnect` line 576: `peerConnections.delete(peerId)` then `openChannelToPeer(peerId)`
- `pc.onconnectionstatechange 'failed'` line 631: `peerConnections.delete(peerId)` then `openChannelToPeer(peerId)`
- `visibilitychange` line 1106: `peerConnections.delete(peerId)` then `openChannelToPeer(peerId)`

`isRecovery` is always `false` at runtime. The `sendPhoneState({ state: 'channel-recovered' })`
branch on dc.onopen line 677 is dead code.

**Fix:** Capture the entry before deleting it at the three call sites, and pass a
recovery flag explicitly rather than trying to read back the deleted entry:

```typescript
// caller pattern:
const wasOpen = peerConnections.get(peerId)?.channelOpen ?? false;
peerConnections.delete(peerId);
openChannelToPeer(peerId, /* isRecovery */ wasOpen);
```

Or remove the `isRecovery` detection entirely and fire `channel-recovered` on
every dc.onopen that follows a prior connection to the same peer.

---

### WR-02: `safeFloat` duplicated verbatim between `encode.ts` and `orientation.ts`

**Files:** `client/src/sensor/encode.ts:44-47`, `client/src/sensor/orientation.ts:59-62`

**Issue:** Both files contain identical implementations. `encode.ts` exports its
copy; `orientation.ts` holds a private copy. Any future behavioral change to one
silently does not apply to the other.

**Fix:** Remove the private copy from `orientation.ts` and import from `encode.ts`:

```typescript
import { safeFloat } from './encode';
```

---

### WR-03: `startMotionIndicator()` is dead code duplicating live logic

**File:** `client/src/phone.ts:1061-1079`

**Issue:** `startMotionIndicator()` is defined but never called. Its
`devicemotion` handler logic (reading `e.acceleration`, computing magnitude,
toggling `motion-active`, managing `_motionIndicatorTimer`) is duplicated inline
inside `startSensorPipeline()` at lines 906-919. If `startMotionIndicator` were
ever called accidentally, it would attach a **second** `devicemotion` listener,
causing double-firing of the indicator and a stale timer race on `_motionIndicatorTimer`.

**Fix:** Delete the `startMotionIndicator` function (lines 1061-1079) entirely.

---

### WR-04: `handleOffer` and `handleIceCandidate` do not null-check `msg.from` — potential crash

**File:** `client/src/room.ts:241-243, 322`

**Issue:**

```typescript
// handleOffer
const phoneId = msg.from as string;
const tag = phoneId.slice(0, 8);  // TypeError crash if msg.from is undefined
```

```typescript
// handleIceCandidate
const from = msg.from as string;
const pc = desktopPeers.get(from);  // undefined key → silently misses candidate
```

A malformed WebSocket message with a missing `from` field crashes the
`handleOffer` chain with an uncaught `TypeError` on `.slice()`. In
`handleIceCandidate`, `undefined` is a valid `Map.get` key that silently
misses the peer connection, losing an ICE candidate and preventing the channel
from opening.

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

Apply the same guard in `handleIceCandidate`.

---

### WR-05: Event-log trim removes `firstChild` (any node type) instead of `firstElementChild`

**File:** `client/src/room.ts:808-810`

**Issue:**

```typescript
if (log.children.length >= 50) {
  log.removeChild(log.firstChild!);  // firstChild = any Node, not just Elements
}
```

`log.children.length` counts element nodes. `log.firstChild` returns the first
`Node`, which may be a `Text` or `Comment` node if the browser inserts whitespace
(or if `innerHTML` is ever assigned to `#event-log`). When a text node is removed
instead of an entry element, the trim fails silently and the element count can
exceed 50, growing unboundedly. Ultimately `firstChild` returns `null` and the
non-null assertion (`!`) throws.

**Fix:**

```typescript
if (log.children.length >= 50) {
  const oldest = log.firstElementChild;
  if (oldest) { log.removeChild(oldest); }
}
```

---

### WR-06: XSS — server-provided `pairingUrl` concatenated into `innerHTML`

**File:** `client/src/room.ts:641-644, 662-665`

**Issue:** Two fallback branches in `renderQR()` concatenate the server-supplied
`pairingUrl` directly into `innerHTML`:

```typescript
canvas.parentElement.innerHTML =
  '<p style="...">Open: ' + pairingUrl + '</p>';
```

`pairingUrl` arrives from the server's `join-ack` WebSocket payload. A compromised
server, or an operator misconfiguration that allows the `pairing_url` field to
contain arbitrary strings, would result in script execution in the desktop player's
browser context. The fallback paths trigger on CDN load failure and QRCode render
error — precisely the degraded-environment conditions where additional network trust
assumptions are unreliable.

**Fix:** Use DOM construction to avoid parsing HTML:

```typescript
const p = document.createElement('p');
p.style.cssText =
  'color:#000;font-family:monospace;font-size:12px;word-break:break-all;padding:8px';
p.textContent = 'Open: ' + pairingUrl;
if (canvas.parentElement) { canvas.parentElement.replaceChildren(p); }
```

Apply to both occurrences.

---

## Info

### IN-01: `lastCompletedGesture` is written but never read — intentional dead write

**File:** `client/src/phone.ts:798, 862`

`lastCompletedGesture` is declared at the top of `startSensorPipeline` and
updated on every ZUPT event, but never consumed in any code path. The comment
"retained for Phase 6/8 gesture-trigger consumers — do not remove" documents intent.
Since it lives inside the `startSensorPipeline` closure (not module scope), it does
not pollute the public API. No action needed — flagged only for awareness.

---

### IN-02: `types.ts` comment says seq "wraps at 65535"; encoding actually wraps at 65536

**File:** `client/src/types.ts:46`

The comment reads "uint16 counter, wraps at 65535." The encoding at `encode.ts:91`
uses `pkt.seq % 65536`, so the wire value resets to 0 when `seq` equals 65536 — the
maximum on-wire value is 65535, but the wrap event occurs one step later. A decoder
implementing "reset if value == 65535" would misinterpret a legitimate seq=65535 packet
as a wrap boundary.

**Fix:** Clarify:

```typescript
// seq — uint16 counter; values 0–65535 on wire; wraps from 65535 → 0 at seq=65536
```

---

_Reviewed: 2026-07-09_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
