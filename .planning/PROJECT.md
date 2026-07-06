# ImmersiveRT

## What This Is

A real-time web platform and SDK for building Three.js browser games where players use their mobile phones as motion controllers. The desktop renders the 3D game world while the phone streams IMU sensor data (orientation + position) via WebRTC unreliable data channels directly to the desktop and other players. A WebTransport server handles signaling, session management, and relaying; coturn provides TURN for NAT traversal.

## Core Value

Phone motion feels physically immediate on screen — sub-20ms sensor delivery from phone to desktop, on the same local network and as fast as physically possible across the internet.

## Requirements

### Validated

(None yet — ship to validate)

### Active

**Server Infrastructure**
- [ ] WebTransport server (Rust + `wtransport`) for signaling, session relay, and game state broadcasting
- [ ] TURN/STUN server (coturn) for NAT traversal when direct P2P is blocked
- [ ] Session management: pairing a phone to a desktop slot within a game room
- [ ] WebRTC peer handshake brokered by the server (offer/answer/ICE exchange)
- [ ] Docker Compose deployment (WebTransport server + coturn + static file server)

**Phone Client (Mobile Web App)**
- [ ] Read `DeviceOrientationEvent` + `DeviceMotionEvent` at maximum available rate (~60–100Hz)
- [ ] On-device Madgwick filter → stable quaternion orientation (no drift)
- [ ] On-device ZUPT + Kalman filter → drift-corrected dead-reckoning position
- [ ] Touch input capture: tap, swipe, configurable on-screen buttons
- [ ] WebRTC unreliable data channel (ordered=false, maxRetransmits=0) to desktop peer
- [ ] WebRTC unreliable data channel broadcasting sensor data to other players' desktops
- [ ] Sensor packet encoding: compact binary (MessagePack or flatbuffers) for minimal wire size

**Desktop Client (Three.js Game Host)**
- [ ] Three.js rendering loop consuming player input streams from WebRTC data channels
- [ ] Receive and apply orientation (quaternion) from each connected phone
- [ ] Receive and apply gesture displacement + dead-reckoning position from each phone
- [ ] Receive touch events from phone
- [ ] Interpolation/prediction layer to smooth packet jitter in rendering

**Developer SDK**
- [ ] npm package `immersive-rt` with both imperative and event-driven API
- [ ] Imperative: `platform.getPlayerInput(playerId)` → `{ orientation, position, displacement, touch }`
- [ ] Events: `platform.on('imuUpdate', (playerId, data) => ...)`, `platform.on('playerJoin', id => ...)`
- [ ] SDK exposes three position layers: orientation (quaternion), gesture displacement (per-action window), raw dead-reckoning (with acknowledged drift)
- [ ] TypeScript types throughout

**Demo Game**
- [ ] Minimal Three.js demo: each connected phone's orientation rotates a 3D object on screen
- [ ] Demonstrates multi-player: multiple phones, each controlling a distinct object
- [ ] Latency display overlay (phone timestamp → render timestamp delta)

### Out of Scope

- Room-scale absolute position (requires camera + VIO — not possible in browser IMU alone)
- Native mobile apps (iOS/Android) — browser Device Motion API covers this use case
- Game engines other than Three.js — platform targets Three.js specifically for v1
- Server-side game logic / authoritative game state — platform is a transport layer; games own their logic
- Persistent accounts, matchmaking, leaderboards — pure session-based for v1

## Context

**Transport choices:**
- WebTransport (QUIC/HTTP3) eliminates head-of-line blocking present in WebSocket/TCP — critical for high-frequency sensor streams where stale packets are worse than dropped ones
- WebRTC unreliable data channel gives UDP semantics inside the browser sandbox — the only way to send fire-and-forget packets in a browser
- Combining both: WebTransport for server ↔ client control/signaling, WebRTC for peer ↔ peer sensor hot path

**IMU position tracking reality:**
- `DeviceOrientationEvent` (OS-fused): excellent, drift-free, use for orientation
- `DeviceMotionEvent` linear acceleration: useful but noisy; double-integration drifts quadratically
- Madgwick filter on-device corrects gyro drift using accelerometer + magnetometer feedback
- ZUPT (Zero-Velocity Update): phone momentarily stationary → velocity reset → kills accumulated drift
- Kalman filter wraps ZUPT events into a probabilistic state estimate
- Gesture displacement windows (arm swing, throw trajectory) are reliable; sustained room-scale position is not

**Server language rationale:**
- Rust selected for WebTransport server: `tokio` async runtime + `wtransport` crate, minimal syscall overhead, zero-cost abstractions — lowest achievable latency for the sensor relay path
- coturn for TURN: battle-tested C, Docker-friendly, standard STUN/TURN protocol
- TypeScript for SDK + client: ecosystem fit, Three.js native, no transpile overhead at runtime

**Network topology:**
- Best case: phone ↔ desktop on same LAN via WebRTC direct P2P (sub-5ms possible)
- Fallback: TURN relay when NAT blocks direct connection
- Other players: phone → TURN/server → other desktops (or partial mesh if ports open)

## Constraints

- **Browser API**: Device Motion API capped at ~60–100Hz depending on device/OS — sensor rate ceiling
- **WebTransport TLS**: Requires HTTPS even in development (self-signed cert or mkcert for local dev)
- **QUIC firewall**: Some networks block UDP; need WebSocket fallback path for WebTransport
- **TURN costs**: Relaying video/audio would be expensive; relaying small IMU packets is cheap — scope TURN to data channels only
- **IMU drift**: Position tracking is best-effort; games must design interactions around drift-reset moments
- **Mobile browser permissions**: Device Motion requires explicit user gesture on iOS 13+ (permission prompt)

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Rust for WebTransport server | Lowest latency for hot path, `wtransport` crate mature, tokio handles async I/O without GC pauses | — Pending |
| WebRTC unreliable data channel for IMU | Only UDP-like transport available in browser; drop stale sensor packets rather than queue them | — Pending |
| On-device Madgwick filter | Orientation fusion on phone reduces server processing, cuts one round-trip from the critical path | — Pending |
| coturn for TURN | De-facto standard, RFC 5766 compliant, Docker image available, well-understood operationally | — Pending |
| Binary sensor encoding (MessagePack) | JSON overhead at 60Hz × N players is significant; compact binary cuts packet size ~4× | — Pending |
| TypeScript SDK | Three.js ecosystem is TypeScript-first; type safety prevents misuse of orientation vs position data | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-07-06 after initialization*
