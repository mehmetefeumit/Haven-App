//! Subscription-health maintenance (M8-4) for the live-sync engine.
//!
//! A scheduled tick that heals a receive plane that has stopped delivering: it
//! snapshots the engine's relay connectivity, its live subscription set and its
//! per-REQ delivery liveness, and re-anchors every subscription at its persisted
//! cursor via [`super::session::LiveSyncCore::resume_after_background`] (which
//! reconnects the pool and re-issues the same subscription ids — no miss window)
//! whenever any of the three says the plane is not being served.
//!
//! # Why connectivity alone is not health
//!
//! A relay can keep the WebSocket open — `Connected` to every connectivity check
//! — while the REQ that carries this device's circles no longer exists on it.
//! nostr-relay-pool deletes a subscription on most `CLOSED` reasons and its
//! `should_resubscribe` then answers `false` for the missing entry, so not even
//! a later socket reconnect brings it back (see [`super::repair`]). That is a
//! permanent, silent receive blackout behind a green connection light, and it is
//! the failure this module exists to catch. Two arms measure it directly:
//!
//! * **subscriptions present** — the pool reports fewer live `(relay, sub)`
//!   pairs than the active session expects. Unambiguous: a REQ we issued is gone.
//! * **delivery silence** — a GROUP REQ has delivered neither an event nor an
//!   `EOSE` for [`delivery_silence_window_secs`] (derived from the publish
//!   cadence). Ambiguous by nature, because a receiver cannot know whether any
//!   peer is publishing, so it never declares failure — and it gets a DIFFERENT,
//!   narrower remedy: [`health_needs_targeted_reanchor`] re-issues only the
//!   endpoints that went quiet, never the whole session.
//!
//! The inbox plane is deliberately exempt from the silence arm. A silent inbox
//! is the NORMAL state — invitations are rare — and its REQ carries a seven-day
//! gift-wrap lookback, so treating that silence as a reason to act would have
//! this device ask its relays to replay a week of wraps keyed on its own `#p` on
//! every tick, forever: battery, relay load, and a standing re-advertisement of
//! the one query that links this npub to itself. The inbox failure that does
//! matter — a relay ending the REQ — is caught by the presence arm and repaired
//! in seconds by [`super::repair`].
//!
//! [`delivery_silence_window_secs`]: super::config::delivery_silence_window_secs
//!
//! # Three connectivity buckets
//!
//! nostr-relay-pool's [`RelayStatus`](nostr_sdk::RelayStatus) has eight
//! variants; the snapshot folds them into three presence-only buckets so a
//! caller can tell "all good" from "some still connecting" from "some dropped →
//! resubscribe":
//!
//! | `RelayStatus`                             | bucket            | resubscribe? |
//! |-------------------------------------------|-------------------|--------------|
//! | `Connected`                               | connected         | no           |
//! | `Initialized` / `Pending` / `Connecting`  | still-connecting  | no (transient) |
//! | `Disconnected` / `Terminated` / `Banned`  | dropped           | **yes**      |
//! | `Sleeping`                                | (neither)         | no (idle)    |
//!
//! Only a **dropped** relay warrants a re-anchor. Relays that are merely
//! mid-setup (`Initialized` / `Pending` / `Connecting`) are counted in a
//! separate `still_connecting` bucket: re-anchoring them would thrash a
//! connection that is coming up, yet they are *not* healthy-subscribed either,
//! so they must not let the snapshot read as a premature all-healthy that
//! suppresses a legitimately-needed future re-anchor.
//!
//! # Engine-coupled, ships inert
//!
//! This task only does work while a live session is running. The FFI self-gates
//! on the `SESSION` global (no session ⇒ [`HealthAction::EngineOff`] no-op), so
//! it ships **inert** until `liveSyncEnabled` flips (M11) and the engine is
//! actually started.
//!
//! # Privacy
//!
//! The snapshot and outcome are presence-only — counts + an action enum, never
//! a relay URL, group id, or pubkey (Security Rule 4/6).

