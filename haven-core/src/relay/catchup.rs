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
//! **No event's `created_at` may ever raise this sweep's cursor.** The outer
//! `kind:445` envelope is signed by a throwaway ephemeral key and its
//! `created_at` is authenticated by nothing on the receive path — the engine
//! authenticates the *inner* MLS message, and no receive-side check binds the
//! two. A circle's `#h` is its public `nostr_group_id`, so any relay observer
//! can mint (or re-wrap an observed ciphertext into) an event carrying any
//! timestamp it likes.
//!
//! So the advance is derived from a LOCAL, trusted fact instead: the wall-clock
//! reading taken **before** the fetch window's REQ was issued. A window that
//! comes back complete means "these relays handed over everything they held
//! matching this filter as of the moment I asked", which is exactly the claim
//! that timestamp encodes. Event timestamps enter only as HOLD-BACKS —
//! see [`cursor_advance_ms`] and [`crate::relay::cursor::cursor_ms_for_window`],
//! which carries the full argument.
//!
//! A window is complete enough to advance only when it was not truncated
//! (`saturated`) and at least one of the circle's relays answered. Anything the
//! sweep could not APPLY — an engine `Buffered`, a hard ingest failure, or an
//! event the deadline stopped us reaching — holds the advance at or below that
//! event so it is re-fetched next sweep.
//!
//! # What is deliberately NOT held back
//!
//! An `IngestOutcome::Stale` (including `PeelFailed`, which is what a genuine
//! future-epoch APPLICATION message produces — it is *not* `Buffered`) does not
//! hold the cursor. The engine persists such a message as a retryable row and
//! re-peels it once the missing commit lands, so recovery is the engine's, not
//! the cursor's. Holding on it would freeze the cursor of any client that is
//! temporarily unable to decrypt, growing the fetch window until `saturated`
//! froze it permanently — a self-inflicted outage in place of the remote one.
//! Nothing is lost by advancing past it, because the advance no longer takes
//! its value from the event.
//!
//! Likewise an event Haven's own receiver-side screen rejected before any MLS
//! authentication ([`ReceiveOnlyOutcome::NoEvidence`]) neither advances nor
//! holds: there is no un-applied message to come back for, and one forged event
//! must not be able to stall the sweep.

/// The catch-up classification of a single ingested group event.
///
/// Fieldless (Copy) — carries no coordinates, pubkey, group id, or commit JSON,
/// so its derived `Debug` cannot leak (Security Rule 4/6).
///
/// Three-valued on purpose: only ONE of the three is a reason to hold the
/// cursor back, and none of the three is a reason to move it forward — the
/// advance comes from the fetch window, never from an event (see the module
/// docs).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReceiveOnlyOutcome {
    /// The engine applied the message, or terminally handled it (stale /
    /// duplicate / not-for-us / undecryptable-and-retained). Nothing is
    /// outstanding at this event's position, so it does not hold the cursor.
    ///
    /// It does not ADVANCE the cursor either: its `created_at` is unbound to
    /// whatever the engine authenticated, so the advance is taken from the
    /// window's open time instead.
    Applied,
    /// The engine buffered the message for a future epoch, the ingest failed
    /// hard, or the sweep's deadline stopped us reaching it. Something at this
    /// position is still outstanding, so the cursor is held at or below this
    /// event's `created_at` and the event is re-fetched next sweep.
    Deferred,
    /// Haven's local receiver-side screen rejected the event BEFORE any MLS
    /// authentication ran (see [`crate::nostr::mls::types::ScreenedIngest`]).
    ///
    /// Contributes nothing in EITHER direction. It is not evidence the sweep
    /// caught up to its `created_at` (nothing authenticated that timestamp), and
    /// it is not evidence of a gap (there is no un-applied message to come back
    /// for) — so it must not hold the cursor either, or one forged event would
    /// buy an attacker a permanent stall. Tallied separately as
    /// [`CatchupOutcome::events_rejected_pre_auth`].
    NoEvidence,
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
    /// Events Haven's own receiver-side screen rejected before any MLS
    /// authentication ran (expired NIP-40 replays, forged or genuine). Neither
    /// applied nor deferred: they contribute no cursor evidence at all. A
    /// persistently non-zero count on a healthy circle means some relay is
    /// serving events past their advertised TTL.
    pub events_rejected_pre_auth: usize,
    /// Per-circle group cursors advanced.
    pub cursors_advanced: usize,
    /// The deadline was reached before every bucket was swept.
    pub deadline_hit: bool,
    /// Relay fetches that returned no response / errored (tallied, never fatal).
    pub relay_errors: usize,
    /// Circles whose fetch window came back SATURATED (some relay returned the
    /// full `CATCHUP_MAX_EVENTS_PER_CIRCLE`), so the window's older tail was
    /// truncated away and the cursor was deliberately NOT advanced. Non-zero
    /// means "this circle still has unretrieved backlog", not an error.
    pub windows_truncated: usize,
}

