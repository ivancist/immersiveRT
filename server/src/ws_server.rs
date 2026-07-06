use futures_util::{SinkExt, StreamExt};
use std::sync::Arc;
use tokio::net::TcpListener;
use tokio::sync::Semaphore;
use tokio_tungstenite::accept_async_with_config;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::Message;

/// Maximum WebSocket message / frame size — ample for IMU packets, blocks 64 MiB default abuse.
const MAX_WS_MESSAGE_BYTES: usize = 64 * 1024; // 64 KiB

/// Maximum number of simultaneous WebSocket connections.
const MAX_WS_CONNECTIONS: usize = 1024;

pub async fn run(port: u16) -> anyhow::Result<()> {
    let listener = TcpListener::bind(format!("0.0.0.0:{}", port)).await?;
    tracing::info!("WebSocket fallback listening on :{}", port);
    run_with_listener(listener).await
}

pub async fn run_with_listener(listener: TcpListener) -> anyhow::Result<()> {
    let sem = Arc::new(Semaphore::new(MAX_WS_CONNECTIONS));
    loop {
        match listener.accept().await {
            Ok((stream, addr)) => {
                let permit = sem.clone().acquire_owned().await.unwrap();
                tokio::spawn(async move {
                    let _permit = permit; // Released when the connection closes
                    if let Err(e) = handle_ws_connection(stream, addr).await {
                        tracing::warn!("WS connection error from {addr}: {e}");
                    }
                });
            }
            Err(e) => {
                tracing::error!("WS accept error: {e}");
                use std::io::ErrorKind;
                match e.kind() {
                    ErrorKind::ConnectionAborted
                    | ErrorKind::ConnectionReset
                    | ErrorKind::Interrupted => continue,
                    _ => return Err(e.into()),
                }
            }
        }
    }
}

async fn handle_ws_connection(
    stream: tokio::net::TcpStream,
    addr: std::net::SocketAddr,
) -> anyhow::Result<()> {
    let config = WebSocketConfig::default()
        .max_message_size(Some(MAX_WS_MESSAGE_BYTES))
        .max_frame_size(Some(MAX_WS_MESSAGE_BYTES));
    match accept_async_with_config(stream, Some(config)).await {
        Ok(ws) => {
            let (mut write, mut read) = ws.split();
            while let Some(result) = read.next().await {
                let msg = match result {
                    Ok(m) => m,
                    Err(e) => {
                        tracing::warn!("WS read error from {addr}: {e}");
                        break;
                    }
                };
                // Only echo data frames; control frames (Ping, Pong, Close) are
                // handled by tungstenite internally — echoing them back would
                // violate RFC 6455 §5.5.2-5.5.3.
                match &msg {
                    Message::Text(_) | Message::Binary(_) => {}
                    _ => continue,
                }
                if write.send(msg).await.is_err() {
                    break;
                }
            }
            tracing::debug!("WS connection from {addr} closed");
        }
        Err(e) => {
            tracing::warn!("WS upgrade failed from {addr}: {e}");
        }
    }
    Ok(())
}
