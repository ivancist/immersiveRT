mod echo;
mod wt_server;
mod ws_server;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt::init();

    let cert_path = std::env::var("CERT_PATH")
        .unwrap_or_else(|_| "certs/localhost+2.pem".into());
    let key_path = std::env::var("KEY_PATH")
        .unwrap_or_else(|_| "certs/localhost+2-key.pem".into());
    let wt_port: u16 = std::env::var("WT_PORT")
        .unwrap_or_else(|_| "4433".into())
        .parse()
        .unwrap_or(4433);
    let ws_port: u16 = std::env::var("WS_PORT")
        .unwrap_or_else(|_| "8080".into())
        .parse()
        .unwrap_or(8080);

    tracing::info!(cert_path, key_path, wt_port, ws_port, "Server starting");

    // Listener spawns added in Plans 02 and 03; stubs return Ok(()) immediately.
    tokio::try_join!(
        wt_server::run(&cert_path, &key_path, wt_port),
        ws_server::run(ws_port),
    )?;

    Ok(())
}
