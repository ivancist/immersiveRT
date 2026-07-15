---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: milestone
current_phase: 06.3
current_phase_name: ios-native-client-arkit-world-tracking
status: executing
stopped_at: Phase 06.3 context gathered
last_updated: "2026-07-15T08:02:30.939Z"
last_activity: 2026-07-15
last_activity_desc: Phase 06.3 execution started
progress:
  total_phases: 11
  completed_phases: 7
  total_plans: 48
  completed_plans: 39
  percent: 64
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-07-07)

**Core value:** Phone motion feels physically immediate on screen — sub-20ms sensor delivery from phone to desktop, lowest possible latency.
**Current focus:** Phase 06.3 — ios-native-client-arkit-world-tracking

## Current Position

Phase: 06.3 (ios-native-client-arkit-world-tracking) — EXECUTING
Plan: 1 of 8
Status: Executing Phase 06.3
Last activity: 2026-07-15 — Phase 06.3 execution started

Progress: [███████░░░] 67%

## Performance Metrics

**Velocity:**

- Total plans completed: 16
- Average duration: 19 min
- Total execution time: 0.6 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| Phase 01 | 2/3 | 37 min | 19 min |
| 01 | 3 | - | - |
| 03 | 4 | - | - |
| 06.2 | 9 | - | - |

**Recent Trend:**

- Last 5 plans: P01 (2 min), P02 (35 min)
- Trend: —

*Updated after each plan completion*

