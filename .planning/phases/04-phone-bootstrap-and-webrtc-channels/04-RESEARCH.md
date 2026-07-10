# Phase 4: Phone Bootstrap and WebRTC Channels - Research

**Researched:** 2026-07-08
**Domain:** Browser WebRTC (RTCPeerConnection, data channels), WebTransport client-side JS, DeviceMotionEvent, Screen Wake Lock, Rust DashMap concurrency
**Confidence:** MEDIUM

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** Phone uses WebTransport (not WebSocket) for all signaling — pair flow, ICE exchange, state notifications, heartbeats. WS fallback exists but phone-primary path is WT.
- **D-02:** Room membership = authorization. No per-pair pre-grant. Server validates HMAC pairing token at pair time; any phone in the room is authorized to open WebRTC to any desktop.
- **D-03:** Desktop verifies offer legitimacy via server attestation in routing envelope: `{from: phone_id, room: ABCD}`. No per-offer crypto.
- **D-04:** Server includes room roster in `pair-ack` payload: `{slot, room_code, reconnect_token, pairing_url, peers: [{id, slot, username}]}`.
- **D-05:** Phone is the offer initiator. After `pair-ack`, phone creates one RTCPeerConnection + offer per desktop. All channels: `{ ordered: false, maxRetransmits: 0 }`.
- **D-06:** New desktop joins while phone connected: server pushes `{type: 'peer-joined', peer: {id, slot, username}}` to phone. Phone opens new RTCPeerConnection + offer.
- **D-07:** Desktop leaves: server pushes `{type: 'peer-left', peer_id}` to phone. Phone closes corresponding RTCPeerConnection.
- **D-08:** Both sides report channel-open to server. Phone sends `{type: 'rtc-channel-ready', with: desktop_id}`; desktop sends `{type: 'rtc-channel-ready', with: phone_id}`. Server requires both confirmations.
- **D-09:** `player-ready` fires when ALL channels for a player are both-sides confirmed. Server broadcasts `{type: 'player-ready', player_id, slot, username}` to all room members.
- **D-10:** Between pair-ack and player-ready: phone shows "Connecting... X/Y channels" spinner.
- **D-11:** After player-ready: phone shows player name, room code, channel count, motion indicator.
- **D-12:** "Grant Motion Access" button is first and only element on load. `DeviceMotionEvent.requestPermission()` called inside synchronous click handler. Android: feature-detect before calling.
- **D-13:** Phone client is `phone.html` + `phone.js` in static dir. Separate from `index.html`.
- **D-14:** QR URL encodes `/phone?token=...` directly (from Phase 3 D-13).
- **D-15:** Wake Lock requested AFTER `player-ready` fires, not during connecting phase.
- **D-16:** On `visibilitychange` → visible: phone re-requests Wake Lock, sends `phone-state: foreground`, checks all `RTCDataChannel.readyState` — re-initiates offer for any closed channel.
- **D-17:** Phone sends state change messages for all transitions (background, foreground, wake-lock-lost, wake-lock-active, channel-lost, channel-recovered). Server broadcasts heartbeat-miss — no phone action needed for that one.
- **D-18:** Server relays all `phone-state` events to all room desktops.
- **D-19:** Heartbeat `{type: 'heartbeat'}` every 5 seconds via WT. Server marks slot `disconnected` after ~65s of silence. Foreground return: send heartbeat immediately.

### Claude's Discretion

- Exact `phone-state` event naming on the wire (consistent with Phase 2/3 JSON envelope pattern).
- How server tracks "all channels confirmed" state — data structure per room/player.
- WakeLock feature detection (Safari partial support on older iOS — graceful degradation).
- Motion indicator animation implementation (CSS pulse driven by devicemotion event magnitude threshold).

### Deferred Ideas (OUT OF SCOPE)

- Full sensor display on phone (orientation indicator, position values) — Phase 5.
- Phone reconnect UI / reconnect flow — Phase 5.
- WakeLock on older Safari detailed cross-browser polyfill — out of Phase 4 scope.
- Touch input capture (tap, on-screen buttons) — Phase 5 (SENS-06).
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| PHONE-01 | Phone web app accessible via QR scan with no app install required | Separate phone.html served at /phone via nginx try_files $uri.html change; QR URL already encodes /phone?token=... from Phase 3 |
| PHONE-02 | Phone shows "Grant Motion Access" button as first interaction on iOS 13+ (required user gesture before DeviceMotionEvent permission prompt) | DeviceMotionEvent.requestPermission() must be called synchronously in click handler; feature detection pattern confirmed via MDN |
| PHONE-03 | Phone establishes WebRTC P2P unreliable data channels to ALL desktops in the room | RTCPeerConnection with ordered:false, maxRetransmits:0; phone is offerer; trickle ICE via WT signaling; D-05 pattern |
| PHONE-06 | Phone sends heartbeat every 5 seconds to prevent slot eviction | setInterval(heartbeat, 5000) in phone.js; server tracks last_heartbeat per slot; background task detects miss |
| PHONE-07 | Phone activates Wake Lock API to prevent screen lock | navigator.wakeLock.request('screen') after player-ready; visibilitychange reacquisition pattern; feature detection via 'wakeLock' in navigator |
</phase_requirements>

---

## Summary

