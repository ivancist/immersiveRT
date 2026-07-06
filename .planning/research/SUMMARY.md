# Project Research Summary

**Project:** ImmersiveRT
**Domain:** Real-time web gaming platform — phone as motion controller
**Researched:** 2026-07-06
**Confidence:** MEDIUM

## Executive Summary

ImmersiveRT is a developer SDK and infrastructure platform that turns smartphones into low-latency IMU motion controllers for browser-based Three.js games. The architecture is a hybrid: a Rust WebTransport server handles signaling only, WebRTC P2P data channels carry the sensor hot path at 60Hz, and on-device Madgwick/Kalman fusion sends processed quaternions rather than raw gyro samples. This mirrors how established platforms (AirConsole, Jackbox) handle the join UX, but differentiates on the quality of the sensor abstraction — structured orientation, gesture displacement, and dead-reckoning position layers rather than raw device_motion intervals.

The recommended stack is clear and well-supported as of 2026: Rust/wtransport for the WebTransport server (zero GC, pure Rust, actively maintained), coturn for STUN/TURN, ahrs (npm) for Madgwick/Mahony filtering, msgpackr for binary serialization, and Three.js r185 as the SDK's rendering peer dependency. WebTransport reached Baseline in March 2026 (Safari 26.4+), so all major browsers are supported without flags. The entire stack can run in three Docker containers (Rust server, coturn, nginx/caddy).

The key risks are infrastructure-level and must be addressed in Phase 1 before any client code is written: WebTransport TLS certificate requirements are strict and opaque, coturn breaks silently in Docker bridge mode, QUIC/UDP is blocked on corporate/hotel networks requiring a WebSocket signaling fallback, and TURN credentials must be generated at connection-start not page load. Secondary risks are sensor-layer: iOS DeviceMotion permission must be gated behind a user gesture, the Madgwick beta must be tunable, and ZUPT false-triggers on mid-gesture pauses require an adaptive threshold. None of these are show-stoppers — all have documented mitigations — but ignoring any one of them causes silent failures that take hours to diagnose.

---

## Key Findings

### Recommended Stack

