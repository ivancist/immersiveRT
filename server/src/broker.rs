use dashmap::DashMap;
use tokio::sync::mpsc;

pub type ClientId = String;

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
    clients: std::sync::Arc<DashMap<ClientId, mpsc::UnboundedSender<Vec<u8>>>>,
}

impl SignalingBroker {
    /// Create a new, empty broker.
    pub fn new() -> Self {
        Self {
            clients: std::sync::Arc::new(DashMap::new()),
        }
    }

    /// Register a client by ID and return the receiver this handler must drain.
    ///
    /// The caller owns the returned `UnboundedReceiver` and must drain it in its
    /// connection task. The corresponding `UnboundedSender` is stored in the map.
    /// Calling `register` for an already-registered ID replaces the previous sender.
    pub fn register(&self, id: ClientId) -> mpsc::UnboundedReceiver<Vec<u8>> {
        let (tx, rx) = mpsc::unbounded_channel::<Vec<u8>>();
        self.clients.insert(id, tx);
        rx
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
            Some(sender) => sender.send(payload).is_ok(),
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
        let mut rx = broker.register("id-A".into());
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
        let _rx = broker.register("id-A".into());
        broker.unregister("id-A");
        let result = broker.route("id-A", b"data".to_vec());
        assert!(!result, "route after unregister should return false");
    }

    /// Two registrations produce independent channels — payload to id-A never
    /// reaches id-B's receiver.
    #[tokio::test]
    async fn test_register_returns_independent_receivers() {
        let broker = SignalingBroker::new();
        let mut rx_a = broker.register("id-A".into());
        let mut rx_b = broker.register("id-B".into());

        broker.route("id-A", b"for-A".to_vec());
        broker.route("id-B", b"for-B".to_vec());

        let a_recv = rx_a.try_recv().expect("id-A should receive its payload");
        let b_recv = rx_b.try_recv().expect("id-B should receive its payload");

        assert_eq!(a_recv, b"for-A".to_vec());
        assert_eq!(b_recv, b"for-B".to_vec());
    }
}
