//! Liveness bounds: one named function per term, each deriving its value from
//! the product constant its doc quotes.
//!
//! # Why no assertion may spell a number
//!
//! A soak run's whole claim is "this took longer than it may". If a test spelled
//! `94` the day the product's own constant moved, the test would keep passing
//! against a bound the product no longer has — it would be asserting the
//! harness's memory of a value rather than the value. So every bound is computed
//! here from the constant it derives from, and no assertion in this crate
//! spells a bound the PRODUCT owns; the harness's own bounds (a witness read, a
//! socket release, a poll interval) are named constants beside their use. The
//! table in the brief prints today's values for a reader, and that is the one
//! place they appear.
//!
//! # Upper bounds, and the one lower bound
//!
//! Every function here is an UPPER bound — "if it has not happened by now, it is
//! not going to" — except [`throttled_backoff_floor`], which is the only lower
//! one. It exists because the two `ClosedKind` arms cannot be told apart by
//! upper bounds alone: a dropped subscription is re-issued at once and a
//! throttled one waits, so the only observable difference is an ABSENCE before
//! the floor. An absence window is never scaled by `HAVEN_TEST_WAIT_SCALE` —
//! scaling it would widen the window in which the product is allowed to do
//! nothing, which is the opposite of what the scale knob is for.

use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Duration;

use haven_core::nostr::mls::types::UNRESOLVABLE_INPUT_MAX_AGE_SECS;
use haven_core::relay::live_sync::config::{
    delivery_silence_window_secs, BACKOFF_JITTER_FRACTION_BP, BACKOFF_MAX_SECS,
    BURST_BACKLOG_WAIT_SECS, COMMIT_SETTLE_WINDOW_SECS, SUBSCRIBE_CONNECT_WAIT_SECS,
    SUBSCRIBE_MAX_ATTEMPTS, SUBSCRIBE_RETRY_WAIT_SECS,
};

/// Basis-point denominator, as `BACKOFF_JITTER_FRACTION_BP`'s own doc uses it.
const BASIS_POINTS: u64 = 10_000;

/// Milliseconds per second: the jitter terms are fractional seconds, and a
/// bound rounded to whole seconds would be a different bound.
const MILLIS_PER_SEC: u64 = 1_000;

/// How long one whole subscribe ladder may take before every REQ is registered.
///
/// `SUBSCRIBE_CONNECT_WAIT_SECS + (SUBSCRIBE_MAX_ATTEMPTS − 1) ×
/// SUBSCRIBE_RETRY_WAIT_SECS` — the initial connect wait plus the retries that
/// follow it, each of which early-returns on connect, so the worst case adds
/// only `(N − 1)` of them (`haven-core/src/relay/live_sync/config.rs:169`,
/// `:193`, `:180`, whose own doc spells that sum out).
#[must_use]
pub fn subscribe_ladder() -> Duration {
    Duration::from_secs(
        SUBSCRIBE_CONNECT_WAIT_SECS
            + u64::from(SUBSCRIBE_MAX_ATTEMPTS.saturating_sub(1)) * SUBSCRIBE_RETRY_WAIT_SECS,
    )
}

/// How long the relay pool may take to get a dropped socket back.
///
/// `MAX_RETRY_INTERVAL + max(JITTER_RANGE) + DEFAULT_CONNECTION_TIMEOUT`
/// = `60 + 3 + 60` seconds, from `nostr-relay-pool-0.44.3/src/relay/constants.rs:23`,
/// `:24` and `:12`.
///
/// # Why this one is a literal and the grep step is its control
///
/// All three of those constants are `pub(super)`, so no expression in this crate
/// can name them: the value is written out here with the citation above it. A
/// test that re-computed `60 + 3 + 60` would be asserting this file against
/// itself, which is why the `soak-tooling` job's grep of the vendored
/// `constants.rs` — not a unit test — is what actually holds this honest. The
/// in-crate case exists only so `--self-test` enumerates every bound.
#[must_use]
pub const fn pool_reconnect() -> Duration {
    Duration::from_secs(123)
}