/// Max events fetched per circle per sweep — a flood-guard (Rule 12) so a
/// malicious relay cannot answer one circle's REQ with an unbounded batch a
/// background wake would then ingest.
///
/// # Saturation is NOT a benign "missed tail"
///
/// NIP-01 `limit: n` returns the **newest** n events, so a window holding more
/// than this many events comes back truncated at the BOTTOM — the oldest
/// events are never delivered. Advancing the cursor to the newest event we did
/// receive would push `since` past that unretrieved tail permanently (the next
/// sweep's floor is only `GROUP_RESUBSCRIBE_BUFFER_SECS` back), silently
/// dropping legitimate offline backlog — the exact failure Security Rule 12
/// forbids. A dropped location merely ages out; a dropped COMMIT strands the
/// epoch chain.
///
/// So on saturation we hold the cursor still (see `advance_cursor` below).
/// Ingest still runs, so the engine makes progress on what we did fetch, and
/// the window is re-fetched next sweep. This is CONSERVATIVE, not complete:
/// holding the cursor stops the silent loss but does not by itself retrieve
/// the tail. Retrieving it needs backward paging (re-issue with
/// `until = oldest_seen` until a short page), which is deliberately left as a
/// follow-up because it changes fetch ordering in the MLS convergence path and
/// wants E2E validation.
const CATCHUP_MAX_EVENTS_PER_CIRCLE: usize = 512;

use std::collections::HashSet;
use std::time::{Duration, Instant};

use nostr::{Event, PublicKey};

use crate::circle::CircleManager;
use crate::location::LocationMessage;
use crate::nostr::mls::types::{
    GroupId, IngestOutcome, LocationMessageResult, PublishWork, ScreenedIngest,
};
use crate::nostr::mls::SessionManager;
use crate::relay::auto_commit::{CONVERGENCE_RETICK_DELAY, MAX_CONVERGENCE_RETICKS};
use crate::relay::cursor::{since_for_stream, SubscribePhase};
use crate::relay::live_sync::group_cursor_stream;
use crate::relay::live_sync::planes::group::group_filter;
use crate::relay::RelayManager;

/// Everything one circle's fetch window learned, in the ONLY terms a cursor
/// advance may be derived from.
///
/// Constructed by the sweep and consumed by [`cursor_advance_ms`]; kept as a
/// named struct so the two trusted, local fields cannot be confused with the
/// one remotely-written field at a call site.
///
/// Fieldless of anything sensitive (timestamps, counts and flags only), so the
/// derived `Debug` is leak-free by construction (Security Rules 4/6).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct FetchWindow {
    /// LOCAL wall-clock reading taken BEFORE this circle's REQ was issued. The
    /// advance target. Not writable by any remote party.
    pub opened_at_secs: i64,
    /// Some relay returned a full page, so the window's older tail was
    /// truncated away (Security Rule 12).
    pub saturated: bool,
    /// At least one of the circle's relays answered. With none, the window is
    /// empty for a reason that says nothing about the circle's traffic.
    pub any_relay_responded: bool,
}

