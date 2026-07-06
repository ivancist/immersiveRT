---
phase: 01-server-and-transport-foundation
plan: 02
subsystem: server/wt-server
tags: [rust, wtransport, webtransport, quic, tls, mkcert, echo, tokio]
status: complete

dependency_graph:
  requires:
    - symbol: EchoMessage
      kind: pub struct
      file: server/src/echo.rs
      plan: 01-01
    - symbol: now_ms
      kind: pub fn
      file: server/src/echo.rs
      plan: 01-01
  provides:
    - symbol: wt_server::run
      kind: pub async fn
      file: server/src/wt_server.rs
    - symbol: handle_wt_connection
      kind: async fn
      file: server/src/wt_server.rs
    - symbol: WebTransport listener on :4433
      kind: runtime
      file: target/debug/immersive-rt-server
  affects:
    - server/src/main.rs (comment update — wt_server stub marker removed)

tech_stack:
  added:
    - wtransport 0.7.1 Identity::load_pemfiles (async PEM cert loading)
    - wtransport 0.7.1 Endpoint::server (QUIC endpoint)
    - wtransport 0.7.1 IncomingSession / accept_bi (three-step accept pattern)
    - anyhow::Context for contextual error messages in async handlers
  patterns:
    - Three-step wtransport accept: IncomingSession.await -> request.accept() -> conn
    - One tokio::spawn per accepted connection; errors logged, accept loop continues (T-01-05)
    - serde_json::from_slice with typed EchoMessage — malformed JSON logged and dropped, no panic (T-01-06)
    - recv.read returns Option<usize> — None = clean stream close, exits connection loop

key_files:
  created: []
  modified:
    - server/src/wt_server.rs (full WebTransport listener replacing stub)
    - server/src/main.rs (comment updated — wt_server now real, ws_server still stub)

decisions:
  - "accept_bi() loop exits cleanly on None from recv.read — clean stream close is not an error"
  - "anyhow::Context used on every ? in handle_wt_connection for actionable error messages in production logs"
  - "ws_server.rs not modified in this plan — remains Plan 03 stub as intended"

metrics:
  duration_minutes: 35
  completed_date: "2026-07-06"
  tasks_completed: 3
  tasks_total: 3
  files_created: 0
  files_modified: 2
---

# Phase 01 Plan 02: WebTransport Server Implementation Summary

**One-liner:** Full wtransport Endpoint accept loop with three-step QUIC handshake, ping/pong JSON echo over bidirectional stream, and mkcert TLS cert loading — Chrome WebTransport echo round-trip verified sub-10ms on localhost after NSS store CA install.

## What Was Built

Replaced the `wt_server::run` stub with a complete WebTransport listener:

- **`wt_server::run`** (`server/src/wt_server.rs`): Loads mkcert TLS certs via `Identity::load_pemfiles`, builds `ServerConfig`, creates `Endpoint::server`, enters accept loop. Each `IncomingSession` is dispatched to `tokio::spawn(handle_wt_connection(incoming))`. Logs `"WebTransport listening on :{port}"` before entering the loop.
- **`handle_wt_connection`** (`server/src/wt_server.rs`): Implements the three-step wtransport accept: `incoming.await?` → `request.accept().await?` → live `Connection`. Logs `"WT session accepted"`. Enters echo loop: `accept_bi()` → read ping JSON → write pong JSON with `server_ts = Some(now_ms())`.
- **Threat mitigations applied:**
  - T-01-05 (DoS): Each connection in its own `tokio::spawn`; errors logged with `tracing::error!`, accept loop never exits.
  - T-01-06 (Tampering): Malformed JSON deserialization returns `Err` → logged and connection continues (no panic, no `unwrap`).
- **`main.rs`**: Comment updated to reflect `wt_server` is the real implementation; `ws_server` stub comment kept.

## Verification Results

| Check | Result |
|-------|--------|
| `cargo build -p immersive-rt-server` | PASS — zero errors |
| `RUSTFLAGS="-D warnings" cargo build` | PASS — zero warnings |
| `cargo test -p immersive-rt-server` | PASS — 2/2 tests (echo unit tests) |
| Cert files exist at certs/localhost+2.pem and certs/localhost+2-key.pem | PASS |
| PEM files are valid format (BEGIN CERTIFICATE / BEGIN PRIVATE KEY) | PASS |
| `cargo run` emits "WebTransport listening on :4433" | PASS |
| Chrome WebTransport echo snippet → pong received | PASS — human approved |
| `server_ts - client_ts` < 10ms on localhost | PASS — sub-10ms confirmed |
| Server logs "WT session accepted" on Chrome connect | PASS |

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | mkcert cert verification (certs pre-existing per user setup) | — | certs/localhost+2.pem, certs/localhost+2-key.pem (verified, not committed) |
| 2 | Implement wt_server.rs WebTransport listener and echo handler | 6e34ea9 | server/src/wt_server.rs, server/src/main.rs |
| 3 | Manual Chrome WebTransport connection verification | APPROVED | Chrome echo snippet received pong; server_ts - client_ts sub-10ms |

## Deviations from Plan

### Human Setup Discovery (not a code deviation)

**mkcert NSS store missing — Chrome QUIC handshake failed until resolved**

- **Found during:** Task 3 human verification
- **Issue:** Chrome's QUIC stack validates WebTransport TLS certs against its own NSS certificate database, not the OS trust store alone. The `chrome://flags/#webtransport-developer-mode` flag was already enabled, but `ERR_QUIC_HANDSHAKE_FAILED` persisted. Root cause: `libnss3-tools` was not installed on the system, so `mkcert -install` had not registered the local CA in Chrome's NSS store.
- **Resolution:** User ran `sudo apt install libnss3-tools && mkcert -install` followed by a Chrome restart. Connection succeeded immediately.
- **Impact on code:** No code changes required.
- **Documentation note:** Downstream plans should clarify that `libnss3-tools` must be installed before `mkcert -install` on Debian/Ubuntu. The `webtransport-developer-mode` flag alone is not sufficient when the NSS store is absent.

All code tasks executed exactly as written.

## Known Stubs

| Stub | File | Reason |
|------|------|--------|
| `ws_server::run` returns `Ok(())` immediately | server/src/ws_server.rs | WebSocket fallback listener implemented in Plan 03 |

No stubs in the wt_server module — this plan's goal is a fully working WebTransport listener.

## Threat Flags

None. All security-relevant surfaces introduced in this plan were covered by the plan's `<threat_model>`:
- T-01-04 (key disclosure): certs gitignored since Plan 01; Identity::load_pemfiles reads from filesystem only, never serializes the key
- T-01-05 (DoS on accept loop): mitigated — spawned connection tasks log errors and exit; accept loop is never killed
- T-01-06 (Tampering via malformed JSON): mitigated — serde_json::from_slice with typed EchoMessage; Err logged and dropped, no panic

## Self-Check: PASSED

- [x] server/src/wt_server.rs exists and is non-stub (contains `pub async fn run` and `handle_wt_connection`)
- [x] server/src/main.rs wires `wt_server::run` (not a stub)
- [x] Commit 6e34ea9 exists (Task 2 — feat(01-02))
- [x] Commit 8ca8613 exists (Task 3 — docs(01-02) checkpoint)
- [x] `cargo build -p immersive-rt-server` exits 0
- [x] `cargo test -p immersive-rt-server` exits 0, 2/2 tests passing
- [x] certs/localhost+2.pem exists (gitignored, not committed)
- [x] certs/localhost+2-key.pem exists (gitignored, not committed)
- [x] Chrome echo snippet received pong — human approved, sub-10ms latency confirmed
