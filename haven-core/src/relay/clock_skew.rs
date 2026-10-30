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
//!   location sharing is dead for the session. Inside the relay's window the
//!   publish is accepted instead, and the device goes deaf: past
//!   [`TOTAL_LOSS_SKEW_SECS`] its own relay pool discards every peer location
//!   as already expired, and neither signal below can see it (the relay took
//!   the event; the peer timestamps are in the events the pool dropped).
//! * **Clock behind** — `expiration = created_at + 228` is computed from the
//!   same skewed clock, so the event expires early, or is born expired. The
//!   relay still ACKs it (the publisher sees success!) but a NIP-40-honouring
//!   relay may drop it and a correctly-clocked peer's relay pool
//!   (`nostr-relay-pool`) discards it on receipt, before Haven sees it.
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

use crate::location::ttl::LOCATION_MESSAGE_RETENTION_SECS;

/// Haven-authored prefix of the `Display` form of
/// [`crate::relay::RelayError::DeviceClockRejected`].
///
/// The rendering names the classification and nothing a relay wrote. Nothing
/// parses it: the bridge carries the complaint as a typed field
/// (`PublishFailureFfi.clock_rejected`), and Dart reads that field.
pub const DEVICE_CLOCK_REJECTED_TOKEN: &str = "haven.clock.device_clock_rejected";

/// Clock disagreement past which every location sent across it is lost
/// (seconds).
///
/// `nostr-relay-pool` drops an event whose NIP-40 expiration is behind the
/// receiving device's own clock, on receipt and with no grace
/// (`nostr-relay-pool-0.44.3/src/relay/inner.rs:1193`), and the expiration is
/// `created_at + LOCATION_MESSAGE_RETENTION_SECS` by the sender's clock. At
/// this disagreement a location's residency is zero: a publisher lagging by it
/// loses **100 %** of its updates while still seeing a successful relay ACK,
/// and a receiver running this far ahead hears no peer at all. Below it the
/// residency is `LOCATION_MESSAGE_RETENTION_SECS − skew`, not the full window.
pub const TOTAL_LOSS_SKEW_SECS: u64 = LOCATION_MESSAGE_RETENTION_SECS;

/// Skew magnitude at or above which Haven tells the user their clock is wrong
/// (seconds).
///
/// # Why 120 and not something else
///
/// Nothing absorbs a disagreement — the pool judges every expiration with no
/// grace — so a lag of `d` leaves a location `228 − d` seconds of residency.
/// The number is placed against what that costs:
///
/// * **Lower bound — do not cry wolf.** Until the residency falls below the
///   median publish interval (the 120 s nominal of the uniform `[72, 168] s`
///   jitter), i.e. while the lag is under `228 − 120 = 108 s`, a member who is
///   not connected at the moment of a publish still finds the location on the
///   relay in most cycles; the holes are the jitter's tail.
/// * **Upper bound — do not hide real breakage.** At
///   [`TOTAL_LOSS_SKEW_SECS`] (228 s) delivery is already 100 % lost and
///   silent. The alarm must fire well before that, so the user still has a
///   chance to act; 120 s leaves 108 s of margin.
/// * **It is already a real defect at this value.** A publisher lagging by
///   120 s has a residency of `228 − 120 = 108 s`, under the 168 s worst-case
///   interval, so most cycles (the 62.5 % of intervals above 108 s) leave a
///   member who catches up later a coverage hole. 120 s is therefore the point
///   where the user is measurably harmed but not yet dark — exactly where a
///   warning belongs.
///
/// Moving this in *either* direction is a behaviour change: widening hides
/// breakage, narrowing cries wolf. `clock_skew_threshold_is_pinned` fails on
/// both. Mirrored in Dart as `kClockSkewAlertThreshold`
/// (`haven/lib/src/constants/location.dart`) and pinned across the two by
/// `scripts/ci/check_clock_skew_policy_parity.sh`.
pub const CLOCK_SKEW_ALERT_THRESHOLD_SECS: u64 = 120;

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
/// Which prefixes are read at all is [`classify_clock_refusal`]'s rule:
/// khatru sends its verdict under `blocked:` (`event too much in the future`,
/// `event too old`).
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
        .filter_map(|(_, reason)| classify_clock_refusal(reason))
        .reduce(DeviceClockComplaint::merge)
}

