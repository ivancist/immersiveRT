---
phase: 01-server-and-transport-foundation
plan: 01
subsystem: server/cargo-workspace
tags: [rust, cargo, workspace, scaffold, echo, tokio, wtransport]
status: complete

dependency_graph:
  requires: []
  provides:
    - symbol: now_ms
      kind: pub fn
      file: server/src/echo.rs
    - symbol: EchoMessage
      kind: pub struct
      file: server/src/echo.rs
    - symbol: wt_server::run
      kind: pub async fn stub
      file: server/src/wt_server.rs
    - symbol: ws_server::run
      kind: pub async fn stub
      file: server/src/ws_server.rs
    - symbol: immersive-rt-server
      kind: binary
      file: target/debug/immersive-rt-server
  affects: []

tech_stack:
  added:
    - wtransport 0.7 (WebTransport/HTTP3 server)
    - tokio 1.x with rt-multi-thread (async runtime)
    - tokio-tungstenite 0.29 (WebSocket fallback)
    - futures-util 0.3 (stream/sink traits)
    - anyhow 1.x (ergonomic error handling)
    - tracing 0.1 + tracing-subscriber 0.3 (structured logging)
    - serde 1.x + serde_json 1.x (serialization)
  patterns:
    - Cargo workspace with resolver = "2" and server-only members
    - Dead-code suppression on stubs with #[allow(dead_code)] pending Plan 02/03 implementation
    - tokio::try_join! for concurrent listener spawning (Plans 02/03 will fill bodies)
    - serde rename attribute for JSON key aliasing ("msg_type" -> "type")

