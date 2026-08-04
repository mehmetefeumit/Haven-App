//! The group-event processor — the receive engine's ingest loop.
//!
//! For each incoming `kind:445`, the processor feeds the transport message to
//! the Dark Matter engine (`SessionManager::process_event`), which owns
//! convergence, out-of-order sequencing (buffering future-epoch messages), and
//! stale/duplicate rejection. The processor then drains the engine's emitted
//! `GroupEvent`s onto the fan-out bus.
//!
//! The hand-rolled settle-window / regime gate that used to live here is gone
//! (plan §5.3/§5.4): the engine's stored convergence replaces it.
//!
//! # No delivered event ever advances a cursor
//!
//! An inbound event's outer `created_at` is chosen by whoever signed the
//! envelope — a throwaway ephemeral key — and no receive-side check binds it to
//! the inner MLS message the engine authenticates. That is true for EVERY
//! ingest outcome, `Processed` and `Stale` included: the engine's re-wrap dedup
//! is content-derived, so an observer who re-wraps a circle's ciphertext under a
//! fresh key and a `created_at` of its choosing still gets a clean engine
//! verdict. A per-event cursor advance would therefore hand the persisted REQ
//! floor to any relay observer (the `#h` routing tag IS the public
//! `nostr_group_id`).
//!
//! So the advance comes from [`super::anchor`] instead, anchored on the relay's
//! `EOSE`: after end-of-stored-events on a REQ, everything the relay held has
//! been delivered as of the LOCAL instant the REQ was issued. Delivered events
//! contribute in one direction only — an event that could not be APPLIED
//! (engine `Buffered`, or a hard ingest failure) holds that generation's advance
//! at or below its own `created_at`, so it is re-requested.
//!
//! A "future-epoch message is `Buffered`, so the cursor stops at it" rule would
//! not have been enough even if the timestamps were trustworthy: the engine
//! reports a future-epoch APPLICATION message as `Stale { PeelFailed }` (it
//! retains it as a retryable row and re-peels once the commit lands), not as
//! `Buffered`. `Buffered` is reported when this device's own group state cannot
//! ingest at all — during a publish-before-apply transition. The EOSE anchor
//! covers both because it does not depend on per-event outcomes.
//!
//! # The inbox plane is the same rule, against a cheaper forgery
//!
//! A `kind:1059` gift wrap is routed by a `#p` tag holding the recipient's
//! PUBLIC key and is authored by a throwaway ephemeral key by construction, and
//! peeling one consults NIP-59 alone — no MLS state, and nothing binding the
//! outer `created_at` to the payload. So minting a wrap that a victim's client
//! peels cleanly, at any `created_at`, costs one NIP-44 encryption to a
//! published npub. The inbox cursor therefore advances on its own REQ's `EOSE`
//! (see [`super::anchor::InboxAnchor`]) and the wrapper timestamp is not even
//! forwarded to the consumer.
//!
//! # Per-circle cursor
//!
//! Each circle gets its own group cursor via `group_445:{hex(nostr_group_id)}`,
//! so a busy circle's cursor advance cannot bury a quiet co-multiplexed
//! circle's un-applied commit.

use std::sync::Arc;

use nostr::{Event, JsonUtil};

use crate::circle::CircleManager;
use crate::nostr::mls::types::{
    GroupId, IngestOutcome, LocationMessageResult, PublishWork, ScreenedIngest,
};
use crate::nostr::mls::SessionManager;
use crate::relay::auto_commit::{
    resolve_receive_publish_work, rollback_receive_publish_work, AutoCommitPublisher,
    CONVERGENCE_RETICK_DELAY, MAX_CONVERGENCE_RETICKS,
};

use super::anchor::{CursorAnchors, InboxAnchor};
use super::event::{LiveSyncEvent, SyncStatusReason};
use super::event_bus::EventBus;

/// Per-circle group-cursor stream key (a distinct stream per
/// `hex(nostr_group_id)`).
#[must_use]
pub fn group_cursor_stream(group_id_hex: &str) -> String {
    format!("{}:{group_id_hex}", crate::relay::cursor::STREAM_GROUP_445)
}

