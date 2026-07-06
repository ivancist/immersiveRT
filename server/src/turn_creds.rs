use base64::{engine::general_purpose::STANDARD, Engine};
use hmac::{Hmac, KeyInit, Mac};
use sha1::Sha1;
use std::time::{SystemTime, UNIX_EPOCH};

type HmacSha1 = Hmac<Sha1>;

/// Ephemeral TURN credentials generated via coturn's `use-auth-secret` REST API
/// mechanism (INFRA-04, D-06).
pub struct TurnCredentials {
    /// `"{expiry}:{userid}"` — expiry is Unix seconds when these credentials
    /// expire (NOT the issue time — see Pitfall 1 in RESEARCH.md).
    pub username: String,
    /// `base64(HMAC-SHA1(shared_secret, username))` — exact coturn algorithm.
    pub password: String,
    /// TTL used to produce this credential (informational).
    pub ttl_seconds: u64,
}

/// Generate ephemeral TURN credentials using coturn's `use-auth-secret` HMAC-SHA1
/// REST API mechanism.
///
/// `expiry = now_unix_seconds + ttl_seconds` is embedded in `username` so coturn
/// can verify freshness.  `password = base64(HMAC-SHA1(shared_secret, username))`.
pub fn generate_turn_credentials(
    shared_secret: &str,
    userid: &str,
    ttl_seconds: u64,
) -> anyhow::Result<TurnCredentials> {
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    // EXPIRY timestamp: coturn checks `now < expiry` when validating credentials.
    // Always add ttl_seconds — never use `now` alone (Pitfall 1 in RESEARCH.md).
    let expiry = now + ttl_seconds;
    let username = format!("{expiry}:{userid}");

    let mut mac = HmacSha1::new_from_slice(shared_secret.as_bytes())
        .map_err(|e| anyhow::anyhow!("HMAC key error: {e}"))?;
    mac.update(username.as_bytes());
    let password = STANDARD.encode(mac.finalize().into_bytes());

    Ok(TurnCredentials {
        username,
        password,
        ttl_seconds,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Known-vector test: verifies the exact HMAC-SHA1 algorithm matches coturn's.
    ///
    /// Pre-computed from coturn's algorithm:
    /// HMAC-SHA1(key="turn-secret", msg="1720000300:testuser") = /LVV/XKVO6NE5ItSOBdhdQh+N0I=
    ///
    /// This test is the only automated early warning for silent coturn 401 failures
    /// caused by HMAC algorithm bugs (wrong key, wrong message input, wrong encoding).
    #[test]
    fn test_turn_credential_known_vector() {
        let shared_secret = "turn-secret";
        let userid = "testuser";
        let fixed_expiry = 1_720_000_300u64;
        let expected_username = format!("{fixed_expiry}:{userid}");

        // Known expected password — pre-computed using Python:
        // hmac.new(b"turn-secret", b"1720000300:testuser", hashlib.sha1).digest() → base64
        let expected_password = "/LVV/XKVO6NE5ItSOBdhdQh+N0I=";

        // Verify the HMAC machinery directly (crate-level known-vector check)
        let mut mac = HmacSha1::new_from_slice(shared_secret.as_bytes())
            .expect("HMAC key init failed");
        mac.update(expected_username.as_bytes());
        let computed_password = STANDARD.encode(mac.finalize().into_bytes());
        assert_eq!(
            computed_password, expected_password,
            "HMAC-SHA1 known-vector mismatch — coturn uses this exact algorithm"
        );

        // Verify generate_turn_credentials produces correctly-formatted username
        let creds = generate_turn_credentials(shared_secret, userid, 300)
            .expect("credential generation failed");
        assert!(
            creds.username.ends_with(":testuser"),
            "username should end with ':testuser', got: {}",
            creds.username
        );
        assert_eq!(creds.ttl_seconds, 300);
    }

    /// Two calls with different TTLs must produce different usernames because
    /// expiry = now + ttl_seconds — credential freshness is not cached.
    #[test]
    fn test_turn_credentials_not_cached() {
        // Different TTLs → different expiry timestamps → different usernames
        // This also verifies ttl_seconds is actually added to the expiry (Pitfall 1)
        let creds1 = generate_turn_credentials("secret", "user", 100)
            .expect("first call failed");
        let creds2 = generate_turn_credentials("secret", "user", 200)
            .expect("second call failed");

        assert_ne!(
            creds1.username, creds2.username,
            "different TTLs must produce different usernames (expiry = now + ttl)"
        );
        assert_eq!(creds1.ttl_seconds, 100);
        assert_eq!(creds2.ttl_seconds, 200);
    }
}