Phase 4 connects three previously-isolated subsystems: the phone browser's sensor permissions + Wake Lock (platform APIs), WebRTC peer-to-peer data channels (browser-negotiated), and the existing Rust WebTransport signaling server. The phone is a new web client (`phone.html` + `phone.js`) served at `/phone?token=...` via a one-line nginx change. It is a complete, self-contained state machine with six views (permission gate, connecting, active, session ended, error-permission-denied, error-pairing-failed), all implemented in vanilla JS/CSS inheriting design tokens from `index.html`.

The critical sequencing constraint is the iOS permission gate: `DeviceMotionEvent.requestPermission()` MUST execute in a synchronous `onclick` handler — not inside a Promise `.then()`, not in a `setTimeout(0)`, not after any `await`. This is enforced by iOS Safari's user-gesture stack. Any deviation silently fails on iOS with no error thrown.

The server requires the most code in this phase. `handle_pair` must be extended to return the full room roster (`peers[]`) and TURN credentials, and SlotInfo must gain a `phone_client_id: Option<String>` field populated at pair time to enable server-to-phone routing. Two new DashMap entries are needed: channel-readiness tracking (both-sided confirmation per phone-desktop pair) and heartbeat timestamps per slot. The existing `broadcast_to_room` pattern (collect-then-drop DashMap ref before calling broker) governs all new server code.

**Primary recommendation:** Build the server extensions first (pair-ack enhancement, phone_client_id tracking, rtc-channel-ready handler, heartbeat handler), then phone.js client, then the desktop WebRTC answer acceptance additions in room.js, then the nginx one-line change.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| iOS DeviceMotion permission gate | Browser / Client (Phone) | — | Platform API; must be called in synchronous user gesture; no server involvement |
| WebRTC P2P data channel establishment | Browser / Client (Phone + Desktop) | — | Browser WebRTC stack handles all ICE gathering, DTLS, SCTP |
| WebRTC signaling relay (offer/answer/ICE) | API / Backend (Rust) | — | Server routes envelopes; D-03 server attestation pattern |
| Channel readiness tracking (both-sides) | API / Backend (Rust) | — | Two-sided confirmation requires neutral third party (server) to count both |
| pair-ack room roster generation | API / Backend (Rust) | — | Server has full room state; D-04 |
| peer-joined / peer-left push to phone | API / Backend (Rust) | — | Server knows room membership changes; D-06/D-07 |
| player-ready gate and broadcast | API / Backend (Rust) | — | Reliable signal requires server to confirm all channels; D-09 |
| Heartbeat tracking + miss detection | API / Backend (Rust) | — | Server-side timer logic; client just sends; server broadcasts miss |
| phone-state relay to desktops | API / Backend (Rust) | — | D-18: server relays to all room desktops |
| Wake Lock lifecycle | Browser / Client (Phone) | — | navigator.wakeLock is a client browser API |
| Motion indicator | Browser / Client (Phone) | — | devicemotion event + CSS animation; D-11 |
| phone.html static serving | CDN / Static (nginx) | — | One-line try_files change; no new container |
| TURN credential generation at pair | API / Backend (Rust) | — | Phone needs ICE servers at pair time; generate_turn_credentials already exists |

---

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Browser RTCPeerConnection | Built-in | WebRTC data channel establishment | Native browser API; no library needed for data-only WebRTC |
| Browser WebTransport | Built-in | Phone→server signaling transport | D-01 locked decision; existing server on port 4433 |
| Browser DeviceMotionEvent | Built-in | Motion sensor data + iOS permission gate | Platform API; D-12 |
| Browser Screen Wake Lock | Built-in | navigator.wakeLock.request('screen') | D-07/D-15; Baseline 2025 |
| Rust tokio (existing) | 1.x | Async runtime for new server handlers | Already in Cargo.toml; no change |
| Rust dashmap (existing) | latest | Channel-readiness and heartbeat tracking maps | Same Arc<DashMap> pattern as broker and room_registry |
| Rust serde_json (existing) | 1.x | New message type serialization | Already used for all signaling envelopes |

### No New npm or Cargo Dependencies

Phase 4 introduces no new external packages. All capabilities are served by:
- Browser built-in APIs (RTCPeerConnection, WebTransport, DeviceMotionEvent, Screen Wake Lock)
- Existing Rust crates (tokio, dashmap, serde_json, hmac, tracing, anyhow)
- Vanilla JS/CSS (phone.html has zero npm dependencies)

**Installation:** None required.

---

## Package Legitimacy Audit

No new packages are introduced in Phase 4. All Rust crates and browser APIs are already present in the project.

| Package | Registry | Verdict | Disposition |
|---------|----------|---------|-------------|
| (none) | — | — | No new packages |

**Packages removed due to SLOP verdict:** none
**Packages flagged as suspicious:** none

---

## Architecture Patterns

### System Architecture Diagram

