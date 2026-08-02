//! Compile-time configuration for the public-profile module.
//!
//! Every tunable lives here in one place: the kind-0 `REQ` shape, the
//! scheduling budget that spreads those `REQ`s out over time, and the Blossom
//! picture limits.
//!
//! # This module no longer selects relays
//!
//! It used to expose read / write / merge-base relay helpers. All three
//! resolved to the AUTH-free discovery plane, which is a strict SUPERSET of the
//! account-seed relays — i.e. exactly the relays already carrying this account's
//! kind-445 and kind-1059 traffic. Routing kind-0 there let one operator join
//! "who this IP shares location with" against "who this IP looks up", which is
//! the cross-plane link the profile redesign exists to break.
//!
//! Relay selection now lives in two dedicated modules and nowhere else:
//! [`crate::profile::relay_pool`] resolves the curated pool minus the
//! contamination ledger (fail-closed on underflow), and
//! [`crate::profile::assignment`] pins each author to one pool relay by salted
//! rendezvous hash. The constants below only govern how the resulting
//! single-author `REQ`s are paced.

use std::ops::RangeInclusive;
use std::time::Duration;

/// Re-export of the canonical avatar MIME type (`image/jpeg`). Profile pictures
/// use the same re-encode format as the avatar pipeline.
pub use crate::avatar::AVATAR_MIME;

// Profile staleness tolerance is NOT configured here. `fetch_member_profiles`
// takes a per-call `max_age_secs`, so each refresh trigger states its own tier
// (interactive / periodic anti-entropy / forced). Those tiers live in Dart
// (`haven/lib/src/constants/profile_refresh_tiers.dart`) next to the timer that
// drives them — the same "Dart owns cadence, Rust owns logic" split the
// maintenance scheduler already uses.
//
// For the record, because a previous constant here claimed otherwise: this is
// NOT White Noise parity. White Noise has no TTL for real users at all — it
// keeps a standing kind-0 subscription over every locally known pubkey and
// re-pulls only when metadata is entirely unknown. Haven is deliberately
// pull-only (no standing kind-0 subscription — see
// `docs/PUBLIC_PROFILE_MIGRATION_PLAN.md` §1.6/D3), so freshness here comes
// from tiered polling instead.

/// Bounded timeout for a one-shot profile (kind-0) relay fetch.
///
/// Used by the PUBLISH path (own-profile merge base / read-back), which talks
/// to the user's own write relays rather than to an assigned pool relay. The
/// per-author fetch path uses the tighter
/// [`PROFILE_AUTHOR_FETCH_TIMEOUT`] instead, because it issues many more
/// requests and must fit them inside [`PROFILE_BATCH_DEADLINE`].
pub const PROFILE_FETCH_TIMEOUT: Duration = Duration::from_secs(10);

/// Kind-0 revisions requested for ONE author in ONE `REQ`.
///
/// A well-behaved relay prunes replaceable events and returns exactly one, but
/// a non-pruning relay can hold every historical revision. Four is a defensive
/// bound: enough that `parse_newest_metadata` still sees a genuine newest event
/// if the relay happens to return them oldest-first, small enough that a
/// misbehaving relay cannot flood the client. This is a PER-AUTHOR limit
/// because there is exactly one author per filter — the batched
/// `authors × 4` product of the old broadcast model is gone.
pub const PROFILE_PER_AUTHOR_LIMIT: usize = 4;

/// Bounded timeout for ONE author's kind-0 `REQ` against ONE assigned relay.
///
/// Deliberately much tighter than [`PROFILE_FETCH_TIMEOUT`]: requests to a
/// single relay run SERIALLY (that serialization is what removes the burst
/// signature a relay could otherwise use to fingerprint a roster refresh), so
/// this value multiplies by the number of authors assigned to that relay. Four
/// seconds is comfortably above a healthy relay's round-trip while keeping an
/// unresponsive one from consuming the whole cycle budget.
pub const PROFILE_AUTHOR_FETCH_TIMEOUT: Duration = Duration::from_secs(4);