key_files:
  created:
    - Cargo.toml (workspace root — members=["server"], resolver="2")
    - server/Cargo.toml (immersive-rt-server 0.1.0, all Phase 1 deps)
    - server/src/main.rs (#[tokio::main], env var reads, tokio::try_join! with stubs)
    - server/src/echo.rs (now_ms, EchoMessage, 2 unit tests)
    - server/src/wt_server.rs (stub pub async fn run)
    - server/src/ws_server.rs (stub pub async fn run)
    - .gitignore (certs/ and target/)
    - Cargo.lock (pinned resolved versions — T-01-02 mitigation)
  modified: []

decisions:
  - "resolver = \"2\" in workspace Cargo.toml — enables feature unification improvements for 2021 edition workspaces"
  - "certs/ gitignored before any cert files exist — T-01-01 threat mitigation; private key must never appear in git history"
  - "Cargo.lock committed — T-01-02 mitigation pins exact crate versions to prevent supply-chain substitution via crates.io"
  - "#[allow(dead_code)] on echo.rs public items and stub module fns — suppresses RUSTFLAGS=-D warnings until Plans 02/03 activate them"

metrics:
  duration_minutes: 2
  completed_date: "2026-07-06"
  tasks_completed: 3
  tasks_total: 3
  files_created: 8
  files_modified: 0
---

# Phase 01 Plan 01: Cargo Workspace Scaffold Summary

**One-liner:** Rust Cargo workspace with immersive-rt-server package, all Phase 1 dependencies declared, echo.rs shared module with 2 passing unit tests, and certs/ gitignored for security.

## What Was Built

Scaffolded the complete Cargo workspace structure that Plans 02 and 03 will build upon:

- **Workspace root** (`Cargo.toml`): `[workspace]` with `members = ["server"]` and `resolver = "2"` — no `[package]` section.
- **Server package** (`server/Cargo.toml`): `immersive-rt-server` v0.1.0, all Phase 1 dependencies declared at semver-minor ranges (no patch pinning).
- **Entry point** (`server/src/main.rs`): `#[tokio::main]` with `tracing_subscriber::fmt::init()`, env var reads for `CERT_PATH`/`KEY_PATH`/`WT_PORT`/`WS_PORT` with SKELETON.md defaults, and `tokio::try_join!` calling stub listeners.
- **Echo module** (`server/src/echo.rs`): `pub fn now_ms() -> u64` (SystemTime epoch ms) and `pub struct EchoMessage` with `#[serde(rename = "type")]` on `msg_type` field plus `client_ts: u64`, `server_ts: Option<u64>`.
- **Stub modules** (`wt_server.rs`, `ws_server.rs`): Each exports `pub async fn run(...) -> anyhow::Result<()> { Ok(()) }` with `#[allow(dead_code)]`.
- **Security** (`.gitignore`): `certs/` and `target/` entries present before any cert files exist.
- **Dependency lock** (`Cargo.lock`): committed to pin exact resolved versions.

## Verification Results

| Check | Result |
|-------|--------|
| `cargo build -p immersive-rt-server` (RUSTFLAGS="-D warnings") | PASS — zero warnings |
| `cargo test -p immersive-rt-server` | PASS — 2/2 tests ok |
| `.gitignore` contains `certs/` | PASS |
| `cargo metadata --no-deps` lists `immersive-rt-server` | PASS |
| `git check-ignore -v certs/` matches `.gitignore:1:certs/` | PASS |

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Cargo workspace root and server package manifest | acf5404 | Cargo.toml, server/Cargo.toml, server/src/main.rs (placeholder) |
| 2 | server/src/main.rs and server/src/echo.rs scaffolds | 8e85cf6 | server/src/main.rs, server/src/echo.rs, wt_server.rs, ws_server.rs, .gitignore |
| 3 | echo unit tests + cargo test baseline | f9a2cee | server/src/echo.rs (test block added) |
| — | Cargo.lock committed (T-01-02 supply chain mitigation) | a3374c4 | Cargo.lock |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Dead-code warnings in echo.rs under RUSTFLAGS="-D warnings"**

- **Found during:** Task 2 verification
- **Issue:** `pub fn now_ms()` and `pub struct EchoMessage` in echo.rs were reported as unused because no production code in this plan's scope calls them yet (Plans 02/03 will). With `RUSTFLAGS="-D warnings"` this failed the build.
- **Fix:** Added `#[allow(dead_code)]` attribute to both `now_ms` and `EchoMessage`. The plan already anticipated this pattern for stub modules (wt_server.rs, ws_server.rs) — same treatment applied to echo.rs public symbols.
- **Files modified:** `server/src/echo.rs`
- **Commit:** 8e85cf6

**2. [Rule 2 - Security] Cargo.lock committed for supply chain integrity**

- **Found during:** Post-Task 3 git status check
- **Issue:** Cargo.lock was untracked after first `cargo build`. T-01-02 threat register specifies "Cargo.lock committed to repo pins exact resolved versions after first fetch."
- **Fix:** Committed Cargo.lock in a dedicated chore commit.
- **Files modified:** `Cargo.lock`
- **Commit:** a3374c4

## Known Stubs

| Stub | File | Reason |
|------|------|--------|
| `wt_server::run` returns `Ok(())` immediately | server/src/wt_server.rs | WebTransport listener implemented in Plan 02 |
| `ws_server::run` returns `Ok(())` immediately | server/src/ws_server.rs | WebSocket fallback listener implemented in Plan 03 |
| `main.rs` exits immediately after `tokio::try_join!` | server/src/main.rs | Stubs return instantly; Plans 02/03 fill them with accept loops |

These stubs are intentional — Plan 01's goal is a clean-compiling scaffold, not working listeners.

## Threat Flags

None. All surfaces introduced in this plan were covered by the plan's `<threat_model>`:
- T-01-01 (key disclosure): mitigated by `.gitignore` with `certs/` entry
- T-01-02 (supply chain): mitigated by committing `Cargo.lock`
- T-01-03 (build-time DoS): accepted

## Self-Check: PASSED

- [x] Cargo.toml exists at /home/ivancist/Documents/immersiveRT/Cargo.toml
- [x] server/Cargo.toml exists at /home/ivancist/Documents/immersiveRT/server/Cargo.toml
- [x] server/src/main.rs exists
- [x] server/src/echo.rs exists
- [x] server/src/wt_server.rs exists
- [x] server/src/ws_server.rs exists
- [x] .gitignore exists with certs/ entry
- [x] Cargo.lock committed
- [x] Commit acf5404 exists (Task 1)
- [x] Commit 8e85cf6 exists (Task 2)
- [x] Commit f9a2cee exists (Task 3)
- [x] Commit a3374c4 exists (Cargo.lock)
