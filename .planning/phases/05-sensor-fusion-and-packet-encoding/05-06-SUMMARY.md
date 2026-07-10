---
phase: "05"
plan: "06"
subsystem: phone-sensor-pipeline
status: complete
tags: [sensor-pipeline, webrtc, calibration, orientation, packet-encoding]
completed: "2026-07-09"
duration: "8 min"
tasks_completed: 2
tasks_total: 2
files_created: []
files_modified:
  - client/phone.html
  - client/src/phone.ts
requires: [05-02, 05-03, 05-04]
provides: [broadcastPacket, startSensorPipeline, view-calibrating]
affects: [client/src/phone.ts, client/phone.html]
tech_stack_added: []
tech_stack_patterns:
  - "eulerToQuat(OS-DeviceOrientationEvent) → encodePacket(_packetBuf) → broadcastPacket(dc.send)"
  - "runCalibration (3s devicemotion) → showView('view-active') → startSensorPipeline"
  - "CSS linear transition 0→100% width over 3s for countdown bar"
key_decisions:
  - "fold motion indicator into startSensorPipeline devicemotion handler to avoid duplicate listeners"
  - "cast encodePacket return to Uint8Array<ArrayBuffer> for RTCDataChannel.send TS 5.6+ compatibility"
  - "requestWakeLock + startHeartbeat moved to runCalibration callback so they fire after active view shows"
requirements: [PHONE-04, PHONE-05]
---

# Phase 05 Plan 06: Thin Sensor Pipeline — Calibration and Broadcast Summary

**One-liner:** Hold-still calibration scene wired to OS-fused orientation → 36-byte encodePacket → broadcastPacket fan-out on every devicemotion tick.

## What Was Built

### Task 1: Calibration scene in phone.html and showView

Added `#view-calibrating` between `#view-connecting` and `#view-active` in `client/phone.html`. The view contains a "Hold your phone still" heading, a subtitle "Place it flat on a surface.", and a `#calibration-bar` / `#calibration-fill` progress bar that animates from 0% to 100% width over 3 seconds using a CSS `transition: width 3s linear`. The countdown animation is triggered by a double-rAF pattern in `onPlayerReady` so the hidden→visible repaint settles before the width transition fires.

Added `'view-calibrating'` to the id array inside `showView()` in `client/src/phone.ts` so the new view is hidden/shown correctly alongside all other views.

### Task 2: Thin sensor pipeline

Added to `client/src/phone.ts`:

**Imports:** `encodePacket`, `_packetBuf`, `runCalibration`, `safeFloat` from `./sensor/encode`; `eulerToQuat` from `./sensor/orientation`; `SensorPacket`, `Quaternion` types from `./types`.

**Module state:** `sessionStart`, `seq`, `primaryQuat` (OS-fused quaternion), `_calThreshold`, `_calKalmanQ` (calibration params stored for Plan 07).

**`broadcastPacket(uint8: Uint8Array<ArrayBuffer>)`:** Iterates `peerConnections`; for each entry where `entry.channelOpen && entry.dc.readyState === 'open'`, calls `entry.dc.send(uint8)` wrapped in try/catch (T-05-14 mitigation).

**`startSensorPipeline(zuptThreshold, kalmanQ)`:** Stores calibration params for Plan 07. Attaches a `deviceorientation` listener that calls `eulerToQuat(safeFloat(e.alpha), safeFloat(e.beta), safeFloat(e.gamma))` to update `primaryQuat`. Attaches a `devicemotion` listener that builds a `SensorPacket` with real orientation (from `primaryQuat`) and zero placeholders for `dx/dy/dz`, `px/py/pz`, `driftConfidence`, and touch fields, then calls `encodePacket(pkt, _packetBuf) as Uint8Array<ArrayBuffer>` (reusing the module-scope buffer — no per-tick allocation) and `broadcastPacket`. Includes motion indicator visual feedback and a dev Hz/byte log (at most once per second).

**`onPlayerReady` rewired:** Replaces `showView('view-active')` with `showView('view-calibrating')`, triggers the countdown bar animation, then calls `runCalibration(callback)`. The callback shows `view-active`, calls `requestWakeLock`, `startHeartbeat`, and `startSensorPipeline(threshold, kalmanQ)`.

