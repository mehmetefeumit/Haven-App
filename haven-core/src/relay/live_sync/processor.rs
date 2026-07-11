//! The regime-aware group-event processor — the heart of the receive engine.
//!
//! For each incoming `kind:445`, the processor chooses between the two regimes
//! that the M3b empirical work established (see the `*_while_holding_pending_*`
//! and `no_pending_observers_*` regression tests in `circle::manager`):
//!
//! - **Regime 1 — no settle window open** (the common case, all observers): the
//!   event is decrypted via [`CircleManager::decrypt_location_for_engine`] and
//!   planned via [`plan_outcome`]. Concurrent commits converge through MDK's
//!   native epoch-snapshot rollback; nothing is buffered.
//! - **Regime 2 — a settle window is open** (we hold our own unmerged pending
//!   commit; only on an admin staging a membership change): the raw event is
//!   **buffered** as a competitor candidate and **NOT decrypted**. This is the
//!   load-bearing fork-safety gate — a same-epoch sibling decrypted while we
//!   hold a pending commit is *applied* by MDK (it surfaces as `Ok(Commit)`, NOT
//!   an error), forking the group. The gate therefore lives **here, before
//!   decryption**, not in [`plan_outcome`] (which would only see the already
//!   forked `GroupUpdate`). The buffered candidates are resolved by
//!   `converge_commit` when the foreground closes the window.
//!
//! # Per-circle cursor
//!
//! Each circle gets its own group cursor via the per-circle stream key
//! `group_445:{hex(nostr_group_id)}`, so a busy circle's cursor advance cannot
//! bury a quiet co-multiplexed circle's un-applied commit (the
//! [`crate::relay::cursor`] machinery treats any non-inbox key as a group
//! stream).

use std::sync::{Arc, Mutex};

use nostr::{Event, JsonUtil};

use crate::circle::CircleManager;

use super::autocommit::AutoCommitWork;
use super::event::{EngineDecryptOutcome, LiveSyncEvent, SyncStatusReason};
use super::event_bus::EventBus;
use super::finalize::open_window_carrying_displaced;
use super::plan::plan_outcome;
use super::settle::{BufferedCommit, CommitSettleBuffer};

/// Per-circle group-cursor stream key (gate #3: per-circle cursors with no
/// storage-schema change — a distinct stream key per `hex(nostr_group_id)`).
#[must_use]
pub fn group_cursor_stream(group_id_hex: &str) -> String {
    format!("{}:{group_id_hex}", crate::relay::cursor::STREAM_GROUP_445)
}

/// What the processor did with one group event (returned for observability and
/// testing; the side effects — buffer insert, cursor advance, bus emit — have
/// already been applied).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GroupProcessOutcome {
    /// Regime 2: the raw event was buffered as a competitor candidate (or
    /// ignored if the bound/dedup rejected it); the MLS state was NOT touched.
    Buffered {
        /// Whether the candidate was actually retained.
        inserted: bool,
    },
    /// Regime 1: the event was decrypted and planned.
    Processed {
        /// Whether the per-circle group cursor advanced.
        advanced_cursor: bool,
    },
    /// Regime 1, path B: the decrypt auto-committed a peer `SelfRemove` (MDK
    /// staged a pending commit). The processor opened a settle window under the
    /// gate; the supervisor must now spawn the in-Rust converge task with this
    /// work item. The cursor did NOT advance (it advances only after convergence,
    /// via lossless replay if the task is interrupted).
    AutoCommitStaged(Box<AutoCommitWork>),
}

/// The receive engine's group/inbox event processor.
///
/// Holds the single MLS-state owner ([`CircleManager`]), the shared settle
/// buffer, and the fan-out bus. `process_group_event` is **synchronous** (no
/// `await`) so the regime gate is unit-testable against a real MDK without the
/// async session; the async supervisor merely feeds it events.
pub struct EngineProcessor {
    circle: Arc<CircleManager>,
    settle: Arc<Mutex<CommitSettleBuffer>>,
    bus: EventBus,
}

