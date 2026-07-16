# Phase 7: SDK Public API - Research

**Researched:** 2026-07-16
**Domain:** TypeScript library packaging (Vite library mode + npm workspaces) + WebRTC stats API + typed EventTarget event bus
**Confidence:** MEDIUM-HIGH (core packaging mechanics VERIFIED via direct tool tests against installed packages; WebRTC stats shape VERIFIED against W3C spec + MDN cross-check; general ecosystem best-practice claims are CITED from official docs)

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** The SDK is **headless** — no DOM, no Three.js, no game UI, no room-join/QR-pairing UI. Public surface is `connect()`/`joinRoom()` + `getPlayerInput()`/`getRawInput()` + `platform.on(...)` events only. Each game brings its own Three.js environment and its own rules; each game also builds its own lobby/pairing screen (the existing `client/src/room.ts` markup is a copy-paste reference, not an SDK dependency).
- **D-02 (the one deliberate exception):** `platform.attachLatencyOverlay(container?)` renders a small fixed-position DOM overlay (rolling avg latency, jitter, packet-loss %, ICE state per player) — justified as a developer/debug tool, not game UI. `container` is optional, defaults to `document.body`.
- **D-03:** New npm workspace at `packages/immersive-rt/`, with a new root `package.json` declaring `"workspaces": ["packages/*", "client"]` — mirrors the existing Cargo workspace pattern (root `Cargo.toml` + `server/` member). `client/` becomes a workspace member and depends on `immersive-rt` via the workspace protocol, setting up cleanly for Phase 8's demo game to consume the package.
- **D-04:** Build tooling is **Vite library mode** (`build.lib` entry) — reuses the project's existing Vite 8.1.4 toolchain/config style rather than introducing a new bundler (e.g. tsup).
- **D-05:** Module format is **ESM only** — matches `client/`'s `"type": "module"` and Three.js r185 (itself ESM-only). No CJS dual-build.
- **D-06:** **Full extraction**, not a thin wrapper — the transport layer (WebTransport/WebSocket signaling, WebRTC data channel fan-out), `decode.ts`, `playerStore.ts` (target-state store), and the event bus move into `packages/immersive-rt/src/` as the real source of truth. `client/src/` stops owning this logic and becomes a consumer. `scene.ts`'s Three.js rendering code (mesh, SLERP-on-mesh, grid/axes/trail debug aids) stays behind in `client/` since it's game-specific, not SDK scope.
- **D-07:** The SDK has **zero dependency on the `three` npm package**. Internal SLERP math is a small (~15-line) hand-written function operating on plain `{w,x,y,z}` objects. Public `Quaternion`/`Vector3` types stay the existing plain-object interfaces from `client/src/types.ts`.
- **D-08:** The SDK runs its **own internal tick** (requestAnimationFrame when available, else `setInterval` fallback) started by `connect()`, independent of any consumer's render loop. The tick advances each connected player's smoothed orientation quaternion toward the latest raw packet every tick. `getPlayerInput()` reads the current interpolated value synchronously whenever called — no lazy per-call computation.
- **D-09:** SLERP alpha is **configurable per `connect()` call with a global default** — e.g. `connect({ slerpAlpha: 0.3 })`. Default value carries forward the current `scene.ts` value (0.5). No per-player override.
- **D-10:** Interpolation (SLERP) applies **only to the orientation quaternion**. `gestureDisplacement` and `deadReckoningPosition` pass through as the latest raw packet value, unsmoothed.
- **D-11:** On packet gaps (phone lag/disconnect), the internal tick **holds at the last interpolated value** — no extrapolation, no snapping.
- **D-12:** Event mechanism is **native `EventTarget`** (the `Platform`/SDK root object extends or wraps one internally behind a typed `.on()`/`.off()` facade) — zero dependencies.
- **D-13:** `imuUpdate` payload is `(playerId, data)` where `data` is the **exact same shape** `getPlayerInput()` returns (`{ orientation, gestureDisplacement, deadReckoningPosition, driftConfidence, touch }`).
- **D-14:** `imuUpdate` fires **on every internal interpolation tick** (D-08's rAF-paced cadence), not on every raw packet arrival.
- **D-15:** `playerJoin`/`playerLeave`/`playerReconnect` payload is **just `playerId`** — `cb(playerId)`, no bundled metadata.
- **D-16:** Metrics source is **`RTCPeerConnection.getStats()`** (native WebRTC transport stats: jitter, packetsLost, roundTripTime) combined with the **existing `timestamp` field already present in every `SensorPacket`** (compared against `Date.now()` on receipt) for phone→render latency. **No changes to the wire schema.**
  > **RESEARCH CORRECTION (see Pitfall 1 below):** `getStats()` on a data-channel-only `RTCPeerConnection` does **not** produce `jitter` or `packetsLost` fields — those live exclusively on RTP-stream stats (`RTCReceivedRtpStreamStats`), which require an active audio/video track. This connection has none. The "no wire schema changes" *outcome* D-16 mandates is still fully achievable — `roundTripTime` and ICE state genuinely do come from native WebRTC APIs, and jitter/packet-loss must instead be computed by the SDK from data the wire schema **already carries** (`seq` for loss, packet arrival timing for jitter) — but the literal mechanism ("jitter, packetsLost ... from getStats()") needs correcting in the plan. See Pitfall 1 for the exact implementation.

### Claude's Discretion

- Exact internal SLERP function implementation (~15 lines, standard quaternion SLERP over plain objects).
- Exact `EventTarget` wrapping approach (subclass vs. internal instance + facade methods).
- Whether `scene.ts`'s existing debug/precision-eval Three.js code is deleted from `client/` or repurposed as a dev harness during this phase (Phase 8 owns the real demo game either way).
- Exact internal tick fallback logic (feature-detecting `requestAnimationFrame` vs Node/non-browser environments).
- `getRawInput(playerId).orientationRaw` implementation — the latest raw (non-interpolated) packet quaternion, trivially available since D-08's tick already tracks both raw-latest and smoothed state.

### Deferred Ideas (OUT OF SCOPE)

None — discussion stayed within phase scope. Game-specific concerns (Three.js scene, meshes, gesture-launch visuals, multi-desktop sync) remain out of scope per D-01 and belong to Phase 8.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| SDK-01 | npm package `immersive-rt` published with TypeScript types for all public surfaces | Standard Stack (Vite lib mode + unplugin-dts/vite-plugin-dts), Package Layout section, `package.json` exports/types layout below |
| SDK-02 | `platform.getPlayerInput(playerId)` returns `{ orientation, gestureDisplacement, deadReckoningPosition, driftConfidence, touch }` | Architecture Patterns (internal tick + target-state store extraction), Code Examples |
| SDK-03 | Event API: `platform.on('imuUpdate', ...)`, `playerJoin`, `playerLeave`, `playerReconnect` | Pattern 3 (Typed EventTarget facade), Code Examples |
| SDK-04 | Developer latency overlay: single-line include renders rolling avg latency, jitter, packet loss %, ICE state per player | Pitfall 1 (`getStats()` data-channel-only shape correction), Code Examples (latency/jitter/loss computation) |
| SDK-05 | (Complete, carried forward) `deadReckoningPosition`/`driftConfidence` naming | Already implemented in `client/src/types.ts` — extraction preserves naming verbatim |
| SDK-06 | `platform.getRawInput(playerId).orientationRaw` — unsmoothed quaternion | Architecture Patterns (internal tick tracks raw-latest and smoothed state separately) |
</phase_requirements>

## Summary

This phase is a **structural extraction + packaging** phase, not new algorithm work — the transport, decode, and state-store logic already exists and is battle-tested through Phase 6. The two genuinely new engineering surfaces are: (1) the Vite-library-mode + npm-workspace packaging pipeline (net-new to this repo), and (2) the typed event bus + internal interpolation tick that didn't exist as a public API before.

Three findings from this research materially change what CONTEXT.md assumed and must be corrected in the plan:

1. **npm does not support the `workspace:*` protocol** (that is a pnpm/Yarn-Berry-only feature). Verified by actually running `npm install` against a scratch workspace with `"immersive-rt": "workspace:*"` in a dependent's `package.json` — it fails with `EUNSUPPORTEDPROTOCOL`. The correct npm syntax is a normal semver range (e.g. `"immersive-rt": "^0.1.0"` or `"*"`); npm auto-detects the local workspace member and symlinks it instead of hitting the registry. CONTEXT.md D-03's language ("workspace protocol") must be read as "npm workspace symlinking," not literal `workspace:*` syntax.
2. **`RTCPeerConnection.getStats()` cannot supply `jitter` or `packetsLost` for a data-channel-only connection** — those fields exist only on RTP-stream stats, and a data-channel-only PC has zero RTP streams. `roundTripTime` (via `candidate-pair.currentRoundTripTime`) and ICE state ARE genuinely available. See Pitfall 1 for the corrected, wire-schema-unchanged implementation (jitter/loss computed from the packet's existing `seq`/`timestamp` fields).
3. **`vite-plugin-dts`'s current npm package (5.0.3) is a thin re-export shim of `unplugin-dts`** — confirmed by unpacking the actual published tarball. Its options interface no longer has `rollupTypes` (a name from the old v3/v4 API that tutorials still reference) — the current option is `bundleTypes`. Either `vite-plugin-dts` or `unplugin-dts` works; this research recommends `vite-plugin-dts` for import-path brevity, both are the same underlying code.

**Primary recommendation:** Convert repo root to an npm workspace (`workspaces: ["packages/*", "client"]`) alongside the untouched Cargo workspace, scaffold `packages/immersive-rt/` with Vite `build.lib` (ESM-only, single `es` format) + `vite-plugin-dts` for declaration bundling, extract `room.ts`'s transport logic / `decode.ts` / `playerStore.ts` verbatim into the new package with a thin `Platform` class wrapping a native `EventTarget`, and implement the latency overlay's jitter/packet-loss metrics as SDK-computed values derived from the packet's existing `seq` and `timestamp` fields (not from `getStats()`, which cannot provide them for this connection type).

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| WebTransport/WebSocket signaling client | Browser / Client (SDK) | — | Runs entirely in the desktop browser; no server changes this phase; extracted from `room.ts` into `packages/immersive-rt/src/transport/` |
| WebRTC peer connection + data channel fan-out | Browser / Client (SDK) | — | `RTCPeerConnection` objects live in the SDK; each game's browser tab owns its own connections (no relay tier) |
| Binary packet decode | Browser / Client (SDK) | — | Pure function, `decode.ts`, moves unchanged |
| Per-player target-state store | Browser / Client (SDK) | — | `playerStore.ts`, already dependency-free; moves unchanged |
| Orientation interpolation (SLERP tick) | Browser / Client (SDK) | — | New: SDK's own rAF/interval-driven tick, independent of any consumer's render loop (D-08) |
| Public imperative/event API (`getPlayerInput`, `platform.on(...)`) | Browser / Client (SDK) | — | The SDK's only consumer-facing surface; headless, no DOM except the one exception below |
| Latency/jitter/loss dev overlay | Browser / Client (SDK, DOM exception) | — | D-02's explicit exception — small fixed-position DOM overlay, still SDK-owned, not game UI |
| Three.js scene / mesh / game rules | Browser / Client (Game, NOT SDK) | — | Explicitly out of scope (D-01) — each game (Phase 8's demo) owns this against the SDK's programmatic API |
| Room-join / QR-pairing UI | Browser / Client (Game, NOT SDK) | — | Explicitly out of scope (D-01) — `room.ts`'s markup is a copy-paste reference only |
| Signaling message contract (offer/answer/ice-candidate/join-room/player-ready) | API / Backend (Server, unchanged) | — | `server/src/wt_server.rs` / `ws_server.rs` — this phase's extracted transport layer must continue speaking the exact same message shapes; no server changes |

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| vite | 8.1.5 (client already pins `8.1.4`; `8.1.5` is what's actually installed via `^`/exact-match resolution — confirm exact pin in new `packages/immersive-rt/package.json`) [VERIFIED: `npm view vite version` + installed `client/node_modules/vite/package.json`] | Bundler for library mode (`build.lib`) | Matches D-04; already the project's toolchain; `LibraryOptions` (`entry`/`formats`/`fileName`) verified directly from the installed package's type declarations |
| vite-plugin-dts | `5.0.3` [VERIFIED: `npm view vite-plugin-dts version`] | Generates and bundles `.d.ts` declaration output during the Vite build | Only actively-maintained way to get rolled-up TypeScript declarations out of a Vite library build without a second `tsc --emitDeclarationOnly` pass; peerDependency `vite: >=3` covers the installed `8.1.x` [VERIFIED: `npm view vite-plugin-dts peerDependencies`] |
| typescript | `^5.0.0` (already pinned in `client/package.json` devDependencies; reuse same version in new package) [VERIFIED: `client/package.json`] | Type-checking + `tsc --strict` verification (ROADMAP success criterion 1) | Already the project's language; no reason to introduce a second TS version across workspace members |
| @petamoriken/float16 | `3.9.3` (existing dependency, unchanged) [VERIFIED: `client/package.json`, `npm view @petamoriken/float16 version` confirms `3.9.3+` still current] | Float16 reads inside `decode.ts` | `decode.ts` is extracted byte-for-byte (D-06); this is its only runtime dependency and must move with it into the new package's `dependencies` |
| vitest | `^3.0.0` (reuse client's pinned major; run per-workspace) [VERIFIED: `client/package.json`] | Unit tests for the extracted `decode.ts`/`playerStore.ts`/SLERP/tick logic inside `packages/immersive-rt/` | Matches project's existing test framework; `client/vite.config.ts`'s inline `test: { environment: 'jsdom' }` pattern should be mirrored in the new package's own `vite.config.ts` |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| jsdom | `^29.1.1` (reuse client's pin) [VERIFIED: `client/package.json`] | Test environment for the SDK's tests — needed because `attachLatencyOverlay()` (D-02) touches the DOM | Only if the package's `vite.config.ts` `test.environment` is set to `jsdom`; confirmed via a local test that jsdom 29 does **not** implement `requestAnimationFrame` [VERIFIED: local `jsdom` instantiation test — `typeof dom.window.requestAnimationFrame === 'undefined'`] — this makes the D-08 `setInterval` fallback path *mandatory* for the SDK's own unit tests, not just a defensive nicety for exotic runtimes. See Pitfall 2. |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| vite-plugin-dts | unplugin-dts (`^1.0.3`, import from `unplugin-dts/vite`) | Same underlying code — `vite-plugin-dts@5.0.3`'s published package literally re-exports from `unplugin-dts` [VERIFIED: `unpkg.com/vite-plugin-dts@5.0.3/README.md` — `export { PluginOptions, editSourceMapDir } from 'unplugin-dts';`]. `unplugin-dts` is the actively-promoted name going forward, but has fewer weekly downloads (619K vs 3.59M) simply because it's newer as a published name under that identifier. Either works identically; this research picks `vite-plugin-dts` for the shorter, more Vite-idiomatic import. |
| npm workspaces | pnpm workspaces | pnpm natively supports `workspace:*` protocol and stricter dependency isolation, but introduces a second package manager into a repo that has no existing pnpm usage; npm ships with Node and matches `client/package.json`'s existing lockfile ecosystem — no reason to add pnpm for this phase |
| Hand-rolled typed EventTarget facade | `typescript-event-target` npm package (`1.1.2`) [VERIFIED: `npm view typescript-event-target version`] | D-12 explicitly mandates zero dependencies for the event mechanism ("built into every modern JS runtime") — a ~20-line hand-rolled generic wrapper (Pattern 3 below) achieves the same type safety without adding a dependency |
| getStats()-only latency overlay | Custom wire-level jitter/loss tracking fields | D-16 (as corrected by Pitfall 1) explicitly avoids touching the wire schema — jitter/loss are computed application-side from the packet's *existing* `seq`/`timestamp` fields, satisfying both "no wire changes" and "accurate metrics" |

**Installation:**
```bash
# At repo root, after creating root package.json + packages/immersive-rt/package.json
npm install -w packages/immersive-rt vite-plugin-dts --save-dev
npm install -w packages/immersive-rt @petamoriken/float16
npm install -w client immersive-rt   # symlinks the local workspace member — see Pitfall 3
```

**Version verification:** All versions above were checked via `npm view <pkg> version` against the live registry on 2026-07-16, and cross-checked against the actually-installed `client/node_modules` where applicable (Vite, TypeScript, jsdom, vitest, `@petamoriken/float16`).

## Package Legitimacy Audit

| Package | Registry | Age | Downloads | Source Repo | Verdict | Disposition |
|---------|----------|-----|-----------|-------------|---------|-------------|
| vite-plugin-dts | npm | Package created 2021-06-01 (5 yrs); latest version published 2026-06-24 | 3.59M/wk | github.com/qmhc/unplugin-dts (monorepo, `packages/vite-plugin-dts` dir) | SUS (`too-new` — reflects a recent *version* publish, not package age; package itself is long-established with a very high download count and a canonical, non-typosquat repo) | **Flagged** — planner must add a `checkpoint:human-verify` task before install, per protocol, even though the underlying signals (age, downloads, repo) all support legitimacy |
| unplugin-dts | npm | Same repo/lineage as `vite-plugin-dts` (this is its new canonical name); latest version published 2026-06-24 | 619K/wk | github.com/qmhc/unplugin-dts | SUS (`too-new`, same reason as above) | Flagged as an **alternative** to `vite-plugin-dts` — same disposition, not both are needed |
| @petamoriken/float16 | npm | Latest version published 2025-10-10 | 1.81M/wk | github.com/petamoriken/float16 | OK | Approved — already an existing, vetted project dependency (Phase 5); carries over into `packages/immersive-rt/package.json` unchanged |

**Packages removed due to `[SLOP]` verdict:** none.
**Packages flagged as suspicious `[SUS]`:** `vite-plugin-dts` (or `unplugin-dts` if chosen instead) — flagged purely on "latest version too new" heuristic; both packages' age/downloads/repo signals independently support legitimacy. The planner should still insert a `checkpoint:human-verify` task immediately before the `npm install ... vite-plugin-dts --save-dev` step per protocol.

*No packages in this research were sourced from WebSearch/training-data-only discovery without a subsequent `npm view` / tarball-unpack confirmation — the versions and APIs documented above were all directly verified against the installed or downloaded package artifacts, not assumed from memory.*

## Architecture Patterns

### System Architecture Diagram

```
┌─────────────────────────── packages/immersive-rt (new SDK) ───────────────────────────┐
│                                                                                          │
│  connect() / joinRoom()                                                                 │
│        │                                                                                │
│        ▼                                                                                │
│  ┌───────────────────┐   ondatachannel   ┌──────────────┐   decode + guard   ┌────────┐│
│  │ Transport layer     │ ───────────────▶ │ decode.ts     │ ─────────────────▶│ player ││
│  │ (WT/WS signaling +  │                  │ (unchanged)   │                   │ Store  ││
│  │ RTCPeerConnection    │                  └──────────────┘                   └───┬────┘│
│  │ per phone, extracted │                                                          │     │
│  │ from room.ts)        │  onicecandidate / onconnectionstatechange (live props)  │     │
│  └──────────┬───────────┘ ─────────────────────────────────┐                      │     │
│             │                                               ▼                      │     │
│             │                                     ┌───────────────────┐            │     │
│             │  getStats() per RTCPeerConnection    │ Latency overlay    │           │     │
│             │  (candidate-pair.currentRoundTripTime,│ (D-02 DOM         │           │     │
│             │   ICE state — NOT jitter/packetsLost) │ exception)        │◀──────────┘     │
│             └───────────────────────────────────────▶ jitter/loss       │  seq/timestamp  │
│                                                       computed from      │  from playerStore│
│                                                       packet seq/ts      │                 │
│                                                       └───────────────────┘                │
│                                                                                             │
│  Internal tick (rAF, fallback setInterval) — D-08 ◀── started by connect() ──┐              │
│        │                                                                     │              │
│        ▼ every tick: SLERP orientation toward playerStore's latest raw qtn   │              │
│  ┌────────────────────┐        dispatchEvent(imuUpdate)         ┌────────────┴───────────┐ │
│  │ Platform (EventTarget│ ──────────────────────────────────────▶│ platform.on('imuUpdate',│ │
│  │  facade) — public API│                                        │   'playerJoin', ...)    │ │
│  │  getPlayerInput()     │◀────────── synchronous read ──────────│  (consuming game code)  │ │
│  │  getRawInput()         │                                       └─────────────────────────┘ │
│  └────────────────────┘                                                                     │
└──────────────────────────────────────────────────────────────────────────────────────────┘
                                          ▲
                                          │ npm workspace symlink (client/node_modules/immersive-rt → packages/immersive-rt)
                                          │
                          ┌───────────────┴────────────────┐
                          │ client/ (existing app, now a    │
                          │ workspace member + SDK consumer)│
                          │ scene.ts keeps its OWN axis      │
                          │ remap + THREE.Quaternion SLERP   │
                          └──────────────────────────────────┘
```

### Recommended Project Structure

```
/ (repo root)
├── package.json              # NEW — "workspaces": ["packages/*", "client"]
├── Cargo.toml                 # UNCHANGED — "[workspace] members = [\"server\"]"
├── .gitignore                 # add root-level node_modules/ (see Pitfall 3)
├── packages/
│   └── immersive-rt/
│       ├── package.json       # name, type:module, exports/types, dependencies
│       ├── vite.config.ts     # build.lib (D-04), vite-plugin-dts, test.environment
│       ├── tsconfig.json      # mirrors client/tsconfig.json (strict, ES2020, DOM libs)
│       ├── src/
│       │   ├── index.ts       # public entry — exports Platform, types, connect()
│       │   ├── platform.ts    # Platform class (EventTarget facade — Pattern 3)
│       │   ├── transport/
│       │   │   └── connection.ts   # extracted from room.ts (WT/WS + RTCPeerConnection fan-out)
│       │   ├── sensor/
│       │   │   └── decode.ts       # moved verbatim from client/src/sensor/decode.ts
│       │   ├── playerStore.ts      # moved verbatim from client/src/playerStore.ts
│       │   ├── tick.ts              # D-08 internal rAF/setInterval loop + SLERP application
│       │   ├── slerp.ts             # ~15-line hand-written plain-object SLERP (D-07)
│       │   ├── latencyOverlay.ts    # D-02 DOM overlay + getStats()-based metrics (Pitfall 1)
│       │   └── types.ts             # moved from client/src/types.ts (Quaternion/Vector3/TouchState/SensorPacket)
│       └── tests/
│           ├── decode.test.ts       # moved from client/tests/
│           ├── slerp.test.ts        # NEW
│           └── tick.test.ts         # NEW — must exercise the setInterval fallback (Pitfall 2)
└── client/
    ├── package.json            # gains "workspaces" membership + "immersive-rt" dependency
    ├── vite.config.ts          # unchanged shape, still multi-entry room/phone.html
    └── src/
        ├── scene.ts             # UNCHANGED responsibility, now imports Platform from 'immersive-rt'
        └── room.ts               # SHRINKS — signaling/decode/store logic removed, UI wiring stays
```

### Pattern 1: Vite library mode for an ESM-only TypeScript package

**What:** `build.lib` with a single `formats: ['es']` entry, `vite-plugin-dts` for bundled declarations, `rollupOptions.external` to avoid bundling the one runtime dependency.
**When to use:** Any time a workspace member should ship as a standalone importable package rather than an app bundle.
**Example:**
```typescript
// packages/immersive-rt/vite.config.ts
// Source: installed node_modules/vite/dist/node/index.d.ts LibraryOptions interface [VERIFIED]
//         + vite-plugin-dts@5.0.3 README (unpkg) [VERIFIED]
import { defineConfig } from 'vite';
import { resolve } from 'path';
import dts from 'vite-plugin-dts';

export default defineConfig({
  root: __dirname,
  plugins: [
    dts({
      // NOTE: the option is `bundleTypes`, NOT `rollupTypes` — `rollupTypes` was the
      // name in vite-plugin-dts v3/v4; the current package (a re-export of unplugin-dts@1.x)
      // renamed it. [VERIFIED: unpacked unplugin-dts@1.0.3 tarball, PluginOptions interface]
      bundleTypes: true,
      tsconfigPath: './tsconfig.json',
    }),
  ],
  build: {
    lib: {
      entry: resolve(__dirname, 'src/index.ts'),
      formats: ['es'],              // ESM-only (D-05) — 'name' is NOT required unless
                                     // formats includes 'umd'/'iife' [VERIFIED: LibraryOptions.name docstring]
      fileName: 'immersive-rt',     // -> dist/immersive-rt.js (package.json has "type":"module",
                                     // so the 'es' format output extension is .js, not .mjs)
    },
    rollupOptions: {
      // Externalize the one runtime dependency — do not bundle it into the SDK.
      // NOTE: build.rollupOptions is DEPRECATED in favor of build.rolldownOptions in
      // this Vite version (Vite 8 ships Rolldown as its bundler); rollupOptions still
      // works as an alias but new code should prefer rolldownOptions.
      // [VERIFIED: node_modules/vite/dist/node/index.d.ts — "@deprecated Use `rolldownOptions` instead."]
      external: ['@petamoriken/float16'],
    },
    outDir: 'dist',
    emptyOutDir: true,
  },
  test: {
    environment: 'jsdom',   // matches client/vite.config.ts's existing test config style
  },
});
```

### Pattern 2: `package.json` layout for an ESM-only, single-format library

**What:** Because `"type": "module"` already declares the whole package as ESM-only, there is **no need** for the `.mjs`/`.d.mts` + `.cjs`/`.d.cts` dual-extension dance that dual-format (ESM+CJS) libraries require — that complexity is specifically a CJS/ESM interop concern this package doesn't have (D-05: ESM only). [CITED: hirok.io/posts/package-json-exports — "types condition should always come first"; "when you add type:module ... you still have to define a main field"]
**When to use:** `packages/immersive-rt/package.json`.
**Example:**
```jsonc
{
  "name": "immersive-rt",
  "version": "0.1.0",
  "private": false,
  "type": "module",
  "main": "./dist/immersive-rt.js",
  "module": "./dist/immersive-rt.js",
  "types": "./dist/immersive-rt.d.ts",
  "exports": {
    ".": {
      "types": "./dist/immersive-rt.d.ts",
      "import": "./dist/immersive-rt.js"
    }
  },
  "files": ["dist"],
  "sideEffects": false,
  "scripts": {
    "build": "vite build",
    "test": "vitest run",
    "typecheck": "tsc --noEmit"
  },
  "dependencies": {
    "@petamoriken/float16": "3.9.3"
  },
  "devDependencies": {
    "typescript": "^5.0.0",
    "vite": "8.1.5",
    "vite-plugin-dts": "5.0.3",
    "vitest": "^3.0.0",
    "jsdom": "^29.1.1"
  }
}
```

### Pattern 3: Typed `EventTarget` facade (zero dependencies — D-12)

**What:** A `Platform` class that composes (or extends) `EventTarget` internally and exposes a typed `.on()`/`.off()` pair, avoiding raw `addEventListener('type', (e: Event) => ...)` call sites that lose payload typing.
**When to use:** The SDK's public event API (`platform.on('imuUpdate', cb)`, `playerJoin`, `playerLeave`, `playerReconnect`).
**Example:**
```typescript
// packages/immersive-rt/src/platform.ts
// Pattern synthesized from common TypeScript+EventTarget approaches
// [CITED: dev.to/marcogrcr/type-safe-eventtarget-subclasses-in-typescript-1nkf;
//  dev.to/43081j/strongly-typed-event-emitters-using-eventtarget-in-typescript-3658]
// — hand-rolled here per D-12 (zero deps), not the third-party libraries those articles use.
import type { Quaternion, Vector3, TouchState } from './types';

interface PlayerInputData {
  orientation: Quaternion;
  gestureDisplacement: Vector3;
  deadReckoningPosition: Vector3;
  driftConfidence: number;
  touch: TouchState;
}

// Event name -> callback argument tuple map (D-13, D-15)
interface PlatformEventMap {
  imuUpdate: [playerId: string, data: PlayerInputData];
  playerJoin: [playerId: string];
  playerLeave: [playerId: string];
  playerReconnect: [playerId: string];
}

export class Platform {
  #target = new EventTarget();
  // WeakMap-per-callback so `.off()` can find the wrapped listener that `.on()` created —
  // native EventTarget.removeListener needs the SAME function reference used in addListener,
  // and here that reference is an internal wrapper, not the user's callback directly.
  #wrapped = new Map<Function, EventListener>();

  on<K extends keyof PlatformEventMap>(
    type: K,
    cb: (...args: PlatformEventMap[K]) => void
  ): void {
    const listener = (evt: Event) => {
      cb(...((evt as CustomEvent<PlatformEventMap[K]>).detail));
    };
    this.#wrapped.set(cb, listener);
    this.#target.addEventListener(type, listener);
  }

  off<K extends keyof PlatformEventMap>(
    type: K,
    cb: (...args: PlatformEventMap[K]) => void
  ): void {
    const listener = this.#wrapped.get(cb);
    if (listener) {
      this.#target.removeEventListener(type, listener);
      this.#wrapped.delete(cb);
    }
  }

  /** Internal-only: fire a typed event to all `.on()` subscribers. */
  protected emit<K extends keyof PlatformEventMap>(
    type: K,
    ...args: PlatformEventMap[K]
  ): void {
    this.#target.dispatchEvent(new CustomEvent(type, { detail: args }));
  }
}
```

### Anti-Patterns to Avoid

- **Bundling `@petamoriken/float16` into the SDK's dist output:** Always externalize runtime dependencies via `rollupOptions.external` and list them in `package.json` `dependencies` — bundling means two copies exist if a consuming game already uses a float16 library, and breaks `sideEffects: false` tree-shaking assumptions.
- **Writing `rollupTypes: true` in the `dts()` plugin options:** This option name doesn't exist in the currently-published `vite-plugin-dts`/`unplugin-dts` — it silently does nothing (TypeScript's structural typing on the options object won't error on an unknown extra key unless `exactOptionalPropertyTypes`-style strictness is configured for the plugin's own types, which it typically isn't for consumer-facing plugin option objects). Use `bundleTypes: true` instead.
- **Assuming `"immersive-rt": "workspace:*"` works with plain npm:** It does not (see Pitfall 3) — use a normal semver range.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| `.d.ts` declaration bundling from a multi-file `src/` tree | A manual `tsc --emitDeclarationOnly` + hand-merge script | `vite-plugin-dts` (`bundleTypes: true`) | API Extractor integration under the hood handles cross-file type re-export correctly; a hand-rolled merge script is exactly the kind of "deceptively complex" problem this protocol exists to flag |
| Typed pub/sub event dispatch | A custom array-of-listeners class | Native `EventTarget` + thin typed facade (Pattern 3) | Zero dependencies, built into every JS runtime including the browser and Node 15+; matches D-12 exactly |
| Packet loss detection | New wire-level ACK/NACK protocol | The packet's **existing** `seq` field (already used for `isNewerSeq` sequence-drop in `decode.ts`) — track expected-vs-received count over a rolling window | The wire schema already carries everything needed (D-16's "no wire changes" mandate); building a new loss-detection protocol would be premature and duplicate an existing signal |

**Key insight:** Everything hand-rolled in this phase (SLERP math, the EventTarget facade, jitter/loss computation) is hand-rolled specifically *because* no zero-dependency, purpose-built library exists for these narrow needs, matching the project's established pattern of preferring small local math over adding npm dependencies (see `client/src/sensor/kalman.ts`, `zupt.ts` from Phase 5).

## Runtime State Inventory

> This phase moves existing, working code (`room.ts`'s transport logic, `decode.ts`, `playerStore.ts`, `types.ts`) into a new package rather than renaming external identifiers, so most Runtime State Inventory categories are not applicable. Documented explicitly per protocol rather than left blank.

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | None — no databases, collections, or keyed stores reference file paths or module names being moved. `playerStore.ts`'s `targetStateStore` is an in-memory `Map`, reset on every page load; nothing persists across the extraction. | None |
| Live service config | None — the server (`server/src/wt_server.rs`/`ws_server.rs`) is untouched this phase; the signaling message contract (`register`/`join-room`/`offer`/`answer`/`ice-candidate`/`player-ready`) is unaffected by where the *client-side* code that speaks it lives. | None |
| OS-registered state | None — no Task Scheduler/launchd/pm2 registrations reference these file paths. | None |
| Secrets/env vars | None — no env vars or secrets reference `client/src/room.ts`, `playerStore.ts`, `decode.ts`, or `types.ts` by path or name. | None |
| Build artifacts | **Real item.** (1) `client/node_modules` currently has `three`/`ahrs`/`@petamoriken/float16` as direct dependencies — after extraction, `@petamoriken/float16` moves to `packages/immersive-rt/package.json` and `client`'s only new dependency is `immersive-rt` itself (workspace-symlinked); `three`/`ahrs` stay in `client` unchanged (SDK has zero dependency on `three` per D-07; `ahrs` is phone-side code not touched by this phase's extraction targets). (2) Converting the repo root to an npm workspace changes the `node_modules` hoisting layout — existing `client/node_modules` should be deleted and reinstalled from the workspace root (`rm -rf client/node_modules && npm install` from repo root) rather than left as a stale pre-workspace install. (3) `client/dist` (Vite build output) is stale the moment `room.ts` changes; no action needed beyond a normal rebuild, but call this out so the plan doesn't assume the old `dist/` is still valid for manual testing. | Code edit (move dependency declarations) + one-time `node_modules` reinstall from repo root after workspace conversion |

## Common Pitfalls

### Pitfall 1: `RTCPeerConnection.getStats()` cannot supply jitter/packetsLost for a data-channel-only connection

**What goes wrong:** A task literally implementing D-16 as written ("use `getStats()` for jitter, packetsLost, roundTripTime") will read `undefined` for jitter and packet loss forever, because those fields only exist on `RTCReceivedRtpStreamStats` (surfaced as `inbound-rtp`/`remote-inbound-rtp` report types), which requires an active RTP media stream. This connection carries only an `RTCDataChannel` — zero audio/video tracks — so those report types never appear in the `RTCStatsReport` map at all.
**Why it happens:** The confusion is reasonable — `getStats()` genuinely is the correct, no-wire-schema-change source for **round trip time** and **ICE connection state**, so it's easy to assume it covers jitter/loss too. It doesn't, for this connection topology.
**How to avoid:** Split the four latency-overlay metrics by actual source:
  - **Latency** (phone→render delta): `Date.now()` at packet receipt minus the packet's existing `timestamp` field. Already the correct approach per D-16 — no change needed.
  - **Round trip time**: `pc.getStats()` → find the `candidate-pair` report with `state === 'succeeded'` (or `nominated === true`) → read `.currentRoundTripTime` (seconds; multiply by 1000 for ms). [VERIFIED: W3C webrtc-stats spec, `RTCIceCandidatePairStats` dictionary]
  - **ICE / connection state**: read `pc.iceConnectionState` or `pc.connectionState` directly as a live property — **no `getStats()` call needed at all**; `room.ts` already wires `pc.onconnectionstatechange`/`pc.oniceconnectionstatechange` (lines ~709-717) which the extracted transport layer should keep and expose per-player.
  - **Jitter**: compute application-side from consecutive packet arrival timestamps for a given `phoneId` (e.g. a simple rolling stddev of inter-arrival deltas, or an RFC 3550-style running jitter estimate) — this uses only the packet's existing `timestamp`/receipt-time data already flowing through `playerStore`, no wire change.
  - **Packet loss %**: compute application-side from the packet's existing uint16 `seq` field — track `(seq_max_seen - seq_min_seen + 1)` expected vs. actual-received count over a rolling window per sender (the sequence-drop logic in `decode.ts`'s `isNewerSeq` already touches this exact field, so the counting infrastructure is a natural extension of code that exists).
**Warning signs:** If a code review sees `stats.get(id).jitter` or `.packetsLost` referenced anywhere for this connection type, that's a bug — those will always be `undefined`/`NaN` at runtime, not caught by TypeScript (the DOM lib types these fields as optional on a union of report types, so accessing them compiles fine but returns nothing).

### Pitfall 2: jsdom (this project's test environment) does not implement `requestAnimationFrame`

**What goes wrong:** If the D-08 internal tick's `requestAnimationFrame`-primary / `setInterval`-fallback logic is implemented but only feature-detection-tested (never actually exercised on the fallback path) in a real browser, the SDK's own `vitest` + `jsdom` test suite will *always* silently take the fallback path — which is fine, but means the primary rAF path has **zero automated coverage** unless a test explicitly mocks `requestAnimationFrame` onto the jsdom `window`/`globalThis` before constructing a `Platform`.
**Why it happens:** jsdom deliberately does not implement `requestAnimationFrame` (confirmed empirically — `typeof window.requestAnimationFrame === 'undefined'` in a fresh jsdom 29 instance) because it has no real rendering/compositing loop to synchronize with.
**How to avoid:** Write two explicit unit tests for the tick module: one that stubs a fake `globalThis.requestAnimationFrame` (proving the primary path is taken when available) and one that runs unmodified under jsdom (proving the fallback engages correctly, e.g. using `vi.useFakeTimers()` to deterministically advance `setInterval`-driven ticks rather than waiting on real timers).
**Warning signs:** A tick-related test that passes without ever calling `vi.useFakeTimers()` or asserting *which* scheduling primitive was used — that's a sign the test only incidentally exercises the fallback path and never proves the primary path works.

### Pitfall 3: `"workspace:*"` is not valid npm dependency syntax

**What goes wrong:** Writing `"immersive-rt": "workspace:*"` in `client/package.json` and running `npm install` fails immediately with `npm error code EUNSUPPORTEDPROTOCOL` / `npm error Unsupported URL Type "workspace:": workspace:*`.
**Why it happens:** `workspace:` is a pnpm/Yarn-Berry-specific protocol; plain npm workspaces resolve local members purely by name+semver-range matching against the packages declared in the root `workspaces` field — there is no special syntax to opt in.
**How to avoid:** Use a normal semver range (`"immersive-rt": "^0.1.0"` or `"*"` during pre-1.0 development) in `client/package.json`'s `dependencies`. npm's installer detects that `immersive-rt` matches a local workspace member and creates a symlink (`client/node_modules/immersive-rt -> ../../packages/immersive-rt`) instead of fetching from the registry — confirmed via an actual `npm install` run against a scratch two-package workspace.
**Warning signs:** `EUNSUPPORTEDPROTOCOL` in `npm install` output; or (if silently ignored) `client`'s build failing to resolve `import { Platform } from 'immersive-rt'` because the dependency line was simply dropped/errored during a partial install.

### Pitfall 4: The W3C-earth-frame → Three.js coordinate remap must NOT be lost during extraction, and must NOT move into the SDK

**What goes wrong:** `scene.ts` currently applies a specific axis remap when feeding a decoded quaternion into `THREE.Quaternion.slerp()`: `scratchQuat.set(state.qx, state.qz, -state.qy, state.qw)` — converting the W3C `DeviceOrientationEvent` earth-frame convention (X=East, Y=North, Z=Up) into Three.js's convention (Y=up, right-handed, viewer-facing +Z). If this remap is accidentally copied into the SDK's `getPlayerInput()` return value, the SDK would silently bake in a Three.js-specific assumption despite D-07's "zero dependency on `three`, engine-agnostic" mandate — breaking any non-Three.js consumer. If it's dropped entirely (neither in the SDK nor re-added in Phase 8's demo scene), the demo's meshes will rotate on the wrong axes exactly as the original Fix 6 comment in `scene.ts` describes.
**Why it happens:** The remap currently lives inline in the SLERP call site inside `scene.ts`, which this phase's D-06 extraction target list does **not** include (`scene.ts` stays in `client/`) — but it's easy to overlook that the remap is *conceptually* part of "how to interpret the SDK's orientation output," even though it's physically Three.js-coupled code.
**How to avoid:** `getPlayerInput().orientation` / `getRawInput().orientationRaw` should return the raw W3C-earth-frame quaternion exactly as decoded off the wire (unchanged from `decode.ts`'s output) — no remap in the SDK. The plan must explicitly carry the remap comment/logic forward into whatever `scene.ts` becomes after this phase (whether left as a dev harness or seeded into Phase 8), so the axis-mapping knowledge isn't lost, and must document in the SDK's public API docs that the coordinate frame is W3C-earth (not any particular engine's world frame) — this is a natural doc note for the `Quaternion` type's JSDoc.
**Warning signs:** A demo game (Phase 8) whose meshes visibly rotate on swapped/inverted axes compared to the Phase 6 baseline — the exact symptom the original Fix 6 comment describes ("qy... ended up in Three.js y (yaw)... visually swapped").

## Code Examples

### Latency overlay metrics (corrected per Pitfall 1)

```typescript
// packages/immersive-rt/src/latencyOverlay.ts (excerpt)
// Source: W3C webrtc-stats spec (RTCIceCandidatePairStats) [VERIFIED],
//         existing pc.oniceconnectionstatechange pattern in client/src/room.ts (lines ~709-717)
async function readPeerMetrics(pc: RTCPeerConnection): Promise<{ rttMs: number | null; iceState: RTCIceConnectionState }> {
  const report = await pc.getStats();
  let rttMs: number | null = null;
  for (const stat of report.values()) {
    if (stat.type === 'candidate-pair' && (stat.state === 'succeeded' || stat.nominated)) {
      if (typeof stat.currentRoundTripTime === 'number') {
        rttMs = stat.currentRoundTripTime * 1000;
      }
      break;
    }
  }
  return { rttMs, iceState: pc.iceConnectionState };
}

// Jitter + packet loss are NOT read from getStats() (Pitfall 1) — computed from
// the same seq/timestamp fields decode.ts already exposes, tracked per-sender.
interface LossJitterTracker {
  lastSeq: number | null;
  seenCount: number;
  expectedCount: number;
  arrivalDeltasMs: number[]; // rolling window for jitter estimate
}
```

### npm workspace member dependency (corrected per Pitfall 3)

```jsonc
// client/package.json — dependencies block after this phase
{
  "dependencies": {
    "@petamoriken/float16": "3.9.3",  // stays if still needed directly by client-only code; else remove
    "ahrs": "1.3.3",
    "three": "0.185.1",
    "immersive-rt": "*"   // NOT "workspace:*" — plain npm resolves this to the local
                            // packages/immersive-rt workspace member automatically
  }
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|---------------|--------|
| `vite-plugin-dts` with `rollupTypes: true` (common in older tutorials, v3/v4-era) | `bundleTypes: true` on the same import path, now backed by `unplugin-dts` internally | `vite-plugin-dts` v5.x (current published major) | Any plan/task text copy-pasted from an older tutorial referencing `rollupTypes` will silently no-op — must use `bundleTypes` |
| `build.rollupOptions` in Vite config | `build.rolldownOptions` (Vite 8 ships Rolldown, a Rust rewrite of Rollup, as its default bundler) | Vite 8.x | `rollupOptions` still works as a deprecated alias — fine to keep using for this phase (matches `client/vite.config.ts`'s existing style), but a JSDoc `@deprecated` warning will surface in editors; not a blocking issue |

**Deprecated/outdated:**
- `rollupTypes` (vite-plugin-dts option name): superseded by `bundleTypes`.
- Yarn/pnpm's `workspace:*` protocol syntax: not applicable to this project at all since it uses plain npm — do not carry this syntax over from tutorials that assume pnpm/Yarn.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `vite-plugin-dts` is the preferred `.d.ts` tool over `unplugin-dts`'s direct import path for this phase (a stylistic choice, not a functional difference — both are the same code) | Standard Stack / Alternatives Considered | Low — trivially swappable; both packages resolve to identical generated output |
| A2 | The exact npm-registry-current version pins (`vite: 8.1.5`, `vite-plugin-dts: 5.0.3`, `@petamoriken/float16` latest) will still be current when the plan executes | Standard Stack | Low-Medium — versions checked 2026-07-16; planner should re-run `npm view <pkg> version` at execution time if more than a few days elapse |
| A3 | The rolling-window jitter/packet-loss computation design in Pitfall 1 (stddev of inter-arrival deltas; expected-vs-received seq count) is architecturally sound but its exact window size / smoothing constants are not specified anywhere in CONTEXT.md — left as an implementation detail for the plan | Pitfall 1, Code Examples | Low — any reasonable rolling window (e.g. last 2-5 seconds) satisfies SDK-04's "rolling avg" requirement; exact tuning is not requirement-critical |

## Open Questions

1. **Should `client/package.json`'s existing `@petamoriken/float16`, `ahrs` dependencies be pruned once `decode.ts` moves to the SDK?**
   - What we know: `decode.ts` (which needs `@petamoriken/float16`) moves into the SDK per D-06. `ahrs` is used by phone-side sensor fusion code (`orientation.ts`), which is NOT in this phase's extraction list (phone client is untouched).
   - What's unclear: whether any remaining `client/src/` file (post-extraction) still directly imports `@petamoriken/float16` or `three`'s `Quaternion`/`Vector3` types outside `scene.ts` in a way that would break if the dependency were removed.
   - Recommendation: the plan should grep `client/src/` for remaining `@petamoriken/float16` imports after the extraction task completes, before deciding whether to remove it from `client/package.json`'s `dependencies` — likely still needed if `phone.ts`'s encode path is untouched and lives in `client/src/sensor/encode.ts` (also unchanged, not moved).

2. **Does the Makefile / docker-compose static-file-server build step need updating for the new workspace layout?**
   - What we know: `Makefile` currently has no `client` build target (`make up`/`down`/`dev-certs` only); deployment likely relies on `client/dist` built separately or via docker-compose's static file server stage.
   - What's unclear: whether the Docker build context for the static file server assumes `client/` is buildable standalone (its own `npm install && npm run build`) — converting to a workspace root means `client`'s `npm install` now needs the workspace root's `package.json`/`package-lock.json` present too.
   - Recommendation: out of this phase's explicit scope (D-06 doesn't mention Docker/Makefile), but the plan should at minimum verify `client`'s standalone `npm run build` (as currently invoked, if at all, by any Docker stage) still works from a workspace-member context — flag as a manual verification step if a Docker build stage references `client/` in isolation.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Node.js | npm workspace tooling, Vite build | ✓ | v26.5.0 | — |
| npm | Workspace management (`workspaces` field, `-w` flag) | ✓ | 11.17.0 | — |
| Vite | `build.lib` library mode | ✓ (installed in `client/node_modules`, will need own install in `packages/immersive-rt`) | 8.1.5 | — |
| vite-plugin-dts | `.d.ts` generation | ✗ (not yet installed anywhere in repo) | — | Install via `npm install -w packages/immersive-rt vite-plugin-dts --save-dev`; no viable "no-dependency" fallback for declaration bundling across multiple source files — `tsc --emitDeclarationOnly` alone produces one `.d.ts` per source file rather than a single bundled entry, which is a materially worse DX for a public npm package but *is* a fallback if the dependency is rejected at the human-verify checkpoint |

**Missing dependencies with no fallback:** none blocking — `vite-plugin-dts` has a degraded-but-functional fallback (`tsc --emitDeclarationOnly` producing multi-file declarations) if the human-verify checkpoint rejects it.

**Missing dependencies with fallback:** `vite-plugin-dts` / `unplugin-dts` → `tsc --emitDeclarationOnly` (degraded DX, still satisfies SDK-01's "TypeScript types for all public surfaces").

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Vitest `^3.0.0` (matches `client/package.json`'s existing pin) |
| Config file | New `packages/immersive-rt/vite.config.ts` — `test.environment: 'jsdom'` (mirrors `client/vite.config.ts`'s existing inline `test` block; no separate `vitest.config.ts` exists in this repo, keep that convention) |
| Quick run command | `npm run test -w packages/immersive-rt -- <test-file-pattern>` (or `cd packages/immersive-rt && npx vitest run <pattern>`) |
| Full suite command | `npm run test -w packages/immersive-rt` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| SDK-01 | `tsc --strict` compiles a game against published types with no errors | type-check | `npm run typecheck -w packages/immersive-rt` (`tsc --noEmit`); ROADMAP success criterion 1 additionally wants a consumer-side check — add a small fixture file under `packages/immersive-rt/tests/typecheck-fixture.ts` that calls `platform.getPlayerInput(id)` / `platform.on('imuUpdate', cb)` and gets typechecked as part of the package's own `tsc --noEmit` | ❌ Wave 0 |
| SDK-02 | `getPlayerInput()` returns the exact 5-field shape | unit | `npx vitest run tests/platform.test.ts -t "getPlayerInput"` | ❌ Wave 0 |
| SDK-03 | `imuUpdate`/`playerJoin`/`playerLeave`/`playerReconnect` fire with correct signatures at correct lifecycle moments | unit | `npx vitest run tests/platform.test.ts -t "events"` (simulate transport-layer calls into the store/tick and assert `EventTarget` dispatch happened with correct args) | ❌ Wave 0 |
| SDK-04 | Latency overlay renders rolling avg latency/jitter/loss%/ICE state | unit (jsdom DOM assertions) + manual (visual, live session) | `npx vitest run tests/latencyOverlay.test.ts` for the DOM-render + metrics-computation logic; live ICE state / real RTT requires a manual on-device check (getStats() needs a real RTCPeerConnection, not fully mockable in jsdom) | ❌ Wave 0 |
| SDK-05 | (Already Complete) naming preserved through extraction | unit (regression) | `npx vitest run tests/decode.test.ts tests/platform.test.ts -t "deadReckoningPosition"` — extraction must not rename fields | ✅ (moves from `client/tests/decode.test.ts`, `target-state.test.ts`) |
| SDK-06 | `getRawInput().orientationRaw` returns unsmoothed quaternion, distinct from the SLERP'd `getPlayerInput().orientation` | unit | `npx vitest run tests/tick.test.ts -t "raw vs interpolated"` | ❌ Wave 0 |

### Sampling Rate

- **Per task commit:** targeted `vitest run <file>` for the module just changed
- **Per wave merge:** `npm run test -w packages/immersive-rt` (full suite)
- **Phase gate:** Full suite green, plus `npm run typecheck -w packages/immersive-rt` and (if `client` also changed) `npm run typecheck -w client`, before `/gsd-verify-work`

### Wave 0 Gaps

- [ ] `packages/immersive-rt/vite.config.ts` — framework config, does not exist yet (new package)
- [ ] `packages/immersive-rt/tests/platform.test.ts` — covers SDK-02, SDK-03
- [ ] `packages/immersive-rt/tests/tick.test.ts` — covers SDK-06, and must exercise both the rAF-mocked path and the jsdom-default fallback path (Pitfall 2)
- [ ] `packages/immersive-rt/tests/latencyOverlay.test.ts` — covers SDK-04's computable (non-live-network) portions
- [ ] `packages/immersive-rt/tests/slerp.test.ts` — pure-function unit test for the hand-written SLERP (D-07)
- [ ] Moved (not new) test files: `decode.test.ts`, `target-state.test.ts` from `client/tests/` — must be relocated alongside their source files, not duplicated
- [ ] Framework install: none — `vitest`/`jsdom` already exist as devDependency patterns in `client/package.json`, replicate into the new package's `package.json`

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No | This phase does not touch session/reconnect-token handling — that logic (in `room.ts`'s `handleJoinAck`/reconnect flow) is explicitly OUT of the D-06 extraction list; it's UI/session-page code that stays in `client/` |
| V3 Session Management | No | Same as above — the extracted transport layer is the low-level signaling/RTC plumbing (`sendWtRequest`/`connectDesktopWT`/`handleOffer`), not the session/reconnect-token storage logic |
| V4 Access Control | No | No new access-control surface introduced |
| V5 Input Validation | Yes | `decode.ts`'s existing `isSafePacket()` (finite-value guard on quaternion fields) and `isNewerSeq()` (RFC 1982 sequence validation) move unchanged into the SDK — this phase must not weaken these guards during extraction; they were the T-06-03/T-06-04/T-06-06/T-06-09 mitigations established in Phase 6 |
| V6 Cryptography | No | No cryptographic material handled by the extracted modules (TURN credentials, reconnect tokens are session-layer, out of scope per D-06) |

### Known Threat Patterns for this stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Malformed/truncated binary packet crashing the decoder or poisoning render state with NaN | Tampering / Denial of Service | `decode.ts`'s existing `byteLength < BUF_SIZE` guard and `isSafePacket()` finite-check — preserved verbatim during extraction (this phase adds no new decode logic, only relocates it) |
| Out-of-order / replayed sequence numbers accepted as newer | Tampering | `isNewerSeq()`'s RFC 1982 half-distance comparison — preserved verbatim |
| Latency overlay (D-02's DOM exception) rendering attacker-influenced strings via `innerHTML` | Tampering (XSS) | All overlay text writes must use `textContent`, matching the existing project convention already established in `room.ts`'s `updateHud()`/`renderTabRoster()` (explicitly noted there as "no injection risk — T-06-10b"); the latency overlay only renders numeric metrics (latency ms, jitter ms, loss %, ICE state enum string from a fixed `RTCIceConnectionState` union) so there is no untrusted string surface at all, but the *pattern* (textContent-only DOM writes) should still be followed for consistency and to avoid regressions if a future phase adds a player-name label to the overlay |
| A malicious/compromised phone client sending well-formed-but-adversarial `seq` values to skew the SDK's new jitter/loss computation (Pitfall 1) into misleading a game developer's expectations | Tampering | Low severity (developer-facing debug tool, not a game-security-critical path) — no mitigation beyond the existing `isNewerSeq`/`isSafePacket` guards is warranted for a dev overlay; note this as accepted risk rather than requiring new work |

## Sources

### Primary (HIGH confidence — directly verified via tool execution against installed/downloaded artifacts or primary spec documents)
- `node_modules/vite/dist/node/index.d.ts` (installed Vite 8.1.5 in `client/`) — `LibraryOptions`, `rollupOptions`/`rolldownOptions` deprecation notice — read directly via `grep`/`Read`
- `npm pack unplugin-dts@1.0.3` unpacked tarball, `dist/shared/unplugin-dts.*.d.ts` — `PluginOptions`/`EmitOptions` interfaces (`bundleTypes`, `include`, `exclude`, `tsconfigPath`, `insertTypesEntry`, no `rollupTypes`)
- `unpkg.com/vite-plugin-dts@5.0.3/README.md` and `/dist/index.d.ts` — confirms the package is a re-export shim of `unplugin-dts`
- `w3.org/TR/webrtc-stats/` — `RTCIceCandidatePairStats` and `RTCDataChannelStats` field lists; confirmed no `jitter`/`packetsLost` fields exist outside `RTCReceivedRtpStreamStats`
- Local `npm install` test against a scratch two-package workspace — confirmed `"workspace:*"` fails with `EUNSUPPORTEDPROTOCOL`, and a normal semver range correctly symlinks
- Local `jsdom` instantiation test — confirmed `requestAnimationFrame` is `undefined` on jsdom 29's `window`
- `npm view <pkg> version/peerDependencies/repository.url/scripts.postinstall` for `vite`, `vite-plugin-dts`, `unplugin-dts`, `@petamoriken/float16`, `typescript-event-target` — live registry queries
- `client/src/room.ts`, `client/src/playerStore.ts`, `client/src/sensor/decode.ts`, `client/src/types.ts`, `client/vite.config.ts`, `client/package.json`, `client/src/scene.ts` (coordinate remap, lines ~155-175), `client/src/sensor/webxr.ts` (freeze-on-loss precedent), `server/src/wt_server.rs` (signaling message contract) — read directly from this repository

### Secondary (MEDIUM confidence — WebSearch/WebFetch results cross-checked against official docs pages)
- `docs.npmjs.com/cli/v11/using-npm/workspaces/` — npm workspace `workspaces` field syntax, `-w` flag, local-member symlinking behavior
- `developer.mozilla.org` — `RTCPeerConnection.getStats()`, `RTCStatsReport` report-type overview
- `hirok.io/posts/package-json-exports` — `exports` field ordering conventions (`types` first), ESM-only `type: module` implications
- `vite.dev/config/build-options.html`, `vite.dev/guide/build.html` — `build.lib` option defaults, external-dependency externalization pattern

### Tertiary (LOW confidence — general pattern references, not load-bearing on any specific claim)
- `dev.to/marcogrcr/type-safe-eventtarget-subclasses-in-typescript-1nkf`, `dev.to/43081j/strongly-typed-event-emitters-using-eventtarget-in-typescript-3658` — general TypeScript+EventTarget pattern inspiration for Pattern 3 (the actual implementation shown is hand-synthesized for this project's D-12 zero-dependency constraint, not copied from either article)

## Metadata

**Confidence breakdown:**
- Standard stack (Vite lib mode, vite-plugin-dts, npm workspaces): HIGH — every version/API claim was verified against an actually-installed or actually-downloaded package artifact, not training-data recall
- WebRTC `getStats()` shape for data-channel-only connections: HIGH — cross-checked against the W3C primary spec and MDN, and directly contradicts (correctly) a locked CONTEXT.md decision's literal mechanism, which is exactly the kind of finding this research phase exists to surface
- Architecture / extraction patterns (Platform/EventTarget facade, project structure): MEDIUM — the extraction targets and their current shapes are HIGH confidence (read directly from the repo), but the specific new-code organization (file names like `tick.ts`, `slerp.ts`) is a reasonable synthesis, not a locked decision — the planner has discretion here per CONTEXT.md
- Pitfalls: HIGH for Pitfalls 1-3 (each independently verified via tool execution); MEDIUM for Pitfall 4 (coordinate-frame reasoning is sound and the underlying `scene.ts` code was read directly, but this is a design-implication argument rather than a tool-verifiable fact)

**Research date:** 2026-07-16
**Valid until:** 2026-08-15 (30 days — npm registry versions for `vite-plugin-dts`/`unplugin-dts` are actively moving; re-verify version pins if planning is delayed)