## Verification

- `npx tsc --noEmit` — clean (no errors)
- `npm run build` — emits `dist/assets/phone-qsYPYYGI.js`
- All structural grep checks pass: `runCalibration`, `startSensorPipeline`, `broadcastPacket`, `encodePacket`, `eulerToQuat`, `deviceorientation` in `src/phone.ts`
- `OK-CALIB-VIEW` and `OK-THIN-SLICE` automated checks pass
- No `new ArrayBuffer(` inside the devicemotion handler (Pitfall 5 confirmed)
- `broadcastPacket` checks `dc.readyState === 'open'` before each send

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] TypeScript 5.6+ typed array generic incompatibility**
- **Found during:** Task 2 verification (`npx tsc --noEmit`)
- **Issue:** TypeScript 5.9.3 types `Uint8Array` as `Uint8Array<ArrayBufferLike>` (generic typed arrays new in TS 5.6). `RTCDataChannel.send()` requires `ArrayBufferView<ArrayBuffer>` (concrete `ArrayBuffer`, not `SharedArrayBuffer`). The return value of `encodePacket` couldn't be passed directly to `dc.send`.
- **Fix:** Typed `broadcastPacket` parameter as `Uint8Array<ArrayBuffer>` and cast the `encodePacket` return at the call site: `encodePacket(pkt, _packetBuf) as Uint8Array<ArrayBuffer>`. Cast is correct at runtime because `_packetBuf` is a plain `ArrayBuffer`.
- **Files modified:** `client/src/phone.ts`
- **Commit:** 84930ce

**2. [Rule 2 - Auto-add] Folded motion indicator into startSensorPipeline**
- **Reason:** Calling `startMotionIndicator()` separately would have attached a second `devicemotion` listener. Instead, the motion indicator update logic was folded into the `startSensorPipeline` devicemotion handler. This avoids two concurrent handlers fired per tick and removes the dead `startMotionIndicator` call from the active-view path.
- **Impact:** `startMotionIndicator` function remains defined in the file but is no longer called from `onPlayerReady`'s callback.

## Known Stubs

The following fields in each `SensorPacket` produced by this plan's pipeline are zero/inactive placeholders. Plan 07 replaces them with real dead-reckoning and touch state (this is a deepening slice, not a reduction):

| Field | Placeholder | Plan 07 replacement |
|-------|-------------|---------------------|
| `dx`, `dy`, `dz` | `0` | `getGestureDisplacement` from Kalman1D + ZUPT origin |
| `px`, `py`, `pz` | `0` | `Kalman1D.predict` integration |
| `driftConfidence` | `0` | `Kalman1D.driftConfidence()` |
| `touchActive` | `false` | `currentTouch.active` |
| `touchX`, `touchY` | `0` | `currentTouch.x / y` |

These stubs are intentional and do not prevent Plan 06's stated goal (orientation packets streaming at device rate). Plan 07 is the designated plan to fill them.

## Threat Surface Scan

No new network endpoints or auth paths introduced. The `broadcastPacket` function sends only on existing unreliable WebRTC data channels established in prior plans.

| Mitigation | Status |
|------------|--------|
| T-05-01: NaN from DeviceOrientationEvent | `safeFloat(e.alpha/beta/gamma)` applied before eulerToQuat |
| T-05-04: stale bytes from reused _packetBuf | encodePacket overwrites all 36 offsets each call |
| T-05-14: dc.send throw on closing channel | try/catch wraps each dc.send in broadcastPacket |

## Commits

| Task | Commit | Files |
|------|--------|-------|
| Task 1: Calibration scene + showView | b7fe679 | client/phone.html, client/src/phone.ts |
| Task 2: Thin sensor pipeline | 84930ce | client/src/phone.ts |

## Self-Check: PASSED

| Item | Status |
|------|--------|
| client/phone.html | FOUND |
| client/src/phone.ts | FOUND |
| 05-06-SUMMARY.md | FOUND |
| Commit b7fe679 (Task 1) | FOUND |
| Commit 84930ce (Task 2) | FOUND |
| view-calibrating in phone.html | PASS |
| broadcastPacket in phone.ts | PASS |
| startSensorPipeline in phone.ts | PASS |
| runCalibration in phone.ts | PASS |
