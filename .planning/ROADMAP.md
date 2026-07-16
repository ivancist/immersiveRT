# Roadmap: ImmersiveRT

## Overview

ImmersiveRT is built from the network stack outward. Phase 1 and 2 establish the Rust WebTransport server, coturn TURN relay, and Docker Compose deployment — nothing else can be tested without working signaling and a reachable TURN server. Phase 3 wires up room and slot management so phones can pair to desktops. Phase 4 builds the phone client proper: iOS permission gate, Wake Lock, and the WebRTC unreliable data channels that carry the sensor hot path. Phase 5 runs the full on-device sensor pipeline (Madgwick, ZUPT, Kalman) and binary packet encoder. Phase 6 builds the desktop receive side: WebTransport connection, WebRTC peer accept, binary decode, and Three.js slerp. Phase 7 exposes the clean public SDK surface. Phase 8 ships the demo game that proves the full stack at real multi-player conditions.

## Phases

**Phase Numbering:**

- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Server and Transport Foundation** - Rust WebTransport server binary, mkcert TLS for dev, WebSocket signaling fallback, verified end-to-end QUIC connection (completed 2026-07-06)
- [x] **Phase 2: Signaling, TURN, and Deployment** - WebRTC ICE signaling broker, coturn with host networking, ephemeral TURN credentials, full Docker Compose stack (completed 2026-07-07)
- [x] **Phase 3: Session and Pairing** - Room join, QR code + short code pairing, slot assignment, reconnect hold, 2-8 player support, room lifecycle events (completed 2026-07-07)
- [ ] **Phase 4: Phone Bootstrap and WebRTC Channels** - Phone web app delivery, iOS DeviceMotion permission gate, Wake Lock, heartbeat, unreliable data channels to all desktops
- [x] **Phase 5: Sensor Fusion and Packet Encoding** - On-device Madgwick, adaptive ZUPT, Kalman dead-reckoning, gesture displacement, touch capture, 36-byte binary DataView packet at 60Hz (completed 2026-07-09)
- [x] **Phase 6: Desktop Receive, Decode, and Rendering** - WebTransport desktop connection, WebRTC peer accept from all phones, binary decode, sequence-drop, target-state store, Three.js slerp loop (completed 2026-07-10)
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

**Plans**: 4/5 plans executed

Plans:
**Wave 1**

- [x] 02-01-PLAN.md — Cargo.toml + broker.rs + signaling.rs + turn_creds.rs (core relay modules, Wave 1)

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 02-02-PLAN.md — wt_server + ws_server + main.rs signaling relay activation (Wave 2)
- [x] 02-03-PLAN.md — Docker deployment: Dockerfile, turnserver.conf, docker-compose.yml (Wave 2)

**Wave 3** *(blocked on Wave 2 completion)*

- [x] 02-04-PLAN.md — TURN credential HTTP endpoint via axum on HTTP_PORT (Wave 3)

**Wave 4** *(blocked on Wave 3 completion)*

- [ ] 02-05-PLAN.md — Full workspace gate + manual validation checkpoint (Wave 4)

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

**Plans**: 3/4 plans executed

Plans:
**Wave 1** *(parallel)*

- [x] 03-01-PLAN.md — Package slopcheck + pairing_token.rs (HMAC token engine) + room_registry.rs (slot/hold-timer/lifecycle state)
- [x] 03-03-PLAN.md — docker/nginx/nginx.conf (HTTPS + SPA routing) + docker-compose.yml nginx update

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 03-02-PLAN.md — signaling.rs payload types + ws_server/wt_server join-room dispatch + main.rs env vars + Arc<RoomRegistry> injection

**Wave 3** *(blocked on Wave 2 completion)*

- [x] 03-04-PLAN.md — client/dist/index.html + room.js (lobby, room page, phone landing SPA) + human verification checkpoint

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

**Plans**: 1/3 plans executed
**UI hint**: yes

Plans:
**Wave 1**

- [x] 04-01-PLAN.md — Phone bootstrap slice: phone.html six-view shell + nginx /phone serving, iOS permission gate + WebTransport pair, enhanced pair-ack (peers[] + ice_servers) and SlotInfo.phone_client_id (PHONE-01, PHONE-02)

**Wave 2** *(blocked on Wave 1 completion)*

- [ ] 04-02-PLAN.md — WebRTC connection slice: phone fan-out of unreliable channels to all desktops, both-sides channel-readiness + player-ready broadcast, minimal desktop answerer (PHONE-03)

**Wave 3** *(blocked on Wave 2 completion)*

