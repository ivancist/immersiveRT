---
phase: 04-phone-bootstrap-and-webrtc-channels
reviewed: 2026-07-08T00:00:00Z
depth: standard
files_reviewed: 10
files_reviewed_list:
  - client/dist/phone.html
  - client/dist/phone.js
  - docker/nginx/nginx.conf
  - server/src/main.rs
  - server/src/room_registry.rs
  - server/src/signaling.rs
  - server/src/ws_server.rs
  - server/src/wt_server.rs
  - server/tests/broker_relay.rs
  - server/tests/ws_echo.rs
findings:
  critical: 4
  warning: 11
  info: 4
  total: 19
status: issues_found
---

# Phase 04: Code Review Report

**Reviewed:** 2026-07-08
**Depth:** standard
**Files Reviewed:** 10
**Status:** issues_found

## Summary

Reviewed the full Phase 4 implementation: phone client bootstrap and WebRTC mesh
(`phone.js`, `phone.html`), Rust server modules (`main.rs`, `room_registry.rs`,
`signaling.rs`, `ws_server.rs`, `wt_server.rs`), nginx config, and integration tests.
Supporting modules `broker.rs`, `pairing_token.rs`, and `turn_creds.rs` were read as
called dependencies.

The architecture is sound. DashMap Ref discipline (collect-then-drop) is consistently
applied, HMAC pairing-token validation uses constant-time `verify_slice`, hold-timer
lifecycle is correctly modeled, and the dual WT/WS dispatch tables are symmetric and
complete for Phase 4 message types.

Four blockers were found: (1) the Bearer-token comparison on the TURN-credentials
endpoint is not constant-time, enabling a timing attack; (2) the `player_ready_sent`
dedup guard uses a non-atomic contains-key + insert pair that allows duplicate
`player-ready` broadcasts under tokio's multi-threaded scheduler; (3) the D-17
channel-recovered notification in `dc.onopen` can structurally never fire because the
`peerConnections` entry is overwritten before the callback runs; and (4) the
`visibilitychange` handler fires before the WebTransport connection exists, producing
unhandled Promise rejections on null transport.

---

## Critical Issues

### CR-01: Bearer token comparison is not constant-time — timing attack on `/turn-credentials`

**File:** `server/src/main.rs:64`
**Issue:** The `Authorization: Bearer <token>` check uses Rust's `!=` operator, which
short-circuits on the first differing byte. An attacker with repeated access to the
`/turn-credentials` HTTP endpoint can time responses and recover the correct `API_TOKEN`
prefix character by character.

```rust
// Vulnerable — short-circuits
if token != format!("Bearer {}", state.api_token) {
```

**Fix:** Use a constant-time byte comparison from the `subtle` crate:
```rust
use subtle::ConstantTimeEq;
let expected = format!("Bearer {}", state.api_token);
if expected.as_bytes().ct_eq(token.as_bytes()).unwrap_u8() == 0 {
    return Err((axum::http::StatusCode::UNAUTHORIZED, "Invalid token".into()));
}
```

---

### CR-02: `player_ready_sent` dedup guard is not atomic — TOCTOU race causes duplicate `player-ready` broadcasts

**File:** `server/src/room_registry.rs:1002-1005`
**Issue:** The guard is two separate DashMap operations; each acquires and releases its
own shard lock:

```rust
if self.player_ready_sent.contains_key(&(room_code.clone(), phone_id.clone())) {
    return;
}
// ← another tokio thread can reach here simultaneously
self.player_ready_sent.insert((room_code.clone(), phone_id.clone()), ());
```

In tokio's default multi-threaded scheduler two tasks processing concurrent
`rtc-channel-ready` messages from phone and desktop run on separate OS threads.
Both can see `contains_key == false`, both insert, and both broadcast `player-ready`.
On the phone, `onPlayerReady` is called twice: two `heartbeatInterval` timers are
started (the first interval reference is overwritten, orphaning a timer), and two
`devicemotion` event listeners accumulate.

**Fix:** Use the DashMap `Entry` API, which holds the shard lock across check and
insert — matching the pattern already used in `pairing_token.rs`:
```rust
use dashmap::mapref::entry::Entry;
match self.player_ready_sent.entry((room_code.clone(), phone_id.clone())) {
    Entry::Occupied(_) => return,
    Entry::Vacant(e)   => { e.insert(()); }
}
// Only the task that wins the Vacant entry reaches this point.
```

---

### CR-03: D-17 channel-recovered notification is structurally dead — can never fire

