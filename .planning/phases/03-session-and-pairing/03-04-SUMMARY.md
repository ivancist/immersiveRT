---
phase: 03-session-and-pairing
plan: 04
subsystem: ui
tags: [spa, websocket, qrcode, localstorage, sessionstorage, reconnect]

requires:
  - phase: 03-session-and-pairing
    provides: RoomRegistry, PairingTokenStore, WS/WT routing for join-room/reconnect/pair messages

provides:
  - Full SPA: lobby with Create/Join forms, room page with QR + roster, phone pairing landing
  - Client-side reconnect flow via localStorage token (survives tab close) + sessionStorage (tab-specific, survives reload)
  - Event log with lifecycle events (player-joined, player-disconnected, player-reconnected, player-left)

affects: [04-phone-controller, 05-imu-pipeline]

tech-stack:
  added: [qrcode@1.4.4 (CDN)]
  patterns:
    - SPA routing via history.pushState — pushState only inside handleJoinAck, never on form submit
    - Dual-storage reconnect — sessionStorage (slot key, tab-specific) + localStorage (token keyed room+slot)
    - WS pre-warm on lobby load (D-11); message queue for sends before open

key-files:
  created:
    - client/dist/room.js
  modified:
    - client/dist/index.html
    - server/tests/ws_echo.rs
    - server/tests/broker_relay.rs
    - server/src/turn_creds.rs

key-decisions:
  - "localStorage for reconnect token (survives tab close) + sessionStorage for slot lookup (tab-specific, prevents cross-tab collision on reload)"
  - "isFirstJoin guard on localStorage slot write: only write on first join, not on reconnect-triggered join-ack — prevents reload of any open tab from overwriting the newest joiner's slot"
  - "connectWS() called at end of leaveRoom() to re-warm WS for next create/join without page reload"
  - "qrcode@1.4.4 CDN — 1.5.x dropped the build/ directory so 1.5.x URL 404s"
  - "pairing_url is relative (/phone?token=...) when BASE_URL env var is empty — QR renders but requires BASE_URL for real phone testing"
  - "pair-error reason from server is invalid_token (not token_used) — client default copy handles it"
  - "Tests ws_echo.rs and broker_relay.rs updated to pass Arc<RoomRegistry> as 4th arg after Plan 03-02 changed run_with_listener signature"
  - "TurnCredentials derives Debug to fix compile error in main.rs"

patterns-established:
  - "SPA pushState: only inside server-confirmed ack handlers, never on user action"
  - "Dual-storage pattern for reconnect: sessionStorage slot (reload-safe, tab-scoped) + localStorage token (cross-tab, keyed room+slot)"

requirements-completed:
  - SESS-01
  - SESS-02
  - SESS-03
  - SESS-04
  - SESS-05
  - SESS-06

coverage:
  - id: D1
    description: "Lobby loads at https://localhost:8443 with Create Room and Join Room buttons"
    requirement: SESS-01
    verification:
      - kind: manual_procedural
        ref: "curl -sk https://localhost:8443/ | grep -c btn-create-room → 1"
        status: pass
    human_judgment: false
  - id: D2
    description: "Create Room flow: game-type selector → Continue → join-ack → pushState to /room/{code}, QR renders, short code shows, 8-slot roster"
    requirement: SESS-01
    verification:
      - kind: manual_procedural
        ref: "Human verified in Chrome browser — step 2 of checkpoint"
        status: pass
    human_judgment: true
    rationale: "QR canvas render and pushState navigation require browser observation"
  - id: D3
    description: "Join Room flow: room code + username inputs → join-ack → navigates to same room, host event log shows player-joined"
    requirement: SESS-03
    verification:
      - kind: integration
        ref: "Node.js WS test: join-ack slot=2, room_code matches host room"
        status: pass
    human_judgment: true
    rationale: "Event log display and SPA navigation require browser observation"
  - id: D4
    description: "9th join attempt rejected with room_full error"
    requirement: SESS-05
    verification:
      - kind: integration
        ref: "Node.js WS test: 9th join-error reason=room_full"
        status: pass
    human_judgment: false
  - id: D5
    description: "Phone landing at /phone?token=... connects, sends pair, shows Paired successfully; reuse shows error"
    requirement: SESS-02
    verification:
      - kind: integration
        ref: "Node.js WS test: pair-ack on first use, pair-error on reuse"
        status: pass
    human_judgment: true
    rationale: "Phone UI states (spinner, success, error) require browser observation"
  - id: D6
    description: "Disconnect triggers player-disconnected room-event; reconnect via token restores slot and triggers player-reconnected"
    requirement: SESS-04
    verification:
      - kind: integration
        ref: "Node.js WS test: player-disconnected + reconnect join-ack slot=2 + player-reconnected events"
        status: pass
    human_judgment: true
    rationale: "Roster visual state transitions (hold dot → green dot) require browser observation"
  - id: D7
    description: "Leave Room clears storage and allows create/join in same tab without page reload"
    verification:
      - kind: manual_procedural
        ref: "Human verified in Chrome browser — leave then create works"
        status: pass
    human_judgment: true
    rationale: "SPA state reset behavior requires browser observation"

