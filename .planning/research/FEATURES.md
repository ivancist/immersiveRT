# Feature Landscape

**Domain:** Real-time web gaming platform — phone as motion controller
**Researched:** 2026-07-06
**Overall confidence:** MEDIUM (cross-checked against AirConsole, Jackbox, MDN, WebRTC docs)

---

## Table Stakes

Features users and game developers expect. Missing = platform is unusable or untrusted.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| QR code room join | Every phone-as-controller platform (AirConsole, Jackbox) does this. Players expect scan-and-play | Low | Display QR on desktop; encode room token in URL |
| Short alphanumeric room code | QR unavailable when phone camera broken or remote streaming scenario | Low | 4-6 uppercase chars, case-insensitive, session-scoped |
| No app install | Platform value collapses if players must install an app; browser-native is the whole premise | Low (design) | Pure mobile web app; PWA optional |
| Player name entry | Every party game platform requires it. Players identify themselves to others | Low | On join screen; stored in session slot |
| Multi-player session (2-8 phones) | Single-player phone controller is a toy demo, not a platform | Medium | Server must manage N slots; each phone→desktop channel |
| Orientation stream (quaternion) | Core value proposition — the reason to use ImmersiveRT over raw WebSocket | High | Madgwick filter on-device; WebRTC unreliable channel |
| Touch event stream | Tap, button press — needed for any action that isn't motion-based | Low | Capture on phone; relay with timestamp |
| Player join/leave events in SDK | Game developers need lifecycle hooks to add/remove scene objects | Low | `on('playerJoin')`, `on('playerLeave')` events |
| `getPlayerInput(playerId)` polling API | Game loops run at 60fps; developers expect to read state per-frame | Low | SDK maintains internal buffer; returns latest interpolated state |
| `on('imuUpdate', cb)` event API | Reactive pattern preferred by some developers; AirConsole uses message-passing | Low | Both APIs must coexist — same data, two consumption patterns |
| Session isolation | Player in room A must not receive data from room B | Medium | Room token is the isolation boundary; server enforces it |
| TURN fallback | NAT blocks direct WebRTC on many corporate/school networks | Medium | coturn already planned; SDK auto-uses TURN ICE candidates |
| Sensor permission UI | iOS 13+ requires explicit user gesture to grant DeviceMotion access; if missing, orientation never works on Safari | Medium | Prominent "Enable Motion" button before game starts; handle 'denied' |
| TypeScript types | Three.js ecosystem is TypeScript-first; untyped SDK is a DX red flag | Low | Full typings for all inputs, events, player state |
| Latency timestamp in packets | Every serious real-time input platform embeds send-timestamp so receiver can compute latency | Low | Phone sends `{ seq, ts, ...data }` in every packet |

---

## Differentiators

Features that set ImmersiveRT apart from raw WebSocket + DeviceOrientation DIY approach and from AirConsole's generic message-passing model.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Structured IMU input layers | AirConsole exposes raw device_motion interval; ImmersiveRT exposes three distinct layers: quaternion orientation, gesture displacement window, dead-reckoning position — game devs don't reimplement filtering | High | Madgwick + ZUPT + Kalman on-device; SDK surface is `{ orientation: Quaternion, displacement: Vector3, position: Vector3 }` |
| On-device Madgwick filter | Drift-free orientation without server round-trip; no other browser platform does on-device fusion | High | Runs at sensor rate; outputs stable quaternion |
| Interpolation built into SDK | Raw 60Hz WebRTC delivers jittery quaternions; SDK applies slerp + ring-buffer smoothing before exposing to game | Medium | Default: smoothed. Opt-in: `{ raw: true }` for advanced use |
| Developer latency overlay | Ship a ready-made debug component: rolling avg latency, jitter, packet loss, ICE state | Medium | Reads from SDK internal stats; one-line include in game HTML |
| Sequence + timestamp in every packet | Allows precise latency and packet-loss measurement without external tools; unique to platforms that care about timing | Low | Binary packet header: `[seq: u32, ts: f64, type: u8, payload...]` |
| Graceful reconnection (slot hold) | Server holds player slot for 60s on disconnect; phone rejoins and reclaims its slot without game noticing | Medium | SDK emits `playerDisconnect`/`playerReconnect`; game can pause that player's entity |
| ZUPT gesture displacement windows | Gesture-scoped motion (arm swing, throw) is reliable even when room-scale position drifts — enables throw/swing mechanics no other browser controller platform supports | High | On-device ZUPT triggers displacement window; SDK emits `displacement` delta per gesture |
| Binary packet encoding (MessagePack) | JSON at 60Hz × 8 players = significant overhead; compact binary cuts packet size ~4x; AirConsole uses JSON | Low-Medium | msgpack-lite or manually packed ArrayBuffer |
| WebTransport signaling (QUIC) | WebSocket/TCP signaling has head-of-line blocking; QUIC eliminates it — faster ICE handshake, faster reconnect | High | Rust wtransport server; fallback to WebSocket needed for QUIC-blocked networks |

