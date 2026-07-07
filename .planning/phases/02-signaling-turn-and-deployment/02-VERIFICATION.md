---
status: passed
phase: 02-signaling-turn-and-deployment
verified: 2026-07-07
threats_open: 0
---

# Phase 02 Verification

## Goal

WebRTC ICE signaling broker, coturn with host networking, ephemeral TURN credentials, full Docker Compose stack.

## UAT Results

6/7 tests passed. 1 blocked by design (TURN relay to loopback denied by SSRF mitigation — correct behavior).

| Test | Result |
|------|--------|
| Cold Start Smoke Test | pass |
| Signaling Broker Message Routing | pass |
| TURN Credential Endpoint Rejects Unauthenticated | pass |
| TURN Credential Endpoint Returns Ephemeral Credentials | pass |
| WebRTC ICE Handshake End-to-End | pass |
| coturn STUN/TURN Reachability | pass |
| TURN Relay Path (relay-only ICE) | blocked — loopback denied by denied-peer-ip SSRF mitigation (correct) |

## Deliverables Verified

- [x] SignalingBroker routes offer/answer/ICE messages by peer ID — no self-echo
- [x] TURN credential endpoint returns HMAC-SHA1 ephemeral credentials (username, password, ttl_seconds)
- [x] Unauthenticated credential requests return HTTP 401
- [x] Port 8081 not published to host (internal-only per WR-08)
- [x] coturn runs with network_mode: host, shared-secret injected at startup via entrypoint
- [x] Docker Compose cold start: all 3 containers up, no crashes
- [x] Makefile dev-certs target codifies mkcert + chmod o+r for non-root container user
- [x] WebRTC peer connection established end-to-end via WS signaling broker
- [x] STUN srflx candidates visible from coturn on port 3478

## Issues Resolved During Phase

- WR-03: TURN secret injected via env var not CLI arg (out of ps/inspect)
- WR-08: Port 8081 removed from host port mapping
- no-loopback-peers: removed (invalid conf directive; loopback covered by denied-peer-ip)
- CR-04: Non-root container user cert permission fix via Makefile dev-certs target
