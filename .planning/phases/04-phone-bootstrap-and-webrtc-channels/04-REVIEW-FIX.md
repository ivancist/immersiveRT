---
phase: 04-phone-bootstrap-and-webrtc-channels
fixed_at: 2026-07-08T00:00:00Z
review_path: .planning/phases/04-phone-bootstrap-and-webrtc-channels/04-REVIEW.md
iteration: 1
findings_in_scope: 15
fixed: 15
skipped: 0
status: all_fixed
---

# Phase 04: Code Review Fix Report

**Fixed at:** 2026-07-08
**Source review:** .planning/phases/04-phone-bootstrap-and-webrtc-channels/04-REVIEW.md
**Iteration:** 1

**Summary:**
- Findings in scope: 15 (4 Critical, 11 Warning)
- Fixed: 15
- Skipped: 0

## Fixed Issues

### CR-01: Bearer token comparison is not constant-time — timing attack on `/turn-credentials`

**Files modified:** `server/Cargo.toml`, `server/src/main.rs`
**Commit:** fc6f6c6
**Applied fix:** Added `subtle = "2"` to Cargo.toml. Replaced `!=` string comparison with `subtle::ConstantTimeEq::ct_eq` on byte slices. The `use subtle::ConstantTimeEq;` import is scoped to the function body. Comparison now runs in constant time regardless of input length.

---

### CR-02: `player_ready_sent` dedup guard is not atomic — TOCTOU race

**Files modified:** `server/src/room_registry.rs`
**Commit:** 44f70dd
**Applied fix:** Replaced the two-operation `contains_key` + `insert` pattern with a single `dashmap::mapref::entry::Entry` match. The shard lock is held across both the check and the insert, eliminating the window where two concurrent tasks could both see `Vacant` and both broadcast `player-ready`.

---

### CR-03: D-17 channel-recovered notification is structurally dead — can never fire

**Files modified:** `client/dist/phone.js`
**Commit:** a4fe148
**Applied fix:** Captured `isRecovery` synchronously at the top of `openChannelToPeer`, before `peerConnections.set` overwrites the entry. The `dc.onopen` callback now checks the `isRecovery` closure variable (captured at call time) rather than the peerConnections map (which has already been updated by the time `onopen` fires asynchronously). Also removed the now-redundant `peerConnections.has(peerId)` check from inside `dc.onopen`.

---

### CR-04: `visibilitychange` handler calls `sendPhoneState`/`sendWtMessage` before transport is initialized

**Files modified:** `client/dist/phone.js`
**Commit:** 0d6b38d
**Applied fix:** Added `if (!transport) { return; }` early-return guard at the top of the `visibilitychange` handler. Added `.catch()` to the `sendWtMessage` call in the foreground branch. Updated `startHeartbeat` to guard against null transport with the same `if (!transport) { return; }` check and added `.catch()` to the interval's `sendWtMessage` call, preventing recurring unhandled rejections when the transport closes while the interval is still running.

---

### WR-01: `dc.onclose` never decrements `openChannelCount` — stale channel counter

**Files modified:** `client/dist/phone.js`
**Commit:** 4fed709
**Applied fix:** Added `channelIsOpen = false` closure variable to each `openChannelToPeer` invocation. `dc.onopen` sets it to `true`. `dc.onclose` conditionally decrements `openChannelCount` and calls `updateConnectingUI` only when `channelIsOpen` is true (then resets it to false). Removed the `openChannelCount--` from `closePeer` (WR-11 will add it back after suppressing `dc.onclose`; see WR-11).

---

### WR-02: `peer-joined` handler dereferences `msg.payload.peer` without null guards

**Files modified:** `client/dist/phone.js`
**Commit:** c8c2ce1
**Applied fix:** Added an explicit guard before calling `openChannelToPeer`:
```js
if (!msg.payload || !msg.payload.peer || typeof msg.payload.peer.id !== 'string') {
  console.warn('[WT] peer-joined: malformed payload', msg.payload);
  break;
}
```
Prevents a silent TypeError that would have been swallowed by the outer try/catch, leaving the WebRTC mesh incomplete.

---

### WR-03: `view-ended` is unreachable — no code path ever calls `showView('view-ended')`

**Files modified:** `client/dist/phone.js`
**Commit:** d0d3537
**Applied fix:** Added `transport.closed.then(...).catch(...)` observation in `startPhoneClient` immediately after the pair succeeds. Both branches clear `heartbeatInterval` and call `showView('view-ended')`. Also added a `case 'session-ended':` branch in `handleServerPush` that performs the same cleanup and view transition, covering server-initiated session termination.

---

### WR-04: Concurrent new-room creation is not atomic — data loss under concurrent joins

**Files modified:** `server/src/room_registry.rs`
**Commit:** 2c8ebaf
**Applied fix:** Replaced the `generate_room_code()` helper call + separate `self.rooms.insert()` with an inline loop using `dashmap::mapref::entry::Entry::Vacant`. The check and insert are now atomic under a single shard lock, eliminating the window where two tasks could both see the key absent and both insert (silently overwriting the first room). The `generate_room_code` helper remains in place for any future callers but is no longer called from `handle_join`.

