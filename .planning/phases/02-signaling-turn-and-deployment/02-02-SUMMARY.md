---
phase: 02-signaling-turn-and-deployment
plan: "02"
subsystem: server
tags: [signaling, relay, broker, wss, tokio-select, rust, integration-test]
status: complete

dependency_graph:
  requires:
    - 02-01 (broker.rs, signaling.rs, turn_creds.rs — Phase 2 Plan 1 modules)
  provides:
    - server/src/wt_server.rs (broker-integrated WT relay handler)
    - server/src/ws_server.rs (broker-integrated WS relay handler + WSS TLS loader)
    - server/src/main.rs (broker-wired entry point, WS_PORT 9090, CryptoProvider init)
    - server/tests/broker_relay.rs (integration test proving WS offer routing)
  affects:
    - server/tests/ws_echo.rs (updated to self-routing relay test)
    - server/src/turn_creds.rs (added #[allow(dead_code)] for binary context)

tech_stack:
  added:
    - tokio::select! fan-in/fan-out pattern for bidirectional relay loops
    - tokio_rustls::TlsAcceptor (WSS wrapping in ws_server.rs)
    - rustls_pemfile::{certs, private_key} 2.x API for cert/key loading
    - tokio_rustls::rustls::crypto::aws_lc_rs::default_provider() CryptoProvider init
  patterns:
    - Generic relay_ws<S> helper avoids "multiple non-auto traits in dyn" limitation
    - Optional broker_rx in select! via std::future::pending() when not yet registered
    - wtransport open_bi() returns OpeningBiStream — requires two .await steps
    - Self-routing test pattern (register + send to self) for relay round-trip verification

key_files:
  modified:
    - server/src/wt_server.rs
    - server/src/ws_server.rs
    - server/src/main.rs
    - server/tests/ws_echo.rs
    - server/src/turn_creds.rs
  created:
    - server/tests/broker_relay.rs

decisions:
  - "relay_ws<S> generic helper used instead of Box<dyn AsyncRead+AsyncWrite> trait object — Rust 2021 does not allow multiple non-auto traits in a single dyn object"
  - "wtransport Connection::open_bi() returns Result<OpeningBiStream, _> not Result<(Send, Recv), _> — OpeningBiStream must be awaited a second time"
  - "test_ws_echo updated to self-routing test (register + offer to self) since echo behavior removed — plan note about 'update spawn line only' was inconsistent with removing echo"
  - "turn_creds.rs #[allow(dead_code)] on stub items — binary context (main.rs declares mod turn_creds) but nothing uses it yet; same pattern as echo.rs in Plan 01"

metrics:
  duration: "38 min"
  completed: "2026-07-06"
  tasks_completed: 3
  files_changed: 5
---

# Phase 02 Plan 02: Transport Handler Broker Integration Summary

**One-liner:** Both WebTransport and WebSocket handlers converted from echo to signaling relay via shared SignalingBroker; WS handler gets optional WSS TLS loading; integration test proves cross-client offer routing end-to-end.

## What Was Built

### server/src/wt_server.rs — broker-integrated relay

- `run()` signature extended: `(cert_path, key_path, port, broker: Arc<SignalingBroker>)`
- `handle_wt_connection()` extended: `(incoming, broker: Arc<SignalingBroker>)`
- Registration: first `accept_bi()` stream outside the relay loop reads the "register" message
- Main relay loop: `tokio::select!` with two arms:
  - Arm 1 (`conn.accept_bi()`): reads inbound stream, parses `SignalingEnvelope`, routes via `broker.route()`
  - Arm 2 (`broker_rx.recv()`): receives outbound payload, calls `conn.open_bi()` (two-step: `await` then `await` again on `OpeningBiStream`), writes and finishes stream
- D-05 compliance: `tracing::warn!(to=%envelope.to, "signaling target not connected, dropping")`
- `broker.unregister(&my_id)` on relay loop exit; all error paths log and continue (no connection abort on message errors)
- Removed all references to `EchoMessage` and `echo::now_ms`

### server/src/ws_server.rs — broker + WSS TLS

- `load_tls_acceptor(cert_path, key_path)` — new `pub(crate)` function using `rustls_pemfile::certs` and `rustls_pemfile::private_key` (2.x API)
- `run()` signature: `(port, broker: Arc<SignalingBroker>, cert_path, key_path)` — loads TLS, falls back to None on error
- `run_with_listener()` signature: `(TcpListener, Arc<SignalingBroker>, Option<TlsAcceptor>)` — preserves test compatibility with None
- `handle_ws_connection()` — branches on `Option<TlsAcceptor>`, calls generic `relay_ws<S>`
- `relay_ws<S>()` — generic over `AsyncRead + AsyncWrite + Unpin + Send`; avoids `Box<dyn Trait1 + Trait2>` (Rust limitation)
- Relay loop: `tokio::select!` with `read.next()` (inbound) and async block polling optional `broker_rx`
- Registration: "register" message extracts client ID, calls `broker.register()`; pre-registration non-register messages logged+dropped
- D-05 compliance and `broker.unregister` on connection close

### server/src/main.rs — broker-wired entry point

- Added `mod broker; mod signaling; mod turn_creds;` declarations
- `WS_PORT` default changed from "8080" to "9090" (D-02)
- `tokio_rustls::rustls::crypto::aws_lc_rs::default_provider().install_default()` called before any listener starts (Pitfall 3 — prevents runtime panic if two consumers of rustls try to install different providers)
- `let broker = Arc::new(broker::SignalingBroker::new());` constructed once
- Both listeners receive `broker.clone()`

### server/tests/broker_relay.rs — NEW integration test

- `test_broker_relay_ws`: two WS clients connect to the same server
- client_a registers as "phone-1", client_b registers as "desktop-1"
- `yield_now()` ensures server processes both registrations before the offer is sent
- client_a sends `{"type":"offer","from":"phone-1","to":"desktop-1","payload":{}}`
- Asserts client_b receives the offer with `msg_type == "offer"` and `from == "phone-1"`

### server/tests/ws_echo.rs — updated

- Spawn call updated to `run_with_listener(listener, broker, None)` (new signature)
- Test body updated: now a self-routing round-trip test (register as "echo-client", send offer to self, assert received)

## Test Results (Final)

```
cargo test --workspace — 14 tests, 0 failures, 0 warnings

lib unit tests (11):
  broker: test_route_to_registered_client, test_route_to_unknown_returns_false,
          test_unregister_then_route_returns_false, test_register_returns_independent_receivers
  signaling: test_signaling_envelope_wire_key_is_type, test_parse_envelope_valid_json,
             test_parse_envelope_invalid_returns_none
  turn_creds: test_turn_credential_known_vector, test_turn_credentials_not_cached
  echo: test_now_ms_nonzero, test_echo_message_round_trip

main binary tests (2): test_echo_message_round_trip, test_now_ms_nonzero
integration tests (2): test_broker_relay_ws, test_ws_echo
```

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] `conn.open_bi()` returns `Result<OpeningBiStream, _>` not `Result<(SendStream, RecvStream), _>`**

