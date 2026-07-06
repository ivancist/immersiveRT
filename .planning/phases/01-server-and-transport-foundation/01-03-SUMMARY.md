---
phase: 01-server-and-transport-foundation
plan: 03
subsystem: server/ws-server
tags: [rust, websocket, tokio-tungstenite, echo, integration-test, fallback]
status: complete

dependency_graph:
  requires:
    - symbol: wt_server::run
      kind: pub async fn
      file: server/src/wt_server.rs
      plan: 01-02
    - symbol: tokio::try_join!
      kind: macro usage
      file: server/src/main.rs
      plan: 01-02
  provides:
    - symbol: ws_server::run
      kind: pub async fn
      file: server/src/ws_server.rs
    - symbol: handle_ws_connection
      kind: async fn
      file: server/src/ws_server.rs
    - symbol: test_ws_echo
      kind: integration test
      file: server/tests/ws_echo.rs
    - symbol: immersive_rt_server (lib crate)
      kind: lib.rs re-exports
      file: server/src/lib.rs
    - symbol: WebSocket listener on :8080 TCP
      kind: runtime
      file: target/debug/immersive-rt-server
  affects:
    - server/src/main.rs (ws_server::run stub replaced by full implementation)

tech_stack:
  added:
    - tokio-tungstenite 0.29 accept_async (TCP-to-WebSocket upgrade)
    - futures_util SinkExt/StreamExt for WebSocket stream split/send/next
    - server/src/lib.rs (new library crate target for integration test access)
  patterns:
    - TcpListener::bind -> accept loop -> tokio::spawn per connection (T-01-09 DoS mitigation)
    - accept_async upgrades TcpStream to WebSocketStream; split() for concurrent read/write
    - Echo loop: read.next().await verbatim -> write.send(msg) — any message type echoed
    - Integration test: #[tokio::test] + tokio::spawn(ws_server::run(18080)) on dedicated test port
    - lib.rs + main.rs dual crate target: lib for test access, binary for executable

key_files:
  created:
    - server/src/ws_server.rs (full WebSocket listener replacing stub)
    - server/src/lib.rs (library crate with pub mod re-exports for integration tests)
    - server/tests/ws_echo.rs (integration test — WS echo round-trip)
  modified: []

decisions:
  - "lib.rs added to expose ws_server to integration tests — integration tests link against lib crate, not binary crate"
  - "handle_ws_connection returns anyhow::Result<()>; errors from accept_async logged with tracing::warn, errors from echo loop cause clean exit via is_err() break — no unwrap on connection path"
  - "Test port 18080 (not 8080) to avoid conflicts with a running server instance during test runs"
  - "Plain ws:// only in Phase 1 — WSS deferred to Phase 2 per RESEARCH.md Open Question 1 explicit decision"

metrics:
  duration_minutes: 1
  completed_date: "2026-07-06"
  tasks_completed: 3
  tasks_total: 3
  files_created: 3
  files_modified: 0
---

# Phase 01 Plan 03: WebSocket Fallback Listener Summary

**One-liner:** Full tokio-tungstenite TcpListener + accept_async echo implementation with integration test verifying round-trip on a dedicated test port — Phase 1 workspace test suite gates green at zero warnings.

## What Was Built

Replaced the `ws_server::run` stub with a complete WebSocket fallback listener, added integration test infrastructure, and ran the full workspace test suite gate.

### Task 1: ws_server.rs implementation

- **`ws_server::run(port: u16)`** (`server/src/ws_server.rs`): Binds `TcpListener` on `0.0.0.0:{port}`, logs `"WebSocket fallback listening on :{port}"`, enters accept loop. Each `(TcpStream, SocketAddr)` pair dispatched to `tokio::spawn(handle_ws_connection(stream, addr))`. Errors from spawned tasks logged with `tracing::warn!`; accept loop never exits.
- **`handle_ws_connection`**: Calls `accept_async(stream).await` to upgrade TCP to WebSocket. On success: splits stream with `.split()`, echo loop `while let Some(Ok(msg)) = read.next().await { write.send(msg) }`. On upgrade failure: `tracing::warn!` and returns. No `unwrap()` on connection-handling path.
- **Threat mitigations applied:**
  - T-01-09 (DoS): Each connection in its own `tokio::spawn`; errors logged, accept loop continues uninterrupted.
  - T-01-10 (Large frame DoS): Phase 1 echo is fire-and-forget; max-message-size config deferred to Phase 2 as planned.

