# Requirements: ImmersiveRT

**Defined:** 2026-07-06
**Core Value:** Phone motion feels physically immediate on screen — sub-20ms sensor delivery from phone to desktop, lowest possible latency.

## v1 Requirements

### Infrastructure

- [x] **INFRA-01**: Server runs as a single Rust binary (wtransport + tokio) handling WebTransport connections from both phones and desktops
- [ ] **INFRA-02**: Server brokers WebRTC signaling (offer/answer/ICE) between phone and its paired desktop
- [ ] **INFRA-03**: Server brokers WebRTC signaling between desktop and all other desktops in the same room
- [ ] **INFRA-04**: Server provides a TURN credential endpoint that generates ephemeral credentials at connection-start (not page load)
- [x] **INFRA-05**: Server provides a WebSocket signaling fallback path for networks where QUIC/UDP is blocked
- [ ] **INFRA-06**: coturn STUN/TURN server runs in Docker with `network_mode: host` and `external-ip` configured
- [ ] **INFRA-07**: Full stack deployable with a single `docker compose up` (Rust server + coturn + static file server)

### Session

- [ ] **SESS-01**: Desktop player can join a room by entering a username — server assigns a named slot and a room code
- [ ] **SESS-02**: Desktop shows a QR code unique to its player slot — phone scans to pair exclusively to that desktop
- [ ] **SESS-03**: Desktop shows a short alphanumeric code as fallback for phones that cannot scan QR
- [ ] **SESS-04**: Server holds a player's slot for 60 seconds after disconnect — phone or desktop can reclaim the same slot on reconnect
- [ ] **SESS-05**: Room supports 2–8 desktop players simultaneously
- [ ] **SESS-06**: Server emits room lifecycle events: player joined, player left, player reconnected, room full

### Phone Client

- [ ] **PHONE-01**: Phone web app is accessible via QR scan with no app install required
- [ ] **PHONE-02**: Phone shows a "Grant Motion Access" button as first interaction on iOS 13+ (required user gesture before DeviceMotionEvent permission prompt)
- [ ] **PHONE-03**: Phone establishes WebRTC P2P unreliable data channels to ALL desktops in the room — one to its paired desktop (primary) and one to each other player's desktop — so every desktop receives sensor data directly without relay
- [ ] **PHONE-04**: Phone sends sensor packets at the maximum available device rate (~60–100Hz) over the unreliable data channel
- [ ] **PHONE-05**: Phone encodes each sensor packet as compact binary (~40 bytes) using MessagePack — includes sequence number, timestamp, orientation quaternion, gesture displacement, dead-reckoning position, touch events, drift confidence
- [ ] **PHONE-06**: Phone sends a heartbeat every 5 seconds to prevent slot eviction and detect connection loss
- [ ] **PHONE-07**: Phone activates Wake Lock API to prevent screen lock from killing the sensor stream

### Sensor Fusion (on-device)

- [ ] **SENS-01**: Phone runs Madgwick filter on-device to produce a stable orientation quaternion from gyroscope + accelerometer + magnetometer — drift-free
- [ ] **SENS-02**: Madgwick beta parameter is runtime-configurable; defaults to 0.1, ramps to 0.2–0.3 at cold start and ramps back down after convergence
- [ ] **SENS-03**: Phone runs ZUPT (Zero-Velocity Update) with adaptive variance + 300ms duration threshold — detects stationary moments and resets velocity accumulator to kill drift
- [ ] **SENS-04**: Phone runs Kalman filter over linear acceleration to produce a dead-reckoning position estimate with a `driftConfidence` scalar (0–1)
- [ ] **SENS-05**: Gesture displacement: ZUPT gates a per-action position delta window — each swing/throw/flick produces a discrete `gestureDisplacement` vector reset between actions
- [ ] **SENS-06**: Touch input: phone captures tap events and configurable on-screen button states, included in each sensor packet

### Desktop Client

- [ ] **DESK-01**: Desktop connects to the server via WebTransport (persistent connection for signaling and game state)
- [ ] **DESK-02**: Desktop establishes a WebRTC P2P unreliable data channel to its paired phone (primary sensor input) and accepts WebRTC connections from all other players' phones (cross-player sensor input) — no desktop-to-desktop relay
- [ ] **DESK-03**: Desktop decodes incoming binary sensor packets from all connected phones, drops out-of-order packets via uint16 sequence number comparison per-sender
- [ ] **DESK-04**: Desktop maintains a per-player target-state store (latest orientation, gestureDisplacement, deadReckoningPosition, touch) updated on every packet receipt
- [ ] **DESK-05**: Desktop applies SLERP interpolation on orientation quaternions in the Three.js render loop (default alpha 0.2–0.4, configurable)

### SDK

- [ ] **SDK-01**: npm package `immersive-rt` published with TypeScript types for all public surfaces
- [ ] **SDK-02**: Imperative API: `platform.getPlayerInput(playerId)` returns `{ orientation: Quaternion, gestureDisplacement: Vector3, deadReckoningPosition: Vector3, driftConfidence: number, touch: TouchState }`
- [ ] **SDK-03**: Event API: `platform.on('imuUpdate', (playerId, data) => ...)`, `platform.on('playerJoin', id => ...)`, `platform.on('playerLeave', id => ...)`, `platform.on('playerReconnect', id => ...)`
- [ ] **SDK-04**: Developer latency overlay: single-line include renders rolling avg latency, jitter, packet loss %, ICE state per player — visible on desktop
- [ ] **SDK-05**: SDK exposes `deadReckoningPosition` (not `position`) with `driftConfidence` scalar — naming makes drift nature explicit to game developers
- [ ] **SDK-06**: Raw orientation quaternion available via `platform.getRawInput(playerId).orientationRaw` (no slerp) for games that manage their own interpolation

