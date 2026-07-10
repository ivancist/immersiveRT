---
phase: 05-sensor-fusion-and-packet-encoding
plan: "01"
subsystem: client-build
status: complete
tags: [vite, typescript, sensor-types, room-migration, build-tooling]
dependency_graph:
  requires: []
  provides:
    - client/package.json (npm manifest with dev/build/test/typecheck scripts)
    - client/tsconfig.json (strict TypeScript configuration)
    - client/vite.config.ts (Vite MPA config, single room entry for now)
    - client/src/types.ts (SensorPacket schema v1, Quaternion, Vector3, TouchState)
    - client/src/room.ts (TypeScript migration of room.js, behavior-preserving)
    - client/public/phone.html + phone.js (verbatim bridge via Vite publicDir)
  affects:
    - client/index.html (updated script tag to ./src/room.ts module)
tech_stack:
  added:
    - vite@8.1.4 (bundler, dev server, vitest integration)
    - typescript@^5.0.0 (strict mode, ES2020, bundler moduleResolution)
    - vitest@^3.0.0 (test runner, jsdom environment)
    - ahrs@1.3.3 (Madgwick/Mahony filters — approved via blocking-human gate)
    - "@petamoriken/float16@3.9.3" (float16 encode/decode for sensor packets)
  patterns:
    - Vite MPA with rollupOptions.input (single entry, expanded in Plan 02)
    - TypeScript strict mode with ambient CDN global declarations
    - Vite publicDir for verbatim static file pass-through
key_files:
  created:
    - client/package.json
    - client/tsconfig.json
    - client/vite.config.ts
    - client/.gitignore
    - client/src/types.ts
    - client/src/room.ts
    - client/public/phone.html (moved from dist/)
    - client/public/phone.js (moved from dist/)
  modified:
    - client/index.html (moved from dist/; script tag updated to module)
  deleted:
    - client/dist/room.js (replaced by client/src/room.ts)
decisions:
  - "Vite 8.1.4 as bundler (D-01) — unlocks npm ecosystem for ahrs, float16, future Three.js"
  - "Single room entry in vite.config.ts for Plan 01; phone entry added in Plan 02 when phone.ts is ready"
  - "QRCode CDN global typed via ambient declaration in room.ts — no npm package needed for a pure CDN dependency"
  - "client/.gitignore added to exclude dist/ and node_modules/ (Rule 2 deviation)"
metrics:
  duration: "~8 min"
  completed: "2026-07-09"
  tasks: 3
  files: 9
---

# Phase 05 Plan 01: Client Build Scaffold — Summary

**One-liner:** Vite 8.1.4 + TypeScript strict scaffold with ahrs/float16 installed, SensorPacket schema v1 types defined, and room.js migrated to 951-line strict-TypeScript room.ts.

## What Was Built

This plan converted the flat `client/dist/` static file structure into a proper Vite + TypeScript project. The output is:

- A working `npm run build` that emits `dist/index.html` (Vite-bundled room entry), `dist/phone.html` and `dist/phone.js` (verbatim from `public/` via Vite's publicDir), and `dist/assets/room-*.js`
- The shared `SensorPacket` type contract (`src/types.ts`) that all Phase 5 sensor modules will import
- A strict-TypeScript desktop SPA (`src/room.ts`) with zero behavior changes from `room.js`

## Tasks Completed

| Task | Description | Commit | Status |
|------|-------------|--------|--------|
| 1 | Approve ahrs package (blocking-human gate) | — | Approved by user |
| 2 | Create Vite/TS scaffold, install deps, bridge phone page | 39a9bc8 | Done |
| 3 | Define shared sensor types, migrate room.js to room.ts | f9c8c4f | Done |

## Verification Results

```
OK-SCAFFOLD   — npm install, node_modules present, public/phone.* present, index.html patched
OK-TYPES-ROOM — tsc --noEmit 0 errors, npm run build OK, all dist/ artifacts present
```

- `tsc --noEmit`: **0 errors** (strict mode, ES2020, bundler moduleResolution)
- `npm run build`: **vite v8.1.4, 5 modules, 29ms** — emits index.html + room-*.js + phone.html + phone.js
- `node_modules/ahrs`, `node_modules/@petamoriken/float16`, `node_modules/vite`, `node_modules/vitest`: all present

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing critical configuration] Added client/.gitignore**
- **Found during:** Post-Task-3 untracked file check
- **Issue:** `client/dist/` (Vite build output) and `client/node_modules/` appeared as untracked after the build ran; without .gitignore they would pollute `git status` and risk accidental staging
- **Fix:** Created `client/.gitignore` with `node_modules/` and `dist/`
- **Files modified:** `client/.gitignore` (new)
- **Commit:** 36b3b88

### Notes on "placeholder" references in room.ts

The `'placeholder'` strings in `client/src/room.ts` (lines 374 and 507: `game_type: 'placeholder'`) are carried forward verbatim from `room.js`. This was the existing game type value sent to the server — not a stub introduced in this plan. No action needed.

## Known Stubs

None — this plan is a build scaffold and type/migration plan only. No sensor data flow wired yet. Sensor pipeline slots (Plans 03–07) will fill the remaining integration points.

## Threat Flags

No new network endpoints, auth paths, or file access patterns introduced. The ahrs package was verified via blocking-human gate (T-05-SC mitigation). The qrcode CDN script SRI integrity attribute was preserved in index.html.

## Self-Check: PASSED

Files exist:
- client/package.json: FOUND
- client/tsconfig.json: FOUND
- client/vite.config.ts: FOUND
- client/src/types.ts: FOUND
- client/src/room.ts: FOUND
- client/public/phone.html: FOUND
- client/public/phone.js: FOUND

Commits exist:
- 39a9bc8: feat(05-01): create Vite/TypeScript scaffold and bridge phone page
- f9c8c4f: feat(05-01): define shared sensor types and migrate room.js to strict TypeScript
- 36b3b88: chore(05-01): gitignore client/dist and node_modules
