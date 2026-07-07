---
phase: "03-session-and-pairing"
plan: "01"
subsystem: "server"
status: complete
tags: ["rust", "hmac", "room-registry", "pairing-token", "hold-timer", "dashmap"]
dependency_graph:
  requires: []
  provides:
    - "pairing_token::generate_pairing_token"
    - "pairing_token::validate_and_consume"
    - "pairing_token::generate_reconnect_token"
    - "pairing_token::PairingTokenStore"
    - "room_registry::RoomRegistry"
    - "room_registry::Room"
    - "room_registry::SlotInfo"
    - "room_registry::SlotStatus"
  affects:
    - "server/Cargo.toml"
    - "server/src/lib.rs"
tech_stack:
  added:
    - "sha2 = 0.11 (RustCrypto — SHA-256 for pairing tokens)"
    - "rand = 0.10 with features=[std] (rust-random — room code generation)"
    - "tokio time feature (hold timer sleep)"
  patterns:
    - "HMAC-SHA256 self-validating token (turn_creds.rs pattern with sha2)"
    - "DashMap entry API for atomic single-use token tracking"
    - "JoinHandle::abort() via remove() for cancel-safe hold timer"
    - "DashMap Ref clone-before-drop pattern (Pitfall 1 avoidance)"
key_files:
  created:
    - "server/src/pairing_token.rs"
    - "server/src/room_registry.rs"
  modified:
    - "server/Cargo.toml"
    - "server/src/lib.rs"
decisions:
  - "rand::random::<[u8;32]>() used for reconnect tokens — free function, no trait import, stable across rand versions"
  - "rand::RngExt::random_range used for room code — gen_range renamed in rand 0.10"
  - "cargo test --lib workaround for pre-existing TurnCredentials Debug issue in binary target"
metrics:
  duration: "16 min"
  completed_date: "2026-07-07"
  tasks_completed: 3
  files_modified: 4
---

# Phase 03 Plan 01: Pairing Token and Room Registry Summary

HMAC-SHA256 pairing token lifecycle and 8-slot room registry with hold timers — server-side engine modules underpinning all Phase 3 session management.

## What Was Built

### Task 1: Crate Legitimacy Gate (checkpoint — cleared by user)

The user confirmed at crates.io:
- `sha2 = "0.11"` — RustCrypto org, tens of millions of downloads
- `rand = "0.10"` — rust-random org, hundreds of millions of downloads

Gate cleared before Cargo.toml was modified (T-03-SC mitigation).

### Task 2: Cargo.toml + pairing_token.rs

**Exact function signatures:**

```rust
pub fn generate_pairing_token(
    secret: &str,
    room_code: &str,
    slot_id: u8,
    expiry_unix: u64,
) -> anyhow::Result<String>

pub fn generate_reconnect_token() -> String

impl PairingTokenStore {
    pub fn new() -> Self
    pub fn validate_and_consume(&self, secret: &str, token: &str) -> Option<(String, u8)>
}
```

**Token format:** `base64url(payload).base64url(hmac_sha256(secret, payload))`
where `payload = "{room_code}:{slot_id}:{expiry_unix}"`.

**Known vector verified:**
```
generate_pairing_token("testsecret", "ABCD23", 2, 9_999_999_999)
→ "QUJDRDIzOjI6OTk5OTk5OTk5OQ.imJWyASM57L4QNGKY688w012a1G4z0dmTmJq2OZVVAc"
```

**5 tests green:**
- `test_known_vector` — HMAC-SHA256 exact algorithm match
- `test_token_round_trip` — generate + validate + correct room_code/slot_id
- `test_token_single_use` — second call with same token returns None
- `test_token_expiry` — past expiry returns None
- `test_reconnect_token_opaque` — non-empty, distinct per call

### Task 3: room_registry.rs

**Exact struct field names:**

```rust
pub struct RoomRegistry {
    rooms: Arc<DashMap<RoomCode, Room>>,
    hold_timers: Arc<DashMap<(RoomCode, SlotId), JoinHandle<()>>>,
    reconnect_tokens: Arc<DashMap<String, (RoomCode, SlotId)>>,
    pairing_store: Arc<PairingTokenStore>,
    pairing_secret: String,
    base_url: String,
    hold_ttl_secs: u64,
    pairing_ttl_secs: u64,
}

pub struct Room {
    pub code: RoomCode,
    pub game_type: String,
    pub slots: Vec<Option<SlotInfo>>,  // len=8, index = slot_id - 1
    pub max_slots: usize,              // always 8
}

pub struct SlotInfo {
    pub client_id: String,
    pub username: String,
    pub status: SlotStatus,
    pub reconnect_token: String,
}

pub enum SlotStatus { Empty, Connected, Disconnected }
```

**Constructor:**
```rust
impl RoomRegistry {
    pub fn new(
        pairing_secret: String,
        base_url: String,
        hold_ttl_secs: u64,
        pairing_ttl_secs: u64,
    ) -> Self
}
```