---

## Anti-Features

Features to deliberately NOT build in v1. Scope creep here causes rewrites.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| Room-scale absolute position | Requires camera + VIO; impossible from browser IMU alone; double-integration drifts quadratically. Claiming this works will destroy trust | Document limitation clearly; expose gesture displacement and dead-reckoning with explicit drift warning |
| Server-side game logic / authoritative state | Platform is a transport layer. Adding game authority couples the SDK to game rules, makes it unusable for other games | Keep server to signaling + relay only; game owns all state on desktop |
| Audio/video streaming | Massively increases TURN costs; not the use case; adds latency requirements irrelevant to IMU | Scope TURN strictly to data channels |
| Virtual joystick / D-pad on phone | AirConsole explicitly warns against this: "will always feel subpar on smartphone." Tactile feedback is absent | Design touch UI around large discrete buttons and gestures |
| Persistent accounts / matchmaking | Pure session-based for v1; auth infra is a separate product | Session token is anonymous and ephemeral |
| Native iOS/Android app | Browser Device Motion API covers the use case; app adds distribution friction | Progressive Web App wrapper is acceptable but don't ship native |
| SFU (Selective Forwarding Unit) | Sensor data is many-to-one: N phones → 1 desktop. SFU is for many-to-many media; adds server cost and complexity for no benefit here | Direct P2P + TURN relay covers the topology |
| MCU (mixing/transcoding) | Completely irrelevant for game input data | Never |
| Game library / platform marketplace | ImmersiveRT is a developer SDK, not an end-user game portal (that's AirConsole's business) | Ship demo game as reference, not marketplace |
| Persistent leaderboards | Requires auth, backend DB, and CDN — outside platform scope | Game developers build their own if needed |
| Multi-game switching without reload | Session lifecycle is per-game; supporting hot-swap between games requires complex state machine | Each desktop URL = one game; reload to change game |

---

## Feature Dependencies

```
Room join (QR + code)
  └─ Session management (server)
       └─ WebRTC signaling (WebTransport server)
            ├─ WebRTC P2P data channel (phone→desktop)
            │    ├─ Sensor permission UI  (prerequisite on phone)
            │    ├─ Orientation stream (quaternion)
            │    │    └─ Madgwick filter (on-device)
            │    │         └─ Interpolation layer (SDK)
            │    │              └─ getPlayerInput() + on('imuUpdate')
            │    ├─ Displacement stream
            │    │    └─ ZUPT + Kalman (on-device)
            │    ├─ Touch event stream
            │    └─ Binary packet encoding (seq + ts header)
            │         └─ Latency overlay (dev tool)
            └─ TURN fallback (coturn)
                 └─ Reconnection slot-hold (server)
                      └─ playerDisconnect/playerReconnect events (SDK)

Demo game
  └─ All of the above
  └─ Latency overlay component
```

