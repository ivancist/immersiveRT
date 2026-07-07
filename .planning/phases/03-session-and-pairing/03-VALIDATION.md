---
phase: 3
slug: session-and-pairing
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-07-07
---

# Phase 3 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | cargo test (Rust server inline module tests) / docker compose + curl (nginx integration) |
| **Config file** | server/Cargo.toml |
| **Quick run command** | `cargo test -p immersive-rt-server 2>&1 \| tail -20` |
| **Full suite command** | `cargo test -p immersive-rt-server && docker compose config --quiet` |
| **Estimated runtime** | ~15 seconds |

---

## Sampling Rate

- **After every task commit:** Run quick command above
- **After every plan wave:** Run full suite command
- **Before `/gsd-verify-work`:** Full suite must be green + 03-04-T3 E2E checkpoint passed
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Test Type | Automated Command | Status |
|---------|------|------|-------------|------------|-----------|-------------------|--------|
| 03-01-T1 | 03-01 | 1 | SESS-01, SESS-02 | T-03-SC | checkpoint | `echo "human checkpoint — crates verified at crates.io"` | ⬜ pending |
| 03-01-T2 | 03-01 | 1 | SESS-01, SESS-02 | T-03-01, T-03-03 | unit/tdd | `cargo test -p immersive-rt-server pairing_token::tests 2>&1 \| tail -20` | ⬜ pending |
| 03-01-T3 | 03-01 | 1 | SESS-01, SESS-04, SESS-05, SESS-06 | T-03-02, T-03-04 | unit/tdd | `cargo test -p immersive-rt-server room_registry::tests 2>&1 \| tail -30` | ⬜ pending |
| 03-03-T1 | 03-03 | 1 | SESS-03 | T-03-05, T-03-08 | source | `grep -c 'try_files' docker/nginx/nginx.conf && grep -c 'ssl_certificate' docker/nginx/nginx.conf` | ⬜ pending |
| 03-03-T2 | 03-03 | 1 | SESS-03 | T-03-05 | integration | `docker compose config --quiet 2>&1 \| head -5 && grep -c '8443' docker-compose.yml` | ⬜ pending |
| 03-02-T1 | 03-02 | 2 | SESS-01, SESS-02 | — | source | `cargo check -p immersive-rt-server 2>&1 \| tail -10` | ⬜ pending |
| 03-02-T2 | 03-02 | 2 | SESS-01, SESS-04, SESS-06 | — | source | `cargo check -p immersive-rt-server 2>&1 \| tail -15` | ⬜ pending |
| 03-02-T3 | 03-02 | 2 | SESS-01, SESS-02, SESS-04, SESS-06 | — | unit | `cargo test -p immersive-rt-server 2>&1 \| tail -20` | ⬜ pending |
| 03-04-T1 | 03-04 | 3 | SESS-01, SESS-02, SESS-03, SESS-05, SESS-06 | T-03-10 | source | `grep -c 'view-lobby\|view-room\|view-phone\|view-join-form\|view-game-select' client/dist/index.html && grep -c 'qrcode@1.5.4' client/dist/index.html` | ⬜ pending |
| 03-04-T2 | 03-04 | 3 | SESS-01–SESS-06 | T-03-09, T-03-10 | integration | `docker compose up -d 2>&1 \| tail -3 && sleep 2 && curl -sk https://localhost:8443/ \| grep -c 'Create Room'` | ⬜ pending |
| 03-04-T3 | 03-04 | 3 | SESS-01–SESS-06 | all | checkpoint/e2e | `echo "human E2E checkpoint — full stack pairing flow verified"` | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `server/src/pairing_token.rs` — module with `#[cfg(test)] mod tests` stub (created by 03-01-T2 TDD)
- [ ] `server/src/room_registry.rs` — module with `#[cfg(test)] mod tests` stub (created by 03-01-T3 TDD)
- [ ] `cargo test -p immersive-rt-server` passes with stubs (no compile errors)

*Wave 0 is satisfied by the TDD tasks in 03-01 — test stubs are written before implementation in each task.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Phone permission prompt fires on iOS 13+ | SESS-05 | Requires physical iOS device + user gesture | Tap "Enable Motion" on phone landing page, verify DeviceMotionEvent fires |
| TURN relay path under restrictive NAT | SESS-04 (reconnect) | Requires network simulation or real NAT | Test disconnect/reconnect within 60s on flaky WiFi; verify slot reclaimed without re-pairing |
| Second phone rejected from paired slot | SESS-02 | Requires two physical devices | Pair phone A to slot; attempt same short code from phone B; verify "slot taken" error |
| 9th desktop join rejected | SESS-05 | Requires 9 concurrent connections | Open 9 browser tabs; verify join-error on 9th tab |

These are covered by 03-04-T3 (blocking human checkpoint).

---

## Validation Sign-Off

- [ ] All auto tasks have `<automated>` verify blocks with runnable commands
- [ ] Sampling continuity: no 3 consecutive auto tasks without verification
- [ ] Wave 0 TDD stubs confirmed (03-01-T2 and 03-01-T3 test files exist before implementation)
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s for all automated tasks
- [ ] 03-04-T3 E2E checkpoint passed (full stack pairing flow verified manually)
- [ ] `nyquist_compliant: true` set in frontmatter after all above pass

**Approval:** pending
