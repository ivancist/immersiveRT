---
phase: quick-260711-0lh
plan: 01
subsystem: sensor-fusion
tags: [phone, webrtc, kalman, quaternion, drift, phone.ts]

requires:
  - phase: 05-phone-imu-sensor-pipeline
    provides: primaryQuat (device→world quaternion via eulerToQuat), Kalman1D dead-reckoning integrators
provides:
  - Corrected rotateDeviceToWorld() applying primaryQuat directly (device→world), fixing acceleration-integration position drift
  - Unit test locking the +90° yaw device→world rotation convention
affects: [phone-motion-controller, kalman-position-tracking]

tech-stack:
  added: []
  patterns:
    - "Quaternion rotation direction locked by dedicated unit test using a known +90° yaw case, not just norm/identity checks"

key-files:
  created:
    - client/tests/phone-rotate.test.ts
  modified:
    - client/src/phone.ts

key-decisions:
  - "rotateDeviceToWorld now applies primaryQuat directly (standard active rotation v'=v+w*t+q_vec*t, t=2*(q_vec x v)) instead of its conjugate, matching scene.ts's unconjugated use of the same device->world quaternion"
  - "Exported rotateDeviceToWorld in-place (no module extraction) to make it unit-testable without touching the call site"

patterns-established:
  - "New quaternion-rotation-direction bugs should be caught by asserting a known non-trivial rotation (e.g. +90 deg yaw), not just identity/norm invariants"

requirements-completed: [QUICK-0lh]

coverage:
  - id: D1
    description: "rotateDeviceToWorld() rotates device-frame acceleration into world frame by applying primaryQuat directly, fixing orientation-dependent spurious acceleration that caused position to drift/run away"
    requirement: "QUICK-0lh"
    verification:
      - kind: unit
        ref: "client/tests/phone-rotate.test.ts#rotateDeviceToWorld — device→world convention (+90° yaw) > device-frame (1,0,0) maps to world-frame (0,1,0) — NOT (0,-1,0)"
        status: pass
      - kind: unit
        ref: "client/tests/phone-rotate.test.ts#rotateDeviceToWorld — device→world convention (+90° yaw) > device-frame (0,1,0) maps to world-frame (-1,0,0) — NOT (1,0,0)"
        status: pass
      - kind: unit
        ref: "client/tests/phone-rotate.test.ts#rotateDeviceToWorld — identity quaternion > leaves an arbitrary vector unchanged"
        status: pass
    human_judgment: true
    rationale: "Unit tests lock the math convention, but the user explicitly deferred physical on-device verification of drift-free motion to a later manual UAT pass — automation cannot observe real IMU drift behavior."

duration: 8min
completed: 2026-07-11
status: reverted
---

## POST-COMPLETION UPDATE (2026-07-11)

On-device UAT showed this fix made control **worse**, not better ("moving
without sense... more difficult to move intentionally than with drift").
Root cause: `scene.ts:180-212` applies a hand-tuned, per-axis negation
(`set(-rdx, -rdz, rdy)`) that was empirically calibrated in earlier sessions
("Fix C, Fix 1") against the OLD conjugate `rotateDeviceToWorld()` output.
The rotation-direction change here altered the world-frame vector's direction
per-orientation (not a fixed axis remap), invalidating that calibration.

Reverted in commit `3703a0c` (restores the conjugate implementation and
removes `client/tests/phone-rotate.test.ts`). The underlying "huge drift,
unusable" bug is still unresolved — likely inherent IMU double-integration
noise rather than rotation-direction correctness (rotating a noisy vector by
q vs q⁻¹ changes its direction, not its magnitude). Continuing diagnosis via
`/gsd-debug`.

# Phase quick-260711-0lh Plan 01: Fix huge position drift in phone motion controller Summary

**Fixed rotateDeviceToWorld() to apply primaryQuat directly instead of its conjugate, eliminating orientation-dependent spurious acceleration that was injected into the Kalman position integrator on every phone tilt.**

## Performance

- **Duration:** 8 min
- **Started:** 2026-07-11T00:38:23+01:00 (plan commit)
- **Completed:** 2026-07-11T00:43:20+01:00
- **Tasks:** 3
- **Files modified:** 2

## Accomplishments
- Corrected the rotation direction in `rotateDeviceToWorld()` — device-frame acceleration is now rotated into world frame using `primaryQuat` directly (standard active quaternion rotation), matching the same device→world convention `scene.ts` already uses unconjugated to orient the rendered mesh
- Replaced the stale comment that incorrectly described `primaryQuat` as world→device
- Exported `rotateDeviceToWorld` in-place so it is independently unit-testable, with zero changes to its call site
- Added `client/tests/phone-rotate.test.ts`, locking the +90° yaw convention (device (1,0,0)→world (0,1,0), device (0,1,0)→world (-1,0,0)) and an identity-quaternion no-op case — this test would have failed against the old conjugate bug
- Ran the full client vitest suite (95 tests across 8 files) — zero regressions

## Task Commits

Each task was committed atomically:

1. **Task 1: Fix rotation direction and comment in rotateDeviceToWorld, and export it** - `ba3e172` (fix)
2. **Task 2: Add unit test locking the device→world rotation convention** - `672c608` (test)
3. **Task 3: Run full client test suite to confirm no regressions** - verification only, no code changes (95/95 tests passed)

**Plan metadata:** commit pending (docs: complete plan — handled by orchestrator)

## Files Created/Modified
- `client/src/phone.ts` - Fixed `rotateDeviceToWorld()` to apply `primaryQuat` directly (not its conjugate); corrected the comment describing the quaternion convention; exported the function for testability
- `client/tests/phone-rotate.test.ts` - New unit test locking the device→world rotation convention using a known +90° yaw quaternion, plus an identity no-op case

## Decisions Made
- Applied the fix exactly as specified in the plan/context (root cause was pre-confirmed, not re-litigated): flip both cross products from reversed to standard operand order, deriving `t = 2·(q_vec × v)` and the additive `q_vec × t` term for the final result.
- Kept the fix scoped entirely inside `rotateDeviceToWorld()` and its comment — did not touch the call site, rotational/gyro ZUPT, the `POSITION_MAX` clamp, or `scene.ts` axis-mapping/negation logic, per explicit out-of-scope instructions.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- The acceleration-integration path now uses the correct device→world rotation; dead-reckoning position should track real phone motion instead of running away to the `POSITION_MAX` clamp.
- No physical-phone manual UAT was performed in this task — the user will verify drift-free position tracking on a real device as a follow-up (per CONTEXT.md decision). This is the one `human_judgment: true` coverage item above.
- Rotational ZUPT (gyro-based stillness detection) remains deferred/out of scope, as decided in CONTEXT.md — residual gyro-noise-driven drift, if any, is a separate future task.

---
*Phase: quick-260711-0lh*
*Completed: 2026-07-11*

## Self-Check: PASSED

- FOUND: client/src/phone.ts
- FOUND: client/tests/phone-rotate.test.ts
- FOUND: ba3e172 (Task 1 commit)
- FOUND: 672c608 (Task 2 commit)
