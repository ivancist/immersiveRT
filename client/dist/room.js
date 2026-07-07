/* room.js — ImmersiveRT SPA router, WS client, QR render, event log, reconnect
 * Plain script (no ES module imports); QRCode is a global loaded from CDN.
 * All DOM access via vanilla browser APIs only.
 */

'use strict';

// ──────────────────────────────────────────────────────────────────────────────
// Shared WS state
// ──────────────────────────────────────────────────────────────────────────────
let ws = null;
let myId = null;
let currentRoom = null; // { slot, room_code }
let wsReady = false;    // true once register ack confirmed (open + registered)
let pendingMessageQueue = []; // messages queued before WS is ready
let pendingUsername = null;   // username sent with join-room, used in handleJoinAck

// ──────────────────────────────────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────────────────────────────────
function showView(id) {
  var views = document.querySelectorAll(
    '#view-lobby, #view-room, #view-phone'
  );
  views.forEach(function (v) { v.hidden = true; });
  var target = document.getElementById(id);
  if (target) { target.hidden = false; }
}

function showError(elementId, message) {
  var el = document.getElementById(elementId);
  if (!el) { return; }
  el.textContent = message;
  el.classList.add('error-msg--visible');
  el.style.display = 'block';
}

function clearError(elementId) {
  var el = document.getElementById(elementId);
  if (!el) { return; }
  el.textContent = '';
  el.classList.remove('error-msg--visible');
  el.style.display = '';
}

function setInputError(inputId) {
  var el = document.getElementById(inputId);
  if (el) { el.classList.add('input--error'); }
}

function clearInputError(inputId) {
  var el = document.getElementById(inputId);
  if (el) { el.classList.remove('input--error'); }
}

function disableButton(id, loadingText) {
  var btn = document.getElementById(id);
  if (!btn) { return; }
  btn.disabled = true;
  if (loadingText) { btn.textContent = loadingText; }
}

function enableButton(id, originalText) {
  var btn = document.getElementById(id);
  if (!btn) { return; }
  btn.disabled = false;
  if (originalText) { btn.textContent = originalText; }
}

function formatTimestamp(date) {
  var d = date || new Date();
  var h = String(d.getHours()).padStart(2, '0');
  var m = String(d.getMinutes()).padStart(2, '0');
  var s = String(d.getSeconds()).padStart(2, '0');
  return '[' + h + ':' + m + ':' + s + ']';
}

// ──────────────────────────────────────────────────────────────────────────────
// WebSocket client
// ──────────────────────────────────────────────────────────────────────────────
function connectWS(onOpenCallback) {
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) {
    // Already connected or connecting; call callback if open
    if (ws.readyState === WebSocket.OPEN && onOpenCallback) {
      onOpenCallback();
    } else if (onOpenCallback) {
      // Queue to run after open
      var prevOnOpen = ws.onopen;
      ws.onopen = function (evt) {
        if (prevOnOpen) { prevOnOpen(evt); }
        onOpenCallback();
      };
    }
    return;
  }

  var serverWsUrl = 'wss://' + location.hostname + ':9090';
  ws = new WebSocket(serverWsUrl);
  wsReady = false;

  ws.onopen = function () {
    myId = crypto.randomUUID();
    ws.send(JSON.stringify({ type: 'register', from: myId, to: '', payload: {} }));
    wsReady = true;

    // Flush queued messages
    while (pendingMessageQueue.length > 0) {
      var queued = pendingMessageQueue.shift();
      ws.send(queued);
    }

    if (onOpenCallback) { onOpenCallback(); }
  };

  ws.onmessage = function (evt) {
    var msg;
    try {
      msg = JSON.parse(evt.data);
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

  ws.onerror = function (err) {
    console.error('[WS] Connection error:', err);
    wsReady = false;
    updateConnectionStatus('Disconnected');
  };
}

function sendMessage(type, payload) {
  var msg = JSON.stringify({ type: type, from: myId, to: '', payload: payload });
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(msg);
  } else {
    // Queue for when connection is ready
    pendingMessageQueue.push(msg);
  }
}

function updateConnectionStatus(text) {
  var el = document.getElementById('connection-status');
  if (el) { el.textContent = text; }
}

