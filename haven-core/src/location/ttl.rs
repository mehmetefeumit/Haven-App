//! Timing constants and helpers for kind:445 outer-event metadata and
//! publish cadence.
//!
//! **Only ONE jitter is live.** `compute_jittered_publish_interval_secs`
//! samples the next publish delay in
//! `[nominal*(1-spread), nominal*(1+spread)]` seconds, breaking short-window
//! fingerprinting of the publish rhythm. It must stay unpredictable to relay
//! observers, so `OsRng` only — `thread_rng`/`SmallRng` are forbidden by
//! `clippy::disallowed_methods`.
//!
//! `compute_jittered_ttl_secs` is **retired** and has no production caller.
//! Since the Dark Matter cutover the NIP-40 `expiration` tag is stamped by the
//! engine from the group's `message-retention.v1` component (0x8005) as the
//! fixed `LOCATION_MESSAGE_RETENTION_SECS`. The helper is kept, with its unit
//! tests, as the reference implementation should a per-send TTL path return.
//! Do not read it as describing the wire.
//!
//! The consequence is recorded rather than hidden: a deterministic TTL IS the
//! constant-TTL fingerprint the retired sampling existed to prevent. See
//! `SECURITY.md`, "Outer kind:445 metadata".
//!
//! See `SECURITY.md` for the full threat model — in particular, the surviving
//! jitter does NOT address other remaining leaks (stable `h` tag per circle,
//! predictable ciphertext length).

use rand::rngs::OsRng;
use rand::Rng;

/// Minimum allowed publish-interval (1 minute).
///
/// This is a safety floor to prevent pathological hammering of relays.
/// The Dart call site samples the publish cadence from a jittered window
/// centred on `kLocationUpdateInterval` (see `haven/lib/src/constants/location.dart`),
/// and forwards `publish_max + 30 s` as the TTL floor — both of which
/// must stay at or above this value for `validate_update_interval_secs`
/// to be a no-op on legitimate input.
pub const MIN_UPDATE_INTERVAL_SECS: u64 = 60;

/// Maximum allowed publish-interval (60 minutes).
pub const MAX_UPDATE_INTERVAL_SECS: u64 = 60 * 60;

/// Clock-skew grace window applied at the receiver side (60 seconds).
///
/// Events whose NIP-40 expiration is more than this window in the past
/// are dropped before decryption, as defense-in-depth against relay replay.
/// Enforced in `SessionManager::process_event`, the choke point every
/// receive plane (poll drain, live-sync, background catch-up) funnels
/// through.
pub const RECEIVER_EXPIRATION_GRACE_SECS: u64 = 60;

