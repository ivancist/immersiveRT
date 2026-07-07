---
quick_id: 260707-tuk
slug: fix-leave-room-slot-hold
date: 2026-07-07
status: in-progress
---

# Fix: leave-room slot hold

**Problem:** `leaveRoom()` closes WS without notifying server. Server treats it as a disconnect, starts 60s hold timer. Slot stays locked; old room link unusable until timer fires.

**Fix:** Add explicit `leave-room` message type. Client sends it before WS close; server immediately releases slot without starting hold timer.

## Changes

1. `server/src/room_registry.rs` — add `handle_leave()`: finds slot, releases immediately, cancels any existing hold timer, removes reconnect token, broadcasts player-left
2. `server/src/ws_server.rs` — add `"leave-room"` dispatch arm (no ack)
3. `server/src/wt_server.rs` — add `"leave-room"` dispatch arm + finish()
4. `client/dist/room.js` — send `{type:"leave-room"}` before `ws.close()` in `leaveRoom()`
