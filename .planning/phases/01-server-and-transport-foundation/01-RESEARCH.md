# Phase 01: Server and Transport Foundation - Research

**Researched:** 2026-07-06
**Domain:** Rust async network server — WebTransport (QUIC/HTTP3) + WebSocket fallback + TLS provisioning
**Confidence:** MEDIUM

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| INFRA-01 | Server runs as a single Rust binary (wtransport + tokio) handling WebTransport connections from both phones and desktops | wtransport 0.7.1 ServerConfig + Endpoint::server pattern; tokio rt-multi-thread for concurrency |
| INFRA-05 | Server provides a WebSocket signaling fallback path for networks where QUIC/UDP is blocked | tokio-tungstenite 0.29 TcpListener + accept_async pattern; separate listener spawned concurrently in same binary |
</phase_requirements>

---

## Summary

This phase establishes the foundation of the ImmersiveRT server: a single Rust binary that accepts WebTransport connections over QUIC/HTTP3 with valid TLS, and simultaneously serves a WebSocket fallback endpoint for networks where UDP/QUIC is blocked. The server must be verifiable end-to-end with a latency echo probe (sub-10ms on LAN) and must compile cleanly with no warnings.

The stack is fully determined by project decisions in CLAUDE.md: Rust 1.78+, wtransport 0.7.1 for WebTransport, tokio 1.x for async runtime, tokio-tungstenite 0.29 for the WebSocket fallback listener. All three crates are confirmed legitimate on crates.io. The primary engineering challenge is: (1) correct TLS certificate setup that Chrome's WebTransport stack accepts, and (2) structuring two concurrent listeners (QUIC on 4433, TCP/WebSocket on a second port) within the same tokio runtime without blocking each other.

The most important gotcha for this phase is Chrome's QUIC certificate policy: even a valid mkcert cert requires `chrome://flags/#webtransport-developer-mode` to be enabled in local development, because Chrome requires QUIC certs to come from a known root CA. This flag must be part of the developer setup instructions. In production, a real certificate (Let's Encrypt or equivalent) eliminates the flag requirement.

**Primary recommendation:** Implement two tokio::spawn listener loops in main() — one for wtransport Endpoint::server on port 4433, one for TcpListener + tokio-tungstenite on port 8080. Share a message broadcast channel between them for future signaling use. Provision mkcert certs at project setup, document the Chrome flag requirement prominently.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| WebTransport session handling | API / Backend (Rust binary) | — | QUIC endpoint lives in server process; browser is client only |
| WebSocket fallback signaling | API / Backend (Rust binary) | — | Same binary, separate TCP listener on a different port |
| TLS certificate management | API / Backend (Rust binary) | OS trust store (mkcert CA) | Certs loaded from filesystem into wtransport Identity; mkcert installs CA into OS |
| Latency echo probe | API / Backend (Rust binary) | — | Server timestamps and echoes; client measures round-trip |
| QUIC transport | API / Backend (Rust binary) | — | wtransport wraps quinn/QUIC; all QUIC state in server process |
| Cargo workspace structure | Build / Config | — | No frontend tier at this phase; pure Rust binary |

---

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| wtransport | 0.7.1 | WebTransport/HTTP3 server | Only pure-Rust WebTransport impl; 17.5k weekly downloads; actively maintained; pairs with tokio natively [VERIFIED: crates.io registry] |
| tokio | 1.52.3 (latest 1.x) | Async runtime | De-facto Rust async runtime; 14.2M weekly downloads; used internally by wtransport [VERIFIED: crates.io registry] |
| tokio-tungstenite | 0.29.0 | WebSocket server (fallback listener) | Standard tokio WebSocket binding; 4M weekly downloads; well-maintained [VERIFIED: crates.io registry] |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| tungstenite | (pulled by tokio-tungstenite) | WebSocket protocol impl | Transitive dep — do not declare directly |
| quinn | (pulled by wtransport) | QUIC transport layer | Transitive dep — do not declare directly |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| tokio-tungstenite | axum WebSocket | axum adds router/middleware overhead unnecessary for a raw signaling endpoint; tokio-tungstenite is lighter for this use case |
| wtransport | webtransport-go | Go has GC pauses; wtransport-go warns of spec-break risk [ASSUMED] |