impl EngineProcessor {
    /// Creates a processor over the shared MLS state, settle buffer, and bus.
    #[must_use]
    pub const fn new(
        circle: Arc<CircleManager>,
        settle: Arc<Mutex<CommitSettleBuffer>>,
        bus: EventBus,
    ) -> Self {
        Self {
            circle,
            settle,
            bus,
        }
    }

    /// Shared settle buffer handle (the foreground finalize site opens/closes
    /// windows and takes competitors through the same buffer).
    #[must_use]
    pub const fn settle(&self) -> &Arc<Mutex<CommitSettleBuffer>> {
        &self.settle
    }

    /// Recovers the settle buffer guard, tolerating a poisoned lock (a panic in
    /// another holder must not wedge the whole receive path).
    fn lock_settle(&self) -> std::sync::MutexGuard<'_, CommitSettleBuffer> {
        self.settle
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Processes one incoming `kind:445` for `nostr_group_id` (its routed `#h`).
    ///
    /// THE regime gate (HIGH fork-safety must-fix): when a settle window is open
    /// for the circle, the raw event is buffered and **never decrypted**; only
    /// then is decryption safe to skip. Otherwise it is decrypted, planned, and
    /// applied (cursor advance + bus emit).
    // `cfg_attr(test)`: the `#[cfg(test)]` fault-injection seam below holds the only
    // `panic!`, so `missing_panics_doc` fires solely in test builds; the production
    // signature never panics and needs no `# Panics` section.
    #[cfg_attr(test, allow(clippy::missing_panics_doc))]
    pub fn process_group_event(&self, event: &Event, nostr_group_id: &[u8]) -> GroupProcessOutcome {
        // Test-only fault-injection seam (R6 / GAP-A): a sentinel content string
        // panics here so the `run_worker` catch_unwind panic-isolation test can
        // prove one adversarial event never blinds the receive path. Compiled out
        // of every non-test build (`#[cfg(test)]`), so it has zero production or
        // CI-clippy impact (the CI gate lints the non-test lib, where this is
        // excluded). The `#[allow(clippy::manual_assert)]` keeps the `--all-targets`
        // lint lane clean too — a raw `panic!` seam is intentional (it simulates an
        // unexpected MDK panic), not a candidate for `assert!`.
        #[cfg(test)]
        #[allow(clippy::manual_assert)]
        if event.content == "__panic_for_test__" {
            panic!("injected decrypt panic (R6 test seam)");
        }

        let group_hex = hex::encode(nostr_group_id);

        // REGIME 2 — a window is open ⇒ buffer raw, do NOT decrypt.
        let staged_epoch = self.lock_settle().window_staged_epoch(&group_hex);
        if let Some(staged_epoch) = staged_epoch {
            let candidate = BufferedCommit {
                event_json: event.as_json(),
                created_at_secs: event.created_at.as_secs(),
                id_hex: event.id.to_hex(),
            };
            // `observed_local_epoch` is the window's staged epoch. The engine
            // never advances the epoch in regime 2 (it buffers without
            // decrypting), and the M6 finalize site closes the window atomically
            // with any merge (the finalize/supervisor contract), so while a
            // window is open the local epoch equals the staged epoch and this is
            // exact. The settle-buffer stale-drop is thus a defense-in-depth
            // no-op here; a competitor that somehow outlived an epoch advance is
            // still re-validated — and `RolledBack` — by `converge_commit`'s
            // TOCTOU check, never corrupting state. Reading the true local epoch
            // would require an MLS-group-id lookup the engine deliberately avoids
            // (Rule 4).
            let inserted =
                self.lock_settle()
                    .insert_competitor(&group_hex, candidate, staged_epoch);
            self.bus.send(LiveSyncEvent::Status {
                reason: SyncStatusReason::Unprocessable,
            });
            return GroupProcessOutcome::Buffered { inserted };
        }

        // REGIME 1 — no window ⇒ decrypt + plan + apply. MDK's native rollback
        // converges concurrent commits; nothing is buffered.
        let outcome = self
            .circle
            .decrypt_location_for_engine(event, nostr_group_id);

        // Path B (M6-2): an auto-committed peer SelfRemove. MDK already staged a
        // pending commit (regime 2 now). Open a settle window HERE — still under
        // the worker's gate, before it is released — so a concurrent sibling
        // auto-commit buffers instead of being blind-applied; then hand the work
        // to the supervisor's in-Rust converge task. Intercepted BEFORE
        // `plan_outcome` (which must never see / apply an `AutoCommit`).
        if let EngineDecryptOutcome::AutoCommit {
            mls_group_id,
            commit_json,
            nostr_group_id: routed_id,
        } = outcome
        {
            // The staged epoch is the current epoch — a pending commit does not
            // advance it (verified against MDK 93ae324). On a read failure we
            // cannot converge, so clear the dangling pending commit (no wedge)
            // rather than spawn an un-resolvable task.
            let Ok(staged_epoch) = self.circle.group_epoch_internal(&mls_group_id) else {
                let _ = self.circle.clear_pending_commit(&mls_group_id);
                self.bus.send(LiveSyncEvent::Status {
                    reason: SyncStatusReason::Unprocessable,
                });
                return GroupProcessOutcome::Processed {
                    advanced_cursor: false,
                };
            };
            open_window_carrying_displaced(&self.settle, &group_hex, staged_epoch);
            return GroupProcessOutcome::AutoCommitStaged(Box::new(AutoCommitWork {
                mls_group_id,
                nostr_group_id: routed_id,
                staged_epoch,
                commit_json,
            }));
        }

        let plan = plan_outcome(outcome, false);

        if plan.advance_cursor {
            let ms = i64::try_from(event.created_at.as_secs())
                .unwrap_or(i64::MAX)
                .saturating_mul(1000);
            // Best-effort: a cursor write failure must not drop the delivered
            // event (the bus emit below still fires; the cursor re-advances on
            // the next applied event).
            let _ = self
                .circle
                .advance_sync_cursor(&group_cursor_stream(&group_hex), ms);
        }

        if let Some(ev) = plan.emit {
            self.bus.send(ev);
        }

        GroupProcessOutcome::Processed {
            advanced_cursor: plan.advance_cursor,
        }
    }

