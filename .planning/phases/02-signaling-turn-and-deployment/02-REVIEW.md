---
phase: 02
reviewed: 2026-07-07T00:00:00Z
depth: standard
files_reviewed: 13
files_reviewed_list:
  - server/src/broker.rs
  - server/src/signaling.rs
  - server/src/turn_creds.rs
  - server/src/ws_server.rs
  - server/src/wt_server.rs
  - server/src/main.rs
  - server/src/lib.rs
  - server/src/echo.rs
  - server/Cargo.toml
  - server/tests/broker_relay.rs
  - server/tests/ws_echo.rs
  - docker/Dockerfile.server
  - docker/coturn/turnserver.conf
  - docker-compose.yml
status: has-findings
critical: 4
warning: 10
info: 4
---

# Phase 02: Code Review Report

**Reviewed:** 2026-07-07
**Depth:** standard
**Files Reviewed:** 13 (+ echo.rs pulled in via lib.rs declaration)
**Status:** has-findings

## Summary

Reviewed the Phase 2 signaling relay, TURN credential generation, and Docker deployment stack. The core relay logic in broker.rs is sound and the HMAC-SHA1 credential algorithm matches coturn's expected format. However, the security posture of the deployment layer has four blockers that must be resolved before any internet-facing deployment: the TURN credential endpoint is entirely unauthenticated and served over plain HTTP, the coturn config lacks SSRF protections, and the Docker image runs as root. The relay logic itself has two significant correctness/security issues: the `from` field in signaling envelopes is trusted without verification (allowing impersonation), and the WebTransport server has no connection limit while the WebSocket server does.

---

## Critical Issues

### CR-01: TURN Credential Endpoint Has No Authentication

**File:** `server/src/main.rs:72-74`
**Issue:** The `/turn-credentials` HTTP endpoint returns valid TURN credentials to any caller without any form of authentication. Any internet-connected host — not just game clients — can call this endpoint and receive credentials that authorize relaying traffic through the coturn server. This enables bandwidth theft, cost amplification, and circumvention of the relay scope restriction described in CLAUDE.md ("scope TURN to data channels only").

**Fix:** At minimum, require a bearer token or shared API key header checked in the handler before issuing credentials. A short-lived session token issued during WebSocket/WebTransport registration is the appropriate mechanism here — the client proves it has an active signaling session before receiving TURN creds.

```rust
// Minimal header-based guard (replace with proper session token check):
async fn turn_creds_handler(
    headers: axum::http::HeaderMap,
    State(state): State<Arc<AppState>>,
) -> Result<Json<turn_creds::TurnCredentials>, (axum::http::StatusCode, String)> {
    let token = headers
        .get("Authorization")
        .and_then(|v| v.to_str().ok())
        .ok_or_else(|| (axum::http::StatusCode::UNAUTHORIZED, "Missing Authorization header".into()))?;
    if token != format!("Bearer {}", state.api_token) {
        return Err((axum::http::StatusCode::UNAUTHORIZED, "Invalid token".into()));
    }
    turn_creds::generate_turn_credentials(&state.turn_shared_secret, "anonymous", 300)
        .map(Json)
        .map_err(|e| (axum::http::StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))
}
```

---

### CR-02: `from` Field Not Validated Against Sender's Registered ID (Message Spoofing)

**Files:** `server/src/ws_server.rs:200-209`, `server/src/wt_server.rs:169-185`
**Issue:** The relay accepts the `from` field in every signaling envelope at face value, without verifying that it matches the sender's registered client ID. A client registered as `"phone-1"` can send `{"type":"offer","from":"desktop-1","to":"phone-1",...}` and the recipient will believe the message originated from `"desktop-1"`. WebRTC peers use the `from` field to address their answer — a spoofed `from` causes the answer to be sent to the wrong party, enabling man-in-the-middle session hijacking of WebRTC negotiations.

**Fix:** After parsing the envelope, assert `envelope.from == my_id` before routing. Mismatch should be logged and the message dropped.

