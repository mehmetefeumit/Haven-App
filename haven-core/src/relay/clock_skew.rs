//! Device-clock skew detection from signals Haven already receives.
//!
//! # Why this module exists
//!
//! Every wall-clock dependency on the send path bottoms out in one unguarded
//! `SystemTime::now()`: the MDK peeler stamps the inner application event with
//! `now_unix_seconds()` and binds the outer kind-445 `created_at` to it, and
//! the engine derives the NIP-40 `expiration` as
//! `inner_created_at + LOCATION_MESSAGE_RETENTION_SECS`. A device whose clock
//! is wrong therefore signs events that are wrong in *both* fields, and until
//! this module existed nothing in the tree compared that clock against any
//! external reference. The two resulting failures were both silent:
//!
//! * **Clock ahead** — every event carries a future `created_at`, and a
//!   spec-conformant relay bounds that (strfry's `rejectEventsNewerThanSeconds`,
//!   and every mainstream relay has an equivalent). The publish is refused, so
//!   location sharing is dead for the session.
//! * **Clock behind** — `expiration = created_at + 228` is computed from the
//!   same skewed clock, so the event is born already expired. The relay still
//!   ACKs it (the publisher sees success!) but a NIP-40-honouring relay may
//!   drop it and a correctly-clocked peer discards it in
//!   [`crate::nostr::mls::SessionManager::process_event`] before decryption.
//!
//! # The time reference, and what it deliberately is NOT
//!
//! Haven **never** contacts a third party for time. No NTP, no `time.google.com`,
//! no HTTP `Date` probe against an unrelated host: any of those would add an
//! unencrypted, correlatable network fingerprint to a privacy-first app
//! (Security Rule 10). The reference is derived exclusively from connections
//! Haven already makes:
//!
//! 1. **The relay's `OK false` reason** (this module). NIP-01 requires a
//!    machine-readable reason on rejection, and a relay that refuses an event
//!    on timestamp grounds is a correctly-clocked observer telling us so
//!    directly. This covers the *ahead* direction, which is the direction a
//!    relay can observe.
//! 2. **MLS-authenticated peer timestamps** (Dart side —
//!    `haven/lib/src/services/clock_skew_detector.dart`). Every decrypted
//!    location carries the sender's own `timestamp` inside the MLS ciphertext.
//!    Corroborated across independent senders, a consistently *future* peer
//!    timestamp is evidence that this device is behind. That covers the
//!    *behind* direction, which no relay ever reports because a backdated
//!    event is accepted.
//!
//! Nothing here rewrites `created_at`. Publishing a timestamp that disagrees
//! with the device clock has protocol consequences (the TTL, the `since`
//! cursor, and the peeler's inner/outer binding all ride the same value) and
//! would need its own security analysis. Surfacing the problem is in scope;
//! forging around it is not.
//!
//! # No relay text ever reaches the caller
//!
//! [`classify_relay_rejection`] consumes relay-controlled prose and returns
//! only a [`DeviceClockComplaint`] — a closed enum. The relay's own words are
//! never propagated upward, never stored, and never rendered (Security Rule 8).

use crate::location::ttl::{LOCATION_MESSAGE_RETENTION_SECS, RECEIVER_EXPIRATION_GRACE_SECS};

/// Stable, Haven-authored prefix used as the `Display` form of
/// [`crate::relay::RelayError::DeviceClockRejected`].
///
/// The FFI boundary flattens every error to a `String`
/// (`Result<T, String>` — CLAUDE.md, FFI error convention), so this token is
/// the one channel through which a *classification* — never relay prose —
/// crosses into Dart. It is matched verbatim by
/// `haven/lib/src/services/clock_skew_detector.dart`; the pair is pinned by
/// `scripts/ci/check_clock_skew_policy_parity.sh`.
pub const DEVICE_CLOCK_REJECTED_TOKEN: &str = "haven.clock.device_clock_rejected";

/// Skew magnitude at which every location this device publishes is discarded
/// by a correctly-clocked peer (seconds).
///
/// A receiver drops an event whose NIP-40 expiration is more than
/// [`RECEIVER_EXPIRATION_GRACE_SECS`] into its past, and the expiration is
/// `created_at + LOCATION_MESSAGE_RETENTION_SECS`. A publisher whose clock lags
/// by this much therefore loses **100 %** of its updates while still seeing a
/// successful relay ACK.
pub const TOTAL_LOSS_SKEW_SECS: u64 =
    LOCATION_MESSAGE_RETENTION_SECS + RECEIVER_EXPIRATION_GRACE_SECS;

