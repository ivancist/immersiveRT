---
slug: 260710-wt-race-and-fullscreen-hint
status: complete
date: 2026-07-10
commit: 3e26c64
---

## Changes

- `client/src/room.ts`: `setupTransportClosedHandler` — added `if (transport !== t) return` guard; old transport's closed handler no longer clobbers newly-created transport instance during leaveRoom reconnect
- `client/phone.html`: removed `btn-fullscreen` button; added rotation-lock tip text
- `client/src/phone.ts`: removed `fsBtn` event listener block
