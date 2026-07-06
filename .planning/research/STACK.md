# Technology Stack

**Project:** ImmersiveRT
**Researched:** 2026-07-06
**Overall confidence:** MEDIUM (all findings cross-checked across multiple web sources; no WebTransport-specific latency benchmarks exist yet)

---

## Recommended Stack

### WebTransport Server (Signal + Relay)

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| Rust | 1.78+ (stable) | Server language | No GC pauses on the hot sensor relay path; tokio async runtime saturates available cores without thread-per-connection overhead |
| wtransport | 0.7.1 | WebTransport/HTTP3 server | Only pure-Rust WebTransport implementation; async-friendly API; ~417k crates.io downloads; actively maintained by BiagioFesta; pairs naturally with tokio |
| tokio | 1.x | Async runtime | De-facto Rust async runtime; used internally by wtransport; battle-tested for network I/O |

**Latency implication (MEDIUM confidence):** General HTTP benchmarks show Rust at ~1.5ms avg vs Go ~1.8ms vs Node.js ~3.2ms under moderate load. Under extreme load (many concurrent sessions) the gap widens dramatically (Rust 20ms, Go 45ms, Node.js 120ms). More importantly, Node.js and Go GC pauses introduce jitter — a 50ms GC pause mid-stream is a dropped sensor window. Rust has zero GC. For a sub-20ms sensor delivery target, Rust is the only safe choice.

**Why not Go (quic-go/webtransport-go):** quic-go is production-ready but webtransport-go explicitly warns that browser compatibility may break during spec transitions. Go also has GC pauses. Eliminated.

**Why not Node.js:** Node.js has no mature WebTransport server library; HTTP/3 support exists but no WebTransport stream upgrade path that is production-usable. GC pauses are a reliability concern at 60Hz × N players. Eliminated.

---

### WebRTC Signaling

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| Custom WebSocket relay inside wtransport server | — | Broker offer/answer/ICE exchange | The wtransport server already handles connections; adding a small in-process WebSocket endpoint (via tokio-tungstenite) keeps the signaling on the same Rust binary, eliminating an extra service hop |
| Native browser RTCPeerConnection | — | Peer-to-peer data channel establishment | Standard browser API; no library needed on client side for signaling consumption |

**Why not PeerJS / simple-peer:** Both are black boxes that embed signaling assumptions and add bundle weight. For a data-channel-only use case, the raw RTCPeerConnection API is ~40 lines and gives full control over unreliable channel configuration (ordered=false, maxRetransmits=0). Libraries like PeerJS default to reliable channels and add video/audio plumbing.

**Why not a separate Node.js signaling service:** Adds a second process, a second TLS cert, and a second Docker container for a relay that can be implemented as a tokio task inside the existing Rust server.

---

### TURN / STUN Server

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| coturn | 4.6.x (latest Docker tag) | STUN + TURN for NAT traversal | RFC 5766 compliant, battle-tested in WebRTC deployments globally, Docker image (coturn/coturn) is official and maintained |

**Docker image:** `coturn/coturn` on Docker Hub is the official image. `instrumentisto/coturn` is a well-maintained alternative with smaller attack surface.

**Port requirements:**
- 3478/TCP+UDP — STUN and TURN plain
- 5349/TCP+UDP — TURN over TLS
- 49152–65535/UDP — relay media port range (for IMU packets this is low-bandwidth; range can be narrowed)

**Config complexity:** Low. Core config is ~10 lines: realm, external IP (use `detect-external-ip` or hardcode), long-term credential, min-port/max-port. REST API shared secret auth recommended so the Rust server can generate ephemeral credentials without storing passwords.

**Latency implication:** coturn relay adds one additional network hop (phone → coturn → desktop). On LAN, P2P avoids this entirely. On the internet, a geographically close coturn adds ~10–30ms. For IMU this is acceptable since the sensor window is already 16ms (60Hz). Design: default to P2P, TURN only as fallback.

---

### IMU Sensor Fusion (Browser / Phone Client)

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| ahrs (npm) | latest (psiphi75/ahrs) | Madgwick + Mahony filter for quaternion orientation | Only npm package that provides both Madgwick and Mahony algorithms, browser-compatible, works directly with DeviceOrientationEvent/DeviceMotionEvent data, configurable beta and kp/ki params |
| Custom ZUPT + 1D Kalman | — | Dead-reckoning position estimation | No npm package exists for browser IMU dead-reckoning; a per-axis Kalman filter is ~20 lines; ZUPT threshold detection is ~5 lines; implementing from scratch is the only viable path |