```
Phone Browser                       Rust Server (port 4433 WT)        Desktop Browser (room.js)
─────────────────────────────────   ────────────────────────────────   ──────────────────────────

[View 1: Permission Gate]
  onclick → requestPermission()
  → granted
       │
       ▼
[View 2: Connecting]
  new WebTransport(wt_url)──────────register {from: phone_id}
  ← WT push: pair-ack ─────────────handle_pair():
  {peers[], ice_servers, slot,        validate HMAC token
   room_code, reconnect_token}        read room roster (peers[])
                                      record phone_client_id in SlotInfo
       │                              generate TURN creds
       │                              return pair-ack payload
       ▼
  for each peer in peers[]:
    new RTCPeerConnection(iceServers)
    createDataChannel({ordered:false,
                       maxRetransmits:0})
    onnegotiationneeded:
      setLocalDescription()
      send offer ──────────────────→ route offer to desktop ─────────→ setRemoteDescription
                                                                         setLocalDescription
      ← receive answer ────────────← route answer to phone ──────────── send answer
    setRemoteDescription(answer)
    onicecandidate:
      send ice-candidate ──────────→ route ICE to desktop ──────────→ addIceCandidate
      ← receive ICE ───────────────← route ICE to phone ─────────────── onicecandidate → server
    dc.onopen:
      counter X++
      update "X/Y channels" UI
      send rtc-channel-ready ──────→ handle_rtc_channel_ready():      dc.onopen:
      (with: desktop_id)              update ChannelReadyMap             send rtc-channel-ready
                                      when both_sides_confirmed:        (with: phone_id)
                                      if all_desktops_confirmed:
                                        broadcast player-ready ─────────────────────────────┐
       ────────────────────────────── ← broadcast player-ready ─────────────────────────────┘
       │
       ▼
[View 3: Active]
  wakeLock = await navigator.wakeLock.request('screen')
  setInterval(heartbeat, 5000) ───→ handle_heartbeat():
                                      update slot.last_heartbeat
  visibilitychange → hidden:          background task:
    send phone-state: background ───→   if missed: broadcast ──────→ phone-state: heartbeat-miss
  visibilitychange → visible:
    re-request Wake Lock
    send phone-state: foreground ───→ relay to room desktops ──────→ phone-state event
    check dc.readyState each peer
      if closed: re-initiate offer
  dc closed:
    send phone-state: channel-lost ─→ relay to room desktops ──────→ channel-lost event
```

### Recommended Project Structure (New Files)

```
client/dist/
├── index.html          # Existing desktop SPA (unchanged)
├── room.js             # Existing desktop client (WebRTC answer additions)
├── phone.html          # NEW — phone client HTML (inherits :root tokens from index.html)
└── phone.js            # NEW — phone client JS (~400 lines)

docker/nginx/
└── nginx.conf          # ONE LINE CHANGE: try_files $uri $uri.html /index.html

server/src/
├── room_registry.rs    # EXTENDED: SlotInfo.phone_client_id, handle_pair peers[],
│                       #   ChannelReadyMap, handle_rtc_channel_ready, handle_heartbeat,
│                       #   peer-joined/peer-left push, route_to_phone
├── signaling.rs        # EXTENDED: PairAckPayload with peers[], new typed payload structs
├── wt_server.rs        # EXTENDED: new match arms for rtc-channel-ready, phone-state, heartbeat
└── ws_server.rs        # EXTENDED: same new match arms (parity with wt_server)
```

### Pattern 1: iOS Permission Gate (Synchronous Onclick)

**What:** DeviceMotionEvent.requestPermission() must be called in a synchronous click handler.
**When to use:** View 1 "Grant Motion Access" button handler in phone.js.
**Critical constraint:** No async/await, no Promise chain, no setTimeout before the call.

```javascript
// Source: MDN DeviceMotionEvent — https://developer.mozilla.org/en-US/docs/Web/API/DeviceMotionEvent
// VERIFIED pattern: synchronous call inside click handler (iOS user-gesture requirement)

grantBtn.addEventListener('click', function() {
  // Feature detect — Android has no requestPermission
  if (typeof DeviceMotionEvent !== 'undefined' &&
      typeof DeviceMotionEvent.requestPermission === 'function') {
    // iOS 13+: MUST be called here, synchronously in the click handler.
    // Any async boundary (await, .then, setTimeout) breaks the gesture stack.
    DeviceMotionEvent.requestPermission()
      .then(function(result) {
        if (result === 'granted') {
          showView('connecting');
          startPhoneClient();
        } else {
          showView('error-permission-denied');
        }
      })
      .catch(function() {
        showView('error-permission-denied');
      });
  } else {
    // Android: no permission needed — proceed immediately
    showView('connecting');
    startPhoneClient();
  }
});
```

### Pattern 2: WebTransport Client-Side Signaling (Phone → Server)

**What:** Phone opens one WT bidirectional stream per outgoing signaling message.
**When to use:** pair, offer, answer, ice-candidate, rtc-channel-ready, heartbeat, phone-state.

```javascript
// Source: MDN WebTransport API — https://developer.mozilla.org/en-US/docs/Web/API/WebTransport_API
// [CITED: developer.mozilla.org/en-US/docs/Web/API/WebTransport]

async function sendSignalingMessage(transport, envelope) {
  const stream = await transport.createBidirectionalStream();
  const writer = stream.writable.getWriter();
  const bytes = new TextEncoder().encode(JSON.stringify(envelope));
  await writer.write(bytes);
  await writer.close();
  // Read server response if expected (e.g., pair-ack)
  return stream.readable; // caller reads if needed
}

// Consuming server pushes (REQUIRED — must not skip or server back-pressure kills connection)
async function listenForServerPushes(transport) {
  for await (const stream of transport.incomingBidirectionalStreams) {
    const reader = stream.readable.getReader();
    let buf = new Uint8Array(0);
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      buf = concat(buf, value); // concatenate chunks until FIN
    }
    const msg = JSON.parse(new TextDecoder().decode(buf));
    handleServerPush(msg); // dispatch to peer-joined, peer-left, player-ready, etc.
  }
}
```