**Installation (Cargo.toml):**
```toml
[workspace]
members = ["server"]
resolver = "2"

# server/Cargo.toml
[package]
name = "immersive-rt-server"
version = "0.1.0"
edition = "2021"

[dependencies]
wtransport = "0.7"
tokio = { version = "1", features = ["macros", "rt-multi-thread", "fs", "io-util", "net", "sync"] }
tokio-tungstenite = "0.29"
futures-util = "0.3"  # for ws stream split/fold
anyhow = "1"          # ergonomic error handling
tracing = "0.1"       # structured logging
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
```

**Version verification (cargo search output — 2026-07-06):**
- wtransport = "0.7.1" [VERIFIED: crates.io registry]
- tokio = "1.52.3" [VERIFIED: crates.io registry]
- tokio-tungstenite = "0.29.0" [VERIFIED: crates.io registry]

---

## Package Legitimacy Audit

| Package | Registry | Age | Downloads/wk | Source Repo | Verdict | Disposition |
|---------|----------|-----|--------------|-------------|---------|-------------|
| wtransport | crates.io | ~3 yrs (May 2023) | 17,571 | github.com/BiagioFesta/wtransport | OK | Approved |
| tokio | crates.io | ~10 yrs (Jul 2016) | 14,168,286 | github.com/tokio-rs/tokio | OK | Approved |
| tokio-tungstenite | crates.io | ~9 yrs (Mar 2017) | 4,028,900 | github.com/snapview/tokio-tungstenite | OK | Approved |

**Packages removed due to SLOP verdict:** none
**Packages flagged as suspicious (SUS):** none

---

## Architecture Patterns

### System Architecture Diagram

```
                    ┌─────────────────────────────────────────┐
                    │        Rust Binary (immersive-rt-server)│
                    │                                         │
  Chrome / Browser  │  ┌─────────────────┐                   │
  (WebTransport) ───┼─►│ wtransport       │                   │
  UDP/QUIC :4433    │  │ Endpoint::server │                   │
                    │  │ .accept() loop   │──► session handler │
                    │  │ (tokio::spawn)   │    (echo probe)   │
                    │  └─────────────────┘                   │
                    │                                         │
  Browser / Client  │  ┌─────────────────┐                   │
  (WebSocket) ──────┼─►│ TcpListener      │                   │
  TCP :8080         │  │ accept_async()   │──► ws handler     │
                    │  │ (tokio::spawn)   │    (echo probe)   │
                    │  └─────────────────┘                   │
                    │                                         │
                    │  TLS: mkcert PEM files loaded at startup│
                    └─────────────────────────────────────────┘

  mkcert (host tool)
    mkcert -install          → installs local CA into OS trust store
    mkcert localhost 127.0.0.1 ::1 → generates cert.pem + key.pem
    Chrome flag: chrome://flags/#webtransport-developer-mode → MUST enable
```

### Recommended Project Structure

```
immersiveRT/
├── Cargo.toml              # workspace root [workspace] members=["server"]
├── Cargo.lock
├── certs/                  # gitignored — mkcert output
│   ├── localhost+2.pem
│   └── localhost+2-key.pem
└── server/
    ├── Cargo.toml
    └── src/
        ├── main.rs         # #[tokio::main] — spawns both listeners
        ├── wt_server.rs    # WebTransport Endpoint + session loop
        ├── ws_server.rs    # WebSocket TcpListener + accept_async loop
        └── echo.rs         # latency echo handler (shared logic)
```

### Pattern 1: wtransport ServerConfig with TLS