/// What ONE publish costs when the relay is reachable and its `OK` never
/// arrives.
///
/// `MAX_PUBLISH_ATTEMPTS × DEFAULT_TIMEOUT + (MAX_PUBLISH_ATTEMPTS − 1) ×
/// PUBLISH_RETRY_BACKOFF` = 3 × 10 s + 2 × 2 s = **34 s**
/// (`haven-core/src/relay/manager.rs:36`, `:110`, `:117`; the ladder's shape is
/// pinned by that crate's own
/// `publish_with_retry_pays_the_backoff_between_attempts_and_never_after_the_last`).
///
/// A literal with its citation for exactly [`pool_reconnect`]'s reason: all
/// three constants are private to their module, so no expression in this crate
/// can name them and a test that recomputed `3 × 10 + 2 × 2` would be asserting
/// this file against itself. The `soak-tooling` grep step against that source is
/// the control. The connection timeout is deliberately NOT in the sum — under a
/// swallowed acknowledgement the socket connects and it is only the `OK` that
/// never comes, which is what makes this 34 s rather than the 49 s an
/// unreachable relay costs.
#[must_use]
pub const fn withheld_publish_ladder() -> Duration {
    Duration::from_secs(34)
}

/// What ONE LOCATION publish costs when the relay is reachable and its `OK`
/// never arrives.
///
/// `LOCATION_PUBLISH_ATTEMPTS × LOCATION_ACK_WINDOW` = 1 × 5 s = **5 s**
/// (`haven-core/src/relay/manager.rs:193`, `:165`). A location is not a commit:
/// it takes ONE bounded attempt with no retry and no backoff, because the next
/// tick publishes a fresher position rather than re-sending this one — so an
/// arm that priced a withheld location acknowledgement at
/// [`withheld_publish_ladder`] would be waiting three attempts the product does
/// not make.
///
/// A literal with its citation for [`pool_reconnect`]'s reason: both constants
/// are private to their module, so no expression in this crate can name them
/// and a test that recomputed `1 × 5` would be asserting this file against
/// itself. Two things hold it honest instead — haven-core carries its own
/// `const _: () = assert!(LOCATION_PUBLISH_ATTEMPTS == 1, …)` beside the
/// constant, which is a COMPILE error the day the single attempt grows, and the
/// `soak-tooling` grep step against that source. As with
/// [`withheld_publish_ladder`], the connection timeout is deliberately not in
/// the sum: under a swallowed acknowledgement the socket connects and it is
/// only the `OK` that never comes.
#[must_use]
pub const fn location_publish_window() -> Duration {
    Duration::from_secs(5)
}

/// The longest a throttled REQ may wait before Haven re-issues it.
///
/// `BACKOFF_MAX_SECS × (10000 + BACKOFF_JITTER_FRACTION_BP) / 10000`
/// (`haven-core/src/relay/live_sync/config.rs:233`, `:246`): the schedule caps
/// the doubling at `BACKOFF_MAX_SECS` and then samples uniformly `±` the jitter
/// fraction around it (`repair.rs:229-237`), so the top of that sample is the
/// upper bound.
#[must_use]
pub fn throttled_backoff() -> Duration {
    Duration::from_millis(
        BACKOFF_MAX_SECS * MILLIS_PER_SEC * (BASIS_POINTS + u64::from(BACKOFF_JITTER_FRACTION_BP))
            / BASIS_POINTS,
    )
}

/// The soonest a throttled REQ may be re-issued — the one LOWER bound.
///
/// `BACKOFF_MAX_SECS × (10000 − BACKOFF_JITTER_FRACTION_BP) / 10000`
/// (`haven-core/src/relay/live_sync/config.rs:233`, `:246`). `jittered` samples
/// `base_ms − spread ..= base_ms + spread` with `spread = base × fraction`
/// (`repair.rs:229-237`), and the queue hands a key to `take_due` only once its
/// sampled delay has elapsed (`repair.rs:73-94`, `:148-177`), so no re-issue of
/// a Throttled key can happen before this. It is what makes the `Dropped` and
/// `Throttled` arms distinguishable at all: `Dropped` re-issues immediately,
/// `Throttled` cannot, and an absence before this instant is the only evidence
/// of the difference.
#[must_use]
pub fn throttled_backoff_floor() -> Duration {
    Duration::from_millis(
        BACKOFF_MAX_SECS * MILLIS_PER_SEC * (BASIS_POINTS - u64::from(BACKOFF_JITTER_FRACTION_BP))
            / BASIS_POINTS,
    )
}

/// How long the engine holds its sockets open after commit traffic stops.
///
/// `COMMIT_SETTLE_WINDOW_SECS` (`haven-core/src/relay/live_sync/config.rs:135`),
/// measured from the last commit-shaped observation — so a world that has just
/// committed is not quiescent until at least this has passed.
#[must_use]
pub const fn settle() -> Duration {
    Duration::from_secs(COMMIT_SETTLE_WINDOW_SECS)
}

