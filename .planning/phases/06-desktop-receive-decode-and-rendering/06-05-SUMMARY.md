---
phase: 06-desktop-receive-decode-and-rendering
plan: 05
subsystem: scene-diagnostics
tags: [three.js, diagnostic-hud, keyboard-controls, touch-flash, motion-trail, tab-roster, webrtc]

requires:
  - phase: 06-desktop-receive-decode-and-rendering
    plan: 03
    provides: scene.ts initScene + rAF loop + CSS2DRenderer
  - phase: 06-desktop-receive-decode-and-rendering
    plan: 04
    provides: per-player SLERP boxes + ondatachannel decode pipeline

provides:
  - scene.ts: toggleGrid/toggleAxes/toggleTrail/toggleNumericHud/getToggleStates exports
  - scene.ts: motion trail ring buffer (TRAIL_POINTS=30, preallocated Float32Array, no per-frame alloc)
  - scene.ts: touch flash — 100ms white emissive burst on state.touchActive (D-14)
  - scene.ts: numeric HUD textContent update per rAF frame (D-15)
  - scene.ts: PlayerObject extended with trail+slot+username; removePlayerFromScene disposes trail
  - room.ts: P/G/A/H/T-D/Tab keyboard handler (attachGameKeyListeners, idempotent)
  - room.ts: updateHud() — #hud-slots connected count + #hud-mode pos label + #hud-keys toggle hints
  - room.ts: renderTabRoster() — 8 slot rows with live dc.readyState dots + own-slot accent border
  - room.ts: desktopChannels Map (phoneId→RTCDataChannel) for live readyState reads
  - room.ts: slotUsernames Map (slot→username) for TAB overlay name display
  - index.html: id=hud-keys on key-hint div; white-space:pre on #game-hud-players

affects: [scene.ts-rAF-loop, room.ts-ondatachannel, game-hud, game-tab-overlay]

tech-stack:
  added: []
  patterns:
    - "TRAIL_POINTS=30 ring buffer: preallocated Float32Array + BufferAttribute.needsUpdate — zero per-frame alloc (Pitfall 6, T-06-12)"
    - "Touch flash: emissive.setHex(0xffffff) → setTimeout 100ms → setHex(0x000000); flashing flag prevents re-trigger (D-14)"
    - "Toggle-via-visible: gridRef.visible / axes.visible / trail.line.visible — never add/remove from scene (Pitfall 4)"
    - "getToggleStates() return object: consumed by room.ts updateHud() for HUD key-hint line"
    - "desktopChannels Map (phoneId→RTCDataChannel) stored at dc creation for live readyState without traversing PeerConnections"
    - "attachGameKeyListeners idempotent via keyListenersAttached boolean (no duplicate handlers on re-entry)"
    - "renderTabRoster: rosterEl.textContent='' clears safely; DOM nodes built with textContent (T-06-10b XSS guard)"
    - "initSlotRoster: firstChild loop replaces previous roster.innerHTML='' (0 innerHTML uses in room.ts)"

key-files:
  created: []
  modified:
    - client/src/scene.ts
    - client/src/room.ts
    - client/index.html

key-decisions:
  - "white-space:pre on #game-hud-players (Rule 2 auto-fix) — required for \\n in textContent to produce visual line breaks in multiline diagnostic block"
  - "id=hud-keys on key-hint div (Rule 2 auto-fix) — required for updateHud() to target the third HUD line without fragile nth-child selector"
  - "desktopChannels Map separate from desktopPeers — RTCDataChannel not directly accessible from RTCPeerConnection without storing it; plan 05 needs live readyState per channel"
  - "slotUsernames Map keyed by slot (not phoneId) — renderTabRoster iterates slots 1-8 and needs username without phoneId as key"
  - "hudPlayersEl cached in initScene — avoids per-frame getElementById in 60Hz updateScene loop"
  - "trail.line is scene sibling, not mesh child — prevents trail from rotating with the box mesh; requires separate scene.remove in removePlayerFromScene"
  - "dc.onclose calls updateHud() — ensures connected count decrements immediately when channel closes"

requirements-completed:
  - DESK-05

