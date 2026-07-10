---
phase: 06-desktop-receive-decode-and-rendering
plan: 02
subsystem: decode-and-store
tags: [decode, binary, sensor, playerStore, tdd, vitest, float16, RFC-1982]

requires:
  - phase: 05-sensor-fusion-and-packet-encoding
    provides: encode.ts D-14 wire layout + SCHEMA_VERSION + BUF_SIZE (single source of truth)
  - phase: 05-sensor-fusion-and-packet-encoding
    provides: SensorPacket type in types.ts

provides:
  - decodePacket(buf) — exact inverse of encodePacket, null on malformed/version-mismatch
  - isNewerSeq(newSeq, lastSeq) — RFC 1982 uint16 half-distance seq-drop predicate
  - isSafePacket(pkt) — isFinite guard on quaternion fields (T-06-06)
  - targetStateStore — Map<string, PlayerState> per-phone target state
  - updateTargetState(phoneId, pkt) — upserts PlayerState from SensorPacket
  - removePlayerState(phoneId) — evicts departed player

affects: [06-03-PLAN, 06-04-PLAN, scene.ts-rAF-loop, room.ts-ondatachannel-wiring]

tech-stack:
  added: []
  patterns:
    - "decode.ts is the exact byte-offset inverse of encode.ts (D-14, all little-endian)"
    - "RFC 1982 half-distance: diff = (newSeq - lastSeq) & 0xFFFF; accept if 0 < diff ≤ 32767"
    - "isSafePacket: isFinite(qw) && isFinite(qx) && isFinite(qy) && isFinite(qz)"
    - "playerStore: plain numbers only, no 3D library types (jsdom-testable)"
    - "TDD RED-GREEN: three failing suites first, then implementation, then typecheck"

key-files:
  created:
    - client/src/sensor/decode.ts
    - client/src/playerStore.ts
    - client/tests/decode.test.ts
    - client/tests/seq-drop.test.ts
    - client/tests/target-state.test.ts
  modified: []

key-decisions:
  - "decode.ts imports SCHEMA_VERSION + BUF_SIZE from ./encode — never redefines them (single source of truth)"
  - "isNewerSeq uses RFC 1982 half-distance: diff = (newSeq - lastSeq) & 0xFFFF; return diff > 0 && diff <= 32767"
  - "isSafePacket checks only quaternion fields (qw/qx/qy/qz) — non-finite displacement/position causes glitches but not NaN propagation to THREE.Quaternion"
  - "PlayerState stores plain JS numbers, no THREE.Quaternion — scene.ts owns 3D object allocation (jsdom-testable store)"
  - "targetStateStore exported as mutable Map for rAF loop direct read (no getter abstraction needed at this stage)"

requirements-completed:
  - DESK-03
  - DESK-04

coverage:
  - id: D1
    description: "decodePacket returns SensorPacket for valid 36-byte schema-v1 buffer; recovers seq, timestamp, qw (±0.002), touch flags/coords within uint16 tolerance"
    requirement: DESK-03
    verification:
      - kind: automated
        ref: "cd client && npm test -- --run tests/decode.test.ts"
        status: pass
  - id: D2
    description: "decodePacket returns null for truncated buffer (<36 bytes) and for wrong schema version byte (T-06-03, T-06-04)"
    requirement: DESK-03
    verification:
      - kind: automated
        ref: "cd client && npm test -- --run tests/decode.test.ts"
        status: pass
  - id: D3
    description: "isNewerSeq correctly accepts newer seqs and drops duplicates, backwards, and large-jump-ambiguous packets (6-case truth table, RFC 1982)"
    requirement: DESK-03
    verification:
      - kind: automated
        ref: "cd client && npm test -- --run tests/seq-drop.test.ts"
        status: pass
  - id: D4
    description: "isSafePacket rejects packets with non-finite quaternion fields (NaN or Infinity); accepts finite quaternions"
    requirement: DESK-03
    verification:
      - kind: automated
        ref: "cd client && npm test -- --run tests/decode.test.ts"
        status: pass
  - id: D5
    description: "updateTargetState upserts all SensorPacket fields + lastSeq + lastTimestamp into targetStateStore per phoneId; two senders stored independently"
    requirement: DESK-04
    verification:
      - kind: automated
        ref: "cd client && npm test -- --run tests/target-state.test.ts"
        status: pass

duration: 7 min
completed: 2026-07-10
status: complete
---

# Phase 6 Plan 2: Binary Decode Core Summary

**decode.ts and playerStore.ts implement the complete decode-drop-store pipeline with three green vitest suites (92 total tests, 0 failures)**

## Performance

- **Duration:** 7 min
- **Started:** 2026-07-10T08:34:47Z
- **Completed:** 2026-07-10T08:42:19Z
- **Tasks:** 2 (T1: RED failing tests, T2: GREEN implementation + typecheck fix)
- **Files created:** 5

## Accomplishments