- [ ] 04-03-PLAN.md — Session durability slice: heartbeat + background miss monitor, Wake Lock + self-heal, phone-state relay, dynamic peer-joined/peer-left mesh (PHONE-06, PHONE-07)

### Phase 5: Sensor Fusion and Packet Encoding

**Goal**: The phone runs a full on-device sensor pipeline — Madgwick quaternion fusion, adaptive ZUPT dead-reckoning reset, Kalman position estimate — and encodes every output at the maximum device sample rate into a 36-byte binary DataView packet (schema v1) transmitted over the unreliable data channel
**Depends on**: Phase 4
**Requirements**: SENS-01, SENS-02, SENS-03, SENS-04, SENS-05, SENS-06, PHONE-04, PHONE-05
**Success Criteria** (what must be TRUE):

  1. Rotating the phone 360° on each axis produces a smooth, drift-free quaternion stream — the returned object after slow rotation stops differs from the pre-rotation value by less than 5 degrees of yaw error after 30 seconds
  2. Holding the phone stationary for 300ms triggers a ZUPT reset — `driftConfidence` rises toward 1.0 and `deadReckoningPosition` stabilizes rather than continuing to drift
  3. A single flick gesture produces a non-zero `gestureDisplacement` vector that resets to near-zero after the gesture window closes — without false-triggering on held-still periods
  4. Touch events (tap, button states) appear in every sensor packet alongside orientation and position data
  5. Each sensor packet is <= 45 bytes on the wire (verified with a byte-count logger), sent at >= 55Hz on a mid-range Android device — sequence numbers increment monotonically

**Plans**: 7/7 plans complete

- [x] 05-01-PLAN.md
- [x] 05-02-PLAN.md
- [x] 05-03-PLAN.md
- [x] 05-04-PLAN.md
- [x] 05-05-PLAN.md
- [x] 05-06-PLAN.md
- [x] 05-07-PLAN.md

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

**Plans**: 5/5 plans complete
**UI hint**: yes

Plans:
**Wave 1** *(parallel)*

- [x] 06-01-PLAN.md — WebTransport migration in room.ts (WT-first dual-path, WS fallback) (DESK-01)
- [x] 06-02-PLAN.md — decode.ts + playerStore.ts: binary decode, uint16 seq-drop, finite-guard, per-player target-state store, test-first (DESK-03, DESK-04)

**Wave 2** *(blocked on Wave 1)*

- [x] 06-03-PLAN.md — Three.js install (legitimacy gate) + game DOM/CSS shell + empty scene activates on first player-ready (DESK-05)

**Wave 3** *(blocked on Wave 2)*

- [x] 06-04-PLAN.md — Per-player boxes + SLERP + receive wiring → phone motion rotates its cube; two phones two cubes (DESK-02, DESK-05)

**Wave 4** *(blocked on Wave 3)*

- [x] 06-05-PLAN.md — Precision-eval instrumentation: keyboard toggles, persistent HUD, TAB roster, numeric HUD, touch flash, motion trail (DESK-05)

### Phase 06.1: Camera-Assisted Spatial Tracking (INSERTED)