/// Skew magnitude at or above which Haven tells the user their clock is wrong
/// (seconds).
///
/// # Why 120 and not something else
///
/// The number is derived from the two constants that bound what actually
/// breaks, not chosen for feel:
///
/// * **Lower bound — do not cry wolf.** [`RECEIVER_EXPIRATION_GRACE_SECS`] is
///   60 s: the band of disagreement the protocol *already absorbs by design*.
///   Alerting anywhere inside it would fire on skew that costs the user
///   nothing. `2 × 60 = 120` puts the alarm strictly outside every tolerated
///   band, with a full grace window of headroom for measurement noise.
/// * **Upper bound — do not hide real breakage.** At
///   [`TOTAL_LOSS_SKEW_SECS`] (288 s) delivery is already 100 % lost and
///   silent. The alarm must fire well before that, so the user still has a
///   chance to act; 120 s leaves 168 s of margin.
/// * **It is already a real defect at this value.** The no-gap invariant is
///   `retention (228 s) > max publish gap (168 s)`, a design margin of 60 s.
///   A publisher lagging by 120 s has an effective residency of
///   `228 − 120 = 108 s`, well under the 168 s worst-case inter-publish gap,
///   so peers are *guaranteed* to see coverage holes. 120 s is therefore the
///   point where the user is measurably harmed but not yet dark — exactly
///   where a warning belongs.
///
/// Moving this in *either* direction is a behaviour change: widening hides
/// breakage, narrowing cries wolf. `clock_skew_threshold_is_pinned` fails on
/// both. Mirrored in Dart as `kClockSkewAlertThreshold`
/// (`haven/lib/src/constants/location.dart`) and pinned across the two by
/// `scripts/ci/check_clock_skew_policy_parity.sh`.
pub const CLOCK_SKEW_ALERT_THRESHOLD_SECS: u64 = 2 * RECEIVER_EXPIRATION_GRACE_SECS;

/// What a relay's rejection says about this device's clock.
///
/// Deliberately closed and prose-free: the relay's own reason text is consumed
/// by [`classify_relay_rejection`] and discarded there.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DeviceClockComplaint {
    /// The relay judged the event to be in *its* future — this device's clock
    /// runs fast.
    Ahead,
    /// The relay judged the event to be too far in *its* past, or already
    /// expired on arrival — this device's clock runs slow.
    Behind,
    /// The relay named the timestamp but not a direction (strfry's
    /// "event too far off from the current time" is the canonical example).
    Unspecified,
}

impl DeviceClockComplaint {
    /// The wire suffix carried after [`DEVICE_CLOCK_REJECTED_TOKEN`].
    #[must_use]
    pub const fn wire_token(self) -> &'static str {
        match self {
            Self::Ahead => "ahead",
            Self::Behind => "behind",
            Self::Unspecified => "unspecified",
        }
    }

    /// Parses a suffix produced by [`Self::wire_token`].
    #[must_use]
    pub fn from_wire_token(token: &str) -> Option<Self> {
        match token {
            "ahead" => Some(Self::Ahead),
            "behind" => Some(Self::Behind),
            "unspecified" => Some(Self::Unspecified),
            _ => None,
        }
    }

    /// Combines two complaints from different relays about the same event.
    ///
    /// A specific direction beats [`Self::Unspecified`]; two relays that
    /// disagree about the direction collapse to [`Self::Unspecified`] rather
    /// than letting whichever answered first decide.
    #[must_use]
    pub fn merge(self, other: Self) -> Self {
        match (self, other) {
            (Self::Unspecified, rhs) => rhs,
            (lhs, Self::Unspecified) => lhs,
            (lhs, rhs) if lhs == rhs => lhs,
            _ => Self::Unspecified,
        }
    }
}

/// Substrings that name a *future* timestamp complaint.
const AHEAD_PHRASES: &[&str] = &[
    "in the future",
    "into the future",
    "too new",
    "newer than",
    "future timestamp",
    "future created_at",
];

/// Substrings that name a *past* / already-expired timestamp complaint.
///
/// The expiry phrases are spelled out with the word `event` attached so a
/// transport-layer message about some other expiry (an auth challenge, a
/// session) cannot be mistaken for a NIP-40 verdict on our own event.
const BEHIND_PHRASES: &[&str] = &[
    "too old",
    "older than",
    "in the past",
    "into the past",
    "outdated",
    "event expired",
    "event is expired",
    "expired event",
];

