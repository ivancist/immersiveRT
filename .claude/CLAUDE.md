<!-- GSD:project-start source:PROJECT.md -->

## Project

**ImmersiveRT**

A real-time web platform and SDK for building Three.js browser games where players use their mobile phones as motion controllers. The desktop renders the 3D game world while the phone streams IMU sensor data (orientation + position) via WebRTC unreliable data channels directly to the desktop and other players. A WebTransport server handles signaling, session management, and relaying; coturn provides TURN for NAT traversal.

**Core Value:** Phone motion feels physically immediate on screen — sub-20ms sensor delivery from phone to desktop, on the same local network and as fast as physically possible across the internet.

### Constraints

- **Browser API**: Device Motion API capped at ~60–100Hz depending on device/OS — sensor rate ceiling
- **WebTransport TLS**: Requires HTTPS even in development (self-signed cert or mkcert for local dev)
- **QUIC firewall**: Some networks block UDP; need WebSocket fallback path for WebTransport
- **TURN costs**: Relaying video/audio would be expensive; relaying small IMU packets is cheap — scope TURN to data channels only
- **IMU drift**: Position tracking is best-effort; games must design interactions around drift-reset moments
- **Mobile browser permissions**: Device Motion requires explicit user gesture on iOS 13+ (permission prompt)

<!-- GSD:project-end -->

<!-- GSD:stack-start source:research/STACK.md -->

## Technology Stack

## Recommended Stack

### WebTransport Server (Signal + Relay)

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| Rust | 1.78+ (stable) | Server language | No GC pauses on the hot sensor relay path; tokio async runtime saturates available cores without thread-per-connection overhead |
| wtransport | 0.7.1 | WebTransport/HTTP3 server | Only pure-Rust WebTransport implementation; async-friendly API; ~417k crates.io downloads; actively maintained by BiagioFesta; pairs naturally with tokio |
| tokio | 1.x | Async runtime | De-facto Rust async runtime; used internally by wtransport; battle-tested for network I/O |

### WebRTC Signaling

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| Custom WebSocket relay inside wtransport server | — | Broker offer/answer/ICE exchange | The wtransport server already handles connections; adding a small in-process WebSocket endpoint (via tokio-tungstenite) keeps the signaling on the same Rust binary, eliminating an extra service hop |
| Native browser RTCPeerConnection | — | Peer-to-peer data channel establishment | Standard browser API; no library needed on client side for signaling consumption |

### TURN / STUN Server

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| coturn | 4.6.x (latest Docker tag) | STUN + TURN for NAT traversal | RFC 5766 compliant, battle-tested in WebRTC deployments globally, Docker image (coturn/coturn) is official and maintained |

- 3478/TCP+UDP — STUN and TURN plain
- 5349/TCP+UDP — TURN over TLS
- 49152–65535/UDP — relay media port range (for IMU packets this is low-bandwidth; range can be narrowed)

### IMU Sensor Fusion (Browser / Phone Client)

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| ahrs (npm) | latest (psiphi75/ahrs) | Madgwick + Mahony filter for quaternion orientation | Only npm package that provides both Madgwick and Mahony algorithms, browser-compatible, works directly with DeviceOrientationEvent/DeviceMotionEvent data, configurable beta and kp/ki params |
| Custom ZUPT + 1D Kalman | — | Dead-reckoning position estimation | No npm package exists for browser IMU dead-reckoning; a per-axis Kalman filter is ~20 lines; ZUPT threshold detection is ~5 lines; implementing from scratch is the only viable path |

- `DeviceOrientationEvent` (OS-fused): already provides excellent drift-free orientation via the device OS sensor stack. Use it directly — do NOT run a secondary Madgwick pass on it.
- `DeviceMotionEvent` linear acceleration: run through the ahrs Madgwick filter only if OS fusion is unavailable or if the magnetometer-corrected quaternion differs significantly from the OS quaternion. Prefer the OS output.
- Madgwick vs Mahony: Mahony is 10–15% faster CPU, useful on low-end phones. Madgwick gives slightly better magnetometer fusion. Start with Mahony; make configurable.

### Binary Serialization (Sensor Packets)

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| msgpackr | 1.x (kriszyp/msgpackr) | Encode/decode sensor packets on phone and desktop | Fastest JS MessagePack implementation; 3× faster serialization than JSON; 17.5% smaller payloads; no schema required; works in modern browsers natively; record extension can 2-3× further compress repetitive sensor struct |

### Three.js + Rendering

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| three | r185 (0.185.x) | 3D rendering on desktop game host | Project scope is Three.js-only for v1; r185 is latest stable with all deprecated legacy removed since r176 |
| @types/three | matching | TypeScript types | Three.js ships with bundled TS types since r143; `@types/three` mirrors them |

### TLS for Local Development

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| mkcert | latest | Locally-trusted dev certificates | WebTransport requires valid TLS even on localhost (Chrome refuses self-signed without a trusted CA); mkcert installs a local CA into the system trust store and generates valid certs for localhost/127.0.0.1 with no browser warnings |

# Outputs: localhost+2.pem, localhost+2-key.pem

# Load these into wtransport's TlsConfig

### Docker Base Images

