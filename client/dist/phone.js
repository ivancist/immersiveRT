/* phone.js — ImmersiveRT phone client: permission gate, WebTransport signaling,
 * WebRTC data channels, Wake Lock, heartbeat.
 * Plain script (no ES module imports); all browser built-in APIs only.
 */

'use strict';

// ── State ────────────────────────────────────────────────────────────────────
var transport = null;          // WebTransport instance
var myId = null;               // client UUID (generated on permission grant)
var roomCode = null;
var mySlot = null;
var myUsername = null;
var iceServers = [];
var peers = [];                // [{id, slot, username}] from pair-ack
var peerConnections = new Map(); // peerId → { pc, dc }
var openChannelCount = 0;
var wakeLockSentinel = null;
var heartbeatInterval = null;

// ── View helper ──────────────────────────────────────────────────────────────
function showView(id) {
  ['view-permission', 'view-connecting', 'view-active',
   'view-ended', 'view-error-denied', 'view-error-pair'].forEach(function(v) {
    var el = document.getElementById(v);
    if (el) { el.hidden = true; }
  });
  var target = document.getElementById(id);
  if (target) { target.hidden = false; }
}

// ── iOS Permission Gate (D-12) ────────────────────────────────────────────────
// CRITICAL: DeviceMotionEvent.requestPermission() MUST be the first statement
// inside the synchronous click handler — any async boundary (await, .then,
// setTimeout) before the call breaks the iOS gesture stack (RESEARCH Pitfall 1).
function attachGrantButton() {
  var btn = document.getElementById('btn-grant-motion');
  if (!btn) { return; }

  btn.addEventListener('click', function() {
    if (typeof DeviceMotionEvent !== 'undefined' &&
        typeof DeviceMotionEvent.requestPermission === 'function') {
      // iOS 13+: requestPermission() MUST be the first call — no await before it.
      DeviceMotionEvent.requestPermission()
        .then(function(result) {
          if (result === 'granted') {
            showView('view-connecting');
            startPhoneClient();
          } else {
            showView('view-error-denied');
          }
        })
        .catch(function() {
          showView('view-error-denied');
        });
    } else {
      // Android / non-iOS: no permission gate needed.
      // Show "Activating..." briefly (UI-SPEC Android transient), then advance.
      btn.disabled = true;
      btn.textContent = 'Activating…';
      setTimeout(function() {
        showView('view-connecting');
        startPhoneClient();
      }, 100);
    }
  });
}

// ── WebTransport client bootstrap ────────────────────────────────────────────
async function startPhoneClient() {
  myId = crypto.randomUUID();

  // Read pairing token from query string (D-14, PHONE-01).
  var token = new URLSearchParams(location.search).get('token');
  if (!token) {
    showView('view-error-pair');
    return;
  }

  var wtUrl = 'https://' + location.hostname + ':4433';
  try {
    transport = new WebTransport(wtUrl);
    await transport.ready;
  } catch (err) {
    console.error('[WT] Connection failed:', err);
    showView('view-error-pair');
    return;
  }

  // MUST start listening for server pushes BEFORE sending anything — if we send
  // first and the server pushes before we start listening, the stream is queued
  // in incomingBidirectionalStreams but never consumed (RESEARCH Pitfall 2).
  listenForServerPushes(transport);

  // Register with the server so it can route messages to us by myId.
  try {
    await sendWtMessage(transport, { type: 'register', from: myId, to: '', payload: {} });
  } catch (err) {
    console.error('[WT] Register failed:', err);
    showView('view-error-pair');
    return;
  }

  // Pair: exchange the HMAC token for the desktop roster + ICE servers.
  var pairResp;
  try {
    pairResp = await sendWtRequest(transport, {
      type: 'pair', from: myId, to: '', payload: { token: token }
    });
  } catch (err) {
    console.error('[WT] Pair request failed:', err);
    showView('view-error-pair');
    return;
  }

  if (!pairResp || pairResp.type !== 'pair-ack') {
    var reason = (pairResp && pairResp.payload && pairResp.payload.reason) || '';
    document.getElementById('pair-error-body').textContent =
      reason ? reason : 'This pairing link is invalid or has expired.';
    showView('view-error-pair');
    return;
  }

  // Store session state from pair-ack payload (D-04 roster).
  var payload = pairResp.payload || {};
  mySlot     = payload.slot || null;
  roomCode   = payload.room_code || '';
  myUsername = payload.username || '';
  iceServers = Array.isArray(payload.ice_servers) ? payload.ice_servers : [];
  peers      = Array.isArray(payload.peers) ? payload.peers : [];

  // Pre-populate the connecting counter total (Y in "X/Y channels").
  var chanTotalEl = document.getElementById('chan-total');
  if (chanTotalEl) { chanTotalEl.textContent = peers.length; }

  console.log('[Phone] Paired: slot=' + mySlot + ' room=' + roomCode +
              ' peers=' + peers.length + ' iceServers=' + iceServers.length);

  // Fan out one unreliable WebRTC data channel to every desktop in the room (PHONE-03).
  // openChannelToPeer triggers onnegotiationneeded which auto-creates and sends the offer.
  peers.forEach(function(p) { openChannelToPeer(p.id); });
}

