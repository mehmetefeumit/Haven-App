//! Cursor-anchored catch-up sweep (M7).
//!
//! A best-effort, deadline-bounded fetch that pulls whatever a circle's relays
//! hold since the persisted cursor and feeds it to the Dark Matter engine in the
//! background / on foreground resume. The engine owns convergence,
//! out-of-order sequencing, and publish-before-apply internally, so this sweep
//! no longer needs the Haven-owned staged-commit marker or a per-circle write
//! gate — it just ingests and advances the cursor over the applied prefix.
//!
//! # Rule 14 (single session)
//!
//! This sweep MUST run through the SAME process-global
//! [`crate::nostr::mls::SessionManager`] as the foreground (via the SAME
//! `CircleManager` `Arc`). The caller (the FFI background-wake path) passes the
//! foreground `CircleManager`; it must never construct a second `CircleManager`
//! / session on the same DB file (divergent hydrated epoch state =
//! exporter-key/forward-secrecy erosion). The engine's single `tokio` mutex
//! serializes this sweep's writes against any foreground send.
//!
//! # Cursor safety
//!
//! The cursor advances only over the longest CONTIGUOUS PREFIX of applied
//! events; it STOPS at the first `Buffered` (future-epoch) outcome so an
//! un-applied message is always re-fetched on the next sweep. The engine also
//! persists buffered messages durably, so nothing is lost across a restart.

/// The catch-up classification of a single ingested group event.
///
/// Fieldless (Copy) — carries no coordinates, pubkey, group id, or commit JSON,
/// so its derived `Debug` cannot leak (Security Rule 4/6).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReceiveOnlyOutcome {
    /// The engine applied the message, or terminally handled it (stale /
    /// duplicate / not-for-us). The cursor may advance past it.
    Applied,
    /// The engine buffered the message for a future epoch, or the ingest failed.
    /// The cursor MUST STOP before it (re-fetched next sweep).
    Deferred,
}

impl ReceiveOnlyOutcome {
    /// Whether the cursor may advance past this event. Only an `Applied` outcome
    /// advances; a `Deferred` (future-epoch buffered / failed) stops the
    /// high-water-mark so the message is always re-fetched (C-CURSOR).
    #[must_use]
    pub const fn advances_cursor(self) -> bool {
        matches!(self, Self::Applied)
    }
}

/// Presence-only tally of a catch-up sweep. All counters — no group ids,
/// coordinates, or secrets — so its derived `Debug` is leak-free by
/// construction (Security Rule 4).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CatchupOutcome {
    /// Circles whose relays were swept.
    pub circles_swept: usize,
    /// Events the engine applied / terminally handled.
    pub events_applied: usize,
    /// Events the engine buffered for a future epoch (cursor stopped).
    pub events_deferred: usize,
    /// Per-circle group cursors advanced.
    pub cursors_advanced: usize,
    /// The deadline was reached before every bucket was swept.
    pub deadline_hit: bool,
    /// Relay fetches that returned no response / errored (tallied, never fatal).
    pub relay_errors: usize,
}

/// Max events fetched per circle per sweep — a flood-guard (Rule 12) so a
/// malicious relay cannot answer one circle's REQ with an unbounded batch a
/// background wake would then ingest. A missed tail re-fetches next sweep.
const CATCHUP_MAX_EVENTS_PER_CIRCLE: usize = 512;

use std::collections::HashSet;
use std::time::{Duration, Instant};

use nostr::{Event, PublicKey};

use crate::circle::CircleManager;
use crate::location::LocationMessage;
use crate::nostr::mls::types::{GroupId, IngestOutcome, LocationMessageResult, PublishWork};
use crate::nostr::mls::SessionManager;
use crate::relay::auto_commit::{CONVERGENCE_RETICK_DELAY, MAX_CONVERGENCE_RETICKS};
use crate::relay::cursor::{since_for_stream, SubscribePhase};
use crate::relay::live_sync::group_cursor_stream;
use crate::relay::live_sync::planes::group::group_filter;
use crate::relay::RelayManager;

/// The cursor-advance target (ms) for a batch already sorted ascending by
/// `(created_at, id)`: the `created_at` (→ ms) of the last event in the longest
/// CONTIGUOUS PREFIX of cursor-advancing outcomes. `None` ⇒ do not advance.
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

/// Ingests one fetched event through the process-global engine, persisting any
/// decrypted location and resolving any auto-commit publish work, then reports
/// whether the cursor may advance past it.
async fn ingest_one(
    circle_mgr: &CircleManager,
    relay_mgr: &RelayManager,
    ev: &Event,
    ngid: &[u8; 32],
    own_hex: &str,
) -> ReceiveOnlyOutcome {
    let Ok(ingest) = circle_mgr.session().process_event(ev).await else {
        return ReceiveOnlyOutcome::Deferred;
    };

    persist_locations(circle_mgr, &ingest.effects.events, ngid, own_hex);
    resolve_publish_work(circle_mgr, relay_mgr, &ingest.effects.publish).await;

    // Release any queued convergence work + persist its locations, re-ticking a
    // group that stays pending until its jitter-delayed `SelfRemove` auto-commit
    // surfaces (bounded) — a single advance would strand the eviction commit
    // before its wall-clock due time, so this background sweep would never
    // re-broadcast it. A quiet group exits immediately (no delay).
    let mut pending: Vec<GroupId> = ingest.effects.pending_convergence.clone();
    for _ in 0..MAX_CONVERGENCE_RETICKS {
        if pending.is_empty() {
            break;
        }
        let mut next: Vec<GroupId> = Vec::new();
        for gid in &pending {
            if let Ok(more) = circle_mgr.session().advance_convergence(gid).await {
                persist_locations(circle_mgr, &more.events, ngid, own_hex);
                resolve_publish_work(circle_mgr, relay_mgr, &more.publish).await;
                next.extend(more.pending_convergence);
            }
        }
        pending = next;
        if !pending.is_empty() {
            tokio::time::sleep(CONVERGENCE_RETICK_DELAY).await;
        }
    }

    match ingest.outcome {
        IngestOutcome::Buffered { .. } => ReceiveOnlyOutcome::Deferred,
        IngestOutcome::Processed | IngestOutcome::Stale { .. } => ReceiveOnlyOutcome::Applied,
    }
}

