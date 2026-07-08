---
phase: 04-phone-bootstrap-and-webrtc-channels
reviewed: 2026-07-08T00:00:00Z
depth: standard
files_reviewed: 7
files_reviewed_list:
  - server/src/room_registry.rs
  - server/src/signaling.rs
  - server/src/wt_server.rs
  - server/src/ws_server.rs
  - server/src/main.rs
  - client/dist/phone.js
  - client/dist/room.js
findings:
  critical: 4
  warning: 9
  info: 3
  total: 16
status: issues_found
---

# Phase 04: Code Review Report

**Reviewed:** 2026-07-08
**Depth:** standard
**Files Reviewed:** 7
**Status:** issues_found

## Summary

Reviewed the full Phase 4 implementation: Rust server modules (`room_registry`, `signaling`, `wt_server`, `ws_server`, `main`) and JavaScript clients (`phone.js`, `room.js`). Also read `broker.rs`, `pairing_token.rs`, and `turn_creds.rs` as called dependencies.

The server-side architecture is well-structured: DashMap Ref discipline is consistently followed, HMAC token generation uses constant-time verification (`verify_slice`), hold-timer lifecycle is correctly modeled, and the `broadcast_to_room` / `route_to_phone` collect-then-drop patterns correctly avoid holding locks across async boundaries.

Four critical defects were found. Two are in the same function (`handle_rtc_channel_ready`): the `player_ready_sent` guard is never cleared when a desktop reconnects, permanently blocking the `player-ready` broadcast for that phone after any desktop disconnect; and the guard itself has a non-atomic check-then-insert that allows duplicate broadcasts under concurrent confirmations. The other two are: the desktop's reconnect token is needlessly exposed in the `pair-ack` sent to the phone; and `phone.js` attaches a `visibilitychange` handler that calls `sendWtMessage(null, ...)` before any connection exists, generating an unhandled TypeError on tab-switch before pairing.

---

## Critical Issues

### CR-01: `player_ready_sent` never cleared on desktop disconnect — permanently blocks `player-ready` after reconnect

**File:** `server/src/room_registry.rs:1002-1005`

**Issue:** `player_ready_sent` is a `DashMap<(RoomCode, String), ()>` (keyed by room+phone_id) that acts as a one-shot dedup guard. When all WebRTC channels are first confirmed the guard is inserted and `player-ready` fires. Later, if a desktop disconnects (`on_client_disconnect`) and reconnects (`handle_reconnect`), it gets a **new** `client_id`. The phone receives a `peer-left` push, closes the old `RTCPeerConnection`, then receives `peer-joined` and opens a new one. Both sides send `rtc-channel-ready` again. `handle_rtc_channel_ready` reaches the dedup check, finds `player_ready_sent` still contains `(room_code, phone_id)` from the first confirmation, and returns early. `player-ready` is **permanently suppressed** for the rest of the session.

No code path in `on_client_disconnect`, `handle_reconnect`, or `handle_leave` removes the entry.

**Fix:** Remove the stale dedup entry in `on_client_disconnect` for the disconnecting client, and also remove stale `channel_ready` entries. Minimally:

```rust
// in on_client_disconnect, after finding (room_code, slot_id):
// Clear channel_ready state and player_ready_sent so the phone
// can re-trigger player-ready after the desktop reconnects.
if let Some(phone_id) = self.get_phone_id_for_room_slot(&room_code, slot_id) {
    self.channel_ready
        .retain(|k, _| !(k.0 == room_code && k.2 == *client_id));
    self.player_ready_sent
        .remove(&(room_code.clone(), phone_id));
}
```

A helper `get_phone_id_for_room_slot` collects `phone_client_id` under a short-lived Ref — same collect-then-drop pattern used elsewhere.

---

### CR-02: TOCTOU race on `player_ready_sent` allows duplicate `player-ready` broadcasts

**File:** `server/src/room_registry.rs:1002-1005`

**Issue:** The dedup guard is implemented as two separate DashMap operations:

```rust
if self.player_ready_sent.contains_key(&(room_code.clone(), phone_id.clone())) {
    return;
}
self.player_ready_sent.insert((room_code.clone(), phone_id.clone()), ());
```

