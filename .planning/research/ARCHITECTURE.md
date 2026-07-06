# Architecture Patterns

**Domain:** Real-time web gaming platform — phone-as-controller with IMU sensor streaming
**Researched:** 2026-07-06
**Confidence:** MEDIUM (topology/signaling from web sources LOW; wtransport/Three.js API from docs MEDIUM)

---

## Recommended Architecture

### System Topology: Full P2P Mesh with TURN Fallback (not SFU)

For this use case — each phone streams to one desktop, data packets are tiny (~30-40 bytes), and latency is the primary constraint — a direct WebRTC P2P data channel is the correct topology. An SFU adds a server relay hop (10-50ms) without any mixing benefit for data channels. SFU is only warranted if one phone must fan-out to many desktops simultaneously; that case is handled by the TURN relay fallback path anyway.

```
Phone (Mobile Browser)
  │
  │ [WebTransport QUIC/HTTP3 — bidir stream for signaling]
  │
  ▼
Rust WebTransport Server (wtransport + tokio)
  │
  │ [WebTransport bidir stream for signaling]
  │
  ▼
Desktop Browser (Three.js)
  │
  ◄────────── WebRTC Data Channel ──────────►
         (direct P2P when possible)
         (TURN relay via coturn when NAT blocks)
```

### Deployment Containers

| Container | Image | Role | Exposes |
|-----------|-------|------|---------|
| `webtransport-server` | Rust binary (custom) | Signaling + session mgmt | 4433/UDP (QUIC) |
| `coturn` | `coturn/coturn` | STUN + TURN relay | 3478/UDP+TCP, 49152-65535/UDP |
| `static-server` | nginx or caddy | Serve phone + desktop HTML/JS/WASM | 443/TCP (HTTPS required for Device Motion) |

All three in one Docker Compose network. coturn and the Rust server are peers — the Rust server does not proxy through coturn, it only tells clients coturn's address in signaling messages.

---

## Component Boundaries

### Phone Client

| Responsibility | Lives In |
|----------------|----------|
| DeviceOrientationEvent + DeviceMotionEvent capture | `sensor/reader.ts` |
| Madgwick filter (orientation fusion) | `sensor/madgwick.ts` |
| ZUPT detection (stationary classifier) | `sensor/zupt.ts` |
| Kalman filter (dead-reckoning position) | `sensor/kalman.ts` |
| Binary packet encoder | `transport/encoder.ts` |
| WebTransport client (signaling channel) | `transport/signaling-client.ts` |
| RTCPeerConnection + data channel setup | `transport/webrtc-client.ts` |
| Touch input capture | `input/touch.ts` |

### Desktop Client / SDK

| Responsibility | Lives In |
|----------------|----------|
| WebTransport client (signaling channel) | `transport/signaling-client.ts` |
| RTCPeerConnection setup (offer/answer) | `transport/webrtc-host.ts` |
| Binary packet decoder | `transport/decoder.ts` |
| Jitter buffer + sequence tracker | `transport/jitter-buffer.ts` |
| Quaternion interpolation → Three.js | `renderer/imu-applier.ts` |
| SDK public API surface | `sdk/index.ts` |

### Rust WebTransport Server

| Responsibility | Lives In |
|----------------|----------|
| QUIC endpoint (wtransport Endpoint::server) | `main.rs` / `server.rs` |
| Session accept loop (tokio tasks) | `server.rs` |
| Room registry (phone↔desktop pairing) | `rooms.rs` |
| Signaling message router | `signaling.rs` |
| ICE credential relay (coturn addr injection) | `signaling.rs` |

### coturn

Opaque STUN/TURN process. No custom code. Config only (`turnserver.conf`). Communicates with browsers directly via STUN/TURN protocols — the Rust server does not sit in this path at runtime.

---

## Data Flow — Sensor Hot Path

This is the latency-critical path. Every arrow is a hop with a latency budget.