### Pattern 3: RTCPeerConnection — Phone Offers, Desktop Answers

**What:** Phone creates DataChannel (triggers onnegotiationneeded), sends offer via WT, handles trickle ICE.
**When to use:** After receiving pair-ack, for each peer in peers[].

```javascript
// Source: MDN RTCPeerConnection — https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/createDataChannel
// Source: MDN Perfect Negotiation — https://developer.mozilla.org/en-US/docs/Web/API/WebRTC_API/Perfect_negotiation
// [CITED: developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/createDataChannel]

function openChannelToPeer(transport, peerId, iceServers) {
  const pc = new RTCPeerConnection({ iceServers });

  // Unreliable, unordered — locked decision STATE.md / CONTEXT.md D-05
  const dc = pc.createDataChannel('sensor', { ordered: false, maxRetransmits: 0 });

  // createDataChannel triggers onnegotiationneeded
  pc.onnegotiationneeded = async () => {
    // setLocalDescription() with no args auto-creates the offer
    await pc.setLocalDescription();
    await sendSignalingMessage(transport, {
      type: 'offer',
      from: myPhoneId,
      to: peerId,
      payload: pc.localDescription,
    });
  };

  // Trickle ICE — send each candidate as it arrives
  pc.onicecandidate = async ({ candidate }) => {
    if (!candidate) return; // null = end-of-candidates
    await sendSignalingMessage(transport, {
      type: 'ice-candidate',
      from: myPhoneId,
      to: peerId,
      payload: candidate,
    });
  };

  dc.onopen = () => {
    // Notify server — D-08
    sendSignalingMessage(transport, {
      type: 'rtc-channel-ready',
      from: myPhoneId,
      to: '', // server handles; no specific target client
      payload: { with: peerId },
    });
    openChannelCount++;
    updateConnectingUI(openChannelCount, totalPeers);
  };

  dc.onclose = () => {
    sendPhoneState(transport, { state: 'channel-lost', with: peerId });
  };

  return { pc, dc };
}

// Desktop side — in room.js (additions for Phase 4):
pc.ondatachannel = (event) => {
  const dc = event.channel;
  dc.onopen = () => {
    // D-08: desktop also reports channel-open to server
    sendSignalingMessage(transport, {
      type: 'rtc-channel-ready',
      from: myDesktopId,
      to: '',
      payload: { with: phoneId },
    });
  };
};
```

### Pattern 4: Screen Wake Lock with Visibilitychange Reacquisition

**What:** Request Wake Lock after player-ready; re-request on foreground return.
**When to use:** After receiving player-ready event (D-15, D-16).

```javascript
// Source: MDN Screen Wake Lock API — https://developer.mozilla.org/en-US/docs/Web/API/Screen_Wake_Lock_API
// [CITED: developer.mozilla.org/en-US/docs/Web/API/Screen_Wake_Lock_API]

let wakeLockSentinel = null;

async function requestWakeLock() {
  if (!('wakeLock' in navigator)) return; // graceful degradation — older Safari, etc.
  try {
    wakeLockSentinel = await navigator.wakeLock.request('screen');
    wakeLockSentinel.addEventListener('release', () => {
      // Browser released it (e.g., backgrounded, low battery)
      sendPhoneState(transport, { state: 'wake-lock-lost' });
      wakeLockSentinel = null;
    });
    sendPhoneState(transport, { state: 'wake-lock-active' });
  } catch (err) {
    // Rejected on low battery, power save, document not visible
    // Silently degrade — do not show error (player already sees active screen)
  }
}

// Called once after player-ready (D-15)
// Also called on foreground return (D-16)
document.addEventListener('visibilitychange', async () => {
  if (document.visibilityState === 'visible') {
    sendPhoneState(transport, { state: 'foreground' });
    await requestWakeLock(); // re-acquire (new sentinel each time)
    // Re-check channel states per D-16
    for (const [peerId, { pc, dc }] of peerConnections) {
      if (dc.readyState === 'closed' || dc.readyState === 'closing') {
        openChannelToPeer(transport, peerId, iceServers);
      }
    }
  } else {
    sendPhoneState(transport, { state: 'background' });
  }
});
```

### Pattern 5: Server — Phone ID Tracking in SlotInfo

**What:** SlotInfo needs phone_client_id to enable server-to-phone routing after pairing.
**When to use:** handle_pair must record the phone's client_id from envelope.from.

```rust
// New field in SlotInfo (room_registry.rs)
pub struct SlotInfo {
    pub client_id: String,          // desktop client_id (existing)
    pub username: String,           // existing
    pub status: SlotStatus,         // existing
    pub reconnect_token: String,    // existing
    pub phone_client_id: Option<String>,  // NEW: populated at pair time
    pub last_heartbeat: Option<std::time::Instant>, // NEW: updated on each heartbeat
}
```

The pair handler (`handle_pair`) currently takes `raw_payload` and `_broker`. Phase 4 must add a `phone_client_id: &str` parameter (the `envelope.from` from the WT/WS handler) so it can store the phone's ID in SlotInfo.

### Pattern 6: Server — Channel Readiness Tracking