// ──────────────────────────────────────────────────────────────────────────────
// Server message dispatcher
// ──────────────────────────────────────────────────────────────────────────────
function onServerMessage(msg) {
  switch (msg.type) {
    case 'join-ack':
      handleJoinAck(msg.payload);
      break;
    case 'join-error':
      handleJoinError(msg.payload.reason);
      break;
    case 'room-event':
      handleRoomEvent(msg.payload);
      break;
    case 'pair-ack':
      handlePairAck(msg.payload);
      break;
    case 'pair-error':
      handlePairError(msg.payload);
      break;
    default:
      console.warn('[WS] Unknown message type:', msg.type);
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Desktop page
// ──────────────────────────────────────────────────────────────────────────────
function initDesktopPage() {
  // Pre-warm WS connection (D-11)
  connectWS(null);

  // Button wiring
  var btnCreate    = document.getElementById('btn-create-room');
  var btnJoin      = document.getElementById('btn-join-room');
  var btnContinue  = document.getElementById('btn-continue');
  var btnJoinSubmit = document.getElementById('btn-join-submit');
  var btnBackCreate = document.getElementById('btn-back-create');
  var btnBackJoin  = document.getElementById('btn-back-join');
  var lobbyActions = document.getElementById('lobby-actions');
  var gameSelect   = document.getElementById('view-game-select');
  var joinForm     = document.getElementById('view-join-form');

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
      var gameTypeEl = document.getElementById('game-type');
      var gameType = gameTypeEl ? gameTypeEl.value : 'placeholder';
      createRoom(gameType);
    });
  }

  if (btnJoinSubmit) {
    btnJoinSubmit.addEventListener('click', function () {
      var codeEl = document.getElementById('input-room-code');
      var userEl = document.getElementById('input-username');
      var roomCode = codeEl ? codeEl.value : '';
      var username = userEl ? userEl.value : '';
      joinRoom(roomCode, username);
    });
  }

  // Auto-uppercase room code input
  var codeInput = document.getElementById('input-room-code');
  if (codeInput) {
    codeInput.addEventListener('input', function () {
      var cursor = this.selectionStart;
      this.value = this.value.toUpperCase().replace(/[^A-Z2-9]/g, '').slice(0, 6);
      this.setSelectionRange(cursor, cursor);
    });
  }

  // Handle browser back/forward
  window.addEventListener('popstate', function (evt) {
    if (evt.state && evt.state.room_code) {
      // Re-render room page without QR (pairing_url not stored in history state)
      renderRoomPage(
        evt.state.slot,
        evt.state.room_code,
        null /* pairing_url not available from history */
      );
    } else {
      // Back to lobby
      showView('view-lobby');
      currentRoom = null;
    }
  });

  // If we're already on a /room/ path (e.g. user refreshed), check sessionStorage
  var pathMatch = window.location.pathname.match(/^\/room\/([A-Z0-9]+)$/i);
  if (pathMatch) {
    var storedCode  = sessionStorage.getItem('room_code');
    var storedSlot  = sessionStorage.getItem('my_slot');
    if (storedCode && storedSlot) {
      currentRoom = { slot: parseInt(storedSlot, 10), room_code: storedCode };
      renderRoomPage(
        parseInt(storedSlot, 10),
        storedCode,
        null /* no pairing_url after page refresh */
      );
      // Only reconnect when already on the room path (D-17)
      connectWS(function () { sendReconnect(); });
    } else {
      // On /room/ path but no session data — go back to lobby
      history.replaceState(null, '', '/');
    }
  }
}

function createRoom(gameType) {
  var userEl = document.getElementById('input-create-username');
  var rawName = userEl ? userEl.value.trim() : '';

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
  sendMessage('join-room', {
    username: rawName,
    room_code: '',
    game_type: gameType
  });
}

function joinRoom(roomCode, username) {
  // Client-side validation
  var valid = true;

  clearInputError('input-room-code');
  clearInputError('input-username');
  clearError('error-room-code');
  clearError('error-username');
  clearError('error-join');

  var cleanCode = roomCode.toUpperCase().replace(/[^A-Z2-9]/g, '').slice(0, 6);
  if (cleanCode.length < 1) {
    setInputError('input-room-code');
    showError('error-room-code', 'Please enter a room code.');
    valid = false;
  }

  var cleanUsername = username.trim();
  // Printable ASCII: chars 32–126
  var hasNonPrintable = /[^\x20-\x7E]/.test(cleanUsername);
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
  sendMessage('join-room', {
    username: cleanUsername,
    room_code: cleanCode,
    game_type: 'placeholder'
  });
}

