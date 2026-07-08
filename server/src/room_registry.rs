use crate::broker::SignalingBroker;
use crate::pairing_token::{generate_pairing_token, generate_reconnect_token, PairingTokenStore};
use crate::turn_creds::generate_turn_credentials;
use dashmap::DashMap;
use std::{
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};
use tokio::task::JoinHandle;

/// Type aliases for clarity.
pub type RoomCode = String;
/// Slot numbers are 1-indexed: values 1..=8.
pub type SlotId = u8;

/// Lifecycle status of a single slot inside a Room.
#[derive(Debug, Clone, PartialEq)]
pub enum SlotStatus {
    /// No player is assigned to this slot.
    Empty,
    /// A player is actively connected (WS/WT connection is live).
    Connected,
    /// Player disconnected; hold timer is running (D-16).
    Disconnected,
}

/// Per-slot data stored inside a Room.
#[derive(Debug, Clone)]
pub struct SlotInfo {
    pub client_id: String,
    pub username: String,
    pub status: SlotStatus,
    pub reconnect_token: String,
    /// Set at pair time — the phone's registered client_id.
    /// Enables server→phone routing (route_to_phone helper).
    pub phone_client_id: Option<String>,
    /// Updated on each heartbeat message from the phone (Plan 03).
    #[allow(dead_code)] // Activated in Plan 03 (handle_heartbeat + phones_missing_heartbeat).
    pub last_heartbeat: Option<std::time::Instant>,
}

/// A room: fixed 8-slot array, indexed by slot_id - 1.
pub struct Room {
    pub code: RoomCode,
    pub game_type: String,
    /// `slots[i]` is `Some(SlotInfo)` when slot_id = i+1 is occupied, else `None`.
    /// Always exactly 8 entries (max_slots constant).
    pub slots: Vec<Option<SlotInfo>>,
    pub max_slots: usize,
}

impl Room {
    fn new(code: RoomCode, game_type: String) -> Self {
        Self {
            code,
            game_type,
            slots: vec![None; 8],
            max_slots: 8,
        }
    }

    /// Count of slots that are Connected or Disconnected (i.e. reserved).
    fn occupied_count(&self) -> usize {
        self.slots.iter().filter(|s| s.is_some()).count()
    }
}

/// Central room state manager.
///
/// Wraps `Arc<DashMap<RoomCode, Room>>` so that `Clone` shares the same map
/// across all WS/WT handler tasks — mirrors the `SignalingBroker` Arc<DashMap>
/// pattern exactly (PATTERNS.md §room_registry).
///
/// A second `hold_timers` DashMap holds the per-slot `JoinHandle` for hold
/// timers. Keeping it separate prevents holding the `rooms` shard lock while
/// aborting a timer (RESEARCH.md Pitfall 1).
#[derive(Clone)]
pub struct RoomRegistry {
    rooms: Arc<DashMap<RoomCode, Room>>,
    /// Per-slot hold timers. Keyed by (room_code, slot_id).
    /// `remove()` yields owned handle; `handle.abort()` is synchronous — no lock held.
    hold_timers: Arc<DashMap<(RoomCode, SlotId), JoinHandle<()>>>,
    /// Server-side lookup: reconnect_token → (room_code, slot_id).
    reconnect_tokens: Arc<DashMap<String, (RoomCode, SlotId)>>,
    pairing_store: Arc<PairingTokenStore>,
    pairing_secret: String,
    /// HMAC secret for coturn's use-auth-secret REST API (INFRA-04).
    /// Used in handle_pair to generate ephemeral TURN credentials.
    turn_shared_secret: String,
    base_url: String,
    hold_ttl_secs: u64,
    pairing_ttl_secs: u64,
    /// Tracks two-sided WebRTC channel readiness (Plan 02, D-08/D-09).
    /// Key: (room_code, phone_client_id, desktop_client_id)
    /// Value: (phone_confirmed, desktop_confirmed)
    channel_ready: Arc<DashMap<(RoomCode, String, String), (bool, bool)>>,
    /// Dedup guard: prevents duplicate player-ready broadcasts (Plan 02, D-09).
    /// Key: (room_code, phone_client_id) — inserted on first player-ready broadcast.
    player_ready_sent: Arc<DashMap<(RoomCode, String), ()>>,
}

impl RoomRegistry {
    pub fn new(
        pairing_secret: String,
        turn_shared_secret: String,
        base_url: String,
        hold_ttl_secs: u64,
        pairing_ttl_secs: u64,
    ) -> Self {
        Self {
            rooms: Arc::new(DashMap::new()),
            hold_timers: Arc::new(DashMap::new()),
            reconnect_tokens: Arc::new(DashMap::new()),
            pairing_store: Arc::new(PairingTokenStore::new()),
            pairing_secret,
            turn_shared_secret,
            base_url,
            hold_ttl_secs,
            pairing_ttl_secs,
            channel_ready: Arc::new(DashMap::new()),
            player_ready_sent: Arc::new(DashMap::new()),
        }
    }

    /// Broadcast a JSON event to all Connected desktops in the room, excluding `exclude_client_id`.
    ///
    /// Pattern: collect Connected slot client_ids into a Vec while holding the DashMap Ref,
    /// drop the Ref by ending the if-let block, then iterate over the Vec calling broker.route.
    /// This avoids holding a DashMap shard lock while calling broker.route (RESEARCH.md Pitfall 1).
    fn broadcast_to_room(
        &self,
        room_code: &str,
        exclude_client_id: &str,
        event_bytes: Vec<u8>,
        broker: &SignalingBroker,
    ) {
        // Collect Connected client_ids while holding the DashMap Ref.
        let targets: Vec<String> = if let Some(room) = self.rooms.get(room_code) {
            room.slots
                .iter()
                .filter_map(|s| {
                    s.as_ref().and_then(|info| {
                        if info.status == SlotStatus::Connected
                            && info.client_id != exclude_client_id
                        {
                            Some(info.client_id.clone())
                        } else {
                            None
                        }
                    })
                })
                .collect()
        } else {
            vec![]
        };
        // DashMap Ref is dropped here; safe to call broker now.
        for id in targets {
            if !broker.route(&id, event_bytes.clone()) {
                tracing::warn!(to = %id, "room broadcast: target not connected");
            }
        }
    }

