---
phase: 05
slug: sensor-fusion-and-packet-encoding
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-07-09
---

# Phase 05 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Vitest 3.x (Vite-native) |
| **Config file** | `client/vite.config.ts` (add `test: { environment: 'jsdom' }` key) |
| **Quick run command** | `npm run test` (alias for `vitest run`) |
| **Full suite command** | `vitest run --reporter=verbose` |
| **Estimated runtime** | ~5 seconds |

---

## Sampling Rate

- **After every task commit:** Run `npm run test`
- **After every plan wave:** Run `vitest run --reporter=verbose`
- **Before `/gsd-verify-work`:** All unit tests green + on-device Hz verification
- **Max feedback latency:** ~5 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 05-01-01 | 01 | 0 | PHONE-05 | — | N/A | unit | `vitest run tests/encode.test.ts` | ❌ W0 | ⬜ pending |
| 05-01-02 | 01 | 0 | SENS-05, SENS-06 | — | N/A | unit | `vitest run tests/encode.test.ts` | ❌ W0 | ⬜ pending |
| 05-02-01 | 02 | 0 | SENS-01, SENS-02 | — | N/A | unit | `vitest run tests/orientation.test.ts` | ❌ W0 | ⬜ pending |
| 05-03-01 | 03 | 0 | SENS-03 | — | N/A | unit | `vitest run tests/zupt.test.ts` | ❌ W0 | ⬜ pending |
| 05-04-01 | 04 | 0 | SENS-04 | — | N/A | unit | `vitest run tests/kalman.test.ts` | ❌ W0 | ⬜ pending |
| 05-05-01 | 05 | 1 | PHONE-04 | — | N/A | manual/smoke | On-device: byte-count logger shows Hz ≥ 55 | manual only | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `client/tests/encode.test.ts` — covers PHONE-05 (byte count = 36), float16 round-trip, SENS-05, SENS-06
- [ ] `client/tests/orientation.test.ts` — covers SENS-01 (quaternion unit-norm), SENS-02 (beta ramp), quaternion formula correctness
- [ ] `client/tests/zupt.test.ts` — covers SENS-03 (300ms window, variance threshold)
- [ ] `client/tests/kalman.test.ts` — covers SENS-04 (integration, reset, confidence)
- [ ] Framework install: `npm install --save-dev vitest` inside `client/` — Vite already in devDeps
- [ ] `client/tsconfig.json` — required before TypeScript compiles
- [ ] `client/package.json` — required before `npm install`

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| 60Hz+ packet rate on mid-range Android | PHONE-04 | Requires physical device; DeviceMotionEvent rate is OS-controlled | Open phone client on mid-range Android in Chrome; open DevTools console via USB debugging; observe byte-count logger output: Hz must show ≥ 55 for 10 consecutive seconds |
| Drift-free quaternion after 360° rotation | SENS-01 (live) | Requires physical device rotation | Rotate phone 360° on each axis, hold still 30s; yaw error < 5° |
| ZUPT reset on 300ms stillness | SENS-03 (live) | Requires physical stillness detection | Hold phone still for 300ms; observe `driftConfidence` → 1.0 |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 5s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