Each DashMap operation holds its own shard lock; the shard lock is released between them. When the phone and desktop send `rtc-channel-ready` simultaneously (two separate tokio tasks), both can see `contains_key == false`, both pass the guard, both insert, and both broadcast `player-ready`. Downstream game code receiving two `player-ready` events for the same phone will corrupt initialization state.

**Fix:** Use DashMap's atomic `Entry` API so check and insert occur under a single shard lock:

```rust
use dashmap::mapref::entry::Entry;
match self.player_ready_sent
    .entry((room_code.clone(), phone_id.clone()))
{
    Entry::Occupied(_) => return,
    Entry::Vacant(e) => { e.insert(()); }
}
```

---

### CR-03: Desktop reconnect token unnecessarily exposed in `pair-ack` to phone — enables slot hijacking

**File:** `server/src/room_registry.rs:576-579`, `server/src/room_registry.rs:654-664`

**Issue:** `handle_pair` collects the desktop slot's `reconnect_token` and includes it in the `pair-ack` payload sent to the phone:

```rust
let reconnect_tok = desktop_slot
    .map(|s| s.reconnect_token.clone())
    .unwrap_or_default();
// ...
"reconnect_token": reconnect_token_val,
```

The phone client (`phone.js`) never saves or uses this token, but it is present in the raw response. The `handle_reconnect` function accepts a reconnect token from **any** registered client — there is no check that the caller was ever a desktop. A phone client that reads this token from the `pair-ack` payload can send a `reconnect` message after the legitimate desktop disconnects. This causes the server to:

1. Abort the desktop's hold timer
2. Update the slot's `client_id` to the phone's `client_id`
3. Return a fresh `join-ack` to the phone

The phone now occupies the desktop slot. Room event routing is corrupted for all remaining session participants.

The token is not used by `phone.js` for any legitimate purpose. `PairAckPayload` in `signaling.rs` documents it as "allows re-pair after network interruption" but no phone re-pair flow consumes it.

**Fix:** Remove `reconnect_token` from `pair-ack`. If future phone re-pair needs are identified, generate a **separate** phone-specific token, not the desktop's session token.

```rust
serde_json::json!({
    "type": "pair-ack",
    "payload": {
        "desktop_id": desktop_client_id,
        "slot": slot_id,
        "room_code": room_code,
        // "reconnect_token": removed — phone has no use for desktop's reconnect token
        "pairing_url": pairing_url,
        "peers": peers_list,
        "ice_servers": ice_servers
    }
})
```

---

### CR-04: `visibilitychange` handler calls `sendPhoneState`/`sendWtMessage` before transport is initialized

**File:** `client/dist/phone.js:423-439`

**Issue:** The `visibilitychange` listener is registered unconditionally at module load time (line 423), before any permission grant or WebTransport connection:

```js
document.addEventListener('visibilitychange', function() {
  if (document.visibilityState === 'visible') {
    sendPhoneState({ state: 'foreground' });            // transport is null
    sendWtMessage(transport, { type: 'heartbeat', ... }); // transport is null
    requestWakeLock();
    peerConnections.forEach(function(entry, peerId) {
      if (entry.dc.readyState === 'closed' || ...) {
        peerConnections.delete(peerId);
        openChannelToPeer(peerId);                      // transport is null
      }
    });
  } else {
    sendPhoneState({ state: 'background' });            // transport is null
  }
});
```

`transport` is initialized to `null` (line 9) and only assigned inside `startPhoneClient()`, which is only called after permission is granted and the user taps the button. If the user switches apps before tapping (or after tapping but before `transport.ready` resolves), every subsequent visibility-change event calls `sendWtMessage(null, ...)`, which throws `TypeError: Cannot read properties of null (reading 'createBidirectionalStream')`. This unhandled rejection propagates silently and leaves the app in an inconsistent state.

**Fix:** Guard the handler body with a transport check:

```js
document.addEventListener('visibilitychange', function() {
  if (!transport) { return; }   // not yet connected — nothing to do
  if (document.visibilityState === 'visible') {
    sendPhoneState({ state: 'foreground' });
    // ...
  } else {
    sendPhoneState({ state: 'background' });
  }
});
```

