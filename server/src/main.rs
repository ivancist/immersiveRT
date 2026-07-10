mod broker;
mod pairing_token;
mod room_registry;
mod signaling;
mod turn_creds;
mod wt_server;
mod ws_server;

use std::sync::Arc;
use axum::{extract::State, routing::get, Json, Router};

/// Spawn a background task that periodically scans for phones that have gone
/// silent (no heartbeat within `timeout_secs`) and marks their slots Disconnected,
/// broadcasting a `phone-state:heartbeat-miss` to room desktops (D-19, PHONE-06).
///
/// The monitor runs every `interval_secs` seconds. Both values are configurable via
/// `HEARTBEAT_MONITOR_INTERVAL_SECS` and `HEARTBEAT_TIMEOUT_SECS` env vars.
fn spawn_heartbeat_monitor(
    registry: Arc<room_registry::RoomRegistry>,
    broker: Arc<broker::SignalingBroker>,
    timeout_secs: u64,
    interval_secs: u64,
) {
    tokio::spawn(async move {
        let timeout = std::time::Duration::from_secs(timeout_secs);
        let interval = std::time::Duration::from_secs(interval_secs);
        loop {
            tokio::time::sleep(interval).await;
            let missing = registry.phones_missing_heartbeat(timeout);
            for (room_code, slot_id, _username, _phone_id) in missing {
                registry.handle_heartbeat_miss(&room_code, slot_id, &broker).await;
            }
        }
    });
}

/// Shared application state injected into the axum HTTP handler.
struct AppState {
    turn_shared_secret: String,
    /// Bearer token that callers must supply in the Authorization header to
    /// receive TURN credentials. Set via the API_TOKEN environment variable.
    api_token: String,
}