    /// Handle a `join-room` message from a desktop client.
    ///
    /// - If `room_code` is empty: create new room.
    /// - If non-empty: look up existing room.
    /// - Assign lowest available slot (1-indexed).
    /// - Generate reconnect_token and pairing_token.
    /// - Broadcast `player-joined` to other desktops.
    ///
    /// Returns a JSON `join-ack` or `join-error` value.
    pub async fn handle_join(
        &self,
        client_id: &str,
        raw_payload: &serde_json::Value,
        broker: &SignalingBroker,
    ) -> serde_json::Value {
        // Deserialize payload (T-03-06 mitigation: serde None → invalid_payload error)
        let username = match raw_payload["username"].as_str() {
            Some(u) => u.to_string(),
            None => {
                return serde_json::json!({
                    "type": "join-error",
                    "payload": {"reason": "invalid_payload"}
                });
            }
        };
        let room_code_input = raw_payload["room_code"]
            .as_str()
            .unwrap_or("")
            .to_string();
        let game_type = raw_payload["game_type"]
            .as_str()
            .unwrap_or("default")
            .to_string();

        // D-21: validate username — trim, 1–64 chars, printable ASCII (T-03-04 mitigation)
        let username_trimmed: String = username.trim().chars()
            .filter(|c| c.is_ascii() && !c.is_ascii_control())
            .collect();
        if username_trimmed.is_empty() || username_trimmed.len() > 64 {
            return serde_json::json!({
                "type": "join-error",
                "payload": {"reason": "invalid_username"}
            });
        }

        // Resolve or create room.
        let room_code: RoomCode = if room_code_input.is_empty() {
            // Create new room with a generated code.
            let code = self.generate_room_code();
            self.rooms.insert(code.clone(), Room::new(code.clone(), game_type));
            code
        } else {
            // Validate the existing room exists.
            if !self.rooms.contains_key(&room_code_input) {
                return serde_json::json!({
                    "type": "join-error",
                    "payload": {"reason": "room_not_found"}
                });
            }
            room_code_input
        };

        // Find the first available slot and assign it.
        // IMPORTANT: clone out the needed data and drop the DashMap Ref BEFORE
        // calling any async function or broker method (RESEARCH.md Pitfall 1).
        let slot_result = {
            let mut room_ref = match self.rooms.get_mut(&room_code) {
                Some(r) => r,
                None => {
                    return serde_json::json!({
                        "type": "join-error",
                        "payload": {"reason": "room_not_found"}
                    });
                }
            };

            // Enforce max 8 slots (D-08, SESS-05, T-03-02 mitigation).
            if room_ref.occupied_count() >= room_ref.max_slots {
                // Drop the ref before broadcasting.
                let code = room_ref.code.clone();
                drop(room_ref);
                let event = serde_json::to_vec(&serde_json::json!({
                    "type": "room-event",
                    "payload": {"event": "room-full", "slot": 0, "username": ""}
                }))
                .unwrap_or_default();
                self.broadcast_to_room(&code, "", event, broker);
                return serde_json::json!({
                    "type": "join-error",
                    "payload": {"reason": "room_full"}
                });
            }

            // Find first empty slot (lowest index).
            let slot_index = room_ref
                .slots
                .iter()
                .position(|s| s.is_none())
                .expect("occupied_count < max_slots guarantees at least one None");
            let slot_id = (slot_index + 1) as u8;

            // Generate tokens before storing.
            let reconnect_token = generate_reconnect_token();
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs();
            let expiry = now + self.pairing_ttl_secs;
            let pairing_token = match generate_pairing_token(
                &self.pairing_secret,
                &room_code,
                slot_id,
                expiry,
            ) {
                Ok(t) => t,
                Err(e) => {
                    tracing::error!("failed to generate pairing token: {e}");
                    return serde_json::json!({
                        "type": "join-error",
                        "payload": {"reason": "internal_error"}
                    });
                }
            };

            // Store the slot.
            room_ref.slots[slot_index] = Some(SlotInfo {
                client_id: client_id.to_string(),
                username: username_trimmed.clone(),
                status: SlotStatus::Connected,
                reconnect_token: reconnect_token.clone(),
                phone_client_id: None,
                last_heartbeat: None,
            });

            // Snapshot current occupants (after inserting joiner) for join-ack.
            let slots_snapshot: Vec<serde_json::Value> = room_ref
                .slots
                .iter()
                .enumerate()
                .filter_map(|(i, s)| {
                    s.as_ref().map(|info| {
                        let status = match info.status {
                            SlotStatus::Connected => "connected",
                            SlotStatus::Disconnected => "hold",
                            SlotStatus::Empty => "empty",
                        };
                        serde_json::json!({
                            "slot": i + 1,
                            "username": info.username,
                            "status": status
                        })
                    })
                })
                .collect();

            (slot_id, reconnect_token, pairing_token, room_ref.code.clone(), slots_snapshot)
            // DashMap RefMut is dropped here at end of block.
        };

        let (slot_id, reconnect_token, pairing_token, actual_room_code, slots_snapshot) = slot_result;

        // Store reconnect token server-side (T-03-05 mitigation).
        self.reconnect_tokens
            .insert(reconnect_token.clone(), (actual_room_code.clone(), slot_id));

        // Build pairing URL (D-13).
        let pairing_url = format!("{}/phone?token={}", self.base_url, pairing_token);

        // Broadcast player-joined to other Connected desktops (SESS-06, D-22).
        let event = serde_json::to_vec(&serde_json::json!({
            "type": "room-event",
            "payload": {
                "event": "player-joined",
                "slot": slot_id,
                "username": username_trimmed
            }
        }))
        .unwrap_or_default();
        self.broadcast_to_room(&actual_room_code, client_id, event, broker);

        serde_json::json!({
            "type": "join-ack",
            "payload": {
                "slot": slot_id,
                "room_code": actual_room_code,
                "reconnect_token": reconnect_token,
                "pairing_url": pairing_url,
                "slots": slots_snapshot
            }
        })
    }

    /// Handle a `reconnect` message: abort hold timer, restore slot to Connected.
    ///
    /// Returns a `join-ack` with the same slot/room, a fresh reconnect_token,
    /// and a fresh pairing_url (D-17).
    pub async fn handle_reconnect(
        &self,
        client_id: &str,
        raw_payload: &serde_json::Value,
        broker: &SignalingBroker,
    ) -> serde_json::Value {
        let reconnect_token = match raw_payload["reconnect_token"].as_str() {
            Some(t) => t.to_string(),
            None => {
                return serde_json::json!({
                    "type": "join-error",
                    "payload": {"reason": "invalid_payload"}
                });
            }
        };

        // Look up (room_code, slot_id) from server-side table.
        let (room_code, slot_id) = match self.reconnect_tokens.get(&reconnect_token) {
            Some(entry) => entry.value().clone(),
            None => {
                return serde_json::json!({
                    "type": "join-error",
                    "payload": {"reason": "invalid_token"}
                });
            }
        };
        // DashMap Ref dropped here (value was cloned).

        // Abort hold timer — remove() gives owned JoinHandle; abort() is synchronous.
        // Pattern 3: no lock held across abort() call (RESEARCH.md Pattern 3).
        if let Some((_, handle)) = self.hold_timers.remove(&(room_code.clone(), slot_id)) {
            handle.abort();
        }

        // Update slot: new client_id, status → Connected.
        {
            let mut room_ref = match self.rooms.get_mut(&room_code) {
                Some(r) => r,
                None => {
                    return serde_json::json!({
                        "type": "join-error",
                        "payload": {"reason": "room_not_found"}
                    });
                }
            };
            let idx = (slot_id - 1) as usize;
            if let Some(Some(info)) = room_ref.slots.get_mut(idx) {
                info.client_id = client_id.to_string();
                info.status = SlotStatus::Connected;
            }
        }
        // DashMap RefMut dropped here.

        // Generate fresh reconnect_token and pairing_url (D-17).
        let new_reconnect_token = generate_reconnect_token();
        self.reconnect_tokens.remove(&reconnect_token);
        self.reconnect_tokens
            .insert(new_reconnect_token.clone(), (room_code.clone(), slot_id));

        // Also update stored reconnect token in slot info.
        if let Some(mut room_ref) = self.rooms.get_mut(&room_code) {
            let idx = (slot_id - 1) as usize;
            if let Some(Some(info)) = room_ref.slots.get_mut(idx) {
                info.reconnect_token = new_reconnect_token.clone();
            }
        }

        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        let expiry = now + self.pairing_ttl_secs;
        let new_pairing_token = match generate_pairing_token(
            &self.pairing_secret,
            &room_code,
            slot_id,
            expiry,
        ) {
            Ok(t) => t,
            Err(e) => {
                tracing::error!("failed to generate pairing token on reconnect: {e}");
                return serde_json::json!({
                    "type": "join-error",
                    "payload": {"reason": "internal_error"}
                });
            }
        };
        let pairing_url = format!("{}/phone?token={}", self.base_url, new_pairing_token);

        // Broadcast player-reconnected.
        let (username, slots_snapshot) = self.rooms.get(&room_code).map(|r| {
            let uname = r.slots
                .get((slot_id - 1) as usize)
                .and_then(|s| s.as_ref().map(|i| i.username.clone()))
                .unwrap_or_default();
            let snap: Vec<serde_json::Value> = r.slots.iter().enumerate()
                .filter_map(|(i, s)| {
                    s.as_ref().map(|info| {
                        let status = match info.status {
                            SlotStatus::Connected => "connected",
                            SlotStatus::Disconnected => "hold",
                            SlotStatus::Empty => "empty",
                        };
                        serde_json::json!({
                            "slot": i + 1,
                            "username": info.username,
                            "status": status
                        })
                    })
                })
                .collect();
            (uname, snap)
        }).unwrap_or_default();

        let event = serde_json::to_vec(&serde_json::json!({
            "type": "room-event",
            "payload": {
                "event": "player-reconnected",
                "slot": slot_id,
                "username": username
            }
        }))
        .unwrap_or_default();
        self.broadcast_to_room(&room_code, client_id, event, broker);

        serde_json::json!({
            "type": "join-ack",
            "payload": {
                "slot": slot_id,
                "room_code": room_code,
                "reconnect_token": new_reconnect_token,
                "pairing_url": pairing_url,
                "slots": slots_snapshot
            }
        })
    }