/// Substrings that name the timestamp without naming a direction.
///
/// Deliberately excludes the bare word `time`: "connection timed out" and
/// "operation timed out" are transport failures, not clock verdicts, and
/// `rejected_by` carries transport errors alongside genuine `OK false`
/// reasons (`nostr-relay-pool` folds both into `Output::failed`).
const UNSPECIFIED_PHRASES: &[&str] = &[
    "too far off",
    "created_at",
    "creation date",
    "creation time",
    "timestamp",
    "time stamp",
    "clock",
    "current time",
    "time skew",
    "invalid time",
];

/// Classifies one relay rejection reason as a device-clock complaint.
///
/// Returns `None` for every rejection that is not about the event timestamp
/// (rate limits, auth, proof-of-work, size caps, blocked kinds, transport
/// errors), so a
/// caller can tell "this device's clock is the problem" from "the publish
/// failed" — the distinction between a user who can fix their phone and a user
/// told only that sharing is broken.
///
/// The match is substring-based on a lowercased copy because relay reason text
/// is not standardised beyond NIP-01's machine-readable *prefix*
/// (`invalid:`, `blocked:`, …), which says nothing about timestamps. The
/// phrase tables cover the wording used by strfry, `nostr-rs-relay`,
/// `nostream`, `khatru` and `relayer`; an unrecognised phrasing degrades to
/// `None`, i.e. to today's behaviour, never to a false clock accusation.
#[must_use]
pub fn classify_relay_rejection(reason: &str) -> Option<DeviceClockComplaint> {
    let lowered = reason.to_ascii_lowercase();
    let contains_any = |phrases: &[&str]| phrases.iter().any(|p| lowered.contains(p));

    if contains_any(AHEAD_PHRASES) {
        return Some(DeviceClockComplaint::Ahead);
    }
    if contains_any(BEHIND_PHRASES) {
        return Some(DeviceClockComplaint::Behind);
    }
    if contains_any(UNSPECIFIED_PHRASES) {
        return Some(DeviceClockComplaint::Unspecified);
    }
    None
}

/// The device-clock verdict for one completed publish attempt.
///
/// `rejections` is the `(relay_url, reason)` list from
/// [`crate::relay::PublishResult`]; `any_accepted` says whether at least one
/// relay acknowledged it.
///
/// Returns `Some` only when **no relay accepted the event** and at least one
/// that answered blamed the timestamp. A partially-successful publish is not a
/// clock alarm: the location did reach the network, so telling the user their
/// clock is broken would be crying wolf.
///
/// A single relay is allowed to trigger the verdict. Requiring corroboration
/// here would leave every one- or two-relay account undiagnosable, and the
/// blast radius of a lying relay is bounded: the verdict only ever produces a
/// user-visible warning. It never changes what Haven signs, publishes, or
/// stores.
#[must_use]
pub fn classify_publish_outcome(
    any_accepted: bool,
    rejections: &[(String, String)],
) -> Option<DeviceClockComplaint> {
    if any_accepted {
        return None;
    }
    rejections
        .iter()
        .filter_map(|(_, reason)| classify_relay_rejection(reason))
        .reduce(DeviceClockComplaint::merge)
}

/// Whether retrying this publish is provably pointless.
///
/// True when every relay that answered rejected the event on timestamp
/// grounds. The retry re-offers the *same signed event* with the *same*
/// `created_at`, so a relay that already judged that timestamp out of range
/// will judge it out of range again — the retries buy nothing and cost radio
/// time on a device that is, by hypothesis, already failing to share location.
///
/// A mixed outcome (one relay blames the clock, another rate-limits) is **not**
/// hopeless: the second relay may well accept on the next attempt, so the
/// normal retry policy stands.
#[must_use]
pub fn publish_retry_is_hopeless(any_accepted: bool, rejections: &[(String, String)]) -> bool {
    !any_accepted
        && !rejections.is_empty()
        && rejections
            .iter()
            .all(|(_, reason)| classify_relay_rejection(reason).is_some())
}

#[cfg(test)]
mod tests {
    use super::*;

    // ---------------------------------------------------------------------
    // The threshold. Pinned against BOTH bounds it is derived from, so a
    // future edit in either direction fails: widening hides real breakage,
    // narrowing cries wolf.
    // ---------------------------------------------------------------------

