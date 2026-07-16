---
phase: 07
slug: sdk-public-api
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-07-16
---

# Phase 07 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Vitest `^3.0.0` (matches `client/package.json`'s existing pin) |
| **Config file** | New `packages/immersive-rt/vite.config.ts` — `test.environment: 'jsdom'` (mirrors `client/vite.config.ts`'s existing inline `test` block; no separate `vitest.config.ts` exists in this repo, keep that convention) |
| **Quick run command** | `npm run test -w packages/immersive-rt -- <test-file-pattern>` |
| **Full suite command** | `npm run test -w packages/immersive-rt` |
| **Estimated runtime** | ~10-15 seconds (comparable scale to `client`'s existing ~10s suite) |

---

## Sampling Rate

- **After every task commit:** Run the targeted `vitest run <file>` for the module just changed
- **After every plan wave:** Run `npm run test -w packages/immersive-rt` (full suite)
- **Before `/gsd-verify-work`:** Full suite green, plus `npm run typecheck -w packages/immersive-rt` and (if `client` also changed) `npm run typecheck -w client`
- **Max feedback latency:** ~15 seconds

---

## Per-Task Verification Map

*Task ID / Plan / Wave columns are TBD — the planner assigns real task IDs when breaking this phase into PLAN.md files. Requirement-level mapping below is locked from research and MUST be preserved when the planner fills in concrete task IDs.*

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 07-03 T3 | 07-03 | 3 | SDK-01 | — | `tsc --strict` compiles a consumer fixture against published types with no errors | type-check | `npm run typecheck -w packages/immersive-rt` (fixture `tests/typecheck-fixture.ts` calls `getPlayerInput(id)` / `on('imuUpdate', cb)`) | ❌ W0 → 07-03 | ⬜ pending |
| 07-03 T2 | 07-03 | 3 | SDK-02 | — | `getPlayerInput()` returns the exact `{ orientation, gestureDisplacement, deadReckoningPosition, driftConfidence, touch }` shape | unit | `npx vitest run tests/platform.test.ts -t "getPlayerInput"` | ❌ W0 → 07-03 | ⬜ pending |
| 07-03 T3 / 07-05 T2 | 07-03, 07-05 | 3, 5 | SDK-03 | T-07-05-01 | `imuUpdate`/`playerJoin`/`playerLeave`/`playerReconnect` fire with correct signatures at correct lifecycle moments | unit | `npx vitest run tests/platform.test.ts -t "events"`; `npx vitest run tests/connection.test.ts` (RTC lifecycle) | ❌ W0 → 07-03/05 | ⬜ pending |
| 07-06 T1/T2 | 07-06 | 6 | SDK-04 | T-07-06-01 | Latency overlay renders rolling avg latency/jitter/loss%/ICE state per player from computed (non-live) inputs; textContent-only | unit (jsdom DOM assertions) | `npx vitest run tests/latencyOverlay.test.ts` | ❌ W0 → 07-06 | ⬜ pending |
| 07-02 T1 | 07-02 | 2 | SDK-05 | T-07-02-01/02/03 | Extraction preserves `deadReckoningPosition`/`driftConfidence` naming + decode guards — no silent rename or guard weakening | unit (regression) | `npx vitest run tests/decode.test.ts tests/target-state.test.ts` | ✅ moves from `client/tests/decode.test.ts`, `target-state.test.ts` | ⬜ pending |
| 07-03 T2 | 07-03 | 3 | SDK-06 | — | `getRawInput().orientationRaw` returns the unsmoothed quaternion, distinct from `getPlayerInput().orientation` | unit | `npx vitest run tests/platform.test.ts -t "raw"` / `tests/tick.test.ts` | ❌ W0 → 07-03 | ⬜ pending |
| 07-03 T1 | 07-03 | 3 | SDK-06 | — | jsdom-default fallback path (no `requestAnimationFrame`) is exercised, not just the rAF-mocked path (RESEARCH Pitfall 2: jsdom 29 has no rAF) | unit | `npx vitest run tests/tick.test.ts -t "fallback"` | ❌ W0 → 07-03 | ⬜ pending |
| 07-05 T1 | 07-05 | 5 | SDK-02/03 | T-07-05-01 | decode→isSafePacket→isNewerSeq→updateTargetState guard chain preserved verbatim; malformed/non-finite/out-of-order dropped | unit | `npx vitest run tests/connection.test.ts` (handlePacket guard-drop cases) | ❌ W0 → 07-05 | ⬜ pending |
| 07-07 T3 | 07-07 | 7 | SDK-04, D-16 | T-07-06-01 | Live ICE state / real RTT via `RTCPeerConnection.getStats()` on an actual connection + overlay live | manual-only | N/A — requires a real `RTCPeerConnection`, not mockable in jsdom (on-device checkpoint) | N/A | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `packages/immersive-rt/vite.config.ts` — framework config, does not exist yet (new package)
- [ ] `packages/immersive-rt/tests/platform.test.ts` — covers SDK-02, SDK-03
- [ ] `packages/immersive-rt/tests/tick.test.ts` — covers SDK-06; must exercise both the rAF-mocked path and the jsdom-default fallback path
- [ ] `packages/immersive-rt/tests/latencyOverlay.test.ts` — covers SDK-04's computable (non-live-network) portions
- [ ] `packages/immersive-rt/tests/slerp.test.ts` — pure-function unit test for the hand-written SLERP (D-07)
- [ ] Moved (not new) test files: `decode.test.ts`, `target-state.test.ts` from `client/tests/` — relocate alongside their source files, do not duplicate
- [ ] Framework install: none — `vitest`/`jsdom` already exist as devDependency patterns in `client/package.json`; replicate into the new package's `package.json`

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Live ICE state and real round-trip-time reporting in the latency overlay | SDK-04, D-16 | `RTCPeerConnection.getStats()` requires a real peer connection with live ICE candidates — not fully mockable in jsdom | Connect a phone to a desktop session, attach the overlay, confirm ICE state transitions and a plausible RTT number appear and update live |
| Jitter / packet-loss % computed from `seq`/`timestamp` fields (RESEARCH correction to D-16: `getStats()` does not expose `jitter`/`packetsLost` on a data-channel-only connection) | SDK-04, D-16 | Requires a real, lossy/jittery network path to observe non-zero values — the computation logic itself is unit-testable, but end-to-end accuracy needs a live session | Connect on a real network (or throttle via devtools), confirm jitter and packet-loss % move in the expected direction under induced loss |
| Overlay single-line include works with no additional configuration | SDK-04 | End-to-end DX check that spans package build output + consumer integration, not a unit-testable property | In a scratch consumer project, call `platform.attachLatencyOverlay()` with no other setup and confirm it renders |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 15s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