    /// Emits a raw gift-wrapped invitation (`kind:1059`) onto the bus. The
    /// engine never unwraps it; the foreground consumer does
    /// (`process_gift_wrapped_invitation`). The inbox cursor advances only via
    /// the foreground after a successful unwrap, never here.
    pub fn process_inbox_event(&self, event: &Event) {
        self.bus.send(LiveSyncEvent::Welcome {
            gift_wrap_json: event.as_json(),
            wrap_created_at_secs: i64::try_from(event.created_at.as_secs()).unwrap_or(i64::MAX),
        });
    }

    /// Emits a bare status signal on the bus. Used by the supervisor for
    /// out-of-band conditions — notably to surface (rather than silently swallow)
    /// a recovered worker panic, so a single bad event cannot blind the consumer.
    pub fn emit_status(&self, reason: SyncStatusReason) {
        self.bus.send(LiveSyncEvent::Status { reason });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::relay::cursor::STREAM_GROUP_445;

    #[test]
    fn per_circle_cursor_stream_keys_are_distinct_and_group_scoped() {
        let a = group_cursor_stream("aa00");
        let b = group_cursor_stream("bb11");
        assert_ne!(a, b, "each circle gets its own group cursor");
        // Distinct from the inbox stream and prefixed by the group stream key so
        // `since_for_stream` treats it as a group stream (small clock buffer).
        assert!(a.starts_with(STREAM_GROUP_445));
        assert_ne!(a, crate::relay::cursor::STREAM_INBOX_1059);
    }
}
