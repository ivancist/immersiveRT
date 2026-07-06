---
phase: "01"
phase_name: "server-and-transport-foundation"
status: "issues_found"
files_reviewed: 7
files_reviewed_list:
  - server/Cargo.toml
  - server/src/echo.rs
  - server/src/lib.rs
  - server/src/main.rs
  - server/src/ws_server.rs
  - server/src/wt_server.rs
  - server/tests/ws_echo.rs
findings:
  critical: 3
  warning: 6
  info: 3
  total: 12
---

# Phase 01: Code Review Report

**Reviewed:** 2026-07-06T00:00:00Z
**Depth:** standard
**Files Reviewed:** 7
**Status:** issues_found

## Summary

Seven source files reviewed for the Rust WebTransport + WebSocket server (Phase 1). Three critical issues were found: the WebSocket accept loop exits silently on any transient OS error and returns `Ok(())`, which causes `tokio::try_join!` to cancel the WebTransport server and bring down the entire process with exit code 0 and no error log; RFC 6455 control frames (Ping, Close) are echoed verbatim rather than handled, which can corrupt WebSocket state; and the WebTransport stream reader uses a fixed 4096-byte buffer with a single `recv.read()` call, meaning any message larger than 4096 bytes or any message split across QUIC packets will be silently desynchronized and all subsequent reads on that connection will be corrupted. Six warnings address error swallowing, unclean stream teardown, and test reliability.

---

## Critical Issues

### CR-001: WebSocket accept loop exits silently — shuts down entire server on transient OS error

**Severity:** Critical
**File:** `server/src/ws_server.rs:9`

**Issue:** The accept loop is written as `while let Ok((stream, addr)) = listener.accept().await`. If `listener.accept()` returns `Err(_)` for any reason (EMFILE — too many open files, ENFILE — system file table full, a transient network stack error), the pattern match fails, the loop exits, and the function returns `Ok(())`. Because `tokio::try_join!` in `main.rs` treats either future completing as a signal to cancel the other, the WebTransport server is immediately cancelled. The process exits with code 0. No error is logged.

This is a production availability bug: a brief resource exhaustion spike (too many open file descriptors) that should recover immediately instead takes down the entire server permanently.

**Fix:**
```rust
pub async fn run(port: u16) -> anyhow::Result<()> {
    let listener = TcpListener::bind(format!("0.0.0.0:{}", port)).await?;
    tracing::info!("WebSocket fallback listening on :{}", port);

    loop {
        match listener.accept().await {
            Ok((stream, addr)) => {
                tokio::spawn(async move {
                    if let Err(e) = handle_ws_connection(stream, addr).await {
                        tracing::warn!("WS connection error from {addr}: {e}");
                    }
                });
            }
            Err(e) => {
                tracing::error!("WS accept error: {e}");
                // For transient errors, continue; for fatal errors, break.
                // A simple heuristic: check kind
                use std::io::ErrorKind;
                match e.kind() {
                    ErrorKind::ConnectionAborted
                    | ErrorKind::ConnectionReset
                    | ErrorKind::Interrupted => continue,
                    _ => return Err(e.into()),
                }
            }
        }
    }
}
```

---

### CR-002: WebSocket echo loop forwards RFC 6455 control frames verbatim — protocol violation

**Severity:** Critical
**File:** `server/src/ws_server.rs:27-29`

**Issue:** `while let Some(Ok(msg)) = read.next().await { write.send(msg).await ... }` forwards every `Message` variant, including `Message::Ping`, `Message::Pong`, and `Message::Close`, to the peer unchanged.

- Echoing `Message::Ping` back as a `Ping` (not a `Pong`) violates RFC 6455 §5.5.2–5.5.3. A conformant browser client will close the connection with a protocol error.
- Echoing `Message::Close` initiates a second Close handshake on top of the one the peer already started, corrupting the close sequence and potentially causing the connection to hang.

Note: tokio-tungstenite 0.29 internally auto-responds to Ping with Pong at the framing layer, but still surfaces `Message::Ping` to user code. Sending a second `Ping` back from user code is an independent, additional message — it does not suppress the auto-Pong.

**Fix:**
```rust
while let Some(Ok(msg)) = read.next().await {
    // Only echo data frames; control frames are handled by tungstenite internally.
    match &msg {
        Message::Text(_) | Message::Binary(_) => {}
        _ => continue,
    }
    if write.send(msg).await.is_err() {
        break;
    }
}
```

---

### CR-003: WebTransport stream read uses a single fixed-size buffer — partial reads silently corrupt all subsequent messages on the connection

**Severity:** Critical
**File:** `server/src/wt_server.rs:63-74`

**Issue:** `recv.read(&mut buf)` is called once with a 4096-byte buffer and the result is passed directly to `serde_json::from_slice`. QUIC streams are byte streams, not message streams. `recv.read()` can return any number of bytes from 1 to `buf.len()`. Two failure modes exist:

