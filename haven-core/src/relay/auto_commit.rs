//! Receive-side auto-commit publish resolution (Rule 13 / security F13).
//!
//! When a member leaves via `SendIntent::Leave`, a bare MIP-03 `SelfRemove`
//! proposal is published. A REMAINING member's engine schedules a jitter-delayed
//! (10–50 ms) auto-commit of that proposal; once it comes due, an `ingest` /
//! `advance_convergence` batch surfaces it as a
//! [`PublishWork::AutoPublish`] carrying the wrapped commit (`msg`) and a
//! [`PendingStateRef`]. Its contract is IDENTICAL to
//! [`PublishWork::GroupEvolution`] (publish-before-apply): the commit MUST be
//! published to the group's relays and confirmed ONLY after ≥1 relay OK-acks.
//! This mirrors the upstream reference consumer (`marmot-account`'s
//! `publish_pending`): publish `msg`, then `confirm_published` iff at least one
//! endpoint accepted it, else `publish_failed` — which for THESE commits keeps
//! the publish owed rather than discarding it (see "One rule" below).
//!
//! Optimistically confirming an auto-commit WITHOUT publishing it (the DM-3
//! stopgap) is a two-fold defect: (a) other remaining members never receive the
//! eviction commit, so their rosters diverge (a fork); (b) it applies a commit no
//! relay ever acknowledged, violating Rule 13.
//!
//! This module gives every RECEIVE path that owns a relay plane — the live-sync
//! engine loop ([`crate::relay::live_sync::processor`]) and the background
//! catch-up sweep ([`crate::relay::catchup`]) — ONE publish-then-confirm code
//! path over a pluggable [`AutoCommitPublisher`] (a nostr `Client` for live-sync,
//! the [`RelayManager`] for catch-up, a recording fake in tests). The foreground
//! poll path (`decrypt_location`) owns no relay handle, so it instead SURFACES the
//! pending auto-commit to its Dart caller (see
//! [`crate::circle::CircleManager::decrypt_location_collecting_commits`]).
//!
//! # Crash safety, and the one window that is NOT crash-safe
//!
//! Not confirming an auto-commit before it is published is crash-safe for every
//! commit that removes NO member: the staged commit persists to `OpenMLS`'s
//! `PendingCommit`, and if the process dies before `confirm_published` /
//! `publish_failed`, the engine's hydrate path clears it (treated as
//! publish-failed) and emits `GroupEvent::PendingCommitRecovered`, prompting a
//! resync. Confirming early (the old behaviour) is what would have been unsafe.
//!
//! **A receive-side auto-commit is not in that class.** It is always
//! removal-bearing — it commits a peer's `SelfRemove` — and hydrate's recovery
//! deliberately short-circuits on exactly that: `staged_removes_member`
//! matching `Proposal::Remove | Proposal::SelfRemove` skips the whole emit block
//! (`cgka-engine/src/engine.rs:820-828` at the pinned rev `e391adc`, with the
//! upstream comment explaining why — rolling back a removal would re-add the
//! departed member and fork convergence). So a process killed between STAGE and
//! resolution leaves the group with a staged commit no hydrate will clear, no
//! `PendingCommitRecovered`, and every later send refused: the OD4-c wedge.
//!
//! That is what [`ReceiveAutoCommitPolicy::DeferToForeground`] exists for — and
//! why NO plane here ever rolls one back.
//!
//! # One rule, two halves, every plane
//!
//! 1. **Record the obligation before opening the window.** Every function below
//!    calls [`CircleManager::owe_removal_publish`] before it publishes (or
//!    instead of publishing), so a process killed mid-publish leaves a durable
//!    per-circle row and the next foreground LIVE-SYNC open REPORTS the wedge
//!    (only live-sync reaches the reporter; a flag-off build writes the row and
//!    reads it never). Before this,
//!    only the burst's park wrote that row, which left the detector blind to
//!    every other plane's crash window.
//! 2. **Never roll one back.** An unacked publish keeps the obligation owed. The
//!    decision lives in [`CircleManager::publish_failed`] rather than in each
//!    caller, so it also covers the two Dart planes that resolve a surfaced
//!    auto-commit over the FFI (the foreground poll and the Android foreground
//!    service's publish cycle).
//!
//! # Rule 15, for every diagnostic in this module
//!
//! NEVER add a `log_alias` circle handle to the ladder's lines. Each is a
//! per-circle ACTIVITY signal the moment one is attached — "circle#a91f3c
//! stopped at the cap" says a leave cascade is running there — which is exactly
//! what a handle is supposed to make unsayable. Magnitudes stay bucketed and
//! instants stay absent for the same reason; a later "just add the circle for
//! debuggability" is a review stop, not a judgement call.

