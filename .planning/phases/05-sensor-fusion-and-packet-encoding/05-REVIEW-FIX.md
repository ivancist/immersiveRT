---
phase: 05-sensor-fusion-and-packet-encoding
fixed_at: 2026-07-09T00:00:00Z
review_path: .planning/phases/05-sensor-fusion-and-packet-encoding/05-REVIEW.md
iteration: 1
findings_in_scope: 9
fixed: 9
skipped: 0
status: all_fixed
---

# Phase 05: Code Review Fix Report

**Fixed at:** 2026-07-09
**Source review:** .planning/phases/05-sensor-fusion-and-packet-encoding/05-REVIEW.md
**Iteration:** 1

**Summary:**
- Findings in scope: 9 (3 Critical + 6 Warning; Info excluded by fix_scope: critical_warning)
- Fixed: 9
- Skipped: 0

## Fixed Issues

### CR-01: `rampBeta()` is a complete no-op — the Madgwick filter ignores the beta property

**Files modified:** `client/src/sensor/orientation.ts`
**Commit:** 96b3f96
**Applied fix:** Replaced the `Object.assign` shim with a proper wrapper object that exposes a functional `beta` getter/setter. The setter rebuilds the AHRS instance with the new beta whenever the value changes, because `ahrs@1.3.3` stores beta as a closure-local variable in `Madgwick.js` that cannot be mutated from outside. The `update()` and `getQuaternion()` methods delegate to the current inner instance. `rampBeta()` now actually changes filter behaviour at each step.

---

### CR-02: `computeCalibration([])` returns `threshold: 0` — ZUPTDetector permanently disabled

**Files modified:** `client/src/sensor/encode.ts`
**Commit:** c074706
**Applied fix:** Changed the empty-samples fallback to return `{ threshold: 0.01, kalmanQ: 0.001 }` instead of all-zeros. Also added `Math.max(... , 0.001)` and `Math.max(... , 0.0001)` floors to the non-empty path so that a simulator held perfectly still (variance = 0) also gets a viable threshold instead of zero.

---

### CR-03: `runCalibration` collects `e.acceleration` samples but ZUPT runtime uses `e.accelerationIncludingGravity`

**Files modified:** `client/src/sensor/encode.ts`
**Commit:** c074706
**Applied fix:** Changed `runCalibration`'s DeviceMotion handler to read `e.accelerationIncludingGravity` (the always-available field) instead of `e.acceleration`. This matches the ZUPT runtime path in `phone.ts` exactly, and prevents all calibration samples from being silently dropped on gyro-less Android devices where `e.acceleration` is null.

---

### WR-01: `isRecovery` flag is always `false` — `channel-recovered` state message is never sent

**Files modified:** `client/src/phone.ts`
**Commit:** acfd233
**Applied fix:** Changed `openChannelToPeer` signature to `openChannelToPeer(peerId: string, isRecovery = false)`. Removed the internal `prev`/`isRecovery` detection that was always reading a deleted entry. Updated all three recovery call sites to capture `channelOpen` before deleting from the map and pass it as the `isRecovery` argument: the `attemptReconnect` collect loop now stores `[peerId, entry.channelOpen]` tuples; the `onconnectionstatechange 'failed'` handler captures `wasOpen` before mutating the entry; the `visibilitychange` forEach captures `entry.channelOpen` before the delete.

---

### WR-02: `safeFloat` duplicated verbatim between `encode.ts` and `orientation.ts`

**Files modified:** `client/src/sensor/orientation.ts`
**Commit:** b75113f
**Applied fix:** Removed the private `safeFloat` function from `orientation.ts` and added `import { safeFloat } from './encode'` to use the single exported implementation. The file-level comment block referring to the NaN guard (`safeFloat`) was left intact since `safeFloat` is still used in that file via the import.

---

### WR-03: `startMotionIndicator()` is dead code duplicating live logic

**Files modified:** `client/src/phone.ts`
**Commit:** acfd233
**Applied fix:** Deleted the `startMotionIndicator` function body (the function was never called anywhere). The `_motionIndicatorTimer` variable declaration at module scope was retained because it is actively used by the identical inline logic inside `startSensorPipeline`.

---

### WR-04: `handleOffer` and `handleIceCandidate` do not null-check `msg.from` — potential crash

**Files modified:** `client/src/room.ts`
**Commit:** 420b002
**Applied fix:** In `handleOffer`, replaced `msg.from as string` with `typeof msg.from === 'string' ? msg.from : ''` and added an early return with a console warning when the field is absent. Applied the same guard in `handleIceCandidate`. This prevents the `TypeError: cannot read properties of undefined` crash on `.slice(0,8)` and the silent `Map.get(undefined)` miss on ICE candidates.

---

### WR-05: Event-log trim removes `firstChild` (any node type) instead of `firstElementChild`

**Files modified:** `client/src/room.ts`
**Commit:** 420b002
**Applied fix:** Replaced `log.removeChild(log.firstChild!)` with `const oldest = log.firstElementChild; if (oldest) { log.removeChild(oldest); }`. This correctly targets only element nodes when trimming the 50-entry event log, matching the `log.children.length` count used as the threshold.

---

### WR-06: XSS — server-provided `pairingUrl` concatenated into `innerHTML`

**Files modified:** `client/src/room.ts`
**Commit:** 420b002
**Applied fix:** Replaced both `canvas.parentElement.innerHTML = '<p ...>Open: ' + pairingUrl + '</p>'` assignments (CDN-not-loaded fallback and QRCode render-error fallback) with DOM construction: `document.createElement('p')`, `p.style.cssText = ...`, `p.textContent = 'Open: ' + pairingUrl`, `canvas.parentElement.replaceChildren(p)`. `textContent` assigns a text node, preventing any HTML parsing of the server-supplied URL.

---

## Skipped Issues

None.

---

_Fixed: 2026-07-09_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