### Demo Game

- [ ] **DEMO-01**: Demo Three.js scene where each connected phone's orientation quaternion rotates a distinct 3D object assigned to that player
- [ ] **DEMO-02**: Demo supports 2+ simultaneous players — all objects visible to all desktops moving in sync
- [ ] **DEMO-03**: Demo includes gesture-triggered action: flick/shake of phone launches the player's object (uses `gestureDisplacement`)
- [ ] **DEMO-04**: Demo shows latency overlay: phone-timestamp → desktop-render-timestamp delta, rolling average, packet loss

## v2 Requirements

### Advanced Sensor

- **SENS-V2-01**: Complementary filter option as alternative to Madgwick (simpler, lower CPU cost for low-end phones)
- **SENS-V2-02**: Magnetometer hard-iron calibration routine (phone held still, rotated 360°) for improved absolute heading
- **SENS-V2-03**: Visual-Inertial Odometry (VIO) using phone camera — room-scale position tracking (requires camera permission, high CPU cost)

### Session

- **SESS-V2-01**: Spectator mode: desktop joins as observer only (no phone required)
- **SESS-V2-02**: Room password protection
- **SESS-V2-03**: Session persistence across page reload (rejoin by URL token)

### Network

- **NET-V2-01**: Selective forwarding: game developer controls which players receive which player's state (reduces bandwidth for large rooms)
- **NET-V2-02**: Server-side relay fallback for desktop↔desktop data (when P2P mesh fails for >2 players)

### SDK

- **SDK-V2-01**: Gamepad API mapping: expose phone IMU as a virtual gamepad for compatibility with gamepad-aware Three.js games
- **SDK-V2-02**: SDK plugin system for custom sensor fusion algorithms

## Out of Scope

| Feature | Reason |
|---------|--------|
| Room-scale absolute position tracking | Requires camera + VIO — impossible from browser IMU alone; would drift and destroy trust |
| Native iOS / Android app | Browser Device Motion API covers this use case; no app install is core platform value |
| Server-side game logic / authoritative state | Platform is a transport layer only; game owns its rules |
| Audio / video streaming | Wrong cost profile for TURN relay; out of platform scope |
| SFU / MCU topology | Phone only connects to own desktop; desktop mesh handles cross-player relay — SFU adds unnecessary complexity |
| Persistent accounts / matchmaking / leaderboards | Pure session-based for v1 |
| Virtual joystick / D-pad UI on phone | Platform provides real IMU data; game adds custom UI if needed |
| WebRTC audio / video data channels | Data-only platform; no media tracks |

## Traceability

*Populated during roadmap creation — 2026-07-06*

| Requirement | Phase | Status |
|-------------|-------|--------|
| INFRA-01 | Phase 1 | Complete |
| INFRA-05 | Phase 1 | Complete |
| INFRA-02 | Phase 2 | Pending |
| INFRA-03 | Phase 2 | Pending |
| INFRA-04 | Phase 2 | Pending |
| INFRA-06 | Phase 2 | Pending |
| INFRA-07 | Phase 2 | Pending |
| SESS-01 | Phase 3 | Pending |
| SESS-02 | Phase 3 | Pending |
| SESS-03 | Phase 3 | Pending |
| SESS-04 | Phase 3 | Pending |
| SESS-05 | Phase 3 | Pending |
| SESS-06 | Phase 3 | Pending |
| PHONE-01 | Phase 4 | Pending |
| PHONE-02 | Phase 4 | Pending |
| PHONE-03 | Phase 4 | Pending |
| PHONE-06 | Phase 4 | Pending |
| PHONE-07 | Phase 4 | Pending |
| SENS-01 | Phase 5 | Pending |
| SENS-02 | Phase 5 | Pending |
| SENS-03 | Phase 5 | Pending |
| SENS-04 | Phase 5 | Pending |
| SENS-05 | Phase 5 | Pending |
| SENS-06 | Phase 5 | Pending |
| PHONE-04 | Phase 5 | Pending |
| PHONE-05 | Phase 5 | Pending |
| DESK-01 | Phase 6 | Pending |
| DESK-02 | Phase 6 | Pending |
| DESK-03 | Phase 6 | Pending |
| DESK-04 | Phase 6 | Pending |
| DESK-05 | Phase 6 | Pending |
| SDK-01 | Phase 7 | Pending |
| SDK-02 | Phase 7 | Pending |
| SDK-03 | Phase 7 | Pending |
| SDK-04 | Phase 7 | Pending |
| SDK-05 | Phase 7 | Pending |
| SDK-06 | Phase 7 | Pending |
| DEMO-01 | Phase 8 | Pending |
| DEMO-02 | Phase 8 | Pending |
| DEMO-03 | Phase 8 | Pending |
| DEMO-04 | Phase 8 | Pending |

**Coverage:**

- v1 requirements: 41 total
- Mapped to phases: 41
- Unmapped: 0

---
*Requirements defined: 2026-07-06*
*Last updated: 2026-07-06 — traceability populated after roadmap creation*