/// What one subscription-health tick did.
///
/// Fieldless — no url, id, or hex — so it is leak-free by construction.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HealthAction {
    /// No live engine session (the `SESSION` global is empty, or the session
    /// was stopped) — the inert no-op that ships while `liveSyncEnabled` is off.
    EngineOff,
    /// The engine is running and no relay has dropped — nothing to do. Note this
    /// covers both "every relay connected" and "some relays are still coming up
    /// but none dropped": a mid-connect relay is not a reason to re-anchor.
    Healthy,
    /// A relay had dropped, or a REQ the session expects was missing from the
    /// pool, so the WHOLE session was re-anchored via `resume_after_background`
    /// — the pool reconnected and every subscription re-issued at its persisted
    /// cursor. Sockets are involved, so nothing narrower would do.
    Resubscribed,
    /// Delivery silence alone: every socket was up and every REQ registered, so
    /// only the `(relay, sub)` endpoints that had gone quiet were re-issued.
    /// Nothing was reconnected and no other REQ was touched.
    ///
    /// Distinct from [`Self::Resubscribed`] because the two differ by orders of
    /// magnitude in cost, and because this one is EXPECTED on a device whose
    /// circles are simply idle — reporting it as a full re-anchor would make a
    /// normal quiet device look like it was repeatedly losing its relays.
    TargetedReanchor,
}

/// Presence-only snapshot of the engine pool's relay connectivity AND of
/// whether its subscriptions are present and delivering.
///
/// The three connectivity buckets are disjoint and, together with `Sleeping`
/// relays (which fall into none of them), partition `total`; their sum never
/// exceeds `total`, with equality when no relay is `Sleeping`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct RelayHealthSnapshot {
    /// Relays the engine's pool currently holds.
    pub total: usize,
    /// Relays that are fully connected (`RelayStatus::Connected`).
    pub connected: usize,
    /// Relays still coming up (`Initialized` / `Pending` / `Connecting`) — a
    /// transient state that is neither healthy-subscribed nor a drop, so it is
    /// tracked separately and never triggers a resubscribe.
    pub still_connecting: usize,
    /// Relays in a dropped state (`Disconnected` / `Terminated` / `Banned`).
    pub disconnected: usize,
    /// `(relay, subscription)` REQ pairs the ACTIVE SESSION expects to be live.
    /// `0` when no session has started.
    pub subscriptions_expected: usize,
    /// How many of those the relay pool still holds. Registration is local and
    /// survives a disconnect (the pool replays it on reconnect), so a shortfall
    /// is a REQ that was DELETED — a relay `CLOSED` the pool will never re-issue
    /// — not a relay that is merely mid-handshake.
    pub subscriptions_live: usize,
    /// GROUP REQs, still present in the pool, that have delivered neither an
    /// event nor an `EOSE` within [`delivery_silence_window_secs`]. The inbox is
    /// never counted here (see the module docs). Never read as failure — only as
    /// a reason to re-issue those specific REQs.
    ///
    /// [`delivery_silence_window_secs`]: super::config::delivery_silence_window_secs
    pub subscriptions_silent: usize,
}

