use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use dashmap::DashMap;
use hmac::{Hmac, KeyInit, Mac};
use sha2::Sha256;
use std::{
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};

type HmacSha256 = Hmac<Sha256>;

/// Single-use tracking store for HMAC pairing tokens.
///
/// Wraps an `Arc<DashMap<String, u64>>` (token → expiry_unix) so that `Clone` shares
/// the same underlying map across all handles — matching the broker/registry
/// Arc<DashMap> clone pattern (PATTERNS.md §pairing_token).
///
/// WR-06: expiry is stored alongside the token so `sweep_expired` can evict entries
/// whose TTL has elapsed, preventing unbounded growth on long-running servers.
#[derive(Clone)]
pub struct PairingTokenStore {
    /// token → expiry_unix_secs (stored to enable expiry-based sweep, WR-06)
    used_tokens: Arc<DashMap<String, u64>>,
}

impl PairingTokenStore {
    pub fn new() -> Self {
        Self {
            used_tokens: Arc::new(DashMap::new()),
        }
    }

    /// Validate a pairing token and mark it as consumed if valid.
    ///
    /// Returns `Some((room_code, slot_id))` on the **first** call with a valid,
    /// unexpired token; returns `None` on every subsequent call with the same
    /// token (single-use, per D-14).
    ///
    /// HMAC verification uses `verify_slice` which is constant-time — never
    /// use `==` for HMAC byte comparison (timing attack, RESEARCH.md Anti-Patterns).
    pub fn validate_and_consume(&self, secret: &str, token: &str) -> Option<(String, u8)> {
        // Split on '.' to separate base64url(payload) from base64url(sig)
        let (enc_payload, enc_sig) = token.split_once('.')?;

        // Decode payload and signature
        let payload_bytes = URL_SAFE_NO_PAD.decode(enc_payload).ok()?;
        let payload = std::str::from_utf8(&payload_bytes).ok()?;
        let sig_bytes = URL_SAFE_NO_PAD.decode(enc_sig).ok()?;

        // Constant-time HMAC verification (T-03-03 mitigation)
        let mut mac = HmacSha256::new_from_slice(secret.as_bytes()).ok()?;
        mac.update(payload.as_bytes());
        mac.verify_slice(&sig_bytes).ok()?;

        // Parse payload: "{room_code}:{slot_id}:{expiry}"
        let mut parts = payload.splitn(3, ':');
        let room_code = parts.next()?.to_string();
        let slot_id: u8 = parts.next()?.parse().ok()?;
        let expiry: u64 = parts.next()?.parse().ok()?;

        // Check expiry
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .ok()?
            .as_secs();
        if now >= expiry {
            return None;
        }

        // Atomic check-and-mark: Vacant → insert expiry + return Some; Occupied → return None
        // Per D-14: single-use tracking via DashMap entry (T-03-01 mitigation).
        // WR-06: store expiry so sweep_expired can evict stale entries.
        use dashmap::mapref::entry::Entry;
        match self.used_tokens.entry(token.to_string()) {
            Entry::Vacant(e) => {
                e.insert(expiry);
                Some((room_code, slot_id))
            }
            Entry::Occupied(_) => None,
        }
    }

    /// Evict consumed tokens whose expiry timestamp has passed.
    ///
    /// WR-06: call this from a background task every few minutes to prevent
    /// `used_tokens` from growing unboundedly on long-running servers.
    /// Safe to call concurrently — DashMap `retain` is shard-locked internally.
    pub fn sweep_expired(&self) {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        self.used_tokens.retain(|_, exp| *exp > now);
    }
}

/// Generate an HMAC-SHA256 pairing token encoding `{room_code}:{slot_id}:{expiry_unix}`.
///
/// Format: `base64url(payload).base64url(hmac_sha256(secret, payload))`
///
/// The caller is responsible for supplying `expiry_unix = now + ttl_secs`.
/// Follows the `turn_creds.rs` HMAC pattern exactly (PATTERNS.md §pairing_token).
pub fn generate_pairing_token(
    secret: &str,
    room_code: &str,
    slot_id: u8,
    expiry_unix: u64,
) -> anyhow::Result<String> {
    let payload = format!("{room_code}:{slot_id}:{expiry_unix}");

    let mut mac = HmacSha256::new_from_slice(secret.as_bytes())
        .map_err(|e| anyhow::anyhow!("HMAC key error: {e}"))?;
    mac.update(payload.as_bytes());
    let sig_bytes = mac.finalize().into_bytes();

    let enc_payload = URL_SAFE_NO_PAD.encode(payload.as_bytes());
    let enc_sig = URL_SAFE_NO_PAD.encode(sig_bytes);

    Ok(format!("{enc_payload}.{enc_sig}"))
}

