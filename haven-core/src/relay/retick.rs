//! How long a receive pass waits for the engine's own deadlines in place.
//!
//! Under MDK's pinned convergence policy v1 a received commit or proposal is
//! `Buffered` until its convergence pass closes, `V1_SETTLEMENT_QUIESCENCE_MS`
//! after the last convergence-relevant input, and a peer's `SelfRemove`
//! eviction falls due a small jitter after that. Neither is signalled in the
//! ingest's own effects: the engine reports them only as cutoffs
//! ([`SessionManager::receive_retick_after`]). A pass that advanced once would
//! strand them until an unrelated later event.
//!
//! # Rule 15
//!
//! NEVER add a `log_alias` circle handle to a line about a re-tick. Each is a
//! per-circle ACTIVITY signal the moment one is attached — "circle#a91f3c
//! re-ticked six times" says a leave cascade is running there — which is
//! exactly what a handle is supposed to make unsayable.

use std::time::Duration;

use crate::nostr::mls::types::GroupId;
use crate::nostr::mls::SessionManager;

/// How many times a receive path re-advances a group the engine still owes a
/// deadline before yielding for this pass.
///
/// The bound on how long one membership change holds a receive pass: a
/// permanent bound, not a stop-gap. It caps the in-place waits for a deadline the engine announces
/// for good — a kill-cut eviction falls due 10–50 ms on (T-KILL-WINDOW) —
/// and, times the pinned quiescence, is the fold's budget
/// (`relay::fanout::FOLD_BUDGET_MS`). MDK's own host spins at a 10 ms clamp
/// instead (`marmot-app` `client/sync.rs`, T-SCHEDULER).
pub const MAX_CONVERGENCE_RETICKS: usize = 6;

/// The furthest-off engine deadline a receive pass waits for in place.
///
/// One pinned quiescence window, which covers a pass's close and the
/// `SelfRemove` jitter after it. A later deadline — a pass pushed out by a
/// stream of inputs, a deferred-peel retry — is left for the next wake.
pub const RECEIVE_RETICK_HORIZON: Duration =
    Duration::from_millis(cgka_engine::canonicalization::V1_SETTLEMENT_QUIESCENCE_MS);

/// The groups a receive pass re-ticks next and how long it waits first.
///
/// Every group the last batch left owing an advance, plus every group it just
/// advanced that the engine still owes a deadline within
/// [`RECEIVE_RETICK_HORIZON`]. The wait is the nearest such deadline, or none.
pub async fn next_receive_retick(
    session: &SessionManager,
    advanced: &[GroupId],
    mut owing: Vec<GroupId>,
) -> (Vec<GroupId>, Duration) {
    // A group whose eviction this pass just rolled back owes nothing more to
    // it while its epoch stands: the engine re-arms that eviction for its next
    // advance, not for this pass.
    let mut kept = Vec::with_capacity(owing.len());
    for gid in owing {
        if !session.eviction_retick_held(&gid).await {
            kept.push(gid);
        }
    }
    owing = kept;
    let mut deadlines = Vec::with_capacity(advanced.len());
    for gid in advanced {
        if let Some(after) = session.receive_retick_after(gid).await {
            deadlines.push(after);
            if !owing.contains(gid) {
                owing.push(gid.clone());
            }
        }
    }
    (owing, deadlines.into_iter().min().unwrap_or(Duration::ZERO))
}

/// Owes the next plane that drains (`SessionManager::take_owed_advance`)
/// every group a drain leaves unfinished: each one `pending` still names —
/// cut by the drain's deadline or out of the deadlines it may wait out — and
/// each one it advanced that the engine still owes work it named no deadline
/// for (`SessionManager::still_owes_advance`): an advance whose pass was not
/// yet settled returns without naming its group again.
pub(crate) async fn owe_unfinished(
    session: &SessionManager,
    mut pending: Vec<GroupId>,
    advanced: &[GroupId],
) {
    for group_id in advanced {
        if !pending.contains(group_id) && session.still_owes_advance(group_id).await {
            pending.push(group_id.clone());
        }
    }
    session.owe_advance(&pending);
}
