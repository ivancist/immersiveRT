---
status: complete
post_uat_fixes:
  - fix-leave-room-slot-hold (3a85df8, e118f7c, 8e03d34) — immediate slot release on leave, ack-based close, WS-stays-open race elimination
phase: 03-session-and-pairing
source: [03-04-SUMMARY.md]
started: 2026-07-07T00:00:00Z
updated: 2026-07-07T00:00:00Z
---

## Current Test

number: 5
name: Leave Room clears state
result: pass
testing: complete

## Tests

### 1. Create Room flow (D2)
requirement: SESS-01
rationale: QR canvas render and pushState navigation require browser observation
expected: Open https://localhost:8443, create a room — URL becomes /room/{code}, QR renders, short code visible, 8-slot roster shows slot 1 occupied
result: pass

### 2. Join Room flow (D3)
requirement: SESS-03
rationale: Event log display and SPA navigation require browser observation
expected: Open a second tab at https://localhost:8443, join using the room code and a username — tab navigates to same /room/{code}, first tab event log shows "player-joined" for the new player
result: pass

### 3. Phone pairing page (D5)
requirement: SESS-02
rationale: Phone UI states (spinner, success, error) require browser observation
expected: Copy the pairing URL from the QR page (or open https://localhost:8443/phone?token=...), page shows spinner then "Paired successfully"; visiting the same URL a second time shows an error
result: pass

### 4. Disconnect / reconnect (D6)
requirement: SESS-04
rationale: Roster visual state transitions (hold dot → green dot) require browser observation
expected: Close the second tab — first tab roster shows that slot as disconnected (hold state). Re-open a new tab, reconnect using the same room code — first tab shows that slot restored and "player-reconnected" in event log
result: pass
note: Reconnect auto-triggers via direct /room/{code} URL navigation; lobby entry point does not auto-reconnect (expected — SPA reads room code from URL to look up localStorage token)

### 5. Leave Room clears state (D7)
rationale: SPA state reset behavior requires browser observation
expected: While on the room page, click "Leave Room" — you return to the lobby in the same tab with no page reload, and can create or join a new room successfully
result: pass

## Auto-Passed

### D1. Lobby loads (auto — curl verified)
description: https://localhost:8443/ returns 200 with Create Room and Join Room buttons
result: pass
source: automated
verification: "curl -sk https://localhost:8443/ | grep -c btn-create-room → 1"

### D4. Room full rejection (auto — integration test)
description: 9th join attempt receives join-error reason=room_full
result: pass
source: automated
verification: "Node.js WS test: 9th join-error reason=room_full"

## Summary

total: 7
passed: 7
issues: 0
pending: 0
skipped: 0
blocked: 0

## Gaps

<!-- filled during diagnosis if issues are found -->
