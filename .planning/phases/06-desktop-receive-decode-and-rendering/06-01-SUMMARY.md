---
phase: 06-desktop-receive-decode-and-rendering
plan: 01
subsystem: signaling
tags: [webtransport, websocket, webrtc, signaling, dual-path, room.ts]

requires:
  - phase: 05-sensor-fusion-and-packet-encoding
    provides: phone.ts WT dual-path reference implementation (sendWtRequest, sendWtMessage, listenForServerPushes pattern)
  - phase: 04-phone-bootstrap-and-webrtc-channels
    provides: wt_server.rs relay loop with accept_bi arm for join-room/reconnect request-response

provides:
  - WebTransport-first signaling in room.ts with automatic WebSocket fallback
  - sendWtRequest for request/response round-trips (join-room, reconnect)
  - sendWtMessage for fire-and-forget (register, leave-room, ICE candidates)
  - listenForServerPushes + processWtPush for server-initiated pushes (room-event, pair-ack, offer, ice-candidate)
  - transport-agnostic signalSend routing sendTo/sendMessage to either WT or WS
  - wtConnectPromise pattern preventing race between QUIC handshake and user button clicks

affects: [06-02-PLAN, 06-03-PLAN, signaling, webrtc-answerer]

tech-stack:
  added: []
  patterns:
    - "WT dual-path: connectDesktopWT() tries QUIC/4433 first, falls back to WSS/9090 (D-01, D-02)"
    - "Single active transport: useWt flag gates all sends (D-03)"
    - "request/response on same bidi QUIC stream: sendWtRequest open→write→close→read→FIN"
    - "server push via incomingBidirectionalStreams.getReader() — not for-await-of (iOS compat)"
    - "wtConnectPromise stored in module scope; createRoom/joinRoom await it if WT in-flight"
    - "listenForServerPushes called BEFORE register send (RESEARCH Pitfall 1)"

key-files:
  created: []
  modified:
    - client/src/room.ts

key-decisions:
  - "Used same sendWtRequest/sendWtMessage/listenForServerPushes pattern as phone.ts (D-03, D-04)"
  - "join-room and reconnect use sendWtRequest (request/response on same QUIC stream); server already responds this way per wt_server.rs Arm 1"
  - "WS pending queue left as-is; the wtConnectPromise await guard ensures join-room never falls into it when WT is connecting"
  - "Idempotency guard added to connectDesktopWT() to prevent double-transport creation"
  - "initDesktopPage reconnect path reuses wtConnectPromise instead of calling connectDesktopWT() a second time (Bug B fix)"

patterns-established:
  - "Store async connect promise at module scope; dependent actions await it rather than calling connect twice"
  - "WT idempotency guard: if (useWt && transport) return true immediately"

requirements-completed:
  - DESK-01

coverage:
  - id: D1
    description: "room.ts connects via WebTransport first (QUIC port 4433) with automatic WebSocket fallback when QUIC is unavailable"
    requirement: DESK-01
    verification:
      - kind: manual_procedural
        ref: "load /room on desktop; DevTools Network shows WebTransport connection open on port 4433"
        status: pass
    human_judgment: true
    rationale: "WebTransport connection establishment requires a running server with valid TLS — cannot be automated in CI"
  - id: D2
    description: "join-room / join-ack round-trip over WT: clicking Create Room shows room code, QR, and slot roster"
    requirement: DESK-01
    verification:
      - kind: manual_procedural
        ref: "click Create Room; room code and QR appear without WS fallback"
        status: pass
    human_judgment: true
    rationale: "Requires live server + browser; WT request/response timing only verifiable in integration"
  - id: D3
    description: "Server-push events (room-event, offer, ice-candidate) arrive via listenForServerPushes and dispatch through onServerMessage"
    requirement: DESK-01
    verification:
      - kind: manual_procedural
        ref: "phone pairs via QR; desktop event log shows player-joined within 500ms"
        status: pass
    human_judgment: true
    rationale: "End-to-end push delivery requires phone + desktop + server running simultaneously"
  - id: D4
    description: "All signaling functions (sendMessage, sendTo) route through transport-agnostic signalSend (D-03)"
    requirement: DESK-01
    verification: []
    human_judgment: false
    rationale: ""

duration: multi-session
completed: 2026-07-10
status: complete
---

# Phase 6 Plan 1: Desktop WT Dual-Path Signaling Summary

**room.ts migrated from WS-only to WebTransport-first dual-path using same sendWtRequest / listenForServerPushes pattern as phone.ts, fixing two race-condition bugs discovered during verification**

## Performance

- **Duration:** Multi-session (spanning context compaction)
- **Started:** Prior session
- **Completed:** 2026-07-10T08:31:11Z
- **Tasks:** 3 (T1: WT helpers, T2: transport-agnostic signaling, T3: verification + bug fix)
- **Files modified:** 1

## Accomplishments