/// How long one group REQ may deliver nothing before the health tick re-anchors
/// it.
///
/// `delivery_silence_window_secs()` = `DELIVERY_SILENCE_RETENTION_MULTIPLE ×
/// LOCATION_MESSAGE_RETENTION_SECS` (`haven-core/src/relay/live_sync/config.rs:287`),
/// i.e. three whole kind-445 retention windows. `unsigned_abs` rather than a
/// fallible cast because the product's own expression is a positive multiple of
/// a positive retention and a bound that silently collapsed to zero would assert
/// nothing.
#[must_use]
pub const fn silence_window() -> Duration {
    Duration::from_secs(delivery_silence_window_secs().unsigned_abs())
}

/// How old a stored convergence input must be before re-delivery can no longer
/// resolve it.
///
/// `UNRESOLVABLE_INPUT_MAX_AGE_SECS` = `LOCATION_MESSAGE_RETENTION_SECS +
/// RECEIVER_EXPIRATION_GRACE_SECS` (`haven-core/src/nostr/mls/types.rs:452`).
/// The predicate that consumes it is strictly greater
/// (`beyond_relay_retention`, `types.rs:464`), so a row at EXACTLY this age is
/// still resolvable and a sweep under the horizon must leave it gating.
#[must_use]
pub const fn unresolvable_input_max_age() -> Duration {
    Duration::from_secs(UNRESOLVABLE_INPUT_MAX_AGE_SECS)
}

/// How long a burst waits for the endpoints it opened to finish their replay.
///
/// `BURST_BACKLOG_WAIT_SECS` (`haven-core/src/relay/live_sync/config.rs:324`).
/// The cost side of the same number: one endpoint that stays silent costs this
/// much per `wait_backlog_settled` call, which is why that term runs at the
/// settle-then-check boundary and never inside a tick predicate.
#[must_use]
pub const fn burst_backlog_wait() -> Duration {
    Duration::from_secs(BURST_BACKLOG_WAIT_SECS)
}

/// The most disruptive thing a world is recovering from when a bound is derived.
///
/// A bound is only honest about a specific recovery: waiting a reconnect ladder
/// for a world that was never disconnected would hide a real stall for two
/// minutes, and waiting only the settle window for one that was would report a
/// violation the product does not have.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Recovery {
    /// Nothing was broken during the span: only the engine's own settle stands
    /// between the world and quiescence.
    Undisturbed,
    /// A relay went away and came back, so the pool's own reconnect ladder and
    /// the subscribe ladder behind it are in the path.
    Reconnect,
    /// A relay answered `CLOSED rate-limited:` or `auth-required:`, so Haven's
    /// jittered per-endpoint backoff is in the path.
    Throttled,
}

impl Recovery {
    /// What this recovery adds on top of the engine's own settle.
    #[must_use]
    pub fn term(self) -> Duration {
        match self {
            Self::Undisturbed => Duration::ZERO,
            Self::Reconnect => pool_reconnect() + subscribe_ladder(),
            Self::Throttled => throttled_backoff() + subscribe_ladder(),
        }
    }
}

/// How many times over a delivery budget may be paid.
///
/// The same knob haven-core's own relay-backed tests read
/// (`HAVEN_TEST_WAIT_SCALE`, `relay/manager.rs`'s `wait_budget`), for the same
/// reason and with the same rule: each scaled budget bounds how long a
/// TRANSITION may take, never the property under test, so a larger one can only
/// remove a false negative — a transition that never happens exhausts any
/// budget. An instrumented or loaded runner is slower at the transition and no
/// different at the property.
///
/// An **absence** window is never scaled, and the scale is applied at exactly
/// one place ([`round_trip`]) to keep that structural rather than remembered:
/// [`throttled_backoff_floor`] and [`silence_window`] are leaves, no composite
/// they belong to is scaled, and [`self_check`]'s own cases would fail the day
/// one of them stopped equalling its constant.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct WaitScale(u32);

impl WaitScale {
    /// The unscaled budget: what every local run and every lane but the
    /// instrumented ones use.
    pub const ONE: Self = Self(1);

    /// The scale `factor` names, or `None` below 1 — a scale that SHRANK a
    /// budget would turn a bound into something a slow machine could fail and
    /// a fast one could pass, which is the opposite of what this is for.
    #[must_use]
    pub const fn new(factor: u32) -> Option<Self> {
        if factor >= 1 {
            Some(Self(factor))
        } else {
            None
        }
    }