use std::collections::{HashSet, VecDeque};
use std::future::Future;
use std::pin::Pin;
use std::time::Duration;

use nostr::Event;

use crate::circle::{CircleManager, CommitToPublish, DecryptedIngest};
use crate::log_alias::bucket;
use crate::nostr::mls::types::{PendingStateRef, PublishWork};
use crate::nostr::mls::SessionManager;
use crate::relay::RelayManager;

/// How many times a receive path re-advances a group that stays pending — a
/// jitter-delayed `SelfRemove` auto-commit whose due time has not yet arrived —
/// before yielding for this pass.
///
/// The engine schedules a peer's `SelfRemove` auto-commit with a small
/// deterministic jitter (≤50 ms) so remaining members don't all commit at once,
/// and it re-queues the group for convergence until that wall-clock due time
/// passes. A receive path that advanced the group only ONCE would drain it out of
/// the engine's pending set and strand the eviction commit (it never surfaces to
/// be published). This bounded re-tick (with [`CONVERGENCE_RETICK_DELAY`]) covers
/// the jitter window with margin while capping how long one leave blocks a
/// receive pass (~ `MAX_CONVERGENCE_RETICKS` × delay).
pub const MAX_CONVERGENCE_RETICKS: usize = 6;

/// Wall-clock pause between convergence re-ticks.
///
/// The engine's auto-commit due time is real-time
/// ([`elapsed`](std::time::Instant::elapsed)-based), so re-advancing needs a real
/// delay to let the jitter elapse.
pub const CONVERGENCE_RETICK_DELAY: Duration = Duration::from_millis(20);

/// A relay plane that can publish a receive-side auto-commit (`kind:445`) and
/// report whether at least one relay OK-acked it.
///
/// Rule 13: "acked" MUST mean a relay returned OK, never merely "sent". Any
/// transport error or a zero-ack outcome resolves to `false`, so the caller takes
/// the fail rung (never an optimistic apply).
///
/// The method returns a boxed future rather than using `async fn` in the trait so
/// the trait stays object-safe (`dyn AutoCommitPublisher`) without pulling in the
/// `async-trait` dependency.
pub trait AutoCommitPublisher: Send + Sync {
    /// Publishes `event` to `relays`; resolves to `true` iff ≥1 relay OK-acked.
    fn publish_auto_commit<'a>(
        &'a self,
        event: &'a Event,
        relays: &'a [String],
    ) -> Pin<Box<dyn Future<Output = bool> + Send + 'a>>;
}

/// The background catch-up sweep publishes auto-commits through the same
/// [`RelayManager`] it fetches with — `publish_event` already enforces the
/// ≥1-relay OK-ack contract via [`crate::relay::PublishResult::is_success`].
impl AutoCommitPublisher for RelayManager {
    fn publish_auto_commit<'a>(
        &'a self,
        event: &'a Event,
        relays: &'a [String],
    ) -> Pin<Box<dyn Future<Output = bool> + Send + 'a>> {
        Box::pin(async move {
            self.publish_event(event, relays)
                .await
                .is_ok_and(|result| result.is_success())
        })
    }
}

/// The live-sync engine publishes auto-commits over its OWN already-connected
/// sockets (the circle's group relays are already in this client's pool from the
/// `#h` subscription). `send_event_to` reports the acking relays in
/// `Output.success`; a non-empty set is a ≥1-relay OK-ack.
impl AutoCommitPublisher for nostr_sdk::Client {
    fn publish_auto_commit<'a>(
        &'a self,
        event: &'a Event,
        relays: &'a [String],
    ) -> Pin<Box<dyn Future<Output = bool> + Send + 'a>> {
        Box::pin(async move {
            match self
                .send_event_to(relays.iter().map(String::as_str), event)
                .await
            {
                Ok(output) => !output.success.is_empty(),
                Err(_) => false,
            }
        })
    }
}

