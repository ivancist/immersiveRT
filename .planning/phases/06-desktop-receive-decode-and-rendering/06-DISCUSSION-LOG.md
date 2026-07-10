# Phase 6: Desktop Receive, Decode, and Rendering - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-07-10
**Phase:** 06-desktop-receive-decode-and-rendering
**Areas discussed:** Desktop WebTransport, Three.js entry point, Three.js scene scope, Seq-drop wraparound

---

## Desktop WebTransport

| Option | Description | Selected |
|--------|-------------|----------|
| Full migration | Replace WS with WT in room.ts — all signaling over WT, WS fallback kept | ✓ |
| Parallel WT for game events | Keep WS for session/pairing/ICE; add WT only for game state events | |
| Defer — keep WS for Phase 6 | Focus Phase 6 on decode + Three.js; WT migration in Phase 7 SDK | |

**User's choice:** Full migration (recommended option)
**Notes:** All message types (ICE/offer/answer + game events) move to WT. No split transport. WS fallback kept for QUIC-blocked networks — mirrors phone.ts Phase 4 D-01 pattern exactly.

---

## Three.js Entry Point

| Option | Description | Selected |
|--------|-------------|----------|
| Embed in existing #view-room | Canvas added to index.html/room.ts, no new Vite entry | ✓ |
| New game.ts + game.html | Separate Vite entry, desktop navigates to /game after setup | |

**User's choice:** Embed in existing room.ts

**Canvas layout clarification (user-initiated):**
| Option | Description | Selected |
|--------|-------------|----------|
| Third column / panel below | QR + roster columns stay; canvas added as third panel | |
| Canvas replaces events column | Events log column swapped for canvas when phone connects | |
| Full-viewport canvas on player-ready | Canvas fills viewport on player-ready; room UI hides | ✓ |

**User's choice (clarified):** Full-viewport on player-ready, with:
- Persistent minimal HUD always visible: slots occupied/free count
- TAB held → expanded overlay: full roster (slot names + connection status per player)

---

## Three.js Scene Scope

**Motion scope clarification (user-initiated):**
User clarified Phase 6 scene must handle rotation + translation + touch response, and environment must be suitable for evaluating motion precision. Not just a proof of rotation.

**Object position mode:**
| Option | Description | Selected |
|--------|-------------|----------|
| gestureDisplacement only | Per-action delta, resets after each ZUPT | |
| deadReckoningPosition only | Accumulated dead-reckoning with drift | |
| Both visible simultaneously | Two objects per player | |
| Runtime toggle (user-clarified) | P key cycles between both modes, one at a time | ✓ |

**User's choice (clarified):** Runtime toggle — user wants to try both but not simultaneously. `P` key switches mode.

**Touch response:**
| Option | Description | Selected |
|--------|-------------|----------|
| Color flash / pulse | Immediate visual, latency-legible | ✓ (always on) |
| Burst / trail | Motion drama | ✓ (toggleable) |

**User's choice (clarified):** Both — flash/pulse always active (latency evaluation), drama mode (trail) runtime-toggleable with `D` key.

**Precision aids:**
| Option | Description | Selected |
|--------|-------------|----------|
| Grid floor | Reference grid on ground plane | ✓ |
| Axes gizmo | XYZ widget per object | ✓ |
| Numeric HUD | Quaternion values, displacement, driftConfidence per player | ✓ |
| Motion trail | Ghost trail behind object | ✓ |

**User's choice (clarified):** All 4, each individually hideable via keyboard (`G`, `A`, `H`, `T`).

---

## Seq-drop Wraparound

**User asked for clarification on what seq-drop means.**

Explanation provided: packets arrive at 60Hz each with a uint16 sequence number. Out-of-order delivery would cause visible backward jumps in the 3D object. Seq-drop = silently discard packets with a lower (older) sequence number than the last applied. uint16 wraps at 65535→0, requiring proper half-distance comparison rather than simple `>` check.

**User's choice:** Deferred to Claude's discretion — implementation detail, no product preference.

---

## Claude's Discretion

- uint16 half-distance seq-drop: `(newSeq - lastSeq) & 0xFFFF <= 32767`
- Three.js `requestAnimationFrame` loop structure
- Per-slot hue assignment (HSL evenly spaced)
- Motion trail implementation (lightweight ghost geometry)
- SLERP: `THREE.Quaternion.slerp()` between current and target each frame
- Label rendering: `CSS2DRenderer` or `Sprite`

## Deferred Ideas

- Orbit controls / interactive camera — Phase 8 demo game
- Per-player object shape variety — Phase 8
- SLERP alpha runtime UI control — Phase 7 SDK / Phase 8
- Gesture flick action (DEMO-03) — Phase 8
- Multi-desktop sync (DEMO-02) — Phase 8