---

## Session Lifecycle (detail)

The join flow is the first thing every player experiences. It must be zero-friction.

**Recommended flow:**
1. Desktop loads game URL → generates room token (UUID or short code) → displays QR + 6-char code
2. Phone scans QR or types code → navigates to controller URL with token in query string
3. Server validates token → creates player slot → broker WebRTC offer/answer/ICE via WebTransport
4. WebRTC data channel opens → phone starts streaming sensor data
5. SDK on desktop emits `playerJoin(playerId)` → game adds player entity

**Edge cases that must work:**
- Phone joins after game has started (late join) — slot created dynamically
- Phone disconnects mid-game — slot held 60s; `playerDisconnect` event
- Phone reconnects — same playerId reclaimed; `playerReconnect` event
- Room full — phone receives "room full" message and shows friendly error
- Invalid/expired code — phone receives clear error, not silent failure

---

## Sensor Permission Lifecycle (detail)

This is a critical UX moment unique to mobile IMU gaming. Handled wrong, orientation never works on iOS.

**Recommended flow:**
1. Phone loads controller page
2. Before requesting permission, show a visible "Enable Motion Controls" button (must be inside user gesture handler)
3. On tap: call `DeviceMotionEvent.requestPermission()` and `DeviceOrientationEvent.requestPermission()`
4. If 'granted': start sensor capture, begin streaming
5. If 'denied': show fallback UI (touch-only mode); SDK emits `{ orientation: null }` until granted
6. On Android / non-iOS 13: no permission prompt needed; begin immediately

**Touch-only fallback:** if motion is denied or unavailable, the platform must still function as a touch controller. Games should check `player.hasMotion` flag.

---

## SDK API Patterns (detail)

**Dual consumption pattern (both must exist):**

```typescript
// Polling — game loop pattern
function animate() {
  requestAnimationFrame(animate);
  const input = platform.getPlayerInput(playerId);
  // input.orientation: Quaternion (smoothed)
  // input.displacement: Vector3 (last gesture window)
  // input.touch: { buttons: Record<string, boolean>, taps: Tap[] }
  // input.latencyMs: number
  // input.hasMotion: boolean
  mesh.quaternion.copy(input.orientation);
}

// Event-driven — reactive pattern
platform.on('imuUpdate', (playerId, data) => {
  // called every packet arrival (~60Hz)
  // data.orientation, data.displacement, data.position
});

platform.on('playerJoin', (playerId) => { /* add entity */ });
platform.on('playerLeave', (playerId) => { /* remove entity */ });
platform.on('playerDisconnect', (playerId) => { /* pause entity */ });
platform.on('playerReconnect', (playerId) => { /* resume entity */ });
```

**Three input layers:**
- `orientation`: Quaternion — drift-free OS-fused + Madgwick; use for head/object rotation
- `displacement`: Vector3 — ZUPT-gated gesture delta; use for throw/swing mechanics
- `position`: Vector3 — dead-reckoning; acknowledged drift; use only with explicit drift-aware design

---

## Security Model (detail)

ImmersiveRT is not a financial system, but basic session isolation is required.

**Required:**
- Room token is a randomly generated, unguessable string (UUID v4 or 128-bit)
- Token is single-use for the join flow (server associates it with a slot, not a permanent resource)
- Server enforces room isolation: data from phone in room A is never forwarded to room B
- No unauthenticated admin endpoints

**Not required for v1:**
- Player authentication (token is anonymous and ephemeral)
- Rate limiting per player (small N, local network focus)
- Encryption beyond TLS (WebRTC data channels are DTLS-encrypted by spec)

---

## Demo Game Requirements

The demo game is the platform's primary marketing asset and integration test.

