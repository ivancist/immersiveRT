# Phase 4: Phone Bootstrap and WebRTC Channels - Pattern Map

**Mapped:** 2026-07-08
**Files analyzed:** 7 new/modified files
**Analogs found:** 7 / 7

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `client/dist/phone.html` | component (HTML shell) | request-response | `client/dist/index.html` | exact |
| `client/dist/phone.js` | component (client state machine) | event-driven | `client/dist/room.js` | exact |
| `server/src/room_registry.rs` | service (extended) | CRUD + event-driven | self (existing file) | self-extension |
| `server/src/signaling.rs` | model (extended) | transform | self (existing file) | self-extension |
| `server/src/wt_server.rs` | middleware (extended) | request-response | self (existing file) | self-extension |
| `server/src/ws_server.rs` | middleware (extended) | request-response | `server/src/wt_server.rs` | exact |
| `docker/nginx/nginx.conf` | config (one-line change) | request-response | self (existing file) | self-extension |

---

## Pattern Assignments

### `client/dist/phone.html` (HTML shell)

**Analog:** `client/dist/index.html`

**Design tokens block to copy verbatim** (index.html lines 16–26):
```css
:root {
  --color-bg:               #111111;
  --color-surface:          #1e1e1e;
  --color-accent:           #7c6af7;
  --color-destructive:      #ef4444;
  --color-text-primary:     #f0f0f0;
  --color-text-secondary:   #888888;
  --color-status-connected: #22c55e;
  --color-status-hold:      #eab308;
  --color-status-empty:     #444444;
}
```

**Reusable CSS classes from index.html** (lines 46–198) — copy all of:
- `.btn`, `.btn:hover`, `.btn:disabled` (lines 72–97)
- `.spinner` + `@keyframes spin` (lines 161–172)
- `.error-msg`, `.error-msg--visible` (lines 131–137)
- `.card` (lines 63–67)
- `.text-secondary`, `.size-*` typography helpers (lines 48–57)
- `@keyframes dot-pulse` and `.status-dot` classes (lines 142–156) — reuse for motion indicator pulse

**phone.html view structure** — six `<div hidden>` sections (one per state):
```html
<div id="view-permission" hidden>...</div>   <!-- D-12: first and only element on load — NOT hidden -->
<div id="view-connecting" hidden>...</div>   <!-- D-10: spinner + X/Y channels -->
<div id="view-active" hidden>...</div>       <!-- D-11: name, room, motion indicator -->
<div id="view-ended" hidden>...</div>        <!-- session ended -->
<div id="view-error-denied" hidden>...</div> <!-- permission denied -->
<div id="view-error-pair" hidden>...</div>   <!-- pairing failed -->
```
Only `#view-permission` is visible on load (no `hidden` attribute).

**Script tag** — defer loading phone.js (no module; phone.js is a plain script like room.js):
```html
<script src="/phone.js" defer></script>
```

---

### `client/dist/phone.js` (client state machine, event-driven)

**Analog:** `client/dist/room.js`

**File header and `'use strict'` pattern** (room.js lines 1–6):
```javascript
/* phone.js — ImmersiveRT phone client: permission gate, WebTransport signaling,
 * WebRTC data channels, Wake Lock, heartbeat.
 * Plain script (no ES module imports); all browser built-in APIs only.
 */

'use strict';
```

**Module-level state block** (modeled on room.js lines 11–16):
```javascript
// ── State ────────────────────────────────────────────────────────────────────
let transport = null;      // WebTransport instance
let myId = null;           // client UUID (generated on load)
let roomCode = null;
let mySlot = null;
let myUsername = null;
let iceServers = [];
let peers = [];            // [{id, slot, username}] from pair-ack
let peerConnections = new Map(); // peerId → { pc, dc }
let openChannelCount = 0;
let wakeLockSentinel = null;
let heartbeatInterval = null;
```

**`showView()` helper** — copy pattern from room.js lines 21–28, adapted for phone views:
```javascript
function showView(id) {
  ['view-permission','view-connecting','view-active',
   'view-ended','view-error-denied','view-error-pair'].forEach(function(v) {
    var el = document.getElementById(v);
    if (el) { el.hidden = true; }
  });
  var target = document.getElementById(id);
  if (target) { target.hidden = false; }
}
```