**What:** Build a WebTransport server endpoint loading mkcert PEM certs
**When to use:** Any WebTransport server startup
**Example:**
```rust
// Source: docs.rs/wtransport/latest/wtransport + BiagioFesta/wtransport README
use wtransport::{Endpoint, Identity, ServerConfig};

async fn run_wt_server(cert_path: &str, key_path: &str, port: u16) -> anyhow::Result<()> {
    let identity = Identity::load_pemfiles(cert_path, key_path).await?;
    let config = ServerConfig::builder()
        .with_bind_default(port)
        .with_identity(identity)
        .build();

    let server = Endpoint::server(config)?;
    tracing::info!("WebTransport listening on :{}", port);

    loop {
        let incoming = server.accept().await;
        tokio::spawn(async move {
            if let Err(e) = handle_wt_session(incoming).await {
                tracing::error!("WT session error: {e}");
            }
        });
    }
}

async fn handle_wt_session(incoming: wtransport::IncomingSession) -> anyhow::Result<()> {
    let request = incoming.await?;
    let conn = request.accept().await?;
    // conn.accept_bi(), conn.accept_uni(), conn.receive_datagram()
    Ok(())
}
```
[CITED: docs.rs/wtransport/latest/wtransport]

### Pattern 2: tokio-tungstenite WebSocket fallback listener

**What:** TCP listener that upgrades connections to WebSocket for QUIC-blocked fallback
**When to use:** Parallel to WebTransport listener; client connects here when QUIC fails
**Example:**
```rust
// Source: github.com/snapview/tokio-tungstenite/blob/master/examples/server.rs
use tokio::net::TcpListener;
use tokio_tungstenite::accept_async;
use futures_util::{SinkExt, StreamExt};

async fn run_ws_server(port: u16) -> anyhow::Result<()> {
    let listener = TcpListener::bind(format!("0.0.0.0:{}", port)).await?;
    tracing::info!("WebSocket fallback listening on :{}", port);

    while let Ok((stream, addr)) = listener.accept().await {
        tokio::spawn(async move {
            match accept_async(stream).await {
                Ok(ws) => {
                    let (mut write, mut read) = ws.split();
                    while let Some(Ok(msg)) = read.next().await {
                        // echo for latency probe
                        if write.send(msg).await.is_err() { break; }
                    }
                }
                Err(e) => tracing::warn!("WS upgrade failed from {addr}: {e}"),
            }
        });
    }
    Ok(())
}
```
[CITED: github.com/snapview/tokio-tungstenite examples]

### Pattern 3: Dual-listener main() with tokio::join!

**What:** Spawn both listeners concurrently in one binary
**When to use:** Required structure for INFRA-01 + INFRA-05
**Example:**
```rust
// Source: tokio docs — concurrent task execution pattern [ASSUMED]
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt::init();

    let cert = std::env::var("CERT_PATH").unwrap_or_else(|_| "certs/localhost+2.pem".into());
    let key  = std::env::var("KEY_PATH").unwrap_or_else(|_| "certs/localhost+2-key.pem".into());

    tokio::try_join!(
        run_wt_server(&cert, &key, 4433),
        run_ws_server(8080),
    )?;
    Ok(())
}
```

### Pattern 4: Latency echo handler

**What:** Receive a probe message containing client timestamp, reply with server-stamped echo
**When to use:** Success criterion 3 — sub-10ms LAN round-trip verification
**Example:**
```rust
// [ASSUMED] — standard echo pattern
use std::time::{SystemTime, UNIX_EPOCH};

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as u64
}

// Client sends: { "type": "ping", "client_ts": <ms> }
// Server replies: { "type": "pong", "client_ts": <ms>, "server_ts": <ms> }
// Client measures: server_ts - client_ts (one-way) or total RTT on receipt
```

### Anti-Patterns to Avoid

