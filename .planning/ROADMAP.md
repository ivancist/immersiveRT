# Roadmap: ImmersiveRT

## Overview

ImmersiveRT is built from the network stack outward. Phase 1 and 2 establish the Rust WebTransport server, coturn TURN relay, and Docker Compose deployment — nothing else can be tested without working signaling and a reachable TURN server. Phase 3 wires up room and slot management so phones can pair to desktops. Phase 4 builds the phone client proper: iOS permission gate, Wake Lock, and the WebRTC unreliable data channels that carry the sensor hot path. Phase 5 runs the full on-device sensor pipeline (Madgwick, ZUPT, Kalman) and binary packet encoder. Phase 6 builds the desktop receive side: WebTransport connection, WebRTC peer accept, binary decode, and Three.js slerp. Phase 7 exposes the clean public SDK surface. Phase 8 ships the demo game that proves the full stack at real multi-player conditions.

## Phases

**Phase Numbering:**

- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Server and Transport Foundation** - Rust WebTransport server binary, mkcert TLS for dev, WebSocket signaling fallback, verified end-to-end QUIC connection (completed 2026-07-06)
- [ ] **Phase 2: Signaling, TURN, and Deployment** - WebRTC ICE signaling broker, coturn with host networking, ephemeral TURN credentials, full Docker Compose stack
- [ ] **Phase 3: Session and Pairing** - Room join, QR code + short code pairing, slot assignment, reconnect hold, 2-8 player support, room lifecycle events
- [ ] **Phase 4: Phone Bootstrap and WebRTC Channels** - Phone web app delivery, iOS DeviceMotion permission gate, Wake Lock, heartbeat, unreliable data channels to all desktops
- [ ] **Phase 5: Sensor Fusion and Packet Encoding** - On-device Madgwick, adaptive ZUPT, Kalman dead-reckoning, gesture displacement, touch capture, 40-byte binary packet at 60Hz
- [ ] **Phase 6: Desktop Receive, Decode, and Rendering** - WebTransport desktop connection, WebRTC peer accept from all phones, binary decode, sequence-drop, target-state store, Three.js slerp loop
- [ ] **Phase 7: SDK Public API** - npm package `immersive-rt`, imperative + event APIs, TypeScript types, latency overlay, drift-honest naming, raw orientation opt-in
- [ ] **Phase 8: Demo Game** - Multi-player Three.js scene, orientation-driven objects, gesture-launched flick action, latency overlay always visible

## Phase Details

### Phase 1: Server and Transport Foundation

**Goal**: A Rust binary serves WebTransport connections over QUIC with valid TLS in dev and prod; a WebSocket fallback path handles QUIC-blocked networks; end-to-end connectivity is verified with a latency probe
**Mode:** mvp
**Depends on**: Nothing (first phase)
**Requirements**: INFRA-01, INFRA-05
**Success Criteria** (what must be TRUE):

  1. `cargo run` starts the Rust server and accepts a WebTransport connection from Chrome with a self-signed mkcert cert (no TLS error)
  2. A WebSocket client can connect to the same server on the same port when Chrome's WebTransport is disabled or QUIC is blocked — signaling messages round-trip successfully
  3. A latency probe message sent over WebTransport returns a server-echoed timestamp within 10ms on LAN
  4. The server binary builds and passes `cargo test` with no warnings

**Plans**: 3/3 plans complete

Plans:
**Wave 1**

- [x] 01-01-PLAN.md — Cargo workspace scaffold, echo module, clean build baseline

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 01-02-PLAN.md — WebTransport listener (wtransport + mkcert TLS) + latency echo probe

**Wave 3** *(blocked on Wave 2 completion)*

- [x] 01-03-PLAN.md — WebSocket fallback listener + integration test + full workspace gate

### Phase 2: Signaling, TURN, and Deployment

**Goal**: The server brokers a full WebRTC offer/answer/ICE exchange between a phone and desktop; coturn provides STUN/TURN reachability validated with `turnutils_uclient`; the entire stack ships in a single `docker compose up`
**Mode:** mvp
**Depends on**: Phase 1
**Requirements**: INFRA-02, INFRA-03, INFRA-04, INFRA-06, INFRA-07
**Success Criteria** (what must be TRUE):

  1. A phone and desktop complete a WebRTC ICE handshake brokered through the Rust server — an unreliable data channel opens between them
  2. `turnutils_uclient -u test -w test <server>:3478` succeeds — STUN binding and TURN allocation both pass
  3. `docker compose up` brings up three containers (Rust server, coturn, static file server) from a cold start with no manual steps
  4. A TURN credential request to the server endpoint returns ephemeral username+password that coturn accepts — credentials are generated at connection-start, not cached from page load
  5. A phone behind symmetric NAT (simulated with coturn relay-only mode) still establishes a data channel to the desktop via TURN relay