// ── WebTransport helpers ──────────────────────────────────────────────────────

// One-shot request: open a bidi stream, write the envelope, read the full response.
async function sendWtRequest(transport, envelope) {
  var stream = await transport.createBidirectionalStream();
  var writer = stream.writable.getWriter();
  await writer.write(new TextEncoder().encode(JSON.stringify(envelope)));
  await writer.close();

  var reader = stream.readable.getReader();
  var buf = new Uint8Array(0);
  while (true) {
    var chunk = await reader.read();
    if (chunk.done) { break; }
    var merged = new Uint8Array(buf.length + chunk.value.length);
    merged.set(buf);
    merged.set(chunk.value, buf.length);
    buf = merged;
  }
  return JSON.parse(new TextDecoder().decode(buf));
}

// Fire-and-forget send: open a bidi stream, write the envelope, drain the readable
// so back-pressure cannot stall the connection (no response expected from server).
async function sendWtMessage(transport, envelope) {
  var stream = await transport.createBidirectionalStream();
  var writer = stream.writable.getWriter();
  await writer.write(new TextEncoder().encode(JSON.stringify(envelope)));
  await writer.close();
  // Drain readable to release back-pressure on the server's write side.
  var reader = stream.readable.getReader();
  while (true) {
    var chunk = await reader.read();
    if (chunk.done) { break; }
  }
}

// ── WebRTC fan-out ───────────────────────────────────────────────────────────
// Opens one unreliable data channel to a desktop peer (PHONE-03, D-05).
// channel options { ordered: false, maxRetransmits: 0 } are locked — do not change.
// The offer is produced by onnegotiationneeded + setLocalDescription (no manual
// createOffer call — RESEARCH Pattern 3, anti-pattern: do not call createOffer manually).
function openChannelToPeer(peerId) {
  // CR-03: Detect reconnect BEFORE peerConnections.set overwrites the entry.
  // dc.onopen fires asynchronously — by then the entry is already overwritten,
  // so the previous readyState check inside onopen was always false (D-17).
  var prev = peerConnections.get(peerId);
  var isRecovery = prev && prev.dc &&
    (prev.dc.readyState === 'closed' || prev.dc.readyState === 'closing');

  var pc = new RTCPeerConnection({ iceServers: iceServers });
  // D-05 locked: both options must be present and exactly these values.
  var dc = pc.createDataChannel('sensor', { ordered: false, maxRetransmits: 0 });
  // WR-01: tracks whether this channel reached open so dc.onclose can guard
  // against double-decrement (e.g. closePeer + unexpected close).
  var channelIsOpen = false;

  pc.onnegotiationneeded = function() {
    pc.setLocalDescription()  // no args — auto-creates offer and sets local description
      .then(function() {
        return sendWtMessage(transport, {
          type: 'offer', from: myId, to: peerId, payload: pc.localDescription
        });
      })
      .catch(function(err) {
        console.warn('[WebRTC] onnegotiationneeded failed for ' + peerId + ':', err);
      });
  };

  pc.onicecandidate = function(evt) {
    if (!evt.candidate) { return; }
    sendWtMessage(transport, {
      type: 'ice-candidate', from: myId, to: peerId, payload: evt.candidate
    }).catch(function(err) {
      console.warn('[WebRTC] ice-candidate send failed:', err);
    });
  };

  dc.onopen = function() {
    channelIsOpen = true;  // WR-01
    openChannelCount++;
    updateConnectingUI();
    // Notify server that this channel is open (D-08 phone half).
    sendWtMessage(transport, {
      type: 'rtc-channel-ready', from: myId, to: '', payload: { with: peerId }
    }).catch(function(err) {
      console.warn('[WebRTC] rtc-channel-ready send failed:', err);
    });
    // If this peer was previously lost and we re-opened the channel, notify recovery (D-17).
    // isRecovery was captured synchronously before peerConnections.set overwrote the entry.
    if (isRecovery) {
      sendPhoneState({ state: 'channel-recovered', with: peerId });
    }
  };

  dc.onclose = function() {
    // WR-01: only decrement if the channel actually reached open state; guards against
    // double-decrement when dc.onclose fires after an intentional close that already
    // decremented in closePeer.
    if (channelIsOpen) {
      channelIsOpen = false;
      if (openChannelCount > 0) { openChannelCount--; }
      updateConnectingUI();
    }
    // Notify server and room desktops that this channel was lost (D-17).
    sendPhoneState({ state: 'channel-lost', with: peerId });
  };

  peerConnections.set(peerId, { pc: pc, dc: dc });
}