```
[Phone OS] → DeviceOrientationEvent / DeviceMotionEvent
    │  ~0ms (local event dispatch)
    ▼
[Madgwick filter] → quaternion q_w
    │  ~0.1ms (WASM or JS, runs at 60-100Hz)
    ▼
[Kalman/ZUPT] → position delta Δp
    │  ~0.1ms
    ▼
[Binary encoder] → ArrayBuffer ~30-40 bytes
    │  ~0.05ms
    ▼
[RTCDataChannel.send(buffer)]
    │  Browser DTLS/SCTP stack overhead ~0.5-1ms
    ▼
[Network transit]
    │  LAN: 1-5ms  |  Internet P2P: 20-80ms  |  TURN relay: +10-40ms
    ▼
[RTCDataChannel.onmessage on desktop]
    │  ~0.1ms
    ▼
[Binary decoder + seq/timestamp check]
    │  ~0.05ms (discard stale packets by sequence number)
    ▼
[Jitter buffer] → latest valid state
    │  0ms (no intentional delay; pick newest)
    ▼
[Three.js render frame (requestAnimationFrame)]
    │  object.quaternion.slerp(receivedQuat, t) where t ∈ [0.1, 0.5]
    ▼
[GPU draw] → visual update

Total hot-path budget (LAN): target < 20ms end-to-end (sensor→pixel)
```

### Latency Budget Per Hop

| Hop | Best Case (LAN) | Typical (Internet P2P) | Fallback (TURN) |
|-----|-----------------|------------------------|-----------------|
| Sensor read → filter | < 1ms | < 1ms | < 1ms |
| Filter → encode → send | < 1ms | < 1ms | < 1ms |
| Network transit | 1-5ms | 20-60ms | 30-100ms |
| Receive → decode → buffer | < 1ms | < 1ms | < 1ms |
| Render frame alignment | 0-16ms (60fps budget) | 0-16ms | 0-16ms |
| **Total** | **< 20ms** | **25-80ms** | **35-120ms** |

The 0-16ms render frame alignment is the dominant jitter source on LAN. slerp smoothing hides this without adding perceptible lag.

---

## Signaling Flow: WebRTC Handshake over WebTransport

```
Phone                    Rust Server              Desktop
  │                          │                       │
  │─── WebTransport connect ─►│                       │
  │                          │◄── WebTransport connect─│
  │                          │                       │
  │─── JOIN room_id ────────►│                       │
  │                          │◄── JOIN room_id ───────│
  │                          │                       │
  │◄── ICE config (coturn) ──│── ICE config (coturn) ►│
  │    {urls, credential}    │   {urls, credential}   │
  │                          │                       │
  │  createOffer()           │                       │
  │─── SDP offer ───────────►│── SDP offer ──────────►│
  │                          │                       │
  │                          │   setRemoteDescription │
  │                          │   createAnswer()       │
  │◄── SDP answer ───────────│◄── SDP answer ─────────│
  │                          │                       │
  │  setRemoteDescription    │                       │
  │                          │                       │
  │─── ICE candidate ───────►│── ICE candidate ──────►│  (trickle, multiple)
  │◄── ICE candidate ────────│◄── ICE candidate ──────│
  │                          │                       │
  │  ICE connectivity checks (direct P2P attempts)   │
  │  ◄──────────── DTLS handshake ─────────────────► │
  │  ◄──────────── SCTP association ───────────────► │
  │  ◄──────────── data channel open ──────────────► │
  │                          │                       │
  │  [Signaling bidir stream no longer needed]        │
  │                          │                       │
  │═══ IMU hot path: direct WebRTC data channel ════► │
```

The Rust server is only in the signaling path. Once the WebRTC data channel is open, the server is out of the hot path entirely. This is the key design: server handles setup, not runtime.

### WebTransport Bidir Stream Usage on Server

Each client opens one persistent bidirectional stream for signaling. The server routes messages between clients in the same room. Message framing: length-prefixed JSON (2-byte length prefix + UTF-8 JSON body). Message types: `join`, `leave`, `offer`, `answer`, `ice-candidate`, `ice-config`.

```rust
// Per session loop (simplified)
tokio::select! {
    Ok((send, recv)) = connection.accept_bi() => {
        handle_signaling_stream(send, recv, &rooms).await;
    }
    // datagrams not used for signaling (streams give ordering guarantee)
}
```