**iOS permission gate** (D-12) — synchronous click handler (RESEARCH.md Pattern 1):
```javascript
// CRITICAL: DeviceMotionEvent.requestPermission() MUST be the first call
// inside the click handler — any async boundary before it breaks iOS gesture stack.
document.getElementById('btn-grant-motion').addEventListener('click', function() {
  if (typeof DeviceMotionEvent !== 'undefined' &&
      typeof DeviceMotionEvent.requestPermission === 'function') {
    DeviceMotionEvent.requestPermission()
      .then(function(result) {
        if (result === 'granted') {
          showView('view-connecting');
          startPhoneClient();
        } else {
          showView('view-error-denied');
        }
      })
      .catch(function() { showView('view-error-denied'); });
  } else {
    // Android: no permission gate needed
    showView('view-connecting');
    startPhoneClient();
  }
});
```

**WebTransport client init** (RESEARCH.md Pattern 2):
```javascript
async function startPhoneClient() {
  myId = crypto.randomUUID();
  const token = new URLSearchParams(location.search).get('token');
  if (!token) { showView('view-error-pair'); return; }

  const wtUrl = 'https://' + location.hostname + ':4433';
  transport = new WebTransport(wtUrl);
  await transport.ready;

  // MUST start listening for server pushes before sending anything (RESEARCH.md Pitfall 2)
  listenForServerPushes(transport);

  // Register
  await sendWtMessage(transport, { type: 'register', from: myId, to: '', payload: {} });

  // Pair
  const pairResp = await sendWtRequest(transport, {
    type: 'pair', from: myId, to: '', payload: { token }
  });
  if (pairResp.type !== 'pair-ack') { showView('view-error-pair'); return; }

  // ... store peers, iceServers, open RTCPeerConnections
}
```

**Send-and-read-response helper** (RESEARCH.md Pattern 2):
```javascript
// One-shot: open bidi stream, write message, read response, return parsed JSON.
async function sendWtRequest(transport, envelope) {
  const stream = await transport.createBidirectionalStream();
  const writer = stream.writable.getWriter();
  await writer.write(new TextEncoder().encode(JSON.stringify(envelope)));
  await writer.close();
  const reader = stream.readable.getReader();
  let buf = new Uint8Array(0);
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    const merged = new Uint8Array(buf.length + value.length);
    merged.set(buf); merged.set(value, buf.length);
    buf = merged;
  }
  return JSON.parse(new TextDecoder().decode(buf));
}

// Fire-and-forget (no response expected): heartbeat, phone-state, rtc-channel-ready
async function sendWtMessage(transport, envelope) {
  const stream = await transport.createBidirectionalStream();
  const writer = stream.writable.getWriter();
  await writer.write(new TextEncoder().encode(JSON.stringify(envelope)));
  await writer.close();
  // Drain the readable so back-pressure doesn't stall the connection
  const reader = stream.readable.getReader();
  while (true) { const { done } = await reader.read(); if (done) break; }
}
```

**Server push listener loop** (RESEARCH.md Pattern 2 — Pitfall 2 mitigation):
```javascript
// Must run as a non-blocking concurrent task (don't await at top level — use .then or spawn).
async function listenForServerPushes(transport) {
  for await (const stream of transport.incomingBidirectionalStreams) {
    const reader = stream.readable.getReader();
    let buf = new Uint8Array(0);
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      const merged = new Uint8Array(buf.length + value.length);
      merged.set(buf); merged.set(value, buf.length);
      buf = merged;
    }
    try {
      const msg = JSON.parse(new TextDecoder().decode(buf));
      handleServerPush(msg);
    } catch(e) { console.warn('[WT] Malformed server push', e); }
  }
}

function handleServerPush(msg) {
  switch (msg.type) {
    case 'peer-joined':  openChannelToPeer(msg.peer.id);  break;
    case 'peer-left':    closePeer(msg.peer_id);          break;
    case 'player-ready': onPlayerReady(msg);              break;
    default: console.warn('[WT] Unknown push type:', msg.type);
  }
}
```