    #[test]
    fn clock_skew_threshold_is_pinned() {
        // Read through `let` bindings on purpose: comparing the constants
        // directly makes the assertions compile-time-constant, which clippy
        // rejects (`assertions_on_constants`) and which would also turn a
        // mutation into a build error instead of a readable test failure.
        let threshold = CLOCK_SKEW_ALERT_THRESHOLD_SECS;
        let grace = RECEIVER_EXPIRATION_GRACE_SECS;
        let retention = LOCATION_MESSAGE_RETENTION_SECS;
        let total_loss = TOTAL_LOSS_SKEW_SECS;

        assert_eq!(
            threshold, 120,
            "the alert threshold moved. It is not a free parameter: see the \
             derivation on CLOCK_SKEW_ALERT_THRESHOLD_SECS and change the two \
             bounds below with it, or not at all."
        );

        // Lower bound: strictly outside the band the protocol absorbs by
        // design, so ordinary tolerated disagreement can never raise an alarm.
        // NARROWING the threshold fails here.
        assert!(
            threshold > grace,
            "an alert inside the receiver grace window fires on skew that \
             costs the user nothing"
        );
        assert_eq!(
            threshold,
            2 * grace,
            "the threshold is defined as two grace windows; if the grace \
             window moves the threshold must move with it"
        );

        // Upper bound: must fire strictly BEFORE delivery goes to zero, and
        // before the no-gap invariant is beyond rescue. WIDENING the threshold
        // fails here.
        assert!(
            threshold < total_loss,
            "an alert at or above the total-loss point only ever arrives after \
             every location has already been silently dropped"
        );
        assert!(
            threshold < retention,
            "at a threshold above the retention the residency left to a lagging \
             publisher is already negative"
        );
    }

    #[test]
    fn total_loss_point_is_the_receiver_gate() {
        // Not a restatement of the constant: this is the arithmetic the
        // receiver actually performs in SessionManager::process_event.
        assert_eq!(TOTAL_LOSS_SKEW_SECS, 228 + 60);
    }

    #[test]
    fn threshold_still_leaves_a_coverage_gap_when_reached() {
        // The justification claims that at the threshold the no-gap invariant
        // is already broken. Assert it rather than asserting the prose.
        const MAX_PUBLISH_GAP_SECS: u64 = 168; // kLocationPublishMaxInterval
        let residency_at_threshold =
            LOCATION_MESSAGE_RETENTION_SECS - CLOCK_SKEW_ALERT_THRESHOLD_SECS;
        assert!(
            residency_at_threshold < MAX_PUBLISH_GAP_SECS,
            "a threshold this low would fire before the user is actually harmed"
        );
    }

    // ---------------------------------------------------------------------
    // Rejection classification
    // ---------------------------------------------------------------------

    #[test]
    fn classifies_strfry_future_rejection() {
        // strfry's `rejectEventsNewerThanSeconds` message names the timestamp
        // but not the direction.
        assert_eq!(
            classify_relay_rejection("invalid: event too far off from the current time"),
            Some(DeviceClockComplaint::Unspecified)
        );
    }

    #[test]
    fn classifies_explicit_future_rejections() {
        for reason in [
            "invalid: event created_at is too far in the future",
            "invalid: event is too new",
            "invalid: created_at newer than 900 seconds from now",
            "invalid: future timestamp not allowed",
            "invalid: the event was created in the future",
        ] {
            assert_eq!(
                classify_relay_rejection(reason),
                Some(DeviceClockComplaint::Ahead),
                "should read as a fast-clock complaint: {reason}"
            );
        }
    }

    #[test]
    fn classifies_explicit_past_rejections() {
        for reason in [
            "invalid: event too old",
            "invalid: created_at older than 3600 seconds",
            "invalid: event is too far in the past",
            "invalid: event expired",
            "invalid: this is an expired event",
            "invalid: outdated event",
        ] {
            assert_eq!(
                classify_relay_rejection(reason),
                Some(DeviceClockComplaint::Behind),
                "should read as a slow-clock complaint: {reason}"
            );
        }
    }

    #[test]
    fn classification_is_case_insensitive() {
        assert_eq!(
            classify_relay_rejection("INVALID: EVENT TOO FAR OFF FROM THE CURRENT TIME"),
            Some(DeviceClockComplaint::Unspecified)
        );
    }