/// Pure decision: does a [`RelayHealthSnapshot`] warrant a re-anchor?
///
/// Two independent reasons, either sufficient:
///
/// 1. at least one relay has **dropped** (`Disconnected` / `Terminated` /
///    `Banned`). Transient states (`Initialized` / `Pending` / `Connecting`) are
///    deliberately NOT counted as dropped — see [`RelayHealthSnapshot`] — so a
///    mid-connect relay does not trigger a connection-thrashing resubscribe;
/// 2. the pool holds **fewer subscriptions than the session expects** — a REQ a
///    relay ended and nothing upstream will re-issue.
///
/// (2) is why this is not `disconnected > 0`. That predicate reads a relay that
/// keeps its socket open but deleted our REQ as perfectly healthy, which is
/// exactly the shape of a silent receive blackout.
///
/// Delivery silence is deliberately NOT here: it warrants re-issuing the quiet
/// endpoints, not the whole session, and has its own predicate
/// ([`health_needs_targeted_reanchor`]).
///
/// # Examples
///
/// ```
/// use haven_core::relay::live_sync::{health_needs_resubscribe, RelayHealthSnapshot};
///
/// // All connected, every REQ present and delivering → no resubscribe.
/// assert!(!health_needs_resubscribe(RelayHealthSnapshot {
///     total: 3,
///     connected: 3,
///     subscriptions_expected: 3,
///     subscriptions_live: 3,
///     ..Default::default()
/// }));
/// // Some still connecting, none dropped → no resubscribe (transient).
/// assert!(!health_needs_resubscribe(RelayHealthSnapshot {
///     total: 3,
///     connected: 1,
///     still_connecting: 2,
///     ..Default::default()
/// }));
/// // A dropped relay → resubscribe.
/// assert!(health_needs_resubscribe(RelayHealthSnapshot {
///     total: 3,
///     connected: 2,
///     disconnected: 1,
///     ..Default::default()
/// }));
/// // Every relay connected, but a REQ the session expects is gone from the
/// // pool: a relay CLOSED it and nothing upstream will bring it back.
/// assert!(health_needs_resubscribe(RelayHealthSnapshot {
///     total: 2,
///     connected: 2,
///     subscriptions_expected: 2,
///     subscriptions_live: 1,
///     ..Default::default()
/// }));
/// ```
#[must_use]
pub const fn health_needs_resubscribe(snapshot: RelayHealthSnapshot) -> bool {
    snapshot.disconnected > 0 || snapshot.subscriptions_live < snapshot.subscriptions_expected
}

/// Pure decision: does a [`RelayHealthSnapshot`] warrant re-issuing just the
/// REQs that went quiet?
///
/// The narrow remedy, for the ambiguous signal. Every socket is up and every REQ
/// is registered, so there is nothing to reconnect and nothing to restore — only
/// specific endpoints that stopped delivering, which are re-issued individually.
/// A whole-session re-anchor here would reconnect the pool and replay every REQ
/// on every relay for a signal that, on a circle where nobody happens to be
/// sharing, is indistinguishable from healthy.
///
/// # Examples
///
/// ```
/// use haven_core::relay::live_sync::{
///     health_needs_resubscribe, health_needs_targeted_reanchor, RelayHealthSnapshot,
/// };
///
/// let quiet = RelayHealthSnapshot {
///     total: 1,
///     connected: 1,
///     subscriptions_expected: 1,
///     subscriptions_live: 1,
///     subscriptions_silent: 1,
///     ..Default::default()
/// };
/// // Silence never escalates to the whole-session remedy...
/// assert!(!health_needs_resubscribe(quiet));
/// // ...it gets the narrow one.
/// assert!(health_needs_targeted_reanchor(quiet));
/// ```
#[must_use]
pub const fn health_needs_targeted_reanchor(snapshot: RelayHealthSnapshot) -> bool {
    snapshot.subscriptions_silent > 0
}

/// Pure decision: has one REQ been silent long enough to warrant a re-anchor?
///
/// `last_delivery_secs` is the local-clock instant that REQ last delivered an
/// event or an `EOSE` — seeded when it was issued, so a just-opened REQ is never
/// silent. Compared against a window derived from the publish cadence
/// ([`delivery_silence_window_secs`]), never a magic number.
///
/// A clock that jumps BACKWARDS makes the difference negative, which reads as
/// "not silent": the safe direction, since the alternative is a re-anchor storm
/// driven by a wrong clock.
///
/// [`delivery_silence_window_secs`]: super::config::delivery_silence_window_secs
///
/// # Examples
///
/// ```
/// use haven_core::relay::live_sync::delivery_is_silent;
///
/// assert!(delivery_is_silent(1_000, 1_000 + 700, 684));
/// assert!(!delivery_is_silent(1_000, 1_000 + 683, 684));
/// ```
#[must_use]
pub const fn delivery_is_silent(last_delivery_secs: i64, now_secs: i64, window_secs: i64) -> bool {
    now_secs.saturating_sub(last_delivery_secs) >= window_secs
}