---

## Warnings

### WR-01: `heartbeatInterval` never cleared when transport closes

**File:** `client/dist/phone.js:375-378`

**Issue:** `startHeartbeat` stores the interval handle in `heartbeatInterval` but there is no `clearInterval(heartbeatInterval)` call anywhere in the file — not on transport close, not on error, not on visibility hide. If the WebTransport connection closes (server restart, network loss), the interval continues firing every 5 seconds. Each tick calls `sendWtMessage(transport, ...)` where `transport` is now closed; `createBidirectionalStream()` throws, creating a recurring unhandled rejection every 5 seconds indefinitely.

**Fix:** Listen on `transport.closed` and clear the interval:

```js
transport.closed.then(function() {
    clearInterval(heartbeatInterval);
    heartbeatInterval = null;
}).catch(function() {
    clearInterval(heartbeatInterval);
    heartbeatInterval = null;
});
```

---

### WR-02: `channel-recovered` notification is never sent — dead logic in `dc.onopen`

**File:** `client/dist/phone.js:222-226`

**Issue:** The recovery detection block in `dc.onopen` intends to detect when a closed channel has been re-opened:

```js
dc.onopen = function() {
  openChannelCount++;
  // ...
  if (peerConnections.has(peerId)) {
    var existing = peerConnections.get(peerId);
    if (existing && existing.dc &&
        (existing.dc.readyState === 'closed' || existing.dc.readyState === 'closing')) {
      sendPhoneState({ state: 'channel-recovered', with: peerId });
    }
  }
};
```

`peerConnections.set(peerId, { pc, dc })` is called synchronously at line 235, **before** any async WebRTC negotiation completes. By the time `dc.onopen` fires asynchronously, `peerConnections.get(peerId)` returns the **current** entry (`existing.dc === dc`), and `dc.readyState` is `'open'`. The condition is structurally impossible to satisfy: you cannot be in `onopen` while simultaneously reporting `readyState === 'closed'`.

The visibility-change reconnect path deletes the old entry before calling `openChannelToPeer` (line 432-433), so `peerConnections.has(peerId)` returns `false` for that path as well.

Result: `channel-recovered` is **never** sent to the server under any code path.

**Fix:** Track the previous channel state before overwriting in `peerConnections`:

```js
function openChannelToPeer(peerId) {
  var wasOpen = peerConnections.has(peerId); // remember prior state
  // ...
  dc.onopen = function() {
    openChannelCount++;
    if (wasOpen) {
      sendPhoneState({ state: 'channel-recovered', with: peerId });
    }
    // ...
  };
  peerConnections.set(peerId, { pc, dc });
}
```

---

### WR-03: `handleOffer` leaks `RTCPeerConnection` on duplicate offers

**File:** `client/dist/room.js:212-214`

**Issue:**

```js
function handleOffer(msg) {
  var phoneId = msg.from;
  var pc = new RTCPeerConnection({ ... });
  // ...
  desktopPeers.set(phoneId, pc);
```

If the phone retransmits an offer (e.g., due to re-negotiation or a reconnect), `handleOffer` is called again for the same `phoneId`. The old `RTCPeerConnection` is silently overwritten in the map without calling `.close()`. The old connection remains open, holding DTLS/ICE state and file descriptors, and the associated ICE agent continues running until it times out.

**Fix:** Close and remove any existing connection before creating a new one:

```js
function handleOffer(msg) {
  var phoneId = msg.from;
  var existing = desktopPeers.get(phoneId);
  if (existing) {
    existing.close();
    desktopPeers.delete(phoneId);
  }
  var pc = new RTCPeerConnection({ ... });
```

---

### WR-04: ICE candidates may arrive before `setRemoteDescription` — silent connection failures

**File:** `client/dist/phone.js:334-336`, `client/dist/room.js:244-247`

**Issue:** Both phone and desktop pass ICE candidates directly to `addIceCandidate` without buffering:

```js
// phone.js
case 'ice-candidate':
    entry = peerConnections.get(msg.from);
    if (!entry) { break; }
    await entry.pc.addIceCandidate(msg.payload);
    break;

// room.js
function handleIceCandidate(msg) {
  var pc = desktopPeers.get(msg.from);
  if (!pc) { return; }
  pc.addIceCandidate(msg.payload).catch(...);
}
```

