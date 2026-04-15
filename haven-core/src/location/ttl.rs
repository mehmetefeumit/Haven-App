//! Jittered timing helpers for kind:445 outer-event metadata and publish
//! cadence.
//!
//! This module hosts two independent CSPRNG-backed jitters that share a
//! common rationale (unpredictable to relay observers, so `OsRng` only —
//! `thread_rng`/`SmallRng` are forbidden by `clippy::disallowed_methods`)
//! but address different leaks and MUST remain sampled independently:
//!
//! - `compute_jittered_ttl_secs` — samples the NIP-40 `expiration` tag on
//!   the outer kind:445 wrapper. Bounds relay-side residency to roughly
//!   one to two publish cycles and prevents a constant-TTL Haven
//!   fingerprint.
//! - `compute_jittered_publish_interval_secs` — samples the next publish
//!   delay in `[nominal*(1-spread), nominal*(1+spread)]` seconds. Breaks
//!   short-window fingerprinting of the publish rhythm.
//!
//! See `SECURITY.md` for the full threat model — in particular, these
//! jitters do NOT address other remaining leaks (stable `h` tag per
//! circle, predictable ciphertext length).

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

/// Publish-interval jitter spread in basis points (`10_000` = 100%).
///
/// At `4_000` bp (= 40%) around the 5-minute nominal, the sampled interval
/// is uniform in `[3 min, 7 min]`. The 40% figure is chosen to make
/// long-run statistical averaging meaningfully expensive: σ ≈ 69 s over
/// `[180, 420]` s, so an attacker needs ~200 samples (~16 h of
/// observation) to recover the mean to within ±5 s.
pub const PUBLISH_INTERVAL_JITTER_FRACTION_BP: u16 = 4_000;

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

/// Returns a uniformly random publish interval in
/// `[nominal * (1 - spread), nominal * (1 + spread)]` seconds.
///
/// `spread_bp` is in basis points (`10_000` = 100%) and is clamped to
/// `[0, 10_000]`. `nominal_secs` is clamped to
/// `[MIN_UPDATE_INTERVAL_SECS, MAX_UPDATE_INTERVAL_SECS]` before sampling.
///
/// Uses `OsRng` / `gen_range` for the same reasons documented on
/// `compute_jittered_ttl_secs` — the value MUST be unpredictable to relay
/// observers, so swapping `OsRng` for `thread_rng()` or `SmallRng` would
/// violate the security invariant (also enforced by `clippy::disallowed_methods`).
///
/// Returns `None` on `nominal_secs == 0` for parity with the sibling
/// helper, so callers can distinguish "no schedule" from "schedule now".
#[must_use]
pub fn compute_jittered_publish_interval_secs(nominal_secs: u64, spread_bp: u16) -> Option<u64> {
    if nominal_secs == 0 {
        return None;
    }
    let nominal = validate_update_interval_secs(nominal_secs);
    // Clamp spread BEFORE computing delta, so `nominal - delta` cannot underflow.
    let bp = u64::from(spread_bp.min(10_000));
    // u128 intermediate avoids any overflow risk; `nominal` is bounded above by
    // MAX_UPDATE_INTERVAL_SECS (3600) and `bp` by 10_000, so the product fits
    // trivially in u64 at the call site — but we compute in u128 defensively
    // and cast back once the division has reduced the magnitude.
    #[allow(clippy::cast_possible_truncation)] // delta <= nominal <= u64::MAX by construction
    let delta = ((u128::from(nominal) * u128::from(bp)) / 10_000) as u64;
    let mut rng = OsRng;
    Some(rng.gen_range((nominal - delta)..=(nominal + delta)))
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

    // ---- Publish-interval jitter ----

    #[test]
    fn publish_jitter_within_bounds() {
        for _ in 0..1_000 {
            let v =
                compute_jittered_publish_interval_secs(300, PUBLISH_INTERVAL_JITTER_FRACTION_BP)
                    .expect("non-zero interval");
            assert!((180..=420).contains(&v), "out of range: {v}");
        }
    }

    #[test]
    fn publish_jitter_distribution_not_degenerate() {
        let samples: HashSet<u64> = (0..1_000)
            .map(|_| {
                compute_jittered_publish_interval_secs(300, PUBLISH_INTERVAL_JITTER_FRACTION_BP)
                    .expect("non-zero interval")
            })
            .collect();
        assert!(
            samples.len() > 100,
            "distribution looks degenerate: {} unique values across 1000 draws",
            samples.len()
        );
    }

    #[test]
    fn publish_jitter_zero_interval_returns_none() {
        assert_eq!(
            compute_jittered_publish_interval_secs(0, PUBLISH_INTERVAL_JITTER_FRACTION_BP),
            None
        );
    }

    #[test]
    fn publish_jitter_spread_zero_returns_nominal() {
        for _ in 0..100 {
            let v = compute_jittered_publish_interval_secs(300, 0).expect("non-zero interval");
            assert_eq!(v, 300);
        }
    }

    #[test]
    fn publish_jitter_spread_clamped_above_10000() {
        // spread_bp > 10_000 should behave identically to 10_000 (full spread:
        // [nominal*0, nominal*2]), with no panic or underflow.
        for _ in 0..100 {
            let v = compute_jittered_publish_interval_secs(300, 20_000).expect("non-zero interval");
            assert!((0..=600).contains(&v), "out of range: {v}");
        }
    }

    #[test]
    fn publish_jitter_empirical_mean_close_to_nominal() {
        // 10_000 samples of uniform[180, 420] has σ_mean ≈ 69.3 / √10_000 ≈ 0.69s.
        // Asserting |mean - 300| < 5 is ~7σ — Chernoff bound gives failure
        // probability below 10^-11, so CI-stable.
        let sum: u64 = (0..10_000)
            .map(|_| {
                compute_jittered_publish_interval_secs(300, PUBLISH_INTERVAL_JITTER_FRACTION_BP)
                    .expect("non-zero interval")
            })
            .sum();
        let mean = sum / 10_000;
        let diff = if mean > 300 { mean - 300 } else { 300 - mean };
        assert!(
            diff < 5,
            "empirical mean {mean} drifts too far from nominal 300"
        );
    }

    #[test]
    fn publish_jitter_clamps_nominal_below_min() {
        // Input below MIN is clamped up before sampling, so the result lives
        // in [MIN*(1-spread), MIN*(1+spread)] = [180, 420].
        let v = compute_jittered_publish_interval_secs(60, PUBLISH_INTERVAL_JITTER_FRACTION_BP)
            .expect("non-zero interval");
        assert!((180..=420).contains(&v));
    }

    #[test]
    fn publish_jitter_clamps_nominal_above_max() {
        // Input above MAX is clamped down before sampling, so the result lives
        // in [MAX*(1-spread), MAX*(1+spread)].
        let v = compute_jittered_publish_interval_secs(99_999, PUBLISH_INTERVAL_JITTER_FRACTION_BP)
            .expect("non-zero interval");
        let min = MAX_UPDATE_INTERVAL_SECS * 60 / 100; // 0.6 * MAX
        let max = MAX_UPDATE_INTERVAL_SECS * 140 / 100; // 1.4 * MAX
        assert!((min..=max).contains(&v), "out of range: {v}");
    }
}