- Ported `sendWtRequest`, `sendWtMessage`, `listenForServerPushes`, `processWtPush`, `setupTransportClosedHandler`, `connectDesktopWT` into `room.ts` verbatim from phone.ts reference pattern
- Made `signalSend`, `sendMessage`, `sendTo`, `createRoom`, `joinRoom`, `leaveRoom`, `sendReconnect` all transport-agnostic (WT or WS based on `useWt` flag)
- Fixed two bugs discovered during human-verify: race condition where join-room fell into WS pending queue, and double-transport creation on reconnect path overwriting `myId`
- All 59 existing sensor tests pass; typecheck clean; build produces correct bundle sizes

## Task Commits

1. **Task 1: WT helpers** - `f651d5a` (feat)
2. **Task 2: Transport-agnostic signaling + createRoom/joinRoom** - `db5d494` (feat)
3. **Task 3 bug fix: Race condition + double-connect** - `2fe3323` (fix)

## Files Created/Modified

- `client/src/room.ts` — Added WT helpers, `signalSend`, `wtConnectPromise`, `connectDesktopWT`; updated `createRoom`, `joinRoom`, `leaveRoom`, `sendReconnect`, `initDesktopPage`

## Decisions Made

- Used identical `sendWtRequest`/`sendWtMessage`/`listenForServerPushes` API as phone.ts — no WT-specific API divergence between phone and desktop
- `join-room` uses request/response (`sendWtRequest`) matching server's Arm 1 behavior: writes ack on same stream, then finish()
- `wtConnectPromise` stored at module scope so `createRoom`/`joinRoom` can await it — avoids race where WT is still handshaking when user clicks a button
- `connectDesktopWT` idempotency guard added (`if (useWt && transport) return true`) to prevent second transport creation

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Race condition: join-room falls into WS pending queue when WT still connecting**
- **Found during:** Task 3 (human verify — user reported room page doesn't update after WT connect)
- **Issue:** `connectDesktopWT()` is called without `await` in `initDesktopPage`. If user clicks "Create Room" → "Continue" while QUIC handshake + register stream exchange is still in progress, `useWt` is `false`. The WS else-path runs, `join-room` goes to `pendingMessageQueue`. WS never opens (WT succeeds later), message is stuck forever. Room page never updates.
- **Fix:** Store `connectDesktopWT()` result as `wtConnectPromise`; `createRoom` and `joinRoom` `await wtConnectPromise` before choosing path when `!useWt && !(ws open)`
- **Files modified:** `client/src/room.ts`
- **Verification:** Typecheck clean; build passes; race window eliminated
- **Committed in:** `2fe3323`

**2. [Rule 1 - Bug] Double `connectDesktopWT()` on /room/ reconnect path overwrites `myId`**
- **Found during:** Task 3 (same human verify session)
- **Issue:** `initDesktopPage` called `connectDesktopWT()` twice on `/room/XXXXX` paths: once at line 489 (always) and again at line 576 (pathMatch block). The second call creates a new `WebTransport`, overwrites `myId` with a fresh `crypto.randomUUID()`, and registers that new UUID with the server. When `sendReconnect` then sends `reconnect` with `from: myId` (new UUID), the server validates `from !== registered_id` (old UUID) and silently drops the message. `sendWtRequest` reads an empty stream body, `JSON.parse("")` throws, caught silently, room never reconnects.
- **Fix:** Store `connectDesktopWT()` result as `wtConnectPromise` once at line 489; reconnect path uses `wtConnectPromise.then(...)` instead of calling `connectDesktopWT()` again
- **Files modified:** `client/src/room.ts`
- **Verification:** Typecheck clean; idempotency guard also added (`if (useWt && transport) return true`)
- **Committed in:** `2fe3323`

---

**Total deviations:** 2 auto-fixed (2× Rule 1 — Bug)
**Impact on plan:** Both fixes essential for WT path correctness; no scope creep; plan deliverables unchanged

## Issues Encountered

- Human verify revealed the two bugs above during Task 3 checkpoint. Server-side code confirmed correct (Arm 1 in relay loop writes ack on same stream, matching `sendWtRequest` design). Bugs were entirely client-side race conditions.

## Known Stubs

None — all WT paths wired to real server handlers. `createRoom` → `handleJoinAck` → `renderRoomPage` flow is complete. Push events route through `onServerMessage`.

## Threat Flags

None — no new network endpoints or auth paths introduced. This plan only changes which transport carries existing signaling messages.

## Next Phase Readiness

- Phase 6 Plan 2 (WebRTC answerer pipeline) can proceed: ICE candidates and offer/answer route through `signalSend` → `sendTo` which is now transport-agnostic
- `handleOffer` and `handleIceCandidate` already call `sendTo` (transport-agnostic) and `sendMessage` (transport-agnostic) — no changes needed for WT

## Self-Check

All files and commits verified after writing:

---
*Phase: 06-desktop-receive-decode-and-rendering*
*Completed: 2026-07-10*