/// Pure query: are one or more relays still coming up (and none dropped)?
///
/// Distinguishes a genuine "all good" from a "not yet ready" so a caller can
/// avoid reading a mid-connect pool as a premature all-healthy. Returns `false`
/// once anything has dropped (that is [`health_needs_resubscribe`]'s job).
///
/// # Examples
///
/// ```
/// use haven_core::relay::live_sync::{health_still_connecting, RelayHealthSnapshot};
///
/// assert!(health_still_connecting(RelayHealthSnapshot {
///     total: 2,
///     connected: 1,
///     still_connecting: 1,
///     ..Default::default()
/// }));
/// // A dropped relay takes precedence — that is a resubscribe, not "connecting".
/// assert!(!health_still_connecting(RelayHealthSnapshot {
///     total: 2,
///     connected: 0,
///     still_connecting: 1,
///     disconnected: 1,
///     ..Default::default()
/// }));
/// ```
#[must_use]
pub const fn health_still_connecting(snapshot: RelayHealthSnapshot) -> bool {
    snapshot.disconnected == 0 && snapshot.still_connecting > 0
}

/// Presence-only outcome of a subscription-health maintenance tick.
///
/// Counters + an action enum only — never a relay url, group id, or pubkey — so
/// it is leak-free (Security Rule 4/6). This is the shape the Dart
/// `MaintenanceScheduler` folds ticks into.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SubscriptionHealthOutcome {
    /// What the tick did.
    pub action: HealthAction,
    /// Relays in the engine pool at check time (`0` when `EngineOff`).
    pub relays_total: usize,
    /// Relays still coming up at check time (`Initialized` / `Pending` /
    /// `Connecting`); `0` when `EngineOff`. These did not trigger the tick's
    /// action — they are reported so a caller can distinguish "all healthy"
    /// from "some still connecting".
    pub relays_still_connecting: usize,
    /// Relays found dropped at check time (`0` when `EngineOff`).
    pub relays_disconnected: usize,
    /// `(relay, subscription)` REQ pairs the active session expected to be live
    /// (`0` when `EngineOff` or no session has started).
    pub subscriptions_expected: usize,
    /// How many of those the relay pool still held. A shortfall against
    /// `subscriptions_expected` is a REQ a relay ended and nothing upstream will
    /// re-issue — the failure connectivity counters cannot see.
    pub subscriptions_live: usize,
    /// GROUP REQs, still present in the pool, that had delivered neither an
    /// event nor an `EOSE` within the delivery-silence window. The inbox is
    /// never counted (see the module docs). This is what
    /// [`HealthAction::TargetedReanchor`] acted on.
    pub subscriptions_silent: usize,
}