```rust
// In ws_server.rs relay arm, after parsing the envelope:
if envelope.from != *my_id.as_ref().unwrap() {
    tracing::warn!(
        registered = %my_id.as_ref().unwrap(),
        claimed_from = %envelope.from,
        "WS client spoofed 'from' field, dropping message"
    );
    continue;
}

// In wt_server.rs relay arm, after parsing the envelope:
if envelope.from != my_id {
    tracing::warn!(
        registered = %my_id,
        claimed_from = %envelope.from,
        "WT client spoofed 'from' field, dropping message"
    );
    let _ = send.finish().await;
    continue;
}
```

---

### CR-03: coturn Config Allows Relay to Loopback and Private Network Addresses (SSRF)

**File:** `docker/coturn/turnserver.conf`
**Issue:** The configuration sets `no-multicast-peers` but omits `no-loopback-peers` and has no `denied-peer-ip` rules for RFC 1918 private ranges. Any client holding valid TURN credentials — which are trivially obtainable because CR-01 is present — can instruct the coturn server to open a relay channel to `127.0.0.1`, `169.254.169.254` (AWS/GCP metadata endpoint), or any private 10.x/172.16-31.x/192.168.x address. This is a classic TURN-based SSRF that can be used to probe internal services from the TURN server's network perspective.

**Fix:** Add the following to `turnserver.conf`:

```
no-loopback-peers
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=100.64.0.0-100.127.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=::1
denied-peer-ip=fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff
```

---

### CR-04: Docker Server Image Runs as Root

**File:** `docker/Dockerfile.server:28-41` (runtime stage)
**Issue:** The runtime stage has no `RUN useradd` or `USER` directive. The `immersive-rt-server` binary runs as UID 0 inside the container. Any remote code execution vulnerability in the server yields a root shell, and any container escape grants host root. The server only needs to bind to ports above 1024 (4433, 9090, 8081), so a non-root user is fully sufficient.

**Fix:** Add before the `CMD` line:

```dockerfile
RUN groupadd --system immersivert \
    && useradd --system --gid immersivert --no-create-home immersivert
USER immersivert
```

---

## Warnings

### WR-01: Silent Client ID Hijacking via Re-registration

**File:** `server/src/broker.rs:33-36`
**Issue:** `SignalingBroker::register()` silently overwrites any existing sender when called with an already-registered ID. When this happens, the original client's `broker_rx` channel becomes closed (its sender was dropped from the map), and that client's relay loop breaks on the next `recv()` returning `None`. Any connected client can therefore force-disconnect any other client simply by sending a `register` message claiming that client's ID. There is no locking, no conflict response, and no notification to the evicted client.

**Fix:** Either reject re-registration with an error response, or enforce ID uniqueness before inserting. If intentional (reconnect semantics), log a warning and ensure the displaced client is explicitly notified or already disconnected.

```rust
pub fn register(&self, id: ClientId) -> Result<mpsc::UnboundedReceiver<Vec<u8>>, &'static str> {
    if self.clients.contains_key(&id) {
        return Err("client ID already registered");
    }
    let (tx, rx) = mpsc::unbounded_channel::<Vec<u8>>();
    self.clients.insert(id, tx);
    Ok(rx)
}
```

---

### WR-02: WebTransport Server Has No Connection Limit

**File:** `server/src/wt_server.rs:32-40`
**Issue:** The WebSocket server is protected by a semaphore capping concurrent connections at 1024 (`ws_server.rs:20, 75`). The WebTransport server (`wt_server.rs`) has no equivalent guard — every accepted connection gets an unbounded `tokio::spawn`. An attacker can open thousands of WebTransport connections to exhaust file descriptors or task memory before any connection is authenticated.

**Fix:** Add a `Semaphore` in `wt_server::run` with the same 1024 ceiling used by the WS server, mirroring the pattern in `ws_server.rs:75-99`.

---

### WR-03: TURN Shared Secret Visible in Process Argument List

**File:** `docker-compose.yml:51-52`
**Issue:** `--static-auth-secret=${TURN_SHARED_SECRET}` is passed as a positional command-line argument to coturn. Command-line arguments are visible in `ps aux`, `docker inspect`, and `/proc/<pid>/cmdline` to any process on the host with appropriate permissions. If the host is shared or logged by monitoring infrastructure, the secret leaks.

**Fix:** Use coturn's `static-auth-secret` directive directly in `turnserver.conf` and inject the value via a Docker secret or environment variable substitution in an entrypoint script that writes to the conf file at startup, so the secret is never on the command line.

