---
phase: 04-phone-bootstrap-and-webrtc-channels
plan: "01"
subsystem: phone-bootstrap
status: complete
tags: [phone, webtransport, webrtc-signaling, pairing, ios-permission, nginx]
dependency_graph:
  requires: []
  provides:
    - phone.html six-view shell served at /phone
    - phone.js permission gate + WebTransport pair bootstrap
    - pair-ack enhanced with peers[] roster + ICE servers
    - SlotInfo.phone_client_id recorded at pair time
  affects:
    - server/src/signaling.rs (PeerInfo, PairAckPayload enhanced)
    - server/src/room_registry.rs (SlotInfo, RoomRegistry, handle_pair)
    - server/src/main.rs (RoomRegistry::new 5-arg)
    - server/src/wt_server.rs (pair match arm)
    - server/src/ws_server.rs (pair match arm)
    - docker/nginx/nginx.conf (try_files $uri.html added)
tech_stack:
  added: []
  patterns:
    - TDD red/green for Rust pair-ack tests
    - Collect-then-drop DashMap pattern (hold RefMut only for write, drop before async)
    - iOS DeviceMotionEvent.requestPermission() in synchronous click handler (D-12)
    - listenForServerPushes started before register/pair to avoid RESEARCH Pitfall 2
    - WebTransport bidi-stream request/response (sendWtRequest) + fire-and-forget (sendWtMessage)
key_files:
  created:
    - client/dist/phone.html
    - client/dist/phone.js
  modified:
    - server/src/signaling.rs
    - server/src/room_registry.rs
    - server/src/main.rs
    - server/src/wt_server.rs
    - server/src/ws_server.rs
    - server/tests/ws_echo.rs
    - server/tests/broker_relay.rs
    - docker/nginx/nginx.conf
decisions:
  - "RoomRegistry.turn_shared_secret added — threaded from main.rs TURN_SHARED_SECRET env var so handle_pair can generate ephemeral TURN credentials without an extra HTTP call"
  - "coturn host derived from base_url strip (trim https://, split on :) — phone can override from location.hostname if needed"
  - "pairing_url in pair-ack echoes base_url+/phone (not a new token) — reconnect semantics use reconnect_token field"
  - "#[allow(dead_code)] added to forward-declared structs (RtcChannelReadyPayload, PhoneStatePayload, PlayerReadyPayload) per project pattern — activated in Plans 02/03"
  - "SlotInfo.last_heartbeat added now with #[allow(dead_code)] — Plan 03 activates it in handle_heartbeat"
metrics:
  duration: 12 min
  completed: "2026-07-08"
  tasks_completed: 3
  files_changed: 9
---

# Phase 04 Plan 01: Phone Bootstrap — Permission Gate, pair-ack Roster + ICE, /phone Shell — Summary

Phone bootstrap QR-load → permission gate → paired with roster. A phone loads phone.html at /phone, taps "Grant Motion Access" (iOS-safe synchronous handler), connects over WebTransport, registers, pairs, and receives the full desktop roster (peers[]) plus ephemeral ICE server credentials — ready for Plan 02 to open WebRTC data channels.

## Tasks Completed

| # | Task | Commit | Key Files |
|---|------|--------|-----------|
| 1 | Extend pair-ack with roster + ICE servers and record phone_client_id (TDD) | f6cc839 | signaling.rs, room_registry.rs, main.rs, wt_server.rs, ws_server.rs |
| 2 | Build phone.html six-view shell and enable /phone serving | 1408d0a | client/dist/phone.html, docker/nginx/nginx.conf |
| 3 | Implement phone.js permission gate + WebTransport pair bootstrap | c1dbdf5 | client/dist/phone.js |

TDD RED commit: 48f9b03 (4 failing tests — compile-fail on missing phone_client_id param and SlotInfo.phone_client_id field)
TDD GREEN commit: f6cc839 (full implementation, 4 new tests passing)

## Verification Results

- `cargo test` — 57 tests pass across all test binaries (26 unit + 29 bin + 1 ws_echo + 1 broker_relay)
- 4 new pair-ack tests pass: test_pair_ack_includes_peers, test_pair_ack_records_phone_client_id, test_pair_ack_includes_ice_servers, test_pair_ack_invalid_token_still_errors
- `cargo build` — clean, 7 warnings (all pre-existing; no new warnings introduced)
- `node --check client/dist/phone.js` — syntax valid
- OK-PHONE-HTML grep gate — 6 views, 5 hidden, btn-grant-motion, color tokens, nginx try_files
- OK-PHONE-JS structural check — requestPermission first call, no await before it

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Integration tests used stale 4-arg RoomRegistry::new()**
- **Found during:** Task 1 GREEN phase
- **Issue:** `server/tests/ws_echo.rs` and `server/tests/broker_relay.rs` called `RoomRegistry::new()` with the old 4-argument signature, causing compile failures in those test binaries
- **Fix:** Updated both integration test files to pass `"turn-secret".to_string()` as the new `turn_shared_secret` parameter
- **Files modified:** `server/tests/ws_echo.rs`, `server/tests/broker_relay.rs`
- **Commit:** f6cc839

**2. [Rule 2 - Missing critical] #[allow(dead_code)] on forward-declared structs**
- **Found during:** Task 1 GREEN phase
- **Issue:** New structs in signaling.rs (PeerInfo, PairAckPayload, RtcChannelReadyPayload, PhoneStatePayload, PlayerReadyPayload) triggered dead_code warnings, violating the "no new warnings" acceptance criteria
- **Fix:** Added `#[allow(dead_code)]` with plan-reference comments matching the existing project pattern; also suppressed `last_heartbeat` warning on SlotInfo
- **Files modified:** `server/src/signaling.rs`, `server/src/room_registry.rs`
- **Commit:** f6cc839

## Known Stubs

| Stub | File | Reason |
|------|------|--------|
| `case 'peer-joined'` / `case 'peer-left'` | client/dist/phone.js | Plan 02 fills openChannelToPeer / closePeer |
| `case 'player-ready'` | client/dist/phone.js | Plan 02 fills onPlayerReady |
| `case 'offer'` / `case 'answer'` / `case 'ice-candidate'` | client/dist/phone.js | Plan 02 fills RTCPeerConnection offer/answer/ICE exchange |
| `wakeLockSentinel`, `heartbeatInterval`, `openChannelCount` state vars | client/dist/phone.js | Plan 02/03 activates these (declared now for state block completeness) |
| `SlotInfo.last_heartbeat` | server/src/room_registry.rs | Plan 03 activates in handle_heartbeat |

Note: These stubs do NOT prevent Plan 01's goal (QR load → permission gate → paired with roster) — all stub paths are future features, not missing Plan 01 requirements.

## Threat Flag Scan

No new trust boundary surface introduced beyond what the plan's threat model covers:
- T-04-01 (envelope.from spoofing): pre-existing wt_server.rs guard at line 200 still covers the pair message path; handle_pair now receives phone_client_id from registered from-field (not attacker-controlled payload)
- T-04-02 (token replay): validate_and_consume single-use check preserved verbatim
- T-04-06 (malformed pair payload): raw_payload["token"].as_str() defensive extraction preserved, returns pair-error/invalid_payload

## Self-Check: PASSED

All files verified present on disk. All 4 task commits verified in git history.