duration: 90min
completed: 2026-07-07
status: complete
---

# Phase 3 Plan 04: Summary

**Full SPA with lobby/room/phone views, QR pairing, slot roster, event log, and dual-storage reconnect flow**

## Performance

- **Duration:** ~90 min (across multiple sessions including fix iterations)
- **Completed:** 2026-07-07
- **Tasks:** 3 (Tasks 1-2 auto, Task 3 human checkpoint)
- **Files modified:** 6

## Accomplishments

- Single-page application with 5 views (lobby, game-select, join-form, room, phone) served from `client/dist/index.html`
- `client/dist/room.js` — SPA router, WS client with pre-warm and message queue, QR render via qrcode@1.4.4 CDN, 8-slot roster with live updates, event log (max 50 entries, auto-scroll), reconnect flow
- Dual-storage reconnect: sessionStorage slot (tab-specific, survives reload) + localStorage token keyed by room+slot (survives tab close, no cross-tab collision)
- Fixed 3 pre-existing compile failures: ws_echo.rs and broker_relay.rs missing 4th arg to run_with_listener, TurnCredentials missing Debug derive

## Task Commits

1. **Task 1: index.html** — `8a48202` (feat)
2. **Task 2: room.js** — `ebdb3f5` (feat) + `c53cc46 0023b70 1d6fc2d fb34abc 7c68e62 231f6f1 ccea7a6` (fixes)
3. **Task 3: human checkpoint** — verified 2026-07-07

## Files Created/Modified

- `client/dist/index.html` — full SPA HTML with 5 views, inline CSS design system, qrcode CDN
- `client/dist/room.js` — SPA logic, 764 lines
- `server/tests/ws_echo.rs` — added Arc<RoomRegistry> arg to run_with_listener call
- `server/tests/broker_relay.rs` — same fix
- `server/src/turn_creds.rs` — added Debug derive to TurnCredentials

## Decisions Made

- **localStorage vs sessionStorage for reconnect:** sessionStorage alone breaks new-tab reconnect (tab-scoped); localStorage alone causes cross-tab slot collision when multiple players use same browser. Solution: write slot to both (sessionStorage primary), write token to localStorage keyed by `room+slot`. `isFirstJoin` guard prevents reload from overwriting newest joiner's localStorage slot.
- **qrcode@1.4.4 not 1.5.x:** jsDelivr 1.5.x URL 404s — that version dropped the `build/` directory from the npm package.
- **connectWS() after leaveRoom():** WS was set to null on leave; next create/join queued messages to null socket → permanent loading. Re-warm on leave fixes this.
- **pairing_url relative path:** Server emits `/phone?token=...` when BASE_URL env var is empty. Acceptable for localhost testing; phone testing requires BASE_URL set to LAN IP.

## Deviations from Plan

### Auto-fixed Issues

**1. qrcode CDN version** — Plan specified qrcode@1.5.4; 1.5.x dropped build/ directory. Fixed to 1.4.4 (`c53cc46`).

**2. Creator username** — Plan used auto-generated host name; UX required real username input. Added input-create-username field (`0023b70`).

**3. Test compilation failures** — run_with_listener gained 4th arg in Plan 03-02 but tests weren't updated. Fixed both tests + TurnCredentials Debug during human checkpoint.

**4. sessionStorage → dual storage** — D-17 specified sessionStorage; new-tab reconnect requires localStorage. Resolved with dual-storage pattern maintaining tab isolation via isFirstJoin guard.

**5. pair-error reason** — Server emits `invalid_token` not `token_used` for reused tokens. Client default copy handles it correctly.

## Issues Encountered

- reconnect token collision across browser tabs when using shared localStorage key → resolved with room+slot keyed tokens and isFirstJoin guard on slot write
- leaveRoom permanent-loading bug → WS null after leave, not re-warmed → fixed with connectWS() at end of leaveRoom()

## Next Phase Readiness

- Phase 3 complete: room creation, slot assignment, pairing token flow, reconnect, event log all verified end-to-end
- Phase 4 (phone controller) can assume: WS connected phone client identified by `pair-ack.desktop_id`, slot assigned, reconnect token in hand
- BASE_URL must be set to LAN IP for real phone QR testing in Phase 4

---
*Phase: 03-session-and-pairing*
*Completed: 2026-07-07*