**What:** Track both-sided confirmations without holding DashMap ref across broker calls.
**When to use:** handle_rtc_channel_ready in room_registry.rs.

```rust
// Suggested structure (Claude's Discretion — data structure choice)
// Key: (room_code, phone_client_id, desktop_client_id)
// Value: (phone_confirmed, desktop_confirmed)
type ChannelReadyKey = (String, String, String);
channel_ready: Arc<DashMap<ChannelReadyKey, (bool, bool)>>,

// In handle_rtc_channel_ready:
// 1. Determine if sender is phone or desktop
// 2. Update the appropriate bool in the (bool, bool) pair
// 3. Check if (true, true) — if so, decrement pending count for this player
// 4. Collect all data needed to check player-ready, then DROP the DashMap ref
// 5. If all channels confirmed: broadcast player-ready via broker
```

### Pattern 7: Heartbeat Tracking

**What:** Update last_heartbeat on each heartbeat message; background tokio task detects stale.
**When to use:** handle_heartbeat in room_registry.rs; background task in main.rs or spawn at start.

```rust
// In handle_heartbeat (room_registry.rs):
pub async fn handle_heartbeat(&self, phone_client_id: &str) {
    // Find slot by phone_client_id, update last_heartbeat
    // Pattern: collect data out of DashMap ref, then drop ref (Pitfall 1)
    for mut room_ref in self.rooms.iter_mut() {
        for slot in room_ref.slots.iter_mut().flatten() {
            if slot.phone_client_id.as_deref() == Some(phone_client_id) {
                slot.last_heartbeat = Some(std::time::Instant::now());
                return;
            }
        }
    }
}

// Background heartbeat monitor (tokio::spawn in main.rs):
// Every 10s: iterate rooms, check slots with phone_client_id and last_heartbeat
// If now() - last_heartbeat > 65s: broadcast phone-state: heartbeat-miss to desktops
```

### Pattern 8: pair-ack Enhancement (peers[] + TURN creds)

**What:** handle_pair now returns full room roster and TURN credentials.
**When to use:** room_registry.rs::handle_pair.

```rust
// Enhanced pair-ack payload (signaling.rs additions)
#[derive(Debug, Serialize, Deserialize)]
pub struct PeerInfo {
    pub id: String,
    pub slot: u8,
    pub username: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct PairAckPayload {
    pub desktop_id: String,
    pub slot: u8,
    pub room_code: String,
    pub reconnect_token: String,
    pub pairing_url: String,
    pub peers: Vec<PeerInfo>,
    pub ice_servers: serde_json::Value,  // [{urls, username, credential}] for RTCPeerConnection
}

// In handle_pair: collect all Connected desktop slots from the room,
// build PeerInfo vec, generate TURN credentials (call generate_turn_credentials),
// include in pair-ack. Store phone_client_id in SlotInfo.
```

### Anti-Patterns to Avoid

- **requestPermission in async context:** Any `await` or `.then()` before `requestPermission()` breaks iOS gesture detection. The call must be the first statement after the synchronous click, even if preceded by a brief `'Activating...'` UI update.
- **Not consuming incomingBidirectionalStreams:** If the phone doesn't loop on server-push streams, back-pressure accumulates and the WT connection stalls. This is silent — no error, just timeout.
- **DashMap ref across await:** Holding a DashMap `.get_mut()` ref while calling any `.await` or `broker.route()` will deadlock. Always clone needed data out, drop the ref, then call async functions.
- **sending offer before onnegotiationneeded fires:** Manually calling `createOffer()` before `onnegotiationneeded` races with the browser's internal state machine. Wait for the event.
- **nginx try_files without $uri.html:** `try_files $uri /index.html` serves index.html for `/phone` instead of phone.html. Must be `$uri $uri.html /index.html`.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| ICE gathering / STUN traversal | Custom UDP hole-punch | RTCPeerConnection built-in | Dozens of edge cases (hairpin NAT, IPv6, aggressive firewalls) |
| TURN credential generation | Custom auth scheme | `generate_turn_credentials` (existing turn_creds.rs) | Already HMAC-SHA1 coturn-compatible; single-use pattern |
| Constant-time HMAC comparison | `==` on byte arrays | `mac.verify_slice()` (existing pattern) | Timing attack on pairing token validation |
| WebRTC data serialization | Custom binary framing | `ordered:false, maxRetransmits:0` channel semantics | Browser SCTP handles framing; sensor data is Phase 5 |
| SDP parsing / manipulation | Custom SDP regex | `pc.setLocalDescription()` (no args) | Browser generates correct SDP; manual editing is fragile |
| Session storage across WT reconnect | Custom token scheme | Existing reconnect_token from pair-ack | Already implemented in Phase 3 |

**Key insight:** WebRTC's RTCPeerConnection handles all the hard problems (DTLS handshake, SCTP setup, ICE, TURN relay) invisibly. Phone.js only needs to handle the signaling exchange (offer/answer/ICE via WT); the browser takes care of everything else.

---

## Common Pitfalls

