//! The group-event processor — the receive engine's ingest loop.
//!
//! For each incoming `kind:445`, the processor feeds the transport message to
//! the Dark Matter engine (`SessionManager::process_event`), which owns
//! convergence, out-of-order sequencing (buffering future-epoch messages), and
//! stale/duplicate rejection. The processor then drains the engine's emitted
//! `GroupEvent`s onto the fan-out bus and advances the per-circle cursor — but
//! **only** when the engine reports `Processed` or `Stale`, never on `Buffered`
//! (so a future-epoch message is re-fed until it applies; the engine also
//! persists it durably).
//!
//! The hand-rolled settle-window / regime gate that used to live here is gone
//! (plan §5.3/§5.4): the engine's stored convergence replaces it.
//!
//! # Per-circle cursor
//!
//! Each circle gets its own group cursor via `group_445:{hex(nostr_group_id)}`,
//! so a busy circle's cursor advance cannot bury a quiet co-multiplexed
//! circle's un-applied commit.

use std::sync::Arc;

use nostr::{Event, JsonUtil};

use crate::circle::CircleManager;
use crate::nostr::mls::types::{GroupId, IngestOutcome, LocationMessageResult, PublishWork};
use crate::nostr::mls::SessionManager;
use crate::relay::auto_commit::{
    resolve_receive_publish_work, rollback_receive_publish_work, AutoCommitPublisher,
    CONVERGENCE_RETICK_DELAY, MAX_CONVERGENCE_RETICKS,
};

use super::event::{LiveSyncEvent, SyncStatusReason};
use super::event_bus::EventBus;

/// Per-circle group-cursor stream key (a distinct stream per
/// `hex(nostr_group_id)`).
#[must_use]
pub fn group_cursor_stream(group_id_hex: &str) -> String {
    format!("{}:{group_id_hex}", crate::relay::cursor::STREAM_GROUP_445)
}

/// What the processor did with one group event (returned for observability and
/// testing; the side effects — bus emit, cursor advance — are already applied).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GroupProcessOutcome {
    /// The engine applied the message (or it was stale/terminal); the per-circle
    /// cursor advanced.
    Processed {
        /// Whether the per-circle group cursor advanced.
        advanced_cursor: bool,
    },
    /// The engine buffered the message for a future epoch (out-of-order). The
    /// cursor did NOT advance — the event is re-fed until it applies. The engine
    /// also persists it durably, so nothing is lost across a restart.
    Buffered,
    /// The message could not be ingested at all (hard failure); cursor
    /// unchanged.
    Unprocessable,
}

/// The receive engine's group/inbox event processor.
///
/// Holds the single MLS-state owner ([`CircleManager`], whose one process-global
/// [`SessionManager`] satisfies Rule 14) and the fan-out bus.
pub struct EngineProcessor {
    circle: Arc<CircleManager>,
    bus: EventBus,
    /// The relay plane used to publish receive-side auto-commits (a peer
    /// `SelfRemove` eviction) before confirming them (Rule 13). `None` for a bare
    /// processor with no relay plane wired — it then rolls such commits back
    /// (never an optimistic apply). The live-sync session installs the engine
    /// `Client` here via [`Self::with_publisher`].
    publisher: Option<Arc<dyn AutoCommitPublisher>>,
}

impl EngineProcessor {
    /// Creates a processor over the shared MLS state and bus, with NO relay plane.
    ///
    /// A receive-side auto-commit surfaced through this processor is rolled back
    /// (fail closed, Rule 13) since it cannot be published. Use
    /// [`Self::with_publisher`] for the live-sync path.
    #[must_use]
    pub const fn new(circle: Arc<CircleManager>, bus: EventBus) -> Self {
        Self {
            circle,
            bus,
            publisher: None,
        }
    }

    /// Creates a processor wired to a relay `publisher`, so a receive-side
    /// auto-commit (peer `SelfRemove` eviction) is published to the group's relays
    /// and confirmed ONLY after a ≥1-relay OK-ack (Rule 13 / security F13).
    #[must_use]
    pub fn with_publisher(
        circle: Arc<CircleManager>,
        bus: EventBus,
        publisher: Arc<dyn AutoCommitPublisher>,
    ) -> Self {
        Self {
            circle,
            bus,
            publisher: Some(publisher),
        }
    }

    /// Processes one incoming `kind:445` for `nostr_group_id` (its routed `#h`).
    ///
    /// Ingests via the engine, routes the drained events, advances stored
    /// convergence for any pending group, resolves any engine publish work, and
    /// gates the per-circle cursor on the ingest outcome (advance on
    /// `Processed`/`Stale`, never on `Buffered`).
    #[cfg_attr(test, allow(clippy::missing_panics_doc))]
    pub async fn process_group_event(
        &self,
        event: &Event,
        nostr_group_id: &[u8],
    ) -> GroupProcessOutcome {
        // Test-only fault-injection seam: a sentinel content string panics here
        // so the worker's panic-isolation test proves one adversarial event
        // never blinds the receive path. Compiled out of non-test builds.
        #[cfg(test)]
        #[allow(clippy::manual_assert)]
        if event.content == "__panic_for_test__" {
            panic!("injected decrypt panic (test seam)");
        }

        let group_hex = hex::encode(nostr_group_id);
        let created_at_secs = i64::try_from(event.created_at.as_secs()).unwrap_or(i64::MAX);

        let Ok(ingest) = self.circle.session().process_event(event).await else {
            self.bus.send(LiveSyncEvent::Status {
                reason: SyncStatusReason::Unprocessable,
            });
            return GroupProcessOutcome::Unprocessable;
        };

        // Route the drained events, then release any stored convergence + route
        // those, resolving engine publish work as we go.
        self.route_events(&ingest.effects.events, nostr_group_id, created_at_secs);
        self.resolve_publish_work(&ingest.effects.publish).await;
        self.drain_convergence(
            &ingest.effects.pending_convergence,
            nostr_group_id,
            created_at_secs,
        )
        .await;

        // Cursor gate: advance on Processed/Stale (the engine handled it), never
        // on Buffered (future-epoch; re-fed until it applies — the engine also
        // persists it durably so nothing is lost on restart).
        match ingest.outcome {
            IngestOutcome::Buffered { .. } => GroupProcessOutcome::Buffered,
            IngestOutcome::Processed | IngestOutcome::Stale { .. } => {
                let ms = created_at_secs.saturating_mul(1000);
                // Best-effort: a cursor write failure must not drop the delivered
                // event; the cursor re-advances on the next applied event.
                let _ = self
                    .circle
                    .advance_sync_cursor(&group_cursor_stream(&group_hex), ms);
                GroupProcessOutcome::Processed {
                    advanced_cursor: true,
                }
            }
        }
    }

