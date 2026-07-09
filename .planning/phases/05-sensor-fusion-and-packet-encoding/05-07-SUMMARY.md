---
phase: 05-sensor-fusion-and-packet-encoding
plan: "07"
subsystem: phone-client-sensor-pipeline
tags: [sensor, zupt, kalman, dead-reckoning, gesture, touch, dev-overlay, webrtc]
dependency_graph:
  requires: [05-03, 05-04, 05-05, 05-06]
  provides: [live-sensor-pipeline, dead-reckoning, gesture-displacement, touch-state, dev-overlay]
  affects: [client/src/phone.ts, client/src/sensor/devOverlay.ts]
tech_stack:
  added: []
  patterns:
    - ZUPT-gated Kalman dead-reckoning with safeFloat-guarded inputs
    - Idempotent touch listener attachment via named handler + guard flag
    - Vite import.meta.env.DEV tree-shake pattern for dev-only overlay
    - quatDelta L1 signal fed to rampBeta for Madgwick convergence
key_files:
  created:
    - client/src/sensor/devOverlay.ts
  modified:
    - client/src/phone.ts
    - .planning/REQUIREMENTS.md
decisions:
  - "POSITION_MAX=100m and GESTURE_MAX=100m as bounded float16-safe drift ceilings (T-05-16 mitigation)"
  - "clamp() defined as const arrow inside devicemotion handler for readability; clamp01 at module scope for touch"
  - "lastCompletedGesture saved before ZUPT reset — retained for Phase 6/8 gesture-trigger consumers"
  - "All three tasks committed atomically (same phone.ts file, interdependent)"
metrics:
  duration: 3 min
  completed: 2026-07-09
  tasks_completed: 3
  tasks_total: 3
  files_created: 1
  files_modified: 2
status: complete
---

# Phase 05 Plan 07: Live ZUPT/Kalman/Gesture/Touch/DevOverlay Summary

**One-liner:** Wired ZUPT-gated Kalman dead-reckoning, per-gesture displacement, live touch listeners, and a dev-only dual-orientation overlay into the 60 Hz sensor packet stream — replacing every Plan 06 placeholder field.

## What Was Built

### Task 1 — ZUPT + Kalman Dead-Reckoning (SENS-03, SENS-04)

`startSensorPipeline` now constructs closure-local `ZUPTDetector(300, zuptThreshold)` and three `Kalman1D(kalmanQ)` instances. The `devicemotion` handler:

- Computes `dtSec` clamped to `[0, 0.1]` (V5: stalled/backward clock cannot produce unbounded integration)
- Guards all `DeviceMotionEvent` values through `safeFloat` before ZUPT/Kalman
- Reads `e.acceleration` for Kalman integration (gravity-removed)
- Reads `Math.hypot(safeFloat(ag?.x), ..., ...)` over `accelerationIncludingGravity` for ZUPT magnitude
- Calls `zupt.update(mag, Date.now())` → on `isStill`: `resetVelocity()` all three Kalman axes, re-anchors `gestureOrigin`, zeroes `gestureDisplacement`
- Fills `px/py/pz` with `clamp(rawPos, POSITION_MAX)` and `driftConfidence` with the axis-averaged `driftConfidence()` scalar
- `lastCompletedGesture` is saved at each ZUPT and retained for Phase 6/8 gesture consumers

### Task 2 — Live Touch Input (SENS-06)

- Module-scope `currentTouch { active, x, y }` and `touchListenersAttached` guard
- Named handlers `onTouchStart`, `onTouchMove`, `onTouchEnd` — not anonymous closures (T-05-17: no listener leak on reconnect)
- `clamp01`-normalized `clientX/innerWidth` and `clientY/innerHeight` so encode's `×65535` uint16 write can never overflow
- `touchend`/`touchcancel` clears `active` but preserves last coordinates (D-13: Phase 6 trajectory use)
- `attachTouchListeners()` is idempotent; called from `startSensorPipeline`; passive listeners on `document.body`
- Packet `touchActive/touchX/touchY` now read from `currentTouch` — no placeholders remain