**RTCPeerConnection open channel** (RESEARCH.md Pattern 3, D-05):
```javascript
// All channels: ordered:false, maxRetransmits:0 — locked decision
function openChannelToPeer(peerId) {
  const pc = new RTCPeerConnection({ iceServers });
  const dc = pc.createDataChannel('sensor', { ordered: false, maxRetransmits: 0 });

  pc.onnegotiationneeded = async () => {
    await pc.setLocalDescription(); // no args — auto creates offer
    await sendWtMessage(transport, {
      type: 'offer', from: myId, to: peerId, payload: pc.localDescription
    });
  };

  pc.onicecandidate = async ({ candidate }) => {
    if (!candidate) return;
    await sendWtMessage(transport, {
      type: 'ice-candidate', from: myId, to: peerId, payload: candidate
    });
  };

  dc.onopen = () => {
    openChannelCount++;
    updateConnectingUI();
    sendWtMessage(transport, {
      type: 'rtc-channel-ready', from: myId, to: '', payload: { with: peerId }
    });
  };

  dc.onclose = () => {
    sendPhoneState({ state: 'channel-lost', with: peerId });
  };

  peerConnections.set(peerId, { pc, dc });
}
```

**`handleServerPush` for offer/answer/ICE** — phone also receives answer and ICE from desktop via server push:
```javascript
// In handleServerPush, add cases:
case 'answer': {
  const { pc } = peerConnections.get(msg.from) || {};
  if (pc) await pc.setRemoteDescription(msg.payload);
  break;
}
case 'ice-candidate': {
  const { pc } = peerConnections.get(msg.from) || {};
  if (pc) await pc.addIceCandidate(msg.payload);
  break;
}
```

**Wake Lock** (RESEARCH.md Pattern 4, D-15/D-16):
```javascript
async function requestWakeLock() {
  if (!('wakeLock' in navigator)) return; // graceful degradation — older Safari
  try {
    wakeLockSentinel = await navigator.wakeLock.request('screen');
    wakeLockSentinel.addEventListener('release', () => {
      sendPhoneState({ state: 'wake-lock-lost' });
      wakeLockSentinel = null;
    });
    sendPhoneState({ state: 'wake-lock-active' });
  } catch (err) {
    // Low battery / power save / document not visible — silently degrade
    console.debug('[WakeLock] Request rejected:', err.message);
  }
}

document.addEventListener('visibilitychange', async () => {
  if (document.visibilityState === 'visible') {
    sendPhoneState({ state: 'foreground' });
    // Re-send heartbeat immediately on foreground return (D-19)
    sendWtMessage(transport, { type: 'heartbeat', from: myId, to: '', payload: {} });
    await requestWakeLock();
    // Re-initiate WebRTC for any closed channels (D-16)
    for (const [peerId, { dc }] of peerConnections) {
      if (dc.readyState === 'closed' || dc.readyState === 'closing') {
        peerConnections.delete(peerId);
        openChannelToPeer(peerId);
      }
    }
  } else {
    sendPhoneState({ state: 'background' });
  }
});
```

**Heartbeat** (D-19):
```javascript
function startHeartbeat() {
  heartbeatInterval = setInterval(function() {
    sendWtMessage(transport, { type: 'heartbeat', from: myId, to: '', payload: {} });
  }, 5000);
}
```

**`sendPhoneState` helper** (D-17):
```javascript
function sendPhoneState(statePayload) {
  sendWtMessage(transport, { type: 'phone-state', from: myId, to: '', payload: statePayload });
}
```