- Created `client/tests/decode.test.ts` with 15 tests covering roundtrip (seq, timestamp, qw float16, touch flags/coords), truncated buffer, wrong version, and isSafePacket NaN/Inf rejection
- Created `client/tests/seq-drop.test.ts` with 6 isNewerSeq truth-table cases (RFC 1982 half-distance: normal, duplicate, backwards, two wraparound cases, large-jump-ambiguous)
- Created `client/tests/target-state.test.ts` with 12 tests covering upsert, lastSeq/lastTimestamp, per-sender isolation, and removePlayerState
- Implemented `client/src/sensor/decode.ts`: decodePacket (exact D-14 inverse), isNewerSeq (RFC 1982), isSafePacket (isFinite quaternion guard); imports SCHEMA_VERSION + BUF_SIZE from ./encode, never redefines
- Implemented `client/src/playerStore.ts`: PlayerState interface, targetStateStore Map, updateTargetState upsert, removePlayerState; zero 3D library imports
- All 92 tests pass; typecheck exits 0

## Task Commits

1. **Task 1 (RED): Failing tests** — `d06da93` (test)
2. **Task 2 (GREEN): decode.ts + playerStore.ts** — `4763579` (feat)

## Files Created

- `client/src/sensor/decode.ts` — decodePacket, isNewerSeq, isSafePacket
- `client/src/playerStore.ts` — PlayerState interface, targetStateStore, updateTargetState, removePlayerState
- `client/tests/decode.test.ts` — 15 tests: roundtrip + guards + isSafePacket
- `client/tests/seq-drop.test.ts` — 6 tests: isNewerSeq truth table
- `client/tests/target-state.test.ts` — 12 tests: store upsert + isolation + removal

## Decisions Made

- `decode.ts` imports `SCHEMA_VERSION` and `BUF_SIZE` from `./encode` — single source of truth, never redefines
- RFC 1982 half-distance formula: `diff = (newSeq - lastSeq) & 0xFFFF; return diff > 0 && diff <= 32767`
- `isSafePacket` checks only quaternion fields (qw/qx/qy/qz) — non-finite displacement/position causes rendering glitches but not the NaN-propagation failure mode that poisons THREE.Quaternion
- `PlayerState` stores plain JS numbers (no THREE.Quaternion allocation) — decouples the store from the scene lifecycle and makes it jsdom-testable without a WebGL context
- `targetStateStore` exported as a mutable singleton Map — the rAF loop reads it directly each frame; no getter abstraction needed for this internal module

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] seq-drop test case (200, 33000) had arithmetic error**
- **Found during:** Task 2 (first GREEN test run)
- **Issue:** The plan's behavior block stated `isNewerSeq(200, 33000) = false`, citing "large jump >32767 treated as old." But the RFC 1982 half-distance algorithm gives `diff = (200 - 33000) & 0xFFFF = 32736 ≤ 32767 → true`. The plan author computed `33000 - 200 = 32800 > 32767` but used the wrong operand order: the algorithm is `(newSeq - lastSeq) & 0xFFFF`, not `(lastSeq - newSeq)`. With `lastSeq = 33000`, seq 200 falls in the post-wraparound "newer" zone (200 is 32736 steps ahead after wraparound at 65535), NOT in the "behind" zone.
- **Fix:** Changed test case to `isNewerSeq(300, 33000)` → `diff = (300 - 33000) & 0xFFFF = 32836 > 32767 → false`. This correctly demonstrates the "large backward jump dropped" behavior. 300 is 32700 steps behind 33000, which the algorithm correctly drops.
- **Files modified:** `client/tests/seq-drop.test.ts`
- **Committed in:** `4763579` (bundled with GREEN commit as a test correction)

**2. [Rule 3 - Blocking] TypeScript type error: ArrayBuffer | SharedArrayBuffer on Uint8Array.buffer**
- **Found during:** Task 2 typecheck
- **Issue:** `encodePacket(pkt).buffer` has type `ArrayBuffer | SharedArrayBuffer` (TypeScript's lib typing for typed arrays), but `decodePacket` parameter is typed `ArrayBuffer`. TSC reported 9 identical errors in decode.test.ts.
- **Fix:** Added `as ArrayBuffer` cast at each call site in decode.test.ts. One case that slices the buffer for mutation safety (`encodePacket(basePkt).buffer.slice(0) as ArrayBuffer`) preserves the copy semantics to avoid mutating the shared module-level `_packetBuf`.
- **Files modified:** `client/tests/decode.test.ts`
- **Committed in:** `4763579`

---

**Total deviations:** 2 auto-fixed (1× Rule 1 — Bug, 1× Rule 3 — Blocking)
**Impact on plan:** No scope change; all behavioral requirements met; both fixes are correctness-required

## Known Stubs

None — decode.ts and playerStore.ts implement the full contract. Wiring into `room.ts ondatachannel` is deferred to plan 04 as designed.

## Threat Flags

No new network endpoints or auth paths introduced. This plan mitigates three pre-existing threats:
- T-06-03 (truncated buffer): `buf.byteLength < BUF_SIZE` guard in decodePacket
- T-06-04 (wrong schema version): `view.getUint8(0) !== SCHEMA_VERSION` guard
- T-06-06 (non-finite quaternion): `isSafePacket` isFinite guard (applied at wiring time in plan 04)

## Self-Check: PASSED

All 5 implementation/test files confirmed present on disk.
Both task commits (d06da93, 4763579) confirmed in git log.
92/92 tests pass; typecheck exits 0.
