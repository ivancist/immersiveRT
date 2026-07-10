---
phase: 04-phone-bootstrap-and-webrtc-channels
plan: "03"
subsystem: session-durability
tags: [heartbeat, wake-lock, phone-state, peer-mesh, websocket, webtransport]
status: complete

dependency_graph:
  requires: [04-02]
  provides: [PHONE-06, PHONE-07, D-06, D-07, D-15, D-16, D-17, D-18, D-19]
  affects:
    - server/src/room_registry.rs
    - server/src/wt_server.rs
    - server/src/ws_server.rs
    - server/src/main.rs
    - client/dist/phone.js

tech_stack:
  added: []
  patterns:
    - broadcast-before-mark-disconnected for heartbeat miss (ensures Connected filter in broadcast_to_room still routes)
    - collect-then-drop DashMap pattern (Pitfall 3) used in handle_phone_state and phones_missing_heartbeat
    - tokio::spawn hold-timer reuse from on_client_disconnect in handle_heartbeat_miss
    - feature-detect + silent-catch pattern for navigator.wakeLock (Pitfall 4)

key_files:
  created: []
  modified:
    - server/src/room_registry.rs
    - server/src/wt_server.rs
    - server/src/ws_server.rs
    - server/src/main.rs
    - client/dist/phone.js

decisions:
  - Broadcast heartbeat-miss BEFORE marking slot Disconnected so broadcast_to_room's Connected filter still routes to the desktop in the same slot
  - phones_missing_heartbeat excludes slots with last_heartbeat=None — miss detection starts only after first heartbeat post-player-ready
  - handle_phone_state excludes sender_id from broadcast (broadcast_to_room filters by Connected desktop client_ids, never phone_client_id)
  - Motion indicator threshold 10.3 (gravity-inclusive) = 9.8G rest + 0.5 m/s² UI-SPEC threshold

metrics:
  duration_minutes: 55
  completed_date: "2026-07-08"
  tasks_completed: 3
  tasks_total: 3
  files_modified: 5
---

# Phase 04 Plan 03: Session Durability Summary

**One-liner:** Heartbeat monitor (65s timeout), Wake Lock (screen-awake), phone-state relay (D-17/D-18), and dynamic peer-joined/peer-left mesh (D-06/D-07) make `player-ready` a durable, self-healing session.

## Tasks Completed

| Task | Name | Commit | Key Files |
|------|------|--------|-----------|
| 1 (RED) | Heartbeat TDD tests | baa9afa | room_registry.rs |
| 1 (GREEN) | Heartbeat tracking + monitor | e23a254 | room_registry.rs, wt_server.rs, ws_server.rs, main.rs |
| 2 (RED) | Phone-state + peer-mesh TDD tests | 99a574f | room_registry.rs |
| 2 (GREEN) | Phone-state relay + peer-joined/peer-left | 5cdd708 | room_registry.rs, wt_server.rs, ws_server.rs |
| 3 | phone.js durability: Wake Lock, heartbeat, state, mesh | 01d689e | client/dist/phone.js |

## New Symbols

**Server (room_registry.rs):**
- `handle_heartbeat(&self, phone_client_id)` — synchronous O(1) Instant update
- `phones_missing_heartbeat(&self, timeout) -> Vec<(RoomCode, SlotId, String, String)>` — stale-slot scanner
- `handle_heartbeat_miss(&self, room_code, slot_id, broker)` — broadcast then mark Disconnected + spawn hold timer
- `handle_phone_state(&self, sender_id, payload, broker)` — relay phone-state to Connected desktops only
- Peer-joined push added in `handle_join` (D-06)
- Peer-left push added in `on_client_disconnect` and `handle_leave` (D-07)

**Server (main.rs):**
- `spawn_heartbeat_monitor(registry, broker, timeout_secs, interval_secs)` — tokio background task
- `HEARTBEAT_TIMEOUT_SECS` env var (default 65)
- `HEARTBEAT_MONITOR_INTERVAL_SECS` env var (default 10)

**Server (wt_server.rs + ws_server.rs):**
- `"heartbeat"` match arm — calls `handle_heartbeat`
- `"phone-state"` match arm — calls `handle_phone_state`

**Client (phone.js):**
- `requestWakeLock()` — feature-detected Wake Lock with release listener
- `startHeartbeat()` — 5s setInterval
- `sendPhoneState(statePayload)` — phone→server→desktops relay
- `startMotionIndicator()` — devicemotion magnitude gate (10.3 gravity-inclusive)
- `closePeer(peerId)` — close RTCPeerConnection and remove from map
- `visibilitychange` listener — foreground/background state + immediate heartbeat + channel self-heal
- `dc.onclose` — sends channel-lost; `dc.onopen` recovery — sends channel-recovered

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Broadcast-before-mark pattern for handle_heartbeat_miss**
- **Found during:** Task 1 GREEN phase (test failure)
- **Issue:** `broadcast_to_room` filters to `SlotStatus::Connected` slots. If we marked the slot Disconnected first, the slot was excluded from the broadcast and the desktop never received the heartbeat-miss notification.
- **Fix:** Broadcast the phone-state heartbeat-miss event WHILE the slot is still Connected, then mark it Disconnected in a second DashMap mutation. This preserves the intent (notify desktops) while matching the test expectation.
- **Files modified:** server/src/room_registry.rs
- **Commit:** e23a254

## Test Results

41 cargo tests pass (up from 15 before Phase 4). 8 new tests added in this plan:
- `test_heartbeat_updates_last_heartbeat`
- `test_phones_missing_heartbeat_flags_stale`
- `test_heartbeat_miss_marks_disconnected`
- `test_heartbeat_unknown_phone_is_noop`
- `test_phone_state_relays_to_desktops`
- `test_phone_state_channel_lost_includes_with`
- `test_peer_joined_push_to_phone`
- `test_peer_left_push_to_phone`

## Threat Mitigations Applied

| Threat | Mitigation Applied |
|--------|--------------------|
| T-04-09 (DoS: heartbeat flood) | handle_heartbeat is O(1); existing 64 KiB cap + semaphore bound rate |
| T-04-10 (Spoofing: forged heartbeat) | envelope.from guard in wt_server/ws_server already drops mismatched from-fields |
| T-04-11 (Tampering: forged peer-left) | peer-left is server-originated only — route_to_phone is called from on_client_disconnect/handle_leave, never from client input |
| T-04-12 (DoS: slot never released after miss) | handle_heartbeat_miss reuses bounded hold timer + release_slot_if_disconnected |

## Known Stubs

None — all Plan 03 stubs in phone.js are filled.

## Threat Flags

None — no new network endpoints or trust boundaries introduced beyond those in the plan's threat model.

## Self-Check: PASSED

All 6 files confirmed present. All 5 task commits confirmed in git log.
