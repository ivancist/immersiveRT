/* phone.ts — ImmersiveRT phone client: permission gate, signaling,
 * WebRTC data channels, Wake Lock, heartbeat.
 * Strict-TypeScript ES module (migrated from client/public/phone.js, Plan 05-02).
 *
 * Plan 06 additions: hold-still calibration scene (D-08), OS-orientation thin
 * sensor pipeline (PHONE-04, PHONE-05) — broadcastPacket + startSensorPipeline.
 *
 * Signaling transport priority:
 *   1. WebTransport (QUIC/HTTP3, port 4433) — preferred; uses .getReader() on
 *      incomingBidirectionalStreams because iOS WebKit does not implement
 *      Symbol.asyncIterator on ReadableStream (for-await-of crashes pre-26.4).
 *   2. WebSocket (WSS, port 9090) — automatic fallback if WT is unsupported,
 *      unavailable, or fails to connect.
 */

// ── Sensor pipeline imports (Plan 06/07) ─────────────────────────────────────
import { encodePacket, _packetBuf, runCalibration, safeFloat } from './sensor/encode';
import { eulerToQuat, updateMadgwick, rampBeta } from './sensor/orientation';
import { ZUPTDetector } from './sensor/zupt';
import { Kalman1D } from './sensor/kalman';
import { updateOverlay } from './sensor/devOverlay';
import type { SensorPacket, Quaternion, Vector3 } from './types';

// Marks this file as an ES module (prevents global-scope collision with room.ts).
export {};

// ── Transport state ───────────────────────────────────────────────────────────
let transport: WebTransport | null = null;  // WebTransport if useWt
let ws: WebSocket | null = null;            // WebSocket if !useWt
let useWt = false;                           // set true when WT connect succeeds
let wsReady = false;                         // WS open + registered
let myId: string | null = null;
let roomCode: string | null = null;
let mySlot: number | null = null;
let myUsername: string | null = null;
let iceServers: RTCIceServer[] = [];
let peers: Array<{ id: string; slot: number; username: string }> = [];
const peerConnections = new Map<string, { pc: RTCPeerConnection; dc: RTCDataChannel; channelOpen: boolean; flagClose: () => void }>();
let openChannelCount = 0;
let wakeLockSentinel: WakeLockSentinel | null = null;
let heartbeatInterval: ReturnType<typeof setInterval> | null = null;
let registered = false;       // true once register ack confirmed; guards sendPhoneState
let reconnectToken: string | null = null;  // from pair-ack / join-ack; used for WT-drop WS reconnect
let _reconnecting = false;    // true during attemptReconnect loop; suppresses ws.onclose → view-ended
let sensorPipelineRunning = false; // true once startSensorPipeline has been called; guards re-calibration on desktop reconnect
let desktopLeavingIntentionally = false; // set by DC "peer-leaving" message; cleared after peer-left handled

// ── Sensor pipeline state (Plan 06/07) ───────────────────────────────────────
let sessionStart = 0;                              // ms epoch at pipeline start
let seq = 0;                                       // monotonic packet counter
let primaryQuat: Quaternion = { w: 1, x: 0, y: 0, z: 0 }; // OS-fused orientation
// Calibration params.
let _calThreshold = 0;
let _calKalmanQ   = 0;

// ── Dead-reckoning bounds (Plan 07 / T-05-16) ────────────────────────────────
const POSITION_MAX = 100; // metres; bounds un-reset Kalman drift
const GESTURE_MAX  = 100; // metres; bounds gesture displacement accumulator

// ── Touch state (Plan 07 / SENS-06) ─────────────────────────────────────────
let currentTouch = { active: false, x: 0, y: 0 };
let touchListenersAttached = false;

// ── Dev source-select flag (Plan 07 / D-04) ──────────────────────────────────
let useMadgwick = false;

// Promise resolvers for WS pair / reconnect request/response.
let _pairResolve: ((msg: SignalingMessage) => void) | null = null;
let _pairReject: ((reason: string) => void) | null = null;
let _reconnectResolve: ((msg: SignalingMessage) => void) | null = null;
let _reconnectReject: ((reason: string) => void) | null = null;

// ── Shared signaling message shape ────────────────────────────────────────────
interface SignalingMessage {
  type: string;
  from?: string;
  to?: string;
  payload?: Record<string, unknown>;
}

// ── View helper ──────────────────────────────────────────────────────────────
function showView(id: string): void {
  ['view-permission', 'view-connecting', 'view-calibrating', 'view-active',
   'view-ended', 'view-error-denied', 'view-error-pair'].forEach(function(v) {
    const el = document.getElementById(v);
    if (el) { el.hidden = true; }
  });
  const target = document.getElementById(id);
  if (target) { target.hidden = false; }
}

// ── iOS Permission Gate (D-12) ────────────────────────────────────────────────
// CRITICAL: DeviceMotionEvent.requestPermission() MUST be the first statement
// inside the synchronous click handler — any async boundary (await, .then,
// setTimeout) before the call breaks the iOS gesture stack (RESEARCH Pitfall 1).
function tryLockPortrait(): void {
  if (screen.orientation && typeof (screen.orientation as ScreenOrientation & { lock?: (type: string) => Promise<void> }).lock === 'function') {
    (screen.orientation as ScreenOrientation & { lock: (type: string) => Promise<void> })
      .lock('portrait')
      .catch(function() { /* silently ignore: iOS / unsupported browsers */ });
  }
}

function tryRequestFullscreen(): void {
  const el = document.documentElement;
  if (typeof el.requestFullscreen === 'function') {
    el.requestFullscreen().catch(function() { /* silently ignore: browser policy */ });
  } else if (typeof (el as HTMLElement & { webkitRequestFullscreen?: () => Promise<void> }).webkitRequestFullscreen === 'function') {
    (el as HTMLElement & { webkitRequestFullscreen: () => Promise<void> }).webkitRequestFullscreen()
      .catch(function() { /* silently ignore */ });
  }
}

