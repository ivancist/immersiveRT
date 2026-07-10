---
phase: 05-sensor-fusion-and-packet-encoding
plan: "03"
subsystem: client/sensor
tags: [encoding, binary, float16, calibration, tdd, schema-v1]
status: complete

dependency_graph:
  requires:
    - 05-01  # Vite + types.ts SensorPacket (PHONE-05)
  provides:
    - encodePacket  # 36-byte D-14 binary encoder consumed by Plans 06/07
    - computeCalibration  # ZUPT threshold + Kalman Q for Plans 05, 06
  affects:
    - Phase 6 decoder (wire contract)
    - Plan 05-05 (zupt.ts uses computeCalibration output)
    - Plan 05-06 (phone.ts calls encodePacket on every sample)

tech_stack:
  added:
    - "@petamoriken/float16 setFloat16 — float16 writes for quaternion/position/displacement fields"
    - "jsdom 26.x — vitest peer dep for jsdom test environment (was missing, added as devDep)"
  patterns:
    - "Module-scope ArrayBuffer reuse — _packetBuf allocated once, overwritten every encode call (Pitfall 5)"
    - "safeFloat guard — NaN/Infinity/null neutralised before DataView write (V5 / T-05-01)"
    - "Thin wrapper pattern — runCalibration delegates math to computeCalibration for jsdom testability (D-08)"
    - "Population variance formula for calibration threshold (2×) and Kalman Q (0.1×)"

key_files:
  created:
    - client/src/sensor/encode.ts
    - client/tests/encode.test.ts
  modified:
    - client/package.json  # added jsdom devDep
    - client/package-lock.json

decisions:
  - "encodePacket uses DataView + @petamoriken/float16 setFloat16 — NOT msgpackr (RESEARCH Pitfall 4: MessagePack has no float16 type)"
  - "_packetBuf allocated once at module scope — callers sending over WebRTC must .slice() before next encode (Pitfall 5 no per-tick GC)"
  - "safeFloat applied to all float fields before write — NaN qw encodes to 0, not a poison float16 byte pattern (T-05-01)"
  - "computeCalibration is pure — runCalibration is the thin devicemotion wrapper so calibration math is unit-testable in jsdom (D-08)"
  - "Population variance × 2 for ZUPT threshold; × 0.1 for Kalman Q (RESEARCH Pattern 9 / Pitfall 6 headroom)"

metrics:
  duration_minutes: 2
  completed: "2026-07-09T12:43:41Z"
  tasks_completed: 2
  files_created: 2
  files_modified: 2
  tests_added: 19
  tests_passing: 19
---

# Phase 05 Plan 03: Binary Packet Encoder + Calibration (Schema v1) Summary

**One-liner:** 36-byte DataView encoder (schema v1 D-14) with float16 fields via @petamoriken/float16, safeFloat NaN-guard, and pure computeCalibration for ZUPT/Kalman parameter derivation — TDD RED→GREEN in 2 minutes, 19/19 tests passing.

## What Was Built

`client/src/sensor/encode.ts` implements the binary wire contract that every downstream phase depends on:

- **`encodePacket(pkt, buf?)`** — writes a `SensorPacket` into the D-14 fixed-offset layout using `DataView` + `setFloat16`. Returns a `Uint8Array` view over `_packetBuf` (or caller-supplied buffer). Zero msgpackr usage on the hot path.
- **`safeFloat(v, fallback=0)`** — returns 0 for `null`, `undefined`, `NaN`, and `±Infinity`; otherwise passes the value through. Applied to every float field before the DataView write (V5 input validation / T-05-01).
- **`computeCalibration(samples)`** — pure function: computes population variance of accel-magnitude samples, returns `{ threshold: variance * 2, kalmanQ: variance * 0.1 }`. No DeviceMotion API dependency.
- **`runCalibration(onComplete)`** — thin wrapper: attaches `devicemotion` for 3 s, collects `Math.hypot(ag.x, ag.y, ag.z)` magnitudes, then delegates to `computeCalibration`.
- **`SCHEMA_VERSION = 1`, `BUF_SIZE = 36`, `_packetBuf`** — module-level constants; buffer allocated once (Pitfall 5).

`client/tests/encode.test.ts` — 19 test cases covering: byte count (36), version byte, float16 round-trip (±0.002), seq-wrap at 65536/65537, touch encoding, safeFloat guards (NaN/Infinity/−Infinity/null/undefined/finite), NaN→finite encode proof (T-05-01), computeCalibration zero-variance and known-variance cases, SCHEMA_VERSION and BUF_SIZE constants.

## TDD Gate Compliance

| Gate | Commit | Status |
|------|--------|--------|
| RED — failing tests | `a1baea8` | test(05-03): add failing encode tests |
| GREEN — all tests pass | `ca1cf56` | feat(05-03): implement 36-byte packet encoder + calibration |

## Verification

```
npm run test     → 19/19 passed
npm run typecheck → tsc --noEmit clean (no errors)
grep -c 'msgpackr' client/src/sensor/encode.ts → 0
```

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Missing jsdom peer dependency**
- **Found during:** Task 1 (RED) — running `npm run test` produced `Cannot find package 'jsdom'`
- **Issue:** `vite.config.ts` specifies `environment: 'jsdom'` but `jsdom` was never added as a devDependency. `jsdom` is explicitly listed in vitest's `peerDependencies` and required for the jsdom test environment.
- **Fix:** Installed `jsdom` as a devDependency (`npm install --save-dev jsdom`)
- **Files modified:** `client/package.json`, `client/package-lock.json`
- **Note:** `jsdom` is the official vitest peer dependency for DOM simulation — not a hallucinated or slopsquatted package

## Known Stubs

None — all exported symbols are fully implemented and tested.

## Threat Surface Scan

No new network endpoints, auth paths, file access patterns, or schema changes introduced. The D-14 schema was already declared in `types.ts` (Plan 01). The threat mitigations T-05-01 (safeFloat NaN guard) and T-05-11 (touch coordinate clamp) and T-05-04 (full buffer overwrite on every encode) are implemented and verified by tests.

## Self-Check

Files created/modified:
- `/home/ivancist/Documents/immersiveRT/client/src/sensor/encode.ts` — FOUND
- `/home/ivancist/Documents/immersiveRT/client/tests/encode.test.ts` — FOUND

Commits:
- `a1baea8` (test RED) — in git log
- `ca1cf56` (feat GREEN) — in git log
