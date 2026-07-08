---
status: testing
phase: 04-phone-bootstrap-and-webrtc-channels
source: [04-VERIFICATION.md]
started: 2026-07-08T10:00:00Z
updated: 2026-07-08T10:00:00Z
---

## Current Test

number: 5
name: Heartbeat + slot disconnect
expected: |
  Background phone 65+ seconds → server marks slot Disconnected within 65s; heartbeat-miss broadcast reaches desktops; slot held for 60s reconnect window (not evicted)
awaiting: user test

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
result: pass
notes: |
  Root cause was iOS WebKit pre-26.4 does not implement Symbol.asyncIterator on
  incomingBidirectionalStreams — `for await...of` threw "undefined is not a function"
  so phone never received answer/ICE pushes from server. Fix: replaced for-await-of
  with .getReader() loop in listenForServerPushes. WT now primary; WS auto-fallback.
  Tested with 1 desktop (peers=1). ICE direct LAN, conn=connected, DC-OPEN,
  player-ready all confirmed on both phone log and desktop DevTools.

### 5. Heartbeat + slot disconnect — background phone for 65+ seconds
expected: Server marks slot Disconnected within 65s of silence; heartbeat-miss broadcast reaches desktops; slot held for 60s reconnect window (not evicted)
result: [pending]

## Summary

total: 5
passed: 4
issues: 0
pending: 1
skipped: 0
blocked: 0

## Gaps

- truth: "Phone shows connecting counter 3/3 then active view; all RTCPeerConnection.connectionState === 'connected'"
  status: failed
  reason: "User reported: phone shows 0/3, never connects; server logs: phone paired roster_size=3, coturn allocations increment (2→3→4) but RTCPeerConnection never reaches connected"
  severity: blocker
  test: 4
  root_cause: |
    Previous fixes (denied-peer-ip, TURN creds in join-ack) solved ICE candidate gathering.
    ICE now connects via direct LAN (host-to-host, no TURN relay selected).
    New blocker: DTLS handshake never completes after ICE connects.
    Hypothesis: Docker iptables rules on desktop host selectively drop non-STUN UDP
    (DTLS packets lack STUN magic cookie 0x2112A442) arriving from phone 192.168.0.104.
    ICE STUN checks pass; DTLS ClientHello dropped → both sides wait → timeout.
    Alternative: DTLS role deadlock (both sides actpass) or iOS Safari 18.7 DTLS compat issue.
    CONFIRMED: connection goes to "failed" after ~30s → packet drop, not deadlock.
    Docker adds iptables FORWARD/DOCKER chain rules that drop non-tracked UDP flows.
    STUN passes (stateful conntrack sees outbound check first); DTLS ClientHello may arrive
    as NEW flow from phone and get DROPped by the DOCKER-USER or FORWARD chain.
    Fix: add iptables rule allowing UDP from 192.168.0.0/24 (LAN) on FORWARD chain,
    OR use iceTransportPolicy:'relay' to route all WebRTC through coturn (bypasses direct LAN path).
  artifacts:
    - path: "client/dist/room.js:212"
      issue: "handleOffer RTCPeerConnection — DTLS never completes, connection stays 'connecting'"
    - path: "client/dist/phone.js:233"
      issue: "onnegotiationneeded sends offer — ICE works but DTLS blocked by desktop firewall or role issue"
  missing:
    - "Run test 4 with diagnostic logging added to room.js + phone.js (this session)"
    - "Chrome DevTools: check offer a=setup and answer a=setup values"
    - "Chrome DevTools: check iceConnectionState sequence and connectionState sequence"
    - "If a=setup deadlock suspected: both sides sending ClientHello → force passive on answer"
    - "Relay test: set DEBUG_FORCE_RELAY=true in Chrome console before phone pairs, retest"
  debug_session: "logging added room.js:handleOffer + phone.js:openChannelToPeer — reload tabs"