/// What one relay's `OK false` says about this device's clock.
///
/// The one rule every publish path keeps: only a refusal with NIP-01's
/// `invalid:` or `blocked:` prefix, or with none, is read
/// ([`classify_relay_rejection`]) — `blocked:` because khatru's timestamp
/// policies answer under it. Under any other prefix (`pow:`,
/// `rate-limited:`, …) a mention of a timestamp is not a clock complaint.
#[must_use]
pub fn classify_clock_refusal(reason: &str) -> Option<DeviceClockComplaint> {
    use nostr::message::MachineReadablePrefix as Prefix;
    matches!(
        Prefix::parse(reason),
        None | Some(Prefix::Invalid | Prefix::Blocked)
    )
    .then(|| classify_relay_rejection(reason))
    .flatten()
}

/// `complaint`, about an event this device signed `age_secs` ago by its own
/// clock, kept only where it can be about that clock.
///
/// A relay judges an event's age against its own clock, and Haven sends
/// events that are old in fact: a recorded commit or proposal is sent again
/// byte for byte hours after it was signed. Khatru's past window is set by
/// its operator (`policies.PreventTimestampsInThePast`; its own
/// getting-started example sets two hours), so a refusal of an older event as
/// too old, or out of range, says how old the event is, not how slow this
/// device's clock is. Only an event signed within the alert threshold
/// ([`CLOCK_SKEW_ALERT_THRESHOLD_SECS`]) is kept: a clock behind by the
/// threshold makes even a fresh event look that old. A relay whose operator
/// set its past window under the threshold, 120 s, can still refuse such an
/// event as too old and raise a false `Behind`. A verdict that the event is
/// from the future is about this clock whatever the event's age.
#[must_use]
pub fn on_this_clock(
    complaint: DeviceClockComplaint,
    age_secs: u64,
) -> Option<DeviceClockComplaint> {
    (complaint == DeviceClockComplaint::Ahead || age_secs <= CLOCK_SKEW_ALERT_THRESHOLD_SECS)
        .then_some(complaint)
}

