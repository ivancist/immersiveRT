# Domain Pitfalls

**Domain:** Real-time web gaming platform — Phone IMU + WebRTC + WebTransport
**Researched:** 2026-07-06
**Stack:** Rust/wtransport server, coturn TURN, WebRTC unreliable data channels, on-device Madgwick filter, Three.js desktop, TypeScript SDK

---

## Critical Pitfalls

Mistakes that cause rewrites, silent failures, or ship-blocking issues.

---

### Pitfall 1: WebTransport Certificate Requirements Are Non-Negotiable

**What goes wrong:** The browser rejects WebTransport connections silently or with an opaque network error. Dev works fine over plain HTTP, then everything breaks the moment you add TLS — either because the cert is self-signed without proper SAN extensions, was signed with RSA instead of ECDSA, or exceeds the 14-day validity limit that WebTransport enforces for self-signed certificate hashes.

**Why it happens:** WebTransport over HTTP/3 uses a certificate verification path distinct from normal HTTPS. Even when Chrome allows a self-signed root for HTTP/3 general traffic, it does NOT allow the same root for WebTransport. The spec mandates:
- Certificate must use ECDSA (RSA self-signed certs are rejected).
- Certificate must be valid for ≤ 14 days when using the `serverCertificateHashes` connection option.
- Certificate must have a valid `X509v3 Subject Alternative Name` — missing SANs cause Chrome to reject the cert.
- mkcert's output is NOT compatible with WebTransport's `serverCertificateHashes` API without modification.

**Consequences:** Connection drops at TLS handshake. Error appears only as a generic network failure in DevTools — no fingerprint mismatch message, just a refused connection. Developers spend hours thinking the Rust server is broken when the cert is the issue.