**What makes a good motion-controller platform demo:**
- Immediate visual response to phone orientation — latency is visible and impressive
- Multiple phones simultaneously, each controlling a distinct object — shows multi-player
- Something physically satisfying: throw, swing, or tilt mechanic — demonstrates displacement
- Latency overlay always visible — shows the platform's core technical claim
- Works in under 30 seconds from "load the page" to "phone is controlling something"

**Recommended demo:** each phone controls a 3D object (cube or sphere) whose rotation mirrors the phone's orientation in real time. When shaken/flicked, object launches in the direction of the gesture displacement. Latency counter in top corner. 30-second time limit → objects reset.

**Anti-patterns for demos:**
- Complex rules that distract from the controller feel
- Requiring calibration before play
- Only showing one phone at a time

---

## Complexity Summary

| Feature Area | Complexity | Phase Implication |
|---|---|---|
| QR + short code join | Low | Phase 1 (foundation) |
| WebRTC signaling via WebTransport | High | Phase 1 (foundation) |
| Sensor permission UI | Medium | Phase 1 (phone client) |
| Orientation stream + Madgwick | High | Phase 2 (sensor pipeline) |
| Binary packet encoding | Low-Medium | Phase 2 (sensor pipeline) |
| Touch event stream | Low | Phase 2 (sensor pipeline) |
| ZUPT + displacement windows | High | Phase 3 (advanced IMU) |
| SDK dual API (polling + events) | Low | Phase 3 (SDK) |
| Interpolation layer in SDK | Medium | Phase 3 (SDK) |
| TypeScript types | Low | Phase 3 (SDK) |
| TURN fallback | Medium | Phase 1 (infrastructure) |
| Reconnection slot-hold | Medium | Phase 4 (resilience) |
| Latency overlay (dev tool) | Medium | Phase 4 (DX) |
| Demo game | Medium | Phase 5 (demo) |

---

## Sources

- [AirConsole Smartphones as Controllers](https://developers.airconsole.com/smartphones-as-controllers) — MEDIUM confidence (official docs)
- [AirConsole Quick Start](https://developers.airconsole.com/quick-start) — MEDIUM confidence (official docs)
- [AirConsole API Reference](https://airconsole.github.io/airconsole-api/) — MEDIUM confidence (official)
- [Jackbox Party Game Design Principles](https://www.builtinchicago.org/articles/jackbox-games-design-party-pack) — MEDIUM confidence (cross-checked)
- [Jackbox.tv Room Code UX](https://explore.st-aug.edu/exp/jackbox-tv-join-explained-how-a-simple-code-unlocks-a-world-of-party-games) — MEDIUM confidence
- [MDN DeviceMotionEvent](https://developer.mozilla.org/en-US/docs/Web/API/DeviceMotionEvent) — HIGH confidence (authoritative)
- [MDN DeviceOrientationEvent](https://developer.mozilla.org/en-US/docs/Web/API/DeviceOrientationEvent) — HIGH confidence (authoritative)
- [MDN WebRTC Data Channels in Games](https://developer.mozilla.org/en-US/docs/Games/Techniques/WebRTC_data_channels) — HIGH confidence (authoritative)
- [WebRTC for the Curious — Debugging](https://webrtcforthecurious.com/docs/09-debugging/) — MEDIUM confidence
- [WebRTC Topology Comparison](https://antmedia.io/webrtc-network-topology/) — MEDIUM confidence
- [WebRTC Reconnection — webrtc.ventures](https://webrtc.ventures/2023/06/implementing-a-reconnection-mechanism-for-webrtc-mobile-applications/) — MEDIUM confidence
- [iOS DeviceMotion Permission](https://dev.to/li/how-to-requestpermission-for-devicemotion-and-deviceorientation-events-in-ios-13-46g2) — MEDIUM confidence
- [Three.js Quaternion SLERP](https://threejs.org/docs/pages/Quaternion.html) — HIGH confidence (official docs)
- [AirConsole QR + Connect Code](https://airconsole.zendesk.com/hc/en-us/articles/360014511400-Connect-Code-QR-Code) — MEDIUM confidence
