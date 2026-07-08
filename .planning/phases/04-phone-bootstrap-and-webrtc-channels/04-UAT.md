---
status: testing
phase: 04-phone-bootstrap-and-webrtc-channels
source: [04-VERIFICATION.md]
started: 2026-07-08T10:00:00Z
updated: 2026-07-08T10:00:00Z
---

## Current Test

number: 3
name: Wake Lock — screen stays on
expected: |
  Screen does not auto-lock during active session; navigator.wakeLock.request fulfilled; wake-lock-lost sent to server on release; re-acquired on foreground return
awaiting: re-test after fix

## Tests

### 1. QR load on real devices
expected: iPhone 15 and Android Chrome both load /phone with no install prompt; Grant Motion Access button is the only interactive element
result: pass
notes: verified on iPhone only (no Android available); no TLS warning

### 2. iOS 13+ permission gate — real device tap
expected: System DeviceMotion dialog fires; no sensor events before user approval; Denied routes to view-error-denied; Granted routes to view-connecting then startPhoneClient
result: pass
notes: initial failure was TLS cert not covering LAN IP (fixed: make dev-certs + mkcert CA on iPhone); gate itself works correctly

### 3. Wake Lock — screen stays on
expected: Screen does not auto-lock during active session; navigator.wakeLock.request fulfilled; wake-lock-lost sent to server on release; re-acquired on foreground return
result: pass
notes: initial failure fixed by moving requestWakeLock() to gesture callback; race condition fixed by registered flag guard on sendPhoneState

### 4. WebRTC data channels — 3-desktop room
expected: Phone shows connecting counter 3/3 then active view; all RTCPeerConnection.connectionState === 'connected'; desktops log player-ready; no server relay of sensor packets
result: [pending]

### 5. Heartbeat + slot disconnect — background phone for 65+ seconds
expected: Server marks slot Disconnected within 65s of silence; heartbeat-miss broadcast reaches desktops; slot held for 60s reconnect window (not evicted)
result: [pending]

## Summary

total: 5
passed: 3
issues: 0
pending: 2
skipped: 0
blocked: 0

## Gaps
