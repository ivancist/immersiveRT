---
phase: 02
fixed_at: 2026-07-07T00:00:00Z
status: all_fixed
fix_scope: critical_warning
findings_in_scope: 14
fixed: 14
skipped: 0
iteration: 1
---

# Phase 02: Code Review Fix Report

**Fixed:** 2026-07-07
**Scope:** Critical + Warning (14 findings)
**Status:** all_fixed — 14/14 fixed, 0 skipped

---

## Critical Fixes (4/4)

### CR-01 — TURN Credential Endpoint Authentication
**Commit:** `d75a55d`
**Files:** `server/src/main.rs`, `docker-compose.yml`
Added `Authorization: Bearer` header check to `/turn-credentials` endpoint. Endpoint now returns 401 Unauthorized if token is missing or wrong. `API_TOKEN` injected via env var.

### CR-02 — Signaling Envelope `from` Field Validation
**Commit:** `9b91a00`
**Files:** `server/src/ws_server.rs`, `server/src/wt_server.rs`
Added validation of `envelope.from` against the sender's registered client ID in both relay handlers. Spoofed messages are logged and dropped — prevents client impersonation.

### CR-03 — coturn SSRF Protections
**Commit:** `9c5e65a`
**Files:** `docker/coturn/turnserver.conf`
Added `no-loopback-peers` and `denied-peer-ip` rules covering all RFC 1918 private ranges, loopback, link-local, and cloud-metadata addresses (169.254.0.0/16, 100.64.0.0/10).

### CR-04 — Docker Container Non-Root User
**Commit:** `37d146e`
**File:** `docker/Dockerfile.server`
Added `groupadd`/`useradd` for a non-root `immersivert` system user. `USER immersivert` directive added before `CMD`.

---

## Warning Fixes (10/10)

### WR-01 — Duplicate Client ID Registration
**Commit:** `d218be3`
**Files:** `server/src/broker.rs`, `server/src/ws_server.rs`, `server/src/wt_server.rs`
`register()` returns `Result<_, &'static str>` and rejects duplicate IDs with an error.

### WR-02 — WebTransport Connection Limit
**Commit:** `d0a26f6`
**File:** `server/src/wt_server.rs`
Added `Semaphore` with `MAX_WT_CONNECTIONS=1024` to the WebTransport accept loop, matching the existing WebSocket connection limit.

### WR-03 — TURN Secret Not Exposed in CLI Args
**Commit:** `df15ee5`
**Files:** `docker-compose.yml`, `docker/coturn/turnserver.conf`, `docker/coturn/docker-entrypoint.sh`
Secret injected via env var through a new entrypoint script. Removed `--static-auth-secret` from CLI args in Compose.

### WR-04 — WebTransport Registration Timeout
**Commit:** `fe0e510`
**File:** `server/src/wt_server.rs`
Wrapped registration read loop in `tokio::time::timeout(10s)` to prevent connections that never send a registration from holding resources indefinitely.

### WR-05 — Replace unwrap on Semaphore Acquire
**Commit:** `82191a4`
**File:** `server/src/ws_server.rs`
Changed `.unwrap()` to `.expect("semaphore closed")` with a descriptive panic message.

### WR-06 — TURN Quota and Bandwidth Limits
**Commit:** `4e772f4`
**File:** `docker/coturn/turnserver.conf`
Added `total-quota=100`, `user-quota=10`, `max-bps=500000` to bound relay bandwidth and concurrent sessions.

### WR-07 — Integration Test Timing (yield_now → sleep)
**Commit:** `8cfbc8b`
**Files:** `server/tests/broker_relay.rs`, `server/tests/ws_echo.rs`
Replaced `yield_now()` with `sleep(50ms)` to give the server time to process before test assertions.

### WR-08 — Remove Public Port for Plain HTTP Endpoint
**Commit:** `a4e55b2`
**File:** `docker-compose.yml`
Removed `8081:8081/tcp` public port mapping. Added comment explaining the endpoint is TLS/channel-only.

### WR-09 — Break on WT Stream Open Failure
**Commit:** `26b4f61`
**File:** `server/src/wt_server.rs`
Changed `continue` to `break` on stream open failures in the outbound relay arm to avoid tight error loops.

### WR-10 — Remove Dead `echo` Module
**Commit:** `773ef6a`
**Files:** `server/src/main.rs`, `server/src/lib.rs`, deleted `server/src/echo.rs`
Removed dead echo module declaration from both crate roots and deleted the file.

---

## Info Findings (out of scope)

4 Info findings were not in fix scope (critical_warning only). Run `/gsd-code-review 2 --fix --all` to include them.
