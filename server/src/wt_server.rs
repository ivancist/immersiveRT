use anyhow::Context;
use wtransport::endpoint::IncomingSession;
use wtransport::{Endpoint, Identity, ServerConfig};

use crate::echo::{now_ms, EchoMessage};

/// Run the WebTransport listener.
///
/// Loads mkcert TLS certs from `cert_path` / `key_path`, binds to UDP `port`, and enters
/// an accept loop.  Each accepted connection is dispatched to a `tokio::spawn`; errors in
/// connection tasks are logged but do not kill the accept loop.
pub async fn run(cert_path: &str, key_path: &str, port: u16) -> anyhow::Result<()> {
    let identity = Identity::load_pemfiles(cert_path, key_path)
        .await
        .with_context(|| format!("Failed to load TLS certs from {cert_path} / {key_path}"))?;

    let config = ServerConfig::builder()
        .with_bind_default(port)
        .with_identity(identity)
        .build();

    let server = Endpoint::server(config)?;
    tracing::info!("WebTransport listening on :{}", port);

    loop {
        let incoming = server.accept().await;
        tokio::spawn(async move {
            if let Err(e) = handle_wt_connection(incoming).await {
                tracing::error!("WT connection error: {e:#}");
            }
        });
    }
}

/// Handle a single WebTransport connection.
///
/// Follows the three-step accept pattern required by wtransport:
/// 1. `IncomingSession` — await to get the HTTP/3 request
/// 2. `request.accept()` — complete the WebTransport handshake
/// 3. Enter echo loop on bidirectional streams
async fn handle_wt_connection(incoming: IncomingSession) -> anyhow::Result<()> {
    let request = incoming
        .await
        .context("WebTransport session request failed")?;

    tracing::info!(
        authority = %request.authority(),
        path = %request.path(),
        "WT session request received"
    );

    let conn = request.accept().await.context("WT session accept failed")?;

    tracing::info!("WT session accepted");

    loop {
        let (mut send, mut recv) = conn
            .accept_bi()
            .await
            .context("accept_bi failed — connection likely closed")?;

        // Read the full stream payload until FIN — QUIC is a byte stream, not a
        // message stream.  A single recv.read() can return any number of bytes from
        // 1 to buf.len(), so we must loop until we get None (FIN) to avoid partial
        // reads that silently desync the connection (CR-003).
        let mut buf: Vec<u8> = Vec::new();
        loop {
            let mut chunk = vec![0u8; 4096];
            match recv.read(&mut chunk).await.context("recv read failed")? {
                Some(n) => buf.extend_from_slice(&chunk[..n]),
                None => break, // FIN — stream complete
            }
            // Guard against unbounded memory growth from a misbehaving peer
            if buf.len() > 65_536 {
                tracing::warn!("Oversized WT message ({} bytes), dropping stream", buf.len());
                buf.clear();
                break;
            }
        }

        if buf.is_empty() {
            // Stream closed cleanly with no data — exit the connection loop
            break;
        }

        // Deserialize EchoMessage; drop malformed payloads without panicking (T-01-06)
        let msg: EchoMessage = match serde_json::from_slice(&buf) {
            Ok(m) => m,
            Err(e) => {
                tracing::warn!("Malformed echo message ({e}), dropping");
                continue;
            }
        };

        if msg.msg_type != "ping" {
            tracing::warn!(msg_type = %msg.msg_type, "Unexpected message type, ignoring");
            // Finish the send stream cleanly so the peer receives EOF rather than
            // RESET_STREAM (RFC 9000 §3.3 — dropping without finish() sends RESET_STREAM).
            let _ = send.finish().await;
            continue;
        }

        let pong = EchoMessage {
            msg_type: "pong".into(),
            client_ts: msg.client_ts,
            server_ts: Some(now_ms()),
        };

        let reply = serde_json::to_vec(&pong).context("pong serialization failed")?;
        send.write_all(&reply)
            .await
            .context("send write_all failed")?;
    }

    Ok(())
}