---

## Packet Structure

### IMU Sensor Packet (binary, ArrayBuffer)

```
Offset  Bytes  Type      Field
0       2      uint16    sequence_number  (wraps at 65535)
2       8      float64   timestamp_ms     (performance.now() on phone)
10      4      float32   quat_w
14      4      float32   quat_x
18      4      float32   quat_y
22      4      float32   quat_z
26      2      int16     accel_x          (linear accel, scaled ×1000, m/s²)
28      2      int16     accel_y
30      2      int16     accel_z
32      2      int16     pos_delta_x      (dead-reckoning delta, mm)
34      2      int16     pos_delta_y
36      2      int16     pos_delta_z
38      1      uint8     flags            (bit0=zupt, bit1=gesture_start, bit2=gesture_end, bit3=touch)
39      1      uint8     touch_state      (button bitmask)

Total: 40 bytes per packet
```

At 60Hz: 40 bytes × 60 = 2,400 bytes/sec ≈ 19 Kbps per phone. Negligible bandwidth.

### Out-of-Order Handling

```typescript
// On desktop, per player
let lastSeq = -1;

dataChannel.onmessage = (event) => {
  const view = new DataView(event.data);
  const seq = view.getUint16(0, true);  // little-endian
  
  // Handle uint16 wraparound: if diff > 32767, seq is older
  const diff = (seq - lastSeq + 65536) % 65536;
  if (diff === 0 || diff > 32767) return;  // duplicate or older packet: drop
  
  lastSeq = seq;
  processPacket(view);
};
```

No jitter buffer delay. Drop stale, apply fresh immediately.

---

## Sensor Fusion Pipeline — Where Each Algorithm Runs

| Algorithm | Runs On | Input | Output | Rationale |
|-----------|---------|-------|--------|-----------|
| Madgwick filter | Phone only | gyro + accel + mag (DeviceMotionEvent) | quaternion q | Drift correction needs full sensor access; cuts one round-trip |
| ZUPT detection | Phone only | linear_acceleration magnitude | boolean: stationary | Trivially cheap; must be co-located with Kalman |
| Kalman filter (PDR) | Phone only | accel + ZUPT events | position delta Δp | State must stay on phone; no server round-trip in filter loop |
| Quaternion slerp (render) | Desktop only | received q + render Δt | smoothed rotation | Interpolation between frames; purely a rendering concern |
| Dead-reckoning reset | Game logic | gesture end event | reset accumulated drift | Game decides when to clear Δp; SDK exposes the event |

Dead reckoning on the phone means the server never sees raw sensor data — it only ever routes the processed, filtered, packed state. This is intentional: it keeps server complexity minimal and eliminates a round-trip from the filter loop.

---

## Architecture Patterns to Follow

### Pattern 1: Session State Machine in Rust Server

Each room tracks a state machine: `Waiting → PhonePaired → DesktopPaired → BothPaired → SignalingComplete`.

```rust
enum RoomState {
    Empty,
    PhoneWaiting { phone_tx: BiStreamSender },
    DesktopWaiting { desktop_tx: BiStreamSender },
    Paired { phone_tx: BiStreamSender, desktop_tx: BiStreamSender },
}
```

Route signaling messages only when `Paired`. Discard and return error otherwise.

### Pattern 2: DataView Binary Codec (TypeScript)

Always use `DataView` with explicit byte offsets, never `JSON.stringify`. At 60Hz, JSON serialization overhead is measurable (~0.3ms per frame). Keep encoder/decoder as pure functions with no allocations on the hot path — reuse a pre-allocated `ArrayBuffer`.

```typescript
// Pre-allocate once, reuse every frame
const buffer = new ArrayBuffer(40);
const view = new DataView(buffer);

function encodePacket(q: Quaternion, accel: Vec3, delta: Vec3, flags: number): ArrayBuffer {
  view.setUint16(0, seq++ & 0xFFFF, true);
  view.setFloat64(2, performance.now(), true);
  view.setFloat32(10, q.w, true);
  // ... etc
  return buffer;
}
```

### Pattern 3: Slerp on the Render Loop (Three.js)

