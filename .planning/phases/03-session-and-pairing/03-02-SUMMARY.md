---
phase: "03-session-and-pairing"
plan: "02"
subsystem: "server"
status: complete
tags: ["rust", "room-registry", "ws-server", "wt-server", "env-vars", "dispatch"]
dependency_graph:
  requires:
    - "03-01 (pairing_token::PairingTokenStore, room_registry::RoomRegistry)"
  provides:
    - "ws_server::run (with Arc<RoomRegistry>)"
    - "wt_server::run (with Arc<RoomRegistry>)"
    - "join-room dispatch → room_registry.handle_join"
    - "reconnect dispatch → room_registry.handle_reconnect"
    - "pair dispatch → room_registry.handle_pair"
    - "on_client_disconnect called on WS/WT disconnect"
    - "PAIRING_TOKEN_SECRET and BASE_URL env var enforcement"
  affects:
    - "server/src/signaling.rs"
    - "server/src/ws_server.rs"
    - "server/src/wt_server.rs"
    - "server/src/main.rs"
tech_stack:
  added: []
  patterns:
    - "match envelope.msg_type.as_str() dispatch (join-room|reconnect|pair|_) in relay loop"
    - "Arc<RoomRegistry> threaded through run → run_with_listener → handle_ws_connection → relay_ws"
    - "WT: write_all(&ack_bytes) + finish() per inbound bi-stream for room-aware types"
    - "Required env var pattern: map_err → anyhow::anyhow!(descriptive error) → ?"
key_files:
  created: []
  modified:
    - "server/src/signaling.rs"
    - "server/src/ws_server.rs"
    - "server/src/wt_server.rs"
    - "server/src/main.rs"
decisions:
  - "Arc<RoomRegistry> only threaded through relay functions (not base_url/pairing_secret separately) — base_url and pairing_secret are already stored inside RoomRegistry from Plan 03-01 constructor; adding them to relay function signatures would be dead parameters"
  - "lib.rs unchanged — pub mod pairing_token and pub mod room_registry already added by Plan 03-01"
  - "Startup log includes base_url but not pairing_token_secret value — T-03-07 mitigation; pairing_secret_set = true boolean field confirms secret is configured"
metrics:
  duration: "18 min"
  completed_date: "2026-07-07"
  tasks_completed: 3
  files_modified: 4
---

# Phase 03 Plan 02: WS/WT RoomRegistry Wiring Summary

WS and WT connection handlers wired to Arc<RoomRegistry>; join-room, reconnect, and pair messages now dispatched to room_registry methods; PAIRING_TOKEN_SECRET and BASE_URL enforced as required env vars at startup.

## What Was Built

### Task 1: signaling.rs — typed payload structs

Six new structs appended after `parse_envelope`:

```rust
pub struct JoinRoomPayload  { username, room_code, game_type }
pub struct JoinAckPayload   { slot, room_code, reconnect_token, pairing_url }
pub struct JoinErrorPayload { reason }
pub struct RoomEventPayload { event, slot, username }
pub struct PairPayload      { token }
pub struct PairAckPayload   { desktop_id }
```

`JoinRoomPayload.room_code = ""` means create new room (D-04). `RoomEventPayload.event` includes `"player-disconnected"` for hold-started state (D-21 extension).

### Task 2: ws_server.rs + wt_server.rs — RoomRegistry injection and dispatch

**Updated ws_server::run signature:**
```rust
pub async fn run(
    port: u16,
    broker: Arc<SignalingBroker>,
    room_registry: Arc<RoomRegistry>,
    cert_path: &str,
    key_path: &str,
) -> anyhow::Result<()>
```

**Updated wt_server::run signature:**
```rust
pub async fn run(
    cert_path: &str,
    key_path: &str,
    port: u16,
    broker: Arc<SignalingBroker>,
    room_registry: Arc<RoomRegistry>,
) -> anyhow::Result<()>
```

**WS dispatch pattern** (in relay_ws after spoof-check):
```rust
match envelope.msg_type.as_str() {
    "join-room"  => room_registry.handle_join(&from, &payload, &broker).await → send Text ack
    "reconnect"  → room_registry.handle_reconnect(...).await → send Text ack
    "pair"       → room_registry.handle_pair(&payload, &broker).await → send Text ack
    _            → broker.route(&to, serialized_envelope)
}
```

**WT dispatch pattern** (same logic, WT-specific stream writes):
```rust
match envelope.msg_type.as_str() {
    "join-room"  → write_all(&ack_bytes) + finish()
    "reconnect"  → write_all(&ack_bytes) + finish()
    "pair"       → write_all(&ack_bytes) + finish()
    _            → broker.route() then finish() (no response body)
}
```

**Cleanup path** (both transports):
```rust
broker.unregister(id);
room_registry.on_client_disconnect(id, &broker).await;
```

### Task 3: main.rs + lib.rs — env vars and RoomRegistry construction

**New mod declarations in main.rs:**
```rust
mod pairing_token;
mod room_registry;
```

**Required env vars enforced at startup (descriptive error on missing):**
- `PAIRING_TOKEN_SECRET` — HMAC secret for pairing tokens; descriptive error: "generate a random 32+ char secret..."
- `BASE_URL` — public-facing HTTPS URL for pairing links; descriptive error: "set BASE_URL=https://<your-ip>:8443..."