**Plans**: TBD

### Phase 3: Session and Pairing

**Goal**: A desktop player can join a named room, display a QR code and short code for their slot, and a phone can scan or type to pair exclusively to that desktop; the server holds the slot on disconnect and emits room lifecycle events
**Mode:** mvp
**Depends on**: Phase 2
**Requirements**: SESS-01, SESS-02, SESS-03, SESS-04, SESS-05, SESS-06
**Success Criteria** (what must be TRUE):

  1. A desktop enters a username, the server assigns a named slot and room code visible on screen
  2. A phone scans the desktop QR code (or enters the short code) and pairs exclusively to that slot — a second phone attempting the same code is rejected until the first disconnects
  3. Up to 8 desktops join the same room simultaneously; each sees a distinct QR/short code; a 9th join attempt is rejected
  4. Disconnecting a phone and reconnecting within 60 seconds reclaims the same slot and playerId without re-entering the code
  5. Room lifecycle events (player joined, left, reconnected, room full) are observable on the desktop — at minimum logged to console or shown in a debug overlay

**Plans**: TBD

### Phase 4: Phone Bootstrap and WebRTC Channels

**Goal**: The phone web app loads from a QR-scan URL with no install; iOS users see a "Grant Motion Access" button before any sensor code runs; Wake Lock prevents screen sleep; the phone maintains heartbeats and opens an unreliable WebRTC data channel to every desktop in the room
**Mode:** mvp
**Depends on**: Phase 3
**Requirements**: PHONE-01, PHONE-02, PHONE-03, PHONE-06, PHONE-07
**Success Criteria** (what must be TRUE):

  1. Scanning the QR code on an iPhone 15 and an Android Chrome device both load the phone web app with no app install prompt
  2. On iOS 13+, tapping "Grant Motion Access" triggers the `DeviceMotionEvent.requestPermission` prompt — sensor events are gated until the user approves (no sensor code executes before the button tap)
  3. The phone screen stays on during an active session — Wake Lock API is active and the screen does not auto-lock after 30 seconds
  4. A phone connected to a 3-desktop room opens three independent unreliable WebRTC data channels (`ordered: false, maxRetransmits: 0`), one per desktop — verified by `RTCPeerConnection.connectionState === 'connected'` for each
  5. After 5 seconds of silence, the server receives a heartbeat; if the phone tab is backgrounded and the heartbeat stops, the server marks the slot as disconnected (not permanently evicted) within 65 seconds

**Plans**: TBD
**UI hint**: yes

### Phase 5: Sensor Fusion and Packet Encoding

**Goal**: The phone runs a full on-device sensor pipeline — Madgwick quaternion fusion, adaptive ZUPT dead-reckoning reset, Kalman position estimate — and encodes every output at the maximum device sample rate into a 40-byte binary MessagePack packet transmitted over the unreliable data channel
**Mode:** mvp
**Depends on**: Phase 4
**Requirements**: SENS-01, SENS-02, SENS-03, SENS-04, SENS-05, SENS-06, PHONE-04, PHONE-05
**Success Criteria** (what must be TRUE):

  1. Rotating the phone 360° on each axis produces a smooth, drift-free quaternion stream — the returned object after slow rotation stops differs from the pre-rotation value by less than 5 degrees of yaw error after 30 seconds
  2. Holding the phone stationary for 300ms triggers a ZUPT reset — `driftConfidence` rises toward 1.0 and `deadReckoningPosition` stabilizes rather than continuing to drift
  3. A single flick gesture produces a non-zero `gestureDisplacement` vector that resets to near-zero after the gesture window closes — without false-triggering on held-still periods
  4. Touch events (tap, button states) appear in every sensor packet alongside orientation and position data
  5. Each sensor packet is <= 45 bytes on the wire (verified with a byte-count logger), sent at >= 55Hz on a mid-range Android device — sequence numbers increment monotonically

**Plans**: TBD

### Phase 6: Desktop Receive, Decode, and Rendering