**`onPlayerReady`** (D-10/D-11/D-15):
```javascript
function onPlayerReady(msg) {
  showView('view-active');
  // Populate active view
  document.getElementById('active-username').textContent = myUsername;
  document.getElementById('active-room').textContent = roomCode;
  document.getElementById('active-channels').textContent = openChannelCount + '/' + peers.length + ' connected';
  // Wake Lock after player-ready (D-15)
  requestWakeLock();
  startHeartbeat();
  // Motion indicator for devicemotion (D-11 — lightweight, not full Madgwick)
  startMotionIndicator();
}

function startMotionIndicator() {
  // CSS pulse driven by devicemotion event magnitude threshold
  window.addEventListener('devicemotion', function(e) {
    const a = e.accelerationIncludingGravity;
    if (!a) return;
    const mag = Math.sqrt(a.x*a.x + a.y*a.y + a.z*a.z);
    const indicator = document.getElementById('motion-indicator');
    if (indicator) {
      indicator.classList.toggle('motion-active', mag > 12); // threshold above ~1G
    }
  });
}
```

---

### `server/src/room_registry.rs` (service, CRUD + event-driven — extended)

**Analog:** self (existing file)

**New fields to add to `SlotInfo`** (RESEARCH.md Pattern 5 — after existing `reconnect_token` field):
```rust
pub struct SlotInfo {
    pub client_id: String,
    pub username: String,
    pub status: SlotStatus,
    pub reconnect_token: String,
    // NEW in Phase 4:
    pub phone_client_id: Option<String>,          // set at pair time; enables server→phone routing
    pub last_heartbeat: Option<std::time::Instant>, // updated on each heartbeat message
}
```

**New field to add to `RoomRegistry`** (RESEARCH.md Pattern 6 — after `pairing_ttl_secs`):
```rust
/// Tracks both-sided WebRTC channel readiness.
/// Key: (room_code, phone_client_id, desktop_client_id)
/// Value: (phone_confirmed, desktop_confirmed)
channel_ready: Arc<DashMap<(RoomCode, String, String), (bool, bool)>>,
```
Initialize in `RoomRegistry::new()`: `channel_ready: Arc::new(DashMap::new()),`

**Extended `handle_pair` signature** (RESEARCH.md Pattern 8 — currently line 478):
```rust
pub async fn handle_pair(
    &self,
    phone_client_id: &str,    // NEW: envelope.from from wt_server/ws_server
    raw_payload: &serde_json::Value,
    broker: &SignalingBroker,
) -> serde_json::Value {
```
Inside the function, after finding `desktop_client_id`:
1. Store `phone_client_id` in `SlotInfo.phone_client_id` (get_mut the room, find slot, set field, drop ref).
2. Collect all Connected desktop slots for `peers[]`.
3. Call `generate_turn_credentials` (from `turn_creds.rs`) to produce `ice_servers`.
4. Return extended `pair-ack` payload with `peers`, `ice_servers`, `slot`, `room_code`, `reconnect_token`, `pairing_url`.

**`handle_rtc_channel_ready`** — new method (collect-then-drop pattern from lines 109–141):
```rust
pub async fn handle_rtc_channel_ready(
    &self,
    sender_id: &str,
    payload: &serde_json::Value,
    broker: &SignalingBroker,
) {
    // 1. Determine if sender is phone or desktop; get the partner's id from payload["with"]
    // 2. Look up channel_ready entry; update appropriate bool
    // 3. Check if (true, true) — collect needed state, DROP DashMap ref
    // 4. If both confirmed: check if all channels for this player are confirmed
    // 5. If all confirmed: broadcast player-ready to room (broadcast_to_room + route to phone)
}
```
**Pattern: collect-then-drop** (lines 117–141 — never call broker.route() while holding DashMap ref):
```rust
let targets: Vec<String> = if let Some(room) = self.rooms.get(room_code) {
    room.slots.iter().filter_map(|s| { ... Some(info.client_id.clone()) }).collect()
} else { vec![] };
// DashMap Ref dropped here
for id in targets {
    if !broker.route(&id, event_bytes.clone()) {
        tracing::warn!(to = %id, "room broadcast: target not connected");
    }
}
```

**`handle_heartbeat`** — new method (RESEARCH.md Pattern 7):
```rust
pub fn handle_heartbeat(&self, phone_client_id: &str) {
    for mut room_ref in self.rooms.iter_mut() {
        for slot in room_ref.slots.iter_mut().flatten() {
            if slot.phone_client_id.as_deref() == Some(phone_client_id) {
                slot.last_heartbeat = Some(std::time::Instant::now());
                return;
            }
        }
    }
    tracing::warn!(phone_client_id = %phone_client_id, "heartbeat: phone not found in any slot");
}
```

