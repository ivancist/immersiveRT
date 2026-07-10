---
phase: 06-desktop-receive-decode-and-rendering
plan: "05"
subsystem: ui
tags: [three.js, webrtc, webtransport, websocket, sensor, keyboard, hud, imu]

requires:
  - phase: 06-04
    provides: working scene with SLERP-smoothed player boxes driven by decoded sensor packets

provides:
  - Persistent minimal HUD (connected count, position mode, toggle key hints)
  - Keyboard controls P/G/A/H/T/R/Esc/Tab all wired and functional
  - TAB-held roster overlay with live RTCDataChannel.readyState per player
  - Per-player numeric HUD panel (q/pos/drift, H key toggle)
  - Touch flash — box emissive-white while phone touchActive, per-frame in rAF loop
  - Motion trail ring buffer (Float32Array, no per-frame alloc, T key toggle)
  - Toggle setters (toggleGrid/toggleAxes/toggleTrail/toggleNumericHud) + getToggleStates()
  - cyclePositionMode() — gesture displacement vs dead-reckoning, P key
  - Esc leave-confirmation overlay — two-step leave prevents accidental disconnect
  - R-key position reset using positionOffset (absolute accumulated dx/dy/dz, not zeroed)
  - Fix: leaveRoom async/await ensures leave-room reaches server before transport closes
  - Fix: view-lobby hidden=true default prevents lobby FOUC on /room/ reload
  - Fix: sensorPipelineRunning guard skips phone re-calibration on desktop reconnect

affects:
  - phase-07 (any future phase adding game logic on top of this instrumented scene)

tech-stack:
  added: []
  patterns:
    - "Per-frame emissive touch flash — live state.touchActive check inside rAF updateScene, no setTimeout"
    - "Trail ring buffer — Float32Array(TRAIL_POINTS*3) pre-allocated once, head pointer modulo, needsUpdate each frame"
    - "Toggle-via-visible — grid/axes/trail all flip .visible, never add/remove from scene (Pitfall 4)"
    - "Position offset for R-key reset — record current dx/dy/dz as positionOffset, subtract each frame; Kalman store not zeroed"
    - "gameViewShown guard — all intermediate server-pushed state renders checked before any view transition"
    - "leaveRoom async+await for WT — sendWtMessage must complete before transport.close() to prevent WebTransportError unhandled rejection"
    - "view-lobby hidden=true default — module scripts are deferred; lobby must be hidden before first paint to prevent FOUC on /room/ reload"
    - "sensorPipelineRunning flag — phone skips recalibration when pipeline is already active on desktop reconnect"

key-files:
  created: []
  modified:
    - client/src/scene.ts
    - client/src/room.ts
    - client/index.html
    - client/src/phone.ts

key-decisions:
  - "leaveRoom() made async; sendWtMessage awaited before transport.close() — fix for WebTransportError unhandled rejection (sync try/catch cannot catch async rejections)"
  - "view-lobby hidden=true by default; initDesktopPage() calls showView('view-lobby') for non-room paths and the no-storedSlot else branch"
  - "sensorPipelineRunning flag added to phone.ts; onPlayerReady() returns early to view-active when pipeline is already running"
  - "Touch flash implemented as live per-frame emissive check (state.touchActive) inside updateScene — no setTimeout, no flashing flag"
  - "Coordinate frame W3C earth to Three.js world: scratchQuat.set(qx, qz, -qy, qw)"
  - "Position axis mapping: device X->Three.js -X, device Y->Three.js -Z, device Z->Three.js +Y"
  - "Position dead-zone 0.002m for gesture mode — suppresses accelerometer noise when phone stationary"
  - "Player-ready phoneId read from payload.player_id — server omits top-level msg.from in player-ready messages"
  - "handlePlayerReady guarded against /phone path — server broadcasts player-ready to both desktop and phone"
  - "Esc key shows confirmation overlay first; Leave Room button (not second Esc) actually calls leaveRoom()"
  - "R-key reset records positionOffset at current dx/dy/dz; updateScene subtracts offset each frame — Kalman store not zeroed"

patterns-established:
  - "async leaveRoom pattern: UI updates sync at top, transport close awaited at bottom — user sees lobby immediately, cleanup async"
  - "All server-push handlers that could show a view are guarded by gameViewShown check"
  - "phone.ts sensorPipelineRunning is the canonical gate for 'is the phone already active'"

requirements-completed:
  - DESK-05