    /// Handle a `pair` message from a phone client.
    ///
    /// Validates the HMAC pairing token (single-use, T-04-02 mitigation), records the
    /// phone's client_id in the paired SlotInfo, and returns an enhanced `pair-ack`
    /// carrying the room roster (peers[]) and ephemeral ICE server config (D-04).
    ///
    /// Collect-then-drop pattern: DashMap RefMut is held only to write phone_client_id,
    /// then dropped before collecting peers and calling generate_turn_credentials.
    pub async fn handle_pair(
        &self,
        phone_client_id: &str,
        raw_payload: &serde_json::Value,
        _broker: &SignalingBroker,
    ) -> serde_json::Value {
        let token = match raw_payload["token"].as_str() {
            Some(t) => t.to_string(),
            None => {
                return serde_json::json!({
                    "type": "pair-error",
                    "payload": {"reason": "invalid_payload"}
                });
            }
        };

        // Validate and consume token (single-use, T-04-02 mitigation).
        let (room_code, slot_id) =
            match self.pairing_store.validate_and_consume(&self.pairing_secret, &token) {
                Some(r) => r,
                None => {
                    return serde_json::json!({
                        "type": "pair-error",
                        "payload": {"reason": "invalid_token"}
                    });
                }
            };

        // Step 1: Store phone_client_id in the paired slot (collect-then-drop).
        // Hold RefMut only for the write; drop before any async or broker call.
        {
            if let Some(mut room_ref) = self.rooms.get_mut(&room_code) {
                let idx = (slot_id - 1) as usize;
                if let Some(Some(slot)) = room_ref.slots.get_mut(idx) {
                    slot.phone_client_id = Some(phone_client_id.to_string());
                }
            }
        }
        // DashMap RefMut dropped here.

        // Step 2: Collect desktop_id, reconnect_token, and peers list (collect-then-drop).
        let (desktop_client_id, reconnect_token_val, peers_list) = {
            if let Some(room_ref) = self.rooms.get(&room_code) {
                let desktop_slot = room_ref.slots
                    .get((slot_id - 1) as usize)
                    .and_then(|s| s.as_ref());

                let desktop_id = match desktop_slot {
                    Some(s) => s.client_id.clone(),
                    None => {
                        return serde_json::json!({
                            "type": "pair-error",
                            "payload": {"reason": "slot_not_found"}
                        });
                    }
                };
                let reconnect_tok = desktop_slot
                    .map(|s| s.reconnect_token.clone())
                    .unwrap_or_default();

                // Build peers list from all Connected desktop slots (never the phone — Pitfall 7).
                let peers: Vec<serde_json::Value> = room_ref.slots.iter()
                    .enumerate()
                    .filter_map(|(i, s)| {
                        s.as_ref().and_then(|info| {
                            if info.status == SlotStatus::Connected {
                                Some(serde_json::json!({
                                    "id": info.client_id,
                                    "slot": (i + 1) as u8,
                                    "username": info.username
                                }))
                            } else {
                                None
                            }
                        })
                    })
                    .collect();

                (desktop_id, reconnect_tok, peers)
            } else {
                return serde_json::json!({
                    "type": "pair-error",
                    "payload": {"reason": "slot_not_found"}
                });
            }
        };
        // DashMap Ref dropped here.

        // Step 3: Generate ephemeral TURN credentials for the phone.
        // Use pairing_ttl_secs as the TURN TTL to avoid short-lived credentials (Pitfall 5).
        let creds = match generate_turn_credentials(
            &self.turn_shared_secret,
            phone_client_id,
            self.pairing_ttl_secs,
        ) {
            Ok(c) => c,
            Err(e) => {
                tracing::error!("failed to generate TURN credentials at pair time: {e}");
                return serde_json::json!({
                    "type": "pair-error",
                    "payload": {"reason": "internal_error"}
                });
            }
        };

        // Extract the hostname from base_url for STUN/TURN endpoints.
        // Format: https://<host>[:<port>] — strip scheme and optional port.
        let coturn_host = self.base_url
            .trim_start_matches("https://")
            .trim_start_matches("http://")
            .split(':')
            .next()
            .unwrap_or("localhost");

        let ice_servers = serde_json::json!([
            { "urls": format!("stun:{}:3478", coturn_host) },
            {
                "urls": format!("turn:{}:3478", coturn_host),
                "username": creds.username,
                "credential": creds.password
            }
        ]);

        // pairing_url echoes the phone entry point (reconnect semantics — D-14).
        let pairing_url = format!("{}/phone", self.base_url);

        tracing::info!(
            room_code = %room_code, slot_id = %slot_id,
            phone_client_id = %phone_client_id,
            "pair: phone paired with desktop, roster size = {}",
            peers_list.len()
        );

        serde_json::json!({
            "type": "pair-ack",
            "payload": {
                "desktop_id": desktop_client_id,
                "slot": slot_id,
                "room_code": room_code,
                "reconnect_token": reconnect_token_val,
                "pairing_url": pairing_url,
                "peers": peers_list,
                "ice_servers": ice_servers
            }
        })
    }

    /// Called when a WS/WT connection drops. Marks slot Disconnected, broadcasts
    /// `player-disconnected`, and spawns a hold timer.
    ///
    /// Hold timer fires after `hold_ttl_secs` and releases the slot if still
    /// Disconnected, then broadcasts `player-left` (D-16, D-19, SESS-04).
    ///
    /// DashMap Refs are dropped before spawning the timer task (Pitfall 1).
    pub async fn on_client_disconnect(&self, client_id: &str, broker: &SignalingBroker) {
        // Find which (room_code, slot_id, username) this client_id occupies.
        // Clone data out before dropping the Ref.
        let found: Option<(RoomCode, SlotId, String)> = {
            let mut found = None;
            'outer: for mut room_ref in self.rooms.iter_mut() {
                // Clone code before the mutable slots borrow (Rust borrow-checker:
                // cannot have both &room_ref.code and &mut room_ref.slots alive).
                let code = room_ref.code.clone();
                for (idx, slot) in room_ref.slots.iter_mut().enumerate() {
                    if let Some(info) = slot {
                        if info.client_id == client_id {
                            let slot_id = (idx + 1) as u8;
                            let username = info.username.clone();
                            info.status = SlotStatus::Disconnected;
                            found = Some((code, slot_id, username));
                            break 'outer;
                        }
                    }
                }
            }
            found
        };
        // All DashMap Refs are dropped here.

        let (room_code, slot_id, username) = match found {
            Some(v) => v,
            None => {
                // Client was not in any room — nothing to do.
                tracing::debug!(client_id = %client_id, "disconnect: client was not in any room");
                return;
            }
        };

        // Broadcast player-disconnected to remaining desktops (D-22, SESS-06).
        let event = serde_json::to_vec(&serde_json::json!({
            "type": "room-event",
            "payload": {
                "event": "player-disconnected",
                "slot": slot_id,
                "username": username
            }
        }))
        .unwrap_or_default();
        self.broadcast_to_room(&room_code, client_id, event, broker);

        // Spawn hold timer (Pattern 3 — per-slot JoinHandle, cancel-safe).
        let registry = self.clone();
        let broker_clone = broker.clone();
        let code_clone = room_code.clone();
        let username_clone = username.clone();
        let hold_secs = self.hold_ttl_secs;

