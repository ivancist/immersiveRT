---
phase: 02-signaling-turn-and-deployment
plan: "01"
subsystem: server
tags: [signaling, broker, dashmap, turn-credentials, hmac-sha1, rust]
status: complete

dependency_graph:
  requires:
    - 01-03 (lib.rs, ws_server.rs, wt_server.rs — Phase 1 transport foundation)
  provides:
    - server/src/broker.rs (SignalingBroker — consumed by Plans 02-02 and 02-03)
    - server/src/signaling.rs (SignalingEnvelope, parse_envelope — consumed by Plans 02-02 and 02-03)
    - server/src/turn_creds.rs (TurnCredentials, generate_turn_credentials — consumed by Plan 02-03)
  affects:
    - server/src/lib.rs (added 3 new module exports)

tech_stack:
  added:
    - dashmap 6.2 (concurrent DashMap broker registry)
    - hmac 0.13 (HMAC-SHA1 for coturn ephemeral credentials)
    - sha1 0.11 (SHA-1 digest backing HMAC)
    - base64 0.22 (Engine API for TURN password encoding)
    - tokio-rustls 0.26 (future WSS TLS termination, Plans 02-02/02-03)
    - rustls-pemfile 2.2 (PEM cert/key loading, Plans 02-02/02-03)
    - axum 0.8 (HTTP router for TURN credential endpoint, Plans 02-03+)
  patterns:
    - DashMap wrapped in Arc — Clone broker handle, not the map (D-03)
    - serde rename = "type" for wire format (D-04, mirroring echo.rs pattern)
    - mpsc::UnboundedSender::send is synchronous — DashMap guard safe, no .await held (Pitfall 4 mitigation)
    - expiry = now + ttl_seconds in TURN username (Pitfall 1 mitigation)

key_files:
  created:
    - server/src/broker.rs
    - server/src/signaling.rs
    - server/src/turn_creds.rs
  modified:
    - server/Cargo.toml
    - server/src/lib.rs

decisions:
  - "SignalingBroker::route returns bool; caller (not broker) logs warning on false (D-05)"
  - "hmac::KeyInit trait must be imported alongside Mac to use new_from_slice in hmac 0.13"
  - "aws_lc_rs crypto provider: no ring feature added to any dep (Pitfall 3 prevention)"

metrics:
  duration: "9 min"
  completed: "2026-07-06"
  tasks_completed: 2
  files_changed: 5
---

# Phase 02 Plan 01: Broker, Signaling, and TURN Credentials Summary

**One-liner:** DashMap-backed signaling broker, serde-renamed JSON envelope, and HMAC-SHA1 TURN credential generator with known-vector test — three inert modules proven by unit tests before transport wiring.

## What Was Built

Three new server modules and the Cargo.toml dependency update that unlocks the remaining Phase 2 plans:

### server/src/broker.rs — SignalingBroker

- `pub type ClientId = String` — type alias for clarity
- `#[derive(Clone)] pub struct SignalingBroker` wrapping `Arc<DashMap<ClientId, mpsc::UnboundedSender<Vec<u8>>>>`
- `new()`, `register(id) -> UnboundedReceiver`, `unregister(id)`, `route(to, payload) -> bool`
- `route` returns `false` for unknown IDs; caller logs the warning per D-05 (broker is log-silent)
- DashMap shard guard is never held across `.await` — `UnboundedSender::send` is synchronous by construction

### server/src/signaling.rs — SignalingEnvelope

- `#[serde(rename = "type")] pub msg_type: String` — wire key is `"type"`, not `"msg_type"` (D-04)
- `from`, `to` (default empty), `payload: serde_json::Value` (default null)
- `parse_envelope(bytes) -> Option<SignalingEnvelope>` — returns `None` on malformed input, never panics (T-01-06)

### server/src/turn_creds.rs — generate_turn_credentials