impl SubscriptionHealthOutcome {
    /// The inert no-op returned when no live session is running.
    #[must_use]
    pub const fn engine_off() -> Self {
        Self {
            action: HealthAction::EngineOff,
            relays_total: 0,
            relays_still_connecting: 0,
            relays_disconnected: 0,
            subscriptions_expected: 0,
            subscriptions_live: 0,
            subscriptions_silent: 0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Convenience builder so each test states only the buckets it cares about.
    /// Subscriptions default to "every expected REQ live and delivering", so a
    /// connectivity test stays a connectivity test.
    const fn snap(
        total: usize,
        connected: usize,
        still_connecting: usize,
        disconnected: usize,
    ) -> RelayHealthSnapshot {
        RelayHealthSnapshot {
            total,
            connected,
            still_connecting,
            disconnected,
            subscriptions_expected: total,
            subscriptions_live: total,
            subscriptions_silent: 0,
        }
    }

    #[test]
    fn all_connected_is_healthy_no_resubscribe_and_not_connecting() {
        let s = snap(4, 4, 0, 0);
        assert!(!health_needs_resubscribe(s));
        assert!(!health_still_connecting(s));
    }

    #[test]
    fn some_still_connecting_none_dropped_does_not_resubscribe() {
        // A mid-connect relay is transient — re-anchoring would thrash it.
        let s = snap(3, 1, 2, 0);
        assert!(!health_needs_resubscribe(s));
    }

    #[test]
    fn some_still_connecting_is_reported_as_not_yet_ready() {
        // ...but it must NOT read as a premature all-healthy: the caller can see
        // the pool is still coming up.
        let s = snap(3, 1, 2, 0);
        assert!(health_still_connecting(s));
    }

    #[test]
    fn any_dropped_relay_warrants_resubscribe() {
        assert!(health_needs_resubscribe(snap(4, 3, 0, 1)));
        assert!(health_needs_resubscribe(snap(2, 0, 0, 2)));
    }

    #[test]
    fn dropped_takes_precedence_over_still_connecting() {
        // Mixed: a relay is still connecting AND another has dropped. The drop
        // must win — a resubscribe is warranted and the connecting one does not
        // mask it. And "still connecting" reports false because a drop is not a
        // benign not-yet-ready state.
        let s = snap(3, 1, 1, 1);
        assert!(
            health_needs_resubscribe(s),
            "a dropped relay must trigger a resubscribe even with one still connecting"
        );
        assert!(
            !health_still_connecting(s),
            "with a dropped relay present, the snapshot is not merely 'still connecting'"
        );
    }

    #[test]
    fn a_missing_subscription_warrants_a_resubscribe_with_every_relay_connected() {
        // The C3 blackout in one assertion: nostr-relay-pool deletes a
        // subscription on a `CLOSED` and never re-issues it, while the socket
        // stays up. Connectivity says "perfect"; the REQ that carried this
        // device's circles is gone.
        let s = RelayHealthSnapshot {
            total: 2,
            connected: 2,
            subscriptions_expected: 4,
            subscriptions_live: 3,
            ..Default::default()
        };
        assert!(
            health_needs_resubscribe(s),
            "a REQ the session expects but the pool no longer holds must heal, however green the connection is"
        );
    }

    #[test]
    fn every_expected_subscription_present_does_not_resubscribe() {
        // The complement: the arm must not fire on a fully-served plane, or the
        // health tick would re-anchor on every tick forever.
        let s = RelayHealthSnapshot {
            total: 2,
            connected: 2,
            subscriptions_expected: 4,
            subscriptions_live: 4,
            ..Default::default()
        };
        assert!(!health_needs_resubscribe(s));
    }

    #[test]
    fn a_pool_holding_more_subscriptions_than_expected_is_not_a_reason_to_heal() {
        // A stale REQ the session no longer models is closed by the delta ops,
        // not by a re-anchor; reading it as a shortfall would loop forever.
        let s = RelayHealthSnapshot {
            total: 1,
            connected: 1,
            subscriptions_expected: 1,
            subscriptions_live: 2,
            ..Default::default()
        };
        assert!(!health_needs_resubscribe(s));
    }

    #[test]
    fn a_silent_subscription_gets_the_targeted_remedy_not_the_whole_session_one() {
        let s = RelayHealthSnapshot {
            total: 1,
            connected: 1,
            subscriptions_expected: 1,
            subscriptions_live: 1,
            subscriptions_silent: 1,
            ..Default::default()
        };
        assert!(
            health_needs_targeted_reanchor(s),
            "a REQ present in the pool but delivering nothing must be re-issued"
        );
        assert!(
            !health_needs_resubscribe(s),
            "silence must not escalate to a whole-session re-anchor: every socket is up and every REQ is registered, so replaying every REQ (the inbox's seven-day gift-wrap lookback included) is pure cost on a signal indistinguishable from a circle where nobody is sharing"
        );
    }

    #[test]
    fn nothing_silent_needs_no_targeted_reanchor() {
        assert!(!health_needs_targeted_reanchor(snap(2, 2, 0, 0)));
    }

    #[test]
    fn delivery_silence_starts_at_the_window_and_never_before() {
        // The boundary matters: one second early and a healthy circle publishing
        // at the cadence ceiling would be re-anchored on every tick.
        let window = crate::relay::live_sync::config::delivery_silence_window_secs();
        assert!(!delivery_is_silent(0, window - 1, window));
        assert!(delivery_is_silent(0, window, window));
        assert!(delivery_is_silent(0, window * 10, window));
    }

    #[test]
    fn a_backwards_clock_jump_never_reads_as_silence() {
        // `now` behind the last delivery is a clock that moved, not a REQ that
        // died; treating it as silence would re-anchor every tick until the
        // clock caught up.
        assert!(!delivery_is_silent(10_000, 1_000, 684));
    }

    #[test]
    fn the_silence_window_is_derived_from_the_publish_cadence() {
        // Pins the derivation, not the number: the window must stay a multiple
        // of the group's kind-445 retention, so a cadence change moves it.
        use crate::location::ttl::LOCATION_MESSAGE_RETENTION_SECS;
        assert_eq!(
            crate::relay::live_sync::config::delivery_silence_window_secs(),
            crate::relay::live_sync::config::DELIVERY_SILENCE_RETENTION_MULTIPLE
                * LOCATION_MESSAGE_RETENTION_SECS.cast_signed()
        );
        assert!(
            crate::relay::live_sync::config::delivery_silence_window_secs()
                > LOCATION_MESSAGE_RETENTION_SECS.cast_signed(),
            "the window must outlast a single retention period, or a circle whose only publisher is at the cadence ceiling would look silent"
        );
    }

    #[test]
    fn empty_pool_is_healthy_not_a_drop_and_not_connecting() {
        // A pool with zero relays has nothing dropped and nothing connecting.
        let s = RelayHealthSnapshot::default();
        assert!(!health_needs_resubscribe(s));
        assert!(!health_still_connecting(s));
    }

    #[test]
    fn engine_off_outcome_is_zeroed() {
        let o = SubscriptionHealthOutcome::engine_off();
        assert_eq!(o.action, HealthAction::EngineOff);
        assert_eq!(o.relays_total, 0);
        assert_eq!(o.relays_still_connecting, 0);
        assert_eq!(o.relays_disconnected, 0);
        assert_eq!(o.subscriptions_expected, 0);
        assert_eq!(o.subscriptions_live, 0);
        assert_eq!(o.subscriptions_silent, 0);
    }

    #[test]
    fn outcome_debug_is_presence_only() {
        // Fieldless enum + integer counters — no url/id/hex can appear. The
        // subscription counts are the newest way this could have gone wrong:
        // they are DERIVED from relay urls and subscription ids, so the outcome
        // must carry only how many, never which.
        let o = SubscriptionHealthOutcome {
            action: HealthAction::TargetedReanchor,
            relays_total: 3,
            relays_still_connecting: 1,
            relays_disconnected: 2,
            subscriptions_expected: 4,
            subscriptions_live: 4,
            subscriptions_silent: 1,
        };
        let s = format!("{o:?}");
        assert!(s.contains("TargetedReanchor"));
        assert!(s.contains('3'));
        assert!(s.contains('2'));
        // Only the variant name + digits appear — assert no scheme leaks.
        assert!(!s.contains("ws://"));
        assert!(!s.contains("wss://"));
        // ...and no sub-id-shaped VALUE. The counters are derived from relay
        // urls and subscription ids, so what must not render is an identifier,
        // not the word "subscriptions" in a field name. A sub-id carries a
        // 16-hex-char digest prefix (`SUB_ID_PREFIX_BYTES`), which is exactly
        // the `redact_hex_sequences` floor.
        let longest_hex_run = s
            .split(|c: char| !c.is_ascii_hexdigit())
            .map(str::len)
            .max()
            .unwrap_or(0);
        assert!(
            longest_hex_run < 16,
            "a sub-id-shaped value rendered in the outcome: {s}"
        );
    }

    #[test]
    fn the_two_re_anchor_remedies_are_distinguishable() {
        // They differ by orders of magnitude in cost, and a targeted re-anchor
        // is EXPECTED on a device whose circles are idle — collapsing them
        // would make a normal quiet device look like it kept losing relays.
        assert_ne!(HealthAction::Resubscribed, HealthAction::TargetedReanchor);
    }

    #[test]
    fn snapshot_debug_is_presence_only() {
        let s = snap(5, 2, 1, 1);
        let dbg = format!("{s:?}");
        assert!(dbg.contains("RelayHealthSnapshot"));
        assert!(!dbg.contains("ws://"));
        assert!(!dbg.contains("wss://"));
    }
}
