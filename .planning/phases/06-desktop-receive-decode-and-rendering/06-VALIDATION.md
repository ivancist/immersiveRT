---
phase: 06
slug: desktop-receive-decode-and-rendering
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-07-10
---

# Phase 06 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | vitest |
| **Config file** | `client/vitest.config.ts` (or Wave 0 installs) |
| **Quick run command** | `npm run test --workspace=client` |
| **Full suite command** | `npm run test --workspace=client` |
| **Estimated runtime** | ~10 seconds |

---

## Sampling Rate

- **After every task commit:** Run `npm run test --workspace=client`
- **After every plan wave:** Run `npm run test --workspace=client`
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 10 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 06-01-01 | 01 | 1 | DESK-01 | — | N/A | unit | `npm run test --workspace=client` | ❌ W0 | ⬜ pending |
| 06-01-02 | 01 | 1 | DESK-02 | — | N/A | unit | `npm run test --workspace=client` | ❌ W0 | ⬜ pending |
| 06-02-01 | 02 | 2 | DESK-03 | — | N/A | unit | `npm run test --workspace=client` | ❌ W0 | ⬜ pending |
| 06-02-02 | 02 | 2 | DESK-04 | — | N/A | unit | `npm run test --workspace=client` | ❌ W0 | ⬜ pending |
| 06-03-01 | 03 | 3 | DESK-05 | — | N/A | manual | Visual inspection: two phones drive two cubes simultaneously | N/A | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `client/src/__tests__/decode.test.ts` — stubs for DESK-01, DESK-02
- [ ] `client/src/__tests__/playerStore.test.ts` — stubs for DESK-03
- [ ] `client/src/__tests__/seqDrop.test.ts` — stubs for DESK-03
- [ ] vitest if not already installed in client workspace

*Note: DESK-04 (SLERP rendering) and DESK-05 (two-player) are manual verifications — automated unit coverage covers decode and seq-drop logic only.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Three.js cube rotates smoothly following phone | DESK-04 | Requires real WebRTC channel + physical device | Connect phone, tilt, observe cube SLERP — no jitter visible |
| Two phones drive two distinct objects simultaneously | DESK-05 | Requires two physical devices | Connect two phones, move independently, verify both cubes respond |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 10s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