/// Wall-clock budget for one complete assigned-fetch cycle.
///
/// Whatever has not been attempted when this elapses is reported as
/// *unattempted* — NOT as a miss — so a slow cycle never advances an author's
/// retry ladder onto a second relay (which would widen that author's
/// disclosure for a reason that has nothing to do with the author). Sized to
/// leave room for several serial [`PROFILE_AUTHOR_FETCH_TIMEOUT`] round-trips
/// plus inter-request jitter, while still returning within a foreground
/// refresh's patience.
pub const PROFILE_BATCH_DEADLINE: Duration = Duration::from_secs(20);

/// Maximum distinct relays queried CONCURRENTLY within one cycle.
///
/// Cycles fan out across relays (each holds a disjoint ~`1/N` slice of the
/// author set) and stay serial within a relay. This bounds open sockets and
/// concurrent DNS/TLS work; raising it does not widen disclosure (each relay
/// still sees only its own slice), but it does make the whole cycle more
/// conspicuous as a simultaneous burst to a network observer.
pub const PROFILE_MAX_INFLIGHT_RELAYS: usize = 4;

/// Inclusive millisecond range for the delay between two consecutive `REQ`s
/// sent to the SAME relay.
///
/// Sampled per gap from the OS CSPRNG. Without it, a relay could recognise a
/// refresh cycle by its fixed inter-arrival period and count the roster it
/// holds by timing alone; with it, gaps carry no exploitable regularity. The
/// floor keeps a full slice from finishing inside the batch deadline's noise
/// floor; the ceiling keeps a 10-author slice under ~5 s of pure jitter.
pub const PROFILE_INTER_REQ_JITTER_MS: RangeInclusive<u64> = 120..=480;

/// Bounded timeout for a Blossom upload/download HTTP round-trip.
pub const BLOSSOM_TIMEOUT: Duration = Duration::from_secs(30);

/// Lifetime, in seconds, of a Blossom kind-24242 authorization event's
/// `expiration` tag (stamped `now + this`). Short-lived by design.
pub const BLOSSOM_AUTH_EXPIRY_SECS: u64 = 60;

/// Default Blossom server for profile-picture hosting (White Noise parity).
/// MUST be `https://` — enforced by the CI privacy guard.
pub const DEFAULT_BLOSSOM_SERVER: &str = "https://blossom.primal.net";

/// Process-static install-once override for the Blossom upload server, **debug
/// builds only**. Lets the hermetic e2e harness point profile-picture UPLOADS
/// at a local Blossom (`http://10.0.2.2:3000` on the Android emulator,
/// `http://localhost:3000` on the iOS simulator/host) instead of the production
/// default, without ever affecting a release binary. Mirrors the install-once
/// `relay::set_default_relays_for_test` override discipline.
#[cfg(debug_assertions)]
static BLOSSOM_SERVER_FOR_TEST: std::sync::OnceLock<String> = std::sync::OnceLock::new();

/// The Blossom server URL profile-picture uploads target.
///
/// Returns [`DEFAULT_BLOSSOM_SERVER`] in production. In debug builds an e2e
/// override installed via [`set_blossom_server_for_test`] wins; release builds
/// can never install one (the setter is a fail-closed stub), so this always
/// returns the hard-coded HTTPS default there. The returned URL is still passed
/// through `blossom::require_https`, which permits plaintext `http://` only for
/// the loopback/emulator allowlist in debug builds.
#[must_use]
pub fn blossom_server() -> String {
    #[cfg(debug_assertions)]
    if let Some(url) = BLOSSOM_SERVER_FOR_TEST.get() {
        return url.clone();
    }
    DEFAULT_BLOSSOM_SERVER.to_string()
}

