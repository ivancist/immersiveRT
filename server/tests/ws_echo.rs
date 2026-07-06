use futures_util::{SinkExt, StreamExt};
use tokio_tungstenite::{connect_async, tungstenite::Message};

#[tokio::test]
async fn test_ws_echo() {
    // Bind before spawning so a port conflict is an immediate, clear test failure
    // rather than a misleading "connect failed" error after a 50ms sleep.
    // Port 0 asks the OS for an available ephemeral port — no hardcoded port needed.
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("failed to bind test listener");
    let addr = listener.local_addr().expect("no local addr");

    tokio::spawn(immersive_rt_server::ws_server::run_with_listener(listener));

    let url = format!("ws://{}", addr);
    let (mut ws, _response) = connect_async(&url)
        .await
        .expect("WebSocket connect failed");

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