/// GET /turn-credentials — returns ephemeral TURN credentials for coturn's
/// use-auth-secret REST API mechanism (INFRA-04, D-06).
///
/// Requires `Authorization: Bearer <API_TOKEN>` — any unauthenticated request
/// receives 401. Credentials are generated fresh on every request (not cached);
/// the username encodes the expiry timestamp so each call returns a distinct value.
async fn turn_creds_handler(
    headers: axum::http::HeaderMap,
    State(state): State<Arc<AppState>>,
) -> Result<Json<turn_creds::TurnCredentials>, (axum::http::StatusCode, String)> {
    let token = headers
        .get("Authorization")
        .and_then(|v| v.to_str().ok())
        .ok_or_else(|| {
            (
                axum::http::StatusCode::UNAUTHORIZED,
                "Missing Authorization header".into(),
            )
        })?;
    use subtle::ConstantTimeEq;
    let expected = format!("Bearer {}", state.api_token);
    if expected.as_bytes().ct_eq(token.as_bytes()).unwrap_u8() == 0 {
        return Err((
            axum::http::StatusCode::UNAUTHORIZED,
            "Invalid token".into(),
        ));
    }
    turn_creds::generate_turn_credentials(&state.turn_shared_secret, "anonymous", 300)
        .map(Json)
        .map_err(|e| (axum::http::StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))
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
    // INFRA-04: TURN_SHARED_SECRET is a required env var — server refuses to start
    // without it. No default, no .unwrap_or_else. Error message includes remediation.
    let turn_shared_secret = std::env::var("TURN_SHARED_SECRET")
        .map_err(|_| anyhow::anyhow!(
            "TURN_SHARED_SECRET environment variable not set — \
             generate a random 32-char secret and set it before starting the server"
        ))?;
    // API_TOKEN gates the /turn-credentials endpoint. Required — refuse to start without it.
    let api_token = std::env::var("API_TOKEN")
        .map_err(|_| anyhow::anyhow!(
            "API_TOKEN environment variable not set — \
             generate a random token and set it before starting the server"
        ))?;
    // PAIRING_TOKEN_SECRET: HMAC secret for signing pairing tokens (D-14).
    // Required — server refuses to start without it (T-03-07 mitigation: value never logged).
    let pairing_token_secret = std::env::var("PAIRING_TOKEN_SECRET")
        .map_err(|_| anyhow::anyhow!(
            "PAIRING_TOKEN_SECRET environment variable not set — \
             generate a random 32+ char secret and set it before starting the server"
        ))?;
    // BASE_URL: public-facing HTTPS base URL embedded in pairing tokens (D-13).
    // Required — server refuses to start without it.
    let base_url = std::env::var("BASE_URL")
        .map_err(|_| anyhow::anyhow!(
            "BASE_URL environment variable not set — \
             set BASE_URL=https://<your-ip>:8443 before starting the server"
        ))?;
    // HOLD_TTL_SECS: how long to hold a disconnected player's slot before releasing it (D-16).
    let hold_ttl_secs: u64 = std::env::var("HOLD_TTL_SECS")
        .unwrap_or_else(|_| "60".into())
        .parse()
        .map_err(|e| anyhow::anyhow!("HOLD_TTL_SECS must be a valid u64 (seconds): {e}"))?;
    // PAIRING_TOKEN_TTL_SECS: lifetime of a pairing token before it expires (D-14).
    let pairing_ttl_secs: u64 = std::env::var("PAIRING_TOKEN_TTL_SECS")
        .unwrap_or_else(|_| "90".into())
        .parse()
        .map_err(|e| anyhow::anyhow!("PAIRING_TOKEN_TTL_SECS must be a valid u64 (seconds): {e}"))?;
    let http_port: u16 = std::env::var("HTTP_PORT")
        .unwrap_or_else(|_| "8081".into())
        .parse()
        .map_err(|e| anyhow::anyhow!("HTTP_PORT must be a valid u16 port number: {e}"))?;
    // HEARTBEAT_TIMEOUT_SECS: seconds of silence before a phone slot is marked Disconnected (D-19).
    let heartbeat_timeout_secs: u64 = std::env::var("HEARTBEAT_TIMEOUT_SECS")
        .unwrap_or_else(|_| "65".into())
        .parse()
        .map_err(|e| anyhow::anyhow!("HEARTBEAT_TIMEOUT_SECS must be a valid u64 (seconds): {e}"))?;
    // HEARTBEAT_MONITOR_INTERVAL_SECS: how often the monitor task wakes to check for stale phones.
    let heartbeat_interval_secs: u64 = std::env::var("HEARTBEAT_MONITOR_INTERVAL_SECS")
        .unwrap_or_else(|_| "10".into())
        .parse()
        .map_err(|e| anyhow::anyhow!("HEARTBEAT_MONITOR_INTERVAL_SECS must be a valid u64 (seconds): {e}"))?;
    // WR-05: TURN_CREDENTIAL_TTL_SECS — TTL for ephemeral TURN credentials generated at pair time.
    // Must be longer than pairing_ttl_secs to ensure credentials are still valid when a second
    // desktop joins after the initial pairing window. Default 3600 s (1 hour).
    let turn_credential_ttl_secs: u64 = std::env::var("TURN_CREDENTIAL_TTL_SECS")
        .unwrap_or_else(|_| "3600".into())
        .parse()
        .map_err(|e| anyhow::anyhow!("TURN_CREDENTIAL_TTL_SECS must be a valid u64 (seconds): {e}"))?;

    // T-03-07: log base_url (public, safe) but NOT pairing_token_secret value.
    tracing::info!(
        cert_path,
        key_path,
        wt_port,
        ws_port,
        http_port,
        base_url = %base_url,
        pairing_secret_set = true,
        "Server starting"
    );

    // Shared in-process signaling broker — both WT and WS listeners receive a
    // cloned handle pointing to the same DashMap (D-03).
    let broker = Arc::new(broker::SignalingBroker::new());

    // Room registry — manages room lifecycle, slot assignment, hold timers,
    // pairing token generation, and reconnect token lookup (SESS-01..SESS-06).
    // Constructed here and cloned into both WT and WS listeners.
    // turn_shared_secret is threaded here so handle_pair can generate ephemeral
    // TURN credentials without an extra HTTP call (INFRA-04, D-06, Phase 4).
    let room_registry = Arc::new(room_registry::RoomRegistry::new(
        pairing_token_secret,
        turn_shared_secret.clone(),
        base_url,
        hold_ttl_secs,
        pairing_ttl_secs,
        turn_credential_ttl_secs,
    ));

    // Start the heartbeat monitor before the server accept loops (D-19, PHONE-06).
    spawn_heartbeat_monitor(
        room_registry.clone(),
        broker.clone(),
        heartbeat_timeout_secs,
        heartbeat_interval_secs,
    );

    // WR-06: Periodically evict expired consumed pairing tokens to prevent unbounded growth.
    // Sweep every 5 minutes — tokens expire at pairing_ttl_secs (default 90 s), so a 5-minute
    // sweep keeps the map bounded to at most ~5× the per-TTL join rate.
    {
        let registry_for_sweep = room_registry.clone();
        tokio::spawn(async move {
            let interval = std::time::Duration::from_secs(300); // 5 minutes
            loop {
                tokio::time::sleep(interval).await;
                registry_for_sweep.sweep_expired_pairing_tokens();
            }
        });
    }

    // Axum HTTP state — Arc-wrapped so the handler can clone the secret reference.
    let app_state = Arc::new(AppState { turn_shared_secret, api_token });
    let http_app = Router::new()
        .route("/turn-credentials", get(turn_creds_handler))
        .with_state(app_state);
    let http_listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{}", http_port)).await?;
    tracing::info!(http_port, "TURN credential endpoint listening on :{}", http_port);

    // Run all three servers concurrently; stop if any one exits or errors.
    // The axum serve future returns io::Error; map to anyhow to unify error types.
    tokio::try_join!(
        wt_server::run(&cert_path, &key_path, wt_port, broker.clone(), room_registry.clone()),
        ws_server::run(ws_port, broker.clone(), room_registry.clone(), &cert_path, &key_path),
        async { axum::serve(http_listener, http_app).await.map_err(anyhow::Error::from) },
    )?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Unit test for the TURN credential handler — calls the handler directly without
    /// starting an HTTP server (INFRA-04). No network, no certs, no env vars needed.
    #[tokio::test]
    async fn test_turn_creds_handler_unit() {
        let state = AppState {
            turn_shared_secret: "test-secret".to_string(),
            api_token: "test-token".to_string(),
        };
        let mut headers = axum::http::HeaderMap::new();
        headers.insert(
            axum::http::header::AUTHORIZATION,
            axum::http::HeaderValue::from_static("Bearer test-token"),
        );
        let result = turn_creds_handler(headers, State(Arc::new(state))).await;
        let Json(creds) = result.expect("handler should succeed with valid token");
        assert!(
            creds.username.contains(':'),
            "username should contain ':' separator, got: {}",
            creds.username
        );
        assert!(!creds.password.is_empty(), "password should be non-empty");
        assert_eq!(creds.ttl_seconds, 300);
    }

    /// Requests without Authorization header must receive 401.
    #[tokio::test]
    async fn test_turn_creds_handler_rejects_missing_auth() {
        let state = AppState {
            turn_shared_secret: "test-secret".to_string(),
            api_token: "test-token".to_string(),
        };
        let result = turn_creds_handler(axum::http::HeaderMap::new(), State(Arc::new(state))).await;
        let err = result.expect_err("handler should fail without auth");
        assert_eq!(err.0, axum::http::StatusCode::UNAUTHORIZED);
    }

    /// Requests with wrong token must receive 401.
    #[tokio::test]
    async fn test_turn_creds_handler_rejects_wrong_token() {
        let state = AppState {
            turn_shared_secret: "test-secret".to_string(),
            api_token: "test-token".to_string(),
        };
        let mut headers = axum::http::HeaderMap::new();
        headers.insert(
            axum::http::header::AUTHORIZATION,
            axum::http::HeaderValue::from_static("Bearer wrong-token"),
        );
        let result = turn_creds_handler(headers, State(Arc::new(state))).await;
        let err = result.expect_err("handler should fail with wrong token");
        assert_eq!(err.0, axum::http::StatusCode::UNAUTHORIZED);
    }
}