**Algorithm choice rationale:**
- `DeviceOrientationEvent` (OS-fused): already provides excellent drift-free orientation via the device OS sensor stack. Use it directly — do NOT run a secondary Madgwick pass on it.
- `DeviceMotionEvent` linear acceleration: run through the ahrs Madgwick filter only if OS fusion is unavailable or if the magnetometer-corrected quaternion differs significantly from the OS quaternion. Prefer the OS output.
- Madgwick vs Mahony: Mahony is 10–15% faster CPU, useful on low-end phones. Madgwick gives slightly better magnetometer fusion. Start with Mahony; make configurable.

**Latency implication:** Filter runs on-device before transmission. Madgwick/Mahony converge in ~0.5s of sensor data; no startup latency visible to end users after the first half second.

---

### Binary Serialization (Sensor Packets)

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| msgpackr | 1.x (kriszyp/msgpackr) | Encode/decode sensor packets on phone and desktop | Fastest JS MessagePack implementation; 3× faster serialization than JSON; 17.5% smaller payloads; no schema required; works in modern browsers natively; record extension can 2-3× further compress repetitive sensor struct |

**Why not FlatBuffers:** FlatBuffers has the fastest deserialization (zero-copy) but requires a schema and flatc compiler step. For fire-and-forget UDP-like packets at 60Hz, the phone never waits for a response, so deserialization speed on the receiver (desktop) matters less than serialization speed on the sender (phone). MessagePack wins this trade.

**Why not Protocol Buffers:** Protobuf delivers the smallest payloads (−45% vs JSON) and is well-rounded, but requires protoc + code generation, adding toolchain complexity for a packet structure that changes infrequently. For v1, MessagePack's no-schema approach is the right tradeoff.

**Why not raw ArrayBuffer / custom binary:** Viable but requires hand-writing encode/decode for every field. msgpackr with the record extension achieves similar size savings with much less code. Custom binary is the escape hatch if msgpackr overhead is measured as a bottleneck.

**Latency implication:** Serialization at 60Hz on a phone CPU budget. JSON: ~300µs/packet. msgpackr: ~100µs/packet. Custom binary: ~30µs/packet. The difference (200µs) is well below the 16ms frame budget. Use msgpackr; do not prematurely optimize to custom binary.

**Packet structure (recommended baseline):**

```typescript
// msgpackr encodes this struct via record extension (~30 bytes per packet vs ~120 bytes JSON)
interface SensorPacket {
  t: number;          // phone timestamp (ms, DOMHighResTimeStamp)
  q: [number, number, number, number]; // quaternion [w, x, y, z] as Float32
  a: [number, number, number]; // linear accel [x, y, z] m/s²
  v: number;          // ZUPT velocity magnitude (zero = stationary)
  touch?: number;     // bitmask: tap, swipe, buttons
}
```

---

### Three.js + Rendering

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| three | r185 (0.185.x) | 3D rendering on desktop game host | Project scope is Three.js-only for v1; r185 is latest stable with all deprecated legacy removed since r176 |
| @types/three | matching | TypeScript types | Three.js ships with bundled TS types since r143; `@types/three` mirrors them |

**react-three-fiber (r3f):** Excluded. The SDK is a vanilla TypeScript npm package; wrapping the rendering loop in React adds overhead and forces game developers to use React. The SDK exposes an event-driven API that works with any rendering loop.

**Physics engine:** Not needed for v1. ImmersiveRT is a transport/input layer — it does not simulate physics. If a game built on the SDK needs physics, they should add Rapier.js (not cannon-es, which is unmaintained). No physics dependency in the platform itself.

---

### TLS for Local Development

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| mkcert | latest | Locally-trusted dev certificates | WebTransport requires valid TLS even on localhost (Chrome refuses self-signed without a trusted CA); mkcert installs a local CA into the system trust store and generates valid certs for localhost/127.0.0.1 with no browser warnings |

**Setup (one-time per dev machine):**
```bash
mkcert -install
mkcert localhost 127.0.0.1 ::1
# Outputs: localhost+2.pem, localhost+2-key.pem
# Load these into wtransport's TlsConfig
```