- **Blocking calls inside tokio tasks:** Never call `std::thread::sleep` or synchronous file I/O inside `tokio::spawn`. Use `tokio::time::sleep` and `tokio::fs`.
- **Running both listeners in sequence:** Do NOT `await` the WebTransport listener then start WebSocket. Use `tokio::join!` or `tokio::spawn` both so they run concurrently.
- **Loading cert files synchronously at startup:** `Identity::load_pemfiles` is async — must be `await`ed inside an async context, not in a sync `main()`.
- **Forgetting the Chrome WebTransport flag:** Even with a valid mkcert cert, Chrome will reject QUIC connections unless `chrome://flags/#webtransport-developer-mode` is enabled. This is phase-critical.
- **Using a self-signed cert without mkcert CA:** Raw self-signed certs (openssl self-signed) will NOT work with WebTransport even with the Chrome flag. The cert must be signed by a CA in the system trust store. mkcert does this automatically.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| QUIC/HTTP3 transport | Custom QUIC impl | wtransport 0.7.1 | QUIC is extraordinarily complex (packet loss recovery, flow control, crypto); wtransport wraps quinn which wraps rustls |
| WebSocket framing | Custom WebSocket parser | tokio-tungstenite | WebSocket masking, ping/pong, fragmentation are fiddly; RFC 6455 compliance bugs are common |
| TLS certificate signing | openssl commands | mkcert | mkcert handles CA install + cert signing in one command; Chrome QUIC rejects plain self-signed certs regardless |
| Async runtime | Custom thread pool | tokio | Work-stealing, multi-thread scheduling, io_uring integration — tokio covers this; custom impl would regress latency |
| Latency measurement | Complex stats | `std::time::Instant` / `SystemTime` | Millisecond precision is sufficient; no library needed |

**Key insight:** The complexity of QUIC and TLS is so high that even experienced teams do not hand-roll them. The entire rationale for Rust + wtransport is to get correct, low-latency network code without implementing protocol-level details.

---

## Common Pitfalls

### Pitfall 1: Chrome rejects mkcert certs for WebTransport without the dev flag

**What goes wrong:** Server starts, mkcert cert loads successfully, but Chrome throws `WebTransport connection failed` or `ERR_QUIC_HANDSHAKE_FAILED`.
**Why it happens:** Chrome's QUIC implementation enforces that certificates must be issued by a root CA listed in its bundled trust store. mkcert's local CA is NOT in Chrome's bundled list, only in the system OS trust store. QUIC bypasses the OS store for cert validation by default unless the dev flag is enabled.
**How to avoid:** Document `chrome://flags/#webtransport-developer-mode` as a mandatory dev setup step. Add it to the project README. In CI/CD testing, use a headless Chrome launched with `--ignore-certificate-errors-spki-list=<hash>` instead.
**Warning signs:** Chrome DevTools shows WebTransport connection attempt but no successful session; server logs show no incoming session accepted.

### Pitfall 2: wtransport accept() double-await pattern is non-obvious

**What goes wrong:** Calling `server.accept().await?` once returns an `IncomingSession`, not a live `Connection`. Treating it as a connection immediately panics or returns wrong type errors.
**Why it happens:** wtransport separates the network-level session arrival (first await) from the HTTP/3 request-level accept (second await). This mirrors the WebTransport spec's two-step handshake.
**How to avoid:** Follow the exact three-step pattern: `incoming_session = server.accept().await` → `request = incoming_session.await?` → `conn = request.accept().await?`.
**Warning signs:** Compile errors about mismatched types on the connection variable; `IncomingSession` does not have `accept_bi()` method.

### Pitfall 3: WebSocket listener on same port as WebTransport is impossible

**What goes wrong:** Attempting to bind both wtransport (QUIC/UDP) and tokio-tungstenite (TCP) to port 4433 on the same address fails because they are different transport protocols and the OS assigns port listeners per-protocol.
**Why it happens:** wtransport uses UDP (QUIC) while tokio-tungstenite uses TCP. Different socket types cannot share the exact same port + address combination on most OSes.
**How to avoid:** Use separate ports — WebTransport on 4433 (UDP), WebSocket fallback on 8080 (TCP). The client decides which to use based on protocol availability.
**Warning signs:** `bind: address already in use` errors, or silent failure where one listener blocks the other.