/// Group-level `message-retention.v1` value (seconds) stamped into every
/// Haven circle at creation (Dark Matter app component `0x8005`).
///
/// The engine derives the outer kind-445 NIP-40 `expiration` tag as
/// `inner_created_at + retention` for APPLICATION messages only
/// (commits/proposals are never stamped — group history must outlive any
/// TTL).
///
/// Value = `168 s max publish interval + 2 * 30 s network buffer = 228 s`.
/// This is the **data-minimizing** point that still satisfies the no-gap
/// invariant, for a roster of at most `kMaxCirclesPerBurst` (11) circles —
/// which is every roster the app admits, since `kMaxCirclesPerAccount` (10)
/// refuses the eleventh: a
/// member re-publishes at most every `168 s` (`kLocationPublishMaxInterval`,
/// the ceiling of the ±40 % cadence jitter), and since the publish schedules
/// were coalesced (`PUB-COALESCE`) ONE burst per interval publishes every
/// eligible circle, so a circle that leads one burst and trails the next waits
/// at most one burst spread longer (`kPublishStaggerMaxSpread`, `30 s`). The
/// worst-case SCHEDULED gap is therefore `198 s`, and a `228 s` TTL leaves the
/// relay holding a non-expired event from every active publisher with `30 s`
/// left over for propagation and clock skew — one whole
/// `kTtlNetworkBufferSeconds`, half of the `2 * 30 s` this constant is built
/// from; the burst spread is what spends the other half. Shortened from the
/// earlier `396 s` (which was the *ceiling*
/// of the retired per-send jitter range, i.e. ~2× the necessary residency):
/// halving relay-side residency of location ciphertext is a direct
/// data-minimization win.
///
/// **`198 s` is the SCHEDULED gap; TWO REALIZED gaps exceed this constant, and
/// both are accepted residuals rather than breaches.** The Android foreground
/// service publishes on a platform delivery, which arrives a TTFF late. On API
/// 23–30 — no delayed register, so the regime pays TWO acquisitions per
/// registration — a `30 s` cold TTFF plus a long jittered interval pushes the
/// realized gap to at most `248 s`, i.e. `20 s` past this `228 s`, once. That
/// is `POWER_EFFICIENCY_PLAN.md` D3 (iii)'s ACCEPTED cold residual: it is swept
/// and pinned by equality per API regime in
/// `haven/test/services/background_fix_request_test.dart`, not tolerated
/// silently, and it means a relay-side grader reading a capture from an API
/// 23–30 handset treats a gap between `228 s` and `248 s` as that residual and
/// only a gap above `248 s` as a finding (`docs/POWER_MEASUREMENT.md` §3.5).
/// API 31+ stays at `198 s`. The SECOND crossing is the iOS burst head (connect,
/// backlog wait and one-shot fix, up to `40 s`), which VARIES between bursts and
/// so enters the realized gap as a differential on top of the burst spread:
/// `168 + 40 + spread` reaches `235 s` at four circles and `238 s` from five up,
/// so iOS background sharing is inside this `228 s` only up to THREE circles —
/// an ordinary roster, and unlike the Android one it is pinned by no test. The
/// serial pass's own span is the third realized term and does not cross on its
/// own. Both are stated on the Dart mirror named under KEEP IN SYNC below.
///
/// **The bound stops at eleven circles, and the ROSTER is bounded below that,
/// so the ladder below is unreachable rather than merely moved.** The owner
/// bounded the account roster at `kMaxCirclesPerAccount` (10) on 2026-09-09 —
/// refused at circle creation and at invitation accept, in
/// `haven/lib/src/services/nostr_circle_service.dart` — precisely so that
/// nothing can hand the burst a twelfth circle. The ladder is kept documented
/// because the deferral code is still there and lifting the bound re-opens it
/// exactly as written. A burst publishes at most `kMaxCirclesPerBurst` circles
/// and defers the rest to the next tick. The slice is strict round-robin, so a
/// circle's worst service period is `ceil(N / 11)` bursts rather than two at
/// every roster: `N = 12..22` → TWO sampled intervals (`144 s` best, `240 s`
/// mean, `336 s` worst, and `366 s` once the burst-position differential is
/// added — a circle may lead one burst and trail the one two ticks later, a
/// whole `kPublishStaggerMaxSpread` apart); `N = 23..33` → three (`216`/`360`/
/// `504 s`); `N >= 34` → four or more, where even the BEST case (`288 s`)
/// exceeds this `228 s` on every publish rather than on some.
///
/// Both halves of that ladder are pinned rather than left as prose: the
/// round-robin period itself by `a deferred circle waits ceil(N /
/// kMaxCirclesPerBurst) bursts` in
/// `haven/test/providers/location_publish_scheduler_provider_test.dart`,
/// which drives real ticks over both sides of every rung, and the seconds
/// those periods are quoted in by `and past the cap, the deferral ladder in
/// SECONDS` in `haven/test/services/publish_stagger_test.dart`, which reads
/// them off the cadence constants.
///
/// ONE limit on that quotient, not visible from the arithmetic: the cap bounds
/// what the scheduler HANDS OVER, not what a background pass publishes. While
/// the iOS sink is installed, a tick arriving inside a running burst folds into
/// it (`BackgroundBurstCoordinator._joinable`) rather than opening a socket of
/// its own, so one pass can carry two slices. That is reachable only at
/// `N >= 12`, already outside the roster this constant's bound covers, but it
/// is stated rather than left to be discovered.
///
/// The period itself is ABSOLUTE. `_rotation` outlives
/// `stopScheduling()`/`startScheduling()` and outlives an emission reporting
/// nothing eligible, so neither a backgrounding nor a failed roster read
/// re-phases whose turn it is — pinned by `a deferred circle is not deferred
/// again by every resume`, `a transient empty roster emission does not re-phase
/// whose turn it is` and `a roster change keeps survivors' places in the queue`
/// in `haven/test/providers/location_publish_scheduler_provider_test.dart`.
/// What still rewinds the queue is `build()` — a fresh container, or the
/// invalidate in `IdentityNotifier.deleteIdentity` — and a process restart,
/// which does not persist it; and because the roster keeps
/// `filterPublishEligibleCircles` order (`getVisibleCircles()` orders by
/// `updated_at DESC`) a rewind returns to the same head and re-serves the same
/// first slice, a deterministic re-service rather than a re-phase. The tail's
/// gap across that boundary is bounded by how often the app resumes rather than
/// unbounded, because the deliberately uncapped one-shot burst
/// (`locationPublisherProvider`) fires on cold start, on the motion trigger, on
/// accept/create and on a resume more than `30 s` after the last one
/// (`MapShell`'s resume debounce sits ABOVE its invalidate, so a glance inside
/// that window is not a trigger).
///
/// TWO baselines, because they answer differently. Against an UNCAPPED
/// coalesced burst the hole opened from the twenty-second circle
/// (`168 + 3 * 21 = 231 s`) and the cap moves it to the twelfth. Against the
/// ACTUAL predecessor — per-circle schedulers, where the gap was each circle's
/// own sampled interval, `<= 168 s` at every roster, with no spread and no
/// deferral — there was NO hole at any roster size and the full `60 s`
/// (`2 * kTtlNetworkBufferSeconds`) of margin was intact; so this is a
/// regression at every `N >= 12` with no upper bound, and at every `N >= 2` in
/// the margin (`60 s` -> `30 s`). Taken deliberately (owner, 2026-09-08, option
/// (a)) because the cap is what makes the burst span, the single shared GPS fix
/// and `kLocationPublishOverlapGuard` hold for EVERY roster. It is structural
/// past ~31 circles by pigeonhole — a DIFFERENT bound from the service period
/// above, because it is about one burst's spread rather than how many bursts a
/// circle waits. Closing both needed a roster bound or a longer retention; the
/// owner took the ROSTER BOUND on 2026-09-09, which puts both out of reach in
/// production without moving anything on the wire. The `N >= 12` regression is
/// therefore latent-behind-a-bound rather than live; the `N >= 2` margin
/// halving (`60 s` -> `30 s`) is NOT closed by it and stays as stated. See
/// `kMaxCirclesPerBurst` and `kMaxCirclesPerAccount`
/// (`haven/lib/src/services/publish_stagger.dart`), `SECURITY.md`'s no-gap
/// invariant, and `INV-W-445-EXPIRATION-WINDOW`'s residual.
///
/// A fixed protocol-level constant is deliberately chosen over per-circle
/// jitter: the outer event's stable `h` tag already identifies the circle,
/// so a per-circle TTL adds no unlinkability, and a constant delta leaks
/// less about publish cadence than the old jitter (whose TTL sample
/// correlated with the publish interval). The constant remains a
/// client-observable delta, but one shared with any Dark Matter client using
/// the same engine derivation rather than a per-send Haven quirk.
///
/// KEEP IN SYNC (no shared source of truth across the FFI): the Dart mirror
/// in `haven/lib/src/constants/location.dart` and the
/// `encryption_pipeline_test.dart` expectation both encode this value.
pub const LOCATION_MESSAGE_RETENTION_SECS: u64 = 228;