**Caddy note:** Caddy cannot proxy WebTransport streams (GitHub issue #5421 is unresolved). Do not put Caddy in front of the WebTransport server endpoint. Caddy is acceptable for serving static files (the desktop game client HTML/JS) on port 443 alongside the wtransport server on a different port (e.g., 4433).

---

### Docker Base Images

| Component | Build Stage | Runtime Stage | Why |
|-----------|-------------|---------------|-----|
| WebTransport server (Rust) | `rust:1-slim` | `debian:bookworm-slim` | bookworm-slim (~150MB final) avoids musl complexity while keeping image small; alpine (~25MB) possible but requires `x86_64-unknown-linux-musl` target and careful dynamic linking audit |
| coturn | N/A | `coturn/coturn` (official) | No build needed; use official image directly |
| Static file server | N/A | `nginx:alpine` or `caddy:alpine` | Serve the desktop game client; caddy for auto-TLS in production |

**Rust build optimization pattern:**
```dockerfile
FROM rust:1-slim AS builder
WORKDIR /app
# Cache dependencies separately from source
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo "fn main(){}" > src/main.rs
RUN cargo build --release
RUN rm src/main.rs
# Now build actual source (deps already compiled)
COPY src ./src
RUN touch src/main.rs && cargo build --release

FROM debian:bookworm-slim AS runtime
COPY --from=builder /app/target/release/immersive-rt-server /usr/local/bin/
EXPOSE 4433/udp 4433/tcp
CMD ["immersive-rt-server"]
```

**Rebuild time with caching:** ~90s (deps hit cache) vs ~5min (cold build).

---

### DeviceMotionEvent / DeviceOrientationEvent Constraints

| Constraint | Detail | Mitigation |
|------------|--------|------------|
| iOS 13+ permission | `DeviceMotionEvent.requestPermission()` must be called from a user gesture (button tap) | Add a "Enable Motion" button as the first UI element on the phone client |
| Sampling rate | iOS Safari: ~60Hz max. Android Chrome: up to 100Hz on capable devices. OS-controlled, not configurable | Design sensor pipeline for 60Hz (16ms budget); treat 100Hz as a bonus |
| Android: no permission needed | `devicemotion` fires without prompting on Android | No action needed; feature-detect requestPermission existence before calling |
| HTTPS required | DeviceMotionEvent is gated on secure origin (HTTPS or localhost) in Chrome | Use mkcert for local dev; production requires real TLS |

---

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

---

## Installation

### Server (Rust workspace)

```toml
# Cargo.toml
[dependencies]
wtransport = "0.7"
tokio = { version = "1", features = ["full"] }
tokio-tungstenite = "0.21"   # WebSocket for signaling endpoint
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tracing = "0.1"
tracing-subscriber = "0.3"
```

### Phone + Desktop Client (npm)

```bash
# Core sensor + serialization
npm install ahrs msgpackr

# Three.js (desktop client / SDK peer dependency)
npm install three

# Dev dependencies
npm install -D typescript @types/three vite mkcert
```

### Docker Compose (production-shape)

```yaml
services:
  server:
    build: ./server
    ports:
      - "4433:4433/udp"
      - "4433:4433/tcp"
    volumes:
      - ./certs:/certs:ro

  coturn:
    image: coturn/coturn:latest
    network_mode: host   # required for TURN IP detection
    volumes:
      - ./coturn.conf:/etc/coturn/turnserver.conf:ro

  static:
    image: nginx:alpine
    ports:
      - "443:443"
    volumes:
      - ./dist:/usr/share/nginx/html:ro
      - ./certs:/etc/nginx/certs:ro
```

---

## WebTransport Browser Support (2026)

| Browser | Min Version | Status |
|---------|------------|--------|
| Chrome | 97+ | Full support |
| Edge | 98+ | Full support (Chromium) |
| Firefox | 114+ | Full support |
| Safari | 26.4+ (March 2026) | Full support — now Baseline |

WebTransport crossed the Baseline threshold in March 2026 when Safari 26.4 shipped. All major browsers now support it without flags. QUIC/UDP firewall blocking remains a deployment concern — plan a WebSocket fallback for restrictive networks (hotels, corporate proxies).

---

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
