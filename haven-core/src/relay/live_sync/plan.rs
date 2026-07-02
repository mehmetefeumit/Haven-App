//! Pure processor planning: maps one group-plane [`EngineDecryptOutcome`] to the
//! three decisions the async processor must make — advance the cursor, buffer a
//! competitor, and what (if anything) to emit.
//!
//! Factoring this out keeps the load-bearing cursor-gating contract (PSI-7)
//! unit-testable without a relay, an MLS state, or a runtime. The async
//! processor (M3b) supplies the raw-event context (its `created_at` for the
//! cursor, its JSON for the settle buffer) and applies the returned plan.
//!
//! # Cursor gating (PSI-7)
//!
//! The group cursor advances **only** on a successfully-applied event
//! (`Location`, or a `GroupUpdate` with no pending finalize). Everything that
//! leaves work undone — an unfinalized peer self-remove, an unprocessable or
//! previously-failed event, a competing sibling commit, or any other error —
//! must **not** advance, so the M1 lossless-replay contract re-delivers it on
//! the next subscription.

use super::event::{EngineDecryptOutcome, LiveSyncEvent, SyncStatusReason};

/// The processor's plan for one group-plane outcome.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcessorPlan {
    /// Advance the group cursor to the source event's `created_at`.
    pub advance_cursor: bool,
    /// Feed the source event to the settle buffer as a competitor commit.
    pub buffer_competitor: bool,
    /// What to publish on the bus, or `None` to drop silently.
    pub emit: Option<LiveSyncEvent>,
}

