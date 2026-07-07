use anyhow::Context;
use std::sync::Arc;
use wtransport::endpoint::IncomingSession;
use wtransport::{Endpoint, Identity, ServerConfig};

use crate::broker::SignalingBroker;
use crate::signaling::parse_envelope;

/// Run the WebTransport listener.
///
/// Loads mkcert TLS certs from `cert_path` / `key_path`, binds to UDP `port`, and enters
/// an accept loop.  Each accepted connection is dispatched to a `tokio::spawn`; errors in
/// connection tasks are logged but do not kill the accept loop.
pub async fn run(
    cert_path: &str,
    key_path: &str,
    port: u16,
    broker: Arc<SignalingBroker>,
) -> anyhow::Result<()> {
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
        let broker = broker.clone();
        tokio::spawn(async move {
            if let Err(e) = handle_wt_connection(incoming, broker).await {
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
/// 3. Read the first client-opened stream to get the "register" message
/// 4. Register with broker, enter signaling relay select! loop
async fn handle_wt_connection(
    incoming: IncomingSession,
    broker: Arc<SignalingBroker>,
) -> anyhow::Result<()> {
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

    // Read the first client-opened stream to get the "register" message.
    let (mut send_init, mut recv_init) = conn
        .accept_bi()
        .await
        .context("accept_bi for register failed")?;

    let mut buf: Vec<u8> = Vec::new();
    loop {
        let mut chunk = vec![0u8; 4096];
        match recv_init
            .read(&mut chunk)
            .await
            .context("recv read for register failed")?
        {
            Some(n) => buf.extend_from_slice(&chunk[..n]),
            None => break, // FIN — stream complete
        }
        if buf.len() > 65_536 {
            tracing::warn!(
                "Oversized WT register message ({} bytes), dropping connection",
                buf.len()
            );
            return Ok(());
        }
    }
    // Close the send side of the registration stream (we don't send a response).
    let _ = send_init.finish().await;

    let register_env = match parse_envelope(&buf) {
        Some(e) if e.msg_type == "register" => e,
        Some(e) => {
            tracing::warn!(
                msg_type = %e.msg_type,
                "First WT message was not 'register', closing connection"
            );
            return Ok(());
        }
        None => {
            tracing::warn!("Malformed WT register message, closing connection");
            return Ok(());
        }
    };

    let my_id = register_env.from.clone();
    let mut broker_rx = match broker.register(my_id.clone()) {
        Ok(rx) => rx,
        Err(e) => {
            tracing::warn!(
                client_id = %my_id,
                "WT registration rejected: {e}, closing connection"
            );
            return Ok(());
        }
    };
    tracing::info!(client_id = %my_id, "WT client registered");

    // Main relay loop: race inbound streams from the client against outbound messages
    // pushed via the broker channel.
    loop {
        tokio::select! {
            // Arm 1: inbound — client opens a new stream with a signaling message.
            result = conn.accept_bi() => {
                match result {
                    Ok((mut send, mut recv)) => {
                        // Read the full stream payload until FIN.  A single recv.read() can
                        // return any number of bytes from 1 to buf.len(), so we must loop
                        // until None (FIN) to avoid partial reads (CR-003).
                        let mut buf: Vec<u8> = Vec::new();
                        let read_ok = loop {
                            let mut chunk = vec![0u8; 4096];
                            match recv.read(&mut chunk).await {
                                Ok(Some(n)) => buf.extend_from_slice(&chunk[..n]),
                                Ok(None) => break true,  // FIN — stream complete
                                Err(e) => {
                                    tracing::warn!("WT recv read error: {e}");
                                    break false;
                                }
                            }
                            // Guard against unbounded memory growth from a misbehaving peer
                            if buf.len() > 65_536 {
                                tracing::warn!(
                                    "Oversized WT message ({} bytes), dropping stream",
                                    buf.len()
                                );
                                buf.clear();
                                break false;
                            }
                        };

                        if !read_ok || buf.is_empty() {
                            let _ = send.finish().await;
                            continue;
                        }

                        // Deserialize envelope; drop malformed payloads without panicking (T-01-06)
                        let envelope = match parse_envelope(&buf) {
                            Some(e) => e,
                            None => {
                                tracing::warn!("Malformed signaling envelope, dropping");
                                let _ = send.finish().await;
                                continue;
                            }
                        };

                        // Skip re-registration — client already registered at connect time.
                        if envelope.msg_type == "register" {
                            let _ = send.finish().await;
                            continue;
                        }

                        // Validate the 'from' field matches the registered ID to prevent
                        // message spoofing / man-in-the-middle of WebRTC negotiation.
                        if envelope.from != my_id {
                            tracing::warn!(
                                registered = %my_id,
                                claimed_from = %envelope.from,
                                "WT client spoofed 'from' field, dropping message"
                            );
                            let _ = send.finish().await;
                            continue;
                        }

                        // Re-serialize the envelope to forward its bytes via the broker.
                        let payload = match serde_json::to_vec(&envelope) {
                            Ok(p) => p,
                            Err(e) => {
                                tracing::warn!("Failed to re-serialize envelope: {e}");
                                let _ = send.finish().await;
                                continue;
                            }
                        };

                        // Route to the target client; caller logs the warning per D-05.
                        if !broker.route(&envelope.to, payload) {
                            tracing::warn!(
                                to = %envelope.to,
                                "signaling target not connected, dropping"
                            );
                        }

                        // Finish the send side — we never send a response back on this stream.
                        let _ = send.finish().await;
                    }
                    Err(e) => {
                        tracing::info!(client_id = %my_id, "WT accept_bi closed ({e}), exiting relay loop");
                        break;
                    }
                }
            }

            // Arm 2: outbound — another client routed a message to us via the broker.
            payload = broker_rx.recv() => {
                match payload {
                    Some(payload) => {
                        // Open a new bidirectional stream to push the message to the client.
                        // wtransport::Connection::open_bi() returns Result<OpeningBiStream, _>;
                        // OpeningBiStream must be awaited a second time to get (SendStream, RecvStream).
                        let opening = match conn.open_bi().await {
                            Ok(o) => o,
                            Err(e) => {
                                tracing::warn!(
                                    client_id = %my_id,
                                    "WT open_bi failed for push: {e}"
                                );
                                continue;
                            }
                        };
                        match opening.await {
                            Ok((mut send, _recv)) => {
                                if let Err(e) = send.write_all(&payload).await {
                                    tracing::warn!(
                                        client_id = %my_id,
                                        "WT write_all failed for push: {e}"
                                    );
                                    continue;
                                }
                                if let Err(e) = send.finish().await {
                                    tracing::warn!(
                                        client_id = %my_id,
                                        "WT finish failed for push: {e}"
                                    );
                                }
                            }
                            Err(e) => {
                                tracing::warn!(
                                    client_id = %my_id,
                                    "WT stream open failed for push: {e}"
                                );
                            }
                        }
                    }
                    None => {
                        // Broker channel closed — connection should be torn down.
                        tracing::info!(client_id = %my_id, "WT broker channel closed, exiting relay loop");
                        break;
                    }
                }
            }
        }
    }

    broker.unregister(&my_id);
    tracing::info!(client_id = %my_id, "WT client unregistered");
    Ok(())
}
