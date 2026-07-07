---
status: complete
phase: 02-signaling-turn-and-deployment
source: [02-01-SUMMARY.md, 02-02-SUMMARY.md, 02-03-SUMMARY.md, 02-04-SUMMARY.md, 02-05-SUMMARY.md]
started: 2026-07-07T00:00:00Z
updated: 2026-07-07T12:00:00Z
---

## Current Test

[testing complete]

## Tests

### 1. Cold Start Smoke Test
expected: Kill any running containers (`docker compose down -v`). Run `docker compose up` (requires .env with TURN_SHARED_SECRET, API_TOKEN, COTURN_EXTERNAL_IP, CERT_PATH, KEY_PATH set). All three containers start without errors: server, coturn, static-files. Server logs show WebTransport and WebSocket listeners ready. No crash, no restart loop.
result: pass

### 2. Signaling Broker Message Routing
expected: Two browser tabs (or wscat connections) connect to `wss://localhost:9090`. Tab A sends `{"type":"register","from":"phone-1","to":"","payload":null}`. Tab B sends `{"type":"register","from":"desktop-1","to":"","payload":null}`. Tab A sends `{"type":"offer","from":"phone-1","to":"desktop-1","payload":{}}`. Tab B receives a message with `msg_type == "offer"` and `from == "phone-1"`. Tab A gets nothing (no self-echo).
result: pass

### 3. TURN Credential Endpoint Rejects Unauthenticated Requests
expected: `curl http://localhost:8081/turn-credentials` (no Authorization header) returns HTTP 401. Response body contains "Missing Authorization header" or similar. No credentials leaked.
result: pass

### 4. TURN Credential Endpoint Returns Ephemeral Credentials
expected: `curl -H "Authorization: Bearer <API_TOKEN>" http://localhost:8081/turn-credentials` returns JSON with `username`, `password`, and `ttl_seconds` fields. Calling twice returns different `username` values (different expiry timestamps — format is `"{unix_timestamp}:anonymous"`). `password` is non-empty in both cases.
result: pass

### 5. WebRTC ICE Handshake End-to-End
expected: Open the static-files page at `http://localhost:8090` in two browser tabs (phone and desktop). Both tabs complete the WebRTC offer/answer/ICE exchange brokered through the Rust WS server. Both tabs show `connectionState === 'connected'` and the data channel is open. Messages sent from one tab appear in the other.
result: pass

### 6. coturn STUN/TURN Reachability
expected: `turnutils_uclient -u <username> -w <password> <server-ip>:3478` (credentials from test 4) succeeds — STUN binding and TURN allocation both pass. Or: in a browser RTCPeerConnection, a STUN candidate appears from the coturn server IP within ~2 seconds of `createOffer()`.
result: pass

### 7. TURN Relay Path
expected: Force relay-only ICE by using `iceTransportPolicy: 'relay'` in RTCPeerConnection config in both tabs. Despite no direct path, the WebRTC data channel still opens (may take longer, ~5–10s). Both tabs show `connectionState === 'connected'` via the TURN relay path.
result: blocked
blocked_by: physical-device
reason: "TURN allocations succeed (auth works, allocation count increments) but denied-peer-ip=127.0.0.0-127.255.255.255 SSRF mitigation blocks relay to loopback. Both browser tabs on same machine resolve to 127.0.0.1 — relay path intentionally denied. Requires two hosts on different non-private IPs to fully verify."

## Summary

total: 7
passed: 6
issues: 0
pending: 0
skipped: 0
blocked: 1

## Gaps

[none — all issues resolved]
