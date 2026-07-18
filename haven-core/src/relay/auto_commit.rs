//! Receive-side auto-commit publish resolution (Rule 13 / security F13).
//!
//! When a member leaves via `SendIntent::Leave`, a bare MIP-03 `SelfRemove`
//! proposal is published. A REMAINING member's engine schedules a jitter-delayed
//! (10–50 ms) auto-commit of that proposal; once it comes due, an `ingest` /
//! `advance_convergence` batch surfaces it as a
//! [`PublishWork::AutoPublish`] carrying the wrapped commit (`msg`) and a
//! [`PendingStateRef`]. Its contract is IDENTICAL to
//! [`PublishWork::GroupEvolution`] (publish-before-apply): the commit MUST be
//! published to the group's relays and confirmed ONLY after ≥1 relay OK-acks,
//! else rolled back. This mirrors the upstream reference consumer
//! (`marmot-account`'s `publish_pending`): publish `msg`, then `confirm_published`
//! iff at least one endpoint accepted it, else `publish_failed`.
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
//! # Crash safety
//!
//! Not confirming an auto-commit before it is published is crash-safe by design:
//! the staged commit persists to `OpenMLS`'s `PendingCommit`, and if the process
//! dies before `confirm_published` / `publish_failed`, the engine's hydrate path
//! clears it (treated as publish-failed) and emits
//! `GroupEvent::PendingCommitRecovered`, prompting a resync. Confirming early
//! (the old behaviour) is what would have been unsafe.

use std::future::Future;
use std::pin::Pin;
use std::time::Duration;

use nostr::Event;

use crate::circle::CircleManager;
use crate::nostr::mls::types::PublishWork;
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
/// transport error or a zero-ack outcome resolves to `false` so the caller rolls
/// the staged commit back (never an optimistic apply).
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

/// Resolves the receive-side [`PublishWork`] from an `ingest` /
/// `advance_convergence` batch per Rule 13, publishing any auto-commit through
/// `publisher` before confirming.
///
/// Only [`PublishWork::AutoPublish`] carries a pending ref on the RECEIVE path
/// (send-side `GroupCreated` / `GroupEvolution` originate from `send`, never from
/// inbound processing). For each auto-commit: convert the wrapped commit to a
/// signed `kind:445`, publish it to the group's relays (resolved from the
/// commit's own `#h`, so a batch that mixes groups still routes each correctly),
/// then [`CircleManager::confirm_published`] ONLY on a ≥1-relay OK-ack, else
/// [`CircleManager::publish_failed`]. `ApplicationMessage` / `Proposal` carry no
/// pending ref and are routed/surfaced elsewhere.
pub async fn resolve_receive_publish_work(
    circle: &CircleManager,
    publisher: &dyn AutoCommitPublisher,
    work: &[PublishWork],
) {
    for item in work {
        let (msg, pending) = match item {
            PublishWork::AutoPublish { msg, pending } => (msg, *pending),
            // Defensive: a receive-side batch never carries these, but if one ever
            // appeared, NEVER optimistically confirm (Rule 13) — roll it back so no
            // pending ref leaks and no unpublished commit is applied.
            PublishWork::GroupCreated { pending, .. }
            | PublishWork::GroupEvolution { pending, .. } => {
                let _ = circle.publish_failed(*pending).await;
                continue;
            }
            PublishWork::ApplicationMessage { .. } | PublishWork::Proposal { .. } => continue,
        };

        // Convert the wrapped commit to a signed kind:445 event. A conversion
        // failure means we cannot publish it, so fail closed (roll back).
        let Ok(event) = SessionManager::transport_message_to_event(msg) else {
            let _ = circle.publish_failed(pending).await;
            continue;
        };

        // Resolve the group's relays from the commit's own `#h` (nostr_group_id).
        // No relays / unknown group ⇒ cannot publish ⇒ roll back (fail closed).
        let relays = circle.relays_for_commit_event(&event).unwrap_or_default();
        let acked = !relays.is_empty() && publisher.publish_auto_commit(&event, &relays).await;
        if acked {
            let _ = circle.confirm_published(pending).await;
        } else {
            let _ = circle.publish_failed(pending).await;
        }
    }
}

/// Rolls back — never confirms — every staged commit in a receive-side batch.
///
/// The fail-closed path for a processor with NO relay plane wired: without a
/// publisher the auto-commit cannot be broadcast, so applying it would fork the
/// group. Rolling it back (Rule 13: never apply an unpublished commit) returns the
/// group to its prior stable epoch; the eviction re-derives when a relay-backed
/// path (live-sync / catch-up) next processes the leaver's proposal.
pub async fn rollback_receive_publish_work(circle: &CircleManager, work: &[PublishWork]) {
    for item in work {
        if let PublishWork::AutoPublish { pending, .. }
        | PublishWork::GroupCreated { pending, .. }
        | PublishWork::GroupEvolution { pending, .. } = item
        {
            let _ = circle.publish_failed(*pending).await;
        }
    }
}