### Task 3 — Dev Overlay + Madgwick Source-Select + Beta Ramp (D-04, D-15)

New `client/src/sensor/devOverlay.ts`:
- Exports `updateOverlay(pkt, madgwickQuat, zuptFired, hz)`
- Belt-and-suspenders `if (!import.meta.env.DEV) return` at body start
- Lazily injects `#dev-overlay` div (bottom-left, `font:10px monospace`, `color:#0f0`, `pointer-events:none`)
- Shows: OS/packet quaternion (3 dp) vs Madgwick quaternion, `ahrs.beta`, 500ms-latched ZUPT indicator, `driftConfidence`, rolling Hz
- 500ms ZUPT latch via `lastZuptFireTs = performance.now()` on `zuptFired`

In `phone.ts`:
- `updateMadgwick(e)` + `rampBeta(quatDelta(mq, prevMq))` run every tick inside `import.meta.env.DEV`
- `quatDelta` computes L1 quaternion difference as the convergence signal to `rampBeta`
- `useMadgwick` flag (module-scope, default `false`) set from `?orient=madgwick` URL param once per pipeline start
- Packet quaternion source: `primaryQuat` (OS-fused) by default; `mq` (Madgwick) when `useMadgwick` active
- Plan 06 `phoneLog('pkt ...B @...Hz')` byte/Hz line replaced by `updateOverlay(...)` inside `import.meta.env.DEV`
- `phoneLog` retained for all non-sensor (signaling/WebRTC) events
- Production tree-shake verified: `dev-overlay` literal absent from `dist/assets/phone-*.js`

## Verification

| Check | Result |
|-------|--------|
| `npx tsc --noEmit` | PASS |
| `npm run build` emits `dist/assets/phone-*.js` | PASS |
| `OK-DEADRECKON` grep gate | PASS |
| `OK-TOUCH` grep gate | PASS |
| `OK-DEVOVERLAY` grep gate + tree-shake negative check | PASS |

## Deviations from Plan

### Deviation: All three tasks committed atomically

**Rule:** None (minor process deviation, not a code issue)
**Found during:** All tasks
**Reason:** Tasks 1, 2, and 3 all modify `client/src/phone.ts` in interdependent ways — Task 3's `isStill` and `mq` variables are produced by Task 1's Kalman/ZUPT code. Implementing them as three separate edits/commits would have required partial-file staging which is not supported by the task_commit_protocol. A single well-documented commit covers all three tasks.
**Impact:** No functional impact; all acceptance criteria met for each task individually.

## Commits

| Hash | Message |
|------|---------|
| e1642b7 | feat(05-07): wire ZUPT/Kalman dead-reckoning, touch, and dev overlay into sensor pipeline |

## Known Stubs

None. All packet fields (`px/py/pz`, `dx/dy/dz`, `driftConfidence`, `touchActive/X/Y`) now carry real computed values from live sensor input. No placeholder `0` or `false` values remain.

## Threat Surface Scan

No new network endpoints, auth paths, or schema changes introduced. All changes are within the existing phone client's sensor pipeline. Mitigations confirmed applied:

- **T-05-01** (NaN/null poisoning): `safeFloat` applied to all `DeviceMotionEvent` values before ZUPT/Kalman; `dtSec` clamped
- **T-05-11** (touch overflow): `clamp01` before `currentTouch` assignment; encode.ts additionally clamps before `×65535`
- **T-05-15** (dev surface in production): `import.meta.env.DEV` gates; tree-shake verified
- **T-05-16** (unbounded drift): `±POSITION_MAX`/`±GESTURE_MAX` clamps applied; `dtSec` bounded
- **T-05-17** (listener leak): `touchListenersAttached` guard + named handlers

## Self-Check: PASSED

- `client/src/phone.ts` — modified and committed (e1642b7)
- `client/src/sensor/devOverlay.ts` — created and committed (e1642b7)
- `.planning/REQUIREMENTS.md` — SENS-03/04 marked complete, committed (e1642b7)
- Build artifacts present: `dist/assets/phone-*.js`
- `dev-overlay` absent from production bundle: verified
