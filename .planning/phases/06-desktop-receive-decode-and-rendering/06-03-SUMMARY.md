---
phase: 06-desktop-receive-decode-and-rendering
plan: 03
subsystem: scene-bootstrap
tags: [three.js, webgl, css2drenderer, scene-init, game-view, dom-shell]

requires:
  - phase: 06-desktop-receive-decode-and-rendering
    plan: 01
    provides: room.ts with WT dual-path signaling + player-ready dispatch
  - phase: 06-desktop-receive-decode-and-rendering
    plan: 02
    provides: decode.ts + playerStore.ts decode pipeline

provides:
  - three@0.185.1 + @types/three@0.185.1 installed at pinned versions
  - #game-container, #game-canvas, #game-hud, #hud-slots, #hud-mode,
    #game-hud-players, #game-tab-overlay, #tab-roster DOM elements in index.html
  - CSS block from UI-SPEC Component Inventory (all game elements default hidden)
  - client/src/scene.ts: initScene(canvas, container) + rAF loop + CSS2DRenderer
  - client/src/room.ts: showGameView() + first-player-ready game view activation

affects: [06-04-PLAN, 06-05-PLAN, scene.ts-rAF-loop, room.ts-handlePlayerReady]

tech-stack:
  added:
    - "three@0.185.1 (runtime, client/package.json dependencies, exact pin)"
    - "@types/three@0.185.1 (devDependency, exact pin)"
  patterns:
    - "sceneInitialized + animRunning guards: exactly one renderer + rAF loop regardless of player count (Pitfall 2, T-06-08)"
    - "CSS2DRenderer domElement appended into #game-container (shared positioned wrapper, Pitfall 5)"
    - "window.innerWidth/innerHeight for initial sizing: avoids 0-dimension race when canvas switches from display:none"
    - "gameViewShown flag in room.ts: first player-ready triggers showGameView + initScene; subsequent ones are addPlayer-only"
    - "showGameView() uses style.display not hidden attribute — avoids conflict with [hidden] !important CSS rule"

key-files:
  created:
    - client/src/scene.ts
  modified:
    - client/package.json
    - client/package-lock.json
    - client/index.html
    - client/src/room.ts

key-decisions:
  - "three@0.185.1 exact pin (no caret) — CLAUDE.md lock for Three.js version"
  - "CSS2DRenderer domElement appended to #game-container, not document.body — coordinate space alignment (Pitfall 5)"
  - "window.innerWidth/innerHeight for camera aspect + renderer size in initScene — avoids 0-dimension when canvas was display:none"
  - "showGameView uses element.style.display not element.hidden — [hidden] { display: none !important } in CSS would override any style we set, but game-container/hud use inline display:none not the hidden attribute; consistent with UI-SPEC"
  - "gameViewShown flag in room.ts (separate from sceneInitialized in scene.ts) — ensures showGameView is also called only once"
  - "addPlayerToScene stub exported from plan 03 — room.ts calls it immediately after initScene so plan 04 body fills in without room.ts changes"

requirements-completed:
  - DESK-05

coverage:
  - id: D1
    description: "three@0.185.1 installed as exact pin; @types/three@0.185.1 installed as devDependency; build passes"
    requirement: DESK-05
    verification:
      - kind: automated
        ref: "cd client && npm run build"
        status: pass
  - id: D2
    description: "Game DOM shell (#game-container, #game-canvas, #game-hud, #game-hud-players, #game-tab-overlay) and CSS present in index.html, hidden by default"
    requirement: DESK-05
    verification:
      - kind: automated
        ref: "grep -c 'id=\"game-canvas\"' client/index.html"
        status: pass
  - id: D3
    description: "initScene guarded by sceneInitialized flag — safe to call on every player-ready; CSS2DRenderer into #game-container; rAF loop starts once"
    requirement: DESK-05
    verification:
      - kind: automated
        ref: "cd client && npm run typecheck && npm run build"
        status: pass
  - id: D4
    description: "showGameView hides lobby/room/phone, reveals #game-container + #game-hud; called on first player-ready via gameViewShown guard"
    requirement: DESK-05
    verification:
      - kind: manual_procedural
        ref: "Connect phone through to ready state; confirm grid scene replaces room UI"
        status: pending_human_verify

duration: ~15 min
completed: 2026-07-10
status: complete
---

# Phase 6 Plan 3: Three.js Install + Game View Shell Summary

**three@0.185.1 installed behind a human legitimacy gate; game DOM shell and CSS added to index.html; scene.ts builds a guarded empty grid scene; first player-ready triggers showGameView + initScene with a single renderer/rAF loop**

## Performance

- **Duration:** ~15 min
- **Started:** 2026-07-10T08:44:00Z
- **Completed:** 2026-07-10T08:53:21Z
- **Tasks:** 4 (T1: legitimacy gate — human checkpoint, T2: install + DOM shell, T3: scene.ts + room.ts wiring, T4: human-verify checkpoint)
- **Files modified:** 4 (package.json, package-lock.json, index.html, room.ts)
- **Files created:** 1 (scene.ts)

## Accomplishments

