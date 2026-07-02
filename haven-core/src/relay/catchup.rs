//! Cursor-anchored, receive-only catch-up sweep (M7).
//!
//! A best-effort, deadline-bounded fetch that pulls whatever a circle's relays
//! hold since the persisted cursor and applies it FORK-SAFELY in the background
//! / on foreground resume — without ever authoring, staging, merging, or
//! converging a commit (that is the single foreground writer's job).
//!
//! # Fork-safety (the load-bearing contract)
//!
//! Every group decrypt is gated on [`CircleManager::has_pending_commit`] (the
//! Haven-owned, cross-process-visible staged-commit marker): if a group holds a
//! locally-staged pending commit, the sweep SKIPS it and does NOT advance its
//! cursor — the foreground owns that epoch transition, and blind-applying a
//! same-epoch sibling would fork. See [`ReceiveOnlyOutcome`] and the M7 design.

/// The fork-safe classification of a single receive-only group event.
///
/// Fieldless (Copy) — carries no coordinates, pubkey, group id, or commit JSON,
/// so its derived `Debug` cannot leak (Security Rule 4/6). The location content
/// is persisted in-crate via `upsert_last_known_location`, never surfaced here.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReceiveOnlyOutcome {
    /// A location application-message was decrypted (and persisted, unless a
    /// self-echo). The cursor may advance past it.
    Location,
    /// An already-merged peer commit (`GroupUpdate{None}`, epoch advanced —
    /// convergent, authors nothing). The cursor may advance past it.
    CommitApplied,
    /// MDK auto-staged a peer proposal commit. NOT cleared (clearing loses the
    /// leave) — the marker is set so future wakes skip, and the FOREGROUND
    /// engine converges it. The cursor MUST STOP before this event.
    AutoCommitStaged,
    /// Skipped without applying: a pre-existing pending commit (regime-2, incl.
    /// the fail-closed storage-error case), or an unprocessable / competing /
    /// previously-failed / other-error event. The cursor MUST STOP before it.
    Skipped,
}

impl ReceiveOnlyOutcome {
    /// Whether the cursor may advance past this event. Only fully-applied,
    /// terminal outcomes (a persisted `Location` or an already-merged
    /// `CommitApplied`) advance; everything else stops the high-water-mark so an
    /// un-applied commit is always re-fetched on the next sweep (C-CURSOR).
    #[must_use]
    pub const fn advances_cursor(self) -> bool {
        matches!(self, Self::Location | Self::CommitApplied)
    }
}

/// Presence-only tally of a catch-up sweep. All counters — no group ids,
/// coordinates, or secrets — so its derived `Debug` is leak-free by
/// construction (Security Rule 4).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CatchupOutcome {
    /// Circles whose relays were swept.
    pub circles_swept: usize,
    /// Location events decrypted + persisted.
    pub locations_applied: usize,
    /// Already-merged peer commits observed.
    pub commits_applied: usize,
    /// Groups skipped because they hold a pending commit (regime-2 gate).
    pub skipped_pending: usize,
    /// Peer proposals MDK auto-staged (left for the foreground to converge).
    pub auto_commits_staged: usize,
    /// Per-circle group cursors advanced.
    pub cursors_advanced: usize,
    /// The deadline was reached before every bucket was swept.
    pub deadline_hit: bool,
    /// Relay fetches that returned no response / errored (tallied, never fatal).
    pub relay_errors: usize,
}

/// Max events fetched per circle per sweep — a flood-guard so a malicious relay
/// cannot answer one circle's REQ with an unbounded batch a background wake
/// would then decrypt. Generous: a circle's legitimate backlog in the
/// resubscribe window (locations are NIP-40-ephemeral, commits are rare) is far
/// smaller. A missed tail re-fetches next sweep.
const CATCHUP_MAX_EVENTS_PER_CIRCLE: usize = 512;

use std::collections::HashSet;
use std::time::{Duration, Instant};

use nostr::{Event, PublicKey};

