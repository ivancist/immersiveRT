---
phase: 04-phone-bootstrap-and-webrtc-channels
plan: 02
status: complete
completed: "2026-07-08"
commits:
  - 9a11afd  # Task 1: server channel-readiness tracking + player-ready broadcast
  - 2cbeb8b  # Tasks 2+3: phone.js WebRTC fan-out + room.js desktop answerer
---

# Plan 02 Summary — WebRTC Connection Slice

## What Was Built

**Task 1 (server):** `channel_ready` DashMap keyed `(room_code, phone_id, desktop_id)` tracking
both-sided confirmation; `player_ready_sent` dedup guard; `handle_rtc_channel_ready` that fires
exactly one `player-ready` broadcast once all desktop channels are both-sides confirmed; `route_to_phone`
helper; `rtc-channel-ready` match arm in both wt_server and ws_server. Four passing tests:
both-sides-fires, single-side-no-fire, broadcast-once dedup, two-desktops-waits-for-all.

**Task 2 (phone.js):** Fan-out via `openChannelToPeer` after pair-ack; unreliable data channel
`{ordered:false, maxRetransmits:0}` (D-05 locked); offer produced via `onnegotiationneeded` +
`setLocalDescription()` (no manual createOffer); `handleServerPush` filled for `answer`
(setRemoteDescription), `ice-candidate` (addIceCandidate), `player-ready` (onPlayerReady);
`updateConnectingUI` counting X/Y; `onPlayerReady` switches to view-active and populates
username/room/channel-count + status dot. Wake Lock / heartbeat / motion indicator are Plan 03 stubs.

**Task 3 (room.js):** Desktop WebRTC answerer — `desktopPeers` Map; `sendTo` helper for targeted
envelopes; `handleOffer` (setRemoteDescription → setLocalDescription auto-answer → send answer);
`handleIceCandidate` (addIceCandidate); `handlePlayerReady` (console.info + event log entry);
`ondatachannel → dc.onopen → rtc-channel-ready` (D-08 desktop half). STUN-only for LAN
verification; TURN relay on desktop is Phase 6 (DESK-02).

## Decisions Made

- `handleServerPush` made `async` — allows `await` on setRemoteDescription/addIceCandidate without
  blocking the push-listener loop; caller adds `.catch()` for clean error isolation
- `offer` case removed from phone.js handleServerPush — phone is always the offerer, never receives
  offers; default arm warns on truly unknown types
- `sendTo(type, to, payload)` added alongside `sendMessage` — preserves all existing call sites
  (always `to:''`) while allowing targeted answer/ice-candidate envelopes

## Verification

- `node --check client/dist/phone.js` → OK-PHONE-WEBRTC
- `node --check client/dist/room.js` → OK-DESKTOP-ANSWER
- `cargo test` (Task 1) → full suite green including four channel-readiness tests
- Manual (device): pending phase verification — phone connecting counter reaches N/N, active view
  transitions, desktop connectionState 'connected'

## Phase 03 Stubs Left In Place

- `phone.js onPlayerReady`: `requestWakeLock()`, `startHeartbeat()`, `startMotionIndicator()`
- `phone.js handleServerPush`: `peer-joined` / `peer-left` (payload path corrected to `msg.payload.peer.id`)
- `phone.js openChannelToPeer dc.onclose`: `closePeer(peerId)` + state notification
