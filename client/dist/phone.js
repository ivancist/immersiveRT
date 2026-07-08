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
        handleServerPush(msg);
      } catch (err) {
        console.warn('[WT] Malformed server push or stream error:', err);
      }
    }
  } catch (err) {
    // incomingBidirectionalStreams iterator ends when the transport closes.
    console.debug('[WT] Server push listener ended:', err);
  }
}

function handleServerPush(msg) {
  switch (msg.type) {
    case 'pair-error':
      // Server rejected a re-pair attempt after initial connection.
      showView('view-error-pair');
      break;

    // ── Plan 02 stubs — filled in when WebRTC channels are implemented ──
    case 'peer-joined':
      // TODO(04-02): openChannelToPeer(msg.peer.id)
      break;
    case 'peer-left':
      // TODO(04-02): closePeer(msg.peer_id)
      break;
    case 'player-ready':
      // TODO(04-02): onPlayerReady(msg)
      break;
    case 'offer':
      // TODO(04-02): setRemoteDescription on the matching RTCPeerConnection
      break;
    case 'answer':
      // TODO(04-02): setRemoteDescription on the matching RTCPeerConnection
      break;
    case 'ice-candidate':
      // TODO(04-02): addIceCandidate on the matching RTCPeerConnection
      break;

    default:
      console.warn('[WT] Unknown server push type:', msg.type);
  }
}

// ── Bootstrap ────────────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', function() {
  attachGrantButton();
  showView('view-permission');
});
