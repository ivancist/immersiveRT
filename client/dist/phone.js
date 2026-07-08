/* phone.js — ImmersiveRT phone client: permission gate, signaling,
 * WebRTC data channels, Wake Lock, heartbeat.
 * Plain script (no ES module imports); all browser built-in APIs only.
 *
 * Signaling transport priority:
 *   1. WebTransport (QUIC/HTTP3, port 4433) — preferred; uses .getReader() on
 *      incomingBidirectionalStreams because iOS WebKit does not implement
 *      Symbol.asyncIterator on ReadableStream (for-await-of crashes pre-26.4).
 *   2. WebSocket (WSS, port 9090) — automatic fallback if WT is unsupported,
 *      unavailable, or fails to connect.
 */

'use strict';

// ── Transport state ───────────────────────────────────────────────────────────
var transport = null;    // WebTransport if useWt
var ws = null;           // WebSocket if !useWt
var useWt = false;       // set true when WT connect succeeds
var wsReady = false;     // WS open + registered
var myId = null;
var roomCode = null;
var mySlot = null;
var myUsername = null;
var iceServers = [];
var peers = [];                // [{id, slot, username}] from pair-ack
var peerConnections = new Map(); // peerId → { pc, dc, flagClose }
var openChannelCount = 0;
var wakeLockSentinel = null;
var heartbeatInterval = null;
var registered = false;  // true once register ack confirmed; guards sendPhoneState
var reconnectToken = null; // from pair-ack / join-ack; used for WT-drop WS reconnect
var _reconnecting = false; // true during attemptReconnect loop; suppresses ws.onclose → view-ended

// Promise resolvers for WS pair / reconnect request/response.
var _pairResolve = null;
var _pairReject = null;
var _reconnectResolve = null;
var _reconnectReject = null;

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
            // Request Wake Lock here, while still in the user-gesture context.
            // iOS rejects navigator.wakeLock.request() if called outside a gesture.
            requestWakeLock();
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
      btn.disabled = true;
      btn.textContent = 'Activating…';
      setTimeout(function() {
        showView('view-connecting');
        startPhoneClient();
      }, 100);
    }
  });
}

// ── Signaling abstraction ─────────────────────────────────────────────────────
// All send calls go through signalSend so the rest of the code is transport-agnostic.
function signalSend(type, to, payload) {
  if (useWt && transport) {
    sendWtMessage(transport, { type: type, from: myId, to: to || '', payload: payload || {} });
  } else {
    sendWsMsg(type, to, payload);
  }
}

// ── WebTransport helpers ──────────────────────────────────────────────────────

