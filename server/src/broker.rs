use dashmap::DashMap;
use std::sync::{atomic::{AtomicBool, Ordering}, Arc};
use tokio::sync::mpsc;

pub type ClientId = String;

struct BrokerEntry {
    tx: mpsc::UnboundedSender<Vec<u8>>,
    /// Cleared to false when this entry is replaced by a newer connection for the same ID.
    /// The old relay task checks this flag before calling on_client_disconnect to avoid
    /// firing disconnect for a client that has already reconnected on a new transport.
    alive: Arc<AtomicBool>,
}

/// In-process signaling relay registry (D-03).
///
/// Maps client IDs to their outbound message sender. Both the WebTransport and
/// WebSocket handlers share a single `Arc<SignalingBroker>` and call `route` to
/// forward signaling envelopes to any registered client regardless of which
/// transport they arrived on.
///
/// The inner `Arc<DashMap>` means `clone()` is cheap — both WT and WS handlers
/// receive the same logical broker handle and share the same map.
#[derive(Clone)]
pub struct SignalingBroker {
    clients: Arc<DashMap<ClientId, BrokerEntry>>,
}

impl SignalingBroker {
    /// Create a new, empty broker.
    pub fn new() -> Self {
        Self {
            clients: Arc::new(DashMap::new()),
        }
    }

    /// Register a client by ID and return the receiver this handler must drain
    /// plus an alive flag the relay task must hold.
    ///
    /// Always succeeds — if an entry already exists it is replaced and the old
    /// entry's alive flag is set to false so the superseded relay task skips
    /// `on_client_disconnect` when it eventually exits. This allows a phone to
    /// reconnect via a new transport (WS fallback) before the old WT relay task
    /// has detected the dropped QUIC connection.
    ///
    /// The relay task MUST check `alive.load(SeqCst)` before calling
    /// `broker.unregister()` and `on_client_disconnect` — if false, a newer
    /// connection has already taken ownership and cleanup must not be performed.
    pub fn register(&self, id: ClientId) -> (mpsc::UnboundedReceiver<Vec<u8>>, Arc<AtomicBool>) {
        let alive = Arc::new(AtomicBool::new(true));
        let (tx, rx) = mpsc::unbounded_channel::<Vec<u8>>();
        // Replace any existing entry; signal the superseded relay that it lost ownership.
        if let Some(old) = self.clients.insert(id, BrokerEntry { tx, alive: alive.clone() }) {
            old.alive.store(false, Ordering::SeqCst);
        }
        (rx, alive)
    }

    /// Remove a client from the registry.
    pub fn unregister(&self, id: &str) {
        self.clients.remove(id);
    }

    /// Route `payload` to the client identified by `to`.
    ///
    /// Returns `true` if the client is connected and the send succeeded.
    /// Returns `false` if the client is unknown — the **caller** must log a
    /// warning per D-05; the broker itself does not log here.
    ///
    /// Safety note: `mpsc::UnboundedSender::send` is synchronous (not `.await`),
    /// so the DashMap shard guard is never held across an `.await` point — safe
    /// by construction for unbounded channels. If this changes to a bounded
    /// channel, the sender must be cloned out of the guard before any `.await`.
    pub fn route(&self, to: &str, payload: Vec<u8>) -> bool {
        match self.clients.get(to) {
            Some(entry) => entry.tx.send(payload).is_ok(),
            None => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Routing to a registered client returns true and the payload arrives.
    #[tokio::test]
    async fn test_route_to_registered_client() {
        let broker = SignalingBroker::new();
        let (mut rx, _alive) = broker.register("id-A".into());
        let payload = b"hello".to_vec();

        let routed = broker.route("id-A", payload.clone());
        assert!(routed, "route to registered client should return true");

        let received = rx.try_recv().expect("payload should arrive on receiver");
        assert_eq!(received, payload);
    }

    /// Routing to an unknown client returns false (broker does not panic or log).
    #[test]
    fn test_route_to_unknown_returns_false() {
        let broker = SignalingBroker::new();
        let result = broker.route("id-unknown", b"data".to_vec());
        assert!(!result, "route to unknown id should return false");
    }

    /// After unregister, routing to that id returns false.
    #[test]
    fn test_unregister_then_route_returns_false() {
        let broker = SignalingBroker::new();
        let (_rx, _alive) = broker.register("id-A".into());
        broker.unregister("id-A");
        let result = broker.route("id-A", b"data".to_vec());
        assert!(!result, "route after unregister should return false");
    }

    /// Re-registration replaces the old entry and signals alive=false to the superseded relay.
    #[tokio::test]
    async fn test_force_replace_registration_supersedes_old() {
        let broker = SignalingBroker::new();
        let (_rx1, alive1) = broker.register("id-A".into());
        assert!(alive1.load(Ordering::SeqCst), "first registration should be alive");

        let (mut rx2, alive2) = broker.register("id-A".into());
        assert!(!alive1.load(Ordering::SeqCst), "old registration should be superseded");
        assert!(alive2.load(Ordering::SeqCst), "new registration should be alive");

        // Messages now route to the new receiver.
        broker.route("id-A", b"msg".to_vec());
        let msg = rx2.try_recv().expect("new rx should receive message");
        assert_eq!(msg, b"msg".to_vec());
    }

    /// Two registrations produce independent channels — payload to id-A never
    /// reaches id-B's receiver.
    #[tokio::test]
    async fn test_register_returns_independent_receivers() {
        let broker = SignalingBroker::new();
        let (mut rx_a, _alive_a) = broker.register("id-A".into());
        let (mut rx_b, _alive_b) = broker.register("id-B".into());

        broker.route("id-A", b"for-A".to_vec());
        broker.route("id-B", b"for-B".to_vec());

        let a_recv = rx_a.try_recv().expect("id-A should receive its payload");
        let b_recv = rx_b.try_recv().expect("id-B should receive its payload");

        assert_eq!(a_recv, b"for-A".to_vec());
        assert_eq!(b_recv, b"for-B".to_vec());
    }
}