---

### WR-05: TURN credential TTL equals `pairing_ttl_secs` — credentials may expire before new peer connections

**Files modified:** `server/src/room_registry.rs`, `server/src/main.rs`
**Commit:** 52daf40
**Applied fix:** Added `turn_credential_ttl_secs: u64` field to `RoomRegistry` struct (with doc comment). Added it as the sixth parameter to `RoomRegistry::new`. Updated `handle_pair` to use `self.turn_credential_ttl_secs` instead of `self.pairing_ttl_secs` when calling `generate_turn_credentials`. Added `TURN_CREDENTIAL_TTL_SECS` env var parsing to `main.rs` with a default of 3600 s (1 hour). Updated all three `RoomRegistry::new` call sites in the test module.

---

### WR-06: `PairingTokenStore.used_tokens` grows unbounded — memory leak on long-running servers

**Files modified:** `server/src/pairing_token.rs`, `server/src/room_registry.rs`, `server/src/main.rs`
**Commit:** 36decc4
**Applied fix:** Changed `used_tokens` map value type from `()` to `u64` (expiry timestamp). In `validate_and_consume`, the `Vacant` branch now inserts `expiry` instead of `()`. Added `sweep_expired` method on `PairingTokenStore` that calls `self.used_tokens.retain(|_, exp| *exp > now)`. Added `sweep_expired_pairing_tokens` delegation method on `RoomRegistry`. Spawned a background tokio task in `main.rs` that calls this method every 5 minutes, bounding the map to approximately 5× the per-TTL join rate.

---

### WR-07: `handle_reconnect` overwrites slot without verifying it is `Disconnected`

**Files modified:** `server/src/room_registry.rs`
**Commit:** 8455dd9
**Applied fix:** Added a status check inside the `if let Some(Some(info))` guard:
```rust
if info.status != SlotStatus::Disconnected {
    return serde_json::json!({
        "type": "join-error",
        "payload": {"reason": "slot_not_held"}
    });
}
```
This rejects reconnects when the slot is in any state other than `Disconnected` (e.g., the hold timer fired and released the slot between the token lookup and the `get_mut`), preventing a stale `reconnect_tokens` entry from causing a `slot_not_found` on future pair attempts.

---

### WR-08: `String::from_utf8_lossy` silently corrupts non-UTF-8 broker payloads

**Files modified:** `server/src/ws_server.rs`
**Commit:** 2be6583
**Applied fix:** Replaced `String::from_utf8_lossy(&payload).into_owned()` with a `match String::from_utf8(payload)` expression. The `Ok` arm forwards the text as before. The `Err` arm logs `tracing::error!(...)` and `continue`s (skips the invalid payload without closing the connection). No silent data corruption; non-UTF-8 payload bugs will now appear in logs.

---

### WR-09: `nginx.conf` specifies no TLS protocols or ciphers — may serve TLS 1.0/1.1

**Files modified:** `docker/nginx/nginx.conf`
**Commit:** e904246
**Applied fix:** Added three directives after the certificate lines:
```nginx
ssl_protocols       TLSv1.2 TLSv1.3;
ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:...;
ssl_prefer_server_ciphers off;
```
Disables TLS 1.0/1.1 (RFC 8996 deprecated), restricts to modern AEAD cipher suites, and sets `ssl_prefer_server_ciphers off` per Mozilla modern profile recommendation.

---

### WR-10: Motion indicator ignores `linearAcceleration` despite comment saying to prefer it

**Files modified:** `client/dist/phone.js`
**Commit:** 5cc8b3d
**Applied fix:** Changed `var a = e.accelerationIncludingGravity` to `var a = e.linearAcceleration || e.accelerationIncludingGravity`. Added `var threshold = e.linearAcceleration ? 0.5 : 10.3;` to use the correct threshold for each sensor: 0.5 m/s² for gravity-subtracted linear acceleration (orientation-independent) and 10.3 m/s² for the gravity-inclusive fallback.

---

### WR-11: `closePeer` triggers a spurious `channel-lost` via `pc.close()` → `dc.onclose`

**Files modified:** `client/dist/phone.js`
**Commit:** fc5c93a
**Applied fix:** Added `intentionalClose = false` closure variable to each `openChannelToPeer` invocation (alongside `channelIsOpen` from WR-01). `dc.onclose` now returns early when `intentionalClose` is true, suppressing the spurious `channel-lost` notification. Added a `flagClose: function() { intentionalClose = true; }` helper to the peerConnections entry. Updated `closePeer` to call `entry.flagClose()` before `entry.pc.close()`, then manually decrement `openChannelCount` and call `updateConnectingUI` (since `dc.onclose` is now suppressed for the intentional-close path).

---

## Skipped Issues

None — all 15 in-scope findings were successfully fixed.

---

_Fixed: 2026-07-08_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
