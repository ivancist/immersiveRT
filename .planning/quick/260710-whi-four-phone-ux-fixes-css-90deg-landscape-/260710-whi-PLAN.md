---
quick_id: 260710-whi
slug: four-phone-ux-fixes-css-90deg-landscape
description: Four phone UX fixes: CSS 90deg landscape rotation, requestFullscreen on tap, peer-left reason field in Rust, view-ended on desktop leave
date: 2026-07-10
status: planning
---

# Quick Task 260710-whi: Four Phone UX Fixes

## Fix 1: CSS landscape rotation (phone.html)
Replace `#landscape-overlay` with `@media (orientation: landscape) { body { transform: rotate(-90deg); ... } }`.

## Fix 2: requestFullscreen on tap (phone.ts)
Add `tryRequestFullscreen()` called from button click handler (user gesture context).

## Fix 3: peer-left reason field (room_registry.rs)
- `on_client_disconnect` → `"reason": "disconnect"` (reload/network drop)
- `handle_leave` → `"reason": "leave"` (intentional)
Phone only resets `sensorPipelineRunning` on `leave`, skips calibration on reconnect after reload.

## Fix 4: view-ended on desktop leave (phone.ts)
`peer-left` with `reason=leave` → `showView('view-ended')` instead of `view-connecting`.
