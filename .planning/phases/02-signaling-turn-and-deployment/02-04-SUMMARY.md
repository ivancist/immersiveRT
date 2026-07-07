---
phase: 02-signaling-turn-and-deployment
plan: "04"
subsystem: server
tags: [axum, turn, rest-api, http, tokio-try-join, tdd, rust, infra]
status: complete

dependency_graph:
  requires:
    - 02-01 (turn_creds.rs — generate_turn_credentials, TurnCredentials)
    - 02-02 (main.rs — broker wiring, CryptoProvider init, try_join! pattern)
  provides:
    - server/src/main.rs (AppState, turn_creds_handler, HTTP_PORT, TURN_SHARED_SECRET, 3-task try_join!)
    - GET /turn-credentials route on HTTP_PORT (default 8081)
  affects:
    - server/src/turn_creds.rs (added serde::Serialize to TurnCredentials; removed dead_code annotations)

tech_stack:
  added:
    - axum 0.8 Router::new().route().with_state() pattern for HTTP REST endpoint
    - tokio::net::TcpListener + axum::serve() as third concurrent task in try_join!
    - async { ...map_err(anyhow::Error::from) } pattern to unify io::Error with anyhow in try_join!
    - serde::Serialize derive on TurnCredentials for axum Json<T> response type
  patterns:
    - turn_creds_handler(State(Arc::new(state))) direct call pattern for unit testing without HTTP server
    - TURN_SHARED_SECRET via std::env::var()? with no default — server refuses to start if absent
    - HTTP_PORT with unwrap_or_else default "8081" following established WT_PORT/WS_PORT pattern

key_files:
  modified:
    - server/src/main.rs
    - server/src/turn_creds.rs

decisions:
  - "async { axum::serve(...).await.map_err(anyhow::Error::from) } wraps axum serve in try_join! — maps io::Error to anyhow::Error to unify all three future error types"
  - "turn_creds_handler unit test calls handler directly with State(Arc::new(state)) — no HTTP server started; proves handler logic without infrastructure"
  - "userid='anonymous' for Phase 2 — Phase 4 will supply real client session ID"
  - "TDD RED/GREEN: stub returning Err committed first; then full implementation making test pass"

metrics:
  duration: "4 min"
  completed: "2026-07-07"
  tasks_completed: 2
  files_changed: 2
---

# Phase 02 Plan 04: TURN Credential HTTP Endpoint Summary

**One-liner:** axum HTTP server on HTTP_PORT exposes GET /turn-credentials returning HMAC-SHA1 ephemeral credentials; TURN_SHARED_SECRET is a required env var causing server startup failure if absent; handler is unit-tested directly without an HTTP server.

## What Was Built

### server/src/main.rs — AppState, handler, axum Router, extended try_join!

**AppState struct:**
```rust
struct AppState { turn_shared_secret: String }
```
Arc-wrapped: `let app_state = Arc::new(AppState { turn_shared_secret });`

**turn_creds_handler:**
- Accepts `State(state): State<Arc<AppState>>`
- Returns `Result<Json<turn_creds::TurnCredentials>, String>`
- Calls `turn_creds::generate_turn_credentials(&state.turn_shared_secret, "anonymous", 300)`
- Maps result to `Json(...)` on success; maps `anyhow::Error` to `String` on failure
- Fresh credentials on every request — no caching; each call returns a different username (different expiry timestamp)

**New env vars in main():**
- `TURN_SHARED_SECRET`: required via `std::env::var("TURN_SHARED_SECRET")?` with no default — server exits with clear error if absent (INFRA-04, T-02-11 mitigation)
- `HTTP_PORT`: optional with default "8081" following the established WT_PORT/WS_PORT pattern

**axum Router and listener:**
```rust
let app_state = Arc::new(AppState { turn_shared_secret });
let http_app = Router::new()
    .route("/turn-credentials", get(turn_creds_handler))
    .with_state(app_state);
let http_listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{}", http_port)).await?;
```

**tokio::try_join! extended from 2 to 3 futures:**
```rust
tokio::try_join!(
    wt_server::run(&cert_path, &key_path, wt_port, broker.clone()),
    ws_server::run(ws_port, broker.clone(), &cert_path, &key_path),
    async { axum::serve(http_listener, http_app).await.map_err(anyhow::Error::from) },
)?;
```