**`route_to_phone`** — new helper (mirrors `broadcast_to_room`):
```rust
fn route_to_phone(&self, room_code: &str, event_bytes: Vec<u8>, broker: &SignalingBroker) {
    // Collect phone_client_id while holding DashMap ref, then drop ref before calling broker
    let phone_id: Option<String> = self.rooms.get(room_code).and_then(|room| {
        room.slots.iter().find_map(|s| {
            s.as_ref().and_then(|info| info.phone_client_id.clone())
        })
    });
    // DashMap Ref dropped here
    if let Some(id) = phone_id {
        if !broker.route(&id, event_bytes) {
            tracing::warn!(phone_id = %id, "route_to_phone: phone not connected");
        }
    }
}
```

**`handle_peer_joined` / `handle_peer_left`** — push events to phone on desktop join/leave:
```rust
// In on_client_disconnect and handle_join: after broadcasting to room desktops,
// also push peer-joined or peer-left to the phone via route_to_phone.
// peer-joined when a new desktop joins; peer-left when desktop disconnects/leaves.
let peer_event = serde_json::to_vec(&serde_json::json!({
    "type": "peer-joined",   // or "peer-left"
    "peer": { "id": client_id, "slot": slot_id, "username": username }
})).unwrap_or_default();
self.route_to_phone(&room_code, peer_event, broker);
```