/// What the processor did with one group event (returned for observability and
/// testing; the bus side effects are already applied).
///
/// **No variant advances a cursor.** The variants say what the ENGINE decided
/// and, through that, whether the event holds its generation's EOSE advance
/// back — see the module docs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GroupProcessOutcome {
    /// The engine APPLIED the message (`IngestOutcome::Processed`). Nothing is
    /// outstanding at this event's position, so it holds nothing back.
    Applied,
    /// The engine terminally handled the message without applying anything new
    /// (`IngestOutcome::Stale` — duplicate, stale epoch, not-for-us, or
    /// undecryptable-and-retained). Holds nothing back: the engine owns the
    /// retry of what it retained, and holding here would let one forged event
    /// pin the circle's cursor for the session.
    Stale,
    /// The engine buffered the message (this device's own group state cannot
    /// ingest right now — a publish-before-apply transition). Un-applied, so it
    /// holds this generation's advance at or below its `created_at`; the engine
    /// also persists it durably, so nothing is lost across a restart.
    Buffered,
    /// Haven's local receiver-side screen rejected the event BEFORE any MLS
    /// authentication (see [`crate::nostr::mls::types::ScreenedIngest`]) — an
    /// expired NIP-40 replay, or an envelope the pure pre-engine transport parse
    /// could not read at all. Nothing was routed and nothing was persisted. It
    /// holds nothing back either: there is no un-applied message to come back
    /// for, and letting it hold would sell an attacker a stall for the price of
    /// one forged event.
    RejectedBeforeAuth,
    /// The ENGINE could not ingest the message (hard failure). Treated like
    /// [`Self::Buffered`] for the cursor: something at this position is
    /// unresolved, so it holds the generation back.
    ///
    /// Reaching this means the envelope parsed and the engine took the message —
    /// it is the authenticated path failing, not a screen. An envelope that does
    /// not parse is [`Self::RejectedBeforeAuth`] instead, so an attacker cannot
    /// mint a hold-back here without producing ciphertext the engine will
    /// actually work on.
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
    /// Per-circle cursor anchors: one of the only two things in this module that
    /// may move a sync cursor forward, and it moves it to a local clock reading.
    anchors: CursorAnchors,
    /// The inbox (`kind:1059`) cursor anchor — the other one, and likewise a
    /// local clock reading. A gift wrap's own `created_at` reaches it in no
    /// direction; see [`InboxAnchor`].
    inbox_anchor: InboxAnchor,
}

impl EngineProcessor {
    /// Creates a processor over the shared MLS state and bus, with NO relay plane.
    ///
    /// A receive-side auto-commit surfaced through this processor is rolled back
    /// (fail closed, Rule 13) since it cannot be published. Use
    /// [`Self::with_publisher`] for the live-sync path.
    #[must_use]
    pub fn new(circle: Arc<CircleManager>, bus: EventBus) -> Self {
        Self {
            circle,
            bus,
            publisher: None,
            anchors: CursorAnchors::default(),
            inbox_anchor: InboxAnchor::default(),
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
            anchors: CursorAnchors::default(),
            inbox_anchor: InboxAnchor::default(),
        }
    }

    /// Opens a fresh cursor-anchor generation for `group_id_hex`, anchored at
    /// `opened_at_secs` — a LOCAL wall-clock reading taken when that circle's REQ
    /// was (re-)issued.
    ///
    /// The session MUST call this for every circle of every REQ it issues, before
    /// or as it issues it. Passing an open time EARLIER than the actual REQ is
    /// safe (it claims less); passing a later one is not, so callers reuse the
    /// same `now` they derived the REQ's `since` from.
    ///
    /// A circle with no open generation never advances its cursor — which is why
    /// a bare processor with no session wired is inert on the cursor.
    pub fn note_subscription_opened(&self, group_id_hex: &str, opened_at_secs: i64) {
        self.anchors.open_generation(group_id_hex, opened_at_secs);
    }

    /// Records the relay's end-of-stored-events for `group_id_hex` and advances
    /// that circle's persisted cursor to what the generation justifies.
    ///
    /// Returns whether an advance was issued (`false` when no generation is open
    /// or this generation already advanced). Best-effort: a storage failure is
    /// swallowed, because the cursor is an optimization and dropping the EOSE
    /// signal must never cost a delivered event.
    ///
    /// # Why EOSE and not the event
    ///
    /// EOSE is the relay saying "that was everything I had for this REQ". Paired
    /// with the local instant the REQ was issued, it is the only completeness
    /// claim this plane can make that no remote party can write. See the module
    /// docs.
    pub fn note_end_of_stored_events(&self, group_id_hex: &str) -> bool {
        let now_secs = chrono::Utc::now().timestamp();
        let Some(ms) = self.anchors.note_eose(group_id_hex, now_secs) else {
            return false;
        };
        let _ = self
            .circle
            .advance_sync_cursor(&group_cursor_stream(group_id_hex), ms);
        true
    }

    /// Drops a circle's anchor after its subscription is closed, so a later
    /// stray EOSE cannot advance a cursor for a circle we no longer follow.
    pub fn forget_subscription(&self, group_id_hex: &str) {
        self.anchors.forget(group_id_hex);
    }

    /// Opens a fresh INBOX cursor-anchor generation at `opened_at_secs` — a
    /// LOCAL wall-clock reading taken when the `kind:1059` REQ was (re-)issued.
    ///
    /// The session MUST call this for every inbox REQ it issues, before or as it
    /// issues it, reusing the same `now` it derived that REQ's `since` from.
    /// With no open generation the inbox cursor never advances.
    pub fn note_inbox_subscription_opened(&self, opened_at_secs: i64) {
        self.inbox_anchor.open(opened_at_secs);
    }

