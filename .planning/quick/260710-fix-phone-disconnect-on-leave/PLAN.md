---
slug: fix-phone-disconnect-on-leave
date: 2026-07-10
status: in_progress
file: client/src/phone.ts
---

# Fix: Phone stays on view-active after desktop leaves room

## Problem

When desktop clicks "Leave Room", the server correctly sends `peer-left` to the phone.
The phone calls `closePeer(peerId)` which closes the RTCPeerConnection and decrements
`openChannelCount`. But `updateConnectingUI()` only updates the counter text element —
it never transitions the phone back to `view-connecting`.

Result: phone stays on `view-active` showing the sensor UI with no connected desktop.

## Root Cause

`updateConnectingUI()` at client/src/phone.ts:691 only updates `#chan-open` text.
No view transition when `openChannelCount` drops to 0.

## Fix

In `updateConnectingUI()`, when `openChannelCount === 0 && sensorPipelineRunning`:
1. Set `sensorPipelineRunning = false` — allows re-calibration on next desktop join
2. Call `showView('view-connecting')` — phone shows "waiting for desktop" UI

## Why sensorPipelineRunning reset

The flag prevents re-calibration on desktop *reconnect* (same desktop, temporary disconnect).
When the desktop *intentionally leaves*, a new desktop should get fresh calibration.
Resetting here is correct: `peer-left` from `handle_leave` is only sent on intentional leave.

## Task

1. Edit `updateConnectingUI()` in `client/src/phone.ts` — 3-line change
2. Build verify: `npm run typecheck && npm run build` in client/
3. Commit

## Acceptance

- Phone transitions to view-connecting within ~1s of desktop clicking "Leave Room"
- When a new desktop joins, phone goes through calibration (sensorPipelineRunning was reset)
- No regression: desktop reload (temporary disconnect) still skips calibration
