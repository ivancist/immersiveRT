# Phase 2: Signaling, TURN, and Deployment - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-07-06
**Phase:** 2-Signaling, TURN, and Deployment
**Areas discussed:** Signaling transport

---

## Signaling Transport

### Q1: Primary signaling channel

| Option | Description | Selected |
|--------|-------------|----------|
| WebSocket only | Port 8080, simpler relay, existing ws_server.rs | |
| WebTransport only | Port 4433, single port, QUIC required | |
| Both (WT primary, WS fallback) | Resilient, both transports relay ICE | ✓ |

**User's choice:** Both — WebTransport primary, WebSocket fallback

---

### Q2: Cross-transport routing mechanism

| Option | Description | Selected |
|--------|-------------|----------|
| Shared in-process broker (DashMap / RwLock<HashMap>) | Transport-agnostic, maps client IDs to mpsc::Sender | ✓ |
| Shared broadcast channel | All clients fan-out, O(N) overhead | |

**User's choice:** Shared in-process broker

---

### Q3: Message envelope format

| Option | Description | Selected |
|--------|-------------|----------|
| JSON with type + from + to + payload | Standard WebRTC signaling convention, debuggable | ✓ |
| MessagePack binary | Consistent with sensor encoding but overkill for signaling | |
| JSON without routing fields | Breaks multi-desktop model | |

**User's choice:** JSON with type + from + to + payload

---

### Q4: Broker state model

| Option | Description | Selected |
|--------|-------------|----------|
| Minimal stateful — track connected IDs, drop to unknown | Prevents dangling messages, surfaces bugs | ✓ |
| Stateless forward — silently drop if target not found | Simpler but harder to debug ICE failures | |

**User's choice:** Minimal stateful broker

---

### Q5: Continue or write context?

**User's choice:** Free-text: "Make WebSocket port 9090 or other unused ports by default, no 8080"

**Notes:** WS default port changes from 8080 → 9090 to avoid conflicts with common local services. Captured as D-02 in CONTEXT.md.

---

## Claude's Discretion

- TURN credential endpoint placement (HTTP sub-path vs new listener) — not specified
- Docker Compose platform compatibility strategy (Linux-only vs dev/prod split) — not specified

## Deferred Ideas

None.