/// The cursor-advance target (ms) for one circle's sweep, or `None` to hold the
/// cursor where it is.
///
/// `unapplied_secs` carries the `created_at` of every event this sweep did not
/// apply — engine-buffered, hard ingest failure, or never reached because the
/// deadline cut the batch short. It is the ONLY remotely-written input, and it
/// can only LOWER the result; see
/// [`crate::relay::cursor::cursor_ms_for_window`] for why that is the whole
/// security argument.
///
/// # The two gates that block the advance outright
///
/// Both are facts about the FETCH, invisible in the events themselves:
///
/// * `saturated` — NIP-01 `limit: n` returns the NEWEST n, so a truncated
///   window has an unretrieved tail BELOW it that is byte-for-byte
///   indistinguishable from a complete window. Only the fetch layer knows.
/// * `any_relay_responded` — with nothing reached, "the relays held nothing
///   new" and "we could not ask" are the same empty list. Claiming the first
///   would skip whatever accumulated during the outage.
///
/// # Why partial relay coverage still advances
///
/// A circle with two relays, one unreachable, DOES advance. Requiring unanimity
/// would freeze the cursor of any circle carrying a permanently-dead relay URL,
/// which makes every later sweep re-fetch and re-ingest a window that only
/// grows — a self-inflicted outage, and one an attacker never had to cause. The
/// residual (an event held ONLY by the unreachable relay, published between the
/// last window and this one) is the same coverage assumption the whole cursor
/// design already rests on, is unchanged from the previous rule, and is outside
/// the injection threat model this gate exists for: a relay that withholds
/// events can already withhold them outright.
#[must_use]
pub(crate) fn cursor_advance_ms(
    window: FetchWindow,
    unapplied_secs: &[i64],
    now_secs: i64,
) -> Option<i64> {
    if window.saturated || !window.any_relay_responded {
        return None;
    }
    Some(crate::relay::cursor::cursor_ms_for_window(
        window.opened_at_secs,
        unapplied_secs.iter().copied().min(),
        now_secs,
    ))
}

/// The `created_at`s that must hold this window's advance back: every event the
/// sweep classified as [`ReceiveOnlyOutcome::Deferred`].
///
/// [`ReceiveOnlyOutcome::Applied`] and [`ReceiveOnlyOutcome::NoEvidence`] are
/// both skipped, for different reasons — see their docs. Neither can raise the
/// advance, because nothing here can.
#[must_use]
#[deny(clippy::wildcard_enum_match_arm)]
pub(crate) fn hold_backs(classified: &[(i64, ReceiveOnlyOutcome)]) -> Vec<i64> {
    classified
        .iter()
        .filter_map(|(secs, outcome)| match outcome {
            ReceiveOnlyOutcome::Deferred => Some(*secs),
            ReceiveOnlyOutcome::Applied | ReceiveOnlyOutcome::NoEvidence => None,
        })
        .collect()
}

/// Ingests one fetched event through the process-global engine, persisting any
/// decrypted location and resolving any auto-commit publish work, then reports
/// whether the cursor may advance past it.
#[deny(clippy::wildcard_enum_match_arm)]
async fn ingest_one(
    circle_mgr: &CircleManager,
    relay_mgr: &RelayManager,
    ev: &Event,
    ngid: &[u8; 32],
    own_hex: &str,
) -> ReceiveOnlyOutcome {
    let Ok(screened) = circle_mgr.session().process_event(ev).await else {
        return ReceiveOnlyOutcome::Deferred;
    };

    let ingest = match screened {
        // Rejected by Haven's local screen BEFORE any MLS authentication.
        // Nothing here is verified, so persist nothing, publish nothing, drain
        // nothing — and report `NoEvidence` so the event's unauthenticated
        // `created_at` cannot become this circle's cursor.
        ScreenedIngest::RejectedBeforeAuth(_) => return ReceiveOnlyOutcome::NoEvidence,
        ScreenedIngest::Ingested(effects) => effects,
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
        let relays = cwm.circle.relays;
        if relays.is_empty() {
            continue;
        }
        out.circles_swept += 1;
        sweep_one_circle(
            circle_mgr,
            relay_mgr,
            cwm.circle.nostr_group_id,
            &relays,
            &own_hex,
            deadline,
            &mut out,
        )
        .await;
    }

    out
}