coverage:
  - id: D1
    description: "toggleGrid/toggleAxes/toggleTrail/toggleNumericHud use .visible (Pitfall 4 compliance)"
    requirement: DESK-05
    verification:
      - kind: automated
        ref: "grep -c '.visible =' client/src/scene.ts → 6 (≥3)"
        status: pass
  - id: D2
    description: "Touch flash: emissive.setHex + 100ms setTimeout (D-14)"
    requirement: DESK-05
    verification:
      - kind: automated
        ref: "grep -c 'emissive' client/src/scene.ts → 5 (≥2); grep -c '100' → 4 (≥1)"
        status: pass
  - id: D3
    description: "Trail ring buffer: preallocated Float32Array + needsUpdate (no per-frame alloc)"
    requirement: DESK-05
    verification:
      - kind: automated
        ref: "grep -c 'needsUpdate' client/src/scene.ts → 2 (≥1)"
        status: pass
  - id: D4
    description: "Numeric HUD writes via textContent (no injection risk, T-06-10b)"
    requirement: DESK-05
    verification:
      - kind: automated
        ref: "grep -c 'innerHTML' client/src/scene.ts → 0; grep -c 'innerHTML' client/src/room.ts → 0"
        status: pass
  - id: D5
    description: "Keyboard handler covers P/G/A/H/T/D/Tab; HUD reflects toggle states"
    requirement: DESK-05
    verification:
      - kind: automated
        ref: "grep -c 'cyclePositionMode|toggleGrid|toggleAxes|toggleTrail|toggleNumericHud' client/src/room.ts → 10 (≥5)"
        status: pass
  - id: D6
    description: "TAB roster reads live dc.readyState"
    requirement: DESK-05
    verification:
      - kind: automated
        ref: "grep -c 'readyState' client/src/room.ts → 16 (≥1)"
        status: pass
  - id: D7
    description: "Full precision-evaluation scene: toggles + roster + touch flash + numeric HUD verified live"
    requirement: DESK-05
    verification:
      - kind: human-verify
        ref: "Task 3 checkpoint: P/G/A/H/T-D toggles + TAB roster + touch flash + numeric HUD all verified live"
        status: pending_human_verify
    human_judgment: true
    rationale: "Requires physical phone + live WebRTC session for touch flash and live channel state"

duration: ~7 min
completed: 2026-07-10
status: checkpoint
---

# Phase 6 Plan 5: Precision-Evaluation Instrumentation Summary

**Diagnostic overlays, keyboard controls, and touch/latency legibility added to the working scene: toggleGrid/toggleAxes/toggleTrail/toggleNumericHud setters, touch flash 100ms emissive burst, motion trail ring buffer, persistent HUD with P/G/A/H/T-D keys, and TAB-held roster with live RTCDataChannel state**

## Performance

- **Duration:** ~7 min
- **Started:** 2026-07-10T10:17:49Z
- **Completed:** 2026-07-10T10:25:00Z (Tasks 1-2 complete; Task 3 = human-verify checkpoint)
- **Tasks:** 2 auto + 1 human-verify checkpoint
- **Files modified:** 3 (scene.ts, room.ts, index.html)

## Accomplishments

### Task 1 — scene.ts (commit 1e5d08f)

- Added `TRAIL_POINTS=30` constant + `TrailHandle` interface + `PlayerObject.trail/slot/username` fields
- `createTrail(color)`: preallocates `Float32Array(TRAIL_POINTS * 3)` + `BufferGeometry` + `LineBasicMaterial` at opacity 0.5 — zero allocation per frame (Pitfall 6)
- `updateTrail(trail, x, y, z)`: ring-buffer write + `BufferAttribute.needsUpdate = true` — no allocation
- Extended `updateScene()` with three new per-player effects (inside existing rAF, no new loop):
  - **(a) Touch flash**: when `state.touchActive && !obj.flashing`, immediately sets `emissive.setHex(0xffffff)`, sets `flashing=true`, and after 100ms clears emissive + resets flag (D-14)
  - **(b) Trail update**: when `trailVisible`, calls `updateTrail()` with current mesh position (no allocation)
  - **(c) Numeric HUD**: when `numericHudVisible`, accumulates per-player `[Slot N — username]\n  q: w= x= y= z=\n  pos: x= y= z= [mode]\n  drift:\n` text and sets `hudPlayersEl.textContent` once per frame (textContent-only, T-06-10b)
