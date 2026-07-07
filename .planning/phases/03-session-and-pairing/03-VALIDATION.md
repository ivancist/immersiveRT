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
| **Framework** | vitest (browser client) / cargo test (Rust server) |
| **Config file** | vitest.config.ts / Cargo.toml |
| **Quick run command** | `npm run test:unit` / `cargo test` |
| **Full suite command** | `npm run test` / `cargo test --workspace` |
| **Estimated runtime** | ~15 seconds |

---

## Sampling Rate

- **After every task commit:** Run `npm run test:unit` / `cargo test`
- **After every plan wave:** Run `npm run test` / `cargo test --workspace`
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 03-01-01 | 01 | 1 | SESS-01 | — | Session token opaque, not guessable | unit | `cargo test session` | ❌ W0 | ⬜ pending |
| 03-01-02 | 01 | 1 | SESS-02 | — | Pairing code 6-digit, expires TTL | unit | `cargo test pairing` | ❌ W0 | ⬜ pending |
| 03-02-01 | 02 | 1 | SESS-03 | — | WebTransport stream handles session join | integration | `cargo test wt_session` | ❌ W0 | ⬜ pending |
| 03-02-02 | 02 | 1 | SESS-04 | — | ICE candidates relayed within 500ms | integration | `cargo test ice_relay` | ❌ W0 | ⬜ pending |
| 03-03-01 | 03 | 2 | SESS-05 | — | Phone client pairs and receives RTCPeerConnection config | e2e | `npm run test:e2e:pair` | ❌ W0 | ⬜ pending |
| 03-03-02 | 03 | 2 | SESS-06 | — | Desktop receives phone IMU data via data channel | e2e | `npm run test:e2e:imu` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `server/tests/session_tests.rs` — unit stubs for SESS-01, SESS-02
- [ ] `server/tests/wt_session_tests.rs` — integration stubs for SESS-03, SESS-04
- [ ] `tests/e2e/pair.test.ts` — e2e stubs for SESS-05, SESS-06
- [ ] `vitest.config.ts` — browser test config if not present
- [ ] `cargo test --workspace` must pass with stub tests

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Phone permission prompt fires on iOS 13+ | SESS-05 | Requires physical iOS device + user gesture | Tap "Enable Motion" on phone client, verify DeviceMotionEvent fires |
| TURN relay path under restrictive NAT | SESS-04 | Requires network simulation | Use coturn with firewall rules; verify ICE connects via relay |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
