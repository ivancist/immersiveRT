---
phase: 2
slug: signaling-turn-and-deployment
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-07-06
---

# Phase 2 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Rust built-in (`cargo test`), same as Phase 1 |
| **Config file** | none — cargo test runs automatically |
| **Quick run command** | `cargo test -p immersive-rt-server` |
| **Full suite command** | `cargo test --workspace` |
| **Estimated runtime** | ~15 seconds |

---

## Sampling Rate

- **After every task commit:** Run `cargo test -p immersive-rt-server`
- **After every plan wave:** Run `cargo test --workspace`
- **Before `/gsd-verify-work`:** Full suite must be green + manual `turnutils_uclient` validation + manual browser ICE handshake
- **Max feedback latency:** ~15 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| broker-unit | TBD | 1 | INFRA-02 | — | N/A | unit | `cargo test test_broker_relay_ws` | ❌ W0 `server/src/broker.rs` | ⬜ pending |
| turn-creds-unit | TBD | 1 | INFRA-04 | T-HMAC | HMAC-SHA1 known-vector passes | unit | `cargo test test_turn_credential_known_vector` | ❌ W0 `server/src/turn_creds.rs` | ⬜ pending |
| broker-cross-transport | TBD | 2 | INFRA-03 | — | N/A | integration | `cargo test test_broker_relay_cross_transport` | ❌ W0 `server/tests/broker_relay.rs` | ⬜ pending |
| turn-creds-endpoint | TBD | 2 | INFRA-04 | T-HMAC | Credentials differ per request (ephemeral) | integration | `cargo test test_turn_creds_endpoint_ephemeral` | ❌ W0 | ⬜ pending |
| coturn-stun-turn | TBD | 3 | INFRA-06 | — | N/A | manual | `turnutils_uclient -u test -w test <host>:3478` | Manual only | ⬜ pending |
| docker-compose-cold-start | TBD | 3 | INFRA-07 | — | N/A | manual/smoke | `docker compose up --build` then `docker compose ps` | Manual only | ⬜ pending |
| ice-handshake-e2e | TBD | 3 | INFRA-02 SC1 | — | N/A | manual | Two browser tabs, DevTools RTCPeerConnection state | Manual only | ⬜ pending |
| turn-relay-only | TBD | 3 | INFRA-02 SC5 | — | N/A | manual | coturn relay-only mode test | Manual only | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `server/src/broker.rs` — SignalingBroker implementation, covers INFRA-02/03
- [ ] `server/src/turn_creds.rs` — HMAC-SHA1 credential generation + known-answer unit test, covers INFRA-04
- [ ] `server/tests/broker_relay.rs` — integration test for cross-client, cross-transport routing
- [ ] `docker/Dockerfile.server`, `docker/coturn/turnserver.conf`, `docker-compose.yml` — net-new for INFRA-06/07
- [ ] Verify `turnutils_uclient` availability inside `coturn/coturn:4.6` image before writing manual validation step

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Full WebRTC ICE handshake (phone↔desktop data channel opens) | INFRA-02 SC1 | Requires real browsers and real network conditions | Open two browser tabs; verify `RTCPeerConnection.connectionState === 'connected'` in DevTools |
| STUN binding + TURN allocation pass | INFRA-06 | Requires Docker-networked coturn service running | `turnutils_uclient -u test -w test <host>:3478` — must show STUN binding and TURN allocation success |
| Docker Compose cold start — 3 healthy containers | INFRA-07 | Requires Docker runtime | `docker compose up --build` then `docker compose ps` — all 3 services show healthy state |
| TURN relay-only path via symmetric NAT simulation | INFRA-02 SC5 | Requires coturn relay-only test config | Configure coturn with `no-udp`/relay-only or use `turnutils_uclient --relay-only` |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 15s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