use crate::circle::CircleManager;
use crate::relay::cursor::{since_for_stream, SubscribePhase};
use crate::relay::live_sync::planes::group::group_filter;
use crate::relay::live_sync::{group_cursor_stream, MlsWriteGate};
use crate::relay::RelayManager;

/// The cursor-advance target (ms) for a batch already sorted ascending by
/// `(created_at, id)`: the `created_at` (→ ms) of the last event in the longest
/// CONTIGUOUS PREFIX of cursor-advancing outcomes. Stops at the first
/// non-advancing event so an un-applied commit is always re-fetched next sweep
/// (C-CURSOR). `None` ⇒ do not advance. Pure + unit-tested.
#[must_use]
pub(crate) fn contiguous_prefix_cursor_ms(sorted: &[(i64, ReceiveOnlyOutcome)]) -> Option<i64> {
    let mut advance_secs: Option<i64> = None;
    for (secs, outcome) in sorted {
        if outcome.advances_cursor() {
            advance_secs = Some(*secs);
        } else {
            break;
        }
    }
    advance_secs.map(|s| s.saturating_mul(1000))
}

/// Runs a cursor-anchored, receive-only catch-up sweep over every visible
/// circle.
///
/// Best-effort and deadline-bounded; NEVER authors/merges/converges a commit.
/// See the module docs for the fork-safety contract.
///
/// `gate` (when a live-sync engine is running in-process) serializes each
/// group's decrypt against the engine writer; in a cold background wake it is
/// `None` and the persisted staged-commit marker (checked inside
/// [`CircleManager::decrypt_receive_only`]) is the fork guard. Fails closed: if
/// storage is unavailable, returns an empty [`CatchupOutcome`] (no decrypt).
pub async fn run_catchup_all_circles(
    circle_mgr: &CircleManager,
    relay_mgr: &RelayManager,
    own_pubkey: &PublicKey,
    gate: Option<&MlsWriteGate>,
    max_duration_secs: u64,
) -> CatchupOutcome {
    let mut out = CatchupOutcome::default();
    let deadline = Instant::now() + Duration::from_secs(max_duration_secs);
    let own_hex = own_pubkey.to_hex();

    // Fail-closed: storage unavailable (e.g. locked device) ⇒ clean no-op.
    let Ok(circles) = circle_mgr.get_visible_circles() else {
        return out;
    };

    for cwm in circles {
        if Instant::now() >= deadline {
            out.deadline_hit = true;
            break;
        }
        let ngid = cwm.circle.nostr_group_id;
        let relays = cwm.circle.relays;
        if relays.is_empty() {
            continue;
        }
        let hex = hex::encode(ngid);
        let stream = group_cursor_stream(&hex);
        out.circles_swept += 1;

        // since = cursor − resubscribe buffer; a fail-safe now−24h floor if the
        // cursor is unseeded (matches the bootstrap seed policy).
        let now_secs = chrono::Utc::now().timestamp();
        let cursor_ms = circle_mgr
            .read_sync_cursor(&stream)
            .ok()
            .flatten()
            .unwrap_or_else(|| now_secs.saturating_sub(24 * 3600).saturating_mul(1000));
        let since_secs =
            since_for_stream(&stream, cursor_ms, SubscribePhase::Resubscribe, now_secs);
        // Cap the per-circle batch: a malicious/compromised relay must not be
        // able to answer one circle's REQ with an unbounded flood that a
        // background wake would then decrypt (CPU/battery DoS). A missed tail
        // re-fetches on the next sweep (the cursor only advances over the
        // applied prefix).
        let filter = group_filter(std::slice::from_ref(&hex), since_secs)
            .limit(CATCHUP_MAX_EVENTS_PER_CIRCLE);

        let Ok(fetch_outcomes) = relay_mgr.fetch_events_per_relay(filter, &relays).await else {
            // A bad relay URL (e.g. plaintext ws:// in release) must not abort
            // the whole sweep — tally and move on.
            out.relay_errors += 1;
            continue;
        };

        // Dedup by event id across relays.
        let mut seen: HashSet<_> = HashSet::new();
        let mut events: Vec<Event> = Vec::new();
        for fo in fetch_outcomes {
            if !fo.responded {
                out.relay_errors += 1;
            }
            for ev in fo.events {
                if seen.insert(ev.id) {
                    events.push(ev);
                }
            }
        }
        // Ascending (created_at, id) so the contiguous-prefix cursor rule holds.
        events.sort_by(|a, b| a.created_at.cmp(&b.created_at).then(a.id.cmp(&b.id)));

        // In-process serialization with the engine writer, if running.
        let lock = gate.map(|g| g.for_group(&hex));
        let gate_guard = match &lock {
            Some(l) => Some(l.lock().await),
            None => None,
        };

        let mut classified: Vec<(i64, ReceiveOnlyOutcome)> = Vec::with_capacity(events.len());
        for ev in &events {
            // Bound the inner decrypt loop too: a large (capped) batch of
            // crafted events must not blow past the deadline on a low-power
            // wake. Stopping here only advances the cursor over the prefix
            // decrypted so far; the rest re-fetch next sweep.
            if Instant::now() >= deadline {
                out.deadline_hit = true;
                break;
            }
            let secs = i64::try_from(ev.created_at.as_secs()).unwrap_or(i64::MAX);
            let outcome = circle_mgr.decrypt_receive_only(ev, &ngid, &own_hex);
            match outcome {
                ReceiveOnlyOutcome::Location => out.locations_applied += 1,
                ReceiveOnlyOutcome::CommitApplied => out.commits_applied += 1,
                ReceiveOnlyOutcome::AutoCommitStaged => out.auto_commits_staged += 1,
                ReceiveOnlyOutcome::Skipped => out.skipped_pending += 1,
            }
            classified.push((secs, outcome));
        }
        drop(gate_guard);

        if let Some(ms) = contiguous_prefix_cursor_ms(&classified) {
            if circle_mgr.advance_sync_cursor(&stream, ms).is_ok() {
                out.cursors_advanced += 1;
            }
        }
    }

    out
}