    #[test]
    fn ordinary_rejections_are_not_clock_complaints() {
        // Every one of these is a real relay/transport message. A false
        // positive here is worse than no detection at all: it tells the user
        // to fix a clock that is fine while the real cause goes unmentioned.
        for reason in [
            "blocked: pubkey not on the allowlist",
            "rate-limited: slow down",
            "invalid: bad signature",
            "invalid: event id does not match",
            "pow: difficulty 20 is less than 25",
            "duplicate: already have this event",
            "restricted: we do not accept events from unauthenticated users",
            "error: event too large",
            "connection timed out",
            "operation timed out after 30s",
            "not connected (status: disconnected)",
            "websocket error: connection reset by peer",
            "",
        ] {
            assert_eq!(
                classify_relay_rejection(reason),
                None,
                "must NOT be read as a clock complaint: {reason:?}"
            );
        }
    }

    // ---------------------------------------------------------------------
    // Publish-outcome verdict
    // ---------------------------------------------------------------------

    fn rejection(reason: &str) -> (String, String) {
        ("wss://relay.example.com".to_string(), reason.to_string())
    }

    #[test]
    fn publish_outcome_reports_clock_when_nothing_was_accepted() {
        assert_eq!(
            classify_publish_outcome(
                false,
                &[rejection(
                    "invalid: event too far off from the current time"
                )]
            ),
            Some(DeviceClockComplaint::Unspecified)
        );
    }

    #[test]
    fn publish_outcome_is_silent_when_a_relay_accepted() {
        // The location DID reach the network; a clock warning here would be
        // crying wolf.
        assert_eq!(
            classify_publish_outcome(
                true,
                &[rejection(
                    "invalid: event too far off from the current time"
                )]
            ),
            None
        );
    }

    #[test]
    fn publish_outcome_is_silent_for_non_clock_rejections() {
        assert_eq!(
            classify_publish_outcome(false, &[rejection("rate-limited: slow down")]),
            None
        );
    }

    #[test]
    fn publish_outcome_merges_a_specific_direction_over_unspecified() {
        assert_eq!(
            classify_publish_outcome(
                false,
                &[
                    rejection("invalid: event too far off from the current time"),
                    rejection("invalid: created_at is in the future"),
                ]
            ),
            Some(DeviceClockComplaint::Ahead)
        );
    }

    #[test]
    fn publish_outcome_collapses_contradicting_directions() {
        assert_eq!(
            classify_publish_outcome(
                false,
                &[
                    rejection("invalid: created_at is in the future"),
                    rejection("invalid: event too old"),
                ]
            ),
            Some(DeviceClockComplaint::Unspecified)
        );
    }

    // ---------------------------------------------------------------------
    // Retry policy
    // ---------------------------------------------------------------------

    #[test]
    fn retry_is_hopeless_when_every_answer_blamed_the_clock() {
        assert!(publish_retry_is_hopeless(
            false,
            &[
                rejection("invalid: event too far off from the current time"),
                rejection("invalid: created_at is in the future"),
            ]
        ));
    }

    #[test]
    fn retry_is_not_hopeless_when_one_relay_might_still_accept() {
        assert!(!publish_retry_is_hopeless(
            false,
            &[
                rejection("invalid: event too far off from the current time"),
                rejection("rate-limited: slow down"),
            ]
        ));
    }

    #[test]
    fn retry_is_not_hopeless_without_any_answer() {
        // No relay answered at all — a cold-connection race, which the retry
        // loop exists to recover from.
        assert!(!publish_retry_is_hopeless(false, &[]));
    }

    #[test]
    fn retry_is_not_hopeless_after_an_acceptance() {
        assert!(!publish_retry_is_hopeless(
            true,
            &[rejection(
                "invalid: event too far off from the current time"
            )]
        ));
    }

    // ---------------------------------------------------------------------
    // Wire token
    // ---------------------------------------------------------------------

    #[test]
    fn wire_tokens_round_trip() {
        for complaint in [
            DeviceClockComplaint::Ahead,
            DeviceClockComplaint::Behind,
            DeviceClockComplaint::Unspecified,
        ] {
            assert_eq!(
                DeviceClockComplaint::from_wire_token(complaint.wire_token()),
                Some(complaint)
            );
        }
        assert_eq!(DeviceClockComplaint::from_wire_token("sideways"), None);
    }

    #[test]
    fn merge_prefers_a_direction_and_collapses_conflict() {
        use DeviceClockComplaint::{Ahead, Behind, Unspecified};
        assert_eq!(Unspecified.merge(Ahead), Ahead);
        assert_eq!(Ahead.merge(Unspecified), Ahead);
        assert_eq!(Ahead.merge(Ahead), Ahead);
        assert_eq!(Ahead.merge(Behind), Unspecified);
        assert_eq!(Behind.merge(Ahead), Unspecified);
    }
}