| Plan | Duration | Tasks | Files |
|------|----------|-------|-------|
| Phase 01 P01 | 2 min | 3 tasks | 8 files |
| Phase 01 P02 | 35 min | 3 tasks | 2 files |
| Phase 01 P03 | 1 | 3 tasks | 3 files |
| Phase 02 P01 | 9 | 2 tasks | 5 files |
| Phase 02 P03 | 6 min | 3 tasks | 7 files |
| Phase 02 P04 | 4 min | 2 tasks | 2 files |
| Phase 03 P01 | 16 | 3 tasks | 4 files |
| Phase 03 P03 | 2 min | 2 tasks | 2 files |
| Phase 03 P02 | 18 min | 3 tasks | 4 files |
| Phase 04 P01 | 12 | 3 tasks | 9 files |
| Phase 05 P01 | 8 | - tasks | - files |
| Phase 05 P01 | 8 | 3 tasks | 9 files |
| Phase 05 P02 | 6 | 2 tasks | 4 files |
| Phase 05 P03 | 2 | 2 tasks | 4 files |
| Phase 05 P04 | 6 | 2 tasks | 2 files |
| Phase 05 P05 | 3 | 4 tasks | 4 files |
| Phase 05 P06 | 8 | 2 tasks | 2 files |
| Phase 05 P07 | 3 | 3 tasks | 3 files |
| Phase 06 P02 | 7 | 2 tasks | 5 files |
| Phase 06 P03 | 15 | 3 tasks | 5 files |
| Phase 06 P04 | 61 | 3 tasks | 2 files |
| Phase 06 P06-05 | 240 | 2 tasks | 4 files |
| Phase quick-260711-0lh P01 | 8min | 3 tasks | 2 files |
| Phase 06.1 P01 | 3min | 2 tasks | 3 files |
| Phase 06.1 P02 | 3min | 1 tasks | 1 files |
| Phase 06.1 P03 | 4min | 2 tasks | 2 files |

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- Phase 1: Rust/wtransport for WebTransport server — zero GC pauses, only production-ready pure-Rust WebTransport impl
- Phase 1: mkcert for local dev TLS — Caddy cannot proxy WebTransport (issue #5421 unresolved)
- Phase 2: coturn must run with `network_mode: host` — bridge mode silently breaks STUN
- Phase 4: `{ ordered: false, maxRetransmits: 0 }` enforced from first data channel use — browser default is ordered/reliable
- Phase 4: iOS DeviceMotion permission must be in synchronous user gesture handler — gated behind button before any sensor code
- Phase 5: MessagePack (msgpackr) for binary encoding — 3x faster than JSON, ~40 bytes per packet target
- [Phase ?]: resolver=2 in workspace Cargo.toml for 2021 edition feature unification
- [Phase ?]: certs/ gitignored before any cert files exist — T-01-01 private key disclosure mitigation
- [Phase ?]: Cargo.lock committed to repo to pin exact crate versions — T-01-02 supply chain tampering mitigation
- [Phase ?]: #[allow(dead_code)] on echo.rs public items until Plans 02/03 activate them — avoids false warnings on stub modules
- Phase 1 Plan 02: NSS store install (libnss3-tools + mkcert -install) required for Chrome QUIC cert trust on Debian/Ubuntu — webtransport-developer-mode flag alone insufficient without CA in NSS store
- [Phase ?]: lib.rs added to expose ws_server to integration tests — integration tests link against lib crate not binary crate
- [Phase ?]: Test port 18080 for ws_echo integration test — avoids conflicts with running server on port 8080
- [Phase ?]: Phase 1: Plain ws:// only for WebSocket fallback — WSS with TLS deferred to Phase 2 Docker deployment per RESEARCH.md Open Q1
- Phase 2 Plan 01: SignalingBroker::route returns bool; caller (not broker) logs warning for unknown targets per D-05
- Phase 2 Plan 01: hmac::KeyInit trait must be imported alongside Mac to use new_from_slice in hmac 0.13
- Phase 2 Plan 01: TURN credential expiry = now + ttl_seconds (never now alone) — coturn treats username timestamp as expiry not issue time (Pitfall 1)
- [Phase ?]: coturn no ports: block in host mode
- [Phase ?]: static-auth-secret via CLI arg not turnserver.conf (T-02-07)
- [Phase ?]: axum io::Error mapped to anyhow::Error for try_join! unification
- [Phase ?]: userid=anonymous placeholder for Phase 2; Phase 4 supplies real client session ID
- [Phase ?]: Arc<RoomRegistry> only threaded through relay functions — base_url and pairing_secret stored inside registry from Plan 03-01 constructor
- [Phase ?]: Startup log includes base_url but not pairing_token_secret value — T-03-07 mitigation enforced at main.rs level
- [Phase ?]: Phase 4 Plan 01: RoomRegistry.turn_shared_secret added — threaded from main.rs so handle_pair can generate TURN credentials at pair time
- [Phase ?]: Phase 4 Plan 01: nginx try_files $uri $uri.html added — /phone resolves to phone.html without serving index.html (RESEARCH Pitfall 6)
- [Phase ?]: Phase 4 Plan 01: listenForServerPushes started before register/pair — incomingBidirectionalStreams must be consumed immediately after transport.ready (RESEARCH Pitfall 2)
- [Phase ?]: Phase 5 Plan 01: Vite 8.1.4 as bundler (D-01) to unlock npm ecosystem for ahrs, float16, future Three.js
- [Phase ?]: Phase 5 Plan 01: vite.config.ts single room entry only; phone entry added in Plan 02
- [Phase ?]: Phase 5 Plan 02: export {} added to phone.ts and room.ts — makes them ES modules, prevents global-scope collision when multiple TS files lack imports
- [Phase ?]: Phase 5 Plan 02: e.acceleration (standard spec) replaces non-standard e.linearAcceleration — identical behavior, strict DOM type compliance
- Phase 5 Plan 03: DataView + @petamoriken/float16 setFloat16 used for packet encoding — NOT msgpackr (no float16 type in MessagePack, Pitfall 4)
- Phase 5 Plan 03: _packetBuf allocated once at module scope — callers must .slice() before WebRTC send (Pitfall 5 no per-tick GC)
- Phase 5 Plan 03: computeCalibration is pure function; runCalibration is thin devicemotion wrapper — calibration math stays unit-testable in jsdom (D-08)
- Phase 5 Plan 05: ZUPTDetector NaN guard skips push but still evicts stale entries — bounded window preserved on bad samples (T-05-01)
- Phase 5 Plan 05: Kalman1D resetVelocity uses Kalman gain K=P/(P+R) to shrink P proportionally — not a hard reset to zero
- Phase 5 Plan 05: driftConfidence=max(0,1-min(1,P)) naturally in [0,1] without explicit clamping branches
- [Phase ?]: Phase 5 Plan 06: cast encodePacket return to Uint8Array<ArrayBuffer> for RTCDataChannel.send TS 5.6+ compatibility
- [Phase ?]: Phase 5 Plan 06: requestWakeLock + startHeartbeat moved to runCalibration callback — fire when active view shows, not before calibration
- [Phase ?]: Phase 5 Plan 07: POSITION_MAX=100m bounds Kalman drift
- [Phase ?]: Phase 5 Plan 07: attachTouchListeners idempotent behind touchListenersAttached + named handlers — no listener leak on session reconnect (T-05-17)
- [Phase ?]: .planning/phases/06-desktop-receive-decode-and-rendering/06-01-SUMMARY.md
- [Phase ?]: .planning/phases/06-desktop-receive-decode-and-rendering/06-01-SUMMARY.md
- Phase 6 Plan 02: decode.ts imports SCHEMA_VERSION + BUF_SIZE from ./encode — single source of truth for byte offsets (never redefines)
- Phase 6 Plan 02: RFC 1982 half-distance isNewerSeq — diff = (newSeq - lastSeq) & 0xFFFF; accept if diff > 0 && diff <= 32767 (handles 65535→0 wraparound)
- Phase 6 Plan 02: PlayerState stores plain JS numbers, no THREE types — decouples store from WebGL context for jsdom-testable unit testing
- [Phase ?]: Phase 6 Plan 04: THREE.Quaternion.set(x,y,z,w) — w is scalar; pass (qx,qy,qz,qw) not (qw,qx,qy,qz)
- [Phase ?]: Phase 6 Plan 04: console.log (not console.debug) for decode drop messages — Chrome filters debug at Info level
- [Phase ?]: Phase 6 Plan 04: Namespace imports (import * as decode) to keep grep counts at exactly 1 per function name in room.ts
- [Phase ?]: leaveRoom async+await: sendWtMessage must complete before transport.close() — sync try/catch cannot catch async rejections
- [Phase ?]: view-lobby hidden=true by default: module scripts deferred, lobby must be hidden before first paint to prevent FOUC on /room/ reload
- [Phase ?]: sensorPipelineRunning flag in phone.ts: server replays player-ready on every desktop reconnect; phone must skip recalibration when already active
- [Phase ?]: Per-frame emissive touch flash: live state.touchActive check in updateScene rAF loop — no setTimeout, no timers, no race conditions
- [Phase ?]: Fixed rotateDeviceToWorld to apply primaryQuat directly (not conjugate) - matches scene.ts device-to-world convention, resolving huge position drift
- [Phase ?]: Phase 06.1 Plan 01: WebXrPoseTracker.ingest() takes an optional nowMs param (default performance.now()) beyond the plan's literal 2-arg signature, for deterministic unit testing
- [Phase ?]: Phase 06.1 Plan 01: Hand-written ambient client/src/webxr.d.ts (no @types/webxr dependency) per RESEARCH Open Q1 option (a)
- [Phase ?]: Phase 06.1 Plan 02: encode.test.ts byte-identical comparison uses two separate ArrayBuffer instances, not the shared _packetBuf, to avoid overwrite-before-compare
- [Phase 06.1]: Phase 06.1 Plan 03: isStill declared as a mutable let outside the branch so the existing dev-overlay call site stays untouched across both position-source branches
- [Phase 06.1]: Phase 06.1 Plan 03: wa/mag pre-branch computation left unconditional (only fallback branch consumes them) to avoid restructuring code the plan required to remain untouched

### Pending Todos

None yet.

### Blockers/Concerns

- Phase 06.1 OPEN: Plan 06.1-04 (on-device WebXR/ARCore verification — badge, drift resolution SENS-V2-03, freeze-on-loss D-06, battery/thermal, iOS fallback D-04) deferred at user's request — no ARCore-capable Android device available. No SUMMARY.md was written for 06.1-04 so it stays "incomplete"; re-run `/gsd-execute-phase 06.1` or `/gsd-verify-work 06.1` once hardware is available to re-surface the checkpoint. Phase is NOT marked complete in ROADMAP.md.
- Phase 1 Plan 02 RESOLVED: WebTransport TLS cert requirements — Chrome echo round-trip verified; NSS store install required on Debian/Ubuntu
- Phase 2 critical: TURN credential endpoint must generate at connection-start (not page load) to prevent staleness
- Phase 5: Madgwick beta empirical tuning (0.1 default, ramp 0.2–0.3 at cold start) requires real-device validation
- Phase 5: ZUPT adaptive threshold values require empirical tuning — plan device testing session

### Quick Tasks Completed

| # | Description | Date | Commit | Directory |
|---|-------------|------|--------|-----------|
| 260707-f1x | Fix cert permissions for cold start | 2026-07-07 | 880ea1b | [260707-f1x-fix-cert-permissions-for-cold-start](./quick/260707-f1x-fix-cert-permissions-for-cold-start/) |
| 260710-fix-phone-disconnect-on-leave | Phone transitions to view-connecting when desktop leaves room | 2026-07-10 | 268bf50 | [260710-fix-phone-disconnect-on-leave](./quick/260710-fix-phone-disconnect-on-leave/) |
| 260710-w83 | Fix inverted position axes: negate all three components in both position paths | 2026-07-10 | b38e0e5 | [260710-w83-fix-inverted-position-axes-negate-all-th](./quick/260710-w83-fix-inverted-position-axes-negate-all-th/) |
| 260710-wb4 | Prevent screen rotation: CSS landscape overlay + orientation lock in user gesture | 2026-07-10 | 00eb30d | [260710-wb4-add-landscape-lock-overlay-to-phone-html](./quick/260710-wb4-add-landscape-lock-overlay-to-phone-html/) |
| 260710-whi | Four phone UX fixes: landscape CSS rotation, fullscreen, peer-left reason, view-ended on leave | 2026-07-10 | 8022055 | [260710-whi-four-phone-ux-fixes-css-90deg-landscape-](./quick/260710-whi-four-phone-ux-fixes-css-90deg-landscape-/) |
| 260710-wt-race-and-fullscreen-hint | WT close race fix + fullscreen button → rotation hint | 2026-07-10 | 3e26c64 | [260710-wt-race-and-fullscreen-hint](./quick/260710-wt-race-and-fullscreen-hint/) |
| 260711-0lh | Fix huge position drift (REVERTED — broke on-device control, see 3703a0c; root cause still open, moved to /gsd-debug) | 2026-07-11 | 3703a0c | [260711-0lh-fix-huge-position-drift-making-phone-mot](./quick/260711-0lh-fix-huge-position-drift-making-phone-mot/) |

### Roadmap Evolution

- Phase 06.1 inserted after Phase 6: Camera-Assisted Spatial Tracking — WebXR/ARCore (Android) + iOS VIO library research, replacing unfixable IMU-only dead-reckoning (URGENT)
- Phase 06.2 inserted after Phase 6: iOS Native Client (ARKit) — native Swift companion app replacing browser phone client for iOS, invoking the native-companion-app escape hatch Phase 06.1 anticipated (Safari has no WebXR immersive-ar) (URGENT)
- Phase 06.2 edited: narrowed scope to native transport parity (WebTransport/WebRTC/pairing/CoreMotion orientation); ARKit tracking split out to new Phase 06.3
- Phase 06.3 inserted after Phase 06.2: ARKit ARSession world tracking + go/no-go verification checkpoint, split out from original 06.2 scope (URGENT)

## Deferred Items

| Category | Item | Status | Deferred At |
|----------|------|--------|-------------|
| *(none)* | | | |

## Session Continuity

Last session: 2026-07-12T18:35:42.845Z
Stopped at: Phase 06.3 context gathered
Resume file: .planning/phases/06.3-ios-native-client-arkit-world-tracking/06.3-CONTEXT.md