1. **Message larger than 4096 bytes:** Only the first 4096 bytes are read. The remainder stays in the stream buffer. `serde_json::from_slice` fails; the handler logs "Malformed echo message" and `continue`s to `accept_bi()`. But the original stream still has unread bytes; the peer is still sending on it. The connection is now desynchronized — every subsequent `accept_bi()` call opens a new QUIC stream, while the peer is blocked waiting for a response on the old stream.

2. **Message split across QUIC packets (any size):** Even a 100-byte JSON payload can arrive in two reads (e.g., 60 bytes + 40 bytes) if QUIC packets are fragmented or paced. The partial JSON parse fails, and the stream is abandoned as in case 1.

The `continue` on deserialization failure (line 76-79) does not discard the remaining bytes from the stream — it just moves on to the next `accept_bi()`. This turns any oversized or fragmented message into a permanent connection-level failure.

**Fix:** Read until the stream signals EOF (FIN), then parse:
```rust
loop {
    let (mut send, mut recv) = conn
        .accept_bi()
        .await
        .context("accept_bi failed — connection likely closed")?;

    // Read full stream payload (until FIN)
    let mut buf = Vec::new();
    loop {
        let mut chunk = vec![0u8; 4096];
        match recv.read(&mut chunk).await.context("recv read failed")? {
            Some(n) => buf.extend_from_slice(&chunk[..n]),
            None => break, // FIN — stream complete
        }
        // Guard against unbounded memory growth
        if buf.len() > 65_536 {
            tracing::warn!("Oversized message ({} bytes), dropping stream", buf.len());
            break;
        }
    }

    if buf.is_empty() {
        break; // Connection closed cleanly
    }

    let msg: EchoMessage = match serde_json::from_slice(&buf) {
        Ok(m) => m,
        Err(e) => {
            tracing::warn!("Malformed echo message ({e}), dropping");
            continue;
        }
    };
    // ... rest of handler
}
```

---

## Warnings

### WR-001: WebSocket read errors silently swallowed — operator-invisible client misbehavior

**Severity:** Warning
**File:** `server/src/ws_server.rs:27`

**Issue:** `while let Some(Ok(msg)) = read.next().await` silently drops `Some(Err(_))` — the pattern match simply stops iterating. Tungstenite errors include invalid UTF-8 in a Text frame, oversized frames, protocol violations, and IO errors. These are all silently discarded. The connection closes without any log entry, making client misbehavior invisible to operators.

**Fix:**
```rust
while let Some(result) = read.next().await {
    let msg = match result {
        Ok(m) => m,
        Err(e) => {
            tracing::warn!("WS read error from {addr}: {e}");
            break;
        }
    };
    // ... filter control frames and echo
}
```

---

### WR-002: WebTransport SendStream dropped without finish() on non-ping path — peer receives RESET_STREAM instead of EOF

**Severity:** Warning
**File:** `server/src/wt_server.rs:82-85`

**Issue:** When `msg.msg_type != "ping"`, the handler logs a warning and `continue`s. The `send` variable (a `wtransport::SendStream`) is dropped without calling `send.finish()`. Per the QUIC spec (RFC 9000 §3.3), dropping a `SendStream` without finishing it causes the QUIC implementation to send `RESET_STREAM`, signaling an abrupt stream termination with an error code. The peer's receive-half gets an error, not a clean EOF. For the current echo-only server this is benign, but it sets a bad precedent for production code where clean stream closure matters.

**Fix:**
```rust
if msg.msg_type != "ping" {
    tracing::warn!(msg_type = %msg.msg_type, "Unexpected message type, ignoring");
    let _ = send.finish().await; // Send clean FIN before dropping
    continue;
}
```

---

### WR-003: Invalid port environment variables silently fall back to defaults

**Severity:** Warning
**File:** `server/src/main.rs:13-20`

**Issue:** `.parse().unwrap_or(4433)` and `.parse().unwrap_or(8080)` silently ignore malformed port values. If an operator sets `WT_PORT=443a` or `WS_PORT=` by mistake, the server starts on the default port without any warning. The log line on line 22 shows the port values, but only after the silent fallback — the operator has no indication that their env var was rejected.

**Fix:**
```rust
let wt_port: u16 = std::env::var("WT_PORT")
    .unwrap_or_else(|_| "4433".into())
    .parse()
    .context("WT_PORT must be a valid u16 port number")?;
let ws_port: u16 = std::env::var("WS_PORT")
    .unwrap_or_else(|_| "8080".into())
    .parse()
    .context("WS_PORT must be a valid u16 port number")?;
```

---

### WR-004: No per-connection or global connection limit — unbounded resource consumption

**Severity:** Warning
**File:** `server/src/ws_server.rs:10` and `server/src/wt_server.rs:27`

**Issue:** Both servers spawn an unbounded number of tasks via `tokio::spawn` with no connection cap. A single client can open thousands of connections simultaneously. Each tokio task consumes a stack frame, and each WebSocket/WebTransport connection holds OS file descriptors and socket buffers. For a sub-20ms latency server, resource exhaustion from a connection flood will degrade all clients. There is no IP-based rate limiting either.

