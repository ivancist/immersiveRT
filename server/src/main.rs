mod broker;
mod echo;
mod signaling;
mod turn_creds;
mod wt_server;
mod ws_server;

use std::sync::Arc;
use axum::{extract::State, Json};

struct AppState {
    turn_shared_secret: String,
}

/// GET /turn-credentials — returns ephemeral TURN credentials for coturn's
/// use-auth-secret REST API mechanism (INFRA-04, D-06).
/// RED stub — returns Err until GREEN implementation replaces it.
#[allow(dead_code)]
async fn turn_creds_handler(
    State(state): State<Arc<AppState>>,
) -> Result<Json<turn_creds::TurnCredentials>, String> {
    let _ = &state.turn_shared_secret;
    Err("not implemented".to_string())
}

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

#[cfg(test)]
mod tests {
    use super::*;

    /// Unit test for the TURN credential handler — calls the handler directly without
    /// starting an HTTP server (INFRA-04). RED: panics on .expect() because the stub
    /// returns Err("not implemented").
    #[tokio::test]
    async fn test_turn_creds_handler_unit() {
        let state = AppState {
            turn_shared_secret: "test-secret".to_string(),
        };
        let result = turn_creds_handler(State(Arc::new(state))).await;
        let Json(creds) = result.expect("handler should succeed");
        assert!(
            creds.username.contains(':'),
            "username should contain ':' separator, got: {}",
            creds.username
        );
        assert!(!creds.password.is_empty(), "password should be non-empty");
        assert_eq!(creds.ttl_seconds, 300);
    }
}
