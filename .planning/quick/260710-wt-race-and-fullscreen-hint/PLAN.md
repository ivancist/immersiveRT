---
slug: 260710-wt-race-and-fullscreen-hint
date: 2026-07-10
status: in-progress
---

# Fix WT close race + replace fullscreen button with rotation hint

## Bug 1: WT transport close race (room.ts)

`setupTransportClosedHandler` attaches `onWtClose` to a transport instance `t`, but
`onWtClose` unconditionally clobbers the module-level `transport` variable. When
`leaveRoom` closes the old transport and immediately calls `connectDesktopWT()`, the
new transport is assigned to `transport` before the old `.closed` promise resolves.
When it does resolve, `onWtClose` nullifies `transport` (now pointing at the new
instance) and calls `connectWS(null)`, leaving `connectDesktopWT` to crash at
`null.incomingBidirectionalStreams`.

**Fix:** Guard `onWtClose` with `if (transport !== t) return;`

## Bug 2: Fullscreen button useless (phone.html + phone.ts)

Fullscreen API does not prevent browser tabs/chrome from appearing on rotation.
Remove the button; add a plain tip text instead.

**Fix:**
- `phone.html`: remove `btn-fullscreen` button div; add `<p class="size-caption text-secondary mt-md">Tip: Lock your phone rotation for the best experience.</p>`
- `phone.ts`: remove `fsBtn` event listener block in DOMContentLoaded

## Files

- `client/src/room.ts` — `setupTransportClosedHandler`
- `client/phone.html` — permission view
- `client/src/phone.ts` — DOMContentLoaded
