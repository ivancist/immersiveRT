---
phase: 4
slug: phone-bootstrap-and-webrtc-channels
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-07-08
---

# Phase 04 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | vitest (client JS) + cargo test (Rust server) |
| **Config file** | package.json (vitest config) / Cargo.toml |
| **Quick run command** | `cargo test -p immersive-rt-server -- --test-threads=4` |
| **Full suite command** | `cargo test && npx vitest run` |
| **Estimated runtime** | ~15 seconds |

---

## Sampling Rate

- **After every task commit:** Run `cargo test -p immersive-rt-server -- --test-threads=4`
- **After every plan wave:** Run `cargo test && npx vitest run`
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 20 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 04-01-01 | 01 | 1 | PHONE-01 | — | Phone URL loads over HTTPS only | unit | `npx vitest run` | ❌ W0 | ⬜ pending |
| 04-01-02 | 01 | 1 | PHONE-02 | — | iOS permission gate fires on gesture only | manual | see Manual-Only | N/A | ⬜ pending |
| 04-01-03 | 01 | 1 | PHONE-03 | — | Wake Lock acquires on session start | unit | `npx vitest run` | ❌ W0 | ⬜ pending |
| 04-02-01 | 02 | 2 | PHONE-03 | — | WebRTC data channel opens unreliable | unit | `cargo test` | ❌ W0 | ⬜ pending |
| 04-02-02 | 02 | 2 | PHONE-06 | — | Heartbeat sent every 5s | unit | `cargo test` | ❌ W0 | ⬜ pending |
| 04-02-03 | 02 | 2 | PHONE-07 | — | Disconnected slot not evicted for 65s | unit | `cargo test` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `client/phone/__tests__/phone-bootstrap.test.ts` — stubs for PHONE-01, PHONE-02, PHONE-03
- [ ] `server/src/tests/heartbeat.rs` — stubs for PHONE-06, PHONE-07
- [ ] vitest installed in package.json devDependencies if not already present

*Existing infrastructure may cover some requirements — planner to confirm.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| iOS DeviceMotionEvent permission prompt fires on button tap | PHONE-02 | Requires physical iOS 13+ device; Safari enforces gesture stack at OS level | Load phone URL on iPhone 13+, tap "Grant Motion Access", confirm native prompt appears |
| Screen stays on during active session | PHONE-01 | Wake Lock behavior varies by device power settings | Connect phone, wait 45s, verify screen stays on |
| QR scan loads app on Android | PHONE-01 | Requires physical Android device | Scan QR on Android Chrome, verify app loads without install prompt |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 20s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
