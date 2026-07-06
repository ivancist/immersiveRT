use futures_util::{SinkExt, StreamExt};
use std::time::Duration;
use tokio_tungstenite::{connect_async, tungstenite::Message};

#[tokio::test]
async fn test_ws_echo() {
    // Spawn the WebSocket listener on a dedicated test port to avoid conflicts with
    // a running server instance (port 8080).
    tokio::spawn(immersive_rt_server::ws_server::run(18080));

    // Give the listener a moment to bind before connecting.
    tokio::time::sleep(Duration::from_millis(50)).await;

    let (mut ws, _response) = connect_async("ws://127.0.0.1:18080")
        .await
        .expect("WebSocket connect failed — is port 18080 available?");

    let payload = "hello-echo-test";
    ws.send(Message::Text(payload.into()))
        .await
        .expect("send failed");

    let reply = ws
        .next()
        .await
        .expect("no reply received")
        .expect("reply was an error");

    match reply {
        Message::Text(text) => {
            assert_eq!(text, payload, "echo mismatch: got {text:?}, expected {payload:?}");
        }
        other => panic!("unexpected message type: {other:?}"),
    }
}
