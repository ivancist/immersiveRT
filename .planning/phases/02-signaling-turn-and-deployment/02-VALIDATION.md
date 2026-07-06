---
phase: 02
slug: signaling-turn-and-deployment
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-07-06
---

# Phase 02 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Rust built-in (`cargo test`), same as Phase 1 |
| **Config file** | none — cargo test runs automatically |
| **Quick run command** | `cargo test -p immersive-rt-server` |
| **Full suite command** | `cargo test --workspace` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run `cargo test -p immersive-rt-server`
- **After every plan wave:** Run `cargo test --workspace`
- **Before `/gsd-verify-work`:** Full suite green + manual `turnutils_uclient` validation + manual browser ICE handshake
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 02-TBD | TBD | 0 | INFRA-02 | — | Broker routes a JSON envelope from client A to client B over two WS connections | integration | `cargo test test_broker_relay_ws` | ❌ Wave 0 — new `server/tests/broker_relay.rs` | ⬜ pending |
| 02-TBD | TBD | 0 | INFRA-02 | T-02-security-01 | HMAC-SHA1 credential generation produces coturn-compatible output for a known fixture (secret, userid, ttl) → expected password | unit | `cargo test test_turn_credential_known_vector` | ❌ Wave 0 — new `server/src/turn_creds.rs` `#[cfg(test)]` module | ⬜ pending |
| 02-TBD | TBD | 0 | INFRA-03 | — | Broker routes correctly when sender/receiver are on same transport (WS↔WS) and cross transport (WT↔WS) | integration | `cargo test test_broker_relay_cross_transport` | ❌ Wave 0 | ⬜ pending |
| 02-TBD | TBD | 0 | INFRA-04 | T-02-security-02 | TURN credential HTTP endpoint returns username+password that changes on every request (not cached) | integration | `cargo test test_turn_creds_endpoint_ephemeral` | ❌ Wave 0 | ⬜ pending |
| 02-TBD | TBD | 0 | INFRA-06 | — | `docker compose up` brings up coturn; `turnutils_uclient` STUN+TURN check passes | manual | Manual — `turnutils_uclient -u test -w test <host>:3478` | Manual only | ⬜ pending |
| 02-TBD | TBD | 0 | INFRA-07 | — | `docker compose up` cold start brings up 3 containers with no manual steps | manual/smoke | `docker compose up --build` then `docker compose ps` shows 3 healthy services | Manual only | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `server/src/broker.rs` — SignalingBroker implementation (DashMap-backed), covers INFRA-02/03
- [ ] `server/src/turn_creds.rs` — HMAC-SHA1 credential generation + known-answer unit test, covers INFRA-04
- [ ] `server/tests/broker_relay.rs` — integration test for cross-client, cross-transport routing
- [ ] `docker/Dockerfile.server`, `docker/coturn/turnserver.conf`, `docker-compose.yml` — none exist yet, all net-new for INFRA-06/07
- [ ] Verify `turnutils_uclient` availability inside `coturn/coturn:4.6` (Open Question 2 in RESEARCH.md) before writing the manual validation step into VERIFICATION.md

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Full WebRTC ICE handshake between phone and desktop | Success Criterion 1 | Requires real browsers/devices and network conditions | Open two browser tabs/devices, inspect `RTCPeerConnection` connection state via DevTools until `connected` |
| Docker Compose cold-start brings up 3 healthy containers | INFRA-07 / Success Criterion 3 | Requires real Docker daemon, no unit-testable equivalent | `docker compose up --build` from clean state, then `docker compose ps` shows all 3 services healthy |
| STUN/TURN reachability via `turnutils_uclient` | INFRA-06 / Success Criterion 2 | External tool, requires running coturn instance | `turnutils_uclient -u test -w test <server>:3478` succeeds |
| TURN relay path under simulated symmetric NAT | Success Criterion 5 | Requires a relay-only coturn test profile or NAT simulation | Configure coturn `no-udp`/relay-only test profile, confirm data channel still establishes via TURN relay |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
