---
phase: 3
slug: session-and-pairing
status: verified
threats_open: 0
asvs_level: 1
created: 2026-07-07
---

# Phase 03 — Security

> Per-phase security contract: threat register, accepted risks, and audit trail.

---

## Trust Boundaries

| Boundary | Description | Data Crossing |
|----------|-------------|---------------|
| client→join-room handler | Untrusted WS/WT payload claiming username, room_code, game_type | Username string (untrusted), room code (low) |
| QR scan→pair handler | Untrusted token string from any phone via WS/WT | pairing_token (high — HMAC credential) |
| Reconnect→reconnect handler | Untrusted reconnect_token string claiming a slot identity | reconnect_token (high — session credential) |
| PAIRING_TOKEN_SECRET env | HMAC signing secret; must never appear in logs | Secret key (critical) |
| phone browser→nginx TLS | Phone connects to nginx HTTPS on port 8443 | TLS certificate trust |
| sessionStorage reconnect_token | Client-side credential; must not be logged | reconnect_token (high) |

---

## Threat Register

| Threat ID | Category | Component | Severity | Disposition | Mitigation | Status |
|-----------|----------|-----------|----------|-------------|------------|--------|
| T-03-01 | Spoofing | pairing_token.rs validate_and_consume | high | mitigate | Single-use DashMap entry; constant-time HMAC via `verify_slice()`; TTL=90s | closed |
| T-03-02 | DoS | room_registry handle_join + lobby form | medium | mitigate | Max 8 slots enforced server-side; btn-join-submit disabled on click until ack | closed |
| T-03-03 | Information Disclosure | pairing_token.rs HMAC verify | medium | mitigate | `mac.verify_slice()` throughout; no `==` comparison on HMAC output | closed |
| T-03-04 | Tampering | username validation | medium | mitigate | Username: trim, 1–64 chars, printable ASCII; reject empty after sanitization | closed |
| T-03-05 | Spoofing | reconnect tokens + nginx HTTPS | high | mitigate | Opaque 32-byte random server-side tokens; BASE_URL required (panics if absent) | closed |
| T-03-06 | Tampering | payload deserialization | low | mitigate | serde_json::Value None on malformed → join-error; connection stays open | closed |
| T-03-07 | Information Disclosure | PAIRING_TOKEN_SECRET in logs | medium | mitigate | Secret not logged; startup log emits boolean `pairing_secret_set = true` only | closed |
| T-03-08 | Information Disclosure | nginx serving certs directory | medium | mitigate | `./certs:/certs:ro` mount; certs not under nginx document root | closed |
| T-03-09 | Information Disclosure | reconnect_token logged to console | low | mitigate | room.js contains zero `console.log` calls; token stored in localStorage only | closed |
| T-03-10 | Spoofing | pairing_url HTTP vs HTTPS in QR | high | mitigate | BASE_URL required env var; server panics at startup if unset or HTTP | closed |
| T-03-SC | Tampering | cargo sha2 + rand package legitimacy | high | mitigate | Cargo.lock checksums: sha2=0.11.0 (446ba717…), rand=0.10.2 (c7f5fa3a…), hmac=0.13.0 (6303bc97…) — all from crates.io registry | closed |

*Status: open · closed*
*Severity: critical > high > medium > low — only open threats at or above `high` count toward threats_open*
*Disposition: mitigate (implementation required) · accept (documented risk) · transfer (third-party)*

---

## Accepted Risks Log

No accepted risks.

---

## Security Audit Trail

| Audit Date | Threats Total | Closed | Open | Run By |
|------------|---------------|--------|------|--------|
| 2026-07-07 | 11 | 11 | 0 | gsd-secure-phase (L1 grep, ASVS level 1) |

---

## Sign-Off

- [x] All threats have a disposition (mitigate / accept / transfer)
- [x] Accepted risks documented in Accepted Risks Log
- [x] `threats_open: 0` confirmed
- [x] `status: verified` set in frontmatter

**Approval:** verified 2026-07-07