**Goal:** Replace/augment IMU-only position dead-reckoning — which cannot be tuned to usable accuracy (see resolved debug session `.planning/debug/huge-position-drift-makes-pho.md`) — with camera-assisted 6DOF position tracking. Android: WebXR `immersive-ar` (ARCore) via three.js r185, opaque-layer trick to skip passthrough rendering, position-only at ~30fps, keep existing `DeviceOrientationEvent` for orientation. iOS: Safari has no native WebXR AR (confirmed dead end) — needs a research spike into a third-party visual-inertial/SLAM library (e.g. 8th Wall's Distributed Engine Binary post-Niantic-shutdown licensing, or alternatives), since MindAR/AR.js are marker-tracking only, not free-space 6DOF. Escape hatch: if browser-based camera tracking drains battery/heat too much on either platform, fall back to a native companion app (iOS native ARKit, Android native ARCore) instead of browser-based tracking.
**Requirements**: SENS-V2-03, SENS-03, SENS-04, SENS-05, SDK-05
**Depends on:** Phase 6
**Plans:** 3/4 plans executed

Plans:
**Wave 1** *(parallel)*

- [x] 06.1-01-PLAN.md — WebXR pure module (webxr.d.ts ambient types + webxr.ts: support detect, driftConfidence map D-02, rolling gesture D-03, freeze-on-lost) + webxr.test.ts (SENS-V2-03, SDK-05)
- [x] 06.1-02-PLAN.md — encode.test.ts camera-sourced position regression guard (Pitfall 4 / V5, D-01) + fallback suite green (SENS-03, SENS-04)

**Wave 2** *(blocked on 06.1-01)*

- [x] 06.1-03-PLAN.md — phone.ts WebXR branch integration + phone.html tracking-mode badge (D-05 badge, D-06 branch lock, D-02/D-03 wiring, D-04 fallback preserved) (SENS-V2-03, SENS-05, SENS-03, SENS-04, SDK-05)

**Wave 3** *(blocked on 06.1-03)*

- [ ] 06.1-04-PLAN.md — On-device manual verification checkpoint: ARCore drift resolution, freeze-on-loss (D-06), badge/fallback, battery/thermal escape-hatch (SENS-V2-03)

### Phase 06.2: iOS Native Client — Transport Parity (INSERTED)

**Goal:** Reimplement the phone client's transport stack natively in Swift (`mobile/ios-app/immersiveRT`, which already has QR scan + pairing-token extraction via QRScannerView.swift/QRTokenParser.swift): WebTransport signaling connection, join-room/pairing flow, WebRTC unreliable data channel fan-out to all desktops in the room, heartbeat, and the 36-byte binary sensor packet schema v1 (Phase 5). Orientation is sourced from CoreMotion's OS-fused device-motion attitude quaternion (mirroring the web client's `DeviceOrientationEvent` — no Madgwick pass, no ARKit yet); position stays at parity with the web client's Kalman dead-reckoning output. This phase proves the native app reaches feature parity with the browser phone client before ARKit tracking is layered on in Phase 06.3.
**Requirements**: PHONE-03, PHONE-04, PHONE-05, PHONE-06, PHONE-07 (native re-implementation; PHONE-01 stays web-only — N/A for native; SENS-01..05 deferred to 06.3 per D-01; SENS-06 optional scope-fill)
**Depends on:** Phase 6 (desktop decode/render pipeline)
**Plans:** 9/9 plans complete

Plans:
**Wave 1**

- [x] 06.2-01-PLAN.md — XCTest target + SignalingEnvelope + SignalingTransport protocol (foundation)

**Wave 2** *(blocked on 06.2-01)*

- [x] 06.2-02-PLAN.md — Byte-identical SensorPacketEncoder + fixture + QRTokenParser host extraction (PHONE-05, D-09)
- [x] 06.2-03-PLAN.md — CoreMotionSource (real OS-fused orientation) + HeartbeatTimer (PHONE-04, PHONE-06, D-09)
- [x] 06.2-04-PLAN.md — WebSocketSignaling fallback transport (PHONE-03, PHONE-06, D-05)
- [x] 06.2-05-PLAN.md — WebTransport-over-HTTP/3 spike: Http3Framing + WebTransportSignaling (PHONE-03, D-04, D-05)
- [x] 06.2-06-PLAN.md — WebRTC dep (legitimacy checkpoint) + PeerConnectionManager fan-out + ICEConfig (PHONE-03)

**Wave 3** *(blocked on 06.2-01/03/04/05/06)*

- [x] 06.2-07-PLAN.md — TransportManager dual-path connect + pair + fan-out + reconnect loop (PHONE-03, PHONE-06, D-04)

**Wave 4** *(blocked on 06.2-07)*

- [x] 06.2-08-PLAN.md — SessionState + ActiveSessionView UI + Wake Lock lifecycle (PHONE-03, PHONE-07)

**Wave 5** *(blocked on 06.2-02/06/07/08)*

- [x] 06.2-09-PLAN.md — On-device verification: mkcert trust, WT spike decision, CoreMotion axis, WebRTC fan-out, Wake Lock (PHONE-03/04/05/07)

### Phase 06.3: iOS Native Client — ARKit World Tracking (INSERTED)

**Goal:** Swap the native iOS phone client's position source from CoreMotion dead-reckoning (the Phase 06.2 parity baseline) to ARKit `ARSession` world tracking for precise 6DOF position, keeping orientation semantics compatible with the existing desktop decode/SLERP pipeline (Phase 6) and SDK naming (Phase 7 — `deadReckoningPosition`/`driftConfidence`). This is the native-companion-app escape hatch Phase 06.1 explicitly anticipated for iOS (Safari has no WebXR `immersive-ar`), invoked now instead of the planned web-based VIO/SLAM research spike. Includes a mandatory on-device ARKit tracking-precision verification checkpoint that is a go/no-go gate for the project, mirroring Phase 06.1's Wave 3 on-device checkpoint pattern.
**Requirements**: SENS-V2-03, SDK-05 (reused from Phase 06.1); SENS-06 (native-parity for the already-Complete Phase 5 web touch-capture requirement — no distinct new requirement ID, per CONTEXT.md/RESEARCH.md)
**Depends on:** Phase 06.2 (native transport parity must land first); references Phase 06.1's WebXR pose-tracking conventions (webxr.ts, phone.ts D-02/D-03/D-05/D-06) as a native-porting guide
**Plans:** 8/8 plans complete

Plans:

**Wave 1**

- [x] 06.3-01-PLAN.md — ARKit pose conversion pure functions + freeze-on-loss tracker + tests (D-02/D-07, SENS-V2-03)

**Wave 2** *(blocked on 06.3-01)*

- [x] 06.3-02-PLAN.md — Headless ARPoseSource + TransportManager wiring + encoder regression (D-01/D-14, SENS-V2-03/SDK-05)

**Wave 3** *(blocked on 06.3-02 — EARLY go/no-go gate)*

- [x] 06.3-03-PLAN.md — On-device ARKit accuracy checkpoint: axis verify + ~1m³ quant + qual + GO/NO-GO (D-16/D-17/D-18)

**Wave 4** *(blocked on 06.3-03 GO)*

- [x] 06.3-04-PLAN.md — Full-screen touch capture + local feedback (D-03/D-04/D-05/D-06, SENS-06)
- [x] 06.3-07-PLAN.md — Corner long-press gesture recognizer + hit-test tests (D-12)

**Wave 5** *(blocked on 06.3-04)*

- [x] 06.3-05-PLAN.md — Hold-still auto-recenter + manual recenter via setWorldOrigin (D-10/D-11)

**Wave 6** *(blocked on 06.3-05)*

- [x] 06.3-06-PLAN.md — D-09 session-start gate + D-08 tracking-limited toasts + Toast cases (D-08/D-09/D-15)

**Wave 7** *(blocked on 06.3-05/06/07)*

- [x] 06.3-08-PLAN.md — Hidden overlay menu: recenter + disconnect/back (D-11/D-12/D-13)

*Note (traceability): SENS-06 is covered by touch-capture Plan 06.3-04 as native-client parity for the existing Complete SENS-06 (Phase 5) entry; REQUIREMENTS.md traceability may either add a "SENS-06 (native parity)" row for Phase 06.3 or leave it implicitly covered by the existing SENS-06/Phase 5 entry — developer's choice.*

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

**Plans**: 7 plans

Plans:
**Wave 1**

- [ ] 07-01-PLAN.md — npm workspace + Vite library-mode packaging pipeline + vite-plugin-dts legitimacy gate (SDK-01)

**Wave 2** *(blocked on 07-01)*

- [ ] 07-02-PLAN.md — Pure-layer extraction: types/schema/decode/encode/playerStore moved + hand-written slerp + relocated tests (SDK-05)

**Wave 3** *(blocked on 07-02)*

- [ ] 07-03-PLAN.md — API core: internal tick + getPlayerInput/getRawInput + typed EventTarget events + strict-typecheck fixture (SDK-01/02/03/06)

**Wave 4** *(blocked on 07-03)*

- [ ] 07-04-PLAN.md — Signaling transport extraction: WT-first/WS-fallback connect/joinRoom/reconnect/leaveRoom + onSignal passthrough (SDK-02/03)

**Wave 5** *(blocked on 07-04)*

- [ ] 07-05-PLAN.md — WebRTC fan-out + verbatim guard-first decode→store pipeline + player lifecycle events (SDK-02/03)

**Wave 6** *(blocked on 07-05)*

- [ ] 07-06-PLAN.md — Latency overlay: RTT/ICE from getStats+live pc, jitter/loss computed from seq/timestamp, textContent-only DOM (SDK-04)

**Wave 7** *(blocked on 07-06)*

- [ ] 07-07-PLAN.md — client consumes the SDK (room.ts + scene.ts, axis remap preserved) + live on-device verification (SDK-01/04)

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
| 2. Signaling, TURN, and Deployment | 4/5 | In Progress|  |
| 3. Session and Pairing | 4/4 | Complete    | 2026-07-07 |
| 4. Phone Bootstrap and WebRTC Channels | 1/3 | In Progress|  |
| 5. Sensor Fusion and Packet Encoding | 7/7 | Complete   | 2026-07-09 |
| 6. Desktop Receive, Decode, and Rendering | 5/5 | Complete   | 2026-07-10 |
| 7. SDK Public API | 0/7 | Not started | - |
| 8. Demo Game | 0/TBD | Not started | - |
