---
quick_id: 260707-tuk
slug: fix-leave-room-slot-hold
date: 2026-07-07
status: complete
---

# Summary: fix leave-room slot hold

**Commit:** 3a85df8

**Changes:**
- `server/src/room_registry.rs` — added `handle_leave()`: immediate slot release, hold timer cancel, reconnect token removal, player-left broadcast
- `server/src/ws_server.rs` — `"leave-room"` dispatch arm (no ack)
- `server/src/wt_server.rs` — `"leave-room"` dispatch arm + finish()
- `client/dist/room.js` — sends `{type:"leave-room"}` before `ws.close()` in `leaveRoom()`

**Verification:** 22/22 lib tests pass