**File:** `client/dist/phone.js:212-236`
**Issue:** `openChannelToPeer` calls `peerConnections.set(peerId, { pc, dc })` at
line 235 **synchronously**, before the function returns. `dc.onopen` fires
asynchronously (after ICE/DTLS completes). By the time `onopen` executes,
`peerConnections.get(peerId)` returns the **current** entry — the same `dc` that just
opened. Its `readyState` is `'open'`, so the check

```js
if (existing.dc.readyState === 'closed' || existing.dc.readyState === 'closing')
```

is always false. `sendPhoneState({ state: 'channel-recovered' })` is never called
under any code path.

The reconnect path in `visibilitychange` (line 431-434) makes this worse: it calls
`peerConnections.delete(peerId)` before `openChannelToPeer(peerId)`, so
`peerConnections.has(peerId)` returns false at call time — the check is skipped
entirely for the recovery case it was designed to handle.

**Fix:** Capture reconnect intent before overwriting the `peerConnections` entry:
```js
function openChannelToPeer(peerId) {
  // Detect reconnect BEFORE peerConnections.set overwrites the entry.
  var prev = peerConnections.get(peerId);
  var isRecovery = prev && prev.dc &&
    (prev.dc.readyState === 'closed' || prev.dc.readyState === 'closing');

  var pc = new RTCPeerConnection({ iceServers: iceServers });
  var dc = pc.createDataChannel('sensor', { ordered: false, maxRetransmits: 0 });

  dc.onopen = function() {
    openChannelCount++;
    updateConnectingUI();
    sendWtMessage(transport, {
      type: 'rtc-channel-ready', from: myId, to: '', payload: { with: peerId }
    }).catch(function(err) {
      console.warn('[WebRTC] rtc-channel-ready send failed:', err);
    });
    if (isRecovery) {
      sendPhoneState({ state: 'channel-recovered', with: peerId });
    }
  };
  // ... dc.onclose, pc.onnegotiationneeded, pc.onicecandidate unchanged ...
  peerConnections.set(peerId, { pc: pc, dc: dc });
}
```

---

### CR-04: `visibilitychange` handler calls `sendPhoneState`/`sendWtMessage` before transport is initialized

**File:** `client/dist/phone.js:423-440`
**Issue:** The listener is registered unconditionally at script-load time. `transport`
(line 9) is `null` until `startPhoneClient()` assigns it after permission is granted.
If the user backgrounds the tab before tapping "Grant Motion Access" (or during the
connecting phase before `transport.ready` resolves), every visibility change executes:

```js
sendPhoneState({ state: 'background' });          // calls sendWtMessage(null, ...)
// or on foreground:
sendPhoneState({ state: 'foreground' });
sendWtMessage(transport, { type: 'heartbeat', ... }); // transport === null
```

`sendWtMessage(null, envelope)` reaches `await null.createBidirectionalStream()`,
throws `TypeError`, and becomes an unhandled Promise rejection. Because neither
`sendPhoneState` nor the direct `sendWtMessage` call here attach `.catch()`, the
rejections fire silently. The `heartbeatInterval` timer (once started) suffers the
same problem if the transport closes: fire-and-forget calls to `sendWtMessage` on a
closed transport generate a recurring unhandled rejection every 5 seconds.

**Fix:** Guard the handler and the heartbeat:
```js
document.addEventListener('visibilitychange', function() {
  if (!transport) { return; }  // not yet connected
  if (document.visibilityState === 'visible') {
    sendPhoneState({ state: 'foreground' });
    sendWtMessage(transport, { type: 'heartbeat', from: myId, to: '', payload: {} })
      .catch(function(e) { console.debug('[HB] foreground heartbeat failed:', e); });
    requestWakeLock();
    peerConnections.forEach(function(entry, peerId) {
      if (entry.dc.readyState === 'closed' || entry.dc.readyState === 'closing') {
        peerConnections.delete(peerId);
        openChannelToPeer(peerId);
      }
    });
  } else {
    sendPhoneState({ state: 'background' });
  }
});

// In startHeartbeat():
heartbeatInterval = setInterval(function() {
  if (!transport) { return; }
  sendWtMessage(transport, { type: 'heartbeat', from: myId, to: '', payload: {} })
    .catch(function(e) { console.debug('[HB] heartbeat send failed:', e); });
}, 5000);
```

---

## Warnings

### WR-01: `dc.onclose` never decrements `openChannelCount` — stale channel counter

