# Phase 5: Sensor Fusion and Packet Encoding - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-07-09
**Phase:** 05-sensor-fusion-and-packet-encoding
**Areas discussed:** Library delivery, Orientation pipeline, Packet schema, Tuning exposure

---

## Library delivery

| Option | Description | Selected |
|--------|-------------|----------|
| Add Vite build step | client/ gets package.json + vite.config.ts. Unlocks npm ecosystem. | ✓ |
| CDN UMD builds via script tags | External network dependency, fragile version pinning. | |
| Hand-roll both inline in phone.js | Madgwick ~100 lines, MessagePack ~50 lines. Zero deps but no future npm access. | |

**User's choice:** Add Vite build step

| Option | Description | Selected |
|--------|-------------|----------|
| Build both phone.js and room.js | Single pipeline, TypeScript + npm for all client code. | ✓ |
| Build phone.js only | Minimal change, room.js migrated separately. | |

**User's choice:** Build both

| Option | Description | Selected |
|--------|-------------|----------|
| TS now for phone + room | One migration, sensor types defined once, Phase 7 SDK inherits. | ✓ |
| JS in Phase 5, TS in Phase 7 | Keep Phase 5 scope tight, second migration later. | |

**User's choice:** TypeScript now

---

## Orientation pipeline

**User clarification:** User asked what DeviceOrientationEvent vs DeviceMotionEvent means and why not use raw data with filters. Explained: DeviceOrientationEvent = OS-fused (already Kalman'd by phone OS); DeviceMotionEvent = raw IMU. Madgwick on top of OS-fused data = worse output. CLAUDE.md says use OS directly.

**User decision:** Run both pipelines in parallel to evaluate quality on real devices. Dev overlay shows both quaternions live.

| Option | Description | Selected |
|--------|-------------|----------|
| Dev overlay shows both quaternions live | Phone screen shows OS vs Madgwick side-by-side. | ✓ |
| Log both to console + data channel | More quantitative but requires desktop session. | |
| You decide | Leave to Claude. | |

| Option | Description | Selected |
|--------|-------------|----------|
| OS-fused by default; URL param to switch | ?orient=madgwick switches to Madgwick. | ✓ |
| Madgwick default | Exercises full custom pipeline. | |
| You decide | Leave to Claude. | |

**Filter selection clarification:** User said "fast but also most reliable." Locked Madgwick over Mahony — better magnetometer fusion, more reliable absolute heading. Mahony 10–15% faster but drifts more on yaw.

| Option | Description | Selected |
|--------|-------------|----------|
| Mahony first (faster) | 10-15% CPU savings, slightly worse yaw. | |
| Madgwick (reliable) | Better magnetometer fusion, reliable absolute heading. | ✓ |

**Notes:** URL params are dev-mode only (import.meta.env.DEV). Production build strips them — no cheating risk.

---

## Packet schema

| Option | Description | Selected |
|--------|-------------|----------|
| Array format (positional) | No field names on wire. Smallest payload. | ✓ |
| Object format (named fields) | Self-describing, 15-20 bytes larger per packet. | |

| Option | Description | Selected |
|--------|-------------|----------|
| float32 for all fields | Standard, simple. | |
| float16 for quaternion+position, float32 for drift | Saves ~14 bytes. Needs bit-math encode/decode. | ✓ |

**Touch clarification:** User asked about long touches and swipes with precision, and said "better to track every motion in realtime." Decision: stream raw (x, y) coordinates every 60Hz packet. Desktop derives swipe, long-press, velocity from coordinate stream. No gesture detection on phone.

**User clarification on future expansion:** User asked "is it easy to add touch points in future?" Answer: yes, schema version byte makes expansion non-breaking.

| Option | Description | Selected |
|--------|-------------|----------|
| 1 touch point (Phase 5) | 5 bytes. Expandable via schema version bump. | ✓ |
| 2 touch points | 10 bytes. | |
| Up to 5 touch points | 25 bytes, exceeds 45-byte target. | |

| Option | Description | Selected |
|--------|-------------|----------|
| uint8 version as first byte | Version 1. Phase 6 derives field layout from version. | ✓ |
| Infer from packet length | Fragile — breaks if future field is same size. | |

---

## Tuning exposure

**ZUPT clarification:** User asked "ZUPT add latency? Or only reset velocity after a certain time?" Confirmed: ZUPT fires only after 300ms stillness detected. No impact on live 60Hz packet stream. Background correction only — resets velocity during natural movement pauses.

**Cheating concern:** User correctly identified that URL params for filter tuning in production = players could cheat by adjusting filter behavior. Solution: dev-mode only via import.meta.env.DEV.

**Calibration idea:** User proposed guided calibration scene ("a scene that says to the user how to move the phone"). Agreed: hold-still step at session start auto-tunes ZUPT threshold and Kalman noise params for that device's specific sensor characteristics.

| Option | Description | Selected |
|--------|-------------|----------|
| Dev-only tuning + hold-still calibration | URL params dev-mode only. Hold-still scene at session start. | ✓ |
| Hard-code defaults only | No runtime override at all. | |

| Option | Description | Selected |
|--------|-------------|----------|
| Phase 5: basic calibration (hold-still only) | 3-second countdown, auto-tunes ZUPT + Kalman. | ✓ |
| Phase 5: full guided calibration | Hold + rotate + flick. Larger scope. | |
| Deferred entirely | Hardcoded defaults in Phase 5. | |

| Option | Description | Selected |
|--------|-------------|----------|
| Simple instruction + countdown timer | "Hold still on flat surface" + 3s bar. Auto-advances. | ✓ |
| Live sensor noise visualization | Graph showing variance drop. Scope creep risk. | |

---

## Claude's Discretion

- Float16 encode/decode bit-manipulation implementation
- Madgwick beta ramp at cold start (0.2–0.3 → 0.1 after convergence)
- Kalman filter process/measurement noise default values
- Gesture displacement window gating implementation (SENS-05)
- msgpackr record extension usage (optional compression)

## Deferred Ideas

- Full guided calibration (rotate + flick steps) — Phase 8 or SDK
- 2+ touch points — future schema version bump when game needs it
- Mahony filter option — re-evaluate if CPU bottleneck on low-end Android
- Touch UI on phone (virtual buttons, D-pad) — out of platform scope