**Goal**: The desktop connects to the server via WebTransport, accepts WebRTC data channels from all phones in the room, decodes binary packets with out-of-order dropping, maintains a per-player target-state store, and applies SLERP interpolation to orientation quaternions in the Three.js render loop
**Mode:** mvp
**Depends on**: Phase 5
**Requirements**: DESK-01, DESK-02, DESK-03, DESK-04, DESK-05
**Success Criteria** (what must be TRUE):

  1. The desktop page loads and establishes a persistent WebTransport connection to the Rust server — browser DevTools shows an active HTTP/3 session
  2. A phone connecting to the room causes the desktop to open a WebRTC data channel to that phone — no server relay of sensor packets occurs after the channel is established
  3. Out-of-order packets from a phone are silently dropped — a logged sequence-number comparison per sender shows no backward jumps applied to the target-state store
  4. A Three.js cube rotates smoothly following phone orientation with no visible jitter — the render loop reads from the target-state store and applies SLERP at the configured alpha (default 0.3)
  5. Two phones in the same room each drive a distinct Three.js object — both objects move simultaneously and independently on the same desktop

**Plans**: TBD
**UI hint**: yes

### Phase 7: SDK Public API

**Goal**: The `immersive-rt` npm package exposes a clean imperative + event-driven API with TypeScript types, a developer latency overlay, drift-honest naming, and a raw orientation opt-in — ready for a third-party developer to integrate without reading source code
**Mode:** mvp
**Depends on**: Phase 6
**Requirements**: SDK-01, SDK-02, SDK-03, SDK-04, SDK-05, SDK-06
**Success Criteria** (what must be TRUE):

  1. `npm install immersive-rt` installs the package; TypeScript `tsc --strict` compiles a game that calls `platform.getPlayerInput(id)` and `platform.on('imuUpdate', cb)` with no type errors
  2. `platform.getPlayerInput(playerId)` returns `{ orientation, gestureDisplacement, deadReckoningPosition, driftConfidence, touch }` — the return shape matches the TypeScript type exactly
  3. `platform.on('playerJoin', id => ...)`, `platform.on('playerLeave', ...)`, and `platform.on('playerReconnect', ...)` all fire at the correct lifecycle moments during a live session
  4. Adding the latency overlay (single-line include) renders rolling avg latency, jitter, packet loss %, and ICE state per player on the desktop without any additional configuration
  5. `platform.getRawInput(playerId).orientationRaw` returns the unsmoothed quaternion — a game that applies its own SLERP can bypass the SDK's interpolation
  6. The public API surface uses `deadReckoningPosition` (not `position`) and `driftConfidence` — no API surface leaks the word "position" without the drift qualifier

**Plans**: TBD

### Phase 8: Demo Game

**Goal**: A multi-player Three.js demo scene where 2-8 phones each drive a distinct 3D object with orientation, a gesture-triggered flick action uses `gestureDisplacement`, and a latency overlay is always visible — proving the full SDK under real conditions
**Mode:** mvp
**Depends on**: Phase 7
**Requirements**: DEMO-01, DEMO-02, DEMO-03, DEMO-04
**Success Criteria** (what must be TRUE):

  1. Loading the demo URL and scanning two QR codes with two phones causes two distinct 3D objects to appear and rotate in real time on the desktop — each phone controls only its own object
  2. A flick or shake gesture on a phone visibly launches that player's 3D object across the scene — the launch vector matches the direction of the `gestureDisplacement` vector
  3. All objects on all desktops in the same room move in sync — a second desktop in the same room sees the same object positions as the first
  4. The latency overlay is always visible during the demo and shows phone-to-render timestamp delta, rolling average latency, and packet loss % — numbers update in real time as packets arrive

**Plans**: TBD
**UI hint**: yes

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Server and Transport Foundation | 3/3 | Complete    | 2026-07-06 |
| 2. Signaling, TURN, and Deployment | 0/TBD | Not started | - |
| 3. Session and Pairing | 0/TBD | Not started | - |
| 4. Phone Bootstrap and WebRTC Channels | 0/TBD | Not started | - |
| 5. Sensor Fusion and Packet Encoding | 0/TBD | Not started | - |
| 6. Desktop Receive, Decode, and Rendering | 0/TBD | Not started | - |
| 7. SDK Public API | 0/TBD | Not started | - |
| 8. Demo Game | 0/TBD | Not started | - |