**File:** `client/dist/phone.js:230-232`
**Issue:** `openChannelCount` is incremented in `dc.onopen` (line 213) but decremented
only inside `closePeer` (line 416), which is only called on a server `peer-left` push.
When a data channel closes unexpectedly (ICE failure, network drop), `dc.onclose`
fires and sends `channel-lost` but never adjusts the counter. The `X/Y channels`
display in the active view stays permanently too high. On the next foreground
reconnect, `dc.onopen` for the new channel increments an already-inflated count.

**Fix:** Add a decrement (with double-decrement guard) to `dc.onclose`. Use a
closure boolean to prevent `closePeer`'s explicit `pc.close()` from decrementing again:
```js
var channelIsOpen = false;
dc.onopen = function() {
  channelIsOpen = true;
  openChannelCount++;
  // ...
};
dc.onclose = function() {
  if (channelIsOpen) {
    channelIsOpen = false;
    if (openChannelCount > 0) { openChannelCount--; }
    updateConnectingUI();
  }
  sendPhoneState({ state: 'channel-lost', with: peerId });
};
```
And remove the `openChannelCount--` line from `closePeer`, letting the `dc.onclose`
callback handle it.

---

### WR-02: `peer-joined` handler dereferences `msg.payload.peer` without null guards

**File:** `client/dist/phone.js:341`
**Issue:** A malformed or future-changed server push where `msg.payload` is absent or
`msg.payload.peer` is null would throw `TypeError: Cannot read properties of null`.
The outer `try/catch` in `listenForServerPushes` (line 301) swallows it, silently
dropping the `peer-joined` event and leaving the WebRTC mesh incomplete.

```js
case 'peer-joined':
  openChannelToPeer(msg.payload.peer.id);  // TypeError if peer or payload is null
  break;
```

**Fix:**
```js
case 'peer-joined':
  if (!msg.payload || !msg.payload.peer || typeof msg.payload.peer.id !== 'string') {
    console.warn('[WT] peer-joined: malformed payload', msg.payload);
    break;
  }
  openChannelToPeer(msg.payload.peer.id);
  break;
```

---

### WR-03: `view-ended` is unreachable — no code path ever calls `showView('view-ended')`