    /// Drains stored convergence for the pending groups, re-ticking a group that
    /// stays pending until its jitter-delayed `SelfRemove` auto-commit surfaces
    /// (bounded by [`MAX_CONVERGENCE_RETICKS`]).
    ///
    /// A single advance per group would strand the eviction: the engine re-queues
    /// the group until the auto-commit's wall-clock due time passes, and a lone
    /// advance drains it out of the pending set before it comes due. Each pass
    /// routes the drained events and resolves publish work (publishing the
    /// auto-commit over the relay plane, Rule 13). A quiet group (nothing pending)
    /// exits immediately with no delay, so only a leave pays the re-tick cost.
    async fn drain_convergence(
        &self,
        initial_pending: &[GroupId],
        nostr_group_id: &[u8],
        event_created_at_secs: i64,
    ) {
        let mut pending: Vec<GroupId> = initial_pending.to_vec();
        for _ in 0..MAX_CONVERGENCE_RETICKS {
            if pending.is_empty() {
                return;
            }
            let mut next: Vec<GroupId> = Vec::new();
            for gid in &pending {
                if let Ok(more) = self.circle.session().advance_convergence(gid).await {
                    self.route_events(&more.events, nostr_group_id, event_created_at_secs);
                    self.resolve_publish_work(&more.publish).await;
                    next.extend(more.pending_convergence);
                }
            }
            pending = next;
            if !pending.is_empty() {
                tokio::time::sleep(CONVERGENCE_RETICK_DELAY).await;
            }
        }
    }

    /// Routes an engine `GroupEvent` batch onto the fan-out bus.
    fn route_events(
        &self,
        events: &[crate::nostr::mls::types::GroupEvent],
        nostr_group_id: &[u8],
        event_created_at_secs: i64,
    ) {
        for group_event in events {
            let Some(result) = SessionManager::location_result_from_event(group_event) else {
                continue;
            };
            match result {
                LocationMessageResult::Location {
                    sender_pubkey,
                    content,
                    ..
                } => self.bus.send(LiveSyncEvent::Location {
                    nostr_group_id: nostr_group_id.to_vec(),
                    sender_pubkey,
                    content,
                    event_created_at_secs,
                }),
                // A roster/epoch change, a join, or a superseded (invalidated)
                // commit are all UI-only refresh signals now (the engine already
                // applied / rolled back the change internally).
                LocationMessageResult::GroupUpdate { .. }
                | LocationMessageResult::Joined { .. }
                | LocationMessageResult::Invalidated { .. } => {
                    self.bus.send(LiveSyncEvent::GroupUpdate {
                        nostr_group_id: nostr_group_id.to_vec(),
                        evolution_event_json: None,
                    });
                }
                // The group is unrecoverable: surface a blocked-state status so
                // the UI can stop send/mutate (Rule 8).
                LocationMessageResult::Unrecoverable { .. } => {
                    self.bus.send(LiveSyncEvent::Status {
                        reason: SyncStatusReason::Unprocessable,
                    });
                }
            }
        }
    }

    /// Resolves engine publish work surfaced during ingest / convergence.
    ///
    /// On the receive path the engine can auto-commit a peer `SelfRemove`
    /// (`PublishWork::AutoPublish`). Publish-before-apply (Rule 13 / security
    /// F13): the commit is published over the live-sync relay plane and confirmed
    /// ONLY after ≥1 relay OK-acks (else rolled back) — never an optimistic
    /// confirm, which would apply an eviction no peer received and fork the group.
    /// Without a relay plane the commit is rolled back (fail closed).
    /// `ApplicationMessage` / `Proposal` publish work carries no pending ref.
    async fn resolve_publish_work(&self, work: &[PublishWork]) {
        match &self.publisher {
            Some(publisher) => {
                resolve_receive_publish_work(&self.circle, publisher.as_ref(), work).await;
            }
            None => rollback_receive_publish_work(&self.circle, work).await,
        }
    }

    /// Emits a raw gift-wrapped invitation (`kind:1059`) onto the bus. The
    /// engine never unwraps it; the foreground consumer does. The inbox cursor
    /// advances only via the foreground after a successful hold, never here.
    pub fn process_inbox_event(&self, event: &Event) {
        self.bus.send(LiveSyncEvent::Welcome {
            gift_wrap_json: event.as_json(),
            wrap_created_at_secs: i64::try_from(event.created_at.as_secs()).unwrap_or(i64::MAX),
        });
    }

    /// Emits a bare status signal on the bus (e.g. to surface a recovered worker
    /// panic rather than silently swallow it).
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
        assert!(a.starts_with(STREAM_GROUP_445));
        assert_ne!(a, crate::relay::cursor::STREAM_INBOX_1059);
    }
}
