---
phase: 02-signaling-turn-and-deployment
plan: "05"
subsystem: validation
tags: [integration, validation, webrtc, turn, docker, signaling, checkpoint]
status: complete

dependency_graph:
  requires:
    - 02-01 (broker.rs, signaling.rs, turn_creds.rs)
    - 02-02 (ws_server.rs, wt_server.rs, main.rs broker wiring)
    - 02-03 (docker-compose.yml, Dockerfile.server, turnserver.conf)
    - 02-04 (main.rs TURN credentials HTTP endpoint)
  provides:
    - Phase 2 validated and complete
  affects: []

tech_stack:
  added: []
  patterns:
    - WebRTC ICE handshake via broker relay (ws → SignalingBroker → ws) proven in browser
    - mkcert CA required in NSS/Chrome trust store for wss:// connections to Rust server
    - CERT_PATH/KEY_PATH in .env must use absolute container paths (/certs/...) not relative

key_files:
  created: []
  modified:
    - docker-compose.yml (port 8090 for static-files; 8080 occupied on dev host)
    - docker/Dockerfile.server (rust:1-slim-bookworm pinned; rust:1-slim is now Trixie glibc 2.38, runtime is Bookworm glibc 2.36)
    - docker/coturn/turnserver.conf (removed lt-cred-mech; conflicts with use-auth-secret)
    - .env (CERT_PATH/KEY_PATH fixed to /certs/ absolute paths)
---

## Summary

Phase 2 integration validation complete. All automated tests passed and the full docker compose stack was verified manually.

## What Was Validated

**Task 1 — Full workspace test suite (automated):**
- `RUSTFLAGS="-D warnings" cargo test --workspace` exits 0
- 25 tests across 4 suites: lib tests (11), binary tests (12), broker_relay integration (1), ws_echo integration (1)
- All Phase 2 tests passing: `test_broker_relay_ws`, `test_turn_credential_known_vector`, `test_turn_credentials_not_cached`, `test_turn_creds_handler_unit`
- Zero warnings, zero failures

**Task 2 — Manual validation (human checkpoint):**

| Check | Result | Notes |
|-------|--------|-------|
| 1. docker compose up (3 containers) | ✅ PASSED | server, coturn, static-files all running |
| 2. coturn STUN/TURN reachability | ✅ PASSED | 403 Forbidden IP = coturn running, credentials validated, loopback peer blocked by security policy (expected) |
| 3. GET /turn-credentials (two calls, different usernames) | ✅ PASSED | JSON with username/password; sequential calls return different expiry timestamps |
| 4. WebRTC ICE handshake end-to-end | ✅ PASSED | Both tabs: `connectionState === 'connected'`, data channel open |
| 5. TURN relay-only | skipped | Check 4 succeeded via direct ICE; TURN relay path deferred |

## Issues Found and Fixed During Validation

| Fix | Root Cause | Commit |
|-----|-----------|--------|
| static-files port 8090 | port 8080 occupied on dev host | 5377e0a |
| `rust:1-slim-bookworm` in Dockerfile | `rust:1-slim` moved to Debian Trixie (glibc 2.38); runtime is Bookworm (glibc 2.36) | b611e48 |
| Remove `lt-cred-mech` from turnserver.conf | Conflicts with `use-auth-secret`; shared secret auth requires only `use-auth-secret` | 2e5f71a |
| CERT_PATH/KEY_PATH absolute in .env | Relative paths (`certs/`) don't resolve inside container; mount is at `/certs/` | user-applied |

## Deviations

- Check 5 (TURN relay-only) not performed — Check 4 passed via direct ICE path, satisfying INFRA-02 success criterion 1. TURN relay path (iceTransportPolicy: 'relay') is an optional check and deferred.

## Self-Check: PASSED

All Phase 2 required success criteria met:
- [x] `cargo test --workspace` exits 0, zero warnings
- [x] docker compose up brings 3 healthy containers
- [x] coturn responds to TURN protocol (credentials validated)
- [x] GET /turn-credentials returns different credentials on sequential calls
- [x] WebRTC ICE handshake via Rust signaling broker — data channel open in both tabs