**Fix:** Use an `Arc<Semaphore>` with a configured limit (e.g., 1024 connections):
```rust
let sem = Arc::new(tokio::sync::Semaphore::new(1024));
loop {
    let permit = sem.clone().acquire_owned().await.unwrap();
    let (stream, addr) = listener.accept().await?;
    tokio::spawn(async move {
        let _permit = permit; // Dropped when connection closes
        handle_ws_connection(stream, addr).await
    });
}
```

---

### WR-005: WebSocket server has no maximum message size — memory exhaustion via large frames

**Severity:** Warning
**File:** `server/src/ws_server.rs:24`

**Issue:** `accept_async(stream)` uses tungstenite's default `WebSocketConfig`, which sets `max_message_size` to 64 MiB and `max_frame_size` to 16 MiB by default. For an IMU sensor relay, messages should be kilobytes at most. A malicious client sending 64 MiB frames can consume significant memory per connection and amplify it via the echo response. In the production system (which this stub prefigures), there is no protection against this.

**Fix:**
```rust
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;

let config = WebSocketConfig {
    max_message_size: Some(64 * 1024),   // 64 KiB — ample for IMU packets
    max_frame_size: Some(64 * 1024),
    ..Default::default()
};
let ws = accept_async_with_config(stream, Some(config)).await?;
```

---

### WR-006: Test server task bind failure is undetectable — misleading test error message

**Severity:** Warning
**File:** `server/tests/ws_echo.rs:9`

**Issue:** `tokio::spawn(immersive_rt_server::ws_server::run(18080))` drops the returned `JoinHandle`. If `TcpListener::bind("0.0.0.0:18080")` fails (port already in use on a CI machine, permission denied), `ws_server::run` returns an `Err`. The error is silently discarded by the dropped `JoinHandle`. The test then sleeps 50ms and fails at `connect_async` with the message "WebSocket connect failed — is port 18080 available?" — which happens to guess the cause correctly but provides no actual bind error.

**Fix:** Bind the listener before spawning so bind failure is immediately propagated as a test failure:
```rust
#[tokio::test]
async fn test_ws_echo() {
    // Bind before spawning so a port conflict is an immediate, clear test failure.
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("failed to bind test listener");
    let addr = listener.local_addr().expect("no local addr");

    tokio::spawn(immersive_rt_server::ws_server::run_with_listener(listener));

    let url = format!("ws://{}", addr);
    let (mut ws, _response) = connect_async(&url)
        .await
        .expect("WebSocket connect failed");
    // ... rest of test
}
```
This also eliminates the hardcoded port 18080 and the fragile 50ms sleep.

---

## Info

### IN-001: echo.rs functions marked #[allow(dead_code)] but are used by wt_server.rs

**Severity:** Info
**File:** `server/src/echo.rs:6` and `server/src/echo.rs:18`

**Issue:** Both `now_ms` and `EchoMessage` carry `#[allow(dead_code)]` attributes, but they are imported and used by `wt_server.rs` via `use crate::echo::{now_ms, EchoMessage}`. The attributes are not needed — the compiler does not warn about these as dead code when they are actually used. The attributes suggest the author was suppressing spurious warnings, which may indicate the crate's module structure was changed during development without cleaning up.

**Fix:** Remove both `#[allow(dead_code)]` attributes.

---

### IN-002: main.rs re-declares modules as private that lib.rs declares as public — double compilation

**Severity:** Info
**File:** `server/src/main.rs:1-3`

**Issue:** `main.rs` declares `mod echo; mod wt_server; mod ws_server;` as private modules. `lib.rs` declares the same three modules as `pub mod`. This means all three modules are compiled twice — once as part of the binary crate (`main.rs`) and once as part of the library crate (`lib.rs`). This is intentional in the dual-binary/library pattern, but it means that `main.rs` and `lib.rs` have separate module trees. Any change to module-level state (constants, statics) would not be shared between them. This is a maintainability risk if the codebase grows and someone adds shared state.

**Fix:** Either remove `lib.rs` (since the test uses `immersive_rt_server::ws_server::run`, `lib.rs` is necessary for the integration test) or have `main.rs` use the library crate directly: `use immersive_rt_server::{wt_server, ws_server};`. The latter is cleaner — the binary becomes a thin wrapper over the library.

---

### IN-003: WebTransport server ignores request.path() — any URL path is accepted

**Severity:** Info
**File:** `server/src/wt_server.rs:46-50`

**Issue:** `request.path()` is logged but not validated. The server accepts WebTransport connections regardless of path. This means clients connecting to `/wrong`, `/admin`, or any arbitrary path receive the same echo service. For Phase 1 this is acceptable, but it sets a pattern that must be corrected before routing multiple services (signaling, relay, health check) on the same server.

**Fix:** Add a path check before accepting:
```rust
if request.path() != "/echo" {
    tracing::warn!(path = %request.path(), "Rejecting unknown path");
    request.reject().await;
    return Ok(());
}
let conn = request.accept().await.context("WT session accept failed")?;
```

---

_Reviewed: 2026-07-06T00:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