**File:** `client/dist/phone.js` (whole file)
**Issue:** `#view-ended` exists in the HTML ("Session ended — your session timed out
or the room closed") but `showView('view-ended')` is never called anywhere in
`phone.js`. `handleServerPush` has no `session-ended` case. The `transport.closed`
promise is never observed. Users whose sessions expire, whose rooms close, or whose
transport is severed will remain stuck on the active view with a stale UI.

**Fix:** Observe `transport.closed` after assignment in `startPhoneClient`:
```js
transport.closed.then(function() {
  clearInterval(heartbeatInterval);
  heartbeatInterval = null;
  showView('view-ended');
}).catch(function() {
  clearInterval(heartbeatInterval);
  heartbeatInterval = null;
  showView('view-ended');
});
```
Also add a `case 'session-ended':` branch in `handleServerPush`.

---

### WR-04: Concurrent new-room creation is not atomic — data loss under concurrent joins

**File:** `server/src/room_registry.rs:210-214`
**Issue:** `handle_join` with an empty `room_code_input` calls `generate_room_code()`
which checks `!self.rooms.contains_key(&code)`, then `handle_join` separately calls
`self.rooms.insert(code, ...)`. The check and insert are not atomic. Two tokio tasks
running simultaneously can both generate the same code, both see the key absent, and
both insert. DashMap's `insert` silently overwrites; the first room's slot assignments
are destroyed with no notification to its occupants.

The per-call collision probability is ~N/10^9 (negligible at normal room counts), but
the fix is a one-line change using the already-imported DashMap `Entry` API.

**Fix:**
```rust
use dashmap::mapref::entry::Entry;
let room_code: RoomCode = if room_code_input.is_empty() {
    loop {
        let code = {
            use rand::RngExt;
            let mut rng = rand::rng();
            (0..6).map(|_| CHARSET[rng.random_range(0..CHARSET.len())] as char).collect::<String>()
        };
        if let Entry::Vacant(e) = self.rooms.entry(code.clone()) {
            e.insert(Room::new(code.clone(), game_type.clone()));
            break code;
        }
        // collision — regenerate
    }
} else { ... }
```

---

### WR-05: TURN credential TTL equals `pairing_ttl_secs` (default 90 s) — credentials may expire before new `peer-joined` connections

**File:** `server/src/room_registry.rs:611-615`
**Issue:** Ephemeral TURN credentials are generated at pair time with
`ttl_seconds = self.pairing_ttl_secs` (default 90 s). The phone uses these same
credentials for all WebRTC connections, including ones opened in response to future
`peer-joined` events. coturn validates credentials at allocation time. If a second
desktop joins more than 90 s after the phone paired, the TURN allocation for the new
WebRTC connection will fail (401), and the phone falls back to direct P2P only.

**Fix:** Add a separate `TURN_CREDENTIAL_TTL_SECS` env var (suggested default 3600 s)
distinct from `pairing_ttl_secs`. Thread it through `RoomRegistry::new` and use it
in `handle_pair`.

---

### WR-06: `PairingTokenStore.used_tokens` grows unbounded — memory leak on long-running servers

**File:** `server/src/pairing_token.rs:69-75`
**Issue:** Consumed tokens are inserted into `used_tokens` with `e.insert(())` and
never evicted. Expired tokens are rejected before the `used_tokens` check runs,
so valid-but-consumed tokens accumulate indefinitely. At a join rate of R/s with
TTL of T seconds, the map grows by R×T entries continuously.

**Fix:** Store the expiry alongside the entry and periodically sweep expired tokens
in a background task:
```rust
// Change store type:
used_tokens: Arc<DashMap<String, u64>>,  // token → expiry_unix

// In validate_and_consume Vacant branch:
e.insert(expiry);

// New sweep method (call from a spawned task every few minutes):
pub fn sweep_expired(&self) {
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs();
    self.used_tokens.retain(|_, exp| *exp > now);
}
```

---

### WR-07: `handle_reconnect` overwrites slot without verifying it is `Disconnected`

**File:** `server/src/room_registry.rs:422-425`
**Issue:** After the reconnect-token lookup succeeds, the code unconditionally sets
`info.status = SlotStatus::Connected` without checking the current status. If the
hold timer fires between the `reconnect_tokens.get` lookup and the `get_mut` mutation
(the slot is set to `None` by `release_slot_if_disconnected`), the `if let Some(Some(info))`
guard skips silently. The caller has already removed the old token and inserted a new
one pointing to this now-vacant slot; future pair attempts for this slot return
`pair-error: slot_not_found`, leaving a stale entry in `reconnect_tokens`.

**Fix:** Assert the slot is in Disconnected state before accepting the reconnect:
```rust
if let Some(Some(info)) = room_ref.slots.get_mut(idx) {
    if info.status != SlotStatus::Disconnected {
        return serde_json::json!({
            "type": "join-error",
            "payload": {"reason": "slot_not_held"}
        });
    }
    info.client_id = client_id.to_string();
    info.status = SlotStatus::Connected;
}
```

---

### WR-08: `String::from_utf8_lossy` silently corrupts non-UTF-8 broker payloads

**File:** `server/src/ws_server.rs:330`
**Issue:** Outbound broker messages are converted to text via `from_utf8_lossy`, which
replaces invalid bytes with U+FFFD (`\u{fffd}`) instead of returning an error. All
current broker payloads are `serde_json::to_vec` output and valid UTF-8. However, if
any future code path pushes binary data to the broker, the JSON forwarded to the WS
client will be silently corrupted and unparseable, with no server-side log entry.

**Fix:**
```rust
match String::from_utf8(payload) {
    Ok(text) => {
        if write.send(Message::Text(text.into())).await.is_err() {
            tracing::warn!("WS send failed to {addr}, closing connection");
            break;
        }
    }
    Err(e) => {
        tracing::error!("WS broker payload is not valid UTF-8, dropping: {e}");
        continue;
    }
}
```

---

### WR-09: `nginx.conf` specifies no TLS protocols or ciphers — may serve TLS 1.0/1.1

**File:** `docker/nginx/nginx.conf:16-19`
**Issue:** The TLS block contains only `ssl_certificate` and `ssl_certificate_key`.
Older nginx builds default to `ssl_protocols TLSv1 TLSv1.1 TLSv1.2`. TLS 1.0 and
1.1 are deprecated (RFC 8996) and expose the handshake to known downgrade attacks.
The same config file is referenced by `make dev-certs` and may be carried into
production deployments.

**Fix:** Add explicit protocol and cipher restrictions:
```nginx
ssl_protocols       TLSv1.2 TLSv1.3;
ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers off;
```

---

### WR-10: Motion indicator ignores `linearAcceleration` despite comment saying to prefer it

**File:** `client/dist/phone.js:391-407`
**Issue:** The code comment says "Prefer linear_acceleration (gravity-subtracted);
fall back to accelerationIncludingGravity" but the implementation reads only
`e.accelerationIncludingGravity` unconditionally:

```js
var a = e.accelerationIncludingGravity;  // linearAcceleration never tried
```

The threshold `mag > 10.3` (= 9.8 rest + 0.5) is only correct when the phone is
flat. When held at any other angle, the gravity projection changes and the static
`mag` differs from 9.8, causing false positives or missed motion events.
`linearAcceleration` (gravity-subtracted) is available on most modern browsers and
would give a correct 0.5 m/s² threshold in all orientations.

**Fix:**
```js
var a = e.linearAcceleration || e.accelerationIncludingGravity;
if (!a) { return; }
var mag = Math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
var threshold = e.linearAcceleration ? 0.5 : 10.3;
if (mag > threshold) { ... }
```

---

### WR-11: `closePeer` triggers a spurious `channel-lost` via `pc.close()` → `dc.onclose`

**File:** `client/dist/phone.js:411-418`
**Issue:** `closePeer` calls `entry.pc.close()` which closes all data channels and
fires `dc.onclose`. That handler unconditionally calls
`sendPhoneState({ state: 'channel-lost', with: peerId })`. So when a `peer-left`
server push drives `closePeer`, the phone immediately sends back a `channel-lost`
for a peer that already left. The server relays this to remaining desktops as a
spurious state event, polluting their UI state.

**Fix:** Suppress the `dc.onclose` callback when the close is intentional:
```js
function openChannelToPeer(peerId) {
  // ...
  var intentionalClose = false;
  dc.onclose = function() {
    if (intentionalClose) { return; }
    if (openChannelCount > 0) { openChannelCount--; }
    updateConnectingUI();
    sendPhoneState({ state: 'channel-lost', with: peerId });
  };
  peerConnections.set(peerId, { pc: pc, dc: dc, flagClose: function() { intentionalClose = true; } });
}

function closePeer(peerId) {
  var entry = peerConnections.get(peerId);
  if (!entry) { return; }
  if (entry.flagClose) { entry.flagClose(); }
  try { entry.pc.close(); } catch (e) {}
  peerConnections.delete(peerId);
  if (openChannelCount > 0) { openChannelCount--; }
  updateConnectingUI();
}
```

---

## Info

### IN-01: `heartbeatInterval` is never cleared — recurring unhandled rejections if transport closes

**File:** `client/dist/phone.js:375-378`
**Issue:** `heartbeatInterval = setInterval(...)` is set in `startHeartbeat()` but
`clearInterval(heartbeatInterval)` is called nowhere in the file. If the transport
closes after pairing (server restart, network loss), the interval continues firing
every 5 s. Each tick's fire-and-forget `sendWtMessage(transport, ...)` on a closed
transport produces an unhandled rejection. Add `clearInterval` wherever the session
ends (transport close handler, error views).

---

### IN-02: `JoinAckPayload` struct is missing the `slots` field — wire format divergence

**File:** `server/src/signaling.rs:44-51`
**Issue:** `JoinAckPayload` documents the `join-ack` wire shape but is missing the
`slots` field that `handle_join` includes in its actual JSON output (the room roster).
The struct is `#[allow(dead_code)]` and unused for serialization, but developers
reading it will have an incorrect mental model. Add `pub slots: Vec<serde_json::Value>`
to keep the type accurate as living documentation.

---

### IN-03: `nginx.conf` has no `server_name` directive

**File:** `docker/nginx/nginx.conf:14`
**Issue:** Without `server_name`, nginx acts as the default catch-all server for all
incoming hostnames on the configured ports. In a multi-virtual-host environment, any
unmatched request would be served by this block. Add
`server_name localhost 127.0.0.1;` (and the production domain/IP) to restrict serving
to intended hostnames.

---

### IN-04: Server-opened WT push stream's `_recv` half is silently dropped

**File:** `server/src/wt_server.rs:320`
**Issue:** When the server pushes a message via `open_bi()`, the receive half of the
bidirectional stream is bound to `_recv` and immediately dropped:
```rust
Ok((mut send, _recv)) => {
```
If a misbehaving client sends data on this server-opened stream, QUIC flow-control
can fill the stream receive window and stall the task. Consider draining `_recv`
in a spawned task, or switching to `open_uni` (unidirectional) for server pushes
if the wtransport API supports it, since no response is expected from the client on
these streams.

---

_Reviewed: 2026-07-08_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
