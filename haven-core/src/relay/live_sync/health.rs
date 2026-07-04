//! Subscription-health maintenance (M8-4) for the live-sync engine.
//!
//! A scheduled tick that heals dropped relay connections: it snapshots the
//! engine's relay connectivity and, if any relay has dropped, re-anchors every
//! subscription at its persisted cursor via
//! [`super::session::LiveSyncCore::resume_after_background`] (which reconnects
//! the pool and re-issues the same subscription ids — no miss window).
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
    /// The engine is running and every relay is connected — nothing to do.
    Healthy,
    /// One or more relays had dropped; every subscription was re-anchored at
    /// its persisted cursor via `resume_after_background`.
    Resubscribed,
}

/// Presence-only snapshot of the engine pool's relay connectivity.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct RelayHealthSnapshot {
    /// Relays the engine's pool currently holds.
    pub total: usize,
    /// Relays in a dropped state (`Disconnected` / `Terminated` / `Banned`).
    pub disconnected: usize,
}

/// Pure decision: does a [`RelayHealthSnapshot`] warrant a re-anchor?
///
/// A re-anchor (reconnect + re-subscribe at the persisted cursor) is warranted
/// only when at least one relay has dropped. Transient states (`Connecting`,
/// `Pending`) are deliberately NOT counted as dropped, so a mid-connect relay
/// does not trigger a redundant resubscribe.
///
/// # Examples
///
/// ```
/// use haven_core::relay::live_sync::{health_needs_resubscribe, RelayHealthSnapshot};
///
/// assert!(!health_needs_resubscribe(RelayHealthSnapshot { total: 3, disconnected: 0 }));
/// assert!(health_needs_resubscribe(RelayHealthSnapshot { total: 3, disconnected: 1 }));
/// ```
#[must_use]
pub const fn health_needs_resubscribe(snapshot: RelayHealthSnapshot) -> bool {
    snapshot.disconnected > 0
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
            relays_disconnected: 0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_dropped_relays_does_not_warrant_resubscribe() {
        assert!(!health_needs_resubscribe(RelayHealthSnapshot {
            total: 4,
            disconnected: 0,
        }));
    }

    #[test]
    fn any_dropped_relay_warrants_resubscribe() {
        assert!(health_needs_resubscribe(RelayHealthSnapshot {
            total: 4,
            disconnected: 1,
        }));
        assert!(health_needs_resubscribe(RelayHealthSnapshot {
            total: 2,
            disconnected: 2,
        }));
    }

    #[test]
    fn empty_pool_is_healthy_not_a_drop() {
        // A pool with zero relays has nothing dropped — no resubscribe.
        assert!(!health_needs_resubscribe(RelayHealthSnapshot::default()));
    }

    #[test]
    fn engine_off_outcome_is_zeroed() {
        let o = SubscriptionHealthOutcome::engine_off();
        assert_eq!(o.action, HealthAction::EngineOff);
        assert_eq!(o.relays_total, 0);
        assert_eq!(o.relays_disconnected, 0);
    }

    #[test]
    fn outcome_debug_is_presence_only() {
        // Fieldless enum + integer counters — no url/id/hex can appear.
        let o = SubscriptionHealthOutcome {
            action: HealthAction::Resubscribed,
            relays_total: 3,
            relays_disconnected: 2,
        };
        let s = format!("{o:?}");
        assert!(s.contains("Resubscribed"));
        assert!(s.contains('3'));
        assert!(s.contains('2'));
    }
}
