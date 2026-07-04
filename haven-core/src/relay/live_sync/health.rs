//! Subscription-health maintenance (M8-4) for the live-sync engine.
//!
//! A scheduled tick that heals dropped relay connections: it snapshots the
//! engine's relay connectivity and, if any relay has dropped, re-anchors every
//! subscription at its persisted cursor via
//! [`super::session::LiveSyncCore::resume_after_background`] (which reconnects
//! the pool and re-issues the same subscription ids — no miss window).
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
    /// One or more relays had dropped; every subscription was re-anchored at
    /// its persisted cursor via `resume_after_background`.
    Resubscribed,
}

/// Presence-only snapshot of the engine pool's relay connectivity.
///
/// The three buckets are disjoint and, together with `Sleeping` relays (which
/// fall into none of them), partition `total`. `total >= connected +
/// still_connecting + disconnected` always holds (equality when no relay is
/// `Sleeping`).
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
}

/// Pure decision: does a [`RelayHealthSnapshot`] warrant a re-anchor?
///
/// A re-anchor (reconnect + re-subscribe at the persisted cursor) is warranted
/// only when at least one relay has **dropped** (`Disconnected` / `Terminated`
/// / `Banned`). Transient states (`Initialized` / `Pending` / `Connecting`) are
/// deliberately NOT counted as dropped — see [`RelayHealthSnapshot`] — so a
/// mid-connect relay does not trigger a redundant, connection-thrashing
/// resubscribe.
///
/// # Examples
///
/// ```
/// use haven_core::relay::live_sync::{health_needs_resubscribe, RelayHealthSnapshot};
///
/// // All connected → no resubscribe.
/// assert!(!health_needs_resubscribe(RelayHealthSnapshot {
///     total: 3,
///     connected: 3,
///     still_connecting: 0,
///     disconnected: 0,
/// }));
/// // Some still connecting, none dropped → no resubscribe (transient).
/// assert!(!health_needs_resubscribe(RelayHealthSnapshot {
///     total: 3,
///     connected: 1,
///     still_connecting: 2,
///     disconnected: 0,
/// }));
/// // A dropped relay → resubscribe.
/// assert!(health_needs_resubscribe(RelayHealthSnapshot {
///     total: 3,
///     connected: 2,
///     still_connecting: 0,
///     disconnected: 1,
/// }));
/// ```
#[must_use]
pub const fn health_needs_resubscribe(snapshot: RelayHealthSnapshot) -> bool {
    snapshot.disconnected > 0
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
///     disconnected: 0,
/// }));
/// // A dropped relay takes precedence — that is a resubscribe, not "connecting".
/// assert!(!health_still_connecting(RelayHealthSnapshot {
///     total: 2,
///     connected: 0,
///     still_connecting: 1,
///     disconnected: 1,
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
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Convenience builder so each test states only the buckets it cares about.
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
    }

    #[test]
    fn outcome_debug_is_presence_only() {
        // Fieldless enum + integer counters — no url/id/hex can appear.
        let o = SubscriptionHealthOutcome {
            action: HealthAction::Resubscribed,
            relays_total: 3,
            relays_still_connecting: 1,
            relays_disconnected: 2,
        };
        let s = format!("{o:?}");
        assert!(s.contains("Resubscribed"));
        assert!(s.contains('3'));
        assert!(s.contains('2'));
        // Only the variant name + digits appear — assert no scheme leaks.
        assert!(!s.contains("ws://"));
        assert!(!s.contains("wss://"));
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