        let handle = tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_secs(hold_secs)).await;

            // Defense-in-depth: only evict if slot is still Disconnected.
            // release_slot_if_disconnected returns Some(username) only when the
            // slot was genuinely still Disconnected — reconnect sets it to Connected.
            if let Some(evicted_username) = registry.release_slot_if_disconnected(&code_clone, slot_id) {
                // Remove the stale reconnect token.
                registry.reconnect_tokens.retain(|_, v| v != &(code_clone.clone(), slot_id));

                // Broadcast player-left (D-19).
                let left_event = serde_json::to_vec(&serde_json::json!({
                    "type": "room-event",
                    "payload": {
                        "event": "player-left",
                        "slot": slot_id,
                        "username": evicted_username
                    }
                }))
                .unwrap_or_default();
                registry.broadcast_to_room(&code_clone, "", left_event, &broker_clone);

                tracing::info!(
                    room_code = %code_clone, slot_id = %slot_id,
                    username = %username_clone,
                    "hold timer expired — slot released"
                );
            }
        });

        // Store handle; any subsequent reconnect removes and aborts it.
        self.hold_timers.insert((room_code, slot_id), handle);
    }

    /// Explicit player leave: immediately release the slot and broadcast player-left.
    /// Unlike on_client_disconnect, no hold timer is started — the leave is intentional.
    pub async fn handle_leave(&self, client_id: &str, broker: &SignalingBroker) {
        let found: Option<(RoomCode, SlotId, String)> = {
            let mut found = None;
            'outer: for mut room_ref in self.rooms.iter_mut() {
                let code = room_ref.code.clone();
                for (idx, slot) in room_ref.slots.iter_mut().enumerate() {
                    if let Some(info) = slot {
                        if info.client_id == client_id {
                            let slot_id = (idx + 1) as u8;
                            let username = info.username.clone();
                            *slot = None;
                            found = Some((code, slot_id, username));
                            break 'outer;
                        }
                    }
                }
            }
            found
        };

        let (room_code, slot_id, username) = match found {
            Some(v) => v,
            None => {
                tracing::debug!(client_id = %client_id, "leave-room: client not in any room");
                return;
            }
        };

        // Cancel stale hold timer if any (edge case: prior disconnect still pending).
        if let Some((_, handle)) = self.hold_timers.remove(&(room_code.clone(), slot_id)) {
            handle.abort();
        }

        // Remove reconnect token — slot is gone, token is invalid.
        self.reconnect_tokens.retain(|_, v| v != &(room_code.clone(), slot_id));

        let event = serde_json::to_vec(&serde_json::json!({
            "type": "room-event",
            "payload": {
                "event": "player-left",
                "slot": slot_id,
                "username": username
            }
        }))
        .unwrap_or_default();
        self.broadcast_to_room(&room_code, client_id, event, broker);

        tracing::info!(
            room_code = %room_code, slot_id = %slot_id,
            username = %username,
            "explicit leave — slot released immediately"
        );
    }

    /// Release a slot only if it is still in Disconnected state.
    ///
    /// Returns `Some(username)` if the slot was released, `None` if the slot
    /// was already reconnected (Connected) or otherwise not Disconnected.
    ///
    /// This is the hold-timer's final step and also the defense-in-depth guard
    /// (RESEARCH.md Pitfall 2): a missed abort() on reconnect will not evict
    /// a reconnected player because this function refuses to act on Connected slots.
    fn release_slot_if_disconnected(&self, room_code: &RoomCode, slot_id: SlotId) -> Option<String> {
        let mut room_ref = self.rooms.get_mut(room_code)?;
        let idx = (slot_id - 1) as usize;
        let slot = room_ref.slots.get_mut(idx)?;
        match slot {
            Some(info) if info.status == SlotStatus::Disconnected => {
                let username = info.username.clone();
                *slot = None;
                Some(username)
            }
            _ => None,
        }
    }

    /// Route a server-push event to the phone associated with a room slot.
    ///
    /// Collects the phone_client_id while holding the DashMap Ref, drops the Ref,
    /// then calls broker.route — never holds a Ref across the broker call (Pitfall 3).
    fn route_to_phone(&self, room_code: &str, event_bytes: Vec<u8>, broker: &SignalingBroker) {
        let phone_id: Option<String> = self.rooms.get(room_code).and_then(|room| {
            room.slots.iter().find_map(|s| {
                s.as_ref().and_then(|info| info.phone_client_id.clone())
            })
        });
        // DashMap Ref dropped here.
        if let Some(id) = phone_id {
            if !broker.route(&id, event_bytes) {
                tracing::warn!(phone_id = %id, "route_to_phone: phone not connected");
            }
        }
    }

    /// Handle an `rtc-channel-ready` message from either the phone or a desktop.
    ///
    /// Both sides send this when their WebRTC data channel opens. This method
    /// tracks two-sided confirmation and fires exactly one `player-ready` broadcast
    /// once every Connected desktop has a confirmed channel with the phone (D-08/D-09).
    ///
    /// Collect-then-drop: all DashMap Refs are dropped before any broker.route call
    /// (RESEARCH.md Pitfall 3). Input validation: missing `with` → early return
    /// (T-04-06 mitigation).
    pub async fn handle_rtc_channel_ready(
        &self,
        sender_id: &str,
        payload: &serde_json::Value,
        broker: &SignalingBroker,
    ) {
        // 1. Defensive extraction of "with" (T-04-06 mitigation).
        let with_id = match payload["with"].as_str() {
            Some(v) => v.to_string(),
            None => {
                tracing::warn!(sender_id = %sender_id, "rtc-channel-ready: missing 'with' field");
                return;
            }
        };

        // 2. Determine sender role by scanning room slots (T-04-07: role derived
        //    from server-held slot state, not client-asserted identity).
        //    Collect all needed data and drop all DashMap Refs before any async work.
        let role_info: Option<(RoomCode, String, String, bool)> = {
            let mut found: Option<(RoomCode, String, String, bool)> = None;
            'outer: for room_ref in self.rooms.iter() {
                let room = room_ref.value();
                for slot in room.slots.iter().flatten() {
                    if slot.phone_client_id.as_deref() == Some(sender_id) {
                        // Sender is the phone; with_id is the desktop
                        found = Some((room.code.clone(), sender_id.to_string(), with_id.clone(), true));
                        break 'outer;
                    }
                    if slot.client_id == sender_id {
                        // Sender is the desktop; with_id is the phone
                        found = Some((room.code.clone(), with_id.clone(), sender_id.to_string(), false));
                        break 'outer;
                    }
                }
            }
            found
        };
        // All DashMap Refs dropped here.

        let (room_code, phone_id, desktop_id, is_phone_sender) = match role_info {
            Some(v) => v,
            None => {
                tracing::warn!(
                    sender_id = %sender_id,
                    "rtc-channel-ready: sender not found in any room slot"
                );
                return;
            }
        };

        // 3. Upsert the channel_ready entry; canonical key: (room, phone, desktop).
        {
            let mut entry = self.channel_ready
                .entry((room_code.clone(), phone_id.clone(), desktop_id.clone()))
                .or_insert((false, false));
            if is_phone_sender {
                entry.0 = true;
            } else {
                entry.1 = true;
            }
        }
        // DashMap RefMut dropped here.

        // 4. Collect all Connected desktop client_ids + phone slot/username.
        //    Drop the room Ref before checking channel_ready (Pitfall 3).
        let (all_desktop_ids, phone_slot, phone_username): (Vec<String>, u8, String) = {
            if let Some(room_ref) = self.rooms.get(&room_code) {
                let desktops: Vec<String> = room_ref.slots.iter()
                    .filter_map(|s| {
                        s.as_ref().and_then(|info| {
                            if info.status == SlotStatus::Connected {
                                Some(info.client_id.clone())
                            } else {
                                None
                            }
                        })
                    })
                    .collect();

                let (slot_num, username) = room_ref.slots.iter()
                    .enumerate()
                    .find_map(|(i, s)| {
                        s.as_ref().and_then(|info| {
                            if info.phone_client_id.as_deref() == Some(phone_id.as_str()) {
                                Some(((i + 1) as u8, info.username.clone()))
                            } else {
                                None
                            }
                        })
                    })
                    .unwrap_or((0u8, String::new()));

                (desktops, slot_num, username)
            } else {
                (vec![], 0u8, String::new())
            }
        };
        // DashMap Ref dropped here.

        // 5. Check whether every Connected desktop has (true, true) for this phone.
        if all_desktop_ids.is_empty() {
            return;
        }
        let all_confirmed = all_desktop_ids.iter().all(|desktop| {
            self.channel_ready
                .get(&(room_code.clone(), phone_id.clone(), desktop.clone()))
                .map(|entry| entry.0 && entry.1)
                .unwrap_or(false)
        });
        // All short-lived channel_ready Refs dropped after each .get() call.

        if !all_confirmed {
            return;
        }

        // 6. Dedup guard: insert before broadcasting to prevent a second broadcast
        //    from a redundant confirmation arriving concurrently.
        if self.player_ready_sent.contains_key(&(room_code.clone(), phone_id.clone())) {
            return;
        }
        self.player_ready_sent.insert((room_code.clone(), phone_id.clone()), ());

        // 7. Build player-ready payload and broadcast (Pitfall 3: no DashMap Ref held).
        let player_ready_bytes = match serde_json::to_vec(&serde_json::json!({
            "type": "player-ready",
            "payload": {
                "player_id": phone_id,
                "slot": phone_slot,
                "username": phone_username
            }
        })) {
            Ok(b) => b,
            Err(e) => {
                tracing::error!("failed to serialize player-ready: {e}");
                return;
            }
        };

        tracing::info!(
            room_code = %room_code,
            phone_id = %phone_id,
            slot = %phone_slot,
            "player-ready: all channels confirmed, broadcasting"
        );

        // Broadcast to all Connected desktops.
        self.broadcast_to_room(&room_code, "", player_ready_bytes.clone(), broker);
        // Route to the phone as well.
        self.route_to_phone(&room_code, player_ready_bytes, broker);
    }

    /// Generate a 6-character uppercase room code from the unambiguous charset
    /// `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` (D-05, Claude's discretion).
    ///
    /// Excludes: 0 (like O), O (like 0), 1 (like I/l), I (like 1/l), L (like 1/I).
    /// 32 chars → 32^6 ≈ 1 billion combinations; collision probability negligible.
    ///
    /// Uses `rand::Rng::gen_range` for bias-free selection (RESEARCH.md Don't Hand-Roll).
    fn generate_room_code(&self) -> RoomCode {
        // rand 0.10: random_range is on RngExt (gen_range was renamed).
        use rand::RngExt;
        const CHARSET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
        const CODE_LEN: usize = 6;

        loop {
            let mut rng = rand::rng();
            let code: String = (0..CODE_LEN)
                .map(|_| CHARSET[rng.random_range(0..CHARSET.len())] as char)
                .collect();
            // Regenerate on collision (probability ~6e-9 at 1000 rooms).
            if !self.rooms.contains_key(&code) {
                return code;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_registry() -> RoomRegistry {
        RoomRegistry::new(
            "test-pairing-secret".to_string(),
            "turn-secret".to_string(),           // turn_shared_secret (fixed for tests)
            "https://localhost:8443".to_string(),
            60,  // hold_ttl_secs
            300, // pairing_ttl_secs
        )
    }

    /// A join with empty room_code creates a new room; slot=1, 6-char code from charset.
    #[tokio::test]
    async fn test_join_creates_room() {
        let registry = make_registry();
        let broker = SignalingBroker::new();
        let _ = broker.register("client-A".to_string());

        let payload = serde_json::json!({
            "username": "Alice",
            "room_code": "",
            "game_type": "demo"
        });
        let result = registry.handle_join("client-A", &payload, &broker).await;

        assert_eq!(result["type"], "join-ack", "should return join-ack");
        assert_eq!(result["payload"]["slot"], 1, "first join gets slot 1");

        let code = result["payload"]["room_code"].as_str().unwrap();
        assert_eq!(code.len(), 6, "room code must be 6 chars");

        const CHARSET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
        for ch in code.chars() {
            assert!(
                CHARSET.contains(&(ch as u8)),
                "char '{ch}' not in unambiguous charset (D-05)"
            );
        }
    }

    /// Three sequential joins get slots 1, 2, 3 in order.
    #[tokio::test]
    async fn test_join_assigns_sequential_slots() {
        let registry = make_registry();
        let broker = SignalingBroker::new();
        let _ = broker.register("c1".to_string());
        let _ = broker.register("c2".to_string());
        let _ = broker.register("c3".to_string());

        let p1 = serde_json::json!({"username": "P1", "room_code": "", "game_type": "g"});
        let r1 = registry.handle_join("c1", &p1, &broker).await;
        assert_eq!(r1["type"], "join-ack");
        let room_code = r1["payload"]["room_code"].as_str().unwrap().to_string();
        assert_eq!(r1["payload"]["slot"], 1);

        let p2 = serde_json::json!({"username": "P2", "room_code": room_code, "game_type": "g"});
        let r2 = registry.handle_join("c2", &p2, &broker).await;
        assert_eq!(r2["type"], "join-ack");
        assert_eq!(r2["payload"]["slot"], 2);

        let p3 = serde_json::json!({"username": "P3", "room_code": room_code, "game_type": "g"});
        let r3 = registry.handle_join("c3", &p3, &broker).await;
        assert_eq!(r3["type"], "join-ack");
        assert_eq!(r3["payload"]["slot"], 3);
    }

    /// After 8 joins, the 9th join returns join-error with reason "room_full" (D-08).
    #[tokio::test]
    async fn test_room_full_rejection() {
        let registry = make_registry();
        let broker = SignalingBroker::new();

        // Join 8 desktops.
        let mut room_code = String::new();
        for i in 0..8usize {
            let id = format!("client-{i}");
            let _ = broker.register(id.clone());
            let p = if i == 0 {
                serde_json::json!({"username": format!("P{i}"), "room_code": "", "game_type": "g"})
            } else {
                serde_json::json!({"username": format!("P{i}"), "room_code": room_code, "game_type": "g"})
            };
            let r = registry.handle_join(&id, &p, &broker).await;
            assert_eq!(r["type"], "join-ack", "join {i} should succeed");
            if i == 0 {
                room_code = r["payload"]["room_code"].as_str().unwrap().to_string();
            }
        }

        // 9th join must fail.
        let _ = broker.register("client-9".to_string());
        let p9 = serde_json::json!({"username": "P9", "room_code": room_code, "game_type": "g"});
        let r9 = registry.handle_join("client-9", &p9, &broker).await;

        assert_eq!(r9["type"], "join-error", "9th join must return join-error");
        assert_eq!(
            r9["payload"]["reason"], "room_full",
            "reason must be 'room_full'"
        );
    }

    /// Joining an existing room by code returns join-ack with the same room_code.
    #[tokio::test]
    async fn test_existing_room_join() {
        let registry = make_registry();
        let broker = SignalingBroker::new();
        let _ = broker.register("c1".to_string());
        let _ = broker.register("c2".to_string());

        // First join — creates room.
        let p1 = serde_json::json!({"username": "Alice", "room_code": "", "game_type": "g"});
        let r1 = registry.handle_join("c1", &p1, &broker).await;
        assert_eq!(r1["type"], "join-ack");
        let room_code = r1["payload"]["room_code"].as_str().unwrap().to_string();

        // Second join — uses existing room code.
        let p2 = serde_json::json!({"username": "Bob", "room_code": room_code, "game_type": "g"});
        let r2 = registry.handle_join("c2", &p2, &broker).await;
        assert_eq!(r2["type"], "join-ack");
        assert_eq!(
            r2["payload"]["room_code"].as_str().unwrap(),
            room_code,
            "room_code should match the existing room"
        );
    }

    /// handle_reconnect aborts the hold timer and marks slot Connected.
    #[tokio::test]
    async fn test_reconnect_cancels_timer() {
        // Use a 0-second hold_ttl so the timer fires almost immediately.
        let registry = RoomRegistry::new(
            "sec".to_string(),
            "turn-secret".to_string(),
            "https://localhost:8443".to_string(),
            0,   // hold_ttl = 0 → fires as soon as awaited
            300,
        );
        let broker = SignalingBroker::new();
        let _ = broker.register("client-A".to_string());
        let _ = broker.register("client-A2".to_string());

        // Join.
        let p = serde_json::json!({"username": "Alice", "room_code": "", "game_type": "g"});
        let r = registry.handle_join("client-A", &p, &broker).await;
        assert_eq!(r["type"], "join-ack");
        let reconnect_token = r["payload"]["reconnect_token"].as_str().unwrap().to_string();
        let room_code = r["payload"]["room_code"].as_str().unwrap().to_string();
        let slot_id = r["payload"]["slot"].as_u64().unwrap() as u8;

        // Disconnect — spawns hold timer.
        broker.unregister("client-A");
        registry.on_client_disconnect("client-A", &broker).await;

        // Timer handle was stored.
        assert!(
            registry.hold_timers.contains_key(&(room_code.clone(), slot_id)),
            "hold timer should be stored after disconnect"
        );

        // Immediately reconnect (before timer fires).
        let _ = broker.register("client-A2".to_string());
        let reconnect_payload = serde_json::json!({"reconnect_token": reconnect_token});
        let r2 = registry.handle_reconnect("client-A2", &reconnect_payload, &broker).await;
        assert_eq!(r2["type"], "join-ack", "reconnect should succeed");

        // Timer handle must have been removed (aborted).
        assert!(
            !registry.hold_timers.contains_key(&(room_code.clone(), slot_id)),
            "hold timer should be removed after reconnect"
        );

        // Slot must be Connected.
        let room = registry.rooms.get(&room_code).unwrap();
        let slot = room.slots[(slot_id - 1) as usize].as_ref().unwrap();
        assert_eq!(
            slot.status,
            SlotStatus::Connected,
            "slot must be Connected after reconnect"
        );
    }

    /// Hold timer fires (hold_ttl=0) and releases the slot; slot becomes None.
    #[tokio::test]
    async fn test_hold_timer_fires() {
        let registry = RoomRegistry::new(
            "sec".to_string(),
            "turn-secret".to_string(),
            "https://localhost:8443".to_string(),
            0,   // hold_ttl = 0 → fires almost immediately
            300,
        );
        let broker = SignalingBroker::new();
        let _ = broker.register("client-A".to_string());

        // Join.
        let p = serde_json::json!({"username": "Alice", "room_code": "", "game_type": "g"});
        let r = registry.handle_join("client-A", &p, &broker).await;
        assert_eq!(r["type"], "join-ack");
        let room_code = r["payload"]["room_code"].as_str().unwrap().to_string();
        let slot_id = r["payload"]["slot"].as_u64().unwrap() as u8;

        // Disconnect — marks Disconnected and starts hold timer (hold_ttl=0).
        registry.on_client_disconnect("client-A", &broker).await;

        // Wait long enough for the 0-second timer to fire.
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        // Slot must be None (released).
        let room = registry.rooms.get(&room_code).unwrap();
        assert!(
            room.slots[(slot_id - 1) as usize].is_none(),
            "slot should be released after hold timer fires"
        );
    }

    // ── Phase 4 pair-ack tests ────────────────────────────────────────────────

    /// After a desktop joins and a phone pairs, pair-ack["peers"] is non-empty.
    /// Only Connected desktop slots appear; the phone is never listed (Pitfall 7).
    #[tokio::test]
    async fn test_pair_ack_includes_peers() {
        let registry = make_registry();
        let broker = SignalingBroker::new();
        let _ = broker.register("client-D".to_string());
        let _ = broker.register("phone-XYZ".to_string());

        // Desktop joins
        let join_payload = serde_json::json!({
            "username": "Alice", "room_code": "", "game_type": "demo"
        });
        let join_result = registry.handle_join("client-D", &join_payload, &broker).await;
        assert_eq!(join_result["type"], "join-ack");
        let pairing_url = join_result["payload"]["pairing_url"].as_str().unwrap().to_string();
        let token = pairing_url.split("token=").nth(1).unwrap().to_string();

        // Phone pairs
        let pair_payload = serde_json::json!({ "token": token });
        let pair_result = registry.handle_pair("phone-XYZ", &pair_payload, &broker).await;

        assert_eq!(pair_result["type"], "pair-ack");
        let peers = pair_result["payload"]["peers"]
            .as_array()
            .expect("peers must be a JSON array");
        assert!(!peers.is_empty(), "peers must be non-empty after a desktop has joined");
        let peer = &peers[0];
        assert_eq!(peer["id"].as_str().unwrap(), "client-D", "peer id must match desktop");
        assert_eq!(peer["slot"].as_u64().unwrap(), 1, "peer slot must be 1");
        assert!(peer["username"].as_str().is_some(), "peer must have username");
        // Phone itself must NOT appear in the peers list
        assert!(
            !peers.iter().any(|p| p["id"].as_str() == Some("phone-XYZ")),
            "phone must never appear in peers list (Pitfall 7)"
        );
    }

    /// After handle_pair is called with phone_client_id "phone-XYZ", the paired
    /// SlotInfo.phone_client_id == Some("phone-XYZ").
    #[tokio::test]
    async fn test_pair_ack_records_phone_client_id() {
        let registry = make_registry();
        let broker = SignalingBroker::new();
        let _ = broker.register("client-D".to_string());
        let _ = broker.register("phone-XYZ".to_string());

        let join_payload = serde_json::json!({
            "username": "Alice", "room_code": "", "game_type": "demo"
        });
        let join_result = registry.handle_join("client-D", &join_payload, &broker).await;
        let pairing_url = join_result["payload"]["pairing_url"].as_str().unwrap().to_string();
        let token = pairing_url.split("token=").nth(1).unwrap().to_string();
        let room_code = join_result["payload"]["room_code"].as_str().unwrap().to_string();

        let pair_payload = serde_json::json!({ "token": token });
        let pair_result = registry.handle_pair("phone-XYZ", &pair_payload, &broker).await;
        assert_eq!(pair_result["type"], "pair-ack");

        // Verify phone_client_id is recorded in SlotInfo
        let room = registry.rooms.get(&room_code).unwrap();
        let slot = room.slots[0].as_ref().unwrap();
        assert_eq!(
            slot.phone_client_id.as_deref(),
            Some("phone-XYZ"),
            "phone_client_id must be recorded on the paired SlotInfo"
        );
    }

    /// pair-ack["ice_servers"] is a non-empty array; the TURN entry has
    /// "username" and "credential" fields from generate_turn_credentials.
    #[tokio::test]
    async fn test_pair_ack_includes_ice_servers() {
        let registry = make_registry();
        let broker = SignalingBroker::new();
        let _ = broker.register("client-D".to_string());
        let _ = broker.register("phone-XYZ".to_string());

        let join_payload = serde_json::json!({
            "username": "Alice", "room_code": "", "game_type": "demo"
        });
        let join_result = registry.handle_join("client-D", &join_payload, &broker).await;
        let pairing_url = join_result["payload"]["pairing_url"].as_str().unwrap().to_string();
        let token = pairing_url.split("token=").nth(1).unwrap().to_string();

        let pair_payload = serde_json::json!({ "token": token });
        let pair_result = registry.handle_pair("phone-XYZ", &pair_payload, &broker).await;
        assert_eq!(pair_result["type"], "pair-ack");

        let ice_servers = pair_result["payload"]["ice_servers"]
            .as_array()
            .expect("ice_servers must be a JSON array");
        assert!(!ice_servers.is_empty(), "ice_servers must be non-empty");

        let stun_entry = ice_servers
            .iter()
            .find(|s| s["urls"].as_str().map(|u| u.starts_with("stun:")).unwrap_or(false));
        assert!(stun_entry.is_some(), "must have a STUN entry");

        let turn_entry = ice_servers
            .iter()
            .find(|s| s["urls"].as_str().map(|u| u.starts_with("turn:")).unwrap_or(false))
            .expect("must have a TURN entry");
        assert!(
            turn_entry["username"].as_str().is_some(),
            "TURN entry must have username"
        );
        assert!(
            turn_entry["credential"].as_str().is_some(),
            "TURN entry must have credential"
        );
    }

    // ── Phase 4 Plan 02 rtc-channel-ready / player-ready tests ──────────────────

    /// Helper: join one desktop and pair one phone; returns (room_code, phone_rx, desktop_rx).
    async fn setup_one_desktop_one_phone(
        registry: &RoomRegistry,
        broker: &SignalingBroker,
        desktop_id: &str,
        phone_id: &str,
    ) -> String {
        let join_payload = serde_json::json!({
            "username": "Alice", "room_code": "", "game_type": "demo"
        });
        let join_result = registry.handle_join(desktop_id, &join_payload, broker).await;
        assert_eq!(join_result["type"], "join-ack");
        let pairing_url = join_result["payload"]["pairing_url"].as_str().unwrap().to_string();
        let token = pairing_url.split("token=").nth(1).unwrap().to_string();
        let room_code = join_result["payload"]["room_code"].as_str().unwrap().to_string();

        let pair_payload = serde_json::json!({ "token": token });
        let pair_result = registry.handle_pair(phone_id, &pair_payload, broker).await;
        assert_eq!(pair_result["type"], "pair-ack", "phone pair should succeed");

        room_code
    }

    /// Both sides confirm a single channel → player-ready is routed to both
    /// client-D and phone-P; payload.player_id == phone-P, slot == 1 (D-08/D-09).
    #[tokio::test]
    async fn test_rtc_channel_ready_both_sides_fires_player_ready() {
        let registry = make_registry();
        let broker = SignalingBroker::new();

        let mut rx_d = broker.register("client-D".to_string()).unwrap();
        let mut rx_p = broker.register("phone-P".to_string()).unwrap();

        setup_one_desktop_one_phone(&registry, &broker, "client-D", "phone-P").await;

        // Drain any setup events on rx_d (e.g. player-joined broadcasts — none expected
        // since client-D is the only member when it joins, but defensive drain).
        while rx_d.try_recv().is_ok() {}
        while rx_p.try_recv().is_ok() {}

        // Phone confirms its side.
        let phone_payload = serde_json::json!({ "with": "client-D" });
        registry.handle_rtc_channel_ready("phone-P", &phone_payload, &broker).await;

        // No player-ready yet (desktop hasn't confirmed).
        assert!(rx_d.try_recv().is_err(), "no player-ready while desktop side is pending");
        assert!(rx_p.try_recv().is_err(), "no player-ready while desktop side is pending");

        // Desktop confirms its side.
        let desktop_payload = serde_json::json!({ "with": "phone-P" });
        registry.handle_rtc_channel_ready("client-D", &desktop_payload, &broker).await;

        // Both sides confirmed → player-ready must be delivered.
        let msg_d = rx_d.try_recv().expect("client-D should receive player-ready");
        let event_d: serde_json::Value = serde_json::from_slice(&msg_d).unwrap();
        assert_eq!(event_d["type"], "player-ready", "desktop must receive player-ready");
        assert_eq!(event_d["payload"]["player_id"], "phone-P", "player_id must be phone-P");
        assert_eq!(event_d["payload"]["slot"], 1u64, "phone is paired with slot 1");

        let msg_p = rx_p.try_recv().expect("phone-P should receive player-ready");
        let event_p: serde_json::Value = serde_json::from_slice(&msg_p).unwrap();
        assert_eq!(event_p["type"], "player-ready", "phone must receive player-ready");
        assert_eq!(event_p["payload"]["player_id"], "phone-P");
    }

    /// Only one side confirms → no player-ready emitted (desktop side still pending).
    #[tokio::test]
    async fn test_rtc_channel_ready_single_side_no_player_ready() {
        let registry = make_registry();
        let broker = SignalingBroker::new();

        let mut rx_d = broker.register("client-D".to_string()).unwrap();
        let mut rx_p = broker.register("phone-P".to_string()).unwrap();

        setup_one_desktop_one_phone(&registry, &broker, "client-D", "phone-P").await;

        while rx_d.try_recv().is_ok() {}
        while rx_p.try_recv().is_ok() {}

        // Only phone confirms.
        let phone_payload = serde_json::json!({ "with": "client-D" });
        registry.handle_rtc_channel_ready("phone-P", &phone_payload, &broker).await;

        // No player-ready should be emitted.
        assert!(rx_d.try_recv().is_err(), "no player-ready when only one side confirmed");
        assert!(rx_p.try_recv().is_err(), "no player-ready when only one side confirmed");
    }

    /// Third redundant confirmation after both sides have confirmed does NOT
    /// emit a second player-ready (player_ready_sent dedup guard).
    #[tokio::test]
    async fn test_player_ready_broadcast_once() {
        let registry = make_registry();
        let broker = SignalingBroker::new();

        let mut rx_d = broker.register("client-D".to_string()).unwrap();
        let mut rx_p = broker.register("phone-P".to_string()).unwrap();

        setup_one_desktop_one_phone(&registry, &broker, "client-D", "phone-P").await;

        while rx_d.try_recv().is_ok() {}
        while rx_p.try_recv().is_ok() {}

        // Both sides confirm — triggers the first (and only) player-ready.
        registry.handle_rtc_channel_ready("phone-P", &serde_json::json!({"with":"client-D"}), &broker).await;
        registry.handle_rtc_channel_ready("client-D", &serde_json::json!({"with":"phone-P"}), &broker).await;

        // Drain the single player-ready delivery.
        assert!(rx_d.try_recv().is_ok(), "first player-ready must be delivered to desktop");
        assert!(rx_p.try_recv().is_ok(), "first player-ready must be delivered to phone");

        // Third redundant confirmation — dedup guard must block a second broadcast.
        registry.handle_rtc_channel_ready("phone-P", &serde_json::json!({"with":"client-D"}), &broker).await;

        assert!(rx_d.try_recv().is_err(), "no second player-ready (dedup guard)");
        assert!(rx_p.try_recv().is_err(), "no second player-ready (dedup guard)");
    }

    /// Two desktops in room — player-ready fires only after BOTH channels are
    /// both-sides confirmed, not after the first channel is established.
    #[tokio::test]
    async fn test_rtc_channel_ready_two_desktops_waits_for_all() {
        let registry = make_registry();
        let broker = SignalingBroker::new();

        let mut rx_d1 = broker.register("client-D1".to_string()).unwrap();
        let mut rx_d2 = broker.register("client-D2".to_string()).unwrap();
        let mut rx_p  = broker.register("phone-P".to_string()).unwrap();

        // Desktop-1 creates room.
        let join1 = serde_json::json!({"username": "Alice", "room_code": "", "game_type": "demo"});
        let r1 = registry.handle_join("client-D1", &join1, &broker).await;
        assert_eq!(r1["type"], "join-ack");
        let room_code = r1["payload"]["room_code"].as_str().unwrap().to_string();
        let pairing_url1 = r1["payload"]["pairing_url"].as_str().unwrap().to_string();
        let token1 = pairing_url1.split("token=").nth(1).unwrap().to_string();

        // Desktop-2 joins same room.
        let join2 = serde_json::json!({"username": "Bob", "room_code": room_code, "game_type": "demo"});
        let r2 = registry.handle_join("client-D2", &join2, &broker).await;
        assert_eq!(r2["type"], "join-ack");

        // Drain setup events (client-D1 receives player-joined for D2).
        while rx_d1.try_recv().is_ok() {}
        while rx_d2.try_recv().is_ok() {}
        while rx_p.try_recv().is_ok() {}

        // Phone pairs with token from slot-1 (client-D1).
        let pair_result = registry.handle_pair("phone-P", &serde_json::json!({"token": token1}), &broker).await;
        assert_eq!(pair_result["type"], "pair-ack");
        // pair-ack must include both desktops in peers.
        let peers = pair_result["payload"]["peers"].as_array().unwrap();
        assert_eq!(peers.len(), 2, "pair-ack must include both desktops");

        // Channel-1 (phone ↔ D1): phone side confirms.
        registry.handle_rtc_channel_ready("phone-P", &serde_json::json!({"with":"client-D1"}), &broker).await;
        // Channel-1: D1 side confirms → first channel fully open.
        registry.handle_rtc_channel_ready("client-D1", &serde_json::json!({"with":"phone-P"}), &broker).await;

        // player-ready must NOT fire yet (D2 channel still pending).
        assert!(rx_d1.try_recv().is_err(), "no player-ready: D2 channel still pending");
        assert!(rx_d2.try_recv().is_err(), "no player-ready: D2 channel still pending");
        assert!(rx_p.try_recv().is_err(),  "no player-ready: D2 channel still pending");

        // Channel-2 (phone ↔ D2): phone side confirms.
        registry.handle_rtc_channel_ready("phone-P", &serde_json::json!({"with":"client-D2"}), &broker).await;
        // Channel-2: D2 side confirms → all channels fully open.
        registry.handle_rtc_channel_ready("client-D2", &serde_json::json!({"with":"phone-P"}), &broker).await;

        // Now player-ready must be delivered to all three: D1, D2, and the phone.
        let msg_d1 = rx_d1.try_recv().expect("client-D1 should receive player-ready");
        let event_d1: serde_json::Value = serde_json::from_slice(&msg_d1).unwrap();
        assert_eq!(event_d1["type"], "player-ready");
        assert_eq!(event_d1["payload"]["player_id"], "phone-P");

        let msg_d2 = rx_d2.try_recv().expect("client-D2 should receive player-ready");
        let event_d2: serde_json::Value = serde_json::from_slice(&msg_d2).unwrap();
        assert_eq!(event_d2["type"], "player-ready");

        let msg_p = rx_p.try_recv().expect("phone-P should receive player-ready");
        let event_p: serde_json::Value = serde_json::from_slice(&msg_p).unwrap();
        assert_eq!(event_p["type"], "player-ready");
        assert_eq!(event_p["payload"]["player_id"], "phone-P");
    }

    /// An unknown/consumed token returns type "pair-error" with reason "invalid_token"
    /// (existing behavior must be preserved).
    #[tokio::test]
    async fn test_pair_ack_invalid_token_still_errors() {
        let registry = make_registry();
        let broker = SignalingBroker::new();
        let _ = broker.register("phone-XYZ".to_string());

        let pair_payload = serde_json::json!({ "token": "invalid-token-xyz" });
        let pair_result = registry.handle_pair("phone-XYZ", &pair_payload, &broker).await;

        assert_eq!(
            pair_result["type"], "pair-error",
            "invalid token must return pair-error"
        );
        assert_eq!(
            pair_result["payload"]["reason"], "invalid_token",
            "reason must be invalid_token"
        );
    }

    // ── Phase 4 Plan 03: heartbeat tests (TDD RED) ─────────────────────────────

    /// After a desktop joins and a phone pairs, handle_heartbeat(phone_id)
    /// sets that slot's last_heartbeat to Some(_).
    #[tokio::test]
    async fn test_heartbeat_updates_last_heartbeat() {
        let registry = make_registry();
        let broker = SignalingBroker::new();
        let _ = broker.register("client-D".to_string());
        let _ = broker.register("phone-H".to_string());

        let join_payload = serde_json::json!({
            "username": "Alice", "room_code": "", "game_type": "demo"
        });
        let join_result = registry.handle_join("client-D", &join_payload, &broker).await;
        let pairing_url = join_result["payload"]["pairing_url"].as_str().unwrap().to_string();
        let token = pairing_url.split("token=").nth(1).unwrap().to_string();
        let room_code = join_result["payload"]["room_code"].as_str().unwrap().to_string();

        let pair_payload = serde_json::json!({ "token": token });
        let pair_result = registry.handle_pair("phone-H", &pair_payload, &broker).await;
        assert_eq!(pair_result["type"], "pair-ack");

        // Before heartbeat: last_heartbeat should be None
        {
            let room = registry.rooms.get(&room_code).unwrap();
            let slot = room.slots[0].as_ref().unwrap();
            assert!(slot.last_heartbeat.is_none(), "last_heartbeat must be None before first heartbeat");
        }

        // After heartbeat
        registry.handle_heartbeat("phone-H");

        // last_heartbeat must now be Some(_)
        {
            let room = registry.rooms.get(&room_code).unwrap();
            let slot = room.slots[0].as_ref().unwrap();
            assert!(slot.last_heartbeat.is_some(), "last_heartbeat must be Some after handle_heartbeat");
        }
    }

    /// A slot whose last_heartbeat is older than timeout appears in phones_missing_heartbeat;
    /// a slot heartbeated recently does not.
    #[tokio::test]
    async fn test_phones_missing_heartbeat_flags_stale() {
        let registry = make_registry();
        let broker = SignalingBroker::new();
        let _ = broker.register("client-D".to_string());
        let _ = broker.register("phone-H".to_string());

        let join_payload = serde_json::json!({
            "username": "Alice", "room_code": "", "game_type": "demo"
        });
        let join_result = registry.handle_join("client-D", &join_payload, &broker).await;
        let pairing_url = join_result["payload"]["pairing_url"].as_str().unwrap().to_string();
        let token = pairing_url.split("token=").nth(1).unwrap().to_string();
        let room_code = join_result["payload"]["room_code"].as_str().unwrap().to_string();

        let pair_payload = serde_json::json!({ "token": token });
        registry.handle_pair("phone-H", &pair_payload, &broker).await;

        // Manually set an old last_heartbeat (2 minutes ago) in the slot.
        {
            let mut room = registry.rooms.get_mut(&room_code).unwrap();
            let slot = room.slots[0].as_mut().unwrap();
            slot.last_heartbeat = Some(std::time::Instant::now() - std::time::Duration::from_secs(120));
        }

        // A 65-second timeout — our 120s old heartbeat is stale.
        let stale = registry.phones_missing_heartbeat(std::time::Duration::from_secs(65));
        assert!(!stale.is_empty(), "stale slot must be reported");
        assert_eq!(stale[0].3, "phone-H", "stale entry must be phone-H");

        // Recent heartbeat — not stale.
        registry.handle_heartbeat("phone-H");
        let fresh = registry.phones_missing_heartbeat(std::time::Duration::from_secs(65));
        assert!(fresh.is_empty(), "freshly heartbeated slot must not appear in missing list");
    }

    /// handle_heartbeat_miss sets the slot Disconnected and broadcasts a phone-state
    /// heartbeat-miss envelope to room desktops; the slot is held (not removed).
    #[tokio::test]
    async fn test_heartbeat_miss_marks_disconnected() {
        let registry = make_registry();
        let broker = SignalingBroker::new();
        let mut rx_d = broker.register("client-D".to_string()).unwrap();
        let _ = broker.register("phone-H".to_string());

        let join_payload = serde_json::json!({
            "username": "Alice", "room_code": "", "game_type": "demo"
        });
        let join_result = registry.handle_join("client-D", &join_payload, &broker).await;
        let pairing_url = join_result["payload"]["pairing_url"].as_str().unwrap().to_string();
        let token = pairing_url.split("token=").nth(1).unwrap().to_string();
        let room_code = join_result["payload"]["room_code"].as_str().unwrap().to_string();
        let slot_id = join_result["payload"]["slot"].as_u64().unwrap() as u8;

        let pair_payload = serde_json::json!({ "token": token });
        registry.handle_pair("phone-H", &pair_payload, &broker).await;

        // Drain setup events on desktop.
        while rx_d.try_recv().is_ok() {}

        // Simulate heartbeat miss.
        registry.handle_heartbeat_miss(&room_code, slot_id, &broker).await;

        // Slot must be Disconnected (not removed — hold window kept).
        {
            let room = registry.rooms.get(&room_code).unwrap();
            let slot = room.slots[(slot_id - 1) as usize].as_ref()
                .expect("slot must still exist (hold, not evicted)");
            assert_eq!(slot.status, SlotStatus::Disconnected, "slot must be Disconnected after miss");
        }

        // Desktop must receive a phone-state / heartbeat-miss message.
        let msg = rx_d.try_recv().expect("desktop must receive heartbeat-miss notification");
        let event: serde_json::Value = serde_json::from_slice(&msg).unwrap();
        assert_eq!(event["type"], "phone-state", "type must be phone-state");
        assert_eq!(event["payload"]["state"], "heartbeat-miss", "state must be heartbeat-miss");
    }

    /// handle_heartbeat for an unknown phone_client_id does not panic.
    #[tokio::test]
    async fn test_heartbeat_unknown_phone_is_noop() {
        let registry = make_registry();
        // Should not panic — just logs a warning.
        registry.handle_heartbeat("no-such-phone");
    }

    /// Lifecycle broadcast: desktop B disconnects; desktop A receives player-disconnected event.
    #[tokio::test]
    async fn test_lifecycle_broadcast() {
        let registry = make_registry();
        let broker = SignalingBroker::new();

        // Register both clients and capture A's receiver.
        let mut rx_a = broker.register("client-A".to_string()).unwrap();
        let _ = broker.register("client-B".to_string());

        // Both join.
        let pa = serde_json::json!({"username": "Alice", "room_code": "", "game_type": "g"});
        let ra = registry.handle_join("client-A", &pa, &broker).await;
        assert_eq!(ra["type"], "join-ack");
        let room_code = ra["payload"]["room_code"].as_str().unwrap().to_string();

        let pb = serde_json::json!({"username": "Bob", "room_code": room_code, "game_type": "g"});
        // After B joins, A receives a player-joined event — drain it.
        let _rb = registry.handle_join("client-B", &pb, &broker).await;
        let _ = rx_a.try_recv(); // consume the player-joined broadcast

        // B disconnects.
        registry.on_client_disconnect("client-B", &broker).await;

        // A must receive a player-disconnected event.
        let msg = rx_a.try_recv().expect("client-A should receive player-disconnected event");
        let event: serde_json::Value = serde_json::from_slice(&msg).unwrap();
        assert_eq!(event["type"], "room-event");
        assert_eq!(event["payload"]["event"], "player-disconnected");
        assert_eq!(event["payload"]["username"], "Bob");
    }
}