The server is a single Rust binary using the `wtransport` crate (0.7.x) over tokio. This is the only pure-Rust WebTransport implementation and the right call for a 60Hz sensor relay where GC pauses are unacceptable. Signaling runs as a tokio task inside the same process (tokio-tungstenite for WebSocket fallback). coturn 4.6.x handles STUN/TURN in Docker with `network_mode: host`. The phone and desktop clients are TypeScript/npm: `ahrs` for sensor fusion, `msgpackr` for binary encoding, and `three` r185 as a peer dependency. Local dev requires mkcert — WebTransport enforces TLS even on localhost and Caddy cannot proxy WebTransport streams (issue #5421 unresolved).

**Core technologies:**
- Rust 1.78+ / wtransport 0.7: WebTransport server — zero GC pauses; only production-ready pure-Rust WebTransport implementation
- tokio 1.x: async runtime — de facto Rust standard; used internally by wtransport
- coturn 4.6.x: STUN/TURN — RFC 5766 compliant; Docker official image; battle-tested globally
- ahrs (npm): Madgwick + Mahony filter — only npm package with both algorithms; browser-compatible; works directly with DeviceMotion/DeviceOrientation events
- msgpackr (npm): binary serialization — 3x faster than JSON; 17.5% smaller payloads; no schema required; record extension achieves ~30 bytes per sensor packet
- three r185: rendering — latest stable; ships bundled TypeScript types; SDK exposes event-driven API that works with any rendering loop
- mkcert: local TLS — WebTransport requires valid TLS on localhost; Caddy cannot proxy WebTransport

### Expected Features

The feature landscape is well-mapped against AirConsole and Jackbox. The join flow (QR code + short room code + no app install) is non-negotiable table stakes. The real differentiation is in the sensor abstraction layer: three distinct input layers (orientation quaternion, gesture displacement window, dead-reckoning position) with built-in slerp interpolation, and a dual consumption API (polling for game loops, events for reactive patterns).

**Must have (table stakes):**
- QR code + short alphanumeric room code join — AirConsole/Jackbox established expectation
- No app install (pure mobile web) — platform value collapses without it
- Player name entry and slot management (2-8 phones)
- Orientation stream (quaternion) — core value proposition
- Touch event stream (tap, buttons)
- Player join/leave/disconnect/reconnect lifecycle events in SDK
- `getPlayerInput(playerId)` polling API + `on('imuUpdate', cb)` event API — both required
- Session isolation (room token as isolation boundary)
- TURN fallback via coturn
- iOS sensor permission UI (DeviceMotion gate on user gesture)
- TypeScript types for all public API surfaces
- Latency timestamp in every packet (seq + ts header)

**Should have (differentiators):**
- Structured IMU input layers: `orientation` / `gestureDisplacement` / `deadReckoningPosition`
- On-device Madgwick filter (drift-free orientation, no server round-trip)
- SDK slerp interpolation (smoothed quaternions by default, raw opt-in)
- Developer latency overlay (rolling avg latency, jitter, packet loss, ICE state)
- Graceful reconnection with slot hold (60s window; phone reclaims same playerId)
- ZUPT gesture displacement windows (enables throw/swing mechanics)
- Binary packet encoding (MessagePack, ~30 bytes per packet vs ~120 bytes JSON)
- WebTransport signaling with WebSocket fallback for blocked networks

**Defer (v2+):**
- Room-scale absolute position (impossible from browser IMU; would destroy trust)
- Server-side game logic / authoritative state
- Audio/video streaming
- Virtual joystick / D-pad touch UI
- Persistent accounts / matchmaking
- Native iOS/Android app
- SFU or MCU topology
- Game marketplace / platform portal

### Architecture Approach

The system uses a P2P mesh topology with TURN fallback — not an SFU. The Rust WebTransport server is signaling-only: once the WebRTC data channel is open, the server is entirely out of the hot path. All sensor fusion (Madgwick, ZUPT, Kalman) runs on-device on the phone; the server and desktop only receive processed quaternion + delta position packets (~40 bytes at 60Hz = ~19 Kbps per phone). The Three.js render loop on desktop applies slerp interpolation at frame time using a target-state store updated by incoming packets via `onmessage`.

**Major components:**
1. Rust WebTransport Server (wtransport + tokio) — QUIC endpoint, room state machine, signaling router; NOT in sensor hot path after handshake
2. Phone Client (TypeScript) — DeviceMotion/Orientation capture, Madgwick filter, ZUPT/Kalman pipeline, binary encoder, WebTransport signaling client, RTCPeerConnection + unreliable data channel (`ordered: false, maxRetransmits: 0`)
3. Desktop Client / SDK (TypeScript) — WebTransport signaling client, RTCPeerConnection host, binary decoder, sequence-number out-of-order drop, slerp applier, public SDK API surface
4. coturn — STUN/TURN process; `network_mode: host` required
5. Static Server (nginx/caddy) — serves phone + desktop HTML/JS

### Critical Pitfalls

1. **WebTransport TLS cert requirements are strict and silent** — use Chrome's `chrome://flags/#webtransport-developer-mode` in dev; Let's Encrypt in prod. Address in Phase 1.

2. **coturn Docker bridge mode silently breaks STUN** — use `network_mode: host` and `external-ip=<PUBLIC_IP>`; validate with `turnutils_uclient`. Address in Phase 1.

3. **QUIC/UDP blocked on corporate/hotel networks** — implement WebSocket fallback for signaling after ~3s timeout; configure coturn TCP 443 TURN relay. Address in Phase 1.

4. **TURN credential staleness** — generate at connection-start via server endpoint, not page load. Address in Phase 1 + Phase 2.

5. **iOS DeviceMotion permission must be in a synchronous user gesture handler** — show "Grant Motion Access" button before any sensor code; feature-detect `DeviceMotionEvent.requestPermission`. Address in Phase 2.

6. **Unreliable data channel misconfiguration** — enforce `{ ordered: false, maxRetransmits: 0 }` explicitly; browser default is ordered/reliable. Address in Phase 2.

7. **Madgwick beta tuning** — default 0.1; ramp 0.2-0.3 at cold start; make runtime-configurable. Address in Phase 2.

8. **ZUPT false triggers** — adaptive variance + 300ms duration threshold; suppress during gesture windows. Address in Phase 2.

---

## Implications for Roadmap

### Suggested Phases

**Phase 1: Infrastructure and Transport Foundation**
Hard dependency — nothing else can be tested without working signaling and WebRTC handshake. All critical infrastructure pitfalls (TLS, coturn bridge mode, QUIC blocked, TURN credentials) live here.

Delivers: Working WebRTC P2P data channel between phone and desktop, via Rust WebTransport signaling + coturn TURN. WebSocket signaling fallback. TURN credentials at connection-start.

Research flag: **NEEDS RESEARCH** — WebTransport TLS fingerprinting, wtransport Rust API, coturn REST API credential generation.

**Phase 2: Sensor Pipeline and Phone Client**
Sensor logic can be unit-tested offline during Phase 1 but end-to-end validation requires working transport. iOS permission gate must be established before any sensor code runs.

Delivers: Phone client with sensor permission UI, Madgwick filter (beta=0.1, runtime-configurable), adaptive ZUPT detector, Kalman dead-reckoning, binary packet encoder (40-byte fixed layout, pre-allocated DataView buffer), unreliable data channel.

Research flag: Skip — standard patterns well-documented.

**Phase 3: Desktop Rendering and SDK Core**
Once sensor packets flow, the Three.js slerp loop and public SDK API surface can be built and validated against real data.

Delivers: Binary packet decoder, sequence-number out-of-order drop, Three.js slerp interpolation loop, public SDK API (`getPlayerInput()` + `on()` event emitter), TypeScript types, `deadReckoningPosition` naming with `driftConfidence` scalar.

Research flag: Skip — standard Three.js and TypeScript SDK patterns.

**Phase 4: Resilience, DX, and SDK Polish**
Required before any third-party developer touches the SDK.

Delivers: Slot-hold reconnection (60s window), developer latency overlay, heartbeat from phone (5s), Wake Lock API integration, wtransport keepalive (20s).

Research flag: Skip — reconnection and Wake Lock API are well-documented.

**Phase 5: Demo Game**
Built last, against the complete SDK, to validate full stack under real multi-player conditions.

Delivers: Demo where 2-8 phones each control a 3D object mirroring phone orientation. Shake/flick gesture launches object using `gestureDisplacement`. Latency overlay always visible. 30 seconds from page load to phone controlling an object.

Research flag: Skip — standard Three.js demo patterns.

### Phase Ordering Rationale

- Infrastructure before transport: WebRTC handshake hard-depends on working signaling and reachable TURN
- Transport before end-to-end sensor validation: sensor logic unit-testable offline; timing/delivery only validatable against real packet flows
- Sensor pipeline before SDK surface: finalizing the public API before data shape is proven leads to rewrites
- SDK polish before demo: demo must exercise the final API and set the right usage precedent

---

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | MEDIUM | All tools cross-checked; no WebTransport-specific end-to-end latency benchmarks exist |
| Features | MEDIUM | Cross-checked against AirConsole, Jackbox, and MDN; ZUPT displacement windows are novel and unvalidated |
| Architecture | MEDIUM | Topology well-supported; latency budget is estimated, not benchmarked |
| Pitfalls | MEDIUM | TLS and coturn pitfalls well-documented; sensor tuning values require empirical device testing |

**Overall confidence:** MEDIUM

### Gaps to Address

- End-to-end latency benchmark: validate <20ms LAN budget empirically in Phase 1 with a latency probe
- Madgwick beta empirical range: build runtime-configurable beta from day one
- ZUPT adaptive threshold values: plan empirical tuning in Phase 2 with real devices
- coturn REST API integration: add integration test in Phase 1
- WebSocket fallback mechanism scope: nail down during Phase 1 planning (same Rust server port? separate endpoint?)

---

## Sources

### Primary (HIGH confidence)
- MDN DeviceMotionEvent / DeviceOrientationEvent — sensor permission lifecycle
- MDN WebRTC Data Channels in Games — data channel patterns
- Three.js Quaternion SLERP docs — slerp API

### Secondary (MEDIUM confidence)
- wtransport GitHub (BiagioFesta) — Rust WebTransport crate API
- coturn GitHub — TURN configuration, REST API
- ahrs npm — Madgwick/Mahony browser package
- msgpackr GitHub — binary serialization performance
- WebTransport Baseline announcement (March 2026) — browser support status
- WebKit Features for Safari 26.4 — Safari WebTransport confirmation
- Gaffer on Games — snapshot interpolation packet design
- Ant Media — WebRTC topology comparison (P2P vs SFU vs MCU)
- AirConsole API Reference — competitive feature comparison
- coturn Docker host networking (metered.ca) — bridge mode pitfall
- DTLS handshake failure Chrome 124 — DTLS algorithm drift pitfall

### Tertiary (LOW confidence)
- General HTTP language benchmark comparisons — directional rationale only; no WebTransport-specific numbers
- Academic IMU literature for ZUPT threshold values — requires empirical validation

---
*Research completed: 2026-07-06*
*Ready for roadmap: yes*