### Pitfall 1: iOS requestPermission Breaks Outside Synchronous Gesture
**What goes wrong:** `DeviceMotionEvent.requestPermission()` silently fails (permission denied or no prompt) on iOS.
**Why it happens:** iOS Safari tracks a synchronous user-gesture stack. Any async boundary — including `Promise.resolve().then()`, `await someOtherThing()`, or `setTimeout(fn, 0)` — pops the gesture stack before requestPermission is called.
**How to avoid:** First line of the `onclick` handler must be the `requestPermission()` call (or the feature-detection `if` that immediately calls it). The subsequent `.then()` on the returned promise is fine — that is after the call, not before.
**Warning signs:** iOS 13+ users see no permission prompt; motion events never fire; page loads but "Grant Motion Access" tap does nothing visible.

### Pitfall 2: incomingBidirectionalStreams Not Consumed
**What goes wrong:** Server pushes (peer-joined, peer-left, player-ready) silently never arrive at the phone. WT connection eventually stalls.
**Why it happens:** WebTransport streams that are not consumed by the receiver cause flow-control back-pressure. The server's `open_bi().await` will eventually hang, breaking the relay loop.
**How to avoid:** Start `listenForServerPushes(transport)` immediately after `await transport.ready`, before sending any signaling messages. Run it in a separate async task (non-blocking relative to sending).
**Warning signs:** Signaling messages sent to phone via broker are never received; `player-ready` never fires on phone side.

### Pitfall 3: DashMap Ref Held Across Broker Call (Phase 3 Pattern)
**What goes wrong:** Deadlock in the Rust server when handle_rtc_channel_ready tries to route player-ready via broker while holding a DashMap shard lock.
**Why it happens:** DashMap uses per-shard RwLocks. broker.route() also accesses the broker's DashMap. If the same thread holds a shard read lock on rooms and then calls broker.route() which tries to acquire a broker shard lock, no deadlock — but if the rooms shard is write-locked and another thread needs it, the tokio task blocks a worker thread. More critically, DashMap guards cannot be held across `.await` points safely.
**How to avoid:** Follow the established collect-then-drop pattern from room_registry.rs: collect needed data (peer ids) into a Vec while holding the DashMap ref, end the block (drop the ref), then iterate the Vec calling broker.route().
**Warning signs:** Server appears to hang during high-connection-count scenarios; cargo test hangs in new room_registry tests.

### Pitfall 4: Wake Lock Silently Rejected
**What goes wrong:** navigator.wakeLock.request() throws on low battery, power save mode, or when the document is not visible.
**Why it happens:** The Wake Lock API requires the document to be active and visible, and the system to allow it (battery policy).
**How to avoid:** Wrap in try-catch. Do not surface this error to the user — Wake Lock is a best-effort enhancement. Log to console in dev mode only.
**Warning signs:** Screen auto-locks during active game session on some devices; error logs show "DOMException: The request is not allowed".

### Pitfall 5: TURN Credential TTL Too Short
**What goes wrong:** WebRTC ICE negotiation fails with auth errors (`401 Unauthorized` from coturn) seconds after pair-ack is received.
**Why it happens:** ICE gathering can take several seconds; if TURN credentials in pair-ack have a very short TTL (e.g., 60s with slow ICE), coturn rejects them by the time the first TURN allocation attempt is made.
**How to avoid:** Use 5-minute TTL (300 seconds) for TURN credentials in pair-ack. The existing `pairing_ttl_secs` is 300 — reuse that constant or add a separate `turn_ttl_secs = 300`.
**Warning signs:** P2P connections work on local network (STUN only) but fail through TURN; `RTCPeerConnection.connectionState` stays `'failed'` on cellular or restrictive networks.