Never set `object.quaternion` directly from received data inside `onmessage`. Instead, write to a player state store and slerp toward it each `requestAnimationFrame`.

```typescript
// onmessage: update target state
playerState[playerId].targetQuat.set(qx, qy, qz, qw);

// rAF loop: smooth toward target
function render() {
  for (const [id, state] of playerState) {
    objects[id].quaternion.slerp(state.targetQuat, SLERP_ALPHA);
    objects[id].quaternion.normalize();
  }
  renderer.render(scene, camera);
  requestAnimationFrame(render);
}
```

`SLERP_ALPHA` of 0.2-0.4 gives responsive-yet-smooth motion. Increase to 1.0 for immediate snap (useful for debugging).

### Pattern 4: WebTransport TLS for Local Dev

coturn and the Rust server both require real TLS — browsers reject self-signed certs for both WebTransport (QUIC) and HTTPS (Device Motion permission gate). Use `mkcert` to generate a locally-trusted cert for dev:

```bash
mkcert -install && mkcert localhost 127.0.0.1
```

Pass the generated cert to both the Rust server (`Identity::load_pemfiles`) and the static server nginx config.

---

## Anti-Patterns to Avoid

### Anti-Pattern 1: SFU for Data Channels

**What:** Routing all IMU packets through an SFU server even when direct P2P is possible.
**Why bad:** Adds 10-50ms server relay latency for zero benefit. Data channels carry no audio/video that needs SFU mixing. The SFU relay path is already covered by the TURN fallback.
**Instead:** Default to P2P direct. Use TURN only as ICE fallback.

### Anti-Pattern 2: JSON Encoding on the Hot Path

**What:** `dataChannel.send(JSON.stringify({ qw, qx, qy, qz, ts, seq }))`.
**Why bad:** JSON for a quaternion is ~80 bytes vs 40 bytes binary. At 60Hz × 4 players = 19KB/s vs 10KB/s. String serialization adds ~0.3ms/frame and forces GC pressure in the render loop.
**Instead:** Binary `DataView` with fixed-offset fields, pre-allocated buffer, reused every frame.

### Anti-Pattern 3: Filtering on the Server

**What:** Sending raw gyro + accel samples to the server for Madgwick/Kalman processing.
**Why bad:** Doubles the round-trip in the filter loop. Server becomes stateful per player. Adds server CPU cost proportional to player count.
**Instead:** All sensor fusion runs on-device. Server only routes the processed, stable quaternion + delta position.

### Anti-Pattern 4: Reliable WebRTC Data Channel for IMU

**What:** `createDataChannel('imu', { ordered: true })` (the default).
**Why bad:** A dropped packet triggers TCP-like retransmit + head-of-line blocking. Late retransmitted quaternion replaces a newer one. At 60Hz this causes visible jitter spikes during any packet loss.
**Instead:** `{ ordered: false, maxRetransmits: 0 }`. Drop stale packets on the receiver using sequence number comparison.

### Anti-Pattern 5: Blocking Accept Loop in Rust Server

**What:** Single-threaded accept loop that handles one session to completion before accepting the next.
**Why bad:** One slow session blocks all others. Can't handle concurrent phones + desktops.
**Instead:** `tokio::spawn` per accepted session. The main accept loop returns immediately after spawning.

---

## Build Order Implications

The architecture has hard dependencies that determine build order:

```
1. INFRASTRUCTURE LAYER (must exist first)
   - coturn running and STUN-accessible
   - Rust WebTransport server: TLS cert, accept loop, room state machine, signaling router
   - Static file server with HTTPS
   → Without this, WebRTC handshake cannot complete

2. TRANSPORT LAYER (depends on infra)
   - Phone: WebTransport signaling client, RTCPeerConnection + data channel setup
   - Desktop: mirror of above
   → Cannot test P2P without working signaling

3. SENSOR PIPELINE (depends on transport)
   - Madgwick filter (can be tested standalone with DeviceMotion mock)
   - Binary encoder/decoder (can be unit tested offline)
   - ZUPT + Kalman (can be unit tested offline)
   → Sensor code is pure logic; testable before transport is ready

4. RENDERING LAYER (depends on transport + sensor)
   - Three.js slerp loop
   - Player state store
   → Needs real packets flowing to validate timing

5. SDK LAYER (depends on all above)
   - Public API surface wrapping all the above
   → Integration work; no new primitives

6. DEMO GAME (depends on SDK)
   - Wires SDK to visible Three.js objects
   - Latency overlay
```

