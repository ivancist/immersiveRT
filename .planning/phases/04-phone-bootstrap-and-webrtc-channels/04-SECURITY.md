---
phase: "04"
slug: phone-bootstrap-and-webrtc-channels
status: verified
threats_open: 0
asvs_level: 1
created: 2026-07-09
---

# Phase 04 — Security

> Per-phase security contract: threat register, accepted risks, and audit trail.

---

## Trust Boundaries

| Boundary | Description | Data Crossing |
|----------|-------------|---------------|
| phone browser → Rust server (WebTransport :4433) | Untrusted phone-supplied pairing token + client_id cross here | Pairing token (JWT/HMAC), client_id string, signaling envelopes |
| QR URL → phone browser | Pairing token travels in the URL query string | Short-lived HMAC pairing token (TTL=300s, single-use) |
| phone → server signaling (WT) | Phone-supplied offer/ICE and rtc-channel-ready with a `with` target cross here | WebRTC offer SDP, ICE candidates, rtc-channel-ready payload |
| desktop → server signaling (WS) | Desktop-supplied answer/ICE and rtc-channel-ready cross here | WebRTC answer SDP, ICE candidates, rtc-channel-ready payload |
| phone ↔ desktop (WebRTC data channel) | P2P channel established after ICE; browser DTLS/SCTP secures it | IMU sensor data (unreliable, unordered) |
| phone → server (WT) | Phone-supplied heartbeat and phone-state messages cross here | Heartbeat pings, phone-state transition strings |
| server background monitor → room state | Timer-driven slot transitions act on server-held state only | Internal: slot status transitions (Connected → Disconnected) |
| server → desktops (relay) | phone-state and peer events relayed to all room desktops | phone-state payloads, peer-joined/peer-left events |

---

## Threat Register

| Threat ID | Category | Component | Severity | Disposition | Mitigation | Status |
|-----------|----------|-----------|----------|-------------|------------|--------|
| T-04-01 | Spoofing | `envelope.from` on WT/WS pair message | high | mitigate | `envelope.from != *registered_id` drop guard at `wt_server.rs:193` / `ws_server.rs:214`; phone_client_id set from registered id, not attacker-supplied payload field | closed |
| T-04-02 | Elevation of privilege | pairing token replay | high | mitigate | `pairing_store.validate_and_consume()` at `room_registry.rs:650` — single-use; replayed token returns `pair-error:invalid_token` (verified by `test_invalid_token_returns_pair_error`) | closed |
| T-04-03 | Tampering | ICE candidate/offer injection in signaling | high | mitigate | Same `envelope.from != registered_id` drop guard prevents source spoofing; offers/answers routed via broker with server-attested `from` field; desktop trusts server routing, not offer contents | closed |
| T-04-05 | Information disclosure | pairing token in `/phone?token=` URL | low | accept | Short-lived (TTL=300s, configurable via `PAIRING_TTL_SECS`), single-use; Phase 3 precedent accepted | closed |
| T-04-06 | Input validation | malformed pair / rtc-channel-ready payload | medium | mitigate | `raw_payload["token"].as_str()` → `None` → `pair-error:invalid_payload` at `room_registry.rs:638–643`; `payload["with"].as_str()` → `None` → early return at `room_registry.rs:1022–1025`; `parse_envelope` returns `None` on malformed bytes at `wt_server.rs:176–178`, never panics | closed |
| T-04-07 | Spoofing | forged rtc-channel-ready claiming channel open | medium | mitigate | Sender role derived from server-held slot state (`phone_client_id`, `client_id`), not client-asserted; DashMap key `(room_code, phone_client_id, desktop_client_id)` — only valid room members can form the key | closed |
| T-04-08 | Denial of service | channel_ready map growth from bogus keys | low | accept | Entries bounded by room membership; upsert O(1); rooms evicted on disconnect; no unbounded growth under existing 64 KiB message cap + per-connection semaphore | closed |
| T-04-09 | Denial of service | heartbeat/phone-state flood from a phone | medium | mitigate | `handle_heartbeat` is O(1); `MAX_WT_CONNECTIONS=1024` semaphore at `wt_server.rs:12,38`; `MAX_WS_MESSAGE_BYTES=65536` cap at `ws_server.rs:18`; `from` guard prevents cross-phone spoofing | closed |
| T-04-10 | Spoofing | forged phone-state/heartbeat claiming another phone's identity | high | mitigate | Same `envelope.from != registered_id` drop guard (applies to all message types including heartbeat/phone-state); heartbeat/phone-state resolve slot by registered `phone_client_id`, not client-asserted fields | closed |
| T-04-11 | Tampering | peer-left injection to force-close rival channel | medium | mitigate | `peer-left` is server-originated only — `route_to_phone` called from `on_client_disconnect` (`room_registry.rs:854`) and `handle_leave` (`room_registry.rs:951`); no client-facing message type dispatches `peer-left` | closed |
| T-04-12 | Denial of service | slot never released after heartbeat miss | low | mitigate | `HOLD_TTL_SECS` env var (default 60s); `hold_timers` DashMap per-slot; `release_slot_if_disconnected` fires when timer expires — no permanent leak | closed |
| T-04-SC | Tampering | supply-chain: npm/cargo installs | low | accept | No new npm or Cargo dependencies introduced in Phase 4 (RESEARCH Package Legitimacy Audit: none) — no install tasks, no `[ASSUMED]`/`[SUS]` packages | closed |

*Status: open · closed · open — below threshold (non-blocking)*
*Severity: critical > high > medium > low — open threats at or above `workflow.security_block_on` (high) count toward `threats_open`*
*Disposition: mitigate (implementation required) · accept (documented risk) · transfer (third-party)*

---

## Accepted Risks Log

| Risk ID | Threat Ref | Rationale | Accepted By | Date |
|---------|------------|-----------|-------------|------|
| AR-04-01 | T-04-05 | Pairing token in URL query string is short-lived (300s) and single-use; risk window is minimal; Phase 3 precedent accepted; no bearer header alternative without breaking QR-scan UX | orchestrator | 2026-07-09 |
| AR-04-02 | T-04-08 | channel_ready map bounded by room membership (≤8 slots per room); O(1) upsert; per-connection rate already capped by message-size and semaphore guards | orchestrator | 2026-07-09 |
| AR-04-03 | T-04-SC | No new dependencies in Phase 4 — supply-chain attack surface unchanged from prior phases; audit ran clean | orchestrator | 2026-07-09 |

---

## Security Audit Trail

| Audit Date | Threats Total | Closed | Open | Run By |
|------------|---------------|--------|------|--------|
| 2026-07-09 | 12 | 12 | 0 | Claude (gsd-secure-phase, ASVS L1) |

---

## Sign-Off

- [x] All threats have a disposition (mitigate / accept / transfer)
- [x] Accepted risks documented in Accepted Risks Log
- [x] `threats_open: 0` confirmed
- [x] `status: verified` set in frontmatter

**Approval:** verified 2026-07-09