// Updates the X/Y channel counter in the connecting view (D-10).
function updateConnectingUI() {
  var chanOpenEl = document.getElementById('chan-open');
  if (chanOpenEl) { chanOpenEl.textContent = String(openChannelCount); }
  // chan-total is pre-populated in startPhoneClient; no update needed here.
}

// Called when server fires player-ready: transition to active view (D-11).
// Sets active-status-dot to connected and populates username/room/channel count.
// Wake Lock, heartbeat, and motion indicator are Plan 03 (stubs below).
function onPlayerReady(msg) {
  // Capture username from player-ready payload (desktop player's name for this slot).
  var payload = (msg && msg.payload) ? msg.payload : {};
  if (payload.username) { myUsername = payload.username; }

  showView('view-active');

  var usernameEl  = document.getElementById('active-username');
  var roomEl      = document.getElementById('active-room');
  var channelsEl  = document.getElementById('active-channels');
  var dotEl       = document.getElementById('active-status-dot');

  if (usernameEl) { usernameEl.textContent = myUsername; }
  if (roomEl)     { roomEl.textContent = roomCode; }
  if (channelsEl) {
    channelsEl.textContent = openChannelCount + '/' + peers.length + ' connected';
  }
  if (dotEl) {
    dotEl.classList.remove('dot--hold', 'dot--empty');
    dotEl.classList.add('dot--connected');
  }

  // Wake Lock after player-ready (D-15 — never during connecting).
  requestWakeLock();
  // Heartbeat every 5s so the server never prematurely evicts this slot (D-19, PHONE-06).
  startHeartbeat();
  // Motion indicator for devicemotion magnitude (D-11 / UI-SPEC).
  startMotionIndicator();
}

// ── Server push listener ──────────────────────────────────────────────────────
// Called WITHOUT await at the top level — runs as a concurrent background task.
// Must loop over incomingBidirectionalStreams to avoid back-pressure stall
// (RESEARCH Pitfall 2: not consuming this iterator blocks the server's ability
// to open new streams, which can deadlock the connection).
async function listenForServerPushes(transport) {
  try {
    for await (var stream of transport.incomingBidirectionalStreams) {
      var reader = stream.readable.getReader();
      var buf = new Uint8Array(0);
      try {
        while (true) {
          var chunk = await reader.read();
          if (chunk.done) { break; }
          var merged = new Uint8Array(buf.length + chunk.value.length);
          merged.set(buf);
          merged.set(chunk.value, buf.length);
          buf = merged;
        }
        var msg = JSON.parse(new TextDecoder().decode(buf));
        handleServerPush(msg).catch(function(err) {
          console.warn('[WebRTC] handleServerPush error:', err);
        });
      } catch (err) {
        console.warn('[WT] Malformed server push or stream error:', err);
      }
    }
  } catch (err) {
    // incomingBidirectionalStreams iterator ends when the transport closes.
    console.debug('[WT] Server push listener ended:', err);
  }
}

async function handleServerPush(msg) {
  var entry;
  switch (msg.type) {
    case 'pair-error':
      // Server rejected a re-pair attempt after initial connection.
      showView('view-error-pair');
      break;

    case 'player-ready':
      onPlayerReady(msg);
      break;

    case 'answer':
      entry = peerConnections.get(msg.from);
      if (!entry) {
        console.warn('[WebRTC] answer from unknown peer:', msg.from);
        break;
      }
      await entry.pc.setRemoteDescription(msg.payload);
      break;

    case 'ice-candidate':
      entry = peerConnections.get(msg.from);
      if (!entry) { break; }
      await entry.pc.addIceCandidate(msg.payload);
      break;

    // ── Dynamic peer mesh (D-06/D-07) ──
    case 'peer-joined':
      // Server pushed a new desktop — grow the WebRTC mesh.
      // WR-02: guard against malformed payload to prevent silent TypeError.
      if (!msg.payload || !msg.payload.peer || typeof msg.payload.peer.id !== 'string') {
        console.warn('[WT] peer-joined: malformed payload', msg.payload);
        break;
      }
      openChannelToPeer(msg.payload.peer.id);
      break;
    case 'peer-left':
      // Desktop departed — close and remove the matching connection.
      closePeer(msg.payload.peer_id);
      break;

    default:
      console.warn('[WT] Unknown server push type:', msg.type);
  }
}

