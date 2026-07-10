---
quick_id: 260710-whi
status: complete
date: 2026-07-10
commit: 8022055
---

# Quick Task 260710-whi: Four Phone UX Fixes — Summary

## Changes

**client/phone.html:** Replaced `#landscape-overlay` div+CSS with `@media (orientation: landscape) { body { transform: rotate(-90deg); transform-origin: left top; width: 100vh; height: 100vw; position: absolute; top: 100%; left: 0; } }`.

**client/src/phone.ts:**
- Added `tryRequestFullscreen()` — calls `requestFullscreen()` / webkit prefix, silently ignores failures
- Called `tryRequestFullscreen()` alongside `tryLockPortrait()` in button click handler
- `peer-left` handler: reads `reason` from payload (default `'disconnect'`); only resets `sensorPipelineRunning` and calls `showView('view-ended')` when `reason === 'leave'`

**server/src/room_registry.rs:**
- `on_client_disconnect`: adds `"reason": "disconnect"` to peer-left payload
- `handle_leave`: adds `"reason": "leave"` to peer-left payload

## Behaviour After Fix

| Scenario | Phone shows |
|----------|-------------|
| Desktop reloads | view-connecting → skip calibration when desktop rejoins |
| Desktop clicks Leave Room | view-ended immediately |
| Phone rotated to landscape | Page rotates -90deg, appears upright |
| Button tapped | Fullscreen requested (Chrome Android) |