```yaml
# In docker-compose.yml, replace command arg with env injection:
environment:
  - TURN_SHARED_SECRET=${TURN_SHARED_SECRET}
# In entrypoint.sh: echo "static-auth-secret=${TURN_SHARED_SECRET}" >> /etc/coturn/turnserver.conf
```

---

### WR-04: No Timeout on WebTransport Registration Stream Read

**File:** `server/src/wt_server.rs:75-92`
**Issue:** After accepting a WebTransport connection, the server enters a synchronous read loop waiting for the client to send a "register" message and close the stream with FIN. A client that opens a connection but never sends FIN will hold a task indefinitely, leaking a goroutine-equivalent tokio task and blocking a connection slot. The relay loop (lines 117-246) similarly has no idle timeout — a registered client that never sends or receives holds resources forever.

**Fix:** Wrap the registration read with `tokio::time::timeout`:

```rust
let buf = tokio::time::timeout(
    std::time::Duration::from_secs(10),
    async {
        let mut buf = Vec::new();
        loop {
            let mut chunk = vec![0u8; 4096];
            match recv_init.read(&mut chunk).await? {
                Some(n) => buf.extend_from_slice(&chunk[..n]),
                None => break,
            }
            if buf.len() > 65_536 { return Err(anyhow::anyhow!("oversized")); }
        }
        Ok::<Vec<u8>, anyhow::Error>(buf)
    }
)
.await
.context("registration timed out")??;
```

---

### WR-05: `unwrap()` on Semaphore Acquire Can Panic the Accept Loop

**File:** `server/src/ws_server.rs:79`
**Issue:** `sem.clone().acquire_owned().await.unwrap()` will panic if the `Semaphore` is closed. The semaphore is never explicitly closed in the current code, but defensive practice requires `.expect()` or explicit error handling. A future refactor that adds graceful shutdown via `sem.close()` will immediately introduce a panic in the production accept loop.

**Fix:**
```rust
let permit = sem.clone().acquire_owned().await
    .expect("WS connection semaphore was unexpectedly closed");
```

---

### WR-06: No TURN Quota or Rate Limiting

**File:** `docker/coturn/turnserver.conf`
**Issue:** No `total-quota`, `user-quota`, or `max-bps` directives are configured. A single client with valid credentials can monopolize all relay bandwidth and connection slots. Combined with the unauthenticated credential endpoint (CR-01), resource exhaustion is trivial.

**Fix:**
```
# Add to turnserver.conf
total-quota=100
user-quota=10
max-bps=500000
```

---

### WR-07: `yield_now()` Is Not a Reliable Synchronization Barrier in Tests

**Files:** `server/tests/broker_relay.rs:51`, `server/tests/ws_echo.rs:35`
**Issue:** Both integration tests use `tokio::task::yield_now().await` between sending registration messages and sending the test payload, hoping the server has processed the registration. A single scheduler yield is not guaranteed to run all pending tasks to completion. Under load or on a different Tokio runtime flavor, the server task may not have processed the `register` message before the test sends the `offer`, causing the message to be silently dropped (logged as "not yet registered") and the test to hang waiting for a reply that never arrives.

**Fix:** Use a proper synchronization mechanism. The simplest approach is a short `tokio::time::sleep` (not a single yield) or, better, retry-with-timeout on the receive:

```rust
// Replace yield_now() with:
tokio::time::sleep(std::time::Duration::from_millis(50)).await;
```

Or restructure the test to wait for the server to echo back an acknowledgement of registration before proceeding.

---

### WR-08: TURN Credential Endpoint Served Over Plain HTTP

**File:** `server/src/main.rs:75-76`
**Issue:** The axum HTTP server listening on `http_port` is a plain TCP listener with no TLS. TURN credentials are returned in cleartext over the network. On any non-localhost path (cloud VM, remote dev, production), credentials are visible to network observers. Port 8081 is also exposed directly to the public internet in `docker-compose.yml:27`.

**Fix:** Either add TLS to the HTTP server using the same cert/key used by the WS server, or restrict `0.0.0.0` binding to `127.0.0.1` and expose credentials only through the already-TLS-protected WS/WT connection as part of the registration handshake.

---

### WR-09: Signaling Messages Are Silently Dropped on Transient WT Stream Errors

