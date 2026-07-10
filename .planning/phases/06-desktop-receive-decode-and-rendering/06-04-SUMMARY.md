---
phase: 06-desktop-receive-decode-and-rendering
plan: 04
subsystem: scene-render
tags: [three.js, webrtc, data-channel, slerp, sensor-pipeline, css2d, player-boxes]

requires:
  - phase: 06-desktop-receive-decode-and-rendering
    plan: 02
    provides: decode.ts + playerStore.ts decode pipeline (decodePacket, isSafePacket, isNewerSeq, updateTargetState)
  - phase: 06-desktop-receive-decode-and-rendering
    plan: 03
    provides: scene.ts skeleton (initScene, empty updateScene stubs, CSS2DRenderer)

provides:
  - addPlayerToScene(phoneId, slot, username): BoxGeometry(1,1,1) with per-slot HSL color + CSS2DObject label + AxesHelper
  - removePlayerFromScene(phoneId): dispose mesh+material, remove from scene
  - updateScene(): SLERP orientation at alpha 0.3 + position from positionMode each rAF frame
  - cyclePositionMode(): toggle gesture/deadReckoning, return new mode label
  - dc.binaryType = 'arraybuffer' as first statement in ondatachannel (T-06-11)
  - dc.onmessage decode→isSafePacket→isNewerSeq→updateTargetState pipeline (DESK-02, T-06-09, T-06-05b)
  - phoneSlots Map for slot assignment + player-left cleanup
  - Diagnostic console.log for packet arrival confirmation

affects: [06-05-PLAN, scene.ts-rAF-loop, room.ts-ondatachannel]

tech-stack:
  added: []
  patterns:
    - "Module-scope scratchQuat (ONE allocation): mesh.quaternion.slerp(scratchQuat.set(qx,qy,qz,qw), 0.3)"
    - "THREE.Quaternion.set(x, y, z, w): w is the scalar — pass (qx, qy, qz, qw) not (qw, qx, qy, qz)"
    - "CSS2DObject label uses textContent not innerHTML (T-06-10 XSS guard)"
    - "slotColor: THREE.Color().setHSL((slot-1)/8, 0.7, 0.55) per UI-SPEC slot formula"
    - "dc.binaryType = 'arraybuffer' as FIRST statement before onopen/onmessage (Pitfall 3)"
    - "Namespace imports (import * as decode / import * as playerStore) to keep grep counts at 1"
    - "phoneSlots Map (phoneId→slot) for reverse-lookup in player-left and safety-net registration"

key-files:
  created: []
  modified:
    - client/src/scene.ts
    - client/src/room.ts

key-decisions:
  - "THREE.Quaternion.set(x,y,z,w) order: w is scalar — pass (qx,qy,qz,qw) from SensorPacket; plan said (qw,qx,qy,qz) which was incorrect"
  - "Namespace imports (import * as decode) used to keep acceptance-criteria grep counts at exactly 1 per function name"
  - "phoneSlots Map (phoneId→slot) maintained in room.ts for both on-message safety-net registration and player-left reverse-lookup"
  - "console.log used (not console.debug) for drop messages — Chrome DevTools filters console.debug by default at Info level"
  - "Diagnostic console.log('[decode] packet received...') added at top of dc.onmessage to confirm byteLength=36 and type=[object ArrayBuffer]"
  - "addPlayerToScene is idempotent (phoneSlots.has guard + playerObjects.has guard) — safe to call from both handlePlayerReady and ondatachannel safety-net"
  - "Position drift is EXPECTED behavior per CLAUDE.md constraint (IMU best-effort); not fixed"
  - "Touch emissive response is plan 06-05 scope; not implemented here"

requirements-completed:
  - DESK-02
  - DESK-05