function handleJoinAck(payload) {
  var slot           = payload.slot;
  var roomCode       = payload.room_code;
  var reconnectToken = payload.reconnect_token;
  var pairingUrl     = payload.pairing_url;

  // Store reconnect token — never log the value (T-03-09)
  sessionStorage.setItem('reconnect_token', reconnectToken);
  sessionStorage.setItem('room_code', roomCode);
  sessionStorage.setItem('my_slot', String(slot));

  currentRoom = { slot: slot, room_code: roomCode };

  // Navigate to room URL — ONLY here, never before server approval (D-07)
  history.pushState({ slot: slot, room_code: roomCode }, '', '/room/' + roomCode);

  renderRoomPage(slot, roomCode, pairingUrl);

  // Server excludes the joiner from its own player-joined broadcast; self-update.
  updateSlotRow(slot, 'connected', pendingUsername || 'Player');
  if (pendingUsername) { appendEventLog('player-joined', slot, pendingUsername); }
}

function handleJoinError(reason) {
  enableButton('btn-continue', 'Continue');
  enableButton('btn-join-submit', 'Join Room');

  var message;
  if (reason === 'room_not_found') {
    message = 'Room not found. Double-check the code and try again.';
  } else if (reason === 'room_full') {
    message = 'This room is full (8/8 players). Ask the host for a different code.';
  } else {
    message = 'Could not join room. Check your connection and try again.';
  }

  showError('error-join', message);
}