### Task 2: Integration test infrastructure

- **`server/src/lib.rs`**: New library crate target with `pub mod echo; pub mod ws_server; pub mod wt_server;` — exposes server modules to Rust integration tests in `server/tests/`.
- **`server/tests/ws_echo.rs`**: `#[tokio::test]` that spawns `immersive_rt_server::ws_server::run(18080)` in a background task, sleeps 50ms for listener bind, connects `tokio-tungstenite::connect_async` to `ws://127.0.0.1:18080`, sends `Message::Text("hello-echo-test")`, reads reply, asserts text equality.

### Task 3: Full workspace test suite gate

- `cargo test --workspace` exits 0 with 5 tests: 2 unit (lib crate) + 2 unit (binary crate) + 1 integration (`test_ws_echo`).
- `RUSTFLAGS="-D warnings" cargo test --workspace` exits 0 — zero compiler warnings across all targets.
- main.rs confirmed: `tracing_subscriber::fmt::init()`, env vars for CERT_PATH/KEY_PATH/WT_PORT/WS_PORT, `tokio::try_join!(wt_server::run(...), ws_server::run(...))`.

## Verification Results

| Check | Result |
|-------|--------|
| `cargo build -p immersive-rt-server` | PASS — zero errors |
| `RUSTFLAGS="-D warnings" cargo build` | PASS — zero warnings |
| `cargo test test_ws_echo -p immersive-rt-server` | PASS — "test test_ws_echo ... ok" |
| `cargo test --workspace` | PASS — 5/5 tests, all suites ok |
| `RUSTFLAGS="-D warnings" cargo test --workspace` | PASS — zero warnings |
| ws_server.rs has no `unwrap()` on connection path | PASS — verified by code review |

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Implement ws_server.rs — WebSocket fallback listener and echo | 8ab3b5a | server/src/ws_server.rs |
| 2 | ws_echo integration test | f8856cc | server/src/lib.rs, server/tests/ws_echo.rs |
| 3 | Full workspace test suite gate | — (gate only, no code changes) | — |

## Deviations from Plan

### Auto-additions (Rule 2)

None — all implementation matched the plan exactly.

The plan anticipated that lib.rs would need to be created for integration test access. This was executed as specified in Task 2 action block. The `main.rs` mod declarations (`mod echo; mod wt_server; mod ws_server;`) coexist with lib.rs (`pub mod echo; pub mod ws_server; pub mod wt_server;`) because Rust supports both a binary crate (`main.rs`) and a library crate (`lib.rs`) in the same package. Integration tests automatically link against the library crate.

No bugs found, no blocking issues encountered, no architectural changes required.

## Phase 1 Success Criteria — All Met

| Criterion | Status |
|-----------|--------|
| `cargo run` emits "WebTransport listening on :4433" AND "WebSocket fallback listening on :8080" | Met (wt_server Plan 02 + ws_server Plan 03) |
| WebSocket client connecting to ws://localhost:8080 receives echo | Met (ws_server::run full implementation) |
| `cargo test test_ws_echo` passes (automated integration test) | Met — "test test_ws_echo ... ok" |
| Both listeners run concurrently — neither blocks the other | Met — tokio::try_join! with tokio::spawn per connection |
| `cargo test --workspace` exits 0 with no warnings | Met — 5 tests, zero warnings |

## Known Stubs

None — all stubs from Plans 01-02 have been replaced. The server is fully functional for Phase 1 scope.

## Threat Flags

None. All security-relevant surfaces introduced in this plan are covered by the plan's threat_model:
- T-01-08 (plain ws://): explicit accept — LAN dev only, WSS in Phase 2
- T-01-09 (DoS on accept loop): mitigated — tokio::spawn per connection, errors logged, loop continues
- T-01-10 (large frame): accept for Phase 1 — max-message-size added in Phase 2

## Self-Check: PASSED

- [x] server/src/ws_server.rs exists and is full implementation (TcpListener + accept_async + echo loop)
- [x] server/src/lib.rs exists with pub mod re-exports
- [x] server/tests/ws_echo.rs exists and tests pass
- [x] Commit 8ab3b5a exists (Task 1 — feat(01-03))
- [x] Commit f8856cc exists (Task 2 — test(01-03))
- [x] `cargo test --workspace` exits 0, 5 tests passing, zero warnings
- [x] No `unwrap()` on ws_server.rs connection-handling path