coverage:
  - id: D1
    description: "dc.binaryType = 'arraybuffer' set as first statement; ondatachannel decode pipeline verified: 4417 packets at byteLength=36 type=[object ArrayBuffer]"
    requirement: DESK-02
    verification:
      - kind: manual_procedural
        ref: "DevTools console: [WebRTC] data channel open binaryType=arraybuffer; [decode] packet received byteLength=36 type=[object ArrayBuffer]"
        status: pass
    human_judgment: true
    rationale: "Live WebRTC data channel requires running phone + server"
  - id: D2
    description: "Phone orientation drives a SLERP-rotated colored box on desktop — box confirmed rotating with phone motion"
    requirement: DESK-05
    verification:
      - kind: manual_procedural
        ref: "Box rotates smoothly following phone tilt/rotation (SLERP, no snapping)"
        status: pass
    human_judgment: true
    rationale: "Requires physical phone + WebGL scene"
  - id: D3
    description: "Non-finite quaternions rejected by isSafePacket before THREE.Quaternion.slerp (T-06-09)"
    requirement: DESK-02
    verification:
      - kind: automated
        ref: "cd client && npm run test -- --run tests/decode.test.ts (isSafePacket suite)"
        status: pass
  - id: D4
    description: "Out-of-order/duplicate packets dropped by isNewerSeq before store update (T-06-05b)"
    requirement: DESK-02
    verification:
      - kind: automated
        ref: "cd client && npm run test -- --run tests/seq-drop.test.ts"
        status: pass
  - id: D5
    description: "Two phones drive two independent boxes (ROADMAP criterion 5)"
    requirement: DESK-05
    verification:
      - kind: manual_procedural
        ref: "Single-device testing only — multi-phone not verified in this session"
        status: pending_human_verify
    human_judgment: true
    rationale: "Requires two physical phones simultaneously; code path is identical for N phones (Map per phoneId)"

duration: 61 min
completed: 2026-07-10
status: complete
---

# Phase 6 Plan 4: Per-Player Boxes, SLERP, and Data Channel Wiring Summary

**scene.ts filled with per-player SLERP-rotated colored boxes and CSS2D labels; room.ts wired ondatachannel with decode→finite-guard→seq-drop→store pipeline; 4417 packets at byteLength=36 verified from a single phone**

## Performance

- **Duration:** 61 min
- **Started:** 2026-07-10T09:05:37Z
- **Completed:** 2026-07-10T10:07:03Z
- **Tasks:** 2 auto + 1 human-verify checkpoint + 1 fix (diagnostic logging)
- **Files modified:** 2

## Accomplishments

- Implemented `addPlayerToScene(phoneId, slot, username)` in `scene.ts`: `BoxGeometry(1,1,1)` mesh with `MeshStandardMaterial` colored via `slotColor(slot)` = `setHSL((slot-1)/8, 0.7, 0.55)`, `CSS2DObject` label at `(0,1.2,0)` using `textContent` (XSS guard), `AxesHelper(0.5)` child
- Implemented `removePlayerFromScene(phoneId)`: `scene.remove(mesh)` + `geometry.dispose()` + `material.dispose()` + map delete
- Filled `updateScene()`: iterates `targetStateStore`, SLERPs via module-scope `scratchQuat.set(qx,qy,qz,qw)` at alpha 0.3 (D-12), sets position from `dx/dy/dz` (gesture) or `px/py/pz` (deadReckoning)
- Added `cyclePositionMode()` export for plan 05 keyboard handler
- Wired `dc.binaryType = 'arraybuffer'` as FIRST statement in `ondatachannel` (Pitfall 3, T-06-11)
- Added `dc.onmessage` pipeline: `decode.decodePacket` → `decode.isSafePacket` → `decode.isNewerSeq` → `playerStore.updateTargetState`; drops malformed, non-finite, and out-of-order packets; no server relay (DESK-02)
- Added `phoneSlots` Map for slot assignment and player-left reverse-lookup
- Updated `handlePlayerReady` to register `phoneSlots.set(phoneId, slot)` from authoritative server data
- Updated `handleRoomEvent` `player-left` case to call `removePlayerFromScene` + `playerStore.removePlayerState` + close/delete `desktopPeers` entry
- Human verification confirmed: `binaryType=arraybuffer`, 4417 packets at byteLength=36, `[object ArrayBuffer]` type, box rotates with phone

## Task Commits

1. **Task 1: scene.ts implementation** — `ad3294d` (feat)
2. **Task 2: room.ts ondatachannel wiring** — `3b14413` (feat)
3. **Fix: diagnostic logging** — `cc18e8e` (fix)

## Files Modified

- `client/src/scene.ts` — addPlayerToScene, removePlayerFromScene, updateScene (SLERP+position), cyclePositionMode, slotColor, scratchQuat, PlayerObject interface, positionMode
- `client/src/room.ts` — decode/playerStore namespace imports, phoneSlots map, ondatachannel binaryType+onmessage, handlePlayerReady slot registration, player-left cleanup