    /// Records the relay's end-of-stored-events for the INBOX subscription and
    /// advances the persisted `inbox_1059` cursor to what the generation
    /// justifies.
    ///
    /// Returns whether an advance was issued (`false` when no generation is open
    /// or this generation already advanced). Best-effort: a storage failure is
    /// swallowed, because the cursor is an optimization and dropping the EOSE
    /// signal must never cost a delivered invitation.
    ///
    /// # Why not the gift wrap's own timestamp
    ///
    /// A `kind:1059`'s `#p` routing tag is the recipient's PUBLIC key and its
    /// author is a throwaway ephemeral key by construction, so anyone who knows
    /// a user's npub can mint a wrap that peels cleanly at any `created_at` —
    /// see [`InboxAnchor`] for the full argument and for why the FUTURE
    /// direction is the one that kills invitation delivery outright.
    pub fn note_inbox_end_of_stored_events(&self) -> bool {
        let now_secs = chrono::Utc::now().timestamp();
        let Some(ms) = self.inbox_anchor.consume_eose(now_secs) else {
            return false;
        };
        let _ = self
            .circle
            .advance_sync_cursor(crate::relay::cursor::STREAM_INBOX_1059, ms);
        true
    }

    /// Drops the inbox anchor after its subscription is closed, so a later stray
    /// EOSE cannot advance a cursor for a REQ we no longer own.
    pub fn forget_inbox_subscription(&self) {
        self.inbox_anchor.forget();
    }

    /// Processes one incoming `kind:445` for `nostr_group_id` (its routed `#h`).
    ///
    /// Ingests via the engine, routes the drained events, advances stored
    /// convergence for any pending group, and resolves any engine publish work.
    ///
    /// **Never advances a cursor.** An event that could not be applied records a
    /// hold-back against its circle's current anchor generation, so the next
    /// [`Self::note_end_of_stored_events`] stops at or below it; every other
    /// outcome is cursor-inert. See the module docs for why no ingest outcome —
    /// `Processed` included — vouches for the outer `created_at`.
    ///
    /// `#[deny(clippy::wildcard_enum_match_arm)]`: the two matches below are the
    /// hold-back gate. A wildcard arm here is how a future variant — of
    /// [`ScreenedIngest`] or of the upstream `IngestOutcome` — silently inherits
    /// "nothing outstanding here", so making one a hard error (clippy runs with
    /// `-D warnings` in CI) forces the decision to be written down.
    #[cfg_attr(test, allow(clippy::missing_panics_doc))]
    #[deny(clippy::wildcard_enum_match_arm)]
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

        // An `Err` here is an ENGINE-side ingest failure: the envelope parsed, so
        // the engine took the message and failed on it. Something at this
        // position is unresolved, so hold the generation at it. Attacker-writable
        // in principle, but only downwards (and the cursor write is
        // monotonic-max), so the worst it buys is a wider refetch — and minting
        // one now costs producing ciphertext the engine will actually work on,
        // because an unreadable envelope no longer lands here (it is a
        // `RejectedBeforeAuth` below).
        let Ok(screened) = self.circle.session().process_event(event).await else {
            self.bus.send(LiveSyncEvent::Status {
                reason: SyncStatusReason::Unprocessable,
            });
            self.anchors.note_unapplied(&group_hex, created_at_secs);
            return GroupProcessOutcome::Unprocessable;
        };

        let ingest = match screened {
            // Rejected by Haven's local screen BEFORE any MLS authentication:
            // the signature, the ephemeral author and the ciphertext are all
            // unverified. No routing, no publish work, no convergence drain —
            // and no hold-back either: there is no un-applied message to come
            // back for, so letting it hold would let one forged event stall the
            // circle's cursor for the whole generation.
            ScreenedIngest::RejectedBeforeAuth(_) => {
                return GroupProcessOutcome::RejectedBeforeAuth;
            }
            ScreenedIngest::Ingested(effects) => effects,
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

        // The hold-back gate. NOT a cursor advance: no arm here writes a cursor,
        // because no engine verdict binds this envelope's `created_at` to what it
        // authenticated. `Buffered` is the one un-applied verdict, so it — and
        // only it — pins this generation's EOSE advance at or below the event.
        match ingest.outcome {
            IngestOutcome::Buffered { .. } => {
                self.anchors.note_unapplied(&group_hex, created_at_secs);
                GroupProcessOutcome::Buffered
            }
            IngestOutcome::Processed => GroupProcessOutcome::Applied,
            IngestOutcome::Stale { .. } => GroupProcessOutcome::Stale,
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
    /// engine never unwraps it; the foreground consumer does.
    ///
    /// **Cursor-inert, in both directions.** The wrapper's `created_at` is not
    /// forwarded to the consumer at all, because the only thing it was ever used
    /// for was a cursor advance — and it is an unauthenticated field on an event
    /// anyone who knows this user's npub can mint (see [`InboxAnchor`]). The
    /// inbox cursor moves on [`Self::note_inbox_end_of_stored_events`] alone.
    pub fn process_inbox_event(&self, event: &Event) {
        self.bus.send(LiveSyncEvent::Welcome {
            gift_wrap_json: event.as_json(),
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