    /// The multiplier.
    #[must_use]
    pub const fn factor(self) -> u32 {
        self.0
    }
}

/// The process-wide scale, installed once before anything derives a bound.
static WAIT_SCALE: AtomicU32 = AtomicU32::new(1);

/// Installs the delivery-budget scale for this process.
///
/// Once, before the first world is built: a scale that moved mid-run would make
/// two arms of one run answer to different bounds, and the timeline would have
/// no way to say which.
pub fn install_wait_scale(scale: WaitScale) {
    WAIT_SCALE.store(scale.factor(), Ordering::Release);
}

/// The scale every delivery budget is paid at.
#[must_use]
pub fn wait_scale() -> WaitScale {
    WaitScale::new(WAIT_SCALE.load(Ordering::Acquire)).unwrap_or(WaitScale::ONE)
}

/// How long one probe may take to cross a circle and come back decrypted.
///
/// Composed, never invented: the recovery the world is coming out of, plus the
/// settle window the engine holds after commit traffic, plus the backlog wait a
/// re-opened endpoint spends on its stored replay. Nothing is added for the
/// relay itself — a `MockRelay` and a real one both broadcast on the socket the
/// publish returned on, and the publish is separately proven by a witnessed
/// `OK` before this bound starts.
///
/// This is the ONE place [`WaitScale`] is applied: every term above bounds a
/// transition, and every composite that pays for a delivery goes through here.
/// An absence window does not, and cannot be made to.
#[must_use]
pub fn round_trip(recovery: Recovery) -> Duration {
    (recovery.term() + settle() + burst_backlog_wait()) * wait_scale().factor()
}

/// How long a world may take to go quiet after its last fault was healed.
///
/// [`round_trip`] plus the stability window itself: the predicate must hold
/// across [`crate::oracle::quiescence::STABILITY_TICKS`] consecutive
/// observations, and a deadline that did not pay for those observations would
/// expire while the world was already settled.
#[must_use]
pub fn quiescence(recovery: Recovery, tick: Duration) -> Duration {
    round_trip(recovery) + tick * u32::from(crate::oracle::quiescence::STABILITY_TICKS)
}

/// Which bound failed to re-derive from its source constant.
///
/// Returned rather than panicked so `--self-test` can report it through the rc
/// contract like every other finding.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BoundDefect {
    /// The subscribe ladder no longer equals its connect-plus-retries sum.
    SubscribeLadder,
    /// The throttled backoff's floor is not below its ceiling, so the two
    /// `ClosedKind` arms would be indistinguishable.
    ThrottledBackoff,
    /// The settle window no longer equals the product's own constant.
    Settle,
    /// The delivery-silence window is no longer a whole multiple of the
    /// kind-445 retention.
    SilenceWindow,
    /// The unresolvable-input horizon no longer equals the product's constant.
    UnresolvableInputMaxAge,
    /// The burst backlog wait no longer equals the product's constant.
    BurstBacklogWait,
    /// A composite bound does not dominate the terms it is composed of.
    Composite,
    /// A location's single bounded attempt no longer costs strictly less than
    /// the commit ladder, so one of the two literals has drifted from the
    /// source it cites.
    LocationPublishWindow,
}