/// Plans the processor's actions for one group-plane decrypt outcome.
///
/// Consumes `outcome` so successfully-decrypted payloads move directly into the
/// emitted [`LiveSyncEvent`] without a copy.
///
/// `window_open` is whether a settle window is currently open for this circle
/// (i.e. we hold our own unmerged pending commit — "regime 2"). A
/// [`EngineDecryptOutcome::CompetingCommit`] is buffered for convergence **only**
/// while a window is open; with no window ("regime 1", the common case) there is
/// nothing to converge against, so the competitor is not buffered — the lossless
/// cursor replay plus MDK's native epoch-snapshot rollback reconcile it instead.
#[must_use]
pub fn plan_outcome(outcome: EngineDecryptOutcome, window_open: bool) -> ProcessorPlan {
    match outcome {
        EngineDecryptOutcome::Location {
            nostr_group_id,
            sender_pubkey,
            content,
            created_at_secs,
        } => ProcessorPlan {
            advance_cursor: true,
            buffer_competitor: false,
            emit: Some(LiveSyncEvent::Location {
                nostr_group_id,
                sender_pubkey,
                content,
                event_created_at_secs: created_at_secs,
            }),
        },
        EngineDecryptOutcome::GroupUpdate {
            nostr_group_id,
            evolution_event_json,
        } => {
            // A `Some` evolution event is an auto-committed peer self-remove the
            // consumer must publish+merge before the epoch advances; until it
            // does, the cursor must NOT advance past this event. A `None`
            // evolution event is already applied → safe to advance.
            let advance_cursor = evolution_event_json.is_none();
            ProcessorPlan {
                advance_cursor,
                buffer_competitor: false,
                emit: Some(LiveSyncEvent::GroupUpdate {
                    nostr_group_id,
                    evolution_event_json,
                }),
            }
        }
        EngineDecryptOutcome::CompetingCommit => ProcessorPlan {
            advance_cursor: false,
            // Only buffer when a settle window is open (regime 2). With no
            // window there is no `converge_commit` to feed; cursor replay +
            // MDK's native rollback reconcile it.
            buffer_competitor: window_open,
            emit: Some(LiveSyncEvent::Status {
                reason: SyncStatusReason::Unprocessable,
            }),
        },
        // `AutoCommit` (path B) is intercepted by `process_group_event` BEFORE
        // `plan_outcome` is ever called (it opens a settle window + spawns the
        // engine's converge task), so this arm is unreachable in production — but
        // required for exhaustiveness. Defensive no-op: advance nothing, emit
        // nothing (a stray AutoCommit reaching here must not be silently applied).
        EngineDecryptOutcome::AutoCommit { .. } => ProcessorPlan {
            advance_cursor: false,
            buffer_competitor: false,
            emit: None,
        },
        EngineDecryptOutcome::Unprocessable
        | EngineDecryptOutcome::PreviouslyFailed
        | EngineDecryptOutcome::OtherError => ProcessorPlan {
            advance_cursor: false,
            buffer_competitor: false,
            emit: Some(LiveSyncEvent::Status {
                reason: SyncStatusReason::Unprocessable,
            }),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn location() -> EngineDecryptOutcome {
        EngineDecryptOutcome::Location {
            nostr_group_id: vec![1, 2, 3],
            sender_pubkey: "deadbeef".to_string(),
            content: "{\"lat\":0}".to_string(),
            created_at_secs: 100,
        }
    }

    #[test]
    fn location_advances_cursor_and_emits_location_with_fields_intact() {
        let plan = plan_outcome(location(), false);
        assert!(plan.advance_cursor);
        assert!(!plan.buffer_competitor);
        // Destructure (not `..`) so a swapped/zeroed field is caught — the
        // group-id and created_at passthrough are load-bearing for routing the
        // location to the right circle and gating the cursor (PSI-7).
        match plan.emit {
            Some(LiveSyncEvent::Location {
                nostr_group_id,
                sender_pubkey,
                content,
                event_created_at_secs,
            }) => {
                assert_eq!(nostr_group_id, vec![1, 2, 3]);
                assert_eq!(sender_pubkey, "deadbeef");
                assert_eq!(content, "{\"lat\":0}");
                assert_eq!(event_created_at_secs, 100);
            }
            other => panic!("expected Location emit, got {other:?}"),
        }
    }

    #[test]
    fn applied_group_update_advances_but_pending_self_remove_does_not() {
        // evolution_event = None  → already applied → advance.
        let applied = plan_outcome(
            EngineDecryptOutcome::GroupUpdate {
                nostr_group_id: vec![9],
                evolution_event_json: None,
            },
            false,
        );
        assert!(applied.advance_cursor);
        assert!(!applied.buffer_competitor);
        // The None must round-trip into the emit (not become a drop or a Status).
        assert!(matches!(
            applied.emit,
            Some(LiveSyncEvent::GroupUpdate {
                evolution_event_json: None,
                ..
            })
        ));

        // evolution_event = Some → consumer must finalize first → DO NOT advance.
        let pending = plan_outcome(
            EngineDecryptOutcome::GroupUpdate {
                nostr_group_id: vec![9],
                evolution_event_json: Some("{\"commit\":true}".to_string()),
            },
            false,
        );
        assert!(
            !pending.advance_cursor,
            "unfinalized self-remove must not advance"
        );
        assert!(matches!(
            pending.emit,
            Some(LiveSyncEvent::GroupUpdate {
                evolution_event_json: Some(_),
                ..
            })
        ));
    }

    #[test]
    fn competing_commit_never_advances_and_buffers_only_when_window_open() {
        // Regime 2 (window open): buffer for converge.
        let with_window = plan_outcome(EngineDecryptOutcome::CompetingCommit, true);
        assert!(
            !with_window.advance_cursor,
            "a competing sibling must never advance the cursor"
        );
        assert!(
            with_window.buffer_competitor,
            "with an open window, a competing sibling must be buffered"
        );
        assert!(matches!(
            with_window.emit,
            Some(LiveSyncEvent::Status {
                reason: SyncStatusReason::Unprocessable
            })
        ));

        // Regime 1 (no window): do NOT buffer — nothing to converge against; the
        // cursor (un-advanced) replays it and MDK's native rollback reconciles.
        let no_window = plan_outcome(EngineDecryptOutcome::CompetingCommit, false);
        assert!(!no_window.advance_cursor);
        assert!(
            !no_window.buffer_competitor,
            "with no open window, a competing sibling must NOT be buffered"
        );
    }

    #[test]
    fn unprocessable_previously_failed_and_other_error_do_not_advance_or_buffer() {
        for outcome in [
            EngineDecryptOutcome::Unprocessable,
            EngineDecryptOutcome::PreviouslyFailed,
            EngineDecryptOutcome::OtherError,
        ] {
            // Window state is irrelevant for these — never buffered either way.
            let plan = plan_outcome(outcome.clone(), true);
            assert!(!plan.advance_cursor, "{outcome:?} must not advance");
            assert!(!plan.buffer_competitor, "{outcome:?} must not buffer");
            assert!(matches!(
                plan.emit,
                Some(LiveSyncEvent::Status {
                    reason: SyncStatusReason::Unprocessable
                })
            ));
        }
    }
}