### Pitfall 4: tokio-tungstenite requires futures-util for stream operations

**What goes wrong:** `ws.split()`, `read.next()`, `write.send()` don't compile because `StreamExt` and `SinkExt` traits are not in scope.
**Why it happens:** tokio-tungstenite returns a `WebSocketStream` that implements futures `Stream` and `Sink` traits, which require `futures_util::StreamExt` and `futures_util::SinkExt` to be in scope.
**How to avoid:** Add `futures-util = "0.3"` to Cargo.toml and `use futures_util::{SinkExt, StreamExt};` at the top of the ws handler file.
**Warning signs:** Compiler error "no method named `split` found for type `WebSocketStream`" or "no method `next` found".

### Pitfall 5: mkcert certificate SAN must include all addresses clients will use

**What goes wrong:** mkcert cert generated for `localhost` only; connecting via `127.0.0.1` or the machine's LAN IP fails TLS handshake.
**Why it happens:** TLS certificate validation checks the Subject Alternative Name (SAN) field against the hostname used in the connection. `localhost` ≠ `127.0.0.1` from the browser's perspective.
**How to avoid:** Generate with `mkcert localhost 127.0.0.1 ::1 <lan-ip>` to cover all likely connection addresses. For dev, at minimum: `mkcert localhost 127.0.0.1 ::1`.
**Warning signs:** TLS error when connecting via IP address while hostname connection works.

---

## Code Examples

### Cargo.toml server workspace member
```toml
# Source: crates.io verified versions — 2026-07-06
[package]
name = "immersive-rt-server"
version = "0.1.0"
edition = "2021"

[dependencies]
wtransport = "0.7"
tokio = { version = "1", features = ["macros", "rt-multi-thread", "fs", "io-util", "net", "sync"] }
tokio-tungstenite = "0.29"
futures-util = "0.3"
anyhow = "1"
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
```

### mkcert setup commands (Linux)
```bash
# Source: github.com/FiloSottile/mkcert README [CITED]
# Install mkcert
sudo apt install mkcert  # Debian/Ubuntu
# OR: download binary from https://github.com/FiloSottile/mkcert/releases

# One-time CA install (installs into OS trust store)
mkcert -install

# Generate dev certs (run from project root)
mkdir -p certs
cd certs && mkcert localhost 127.0.0.1 ::1
# Creates: localhost+2.pem  localhost+2-key.pem
cd ..

# .gitignore certs/ — never commit private key
echo "certs/" >> .gitignore
```