#[cfg(test)]
mod tests {
    use super::{contiguous_prefix_cursor_ms, ReceiveOnlyOutcome as O};

    #[test]
    fn advances_cursor_only_for_applied_outcomes() {
        assert!(O::Location.advances_cursor());
        assert!(O::CommitApplied.advances_cursor());
        assert!(!O::AutoCommitStaged.advances_cursor());
        assert!(!O::Skipped.advances_cursor());
    }

    #[test]
    fn cursor_stops_at_first_non_applied_event() {
        // [Loc@1, Loc@2, Skipped@3, Loc@4] → advance only to 2 (×1000 ms); the
        // un-applied event at 3 is never skipped past, so 3+4 re-fetch next time.
        let batch = [
            (1, O::Location),
            (2, O::Location),
            (3, O::Skipped),
            (4, O::Location),
        ];
        assert_eq!(contiguous_prefix_cursor_ms(&batch), Some(2_000));
    }

    #[test]
    fn cursor_advances_over_applied_commit_in_prefix() {
        let batch = [(5, O::Location), (6, O::CommitApplied)];
        assert_eq!(contiguous_prefix_cursor_ms(&batch), Some(6_000));
    }

    #[test]
    fn cursor_does_not_advance_when_first_event_is_unapplied() {
        // A group in regime 2 skips its first event (pending-commit gate) → no advance.
        assert_eq!(
            contiguous_prefix_cursor_ms(&[(9, O::Skipped), (10, O::Location)]),
            None
        );
        assert_eq!(
            contiguous_prefix_cursor_ms(&[(9, O::AutoCommitStaged)]),
            None
        );
    }

    #[test]
    fn empty_batch_does_not_advance() {
        assert_eq!(contiguous_prefix_cursor_ms(&[]), None);
    }
}