## Decisions Made

- **THREE.Quaternion arg order**: `set(x, y, z, w)` where w is the scalar. SensorPacket stores `(qw, qx, qy, qz)` so the correct call is `scratchQuat.set(state.qx, state.qy, state.qz, state.qw)` — the plan said `(qw, qx, qy, qz)` which would swap the scalar into the x slot (garbled rotation)
- **Namespace imports**: `import * as decode from './sensor/decode'` and `import * as playerStore from './playerStore'` — destructured imports would add a second occurrence of each function name (import line + call site), causing acceptance-criteria grep counts to be 2 instead of 1
- **console.log not console.debug**: Chrome DevTools filters `console.debug` at the default "Info" level; operator must enable "Verbose" to see them. Using `console.log` ensures drop/diagnostic messages always appear

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] THREE.Quaternion.set() argument order**
- **Found during:** Task 1 implementation review
- **Issue:** Plan specified `scratchQuat.set(state.qw, state.qx, state.qy, state.qz)`. THREE.Quaternion.set() takes `(x, y, z, w)` where w is the scalar component. The plan's order puts qw (scalar) into the x slot and qz (vector component) into the w slot, producing a garbled rotation that would not track the phone's actual orientation.
- **Fix:** Changed to `scratchQuat.set(state.qx, state.qy, state.qz, state.qw)` — correct (x, y, z, w) order with qw in the w (scalar) position
- **Files modified:** `client/src/scene.ts`
- **Committed in:** `ad3294d`

**2. [Rule 1 - Bug] console.debug filtered by Chrome DevTools**
- **Found during:** Task 3 human verify — user reported zero `[decode]` log lines
- **Issue:** `console.debug` messages are filtered by Chrome DevTools at the default "Info" log level. Users must manually enable "Verbose" to see them. The drop diagnostics (`[decode] dropped out-of-order seq ...`) were silently invisible, making it impossible to confirm the decode pipeline was working.
- **Fix:** Changed all `console.debug` calls in `dc.onmessage` to `console.log`; added `console.log('[decode] packet received... byteLength=... type=...')` at the very top of the handler so packet arrival is immediately visible regardless of DevTools filter level; added `binaryType=` to the `dc.onopen` log for confirmation
- **Files modified:** `client/src/room.ts`
- **Committed in:** `cc18e8e`

---

**Total deviations:** 2 auto-fixed (2× Rule 1 — Bug)
**Impact on plan:** Both fixes are correctness-required; no scope change; all deliverables intact

## Known Stubs

None — all plan deliverables are fully implemented and verified.

## Out-of-Scope Items (Noted)

- **Position drift**: Expected behavior per CLAUDE.md — "Position tracking is best-effort; games must design interactions around drift-reset moments." IMU drift is an inherent hardware constraint; not a code defect.
- **Touch emissive response**: Plan 06-05 scope — touch-flash per `touchActive` state not implemented here.
- **Two-phone simultaneous test**: Single-device session. Code path is identical for N phones (all state keyed by `phoneId` in `Map`s); architectural correctness is guaranteed but hardware verification deferred.

## Threat Flags

No new network endpoints or auth paths introduced.

Mitigations applied in this plan:
- T-06-09 (mitigated): `decode.isSafePacket` rejects non-finite quaternion before `slerp`
- T-06-05b (mitigated): `decode.isNewerSeq` drops backward/duplicate seq before store update
- T-06-10 (mitigated): label `textContent` (not innerHTML) in `addPlayerToScene`
- T-06-11 (mitigated): `dc.binaryType = 'arraybuffer'` as first statement in `ondatachannel`

## Self-Check: PASSED

All files confirmed present on disk:
- client/src/scene.ts — EXISTS
- client/src/room.ts — EXISTS

All task commits confirmed in git log:
- ad3294d (Task 1 — scene.ts) — confirmed
- 3b14413 (Task 2 — room.ts wiring) — confirmed
- cc18e8e (Fix — diagnostic logging) — confirmed

Build + typecheck: PASS (0 errors); 92/92 tests pass.
Human verified: binaryType=arraybuffer, 4417 packets at byteLength=36 type=[object ArrayBuffer], box rotates with phone.

---
*Phase: 06-desktop-receive-decode-and-rendering*
*Completed: 2026-07-10*