// One-shot request: open a bidi stream, write the envelope, read the full response.
async function sendWtRequest(t, envelope) {
  var stream = await t.createBidirectionalStream();
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

// Fire-and-forget send: open a bidi stream, write the envelope, drain the readable.
async function sendWtMessage(t, envelope) {
  var stream = await t.createBidirectionalStream();
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

// Server-push listener using .getReader() instead of for-await-of.
// iOS WebKit pre-26.4 does not implement Symbol.asyncIterator on ReadableStream,
// so `for await (const s of transport.incomingBidirectionalStreams)` throws
// "undefined is not a function". The .getReader() API works on all versions.
async function listenForServerPushes(t) {
  phoneLog('push-listener-start (WT)');
  try {
    var bidiReader = t.incomingBidirectionalStreams.getReader();
    while (true) {
      var result = await bidiReader.read();
      if (result.done) { break; }
      phoneLog('push-stream-rx');
      processWtPush(result.value); // process concurrently, do not await
    }
    phoneLog('push-listener-done');
  } catch (err) {
    phoneLog('push-listener-err:' + (err && err.message || String(err)));
    console.debug('[WT] Server push listener ended:', err);
  }
}

function processWtPush(stream) {
  var reader = stream.readable.getReader();
  var buf = new Uint8Array(0);
  (function readNext() {
    reader.read().then(function(chunk) {
      if (chunk.done) {
        try {
          var msg = JSON.parse(new TextDecoder().decode(buf));
          phoneLog('push-msg type=' + msg.type);
          handleServerPush(msg).catch(function(err) {
            console.warn('[WT] handleServerPush error:', err);
            phoneLog('push-handle-err:' + err.message);
          });
        } catch (e) {
          phoneLog('push-parse-err:' + e.message);
        }
        return;
      }
      var merged = new Uint8Array(buf.length + chunk.value.length);
      merged.set(buf);
      merged.set(chunk.value, buf.length);
      buf = merged;
      readNext();
    }).catch(function(err) {
      phoneLog('push-read-err:' + err.message);
    });
  })();
}

// ── WebSocket helpers (fallback) ──────────────────────────────────────────────
function connectPhoneWS(onReadyCallback) {
  var url = 'wss://' + location.hostname + ':9090';
  phoneLog('ws-connect (fallback)');
  ws = new WebSocket(url);

  ws.onopen = function() {
    if (!myId) { myId = crypto.randomUUID(); }  // preserve myId across reconnects
    ws.send(JSON.stringify({ type: 'register', from: myId, to: '', payload: {} }));
    wsReady = true;
    registered = true;
    phoneLog('ws-open id=' + myId.slice(0, 8));
    if (onReadyCallback) { onReadyCallback(); }
  };

  ws.onmessage = function(evt) {
    var msg;
    try { msg = JSON.parse(evt.data); } catch (e) { return; }
    onPhoneWsMessage(msg);
  };

  ws.onclose = function() {
    wsReady = false;
    registered = false;
    phoneLog('ws-closed');
    if (_pairReject) { _pairReject('ws-closed'); _pairResolve = null; _pairReject = null; }
    if (_reconnectReject) { _reconnectReject('ws-closed'); _reconnectResolve = null; _reconnectReject = null; }
    clearInterval(heartbeatInterval);
    heartbeatInterval = null;
    // Don't show view-ended during a managed reconnect loop — attemptReconnect controls the UI.
    if (!_reconnecting) { showView('view-ended'); }
  };

  ws.onerror = function() { phoneLog('ws-err'); };
}

function sendWsMsg(type, to, payload) {
  if (!ws || ws.readyState !== WebSocket.OPEN) { return; }
  ws.send(JSON.stringify({ type: type, from: myId, to: to || '', payload: payload || {} }));
}

function onPhoneWsMessage(msg) {
  if (msg.type === 'pair-ack') {
    if (_pairResolve) { _pairResolve(msg); _pairResolve = null; _pairReject = null; }
    return;
  }
  if (msg.type === 'pair-error') {
    var reason = (msg.payload && msg.payload.reason) || 'pair-error';
    if (_pairReject) { _pairReject(reason); _pairResolve = null; _pairReject = null; }
    return;
  }
  if (msg.type === 'join-ack') {
    if (_reconnectResolve) { _reconnectResolve(msg); _reconnectResolve = null; _reconnectReject = null; }
    return;
  }
  if (msg.type === 'join-error') {
    var errReason = (msg.payload && msg.payload.reason) || 'join-error';
    if (_reconnectReject) { _reconnectReject(errReason); _reconnectResolve = null; _reconnectReject = null; }
    return;
  }
  handleServerPush(msg).catch(function(err) {
    console.warn('[WS] handleServerPush error:', err);
    phoneLog('ws-handle-err:' + (err && err.message || err));
  });
}

// ── WT lifecycle helpers ──────────────────────────────────────────────────────

function setupTransportClosedHandler(t) {
  function onWtClose() {
    if (_reconnecting) { return; } // already in reconnect loop
    registered = false;
    clearInterval(heartbeatInterval);
    heartbeatInterval = null;
    transport = null;
    useWt = false;
    phoneLog('WT-closed → reconnect');
    attemptReconnect();
  }
  t.closed.then(onWtClose).catch(onWtClose);
}

// Attempt WT reconnect: create a fresh transport, register, send reconnect request.
// Returns the join-ack/join-error envelope, or { reason: 'wt-net' } on network failure.
// Commits to global `transport` only on success; closes the temp transport otherwise.
// listenForServerPushes is started AFTER success to avoid stale listener noise.
async function tryWtReconnect() {
  var wtUrl = 'https://' + location.hostname + ':4433';
  var t = null;
  try {
    phoneLog('reconnect-WT-try');
    t = new WebTransport(wtUrl);
    await Promise.race([
      t.ready,
      new Promise(function(_, rej) { setTimeout(function() { rej(new Error('timeout')); }, 5000); })
    ]);
    if (typeof t.incomingBidirectionalStreams.getReader !== 'function') {
      throw new Error('getReader not supported');
    }
    // Register and reconnect BEFORE starting push listener — avoids push-listener-err
    // noise from a short-lived transport that closes before the reconnect is confirmed.
    await sendWtMessage(t, { type: 'register', from: myId, to: '', payload: {} });
    var resp = await sendWtRequest(t, {
      type: 'reconnect', from: myId, to: '', payload: { reconnect_token: reconnectToken }
    });
    if (resp && resp.type === 'join-ack') {
      transport = t;
      useWt = true;
      listenForServerPushes(t); // start listener only after commit
      setupTransportClosedHandler(t);
      return resp;
    }
    // Reconnect request failed (slot_not_held etc.) — don't commit this transport.
    try { t.close(); } catch (e) {}
    return resp;
  } catch (err) {
    phoneLog('reconnect-WT-net:' + (err && (err.message || err.name) || String(err)));
    if (t) { try { t.close(); } catch (e) {} }
    return { type: 'join-error', payload: { reason: 'wt-net' } };
  }
}

// ── Phone client bootstrap ────────────────────────────────────────────────────
async function startPhoneClient() {
  var token = new URLSearchParams(location.search).get('token');
  if (!token) { showView('view-error-pair'); return; }

  // ── Attempt 1: WebTransport ───────────────────────────────────────────────
  var wtOk = false;
  if (typeof WebTransport !== 'undefined') {
    var wtUrl = 'https://' + location.hostname + ':4433';
    phoneLog('WT-try ' + wtUrl);
    try {
      transport = new WebTransport(wtUrl);
      await transport.ready;

      // Verify getReader is available before committing to WT path.
      if (typeof transport.incomingBidirectionalStreams.getReader !== 'function') {
        throw new Error('incomingBidirectionalStreams.getReader not supported');
      }

      // Start push listener BEFORE sending anything (avoids dropped pushes).
      listenForServerPushes(transport);

      // Register.
      myId = crypto.randomUUID();
      await sendWtMessage(transport, { type: 'register', from: myId, to: '', payload: {} });
      registered = true;
      phoneLog('WT-registered id=' + myId.slice(0, 8));

      useWt = true;
      wtOk = true;

      setupTransportClosedHandler(transport);
    } catch (err) {
      phoneLog('WT-failed:' + err.message + ' → WS fallback');
      console.warn('[WT] Connect failed, falling back to WS:', err);
      transport = null;
      useWt = false;
    }
  } else {
    phoneLog('WT-unsupported → WS fallback');
  }

  // ── Attempt 2: WebSocket fallback ─────────────────────────────────────────
  if (!wtOk) {
    try {
      await new Promise(function(resolve, reject) {
        var t = setTimeout(function() { reject(new Error('WS timeout')); }, 10000);
        connectPhoneWS(function() { clearTimeout(t); resolve(); });
      });
    } catch (err) {
      phoneLog('WS-failed:' + err.message);
      document.getElementById('pair-error-body').textContent =
        'Cannot reach the server. Make sure this device trusts the TLS certificate.';
      showView('view-error-pair');
      return;
    }
  }

  // ── Pair ──────────────────────────────────────────────────────────────────
  var pairResp;
  if (useWt) {
    try {
      pairResp = await sendWtRequest(transport, {
        type: 'pair', from: myId, to: '', payload: { token: token }
      });
    } catch (err) {
      phoneLog('pair-req-err:' + err.message);
      document.getElementById('pair-error-body').textContent =
        'Server connection dropped during pairing.';
      showView('view-error-pair');
      return;
    }
  } else {
    pairResp = await new Promise(function(resolve, reject) {
      _pairResolve = resolve;
      _pairReject = reject;
      sendWsMsg('pair', '', { token: token });
    }).catch(function(reason) {
      return { type: 'pair-error', payload: { reason: reason } };
    });
  }

  if (!pairResp || pairResp.type !== 'pair-ack') {
    var errReason = (pairResp && pairResp.payload && pairResp.payload.reason) || '';
    document.getElementById('pair-error-body').textContent =
      errReason || 'This pairing link is invalid or has expired.';
    showView('view-error-pair');
    return;
  }

  var payload = pairResp.payload || {};
  mySlot        = payload.slot || null;
  roomCode      = payload.room_code || '';
  myUsername    = payload.username || '';
  iceServers    = Array.isArray(payload.ice_servers) ? payload.ice_servers : [];
  peers         = Array.isArray(payload.peers) ? payload.peers : [];
  reconnectToken = payload.reconnect_token || null;

  var chanTotalEl = document.getElementById('chan-total');
  if (chanTotalEl) { chanTotalEl.textContent = peers.length; }

  phoneLog('paired slot=' + mySlot + ' peers=' + peers.length +
           ' ice=' + iceServers.length + ' via=' + (useWt ? 'WT' : 'WS'));
  console.log('[Phone] Paired: slot=' + mySlot + ' room=' + roomCode +
              ' peers=' + peers.length + ' iceServers=' + iceServers.length +
              ' transport=' + (useWt ? 'WebTransport' : 'WebSocket'));

  // Fan out one unreliable WebRTC data channel to every desktop in the room.
  peers.forEach(function(p) { openChannelToPeer(p.id); });
}

// ── WT-drop reconnect via WebSocket ──────────────────────────────────────────
// Called when the WebTransport connection drops (iOS background kills QUIC).
// Attempts to restore the session using the reconnect_token obtained at pair time.
// On success: restores registered state, re-opens any closed WebRTC channels.
// On failure: shows view-ended.
function showReconnecting() {
  var dotEl = document.getElementById('active-status-dot');
  var chanEl = document.getElementById('active-channels');
  if (dotEl) { dotEl.classList.remove('dot--connected', 'dot--empty'); dotEl.classList.add('dot--hold'); }
  if (chanEl) { chanEl.textContent = 'Reconnecting…'; }
}

function showReconnected() {
  var dotEl = document.getElementById('active-status-dot');
  var chanEl = document.getElementById('active-channels');
  if (dotEl) { dotEl.classList.remove('dot--hold', 'dot--empty'); dotEl.classList.add('dot--connected'); }
  if (chanEl) { chanEl.textContent = openChannelCount + '/' + peers.length + ' connected'; }
}

async function attemptReconnect() {
  if (!reconnectToken) { showView('view-ended'); return; }
  _reconnecting = true;
  showReconnecting();
  phoneLog('reconnect-try');

  // 3s initial delay: iOS network is unstable immediately after backgrounding.
  // Connections open then die within ~50ms for the first 20-30s. Waiting 3s
  // before the first attempt skips most of that window.
  await new Promise(function(r) { setTimeout(r, 3000); });

  // Outer loop retries all transports until slot becomes Disconnected (server-side
  // WT relay may stay alive ~19s; heartbeat-miss fires ~65s after last heartbeat).
  // Each iteration: try WT first (preferred for games), fall to WS on network failure.
  // slot_not_held skips WS (both transports get same result) and waits 10s.
  var maxAttempts = 13;
  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    var resp = null;

    // ── Try WT first ─────────────────────────────────────────────────────────
    if (typeof WebTransport !== 'undefined') {
      resp = await tryWtReconnect();
      if (resp && resp.type === 'join-ack') {
        // committed inside tryWtReconnect (transport + useWt set)
      } else {
        var wtReason = (resp && resp.payload && resp.payload.reason) || '';
        if (wtReason === 'slot_not_held') {
          // WS would give the same result — skip it, just wait.
          phoneLog('reconnect-wait:' + attempt + ' slot_not_held');
          if (attempt < maxAttempts) {
            await new Promise(function(r) { setTimeout(r, 10000); });
            continue;
          }
          _reconnecting = false; reconnectToken = null; showView('view-ended'); return;
        }
        // WT network/init failure — fall through to WS
        resp = null;
      }
    }

    // ── Try WS if WT didn't succeed ──────────────────────────────────────────
    if (!resp || resp.type !== 'join-ack') {
      if (!ws || ws.readyState === WebSocket.CLOSED || ws.readyState === WebSocket.CLOSING) {
        if (ws && ws.readyState !== WebSocket.CLOSED) { ws.close(); }
        var wsOk = await new Promise(function(resolve) {
          var t = setTimeout(function() { resolve(false); }, 10000);
          connectPhoneWS(function() { clearTimeout(t); resolve(true); });
        });
        if (!wsOk || !ws || ws.readyState !== WebSocket.OPEN) {
          phoneLog('reconnect-ws-fail n=' + attempt);
          if (attempt < maxAttempts) {
            await new Promise(function(r) { setTimeout(r, 10000); });
            continue;
          }
          _reconnecting = false; reconnectToken = null; showView('view-ended'); return;
        }
      }

      if (!ws || ws.readyState !== WebSocket.OPEN) {
        phoneLog('reconnect-ws-not-ready n=' + attempt);
        if (attempt < maxAttempts) {
          await new Promise(function(r) { setTimeout(r, 10000); });
          continue;
        }
        _reconnecting = false; reconnectToken = null; showView('view-ended'); return;
      }

      resp = await new Promise(function(resolve, reject) {
        _reconnectResolve = resolve;
        _reconnectReject = reject;
        sendWsMsg('reconnect', '', { reconnect_token: reconnectToken });
      }).catch(function(reason) {
        return { type: 'join-error', payload: { reason: String(reason) } };
      });
    }

    // ── Handle response ───────────────────────────────────────────────────────
    if (resp && resp.type === 'join-ack') {
      var rp = resp.payload || {};
      reconnectToken = rp.reconnect_token || null;
      if (Array.isArray(rp.ice_servers)) { iceServers = rp.ice_servers; }
      if (!useWt) { useWt = false; } // WS path: already false
      registered = true;
      _reconnecting = false;
      showReconnected();
      phoneLog('reconnect-ok slot=' + mySlot + ' n=' + attempt + ' via=' + (useWt ? 'WT' : 'WS'));

      var toReopen = [];
      peerConnections.forEach(function(entry, peerId) {
        if (entry.dc.readyState === 'closed' || entry.dc.readyState === 'closing') {
          toReopen.push(peerId);
        }
      });
      toReopen.forEach(function(peerId) {
        peerConnections.delete(peerId);
        openChannelToPeer(peerId);
      });

      startHeartbeat();
      return;
    }

    var errReason = (resp && resp.payload && resp.payload.reason) || '';
    var retryable = errReason === 'slot_not_held' || errReason === 'ws-closed' || errReason === 'wt-net';
    if (retryable && attempt < maxAttempts) {
      phoneLog('reconnect-wait:' + attempt + ' ' + errReason);
      await new Promise(function(r) { setTimeout(r, 10000); });
      continue;
    }

    phoneLog('reconnect-fail:' + errReason + ' n=' + attempt);
    _reconnecting = false;
    reconnectToken = null;
    showView('view-ended');
    return;
  }

  // Exhausted all attempts.
  _reconnecting = false;
  reconnectToken = null;
  showView('view-ended');
}

// ── WebRTC fan-out ───────────────────────────────────────────────────────────
function openChannelToPeer(peerId) {
  // CR-03: Detect reconnect BEFORE peerConnections.set overwrites the entry.
  var prev = peerConnections.get(peerId);
  var isRecovery = prev && prev.dc &&
    (prev.dc.readyState === 'closed' || prev.dc.readyState === 'closing');

  var ptag = peerId.slice(0, 8);
  phoneLog('openCh p=' + ptag + ' ice=' + iceServers.length);
  var pc = new RTCPeerConnection({ iceServers: iceServers });
  // D-05 locked: both options must be present and exactly these values.
  var dc = pc.createDataChannel('sensor', { ordered: false, maxRetransmits: 0 });

  pc.onconnectionstatechange = function() {
    phoneLog('conn=' + pc.connectionState + ' p=' + ptag);
    console.info('[WebRTC] connectionState=' + pc.connectionState + ' peer=' + ptag);
  };
  pc.oniceconnectionstatechange = function() {
    phoneLog('ice=' + pc.iceConnectionState + ' p=' + ptag);
    console.info('[WebRTC] iceConnectionState=' + pc.iceConnectionState + ' peer=' + ptag);
  };
  pc.onicegatheringstatechange = function() {
    phoneLog('gather=' + pc.iceGatheringState + ' p=' + ptag);
  };

  var channelIsOpen = false;  // WR-01
  var intentionalClose = false;  // WR-11

  pc.onnegotiationneeded = function() {
    pc.setLocalDescription()
      .then(function() {
        var offerSetup = (pc.localDescription && pc.localDescription.sdp || '').match(/a=setup:(\S+)/);
        phoneLog('offer a=setup:' + (offerSetup ? offerSetup[1] : '?') + ' p=' + ptag);
        signalSend('offer', peerId, pc.localDescription);
      })
      .catch(function(err) {
        console.warn('[WebRTC] onnegotiationneeded failed for ' + peerId + ':', err);
        phoneLog('offer-err:' + err.message);
      });
  };

  pc.onicecandidate = function(evt) {
    if (!evt.candidate) {
      phoneLog('cand-done p=' + ptag);
      return;
    }
    phoneLog('cand ' + (evt.candidate.type || 'host') + ' p=' + ptag);
    signalSend('ice-candidate', peerId, evt.candidate);
  };

  dc.onopen = function() {
    channelIsOpen = true;  // WR-01
    phoneLog('DC-OPEN p=' + ptag);
    openChannelCount++;
    updateConnectingUI();
    signalSend('rtc-channel-ready', '', { with: peerId });
    if (isRecovery) { sendPhoneState({ state: 'channel-recovered', with: peerId }); }
  };

  dc.onclose = function() {
    if (intentionalClose) { return; }  // WR-11
    if (channelIsOpen) {
      channelIsOpen = false;
      if (openChannelCount > 0) { openChannelCount--; }
      updateConnectingUI();
    }
    sendPhoneState({ state: 'channel-lost', with: peerId });
  };

  peerConnections.set(peerId, { pc: pc, dc: dc, flagClose: function() { intentionalClose = true; } });
}

function updateConnectingUI() {
  var chanOpenEl = document.getElementById('chan-open');
  if (chanOpenEl) { chanOpenEl.textContent = String(openChannelCount); }
}

function onPlayerReady(msg) {
  var payload = (msg && msg.payload) ? msg.payload : {};
  if (payload.username) { myUsername = payload.username; }

  showView('view-active');

  var usernameEl = document.getElementById('active-username');
  var roomEl     = document.getElementById('active-room');
  var channelsEl = document.getElementById('active-channels');
  var dotEl      = document.getElementById('active-status-dot');

  if (usernameEl) { usernameEl.textContent = myUsername; }
  if (roomEl)     { roomEl.textContent = roomCode; }
  if (channelsEl) { channelsEl.textContent = openChannelCount + '/' + peers.length + ' connected'; }
  if (dotEl) {
    dotEl.classList.remove('dot--hold', 'dot--empty');
    dotEl.classList.add('dot--connected');
  }

  requestWakeLock();
  startHeartbeat();
  startMotionIndicator();
}

// ── Server message handler ────────────────────────────────────────────────────
async function handleServerPush(msg) {
  var entry;
  switch (msg.type) {
    case 'pair-error':
      showView('view-error-pair');
      break;

    case 'player-ready':
      onPlayerReady(msg);
      break;

    case 'answer':
      entry = peerConnections.get(msg.from);
      if (!entry) {
        console.warn('[WebRTC] answer from unknown peer:', msg.from);
        phoneLog('answer unknown peer=' + (msg.from || '').slice(0, 8));
        break;
      }
      var answerSetup = ((msg.payload && msg.payload.sdp) || '').match(/a=setup:(\S+)/);
      phoneLog('answer a=setup:' + (answerSetup ? answerSetup[1] : '?') +
               ' from=' + (msg.from || '').slice(0, 8));
      await entry.pc.setRemoteDescription(msg.payload);
      break;

    case 'ice-candidate':
      entry = peerConnections.get(msg.from);
      if (!entry) { break; }
      phoneLog('rx-cand from=' + (msg.from || '').slice(0, 8));
      await entry.pc.addIceCandidate(msg.payload);
      break;

    case 'peer-joined':
      if (!msg.payload || !msg.payload.peer || typeof msg.payload.peer.id !== 'string') {
        console.warn('[signaling] peer-joined: malformed payload', msg.payload);
        break;
      }
      openChannelToPeer(msg.payload.peer.id);
      break;

    case 'peer-left':
      closePeer(msg.payload.peer_id);
      break;

    case 'session-ended':
      clearInterval(heartbeatInterval);
      heartbeatInterval = null;
      showView('view-ended');
      break;

    default:
      console.warn('[signaling] Unknown push type:', msg.type);
  }
}

// ── Session durability ────────────────────────────────────────────────────────

async function requestWakeLock() {
  if (!('wakeLock' in navigator)) { return; }
  try {
    wakeLockSentinel = await navigator.wakeLock.request('screen');
    wakeLockSentinel.addEventListener('release', function() {
      sendPhoneState({ state: 'wake-lock-lost' });
      wakeLockSentinel = null;
    });
    sendPhoneState({ state: 'wake-lock-active' });
  } catch (err) {
    console.debug('[WakeLock] Request rejected:', err.message);
  }
}

function startHeartbeat() {
  heartbeatInterval = setInterval(function() {
    signalSend('heartbeat', '', {});
  }, 5000);
}

function sendPhoneState(statePayload) {
  if (!registered) { return; }
  signalSend('phone-state', '', statePayload);
}

var _motionIndicatorTimer = null;
function startMotionIndicator() {
  window.addEventListener('devicemotion', function(e) {
    var a = e.linearAcceleration || e.accelerationIncludingGravity;
    if (!a) { return; }
    var mag = Math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
    var indicator = document.getElementById('motion-indicator');
    if (!indicator) { return; }
    var threshold = e.linearAcceleration ? 0.5 : 10.3;
    if (mag > threshold) {
      indicator.classList.add('motion-active');
      clearTimeout(_motionIndicatorTimer);
      _motionIndicatorTimer = setTimeout(function() {
        indicator.classList.remove('motion-active');
      }, 300);
    }
  });
}

function closePeer(peerId) {
  var entry = peerConnections.get(peerId);
  if (!entry) { return; }
  if (entry.flagClose) { entry.flagClose(); }
  try { entry.pc.close(); } catch (e) { /* already closed */ }
  peerConnections.delete(peerId);
  if (openChannelCount > 0) { openChannelCount--; }
  updateConnectingUI();
}

document.addEventListener('visibilitychange', function() {
  if (document.visibilityState === 'visible') {
    if (!registered) {
      // Signaling dropped while backgrounded (WT killed by iOS). attemptReconnect
      // is triggered by transport.closed, but the two events can race. If registered
      // is still false here and reconnectToken is set, kick reconnect explicitly.
      if (reconnectToken && !ws) { attemptReconnect(); }
      return;
    }
    sendPhoneState({ state: 'foreground' });
    signalSend('heartbeat', '', {});
    requestWakeLock();
    peerConnections.forEach(function(entry, peerId) {
      if (entry.dc.readyState === 'closed' || entry.dc.readyState === 'closing') {
        peerConnections.delete(peerId);
        openChannelToPeer(peerId);
      }
    });
  } else {
    if (!registered) { return; }
    sendPhoneState({ state: 'background' });
  }
});

// ── On-screen debug log (collapsible) ────────────────────────────────────────
var _logEl = null;
var _logBody = null;
var _logCollapsed = false;

function initOnScreenLog() {
  _logEl = document.createElement('div');
  _logEl.style.cssText =
    'position:fixed;bottom:0;left:0;right:0;z-index:9999;' +
    'background:rgba(0,0,0,0.85);border-top:2px solid #0f0;' +
    'font:11px/1.5 monospace;';

  var header = document.createElement('div');
  header.style.cssText =
    'display:flex;justify-content:space-between;align-items:center;' +
    'padding:3px 8px;cursor:pointer;color:#0f0;user-select:none;';
  header.innerHTML = '<span>📱 debug</span><span id="_log_toggle">▼</span>';
  header.addEventListener('click', function() {
    _logCollapsed = !_logCollapsed;
    _logBody.style.display = _logCollapsed ? 'none' : 'block';
    document.getElementById('_log_toggle').textContent = _logCollapsed ? '▲' : '▼';
  });

  _logBody = document.createElement('div');
  _logBody.style.cssText =
    'max-height:40vh;overflow-y:auto;padding:4px 8px;' +
    'color:#0f0;white-space:pre-wrap;word-break:break-all;';

  _logEl.appendChild(header);
  _logEl.appendChild(_logBody);
  document.body.appendChild(_logEl);
}

function phoneLog(msg) {
  if (!_logBody) { return; }
  var now = new Date();
  var ts = String(now.getMinutes()).padStart(2, '0') + ':' +
            String(now.getSeconds()).padStart(2, '0') + '.' +
            String(now.getMilliseconds()).padStart(3, '0');
  var line = document.createElement('div');
  line.textContent = ts + ' ' + msg;
  _logBody.appendChild(line);
  while (_logBody.children.length > 40) { _logBody.removeChild(_logBody.firstChild); }
  if (!_logCollapsed) { _logBody.scrollTop = _logBody.scrollHeight; }
}

// ── Bootstrap ────────────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', function() {
  initOnScreenLog();
  phoneLog('loaded');
  attachGrantButton();
  showView('view-permission');
});