WebRTC specifies that `addIceCandidate` must not be called before `setRemoteDescription`. ICE trickle means candidates can arrive before the `answer` (on the phone) or before `setRemoteDescription` completes (on the desktop). In that case `addIceCandidate` throws `InvalidStateError: remote description not set` and the candidate is silently lost. In high-latency or loopback scenarios (where ICE candidates travel faster than SDP) this causes WebRTC connections to fail or degrade.

**Fix:** Buffer candidates until `setRemoteDescription` resolves:

```js
// Per connection, collect candidates before remote desc is set
var pendingCandidates = [];
var remoteDescSet = false;

// After setRemoteDescription:
remoteDescSet = true;
for (var c of pendingCandidates) { pc.addIceCandidate(c); }
pendingCandidates = [];

// In ice-candidate handler:
if (remoteDescSet) { pc.addIceCandidate(payload); }
else { pendingCandidates.push(payload); }
```

---

### WR-05: `wsReady` variable set but never read — dead code

**File:** `client/dist/room.js:7`, `room.js:107`, `room.js:130`, `room.js:143`

**Issue:** `wsReady` is declared at module level and written in `ws.onopen` (set true), `ws.onclose` (set false), and `ws.onerror` (set false). It is never read in any conditional. The actual send-gate in `sendMessage` uses `ws.readyState === WebSocket.OPEN`, not `wsReady`. The variable provides no behavioral effect and creates a false impression that it guards something.

**Fix:** Remove `wsReady` entirely, or — if it was intended to gate sends on successful registration — use it: replace the `ws.readyState === WebSocket.OPEN` check in `sendMessage` with `wsReady` (which is only set true after the register handshake).

---

### WR-06: Non-constant-time bearer token comparison

**File:** `server/src/main.rs:64`

**Issue:**

```rust
if token != format!("Bearer {}", state.api_token) {
    return Err((axum::http::StatusCode::UNAUTHORIZED, ...));
}
```

`String !=` is a short-circuit comparison that returns as soon as a differing byte is found. Repeated timing measurements of the `/turn-credentials` endpoint can leak the correct prefix of the bearer token character by character. The `/turn-credentials` endpoint is HTTP-accessible (no WebTransport) and produces a round trip that can be timed.

**Fix:** Use `subtle::ConstantTimeEq` or `ring`/`hmac` constant-time comparison:

```rust
use subtle::ConstantTimeEq;
let expected = format!("Bearer {}", state.api_token);
let valid = bool::from(
    expected.as_bytes().ct_eq(token.as_bytes())
);
if !valid {
    return Err((axum::http::StatusCode::UNAUTHORIZED, "Invalid token".into()));
}
```

---

### WR-07: `innerHTML` injection with server-generated `pairingUrl`

**File:** `client/dist/room.js:556-559`, `room.js:574-577`

**Issue:** Two QR fallback paths write the pairing URL directly into `innerHTML`:

```js
canvas.parentElement.innerHTML =
  '<p style="...">Open: ' + pairingUrl + '</p>';
```

`pairingUrl` originates from `payload.pairing_url` in the server's `join-ack`. The server generates it as `BASE_URL + "/phone?token=" + hmac_token`, where `BASE_URL` is an operator-controlled env var and the token is base64url. Under normal operation there is no XSS vector. However, if `BASE_URL` is ever misconfigured (e.g., accidentally set to a value containing `</p><script>...`), or if this code path is ever refactored to accept user-supplied input, `innerHTML` becomes a direct XSS sink. The fix is zero cost.

**Fix:**

```js
var p = document.createElement('p');
p.style.cssText = 'color:#000;font-family:monospace;font-size:12px;word-break:break-all;padding:8px';
p.textContent = 'Open: ' + pairingUrl;   // textContent, never innerHTML
canvas.parentElement.replaceWith(p);
```

---

### WR-08: `openChannelCount` not decremented on unexpected `dc.onclose`

**File:** `client/dist/phone.js:230-233`

