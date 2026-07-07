use anyhow::Context;
use futures_util::{SinkExt, StreamExt};
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpListener;
use tokio::sync::Semaphore;
use tokio_rustls::TlsAcceptor;
use tokio_tungstenite::accept_async_with_config;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::Message;

use crate::broker::SignalingBroker;
use crate::signaling::parse_envelope;

/// Maximum WebSocket message / frame size — ample for IMU packets, blocks 64 MiB default abuse.
const MAX_WS_MESSAGE_BYTES: usize = 64 * 1024; // 64 KiB

/// Maximum number of simultaneous WebSocket connections.
const MAX_WS_CONNECTIONS: usize = 1024;

/// Load a TLS acceptor from PEM cert and key files (rustls-pemfile 2.x API).
///
/// Callers that receive an `Err` should fall back to plain WS.
pub(crate) fn load_tls_acceptor(cert_path: &str, key_path: &str) -> anyhow::Result<TlsAcceptor> {
    use rustls_pemfile::{certs, private_key};
    use std::io::BufReader;
    use tokio_rustls::rustls::ServerConfig;

    let cert_file = &mut BufReader::new(
        std::fs::File::open(cert_path)
            .with_context(|| format!("Failed to open cert file {cert_path}"))?,
    );
    let key_file = &mut BufReader::new(
        std::fs::File::open(key_path)
            .with_context(|| format!("Failed to open key file {key_path}"))?,
    );

    let cert_chain = certs(cert_file).collect::<Result<Vec<_>, _>>()?;
    let key = private_key(key_file)?
        .ok_or_else(|| anyhow::anyhow!("no private key found in {key_path}"))?;

    let config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(cert_chain, key)?;
    Ok(TlsAcceptor::from(Arc::new(config)))
}

pub async fn run(
    port: u16,
    broker: Arc<SignalingBroker>,
    cert_path: &str,
    key_path: &str,
) -> anyhow::Result<()> {
    let listener = TcpListener::bind(format!("0.0.0.0:{}", port)).await?;
    tracing::info!("WebSocket fallback listening on :{}", port);
    let tls = match load_tls_acceptor(cert_path, key_path) {
        Ok(acceptor) => {
            tracing::info!("WSS TLS enabled (cert={cert_path})");
            Some(acceptor)
        }
        Err(e) => {
            tracing::warn!("WSS TLS not available ({e}), falling back to plain WS");
            None
        }
    };
    run_with_listener(listener, broker, tls).await
}