- `toggleGrid()` / `toggleAxes()` / `toggleTrail()` / `toggleNumericHud()` — all use `.visible` toggling (Pitfall 4: never add/remove from scene)
- `getToggleStates()` export — returns four booleans + `positionModeLabel` for room.ts HUD rendering
- `addPlayerToScene`: creates trail with `slotColor`, applies current `trailVisible`/`axesVisible` state for late joiners
- `removePlayerFromScene`: disposes and removes trail line from scene (sibling of mesh, not child)
- `hudPlayersEl` cached in `initScene()` — avoids per-frame `getElementById`

### Task 2 — room.ts (commit ddf5c41)

- Imported `cyclePositionMode / toggleGrid / toggleAxes / toggleTrail / toggleNumericHud / getToggleStates` from `./scene`
- `desktopChannels = new Map<string, RTCDataChannel>()` — populated in `ondatachannel`, read by `updateHud` and `renderTabRoster` for live `.readyState`
- `slotUsernames = new Map<number, string>()` — populated in `handlePlayerReady`, read by `renderTabRoster`
- `attachGameKeyListeners()` — idempotent (`keyListenersAttached` guard); attaches `keydown/keyup` to `window`; active only when `gameViewShown`:
  - `p` → `cyclePositionMode()` + `updateHud()`
  - `g` → `toggleGrid()` + `updateHud()`
  - `a` → `toggleAxes()` + `updateHud()`
  - `h` → `toggleNumericHud()` + `updateHud()`
  - `t` / `d` → `toggleTrail()` + `updateHud()` (both map to single trail toggle per UI-SPEC note)
  - `Tab` → `preventDefault()` (T-06-13), set `tabHeld=true`, show `#game-tab-overlay`, call `renderTabRoster()`
  - `keyup Tab` → `tabHeld=false`, hide `#game-tab-overlay`
- `updateHud()` — writes `#hud-slots` (`N/max connected`), `#hud-mode` (`pos: gesture  [P to cycle]`), `#hud-keys` (`G:on  A:on  H:on  T:off`) using `textContent` only
- `renderTabRoster()` — clears `#tab-roster` via `textContent=''`, rebuilds 8 slot rows:
  - Status dot: `--color-status-connected` / `--color-status-hold` / `--color-status-empty` from live `dc.readyState`
  - Slot label (13px/600, `--color-text-secondary`)
  - Player name via `textContent` (XSS guard, T-06-10b) or `(empty)`
  - Verbatim `dc.readyState` string or `—`
  - Own slot (from `currentRoom.slot`): 3px left border `--color-accent`
- `showGameView()`: calls `attachGameKeyListeners()` + `updateHud()`
- `handlePlayerReady()`: adds `slotUsernames.set(slot, username)`, calls `updateHud()`
- `player-left`: deletes from `desktopChannels` + `slotUsernames`, calls `updateHud()`
- `dc.onopen` / `dc.onclose`: call `updateHud()` to keep connected count current
- Replaced `roster.innerHTML = ''` with `firstChild` loop — 0 `innerHTML` uses total (T-06-10b)

### Task 3 — human-verify checkpoint (PENDING)

Live verification required with a connected phone.

## Task Commits

1. **Task 1: scene.ts** — `1e5d08f` (feat)
2. **Task 2: room.ts** — `ddf5c41` (feat)
3. **Task 3** — human-verify checkpoint (pending)

## Files Modified

- `client/src/scene.ts` — TrailHandle, toggle setters, getToggleStates, touch flash, trail, numeric HUD
- `client/src/room.ts` — keyboard handler, updateHud, renderTabRoster, desktopChannels, slotUsernames
- `client/index.html` — id=hud-keys, white-space:pre on #game-hud-players

## Decisions Made