**Test pattern** (lines 730–738 — make_registry helper + #[tokio::test]):
```rust
fn make_registry() -> RoomRegistry {
    RoomRegistry::new(
        "test-pairing-secret".to_string(),
        "https://localhost:8443".to_string(),
        60,  // hold_ttl_secs
        300, // pairing_ttl_secs
    )
}

#[tokio::test]
async fn test_pair_ack_includes_peers() {
    // Setup: join a desktop, call handle_pair with a phone_client_id
    // Assert: pair-ack payload["peers"] is non-empty array with id/slot/username
}
```

---

### `server/src/signaling.rs` (model — extended)

**Analog:** self (existing file)

**Existing `PairAckPayload`** (lines 80–84) — replace with enhanced version:
```rust
// REPLACE existing PairAckPayload with:
#[derive(Debug, Serialize, Deserialize)]
pub struct PeerInfo {
    pub id: String,
    pub slot: u8,
    pub username: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct PairAckPayload {
    pub desktop_id: String,   // existing
    pub slot: u8,             // NEW
    pub room_code: String,    // NEW
    pub reconnect_token: String, // NEW
    pub pairing_url: String,  // NEW
    pub peers: Vec<PeerInfo>, // NEW — all Connected desktops in room
    pub ice_servers: serde_json::Value, // NEW — [{urls, username, credential}]
}
```

**New typed payload structs to add** (follow existing struct pattern with `#[derive(Debug, Serialize, Deserialize)]`):
```rust
#[derive(Debug, Serialize, Deserialize)]
pub struct RtcChannelReadyPayload {
    pub with: String,  // the peer's client_id
}

#[derive(Debug, Serialize, Deserialize)]
pub struct PhoneStatePayload {
    pub state: String,              // background | foreground | wake-lock-lost | wake-lock-active | channel-lost | channel-recovered
    pub with: Option<String>,       // present for channel-lost / channel-recovered
}

#[derive(Debug, Serialize, Deserialize)]
pub struct PlayerReadyPayload {
    pub player_id: String,
    pub slot: u8,
    pub username: String,
}
```

---

### `server/src/wt_server.rs` (middleware — extended)

**Analog:** self (existing file)

**New match arms** — add to the `match envelope.msg_type.as_str()` block (lines 214–265), following the same pattern as existing arms:
```rust
"pair" => {
    // CHANGE: pass envelope.from as first arg (phone_client_id)
    let ack = room_registry
        .handle_pair(&envelope.from, &envelope.payload, &broker)
        .await;
    let ack_bytes = serde_json::to_vec(&ack).unwrap_or_default();
    let _ = send.write_all(&ack_bytes).await;
    let _ = send.finish().await;
}
"rtc-channel-ready" => {
    room_registry
        .handle_rtc_channel_ready(&envelope.from, &envelope.payload, &broker)
        .await;
    let _ = send.finish().await;
}
"heartbeat" => {
    room_registry.handle_heartbeat(&envelope.from);
    let _ = send.finish().await;
}
"phone-state" => {
    // Server relays phone-state to all room desktops (D-18)
    room_registry
        .handle_phone_state(&envelope.from, &envelope.payload, &broker)
        .await;
    let _ = send.finish().await;
}
```

---

### `server/src/ws_server.rs` (middleware — extended)

**Analog:** `server/src/wt_server.rs`

Apply the exact same four new match arms (`pair` signature change, `rtc-channel-ready`, `heartbeat`, `phone-state`) in ws_server.rs. The dispatch structure is identical — find the existing `match msg_type` block and add arms in the same order.

---

### `docker/nginx/nginx.conf` (config — one-line change)

**Analog:** self (existing file)

**Change** (line 27):
```nginx
# BEFORE:
try_files $uri /index.html;

# AFTER:
try_files $uri $uri.html /index.html;
```
This allows `/phone` (no extension) to serve `phone.html`. Without `$uri.html`, nginx falls back to `index.html` and the phone sees the desktop SPA. (RESEARCH.md Pitfall 6)

---

## Shared Patterns

### Collect-then-drop DashMap pattern
**Source:** `server/src/room_registry.rs` lines 109–141 (`broadcast_to_room`)
**Apply to:** All new server methods that read room state and then call `broker.route()`
```rust
let targets: Vec<String> = if let Some(room) = self.rooms.get(room_code) {
    room.slots.iter().filter_map(|s| { ... Some(info.client_id.clone()) }).collect()
} else { vec![] };
// DashMap Ref is dropped here; safe to call broker now.
for id in targets { broker.route(&id, event_bytes.clone()); }
```

### `tracing` logging convention
**Source:** `server/src/room_registry.rs` lines 137, 564, 614, 671
**Apply to:** All new server methods
```rust
tracing::info!(room_code = %room_code, slot_id = %slot_id, "description");
tracing::warn!(to = %id, "room broadcast: target not connected");
tracing::error!("failed to generate pairing token: {e}");
```

### Input validation / defensive payload extraction
**Source:** `server/src/room_registry.rs` lines 159–172
**Apply to:** All new message type handlers
```rust
let field = match raw_payload["field"].as_str() {
    Some(v) => v.to_string(),
    None => return serde_json::json!({ "type": "error-type", "payload": {"reason": "invalid_payload"} }),
};
```

### JSON envelope wire format
**Source:** `server/src/signaling.rs` lines 7–20
**Apply to:** All new server-push messages — always use `{type, from, to, payload}` structure
```rust
serde_json::json!({
    "type": "player-ready",
    "payload": { "player_id": ..., "slot": ..., "username": ... }
})
```

### `from`-field spoofing guard
**Source:** `server/src/wt_server.rs` lines 200–208
**Apply to:** All new wt_server/ws_server message handlers — already handled by the existing check before the match block; no new code needed per handler

### `showView()` UI helper
**Source:** `client/dist/room.js` lines 21–28
**Apply to:** phone.js — adapt with phone-specific view IDs

### `sendMessage()` envelope pattern
**Source:** `client/dist/room.js` lines 144–151
**Apply to:** phone.js `sendWtMessage()` — same envelope `{type, from, to, payload}` structure

---

## No Analog Found

None — all files have direct analogs in the codebase.

---

## Metadata

**Analog search scope:** `server/src/`, `client/dist/`, `docker/nginx/`
**Files read:** 7 (room_registry.rs, signaling.rs, wt_server.rs, index.html, room.js, nginx.conf, CONTEXT.md/RESEARCH.md)
**Pattern extraction date:** 2026-07-08