**test_turn_creds_handler_unit:**
- Constructs `AppState` with `turn_shared_secret: "test-secret"`
- Calls handler directly: `turn_creds_handler(State(Arc::new(state))).await`
- Asserts: `username.contains(':')` (format is `"{expiry}:anonymous"`) and `!password.is_empty()` and `ttl_seconds == 300`

### server/src/turn_creds.rs — Serialize derive added

- `#[derive(Serialize)]` added to `TurnCredentials` — required for axum `Json<TurnCredentials>` response type (`impl<T: Serialize> IntoResponse for Json<T>`)
- Removed `#[allow(dead_code)]` annotations — `TurnCredentials` is now used by the handler and `generate_turn_credentials` is called from within the handler; no dead code remains

## Test Results (Final)

```
RUSTFLAGS="-D warnings" cargo test --workspace — 15 test runs, 0 failures, 0 warnings

lib unit tests (11):
  broker: test_route_to_registered_client, test_route_to_unknown_returns_false,
          test_unregister_then_route_returns_false, test_register_returns_independent_receivers
  signaling: test_signaling_envelope_wire_key_is_type, test_parse_envelope_valid_json,
             test_parse_envelope_invalid_returns_none
  turn_creds: test_turn_credential_known_vector, test_turn_credentials_not_cached
  echo: test_now_ms_nonzero, test_echo_message_round_trip

main binary tests (12 = 11 + 1 new):
  All lib tests + test_turn_creds_handler_unit (PASSES: username contains ':', password non-empty)

integration tests (2): test_broker_relay_ws, test_ws_echo
```

## TDD Gate Compliance

| Gate | Commit | Status |
|------|--------|--------|
| RED | 6fafbc5 | `test(02-04)` — stub handler returns Err; test panics on `.expect()` |
| GREEN | 22ddc04 | `feat(02-04)` — real handler; all 15 tests pass, 0 warnings |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] axum::serve().into_future() returns io::Error, not anyhow::Error — type mismatch in try_join!**

- **Found during:** Task 1 GREEN implementation
- **Issue:** The plan suggested `axum::serve(...).into_future()` directly in `try_join!`. However, `Serve::into_future()` returns `Future<Output = Result<(), std::io::Error>>` while the other two futures return `anyhow::Result<()>`. Rust's `try_join!` requires all futures to return the same error type — there is no implicit coercion for generic error types.
- **Fix:** Wrapped axum serve in an async block with explicit error mapping: `async { axum::serve(http_listener, http_app).await.map_err(anyhow::Error::from) }`. `anyhow::Error` implements `From<io::Error>` so this is a one-liner.
- **Files modified:** `server/src/main.rs`
- **Commit:** 22ddc04

**2. [Rule 1 - Bug] RED phase dead_code false-positive — turn_creds_handler flagged as unused by binary build**

- **Found during:** Task 1 RED phase compilation with `-D warnings`
- **Issue:** `turn_creds_handler` defined outside main() is not called from main() in the RED stub state. The binary build (not the test build) sees it as dead_code. With `-D warnings`, this becomes a compile error.
- **Fix:** Added `#[allow(dead_code)]` to the stub handler in the RED commit; removed it in the GREEN commit when main() uses the handler via the axum Router. Per project TDD+Rust pattern established in Plans 02-01/02-02 (same treatment as echo.rs stub items).
- **Files modified:** `server/src/main.rs`
- **Commits:** 6fafbc5 (RED + allow), 22ddc04 (GREEN, allow removed)

## Known Stubs

None — all implemented functionality is fully wired. `turn_creds_handler` is integrated into the axum Router and `try_join!` in main(). The `anonymous` userid is an intentional Phase 2 placeholder (documented in plan objective; Phase 4 adds session auth).

## Threat Flags

No new threat surface beyond the plan's threat model:
- T-02-11 mitigated: `TURN_SHARED_SECRET` via `std::env::var()?` — no default, no logging, server refuses to start if absent; value lives only in `AppState` (in-memory)
- T-02-12 accepted: 300s TTL default as planned
- T-02-13 accepted: `/turn-credentials` unauthenticated in Phase 2 — low risk for IMU-only data channel usage

## Self-Check: PASSED

Files exist on disk:
- server/src/main.rs: FOUND
- server/src/turn_creds.rs: FOUND

Commits verified in git log:
- 6fafbc5: test(02-04): add failing test for TURN credential handler (RED)
- 22ddc04: feat(02-04): implement TURN credential HTTP endpoint via axum (GREEN, INFRA-04)
