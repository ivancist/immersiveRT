---
phase: 01
slug: server-and-transport-foundation
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-07-06
---

# Phase 01 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Rust built-in (`cargo test`) |
| **Config file** | none — cargo test discovers tests automatically |
| **Quick run command** | `cargo test -p immersive-rt-server` |
| **Full suite command** | `cargo test --workspace` |
| **Estimated runtime** | ~30 seconds (dependency compilation excluded) |

---

## Sampling Rate

- **After every task commit:** Run `cargo test -p immersive-rt-server`
- **After every plan wave:** Run `cargo test --workspace`
- **Before `/gsd-verify-work`:** Full suite green + manual Chrome WebTransport check (Success Criterion 1)
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 01-01-01 | 01-01 | 1 | INFRA-01 | T-01-02 | Cargo.lock committed — pins resolved crate versions | compile | `cargo metadata --no-deps --manifest-path Cargo.toml 2>&1 \| grep immersive-rt-server` | ❌ W0 | ⬜ pending |
| 01-01-02 | 01-01 | 1 | INFRA-01 | T-01-01 | `certs/` in `.gitignore` before any cert files created | compile | `RUSTFLAGS="-D warnings" cargo build -p immersive-rt-server && echo "BUILD_CLEAN"` | ❌ W0 | ⬜ pending |
| 01-01-03 | 01-01 | 1 | INFRA-01 | — | N/A | unit | `cargo test -p immersive-rt-server 2>&1 \| tail -5` | ❌ W0 | ⬜ pending |
| 01-02-01 | 01-02 | 2 | INFRA-01 | T-01-01 | Private key in `certs/` gitignored; `mkcert -install` CA only in OS trust store | manual setup | `test -f certs/localhost+2.pem && test -f certs/localhost+2-key.pem && echo "CERTS_EXIST"` | ❌ W0 | ⬜ pending |
| 01-02-02 | 01-02 | 2 | INFRA-01 | T-01-05 | tokio::spawn per connection — panics do not kill accept loop | compile | `cargo build -p immersive-rt-server 2>&1 \| grep -c "^error" \| xargs -I{} test {} -eq 0 && echo "WT_BUILD_OK"` | ❌ W0 | ⬜ pending |
| 01-02-03 | 01-02 | 2 | INFRA-01 | — | Chrome flag required | manual | Manual — open Chrome with `chrome://flags/#webtransport-developer-mode` enabled, navigate to test URL | Manual only | ⬜ pending |
| 01-03-01 | 01-03 | 3 | INFRA-05 | T-01-09 | WS accept loop continues on connection error (tracing::warn, no panic) | compile | `cargo build -p immersive-rt-server 2>&1 \| grep -c "^error" \| xargs -I{} test {} -eq 0 && echo "WS_BUILD_OK"` | ❌ W0 | ⬜ pending |
| 01-03-02 | 01-03 | 3 | INFRA-05 | — | N/A | integration | `cargo test test_ws_echo -p immersive-rt-server 2>&1 \| tail -10` | ❌ W0 | ⬜ pending |
| 01-03-03 | 01-03 | 3 | INFRA-01, INFRA-05 | — | N/A | integration | `cargo test --workspace 2>&1 \| tail -20` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `Cargo.toml` (workspace root) — workspace definition before any cargo commands run
- [ ] `server/Cargo.toml` — package with all Phase 1 dependencies
- [ ] `server/src/main.rs` — skeleton entry point (even empty) so crate compiles
- [ ] `server/src/echo.rs` — `now_ms()` and `EchoMessage` module (tests live here)
- [ ] `server/src/wt_server.rs` — stub module (Plan 02 fills it)
- [ ] `server/src/ws_server.rs` — stub module (Plan 03 fills it)
- [ ] `.gitignore` — `certs/` entry before mkcert runs

*All Wave 0 items are created in Plan 01-01 (Wave 1). mkcert cert generation is in Plan 01-02 (Wave 2).*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Chrome connects via WebTransport with mkcert cert | INFRA-01 (SC 1) | Requires real Chrome browser with dev flag; no headless WebTransport test exists | 1. Run `cargo run`. 2. Enable `chrome://flags/#webtransport-developer-mode`. 3. Open browser DevTools → Network. 4. Navigate to test page. 5. Confirm WebTransport session established (no TLS error). |
| Latency probe < 10ms on LAN | INFRA-01 (SC 3) | Requires live server + browser + LAN environment | 1. Run server. 2. Open test page in Chrome on same LAN. 3. Send ping. 4. Verify response RTT < 10ms in console output. |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify (manual-only task 01-02-03 is isolated between two automated tasks)
- [ ] Wave 0 covers all MISSING (❌) references
- [ ] No watch-mode flags in any verify command
- [ ] Feedback latency < 30s for `cargo test -p immersive-rt-server`
- [ ] `nyquist_compliant: true` set in frontmatter after Wave 0 is verified

**Approval:** pending