coverage:
  - id: D1
    description: "Persistent minimal HUD shows connected/max count and active position mode; P cycles gesture vs dead-reckoning and HUD updates"
    requirement: DESK-05
    verification:
      - kind: unit
        ref: "npm run typecheck && npm run build — both exit 0"
        status: pass
    human_judgment: true
    rationale: "Live HUD text requires a connected phone to verify; typecheck confirms wiring but not runtime content"
  - id: D2
    description: "G/A/H/T toggles each flip the corresponding scene element and update the HUD key-hint line"
    requirement: DESK-05
    verification:
      - kind: unit
        ref: "npm run typecheck && npm run build — both exit 0"
        status: pass
    human_judgment: true
    rationale: "Toggle behavior is runtime-only; requires live Three.js render to verify"
  - id: D3
    description: "TAB held shows roster overlay with per-player slot, name, and live dc.readyState color dot; releasing hides it"
    requirement: DESK-05
    verification:
      - kind: unit
        ref: "npm run typecheck — exit 0"
        status: pass
    human_judgment: true
    rationale: "Roster rendering and live channel state require an active WebRTC session"
  - id: D4
    description: "Touch flash — box emissive-white while phone reports touchActive; numeric HUD shows live q/pos/drift"
    requirement: DESK-05
    verification:
      - kind: unit
        ref: "npm run typecheck && npm run build — both exit 0"
        status: pass
    human_judgment: true
    rationale: "Touch and sensor data require physical phone interaction to verify"
  - id: D5
    description: "leaveRoom() no longer throws WebTransportError; phone disconnects when desktop leaves"
    verification:
      - kind: unit
        ref: "npm run typecheck — exit 0; leaveRoom is async and awaits sendWtMessage"
        status: pass
    human_judgment: true
    rationale: "Leave-room delivery and phone disconnect require a live WT session and physical phone"
  - id: D6
    description: "Desktop /room/ reload with prPhones_ sentinel shows game view immediately with no lobby flash"
    verification:
      - kind: unit
        ref: "npm run build — exit 0; view-lobby has hidden attr in index.html"
        status: pass
    human_judgment: true
    rationale: "Flash prevention requires visual inspection during a live browser reload"
  - id: D7
    description: "Phone does not re-show 'Hold your phone still' calibration on desktop reload when already in active state"
    verification:
      - kind: unit
        ref: "npm run typecheck — exit 0; sensorPipelineRunning guard present in onPlayerReady"
        status: pass
    human_judgment: true
    rationale: "Requires physical phone and desktop reload to verify calibration skip"

duration: 240min
completed: "2026-07-10"
status: complete
---

# Phase 06 Plan 05: Precision-Evaluation Instrumentation Summary

**Keyboard-controlled diagnostic scene with persistent HUD, touch-flash emissive response, motion trail, TAB roster, numeric per-player panel, and two-step Esc leave — all rendering inside the single rAF loop with no per-frame allocation.**

## Performance

- **Duration:** ~240 min (multi-session including post-checkpoint verification fixes)
- **Completed:** 2026-07-10
- **Tasks:** 2 implementation tasks + verification checkpoint (human-approved)
- **Files modified:** 4 (scene.ts, room.ts, index.html, phone.ts)

## Accomplishments

- Touch flash: live per-frame emissive check on `state.touchActive` inside `updateScene` — no setTimeout, no allocation
- Motion trail: pre-allocated `Float32Array(TRAIL_POINTS*3)` ring buffer, head pointer, `needsUpdate` each frame — zero GC pressure
- Toggle setters `toggleGrid/toggleAxes/toggleTrail/toggleNumericHud` and `getToggleStates()` exported from scene.ts
- `cyclePositionMode()` — P key switches gesture displacement vs dead-reckoning; HUD label updates instantly
- `updateHud()` — reads live `desktopChannels` readyState map + `getToggleStates()` each call
- `renderTabRoster()` — per-slot status dots from live `dc.readyState`, own-slot accent border, textContent-only (T-06-10b)
- Keyboard listeners (P/G/A/H/T/R/Esc/Tab) attached once via idempotency guard; Tab prevents browser focus-cycle via `preventDefault`
- Esc shows confirmation overlay first; Leave Room button calls `leaveRoom()` — prevents accidental disconnect
- R-key reset: records `positionOffset` at current accumulated values; `updateScene` subtracts offset each frame — no Kalman store zeroing
- Bug 1: `leaveRoom()` made `async`; `await sendWtMessage` ensures leave-room reaches server before `transport.close()` — eliminates unhandled WebTransportError rejection and ensures phone disconnects
- Bug 2: `view-lobby` given `hidden=true` default (prevents FOUC on /room/ reload); `sensorPipelineRunning` flag in phone.ts skips 3-second recalibration on desktop reconnect

## Task Commits