/// Publishes `event` to `relays` and resolves `pending` per Rule 13.
///
/// [`CircleManager::confirm_published`] ONLY on a ≥1-relay OK-ack, else
/// [`CircleManager::publish_failed`]. Returns whether it confirmed.
///
/// Everything short of an OK-ack — a relay that answered `OK: false`, a send
/// the relay never acknowledged, a transport error, or a relay set that cannot
/// be published to at all — takes the fail rung, because each of them leaves the
/// group at an epoch its peers never received. An empty `relays` can never
/// produce an ack, so it fails closed without touching the transport.
///
/// For a removal-bearing receive-side auto-commit that fail rung is NOT a
/// rollback: [`CircleManager::publish_failed`] keeps the publish owed, because
/// discarding the eviction is a permanent silent drop of the removal. The caller
/// must have recorded the obligation first
/// ([`CircleManager::owe_removal_publish`]) or that guarantee does not apply to
/// its commit.
///
/// This is the RECEIVE path's copy of the decision, and its only non-test caller
/// is the ladder below ([`resolve_receive_publish_work_with_policy`]). The
/// send-side staged commits (`create_circle`, `add_members_with_welcomes`,
/// `remove_members`, `update_circle_relays`) are resolved from Dart over the
/// FFI, which calls `confirm_published` / `publish_failed` directly, so they
/// carry this identical contract BY HAND — a change to the rule here has to be
/// mirrored there.
///
/// Returns the resolution's OWN batch alongside the verdict. Resolving a staged
/// commit ends in the engine's replay, which hands back every peer location that
/// arrived behind it, the NEXT eviction in a cascade, and any re-proposed
/// leave — all delivered at most once. An `Err` resolution yields an empty
/// batch: the core has already folded and persisted whatever it could recover
/// from it (see [`CircleManager::confirm_published`]).
pub async fn publish_then_resolve(
    circle: &CircleManager,
    publisher: &dyn AutoCommitPublisher,
    event: &Event,
    relays: &[String],
    pending: PendingStateRef,
) -> (bool, DecryptedIngest) {
    let acked = !relays.is_empty() && publisher.publish_auto_commit(event, relays).await;
    let resolved = if acked {
        circle.confirm_published(pending).await
    } else {
        circle.publish_failed(pending).await
    };
    (acked, resolved.unwrap_or_default())
}

/// The receive-side [`PublishWork`] of one batch, resolved per Rule 13.
///
/// Publishes any auto-commit through `publisher` before confirming, and LOOPS
/// until nothing is left to resolve.
///
/// [`resolve_receive_publish_work_with_policy`] under
/// [`ReceiveAutoCommitPolicy::Publish`]; see there for the ladder.
pub async fn resolve_receive_publish_work(
    circle: &CircleManager,
    publisher: &dyn AutoCommitPublisher,
    work: &[PublishWork],
) -> DecryptedIngest {
    resolve_receive_publish_work_with_policy(
        circle,
        publisher,
        work,
        ReceiveAutoCommitPolicy::Publish,
    )
    .await
    .1
}

/// How many commits one call of the resolve ladder resolves before it stops.
///
/// A RUNAWAY guard, not a business bound: each resolution consumes one scheduled
/// `SelfRemove`, of which there is at most one per member per epoch, so the
/// normal path runs to an empty worklist long before this. Reaching it means the
/// engine or this loop is misbehaving — and the un-run commits are reported, not
/// abandoned (see the cap disposition below).
///
/// It bounds the WORK one call does, not the DEPTH of the cascade it follows.
/// Those are not the same thing, because an engine batch is not single-group:
/// one drain can surface an eviction for every circle this device holds, so a
/// depth bound would let a single call publish and confirm unboundedly many
/// commits inside one background wake and still call itself bounded.
///
/// Sixteen clears that breadth because the breadth is bounded elsewhere: an
/// account holds at most `kMaxCirclesPerAccount` (10) circles, refused at
/// `createCircle` and `acceptInvitation`
/// (`haven/lib/src/services/nostr_circle_service.dart`), so a batch in which
/// EVERY circle loses a member still stays under this. Raise that bound past
/// this one and an ordinary mass-leave reaches the cap — where, in a
/// short-lived isolate, the park is terminal: only a foreground live-sync burst
/// redeems it.
pub const RESOLVE_RUNAWAY_CAP: usize = 16;

