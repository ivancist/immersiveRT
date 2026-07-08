use futures_util::{SinkExt, StreamExt};
use std::sync::Arc;
use tokio_tungstenite::{connect_async, tungstenite::Message};

/// Verifies that a client can connect, register, and receive a message routed back
/// to itself (self-routing round-trip).  This replaced the legacy echo test once
/// ws_server was converted from echo to signaling relay in Plan 02-02.
#[tokio::test]
async fn test_ws_echo() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("failed to bind test listener");
    let addr = listener.local_addr().expect("no local addr");

    let broker = Arc::new(immersive_rt_server::broker::SignalingBroker::new());
    let registry = Arc::new(immersive_rt_server::room_registry::RoomRegistry::new(
        "test-secret".to_string(),
        "turn-secret".to_string(),
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
    let (mut ws, _response) = connect_async(&url)
        .await
        .expect("WebSocket connect failed");

    // Register with the broker so we can receive routed messages.
    ws.send(Message::Text(
        r#"{"type":"register","from":"echo-client","to":"","payload":null}"#.into(),
    ))
    .await
    .expect("register send failed");

    // Sleep to let the server process the registration before sending.
    // yield_now() is not a reliable barrier — a single scheduler yield does not
    // guarantee the server task runs to completion before the next send.
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;

    // Send an offer to ourselves — the broker routes it back to the same connection.
    let offer_msg = r#"{"type":"offer","from":"echo-client","to":"echo-client","payload":{}}"#;
    ws.send(Message::Text(offer_msg.into()))
        .await
        .expect("offer send failed");

    let reply = ws
        .next()
        .await
        .expect("no reply received")
        .expect("reply was an error");

    match reply {
        Message::Text(text) => {
            let env = immersive_rt_server::signaling::parse_envelope(text.as_bytes())
                .expect("reply should be a valid SignalingEnvelope");
            assert_eq!(
                env.msg_type, "offer",
                "relay self-routing: expected msg_type 'offer', got {:?}",
                env.msg_type
            );
            assert_eq!(
                env.from, "echo-client",
                "relay self-routing: expected from 'echo-client', got {:?}",
                env.from
            );
        }
        other => panic!("unexpected message type: {other:?}"),
    }
}
