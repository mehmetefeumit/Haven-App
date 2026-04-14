//! Jittered NIP-40 expiration helper.
//!
//! Computes a randomized TTL window for the outer kind:445 wrapper of
//! location updates. The goal is to bound relay-side residency to roughly
//! one to two publish cycles and to prevent a constant-TTL Haven fingerprint
//! on shared relays. See `SECURITY.md` for the full threat model — in
//! particular, this does NOT hide publish cadence (relays already observe
//! arrival times).

use rand::rngs::OsRng;
use rand::Rng;

/// Minimum allowed publish-interval (5 minutes).
pub const MIN_UPDATE_INTERVAL_SECS: u64 = 5 * 60;

/// Maximum allowed publish-interval (60 minutes).
pub const MAX_UPDATE_INTERVAL_SECS: u64 = 60 * 60;

/// Clock-skew grace window applied at the receiver side (60 seconds).
///
/// Events whose NIP-40 expiration is more than this window in the past
/// are dropped before decryption, as defense-in-depth against relay replay.
pub const RECEIVER_EXPIRATION_GRACE_SECS: u64 = 60;

/// Returns a uniformly random TTL in `[interval, 2 * interval]` seconds.
///
/// Uses `OsRng` (a thin wrapper over `getrandom` with no internal cache or
/// PRNG expansion); `gen_range` applies unbiased rejection sampling. The
/// resulting value MUST be unpredictable to relay observers, so do NOT
/// swap `OsRng` for `thread_rng()` or `SmallRng`. A repo-level clippy
/// `disallowed_methods` rule enforces this.
///
/// Returns `None` for `interval == 0` so callers omit the expiration tag
/// entirely instead of producing an already-expired event.
#[must_use]
pub fn compute_jittered_ttl_secs(update_interval_secs: u64) -> Option<u64> {
    if update_interval_secs == 0 {
        return None;
    }
    let mut rng = OsRng;
    Some(rng.gen_range(update_interval_secs..=2 * update_interval_secs))
}

/// Clamps the input to `[MIN_UPDATE_INTERVAL_SECS, MAX_UPDATE_INTERVAL_SECS]`.
///
/// Callers at the FFI boundary validate the input before reaching this
/// helper; this is a defensive second clamp for in-crate callers.
#[must_use]
pub fn validate_update_interval_secs(secs: u64) -> u64 {
    secs.clamp(MIN_UPDATE_INTERVAL_SECS, MAX_UPDATE_INTERVAL_SECS)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn jitter_within_bounds() {
        for _ in 0..1_000 {
            let v = compute_jittered_ttl_secs(300).expect("non-zero interval");
            assert!((300..=600).contains(&v), "out of range: {v}");
        }
    }

    #[test]
    fn jitter_distribution_not_degenerate() {
        let samples: HashSet<u64> = (0..1_000)
            .map(|_| compute_jittered_ttl_secs(300).expect("non-zero interval"))
            .collect();
        assert!(
            samples.len() > 100,
            "distribution looks degenerate: {} unique values across 1000 draws",
            samples.len()
        );
    }

    #[test]
    fn jitter_two_consecutive_calls_differ() {
        // Probabilistic: 1-in-301 chance of identical draws. Retry up to 10x
        // gives a failure probability below 10^-24.
        let mut last = None;
        for _ in 0..10 {
            let v = compute_jittered_ttl_secs(300).expect("non-zero interval");
            if let Some(prev) = last {
                if prev != v {
                    return;
                }
            }
            last = Some(v);
        }
        panic!("10 consecutive draws all equal — CSPRNG appears non-functional");
    }

    #[test]
    fn jitter_zero_interval_returns_none() {
        assert_eq!(compute_jittered_ttl_secs(0), None);
    }

    #[test]
    fn jitter_max_interval_no_overflow() {
        let v = compute_jittered_ttl_secs(MAX_UPDATE_INTERVAL_SECS).expect("non-zero interval");
        assert!((MAX_UPDATE_INTERVAL_SECS..=2 * MAX_UPDATE_INTERVAL_SECS).contains(&v));
    }

    #[test]
    fn validate_clamps_below_min() {
        assert_eq!(validate_update_interval_secs(60), MIN_UPDATE_INTERVAL_SECS);
    }

    #[test]
    fn validate_clamps_above_max() {
        assert_eq!(
            validate_update_interval_secs(99_999),
            MAX_UPDATE_INTERVAL_SECS
        );
    }

    #[test]
    fn validate_passes_through_valid() {
        assert_eq!(validate_update_interval_secs(900), 900);
    }

    #[test]
    fn validate_at_exact_bounds() {
        assert_eq!(
            validate_update_interval_secs(MIN_UPDATE_INTERVAL_SECS),
            MIN_UPDATE_INTERVAL_SECS
        );
        assert_eq!(
            validate_update_interval_secs(MAX_UPDATE_INTERVAL_SECS),
            MAX_UPDATE_INTERVAL_SECS
        );
    }
}