/// Overrides the Blossom upload server for hermetic e2e tests (**debug only**).
///
/// Intended to be called once from a scenario's `setUpAll` (alongside
/// `set_discovery_relays_for_test` and `allow_private_blossom_for_test`) so
/// `upload_my_profile_picture` targets the local Blossom container/binary.
///
/// # Errors
///
/// * Returns an error if `url` is empty.
/// * Returns an error if the override has already been installed in this
///   process (`OnceLock` install-once semantics).
/// * In release builds this is unreachable; the sibling stub always errors.
#[cfg(debug_assertions)]
pub fn set_blossom_server_for_test(url: String) -> std::result::Result<(), String> {
    if url.is_empty() {
        return Err("blossom server override must not be empty".to_string());
    }
    BLOSSOM_SERVER_FOR_TEST
        .set(url)
        .map_err(|_existing| "set_blossom_server_for_test already installed".to_string())
}

/// Release stub for [`set_blossom_server_for_test`] — always errors so release
/// callers fail closed and the production default is never overridable.
///
/// # Errors
///
/// Always returns an error.
#[cfg(not(debug_assertions))]
pub fn set_blossom_server_for_test(_url: String) -> std::result::Result<(), String> {
    Err("set_blossom_server_for_test is disabled in release builds".to_string())
}

/// Hard byte cap for a profile-picture DOWNLOAD (`512 KiB`).
///
/// Matches the untrusted-inbound avatar input cap
/// ([`crate::avatar::config::INBOUND_MAX_INPUT_BYTES`]). Enforced twice on the
/// download path: a `Content-Length` precheck (reject a header claiming more)
/// AND a streamed byte counter (reject a body that overruns even when the
/// header lies or is absent). A picture at the 512 px / ~90 KB canonical tier
/// is far under this.
pub const PROFILE_PICTURE_MAX_DOWNLOAD_BYTES: u64 = 512 * 1024;

// The read / write / merge-base relay helpers that used to live here were
// deleted with the broadcast fetch model. They all bottomed out in the
// AUTH-free discovery plane, which is a strict superset of the account-seed
// relays; see the module doc above. Fetch-plane relays now come from
// `relay_pool::resolve_profile_pool` + `assignment::assigned_relay_for_attempt`,
// and the publish plane resolves its own write relays in `publish.rs`.

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_blossom_server_is_https() {
        assert!(DEFAULT_BLOSSOM_SERVER.starts_with("https://"));
    }

    #[test]
    fn avatar_mime_is_jpeg() {
        assert_eq!(AVATAR_MIME, "image/jpeg");
    }

    #[test]
    fn per_author_limit_is_bounded_and_non_zero() {
        // Zero would mean "no limit" to a relay; an unbounded reply lets a
        // misbehaving relay flood the client with historical revisions.
        assert!(PROFILE_PER_AUTHOR_LIMIT > 0);
        assert!(PROFILE_PER_AUTHOR_LIMIT <= 16);
    }

    #[test]
    fn a_single_author_req_fits_inside_the_batch_deadline() {
        // If one REQ could outlive the whole cycle budget, the very first
        // author on a slow relay would consume the batch and every remaining
        // author would be reported unattempted forever.
        assert!(PROFILE_AUTHOR_FETCH_TIMEOUT < PROFILE_BATCH_DEADLINE);
    }

    #[test]
    fn inter_req_jitter_is_a_non_degenerate_range() {
        // A collapsed range (start == end) is a FIXED delay, which is exactly
        // the regular inter-arrival pattern the jitter exists to destroy.
        assert!(
            PROFILE_INTER_REQ_JITTER_MS.start() < PROFILE_INTER_REQ_JITTER_MS.end(),
            "jitter must sample from a real range, not a constant delay",
        );
        assert!(
            *PROFILE_INTER_REQ_JITTER_MS.start() > 0,
            "a zero floor lets a whole slice arrive as one burst",
        );
    }

    #[test]
    fn inflight_relay_bound_is_positive() {
        // Zero would deadlock the fan-out (no relay ever scheduled).
        assert!(PROFILE_MAX_INFLIGHT_RELAYS > 0);
    }
}