**Prevention:**
- In dev: use Chrome's `chrome://flags/#webtransport-developer-mode` flag to bypass cert pinning entirely, OR generate short-lived ECDSA certs with a script that auto-renews them every 13 days.
- In prod: use a CA-signed cert (Let's Encrypt via certbot). No cert hashes needed — browser trusts the CA chain.
- For the wtransport server, verify cert has SAN entries for all hostnames before serving.
- Add a health-check endpoint that confirms TLS handshake succeeds from within CI.

**Warning signs:** `net::ERR_QUIC_PROTOCOL_ERROR` or `Failed to construct 'WebTransport'` in the browser console; connection works with WebSocket fallback but not WebTransport.

**Phase to address:** Phase 1 (server infrastructure). Do not defer — this blocks all further integration work.

---

### Pitfall 2: QUIC UDP Blocked on Corporate/Hotel Networks — No Graceful Fallback

**What goes wrong:** WebTransport uses QUIC over UDP port 443. Corporate firewalls, hotel captive portals, and many enterprise networks silently drop UDP packets on port 443. The browser times out rather than falling back to TCP. The user sees a hung loading screen with no error.

**Why it happens:** Many managed networks only allow TCP on ports 80 and 443. QUIC (UDP 443) is blocked at the firewall or transparent proxy level. Unlike HTTP/3 in regular browsing (where browsers auto-fall back to HTTP/2 TCP), WebTransport has no built-in TCP fallback — it is QUIC-only.

**Consequences:** Game is completely unusable for players on corporate WiFi, hotel networks, school networks, or anywhere with restrictive UDP policies. This can be 20–40% of potential users depending on target audience.

**Prevention:**
- Implement a WebSocket fallback signaling path. If WebTransport connection attempt times out after ~3 seconds, silently switch to WebSocket for the signaling channel.
- Keep the WebRTC data channel (which is also UDP-based) as the sensor hot path — but ensure TURN TCP 443 relay is configured for ICE fallback on the same networks.
- Detect QUIC availability early in the connection flow before committing to UI state.
- Deploy coturn on TCP 443 as a relay option (see coturn pitfalls below).

**Warning signs:** Platform works on home WiFi but fails silently on corporate or hotel networks. Users report "spinning" without error messages.

**Phase to address:** Phase 1 (transport layer). Build the fallback path before declaring any transport "done."

---

### Pitfall 3: iOS Safari WebTransport — Now Available, But DeviceMotion Permission Blocks UX

**What goes wrong (two sub-issues):**

**3a — WebTransport availability:** WebTransport was not supported in Safari until Safari 26.4 (released 2026). Earlier iOS 18 builds had it behind a flag. Any iOS device running Safari < 26.4 (iOS 17 and below) has NO WebTransport support and will fail silently. Since all browsers on iOS must use Apple's WebKit engine, this affects Chrome/Firefox on iOS equally.

**3b — DeviceMotion permission prompt:** iOS 13+ requires `DeviceMotionEvent.requestPermission()` and `DeviceOrientationEvent.requestPermission()` to be called inside a synchronous user gesture handler (click or touchend, NOT touchstart). The permission prompt appears exactly once per origin per browser session and is cached. If the permission prompt fires at the wrong time (not on a gesture), the browser silently ignores it — no error, no event, no sensor data ever arrives.

**Why it happens:** Apple added the permission requirement for privacy reasons. The gesture requirement exists to prevent fingerprinting via silent sensor access. Both `DeviceMotionEvent` and `DeviceOrientationEvent` require separate `requestPermission()` calls — they are not bundled.

**Consequences for 3b:** Phone appears connected to the game room, the WebRTC channel is established, but sensor data is all zeros or never emitted. Silent failure is the worst outcome — the dev has no indication the permission was denied.

**Prevention for 3a:**
- Feature-detect `window.WebTransport` before attempting connection. Show a "browser not supported" message with upgrade instructions rather than a timeout.
- Document the Safari 26.4+ requirement prominently in the SDK README.

**Prevention for 3b:**
- Show a "Grant Motion Access" button on the phone's join screen. Attach requestPermission calls to that button's `click` handler.
- Request both permissions sequentially in the same handler.
- Check `DeviceMotionEvent.requestPermission` exists (feature-detect) before calling — non-iOS browsers lack this method and calling it throws.
- Persist the permission grant in `sessionStorage`; do not re-prompt on page reload (Safari caches the grant already, but the app UX should not appear to re-ask).
- If permission is denied, show actionable guidance: "Go to Safari Settings → Motion & Orientation Access → Enable."

**Warning signs:** Sensor data is always `{ alpha: 0, beta: 0, gamma: 0 }` on iOS; no `devicemotion` events fire despite the WebRTC channel connecting.

**Phase to address:** Phase 2 (phone client). Permission gate must exist before any sensor code runs.

---

### Pitfall 4: coturn Requires Host Networking in Docker — Bridge Mode Silently Breaks STUN

**What goes wrong:** coturn started inside a Docker bridge network cannot relay STUN responses correctly because STUN response packets must carry the server's real external IP. Inside a bridge network, coturn sees the container's internal IP (e.g., 172.17.0.x), embeds that in STUN XOR-MAPPED-ADDRESS responses, and returns an unreachable address to WebRTC clients. ICE candidate gathering completes, but all STUN-derived candidates are unreachable. Peers fail to connect.

**Why it happens:** STUN works by reflecting the client's observed public IP back to them. For this to work, the TURN server must see the real source IP and respond from its real external IP. Docker NAT hides both. The `--relay-ip` and `--external-ip` flags in coturn config must match the host's real IP, not the container IP.

**Consequences:** WebRTC fails to gather server-reflexive (srflx) and relay (relay) ICE candidates. Connection works only if both peers are on the same LAN with direct P2P. Any NAT traversal scenario fails.

**Prevention:**
- In Docker Compose, set `network_mode: "host"` for the coturn container.
- Set `external-ip=<PUBLIC_IP>` in `turnserver.conf` (can use `$(curl -s ifconfig.me)` in entrypoint to resolve dynamically).
- Expose the TURN relay port range (49152–65535 UDP) in the host firewall — not just the signaling port (3478).
- Test coturn separately with `turnutils_uclient` before integrating WebRTC — do not test coturn via WebRTC; they have different failure modes.
- Open UDP 49152–65535 AND TCP 443 on the host firewall for TURN relay.

**Warning signs:** ICE gathering finishes but only host candidates appear (no srflx or relay candidates). Browser DevTools → Network → WebRTC internals shows no relay candidates.

**Phase to address:** Phase 1 (infrastructure). Validate with `turnutils_uclient` in CI before any WebRTC testing.

---

### Pitfall 5: WebRTC ICE Gathering Timeout Multiplies With Each Unreachable STUN Server

**What goes wrong:** Chrome's ICE gathering times out after 10 seconds per unreachable network interface × number of STUN servers configured. If you list 3 STUN servers and the client has 3 network interfaces, gathering takes up to 90 seconds before completing (or times out entirely). The game appears frozen on "Connecting..."

**Why it happens:** ICE gathers candidates from every network interface for every ICE server listed. When a STUN server is unreachable (or behind a blocked firewall), Chrome waits the full timeout before moving to the next candidate. Timeouts multiply multiplicatively.

**Consequences:** Connection setup takes 30–90 seconds on devices with VPNs, corporate interfaces, or misconfigured STUN. Users assume the platform is broken and leave.

**Prevention:**
- Use only 1–2 STUN/TURN servers in `iceServers`. Redundancy does not help and multiplies timeouts.
- Always include a TURN server with both UDP and TCP transport, plus TLS-443 (`turns:` prefix). This alone prevents ICE failure in >99% of cases.
- Set `iceCandidatePoolSize` to 0 to disable pre-gathering until the connection is actually needed.
- Validate TURN server reachability with a lightweight pre-check before beginning ICE.
- Monitor `iceGatheringState` and show progressive UI feedback rather than a static spinner.

**Warning signs:** ICE gathering state stays at `gathering` for >5 seconds. No relay candidates appear in `icecandidate` events.

**Phase to address:** Phase 2 (WebRTC data channel). Test on real device behind NAT before declaring working.

---

### Pitfall 6: TURN Credential Staleness — Token Expires Between Page Load and Connection

**What goes wrong:** TURN credentials are generated at page load time with a TTL (e.g., 1 hour). On a game session that starts later — or when the user reopens a tab — the credentials have expired. WebRTC uses the credentials during ICE and silently fails to gather relay candidates. The error appears as "ICE failed" with no indication of why.

**Why it happens:** TURN short-term credentials use HMAC-SHA1 with a shared secret. The `username` encodes the expiry timestamp. coturn rejects credentials where `expiry < now`. If credentials are generated at page load but the WebRTC connection starts 70 minutes later, they are stale.

**Consequences:** Silent ICE failure only in relay scenarios. Direct P2P still works. Bug is intermittent and time-dependent — hard to reproduce in dev.

**Prevention:**
- Generate TURN credentials at connection-start (when the user clicks "Join Game"), not at page load.
- Use a generous TTL (24 hours) for casual game sessions; regenerate on reconnect.
- Implement a server endpoint `/turn-credentials` that the client calls immediately before `new RTCPeerConnection()`.
- Never embed static TURN credentials in client-side code or environment variables shipped to the browser.

**Warning signs:** ICE fails after sessions that span >1 hour; works fine in short integration tests; relay candidates missing from ICE candidate log.

**Phase to address:** Phase 1 (signaling server) + Phase 2 (client WebRTC setup).

---

## Moderate Pitfalls

---

### Pitfall 7: WebRTC Data Channel Ordered=True Trap Causes HOL Blocking

**What goes wrong:** If `RTCDataChannel` is created with `ordered: true` (the default), SCTP retransmits lost packets in order. A single lost IMU packet at 60Hz causes all subsequent packets to queue behind it until the retransmit succeeds — adding 20–200ms of artificial latency. The sensor stream becomes jittery under even mild packet loss.

**Why it happens:** SCTP's reliable ordered delivery is the wrong primitive for sensor data. At 60Hz, a lost packet is already stale before retransmission can complete. You want fire-and-forget semantics.

**Prevention:**
- Create all sensor data channels with `{ ordered: false, maxRetransmits: 0 }`. This gives true UDP semantics.
- Use a separate reliable ordered channel (default) for control messages only (join, disconnect, game events).
- Never use `maxPacketLifeTime` as a substitute for `maxRetransmits: 0` — they have different semantics and `maxPacketLifeTime` can still queue multiple packets.

**Warning signs:** Smooth sensor data in zero-loss conditions, then sudden bursts of stale data during any packet loss. Visible as hitching in the 3D visualization.

**Phase to address:** Phase 2 (phone client data channel creation). Enforce via code review checklist.

---

### Pitfall 8: Madgwick Beta Too High Causes Jitter; Too Low Causes Slow Convergence

**What goes wrong:** The Madgwick filter beta parameter controls how aggressively accelerometer/magnetometer data corrects gyro integration. Too high (>0.3 in a browser context): every accelerometer noise spike corrupts the quaternion — the 3D object shakes even when the phone is still. Too low (<0.05): gyro drift accumulates for 10–30 seconds before the filter corrects it — cold start orientation is wrong.

**Why it happens:** The optimal beta depends on sensor noise characteristics, which vary significantly between phone models. A beta tuned for a Pixel produces a jittery result on an older Android with a noisier IMU.

**Prevention:**
- Start with beta=0.1 as a neutral default for phone-class IMUs in a browser context.
- Expose beta as a runtime-configurable parameter in the SDK (not hardcoded) so game developers can tune per their use case.
- Use a higher beta (0.2–0.3) during the first 2 seconds after initialization to accelerate cold-start convergence, then ramp down to the steady-state value.
- Document that beta=0 means gyro-only (pure integration, drifts immediately).

**Warning signs:** Visible jitter on a stationary phone (beta too high); orientation takes >10 seconds to stabilize after a quick flip (beta too low).

**Phase to address:** Phase 2 (phone client sensor fusion).

---

### Pitfall 9: ZUPT False Triggers During Mid-Motion Pause

**What goes wrong:** ZUPT detects "phone is stationary" by checking if all acceleration magnitudes are below a threshold for N consecutive samples. If a player pauses mid-throw, holds their arm steady for 100ms (e.g., aiming gesture), ZUPT fires and resets the velocity estimate to zero. The position tracking then shows a discontinuous jump when motion resumes.

**Why it happens:** A single fixed threshold cannot distinguish intentional stillness from a momentary pause mid-gesture. The false-alarm probability is high for natural human motion patterns.

**Prevention:**
- Use an adaptive threshold: compute variance over a sliding window, not just mean magnitude. Stillness has low variance; a pause mid-gesture has higher variance.
- Apply a minimum stillness duration (>300ms) before triggering ZUPT — human gestural pauses are typically shorter.
- Feed gesture-window events from the game layer into ZUPT: if an "arm swing started" event is active, suppress ZUPT.
- Accept that sustained position tracking beyond ~2–3 seconds is unreliable; design game interactions around short gesture windows, not continuous dead-reckoning.

**Warning signs:** Position jumps when players pause mid-gesture. Dead-reckoning trails that snap to zero then jump.

**Phase to address:** Phase 2 (phone client Kalman/ZUPT layer).

---

### Pitfall 10: GC Pauses from Per-Packet Object Allocation at 60Hz

**What goes wrong:** Each incoming WebRTC data channel message triggers a callback. If the handler creates new objects (`new Float32Array(...)`, object literals for parsed state, etc.) at 60Hz × N players, the JS garbage collector accumulates heap pressure rapidly. The GC pause (5–50ms) manifests as a dropped frame or sensor processing hiccup visible as a position jump in the 3D view.

**Why it happens:** At 60Hz with 4 players, that is 240 allocations/second just for incoming packets. Modern V8 GC handles this reasonably, but the allocation of the `ArrayBuffer` or `DataView` wrapper on each message payload is avoidable and compounds with Three.js's own render-loop allocations.

**Prevention:**
- Pre-allocate a ring buffer of `Float32Array` views backed by a single `SharedArrayBuffer` or static `ArrayBuffer`. Reuse views by pointer advancement.
- Parse incoming binary packets into pre-allocated structs (plain object with numeric fields reused across frames) rather than creating new objects per packet.
- Decode MessagePack/binary packets using a pool-aware decoder — avoid libraries that allocate per-call.
- Separate the sensor processing loop from the Three.js render loop: buffer incoming sensor packets in a ring buffer, then drain them at `requestAnimationFrame` time. This decouples 60Hz sensor updates from 60Hz render work.
- Profile with Chrome DevTools Memory tab under load (3–4 simulated players) before Phase 3 is "done."

**Warning signs:** Visible jank every 2–5 seconds under multi-player load; DevTools Performance flamechart shows GC events aligning with frame drops.

**Phase to address:** Phase 2 (packet handling) + Phase 3 (desktop rendering loop).

---

### Pitfall 11: iOS Screen Lock Kills WebRTC Connection and Sensor Events

**What goes wrong:** When the iOS player locks their screen (or the screen auto-dims), Safari suspends the WebKit rendering process. Both the WebRTC data channel connection and all sensor event listeners are terminated. The desktop shows the player frozen at their last position. There is no disconnect event — the ICE connection silently times out after ~30 seconds.

**Why it happens:** iOS aggressively suspends background browser processes to conserve battery. Unlike Android Chrome (which exempts real-time connection tabs from throttling), iOS WebKit does not have the same exemption for WebRTC data channels in PWA contexts.

**Prevention:**
- Implement a heartbeat from phone to desktop every 5 seconds over the data channel. Desktop treats 10 seconds of silence as a disconnect.
- Show a "keep screen on" warning in the phone UI with a `Wake Lock API` call (`navigator.wakeLock.request('screen')`). Wake Lock is supported in iOS 16.4+.
- Design game UX to handle a player going offline gracefully — freeze their in-game avatar, show a "reconnecting" indicator on desktop.
- On reconnect (ICE renegotiation), re-request `DeviceMotionEvent.requestPermission` if the permission state is lost (it usually persists, but verify).

**Warning signs:** Player appears frozen after ~30 seconds of no phone activity; no explicit disconnect event fires.

**Phase to address:** Phase 2 (phone client) + Phase 3 (desktop reconnection handling).

---

### Pitfall 12: SDK Leaking Raw IMU Without Drift Context

**What goes wrong:** The SDK exposes a raw `position` field from dead-reckoning. Game developers see `{ x, y, z }` and treat it like room-scale tracking — building game mechanics that require sustained position accuracy. Within 5 seconds, drift renders the position meaningless. The developer files bugs against the SDK, not their game design.

**Why it happens:** Dead-reckoning from double-integrated phone IMU drifts quadratically. Developers unfamiliar with IMU limitations assume browser position data is comparable to VR headset tracking.

**Prevention:**
- Name the position layer explicitly in the SDK API: `deadReckoningPosition` (not `position`). Reserve `position` for a future high-confidence layer.
- Add JSDoc/TypeScript comments on every position field: `/** Dead-reckoning estimate. Drifts ~0.5m/sec. Use gestureDisplacement for game interactions. */`
- Expose a `driftConfidence` scalar (0–1) that decreases as time since last ZUPT reset increases. Let games fade out position-dependent visuals as confidence drops.
- In the demo game, do NOT use raw dead-reckoning position — use orientation (quaternion) and `gestureDisplacement` only. This sets the right precedent.
- Add a SDK flag `experimental_rawPosition: true` that gate-keeps the raw dead-reckoning field. Default off.

**Warning signs:** Game developers asking "why does position drift in a circle after 10 seconds?" — correct answer is the SDK design should prevent this question.

**Phase to address:** Phase 4 (SDK design). Non-negotiable before any third-party developer touches the API.

---

### Pitfall 13: DTLS Handshake Failure From Algorithm Mismatch After Browser Update

**What goes wrong:** After a Chrome version update, existing WebRTC connections start failing at the DTLS handshake stage. The error is `DTLS handshake failed` with no further details in the browser. This happens because Chrome tightened DTLS certificate algorithm requirements (e.g., dropping SHA-1, mandating SHA-256 or higher for fingerprints).

**Why it happens:** Chrome 124+ deprecated SHA-1 in DTLS certificate fingerprints. Server-side WebRTC implementations or TURN servers compiled with older OpenSSL may still emit SHA-1 fingerprints in SDP offers. The mismatch causes a hard handshake failure.

**Prevention:**
- Ensure coturn is compiled with OpenSSL 1.1.1+ and configured to use `fingerprint-algorithm=SHA-256`.
- Verify SDP offers from the Rust WebRTC layer include SHA-256 fingerprints. Test SDP output after each coturn/browser upgrade.
- Add a canary test: spin up a headless Chrome (Playwright), connect two peers, verify data channel opens — run this in CI against the deployed stack.
- Monitor WebRTC internals (`chrome://webrtc-internals`) for DTLS state transitions in integration tests.

**Warning signs:** Sudden increase in ICE/DTLS failures after a Chrome update; `Failed to set remote description` errors in signaling log.

**Phase to address:** Phase 1 (infrastructure) + ongoing: add CI regression test.

---

### Pitfall 14: Magnetometer Interference Corrupting Absolute Orientation

**What goes wrong:** `DeviceOrientationEvent.alpha` (compass heading / absolute yaw) is driven by the magnetometer. Metal phone cases, magnetic phone mounts, wallet cases with magnetic clips, or nearby electronics (laptop chargers, speakers) corrupt the magnetometer reading. The result is a slowly rotating or oscillating yaw that has nothing to do with how the player is holding the phone.

**Why it happens:** Phone magnetometers are MEMS devices sensitive to nearby ferromagnetic materials and electromagnetic fields. "Hard iron" distortion (constant offset from permanent magnets) and "soft iron" distortion (field shape distortion from nearby metal) both affect the heading.

**Consequences:** The Madgwick filter uses magnetometer data to correct yaw drift. If the magnetometer is corrupted, the filter's yaw correction pulls the quaternion toward wrong north, producing slow uncontrollable rotation in the game.

**Prevention:**
- Do not rely on absolute yaw (north-relative heading) for game mechanics. Use relative rotation (delta quaternion from a reset reference frame) instead.
- Let players "recalibrate" with a button that resets the reference quaternion to the current orientation — equivalent to re-zeroing the controller.
- In the Madgwick filter, make magnetometer weighting configurable. For high-interference environments, reduce or eliminate magnetometer feedback (gyro+accel only: relative quaternion, no absolute yaw).
- Document in the SDK: `orientation.absoluteYaw` is unreliable in environments with magnetic interference; prefer `orientation.relativeYaw` (delta from last reset).

**Warning signs:** Alpha value from `DeviceOrientationEvent` drifts slowly in one direction even when the phone is stationary on a flat surface.

**Phase to address:** Phase 2 (sensor fusion design).

---

## Minor Pitfalls

---

### Pitfall 15: setTimeout Drift at 60Hz — Use requestAnimationFrame or Device Sensor Rate

**What goes wrong:** If sensor data is processed or relayed on a `setTimeout(fn, 16)` loop on the phone client, the actual interval drifts to 20–40ms due to timer clamping in background contexts and browser timer resolution. The sensor stream appears to deliver 25–30Hz instead of 60Hz.

**Prevention:**
- Do not use `setTimeout` for sensor cadence. `DeviceMotionEvent` fires at the native OS rate (60–100Hz) — use the event directly as the clock.
- On the desktop rendering loop, use `requestAnimationFrame` exclusively. Never `setInterval` for render work.
- Timestamps in sensor packets should come from `performance.now()` at event fire time (not at send time).

**Phase to address:** Phase 2 (phone client send loop).

---

### Pitfall 16: DTLS Role Negotiation Deadlock (Both Sides Act as Client)

**What goes wrong:** In WebRTC, one peer must take the DTLS client role and the other the server role. If the signaling exchange completes incorrectly (e.g., both sides create offers without a proper answer exchange), both peers send a DTLS `ClientHello`, neither receives a `ServerHello`, and the DTLS handshake deadlocks.

**Prevention:**
- Follow the standard offer/answer model strictly. The initiator sends the offer (DTLS client), the responder sends the answer (DTLS server). Never create an offer from both sides simultaneously.
- Use the WebTransport signaling server to enforce offer/answer ordering — the server assigns roles explicitly.
- Test signaling with simultaneous join edge cases (two phones join in the same millisecond).

**Phase to address:** Phase 2 (signaling / WebRTC handshake).

---

### Pitfall 17: Kalman Filter Divergence on Sudden High Acceleration

**What goes wrong:** If a player throws their phone (or simulates a throw gesture), the Kalman filter's process noise covariance assumptions are violated. The filter treats the sudden acceleration as sensor noise and damps it out — the dead-reckoning position update is too conservative. Alternatively, if process noise is set high, the filter over-trusts the acceleration and diverges on sustained gestures.

**Prevention:**
- Use the ZUPT reset as a hard state reset, not just a measurement update. When ZUPT fires, set position covariance to near-zero rather than updating it probabilistically.
- For gesture displacement windows, bypass the Kalman estimator entirely: record raw linear acceleration during the gesture window and integrate once — expose this as `gestureDisplacement`, not as a Kalman state.
- Limit dead-reckoning to short windows (< 1 second) and explicitly mark longer estimates as low-confidence.

**Phase to address:** Phase 2 (Kalman/ZUPT design).

---

### Pitfall 18: Three.js Render Loop Blocking Sensor Data Application

**What goes wrong:** The Three.js `setAnimationLoop` callback runs synchronously on the main thread. If scene complexity or post-processing causes the render to exceed 16ms (the 60fps budget), sensor updates queued behind it are delayed. The orientation applied to the 3D object lags behind what the player sees — the disconnect is felt as latency even if the network latency is sub-10ms.

**Prevention:**
- Keep the Three.js scene simple in the demo. No expensive post-processing, no physics simulation in the render loop.
- Apply sensor quaternion updates at the start of the animation loop callback, before any draw calls.
- Profile with Chrome DevTools > Performance tab under load before declaring the demo "done." Flag any frame that exceeds 16ms.
- Consider using a Web Worker for sensor data processing (accumulate in SharedArrayBuffer) so GC in the worker does not affect the main thread render loop.

**Phase to address:** Phase 3 (desktop Three.js client).

---

### Pitfall 19: WebTransport QUIC NAT Timeout During Idle Signaling

**What goes wrong:** After a game session ends (but the connection is kept alive for reconnection), the QUIC connection sits idle. NAT devices (especially home routers) garbage-collect UDP state after 30–60 seconds of inactivity. The QUIC connection appears alive on both endpoints but packets are silently dropped. QUIC's connection migration recovers from NAT rebinding, but only if the client sends a packet first — a long idle means the NAT table entry is gone before migration can trigger.

**Prevention:**
- Send a keep-alive PING frame over the WebTransport connection every 20 seconds during idle periods.
- The wtransport Rust server should be configured with `keep_alive_interval: Duration::from_secs(20)`.
- Design reconnection to be fast (< 2 seconds): the game room state is lightweight (session IDs + ICE restart), so a full reconnect is preferable to fighting NAT timeouts.

**Phase to address:** Phase 1 (server configuration) + Phase 4 (SDK reconnection logic).

---

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation |
|-------------|---------------|------------|
| Phase 1: WebTransport server TLS setup | Self-signed cert rejected by browser (Pitfall 1) | Use Chrome dev flag in dev; Let's Encrypt in prod |
| Phase 1: coturn Docker Compose | Bridge networking breaks STUN (Pitfall 4) | Use `network_mode: host`; validate with turnutils_uclient |
| Phase 1: TURN credentials in signaling | Stale credentials causing ICE failure (Pitfall 6) | Generate credentials at connection-start, not page-load |
| Phase 2: Phone client sensor bootstrap | iOS permission prompt not on gesture (Pitfall 3b) | Add "Grant Motion Access" button before any sensor code |
| Phase 2: WebRTC data channel creation | ordered=true default causes HOL blocking (Pitfall 7) | Enforce `{ ordered: false, maxRetransmits: 0 }` in PR checklist |
| Phase 2: Madgwick filter tuning | Beta too high/low (Pitfall 8) | Start beta=0.1; expose as runtime param; ramp at cold start |
| Phase 2: ZUPT detector | False triggers mid-gesture (Pitfall 9) | Use variance + duration threshold; suppress during gesture windows |
| Phase 2: iOS screen lock | Silent sensor death + connection timeout (Pitfall 11) | Wake Lock API + heartbeat + graceful disconnect |
| Phase 2: Sensor send loop | setTimeout drift at 60Hz (Pitfall 15) | Use DeviceMotionEvent as clock, not setTimeout |
| Phase 3: Desktop rendering | GC from per-packet allocation (Pitfall 10) | Pre-allocate ring buffer; profile under 4-player load |
| Phase 3: Three.js loop vs sensor | Render blocking sensor update (Pitfall 18) | Apply quaternion at start of RAF callback; keep scene simple |
| Phase 4: SDK API design | Leaking raw IMU as `position` (Pitfall 12) | Name it `deadReckoningPosition`; add `driftConfidence` scalar; gate behind flag |
| Phase 4: SDK orientation types | Euler angles causing gimbal lock (SDK design) | Expose quaternions only; never expose raw Euler angles in public API |
| Ongoing: QUIC network compatibility | UDP blocked; no fallback (Pitfall 2) | WebSocket fallback for signaling; TURN TCP 443 for data relay |
| Ongoing: DTLS algorithm drift | Chrome update breaks fingerprints (Pitfall 13) | CI canary test with Playwright; coturn SHA-256 config |

---

## Sources

- [WebTransport TLS and QUIC certificate requirements — moq.dev](https://moq.dev/blog/tls-and-quic/)
- [WebTransport TLS Cert — security-union/videocall-rs wiki](https://github.com/security-union/videocall-rs/wiki/WebTransport---TLS-Cert)
- [WebKit Features for Safari 26.4 — WebTransport shipped](https://webkit.org/blog/17862/webkit-features-for-safari-26-4/)
- [iOS Safari WebTransport Apple Developer Forums](https://developer.apple.com/forums/thread/764486)
- [WebTransport is now Baseline — webrtc.ventures](https://webrtc.ventures/2026/04/webtransport-is-now-baseline-what-it-means-for-real-time-media/)
- [iOS 13 DeviceMotionEvent.requestPermission — DEV Community](https://dev.to/li/how-to-requestpermission-for-devicemotion-and-deviceorientation-events-in-ios-13-46g2)
- [Debugging ICE Failed in Production — expressturn blog](https://blog.expressturn.com/debugging-ice-failed-webrtc)
- [coturn Docker host networking — metered.ca guide](https://www.metered.ca/blog/running-coturn-in-docker-a-step-by-step-guide/)
- [coturn security configuration — enablesecurity.com](https://www.enablesecurity.com/blog/coturn-security-configuration-guide/)
- [WebRTC data channels — MDN](https://developer.mozilla.org/en-US/docs/Web/API/WebRTC_API/Using_data_channels)
- [SCTP interleaving HOL blocking fix — pion.ly](https://pion.ly/blog/sctp-interleaving/)
- [Madgwick filter AHRS documentation](https://ahrs.readthedocs.io/en/latest/filters/madgwick.html)
- [ZUPT adaptive threshold — PMC article](https://pmc.ncbi.nlm.nih.gov/articles/PMC6210023/)
- [QUIC UDP blocking corporate firewall — Chromium proto-quic group](https://groups.google.com/a/chromium.org/g/proto-quic/c/ksokVdwXfQ0)
- [QUIC connection migration — quic-go docs](https://quic-go.net/docs/quic/connection-migration/)
- [GC pressure and sensor allocation — W3C sensors issue](https://github.com/w3c/sensors/issues/153)
- [Chrome background tab throttling exceptions — Chrome developers](https://developers.google.com/web/updates/2017/03/background_tabs)
- [wtransport Rust crate](https://docs.rs/wtransport/latest/wtransport/)
- [Gimbal lock and quaternions — Wikipedia](https://en.wikipedia.org/wiki/Gimbal_lock)
- [DTLS handshake failure Chrome 124](https://milestonesys.my.site.com/developer/s/question/0D5bH0000065pjOSAQ/chrome-124-webrtc-dtls-handshake-failure)
- [Three.js render loop performance — three.js forum](https://discourse.threejs.org/t/i-got-requestanimationframe-handler-took-n-s/67819)