/// [`resolve_receive_publish_work`] under `policy`.
///
/// Only [`PublishWork::AutoPublish`] carries a pending ref on the RECEIVE path
/// (send-side `GroupCreated` / `GroupEvolution` originate from `send`, never from
/// inbound processing). For each auto-commit: convert the wrapped commit to a
/// signed `kind:445`, RECORD the publish this device now owes for it, publish it
/// to the group's relays (resolved from the commit's own `#h`, so a batch that
/// mixes groups still routes each correctly), then
/// [`CircleManager::confirm_published`] ONLY on a ≥1-relay OK-ack — else the
/// obligation stands and the next foreground pass retries it.
/// `ApplicationMessage` carries no pending ref, and a `Proposal` surfaced by a
/// resolution comes back in [`DecryptedIngest::proposals`] for the plane to
/// publish (it opens no publish-before-apply window of its own).
///
/// The record is written BEFORE the publish and not after it fails, because the
/// failure this plane cannot observe is the interesting one: a process killed
/// between SEND and OK leaves a staged removal-bearing commit MDK's hydrate will
/// not clear, and the durable row is the only thing that survives to say so.
///
/// # Why it is a LADDER
///
/// Confirming one eviction ends in the engine's replay, which can apply the next
/// leaver's proposal and stage the next eviction. Running only the batch it was
/// handed would leave that one staged and unpublished for as long as it takes
/// some other pass to notice — which, in a plane whose session does not outlive
/// the wake, is for ever. So each resolution's own `auto_commits` go back on the
/// worklist and the loop runs until the worklist is EMPTY. A `resolved` set makes
/// the termination argument local: one ref is resolved at most once per call, and
/// each engine cycle consumes one scheduled `SelfRemove`, of which there is at
/// most one per member per epoch. A ref handed in twice — by a caller or by a
/// re-surfacing bug — is skipped rather than published twice, because the second
/// resolution would apply a commit the first already merged.
///
/// # At the cap
///
/// Nothing is rolled back and nothing dangles: every un-run commit is PARKED
/// ([`CircleManager::defer_removal_commit`] — the same durable row +
/// in-memory ref an ordinary deferral writes), and ONE bucketed warn reports the
/// set. A commit whose obligation cannot be recorded at all is left STAGED rather
/// than discarded, because this device's projected roster keeps the leaver out
/// either way and only a rollback puts them back. In a short-lived isolate the
/// in-memory ref dies with the session and the durable row surfaces at
/// [`CircleManager::orphaned_removal_deferrals`] on the next foreground open —
/// the honest report of a runaway bug, never of a normal leave.
///
/// Returns how many auto-commits were PARKED by the policy (not by the cap), so
/// a caller can tell a deferral from a publish without re-deriving the
/// classification, plus the folded work every resolution handed back.
///
/// A park that cannot be recorded falls back to publishing that item: an
/// un-recorded deferral is the silent wedge the deferral exists to prevent, so
/// it fails towards the behaviour that at least lands the removal. That fallback
/// publish has no obligation behind it either, so its own no-ack rung CAN discard
/// the eviction — the one residual, and the reason the record is attempted first
/// rather than as a consolation.
///
/// The one remaining rollback is a commit whose wrapped transport message cannot
/// be turned into an event at all. There is then nothing to publish AND nothing
/// to park, and leaving it staged would freeze the circle's sends with no
/// obligation recorded, so it is rolled back — the same choice
/// `CircleManager::collect_deferred_work` makes for the same case. It is
/// unreachable in practice: the engine built that message a moment earlier.
pub async fn resolve_receive_publish_work_with_policy(
    circle: &CircleManager,
    publisher: &dyn AutoCommitPublisher,
    work: &[PublishWork],
    policy: ReceiveAutoCommitPolicy,
) -> (usize, DecryptedIngest) {
    let mut out = DecryptedIngest::default();
    let mut worklist: VecDeque<CommitToPublish> = VecDeque::new();
    let mut resolved: HashSet<PendingStateRef> = HashSet::new();
    let mut deferred = 0_usize;

    for item in work {
        match item {
            PublishWork::AutoPublish { msg, pending } => {
                match SessionManager::transport_message_to_event(msg) {
                    Ok(commit_event) => worklist.push_back(CommitToPublish {
                        commit_event,
                        pending: *pending,
                    }),
                    Err(_) => absorb(
                        &mut out,
                        &mut worklist,
                        circle.publish_failed(*pending).await,
                    ),
                }
            }
            // Defensive: a receive-side batch never carries these, but if one
            // ever appeared, NEVER optimistically confirm (Rule 13) — roll it
            // back so no pending ref leaks and no unpublished commit is applied.
            PublishWork::GroupCreated { pending, .. }
            | PublishWork::GroupEvolution { pending, .. } => {
                absorb(
                    &mut out,
                    &mut worklist,
                    circle.publish_failed(*pending).await,
                );
            }
            PublishWork::ApplicationMessage { .. } | PublishWork::Proposal { .. } => {}
        }
    }

    while let Some(commit) = worklist.pop_front() {
        if resolved.contains(&commit.pending) {
            log::warn!("the resolve ladder saw a pending ref twice; the repeat is ignored");
            continue;
        }
        if resolved.len() == RESOLVE_RUNAWAY_CAP {
            // This one and everything still queued behind it stand owed.
            worklist.push_front(commit);
            log::warn!(
                "resolve ladder stopped at the runaway cap; {} commit(s) stand owed",
                bucket(worklist.len())
            );
            for commit in std::mem::take(&mut worklist) {
                if circle.defer_removal_commit(commit).is_some() {
                    log::warn!(
                        "an un-run eviction commit is left staged with no recordable obligation"
                    );
                }
            }
            break;
        }
        resolved.insert(commit.pending);
        let commit = match policy {
            // Parked: `None` back. Otherwise the commit comes back unparked
            // (unknown circle, or the durable write failed) and falls through
            // to the Rule-13 ladder rather than staying staged with nothing
            // recording the debt.
            ReceiveAutoCommitPolicy::DeferToForeground => {
                let Some(commit) = circle.defer_removal_commit(commit) else {
                    deferred += 1;
                    continue;
                };
                commit
            }
            ReceiveAutoCommitPolicy::Publish => {
                // Write-ahead: this plane is about to open a
                // publish-before-apply window it may not survive, and it is
                // the only plane that can then resolve this ref. `false`
                // means the obligation could not be recorded at all, which
                // is worth saying out loud — it is the one shape in which
                // the fail rung below can still discard the eviction.
                if !circle.owe_removal_publish(&commit) {
                    log::warn!(
                        "receive-side eviction commit published with no recorded \
                             obligation: an unacked publish will roll it back"
                    );
                }
                commit
            }
        };
        // Resolve the group's relays from the commit's own `#h`
        // (nostr_group_id). No relays / unknown group ⇒ cannot publish ⇒ the
        // fail rung (which for this commit keeps the publish owed, never
        // discards it).
        let relays = circle
            .relays_for_commit_event(&commit.commit_event)
            .unwrap_or_default();
        let (_acked, batch) = publish_then_resolve(
            circle,
            publisher,
            &commit.commit_event,
            &relays,
            commit.pending,
        )
        .await;
        absorb_batch(&mut out, &mut worklist, batch);
    }
    (deferred, out)
}

