/* room.ts — ImmersiveRT SPA router, WS client, QR render, event log, reconnect
 * TypeScript migration of room.js (Phase 5, D-02). Behavior-preserving — no new logic.
 * QRCode is loaded from CDN (jsdelivr); typed via ambient declaration below.
 * All DOM access via vanilla browser APIs only.
 */

// Marks this file as an ES module (prevents global-scope collision with phone.ts).
export {};

// Three.js scene lifecycle — plan 03 (initScene, stubs) + plan 04 (addPlayer, removePlayer)
// plan 05 (toggle setters, getToggleStates)
import {
  initScene,
  addPlayerToScene,
  removePlayerFromScene,
  cyclePositionMode,
  toggleGrid,
  toggleAxes,
  toggleTrail,
  toggleNumericHud,
  getToggleStates,
} from './scene';

// Sensor packet decode pipeline (plan 04: decode→guard→seq-drop→store in ondatachannel)
import * as decode from './sensor/decode';
import * as playerStore from './playerStore';

// Ambient declaration for the QRCode CDN global (qrcode@1.4.4 via jsdelivr).
// Only the shape that room.ts actually calls is typed here.
declare const QRCode: {
  toCanvas: (
    canvas: HTMLCanvasElement,
    text: string,
    options: {
      width: number;
      margin: number;
      color: { dark: string; light: string };
      errorCorrectionLevel: string;
    },
    callback: (err: Error | null | undefined) => void
  ) => void;
};

// ──────────────────────────────────────────────────────────────────────────────
// Shared WS state
// ──────────────────────────────────────────────────────────────────────────────
let ws: WebSocket | null = null;
let myId: string | null = null;
let currentRoom: { slot: number; room_code: string; iceServers?: RTCIceServer[] | null } | null = null;
let wsReady = false;    // true once register ack confirmed (open + registered)
const pendingMessageQueue: string[] = []; // messages queued before WS is ready
let pendingUsername: string | null = null; // username sent with join-room, used in handleJoinAck

// WebRTC state — desktop side (Phase 4 Plan 02: minimal answerer for PHONE-03)
const desktopPeers = new Map<string, RTCPeerConnection>(); // phoneId → RTCPeerConnection
const pendingICE = new Map<string, RTCIceCandidateInit[]>(); // phoneId → ICE candidates queued before setRemoteDescription resolves

// Data channels — stored separately so updateHud/renderTabRoster can read live dc.readyState
// without traversing peer connections (plan 05, T-06-13: TAB roster reads live channel state)
const desktopChannels = new Map<string, RTCDataChannel>(); // phoneId → RTCDataChannel

// Scene slot tracking — maps phoneId to display slot (1-based, capped at 8).
// Used to register first-data-channel phones (before player-ready fires) and to
// find the phoneId for a departing slot in player-left cleanup (DESK-02).
const phoneSlots = new Map<string, number>(); // phoneId → slot
let nextSceneSlot = 1; // auto-increment counter for phones that arrive before player-ready

// Per-slot username cache — keyed by slot (1-8), populated in handlePlayerReady.
// Used by renderTabRoster to show player names in the TAB overlay without querying the DOM.
const slotUsernames = new Map<number, string>(); // slot → username

// Diagnostic: set true to force TURN-relay-only ICE (bypasses direct LAN path).
// Useful to isolate whether DTLS failure is specific to the direct host-to-host path.
const DEBUG_FORCE_RELAY = false;

// ──────────────────────────────────────────────────────────────────────────────
// WebTransport state
// ──────────────────────────────────────────────────────────────────────────────
let transport: WebTransport | null = null;
let useWt = false;
// Stored so createRoom/joinRoom can await it if WT is still connecting when the
// user clicks a button (prevents the join-room from falling into the WS pending
// queue which is never flushed once WT takes over — Bug A).
let wtConnectPromise: Promise<boolean> | null = null;

// Guard: first player-ready triggers game view; subsequent ones only add players.
let gameViewShown = false;

// Keyboard listener guard — prevents double-attachment on re-entry (idempotent)
let keyListenersAttached = false;

// TAB-held state flag (plan 05 keyboard handler — D-07)
let tabHeld = false;

// ──────────────────────────────────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────────────────────────────────
function showView(id: string): void {
  const views = document.querySelectorAll<HTMLElement>(
    '#view-lobby, #view-room, #view-phone'
  );
  views.forEach(function (v) { v.hidden = true; });
  const target = document.getElementById(id);
  if (target) { target.hidden = false; }
}

/**
 * Transition from the room UI into the full-viewport game view (D-04, D-05).
 * Hides all room/lobby/phone panels and reveals #game-container + #game-hud.
 * Called once on the first player-ready event, guarded by gameViewShown.
 */
function showGameView(): void {
  // Hide all views using the [hidden] attribute
  const views = document.querySelectorAll<HTMLElement>(
    '#view-lobby, #view-room, #view-phone'
  );
  views.forEach(function (v) { v.hidden = true; });

  // Show game container and persistent HUD (remove inline display:none)
  const gameContainer = document.getElementById('game-container');
  const gameHud = document.getElementById('game-hud');
  if (gameContainer) { gameContainer.style.display = 'block'; }
  if (gameHud) { gameHud.style.display = 'block'; }

  // Attach keyboard listeners (idempotent — safe to call on every showGameView)
  attachGameKeyListeners();

  // Sync HUD with initial state (0/0 connected, gesture mode, all toggles at defaults)
  updateHud();
}

function showError(elementId: string, message: string): void {
  const el = document.getElementById(elementId);
  if (!el) { return; }
  el.textContent = message;
  el.classList.add('error-msg--visible');
  (el as HTMLElement).style.display = 'block';
}

function clearError(elementId: string): void {
  const el = document.getElementById(elementId);
  if (!el) { return; }
  el.textContent = '';
  el.classList.remove('error-msg--visible');
  (el as HTMLElement).style.display = '';
}

function setInputError(inputId: string): void {
  const el = document.getElementById(inputId);
  if (el) { el.classList.add('input--error'); }
}

function clearInputError(inputId: string): void {
  const el = document.getElementById(inputId);
  if (el) { el.classList.remove('input--error'); }
}

function disableButton(id: string, loadingText?: string): void {
  const btn = document.getElementById(id) as HTMLButtonElement | null;
  if (!btn) { return; }
  btn.disabled = true;
  if (loadingText) { btn.textContent = loadingText; }
}

function enableButton(id: string, originalText?: string): void {
  const btn = document.getElementById(id) as HTMLButtonElement | null;
  if (!btn) { return; }
  btn.disabled = false;
  if (originalText) { btn.textContent = originalText; }
}

function formatTimestamp(date?: Date): string {
  const d = date || new Date();
  const h = String(d.getHours()).padStart(2, '0');
  const m = String(d.getMinutes()).padStart(2, '0');
  const s = String(d.getSeconds()).padStart(2, '0');
  return '[' + h + ':' + m + ':' + s + ']';
}