**File:** `server/src/wt_server.rs:203-235`
**Issue:** In the outbound arm of the WT relay loop, if `conn.open_bi()` or the subsequent stream open fails, the payload is dropped with only a warning log and execution continues. For WebRTC `offer` and `answer` messages (which are not automatically retried by the browser), a single dropped message silently breaks the peer connection negotiation. ICE candidates suffer the same issue. There is no delivery confirmation, retry, or error reporting back to the sender.

**Fix:** At minimum, when an outbound stream open fails, break the relay loop and close the connection rather than continuing silently. If the connection is broken, the client should reconnect and retry. A `continue` after a stream open failure is incorrect — it implies the connection is still usable when the evidence suggests otherwise.

---

### WR-10: `echo` Module Is Dead Code

**Files:** `server/src/echo.rs`, `server/src/lib.rs:2`, `server/src/main.rs:2`
**Issue:** The `echo` module is declared in both `main.rs` and `lib.rs` but is never referenced by any live server code. Both `now_ms` and `EchoMessage` are annotated `#[allow(dead_code)]`, confirming the module serves no production purpose. It is compiled twice (once per crate root) and exported as a public API surface from the library crate without intent.

**Fix:** Remove `mod echo;` from `main.rs` and `pub mod echo;` from `lib.rs`, and delete `server/src/echo.rs`. If latency probing is needed in a future phase, add it then with integration into the actual relay loop.

---

## Info

### IN-01: Duplicate Module Declarations Between `main.rs` and `lib.rs`

**Files:** `server/src/main.rs:1-6`, `server/src/lib.rs:1-6`
**Issue:** Both crate roots declare the same six modules (`broker`, `echo`, `signaling`, `turn_creds`, `ws_server`, `wt_server`). When both `src/main.rs` and `src/lib.rs` exist, Cargo produces a binary crate and a library crate. The binary's `main.rs` redeclares all modules as private, compiling them a second time rather than depending on the library crate. The canonical Rust pattern is for `main.rs` to import from the library: `use immersive_rt_server::*;`.

**Fix:** Replace all `mod` declarations in `main.rs` with `use immersive_rt_server::...;` imports, so modules compile once and the binary uses the public library API.

---

### IN-02: `String::from_utf8_lossy` on Known-Valid UTF-8 Output

**File:** `server/src/ws_server.rs:229`
**Issue:** `serde_json::to_vec` always produces valid UTF-8 (JSON is UTF-8 by spec). Using `String::from_utf8_lossy` scans all bytes for invalid sequences unnecessarily. The `into_owned()` call then allocates a new `String` even though the input was borrowed. This is harmless but wasteful.

**Fix:**
```rust
// Replace:
let text = String::from_utf8_lossy(&payload).into_owned();
if write.send(Message::Text(text.into())).await.is_err() { ... }

// With:
let text = String::from_utf8(payload).expect("serde_json always produces valid UTF-8");
if write.send(Message::Text(text.into())).await.is_err() { ... }
```

---

### IN-03: Hardcoded Userid `"anonymous"` in All TURN Credential Requests

**File:** `server/src/main.rs:24`
**Issue:** Every call to `generate_turn_credentials` uses the static userid `"anonymous"`. coturn logs include the username from the credential, making it impossible to correlate relay activity with specific clients. If per-client TURN quotas are ever added (see WR-06), the fixed username defeats them.

**Fix:** Accept a caller-supplied userid — e.g., derive it from the client's registered signaling ID, a session token, or a random nonce. Pass it through the HTTP request (query param or request body) so coturn logs carry meaningful identifiers.

---

### IN-04: `.local` Domain Used as TURN Realm

**File:** `docker/coturn/turnserver.conf:22`
**Issue:** `realm=immersivert.local` uses the `.local` top-level domain, which is reserved for mDNS/Bonjour multicast DNS (RFC 6762). In production, the realm should be the actual public domain name of the service (e.g., `turn.immersivert.io`). While coturn's realm is not DNS-resolved, using `.local` can confuse clients and monitoring tools and is non-standard for a production deployment.

**Fix:** Set `realm=` to the actual production domain or a meaningful non-`.local` identifier. Keep the dev config distinct from the production config.

---

_Reviewed: 2026-07-07_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
