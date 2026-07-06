---
phase: "01"
status: "all_fixed"
fix_scope: "critical_warning"
findings_in_scope: 9
fixed: 9
skipped: 0
iteration: 1
fixed_at: "2026-07-06T00:00:00Z"
review_path: ".planning/phases/01-server-and-transport-foundation/01-REVIEW.md"
---

# Phase 01: Code Review Fix Report

**Fixed at:** 2026-07-06
**Source review:** `.planning/phases/01-server-and-transport-foundation/01-REVIEW.md`
**Iteration:** 1

**Summary:**
- Findings in scope: 9 (3 Critical, 6 Warning — Info excluded per fix_scope)
- Fixed: 9
- Skipped: 0

---

## Fixed Issues

### CR-001: WebSocket accept loop exits silently — shuts down entire server on transient OS error

**Files modified:** `server/src/ws_server.rs`
**Commit:** `0cf7b7b`
**Applied fix:** Replaced the `while let Ok(...)` accept loop with a `loop { match ... }` block. Transient errors (ConnectionAborted, ConnectionReset, Interrupted) log and continue; all other errors are propagated as `Err` which lets `tokio::try_join!` surface them. Also extracted `run_with_listener(TcpListener)` as a separate public function (reused by WR-006 test fix).

---

### CR-002: WebSocket echo loop forwards RFC 6455 control frames verbatim — protocol violation

**Files modified:** `server/src/ws_server.rs`
**Commit:** `40fc415`
**Applied fix:** Added a `match &msg` guard before the `write.send(msg)` call that skips all non-data frame variants (Ping, Pong, Close, Frame). Only `Message::Text` and `Message::Binary` are echoed. Also added `use tokio_tungstenite::tungstenite::Message` import.

---

### CR-003: WebTransport stream read uses a single fixed-size buffer — partial reads silently corrupt all subsequent messages

**Files modified:** `server/src/wt_server.rs`
**Commit:** `92dd23b`
**Applied fix:** Replaced the single `recv.read(&mut buf)` call with an inner read loop that accumulates chunks into a `Vec<u8>` until `recv.read()` returns `None` (FIN). Added a 65,536-byte guard to drop oversized streams without OOM. The `serde_json::from_slice` call now operates on the complete payload.

---

### WR-001: WebSocket read errors silently swallowed — operator-invisible client misbehavior

**Files modified:** `server/src/ws_server.rs`
**Commit:** `d7e2202`
**Applied fix:** Changed `while let Some(Ok(msg))` to `while let Some(result)` with an explicit `match result` block that logs the error via `tracing::warn!` and breaks on `Err`. Client misbehavior (invalid UTF-8, oversized frames, protocol violations) is now visible in logs.

---

### WR-002: WebTransport SendStream dropped without finish() on non-ping path — peer receives RESET_STREAM instead of EOF

**Files modified:** `server/src/wt_server.rs`
**Commit:** `13835b8`
**Applied fix:** Added `let _ = send.finish().await;` before `continue` on the non-ping path. The `let _` discards finish errors (e.g., if the peer already closed), preventing double-error noise while still sending a clean FIN when possible.

---

### WR-003: Invalid port environment variables silently fall back to defaults

**Files modified:** `server/src/main.rs`
**Commit:** `8a86d38`
**Applied fix:** Replaced `.parse().unwrap_or(4433)` and `.parse().unwrap_or(8080)` with `.parse().map_err(|e| anyhow::anyhow!("WT_PORT/WS_PORT must be a valid u16 port number: {e}"))?`. Malformed env vars now cause an immediate startup failure with a clear error message.

---

### WR-004: No per-connection or global connection limit — unbounded resource consumption

**Files modified:** `server/src/ws_server.rs`
**Commit:** `ebd0a24`
**Applied fix:** Added `Arc<Semaphore>` with `MAX_WS_CONNECTIONS = 1024` to `run_with_listener`. Each accepted connection acquires an owned permit before spawning; the permit is held by the task and automatically released when the connection closes.

---

### WR-005: WebSocket server has no maximum message size — memory exhaustion via large frames

**Files modified:** `server/src/ws_server.rs`
**Commit:** `21a7a4d`
**Applied fix:** Switched from `accept_async` to `accept_async_with_config`. Built a `WebSocketConfig` using the builder methods (required because the struct is `#[non_exhaustive]` in tungstenite 0.29) setting `max_message_size` and `max_frame_size` to 64 KiB each. Added `MAX_WS_MESSAGE_BYTES = 64 * 1024` constant.

---

### WR-006: Test server task bind failure is undetectable — misleading test error message

**Files modified:** `server/tests/ws_echo.rs`
**Commit:** `291f53e`
**Applied fix:** Bound the test listener before spawning using `TcpListener::bind("127.0.0.1:0")` (OS assigns an ephemeral port). Retrieved the actual address with `listener.local_addr()` and passed the pre-bound listener to `ws_server::run_with_listener`. Removed the hardcoded port 18080 and the 50ms sleep. Bind failures now immediately panic with the actual OS error.

---

## Skipped Issues

None.

---

_Fixed: 2026-07-06_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