**7 tests green:**
- `test_join_creates_room` — empty room_code creates room, slot=1, 6-char code from charset
- `test_join_assigns_sequential_slots` — slots 1, 2, 3 assigned in order
- `test_room_full_rejection` — 9th join returns join-error reason=room_full
- `test_existing_room_join` — non-empty room_code joins existing room
- `test_reconnect_cancels_timer` — hold timer aborted, slot → Connected
- `test_hold_timer_fires` — hold_ttl=0, slot released after 50ms
- `test_lifecycle_broadcast` — B disconnects; A receives player-disconnected event

**Full cargo test output (library target):**
```
running 22 tests
test broker::tests::test_duplicate_registration_rejected ... ok
test broker::tests::test_register_returns_independent_receivers ... ok
test broker::tests::test_route_to_registered_client ... ok
test broker::tests::test_route_to_unknown_returns_false ... ok
test pairing_token::tests::test_reconnect_token_opaque ... ok
test broker::tests::test_unregister_then_route_returns_false ... ok
test pairing_token::tests::test_token_round_trip ... ok
test pairing_token::tests::test_known_vector ... ok
test pairing_token::tests::test_token_expiry ... ok
test pairing_token::tests::test_token_single_use ... ok
test signaling::tests::test_parse_envelope_invalid_returns_none ... ok
test signaling::tests::test_signaling_envelope_wire_key_is_type ... ok
test signaling::tests::test_parse_envelope_valid_json ... ok
test turn_creds::tests::test_turn_credentials_not_cached ... ok
test turn_creds::tests::test_turn_credential_known_vector ... ok
test room_registry::tests::test_existing_room_join ... ok
test room_registry::tests::test_join_creates_room ... ok
test room_registry::tests::test_join_assigns_sequential_slots ... ok
test room_registry::tests::test_lifecycle_broadcast ... ok
test room_registry::tests::test_reconnect_cancels_timer ... ok
test room_registry::tests::test_room_full_rejection ... ok
test room_registry::tests::test_hold_timer_fires ... ok

test result: ok. 22 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.05s
```

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] rand 0.10 RngCore not in rand re-export**
- **Found during:** Task 2, pairing_token.rs compile
- **Issue:** `use rand::RngCore` fails — `RngCore` was not re-exported from `rand` in 0.10
- **Fix:** Changed `generate_reconnect_token()` to `let bytes: [u8; 32] = rand::random();` — free function, no trait import, works across rand versions
- **Files modified:** `server/src/pairing_token.rs`
- **Commit:** edb4d41

**2. [Rule 1 - Bug] rand 0.10 renamed gen_range to random_range on RngExt**
- **Found during:** Task 3, room_registry.rs compile
- **Issue:** `rng.random_range()` requires `use rand::RngExt;` in scope (not `rand::Rng`)
- **Fix:** Changed import from `use rand::Rng;` to `use rand::RngExt;`
- **Files modified:** `server/src/room_registry.rs`
- **Commit:** d2ead6b

**3. [Rule 1 - Bug] Rust borrow-checker: simultaneous &/&mut borrow in on_client_disconnect**
- **Found during:** Task 3, room_registry.rs compile
- **Issue:** `room_ref.code.clone()` inside the `room_ref.slots.iter_mut()` loop caused borrow conflict — Rust cannot hold `&room_ref` (for code) and `&mut room_ref.slots` (for the iterator) simultaneously
- **Fix:** Moved `let code = room_ref.code.clone()` to before the `iter_mut()` call
- **Files modified:** `server/src/room_registry.rs`
- **Commit:** d2ead6b

**4. [Out-of-scope — logged to deferred-items.md] Pre-existing TurnCredentials Debug compile error**
- **Found during:** Task 2, first test run
- **Issue:** `main.rs` binary test target fails: `TurnCredentials` does not implement `Debug`, required by `expect_err()` in Rust 1.93.1
- **Action:** Logged to `deferred-items.md`. Workaround: `cargo test --lib` skips binary test target. All 22 library tests run cleanly.

## Known Stubs

None. Both modules implement real logic; no placeholder values or TODO paths reach the test surface.

## Threat Flags

No new threat surface beyond the plan's threat model. All T-03-* mitigations implemented:
- T-03-01: Single-use DashMap entry tracking + constant-time HMAC verify
- T-03-02: Max 8 slots enforced in handle_join
- T-03-03: `mac.verify_slice()` used throughout (no `==` comparison)
- T-03-04: Username trimmed, ASCII-only, 1–64 chars
- T-03-05: Reconnect tokens opaque 32-byte random, server-side lookup only
- T-03-06: serde_json::Value::as_str() returns None on malformed payload → join-error

## Self-Check

### Files exist

- server/src/pairing_token.rs — FOUND
- server/src/room_registry.rs — FOUND
- server/Cargo.toml (sha2, rand, tokio time) — FOUND

### Commits exist

- edb4d41 (Task 2: pairing_token.rs) — FOUND
- d2ead6b (Task 3: room_registry.rs) — FOUND

## Self-Check: PASSED
