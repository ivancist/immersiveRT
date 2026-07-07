use futures_util::{SinkExt, StreamExt};
use std::sync::Arc;
use tokio_tungstenite::{connect_async, tungstenite::Message};

/// Integration test for cross-client WS signaling relay (D-03, INFRA-02, INFRA-03).
///
/// Two clients connect to the same server.  Client A registers as "phone-1",
/// client B registers as "desktop-1".  Client A sends an offer to "desktop-1".
/// Client B must receive the offer with msg_type=="offer" and from=="phone-1".
#[tokio::test]
async fn test_broker_relay_ws() {
    // Bind before spawning so a port conflict is an immediate, clear test failure
    // rather than a misleading "connect failed" error.
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("failed to bind test listener");
    let addr = listener.local_addr().expect("no local addr");

    let broker = Arc::new(immersive_rt_server::broker::SignalingBroker::new());
    let registry = Arc::new(immersive_rt_server::room_registry::RoomRegistry::new(
        "test-secret".to_string(),
        "http://localhost".to_string(),
        60,
        90,
    ));
    tokio::spawn(immersive_rt_server::ws_server::run_with_listener(
        listener,
        broker,
        registry,
        None,
    ));

    let url = format!("ws://{}", addr);

    // Connect two independent clients.
    let (mut ws_a, _) = connect_async(&url)
        .await
        .expect("client A WebSocket connect failed");
    let (mut ws_b, _) = connect_async(&url)
        .await
        .expect("client B WebSocket connect failed");

    // Register phone-1
    ws_a.send(Message::Text(
        r#"{"type":"register","from":"phone-1","to":"","payload":null}"#.into(),
    ))
    .await
    .expect("client A register send failed");

    // Register desktop-1
    ws_b.send(Message::Text(
        r#"{"type":"register","from":"desktop-1","to":"","payload":null}"#.into(),
    ))
    .await
    .expect("client B register send failed");

    // Allow time for both registrations to be processed by the server.
    // yield_now() is not a reliable barrier — a single scheduler yield does not
    // guarantee the server task runs to completion before the next send.
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;

    // Client A sends an offer to desktop-1.
    ws_a.send(Message::Text(
        r#"{"type":"offer","from":"phone-1","to":"desktop-1","payload":{}}"#.into(),
    ))
    .await
    .expect("client A offer send failed");

    // Client B should receive the offer routed via the broker.
    let reply = ws_b
        .next()
        .await
        .expect("client B received no message")
        .expect("client B message was an error");

    match reply {
        Message::Text(text) => {
            let envelope = immersive_rt_server::signaling::parse_envelope(text.as_bytes())
                .expect("client B message should be a valid SignalingEnvelope");
            assert_eq!(
                envelope.msg_type, "offer",
                "expected msg_type 'offer', got {:?}",
                envelope.msg_type
            );
            assert_eq!(
                envelope.from, "phone-1",
                "expected from 'phone-1', got {:?}",
                envelope.from
            );
        }
        other => panic!("unexpected message type from client B: {other:?}"),
    }
}
