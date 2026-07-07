# Phase 3: Session and Pairing - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-07-07
**Phase:** 03-session-and-pairing
**Areas discussed:** Room join + slot registration, QR code display approach, Slot hold + reconnect mechanics, Lifecycle event targeting

---

## Room join + slot registration

| Option | Description | Selected |
|--------|-------------|----------|
| New WS/WT message type | Desktop sends join-room message over existing signaling connection. Reuses established channel. | ✓ |
| HTTP POST endpoint | New HTTP route for join. Two channels to manage. | |

**Notes:** User clarified that rooms should be URL-addressable for multi-game/multi-room contexts. Discussed WebTransport URL compatibility — WT supports path+query params but opted for SPA `pushState` approach to keep WT URL stable. Join handshake over WS/WT; HTTP layer reserved for TURN creds only.

---

| Option | Description | Selected |
|--------|-------------|----------|
| Server auto-creates on first join | No explicit create step. | ✓ |
| Desktop explicitly creates first | Two-step create flow. | |

---

| Option | Description | Selected |
|--------|-------------|----------|
| Explicit Create / Join split | Two buttons, distinct flows. | ✓ |
| Combined single form | Username + room code, server auto-creates if missing. | |
| Room code in URL only | Page at / asks username only. | |

**Notes:** User specified that after Create, a game/mode selection step must appear before redirect. Multiple game types anticipated. Phase 3 scaffolds the UI step with one placeholder game type.

---

| Option | Description | Selected |
|--------|-------------|----------|
| Query param /?room=ABCD | Simple nginx config, no path rewriting. | |
| Path /room/ABCD | Cleaner URL, one nginx try_files rule. | ✓ |
| No room in URL | Desktop generates/enters code on-screen. | |

**Notes:** User confirmed path preferred. Added constraint: server must approve before redirect; 9th join rejected.

---

| Option | Description | Selected |
|--------|-------------|----------|
| WS/WT join message + pushState | Single connection, no reload, already connected on approval. | ✓ |
| HTTP API first then WS/WT | Two round trips before room renders. | |

**Rationale:** WS/WT-first is smoothest UX — one fewer network round trip, no page reload, same connection active after approval.

---

## QR code display approach

| Option | Description | Selected |
|--------|-------------|----------|
| Client-side JS library | Desktop renders QR from URL string. No server endpoint. Fast. | ✓ |
| Server renders PNG/SVG | Server generates QR image via HTTP. Adds dependency. | |

---

| Option | Description | Selected |
|--------|-------------|----------|
| Full HTTPS URL with signed token | Camera-app scannable, single-use HMAC token, secure. | ✓ |
| Full phone pairing URL (static) | Camera-app scannable but replayable. | |
| Room code only | Extra step for phone user. | |

**Notes:** User requested most secure approach. HMAC-signed single-use short-lived token prevents QR screenshot replay. HTTPS URL required for iOS/Android camera app to auto-open browser. Camera-app compatibility was an explicit requirement from the user.

---

## Slot hold + reconnect mechanics

| Option | Description | Selected |
|--------|-------------|----------|
| Reconnect token issued at pairing time | Stored in sessionStorage, exchanged on reconnect. | ✓ |
| Username-based reclaim | Simpler but collision-prone. | |

---

| Option | Description | Selected |
|--------|-------------|----------|
| Slot reservation only | Minimal: room + slot + identity + status. No message buffering. | ✓ |
| Full connection state | Buffers messages during disconnect. Out of scope. | |

---

| Option | Description | Selected |
|--------|-------------|----------|
| Slot released back to pool | Available for new player; player-left event fires. | ✓ |
| Slot stays reserved until room empty | Ghost slots, simpler but broken UX. | |

---

## Lifecycle event targeting

| Option | Description | Selected |
|--------|-------------|----------|
| All desktops in the room | Every desktop has complete room view. | ✓ |
| Only affected parties | Incomplete room view per desktop. | |

---

| Option | Description | Selected |
|--------|-------------|----------|
| Server pushes over WS/WT | Real-time, no polling, same JSON envelope. | ✓ |
| Client polls HTTP endpoint | Latency, overhead, not real-time. | |

---

## Claude's Discretion

- Room code exact length and character set
- Hold timer implementation (per-slot tokio sleep vs periodic sweep)
- Room state data structure (extend SignalingBroker vs separate RoomRegistry)
- Reconnect token format (HMAC vs opaque lookup)
- HMAC secret management (env var vs generated at startup)

## Deferred Ideas

- Spectator mode (SESS-V2-01) — v2
- Room password protection (SESS-V2-02) — v2
- Cross-reload session persistence (SESS-V2-03) — v2
- Multiple concrete game types — Phase 8+