// ──────────────────────────────────────────────────────────────────────────────
// Persistent HUD updater (plan 05 — D-06, D-13, D-15)
//
// Reads live state from desktopChannels (connected count), scene.getToggleStates()
// (position mode + toggle booleans), and phoneSlots.size (total registered phones).
// All writes use textContent (no DOM injection risk from player-controlled data — T-06-10b).
// ──────────────────────────────────────────────────────────────────────────────
function updateHud(): void {
  const states = getToggleStates();

  // Connected count = phones with an open RTCDataChannel;
  // max = total registered phones (phoneSlots.size)
  let connectedCount = 0;
  for (const dc of desktopChannels.values()) {
    if (dc.readyState === 'open') { connectedCount++; }
  }
  const maxCount = phoneSlots.size;

  const hudSlots = document.getElementById('hud-slots');
  const hudMode  = document.getElementById('hud-mode');
  const hudKeys  = document.getElementById('hud-keys');

  // textContent writes only — no injection risk (T-06-10b)
  if (hudSlots) {
    hudSlots.textContent = connectedCount + '/' + maxCount + ' connected';
  }
  if (hudMode) {
    hudMode.textContent = 'pos: ' + states.positionModeLabel + '  [P to cycle]';
  }
  if (hudKeys) {
    hudKeys.textContent =
      'G:' + (states.gridVisible     ? 'on' : 'off') + '  ' +
      'A:' + (states.axesVisible     ? 'on' : 'off') + '  ' +
      'H:' + (states.numericHudVisible ? 'on' : 'off') + '  ' +
      'T:' + (states.trailVisible    ? 'on' : 'off');
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// TAB roster builder (plan 05 — D-07)
//
// Rebuilds #tab-roster with one row per slot (1–8).
// Status dot color reflects live RTCDataChannel.readyState.
// Own slot receives a 3px left accent border (UI-SPEC: --color-accent, D-07).
// All player-name writes use textContent (XSS guard — T-06-10b).
// ──────────────────────────────────────────────────────────────────────────────
function renderTabRoster(): void {
  const rosterEl = document.getElementById('tab-roster');
  if (!rosterEl) { return; }

  // Clear existing content — textContent = '' removes all descendants (XSS-safe, T-06-10b)
  rosterEl.textContent = '';

  // Re-add heading
  const heading = document.createElement('p');
  heading.className = 'size-heading';
  heading.textContent = 'Players';
  rosterEl.appendChild(heading);

  const ownSlot = currentRoom ? currentRoom.slot : -1;

  for (let i = 1; i <= 8; i++) {
    // Reverse-lookup: find phoneId for this slot (if any)
    let phoneId: string | undefined;
    for (const [pid, s] of phoneSlots) {
      if (s === i) { phoneId = pid; break; }
    }

    const username = phoneId ? slotUsernames.get(i) : undefined;
    const dc = phoneId ? desktopChannels.get(phoneId) : undefined;
    const readyState = dc ? dc.readyState : '';

    // Status dot color from RTCDataChannel.readyState (UI-SPEC color contract)
    let dotColor: string;
    if (dc && dc.readyState === 'open') {
      dotColor = 'var(--color-status-connected)'; // #22c55e
    } else if (dc && dc.readyState === 'connecting') {
      dotColor = 'var(--color-status-hold)'; // #eab308 (animated pulse in full CSS; omitted here)
    } else {
      dotColor = 'var(--color-status-empty)'; // #444444
    }

    const row = document.createElement('div');
    row.style.cssText = 'display:flex;align-items:center;gap:8px;padding:4px 0;';
    // Own slot: 3px accent left border (UI-SPEC D-07)
    if (i === ownSlot) {
      row.style.borderLeft = '3px solid var(--color-accent)';
      row.style.paddingLeft = '8px';
    }

    // Status dot (8px circle)
    const dot = document.createElement('span');
    dot.style.cssText = 'width:8px;height:8px;border-radius:50%;flex-shrink:0;';
    dot.style.backgroundColor = dotColor;
    row.appendChild(dot);

    // Slot label (min-width 72px, --color-text-secondary, semibold)
    const slotLabelEl = document.createElement('span');
    slotLabelEl.style.cssText = 'min-width:72px;font-size:13px;font-weight:600;color:var(--color-text-secondary);';
    slotLabelEl.textContent = 'Slot ' + i;
    row.appendChild(slotLabelEl);

    // Player name (textContent — XSS guard, T-06-10b)
    const nameEl = document.createElement('span');
    nameEl.style.cssText = 'flex:1;';
    nameEl.textContent = (phoneId && username) ? username : '(empty)';
    row.appendChild(nameEl);

    // Channel state string (verbatim RTCDataChannel.readyState — UI-SPEC D-07)
    const stateEl = document.createElement('span');
    stateEl.textContent = phoneId && readyState ? readyState : '—'; // em dash for empty
    row.appendChild(stateEl);

    rosterEl.appendChild(row);
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Game keyboard handler (plan 05 — UI-SPEC Keyboard Interaction Contract)
//
// Active only when game view is visible (gameViewShown guard).
// keydown: P/G/A/H/T/D toggle scene state; Tab shows roster overlay.
// keyup: Tab hides roster overlay.
// Attached once via attachGameKeyListeners() idempotency guard.
// ──────────────────────────────────────────────────────────────────────────────
function attachGameKeyListeners(): void {
  // Idempotency guard — prevents duplicate handler attachment on re-entry
  if (keyListenersAttached) { return; }
  keyListenersAttached = true;

  function onGameKeydown(evt: KeyboardEvent): void {
    // Only dispatch when game view is active
    if (!gameViewShown) { return; }

    switch (evt.key.toLowerCase()) {
      case 'p':
        // Cycle position mode (gestureDisplacement ↔ deadReckoningPosition — D-13)
        cyclePositionMode();
        updateHud();
        break;
      case 'g':
        // Toggle grid floor visibility (D-15)
        toggleGrid();
        updateHud();
        break;
      case 'a':
        // Toggle per-object axes gizmo visibility (D-15)
        toggleAxes();
        updateHud();
        break;
      case 'h':
        // Toggle per-player numeric HUD panel (D-15)
        toggleNumericHud();
        updateHud();
        break;
      case 't':
      case 'd':
        // Toggle motion trail / drama mode — both T and D map to single trail toggle (D-14, D-15)
        toggleTrail();
        updateHud();
        break;
      case 'tab':
        // Show TAB roster overlay while held; preventDefault stops browser focus-cycling (T-06-13)
        evt.preventDefault();
        tabHeld = true;
        const overlay = document.getElementById('game-tab-overlay');
        if (overlay) { overlay.style.display = 'block'; }
        renderTabRoster();
        break;
    }
  }

  function onGameKeyup(evt: KeyboardEvent): void {
    if (!gameViewShown) { return; }
    if (evt.key === 'Tab') {
      tabHeld = false;
      const overlay = document.getElementById('game-tab-overlay');
      if (overlay) { overlay.style.display = 'none'; }
    }
  }

  window.addEventListener('keydown', onGameKeydown);
  window.addEventListener('keyup', onGameKeyup);
}

// ──────────────────────────────────────────────────────────────────────────────
// WebTransport helpers
// ──────────────────────────────────────────────────────────────────────────────

// One-shot request: open a bidi stream, write the envelope, read the full response.
async function sendWtRequest(t: WebTransport, envelope: Record<string, unknown>): Promise<Record<string, unknown>> {
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
  return JSON.parse(new TextDecoder().decode(buf)) as Record<string, unknown>;
}

// Fire-and-forget send: open a bidi stream, write the envelope, drain the readable.
async function sendWtMessage(t: WebTransport, envelope: Record<string, unknown>): Promise<void> {
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
  console.debug('[WT] Desktop push listener starting');
  try {
    const bidiReader = t.incomingBidirectionalStreams.getReader();
    while (true) {
      const result = await bidiReader.read();
      if (result.done) { break; }
      processWtPush(result.value); // process concurrently, do not await
    }
    console.debug('[WT] Desktop push listener ended');
  } catch (err) {
    console.debug('[WT] Desktop push listener error:', err);
  }
}

function processWtPush(stream: WebTransportBidirectionalStream): void {
  const reader = stream.readable.getReader();
  let buf = new Uint8Array(0);
  (function readNext() {
    reader.read().then(function(chunk) {
      if (chunk.done) {
        // T-06-01: wrap JSON.parse in try/catch; malformed pushes are logged and ignored, never dispatched.
        try {
          const msg = JSON.parse(new TextDecoder().decode(buf)) as Record<string, unknown>;
          onServerMessage(msg);
        } catch (e) {
          console.warn('[WT] processWtPush: malformed JSON, ignoring:', e);
        }
        return;
      }
      const merged = new Uint8Array(buf.length + chunk.value.length);
      merged.set(buf);
      merged.set(chunk.value, buf.length);
      buf = merged;
      readNext();
    }).catch(function(err: unknown) {
      console.warn('[WT] processWtPush: read error:', err);
    });
  })();
}

function setupTransportClosedHandler(t: WebTransport): void {
  function onWtClose(): void {
    transport = null;
    useWt = false;
    console.info('[WT] Desktop transport closed — falling back to WS');
    connectWS(null);
  }
  t.closed.then(onWtClose).catch(onWtClose);
}

async function connectDesktopWT(): Promise<boolean> {
  // Idempotency guard: already connected — return immediately without a second transport.
  if (useWt && transport) { return true; }
  if (typeof WebTransport === 'undefined') { return false; }
  const wtUrl = 'https://' + location.hostname + ':4433';
  try {
    transport = new WebTransport(wtUrl);
    await transport.ready;

    // Verify getReader() is available (iOS/WebKit compat).
    if (typeof (transport.incomingBidirectionalStreams as ReadableStream).getReader !== 'function') {
      throw new Error('incomingBidirectionalStreams.getReader not supported');
    }

    // Start push listener BEFORE sending anything (RESEARCH Pitfall 1 — avoids dropped pushes).
    listenForServerPushes(transport);

    // Register.
    myId = crypto.randomUUID();
    await sendWtMessage(transport, { type: 'register', from: myId, to: '', payload: {} });

    useWt = true;
    setupTransportClosedHandler(transport);
    return true;
  } catch (err) {
    console.warn('[WT] Desktop connect failed, falling back to WS:', err);
    transport = null;
    useWt = false;
    return false;
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// WebSocket client
// ──────────────────────────────────────────────────────────────────────────────
function connectWS(onOpenCallback: (() => void) | null): void {
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) {
    // Already connected or connecting; call callback if open
    if (ws.readyState === WebSocket.OPEN && onOpenCallback) {
      onOpenCallback();
    } else if (onOpenCallback) {
      // Queue to run after open
      const prevOnOpen = ws.onopen;
      ws.onopen = function (evt: Event) {
        if (prevOnOpen) { prevOnOpen.call(ws!, evt); }
        onOpenCallback();
      };
    }
    return;
  }

  const serverWsUrl = 'wss://' + location.hostname + ':9090';
  ws = new WebSocket(serverWsUrl);
  wsReady = false;

  ws.onopen = function () {
    myId = crypto.randomUUID();
    ws!.send(JSON.stringify({ type: 'register', from: myId, to: '', payload: {} }));
    wsReady = true;

    // Flush queued messages
    while (pendingMessageQueue.length > 0) {
      const queued = pendingMessageQueue.shift();
      if (queued) { ws!.send(queued); }
    }

    if (onOpenCallback) { onOpenCallback(); }
  };

  ws.onmessage = function (evt: MessageEvent) {
    let msg: Record<string, unknown>;
    try {
      msg = JSON.parse(evt.data as string) as Record<string, unknown>;
    } catch (e) {
      console.warn('[WS] Malformed message, ignoring:', e);
      return;
    }
    onServerMessage(msg);
  };

  ws.onclose = function () {
    wsReady = false;
    updateConnectionStatus('Disconnected');
    // Attempt reconnect after 3s if we are on room page
    if (currentRoom) {
      setTimeout(function () {
        connectWS(null);
      }, 3000);
    }
  };

  ws.onerror = function (err: Event) {
    console.error('[WS] Connection error:', err);
    wsReady = false;
    updateConnectionStatus('Disconnected');
  };
}

// Transport-agnostic fire-and-forget send (D-03: single active transport at a time).
// When useWt: sends via sendWtMessage (WT bidi stream); else falls back to WS with
// the existing pending-queue behaviour.
function signalSend(type: string, to: string, payload: Record<string, unknown>): void {
  if (useWt && transport) {
    sendWtMessage(transport, { type: type, from: myId ?? '', to: to || '', payload: payload });
  } else {
    const msg = JSON.stringify({ type: type, from: myId, to: to || '', payload: payload });
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(msg);
    } else {
      pendingMessageQueue.push(msg);
    }
  }
}

function sendMessage(type: string, payload: Record<string, unknown>): void {
  signalSend(type, '', payload);
}

function sendTo(type: string, to: string, payload: unknown): void {
  signalSend(type, to, payload as Record<string, unknown>);
}

function updateConnectionStatus(text: string): void {
  const el = document.getElementById('connection-status');
  if (el) { el.textContent = text; }
}

// ──────────────────────────────────────────────────────────────────────────────
// Server message dispatcher
// ──────────────────────────────────────────────────────────────────────────────
function onServerMessage(msg: Record<string, unknown>): void {
  switch (msg.type) {
    case 'join-ack':
      handleJoinAck(msg.payload as Record<string, unknown>);
      break;
    case 'join-error':
      handleJoinError(((msg.payload as Record<string, unknown>)?.reason) as string);
      break;
    case 'room-event':
      handleRoomEvent(msg.payload as Record<string, unknown>);
      break;
    case 'pair-ack':
      handlePairAck(msg.payload as Record<string, unknown>);
      break;
    case 'pair-error':
      handlePairError(msg.payload as Record<string, unknown>);
      break;
    case 'leave-ack':
      // Slot freed on server — no action needed; WS stays open for next join.
      break;
    case 'offer':
      handleOffer(msg);
      break;
    case 'ice-candidate':
      handleIceCandidate(msg);
      break;
    case 'player-ready':
      handlePlayerReady(msg);
      break;
    case 'phone-state':
      if (msg.payload && (msg.payload as Record<string, unknown>).state === 'heartbeat-miss') {
        console.info('[Server] heartbeat-miss slot=' + (msg.payload as Record<string, unknown>).slot);
      }
      break;
    default:
      console.warn('[WS] Unknown message type:', msg.type);
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// WebRTC answerer — minimal desktop side (PHONE-03 / RESEARCH A4)
// Full receive pipeline, target-state store, and TURN path are Phase 6 (DESK-02).
// ──────────────────────────────────────────────────────────────────────────────
function handleOffer(msg: Record<string, unknown>): void {
  const phoneId = typeof msg.from === 'string' ? msg.from : '';
  if (!phoneId) {
    console.warn('[WebRTC] handleOffer: missing or invalid from field', msg);
    return;
  }
  const tag = phoneId.slice(0, 8);

  // Close zombie PC from a previous offer by the same phone.
  const oldPc = desktopPeers.get(phoneId);
  if (oldPc) {
    try { oldPc.close(); } catch (e) { /* ignore */ }
    desktopPeers.delete(phoneId);
  }

  const iceConfig: RTCConfiguration = {
    iceServers: (currentRoom && currentRoom.iceServers) || [{ urls: 'stun:' + location.hostname + ':3478' }]
  };
  if (DEBUG_FORCE_RELAY) { iceConfig.iceTransportPolicy = 'relay'; }
  const pc = new RTCPeerConnection(iceConfig);

  pc.onconnectionstatechange = function () {
    console.info('[WebRTC] connectionState=' + pc.connectionState + ' phone=' + tag);
  };
  pc.oniceconnectionstatechange = function () {
    console.info('[WebRTC] iceConnectionState=' + pc.iceConnectionState + ' phone=' + tag);
  };
  pc.onicegatheringstatechange = function () {
    console.info('[WebRTC] iceGatheringState=' + pc.iceGatheringState + ' phone=' + tag);
  };

  pc.ondatachannel = function (evt: RTCDataChannelEvent) {
    const dc = evt.channel;

    // Set binaryType BEFORE assigning onopen/onmessage (Pitfall 3: Firefox defaults to 'blob';
    // setting after open has no effect on already-buffered messages).
    dc.binaryType = 'arraybuffer';

    // Store data channel so updateHud / renderTabRoster can read live dc.readyState (plan 05)
    desktopChannels.set(phoneId, dc);

    dc.onopen = function () {
      console.info('[WebRTC] data channel open phone=' + tag + ' binaryType=' + dc.binaryType);
      sendMessage('rtc-channel-ready', { with: phoneId });
      // Update HUD so connected count reflects the newly-open channel
      if (gameViewShown) { updateHud(); }
    };

    dc.onclose = function () {
      // Update HUD so connected count reflects the closed channel
      if (gameViewShown) { updateHud(); }
    };

    // Decode→finite-guard→seq-drop→store pipeline (DESK-02, T-06-09, T-06-05b, T-06-11).
    // No sensor packet is relayed back through the server from this handler (DESK-02: P2P only).
    dc.onmessage = function (msgEvt: MessageEvent<ArrayBuffer>) {
      // Diagnostic: confirm packets are arriving and arriving as ArrayBuffer.
      // Remove once verified (or keep at console.debug to silence in production).
      console.log('[decode] packet received from phone=' + tag + ' byteLength=' + (msgEvt.data as ArrayBuffer).byteLength + ' type=' + Object.prototype.toString.call(msgEvt.data));

      // T-06-03/T-06-04: decode packet — null on truncated or version-mismatch buffer
      const pkt = decode.decodePacket(msgEvt.data);
      if (!pkt) {
        console.log('[decode] dropped malformed packet from phone=' + tag);
        return;
      }

      // T-06-09: reject non-finite quaternion fields before they reach THREE.Quaternion
      if (!decode.isSafePacket(pkt)) {
        console.log('[decode] dropped non-finite quaternion from phone=' + tag);
        return;
      }

      // T-06-05b: RFC 1982 seq-drop — reject out-of-order / duplicate / replayed packets
      const state = playerStore.targetStateStore.get(phoneId);
      if (state && !decode.isNewerSeq(pkt.seq, state.lastSeq)) {
        console.log('[decode] dropped out-of-order seq ' + pkt.seq + ' (last=' + state.lastSeq + ') from phone=' + tag);
        return;
      }

      // Register the phone in the scene on first accepted packet (if player-ready hasn't fired yet).
      // player-ready is authoritative (correct slot + username from server); this is a safety net.
      if (!phoneSlots.has(phoneId)) {
        const assignedSlot = nextSceneSlot <= 8 ? nextSceneSlot++ : 8;
        phoneSlots.set(phoneId, assignedSlot);
        // addPlayerToScene is idempotent: if player-ready already registered this phoneId, this is a no-op.
        addPlayerToScene(phoneId, assignedSlot, 'Slot ' + assignedSlot);
      }

      // Store the decoded packet — scene.ts rAF loop reads this each frame
      playerStore.updateTargetState(phoneId, pkt);
    };
  };

  pc.onicecandidate = function (evt: RTCPeerConnectionIceEvent) {
    if (!evt.candidate) { return; }
    sendTo('ice-candidate', phoneId, evt.candidate);
  };

  // Initialise ICE queue BEFORE the async chain so candidates arriving during
  // setRemoteDescription are buffered rather than dropped.
  pendingICE.set(phoneId, []);

  const offerDesc = msg.payload as RTCSessionDescriptionInit;

  pc.setRemoteDescription(offerDesc)
    .then(function () {
      // Only now is addIceCandidate safe — commit pc and drain the queue.
      desktopPeers.set(phoneId, pc);
      const queued = pendingICE.get(phoneId) || [];
      pendingICE.delete(phoneId);
      queued.forEach(function (c) {
        pc.addIceCandidate(c).catch(function (e: unknown) {
          console.warn('[WebRTC] queued addIceCandidate failed:', e);
        });
      });
      const sdp = (offerDesc && offerDesc.sdp) || '';
      const offerSetup = sdp.match(/a=setup:(\S+)/);
      console.info('[WebRTC] offer a=setup:' + (offerSetup ? offerSetup[1] : 'not found') + ' phone=' + tag);
      return pc.createAnswer();
    })
    .then(function (answer: RTCSessionDescriptionInit) {
      // iOS Safari ≥18 silently ignores DTLS ClientHello when it is forced into the passive
      // role (i.e. remote a=setup:active). Flip desktop to passive so Safari (which sent
      // actpass) must be the DTLS client and initiates the handshake instead.
      const patchedSdp = (answer.sdp || '').replace(/a=setup:active/g, 'a=setup:passive');
      const patchedAnswer: RTCSessionDescriptionInit = { type: 'answer', sdp: patchedSdp };
      console.info('[WebRTC] answer a=setup:passive (patched for iOS Safari) phone=' + tag);
      return pc.setLocalDescription(patchedAnswer).then(function () { return patchedAnswer; });
    })
    .then(function (patchedAnswer: RTCSessionDescriptionInit) {
      sendTo('answer', phoneId, patchedAnswer);
    })
    .catch(function (err: unknown) {
      console.warn('[WebRTC] handleOffer failed for phone', phoneId, ':', err);
      desktopPeers.delete(phoneId);
      pendingICE.delete(phoneId);
    });
}

function handleIceCandidate(msg: Record<string, unknown>): void {
  const from = typeof msg.from === 'string' ? msg.from : '';
  if (!from) {
    console.warn('[WebRTC] handleIceCandidate: missing or invalid from field', msg);
    return;
  }
  const pc = desktopPeers.get(from);
  if (pc) {
    pc.addIceCandidate(msg.payload as RTCIceCandidateInit).catch(function (err: unknown) {
      console.warn('[WebRTC] addIceCandidate failed:', err);
    });
    return;
  }
  // setRemoteDescription not yet resolved — buffer the candidate.
  const queue = pendingICE.get(from);
  if (queue) { queue.push(msg.payload as RTCIceCandidateInit); }
}

function handlePlayerReady(msg: Record<string, unknown>): void {
  const payload = (msg && msg.payload) ? msg.payload as Record<string, unknown> : {};
  const slot = (payload.slot as number) || 0;
  const username = (payload.username as string) || '';
  const phoneId = typeof msg.from === 'string' ? msg.from : '';
  console.info('[WebRTC] player-ready received:', payload);
  appendEventLog('player-ready', slot, username);

  // First player-ready: show game view and init the 3D scene (guarded — D-04, D-05)
  if (!gameViewShown) {
    gameViewShown = true;
    showGameView();
    const canvas = document.getElementById('game-canvas') as HTMLCanvasElement | null;
    const container = document.getElementById('game-container') as HTMLElement | null;
    if (canvas && container) {
      initScene(canvas, container);
    }
  }

  // Register phoneId → slot mapping so player-left can find the phoneId by slot for cleanup.
  // Also used by ondatachannel safety-net to skip auto-assignment if player-ready already ran.
  if (phoneId) {
    phoneSlots.set(phoneId, slot);
  }

  // Cache username by slot for TAB roster (plan 05 — renderTabRoster reads slotUsernames)
  if (slot && username) {
    slotUsernames.set(slot, username);
  }

  // Add the player's 3D object to the scene (plan 04: box mesh, HSL color, CSS2DLabel, axes)
  if (phoneId) {
    addPlayerToScene(phoneId, slot, username);
  }

  // Refresh HUD so connected count and slot count stay current
  if (gameViewShown) { updateHud(); }
}

// ──────────────────────────────────────────────────────────────────────────────
// Desktop page
// ──────────────────────────────────────────────────────────────────────────────
function initDesktopPage(): void {
  // Connect WT-first (D-01); fall back to WS if QUIC is unavailable or blocked (D-02).
  // Do NOT call connectWS here unconditionally — once useWt is true, WS must not open (D-03).
  // Store the promise in wtConnectPromise so createRoom/joinRoom can await it if the user
  // clicks a button while WT is still in the QUIC handshake (Bug A — race condition fix).
  wtConnectPromise = connectDesktopWT();
  wtConnectPromise.then(function(ok) { if (!ok) connectWS(null); });

  // Button wiring
  const btnCreate    = document.getElementById('btn-create-room');
  const btnJoin      = document.getElementById('btn-join-room');
  const btnContinue  = document.getElementById('btn-continue');
  const btnJoinSubmit = document.getElementById('btn-join-submit');
  const btnBackCreate = document.getElementById('btn-back-create');
  const btnBackJoin  = document.getElementById('btn-back-join');
  const gameSelect   = document.getElementById('view-game-select');
  const joinForm     = document.getElementById('view-join-form');

  if (btnCreate) {
    btnCreate.addEventListener('click', function () { showSubForm(gameSelect); });
  }

  if (btnJoin) {
    btnJoin.addEventListener('click', function () { showSubForm(joinForm); });
  }

  if (btnBackCreate) {
    btnBackCreate.addEventListener('click', showLobbyActions);
  }

  if (btnBackJoin) {
    btnBackJoin.addEventListener('click', showLobbyActions);
  }

  if (btnContinue) {
    btnContinue.addEventListener('click', function () {
      const gameTypeEl = document.getElementById('game-type') as HTMLSelectElement | null;
      const gameType = gameTypeEl ? gameTypeEl.value : 'placeholder';
      createRoom(gameType);
    });
  }

  if (btnJoinSubmit) {
    btnJoinSubmit.addEventListener('click', function () {
      const codeEl = document.getElementById('input-room-code') as HTMLInputElement | null;
      const userEl = document.getElementById('input-username') as HTMLInputElement | null;
      const roomCode = codeEl ? codeEl.value : '';
      const username = userEl ? userEl.value : '';
      joinRoom(roomCode, username);
    });
  }

  // Auto-uppercase room code input
  const codeInput = document.getElementById('input-room-code') as HTMLInputElement | null;
  if (codeInput) {
    codeInput.addEventListener('input', function () {
      const self = codeInput;
      const cursor = self.selectionStart;
      self.value = self.value.toUpperCase().replace(/[^A-Z2-9]/g, '').slice(0, 6);
      self.setSelectionRange(cursor, cursor);
    });
  }

  // Handle browser back/forward
  window.addEventListener('popstate', function (evt: PopStateEvent) {
    const state = evt.state as { room_code?: string; slot?: number } | null;
    if (state && state.room_code) {
      // Re-render room page without QR (pairing_url not stored in history state)
      renderRoomPage(
        state.slot || 0,
        state.room_code,
        null /* pairing_url not available from history */
      );
    } else {
      // Back to lobby
      showView('view-lobby');
      currentRoom = null;
    }
  });

  // If we're already on a /room/ path (e.g. user refreshed), check sessionStorage
  const pathMatch = window.location.pathname.match(/^\/room\/([A-Z0-9]+)$/i);
  if (pathMatch) {
    const codeFromPath = pathMatch[1].toUpperCase();
    // sessionStorage preferred (tab-specific, reload-safe); localStorage fallback for new-tab reconnect.
    const storedSlot   = sessionStorage.getItem('slot_' + codeFromPath)
                      || localStorage.getItem('slot_' + codeFromPath);
    if (storedSlot) {
      const slotNum = parseInt(storedSlot, 10);
      currentRoom = { slot: slotNum, room_code: codeFromPath };
      renderRoomPage(slotNum, codeFromPath, null);
      // Only reconnect when already on the room path (D-17).
      // WT-first: if WT connected, sendReconnect uses sendWtRequest; else fall back to WS.
      // IMPORTANT: reuse wtConnectPromise (started above) — do NOT call connectDesktopWT()
      // again here. A second call creates a new transport, overwrites myId with a fresh UUID,
      // and the server rejects the join-room because from !== registered_id (Bug B fix).
      wtConnectPromise!.then(function(ok) {
        if (ok) {
          sendReconnect(codeFromPath, slotNum);
        } else {
          connectWS(function () { sendReconnect(codeFromPath, slotNum); });
        }
      });
    } else {
      // On /room/ path but no session data — show join form pre-filled with the code.
      history.replaceState(null, '', '/');
      const codeInputEl = document.getElementById('input-room-code') as HTMLInputElement | null;
      if (codeInputEl) { codeInputEl.value = codeFromPath; }
      if (joinForm) { showSubForm(joinForm); }
    }
  }
}

async function createRoom(gameType: string): Promise<void> {
  const userEl = document.getElementById('input-create-username') as HTMLInputElement | null;
  const rawName = userEl ? userEl.value.trim() : '';

  if (!rawName) {
    showError('error-create-username', 'Please enter your name.');
    if (userEl) { userEl.classList.add('input--error'); }
    return;
  }
  if (rawName.length > 64) {
    showError('error-create-username', 'Name must be 64 characters or fewer.');
    if (userEl) { userEl.classList.add('input--error'); }
    return;
  }
  if (userEl) { userEl.classList.remove('input--error'); }
  clearError('error-create-username');

  disableButton('btn-continue', 'Creating...');
  pendingUsername = rawName;

  // Bug A fix: if WT is still connecting (QUIC handshake / register in progress) and WS
  // is not yet open, wait for the connection attempt to finish before choosing the path.
  // Without this, a user who clicks quickly gets a WS pending-queue message that is never
  // flushed (WS never opens once WT succeeds).
  if (wtConnectPromise && !useWt && !(ws && ws.readyState === WebSocket.OPEN)) {
    await wtConnectPromise;
  }

  if (useWt && transport) {
    // WT path: request/response (join-room → join-ack or join-error in one round-trip).
    try {
      const resp = await sendWtRequest(transport, {
        type: 'join-room', from: myId ?? '', to: '',
        payload: { username: rawName, room_code: '', game_type: gameType }
      });
      if (resp.type === 'join-ack') {
        handleJoinAck(resp.payload as Record<string, unknown>);
      } else if (resp.type === 'join-error') {
        handleJoinError(((resp.payload as Record<string, unknown>)?.reason) as string);
      } else {
        enableButton('btn-continue', 'Continue');
      }
    } catch (err) {
      console.warn('[WT] createRoom request failed:', err);
      enableButton('btn-continue', 'Continue');
    }
  } else {
    // WS path: fire-and-forget; response arrives asynchronously via onServerMessage.
    sendMessage('join-room', {
      username: rawName,
      room_code: '',
      game_type: gameType
    });
  }
}

async function joinRoom(roomCode: string, username: string): Promise<void> {
  // Client-side validation
  let valid = true;

  clearInputError('input-room-code');
  clearInputError('input-username');
  clearError('error-room-code');
  clearError('error-username');
  clearError('error-join');

  const cleanCode = roomCode.toUpperCase().replace(/[^A-Z2-9]/g, '').slice(0, 6);
  if (cleanCode.length < 1) {
    setInputError('input-room-code');
    showError('error-room-code', 'Please enter a room code.');
    valid = false;
  }

  const cleanUsername = username.trim();
  // Printable ASCII: chars 32–126
  const hasNonPrintable = /[^\x20-\x7E]/.test(cleanUsername);
  if (cleanUsername.length < 1) {
    setInputError('input-username');
    showError('error-username', 'Please enter a username.');
    valid = false;
  } else if (cleanUsername.length > 64) {
    setInputError('input-username');
    showError('error-username', 'Username must be 64 characters or fewer.');
    valid = false;
  } else if (hasNonPrintable) {
    setInputError('input-username');
    showError('error-username', 'Username must contain only printable characters.');
    valid = false;
  }

  if (!valid) { return; }

  pendingUsername = cleanUsername;
  disableButton('btn-join-submit', 'Joining...');

  // Bug A fix: same guard as createRoom — wait for WT if still connecting.
  if (wtConnectPromise && !useWt && !(ws && ws.readyState === WebSocket.OPEN)) {
    await wtConnectPromise;
  }

  if (useWt && transport) {
    // WT path: request/response (join-room → join-ack or join-error in one round-trip).
    try {
      const resp = await sendWtRequest(transport, {
        type: 'join-room', from: myId ?? '', to: '',
        payload: { username: cleanUsername, room_code: cleanCode, game_type: 'placeholder' }
      });
      if (resp.type === 'join-ack') {
        handleJoinAck(resp.payload as Record<string, unknown>);
      } else if (resp.type === 'join-error') {
        handleJoinError(((resp.payload as Record<string, unknown>)?.reason) as string);
      } else {
        enableButton('btn-join-submit', 'Join Room');
      }
    } catch (err) {
      console.warn('[WT] joinRoom request failed:', err);
      enableButton('btn-join-submit', 'Join Room');
    }
  } else {
    // WS path: fire-and-forget; response arrives asynchronously via onServerMessage.
    sendMessage('join-room', {
      username: cleanUsername,
      room_code: cleanCode,
      game_type: 'placeholder'
    });
  }
}

function handleJoinAck(payload: Record<string, unknown>): void {
  const slot           = payload.slot as number;
  const roomCode       = payload.room_code as string;
  const reconnectToken = payload.reconnect_token as string;
  const pairingUrl     = payload.pairing_url as string | null;

  // Store reconnect token — never log the value (T-03-09).
  // sessionStorage: tab-specific, survives reload — primary slot key.
  // localStorage slot: only written on first join (sessionStorage empty), so reconnects
  //   don't overwrite the newest joiner's slot (which enables new-tab reconnect for the
  //   most-recently-closed tab). Token keyed by room+slot — no cross-tab collision.
  const isFirstJoin = !sessionStorage.getItem('slot_' + roomCode);
  sessionStorage.setItem('slot_' + roomCode, String(slot));
  if (isFirstJoin) {
    localStorage.setItem('slot_' + roomCode, String(slot));
  }
  localStorage.setItem('token_' + roomCode + '_' + slot, reconnectToken);

  currentRoom = { slot: slot, room_code: roomCode, iceServers: (payload.ice_servers as RTCIceServer[] | null) || null };

  // Navigate to room URL — ONLY here, never before server approval (D-07)
  history.pushState({ slot: slot, room_code: roomCode }, '', '/room/' + roomCode);

  renderRoomPage(slot, roomCode, pairingUrl);

  // Populate roster from snapshot (includes all current occupants).
  const slots = payload.slots as Array<{ slot: number; status: string; username: string }> | undefined;
  if (Array.isArray(slots)) {
    slots.forEach(function (s) {
      updateSlotRow(s.slot, s.status === 'hold' ? 'hold' : 'connected', s.username);
    });
  } else {
    // Fallback: server didn't send snapshot — at least show own slot.
    updateSlotRow(slot, 'connected', pendingUsername || 'Player');
  }
  if (pendingUsername) { appendEventLog('player-joined', slot, pendingUsername); }
}

function handleJoinError(reason: string): void {
  // Reconnect failure while on room page — session expired or room gone.
  if (currentRoom || reason === 'invalid_token') {
    if (currentRoom) {
      sessionStorage.removeItem('slot_' + currentRoom.room_code);
      localStorage.removeItem('slot_' + currentRoom.room_code);
      localStorage.removeItem('token_' + currentRoom.room_code + '_' + currentRoom.slot);
    }
    currentRoom = null;
    history.replaceState(null, '', '/');
    showView('view-lobby');
    showLobbyActions();
    showError('error-join', 'Session expired. Please join or create a new room.');
    return;
  }

  enableButton('btn-continue', 'Continue');
  enableButton('btn-join-submit', 'Join Room');

  let message: string;
  if (reason === 'room_not_found') {
    message = 'Room not found. Double-check the code and try again.';
  } else if (reason === 'room_full') {
    message = 'This room is full (8/8 players). Ask the host for a different code.';
  } else {
    message = 'Could not join room. Check your connection and try again.';
  }

  showError('error-join', message);
}

function renderRoomPage(slot: number, roomCode: string, pairingUrl: string | null): void {
  // Hide lobby, show room
  const lobby = document.getElementById('view-lobby');
  const room  = document.getElementById('view-room');
  if (lobby) { lobby.hidden = true; }
  if (room)  { room.hidden = false; }

  // Update room title
  const roomTitle = document.getElementById('room-title');
  if (roomTitle) { roomTitle.textContent = 'Your Room: ' + roomCode; }

  // Update short code (D-15)
  const shortCode = document.getElementById('short-code');
  if (shortCode) { shortCode.textContent = roomCode + '-' + slot; }

  // Update connection status
  updateConnectionStatus('Connected');

  // Render QR code (only if we have the pairing URL)
  if (pairingUrl) {
    renderQR(pairingUrl);
  } else {
    // No pairing URL (e.g. after page refresh) — show fallback text
    const canvas = document.getElementById('pairing-qr') as HTMLCanvasElement | null;
    if (canvas) {
      const ctx = canvas.getContext('2d');
      if (ctx) {
        canvas.width = 256;
        canvas.height = 256;
        ctx.fillStyle = '#ffffff';
        ctx.fillRect(0, 0, 256, 256);
        ctx.fillStyle = '#000000';
        ctx.font = '13px monospace';
        ctx.fillText('QR unavailable after', 10, 80);
        ctx.fillText('page refresh.', 10, 100);
        ctx.fillText('Use the short code', 10, 120);
        ctx.fillText('above.', 10, 140);
      }
    }
  }

  // Wire leave button (re-wire each render to avoid duplicate listeners)
  const leaveBtn = document.getElementById('btn-leave-room');
  if (leaveBtn) {
    leaveBtn.onclick = leaveRoom;
  }

  // Initialize slot roster
  initSlotRoster(slot);
}

function renderQR(pairingUrl: string): void {
  const canvas = document.getElementById('pairing-qr') as HTMLCanvasElement | null;
  if (!canvas) { return; }

  if (typeof QRCode === 'undefined') {
    // CDN not loaded — show text fallback
    if (canvas.parentElement) {
      const p = document.createElement('p');
      p.style.cssText = 'color:#000;font-family:monospace;font-size:12px;word-break:break-all;padding:8px';
      p.textContent = 'Open: ' + pairingUrl;
      canvas.parentElement.replaceChildren(p);
    }
    return;
  }

  // Exact options from UI-SPEC — no deviation
  QRCode.toCanvas(
    canvas,
    pairingUrl,
    {
      width: 256,
      margin: 2,
      color: { dark: '#000000', light: '#ffffff' },
      errorCorrectionLevel: 'M'
    },
    function (err: Error | null | undefined) {
      if (err) {
        // Fallback per UI-SPEC §QR Code Fallback
        if (canvas.parentElement) {
          const p = document.createElement('p');
          p.style.cssText = 'color:#000;font-family:monospace;font-size:12px;word-break:break-all;padding:8px';
          p.textContent = 'Open: ' + pairingUrl;
          canvas.parentElement.replaceChildren(p);
        }
      }
    }
  );
}

function initSlotRoster(mySlot: number): void {
  const roster = document.getElementById('slot-roster');
  if (!roster) { return; }

  // Clear via firstChild loop (XSS-hygiene — all DOM writes use textContent, T-06-10b)
  while (roster.firstChild) { roster.removeChild(roster.firstChild); }

  for (let i = 1; i <= 8; i++) {
    const li = document.createElement('li');
    li.className = 'slot-row';
    li.dataset.slot = String(i);

    if (i === mySlot) {
      li.classList.add('own-slot');
    }

    const dot = document.createElement('span');
    dot.className = 'status-dot dot--empty';
    dot.dataset.slotDot = String(i);

    const slotLabel = document.createElement('span');
    slotLabel.className = 'slot-label';
    slotLabel.textContent = 'Slot ' + i;

    const slotUser = document.createElement('span');
    slotUser.className = 'slot-username';
    slotUser.dataset.slotUsername = String(i);
    slotUser.textContent = 'Empty';

    li.appendChild(dot);
    li.appendChild(slotLabel);
    li.appendChild(slotUser);
    roster.appendChild(li);
  }
}

function updateSlotRow(slotId: number, state: 'connected' | 'hold' | 'empty', username: string): void {
  const dot    = document.querySelector<HTMLElement>('[data-slot-dot="' + slotId + '"]');
  const userEl = document.querySelector<HTMLElement>('[data-slot-username="' + slotId + '"]');

  if (!dot || !userEl) { return; }

  // Reset dot classes
  dot.className = 'status-dot';

  switch (state) {
    case 'connected':
      dot.classList.add('dot--connected');
      userEl.textContent = username || 'Player';
      userEl.className = 'slot-username occupied';
      break;
    case 'hold':
      dot.classList.add('dot--hold');
      userEl.textContent = (username || 'Player') + ' (reconnecting...)';
      userEl.className = 'slot-username';
      break;
    case 'empty':
    default:
      dot.classList.add('dot--empty');
      userEl.textContent = 'Empty';
      userEl.className = 'slot-username';
      break;
  }
}

function handleRoomEvent(payload: Record<string, unknown>): void {
  const event    = payload.event as string;
  const slot     = payload.slot as number;
  const username = (payload.username as string) || '';

  switch (event) {
    case 'player-joined':
      updateSlotRow(slot, 'connected', username);
      appendEventLog('player-joined', slot, username);
      break;
    case 'player-disconnected':
      updateSlotRow(slot, 'hold', username);
      appendEventLog('player-disconnected', slot, username);
      break;
    case 'player-reconnected':
      updateSlotRow(slot, 'connected', username);
      appendEventLog('player-reconnected', slot, username);
      break;
    case 'player-left': {
      updateSlotRow(slot, 'empty', '');
      appendEventLog('player-left', slot, username);
      // Clean up the departing player's scene object + store + peer connection.
      // Resolve phoneId from the slot → phoneId reverse scan over phoneSlots.
      let departedPhoneId: string | undefined;
      for (const [pid, s] of phoneSlots) {
        if (s === slot) { departedPhoneId = pid; break; }
      }
      if (departedPhoneId) {
        removePlayerFromScene(departedPhoneId);
        playerStore.removePlayerState(departedPhoneId);
        phoneSlots.delete(departedPhoneId);
        // Remove data channel and username from plan 05 caches
        desktopChannels.delete(departedPhoneId);
        slotUsernames.delete(slot);
        const departedPc = desktopPeers.get(departedPhoneId);
        if (departedPc) {
          try { departedPc.close(); } catch (e) { /* ignore */ }
          desktopPeers.delete(departedPhoneId);
        }
      }
      // Refresh HUD after player leaves
      if (gameViewShown) { updateHud(); }
      break;
    }
    case 'room-full':
      appendEventLog('room-full', 0, '');
      break;
    default:
      console.warn('[WS] Unknown room-event:', event);
  }
}

function appendEventLog(event: string, slot: number, username: string): void {
  const log = document.getElementById('event-log');
  if (!log) { return; }

  // Format log text per UI-SPEC copywriting contract
  let text: string;
  switch (event) {
    case 'player-joined':
      text = username + ' joined — slot ' + slot;
      break;
    case 'player-disconnected':
      text = username + ' disconnected — waiting 60s for reconnect';
      break;
    case 'player-reconnected':
      text = username + ' reconnected — slot ' + slot;
      break;
    case 'player-left':
      text = username + ' left — slot ' + slot;
      break;
    case 'room-full':
      text = 'Room is full (8/8 players)';
      break;
    case 'player-ready':
      text = (username ? username : 'Player') + ' ready — slot ' + slot;
      break;
    default:
      text = event + ' (slot ' + slot + ')';
  }

  const entry = document.createElement('div');
  entry.className = 'event-entry';

  const ts = document.createElement('span');
  ts.className = 'event-ts';
  ts.textContent = formatTimestamp(new Date());

  const body = document.createElement('span');
  body.textContent = text;

  entry.appendChild(ts);
  entry.appendChild(body);

  // Max 50 entries — remove oldest when limit reached
  if (log.children.length >= 50) {
    const oldest = log.firstElementChild;
    if (oldest) { log.removeChild(oldest); }
  }

  log.appendChild(entry);

  // Auto-scroll to bottom
  log.scrollTop = log.scrollHeight;
}

function leaveRoom(): void {
  // Clear session so reload doesn't re-enter the room
  if (currentRoom) {
    sessionStorage.removeItem('slot_' + currentRoom.room_code);
    localStorage.removeItem('slot_' + currentRoom.room_code);
    localStorage.removeItem('token_' + currentRoom.room_code + '_' + currentRoom.slot);
  }
  currentRoom = null;
  history.pushState(null, '', '/');
  showView('view-lobby');
  showLobbyActions();
  if (useWt && transport) {
    // WT path: fire-and-forget leave-room; transport stays open for the next join (D-03).
    sendWtMessage(transport, { type: 'leave-room', from: myId ?? '', to: '', payload: {} });
  } else if (ws && ws.readyState === WebSocket.OPEN) {
    // WS path: send leave-room and keep the WS open — server frees the slot immediately.
    // Closing the WS races with the data frame (FIN can arrive before the message),
    // triggering on_client_disconnect which starts a hold timer instead.
    // Keeping the WS open eliminates the race; the connection is reused for the next join.
    ws.send(JSON.stringify({ type: 'leave-room', from: myId, to: '', payload: {} }));
  } else {
    if (ws) { ws.close(); ws = null; }
    connectWS(null);
  }
}

function showLobbyActions(): void {
  const lobbyActions = document.getElementById('lobby-actions');
  const gameSelect   = document.getElementById('view-game-select');
  const joinForm     = document.getElementById('view-join-form');
  if (gameSelect)   { gameSelect.hidden = true; }
  if (joinForm)     { joinForm.hidden = true; }
  if (lobbyActions) { lobbyActions.hidden = false; }
}

function showSubForm(form: HTMLElement | null): void {
  const lobbyActions = document.getElementById('lobby-actions');
  const gameSelect   = document.getElementById('view-game-select');
  const joinForm     = document.getElementById('view-join-form');
  if (lobbyActions) { lobbyActions.hidden = true; }
  if (gameSelect)   { gameSelect.hidden = true; }
  if (joinForm)     { joinForm.hidden = true; }
  // Clear stale errors from previous attempts
  clearError('error-join');
  clearError('error-room-code');
  clearError('error-username');
  clearError('error-create-username');
  if (form) { form.hidden = false; }
}

async function sendReconnect(roomCode: string, slot: number): Promise<void> {
  const code  = roomCode || (currentRoom && currentRoom.room_code) || '';
  const slotN = slot     || (currentRoom && currentRoom.slot) || 0;
  if (!code || !slotN) { return; }
  const token = localStorage.getItem('token_' + code + '_' + slotN);
  if (!token) { return; }
  // Never log the value (T-03-09)
  if (useWt && transport) {
    // WT path: request/response (reconnect → join-ack or join-error).
    try {
      const resp = await sendWtRequest(transport, {
        type: 'reconnect', from: myId ?? '', to: '', payload: { reconnect_token: token }
      });
      if (resp.type === 'join-ack') {
        handleJoinAck(resp.payload as Record<string, unknown>);
      } else if (resp.type === 'join-error') {
        handleJoinError(((resp.payload as Record<string, unknown>)?.reason) as string);
      }
    } catch (err) {
      console.warn('[WT] sendReconnect request failed:', err);
    }
  } else {
    // WS path: fire-and-forget; response arrives asynchronously via onServerMessage.
    sendMessage('reconnect', { reconnect_token: token });
    console.info('[WS] Reconnect token sent.');
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Phone page
// ──────────────────────────────────────────────────────────────────────────────
function initPhonePage(): void {
  showView('view-phone');

  // Show initial pairing state
  const pairingState = document.getElementById('pairing-state');
  const successState = document.getElementById('success-state');
  const errorState   = document.getElementById('error-state');

  if (pairingState) { pairingState.hidden = false; }
  if (successState) { successState.hidden = true; }
  if (errorState)   { errorState.hidden = true; }

  // Extract token from URL
  const params = new URLSearchParams(location.search);
  const token  = params.get('token');

  if (!token) {
    // No token in URL — show error immediately
    showPhoneError('no_token');
    return;
  }

  // Connect WS; on open, send pair message
  connectWS(function () {
    sendMessage('pair', { token: token });
  });
}

function handlePairAck(_payload: Record<string, unknown>): void {
  const pairingState = document.getElementById('pairing-state');
  const successState = document.getElementById('success-state');

  if (pairingState) { pairingState.hidden = true; }
  if (successState) { successState.hidden = false; }
}

function handlePairError(payload: Record<string, unknown>): void {
  const reason = (payload && payload.reason) ? payload.reason as string : 'unknown';
  showPhoneError(reason);
}

function showPhoneError(reason: string): void {
  const pairingState = document.getElementById('pairing-state');
  const errorState   = document.getElementById('error-state');
  const errorMsg     = document.getElementById('pair-error-msg');

  if (pairingState) { pairingState.hidden = true; }
  if (errorState)   { errorState.hidden = false; }

  let message: string;
  if (reason === 'token_expired') {
    message = 'This pairing code has expired. Ask the desktop player to share a new one.';
  } else if (reason === 'token_used') {
    message = 'This pairing code has already been used. Ask the desktop player to share a new one.';
  } else if (reason === 'no_token') {
    message = 'Pairing failed: no token in URL.';
  } else {
    message = 'Pairing failed. Try scanning the QR code again.';
  }

  if (errorMsg) { errorMsg.textContent = message; }
}

// ──────────────────────────────────────────────────────────────────────────────
// Init — route to desktop or phone page
// ──────────────────────────────────────────────────────────────────────────────
function init(): void {
  if (window.location.pathname.indexOf('/phone') === 0) {
    initPhonePage();
  } else {
    initDesktopPage();
  }
}

document.addEventListener('DOMContentLoaded', init);