/// Publish-interval jitter spread in basis points (`10_000` = 100%).
///
/// At `4_000` bp (= 40%) around the 2-minute nominal, the sampled interval
/// is uniform in `[72 s, 168 s]`. The 40% figure is chosen to make
/// long-run statistical averaging meaningfully expensive: relative σ is
/// ~23% of the mean regardless of nominal, so an attacker needs a fixed
/// number of samples (~200) to recover the mean to within ±5% — ~6.6 h
/// of observation at the current 2-minute cadence.
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
// Dark Matter: superseded in the lib build — kind-445 TTL now rides the
// group-level `message-retention.v1` component (`LOCATION_MESSAGE_RETENTION_SECS`
// above), which the engine applies deterministically. Kept (with its unit
// tests) as the reference jitter helper should a per-send TTL path return.
#[allow(dead_code)]
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
        assert_eq!(validate_update_interval_secs(10), MIN_UPDATE_INTERVAL_SECS);
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
        let diff = mean.abs_diff(300);
        assert!(
            diff < 5,
            "empirical mean {mean} drifts too far from nominal 300"
        );
    }

    #[test]
    fn publish_jitter_clamps_nominal_below_min() {
        // Input below MIN is clamped up before sampling, so the result lives
        // in [MIN*(1-spread), MIN*(1+spread)] = [36, 84] for MIN=60.
        let v = compute_jittered_publish_interval_secs(10, PUBLISH_INTERVAL_JITTER_FRACTION_BP)
            .expect("non-zero interval");
        let min = MIN_UPDATE_INTERVAL_SECS * 60 / 100; // 0.6 * MIN
        let max = MIN_UPDATE_INTERVAL_SECS * 140 / 100; // 1.4 * MIN
        assert!((min..=max).contains(&v), "out of range: {v}");
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

    #[test]
    fn publish_interval_jitter_fraction_bp_is_pinned() {
        // Read through a `let` for the same reason as the other constant pins
        // in this crate — see `clock_skew_threshold_is_pinned` in
        // `relay/clock_skew.rs`.
        let bp = PUBLISH_INTERVAL_JITTER_FRACTION_BP;
        // The inclusion-style tests above only assert membership in the WIDE
        // range this constant produces, so they pass unchanged under both a
        // narrowing and a widening. NARROWING sharpens the publish-cadence
        // fingerprint a relay can extract (fewer distinct sampled intervals,
        // faster convergence to the mean than the "~200 samples" claim this
        // module documents); WIDENING silently invalidates the Dart mirror
        // `kLocationPublishMinInterval`/`kLocationPublishMaxInterval`
        // (72s/168s), which is checked against this value by
        // `scripts/ci/check_publish_jitter_fraction_parity.sh`.
        assert_eq!(bp, 4_000, "PUBLISH_INTERVAL_JITTER_FRACTION_BP moved");
    }
}