/// Whether retrying this publish is provably pointless.
///
/// True when every relay that answered rejected the event on timestamp
/// grounds ([`classify_clock_refusal`]). The retry re-offers the *same signed event* with the *same*
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
            .all(|(_, reason)| classify_clock_refusal(reason).is_some())
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::{EventBuilder, Keys, Kind, Tag, Timestamp};

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
        const MEDIAN_PUBLISH_INTERVAL_SECS: u64 = 120; // kLocationUpdateInterval
        let threshold = CLOCK_SKEW_ALERT_THRESHOLD_SECS;
        let retention = LOCATION_MESSAGE_RETENTION_SECS;
        let total_loss = TOTAL_LOSS_SKEW_SECS;

        assert_eq!(
            threshold, 120,
            "the alert threshold moved. It is not a free parameter: see the \
             derivation on CLOCK_SKEW_ALERT_THRESHOLD_SECS and change the two \
             bounds below with it, or not at all."
        );

        // Lower bound: past the lag at which the residency left to a lagging
        // publisher drops under the median publish interval, so a lag whose
        // holes are only the jitter's tail never raises an alarm.
        assert!(
            threshold > retention - MEDIAN_PUBLISH_INTERVAL_SECS,
            "an alert while the residency still covers most publish intervals \
             fires on skew that costs the user only the jitter's tail"
        );

        // Upper bound: must fire strictly BEFORE delivery goes to zero.
        // WIDENING the threshold fails here.
        assert!(
            threshold < total_loss,
            "an alert at or above the total-loss point only ever arrives after \
             every location has already been silently dropped"
        );
    }

    #[test]
    fn total_loss_point_is_the_relay_pools_drop_point() {
        // `Event::is_expired_at` is the predicate `nostr-relay-pool` applies to
        // every received event (`relay/inner.rs:1193`, through `is_expired`),
        // and the expiration is stamped as the engine stamps a location. Fixed
        // instants make the boundary exact; the real pool is exercised by
        // `tests/relay_pool_expiry_drop_point.rs`.
        let receiver_now = Timestamp::from(1_800_000_000);
        let sent_lagging_by = |lag: u64| {
            let created_at = Timestamp::from(receiver_now.as_secs() - lag);
            EventBuilder::new(Kind::Custom(445), "")
                .tag(Tag::expiration(
                    created_at + LOCATION_MESSAGE_RETENTION_SECS,
                ))
                .custom_created_at(created_at)
                .sign_with_keys(&Keys::generate())
                .expect("a locally built event signs")
        };

        assert!(
            !sent_lagging_by(TOTAL_LOSS_SKEW_SECS).is_expired_at(&receiver_now),
            "at the total-loss point the residency is zero, not negative: \
             the point is past where the pool starts dropping"
        );
        assert!(
            sent_lagging_by(TOTAL_LOSS_SKEW_SECS + 1).is_expired_at(&receiver_now),
            "one second past the total-loss point the pool must already drop \
             the location: the point is short of where the pool starts dropping"
        );
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

    /// A timestamp mentioned under another prefix is no clock complaint;
    /// under `invalid:`, `blocked:` or none it is.
    #[test]
    fn only_an_invalid_blocked_or_unprefixed_refusal_is_read_for_the_clock() {
        assert_eq!(
            classify_publish_outcome(
                false,
                &[
                    rejection("rate-limited: too many events in the future"),
                    rejection("pow: difficulty too low for an event in the past"),
                ]
            ),
            None
        );
        assert_eq!(
            classify_publish_outcome(false, &[rejection("created_at is in the future")]),
            Some(DeviceClockComplaint::Ahead)
        );
        // khatru's `PreventTimestampsInTheFuture` / `...InThePast`, as its
        // `handleNormal` sends them: `NormalizeOKMessage(msg, "blocked")`.
        assert_eq!(
            classify_publish_outcome(false, &[rejection("blocked: event too much in the future")]),
            Some(DeviceClockComplaint::Ahead)
        );
        assert_eq!(
            classify_publish_outcome(false, &[rejection("blocked: event too old")]),
            Some(DeviceClockComplaint::Behind)
        );
        assert_eq!(
            classify_publish_outcome(false, &[rejection("blocked: pubkey not on the allowlist")]),
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

    /// The retry rule reads refusals as the verdict does: a timestamp named
    /// under a prefix the verdict ignores leaves the retry in place, and
    /// khatru's `blocked:` one ends it.
    #[test]
    fn retry_is_hopeless_exactly_when_the_verdict_reads_every_refusal() {
        assert!(!publish_retry_is_hopeless(
            false,
            &[rejection("rate-limited: too many events in the future")]
        ));
        assert!(publish_retry_is_hopeless(
            false,
            &[rejection("blocked: event too much in the future")]
        ));
    }

    /// A complaint about an event older than the alert threshold says how old
    /// the event is, unless it says the event is from the future; within the
    /// threshold every direction stands.
    #[test]
    fn an_old_events_refusal_is_no_evidence_of_a_slow_clock() {
        let old = CLOCK_SKEW_ALERT_THRESHOLD_SECS + 1;
        assert_eq!(on_this_clock(DeviceClockComplaint::Behind, old), None);
        assert_eq!(on_this_clock(DeviceClockComplaint::Unspecified, old), None);
        assert_eq!(
            on_this_clock(DeviceClockComplaint::Ahead, old),
            Some(DeviceClockComplaint::Ahead)
        );
        for complaint in [
            DeviceClockComplaint::Ahead,
            DeviceClockComplaint::Behind,
            DeviceClockComplaint::Unspecified,
        ] {
            assert_eq!(
                on_this_clock(complaint, CLOCK_SKEW_ALERT_THRESHOLD_SECS),
                Some(complaint)
            );
        }
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