/// Generate an opaque reconnect token: 32 cryptographically-random bytes,
/// base64url-encoded (no padding).
///
/// Each call produces a different value — used for per-slot reconnect identity
/// (D-17, T-03-05 mitigation). Server-side lookup only; not self-validating.
///
/// Uses `rand::random::<[u8; 32]>()` — free function, no trait import needed.
/// rand 0.10 moved `RngCore` out of the `rand` re-export; `rand::random()` is
/// the stable cross-version API for generating random arrays.
pub fn generate_reconnect_token() -> String {
    let bytes: [u8; 32] = rand::random();
    URL_SAFE_NO_PAD.encode(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Known-vector test: verifies the exact HMAC-SHA256 algorithm matches the
    /// pre-computed Python reference output.
    ///
    /// Pre-computed with:
    /// python3 -c "import hmac,hashlib,base64;
    ///   payload=b'ABCD23:2:9999999999';
    ///   sig=hmac.new(b'testsecret',payload,hashlib.sha256).digest();
    ///   enc_p=base64.urlsafe_b64encode(payload).rstrip(b'=').decode();
    ///   enc_s=base64.urlsafe_b64encode(sig).rstrip(b'=').decode();
    ///   print(f'{enc_p}.{enc_s}')"
    ///
    /// This is the only automated early warning for silent algorithm bugs
    /// (PATTERNS.md §pairing_token).
    #[test]
    fn test_known_vector() {
        let expected = "QUJDRDIzOjI6OTk5OTk5OTk5OQ.imJWyASM57L4QNGKY688w012a1G4z0dmTmJq2OZVVAc";
        let actual = generate_pairing_token("testsecret", "ABCD23", 2, 9_999_999_999)
            .expect("token generation must not fail");
        assert_eq!(actual, expected, "HMAC-SHA256 known-vector mismatch");
    }

    /// Round-trip: generate then validate a fresh (far-future expiry) token.
    #[test]
    fn test_token_round_trip() {
        let store = PairingTokenStore::new();
        let expiry = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs()
            + 300;
        let token =
            generate_pairing_token("mysecret", "ROOMXY", 3, expiry).expect("token gen failed");

        let result = store.validate_and_consume("mysecret", &token);
        assert!(result.is_some(), "valid token should be accepted");
        let (room_code, slot_id) = result.unwrap();
        assert_eq!(room_code, "ROOMXY");
        assert_eq!(slot_id, 3);
    }

    /// Single-use: same valid token accepted once, rejected on second call.
    #[test]
    fn test_token_single_use() {
        let store = PairingTokenStore::new();
        let expiry = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs()
            + 300;
        let token =
            generate_pairing_token("singlesecret", "SINGLEROOM", 1, expiry)
                .expect("token gen failed");

        let first = store.validate_and_consume("singlesecret", &token);
        assert!(first.is_some(), "first call must return Some");

        let second = store.validate_and_consume("singlesecret", &token);
        assert!(second.is_none(), "second call with same token must return None (single-use)");
    }

    /// Expired token (expiry in the past) must be rejected.
    #[test]
    fn test_token_expiry() {
        let store = PairingTokenStore::new();
        // Expiry 1 second in the past
        let past_expiry = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs()
            .saturating_sub(1);
        let token =
            generate_pairing_token("expsecret", "EXPROOM", 5, past_expiry)
                .expect("token gen failed");

        let result = store.validate_and_consume("expsecret", &token);
        assert!(result.is_none(), "expired token must be rejected");
    }

    /// generate_reconnect_token returns non-empty and produces different values per call.
    #[test]
    fn test_reconnect_token_opaque() {
        let t1 = generate_reconnect_token();
        let t2 = generate_reconnect_token();

        assert!(!t1.is_empty(), "reconnect token must be non-empty");
        assert!(!t2.is_empty(), "reconnect token must be non-empty");
        assert_ne!(t1, t2, "each generate_reconnect_token() call must produce a unique value");
    }
}
