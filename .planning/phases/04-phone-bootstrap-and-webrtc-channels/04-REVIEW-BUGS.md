# Phase 04 — Code Review Bug Fixes

8 bugs found during `/code-review` of PR #1. Fix all before merge.

---

## Bug 1+2: Phone gets desktop's reconnect_token (CRITICAL)

**Files:** `server/src/room_registry.rs`

**Root cause:** `handle_pair` reads the DESKTOP slot's existing `reconnect_token` and puts it in `pair-ack` (line ~688). `handle_reconnect` then overwrites `info.client_id` unconditionally for ALL reconnecting clients including desktops (line 495).

**Fix:**
1. Change `reconnect_tokens: DashMap<String, (RoomCode, usize)>` → `DashMap<String, (RoomCode, usize, bool)>` where `bool` = `is_phone`.
2. In `handle_pair`: generate a SEPARATE phone reconnect token, insert with `is_phone=true`. Send that token in `pair-ack`, not the desktop's token. Desktop slot keeps its own token (`is_phone=false`) untouched.
3. In `handle_reconnect`: if `is_phone=true` → only update `info.phone_client_id`, do NOT touch `info.client_id`. If `is_phone=false` → only update `info.client_id`, do NOT touch `info.phone_client_id`.

---

## Bug 3: route_to_phone only delivers to first phone (CRITICAL)

**File:** `server/src/room_registry.rs` line ~994

**Root cause:** Uses `find_map` — stops at first phone. Multi-phone rooms broken.

**Fix:** Replace `find_map` with `filter_map + collect` into a `Vec<String>`, then iterate and call `broker.route` for each phone_id.

```rust
fn route_to_phone(&self, room_code: &str, event_bytes: Vec<u8>, broker: &SignalingBroker) {
    let phone_ids: Vec<String> = self.rooms.get(room_code)
        .map(|room| room.slots.iter()
            .filter_map(|s| s.as_ref()?.phone_client_id.clone())
            .collect())
        .unwrap_or_default();
    for id in phone_ids {
        if !broker.route(&id, event_bytes.clone()) {
            tracing::warn!(phone_id = %id, "route_to_phone: phone not connected");
        }
    }
}
```

---

## Bug 4: ICE candidates arrive before setRemoteDescription in room.js (HIGH)

**File:** `client/dist/room.js` line ~256

**Root cause:** `desktopPeers.set(phoneId, pc)` called BEFORE `setRemoteDescription` resolves. ICE candidates that arrive during the async gap call `addIceCandidate` with no remote description → `InvalidStateError`, candidates lost. Also: second offer from same phone overwrites map entry without closing old PC → zombie PC sends stale ICE candidates.

**Fix:**
1. Add `var pendingICE = new Map();` at module level.
2. In `handleOffer`: close old PC if present; create new PC; set `pendingICE.set(phoneId, [])` BEFORE async chain; call `desktopPeers.set` INSIDE `.then()` AFTER `setRemoteDescription` resolves; drain `pendingICE` queue into `addIceCandidate`.
3. In `handleIceCandidate`: if `desktopPeers.get(phoneId)` exists, call `addIceCandidate` normally; else push to `pendingICE.get(phoneId)`.

---

## Bug 5: visibilitychange spawns concurrent reconnect loop (HIGH)

**File:** `client/dist/phone.js` line 796

**Fix:** One character change:
```javascript
// before:
if (reconnectToken && !ws) { attemptReconnect(); }
// after:
if (reconnectToken && !ws && !_reconnecting) { attemptReconnect(); }
```

---

## Bug 6: coturn allows TURN relay to 192.168.x.x (SECURITY)

**File:** `docker/coturn/turnserver.conf` line 36

**Fix:** Uncomment:
```
denied-peer-ip=192.168.0.0-192.168.255.255
```
WebRTC data channels go peer-to-peer on LAN; TURN is only for NAT traversal fallback.

---

## Bug 7: closePeer double-decrements openChannelCount (MEDIUM)

**File:** `client/dist/phone.js` line 786

**Root cause:** `channelIsOpen` is a closure-local variable inaccessible from `closePeer`. If `dc.onclose` fires first (decrement 1), then `peer-left` triggers `closePeer` (decrement 2), count goes wrong.

**Fix:** Move `channelIsOpen` into the `peerConnections` map entry as `channelOpen: false`. Update `dc.onopen`, `dc.onclose`, and `closePeer` to read/write `entry.channelOpen` instead of the closure var. `closePeer` only decrements if `entry.channelOpen === true`.

---

## Bug 8: startHeartbeat leaks timer on second call (MEDIUM)

**File:** `client/dist/phone.js` line 750

**Fix:** Add `clearInterval` as first line:
```javascript
function startHeartbeat() {
    clearInterval(heartbeatInterval);  // add this line
    heartbeatInterval = setInterval(function() {
        signalSend('heartbeat', '', {});
    }, 5000);
}
```

---

## Implementation order

1. Bug 5, 6, 8 — trivial one-liners, do first
2. Bug 3 — small Rust change, self-contained
3. Bug 7 — JS refactor of peerConnections entry shape
4. Bug 4 — JS ICE queuing in room.js
5. Bug 1+2 — Rust type change across reconnect_tokens, requires updating handle_pair + handle_reconnect + all match sites