/// Sweeps ONE circle: opens the window, fetches, ingests, and advances that
/// circle's cursor. Tallies into `out`.
async fn sweep_one_circle(
    circle_mgr: &CircleManager,
    relay_mgr: &RelayManager,
    ngid: [u8; 32],
    relays: &[String],
    own_hex: &str,
    deadline: Instant,
    out: &mut CatchupOutcome,
) {
    let hex = hex::encode(ngid);
    let stream = group_cursor_stream(&hex);

    // THE ADVANCE ANCHOR. Read from the LOCAL clock before the REQ goes out, so
    // it means "everything these relays held at this instant" — the only claim a
    // completed window actually earns, and the only input to the advance no
    // remote party can write. Nothing an event carries may raise the cursor
    // above it (see the module docs and
    // `crate::relay::cursor::cursor_ms_for_window`, which carries the argument).
    // It doubles as the `since` derivation's `now`, which only ever narrows the
    // request.
    let window_opened_at_secs = chrono::Utc::now().timestamp();
    let cursor_ms = circle_mgr
        .read_sync_cursor(&stream)
        .ok()
        .flatten()
        .unwrap_or_else(|| {
            window_opened_at_secs
                .saturating_sub(24 * 3600)
                .saturating_mul(1000)
        });
    let since_secs = since_for_stream(
        &stream,
        cursor_ms,
        SubscribePhase::Resubscribe,
        window_opened_at_secs,
    );
    let filter =
        group_filter(std::slice::from_ref(&hex), since_secs).limit(CATCHUP_MAX_EVENTS_PER_CIRCLE);

    let Ok(fetch_outcomes) = relay_mgr.fetch_events_per_relay(filter, relays).await else {
        out.relay_errors += 1;
        return;
    };

    // Dedup by event id across relays.
    //
    // `saturated` is measured PER RELAY, before dedup: a relay that returns
    // exactly the limit is the signal that ITS window was truncated at the
    // bottom. Measuring the deduped total instead would mask the case where two
    // relays each truncate but overlap, leaving the union under the cap.
    let mut seen: HashSet<_> = HashSet::new();
    let mut events: Vec<Event> = Vec::new();
    let mut saturated = false;
    let mut any_relay_responded = false;
    for fo in fetch_outcomes {
        if fo.responded {
            any_relay_responded = true;
        } else {
            out.relay_errors += 1;
        }
        saturated |= fo.events.len() >= CATCHUP_MAX_EVENTS_PER_CIRCLE;
        for ev in fo.events {
            if seen.insert(ev.id) {
                events.push(ev);
            }
        }
    }
    if saturated {
        out.windows_truncated += 1;
    }
    // Ascending (created_at, id): the sort is what makes an early deadline break
    // leave the OLDEST un-ingested events for the hold-back below.
    events.sort_by(|a, b| a.created_at.cmp(&b.created_at).then(a.id.cmp(&b.id)));

    let mut classified: Vec<(i64, ReceiveOnlyOutcome)> = Vec::with_capacity(events.len());
    for (idx, ev) in events.iter().enumerate() {
        if Instant::now() >= deadline {
            out.deadline_hit = true;
            // Everything from here on was FETCHED but never ingested. The window
            // is therefore not fully applied, and without this the window-open
            // anchor would happily claim it: the advance would jump over an
            // un-ingested tail that only a future sweep with a lower floor could
            // ever recover. Classify the remainder as deferred so each one holds
            // the cursor at or below itself.
            classified.extend(events[idx..].iter().map(|pending| {
                (
                    i64::try_from(pending.created_at.as_secs()).unwrap_or(i64::MAX),
                    ReceiveOnlyOutcome::Deferred,
                )
            }));
            out.events_deferred += events.len() - idx;
            break;
        }
        let secs = i64::try_from(ev.created_at.as_secs()).unwrap_or(i64::MAX);
        let outcome = ingest_one(circle_mgr, relay_mgr, ev, &ngid, own_hex).await;
        match outcome {
            ReceiveOnlyOutcome::Applied => out.events_applied += 1,
            ReceiveOnlyOutcome::Deferred => out.events_deferred += 1,
            ReceiveOnlyOutcome::NoEvidence => out.events_rejected_pre_auth += 1,
        }
        classified.push((secs, outcome));
    }

    let window = FetchWindow {
        opened_at_secs: window_opened_at_secs,
        saturated,
        any_relay_responded,
    };
    // The clamp reads the clock AGAIN so a long sweep is measured against a
    // current wall clock, never the stale one the window opened with.
    if let Some(ms) = cursor_advance_ms(
        window,
        &hold_backs(&classified),
        chrono::Utc::now().timestamp(),
    ) {
        if circle_mgr.advance_sync_cursor(&stream, ms).is_ok() {
            out.cursors_advanced += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        cursor_advance_ms, hold_backs, ingest_one, FetchWindow, ReceiveOnlyOutcome,
        ReceiveOnlyOutcome as O,
    };

    /// A `now` far past every timestamp these batches use, so the clamp is
    /// inert and each test isolates the rule it is actually about.
    const NOW: i64 = 2_000_000_000;

    /// The local clock reading a healthy window opened at. Every "advance to"
    /// assertion below is against THIS number, never against an event's.
    const OPENED: i64 = 1_000_000;

    /// A window that reached its relays and was not truncated.
    const fn healthy() -> FetchWindow {
        FetchWindow {
            opened_at_secs: OPENED,
            saturated: false,
            any_relay_responded: true,
        }
    }

    // ---- The headline: the advance comes from the window, not from any event.

    #[test]
    fn a_clean_window_advances_to_its_own_open_time() {
        let batch = [(10, O::Applied), (20, O::Applied)];
        assert_eq!(
            cursor_advance_ms(healthy(), &hold_backs(&batch), NOW),
            Some(OPENED * 1000),
            "a completed window means 'the relays held nothing else as of the \
             moment I asked' — that local instant is the advance, not the \
             newest event's remotely-chosen created_at",
        );
    }

    #[test]
    fn no_event_timestamp_can_raise_the_advance() {
        // THE ATTACK. An observer of the circle's public `#h` re-wraps a genuine
        // ciphertext under a throwaway key at a `created_at` of its choosing.
        // The outer AEAD still opens and the inner MLS message still
        // authenticates, so the engine reports Processed/Stale — an `Applied`
        // here. Under the old contiguous-prefix rule the cursor jumped to
        // 999_999_999, burying the genuine event at 10 beneath a permanently
        // raised REQ floor. It must now be inert.
        let forged_high = [(10, O::Applied), (999_999_999, O::Applied)];
        assert_eq!(
            cursor_advance_ms(healthy(), &hold_backs(&forged_high), NOW),
            Some(OPENED * 1000),
        );
        // ...and the same forgery screened before authentication, likewise.
        let forged_pre_auth = [(10, O::Applied), (999_999_999, O::NoEvidence)];
        assert_eq!(
            cursor_advance_ms(healthy(), &hold_backs(&forged_pre_auth), NOW),
            Some(OPENED * 1000),
        );
        // ...and a whole window of nothing but forgeries.
        let only_forgeries = [(888_888_888, O::Applied), (999_999_999, O::NoEvidence)];
        assert_eq!(
            cursor_advance_ms(healthy(), &hold_backs(&only_forgeries), NOW),
            Some(OPENED * 1000),
            "an attacker's created_at must not appear in the result at ANY \
             magnitude — the window open time is the ceiling",
        );
    }

    #[test]
    fn an_empty_window_still_advances() {
        // The availability direction. A quiet circle whose relays hold nothing
        // new is fully caught up as of the open time; the old rule stalled here
        // forever because no event had "applied".
        assert_eq!(cursor_advance_ms(healthy(), &[], NOW), Some(OPENED * 1000),);
    }

    #[test]
    fn a_window_of_only_expired_or_undecryptable_events_still_advances() {
        // Two shapes that both stalled the contiguous prefix at index 0 and can
        // each be produced remotely for free: a run of pre-auth-screened
        // (expired) events, and a run of engine-terminal ones (`Stale`, which is
        // what an undecryptable or future-epoch application message yields).
        let all_expired = [(1, O::NoEvidence), (2, O::NoEvidence)];
        let all_stale = [(1, O::Applied), (2, O::Applied)];
        for batch in [all_expired.as_slice(), all_stale.as_slice()] {
            assert_eq!(
                cursor_advance_ms(healthy(), &hold_backs(batch), NOW),
                Some(OPENED * 1000),
                "neither shape may wedge the cursor: the sweep still fetched the \
                 whole window, so it is caught up to the open time",
            );
        }
    }

    // ---- Hold-backs: the ONE place a remote timestamp enters, lowering only.

    #[test]
    fn an_unapplied_event_holds_the_cursor_at_itself() {
        // [Applied@10, Deferred@20, Applied@30]: something at 20 is still
        // outstanding, so the advance stops there and the next sweep's `since`
        // (cursor − buffer) re-requests it.
        let batch = [(10, O::Applied), (20, O::Deferred), (30, O::Applied)];
        assert_eq!(
            cursor_advance_ms(healthy(), &hold_backs(&batch), NOW),
            Some(20_000),
        );
    }

    #[test]
    fn the_oldest_unapplied_event_is_the_one_that_holds() {
        // Several deferrals ⇒ the MINIMUM wins, so nothing outstanding is ever
        // jumped over.
        let batch = [
            (50, O::Deferred),
            (20, O::Deferred),
            (30, O::Applied),
            (40, O::Deferred),
        ];
        assert_eq!(
            cursor_advance_ms(healthy(), &hold_backs(&batch), NOW),
            Some(20_000),
        );
    }

    #[test]
    fn a_hold_back_above_the_open_time_cannot_raise_the_advance() {
        // The asymmetry, at this layer: a deferral is the only remotely-written
        // number reaching the computation, and a hostile one dated in the far
        // future must be inert rather than a lever.
        let batch = [(999_999_999, O::Deferred)];
        assert_eq!(
            cursor_advance_ms(healthy(), &hold_backs(&batch), NOW),
            Some(OPENED * 1000),
        );
    }

    #[test]
    fn only_deferred_events_hold_the_cursor_back() {
        // `Applied` and `NoEvidence` must contribute NO hold-back: an `Applied`
        // has nothing outstanding, and letting a pre-auth rejection hold would
        // sell an attacker a permanent stall for one forged event.
        let batch = [(5, O::Applied), (6, O::NoEvidence), (7, O::Deferred)];
        assert_eq!(hold_backs(&batch), vec![7]);
    }

    // ---- Gates that block the advance outright (facts about the FETCH).

    #[test]
    fn a_saturated_window_never_advances() {
        // Rule 12. NIP-01 `limit: n` returns the NEWEST n, so a truncated window
        // has an unretrieved tail BELOW it, indistinguishable from a complete
        // one in the events themselves. A dropped location merely ages out; a
        // dropped COMMIT strands the epoch chain.
        let all_applied = [(1, O::Applied), (2, O::Applied), (3, O::Applied)];
        assert_eq!(
            cursor_advance_ms(healthy(), &hold_backs(&all_applied), NOW),
            Some(OPENED * 1000),
            "precondition: this window DOES advance when not saturated — \
             otherwise the assertion below passes for the wrong reason",
        );
        let saturated = FetchWindow {
            saturated: true,
            ..healthy()
        };
        assert_eq!(
            cursor_advance_ms(saturated, &hold_backs(&all_applied), NOW),
            None
        );
        // ...and saturation blocks an EMPTY window too, so the new
        // "empty windows advance" rule cannot sneak past it.
        assert_eq!(cursor_advance_ms(saturated, &[], NOW), None);
    }

    #[test]
    fn a_window_no_relay_answered_never_advances() {
        // "The relays held nothing new" and "we could not ask" are the same
        // empty list. Claiming the first would skip whatever accumulated during
        // the outage — and this is precisely the case the window-open anchor
        // would otherwise wave through.
        let unreachable = FetchWindow {
            any_relay_responded: false,
            ..healthy()
        };
        assert_eq!(cursor_advance_ms(unreachable, &[], NOW), None);
        assert_eq!(
            cursor_advance_ms(unreachable, &hold_backs(&[(1, O::Applied)]), NOW),
            None,
        );
    }

    #[test]
    fn the_two_fetch_gates_block_independently() {
        // Neither subsumes the other, and each alone is sufficient.
        let both = FetchWindow {
            saturated: true,
            any_relay_responded: false,
            ..healthy()
        };
        assert_eq!(cursor_advance_ms(both, &[], NOW), None);
    }

    // ---- The clamp: no window may push the cursor past the local clock.

    #[test]
    fn a_future_window_open_time_clamps_to_now() {
        // `opened_at_secs` is read before the fetch and `now_secs` after it, so
        // they normally satisfy opened <= now. A clock stepped BACKWARDS during
        // a long sweep inverts that; the cursor must still never land in the
        // future, where `since_for_stream` pins every REQ floor at `now` for the
        // duration of the skew.
        let now = 1_000_i64;
        let ahead = FetchWindow {
            opened_at_secs: now + 900,
            ..healthy()
        };
        assert_eq!(cursor_advance_ms(ahead, &[], now), Some(now * 1000));
    }

    #[test]
    fn the_clamp_leaves_a_normal_window_alone() {
        // The complement: clamping must not become a blanket "always now",
        // which would push the cursor PAST a hold-back.
        let now = 2_000_i64;
        assert_eq!(cursor_advance_ms(healthy(), &[400], now), Some(400_000),);
    }

    // ---- The deadline tail: FETCHED but never INGESTED is not "caught up".
    //
    // This one drives the real `sweep_one_circle` against a real relay, because
    // the property lives in the loop and not in the arithmetic: an anchor keyed
    // on the window's open time will happily claim events the deadline stopped
    // the sweep from reaching, and no assertion over `cursor_advance_ms` alone
    // can see that.

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_deadline_that_cuts_the_batch_short_holds_the_cursor_at_the_unreached_tail() {
        use super::{sweep_one_circle, CatchupOutcome};
        use crate::relay::live_sync::group_cursor_stream;

        let _ = crate::relay::allow_ws_loopback_for_test();
        let relay = nostr_relay_builder::MockRelay::run().await.expect("relay");
        let url = relay.url().await.to_string();
        let relay_mgr = RelayManager::new();

        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let mgr = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();
        let ngid = [0x5Cu8; 32];
        let h = hex::encode(ngid);

        // Two events in the window, both older than the sweep. The OLDEST is the
        // one the advance must not pass.
        let now = chrono::Utc::now().timestamp();
        let oldest = now - 3600;
        for at in [oldest, now - 1800] {
            let ev = EventBuilder::new(Kind::Custom(445), "b3BhcXVl")
                .tags(vec![Tag::parse(["h", &h]).unwrap()])
                .custom_created_at(Timestamp::from(u64::try_from(at).unwrap()))
                .sign_with_keys(&Keys::generate())
                .unwrap();
            relay_mgr
                .publish_event(&ev, std::slice::from_ref(&url))
                .await
                .expect("publish");
        }

        // An ALREADY-EXPIRED deadline: the fetch still runs (the deadline is
        // checked per event, after it), then the ingest loop breaks at index 0.
        let mut out = CatchupOutcome::default();
        sweep_one_circle(
            &mgr,
            &relay_mgr,
            ngid,
            std::slice::from_ref(&url),
            &keys.public_key().to_hex(),
            std::time::Instant::now(),
            &mut out,
        )
        .await;

        assert!(
            out.deadline_hit,
            "precondition: the deadline must really have cut the batch short"
        );
        assert_eq!(
            out.events_deferred, 2,
            "precondition: both fetched-but-unreached events must be counted as \
             deferred, or the assertion below proves nothing"
        );
        assert_eq!(out.events_applied, 0);

        let cursor = mgr
            .read_sync_cursor(&group_cursor_stream(&h))
            .expect("cursor read");
        assert!(
            cursor.is_none_or(|ms| ms <= oldest * 1000),
            "the advance must not claim events the sweep never ingested; got \
             {cursor:?} for an unreached tail starting at {oldest} s",
        );
    }

    // ---- The classifier that feeds the arithmetic above.
    //
    // The gates above are pure arithmetic over a `ReceiveOnlyOutcome`; these two
    // pin the only thing that produces one. Driven through the REAL private
    // `ingest_one` (a hand-built `(i64, ReceiveOnlyOutcome)` tuple would prove
    // nothing about the sweep).
    //
    // These live here rather than in `tests/cursor_poisoning_e2e.rs` because the
    // sweep's own end-to-end path cannot carry an already-expired event:
    // `MockRelay` is backed by `nostr-database`, which refuses to save an expired
    // event and filters expired events out of every query (`helper.rs:193,216`).
    // Being NIP-40-conformant, it will not serve the input this screen exists to
    // defend against — which is the screen's premise, not a gap in it.

    use crate::circle::CircleManager;
    use crate::relay::RelayManager;
    use nostr::{EventBuilder, Keys, Kind, Tag, Timestamp};
    use tempfile::TempDir;

    /// A `kind:445` routed at `h`, minted by a throwaway key that belongs to no
    /// member — exactly what any relay observer can produce.
    fn unauthenticated_445(h: &str, expired: bool) -> nostr::Event {
        let mut tags = vec![Tag::parse(["h", h]).unwrap()];
        if expired {
            tags.push(Tag::expiration(Timestamp::from(
                Timestamp::now().as_secs() - 3600,
            )));
        }
        EventBuilder::new(Kind::Custom(445), "b3BhcXVl")
            .tags(tags)
            .sign_with_keys(&Keys::generate())
            .unwrap()
    }

    #[tokio::test]
    async fn ingest_one_reports_no_evidence_for_a_pre_auth_rejection() {
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let mgr = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();
        let relay_mgr = RelayManager::new();
        let ngid = [0x8Au8; 32];
        let h = hex::encode(ngid);
        let own = keys.public_key().to_hex();

        let expired = unauthenticated_445(&h, true);
        assert_eq!(
            ingest_one(&mgr, &relay_mgr, &expired, &ngid, &own).await,
            ReceiveOnlyOutcome::NoEvidence,
            "an event screened before authentication must contribute NO cursor \
             evidence — reporting `Applied` here is the defect, and reporting \
             `Deferred` would let one forged event stall the sweep forever"
        );
    }

    #[tokio::test]
    async fn ingest_one_does_not_report_no_evidence_for_engine_verdicts() {
        // Anti-vacuity: the same unauthenticated event WITHOUT the expiration
        // tag reaches the engine, so whatever comes back is an engine verdict —
        // never `NoEvidence`. Without this, the gate above would pass just as
        // well if `ingest_one` returned `NoEvidence` unconditionally.
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let mgr = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();
        let relay_mgr = RelayManager::new();
        let ngid = [0x8Au8; 32];
        let h = hex::encode(ngid);
        let own = keys.public_key().to_hex();

        let unexpired = unauthenticated_445(&h, false);
        assert_ne!(
            ingest_one(&mgr, &relay_mgr, &unexpired, &ngid, &own).await,
            ReceiveOnlyOutcome::NoEvidence,
            "only Haven's own pre-auth screen may produce `NoEvidence`"
        );
    }
}