1. **Task 1: Touch flash, motion trail, numeric HUD, toggle setters in scene.ts** — `1e5d08f` (feat)
2. **Task 2: Keyboard controls, persistent HUD, TAB roster in room.ts** — `ddf5c41` (feat)
3. **Post-verification fix: handlePlayerReady /phone-path guard** — `3a33632` (fix)
4. **Post-verification fix: axes, keys, flash, HUD, positions, frame, drift** — `af2d0ea` (fix)
5. **Post-verification fix: player-ready phoneId and QR flow regression** — `3a6d912` (fix)
6. **Post-verification fix: CSS, orientation, axis mapping, positionOffset, reconnect, Esc** — `4bee718` (fix)
7. **Post-verification fix: position signs, Esc menu, reconnect flicker, phone zoom** — `50a78ac` (fix)
8. **Post-verification fix: Esc dismiss-only, gesture dead-zone threshold** — `f31c712` (fix)
9. **Post-verification fix: leaveRoom cleanup, Esc text, reconnect flash, scene teardown** — `1ffe9f4` (fix)
10. **Bug 1+2: WebTransportError crash, phone disconnect, lobby flash, calibration replay** — `2cecdad` (fix)

## Files Created/Modified

- `client/src/scene.ts` — touch flash (per-frame emissive), motion trail (ring buffer), numeric HUD (textContent only), toggle setters, `getToggleStates()`, `cyclePositionMode()`, `resetAllPlayerPositions()` with positionOffset
- `client/src/room.ts` — keyboard handler (P/G/A/H/T/R/Esc/Tab), `updateHud()`, `renderTabRoster()`, `showEscMenu()/dismissEscMenu()`, `gameViewShown` guard on all view transitions, `leaveRoom()` made async+await, `initDesktopPage()` shows view-lobby explicitly for non-room paths
- `client/index.html` — `hidden` added to `<div id="view-lobby">` to prevent FOUC on /room/ reload
- `client/src/phone.ts` — `sensorPipelineRunning` flag; `onPlayerReady()` guard skips calibration when pipeline already active

## Decisions Made

- **leaveRoom async+await**: `sendWtMessage` is async; sync `try/catch` cannot catch async rejections. Awaiting ensures the WT leave-room signal is delivered before `transport.close()`, so the server notifies the phone immediately.
- **view-lobby hidden default**: Module scripts are deferred (run after HTML paint). `view-lobby` rendered visible for 1-50ms on fast machines, longer on mobile. Default `hidden=true` eliminates the flash.
- **sensorPipelineRunning flag**: Server replays `player-ready` to the phone on every desktop reconnect. Phone must not re-run the 3-second calibration when already in `view-active` state.
- **Per-frame emissive touch flash**: Implemented as live `state.touchActive` check in `updateScene` — same visual result as 100ms setTimeout, zero timers, no race conditions.
- **W3C to Three.js quaternion transform**: `scratchQuat.set(qx, qz, -qy, qw)` — W3C earth frame Y (North) maps to Three.js -Z (into scene).
- **Position axis mapping**: device X to Three.js -X, device Y to Three.js -Z, device Z to Three.js +Y (verified against user-reported inversion: lift phone, cube goes up).
- **Position dead-zone 0.002m**: Suppresses accelerometer noise when phone is stationary; gesture displacement accumulates continuously.
- **player_id from payload not msg.from**: Server serialises player-ready without a top-level `from` field; `payload.player_id` is the authoritative phoneId.
- **Esc two-step**: Single Esc shows overlay, any key or Stay button dismisses; only Leave Room button calls `leaveRoom()`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Touch flash implemented as per-frame check, not 100ms setTimeout**
- **Found during:** Task 1 and post-verification
- **Issue:** `setTimeout(clearEmissive, 100)` caused double-toggle artifacts and needed a separate `flashing` flag.
- **Fix:** Live emissive set/clear in `updateScene` each frame based on `state.touchActive`.
- **Files modified:** client/src/scene.ts
- **Committed in:** 1e5d08f, refined in af2d0ea

**2. [Rule 1 - Bug] W3C to Three.js quaternion coordinate frame transform**
- **Found during:** Post-verification (cube rotation visually wrong)
- **Issue:** Raw W3C quaternion applied directly caused W3C Y (roll/gamma) to appear as Three.js Y (yaw).
- **Fix:** `scratchQuat.set(qx, qz, -qy, qw)` applies the correct -90deg rotation around X.
- **Files modified:** client/src/scene.ts
- **Committed in:** af2d0ea

**3. [Rule 1 - Bug] Position sign errors (lift phone, cube goes down; push forward, cube goes away)**
- **Found during:** Post-verification
- **Issue:** `mesh.position.set(-dx, dz, -dy)` had wrong Y/Z signs.
- **Fix:** `set(-dx, -dz, dy)` — negate Three.js Y so lift maps to up; negate Three.js Z for correct forward.
- **Files modified:** client/src/scene.ts
- **Committed in:** 50a78ac

