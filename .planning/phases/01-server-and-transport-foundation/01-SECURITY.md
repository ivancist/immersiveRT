---
phase: "01"
slug: server-and-transport-foundation
status: verified
threats_open: 0
asvs_level: 1
created: 2026-07-06
---

# Phase 01 — Security

> Per-phase security contract: threat register, accepted risks, and audit trail.

---

## Trust Boundaries

| Boundary | Description | Data Crossing |
|----------|-------------|---------------|
| developer → git repo | Developer must not accidentally commit cert private key | Private TLS key (certs/localhost+2-key.pem) |
| build system → crates.io | cargo fetch pulls from crates.io registry; supply-chain attack surface | Compiled Rust crates |
| internet → QUIC:4433 | Untrusted WebTransport connections arrive here | Client JSON payloads |
| filesystem → TLS identity | Private key loaded from certs/ at startup | TLS private key (read-only) |
| WebTransport client → echo handler | Client-supplied JSON must not cause panic on malformed input | EchoMessage JSON |
| internet → TCP:8080/9090 | Untrusted WebSocket connections arrive; plain ws:// (no TLS in Phase 1) | WebSocket frames |
| WebSocket client → echo handler | Client-supplied messages echoed verbatim | Raw message frames |
| tokio::try_join! error boundary | Panic or fatal error in one listener kills both via try_join propagation | Error propagation |

---

## Threat Register

| Threat ID | Category | Component | Severity | Disposition | Mitigation | Status |
|-----------|----------|-----------|----------|-------------|------------|--------|
| T-01-01 | Information Disclosure | certs/localhost+2-key.pem | high | mitigate | `certs/` in `.gitignore` before any cert files created; `git ls-files certs/` returns empty (confirmed UAT test 6) | closed |
| T-01-02 | Tampering | crates.io dependency fetch | medium | mitigate | Cargo.lock committed (commit a3374c4) — pins exact resolved versions after first fetch | closed |
| T-01-03 | DoS | `cargo build` in CI | low | accept | Build-time only; no runtime exposure | closed |
| T-01-04 | Information Disclosure | certs/localhost+2-key.pem | high | mitigate | `certs/` gitignored; `Identity::load_pemfiles` reads from filesystem only at startup — key never serialized or logged | closed |
| T-01-05 | DoS | wt_server accept loop | high | mitigate | Each connection dispatched to `tokio::spawn`; errors logged with `tracing::error!`; accept loop never exits on connection errors | closed |
| T-01-06 | Tampering | echo handler JSON parsing | medium | mitigate | `serde_json::from_slice` with typed `EchoMessage`; `Err` logged and stream dropped — no panic, no `unwrap` | closed |
| T-01-07 | Spoofing | TLS handshake (mkcert CA) | low | accept | mkcert CA is dev-only; production will use trusted CA in Phase 2 Docker deployment | closed |
| T-01-08 | Tampering | Plain WebSocket ws:// on port 8080 | medium | accept | LAN-dev-only; WSS with TLS added in Phase 2; explicit RESEARCH.md decision | closed |
| T-01-09 | DoS | ws_server accept loop | high | mitigate | `tokio::spawn` per connection + `Semaphore(1024)` connection cap (applied in code review fix WR-004); errors logged; loop continues | closed |
| T-01-10 | DoS | Large WebSocket frame echoed verbatim | medium | mitigate | Originally accepted for Phase 1; applied early via code review fix WR-005 — `accept_async_with_config` with `max_message_size = 64 KiB` and `max_frame_size = 64 KiB` | closed |
| T-01-11 | Spoofing | tokio::try_join! failure propagation | low | accept | Clean-fail behavior acceptable for Phase 1; Phase 2 adds restart logic in Docker Compose | closed |

*Status: open · closed · open — below high threshold (non-blocking)*
*Severity: critical > high > medium > low — only open threats at or above `high` count toward threats_open*
*Disposition: mitigate (implementation required) · accept (documented risk) · transfer (third-party)*

---

## Accepted Risks Log

| Risk ID | Threat Ref | Rationale | Accepted By | Date |
|---------|------------|-----------|-------------|------|
| AR-01 | T-01-03 | Build-time DoS; no runtime exposure; acceptable for Phase 1 scaffold | plan | 2026-07-06 |
| AR-02 | T-01-07 | mkcert CA is dev-only; production uses Let's Encrypt in Phase 2 | plan | 2026-07-06 |
| AR-03 | T-01-08 | Plain ws:// LAN-dev-only per RESEARCH.md decision; WSS in Phase 2 | plan | 2026-07-06 |
| AR-04 | T-01-11 | Clean-fail via try_join acceptable for Phase 1; Docker restart in Phase 2 | plan | 2026-07-06 |

---

## Security Audit Trail

| Audit Date | Threats Total | Closed | Open | Run By |
|------------|---------------|--------|------|--------|
| 2026-07-06 | 11 | 11 | 0 | gsd-secure-phase (asvs_level=1, block_on=high) |

---

## Sign-Off

- [x] All threats have a disposition (mitigate / accept / transfer)
- [x] Accepted risks documented in Accepted Risks Log
- [x] `threats_open: 0` confirmed
- [x] `status: verified` set in frontmatter

**Approval:** verified 2026-07-06