/// Folds a resolution's `Result` into the ladder's output, queueing whatever it
/// surfaced. An `Err` carries nothing: the core folded it already.
fn absorb(
    out: &mut DecryptedIngest,
    worklist: &mut VecDeque<CommitToPublish>,
    batch: crate::circle::Result<DecryptedIngest>,
) {
    absorb_batch(out, worklist, batch.unwrap_or_default());
}

/// [`absorb`] over an already-unwrapped batch.
fn absorb_batch(
    out: &mut DecryptedIngest,
    worklist: &mut VecDeque<CommitToPublish>,
    batch: DecryptedIngest,
) {
    out.results.extend(batch.results);
    out.proposals.extend(batch.proposals);
    worklist.extend(batch.auto_commits);
}

/// Never confirms anything in a receive-side batch: an eviction auto-commit is
/// PARKED as an owed obligation, and any other staged commit is rolled back.
///
/// The fail-closed path for a processor with NO relay plane wired. Without a
/// publisher the commit cannot be broadcast, so applying it would fork the group
/// (Rule 13: never apply an unpublished commit) — but the two staged shapes need
/// opposite treatment, and giving them the same one is what this function did
/// wrong while it was called `rollback_receive_publish_work`.
///
/// # Why an eviction is parked and not rolled back
///
/// A rollback DROPS the removal, permanently and silently. Verified at the pinned
/// MDK rev `e391adc`, by source and by experiment: the engine removes its
/// in-memory `scheduled_self_remove_auto_commits` entry BEFORE staging,
/// `do_publish_failed` does not re-arm it, and a redelivery of the proposal
/// short-circuits to `IngestOutcome::Buffered` off its durable `Created`
/// `MessageRecord` without ever reaching the arm that reschedules. No later
/// `advance_convergence`, no re-ingest of the same proposal, no outbound send and
/// no process restart re-derives it. The leaver stays in the circle — still able
/// to derive its keys — until some unrelated commit moves the epoch and its own
/// client re-proposes.
///
/// And it buys nothing in exchange. `do_publish_failed` clears the staged COMMIT
/// but not the stored PROPOSAL it was built from, and `OpenMLS`'s
/// `create_message` refuses while the proposal store is non-empty: the next
/// `encrypt_location` fails with `GroupStateError(PendingProposal)` until some
/// commit merges and empties the store. So a rollback trades a `PendingPublish`
/// refusal for a `PendingProposal` refusal AND loses the removal.
///
/// Parking keeps the removal owed and makes the wedge visible
/// ([`CircleManager::owe_removal_publish`]). If even the park cannot be recorded
/// the commit is left STAGED rather than discarded — this device's projected
/// roster keeps the leaver out either way, and only the rollback puts them back.
///
/// Returns the folded work of every rollback it had to make — the only batches
/// this path can produce, since nothing here is ever confirmed.
pub async fn park_or_rollback_receive_publish_work(
    circle: &CircleManager,
    work: &[PublishWork],
) -> DecryptedIngest {
    let mut out = DecryptedIngest::default();
    // Nothing here CONFIRMS — but a rollback replays at the original epoch and
    // its fold drains convergence, so a batch coming back from one really can
    // carry the next staged commit. That is why the queue is handed back below
    // rather than asserted empty: deleting that line would drop a live
    // `PendingStateRef` in the one plane that has no relay to resolve it with.
    let mut rolled_back_commits: VecDeque<CommitToPublish> = VecDeque::new();
    for item in work {
        match item {
            PublishWork::AutoPublish { msg, pending } => {
                // A commit whose transport message will not serialize can be
                // neither published nor parked, so it is the one staged eviction
                // still rolled back: there is no event to owe a publish for.
                match SessionManager::transport_message_to_event(msg) {
                    Ok(commit_event) => {
                        let commit = crate::circle::CommitToPublish {
                            commit_event,
                            pending: *pending,
                        };
                        if circle.defer_removal_commit(commit).is_some() {
                            log::warn!(
                                "eviction commit left staged: no relay plane and no \
                                 recordable obligation"
                            );
                        }
                    }
                    Err(_) => absorb(
                        &mut out,
                        &mut rolled_back_commits,
                        circle.publish_failed(*pending).await,
                    ),
                }
            }
            PublishWork::GroupCreated { pending, .. }
            | PublishWork::GroupEvolution { pending, .. } => absorb(
                &mut out,
                &mut rolled_back_commits,
                circle.publish_failed(*pending).await,
            ),
            PublishWork::ApplicationMessage { .. } | PublishWork::Proposal { .. } => {}
        }
    }
    out.auto_commits.extend(rolled_back_commits);
    out
}

/// What a receive plane does with a staged auto-commit it has just been handed.
///
/// The variant is chosen by the plane's LIFECYCLE, not by the work item: a
/// background burst and a foreground session run the same processor over the
/// same engine, and the only thing that differs is whether the OS may end the
/// wake window mid-publish. Making it a value the session sets means the scoping
/// is a state read, never a comment.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReceiveAutoCommitPolicy {
    /// Publish now, confirm on a ≥1-relay OK-ack, roll back otherwise
    /// (Rule 13). What a FOREGROUND session does, unchanged.
    Publish,
    /// Do not publish and do not resolve: park the commit as a durable
    /// per-circle obligation for the next FOREGROUND pass
    /// ([`CircleManager::defer_removal_commit`]).
    ///
    /// What a BACKGROUND burst does (owner decision OD4-c, option (iv)): a burst
    /// must not open a publish-before-apply window for a removal-bearing commit,
    /// because the OS may end its wake window mid-publish and MDK's hydrate
    /// deliberately does not recover a removal-bearing staged commit.
    DeferToForeground,
}