**4. [Rule 1 - Bug] R-key reset used store zeroing (overwritten by next packet)**
- **Found during:** Post-verification (R-key had no effect)
- **Issue:** dx/dy/dz in SensorPacket are absolute accumulated values. Zeroing the store is immediately overwritten by the next incoming packet.
- **Fix:** Record current values as `positionOffset`; subtract offset in `updateScene` every frame.
- **Files modified:** client/src/scene.ts
- **Committed in:** 4bee718

**5. [Rule 1 - Bug] player-ready phoneId read from msg.from (always empty)**
- **Found during:** Post-verification (TAB roster showed empty, HUD counter wrong)
- **Issue:** Server serialises player-ready without `msg.from`; `payload.player_id` is the correct field.
- **Fix:** Read phoneId from `payload.player_id` with `msg.from` as fallback.
- **Files modified:** client/src/room.ts
- **Committed in:** 3a6d912

**6. [Rule 2 - Missing] handlePlayerReady guard for /phone path**
- **Found during:** Post-verification
- **Issue:** Server broadcasts player-ready to both desktop and phone. Without a path check, the phone would call `showGameView()` replacing its pairing UI with a blank WebGL canvas.
- **Fix:** Early return in `handlePlayerReady` when `window.location.pathname.startsWith('/phone')`.
- **Files modified:** client/src/room.ts
- **Committed in:** 3a33632

**7. [Rule 1 - Bug] leaveRoom WebTransportError unhandled rejection and phone not disconnecting**
- **Found during:** Bug report after plan checkpoint
- **Issue:** Sync `try/catch` around async `sendWtMessage` did not catch Promise rejection; transport closed before bidi stream resolved, so leave-room was never delivered.
- **Fix:** `leaveRoom()` made `async`; `await sendWtMessage` with surrounding `try/catch`.
- **Files modified:** client/src/room.ts
- **Committed in:** 2cecdad

**8. [Rule 1 - Bug] Lobby flash on /room/ reload and phone recalibration on desktop reconnect**
- **Found during:** Bug report after plan checkpoint
- **Issue:** (a) `view-lobby` had no `hidden` attribute so it painted before deferred module script ran. (b) Server replays `player-ready` on desktop reconnect; phone restarted 3s hold-still calibration unconditionally.
- **Fix:** `hidden=true` on `view-lobby` with explicit `showView('view-lobby')` callsites; `sensorPipelineRunning` guard in `onPlayerReady`.
- **Files modified:** client/index.html, client/src/room.ts, client/src/phone.ts
- **Committed in:** 2cecdad

---

**Total deviations:** 8 auto-fixed (Rules 1 and 2)
**Impact on plan:** All auto-fixes corrected runtime behavior bugs discovered during verification. No scope creep. Plan goal (precision-evaluation instrumentation) achieved in full.

## Issues Encountered

- AxesHelper size 0.5 was hidden inside the box half-extent — corrected to 1.5 units (4bee718)
- Esc key initially left the room immediately without confirmation — two-step overlay added (50a78ac)
- Scene not torn down on leaveRoom before fix: CSS2DRenderer and rAF loop kept running, causing WebGL context exhaustion on re-join (1ffe9f4)
- Phone pinch-zoom gesture interfered with touch readings — touchmove preventDefault added in phone.ts (50a78ac)

## Next Phase Readiness

- Precision-evaluation scene fully instrumented; sensor fidelity and latency are legible via keyboard overlays
- `leaveRoom` cleanly tears down all resources and notifies server and phone
- `phone.ts` reconnect flow is idempotent: re-joining desktop does not disrupt active phone sensor stream
- Scene ready for Phase 07 game-logic layer on top of the established Three.js scene

## Known Stubs

None — all packet fields, HUD values, and scene elements wire to live sensor data.

## Threat Flags

None — no new network endpoints, auth paths, or trust boundaries beyond the plan's registered threat model (T-06-10b XSS guard, T-06-12 no-per-frame-alloc, T-06-13 Tab preventDefault).

---
*Phase: 06-desktop-receive-decode-and-rendering*
*Completed: 2026-07-10*

## Self-Check: PASSED

- client/src/scene.ts: FOUND
- client/src/room.ts: FOUND
- client/index.html: FOUND
- client/src/phone.ts: FOUND
- 06-05-SUMMARY.md: FOUND
- Commits 1e5d08f, ddf5c41, 3a33632, af2d0ea, 3a6d912, 4bee718, 50a78ac, f31c712, 1ffe9f4, 2cecdad: all FOUND
