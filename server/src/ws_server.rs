use futures_util::{SinkExt, StreamExt};
use tokio::net::TcpListener;
use tokio_tungstenite::accept_async;

pub async fn run(port: u16) -> anyhow::Result<()> {
    let listener = TcpListener::bind(format!("0.0.0.0:{}", port)).await?;
    tracing::info!("WebSocket fallback listening on :{}", port);
    run_with_listener(listener).await
}

pub async fn run_with_listener(listener: TcpListener) -> anyhow::Result<()> {
    loop {
        match listener.accept().await {
            Ok((stream, addr)) => {
                tokio::spawn(async move {
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
    match accept_async(stream).await {
        Ok(ws) => {
            let (mut write, mut read) = ws.split();
            while let Some(Ok(msg)) = read.next().await {
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