pub async fn run_with_listener(
    listener: TcpListener,
    broker: Arc<SignalingBroker>,
    tls: Option<TlsAcceptor>,
) -> anyhow::Result<()> {
    let sem = Arc::new(Semaphore::new(MAX_WS_CONNECTIONS));
    loop {
        match listener.accept().await {
            Ok((stream, addr)) => {
                let permit = sem.clone().acquire_owned().await
                    .expect("WS connection semaphore was unexpectedly closed");
                let broker = broker.clone();
                let tls = tls.clone();
                tokio::spawn(async move {
                    let _permit = permit; // Released when the connection closes
                    if let Err(e) = handle_ws_connection(stream, addr, broker, tls).await {
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
    tcp_stream: tokio::net::TcpStream,
    addr: SocketAddr,
    broker: Arc<SignalingBroker>,
    tls: Option<TlsAcceptor>,
) -> anyhow::Result<()> {
    let config = WebSocketConfig::default()
        .max_message_size(Some(MAX_WS_MESSAGE_BYTES))
        .max_frame_size(Some(MAX_WS_MESSAGE_BYTES));

    // If TLS is configured, wrap the TCP stream before the WS upgrade.
    // relay_ws is generic over the stream type, so both TcpStream and TlsStream<TcpStream>
    // go through the same relay logic after the WS upgrade — no boxing needed.
    if let Some(acceptor) = tls {
        match acceptor.accept(tcp_stream).await {
            Ok(tls_stream) => relay_ws(tls_stream, addr, broker, config).await,
            Err(e) => {
                tracing::warn!("TLS handshake failed from {addr}: {e}");
                Ok(())
            }
        }
    } else {
        relay_ws(tcp_stream, addr, broker, config).await
    }
}

/// Generic relay function that handles the WebSocket signaling relay loop.
///
/// `S` is the underlying transport stream (plain TcpStream or TlsStream<TcpStream>).
/// Using generics instead of trait objects avoids the "multiple non-auto traits in dyn"
/// limitation and compiles to zero-overhead monomorphized code.
async fn relay_ws<S>(
    stream: S,
    addr: SocketAddr,
    broker: Arc<SignalingBroker>,
    config: WebSocketConfig,
) -> anyhow::Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    match accept_async_with_config(stream, Some(config)).await {
        Ok(ws) => {
            tracing::debug!("WS connection accepted from {addr}");
            let (mut write, mut read) = ws.split();

            // broker_rx is None until the first "register" message is received.
            // Before registration, inbound messages that are not "register" type are dropped.
            let mut my_id: Option<String> = None;
            let mut broker_rx: Option<tokio::sync::mpsc::UnboundedReceiver<Vec<u8>>> = None;

            loop {
                tokio::select! {
                    // Arm 1: inbound frame from this client
                    msg_opt = read.next() => {
                        let result = match msg_opt {
                            Some(r) => r,
                            None => break, // client disconnected
                        };
                        let msg = match result {
                            Ok(m) => m,
                            Err(e) => {
                                tracing::warn!("WS read error from {addr}: {e}");
                                break;
                            }
                        };
                        // Only process data frames; control frames (Ping, Pong, Close) are
                        // handled by tungstenite internally — echoing them back would violate
                        // RFC 6455 §5.5.2-5.5.3.
                        match &msg {
                            Message::Text(_) | Message::Binary(_) => {}
                            _ => continue,
                        }
                        let bytes: &[u8] = match &msg {
                            Message::Text(t) => t.as_bytes(),
                            Message::Binary(b) => b.as_ref(),
                            _ => unreachable!(),
                        };
                        // Deserialize envelope; drop malformed payloads without panicking (T-01-06)
                        let envelope = match parse_envelope(bytes) {
                            Some(e) => e,
                            None => {
                                tracing::warn!("Malformed signaling envelope from {addr}, dropping");
                                continue;
                            }
                        };
                        if envelope.msg_type == "register" {
                            // Register with broker; subsequent inbound messages route via broker.
                            let id = envelope.from.clone();
                            match broker.register(id.clone()) {
                                Ok(rx) => {
                                    my_id = Some(id.clone());
                                    broker_rx = Some(rx);
                                    tracing::info!(client_id = %id, "WS client registered from {addr}");
                                }
                                Err(e) => {
                                    tracing::warn!(
                                        client_id = %id,
                                        "WS registration rejected from {addr}: {e}, closing connection"
                                    );
                                    break;
                                }
                            }
                        } else if my_id.is_none() {
                            // Cannot route without an ID — drop and warn.
                            tracing::warn!(
                                "WS client from {addr} not yet registered, dropping message"
                            );
                        } else {
                            // Validate the 'from' field matches the registered ID to prevent
                            // message spoofing / man-in-the-middle of WebRTC negotiation.
                            let registered_id = my_id.as_ref().unwrap();
                            if envelope.from != *registered_id {
                                tracing::warn!(
                                    registered = %registered_id,
                                    claimed_from = %envelope.from,
                                    "WS client spoofed 'from' field, dropping message"
                                );
                                continue;
                            }
                            // Route to the target client; caller logs the warning per D-05.
                            let payload = match serde_json::to_vec(&envelope) {
                                Ok(p) => p,
                                Err(e) => {
                                    tracing::warn!("Failed to re-serialize envelope: {e}");
                                    continue;
                                }
                            };
                            if !broker.route(&envelope.to, payload) {
                                tracing::warn!(
                                    to = %envelope.to,
                                    "signaling target not connected, dropping"
                                );
                            }
                        }
                    }

                    // Arm 2: outbound — another client routed a message to us via the broker.
                    // When broker_rx is None (not yet registered), the async block returns Pending
                    // via std::future::pending(), keeping this arm dormant until registration.
                    maybe_payload = async {
                        match broker_rx.as_mut() {
                            Some(rx) => rx.recv().await,
                            None => std::future::pending::<Option<Vec<u8>>>().await,
                        }
                    } => {
                        match maybe_payload {
                            Some(payload) => {
                                let text = String::from_utf8_lossy(&payload).into_owned();
                                if write.send(Message::Text(text.into())).await.is_err() {
                                    tracing::warn!("WS send failed to {addr}, closing connection");
                                    break;
                                }
                            }
                            None => {
                                // Broker channel closed — connection should be torn down.
                                tracing::info!(
                                    "WS broker channel closed for {addr}, exiting relay loop"
                                );
                                break;
                            }
                        }
                    }
                }
            }
            tracing::debug!("WS connection from {addr} closed");
            if let Some(id) = &my_id {
                broker.unregister(id);
                tracing::info!(client_id = %id, "WS client unregistered");
            }
        }
        Err(e) => {
            tracing::warn!("WS upgrade failed from {addr}: {e}");
        }
    }
    Ok(())
}
