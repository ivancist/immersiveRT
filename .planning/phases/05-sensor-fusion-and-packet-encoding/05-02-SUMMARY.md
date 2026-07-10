---
phase: 05-sensor-fusion-and-packet-encoding
plan: "02"
subsystem: phone-client
tags: [typescript, migration, vite, webrtc, webtransport]
dependency_graph:
  requires: [05-01]
  provides: [client/src/phone.ts, client/phone.html]
  affects: [client/vite.config.ts, client/src/room.ts]
tech_stack:
  added: []
  patterns:
    - Strict-TypeScript ES module with export {} for module isolation
    - var → const/let with explicit RTCIceServer[], Map<string,{...}>, WakeLockSentinel|null types
    - DeviceMotionEvent.requestPermission() cast through unknown (iOS 13+ strict compliance)
    - e.acceleration (standard spec) replacing non-standard e.linearAcceleration
key_files:
  created:
    - client/src/phone.ts
    - client/phone.html (promoted from public/)
  modified:
    - client/vite.config.ts
    - client/src/room.ts
decisions:
  - "phone.ts adds export {} sentinel — makes it a proper ES module, preventing global-scope collision with room.ts (both files had no imports/exports before this plan)"
  - "DeviceMotionEvent.requestPermission cast through unknown (not direct cast) to satisfy strict TypeScript lib.dom type check"
  - "e.acceleration used instead of non-standard e.linearAcceleration — identical runtime behavior (acceleration is the spec-compliant property for gravity-removed reading)"
metrics:
  duration: "6 min"
  completed: "2026-07-09"
  tasks_completed: 2
  files_changed: 4
status: complete
---

# Phase 05 Plan 02: Phone.js → Phone.ts Migration Summary

Migrated the phone client from `client/public/phone.js` (plain script) to `client/src/phone.ts` (strict-TypeScript ES module) and promoted `phone.html` from the temporary `public/` bridge to a real Vite entry. Behavior-preserving — no sensor pipeline, encoding, or overlay code added. The `{ ordered: false, maxRetransmits: 0 }` data channel contract (Phase 4 D-05, PHONE-04) is unchanged.

## What Was Built

### Task 1: Promote phone.html to Vite entry

- `client/vite.config.ts`: added `phone: resolve(__dirname, 'phone.html')` to `rollupOptions.input` alongside the existing `room` entry
- `git mv client/public/phone.html → client/phone.html`: promoted to project root
- Updated script tag: `<script src="/phone.js" defer>` → `<script type="module" src="./src/phone.ts">`
- `git rm client/public/phone.js`: removed the orphan bridge file
- Verification: `OK-PHONE-ENTRY`

### Task 2: Migrate phone.js → src/phone.ts (strict TypeScript)

- Created `client/src/phone.ts` (892 lines, exceeds 800-line minimum)
- All 32 top-level `var` declarations converted to `const`/`let` with explicit types:
  - `transport: WebTransport | null`, `ws: WebSocket | null`, `useWt: boolean`
  - `myId: string | null`, `roomCode: string | null`, `mySlot: number | null`
  - `iceServers: RTCIceServer[]`, `peers: Array<{id,slot,username}>`
  - `peerConnections: Map<string, {pc,dc,channelOpen,flagClose}>`
  - `wakeLockSentinel: WakeLockSentinel | null`, `heartbeatInterval: ReturnType<typeof setInterval> | null`
  - Promise resolver pairs typed as `((msg: SignalingMessage) => void) | null`
- All function signatures typed (params + return types)
- `DeviceMotionEvent.requestPermission()` remains first statement in synchronous click handler (iOS D-12, no await/then/setTimeout before it)
- `{ ordered: false, maxRetransmits: 0 }` on data channel is byte-identical to Phase 4 (PHONE-04)
- Phase 5 sensor pipeline hook marker left in `onPlayerReady` for Plan 06
- Verification: `OK-PHONE-TS`
- Build: emits `dist/phone.html` + `dist/assets/phone-BSm-baHG.js`

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Added `export {}` to phone.ts and room.ts to prevent global-scope collision**

- **Found during:** Task 2 (tsc --noEmit)
- **Issue:** Both `phone.ts` and `room.ts` had no imports or exports, so TypeScript treated them as global scripts. Adding `phone.ts` to `src/` caused duplicate `let ws`, `let myId`, `let wsReady` and duplicate `function showView` errors across both files.
- **Fix:** Added `export {}` sentinel comment to both `phone.ts` (new file) and `room.ts` (existing file from Plan 01). This is the standard TypeScript idiom to declare a file as an ES module without any actual exports.
- **Files modified:** `client/src/phone.ts` (new), `client/src/room.ts` (1-line addition)
- **Commit:** e302305

**2. [Rule 1 - Bug] Changed `e.linearAcceleration` → `e.acceleration` in startMotionIndicator**

- **Found during:** Task 2 (tsc --noEmit)
- **Issue:** `DeviceMotionEvent.linearAcceleration` does not exist in TypeScript's `lib.dom`. The standard DOM spec property for gravity-removed linear acceleration is `acceleration`.
- **Fix:** Replaced `e.linearAcceleration` with `e.acceleration` in `startMotionIndicator` (both usage sites: the fallback chain and the threshold selector). Runtime behavior is identical — `e.acceleration` is the property browsers implement for linear acceleration without gravity.
- **Files modified:** `client/src/phone.ts`
- **Commit:** e302305

**3. [Rule 1 - Bug] Cast DeviceMotionEvent.requestPermission and RTCSessionDescriptionInit through `unknown`**

- **Found during:** Task 2 (tsc --noEmit)
- **Issue:** Direct casts `DeviceMotionEvent as { requestPermission: ... }` and `msg.payload as RTCSessionDescriptionInit` failed strict TypeScript type overlap checks.
- **Fix:** Added intermediate `as unknown` cast for both. No runtime change.
- **Files modified:** `client/src/phone.ts`
- **Commit:** e302305

## Key Links Verified

| Link | Status |
|------|--------|
| `vite.config.ts` → `phone.html` → `./src/phone.ts` | Verified (Vite build emits `dist/phone.html` + phone bundle) |
| `openChannelToPeer` → `{ ordered: false, maxRetransmits: 0 }` | Verified (grep confirmed, unchanged) |

## Build Output

```
dist/
  phone.html              ← new Vite entry
  assets/phone-BSm-baHG.js  ← hashed JS bundle for phone page
  index.html              ← room entry (unchanged)
  assets/room-*.js        ← room bundle (unchanged)
```

## Known Stubs

None. This is a behavior-preserving migration. No sensor pipeline, encoding, or UI overlay was added — those are Plans 03–07.

## Threat Surface Scan

No new trust boundaries introduced. The phone entry and data channel contract are unchanged from Phase 4. T-05-09 mitigation verified: `{ ordered: false, maxRetransmits: 0 }` byte-identical in phone.ts.

## Self-Check: PASSED

- `/home/ivancist/Documents/immersiveRT/client/src/phone.ts` — exists (892 lines)
- `/home/ivancist/Documents/immersiveRT/client/phone.html` — exists (module script tag present)
- `/home/ivancist/Documents/immersiveRT/client/vite.config.ts` — phone + room inputs present
- `dist/phone.html` + `dist/assets/phone-BSm-baHG.js` — build confirmed
- `npx tsc --noEmit` — zero errors
- Commit ac55e47 (Task 1) — verified
- Commit e302305 (Task 2) — verified