function renderRoomPage(slot, roomCode, pairingUrl) {
  // Hide lobby, show room
  var lobby = document.getElementById('view-lobby');
  var room  = document.getElementById('view-room');
  if (lobby) { lobby.hidden = true; }
  if (room)  { room.hidden = false; }

  // Update room title
  var roomTitle = document.getElementById('room-title');
  if (roomTitle) { roomTitle.textContent = 'Your Room: ' + roomCode; }

  // Update short code (D-15)
  var shortCode = document.getElementById('short-code');
  if (shortCode) { shortCode.textContent = roomCode + '-' + slot; }

  // Update connection status
  updateConnectionStatus('Connected');

  // Render QR code (only if we have the pairing URL)
  if (pairingUrl) {
    renderQR(pairingUrl);
  } else {
    // No pairing URL (e.g. after page refresh) — show fallback text
    var canvas = document.getElementById('pairing-qr');
    if (canvas) {
      var ctx = canvas.getContext('2d');
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
  var leaveBtn = document.getElementById('btn-leave-room');
  if (leaveBtn) {
    leaveBtn.onclick = leaveRoom;
  }

  // Initialize slot roster
  initSlotRoster(slot);
}

function renderQR(pairingUrl) {
  var canvas = document.getElementById('pairing-qr');
  if (!canvas) { return; }

  if (typeof QRCode === 'undefined') {
    // CDN not loaded — show text fallback
    canvas.parentElement.innerHTML =
      '<p style="color:#000;font-family:monospace;font-size:12px;word-break:break-all;padding:8px">Open: ' +
      pairingUrl + '</p>';
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
    function (err) {
      if (err) {
        // Fallback per UI-SPEC §QR Code Fallback
        canvas.parentElement.innerHTML =
          '<p style="color:#000;font-family:monospace;font-size:12px;word-break:break-all;padding:8px">Open: ' +
          pairingUrl + '</p>';
      }
    }
  );
}

function initSlotRoster(mySlot) {
  var roster = document.getElementById('slot-roster');
  if (!roster) { return; }

  roster.innerHTML = ''; // clear any existing rows

  for (var i = 1; i <= 8; i++) {
    var li = document.createElement('li');
    li.className = 'slot-row';
    li.dataset.slot = String(i);

    if (i === mySlot) {
      li.classList.add('own-slot');
    }

    var dot = document.createElement('span');
    dot.className = 'status-dot dot--empty';
    dot.dataset.slotDot = String(i);

    var slotLabel = document.createElement('span');
    slotLabel.className = 'slot-label';
    slotLabel.textContent = 'Slot ' + i;

    var slotUser = document.createElement('span');
    slotUser.className = 'slot-username';
    slotUser.dataset.slotUsername = String(i);
    slotUser.textContent = 'Empty';

    li.appendChild(dot);
    li.appendChild(slotLabel);
    li.appendChild(slotUser);
    roster.appendChild(li);
  }
}

function updateSlotRow(slotId, state, username) {
  var dot      = document.querySelector('[data-slot-dot="' + slotId + '"]');
  var userEl   = document.querySelector('[data-slot-username="' + slotId + '"]');

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

function handleRoomEvent(payload) {
  var event    = payload.event;
  var slot     = payload.slot;
  var username = payload.username || '';

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
    case 'player-left':
      updateSlotRow(slot, 'empty', '');
      appendEventLog('player-left', slot, username);
      break;
    case 'room-full':
      appendEventLog('room-full', 0, '');
      break;
    default:
      console.warn('[WS] Unknown room-event:', event);
  }
}

function appendEventLog(event, slot, username) {
  var log = document.getElementById('event-log');
  if (!log) { return; }

  // Format log text per UI-SPEC copywriting contract
  var text;
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
    default:
      text = event + ' (slot ' + slot + ')';
  }

  var entry = document.createElement('div');
  entry.className = 'event-entry';

  var ts = document.createElement('span');
  ts.className = 'event-ts';
  ts.textContent = formatTimestamp(new Date());

  var body = document.createElement('span');
  body.textContent = text;

  entry.appendChild(ts);
  entry.appendChild(body);

  // Max 50 entries — remove oldest when limit reached
  if (log.children.length >= 50) {
    log.removeChild(log.firstChild);
  }

  log.appendChild(entry);

  // Auto-scroll to bottom
  log.scrollTop = log.scrollHeight;
}

function leaveRoom() {
  // Clear session so reload doesn't re-enter the room
  sessionStorage.removeItem('reconnect_token');
  sessionStorage.removeItem('room_code');
  sessionStorage.removeItem('my_slot');
  currentRoom = null;
  if (ws) { ws.close(); ws = null; }
  history.pushState(null, '', '/');
  showView('view-lobby');
  showLobbyActions();
}

function showLobbyActions() {
  var lobbyActions = document.getElementById('lobby-actions');
  var gameSelect   = document.getElementById('view-game-select');
  var joinForm     = document.getElementById('view-join-form');
  if (gameSelect)   { gameSelect.hidden = true; }
  if (joinForm)     { joinForm.hidden = true; }
  if (lobbyActions) { lobbyActions.hidden = false; }
}

function showSubForm(form) {
  var lobbyActions = document.getElementById('lobby-actions');
  var gameSelect   = document.getElementById('view-game-select');
  var joinForm     = document.getElementById('view-join-form');
  if (lobbyActions) { lobbyActions.hidden = true; }
  if (gameSelect)   { gameSelect.hidden = true; }
  if (joinForm)     { joinForm.hidden = true; }
  if (form)         { form.hidden = false; }
}

function sendReconnect() {
  var token = sessionStorage.getItem('reconnect_token');
  if (token) {
    // Send reconnect token — never log the value (T-03-09)
    sendMessage('reconnect', { reconnect_token: token });
    console.info('[WS] Reconnect token sent.');
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Phone page
// ──────────────────────────────────────────────────────────────────────────────
function initPhonePage() {
  showView('view-phone');

  // Show initial pairing state
  var pairingState = document.getElementById('pairing-state');
  var successState = document.getElementById('success-state');
  var errorState   = document.getElementById('error-state');

  if (pairingState) { pairingState.hidden = false; }
  if (successState) { successState.hidden = true; }
  if (errorState)   { errorState.hidden = true; }

  // Extract token from URL
  var params = new URLSearchParams(location.search);
  var token  = params.get('token');

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

function handlePairAck(payload) {
  var pairingState = document.getElementById('pairing-state');
  var successState = document.getElementById('success-state');

  if (pairingState) { pairingState.hidden = true; }
  if (successState) { successState.hidden = false; }
}

function handlePairError(payload) {
  var reason = (payload && payload.reason) ? payload.reason : 'unknown';
  showPhoneError(reason);
}

function showPhoneError(reason) {
  var pairingState = document.getElementById('pairing-state');
  var errorState   = document.getElementById('error-state');
  var errorMsg     = document.getElementById('pair-error-msg');

  if (pairingState) { pairingState.hidden = true; }
  if (errorState)   { errorState.hidden = false; }

  var message;
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
function init() {
  if (window.location.pathname.indexOf('/phone') === 0) {
    initPhonePage();
  } else {
    initDesktopPage();
  }
}

document.addEventListener('DOMContentLoaded', init);