- `expiry = SystemTime::now().as_secs() + ttl_seconds` — expiry timestamp, NOT issue time (Pitfall 1)
- `username = "{expiry}:{userid}"` — coturn REST API format
- `password = STANDARD.encode(HMAC-SHA1(shared_secret.as_bytes(), username.as_bytes()))` — exact coturn algorithm
- Known-vector test pins expected password to `/LVV/XKVO6NE5ItSOBdhdQh+N0I=` for `(secret="turn-secret", username="1720000300:testuser")`

### server/Cargo.toml — 7 new dependencies

All seven packages from the RESEARCH.md Package Legitimacy Audit (all VERIFIED): dashmap 6.2, hmac 0.13, sha1 0.11, base64 0.22, tokio-rustls 0.26, rustls-pemfile 2.2, axum 0.8. No `ring` feature added to any rustls-adjacent dep (Pitfall 3 prevention).

### server/src/lib.rs — 6 module exports

Added `pub mod broker; pub mod signaling; pub mod turn_creds;` alongside the existing three modules. Integration tests can now import via `immersive_rt_server::broker::SignalingBroker`.

## TDD Cycle

### Task 1: broker.rs + signaling.rs

- **RED commit `92953e2`:** Cargo.toml deps + broker/signaling stubs with tests. Broker `route` always returned `false`; signaling struct lacked `serde(rename)`. 4 tests failed.
- **GREEN commit `253e5b2`:** Proper implementations. All 9 lib tests pass.

### Task 2: turn_creds.rs + lib.rs

- **RED commit `12d84ea`:** turn_creds stub used `expiry = now` (no ttl addition — Pitfall 1 bug). `test_turn_credentials_not_cached` with different TTLs failed because both calls returned the same username.
- **GREEN commit `41155c4`:** Fixed to `expiry = now + ttl_seconds`. All 11 lib + 2 main + 1 integration tests pass.

## Test Results (Final)

```
cargo test --workspace — 14 tests, 0 failures, 0 warnings

lib tests (11):
  broker: test_route_to_registered_client, test_route_to_unknown_returns_false,
          test_unregister_then_route_returns_false, test_register_returns_independent_receivers
  signaling: test_signaling_envelope_wire_key_is_type, test_parse_envelope_valid_json,
             test_parse_envelope_invalid_returns_none
  turn_creds: test_turn_credential_known_vector, test_turn_credentials_not_cached
  echo: test_now_ms_nonzero, test_echo_message_round_trip

main binary tests (2): test_echo_message_round_trip, test_now_ms_nonzero
integration test (1): test_ws_echo
```

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Missing Import] `hmac::KeyInit` trait required for `new_from_slice` in hmac 0.13**

- **Found during:** Task 2 compilation
- **Issue:** `HmacSha1::new_from_slice` requires the `KeyInit` trait to be in scope. The RESEARCH.md code example omitted this import (showing only `use hmac::{Hmac, Mac}`).
- **Fix:** Added `KeyInit` to the hmac import: `use hmac::{Hmac, KeyInit, Mac};`
- **Files modified:** `server/src/turn_creds.rs`
- **Impact:** None — standard trait import, no behavior change.

None — plan executed as specified, single compilation fix applied.

## Known Stubs

None — all three modules are fully implemented with passing tests. The new modules are intentionally inert until Plans 02-02/02-03 wire them into the transport handlers.

## Threat Flags

None — no new network endpoints, auth paths, or schema changes introduced. The three modules are pure library code with no I/O surface until wired in Plan 02-02/02-03.

## Self-Check: PASSED

All created files exist on disk:
- server/src/broker.rs: FOUND
- server/src/signaling.rs: FOUND
- server/src/turn_creds.rs: FOUND
- server/src/lib.rs: FOUND (updated)
- server/Cargo.toml: FOUND (updated)
- 02-01-SUMMARY.md: FOUND

All task commits verified in git log:
- 92953e2: test(02-01) RED — broker + signaling stubs
- 253e5b2: feat(02-01) GREEN — broker + signaling implementation
- 12d84ea: test(02-01) RED — turn_creds + lib.rs stubs
- 41155c4: feat(02-01) GREEN — generate_turn_credentials implementation