- **white-space:pre on #game-hud-players** — Rule 2 auto-fix: textContent with `\n` characters requires `white-space:pre` CSS to produce visual line breaks in the multiline diagnostic block. Without it, all fields would be on one line. CSS change is minimal and correctness-required.
- **id=hud-keys on key-hint div** — Rule 2 auto-fix: `updateHud()` must target the key-hints `<div>` to update it; adding `id="hud-keys"` is cleaner than a fragile `nth-child` selector.
- **desktopChannels separate from desktopPeers** — `RTCPeerConnection` does not expose its data channels after creation; the only way to read live `dc.readyState` is to store the `RTCDataChannel` reference separately.
- **slotUsernames keyed by slot** — `renderTabRoster` iterates slots 1-8 and needs the username for each slot without a phoneId key; slot-keyed lookup is O(1).
- **hudPlayersEl cached in initScene** — avoids 60Hz `getElementById` inside `updateScene()`; element exists in DOM from page load so caching in `initScene` is correct.
- **trail.line is scene sibling, not mesh child** — if trail were a mesh child, it would rotate with the box mesh (wrong: trail should show world-space positions). Adding as a scene sibling and disposing separately in `removePlayerFromScene` is the correct pattern.
- **dc.onclose + updateHud** — ensures the connected count in the HUD drops immediately when a channel closes, not only on player-left server event.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing critical functionality] white-space:pre on #game-hud-players**
- **Found during:** Task 1 implementation
- **Issue:** Plan specifies multiline diagnostic format (`[Slot N]\n  q: ...\n  pos: ...\n  drift:`) using textContent. Without `white-space:pre`, browser renders `\n` as whitespace, collapsing the multiline display into a single line.
- **Fix:** Added `white-space: pre` to `#game-hud-players` CSS in index.html.
- **Files modified:** `client/index.html`
- **Committed in:** `1e5d08f`

**2. [Rule 2 - Missing critical functionality] id=hud-keys added to key-hints div**
- **Found during:** Task 2 implementation
- **Issue:** `updateHud()` must update the key-hints line in `#game-hud`. The third child div has no id; targeting it with `#game-hud div:nth-child(3)` is fragile.
- **Fix:** Added `id="hud-keys"` to the third `<div>` in `#game-hud` in index.html.
- **Files modified:** `client/index.html`
- **Committed in:** `1e5d08f`

**3. [Rule 1 - Bug] roster.innerHTML='' replaced with firstChild loop**
- **Found during:** Task 2 implementation — acceptance criteria require `grep -c "innerHTML" client/src/room.ts` = 0
- **Issue:** Pre-existing `roster.innerHTML = ''` in `initSlotRoster` would fail the acceptance criteria.
- **Fix:** Replaced with `while (roster.firstChild) { roster.removeChild(roster.firstChild); }` — equivalent behavior, no injection risk.
- **Files modified:** `client/src/room.ts`
- **Committed in:** `ddf5c41`

## Known Stubs

None introduced in this plan. Pre-existing `game_type: 'placeholder'` stub is from Plan 03 scope; not within Plan 05 deliverables.

## Threat Flags

No new network endpoints or auth paths introduced.

Mitigations applied in this plan:
- T-06-10b (mitigated): All player-name and numeric HUD writes use `textContent` (not innerHTML) — scene.ts numeric HUD, room.ts TAB roster, room.ts updateHud
- T-06-12 (mitigated): Trail uses preallocated ring buffer with needsUpdate; HUD updates via textContent mutation; touch flash uses existing material emissive — no per-frame THREE allocation (Pitfall 6)
- T-06-13 (mitigated): `Tab` keydown calls `preventDefault()` — stops browser focus-cycling while game view is active

## Self-Check: PASSED

Files confirmed present on disk:
- client/src/scene.ts — EXISTS (getToggleStates exported, needsUpdate present, emissive present)
- client/src/room.ts — EXISTS (cyclePositionMode/toggleGrid imported, readyState referenced, 0 innerHTML)
- client/index.html — EXISTS (id=hud-keys present, white-space:pre present)

Task commits confirmed in git log:
- 1e5d08f (Task 1 — scene.ts) — confirmed
- ddf5c41 (Task 2 — room.ts) — confirmed

Build + typecheck: PASS (0 errors); 92/92 tests pass.
Human verify (Task 3): PENDING — live checkpoint.

---
*Phase: 06-desktop-receive-decode-and-rendering*
*Completed (auto tasks): 2026-07-10*
*Pending: Task 3 human-verify checkpoint*
