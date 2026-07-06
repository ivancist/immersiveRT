mod broker;
mod echo;
mod signaling;
mod turn_creds;
mod wt_server;
mod ws_server;

use std::sync::Arc;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt::init();

    // Install the aws_lc_rs CryptoProvider once before any TLS code runs.
    // wtransport's quinn dependency already uses aws_lc_rs; making this explicit
    // prevents a runtime panic if two crates try to install different providers
    // concurrently (RESEARCH.md Pitfall 3).
    let _ = tokio_rustls::rustls::crypto::aws_lc_rs::default_provider().install_default();

    let cert_path = std::env::var("CERT_PATH")
        .unwrap_or_else(|_| "certs/localhost+2.pem".into());
    let key_path = std::env::var("KEY_PATH")
        .unwrap_or_else(|_| "certs/localhost+2-key.pem".into());
    let wt_port: u16 = std::env::var("WT_PORT")
        .unwrap_or_else(|_| "4433".into())
        .parse()
        .map_err(|e| anyhow::anyhow!("WT_PORT must be a valid u16 port number: {e}"))?;
    // D-02: default port changed from 8080 to 9090 to avoid common port conflicts.
    let ws_port: u16 = std::env::var("WS_PORT")
        .unwrap_or_else(|_| "9090".into())
        .parse()
        .map_err(|e| anyhow::anyhow!("WS_PORT must be a valid u16 port number: {e}"))?;

    tracing::info!(cert_path, key_path, wt_port, ws_port, "Server starting");

    // Shared in-process signaling broker — both listeners receive a cloned handle
    // pointing to the same DashMap (D-03).
    let broker = Arc::new(broker::SignalingBroker::new());

    tokio::try_join!(
        wt_server::run(&cert_path, &key_path, wt_port, broker.clone()),
        ws_server::run(ws_port, broker.clone(), &cert_path, &key_path),
    )?;

    Ok(())
}