- **Found during:** Task 1 compilation
- **Issue:** The plan's action said `match conn.open_bi().await { Ok((mut send, _recv)) => { ... } }` — but `open_bi().await` returns `Result<OpeningBiStream, _>`. `OpeningBiStream` must be awaited a second time to get the actual `(SendStream, RecvStream)`.
- **Fix:** Two-step await: `let opening = conn.open_bi().await?;` then `match opening.await { Ok((mut send, _recv)) => { ... } }`
- **Files modified:** `server/src/wt_server.rs`
- **Commit:** eaebe36

**2. [Rule 1 - Bug] Rust disallows multiple non-auto traits in `dyn Trait1 + Trait2` trait objects**

- **Found during:** Task 2 compilation
- **Issue:** The plan described wrapping TcpStream/TlsStream in a `Box<dyn AsyncRead + AsyncWrite + Unpin + Send>`. Rust only allows one non-auto trait in a `dyn` object (`AsyncRead` and `AsyncWrite` are both non-auto).
- **Fix:** Introduced `relay_ws<S>()` generic helper function. Both `TcpStream` and `TlsStream<TcpStream>` satisfy `S: AsyncRead + AsyncWrite + Unpin + Send`; Rust monomorphizes the function for each concrete type.
- **Files modified:** `server/src/ws_server.rs`
- **Commit:** 251c2a2

**3. [Rule 1 - Bug] `test_ws_echo` hangs with relay behavior: server no longer echoes**

- **Found during:** Task 3 analysis
- **Issue:** The plan said "update the tokio::spawn line to pass the new run_with_listener signature" for `ws_echo.rs`, but the server now relays (not echoes). Sending `"hello-echo-test"` (non-JSON) returns nothing; `ws.next()` would block forever.
- **Fix:** Updated the test body to do a self-routing round-trip: register as "echo-client", then send an offer to "echo-client" (itself). The broker routes it back via the same connection's outbound arm. Asserts `msg_type == "offer"`.
- **Files modified:** `server/tests/ws_echo.rs`
- **Commit:** 2142917

**4. [Rule 2 - Missing Critical] `turn_creds.rs` dead code warnings in binary context**

- **Found during:** Task 3 compilation
- **Issue:** Plan adds `mod turn_creds;` to main.rs but nothing in the binary uses `TurnCredentials` or `generate_turn_credentials` yet. RUSTFLAGS="-D warnings" treats dead code as errors.
- **Fix:** Added `#[allow(dead_code)]` to three stub items in `turn_creds.rs`: `HmacSha1` type alias, `TurnCredentials` struct, `generate_turn_credentials` function. Follows the established pattern from Plan 01 where echo.rs received the same treatment.
- **Files modified:** `server/src/turn_creds.rs`
- **Commit:** 2142917

## Known Stubs

None — all implemented functionality is fully wired. The `turn_creds` module remains unused by the binary's runtime path (the TURN credential HTTP endpoint is Plan 02-03), but this is intentional and tracked.

## Threat Flags

None — no new network endpoints, auth paths, or schema changes beyond the plan's threat model. The `load_tls_acceptor` function reads local PEM files; it does not introduce a new trust boundary.

## Self-Check: PASSED

Files exist on disk:
- server/src/wt_server.rs: FOUND
- server/src/ws_server.rs: FOUND
- server/src/main.rs: FOUND
- server/tests/ws_echo.rs: FOUND
- server/tests/broker_relay.rs: FOUND
- server/src/turn_creds.rs: FOUND

Commits verified in git log:
- eaebe36: feat(02-02): wt_server broker integration and select! relay loop
- 251c2a2: feat(02-02): ws_server broker + WSS TLS + select! relay loop
- 2142917: feat(02-02): main.rs broker wiring + integration tests — GREEN