/// Re-derives every bound from its source constant — the `--self-test` case.
///
/// Three bounds have no re-derivation here — [`pool_reconnect`],
/// [`withheld_publish_ladder`] and [`location_publish_window`] — because their
/// source constants are private to their own modules (`pub(super)` in the
/// pinned pool crate, plain `const` in `haven-core`'s relay manager), so a case
/// would compare this file to itself. The `soak-tooling` grep step against
/// those sources is their control, as their docs say; what IS checked here is
/// the relation between the two publish ladders, which does not need either
/// constant to be nameable.
///
/// The cases below are also what keeps [`WaitScale`] honest: the scale is
/// applied at [`round_trip`] alone, so a scale that had leaked into a leaf
/// would show up here as a leaf that no longer equals its constant.
///
/// # Errors
///
/// [`BoundDefect`] naming the first bound that no longer matches its source.
pub fn self_check() -> Result<(), BoundDefect> {
    if subscribe_ladder()
        != Duration::from_secs(
            SUBSCRIBE_CONNECT_WAIT_SECS
                + u64::from(SUBSCRIBE_MAX_ATTEMPTS - 1) * SUBSCRIBE_RETRY_WAIT_SECS,
        )
    {
        return Err(BoundDefect::SubscribeLadder);
    }
    if throttled_backoff_floor() >= throttled_backoff()
        || throttled_backoff_floor() + throttled_backoff()
            != Duration::from_secs(2 * BACKOFF_MAX_SECS)
    {
        return Err(BoundDefect::ThrottledBackoff);
    }
    if settle() != Duration::from_secs(COMMIT_SETTLE_WINDOW_SECS) {
        return Err(BoundDefect::Settle);
    }
    if silence_window() != Duration::from_secs(delivery_silence_window_secs().unsigned_abs()) {
        return Err(BoundDefect::SilenceWindow);
    }
    if unresolvable_input_max_age() != Duration::from_secs(UNRESOLVABLE_INPUT_MAX_AGE_SECS) {
        return Err(BoundDefect::UnresolvableInputMaxAge);
    }
    if burst_backlog_wait() != Duration::from_secs(BURST_BACKLOG_WAIT_SECS) {
        return Err(BoundDefect::BurstBacklogWait);
    }
    // The one relation between the two private-constant ladders that this
    // crate CAN state: a location is one bounded attempt and a commit is three
    // with backoff between them, so the day these two meet, one of the literals
    // has drifted from the source it cites.
    if location_publish_window() == Duration::ZERO
        || location_publish_window() >= withheld_publish_ladder()
    {
        return Err(BoundDefect::LocationPublishWindow);
    }
    if round_trip(Recovery::Undisturbed) >= round_trip(Recovery::Reconnect)
        || round_trip(Recovery::Undisturbed) >= round_trip(Recovery::Throttled)
        || quiescence(Recovery::Undisturbed, Duration::from_millis(1))
            <= round_trip(Recovery::Undisturbed)
    {
        return Err(BoundDefect::Composite);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_bound_re_derives_from_the_constant_its_doc_quotes() {
        self_check().expect("a bound drifted from its source constant");
    }

    #[test]
    fn the_jitter_floor_is_the_only_bound_below_its_base() {
        // The two `ClosedKind` arms are told apart by this and nothing else: a
        // Throttled key may not be re-issued before the floor, while a Dropped
        // one is re-issued at once.
        let base = Duration::from_secs(BACKOFF_MAX_SECS);
        assert!(throttled_backoff_floor() < base);
        assert!(throttled_backoff() > base);
        // Symmetric around the base, which is what `jittered`'s
        // `base − spread ..= base + spread` sample means.
        assert!(
            base.checked_sub(throttled_backoff_floor()) == throttled_backoff().checked_sub(base),
            "the jitter is symmetric around its base, so the two arms are equidistant"
        );
    }

    #[test]
    fn a_location_costs_one_bounded_attempt_and_a_commit_costs_a_ladder() {
        // The product's own trade: a location is superseded by the next tick,
        // so it is never re-sent; a commit is neither superseded nor re-sendable
        // later, so it keeps its retries (Security Rule 13). An arm that priced
        // a withheld location at the commit ladder would wait three attempts
        // the product does not make.
        assert!(location_publish_window() < withheld_publish_ladder());
        assert!(location_publish_window() > Duration::ZERO);
    }

    #[test]
    fn a_recovery_never_shortens_the_bound_it_is_added_to() {
        assert_eq!(Recovery::Undisturbed.term(), Duration::ZERO);
        assert!(Recovery::Reconnect.term() > Recovery::Undisturbed.term());
        assert!(Recovery::Throttled.term() > Recovery::Undisturbed.term());
        // A pool reconnect is the slowest thing in the path, so a world that
        // lost a socket may not be graded on the throttle's shorter bound.
        assert!(Recovery::Reconnect.term() > Recovery::Throttled.term());
    }

    #[test]
    fn a_quiescence_deadline_pays_for_the_observations_it_requires() {
        let tick = Duration::from_millis(250);
        let paid =
            quiescence(Recovery::Undisturbed, tick).checked_sub(round_trip(Recovery::Undisturbed));
        assert!(
            paid == Some(tick * u32::from(crate::oracle::quiescence::STABILITY_TICKS)),
            "a deadline that did not pay for its own stability window would expire \
             while the world was already settled"
        );
    }

    #[test]
    fn a_bound_defect_renders_a_name_and_no_value() {
        let rendered = format!("{:?}", BoundDefect::SubscribeLadder);
        assert_eq!(rendered, "SubscribeLadder");
    }
}