// ── Session durability (Plan 03) ─────────────────────────────────────────────

// D-15/D-16 Wake Lock: keep the screen on after player-ready.
// Feature-detected — older Safari (pre-16.4) lacks navigator.wakeLock.
// Rejection is swallowed (Pitfall 4 — low battery / power-save mode).
async function requestWakeLock() {
  if (!('wakeLock' in navigator)) { return; } // graceful degradation
  try {
    wakeLockSentinel = await navigator.wakeLock.request('screen');
    wakeLockSentinel.addEventListener('release', function() {
      sendPhoneState({ state: 'wake-lock-lost' });
      wakeLockSentinel = null;
    });
    sendPhoneState({ state: 'wake-lock-active' });
  } catch (err) {
    // Low battery / power-save / document not visible — silently degrade.
    console.debug('[WakeLock] Request rejected:', err.message);
  }
}

// D-19 Heartbeat: send every 5s so server knows the phone is still alive (PHONE-06).
// CR-04: guard against null transport (fires before startPhoneClient or after transport closes).
function startHeartbeat() {
  heartbeatInterval = setInterval(function() {
    if (!transport) { return; }
    sendWtMessage(transport, { type: 'heartbeat', from: myId, to: '', payload: {} })
      .catch(function(e) { console.debug('[HB] heartbeat send failed:', e); });
  }, 5000);
}

// D-17 Phone state: relay a state transition to the server (server relays to desktops).
function sendPhoneState(statePayload) {
  sendWtMessage(transport, { type: 'phone-state', from: myId, to: '', payload: statePayload });
}

// D-11 / UI-SPEC: pulse the motion-indicator element when acceleration magnitude exceeds
// 0.5 m/s² (linear) or differs from ~1G (gravity-inclusive). Return to idle after 300ms.
var _motionIndicatorTimer = null;
function startMotionIndicator() {
  window.addEventListener('devicemotion', function(e) {
    // Prefer linear_acceleration (gravity-subtracted); fall back to accelerationIncludingGravity.
    var a = e.accelerationIncludingGravity;
    if (!a) { return; }
    var mag = Math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
    var indicator = document.getElementById('motion-indicator');
    if (!indicator) { return; }

    // Threshold: magnitude > 0.5 m/s² above ~1G (gravity ~9.8) = 10.3; use 10.3 to match spec.
    // UI-SPEC specifies linear-acceleration > 0.5 m/s²; since we use gravity-inclusive,
    // 9.8 (rest) + 0.5 = 10.3. Toggle active when phone is in motion above this threshold.
    if (mag > 10.3) {
      indicator.classList.add('motion-active');
      clearTimeout(_motionIndicatorTimer);
      _motionIndicatorTimer = setTimeout(function() {
        indicator.classList.remove('motion-active');
      }, 300);
    }
  });
}

// D-06/D-07: close and remove a peer connection from the mesh.
// WR-01: openChannelCount decrement is handled by dc.onclose (guarded by channelIsOpen).
function closePeer(peerId) {
  var entry = peerConnections.get(peerId);
  if (!entry) { return; }
  try { entry.pc.close(); } catch (e) { /* already closed */ }
  peerConnections.delete(peerId);
  updateConnectingUI();
}

// D-16 self-heal + state reporting on visibility change.
// On foreground: resend heartbeat, re-request Wake Lock, re-open any closed channels.
// On background: notify server the phone is backgrounded.
// CR-04: guard against null transport — handler is registered at script-load time
// but transport is null until startPhoneClient() succeeds.
document.addEventListener('visibilitychange', function() {
  if (!transport) { return; }  // not yet connected
  if (document.visibilityState === 'visible') {
    sendPhoneState({ state: 'foreground' });
    // Immediate heartbeat on foreground return resets the 65s server timer (D-19).
    sendWtMessage(transport, { type: 'heartbeat', from: myId, to: '', payload: {} })
      .catch(function(e) { console.debug('[HB] foreground heartbeat failed:', e); });
    // Re-acquire Wake Lock (released automatically when tab goes to background).
    requestWakeLock();
    // Re-open any channels that closed while backgrounded (D-16 self-heal).
    peerConnections.forEach(function(entry, peerId) {
      if (entry.dc.readyState === 'closed' || entry.dc.readyState === 'closing') {
        peerConnections.delete(peerId);
        openChannelToPeer(peerId);
      }
    });
  } else {
    sendPhoneState({ state: 'background' });
  }
});

// ── Bootstrap ────────────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', function() {
  attachGrantButton();
  showView('view-permission');
});