- Obtained explicit human approval for three@0.185.1 + @types/three@0.185.1 (Task 1 legitimacy gate — T-06-SC)
- Installed both packages at exact pinned versions (no caret drift)
- Added complete game DOM shell to index.html per UI-SPEC Component Inventory: `#game-container`, `#game-canvas`, `#game-hud` (with `#hud-slots`, `#hud-mode`), `#game-hud-players`, `#game-tab-overlay` (with `#tab-roster`)
- Added full game view CSS block using `var(--color-text-primary)` design tokens
- Created `client/src/scene.ts` with:
  - `initScene(canvas, container)` guarded by `sceneInitialized` — builds WebGLRenderer, PerspectiveCamera(60°) at (0,1.5,4), AmbientLight + DirectionalLight, GridHelper(10,10)
  - CSS2DRenderer appended into container (#game-container) not document.body (Pitfall 5)
  - `animate()` rAF loop with `animRunning` guard (T-06-08 DoS mitigation)
  - `updateScene()` iterating empty `playerObjects` Map (no-op; plan 04 fills in)
  - Exported stubs `addPlayerToScene` + `removePlayerFromScene` (plan 04 bodies)
- Extended `room.ts` with `showGameView()` + `gameViewShown` guard in `handlePlayerReady`
- TypeScript typecheck: 0 errors. Vite build: passes (541KB room bundle expected — Three.js is large)

## Task Commits

1. **Task 1 (human legitimacy gate)** — No commit (checkpoint only)
2. **Task 2: Install + DOM shell** — `60c5764` (feat)
3. **Task 3: scene.ts + room.ts wiring** — `0aae1f3` (feat)
4. **Task 4 (human-verify checkpoint)** — Returned as checkpoint

## Files Created

- `client/src/scene.ts` — initScene, animate, updateScene, addPlayerToScene (stub), removePlayerFromScene (stub)

## Files Modified

- `client/package.json` — three@0.185.1 (deps, exact pin), @types/three@0.185.1 (devDeps, exact pin)
- `client/package-lock.json` — lockfile updated for three + @types/three
- `client/index.html` — game DOM shell + CSS block (UI-SPEC Component Inventory)
- `client/src/room.ts` — import scene functions, showGameView(), gameViewShown guard, handlePlayerReady extension

## Decisions Made

- **Exact version pins** — `three: "0.185.1"` and `@types/three: "0.185.1"` without caret, matching CLAUDE.md directive to lock Three.js at r185
- **CSS2DRenderer into #game-container** — Pitfall 5 avoidance: labelRenderer.domElement appended to the shared positioned wrapper, not document.body
- **window.innerWidth/innerHeight for initial size** — avoids 0-dimension race condition when canvas was display:none before showGameView()
- **showGameView uses style.display** — game-container/hud use inline `display: none` in CSS, not the `[hidden]` attribute. Setting `style.display = 'block'` correctly overrides the inline style. The `[hidden] { display: none !important }` rule only applies to elements using the `hidden` attribute.
- **gameViewShown flag in room.ts** (separate from sceneInitialized in scene.ts) — ensures showGameView() is also called only once, not just initScene()

## Deviations from Plan

### Auto-fixed Issues

None — plan executed exactly as written, with one minor implementation note:

**[Rule 2 - Critical functionality] showGameView uses style.display not element.hidden**
- **Found during:** Task 3 implementation
- **Issue:** The plan says showGameView "clears display:none" on #game-container and #game-hud. The CSS uses inline `display: none` (not the `hidden` attribute), so the correct mechanism is `element.style.display = 'block'` not `element.removeAttribute('hidden')`.
- **Fix:** showGameView sets `style.display = 'block'` on both elements. This is consistent with the existing CSS that sets these elements to `display: none` via the `#game-container` and `#game-hud` CSS rules.
- **Impact:** Correctness requirement — avoids conflict with `[hidden] { display: none !important }` which would prevent showing elements that have the hidden attribute.

## Known Stubs

- `addPlayerToScene(phoneId, slot, username)` in scene.ts — no-op stub; plan 04 creates box mesh, CSS2DLabel, axes, trail
- `removePlayerFromScene(phoneId)` in scene.ts — no-op stub; plan 04 removes objects from scene
- `updateScene()` iterates empty `playerObjects` Map — no visible effect until plan 04 populates it

These stubs are intentional and do not prevent this plan's goal (empty grid scene activation on first player-ready). Plan 04 fills in all bodies.

## Threat Flags

No new network endpoints or auth paths introduced.

- T-06-SC (mitigated): Human legitimacy gate completed before npm install — Task 1 checkpoint, explicit "approved" received
- T-06-08 (mitigated): animRunning guard in scene.ts + sceneInitialized guard + gameViewShown guard in room.ts — exactly one renderer and one rAF loop regardless of player count

## Self-Check: PASSED

All files confirmed present on disk:
- client/src/scene.ts — EXISTS
- client/index.html — modified, all 5 element IDs confirmed (grep -c = 1 each)
- client/package.json — three: "0.185.1" (no caret), @types/three: "0.185.1"

Both task commits confirmed in git log:
- 60c5764 (Task 2) — confirmed
- 0aae1f3 (Task 3) — confirmed

Build + typecheck: PASS (0 errors)

---
*Phase: 06-desktop-receive-decode-and-rendering*
*Completed: 2026-07-10*