**Issue:** `openChannelCount` is incremented in `dc.onopen` (line 213) but only decremented in `closePeer` (line 416), which is called only on a server `peer-left` push. If a data channel closes unexpectedly (network drop, background kill, ICE failure), `dc.onclose` fires:

```js
dc.onclose = function() {
    sendPhoneState({ state: 'channel-lost', with: peerId });
};
```

No decrement. `openChannelCount` remains inflated. The "X/Y channels" display in the active view shows an incorrect higher count for the lifetime of the session.

**Fix:**

```js
dc.onclose = function() {
    if (openChannelCount > 0) { openChannelCount--; }
    updateConnectingUI();
    sendPhoneState({ state: 'channel-lost', with: peerId });
};
```

---

### WR-09: Concurrent new-room creation has a TOCTOU window

**File:** `server/src/room_registry.rs:210-213`

**Issue:** `handle_join` with an empty `room_code_input`:

```rust
let code = self.generate_room_code();          // (1) checks rooms.contains_key
self.rooms.insert(code.clone(), Room::new(...)  // (2) inserts without holding any lock
```

`generate_room_code` contains `if !self.rooms.contains_key(&code) { return code; }`. Between (1) returning and (2) inserting, a concurrent task can generate the same code and insert it first. The second `insert` silently **overwrites** the first room, clobbering its slot assignments and clearing its occupants.

With 32^6 ≈ 10^9 possible codes the per-pair collision probability is ~10^-9, negligible in practice. However, the fix is straightforward: use DashMap's `entry` API to atomically check-and-insert.

**Fix:**

```rust
use dashmap::mapref::entry::Entry;
loop {
    let code = {
        let mut rng = rand::rng();
        (0..CODE_LEN)
            .map(|_| CHARSET[rng.random_range(0..CHARSET.len())] as char)
            .collect::<String>()
    };
    match self.rooms.entry(code.clone()) {
        Entry::Vacant(e) => {
            e.insert(Room::new(code.clone(), game_type.clone()));
            break code;
        }
        Entry::Occupied(_) => continue,
    }
}
```

---

## Info

### IN-01: `sendWtRequest` has no timeout — can hang indefinitely

**File:** `client/dist/phone.js:147-163`

**Issue:** `sendWtRequest` opens a bidi stream and awaits every chunk from the server with no timeout. If the server crashes between receiving the `pair` request and sending the response, `startPhoneClient` stalls forever at `pairResp = await sendWtRequest(...)`. The user sees the connecting view with no error or retry.

**Fix:** Wrap in `Promise.race` with a timeout:

```js
async function sendWtRequest(transport, envelope, timeoutMs) {
  timeoutMs = timeoutMs || 15000;
  return Promise.race([
    _sendWtRequestInner(transport, envelope),
    new Promise(function(_, reject) {
      setTimeout(function() { reject(new Error('Request timed out')); }, timeoutMs);
    })
  ]);
}
```

---

### IN-02: `var codeInput` declared twice in the same function scope

**File:** `client/dist/room.js:310`, `room.js:352`

**Issue:** `initDesktopPage` declares `var codeInput` at line 310 for the input-room-code element, then re-declares it at line 352 inside an `else` block:

```js
var codeInput = document.getElementById('input-room-code');  // line 310
// ...
} else {
    var codeInput = document.getElementById('input-room-code'); // line 352 — shadowing
```

With `var`, both declarations hoist to the same function scope and refer to the same variable. The second declaration is a no-op but implies two independent bindings to readers, masking the fact that line 310's assignment is already available in the `else` block.

**Fix:** Remove the second `var` declaration; the variable from line 310 is already in scope.

---

### IN-03: Magic number `50` for event log max entries

**File:** `client/dist/room.js:720`

**Issue:**

```js
if (log.children.length >= 50) {
    log.removeChild(log.firstChild);
}
```

`50` is a magic number with no named constant or comment. When the UI-SPEC changes the cap or a developer searches for this limit, they must scan all numeric literals.

**Fix:**

```js
const EVENT_LOG_MAX_ENTRIES = 50;
// ...
if (log.children.length >= EVENT_LOG_MAX_ENTRIES) {
```

---

_Reviewed: 2026-07-08_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