function attachGrantButton(): void {
  const btn = document.getElementById('btn-grant-motion');
  if (!btn) { return; }

  btn.addEventListener('click', function() {
    if (typeof DeviceMotionEvent !== 'undefined' &&
        typeof (DeviceMotionEvent as unknown as { requestPermission?: () => Promise<string> }).requestPermission === 'function') {
      // iOS 13+: requestPermission() MUST be the absolute first call — nothing async before it.
      (DeviceMotionEvent as unknown as { requestPermission: () => Promise<string> }).requestPermission()
        .then(function(result: string) {
          if (result === 'granted') {
            tryLockPortrait();
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
      // Android / non-iOS: IMU access implicit — button tap IS the grant.
      tryLockPortrait();
      (btn as HTMLButtonElement).disabled = true;
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
function signalSend(type: string, to: string, payload: object): void {
  if (useWt && transport) {
    sendWtMessage(transport, { type: type, from: myId ?? '', to: to || '', payload: payload as Record<string, unknown> });
  } else {
    sendWsMsg(type, to, payload);
  }
}

// ── WebTransport helpers ──────────────────────────────────────────────────────

// One-shot request: open a bidi stream, write the envelope, read the full response.
async function sendWtRequest(t: WebTransport, envelope: SignalingMessage): Promise<SignalingMessage> {
  const stream = await t.createBidirectionalStream();
  const writer = stream.writable.getWriter();
  await writer.write(new TextEncoder().encode(JSON.stringify(envelope)));
  await writer.close();

  const reader = stream.readable.getReader();
  let buf = new Uint8Array(0);
  while (true) {
    const chunk = await reader.read();
    if (chunk.done) { break; }
    const merged = new Uint8Array(buf.length + chunk.value.length);
    merged.set(buf);
    merged.set(chunk.value, buf.length);
    buf = merged;
  }
  return JSON.parse(new TextDecoder().decode(buf)) as SignalingMessage;
}

// Fire-and-forget send: open a bidi stream, write the envelope, drain the readable.
async function sendWtMessage(t: WebTransport, envelope: SignalingMessage): Promise<void> {
  const stream = await t.createBidirectionalStream();
  const writer = stream.writable.getWriter();
  await writer.write(new TextEncoder().encode(JSON.stringify(envelope)));
  await writer.close();
  // Drain readable to release back-pressure on the server's write side.
  const reader = stream.readable.getReader();
  while (true) {
    const chunk = await reader.read();
    if (chunk.done) { break; }
  }
}

// Server-push listener using .getReader() instead of for-await-of.
// iOS WebKit pre-26.4 does not implement Symbol.asyncIterator on ReadableStream,
// so `for await (const s of transport.incomingBidirectionalStreams)` throws
// "undefined is not a function". The .getReader() API works on all versions.
async function listenForServerPushes(t: WebTransport): Promise<void> {
  phoneLog('push-listener-start (WT)');
  try {
    const bidiReader = t.incomingBidirectionalStreams.getReader();
    while (true) {
      const result = await bidiReader.read();
      if (result.done) { break; }
      phoneLog('push-stream-rx');
      processWtPush(result.value); // process concurrently, do not await
    }
    phoneLog('push-listener-done');
  } catch (err) {
    phoneLog('push-listener-err:' + ((err instanceof Error ? err.message : String(err))));
    console.debug('[WT] Server push listener ended:', err);
  }
}

function processWtPush(stream: WebTransportBidirectionalStream): void {
  const reader = stream.readable.getReader();
  let buf = new Uint8Array(0);
  (function readNext() {
    reader.read().then(function(chunk) {
      if (chunk.done) {
        try {
          const msg = JSON.parse(new TextDecoder().decode(buf)) as SignalingMessage;
          phoneLog('push-msg type=' + msg.type);
          handleServerPush(msg).catch(function(err: unknown) {
            console.warn('[WT] handleServerPush error:', err);
            phoneLog('push-handle-err:' + (err instanceof Error ? err.message : String(err)));
          });
        } catch (e) {
          phoneLog('push-parse-err:' + (e instanceof Error ? e.message : String(e)));
        }
        return;
      }
      const merged = new Uint8Array(buf.length + chunk.value.length);
      merged.set(buf);
      merged.set(chunk.value, buf.length);
      buf = merged;
      readNext();
    }).catch(function(err: unknown) {
      phoneLog('push-read-err:' + (err instanceof Error ? err.message : String(err)));
    });
  })();
}

// ── WebSocket helpers (fallback) ──────────────────────────────────────────────
function connectPhoneWS(onReadyCallback: (() => void) | null): void {
  const url = 'wss://' + location.hostname + ':9090';
  phoneLog('ws-connect (fallback)');
  ws = new WebSocket(url);

  ws.onopen = function() {
    if (!myId) { myId = crypto.randomUUID(); }  // preserve myId across reconnects
    ws!.send(JSON.stringify({ type: 'register', from: myId, to: '', payload: {} }));
    wsReady = true;
    registered = true;
    phoneLog('ws-open id=' + myId.slice(0, 8));
    if (onReadyCallback) { onReadyCallback(); }
  };

  ws.onmessage = function(evt: MessageEvent) {
    let msg: SignalingMessage;
    try { msg = JSON.parse(evt.data as string) as SignalingMessage; } catch (e) { return; }
    onPhoneWsMessage(msg);
  };

  ws.onclose = function() {
    wsReady = false;
    registered = false;
    phoneLog('ws-closed');
    if (_pairReject) { _pairReject('ws-closed'); _pairResolve = null; _pairReject = null; }
    if (_reconnectReject) { _reconnectReject('ws-closed'); _reconnectResolve = null; _reconnectReject = null; }
    if (heartbeatInterval !== null) { clearInterval(heartbeatInterval); heartbeatInterval = null; }
    // Don't show view-ended during a managed reconnect loop — attemptReconnect controls the UI.
    if (!_reconnecting) { showView('view-ended'); }
  };

  ws.onerror = function() { phoneLog('ws-err'); };
}

function sendWsMsg(type: string, to: string, payload: object): void {
  if (!ws || ws.readyState !== WebSocket.OPEN) { return; }
  ws.send(JSON.stringify({ type: type, from: myId, to: to || '', payload: payload || {} }));
}

function onPhoneWsMessage(msg: SignalingMessage): void {
  if (msg.type === 'pair-ack') {
    if (_pairResolve) { _pairResolve(msg); _pairResolve = null; _pairReject = null; }
    return;
  }
  if (msg.type === 'pair-error') {
    const reason = ((msg.payload && msg.payload['reason']) as string | undefined) || 'pair-error';
    if (_pairReject) { _pairReject(reason); _pairResolve = null; _pairReject = null; }
    return;
  }
  if (msg.type === 'join-ack') {
    if (_reconnectResolve) { _reconnectResolve(msg); _reconnectResolve = null; _reconnectReject = null; }
    return;
  }
  if (msg.type === 'join-error') {
    const errReason = ((msg.payload && msg.payload['reason']) as string | undefined) || 'join-error';
    if (_reconnectReject) { _reconnectReject(errReason); _reconnectResolve = null; _reconnectReject = null; }
    return;
  }
  handleServerPush(msg).catch(function(err: unknown) {
    console.warn('[WS] handleServerPush error:', err);
    phoneLog('ws-handle-err:' + (err instanceof Error ? err.message : String(err)));
  });
}

// ── WT lifecycle helpers ──────────────────────────────────────────────────────

function setupTransportClosedHandler(t: WebTransport): void {
  function onWtClose(): void {
    if (_reconnecting) { return; } // already in reconnect loop
    registered = false;
    if (heartbeatInterval !== null) { clearInterval(heartbeatInterval); heartbeatInterval = null; }
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
async function tryWtReconnect(): Promise<SignalingMessage> {
  const wtUrl = 'https://' + location.hostname + ':4433';
  let t: WebTransport | null = null;
  try {
    phoneLog('reconnect-WT-try');
    t = new WebTransport(wtUrl);
    await Promise.race([
      t.ready,
      new Promise<never>(function(_, rej) { setTimeout(function() { rej(new Error('timeout')); }, 5000); })
    ]);
    if (typeof (t.incomingBidirectionalStreams as ReadableStream).getReader !== 'function') {
      throw new Error('getReader not supported');
    }
    // Register and reconnect BEFORE starting push listener — avoids push-listener-err
    // noise from a short-lived transport that closes before the reconnect is confirmed.
    await sendWtMessage(t, { type: 'register', from: myId ?? '', to: '', payload: {} });
    const resp = await sendWtRequest(t, {
      type: 'reconnect', from: myId ?? '', to: '', payload: { reconnect_token: reconnectToken }
    });
    if (resp && resp.type === 'join-ack') {
      transport = t;
      useWt = true;
      listenForServerPushes(t); // start listener only after commit
      setupTransportClosedHandler(t);
      return resp;
    }
    // Reconnect request failed (slot_not_held etc.) — don't commit this transport.
    try { t.close(); } catch (e) { /* ignore */ }
    return resp;
  } catch (err) {
    phoneLog('reconnect-WT-net:' + ((err instanceof Error ? (err.message || (err as Error & { name: string }).name) : String(err))));
    if (t) { try { t.close(); } catch (e) { /* ignore */ } }
    return { type: 'join-error', payload: { reason: 'wt-net' } };
  }
}

// ── Phone client bootstrap ────────────────────────────────────────────────────
async function startPhoneClient(): Promise<void> {
  const token = new URLSearchParams(location.search).get('token');
  if (!token) { showView('view-error-pair'); return; }

  // ── Attempt 1: WebTransport ───────────────────────────────────────────────
  let wtOk = false;
  if (typeof WebTransport !== 'undefined') {
    const wtUrl = 'https://' + location.hostname + ':4433';
    phoneLog('WT-try ' + wtUrl);
    try {
      transport = new WebTransport(wtUrl);
      await transport.ready;

      // Verify getReader is available before committing to WT path.
      if (typeof (transport.incomingBidirectionalStreams as ReadableStream).getReader !== 'function') {
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
      phoneLog('WT-failed:' + (err instanceof Error ? err.message : String(err)) + ' → WS fallback');
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
      await new Promise<void>(function(resolve, reject) {
        const t = setTimeout(function() { reject(new Error('WS timeout')); }, 10000);
        connectPhoneWS(function() { clearTimeout(t); resolve(); });
      });
    } catch (err) {
      phoneLog('WS-failed:' + (err instanceof Error ? err.message : String(err)));
      const pairErrorBody = document.getElementById('pair-error-body');
      if (pairErrorBody) {
        pairErrorBody.textContent =
          'Cannot reach the server. Make sure this device trusts the TLS certificate.';
      }
      showView('view-error-pair');
      return;
    }
  }

  // ── Pair ──────────────────────────────────────────────────────────────────
  let pairResp: SignalingMessage | null;
  if (useWt && transport) {
    try {
      pairResp = await sendWtRequest(transport, {
        type: 'pair', from: myId ?? '', to: '', payload: { token: token }
      });
    } catch (err) {
      phoneLog('pair-req-err:' + (err instanceof Error ? err.message : String(err)));
      const pairErrorBody = document.getElementById('pair-error-body');
      if (pairErrorBody) {
        pairErrorBody.textContent = 'Server connection dropped during pairing.';
      }
      showView('view-error-pair');
      return;
    }
  } else {
    pairResp = await new Promise<SignalingMessage>(function(resolve, reject) {
      _pairResolve = resolve;
      _pairReject = reject;
      sendWsMsg('pair', '', { token: token });
    }).catch(function(reason: string) {
      return { type: 'pair-error', payload: { reason: reason } } as SignalingMessage;
    });
  }

  if (!pairResp || pairResp.type !== 'pair-ack') {
    const errReason = (pairResp && pairResp.payload && pairResp.payload['reason'] as string) || '';
    const pairErrorBody = document.getElementById('pair-error-body');
    if (pairErrorBody) {
      pairErrorBody.textContent = errReason || 'This pairing link is invalid or has expired.';
    }
    showView('view-error-pair');
    return;
  }

  const payload = pairResp.payload || {};
  mySlot        = typeof payload['slot'] === 'number' ? payload['slot'] : null;
  roomCode      = typeof payload['room_code'] === 'string' ? payload['room_code'] : '';
  myUsername    = typeof payload['username'] === 'string' ? payload['username'] : '';
  iceServers    = Array.isArray(payload['ice_servers']) ? payload['ice_servers'] as RTCIceServer[] : [];
  peers         = Array.isArray(payload['peers']) ? payload['peers'] as Array<{ id: string; slot: number; username: string }> : [];
  reconnectToken = typeof payload['reconnect_token'] === 'string' ? payload['reconnect_token'] : null;

  const chanTotalEl = document.getElementById('chan-total');
  if (chanTotalEl) { chanTotalEl.textContent = String(peers.length); }

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
function showReconnecting(): void {
  const dotEl = document.getElementById('active-status-dot');
  const chanEl = document.getElementById('active-channels');
  if (dotEl) { dotEl.classList.remove('dot--connected', 'dot--empty'); dotEl.classList.add('dot--hold'); }
  if (chanEl) { chanEl.textContent = 'Reconnecting…'; }
}

function showReconnected(): void {
  const dotEl = document.getElementById('active-status-dot');
  const chanEl = document.getElementById('active-channels');
  if (dotEl) { dotEl.classList.remove('dot--hold', 'dot--empty'); dotEl.classList.add('dot--connected'); }
  if (chanEl) { chanEl.textContent = openChannelCount + '/' + peers.length + ' connected'; }
}

async function attemptReconnect(): Promise<void> {
  if (!reconnectToken) { showView('view-ended'); return; }
  _reconnecting = true;
  showReconnecting();
  phoneLog('reconnect-try');

  // 3s initial delay: iOS network is unstable immediately after backgrounding.
  // Connections open then die within ~50ms for the first 20-30s. Waiting 3s
  // before the first attempt skips most of that window.
  await new Promise<void>(function(r) { setTimeout(r, 3000); });

  // Outer loop retries all transports until slot becomes Disconnected (server-side
  // WT relay may stay alive ~19s; heartbeat-miss fires ~65s after last heartbeat).
  // Each iteration: try WT first (preferred for games), fall to WS on network failure.
  // slot_not_held skips WS (both transports get same result) and waits 10s.
  const maxAttempts = 13;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    let resp: SignalingMessage | null = null;

    // ── Try WT first ─────────────────────────────────────────────────────────
    if (typeof WebTransport !== 'undefined') {
      resp = await tryWtReconnect();
      if (resp && resp.type === 'join-ack') {
        // committed inside tryWtReconnect (transport + useWt set)
      } else {
        const wtReason = (resp && resp.payload && resp.payload['reason'] as string) || '';
        if (wtReason === 'slot_not_held') {
          // WS would give the same result — skip it, just wait.
          phoneLog('reconnect-wait:' + attempt + ' slot_not_held');
          if (attempt < maxAttempts) {
            await new Promise<void>(function(r) { setTimeout(r, 10000); });
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
        const wsOk = await new Promise<boolean>(function(resolve) {
          const t = setTimeout(function() { resolve(false); }, 10000);
          connectPhoneWS(function() { clearTimeout(t); resolve(true); });
        });
        if (!wsOk || !ws || ws.readyState !== WebSocket.OPEN) {
          phoneLog('reconnect-ws-fail n=' + attempt);
          if (attempt < maxAttempts) {
            await new Promise<void>(function(r) { setTimeout(r, 10000); });
            continue;
          }
          _reconnecting = false; reconnectToken = null; showView('view-ended'); return;
        }
      }

      if (!ws || ws.readyState !== WebSocket.OPEN) {
        phoneLog('reconnect-ws-not-ready n=' + attempt);
        if (attempt < maxAttempts) {
          await new Promise<void>(function(r) { setTimeout(r, 10000); });
          continue;
        }
        _reconnecting = false; reconnectToken = null; showView('view-ended'); return;
      }

      resp = await new Promise<SignalingMessage>(function(resolve, reject) {
        _reconnectResolve = resolve;
        _reconnectReject = reject;
        sendWsMsg('reconnect', '', { reconnect_token: reconnectToken });
      }).catch(function(reason: string) {
        return { type: 'join-error', payload: { reason: String(reason) } } as SignalingMessage;
      });
    }

    // ── Handle response ───────────────────────────────────────────────────────
    if (resp && resp.type === 'join-ack') {
      const rp = resp.payload || {};
      reconnectToken = typeof rp['reconnect_token'] === 'string' ? rp['reconnect_token'] : null;
      if (Array.isArray(rp['ice_servers'])) { iceServers = rp['ice_servers'] as RTCIceServer[]; }
      if (!useWt) { useWt = false; } // WS path: already false
      registered = true;
      _reconnecting = false;
      showReconnected();
      phoneLog('reconnect-ok slot=' + mySlot + ' n=' + attempt + ' via=' + (useWt ? 'WT' : 'WS'));

      const toReopen: Array<[string, boolean]> = [];
      peerConnections.forEach(function(entry, peerId) {
        if (entry.dc.readyState === 'closed' || entry.dc.readyState === 'closing' ||
            entry.pc.connectionState === 'failed') {
          toReopen.push([peerId, entry.channelOpen]);
        }
      });
      toReopen.forEach(function([peerId, wasOpen]) {
        peerConnections.delete(peerId);
        openChannelToPeer(peerId, wasOpen);
      });

      startHeartbeat();
      return;
    }

    const errReason = (resp && resp.payload && resp.payload['reason'] as string) || '';
    const retryable = errReason === 'slot_not_held' || errReason === 'ws-closed' || errReason === 'wt-net';
    if (retryable && attempt < maxAttempts) {
      phoneLog('reconnect-wait:' + attempt + ' ' + errReason);
      await new Promise<void>(function(r) { setTimeout(r, 10000); });
      continue;
    }

    phoneLog('reconnect-fail:' + errReason + ' n=' + attempt);
    _reconnecting = false;
    reconnectToken = null;
    if (heartbeatInterval !== null) { clearInterval(heartbeatInterval); heartbeatInterval = null; }
    showView('view-ended');
    return;
  }

  // Exhausted all attempts.
  _reconnecting = false;
  reconnectToken = null;
  if (heartbeatInterval !== null) { clearInterval(heartbeatInterval); heartbeatInterval = null; }
  showView('view-ended');
}

// ── WebRTC fan-out ───────────────────────────────────────────────────────────
function openChannelToPeer(peerId: string, isRecovery = false): void {
  const ptag = peerId.slice(0, 8);
  phoneLog('openCh p=' + ptag + ' ice=' + iceServers.length);
  const pc = new RTCPeerConnection({ iceServers: iceServers });
  // D-05 locked: both options must be present and exactly these values.
  const dc = pc.createDataChannel('sensor', { ordered: false, maxRetransmits: 0 });

  pc.onconnectionstatechange = function() {
    phoneLog('conn=' + pc.connectionState + ' p=' + ptag);
    console.info('[WebRTC] connectionState=' + pc.connectionState + ' peer=' + ptag);
    if (pc.connectionState === 'failed') {
      const entry = peerConnections.get(peerId);
      const wasOpen = entry ? entry.channelOpen : false;
      if (entry && entry.channelOpen) {
        entry.channelOpen = false;
        if (openChannelCount > 0) { openChannelCount--; }
        updateConnectingUI();
      }
      if (registered) {
        peerConnections.delete(peerId);
        try { pc.close(); } catch (e) { /* ignore */ }
        openChannelToPeer(peerId, wasOpen);
      }
    }
  };
  pc.oniceconnectionstatechange = function() {
    phoneLog('ice=' + pc.iceConnectionState + ' p=' + ptag);
    console.info('[WebRTC] iceConnectionState=' + pc.iceConnectionState + ' peer=' + ptag);
  };
  pc.onicegatheringstatechange = function() {
    phoneLog('gather=' + pc.iceGatheringState + ' p=' + ptag);
  };

  let intentionalClose = false;  // WR-11

  pc.onnegotiationneeded = function() {
    pc.setLocalDescription()
      .then(function() {
        const offerSetup = (pc.localDescription && pc.localDescription.sdp || '').match(/a=setup:(\S+)/);
        phoneLog('offer a=setup:' + (offerSetup ? offerSetup[1] : '?') + ' p=' + ptag);
        signalSend('offer', peerId, pc.localDescription as RTCSessionDescription);
      })
      .catch(function(err: unknown) {
        console.warn('[WebRTC] onnegotiationneeded failed for ' + peerId + ':', err);
        phoneLog('offer-err:' + (err instanceof Error ? err.message : String(err)));
      });
  };

  pc.onicecandidate = function(evt: RTCPeerConnectionIceEvent) {
    if (!evt.candidate) {
      phoneLog('cand-done p=' + ptag);
      return;
    }
    phoneLog('cand ' + (evt.candidate.type || 'host') + ' p=' + ptag);
    signalSend('ice-candidate', peerId, evt.candidate);
  };

  dc.onmessage = function(evt: MessageEvent) {
    try {
      const msg = JSON.parse(evt.data as string);
      if (msg && msg.type === 'peer-leaving') { desktopLeavingIntentionally = true; }
    } catch (_e) { /* binary sensor packets from phone — ignore */ }
  };

  dc.onopen = function() {
    const entry = peerConnections.get(peerId);
    if (entry) { entry.channelOpen = true; }
    phoneLog('DC-OPEN p=' + ptag);
    openChannelCount++;
    updateConnectingUI();
    signalSend('rtc-channel-ready', '', { with: peerId });
    if (isRecovery) { sendPhoneState({ state: 'channel-recovered', with: peerId }); }
  };

  dc.onclose = function() {
    if (intentionalClose) { return; }  // WR-11
    const entry = peerConnections.get(peerId);
    if (entry && entry.channelOpen) {
      entry.channelOpen = false;
      if (openChannelCount > 0) { openChannelCount--; }
      updateConnectingUI();
    }
    sendPhoneState({ state: 'channel-lost', with: peerId });
  };

  peerConnections.set(peerId, { pc: pc, dc: dc, channelOpen: false, flagClose: function() { intentionalClose = true; } });
}

function updateConnectingUI(): void {
  const chanOpenEl = document.getElementById('chan-open');
  if (chanOpenEl) { chanOpenEl.textContent = String(openChannelCount); }
  // Show view-connecting when channels drop (desktop reload/network drop).
  // Intentional desktop leave sends a DC "peer-leaving" message first, which sets
  // desktopLeavingIntentionally — peer-left handler then overrides to view-ended.
  if (openChannelCount === 0 && sensorPipelineRunning) {
    showView('view-connecting');
  }
}

// ── Helpers (Plan 07) ────────────────────────────────────────────────────────

/** Clamp v to [0, 1]. Used to normalise touch coordinates before uint16 write. */
function clamp01(v: number): number { return Math.min(1, Math.max(0, v)); }

/**
 * L1 quaternion delta — per-frame convergence signal fed to rampBeta.
 * A small frameDelta means the filter is converging; rampBeta will lower beta.
 */
function quatDelta(a: Quaternion, b: Quaternion): number {
  return Math.abs(a.w - b.w) + Math.abs(a.x - b.x) + Math.abs(a.y - b.y) + Math.abs(a.z - b.z);
}

// ── Touch listeners (Plan 07 / SENS-06) ─────────────────────────────────────
// Named handlers (not anonymous closures) so re-entry on reconnect never stacks
// duplicate listeners behind the `touchListenersAttached` idempotency guard.

function onTouchStart(e: TouchEvent): void {
  const t = e.touches[0];
  if (!t) { return; }
  currentTouch.active = true;
  currentTouch.x = clamp01(safeFloat(t.clientX) / window.innerWidth);
  currentTouch.y = clamp01(safeFloat(t.clientY) / window.innerHeight);
}

function onTouchMove(e: TouchEvent): void {
  const t = e.touches[0];
  if (!t) { return; }
  currentTouch.active = true;
  currentTouch.x = clamp01(safeFloat(t.clientX) / window.innerWidth);
  currentTouch.y = clamp01(safeFloat(t.clientY) / window.innerHeight);
}

// touchend/touchcancel: clear active but preserve last coordinates (D-13).
function onTouchEnd(_e: TouchEvent): void {
  currentTouch.active = false;
}

/**
 * Attach touch listeners to document.body (idempotent — safe to call on
 * every startSensorPipeline invocation, e.g. after a session reconnect).
 * T-05-17 mitigation: `touchListenersAttached` guard + named handlers.
 */
function attachTouchListeners(): void {
  if (touchListenersAttached) { return; }
  touchListenersAttached = true;
  document.body.addEventListener('touchstart',  onTouchStart, { passive: true });
  document.body.addEventListener('touchmove',   onTouchMove,  { passive: true });
  document.body.addEventListener('touchend',    onTouchEnd,   { passive: true });
  document.body.addEventListener('touchcancel', onTouchEnd,   { passive: true });
}

// ── World-frame acceleration transform ───────────────────────────────────────
// Rotate device-frame acceleration to W3C earth frame (X=East, Y=North, Z=Up).
// primaryQuat represents world→device (W3C ZXY euler convention); applying its
// conjugate rotates device→world, eliminating rotation-induced gravity leakage
// that causes the cube to drift when only rotating the phone.
function rotateDeviceToWorld(vx: number, vy: number, vz: number, q: Quaternion): { x: number; y: number; z: number } {
  const { w, x: qx, y: qy, z: qz } = q;
  const tx = 2 * (qz * vy - qy * vz);
  const ty = 2 * (qx * vz - qz * vx);
  const tz = 2 * (qy * vx - qx * vy);
  return {
    x: vx + w * tx + qz * ty - qy * tz,
    y: vy + w * ty + qx * tz - qz * tx,
    z: vz + w * tz + qy * tx - qx * ty,
  };
}

// ── Sensor broadcast (Plan 06 / PHONE-04) ────────────────────────────────────
/**
 * Fan the given Uint8Array out to every peer data channel that is open.
 * Checks both `entry.channelOpen` and `dc.readyState` before each send;
 * wraps each send in try/catch so one closing channel cannot abort the loop
 * (T-05-14 mitigation).
 */
// RTCDataChannel.send() expects ArrayBufferView<ArrayBuffer> (not SharedArrayBuffer).
// _packetBuf is a plain ArrayBuffer so the cast is always correct at runtime.
function broadcastPacket(uint8: Uint8Array<ArrayBuffer>): void {
  peerConnections.forEach(function(entry) {
    if (entry.channelOpen && entry.dc.readyState === 'open') {
      try {
        entry.dc.send(uint8);
      } catch (_e) {
        // Channel closing between readyState check and send — ignored (T-05-14).
      }
    }
  });
}

// ── Sensor pipeline (Plan 06/07 / PHONE-04, PHONE-05) ────────────────────────
/**
 * Start the OS-orientation → encode → broadcast pipeline.
 *
 * Plan 07 fills every packet field with real data:
 *   - ZUPT-gated Kalman dead-reckoning (px/py/pz + driftConfidence) — SENS-03/04
 *   - Per-gesture displacement (dx/dy/dz, resets to zero after each ZUPT) — SENS-05
 *   - Live touch state via currentTouch (touchActive/X/Y) — SENS-06
 *   - Dev-only Madgwick overlay + source-select (D-04/D-15)
 *
 * @param zuptThreshold  Variance threshold from calibration.
 * @param kalmanQ        Kalman process-noise Q from calibration.
 */
function startSensorPipeline(zuptThreshold: number, kalmanQ: number): void {
  sensorPipelineRunning = true; // Bug 2b: mark pipeline active; guards onPlayerReady re-calibration
  // Store calibration params.
  _calThreshold = zuptThreshold;
  _calKalmanQ   = kalmanQ;

  sessionStart = Date.now();

  // ── Dead-reckoning state (closure-local — reinit once per session) ──────────
  const zupt = new ZUPTDetector(300, zuptThreshold);
  const kalmans = [new Kalman1D(kalmanQ), new Kalman1D(kalmanQ), new Kalman1D(kalmanQ)];
  let gestureOrigin: Vector3 = { x: 0, y: 0, z: 0 };
  let gestureDisplacement: Vector3 = { x: 0, y: 0, z: 0 };
  // lastCompletedGesture retained for Phase 6/8 gesture-trigger consumers — do not remove.
  let lastCompletedGesture: Vector3 = { x: 0, y: 0, z: 0 };
  let lastTs = performance.now();

  // ── Dev-only state (closure-local) ─────────────────────────────────────────
  let prevMq: Quaternion = { w: 1, x: 0, y: 0, z: 0 };
  let hzCount = 0;
  let hzWindowStart = performance.now();
  let hz = 0;

  // Dev source-select: read URL param once (D-04).
  if (import.meta.env.DEV) {
    useMadgwick = new URLSearchParams(location.search).get('orient') === 'madgwick';
  }

  // Attach touch listeners once per lifetime (idempotent guard inside).
  attachTouchListeners();

  // PRIMARY orientation: OS-fused orientation → quaternion (D-03).
  // Prefer deviceorientationabsolute (compass-referenced alpha, no yaw drift on Android).
  // Fall back to generic deviceorientation when absolute is unavailable (iOS always falls here —
  // iOS alpha is device-relative; yaw drift on iOS is a platform constraint, not a code bug).
  // Do NOT run a secondary Madgwick pass on either source — the OS already fuses gyro + mag.

  let hasAbsoluteOrientation = false;

  // deviceorientationabsolute: Android Chrome only; alpha is compass-referenced (drift-free yaw).
  // Not available on iOS — TypeScript does not include this event in WindowEventMap, hence cast.
  (window as EventTarget).addEventListener('deviceorientationabsolute', function(e: Event) {
    const doe = e as DeviceOrientationEvent;
    if (doe.alpha == null) { return; }
    hasAbsoluteOrientation = true;
    primaryQuat = eulerToQuat(
      safeFloat(doe.alpha),
      safeFloat(doe.beta),
      safeFloat(doe.gamma),
    );
  });

  // Generic deviceorientation: alpha is device-relative on iOS; may be device-relative on Android
  // if deviceorientationabsolute has not yet fired. Guard with hasAbsoluteOrientation so Android
  // does not overwrite the compass-corrected quaternion with the lower-quality fallback.
  window.addEventListener('deviceorientation', function(e: DeviceOrientationEvent) {
    if (hasAbsoluteOrientation) { return; } // absolute source active — skip relative fallback
    primaryQuat = eulerToQuat(
      safeFloat(e.alpha),
      safeFloat(e.beta),
      safeFloat(e.gamma),
    );
  });

  // Sensor tick: build SensorPacket → encode 36 bytes into reused buffer → broadcast.
  window.addEventListener('devicemotion', function(e: DeviceMotionEvent) {
    // Clamped delta time (V5: stalled/backward clock cannot produce unbounded integration).
    const now = performance.now();
    const dtSec = Math.min(0.1, Math.max(0, (now - lastTs) / 1000));
    lastTs = now;

    // Linear acceleration for Kalman — gravity-removed (V5: safeFloat before predict).
    const ax = safeFloat(e.acceleration?.x);
    const ay = safeFloat(e.acceleration?.y);
    const az = safeFloat(e.acceleration?.z);

    // accelerationIncludingGravity magnitude for ZUPT (V5: safeFloat before update).
    const ag = e.accelerationIncludingGravity;
    const mag = Math.hypot(safeFloat(ag?.x), safeFloat(ag?.y), safeFloat(ag?.z));

    // Rotate device-frame acceleration to W3C world frame (X=East, Y=North, Z=Up)
    // before Kalman integration. Device-frame integration causes drift whenever the
    // phone rotates — gravity residuals project differently onto device axes at each
    // orientation. World-frame integration is rotation-invariant.
    const wa = rotateDeviceToWorld(ax, ay, az, primaryQuat);

    // ZUPT stillness detection + Kalman position integration (world frame).
    const isStill = zupt.update(mag, Date.now());
    const rawPx = kalmans[0].predict(wa.x, dtSec);
    const rawPy = kalmans[1].predict(wa.y, dtSec);
    const rawPz = kalmans[2].predict(wa.z, dtSec);

    // Bounded positions — T-05-16: drift cannot grow without limit.
    const clamp = (v: number, lim: number): number => Math.min(lim, Math.max(-lim, v));
    const pxBounded = clamp(rawPx, POSITION_MAX);
    const pyBounded = clamp(rawPy, POSITION_MAX);
    const pzBounded = clamp(rawPz, POSITION_MAX);

    // Live gesture displacement = position delta from last ZUPT origin (bounded).
    gestureDisplacement = {
      x: clamp(rawPx - gestureOrigin.x, GESTURE_MAX),
      y: clamp(rawPy - gestureOrigin.y, GESTURE_MAX),
      z: clamp(rawPz - gestureOrigin.z, GESTURE_MAX),
    };

    // ZUPT fired: save completed gesture, reset velocity + origin, zero live displacement.
    if (isStill) {
      lastCompletedGesture = { ...gestureDisplacement }; // retained for Phase 6/8
      kalmans[0].resetVelocity();
      kalmans[1].resetVelocity();
      kalmans[2].resetVelocity();
      gestureOrigin = { x: rawPx, y: rawPy, z: rawPz };
      gestureDisplacement = { x: 0, y: 0, z: 0 };
    }

    // Drift confidence: axis-averaged Kalman covariance-derived scalar.
    const driftConf = (kalmans[0].driftConfidence() + kalmans[1].driftConfidence() + kalmans[2].driftConfidence()) / 3;

    // Dev orientation source-select: default OS-fused; `?orient=madgwick` swaps (D-04).
    let qSource = primaryQuat;
    let mq: Quaternion = { w: 1, x: 0, y: 0, z: 0 };
    if (import.meta.env.DEV) {
      mq = updateMadgwick(e);
      rampBeta(quatDelta(mq, prevMq));
      prevMq = mq;
      if (useMadgwick) { qSource = mq; }
    }

    // Build packet — all fields real (no placeholders remain after Plan 07).
    const pkt: SensorPacket = {
      seq: seq++,
      timestamp: Date.now() - sessionStart,
      qw: qSource.w,
      qx: qSource.x,
      qy: qSource.y,
      qz: qSource.z,
      dx: gestureDisplacement.x, dy: gestureDisplacement.y, dz: gestureDisplacement.z,
      px: pxBounded, py: pyBounded, pz: pzBounded,
      driftConfidence: driftConf,
      touchActive: currentTouch.active,
      touchX: currentTouch.x,
      touchY: currentTouch.y,
    };

    // Encode into module-scope reused buffer — no new ArrayBuffer per tick (Pitfall 5).
    // Cast is correct: _packetBuf is ArrayBuffer (not SharedArrayBuffer) so the
    // Uint8Array returned by encodePacket is always Uint8Array<ArrayBuffer> at runtime.
    const uint8 = encodePacket(pkt, _packetBuf) as Uint8Array<ArrayBuffer>;
    broadcastPacket(uint8);

    // Motion indicator visual feedback.
    const a = e.acceleration || e.accelerationIncludingGravity;
    if (a) {
      const motionMag = Math.sqrt((a.x ?? 0) * (a.x ?? 0) + (a.y ?? 0) * (a.y ?? 0) + (a.z ?? 0) * (a.z ?? 0));
      const indicator = document.getElementById('motion-indicator');
      if (indicator) {
        const threshold = e.acceleration ? 0.5 : 10.3;
        if (motionMag > threshold) {
          indicator.classList.add('motion-active');
          if (_motionIndicatorTimer !== null) { clearTimeout(_motionIndicatorTimer); }
          _motionIndicatorTimer = setTimeout(function() {
            indicator.classList.remove('motion-active');
          }, 300);
        }
      }
    }

    // Dev overlay — replaces Plan 06 phoneLog('pkt ...B @...Hz') byte/Hz log (D-15).
    if (import.meta.env.DEV) {
      hzCount++;
      if (now - hzWindowStart >= 1000) {
        hz = hzCount / ((now - hzWindowStart) / 1000);
        hzCount = 0;
        hzWindowStart = now;
      }
      updateOverlay(pkt, mq, isStill, hz);
    }
  });
}

function onPlayerReady(msg: SignalingMessage): void {
  const payload = (msg && msg.payload) ? msg.payload : {};
  if (typeof payload['username'] === 'string') { myUsername = payload['username']; }

  // Pre-populate the active view's UI elements (visible after calibration completes).
  const usernameEl = document.getElementById('active-username');
  const roomEl     = document.getElementById('active-room');
  const channelsEl = document.getElementById('active-channels');
  const dotEl      = document.getElementById('active-status-dot');

  if (usernameEl) { usernameEl.textContent = myUsername; }
  if (roomEl)     { roomEl.textContent = roomCode; }
  if (channelsEl) { channelsEl.textContent = openChannelCount + '/' + peers.length + ' connected'; }
  if (dotEl) {
    dotEl.classList.remove('dot--hold', 'dot--empty');
    dotEl.classList.add('dot--connected');
  }

  // Bug 2b fix: if sensor pipeline is already running, the desktop merely reconnected —
  // skip the 3-second hold-still recalibration and go straight to view-active.
  // Server replays player-ready on every desktop reconnect; the phone must not restart
  // calibration when it is already in active state.
  if (sensorPipelineRunning) {
    showView('view-active');
    return;
  }

  // Phase 5 D-08: show hold-still calibration scene, then auto-advance to active view.
  showView('view-calibrating');

  // Trigger the 3-second countdown bar CSS transition.
  // Double-rAF ensures the hidden → visible repaint resolves before width transition fires.
  const fillEl = document.getElementById('calibration-fill');
  if (fillEl) {
    requestAnimationFrame(function() {
      requestAnimationFrame(function() {
        (fillEl as HTMLElement).style.width = '100%';
      });
    });
  }

  // runCalibration collects 3 s of devicemotion accel-magnitude samples, then calls back.
  runCalibration(function(threshold, kalmanQ) {
    showView('view-active');
    requestWakeLock();
    startHeartbeat();
    startSensorPipeline(threshold, kalmanQ);
  });
}

// ── Server message handler ────────────────────────────────────────────────────
async function handleServerPush(msg: SignalingMessage): Promise<void> {
  let entry: { pc: RTCPeerConnection; dc: RTCDataChannel; channelOpen: boolean; flagClose: () => void } | undefined;
  switch (msg.type) {
    case 'pair-error':
      showView('view-error-pair');
      break;

    case 'player-ready':
      onPlayerReady(msg);
      break;

    case 'answer':
      entry = peerConnections.get(msg.from || '');
      if (!entry) {
        console.warn('[WebRTC] answer from unknown peer:', msg.from);
        phoneLog('answer unknown peer=' + (msg.from || '').slice(0, 8));
        break;
      }
      {
        const answerSetup = ((msg.payload && msg.payload['sdp'] as string) || '').match(/a=setup:(\S+)/);
        phoneLog('answer a=setup:' + (answerSetup ? answerSetup[1] : '?') +
                 ' from=' + (msg.from || '').slice(0, 8));
        await entry.pc.setRemoteDescription(msg.payload as unknown as RTCSessionDescriptionInit);
      }
      break;

    case 'ice-candidate':
      entry = peerConnections.get(msg.from || '');
      if (!entry) { break; }
      phoneLog('rx-cand from=' + (msg.from || '').slice(0, 8));
      await entry.pc.addIceCandidate(msg.payload as RTCIceCandidateInit);
      break;

    case 'peer-joined':
      if (!msg.payload || !msg.payload['peer'] || typeof (msg.payload['peer'] as { id?: string })['id'] !== 'string') {
        console.warn('[signaling] peer-joined: malformed payload', msg.payload);
        break;
      }
      openChannelToPeer((msg.payload['peer'] as { id: string })['id']);
      break;

    case 'peer-left': {
      closePeer((msg.payload && msg.payload['peer_id'] as string) || '');
      if (desktopLeavingIntentionally) {
        desktopLeavingIntentionally = false;
        sensorPipelineRunning = false;
        showView('view-ended');
      }
      break;
    }

    case 'session-ended':
      if (heartbeatInterval !== null) { clearInterval(heartbeatInterval); heartbeatInterval = null; }
      showView('view-ended');
      break;

    default:
      console.warn('[signaling] Unknown push type:', msg.type);
  }
}

// ── Session durability ────────────────────────────────────────────────────────

async function requestWakeLock(): Promise<void> {
  if (!('wakeLock' in navigator)) { return; }
  try {
    wakeLockSentinel = await (navigator as Navigator & { wakeLock: { request: (type: string) => Promise<WakeLockSentinel> } }).wakeLock.request('screen');
    wakeLockSentinel.addEventListener('release', function() {
      sendPhoneState({ state: 'wake-lock-lost' });
      wakeLockSentinel = null;
    });
    sendPhoneState({ state: 'wake-lock-active' });
  } catch (err) {
    console.debug('[WakeLock] Request rejected:', (err instanceof Error ? err.message : String(err)));
  }
}

function startHeartbeat(): void {
  if (heartbeatInterval !== null) { clearInterval(heartbeatInterval); }
  heartbeatInterval = setInterval(function() {
    signalSend('heartbeat', '', {});
  }, 5000);
}

function sendPhoneState(statePayload: object): void {
  if (!registered) { return; }
  signalSend('phone-state', '', statePayload);
}

let _motionIndicatorTimer: ReturnType<typeof setTimeout> | null = null;

function closePeer(peerId: string): void {
  const entry = peerConnections.get(peerId);
  if (!entry) { return; }
  entry.flagClose();
  try { entry.pc.close(); } catch (e) { /* already closed */ }
  peerConnections.delete(peerId);
  if (entry.channelOpen && openChannelCount > 0) { openChannelCount--; }
  updateConnectingUI();
}

document.addEventListener('visibilitychange', function() {
  if (document.visibilityState === 'visible') {
    if (!registered) {
      // Signaling dropped while backgrounded (WT killed by iOS). attemptReconnect
      // is triggered by transport.closed, but the two events can race. If registered
      // is still false here and reconnectToken is set, kick reconnect explicitly.
      if (reconnectToken && !ws && !_reconnecting) { attemptReconnect(); }
      return;
    }
    sendPhoneState({ state: 'foreground' });
    signalSend('heartbeat', '', {});
    requestWakeLock();
    peerConnections.forEach(function(entry, peerId) {
      if (entry.dc.readyState === 'closed' || entry.dc.readyState === 'closing' ||
          entry.pc.connectionState === 'failed') {
        const wasOpen = entry.channelOpen;
        peerConnections.delete(peerId);
        openChannelToPeer(peerId, wasOpen);
      }
    });
  } else {
    if (!registered) { return; }
    sendPhoneState({ state: 'background' });
  }
});

// ── On-screen debug log (collapsible) ────────────────────────────────────────
let _logEl: HTMLDivElement | null = null;
let _logBody: HTMLDivElement | null = null;
let _logCollapsed = false;

function initOnScreenLog(): void {
  _logEl = document.createElement('div');
  _logEl.style.cssText =
    'position:fixed;bottom:0;left:0;right:0;z-index:9999;' +
    'background:rgba(0,0,0,0.85);border-top:2px solid #0f0;' +
    'font:11px/1.5 monospace;';

  const header = document.createElement('div');
  header.style.cssText =
    'display:flex;justify-content:space-between;align-items:center;' +
    'padding:3px 8px;cursor:pointer;color:#0f0;user-select:none;';
  header.innerHTML = '<span>📱 debug</span><span id="_log_toggle">▼</span>';
  header.addEventListener('click', function() {
    _logCollapsed = !_logCollapsed;
    if (_logBody) { _logBody.style.display = _logCollapsed ? 'none' : 'block'; }
    const toggleEl = document.getElementById('_log_toggle');
    if (toggleEl) { toggleEl.textContent = _logCollapsed ? '▲' : '▼'; }
  });

  _logBody = document.createElement('div');
  _logBody.style.cssText =
    'max-height:40vh;overflow-y:auto;padding:4px 8px;' +
    'color:#0f0;white-space:pre-wrap;word-break:break-all;';

  _logEl.appendChild(header);
  _logEl.appendChild(_logBody);
  document.body.appendChild(_logEl);
}

function phoneLog(msg: string): void {
  if (!_logBody) { return; }
  const now = new Date();
  const ts = String(now.getMinutes()).padStart(2, '0') + ':' +
             String(now.getSeconds()).padStart(2, '0') + '.' +
             String(now.getMilliseconds()).padStart(3, '0');
  const line = document.createElement('div');
  line.textContent = ts + ' ' + msg;
  _logBody.appendChild(line);
  while (_logBody.children.length > 40) {
    const first = _logBody.firstChild;
    if (first) { _logBody.removeChild(first); }
  }
  if (!_logCollapsed) { _logBody.scrollTop = _logBody.scrollHeight; }
}

// ── Bootstrap ────────────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', function() {
  initOnScreenLog();
  phoneLog('loaded');
  attachGrantButton();
  showView('view-permission');
  tryLockPortrait();

  const fsBtn = document.getElementById('btn-fullscreen');
  if (fsBtn) {
    fsBtn.addEventListener('click', function() {
      tryRequestFullscreen();
      fsBtn.remove();
    });
  }

  // Fix 4: block pinch-zoom (multi-touch touchmove) and double-tap zoom.
  // viewport meta already sets maximum-scale=1/user-scalable=no but not all
  // browsers honour that (Firefox Android ignores user-scalable=no).
  document.addEventListener('touchmove', function(e: TouchEvent) {
    if (e.touches.length > 1) { e.preventDefault(); }
  }, { passive: false });
  document.addEventListener('dblclick', function(e: Event) { e.preventDefault(); });
});