### Pitfall 6: nginx try_files Without $uri.html
**What goes wrong:** Navigating to `/phone?token=...` serves index.html (the desktop SPA) instead of phone.html.
**Why it happens:** `try_files $uri /index.html` checks if `/phone` is a file (it isn't) then falls back to index.html. The intermediate `$uri.html` check is needed.
**How to avoid:** Change nginx config to `try_files $uri $uri.html /index.html`. Test by requesting `/phone` from a browser — it should serve phone.html.
**Warning signs:** Phone users see the desktop QR lobby screen after scanning; URL shows `/phone?token=...` but content is index.html.

### Pitfall 7: pair-ack peers[] Includes Phone's Own Slot
**What goes wrong:** Phone tries to open a WebRTC channel to itself.
**Why it happens:** If peers[] is built from all occupied slots without filtering, the phone's own desktop (slot the token belongs to) is included — and the phone's client_id is not registered as a desktop, so routing fails.
**How to avoid:** Build peers[] from Connected desktop slots only. The phone is not a slot occupant — it's associated with a slot. peers[] should only include desktops that have sent join-room (their client_ids are registered in the broker).
**Warning signs:** RTCPeerConnection to "self" connection stays in `'connecting'`; server logs show routing failure for ice-candidate.

---

## Runtime State Inventory

Phase 4 is a greenfield addition (new phone.html/phone.js, server extensions). No rename/refactor operations. No prior runtime state to migrate.

**Nothing found in any category** — verified by reading CONTEXT.md deferred section and REQUIREMENTS.md: no migration, no stored data changes, no OS-level state.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Rust / cargo | Server build | ✓ | 1.93.1 (stable) | — |
| Node.js | Dev tooling | ✓ | v25.6.1 | — |
| Docker / docker compose | Stack deployment | [ASSUMED] present (used in prior phases) | — | dev without containers |
| mkcert certs | WT + nginx HTTPS | ✓ (generated in Phase 1) | — | regenerate via `make dev-certs` |
| coturn | STUN/TURN | [ASSUMED] running in Docker | — | STUN-only (no TURN relay for cellular) |
| iOS device (iPhone 15) | PHONE-02 acceptance | [ASSUMED] available for manual test | — | Simulator cannot test DeviceMotionEvent |
| Android Chrome device | PHONE-01 acceptance | [ASSUMED] available for manual test | — | No fallback — physical device required |

**Missing dependencies with no fallback:**
- Physical iOS device (iPhone 15 or equivalent) — iOS Simulator does not support DeviceMotionEvent.requestPermission(). Required for PHONE-02 acceptance.
- Physical Android device — required for PHONE-01 / PHONE-03 acceptance on Android Chrome.

**Missing dependencies with fallback:**
- coturn TURN relay — can test P2P channels on local network with STUN only. TURN relay tested separately.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Rust built-in test harness (`cargo test`) |
| Config file | `server/Cargo.toml` (workspace) |
| Quick run command | `cd server && cargo test 2>&1 \| tail -20` |
| Full suite command | `cd server && cargo test` |

Baseline (verified): 25 unit tests + 2 integration tests = 27 total, all passing.

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| PHONE-01 | phone.html served at /phone (nginx) | manual | verify URL /phone serves phone.html | ❌ Wave 0 (manual) |
| PHONE-02 | iOS DeviceMotionEvent gate is first interaction | manual | physical device test | ❌ Wave 0 (manual) |
| PHONE-03 | RTCPeerConnection channels open (ordered:false, maxRetransmits:0) | unit + manual | `cargo test room_registry` for server; manual P2P for channels | ❌ Wave 0 |
| PHONE-06 | Heartbeat every 5s; server marks disconnected within 65s | unit | `cargo test handle_heartbeat` | ❌ Wave 0 |
| PHONE-07 | Wake Lock active after player-ready | manual | physical device (screen stays on) | ❌ Wave 0 (manual) |
| D-04 | pair-ack includes peers[] | unit | `cargo test pair_ack_includes_peers` | ❌ Wave 0 |
| D-08 | Both-sides channel-ready → player-ready | unit | `cargo test rtc_channel_ready_both_sides` | ❌ Wave 0 |
| D-09 | player-ready broadcast fires after all channels confirmed | unit | `cargo test player_ready_broadcast` | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** `cd /home/ivancist/Documents/immersiveRT/server && cargo test 2>&1 | tail -15`
- **Per wave merge:** `cd /home/ivancist/Documents/immersiveRT/server && cargo test`
- **Phase gate:** Full suite green + manual device tests (PHONE-01, PHONE-02, PHONE-07) before `/gsd-verify-work`

### Wave 0 Gaps

New test functions (to be added within their respective modules):
- [ ] `room_registry::tests::test_pair_ack_includes_peers` — pair-ack payload has peers[] with all Connected desktops
- [ ] `room_registry::tests::test_pair_ack_records_phone_client_id` — SlotInfo.phone_client_id set after pair
- [ ] `room_registry::tests::test_rtc_channel_ready_both_sides_fires_player_ready` — player-ready only after both phone and desktop confirm each channel
- [ ] `room_registry::tests::test_rtc_channel_ready_single_side_no_player_ready` — one side only → no player-ready
- [ ] `room_registry::tests::test_heartbeat_updates_last_heartbeat` — handle_heartbeat sets timestamp
- [ ] `room_registry::tests::test_peer_joined_push_to_phone` — new desktop join pushes peer-joined to phone
- [ ] `server/tests/broker_relay.rs::test_rtc_channel_ready_routing` — integration test for new message type end-to-end

---

## Security Domain

`security_enforcement: true` (default, not overridden in config.json). ASVS Level 1.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes — pairing token | HMAC-SHA1 with `verify_slice` (constant-time); single-use via PairingTokenStore (existing) |
| V3 Session Management | yes — phone session | phone_client_id bound to slot after pair; slot holds 60s on disconnect |
| V4 Access Control | yes — room membership gate | D-02: room membership = authorization; server validates before routing |
| V5 Input Validation | yes | All new message types parsed via `parse_envelope` (serde, returns None on malformed); payload fields extracted with `.as_str()` / `.as_u64()` defensive pattern |
| V6 Cryptography | yes — TURN creds | HMAC-SHA1 in `generate_turn_credentials` (existing, do not hand-roll) |

### Known Threat Patterns

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| From-field spoofing in signaling | Spoofing | Existing check in wt_server.rs: `envelope.from != my_id → drop` |
| Token replay attack (pairing) | Elevation of privilege | Single-use: PairingTokenStore.validate_and_consume (existing) |
| Heartbeat flood (DoS) | DoS | Server just updates timestamp — O(1) op, no allocation; no mitigation needed beyond existing per-connection semaphore |
| ICE candidate injection | Tampering | Server attestation in routing envelope (D-03); from-field check prevents spoofing source |
| phone-state flood (DoS) | DoS | Server only relays — stateless; existing 64 KiB message size cap in wt_server.rs applies |
| Token in URL query string | Information disclosure | Accepted risk (Phase 3 precedent; QR scan context); token is short-lived (pairing_ttl_secs) |

---

## Open Questions

1. **TURN credentials in pair-ack vs. pre-configured STUN URL**
   - What we know: The `generate_turn_credentials` function exists and works. Phone needs ICE servers before creating RTCPeerConnection.
   - What's unclear: Whether to include TURN creds in pair-ack (server-generated at pair time) or configure coturn STUN URL as a build-time constant in phone.js.
   - Recommendation: Include TURN creds in pair-ack — this follows the "connection-start" principle from STATE.md and avoids hardcoding any server address. Requires handle_pair to call generate_turn_credentials and include `ice_servers` in pair-ack payload.

2. **handle_pair signature extension for phone_client_id**
   - What we know: Currently `handle_pair(&self, raw_payload, _broker)` — broker is unused. Phone's client_id comes from `envelope.from` in wt_server.rs.
   - What's unclear: Whether to pass phone_client_id as a parameter or derive it some other way.
   - Recommendation: Add `phone_client_id: &str` as a third parameter to `handle_pair`. The WT/WS handlers already have access to `envelope.from` at the dispatch point.

3. **Channel-ready tracking data structure (Claude's Discretion)**
   - What we know: Need to track (phone_confirmed, desktop_confirmed) per (room, phone, desktop) triple.
   - What's unclear: Whether to use a dedicated DashMap on RoomRegistry or store per-slot counters.
   - Recommendation: Add `channel_ready: Arc<DashMap<(RoomCode, String, String), (bool, bool)>>` to RoomRegistry. Key = (room_code, phone_client_id, desktop_client_id). Simpler than per-slot counter arithmetic.

4. **Heartbeat miss background task placement**
   - What we know: Need a periodic check across all rooms. tokio::spawn at startup.
   - Recommendation: Spawn in `main.rs` after `RoomRegistry::new()`, passing `Arc<RoomRegistry>` + `Arc<SignalingBroker>`. Run every 10 seconds; check `last_heartbeat` older than 65s.

---

## Sources

### Primary (MEDIUM confidence)
- [MDN WebTransport API](https://developer.mozilla.org/en-US/docs/Web/API/WebTransport_API) — createBidirectionalStream, readable/writable stream patterns, incomingBidirectionalStreams [CITED]
- [MDN RTCPeerConnection createDataChannel](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/createDataChannel) — ordered/maxRetransmits params, onnegotiationneeded, ondatachannel, onopen [CITED]
- [MDN Perfect Negotiation](https://developer.mozilla.org/en-US/docs/Web/API/WebRTC_API/Perfect_negotiation) — setLocalDescription no-args auto-offer pattern, trickle ICE, makingOffer flag [CITED]
- [MDN Screen Wake Lock API](https://developer.mozilla.org/en-US/docs/Web/API/Screen_Wake_Lock_API) — request(), release event, visibilitychange reacquisition, feature detection [CITED]
- [MDN DeviceMotionEvent](https://developer.mozilla.org/en-US/docs/Web/API/DeviceMotionEvent) — requestPermission(), gesture requirement, Android feature detection [CITED]

### Secondary (project-specific)
- `server/src/room_registry.rs` — existing collect-then-drop DashMap pattern; `broadcast_to_room` signature; SlotInfo/SlotStatus structures [VERIFIED: codebase grep]
- `server/src/wt_server.rs` — match arm dispatch pattern for new message types; `envelope.from` validation [VERIFIED: codebase grep]
- `server/src/signaling.rs` — existing SignalingEnvelope, PairAckPayload; extension point for PeerInfo and enhanced pair-ack [VERIFIED: codebase grep]
- `server/src/turn_creds.rs` — `generate_turn_credentials` function signature and HMAC-SHA1 pattern [VERIFIED: codebase grep]
- `docker/nginx/nginx.conf` — current `try_files $uri /index.html`; one-line change target [VERIFIED: codebase grep]
- `client/dist/index.html` — design token `:root` CSS block to copy verbatim into phone.html [VERIFIED: codebase grep]

### Tertiary (LOW confidence)
- WebSearch: trickle ICE pattern confirmation, MDN links [LOW]

---

## Metadata

**Confidence breakdown:**
- Browser APIs (WebTransport, WebRTC, DeviceMotionEvent, Wake Lock): MEDIUM — confirmed against MDN authoritative docs
- Server architecture (room_registry extensions): HIGH — reading existing code directly
- Pitfalls: MEDIUM — some from direct code analysis, some from MDN behavioral notes
- ICE server inclusion in pair-ack: ASSUMED — reasonable extension, consistent with project patterns

**Research date:** 2026-07-08
**Valid until:** 2026-08-08 (browser APIs stable; Rust crates pinned in Cargo.lock)

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Docker and coturn are available and running in the dev environment | Environment Availability | TURN relay tests fail; P2P on LAN still works via STUN |
| A2 | Physical iOS 15 and Android Chrome devices are available for manual acceptance testing | Environment Availability | PHONE-02 and PHONE-01 acceptance criteria cannot be verified; phase cannot be completed |
| A3 | Pairing token TTL (pairing_ttl_secs = 300 from make_registry test) is the right value to reuse for TURN credential TTL | Pattern 8 | TURN creds may expire before ICE completes; use separate TURN_TTL_SECS env var if needed |
| A4 | Desktop side (room.js) needs WebRTC answer/ondatachannel additions in Phase 4 even though DESK-02 is formally Phase 6 | Phase Requirements | PHONE-03 cannot be verified if desktop has no WebRTC answer capability; plan must include room.js additions |