/// Persists each decrypted location application-message as a last-known-location
/// row (never a self-echo — the engine also filters own echoes as `Stale`).
fn persist_locations(
    circle_mgr: &CircleManager,
    events: &[crate::nostr::mls::types::GroupEvent],
    ngid: &[u8; 32],
    own_hex: &str,
) {
    for ge in events {
        if let Some(LocationMessageResult::Location {
            sender_pubkey,
            content,
            ..
        }) = SessionManager::location_result_from_event(ge)
        {
            if sender_pubkey == own_hex {
                continue;
            }
            if let Ok(msg) = serde_json::from_str::<LocationMessage>(&content) {
                let row = crate::circle::LastKnownLocation {
                    nostr_group_id: *ngid,
                    sender_pubkey,
                    latitude: msg.latitude,
                    longitude: msg.longitude,
                    geohash: msg.geohash,
                    display_name: msg.display_name,
                    timestamp: msg.timestamp.timestamp(),
                    expires_at: msg.expires_at.timestamp(),
                    purge_after: 0, // recomputed authoritatively by upsert
                    updated_at: chrono::Utc::now().timestamp(),
                };
                let _ = circle_mgr.upsert_last_known_location(&row);
            }
        }
    }
}

/// Resolves engine publish work surfaced during a catch-up ingest / convergence.
///
/// Publish-before-apply (Rule 13 / security F13): a receive-side auto-commit (a
/// peer `SelfRemove` eviction) is published over the sweep's own [`RelayManager`]
/// and confirmed ONLY after ≥1 relay OK-acks — else rolled back. This background
/// sweep therefore re-broadcasts the eviction to the rest of the group instead of
/// optimistically applying a commit no peer received (the old fork).
async fn resolve_publish_work(
    circle_mgr: &CircleManager,
    relay_mgr: &RelayManager,
    work: &[PublishWork],
) {
    crate::relay::auto_commit::resolve_receive_publish_work(circle_mgr, relay_mgr, work).await;
}

/// Runs a cursor-anchored catch-up sweep over every visible circle.
///
/// Best-effort and deadline-bounded. Runs through the SAME process-global
/// session as the foreground (Rule 14 — see the module docs). Fails closed: if
/// storage is unavailable, returns an empty [`CatchupOutcome`] (no ingest).
pub async fn run_catchup_all_circles(
    circle_mgr: &CircleManager,
    relay_mgr: &RelayManager,
    own_pubkey: &PublicKey,
    max_duration_secs: u64,
) -> CatchupOutcome {
    let mut out = CatchupOutcome::default();
    let deadline = Instant::now() + Duration::from_secs(max_duration_secs);
    let own_hex = own_pubkey.to_hex();

    // Fail-closed: storage unavailable (e.g. locked device) ⇒ clean no-op.
    let Ok(circles) = circle_mgr.get_visible_circles().await else {
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

        let now_secs = chrono::Utc::now().timestamp();
        let cursor_ms = circle_mgr
            .read_sync_cursor(&stream)
            .ok()
            .flatten()
            .unwrap_or_else(|| now_secs.saturating_sub(24 * 3600).saturating_mul(1000));
        let since_secs =
            since_for_stream(&stream, cursor_ms, SubscribePhase::Resubscribe, now_secs);
        let filter = group_filter(std::slice::from_ref(&hex), since_secs)
            .limit(CATCHUP_MAX_EVENTS_PER_CIRCLE);

        let Ok(fetch_outcomes) = relay_mgr.fetch_events_per_relay(filter, &relays).await else {
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

        let mut classified: Vec<(i64, ReceiveOnlyOutcome)> = Vec::with_capacity(events.len());
        for ev in &events {
            if Instant::now() >= deadline {
                out.deadline_hit = true;
                break;
            }
            let secs = i64::try_from(ev.created_at.as_secs()).unwrap_or(i64::MAX);
            let outcome = ingest_one(circle_mgr, relay_mgr, ev, &ngid, &own_hex).await;
            match outcome {
                ReceiveOnlyOutcome::Applied => out.events_applied += 1,
                ReceiveOnlyOutcome::Deferred => out.events_deferred += 1,
            }
            classified.push((secs, outcome));
        }

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
        assert!(O::Applied.advances_cursor());
        assert!(!O::Deferred.advances_cursor());
    }

    #[test]
    fn cursor_stops_at_first_deferred_event() {
        // [Applied@1, Applied@2, Deferred@3, Applied@4] → advance only to 2; the
        // un-applied event at 3 is never skipped past, so 3+4 re-fetch next time.
        let batch = [
            (1, O::Applied),
            (2, O::Applied),
            (3, O::Deferred),
            (4, O::Applied),
        ];
        assert_eq!(contiguous_prefix_cursor_ms(&batch), Some(2_000));
    }

    #[test]
    fn cursor_does_not_advance_when_first_event_is_deferred() {
        assert_eq!(
            contiguous_prefix_cursor_ms(&[(9, O::Deferred), (10, O::Applied)]),
            None
        );
    }

    #[test]
    fn empty_batch_does_not_advance() {
        assert_eq!(contiguous_prefix_cursor_ms(&[]), None);
    }
}