**Critical path:** coturn + Rust server → WebRTC handshake complete → sensor packets flowing → Three.js responds. The sensor filter work can proceed in parallel but cannot be validated end-to-end until the transport layer is proven.

---

## Scalability Considerations

| Concern | At 1-4 phones | At 5-20 phones | At 20+ phones |
|---------|--------------|----------------|---------------|
| WebRTC topology | P2P mesh, zero server data traffic | P2P still fine; signaling load grows linearly | Consider hub-and-spoke: phone → server relay → desktops |
| Rust server CPU | Negligible (signaling only) | Negligible | Consider message fan-out if server relays |
| coturn TURN | Only for blocked NAT (~10-30% of connections) | Same; TURN traffic still tiny (IMU only) | Same; budget relay bandwidth |
| Three.js render | Per-player slerp loop O(N) | 20 slerp calls/frame ≈ trivial | 100+ players needs object culling |
| Bandwidth (phone upload) | 19 Kbps per phone | 380 Kbps for 20 phones | Linear, manageable |

For v1 (demo game, handful of players), the P2P architecture scales with zero changes. SFU is a future concern only if a single desktop must receive from >10 phones simultaneously.

---

## Sources

- WebRTC topology analysis: [Ant Media — Mesh vs SFU vs MCU](https://antmedia.io/webrtc-network-topology/), [BlogGeek.me TURN](https://bloggeek.me/webrtc-turn/)
- WebTransport lifecycle: [MDN WebTransport API](https://developer.mozilla.org/en-US/docs/Web/API/WebTransport_API), [w3c/webtransport explainer](https://github.com/w3c/webtransport/blob/main/explainer.md), [IETF draft-ietf-webtrans-http3](https://datatracker.ietf.org/doc/draft-ietf-webtrans-http3/)
- WebRTC data channel config: [web.dev WebRTC data channels](https://web.dev/articles/webrtc-datachannels), [Jim Fisher reliability explainer](https://jameshfisher.com/2017/01/17/webrtc-datachannel-reliability/)
- WebRTC signaling: [WebRTC.link signaling guide](https://webrtc.link/en/articles/webrtc-signaling-role-and-necessity/), [webrtc.org peer connections](https://webrtc.org/getting-started/peer-connections)
- ICE/STUN/TURN: [GetStream ICE candidates](https://getstream.io/resources/projects/webrtc/advanced/stun-turn/), [BlogGeek.me trickle ICE](https://bloggeek.me/webrtcglossary/trickle-ice/)
- LAN latency benchmarks: [MIT WebRTC measurements](https://dspace.mit.edu/bitstream/handle/1721.1/123051/1128023197-MIT.pdf), [Helsinki WebRTC data channels](https://tuhat.helsinki.fi/ws/portalfiles/portal/167373638/Eskola_webrtc.pdf)
- Packet design: [Gaffer on Games snapshot interpolation](https://gafferongames.com/post/snapshot_interpolation/), [Gaffer on Games state synchronization](https://gafferongames.com/post/state_synchronization/)
- wtransport crate: [docs.rs/wtransport](https://docs.rs/wtransport), [BiagioFesta/wtransport examples](https://github.com/BiagioFesta/wtransport/blob/master/wtransport/examples/server.rs)
- Three.js quaternion: [Object3D.quaternion docs](https://threejs.org/docs/#api/en/core/Object3D.quaternion), [Three.js forum quaternion rotation](https://discourse.threejs.org/t/quaternion-rotation/8376)
- IMU sensor fusion: [Madgwick filter explanation](https://medium.com/@k66115704/imu-madgwick-filter-explanation-556fbe7f02e3), [qsense-motion Madgwick & Kalman](https://qsense-motion.com/qsense-imu-motion-sensor/madgwick-filter-sensor-fusion/)