**Optional env vars with defaults:**
- `HOLD_TTL_SECS` (default `60`) — hold timer duration before slot release (D-16)
- `PAIRING_TOKEN_TTL_SECS` (default `90`) — pairing token lifetime (D-14)

**RoomRegistry construction in main():**
```rust
let room_registry = Arc::new(room_registry::RoomRegistry::new(
    pairing_token_secret,   // String — consumed here
    base_url,               // String — consumed here
    hold_ttl_secs,
    pairing_ttl_secs,
));
```

**Updated try_join!:**
```rust
tokio::try_join!(
    wt_server::run(&cert_path, &key_path, wt_port, broker.clone(), room_registry.clone()),
    ws_server::run(ws_port, broker.clone(), room_registry.clone(), &cert_path, &key_path),
    async { axum::serve(http_listener, http_app).await.map_err(anyhow::Error::from) },
)?;
```

**Startup log (T-03-07 compliant):**
```
cert_path=... key_path=... wt_port=4433 ws_port=9090 http_port=8081 base_url=https://... pairing_secret_set=true "Server starting"
```

`pairing_token_secret` value is never passed to any `tracing::info!/warn!/error!/debug!` call.

## Verification Results

```
running 22 tests
test broker::tests::test_duplicate_registration_rejected ... ok
test broker::tests::test_register_returns_independent_receivers ... ok
test broker::tests::test_route_to_registered_client ... ok
test broker::tests::test_route_to_unknown_returns_false ... ok
test broker::tests::test_unregister_then_route_returns_false ... ok
test pairing_token::tests::test_known_vector ... ok
test pairing_token::tests::test_reconnect_token_opaque ... ok
test pairing_token::tests::test_token_expiry ... ok
test pairing_token::tests::test_token_round_trip ... ok
test pairing_token::tests::test_token_single_use ... ok
test room_registry::tests::test_existing_room_join ... ok
test room_registry::tests::test_hold_timer_fires ... ok
test room_registry::tests::test_join_assigns_sequential_slots ... ok
test room_registry::tests::test_join_creates_room ... ok
test room_registry::tests::test_lifecycle_broadcast ... ok
test room_registry::tests::test_reconnect_cancels_timer ... ok
test room_registry::tests::test_room_full_rejection ... ok
test signaling::tests::test_parse_envelope_invalid_returns_none ... ok
test signaling::tests::test_parse_envelope_valid_json ... ok
test signaling::tests::test_signaling_envelope_wire_key_is_type ... ok
test turn_creds::tests::test_turn_credential_known_vector ... ok
test turn_creds::tests::test_turn_credentials_not_cached ... ok

test result: ok. 22 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.05s
```

**Env var enforcement verified:**
- Missing `PAIRING_TOKEN_SECRET` → `Error: PAIRING_TOKEN_SECRET environment variable not set — generate a random 32+ char secret and set it before starting the server`
- Missing `BASE_URL` → `Error: BASE_URL environment variable not set — set BASE_URL=https://<your-ip>:8443 before starting the server`

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Deviation] Plan action specified adding `base_url: String, pairing_secret: String` to relay function signatures; only `Arc<RoomRegistry>` added**
- **Found during:** Task 2 implementation
- **Issue:** The plan's action section (and PATTERNS.md) was written before Plan 03-01 finalized the `RoomRegistry::new()` constructor. The actual `handle_join`, `handle_reconnect`, and `handle_pair` method signatures store `base_url` and `pairing_secret` inside the registry — not in the relay function parameters. Adding them to relay function signatures would create dead parameters that Rust would warn about.
- **Fix:** Only `Arc<RoomRegistry>` threaded through relay function chains. All method calls use signatures as implemented in 03-01.
- **Impact:** Functionally equivalent to plan intent. Must-haves and key_links all satisfied.
- **Files modified:** `server/src/ws_server.rs`, `server/src/wt_server.rs`
- **Commit:** 02b1c61

**2. [Rule 3 — Pre-existing state] lib.rs requires no changes**
- **Found during:** Task 3 pre-check
- **Issue:** Plan action says to add `pub mod pairing_token;` and `pub mod room_registry;` to lib.rs, but Plan 03-01 already added them (commit d2ead6b).
- **Fix:** Confirmed both lines present; no edit required.
- **Files modified:** none

## Known Stubs

None. All three dispatch arms call real room_registry methods implemented in 03-01.

## Threat Flags

No new threat surface beyond the plan's threat model. T-03-04, T-03-06, T-03-07 mitigations verified:
- T-03-04: Username validation is in `room_registry.handle_join` (1–64 chars, printable ASCII)
- T-03-06: Malformed payload → `serde_json::Value` None path → `join-error "invalid_payload"` returned without crashing
- T-03-07: `pairing_token_secret` not passed to any log macro; `pairing_secret_set = true` boolean in startup log

## Self-Check

### Files exist
- server/src/signaling.rs — FOUND
- server/src/ws_server.rs — FOUND
- server/src/wt_server.rs — FOUND
- server/src/main.rs — FOUND

### Commits exist
- 88c17e4 (Task 1: signaling.rs payload structs) — FOUND
- 02b1c61 (Tasks 2+3: ws/wt wiring + main.rs env vars) — FOUND

## Self-Check: PASSED