### Chrome WebTransport dev flag (REQUIRED for local dev)
```
# Navigate in Chrome:
chrome://flags/#webtransport-developer-mode
# Set to: Enabled
# Relaunch Chrome

# Alternative: launch Chrome with flag (for CI/CD):
# google-chrome --ignore-certificate-errors-spki-list=<hash>
# Get hash: openssl x509 -in certs/localhost+2.pem -noout -fingerprint -sha256
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| WebSocket for real-time server | WebTransport over QUIC | Chrome 97 (2021), now Baseline (2026) | UDP datagrams, stream multiplexing, no head-of-line blocking |
| Node.js WebTransport server | Rust (wtransport) | wtransport first released May 2023 | GC-free relay path; tokio handles 100k+ concurrent conns |
| Self-signed TLS for QUIC dev | mkcert + Chrome dev flag | Chrome added WT dev flag ~2022 | Removes certificate chain complexity for local dev |
| Safari not supporting WebTransport | Safari 26.4+ (March 2026) | March 2026 | WebTransport is now Baseline — all major browsers supported |

**Deprecated/outdated:**
- Raw `openssl req -x509` self-signed certs for WebTransport: Chrome QUIC rejects these even with system trust store install. mkcert is the correct approach.
- `webtransport-developer-mode` flag: still required in 2026 for mkcert certs in local dev.

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | WebSocket fallback uses separate TCP port (8080) from WebTransport QUIC port (4433) | Architecture Patterns, Pitfall 3 | If a single-port multiplexing solution exists (e.g., protocol detection), the port split design is unnecessary. Risk: low — QUIC/UDP vs TCP/WS on same port is a well-known limitation. |
| A2 | `tokio::try_join!` is the correct idiom for running two infallible server loops | Pattern 3 code example | If listeners return on error and should be restarted, `try_join!` will kill both on first error. Could need retry loops. |
| A3 | `futures-util = "0.3"` is the correct companion for tokio-tungstenite stream operations | Code examples | Version mismatch between futures-util and tokio-tungstenite could cause compile errors. Verify compatible versions when adding. |
| A4 | Latency probe design (JSON timestamps over WebTransport datagram) is sufficient for <10ms LAN test | Pattern 4 | JSON serialization adds ~5-10µs overhead; for latency testing this is negligible vs. 10ms target. |

---

## Open Questions (RESOLVED)

1. **Should the WebSocket fallback on port 8080 require TLS (WSS) or plain WS?**
   - **RESOLVED: Plain ws:// for Phase 1 (LAN dev only).** WSS deferred to Phase 2 when Docker TLS/prod setup is addressed. Plan 03 Task 1 explicitly implements plain WS.

2. **Should the Cargo workspace include client crates now, or server-only?**
   - **RESOLVED: Server-only workspace (`members = ["server"]`).** Client crates added in Phases 4+ when phone/desktop client implementation begins.

3. **Latency probe: WebTransport datagram vs. bidirectional stream?**
   - **RESOLVED: Bidirectional stream.** Plan 02 Task 2 uses `conn.accept_bi()` for the echo probe to guarantee delivery. Unreliable datagrams reserved for actual sensor data in Phase 5.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| rustc / cargo | Rust binary build | Yes | rustc 1.93.1, cargo 1.93.1 | — |
| mkcert | TLS cert generation for dev | No | — | Manual cert generation (complex); install mkcert as Wave 0 task |
| Docker | Container build verification | Yes | 29.6.0 | — |
| Node.js | Client testing scripts (optional) | Yes | v25.6.1 | — |

**Missing dependencies with no fallback:**
- mkcert: required for WebTransport TLS in dev; must be installed as part of Wave 0 / dev setup. `sudo apt install mkcert` on this Debian/Ubuntu system.

**Missing dependencies with fallback:**
- None beyond mkcert.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Rust built-in (`cargo test`) |
| Config file | none — cargo test runs automatically |
| Quick run command | `cargo test -p immersive-rt-server` |
| Full suite command | `cargo test --workspace` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| INFRA-01 | Server binary builds without warnings | unit/compile | `cargo build 2>&1 \| grep -c warning` | Wave 0 |
| INFRA-01 | WebTransport endpoint accepts a connection | integration (manual Chrome) | Manual — Chrome browser required | Manual only |
| INFRA-01 | `cargo test` passes | unit | `cargo test -p immersive-rt-server` | Wave 0 |
| INFRA-05 | WebSocket echo round-trips | integration | `cargo test test_ws_echo` | Wave 0 |
| Success Criterion 3 | Latency probe < 10ms on LAN | integration (manual) | Manual LAN test with Chrome | Manual only |

**Note on manual tests:** WebTransport requires a real browser (Chrome with dev flag) — automated headless testing of the full WT handshake is out of scope for Phase 1. The `cargo test` suite covers unit logic; browser integration is validated manually against success criterion 1 and 3.

### Sampling Rate

- **Per task commit:** `cargo test -p immersive-rt-server`
- **Per wave merge:** `cargo test --workspace`
- **Phase gate:** Full suite green + manual Chrome WebTransport verification before `/gsd-verify-work`

### Wave 0 Gaps

- [ ] `server/src/main.rs` — skeleton binary (even empty) needed before tests compile
- [ ] `Cargo.toml` (workspace root) — workspace definition
- [ ] `server/Cargo.toml` — package definition with dependencies
- [ ] `certs/` directory + mkcert cert generation — required for WT server to start
- [ ] `server/tests/ws_echo.rs` — covers INFRA-05 WebSocket round-trip

---

## Security Domain

### Applicable ASVS Categories (Level 1)

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No | Phase 1 is transport-only, no user auth yet |
| V3 Session Management | No | Session management comes in Phase 3 |
| V4 Access Control | No | No routes or access policies in Phase 1 |
| V5 Input Validation | Yes (minimal) | Reject malformed latency probe JSON; don't panic on bad input |
| V6 Cryptography | Yes | Use wtransport's built-in TLS (rustls); never configure cipher suites manually; mkcert CA only for dev |
| V9 Communications | Yes | TLS required for all WebTransport connections; no plaintext QUIC |

### Known Threat Patterns for Rust WebTransport Server

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Malformed WebTransport handshake | Tampering | wtransport handles protocol-level validation internally via quinn/rustls |
| Unbounded connection acceptance (DDoS) | DoS | Add max-connections limit in accept loop; Phase 1 minimal impl should still bound concurrency |
| Private key exposure in git | Information Disclosure | `certs/` must be in `.gitignore` from day one; never commit key files |
| Plain WS fallback over hostile network | Tampering | Phase 1 WS is plain (ws://) — acceptable for LAN dev; add WSS before any internet exposure |
| Panic on unwrap() in async tasks | DoS | Use `anyhow::Result` throughout; log errors instead of panicking; spawned task panics don't kill the whole server in tokio |

---

## Sources

### Primary (MEDIUM confidence)

- [docs.rs/wtransport/latest/wtransport](https://docs.rs/wtransport/latest/wtransport/) — ServerConfig builder API, Identity::load_pemfiles, accept loop pattern
- [crates.io/crates/wtransport](https://crates.io/crates/wtransport) — version 0.7.1 confirmed, published 2023-05-25, 17.5k weekly downloads
- [crates.io/crates/tokio](https://crates.io/crates/tokio) — version 1.52.3 confirmed, 14.2M weekly downloads
- [crates.io/crates/tokio-tungstenite](https://crates.io/crates/tokio-tungstenite) — version 0.29.0 confirmed, 4M weekly downloads

### Secondary (LOW confidence)

- [github.com/BiagioFesta/wtransport](https://github.com/BiagioFesta/wtransport) — README server setup pattern, examples directory
- [github.com/snapview/tokio-tungstenite examples/server.rs](https://github.com/snapview/tokio-tungstenite/blob/master/examples/server.rs) — accept_async pattern, TcpListener loop
- [github.com/FiloSottile/mkcert](https://github.com/FiloSottile/mkcert) — installation and cert generation commands
- [groups.google.com/a/chromium.org — WebTransport dev group](https://groups.google.com/a/chromium.org/g/web-transport-dev/c/qDt0dek65ZU) — Chrome dev flag requirement for mkcert certs
- [WebTransport vs WebSockets — instatunnel.substack.com](https://instatunnel.substack.com/p/webtransport-vs-websockets-architecting) — QUIC fallback strategy patterns

### Tertiary (LOW confidence)

- WebSearch: Chrome WebTransport + self-signed cert developer flag requirement
- WebSearch: Rust cargo workspace structure patterns

---

## Metadata

**Confidence breakdown:**
- Standard stack: MEDIUM — all three crates verified on crates.io with confirmed version numbers; API patterns cross-checked against docs.rs and GitHub README
- Architecture: MEDIUM — dual-listener pattern (separate ports for QUIC vs TCP) is a verified architectural necessity; code examples derived from official docs but not tested
- Pitfalls: MEDIUM — Chrome cert validation behavior and wtransport double-await pattern confirmed via official sources; WebSocket `futures-util` requirement is known behavior

**Research date:** 2026-07-06
**Valid until:** 2026-08-06 (stable libraries; wtransport 0.7.x may increment patch versions)