| Component | Build Stage | Runtime Stage | Why |
|-----------|-------------|---------------|-----|
| WebTransport server (Rust) | `rust:1-slim` | `debian:bookworm-slim` | bookworm-slim (~150MB final) avoids musl complexity while keeping image small; alpine (~25MB) possible but requires `x86_64-unknown-linux-musl` target and careful dynamic linking audit |
| coturn | N/A | `coturn/coturn` (official) | No build needed; use official image directly |
| Static file server | N/A | `nginx:alpine` or `caddy:alpine` | Serve the desktop game client; caddy for auto-TLS in production |

# Cache dependencies separately from source

# Now build actual source (deps already compiled)

### DeviceMotionEvent / DeviceOrientationEvent Constraints

| Constraint | Detail | Mitigation |
|------------|--------|------------|
| iOS 13+ permission | `DeviceMotionEvent.requestPermission()` must be called from a user gesture (button tap) | Add a "Enable Motion" button as the first UI element on the phone client |
| Sampling rate | iOS Safari: ~60Hz max. Android Chrome: up to 100Hz on capable devices. OS-controlled, not configurable | Design sensor pipeline for 60Hz (16ms budget); treat 100Hz as a bonus |
| Android: no permission needed | `devicemotion` fires without prompting on Android | No action needed; feature-detect requestPermission existence before calling |
| HTTPS required | DeviceMotionEvent is gated on secure origin (HTTPS or localhost) in Chrome | Use mkcert for local dev; production requires real TLS |

## Alternatives Considered

| Category | Recommended | Alternative | Why Not |
|----------|-------------|-------------|---------|
| WebTransport server language | Rust (wtransport) | Go (webtransport-go) | Go has GC pauses, webtransport-go warns of spec-break risk during browser transitions |
| WebTransport server language | Rust (wtransport) | Node.js | No production-ready WebTransport server lib for Node; GC jitter at 60Hz × N players |
| Signaling | In-process tokio WebSocket | Separate Node.js service | Extra process, extra container, extra latency hop for no benefit |
| TURN server | coturn | STUNner (Kubernetes-native) | STUNner requires Kubernetes; overkill for this project; coturn Docker works in Compose |
| IMU filter | ahrs (npm) | madgwick.js (ZiCog) | madgwick.js is a standalone script, not an npm package; no Mahony option; less configurable |
| Serialization | msgpackr | FlatBuffers | Schema/codegen overhead; deserialization speed advantage irrelevant for fire-and-forget |
| Serialization | msgpackr | Custom binary | Premature optimization; msgpackr overhead is ~100µs, well within 16ms frame budget |
| Local TLS | mkcert | Caddy auto-HTTPS | Caddy cannot proxy WebTransport; direct wtransport cert loading is simpler |
| Rust runtime image | debian:bookworm-slim | alpine | Alpine requires musl cross-compile; bookworm-slim is simpler with negligible size penalty for a server |
| Physics | None (v1) | Rapier.js | Platform is a transport layer; physics is game responsibility; add as peer dependency note in SDK docs |

## Installation

### Server (Rust workspace)

# Cargo.toml

### Phone + Desktop Client (npm)

# Core sensor + serialization

# Three.js (desktop client / SDK peer dependency)

# Dev dependencies

### Docker Compose (production-shape)

## WebTransport Browser Support (2026)

| Browser | Min Version | Status |
|---------|------------|--------|
| Chrome | 97+ | Full support |
| Edge | 98+ | Full support (Chromium) |
| Firefox | 114+ | Full support |
| Safari | 26.4+ (March 2026) | Full support — now Baseline |

## Sources

- [wtransport GitHub (BiagioFesta)](https://github.com/BiagioFesta/wtransport) — MEDIUM confidence
- [wtransport crates.io](https://crates.io/crates/wtransport) — MEDIUM confidence
- [quic-go/webtransport-go GitHub](https://github.com/quic-go/webtransport-go) — MEDIUM confidence
- [coturn GitHub](https://github.com/coturn/coturn) — MEDIUM confidence
- [coturn Docker Hub](https://hub.docker.com/r/coturn/coturn) — MEDIUM confidence
- [ahrs npm](https://www.npmjs.com/package/ahrs) — MEDIUM confidence
- [msgpackr GitHub](https://github.com/kriszyp/msgpackr) — MEDIUM confidence
- [msgpackr npm](https://www.npmjs.com/package/msgpackr) — MEDIUM confidence
- [Three.js releases](https://github.com/mrdoob/three.js/releases) — MEDIUM confidence
- [WebTransport Baseline announcement](https://webrtc.ventures/2026/04/webtransport-is-now-baseline-what-it-means-for-real-time-media/) — MEDIUM confidence
- [caniuse WebTransport](https://caniuse.com/webtransport) — MEDIUM confidence
- [mkcert GitHub](https://github.com/FiloSottile/mkcert) — MEDIUM confidence
- [Caddy WebTransport issue #5421](https://github.com/caddyserver/caddy/issues/5421) — MEDIUM confidence
- [Rust Docker multi-stage builds](https://dev.to/mattdark/rust-docker-image-optimization-with-multi-stage-builds-4b6c) — MEDIUM confidence
- [MDN DeviceMotionEvent](https://developer.mozilla.org/en-US/docs/Web/API/DeviceMotionEvent) — MEDIUM confidence

<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->

## Conventions

Conventions not yet established. Will populate as patterns emerge during development.
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->

## Architecture

Architecture not yet mapped. Follow existing patterns found in the codebase.
<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->

## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->

## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:

- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->

<!-- GSD:profile-start -->

## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
