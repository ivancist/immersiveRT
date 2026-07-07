# Phase 4: Phone Bootstrap and WebRTC Channels - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-07-07
**Phase:** 4-Phone Bootstrap and WebRTC Channels
**Areas discussed:** WebRTC initiation protocol, Phone UI after channels open, SPA extension vs. separate phone build, Wake Lock + backgrounding behavior

---

## WebRTC Initiation Protocol

**User clarification:** Phone should use WebTransport (not WebSocket) for signaling. Peers should not need to trust each other in advance — room membership is the authorization signal.

| Option | Description | Selected |
|--------|-------------|----------|
| Room snapshot in pair-ack | Server includes desktop peer list in pair-ack payload | ✓ |
| Separate room-snapshot message after pair-ack | Clean message shapes but extra round trip | |
| Phone requests roster after pair-ack | Most explicit but adds latency | |

**User's choice:** Room snapshot in pair-ack

---

| Option | Description | Selected |
|--------|-------------|----------|
| Phone offers → each desktop | Phone is initiator, loops through peers[], sends offer per desktop via WT | ✓ |
| Each desktop offers → phone | Desktop-driven, multi-initiator race risk | |
| Server-orchestrated sequential | Server sends rtc-start messages; adds server complexity | |

**User's choice:** Phone offers → each desktop

---

| Option | Description | Selected |
|--------|-------------|----------|
| Server pushes peer-joined to phone via WT | Phone opens new offer on receiving server push | ✓ |
| New desktop offers to phone on join | Phone must handle unexpected inbound offers | |
| Phone polls / re-requests roster | Wastes bandwidth, delays channel | |

**User's choice:** Server pushes peer-joined event to phone

---

| Option | Description | Selected |
|--------|-------------|----------|
| Server attests in routing envelope | Broker includes {from: phone_id, room: ABCD}; desktop trusts server routing | ✓ |
| Phone includes reconnect token in offer metadata | Extra round trip + token exposure | |
| No verification — accept any offer via WT signaling | Relies purely on WT connection auth | |

**User's choice:** Server attests in routing envelope

**User clarification:** Server must track when all WebRTC channels are fully established (not just when offers are sent), to support game-start gating — some games need confirmation that all connections are properly established before allowing a player to start.

| Option | Description | Selected |
|--------|-------------|----------|
| Phone reports each channel-open | Phone sends rtc-channel-ready when RTCDataChannel opens | |
| Both sides report: phone + desktop each confirm | Server requires both-side confirmation before marking channel established | ✓ |
| Desktop reports when data channel opens | Desktop side only | |

**User's choice:** Both sides report

---

| Option | Description | Selected |
|--------|-------------|----------|
| player-ready event to whole room | {type: 'player-ready', player_id, slot, username} broadcast to all desktops + phone | ✓ |
| Server fires per-channel confirmation only | Game assembles readiness itself | |
| player-ready to desktops only | Phone doesn't get confirmation | |

**User's choice:** player-ready event to whole room

---

## Phone UI After Channels Open

| Option | Description | Selected |
|--------|-------------|----------|
| Minimal status: Connected X/Y + Move indicator | Player name, room code, channel count, motion pulse indicator | ✓ |
| Fullscreen 'You're in' with connection badge | Large confirmation, minimal info | |
| Debug panel: per-desktop channel state table | Useful for dev, too noisy for users | |

**User's choice:** Minimal status screen with motion indicator

---

| Option | Description | Selected |
|--------|-------------|----------|
| Progress: 'Connecting... X/Y channels' with spinner | Live count up as channels open | ✓ |
| Single 'Connecting...' spinner, no detail | Simple but less informative | |
| You decide | Planner picks | |

**User's choice:** Live progress with channel count

---

## SPA Extension vs. Separate Phone Build

| Option | Description | Selected |
|--------|-------------|----------|
| Separate phone.html + phone.js | Own artifact, mobile-optimized, no desktop code on phone | ✓ |
| Extend existing SPA | One bundle, simpler, phone loads unused desktop code | |
| You decide | Researcher + planner choose | |

**User's choice:** Separate phone.html + phone.js

**User clarification:** Wants the faster approach that keeps system consistent — nginx serves phone.html (one-word nginx config change: `try_files $uri $uri.html /index.html`). No Rust server changes needed.

| Option | Description | Selected |
|--------|-------------|----------|
| nginx serves phone.html (try_files change) | Consistent with current static file serving architecture | ✓ |
| Rust server serves phone.html | Axum route, mixes static file serving into WT binary | |

**User's choice:** nginx approach

---

## Wake Lock + Backgrounding Behavior

| Option | Description | Selected |
|--------|-------------|----------|
| After player-ready fires | Request WakeLock when all channels confirmed open | ✓ |
| After iOS motion permission granted | Earlier, covers connecting phase too | |
| After pair-ack | Covers connecting phase but may hold lock during long wait | |

**User's choice:** After player-ready

**User clarification:** When phone state changes (backgrounded, Wake Lock lost, channel drops), the server should be notified and desktops alerted — same publish/broadcast pattern as player-ready.

| State transitions selected | Selected |
|---------------------------|----------|
| Phone backgrounded / foregrounded | ✓ |
| Wake Lock lost / reacquired | ✓ |
| WebRTC data channel drops / recovers | ✓ |
| Heartbeat miss detected by server (server-driven) | ✓ |

**User's choice:** All state transitions notify

---

| Option | Description | Selected |
|--------|-------------|----------|
| Reacquire WakeLock + send foreground state + check WebRTC | Full self-healing on foreground return | ✓ |
| Reacquire WakeLock + send foreground state only | Partial recovery | |
| Show reconnect prompt to user | User-driven recovery | |

**User's choice:** Full self-healing on foreground return

---

## Claude's Discretion

- Exact wire naming for `phone-state` event states (consistent with existing JSON envelope pattern)
- Server data structure for tracking "all channels confirmed" per room/player
- WakeLock graceful degradation when `navigator.wakeLock` is absent (older Safari)
- Motion indicator animation implementation (CSS pulse driven by devicemotion magnitude threshold)

## Deferred Ideas

- Full sensor display on phone (orientation indicator, position values) — Phase 5
- Phone reconnect UI — server holds slot 60s; Phase 4 shows "session ended" state; reconnect UX is Phase 5
- WakeLock cross-browser polyfill for older Safari — graceful degradation only in Phase 4
- Touch input capture (tap, on-screen buttons) — Phase 5 (SENS-06)
