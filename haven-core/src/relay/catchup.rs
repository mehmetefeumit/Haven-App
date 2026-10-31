//! Cursor-anchored catch-up sweep (M7).
//!
//! A best-effort, deadline-bounded fetch that pulls whatever a circle's relays
//! hold since the persisted cursor and feeds it to the Dark Matter engine in the
//! background / on foreground resume. The engine owns convergence,
//! out-of-order sequencing, and publish-before-apply internally, so this sweep
//! no longer needs the Haven-owned staged-commit marker or a per-circle write
//! gate — it just ingests, then advances the cursor to the window's own open
//! time, held back at anything it could not apply (see "Cursor safety" below).
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
//! (`saturated`) and at least one of the circle's relays FINISHED answering.
//! "Finished" is the relay's own NIP-01 `EOSE` and nothing else — see
//! [`crate::relay::RelayFetchOutcome::drained`] and [`summarize_round`] for why
//! nothing in a page's contents can stand in for it. Anything the sweep could
//! not APPLY — an engine `Buffered`, a hard ingest failure, or an event the
//! deadline stopped us reaching — holds the advance at or below that event so it
//! is re-fetched next sweep.
//!
//! That hold is bounded in TIME, not in evidence: a relay cut off on every sweep
//! would otherwise hold a circle's cursor for ever, so after
//! [`CATCHUP_MAX_CUTOFF_HOLDS`] consecutive sweeps held on nothing else, one
//! sweep treats it as unreached instead. A permanent freeze costs more than the
//! residual it was buying.
//!
//! # Backward paging
//!
//! A page is not the end of a window: the sweep re-issues the request bounded
//! above by the oldest event it has been served ([`Pager`]) until a round brings
//! back nothing new, so a saturated window can actually COMPLETE instead of
//! freezing its circle's cursor forever. The chase is driven by what a page
//! CONTRIBUTES rather than by how big it is ([`summarize_round`] argues why a
//! relay's own `limit` cap makes size useless). That next `until` is the one
//! remotely-written number steering a request; [`summarize_round`] argues where
//! it may come from and [`Pager::step`] argues how far it may be followed.
//! Everything neither can establish from a local fact leaves the window marked
//! `saturated` and the cursor held.
//!
//! Each page is INGESTED before the next is fetched. A wake budget is 20-25 s
//! and a chase can outlast it, so a sweep that collected every page before
//! applying any applied NOTHING whenever the deadline landed mid-chase — and,
//! with the cursor rightly held, did the same on the next wake and the one after
//! it. Paying per page costs the engine out-of-order delivery (pages descend)
//! and buys forward progress on every wake — with one floor to make that
//! unconditional: the opening fetch can spend the WHOLE budget on its own, so a
//! sweep that ENTERED with budget applies one event of what it fetched before
//! the deadline binds again ([`CircleSweep::ingest_page`]).
//!
//! A boundary is followed only while it DESCENDS, and the first page's `until`
//! is the window's own open second — so that second is the one the chase cannot
//! step below. It is re-asked exactly once instead (see
//! [`CircleSweep::fetch_and_ingest`]), which is what keeps a quiet circle
//! publishing its only event in the second a sweep opened from losing that sweep
//! to a boundary that could not descend.
//!
//! A chase that runs out of budget persists the `until` it stopped at as that
//! circle's backfill floor, and the NEXT sweep spends a second pass resuming
//! there, so a backlog bigger than one sweep can retrieve is walked down over
//! successive sweeps instead of having its oldest tail fetched by nobody. The
//! floor claims nothing about the band above it and licenses no advance on its
//! own; the pass that resumes there must complete its own chase over
//! `[since, floor]` first — see [`sweep_one_circle`] and
//! [`CATCHUP_MAX_PAGES_PER_CIRCLE`].
//!
//! Walking down is not on its own convergence, and the difference is a real
//! failure the sweep has to avoid. The band ONE pass can finish is bounded by
//! one page budget, while the top-down pass restarts at `now` every sweep — so a
//! sweep that could only ever claim a single pass's band would advance to the
//! same place for ever, re-fetching and re-ingesting the same window on every
//! wake with the cursor pinned. [`sweep_one_circle`] therefore COMPOSES its two
//! passes: a contiguous retrieval that comes down to meet the cursor covers the
//! whole window between them, which neither pass did alone.
//!
//! # What is deliberately NOT held back
//!
//! An `IngestOutcome::Stale` does not hold the cursor, and neither does
//! `IngestOutcome::TransportDeferred`, which is what a genuine future-epoch
//! APPLICATION message produces — it is *not* `Buffered`. The engine keeps
//! such a message as a deferred row and re-peels it by itself once the
//! missing commit lands, so recovery is the engine's, not the cursor's. Holding on it would freeze the cursor of any client that is
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
/// Only ONE of them is a reason to hold the cursor back, and none is a
/// reason to move it forward — the advance comes from the fetch window, never
/// from an event (see the module docs).
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
    /// The engine buffered the message for a future epoch, the ENGINE's ingest
    /// failed hard, or the sweep's deadline stopped us reaching it. Something at
    /// this position is still outstanding, so the cursor is held at or below this
    /// event's `created_at` and the event is re-fetched next sweep.
    ///
    /// A hard failure lands here only once the envelope has parsed and the
    /// engine has taken the message; an envelope the pre-engine parse could not
    /// read is [`Self::NoEvidence`], so this hold-back cannot be minted from
    /// outside without ciphertext the engine will actually work on.
    Deferred,
    /// Haven's local receiver-side screen rejected the event BEFORE any MLS
    /// authentication ran (see [`crate::nostr::mls::types::ScreenedIngest`]) —
    /// an envelope the pure pre-engine transport parse could not read at all.
    ///
    /// Contributes nothing in EITHER direction. It is not evidence the sweep
    /// caught up to its `created_at` (nothing authenticated that timestamp), and
    /// it is not evidence of a gap (there is no un-applied message to come back
    /// for) — so it must not hold the cursor either, or one forged event would
    /// buy an attacker a permanent stall. Tallied separately as
    /// [`CatchupOutcome::events_rejected_pre_auth`].
    NoEvidence,
    /// The engine answered from a row it holds STRANDED: the event as it
    /// arrived, unopened, in a circle that holds no commit of this device's
    /// own pending, which nothing but the engine's own replay reads again
    /// (`docs/MDK_UPSTREAM_TRACKER.md` T-PARKED-REPLAY) — and which Haven
    /// could not take over to hand back (`SessionManager::hand_back_stranded`).
    ///
    /// Not applied, and not a hold either: the answer comes from the stored
    /// row and is the same at every redelivery, so a held cursor would fetch
    /// the event again for as long as a relay serves it — for good, for a
    /// commit or a proposal, which carry no expiration. Its circle is told
    /// ([`crate::nostr::mls::ChangeNote::UnreadChange`]). Tallied as
    /// [`CatchupOutcome::events_stranded`].
    Stranded,
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
    /// authentication ran: envelopes the pure pre-engine transport parse could
    /// not read (forged or genuine). Neither applied nor deferred: they
    /// contribute no cursor evidence at all. A persistently non-zero count on a
    /// healthy circle means something on the wire is emitting `kind:445`s Haven
    /// cannot parse.
    pub events_rejected_pre_auth: usize,
    /// Events the engine answered from a row it holds stranded
    /// ([`ReceiveOnlyOutcome::Stranded`]): neither applied nor a reason to
    /// hold a cursor.
    pub events_stranded: usize,
    /// Per-circle group cursors advanced.
    pub cursors_advanced: usize,
    /// The deadline was reached before every bucket was swept.
    pub deadline_hit: bool,
    /// Per-relay fetches that did not finish answering: unreachable, or cut off
    /// before their end-of-stored-events (tallied, never fatal).
    pub relay_errors: usize,
    /// Circles this sweep did not advance the cursor for: counted ONCE per
    /// circle, and exactly the negation of the advance condition
    /// ([`cursor_advance_ms`]) — the chase ran out of pages, of events, of
    /// deadline, or of a trustworthy answer, or no relay finished answering at
    /// all.
    ///
    /// **Only that negation, in both directions, and neither is a drain check.**
    /// Non-zero is weaker than "backlog remains": a contradicted or cut-off read
    /// may have been over a window that was in fact complete. ZERO is weaker
    /// than "this circle is drained": a sweep advances on the band it
    /// established, which may be a sub-band its passes composed rather than the
    /// whole window ([`sweep_one_circle`]), and a chase completes over the
    /// one-second pile-up a relay's own `limit` cap can hide from every request
    /// ([`Pager::step`]). Not an error either way.
    pub windows_truncated: usize,
    /// How long until there is next something to do for a commit or proposal
    /// record this sweep drove and left stored — a relay due again, a bound
    /// reached — when there is. Never less than the driver's own shortest
    /// wait, so a scheduler that honours it cannot spin. `None` from the sweep
    /// that drives nothing. Relative, and never logged.
    pub retry_after_ms: Option<u64>,
    /// A drive this sweep made ended on an error. What it had done stands,
    /// and the stored records say where each commit is.
    pub drive_errored: bool,
}

/// Max events one REQ may return — a flood-guard (Rule 12) so a malicious relay
/// cannot answer a single page with an unbounded batch a background wake would
/// then ingest.
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
/// So a truncated page is not the end of the window: [`Pager`] chases the tail
/// with further pages bounded above by the oldest event served so far, and the
/// cursor is held still ([`cursor_advance_ms`]) for as long as that chase is
/// unfinished. Each page is ingested as it arrives, so the engine still makes
/// progress on a window that stayed incomplete — and on one the deadline cut off
/// mid-chase, which is the common way a big backlog ends.
///
/// # Why this number no longer decides whether the chase runs
///
/// strfry — which all three of Haven's default relays run, and which the E2E
/// harness runs too — ships its NIP-11 `limitation.max_limit` at exactly this
/// number, so a chase keyed on "the relay returned as many events as we asked
/// for" would never start against one at all. The chase runs on what a page
/// CONTRIBUTES instead ([`summarize_round`] carries that argument), and this
/// number is once more only what its name says.
///
/// Public so the soak rig's saturation predicate reads this bound, never a copy.
pub const CATCHUP_MAX_EVENTS_PER_PAGE: usize = 500;

/// Max backward pages one circle's window may cost in a single sweep.
///
/// Paging is what removed the per-page limit's second job (bounding the SWEEP,
/// not just one response), so the Rule-12 backpressure moved here: a relay that
/// answers every page in full cannot make one circle unbounded in requests, in
/// time, or in events held. Hitting this bound leaves the window marked
/// INCOMPLETE, so the cursor holds and nothing is silently treated as caught up.
///
/// # What hitting it does, and what stops the remainder being orphaned
///
/// On its own it schedules nothing for later: a sweep that restarted the chase
/// at the newest end of the same `since` every time would fetch the same newest
/// pages over and over while the oldest tail was fetched by no sweep at all.
/// Nothing would be DROPPED — the cursor never advances over it, so it stays
/// reachable — but nothing would reach it either, and a circle past this budget
/// would quietly stop converging.
///
/// So the `until` of the LAST page a halted chase issued is persisted as that
/// circle's backfill floor, and the next sweep spends a SECOND pass resuming the
/// descent there ([`CircleSweep::fetch_and_ingest`], driven from
/// [`sweep_one_circle`]). The floor is not a claim about the band ABOVE it and
/// is never read as one: it only says where to look next, and a resumed pass
/// must complete its own chase over `[since, floor]` — under the identical rules
/// that license the ordinary advance — before anything is claimed. That is what
/// keeps it clear of the cursor-poisoning shape: the stored number is a request
/// ceiling this device issued, already confined to the local
/// `[since, window open]` band, it only ever descends while a descent is
/// unfinished, and discarding it costs one sweep of re-fetching rather than a
/// skip.
///
/// The cost is that a circle which already failed to finish may spend two page
/// budgets instead of one. The DEADLINE is unchanged and still bounds both
/// passes (`out_of_time` is read inside each), so the wake budget cannot be
/// exceeded; what doubles is the requests one badly backlogged circle may make
/// inside it, and only for as long as it stays backlogged.
///
/// # And the wake-budget consequence, which is real
///
/// A wake budget is 20–25 s while one page's fetch is bounded by the relay
/// timeout, so the DEADLINE, not this constant, is what usually stops a long
/// chase. One badly backlogged circle can spend the whole wake where it
/// previously cost a single round, after which `run_catchup_all_circles` breaks
/// before the remaining circles are swept at all — they simply wait for the next
/// wake, cursors untouched. What it no longer costs is the ingest: pages are
/// applied as they arrive, so a deadline landing mid-chase leaves everything
/// fetched so far APPLIED. Deferring the whole union instead made the next wake
/// re-fetch the same pages and apply nothing again, on every wake, for as long
/// as the backlog outlasted the budget.
///
/// Public so the soak rig's multi-page backlog is sized from this bound, never a copy.
pub const CATCHUP_MAX_PAGES_PER_CIRCLE: usize = 8;

/// Max unique events one circle's paged window may take in a single sweep.
///
/// The page bound alone does not bound the sweep: every page is put to EVERY
/// relay in the circle's list, so a round costs `CATCHUP_MAX_EVENTS_PER_PAGE` ×
/// a user-configurable relay count. Deliberately equal to a full single-relay
/// chase (pages × page size) so it only ever binds on a multi-relay circle.
///
/// It is a ceiling on the ACCUMULATED count, checked once a whole round has been
/// taken, so the true worst case is this plus one round. That extra round is not
/// avoidable by checking earlier: the fetch fans out to every relay
/// concurrently, so its events are already resident inside
/// `fetch_events_per_relay`'s return value before this code can look at them.
/// Since each page is ingested and dropped, what stays resident is that one
/// round plus an event id and a `(secs, outcome)` pair per unique event; the
/// ceiling's real subject is the WORK one circle may ask of the engine on one
/// wake, which is the Rule-12 surface that matters here. Same honesty rule as
/// above: reaching the ceiling marks the window incomplete.
const CATCHUP_MAX_EVENTS_PER_CIRCLE: usize =
    CATCHUP_MAX_PAGES_PER_CIRCLE * CATCHUP_MAX_EVENTS_PER_PAGE;

/// How many sweeps in a row a circle's cursor may be held on nothing but a
/// relay's cut-off delivery before that relay is treated as UNREACHED instead.
///
/// # Why the hold needs an end at all
///
/// A page nobody signalled `EOSE` for is a prefix of an unknown whole, so it
/// rightly holds the sweep it arrived in ([`summarize_round`]). But the evidence
/// repeats: the same relay, cut off on the next sweep and the one after, holds
/// the same cursor again. With no bound, one entry in a user-editable relay list
/// that omits six bytes — or one that trips this device's own intake cap, which
/// needs no adversary at all — freezes a circle's cursor permanently. The window
/// then only grows, every later sweep re-fetches and re-ingests it whole, and
/// the circle is out of service for good: strictly worse than the residual the
/// hold was protecting, and available for free.
///
/// # ...and why it is a delay rather than a downgrade
///
/// Spending the tolerance moves the offending relay onto the side of the line a
/// relay the fetch never REACHED already sits on — no more, no less. The
/// residual is then exactly the coverage assumption [`cursor_advance_ms`] already
/// documents for an unreachable relay (an event held ONLY there may be missed),
/// and it is bought only after this many consecutive sweeps of asking properly.
/// The count resets the moment the circle advances, so a transient cut — a
/// dropped radio, a relay restart — never reaches it, and a permanent one costs
/// a bounded delay instead of an unbounded outage.
const CATCHUP_MAX_CUTOFF_HOLDS: i64 = 3;

use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use nostr::{Event, EventId, Filter, Kind, Timestamp};

use crate::circle::{CircleManager, DirectoryReconcile};
use crate::nostr::mls::types::{
    EpochState, FanoutId, GroupId, IngestOutcome, PublishWork, ScreenedIngest, SessionEffects,
};
use crate::nostr::mls::{IngestClass, RangePass, SessionManager};
use crate::relay::cursor::{since_for_stream, SubscribePhase};
use crate::relay::fanout::{
    DriveMode, FanoutClock, FanoutSend, Publishing, ResumeOutcome, Still, WallClock, BUSY_RETRY_MS,
};
use crate::relay::live_sync::group_cursor_stream;
use crate::relay::live_sync::planes::group::group_filter;
use crate::relay::negentropy::{self, NegRoute, NegSink, NEG_ROUTE_WAIT};
use crate::relay::retick::{next_receive_retick, owe_unfinished, MAX_CONVERGENCE_RETICKS};
use crate::relay::{RelayFetchOutcome, RelayManager};

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
    /// The newest instant this window can claim to have retrieved everything at
    /// or below — the `until` its FIRST page was issued with, and the advance
    /// target. One ceiling for the whole page chain.
    ///
    /// For the sweep's own pass this is a LOCAL wall-clock reading taken BEFORE
    /// the circle's first REQ went out. For a resumed backfill pass it is the
    /// persisted floor: a request ceiling THIS device chose in an earlier sweep,
    /// which that sweep had already confined to its own
    /// `[since, window open]` band. Neither is writable by a remote party, and
    /// neither can exceed a local clock reading.
    pub ceiling_secs: i64,
    /// Some relay truncated a page and [`Pager`] did not finish retrieving the
    /// tail below it, so the window is INCOMPLETE (Security Rule 12).
    pub saturated: bool,
    /// At least one of the circle's relays FINISHED answering — it signalled
    /// end-of-stored-events for a page of this window
    /// ([`RelayFetchOutcome::drained`]). With none, the window is empty for a
    /// reason that says nothing about the circle's traffic: nobody was reached,
    /// or everybody's delivery was cut off part-way.
    pub any_relay_drained: bool,
}

/// What ONE pass of the paged chase retrieved, and where it stopped.
///
/// Timestamps and flags only, so the derived `Debug` is leak-free by
/// construction (Security Rules 4/6).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct PassResult {
    /// The two FETCH-level facts [`cursor_advance_ms`] gates the advance on,
    /// plus the ceiling the advance would be taken from.
    window: FetchWindow,
    /// The `until` of the LAST page this pass issued — a request ceiling THIS
    /// device chose, confined by [`Pager::step`] to the locally chosen
    /// `[since, ceiling]` band.
    ///
    /// Meaningful only when the pass did NOT finish, where it is the ceiling of
    /// the region still to retrieve and becomes the circle's persisted backfill
    /// floor. Everything STRICTLY ABOVE it was retrieved by the rounds that got
    /// this far, so it is also where a later pass may pick the descent up
    /// without leaving a band in between.
    ///
    /// Deliberately the request the pass ISSUED and not the boundary the round
    /// that halted proposed. From page two that request is itself an earlier
    /// round's boundary — a remote number — but one [`Pager::step`] had already
    /// confined to the locally chosen `[since, ceiling]` band and already spent;
    /// the halting round's own boundary is discarded unexamined. The events at
    /// this ceiling are then re-fetched by the pass that resumes there, which
    /// costs one page and needs no fresh trust.
    last_until_secs: i64,
    /// Some relay in this pass handed over events and never signalled
    /// end-of-stored-events ([`RoundSummary::cut_off`]).
    cut_off: bool,
    /// The pass halted on a FULL page dated entirely at
    /// [`Self::last_until_secs`]: what that second holds past a relay's page
    /// limit no `until` can reach (NIP-01's grain is one second), so only a
    /// walk that steps below it can go further ([`CircleSweep::by_range`]).
    full_at_until: bool,
}

/// The lowest instant a pass's own retrieval reaches, contiguously, down from
/// its ceiling.
///
/// A finished pass reaches its REQ floor: nothing at all is left below it. A
/// halted one reaches the `until` of the page it stopped at — every round before
/// that was trustworthy and descended from the one above it, so everything
/// STRICTLY above that request has been served, and nothing beneath it has been
/// asked for.
#[must_use]
const fn pass_reach(pass: &PassResult, since_secs: i64) -> i64 {
    if pass.window.saturated {
        pass.last_until_secs
    } else {
        since_secs
    }
}

/// What the sweep does after one round of per-relay pages.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PageStep {
    /// Nothing is left below what we hold: the window is complete down to its
    /// own `since` and the cursor may advance.
    Complete,
    /// Issue one more page, bounded above by this `until` (unix seconds).
    Next(i64),
    /// Nobody contributed, but somebody handed back a non-empty page of events
    /// we already hold — which a drained relay and a relay CLAMPING at a
    /// one-second pile-up produce identically. Ask again one second lower
    /// (unix seconds); that answer tells them apart where the page's content
    /// cannot. See [`Pager::step`].
    Confirm(i64),
    /// The window is still incomplete and no further page may be issued. The
    /// cursor holds; the remainder is re-fetched next sweep.
    Halt,
}

/// The backward pager's LOCAL state. The termination rule reads exactly these
/// numbers plus one remotely-written timestamp, and no remote party can write
/// any of these.
///
/// Kept as a named struct for the same reason as [`FetchWindow`]: so the
/// trusted local band can never be confused at a call site with the remote
/// number it confines.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Pager {
    /// The REQ floor shared by every page, derived from the persisted cursor
    /// before the first page went out.
    since_secs: i64,
    /// EXCLUSIVE ceiling of the range still to retrieve: a boundary is followed
    /// only while it sits strictly below this, so the number descends with every
    /// page. A REQ's `until` is INCLUSIVE, so this starts one second above the
    /// window's own open time — see [`CircleSweep::fetch_and_ingest`], which
    /// argues what that one second buys and why it cannot be spent twice.
    bound_secs: i64,
    /// The INCLUSIVE `until` the page just answered was issued with — the
    /// request whose completeness this round is being asked about.
    until_secs: i64,
    /// The page just answered was already a [`PageStep::Confirm`] step below the
    /// previous boundary, so a second round with nothing new ends the chase
    /// rather than stepping again. Bounds the confirming step to one per STALL —
    /// every [`PageStep::Next`] clears it, so a chase that descends again may
    /// confirm again lower down ([`Pager::step`]).
    confirming: bool,
    /// Pages already issued for this circle in this sweep.
    pages: usize,
    /// Unique events collected across those pages.
    collected: usize,
}

impl Pager {
    /// Decides the next move after one round of per-relay pages.
    ///
    /// `boundary_secs` is [`RoundSummary::boundary_secs`]: the oldest
    /// `created_at` served by a relay that is still CONTRIBUTING, maximised
    /// across such relays, or `None` when no responding relay contributed
    /// anything. `read_incomplete` is [`RoundSummary::read_incomplete`]: an
    /// answer went missing, contradicted an earlier one, or came through a fetch
    /// that may have been cut off part-way.
    ///
    /// # The termination rule, and the attack it is written against
    ///
    /// Exactly ONE exit reports a complete window: a round we can trust in which
    /// no responding relay contributed — nobody handed back a full page
    /// (`page.len() >= CATCHUP_MAX_EVENTS_PER_PAGE`), and nothing anybody handed
    /// back was an event we did not already hold. Both halves are LOCAL facts
    /// about the FETCH — a count of what arrived, and a membership test against
    /// ids we already have — in the same sense [`cursor_advance_ms`]'s two gates
    /// are, never a claim read out of an event's contents. Every other path
    /// through this function returns [`PageStep::Halt`], which leaves the window
    /// `saturated` and the cursor held. (Being merely LATE is not one of them:
    /// `out_of_time` is read only once a round has something left to do, because
    /// a deadline that expires over a window nobody was still draining has not
    /// made that window incomplete.)
    ///
    /// # ...and why that exit needs ONE confirming step below it
    ///
    /// "Nobody contributed" is not by itself proof that the relays are drained,
    /// and the gap needs no attacker: a relay CLAMPING our `limit` at a
    /// one-second pile-up answers the identical page every round (the argument
    /// is [`summarize_round`]'s). Neither half of the contribution test can see
    /// it — the page never reaches OUR limit, and a repeat is new to nobody —
    /// and nothing about the page's CONTENT distinguishes it from a relay whose
    /// oldest events genuinely sit in that second.
    ///
    /// So the question is asked instead of guessed: step ONE second below the
    /// request that produced the repeat and issue it again
    /// ([`PageStep::Confirm`]). Nothing back means nothing was below it; events
    /// back mean the relay was clamping, and the chase carries on descending
    /// with them. An empty round needs none, because a relay that served zero
    /// events clamped nothing.
    ///
    /// `confirming` bounds it to one step per STALL, not one per chase: it is
    /// cleared by every [`PageStep::Next`], so a descent that stalls, confirms,
    /// is handed events and descends again may confirm again lower down. That is
    /// the point — each stall is a fresh ambiguity — and it cannot spin the
    /// loop, because a confirming step strictly lowers `until_secs` and the
    /// budget bounds the total.
    ///
    /// # The residual, which is a DROP and not a delay
    ///
    /// A clamp can hide events AT the second a confirming step lands on: they
    /// are addressable by no `until` at all, since `until` is inclusive and one
    /// second is the finest grain NIP-01 offers. Where that second is the band's
    /// own floor the step would leave the band, and this returns
    /// [`PageStep::Complete`] — so the window completes, the cursor advances
    /// past that second, and the tally reports no truncation. Whatever the clamp
    /// hid there is not re-fetched by a later sweep either, because `since` has
    /// moved above it. If a COMMIT is what it hid, the epoch chain strands, the
    /// same cost this module cites for advancing over a saturated window.
    ///
    /// It is kept anyway, and only because the alternative is worse in the same
    /// currency: holding produces the identical answer on every later sweep, so
    /// the circle freezes permanently rather than losing a one-second residual
    /// at the very bottom of one window. The residual is also the one the
    /// unpageable one-second pile-up already has, and a relay must be clamping
    /// below its own pile-up to produce it at all.
    ///
    /// The next page's `until` is, unavoidably, a remote number: the oldest
    /// `created_at` in a page a relay is still contributing to, at which the
    /// next page can then legitimately come back with nothing new. Two
    /// properties contain what a forged one can do:
    ///
    /// * **The boundary is the MAXIMUM across truncating relays**, so one
    ///   poisoned entry in a circle's relay list cannot curtail the paging of
    ///   the others — see [`summarize_round`], which carries that argument.
    /// * **The remote number is CONFINED to a locally chosen band.** It is
    ///   obeyed only while `since_secs <= boundary < bound_secs`: floored at our
    ///   own REQ floor, ceilinged one second above the window's own open time
    ///   (`bound_secs` is exclusive where a REQ's `until` is inclusive), and
    ///   descending from there — so a relay that repeats one page forever, or
    ///   dates a full page inside a single second, terminates the loop instead
    ///   of spinning it. The opening second is the one value the band admits
    ///   twice, and only because the second request is the FIRST one bounded by
    ///   it; a value outside the band is not followed at all, and halts the
    ///   chase with the window incomplete.
    ///
    /// # What a page cannot tell us
    ///
    /// A page is a local count of what ARRIVED, which is not the same as what
    /// the relay chose to serve. Two shapes live in that gap — a read that
    /// failed outright, and one cut off part-way — and [`summarize_round`]
    /// closes both with facts about the FETCH rather than about the page. Either
    /// arrives here as `read_incomplete`, and the window holds.
    ///
    /// **A relay lying about its own ordering** still ends its own chain early.
    /// That one is not a new exposure: the identical outcome is available to it
    /// by answering the FIRST page short while holding a backlog, i.e. plain
    /// withholding, which no receive-side rule can detect and which this design
    /// already treats as out of scope ("a relay that withholds events can
    /// already withhold them outright", [`cursor_advance_ms`]).
    ///
    /// Everywhere completeness cannot be established the answer is `Halt`: a
    /// conservative hold costs one re-fetch, a wrong advance costs the backlog.
    #[must_use]
    const fn step(
        self,
        boundary_secs: Option<i64>,
        repeat_page: bool,
        read_incomplete: bool,
        out_of_time: bool,
    ) -> PageStep {
        // An answer we cannot trust. Something we have local evidence for was
        // not delivered, so no round can establish completeness this sweep;
        // spending more of the deadline on further pages would only delay the
        // remaining circles for a window that cannot be finished now anyway.
        if read_incomplete {
            return PageStep::Halt;
        }
        let Some(boundary) = boundary_secs else {
            // Nobody contributed. Complete, unless somebody's non-empty page was
            // a repeat of what we already hold — the one answer a drained relay
            // and a relay clamping at a one-second pile-up share.
            if !repeat_page || self.confirming {
                return PageStep::Complete;
            }
            let below = self.until_secs.saturating_sub(1);
            // The step would leave the band. Completing here DROPS whatever a
            // clamp is hiding at this second rather than delaying it — the
            // cursor advances past it and no later sweep asks again — and is
            // still the better trade: holding produces this identical round on
            // every later sweep, so the circle freezes for good. See
            // `Pager::step`'s "the residual, which is a DROP and not a delay".
            if below < self.since_secs {
                return PageStep::Complete;
            }
            if self.out_of_budget(out_of_time) {
                return PageStep::Halt;
            }
            return PageStep::Confirm(below);
        };
        if boundary < self.since_secs
            || boundary >= self.bound_secs
            || self.out_of_budget(out_of_time)
        {
            return PageStep::Halt;
        }
        PageStep::Next(boundary)
    }

    /// Whether this circle has spent what one sweep may give it: the Rule-12
    /// backpressure bounds (pages, events held) or the wake's own deadline.
    #[must_use]
    const fn out_of_budget(self, out_of_time: bool) -> bool {
        self.pages >= CATCHUP_MAX_PAGES_PER_CIRCLE
            || self.collected >= CATCHUP_MAX_EVENTS_PER_CIRCLE
            || out_of_time
    }
}

/// What one ROUND of per-relay pages says about the FETCH — the only terms
/// [`Pager::step`] may read.
///
/// Deliberately NOT `Debug`, unlike every other struct in this file: it holds
/// relay URLs, which this codebase treats as sensitive (the fetch layer logs
/// their presence and never their text). The leak-free-by-construction property
/// the others get from having no sensitive fields is achieved here by having no
/// derived formatter at all.
#[derive(Default)]
struct RoundSummary {
    /// At least one relay FINISHED answering this round (it signalled
    /// end-of-stored-events).
    any_drained: bool,
    /// Relays that did not finish answering — unreachable, or cut off part-way
    /// (tallied as relay errors, never fatal).
    unanswered: usize,
    /// This round cannot establish completeness, whatever else it says: a relay
    /// we were still draining produced nothing, a relay that had already
    /// answered "nothing here" produced something, or a relay handed over part
    /// of a page and never said it was done. See below for each.
    read_incomplete: bool,
    /// The relays that handed over events and never signalled
    /// end-of-stored-events. Recorded separately from [`Self::read_incomplete`]
    /// because it is the ONE hold this sweep may run out of patience with (see
    /// [`CATCHUP_MAX_CUTOFF_HOLDS`]) — and by URL, because a relay we could not
    /// read to the end is dropped from the rest of the chase rather than
    /// re-asked, once per round, at the cost of a fetch timeout each time.
    cut_off: Vec<String>,
    /// The `until` for the next page: the oldest `created_at` served by a relay
    /// that is still contributing, MAXIMISED across such relays. `None` means
    /// nobody contributed, which is the shape that completes a window — once
    /// confirmed.
    boundary_secs: Option<i64>,
    /// Some relay handed back a NON-EMPTY page holding nothing we did not
    /// already have. Drained, or clamped at a one-second pile-up and repeating
    /// itself: identical answers, so [`Pager::step`] asks one second lower
    /// rather than choosing. An EMPTY page is deliberately not this — a relay
    /// that served no events clamped nothing.
    repeat_page: bool,
    /// The relays still being drained — those that handed back a full page or an
    /// event we did not already hold. One of them producing nothing next round
    /// is a hold rather than a "nobody contributed, therefore complete".
    chasing: HashSet<String>,
    /// Every relay that ANSWERED some round of this chain with nothing. Each has
    /// said "I hold nothing in this range" about a range that CONTAINS every
    /// later one, so any of them speaking later contradicts that. A relay the
    /// fetch could not reach is deliberately absent: it said nothing to
    /// contradict.
    silent: HashSet<String>,
}

/// Summarises one round's per-relay pages against what the rounds before it
/// established.
///
/// # What keeps the chase alive is CONTRIBUTION, not page size
///
/// A relay is still being drained if it handed back a full page (its own page
/// was cut at the bottom) OR an event we did not already hold. The second half
/// is what survives NIP-11 `limitation.max_limit`: a relay clamping our `limit`
/// to a smaller one of its own can never return "as many events as we asked
/// for", so a chase keyed on page size alone would never start against it and
/// the cursor would advance over everything below its cap. Contribution is
/// measured before dedup and per relay, so two relays that each hold a tail but
/// overlap heavily still each keep their own chase alive.
///
/// The complementary half is that a full page keeps the chase alive even when
/// every event in it is one we already hold — a relay serving one second's worth
/// of pile-up returns the same full page forever, and reading that as "nothing
/// new, therefore drained" would advance the cursor over the events below it
/// that no `until` can ever reach. That half fires at OUR limit only, so a
/// CLAMPING relay slips both tests at once: the same pile-up comes back
/// already-seen and short, forever, with a backlog sitting underneath. Such a
/// page is reported as [`RoundSummary::repeat_page`] and [`Pager::step`] settles
/// it by asking one second lower. An EMPTY page is deliberately not a repeat: a
/// relay that served no events clamped nothing.
///
/// # Why the boundary is the MAXIMUM across contributing relays
///
/// It is the one remotely-written number that steers a request, so which relay
/// it comes from matters. Taking the maximum makes the chain descend only as
/// fast as the SLOWEST-draining relay allows, so a relay that pads its page with
/// a forged ANCIENT event — proposing an `until` at which the next page
/// legitimately comes back with nothing new — cannot curtail the paging of the
/// honest relays beside it. That cross-relay curtailment is the only NEW power
/// backward paging could have granted: forging the bottom of a page is otherwise
/// available only to the relay serving it, and an honest relay's bottom is not
/// attacker-writable at all, since `limit: n` returns ITS newest n by
/// `created_at` and an injected event dated below the cut is simply not in the
/// page.
///
/// # A page nobody said was finished is a PREFIX, not a page
///
/// A relay states it has served everything it stores for a REQ by sending
/// NIP-01 `EOSE`, and that statement is the only evidence a page is whole:
/// [`RelayManager::fetch_events_per_relay`] reports it as
/// [`RelayFetchOutcome::drained`]. A delivery the fetch timeout, a dropped
/// socket, a `CLOSED` or the intake cap cut off part-way arrives as a shorter
/// page and NOTHING ELSE — the events that did land are indistinguishable from a
/// complete short answer. So a relay that handed over events without ever
/// finishing makes the round untrustworthy: what it did not send is exactly what
/// an advance would step over, permanently.
///
/// A relay that finished nothing AND handed over nothing is the different case:
/// it told us neither that it holds something nor that it holds nothing, which
/// is the epistemic position of a relay the fetch never reached. It is treated
/// as one — it does not make the round untrustworthy, and (below) it does not
/// count towards the window having been answered either. Making it
/// untrustworthy instead would halt every chase, on every sweep, for as long as
/// one relay in a circle's list stayed broken, so a circle with a real backlog
/// could never drain past its first page: forward progress traded for nothing,
/// since a relay that hands over nothing has nothing for the chase to lose.
///
/// `tolerate_cut_offs` is what keeps the FIRST of those two cases from becoming
/// the second's permanent twin: a relay cut off on every sweep would otherwise
/// hold the circle for ever. It is set only after [`CATCHUP_MAX_CUTOFF_HOLDS`]
/// consecutive sweeps held on exactly this evidence, and it moves such a relay
/// onto the unreached side of the line for one sweep — the page still gets
/// ingested, but it neither condemns the round nor steers the chase.
///
/// # Why an EMPTY page from a chased relay is a failed read, not an empty range
///
/// A relay that contributed to the previous round still holds the event AT its
/// own page bottom `b`, and this round's request covers it: `until` is inclusive
/// and the boundary is the maximum across contributing relays, hence `>= b`,
/// while `since` has not moved. So that relay MUST return at least one event.
/// Nothing back means we failed to read it — and reading that as "drained" would
/// advance the cursor over a tail we have local proof exists. This holds whether
/// or not the relay signalled `EOSE`: an `EOSE` over an empty page contradicts
/// what the previous round proved rather than settling it. (A page emptied
/// instead by a NIP-40 expiry landing between two rounds milliseconds apart
/// resolves the same way: one conservative hold, re-fetched next sweep.)
///
/// # And why a page from a SILENT relay is one too
///
/// The mirror image, and the one that needs no attacker either. Every page after
/// the first is bounded above by the previous boundary, so a relay that ANSWERED
/// an earlier, WIDER request with nothing and then answers a narrower one was
/// asked for nothing above that boundary by anybody. Its short answer says
/// nothing about the part of the window it was never asked for, so it must not
/// be able to help declare the window complete — one relay slow to answer the
/// opening REQ would otherwise be enough to advance the cursor over whatever it
/// holds up there.
///
/// A relay the fetch could not REACH is a different animal and must not join
/// them, however identical its `RelayFetchOutcome` looks: it was asked nothing,
/// so it has contradicted nothing, and the events it holds above the boundary
/// are covered by the coverage assumption [`cursor_advance_ms`] already makes
/// for a relay that is unreachable throughout (a strict superset of this range).
/// Counting it would freeze a circle on the ordinary shape of a background wake
/// rather than on any attack: `fetch_events_per_relay` reports a handshake that
/// did not complete inside its connection timeout as exactly this outcome, every
/// wake builds a fresh relay pool, and a relay whose first connect is reliably
/// slower than the timeout would then be missing from page 1 and present on page
/// 2 forever, on every wake — the self-inflicted outage that function refuses to
/// cause for a relay that is dead for good.
#[must_use]
fn summarize_round(
    outcomes: &[RelayFetchOutcome],
    state: &ChaseState,
    tolerate_cut_offs: bool,
) -> RoundSummary {
    let mut round = RoundSummary {
        silent: state.silent.clone(),
        ..RoundSummary::default()
    };
    for fo in outcomes {
        if fo.drained {
            round.any_drained = true;
        } else {
            round.unanswered += 1;
            if !fo.events.is_empty() {
                round.cut_off.push(fo.relay_url.clone());
                // Events without an `EOSE` behind them: a prefix of an unknown
                // whole, and the rest of it is what an advance would skip.
                round.read_incomplete |= !tolerate_cut_offs;
                // Either way this relay cannot steer the chase: we did not read
                // it to the end, so it may neither propose the next `until` nor
                // be held to answering it. Exactly what a relay the fetch never
                // reached gets, which is the point of the tolerance.
                continue;
            }
        }
        if fo.events.is_empty() {
            round.read_incomplete |= state.chasing.contains(&fo.relay_url);
            // Only a relay that ANSWERED has claimed to hold nothing here; one
            // we never got a socket to has claimed nothing at all.
            if fo.responded {
                round.silent.insert(fo.relay_url.clone());
            }
            continue;
        }
        round.read_incomplete |= state.silent.contains(&fo.relay_url);
        let contributed = fo.events.len() >= CATCHUP_MAX_EVENTS_PER_PAGE
            || fo.events.iter().any(|ev| !state.seen.contains(&ev.id));
        round.repeat_page |= !contributed;
        if contributed {
            round.boundary_secs = round
                .boundary_secs
                .max(fo.events.iter().map(created_secs).min());
            round.chasing.insert(fo.relay_url.clone());
        }
    }
    round
}

/// What the rounds so far have established about each relay in the circle's
/// list, and about what we already hold.
///
/// Carries relay URLs, so — like [`RoundSummary`] — it derives no formatter at
/// all rather than relying on having nothing sensitive to print.
/// Whether some relay answered a FULL page dated entirely at `until_secs`.
fn full_at(fetch_outcomes: &[RelayFetchOutcome], until_secs: i64) -> bool {
    fetch_outcomes.iter().any(|fo| {
        fo.events.len() >= CATCHUP_MAX_EVENTS_PER_PAGE
            && fo.events.iter().map(created_secs).min() == Some(until_secs)
    })
}

#[derive(Default)]
struct ChaseState {
    /// Relays still being drained: each is known to hold at least the event at
    /// the boundary, so each MUST answer the next round.
    chasing: HashSet<String>,
    /// Relays that ANSWERED some earlier round with nothing, so each must stay
    /// silent. A relay the fetch could not reach is not one of them.
    silent: HashSet<String>,
    /// Every event id this chain has already collected — what makes a page's
    /// contribution NEW.
    seen: HashSet<EventId>,
}

/// An event's `created_at` in the signed seconds the cursor layer speaks.
///
/// A width that cannot fit becomes `i64::MAX`, which is inert in both places
/// this feeds: as a paging boundary it can only sit at or above the band's
/// ceiling, which halts the chase rather than widening it, and as a hold-back it
/// can only fail to lower the advance.
#[must_use]
fn created_secs(ev: &Event) -> i64 {
    i64::try_from(ev.created_at.as_secs()).unwrap_or(i64::MAX)
}

/// The cursor-advance target (ms) one retrieved band justifies, or `None` to
/// hold the cursor where it is.
///
/// `window.ceiling_secs` is the top of the band — the sweep's own open time for
/// its top-down pass, the persisted backfill floor for a resumed one. Either
/// way the claim is the same shape and is established the same way: the chase
/// over `[since, ceiling]` finished, so nothing at or below `ceiling` is
/// outstanding. A lower ceiling advances less far; it never claims more.
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
/// * `saturated` — the chase did not finish, so the window has an unretrieved
///   tail below it that nothing in the events themselves reveals (see
///   [`CATCHUP_MAX_EVENTS_PER_PAGE`] and [`Pager::step`]).
/// * `any_relay_drained` — with nobody having FINISHED answering, "the relays
///   held nothing new" and "we could not ask" are the same empty list. Claiming
///   the first would skip whatever accumulated during the outage. A relay whose
///   delivery was cut off before its `EOSE` is on the "could not ask" side of
///   that line, however cleanly its short page reads.
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
/// events can already withhold them outright. A relay that answered NOTHING
/// before its delivery died rides that same assumption; one that answered
/// PARTLY does not, and holds the window through
/// [`RoundSummary::read_incomplete`] instead.
#[must_use]
pub(crate) fn cursor_advance_ms(
    window: FetchWindow,
    unapplied_secs: &[i64],
    now_secs: i64,
) -> Option<i64> {
    if window.saturated || !window.any_relay_drained {
        return None;
    }
    Some(crate::relay::cursor::cursor_ms_for_window(
        window.ceiling_secs,
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
            ReceiveOnlyOutcome::Applied
            | ReceiveOnlyOutcome::NoEvidence
            | ReceiveOnlyOutcome::Stranded => None,
        })
        .collect()
}

/// What a sweep fetches through, and the driver it stages for: every commit
/// and proposal the engine hands back is recorded as a durable fanout in the
/// hold that released it, and sent through the fanout driver alone, in the
/// mode the sweep's [`Publishing`] gives. In [`DriveMode::FinishOnly`] the
/// engine makes no commit, so nothing is recorded but a leave it proposes
/// again.
///
/// No derived formatter: it holds a relay manager and a driver.
struct Plane<'a> {
    relays: &'a RelayManager,
    driven: Driven<'a>,
    /// The end of the sweep's budget: no retick is waited out past it.
    deadline: Instant,
    /// How many REQs of refused ids this sweep has sent, per circle
    /// ([`REFETCH_REQS_PER_SWEEP`]): one share, whether it is asked for at
    /// the circle's turn or at a new epoch before it.
    refetch_reqs: std::sync::Mutex<Vec<(GroupId, usize)>>,
    /// A refetch at a new epoch is under way: what it ingests begins no
    /// other ([`refetch_at_a_new_epoch`]).
    refetching: AtomicBool,
}

/// The driver a sweep stages for, and what its drives have reported.
struct Driven<'a> {
    publishing: &'a Publishing<'a, dyn FanoutSend + 'a>,
    /// The soonest any drive asked to be called again, and whether one ended
    /// on an error.
    reported: std::sync::Mutex<(Option<u64>, bool)>,
}

impl<'a> Plane<'a> {
    /// Takes one of `group_id`'s REQs of refused ids for this sweep; whether
    /// one was left.
    fn take_refetch_req(&self, group_id: &GroupId) -> bool {
        let mut sent = self
            .refetch_reqs
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let at = sent
            .iter()
            .position(|(group, _)| group == group_id)
            .unwrap_or_else(|| {
                sent.push((group_id.clone(), 0));
                sent.len() - 1
            });
        let left = sent[at].1 < REFETCH_REQS_PER_SWEEP;
        if left {
            sent[at].1 += 1;
        }
        left
    }

    const fn driving(
        relays: &'a RelayManager,
        publishing: &'a Publishing<'a, dyn FanoutSend + 'a>,
        deadline: Instant,
    ) -> Self {
        Self {
            relays,
            driven: Driven {
                publishing,
                reported: std::sync::Mutex::new((None, false)),
            },
            deadline,
            refetch_reqs: std::sync::Mutex::new(Vec::new()),
            refetching: AtomicBool::new(false),
        }
    }

    /// Ingests `ev`: every commit and proposal the engine hands back is
    /// recorded in the hold that takes it.
    async fn ingest(
        &self,
        circle_mgr: &CircleManager,
        ev: &Event,
    ) -> crate::nostr::Result<(ScreenedIngest, Vec<FanoutId>)> {
        let publishing = self.driven.publishing;
        circle_mgr
            .session()
            .process_event_staging(
                ev,
                publishing.clock.now_ms(),
                Still::new(publishing.mode, publishing.mode.mode()),
            )
            .await
    }

    /// Advances `group_id` in the sweep's mode.
    async fn advance(
        &self,
        circle_mgr: &CircleManager,
        group_id: &GroupId,
    ) -> crate::nostr::Result<(SessionEffects, Vec<FanoutId>)> {
        let now_ms = self.driven.publishing.clock.now_ms();
        let session = circle_mgr.session();
        let source = self.driven.publishing.mode;
        let staged = match source.mode() {
            // Read again with the engine held: the wait for it is where the
            // mode this was read in can end.
            DriveMode::Full => {
                session
                    .advance_for_drive_while(group_id, now_ms, Still::new(source, DriveMode::Full))
                    .await
            }
            DriveMode::FinishOnly => session.settle_inputs_for_drive(group_id, now_ms).await,
        };
        circle_mgr.forget_dropped_removals().await;
        let staged = staged?;
        let mut recorded = staged.fanouts;
        recorded.extend(staged.proposals);
        Ok((staged.effects, recorded))
    }

    /// Disposes of what one engine batch left to be published: `recorded` are
    /// the handles of what the hold recorded, `work` what it did not.
    ///
    /// Publish-before-apply (Rule 13): each recorded commit and proposal is
    /// sent through the fanout driver — confirmed on a relay's
    /// acknowledgement, left recorded and awaiting relays on anything short
    /// of one, rolled back only on every relay's proven refusal — and what a
    /// resolution releases in turn in the same call. What `work` still holds
    /// is then a proposal no record could be written for, published once in
    /// the full mode, and a commit that could be neither recorded nor rolled
    /// back, which is left staged.
    async fn resolve(
        &self,
        circle_mgr: &CircleManager,
        recorded: Vec<FanoutId>,
        work: Vec<PublishWork>,
    ) {
        let driven = &self.driven;
        let unrecorded = SessionEffects {
            events: Vec::new(),
            publish: work,
            queued: Vec::new(),
            pending_convergence: Vec::new(),
        };
        let (handed_back, _) = circle_mgr
            .fold_staged(
                unrecorded,
                false,
                driven.publishing.clock.now_ms(),
                Still::new(driven.publishing.mode, driven.publishing.mode.mode()),
            )
            .await;
        let outcome = driven
            .publishing
            .settle_staged(circle_mgr, recorded, handed_back)
            .await;
        driven.report(&outcome);
    }
}

impl Driven<'_> {
    /// Takes in what one of this sweep's drives reported. What it replayed
    /// is dropped here: every location in it is already in the last-known
    /// store, stamped as arrived, and this sweep
    /// has no surface to route it to. What it noted about a change stays in
    /// the circle's durable notes until the app reads them.
    fn report(&self, outcome: &ResumeOutcome) {
        let mut reported = self
            .reported
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        reported.0 = match (reported.0, outcome.retry_after_ms) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        };
        reported.1 |= outcome.errored;
    }
}

/// Ingests one fetched event through the process-global engine, persisting any
/// decrypted location and resolving any auto-commit publish work, then reports
/// whether the cursor may advance past it.
#[cfg(test)]
async fn ingest_one(
    circle_mgr: &CircleManager,
    plane: &Plane<'_>,
    ev: &Event,
) -> ReceiveOnlyOutcome {
    ingest_judged(circle_mgr, plane, ev).await.0
}

/// What the engine holds of an event it was handed.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Left {
    /// The event, or its verdict.
    WithTheEngine,
    /// Nothing: it had no ROOM for the event — it refused it for a local
    /// resource bound, or kept no trace of it.
    NoRoom,
    /// Nothing: the ingest erred, or a hold of the circle's meant the engine
    /// was never asked.
    Unasked,
}

/// [`ingest_one`], and what the engine holds of the event. Having no room is
/// kept apart from an error and a hold: the engine was not short of room in
/// either, and a refetch that read them as "no room" would wait on a store
/// that was never asked. A parked event is the engine's.
#[deny(clippy::wildcard_enum_match_arm)]
async fn ingest_judged(
    circle_mgr: &CircleManager,
    plane: &Plane<'_>,
    ev: &Event,
) -> (ReceiveOnlyOutcome, Left) {
    // An `Err` is an ENGINE-side ingest failure (the envelope parsed and the
    // engine took the message), so something at this position is genuinely
    // outstanding and the cursor must stop at it. An envelope that would not
    // parse never reaches here — it comes back as a pre-auth rejection below.
    let Ok((screened, recorded)) = plane.ingest(circle_mgr, ev).await else {
        // An event the engine recorded before it erred is its own: a refetch
        // would bring back only the same verdict, for ever.
        let left = if circle_mgr.session().engine_processed(&ev.id) {
            Left::WithTheEngine
        } else {
            Left::Unasked
        };
        return (ReceiveOnlyOutcome::Deferred, left);
    };

    let mut ingest = match screened {
        // Rejected by Haven's local screen BEFORE any MLS authentication (an
        // envelope that would not parse, or any kind but 445). Nothing here is verified, so persist nothing, publish nothing, drain nothing — and
        // report `NoEvidence` so the event's unauthenticated `created_at` can
        // neither become this circle's cursor nor hold it back.
        ScreenedIngest::RejectedBeforeAuth(_) => {
            return (ReceiveOnlyOutcome::NoEvidence, Left::WithTheEngine)
        }
        ScreenedIngest::Ingested(effects) => effects,
    };
    let left = if matches!(ingest.outcome, IngestOutcome::ResourceRefused { .. })
        || (ingest.left_object_unpersisted
            && !matches!(ingest.outcome, IngestOutcome::Ignored { .. }))
    {
        Left::NoRoom
    } else {
        Left::WithTheEngine
    };

    circle_mgr
        .persist_replayed_locations(&ingest.effects.events)
        .await;
    let work = std::mem::take(&mut ingest.effects.publish);
    plane.resolve(circle_mgr, recorded, work).await;
    // Receive-side observation for the epoch-rotation repair's quiescence gate
    // (`circle::rotation`), on the AUTHENTICATED batch only — see the same call
    // in the live-sync processor.
    circle_mgr.note_inbound_group_events(&ingest.effects.events);
    let directory = circle_mgr.directory_verdict_for_events(&ingest.effects.events);
    refetch_at_a_new_epoch(circle_mgr, plane, &ingest.effects.events).await;
    let drained = drain_convergence(
        circle_mgr,
        plane,
        SessionManager::groups_owing_service(&ingest),
    )
    .await;
    let directory = directory.max(drained);

    // A commit that lands in the background isolate is applied state like any
    // other, and its withdrawal is the one signal the directory cannot
    // reconstruct later — the fold keeps no per-commit record, so a rewrite that
    // waits for the next foreground trigger would age a withdrawn add out over
    // three days instead of deleting it.
    if let Some(mode) = directory {
        circle_mgr
            .reconcile_member_directory_best_effort(mode)
            .await;
    }

    let verdict = cursor_verdict(
        circle_mgr,
        &ev.id,
        ingest.outcome,
        ingest.left_object_unpersisted,
    )
    .await;
    (verdict, left)
}

/// Whether a cursor may pass the event `id`, which the engine answered
/// `outcome` for, read AFTER the advances that ingest left owing: the one
/// classification every plane that polls makes (this sweep, and the driver's
/// poll entry).
///
/// Rule 12: an object the engine refused for a local resource bound, or kept
/// no trace of, has relay redelivery as its only way back, so it holds —
/// unless the verdict is an `Ignored` exclusion (an unknown route is dropped
/// without a trace by design, mdk#740), which no redelivery can change here.
/// `TransportDeferred` is retained and retried by the engine itself.
#[deny(clippy::wildcard_enum_match_arm)]
pub(crate) async fn cursor_verdict(
    circle_mgr: &CircleManager,
    id: &nostr::EventId,
    outcome: IngestOutcome,
    left_object_unpersisted: bool,
) -> ReceiveOnlyOutcome {
    if left_object_unpersisted && !matches!(outcome, IngestOutcome::Ignored { .. }) {
        return ReceiveOnlyOutcome::Deferred;
    }
    match outcome {
        // Answered from a stranded row: the same answer at every
        // redelivery, whichever epoch the row carries — the circle's own,
        // after a rollback or the open's clear of a staged commit; an
        // earlier one, after a confirm. Never a hold.
        IngestOutcome::Buffered { group_id, .. }
            if circle_mgr.session().holds_stranded(&group_id, id).await =>
        {
            ReceiveOnlyOutcome::Stranded
        }
        // The advances may already have carried the group past the buffered
        // input's epoch (a convergence pass closing inside them); the cursor
        // then passes.
        IngestOutcome::Buffered { group_id, epoch }
            if matches!(
                circle_mgr.session().epoch_state(&group_id).await,
                Some(EpochState::Stable { epoch: now }) if now > epoch
            ) =>
        {
            ReceiveOnlyOutcome::Applied
        }
        IngestOutcome::Buffered { .. } | IngestOutcome::ResourceRefused { .. } => {
            ReceiveOnlyOutcome::Deferred
        }
        IngestOutcome::Processed
        | IngestOutcome::Stale { .. }
        | IngestOutcome::TransportDeferred { .. }
        | IngestOutcome::Ignored { .. }
        | IngestOutcome::Rejected { .. }
        | IngestOutcome::LocalState { .. } => ReceiveOnlyOutcome::Applied,
    }
}

/// Advances `pending` and everything the advances leave owing, persisting the
/// released locations and resolving the released publish work; returns the
/// strongest member-directory verdict the drained events imply.
///
/// Re-ticks a group the engine still owes a deadline — a convergence pass
/// closing, a due `SelfRemove` auto-commit — once it falls due (bounded, see
/// [`next_receive_retick`]): a single advance would strand the commit and the
/// eviction, so this background sweep would never re-broadcast it. A quiet
/// group exits immediately (no delay).
///
/// No deadline is waited out past the sweep's own: a wake's budget is the
/// operating system's, and a drain that slept through it would be cut off
/// wherever it stood. The first advance costs no wait and always runs. What a
/// cut, or a drain out of the deadlines it may wait out, leaves owing is
/// owed to the next plane that drains ([`SessionManager::owe_advance`]):
/// nothing else would come back for a commit left buffered here.
async fn drain_convergence(
    circle_mgr: &CircleManager,
    plane: &Plane<'_>,
    mut pending: Vec<GroupId>,
) -> Option<DirectoryReconcile> {
    let mut directory = None;
    let mut advanced: Vec<GroupId> = Vec::new();
    for _ in 0..MAX_CONVERGENCE_RETICKS {
        if pending.is_empty() {
            break;
        }
        let mut owing: Vec<GroupId> = Vec::new();
        for gid in &pending {
            if !advanced.contains(gid) {
                advanced.push(gid.clone());
            }
            if let Ok((mut more, recorded)) = plane.advance(circle_mgr, gid).await {
                circle_mgr.persist_replayed_locations(&more.events).await;
                let work = std::mem::take(&mut more.publish);
                plane.resolve(circle_mgr, recorded, work).await;
                circle_mgr.note_inbound_group_events(&more.events);
                directory = directory.max(circle_mgr.directory_verdict_for_events(&more.events));
                owing.extend(SessionManager::groups_owing_advance(&more));
                refetch_at_a_new_epoch(circle_mgr, plane, &more.events).await;
            }
        }
        let (next, wait) = next_receive_retick(circle_mgr.session(), &pending, owing).await;
        pending = next;
        if !pending.is_empty() {
            if Instant::now() + wait > plane.deadline {
                break;
            }
            tokio::time::sleep(wait).await;
        }
    }
    owe_unfinished(circle_mgr.session(), pending, &advanced).await;
    directory
}

/// Asks for what a circle owes by id the moment a batch says its epoch has
/// moved, before that circle is advanced again.
///
/// The engine returns from an advance at every new epoch so that its host
/// can deliver again what it refused before (`cgka-engine/src/
/// message_processor/mod.rs` 1491-1513): an event it had no room for may be
/// one the new epoch can open, and the next advance may otherwise settle the
/// circle past it — a member's leave, overtaken by the commit that evicts
/// them. Out of the sweep's own share of REQs for the circle
/// ([`REFETCH_REQS_PER_SWEEP`]), never beside it; and what the refetch
/// ingests begins no refetch of its own.
async fn refetch_at_a_new_epoch(
    circle_mgr: &CircleManager,
    plane: &Plane<'_>,
    events: &[crate::nostr::mls::types::GroupEvent],
) {
    let mut moved: Vec<&GroupId> = Vec::new();
    for event in events {
        if let crate::nostr::mls::types::GroupEvent::EpochChanged { group_id, .. } = event {
            if !moved.contains(&group_id) {
                moved.push(group_id);
            }
        }
    }
    for group_id in moved {
        if circle_mgr
            .session()
            .refused_redeliveries(group_id, 1)
            .is_empty()
            || plane.refetching.swap(true, Ordering::SeqCst)
        {
            continue;
        }
        if let Ok(Some(circle)) = circle_mgr.storage.get_circle(group_id) {
            let relays = circle_mgr.routing_addresses(group_id, &circle.relays).await;
            let refetch = Refetch {
                circle_mgr,
                plane,
                group_id,
                relays: &relays,
                deadline: plane.deadline,
            };
            Box::pin(refetch.by_id()).await;
        }
        plane.refetching.store(false, Ordering::SeqCst);
    }
}

/// Runs a cursor-anchored catch-up sweep over every visible circle.
///
/// Best-effort and deadline-bounded. Runs through the SAME process-global
/// session as the foreground (Rule 14 — see the module docs). Fails closed: if
/// storage is unavailable, returns an empty [`CatchupOutcome`] (no ingest).
///
/// This is the sweep every wake the app has runs, in the background as in the
/// foreground: nothing here can tell which it was called from, so it makes no
/// commit ([`DriveMode::FinishOnly`]). What it receives is settled, a stored
/// record a relay has already decided is finished, and an eviction left due
/// waits for a foreground drive. [`run_catchup_in_foreground`] is the sweep
/// that makes commits.
pub async fn run_catchup_all_circles(
    circle_mgr: &CircleManager,
    relay_mgr: &RelayManager,
    max_duration_secs: u64,
) -> CatchupOutcome {
    run_catchup_in(
        circle_mgr,
        relay_mgr,
        max_duration_secs,
        &DriveMode::FinishOnly,
    )
    .await
}

/// The longest any sweep is given, whatever its caller asks for.
const MAX_SWEEP_SECS: u64 = 3_600;

/// When a sweep given `max_duration_secs` ends. Clamped: the figure crosses
/// the FFI, and an instant that far ahead cannot be represented.
fn sweep_deadline(max_duration_secs: u64) -> Instant {
    Instant::now() + Duration::from_secs(max_duration_secs.min(MAX_SWEEP_SECS))
}

/// [`run_catchup_all_circles`] for a caller that knows the app is in front of
/// its user: the sweep that drives.
///
/// It stages what it surfaces under durable fanouts and drives them, and
/// first drives every stored record that has something due — a commit a kill
/// interrupted, one the open found staged with no record, a proposal a relay
/// has not taken.
///
/// Call it from the FOREGROUND only: a background wake redeems no stored
/// removal (privacy invariant `INV-L-WEDGED-CIRCLE-IS-DETECTED-AND-NAMED`).
///
/// `max_duration_secs` bounds the whole call, drives included: no record is
/// begun unless the sweep has a row's longest run left
/// ([`ROW_BUDGET_MS`](crate::relay::fanout::ROW_BUDGET_MS)),
/// so a sweep given less than that reads and records and drives nothing, and
/// says when to come back ([`CatchupOutcome::retry_after_ms`]).
pub async fn run_catchup_in_foreground(
    circle_mgr: &CircleManager,
    relay_mgr: &RelayManager,
    max_duration_secs: u64,
) -> CatchupOutcome {
    run_catchup_in(circle_mgr, relay_mgr, max_duration_secs, &DriveMode::Full).await
}

/// The product's sweep in `drive_mode`, over `relay_mgr`'s fanout transport
/// and publish ladder on the device's clock.
async fn run_catchup_in(
    circle_mgr: &CircleManager,
    relay_mgr: &RelayManager,
    max_duration_secs: u64,
    drive_mode: &DriveMode,
) -> CatchupOutcome {
    let clock = WallClock;
    let transport = relay_mgr.fanout_transport();
    let budget_ms = max_duration_secs.min(MAX_SWEEP_SECS) * 1_000;
    let publishing: Publishing<'_, dyn FanoutSend + '_> = Publishing {
        fanout: &transport,
        publisher: relay_mgr,
        clock: &clock,
        deadline_ms: Some(clock.now_ms().saturating_add(budget_ms)),
        mode: drive_mode,
    };
    run_catchup_driving(circle_mgr, relay_mgr, &publishing, max_duration_secs).await
}

/// [`run_catchup_in_foreground`] through `publishing`: the transport, the
/// publisher of what has no record, the clock and the drive budget are the
/// caller's.
pub async fn run_catchup_driving(
    circle_mgr: &CircleManager,
    relay_mgr: &RelayManager,
    publishing: &Publishing<'_, dyn FanoutSend + '_>,
    max_duration_secs: u64,
) -> CatchupOutcome {
    let deadline = sweep_deadline(max_duration_secs);
    let plane = Plane::driving(relay_mgr, publishing, deadline);
    // Stored records first: a commit still pending holds its circle's
    // traffic unread, so sweeping before it is resolved would only buffer.
    let resumed = publishing.resume(circle_mgr).await;
    let mut out = sweep_all_circles(circle_mgr, &plane).await;
    plane.driven.report(&resumed);
    let (retry_after_ms, errored) = *plane
        .driven
        .reported
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    out.retry_after_ms = retry_after_ms.map(|wait| wait.max(BUSY_RETRY_MS));
    out.drive_errored = errored;
    out
}

async fn sweep_all_circles(circle_mgr: &CircleManager, plane: &Plane<'_>) -> CatchupOutcome {
    let mut out = CatchupOutcome::default();
    let deadline = plane.deadline;

    // The first plane in a session takes what the engine handed back at the
    // open, before the circle list is read: a join recovered there is swept
    // with the rest. Then the advances the engine named: each drained per
    // circle inside the deadline, and owed back if the deadline stops the
    // walk, so a short wake budget is never spent on them up front and never
    // loses one (MDK's host pending set, T-SCHEDULER).
    let session = circle_mgr.session();
    if session.take_open_recovery() {
        circle_mgr.recover_owed_outputs().await;
    }
    let mut owed = session.take_owed_advance();
    // A follow a kill or an error missed is made before the circles are
    // read, so each is swept where it now lives.
    circle_mgr.reconcile_routing().await;

    // Fail-closed: storage unavailable (e.g. locked device) ⇒ clean no-op.
    let Ok(circles) = circle_mgr.routable_circles().await else {
        session.owe_advance(&owed);
        return out;
    };
    owed.retain(|group_id| {
        circles
            .iter()
            .any(|cwm| &cwm.circle.mls_group_id == group_id)
    });
    let neg_routes = negentropy_routes(circle_mgr, &circles, deadline).await;
    let mut directory = None;

    for cwm in circles {
        if Instant::now() >= deadline {
            out.deadline_hit = true;
            break;
        }
        if let Some(at) = owed
            .iter()
            .position(|group_id| group_id == &cwm.circle.mls_group_id)
        {
            let drained = drain_convergence(circle_mgr, plane, vec![owed.remove(at)]).await;
            directory = directory.max(drained);
        }
        let relays = cwm.circle.relays;
        if relays.is_empty() {
            continue;
        }
        out.circles_swept += 1;
        // A routing the circle left within the day — relays, or a routing id
        // another client's admin rotated — is swept with its current one, as
        // it keeps its standing REQ (decision 237): a device catching up
        // across the change finds there what was sent before it. Only this
        // pass's own sweeps of every one say the circle is caught up.
        let group_id = &cwm.circle.mls_group_id;
        circle_mgr.session().forget_caught_up(Some(group_id));
        let mut caught_up = true;
        for (routing_id, swept) in circle_mgr
            .standing_routings(
                group_id,
                cwm.circle.nostr_group_id,
                &relays,
                chrono::Utc::now().timestamp(),
            )
            .await
        {
            let neg = neg_routes
                .iter()
                .find(|route| route.routing_id == routing_id && &route.group_id == group_id);
            caught_up &= sweep_one_circle(
                circle_mgr, plane, group_id, routing_id, &swept, neg, &mut out,
            )
            .await;
        }
        if caught_up {
            circle_mgr.session().mark_caught_up(group_id);
        }
        let addresses = circle_mgr
            .routing_addresses(&cwm.circle.mls_group_id, &relays)
            .await;
        let refetch = Refetch {
            circle_mgr,
            plane,
            group_id: &cwm.circle.mls_group_id,
            relays: &addresses,
            deadline,
        };
        refetch.by_id().await;
        refetch.by_range(&mut out).await;
    }

    session.owe_advance(&owed);
    if let Some(mode) = directory {
        circle_mgr
            .reconcile_member_directory_best_effort(mode)
            .await;
    }
    out
}

/// What a route's NIP-77 session, by-id fetch and a page of ingests need of
/// a sweep's budget before one is begun.
const NEG_ROOM: Duration =
    Duration::from_secs(super::manager::CONNECTION_TIMEOUT.as_secs() + NEG_ROUTE_WAIT.as_secs());

/// The routings this sweep reconciles over NIP-77: every standing routing of
/// `circles`, taken by [`negentropy::begin_pass`] — none when the sweep has
/// no room for one or a pass began too recently. Each runs at its circle's
/// turn, after the pager's passes ([`sweep_one_circle`]).
async fn negentropy_routes(
    circle_mgr: &CircleManager,
    circles: &[crate::circle::CircleWithMembers],
    deadline: Instant,
) -> Vec<NegRoute> {
    if deadline.saturating_duration_since(Instant::now()) < NEG_ROOM {
        return Vec::new();
    }
    let now = chrono::Utc::now().timestamp();
    let mut routes = Vec::new();
    for cwm in circles {
        let circle = &cwm.circle;
        if circle.relays.is_empty() {
            continue;
        }
        for (routing_id, relays) in circle_mgr
            .standing_routings(
                &circle.mls_group_id,
                circle.nostr_group_id,
                &circle.relays,
                now,
            )
            .await
        {
            routes.push(NegRoute {
                group_id: circle.mls_group_id.clone(),
                routing_id,
                relays,
            });
        }
    }
    negentropy::begin_pass(circle_mgr.session(), routes).await
}

/// Takes what a sweep's NIP-77 pass recovered for one circle in, as a page
/// is ([`CircleSweep::ingest_page`]): each event's verdict is recorded for the
/// cursor, and what the deadline cuts off holds it.
struct CatchupSink<'s, 'a> {
    sweep: &'s CircleSweep<'a>,
    tally: std::sync::Mutex<(CatchupOutcome, Vec<(i64, ReceiveOnlyOutcome)>)>,
}

impl CatchupSink<'_, '_> {
    /// Adds what the sink took in to the sweep's tally and classification.
    fn drain_into(self, out: &mut CatchupOutcome, classified: &mut Vec<(i64, ReceiveOnlyOutcome)>) {
        let (took, verdicts) = self
            .tally
            .into_inner()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        out.events_applied += took.events_applied;
        out.events_deferred += took.events_deferred;
        out.events_rejected_pre_auth += took.events_rejected_pre_auth;
        out.events_stranded += took.events_stranded;
        out.deadline_hit |= took.deadline_hit;
        classified.extend(verdicts);
    }
}

#[async_trait::async_trait]
impl NegSink for CatchupSink<'_, '_> {
    #[deny(clippy::wildcard_enum_match_arm)]
    async fn take_in(&self, route: &NegRoute, events: Vec<(IngestClass, Event)>) -> bool {
        let group_id = &route.group_id;
        let sweep = self.sweep;
        let session = sweep.circle_mgr.session();
        let mut took = CatchupOutcome::default();
        let mut verdicts = Vec::with_capacity(events.len());
        let mut whole = true;
        for (idx, (_, ev)) in events.iter().enumerate() {
            if Instant::now() >= sweep.deadline {
                // Fetched and never taken in: each holds the cursor, and a
                // current-epoch commit stays held unread until an ingest
                // takes it in (Security Rule 10).
                let rest = &events[idx..];
                session.hold_pager_commits(
                    group_id,
                    rest.iter()
                        .filter(|(class, _)| *class == IngestClass::Commit)
                        .map(|(_, event)| &event.id),
                );
                verdicts.extend(
                    rest.iter()
                        .map(|(_, pending)| (created_secs(pending), ReceiveOnlyOutcome::Deferred)),
                );
                took.events_deferred += rest.len();
                took.deadline_hit = true;
                sweep.owing.store(true, Ordering::Relaxed);
                whole = false;
                break;
            }
            let (outcome, left) = ingest_judged(sweep.circle_mgr, sweep.plane, ev).await;
            sweep.ingested_any.store(true, Ordering::Relaxed);
            let taken = match left {
                Left::WithTheEngine => true,
                Left::NoRoom => session.refused_owes(group_id).contains(&ev.id),
                Left::Unasked => false,
            };
            if !taken {
                whole = false;
            }
            if left != Left::WithTheEngine {
                sweep.owing.store(true, Ordering::Relaxed);
            }
            match outcome {
                ReceiveOnlyOutcome::Applied => took.events_applied += 1,
                ReceiveOnlyOutcome::Deferred => took.events_deferred += 1,
                ReceiveOnlyOutcome::NoEvidence => took.events_rejected_pre_auth += 1,
                ReceiveOnlyOutcome::Stranded => took.events_stranded += 1,
            }
            verdicts.push((created_secs(ev), outcome));
        }
        *self
            .tally
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = (took, verdicts);
        whole
    }
}

/// Runs ONLY the refused-object redelivery, for only the circles that owe one.
///
/// What the live plane asks for when the engine refuses an object
/// (`SyncStatusReason::RefetchOwed`). No window is swept and no cursor moves,
/// so a stranger's refusal flood costs this a bounded share of each owing
/// circle, never a full catch-up of every circle. It makes no commit
/// ([`DriveMode::FinishOnly`]): what it ingests is settled.
pub async fn run_refused_refetch(
    circle_mgr: &CircleManager,
    relay_mgr: &RelayManager,
    max_duration_secs: u64,
) -> CatchupOutcome {
    let mut out = CatchupOutcome::default();
    let deadline = sweep_deadline(max_duration_secs);
    let clock = WallClock;
    let transport = relay_mgr.fanout_transport();
    let publishing: Publishing<'_, dyn FanoutSend + '_> = Publishing {
        fanout: &transport,
        publisher: relay_mgr,
        clock: &clock,
        deadline_ms: Some(
            clock
                .now_ms()
                .saturating_add(max_duration_secs.min(MAX_SWEEP_SECS) * 1_000),
        ),
        mode: &DriveMode::FinishOnly,
    };
    let plane = Plane::driving(relay_mgr, &publishing, deadline);
    let Ok(circles) = circle_mgr.routable_circles().await else {
        return out;
    };
    for cwm in circles {
        if Instant::now() >= deadline {
            out.deadline_hit = true;
            break;
        }
        let group_id = &cwm.circle.mls_group_id;
        let session = circle_mgr.session();
        let owes = !session.refused_redeliveries(group_id, 1).is_empty()
            || session.refused_range(group_id).is_some();
        if !owes || cwm.circle.relays.is_empty() {
            continue;
        }
        let addresses = circle_mgr
            .routing_addresses(group_id, &cwm.circle.relays)
            .await;
        let refetch = Refetch {
            circle_mgr,
            plane: &plane,
            group_id,
            relays: &addresses,
            deadline,
        };
        refetch.by_id().await;
        refetch.by_range(&mut out).await;
    }
    out
}

/// Refused ids asked for in one REQ, each REQ capped at as many events as it
/// names, so no answer can exceed what was asked for.
///
/// MDK's own by-id batch (`transport-nostr-adapter/src/sdk_client.rs:66`):
/// half the number whose REQ outgrows the 16 384 bytes NIP-11 gives as an
/// example `max_message_length`.
pub const REFETCH_IDS_PER_REQ: usize = 128;

/// Asks each of `at` for `ids` by id, in one REQ capped at as many events as
/// it names and carrying `#h` = `routing_hex` when given; what each relay
/// served of those ids and whether it finished. The one by-id shape, shared
/// by the refused-object refetch and the NIP-77 pass.
pub(crate) async fn fetch_ids(
    relays: &RelayManager,
    ids: &[EventId],
    routing_hex: Option<&str>,
    at: &[String],
) -> Vec<RelayFetchOutcome> {
    let mut filter = Filter::new()
        .ids(ids.iter().copied())
        .kind(Kind::Custom(445))
        .limit(ids.len());
    if let Some(routing_hex) = routing_hex {
        filter = filter.custom_tag(
            nostr::SingleLetterTag::lowercase(nostr::Alphabet::H),
            routing_hex,
        );
    }
    let mut outcomes = relays
        .fetch_events_per_relay(filter, at)
        .await
        .unwrap_or_default();
    for outcome in &mut outcomes {
        outcome.events.retain(|event| ids.contains(&event.id));
    }
    outcomes
}

/// REQs of refused ids one sweep sends per circle: together with
/// [`REFETCH_IDS_PER_REQ`], a sweep's share of a backlog, which rotates
/// through the rest on later sweeps.
pub const REFETCH_REQS_PER_SWEEP: usize = 2;

/// The redelivery Marmot `transports/nostr.md` (`resource_refused`) requires
/// and Security Rule 12 promises, for ONE circle: every object the engine
/// deferred and then retired for a local resource bound gets another delivery
/// opportunity.
///
/// The deferral let the cursor pass the object and the engine keeps nothing of
/// it, so no window brings it back. Up to [`MAX_REFUSED_IDS_PER_GROUP`] are
/// owed by id; past that, the circle owes its history as a range, walked down a
/// page budget per sweep — the overlapping range the spec allows
/// (`transports/nostr.md:168-171`) and the full-history backfill MDK asks for
/// (`message_processor/store.rs:869-871`).
///
/// [`MAX_REFUSED_IDS_PER_GROUP`]: crate::nostr::mls::MAX_REFUSED_IDS_PER_GROUP
struct Refetch<'a> {
    circle_mgr: &'a CircleManager,
    plane: &'a Plane<'a>,
    group_id: &'a GroupId,
    relays: &'a [String],
    deadline: Instant,
}

impl Refetch<'_> {
    /// Asks for the owed ids whose wait is over, those that waited longest
    /// first, a bounded share per sweep ([`REFETCH_REQS_PER_SWEEP`] REQs of
    /// [`REFETCH_IDS_PER_REQ`] ids, whenever in the sweep they are sent),
    /// and ingests what comes back. An id
    /// is discharged only when its object was ingested to a verdict, or when
    /// EVERY relay asked answered a REQ naming it with no event at all;
    /// anything less — a relay that never answered, an ingest that failed —
    /// keeps it owed, behind a wait that doubles each time
    /// ([`refetch_spacing_secs`](crate::nostr::mls::refetch_spacing_secs)):
    /// never dropped, and never asked for at every sweep.
    ///
    /// An answer that brought some of the ids it was asked for proves
    /// nothing about the rest: a relay may clamp `limit` below what matches
    /// and send a subset before its EOSE. Those are asked for again by
    /// themselves, out of the same share, and keep their turn until then.
    ///
    /// When the engine had no room for anything a REQ brought back, the ids
    /// of the circle that were already asked for since they last became due
    /// wait too. That is all it does: the sweep's share is asked for in
    /// full, and an id that has not had its turn keeps it — it may be the
    /// one event the engine can open, among any number it cannot.
    async fn by_id(&self) {
        let session = self.circle_mgr.session();
        let mut alone: Vec<nostr::EventId> = Vec::new();
        while Instant::now() < self.deadline && !self.relays.is_empty() {
            // Read for each REQ: what the last one left waiting is no longer
            // due, and what a new epoch made due again is.
            let chunk = if alone.is_empty() {
                session.refused_redeliveries(self.group_id, REFETCH_IDS_PER_REQ)
            } else {
                std::mem::take(&mut alone)
            };
            if chunk.is_empty() || !self.plane.take_refetch_req(self.group_id) {
                break;
            }
            let epoch_asked_in = session.epoch_state(self.group_id).await;
            let outcomes = fetch_ids(self.plane.relays, &chunk, None, self.relays).await;
            let every_relay_answered = !self.relays.is_empty()
                && outcomes.len() == self.relays.len()
                && outcomes.iter().all(|outcome| outcome.drained);
            let mut events: Vec<Event> = outcomes
                .into_iter()
                .flat_map(|outcome| outcome.events)
                .collect();
            events.sort_by_key(|event| (event.created_at, event.id));
            events.dedup_by_key(|event| event.id);
            let events: Vec<Event> = session
                .order_for_ingest(self.group_id, events)
                .await
                .into_iter()
                .map(|(_, event)| event)
                .collect();
            let mut discharged: Vec<nostr::EventId> = Vec::new();
            let mut no_room = 0;
            for event in &events {
                let (verdict, left) = ingest_judged(self.circle_mgr, self.plane, event).await;
                no_room += usize::from(left == Left::NoRoom);
                if !matches!(verdict, ReceiveOnlyOutcome::Deferred) {
                    discharged.push(event.id);
                }
            }
            if every_relay_answered {
                let absent = chunk
                    .iter()
                    .filter(|id| !events.iter().any(|event| event.id == **id))
                    .copied();
                if events.is_empty() {
                    discharged.extend(absent);
                } else {
                    alone = absent.collect();
                }
            }
            session.resolve_refused_redeliveries(self.group_id, &discharged);
            // An id the engine refused before a later event of the same
            // answer moved the circle's epoch is due at once, as every owed
            // id is at a new epoch: it earns no wait here.
            if session.epoch_state(self.group_id).await != epoch_asked_in {
                continue;
            }
            let still_owed: Vec<_> = chunk
                .iter()
                .filter(|id| !discharged.contains(id) && !alone.contains(id))
                .copied()
                .collect();
            let wholesale = no_room > 0 && no_room == events.len();
            session.refused_redeliveries_tried(self.group_id, &still_owed, wholesale);
        }
    }

    /// Walks the owed history range down one pass's page budget, from where
    /// the walk under way has got to. A halted pass carries the walk down; a
    /// pass every relay answered in full ends the range only if the engine
    /// took everything the WHOLE walk brought back, and otherwise the next
    /// pass begins again at the ceiling ([`RangePass`]). The cursor is
    /// untouched: it already claims this ground, and a range refetch is a
    /// redelivery, not a sync.
    ///
    /// Past the cap an event is owed as part of the range ONLY, and the
    /// engine announces nothing when it refuses one at ingest: an event it
    /// had no room for, erred on or was never asked about is on record
    /// nowhere else, so a pass that brought one back ends nothing.
    ///
    /// On a schedule of its own, whatever the ids beside it are waiting for:
    /// a range that waited on ids nothing can discharge would never bring
    /// such an event back. A pass that carries the walk no further doubles
    /// the wait before the next; a new epoch makes it due at once.
    async fn by_range(&self, out: &mut CatchupOutcome) {
        let session = self.circle_mgr.session();
        if Instant::now() >= self.deadline {
            return;
        }
        let Some(read) = session.refused_range_to_ask(self.group_id) else {
            return;
        };
        // Each routing id the circle's traffic in the window was sent under —
        // a range reaching back across a rotation spans both — asked for by a
        // filter of its own at the relays it was used with: a relay set the
        // circle left with its prior id is never told the new one.
        let routing_id = self
            .circle_mgr
            .nostr_group_id_for(self.group_id)
            .unwrap_or_default();
        let current = self
            .circle_mgr
            .storage
            .get_circle(self.group_id)
            .ok()
            .flatten()
            .map(|circle| circle.relays)
            .unwrap_or_default();
        let unanswered_before = out.relay_errors;
        let (mut halted_at, mut whole, mut owing) = (None::<i64>, true, false);
        for (id, relays) in self
            .circle_mgr
            .kept_routings(self.group_id, routing_id, &current)
            .await
        {
            let sweep = CircleSweep {
                circle_mgr: self.circle_mgr,
                plane: self.plane,
                group_id: self.group_id,
                ngid_hexes: vec![hex::encode(id)],
                relays: &relays,
                deadline: self.deadline,
                started_out_of_time: false,
                ingested_any: AtomicBool::new(false),
                owing: AtomicBool::new(false),
                tolerate_cut_offs: false,
            };
            let mut classified = Vec::new();
            let pass = sweep
                .fetch_and_ingest(0, read.walk_secs, out, &mut classified)
                .await;
            owing |= sweep.owing.load(Ordering::Relaxed);
            if pass.window.saturated {
                // A second fuller than a page would otherwise pin the walk
                // there for as long as relays serve it — and an outsider can
                // date one just above a genuine event. Below it the walk goes
                // on; what the second holds past the page stays owed.
                let at = if pass.full_at_until && pass.last_until_secs > 0 {
                    owing = true;
                    pass.last_until_secs - 1
                } else {
                    pass.last_until_secs
                };
                // The walk is the circle's: it resumes where the id that
                // got least far down stopped.
                halted_at = Some(halted_at.map_or(at, |seen| seen.max(at)));
            }
            whole &= !pass.cut_off && pass.window.any_relay_drained;
        }
        if let Some(at_secs) = halted_at {
            session.settle_refused_range(self.group_id, read, RangePass::Halted { at_secs, owing });
        } else if whole && out.relay_errors == unanswered_before {
            session.settle_refused_range(self.group_id, read, RangePass::Whole { owing });
            // The relays' verdict on the walk is the stall detector's
            // evidence (T-EPOCH-STALL).
            session.history_walk_settled(self.group_id, owing);
        }
    }
}

/// Whether a top-down pass leaves its circle caught up: it finished, a relay
/// drained, and it held nothing back — an event it fetched and could not
/// apply may be the commit that matters.
fn caught_up_by(top: &PassResult, classified: &[(i64, ReceiveOnlyOutcome)]) -> bool {
    !top.window.saturated
        && top.window.any_relay_drained
        && !classified
            .iter()
            .any(|(_, outcome)| *outcome == ReceiveOnlyOutcome::Deferred)
}

/// Sweeps ONE circle: opens the window, fetches, ingests, and advances that
/// circle's cursor. Tallies into `out`.
///
/// # Two passes, and why the second one cannot be the first
///
/// The top-down pass over `[since, now]` runs on every sweep, in full. Only if
/// it ran out of budget — and only then — does a second pass resume the descent
/// at the persisted backfill floor, which is where an earlier sweep's chase
/// stopped (see [`CATCHUP_MAX_PAGES_PER_CIRCLE`]). Without that second pass a
/// window bigger than one sweep can retrieve has an oldest tail no sweep ever
/// reaches; with it, successive sweeps walk down to it.
///
/// Making the backfill REPLACE the top-down pass would cost less work and would
/// be wrong: the newest events are the ones a location app shows, and a relay in
/// the circle's list that contributes one minted event per page can make the
/// descent crawl for as long as it likes. Additive, that buys it nothing it did
/// not already have. As a replacement it would let one relay stop the OTHER
/// relays' fresh traffic from being fetched at all.
///
/// # ...and why the advance is not simply the better of the two
///
/// Each pass on its own can only ever establish the band IT finished, and that
/// band is bounded by one page budget while the top-down pass restarts at `now`
/// every sweep. A circle whose backlog outlasts a single pass therefore advanced
/// to the same place every time: the descent walked down, the completing pass
/// claimed its own resume ceiling, `since` came back below the whole backlog,
/// and the next sweep repeated the sweep before it — byte for byte, for ever,
/// with the cursor pinned and both budgets spent.
///
/// So the passes are COMPOSED. A halted pass has retrieved everything strictly
/// above the request it stopped on ([`PassResult::last_until_secs`]), and a
/// resumed pass that started exactly there continues that retrieval without a
/// gap; if the pair comes down to at or below the CURSOR, the whole window is
/// covered, because everything at or below the cursor is what the cursor already
/// claims. Both numbers are local — a request ceiling this device issued,
/// compared against this device's own cursor — so the composition adds no
/// remotely-written input to the advance.
///
/// Where the two do NOT abut (a floor an earlier sweep drove deeper leaves a
/// band this sweep asked nobody about), the sweep falls back to the one band it
/// did finish and the descent carries on next sweep.
///
/// Returns whether the top-down pass left the routing id caught up
/// ([`caught_up_by`]).
#[allow(clippy::too_many_lines)]
async fn sweep_one_circle(
    circle_mgr: &CircleManager,
    plane: &Plane<'_>,
    group_id: &GroupId,
    ngid: [u8; 32],
    relays: &[String],
    neg: Option<&NegRoute>,
    out: &mut CatchupOutcome,
) -> bool {
    let deadline = plane.deadline;
    let ngid_hex = hex::encode(ngid);
    let stream = group_cursor_stream(&ngid_hex);
    let ngid_hexes = vec![ngid_hex];
    // Rule-12 escape hatch, spent at most once per run of held sweeps: see
    // `CATCHUP_MAX_CUTOFF_HOLDS`. Storage-unavailable reads as "not yet", so a
    // locked device degrades to the strict rule rather than to the lenient one.
    let tolerate_cut_offs =
        circle_mgr.storage.read_cutoff_holds(&stream).unwrap_or(0) >= CATCHUP_MAX_CUTOFF_HOLDS;
    let sweep = CircleSweep {
        circle_mgr,
        plane,
        group_id,
        ngid_hexes,
        relays,
        deadline,
        started_out_of_time: Instant::now() >= deadline,
        ingested_any: AtomicBool::new(false),
        owing: AtomicBool::new(false),
        tolerate_cut_offs,
    };

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
    // Shared by both passes: a hold-back either of them found bounds whatever
    // the other goes on to claim, and the two bands overlap wherever a top-down
    // page reached below the floor.
    let mut classified: Vec<(i64, ReceiveOnlyOutcome)> = Vec::new();
    let top = sweep
        .fetch_and_ingest(since_secs, window_opened_at_secs, out, &mut classified)
        .await;
    let caught_up = caught_up_by(&top, &classified);

    // The band the advance may be taken from if the passes cannot be composed,
    // how far down this sweep's OWN contiguous retrieval reached, and the
    // ceiling of whatever is left under it. A finished top-down pass reaches the
    // REQ floor, so there is nothing left and any stored floor is spent.
    let mut established = top.window;
    let mut reached = pass_reach(&top, since_secs);
    let mut any_drained = top.window.any_relay_drained;
    let mut cut_off = top.cut_off;
    let mut unfinished_below = top.window.saturated.then_some(top.last_until_secs);

    // Storage-unavailable reads as "no floor": the resumed pass is an
    // OPTIMISATION over where to look next, never a licence to claim anything,
    // so losing it degrades to the plain top-down sweep instead of failing the
    // wake.
    let stored_floor = circle_mgr.read_backfill_floor(&stream).ok().flatten();

    // Resume only where the descent actually got FURTHER than this sweep's own
    // top-down pass. `<=` and not `<`: a backlog the budget cannot clear leaves
    // the top-down pass stopping at the same depth every sweep, so requiring a
    // strict gap would refuse the resume in exactly the steady state it exists
    // for — and equality is also the case the two passes COMPOSE in. A floor
    // ABOVE where the top pass reached is ground already covered, and the write
    // below lowers it instead. A floor at or below the REQ floor is spent
    // ground: resuming there would claim a band nobody asked about, and the
    // write below is what stops it disabling this circle's backfill for good.
    if let Some(floor) = unfinished_below
        .and_then(|stopped| stored_floor.filter(|f| since_secs < *f && *f <= stopped))
    {
        let backfill = sweep
            .fetch_and_ingest(since_secs, floor, out, &mut classified)
            .await;
        any_drained |= backfill.window.any_relay_drained;
        cut_off |= backfill.cut_off;
        // The two passes are one contiguous retrieval only where the backfill
        // resumed EXACTLY at the request the top-down pass stopped on. A deeper
        // floor leaves the band between them unasked-for by this sweep, and an
        // earlier sweep having covered it is not a claim this one may inherit.
        if floor == top.last_until_secs {
            reached = pass_reach(&backfill, since_secs);
        }
        if backfill.window.saturated {
            unfinished_below = Some(backfill.last_until_secs);
        } else {
            // A finished backfill establishes `[since, floor]` — a band this
            // pass drained itself, under the same rules the ordinary advance
            // uses, and never a claim inherited from the sweep that left the
            // floor behind. Its ceiling is the fallback advance target, and the
            // descent has nothing left under it: the next sweep's top-down pass
            // is where a resume point comes from in the first place.
            established = backfill.window;
            unfinished_below = None;
        }
    }

    // THE WHOLE WINDOW, composed. Everything at or below the cursor is what the
    // cursor already claims to have retrieved and applied, so a sweep whose own
    // contiguous retrieval came down to meet it has covered `[since, ceiling]`
    // with no gap — even though neither pass covered it alone.
    //
    // Without this the advance could never exceed the deepest band ONE pass
    // finished, which is bounded by one page budget while the top-down pass
    // restarts at `now` every sweep: a circle whose backlog outlasts a single
    // pass converged on a limit cycle instead, re-fetching and re-ingesting the
    // same window for ever with its cursor pinned. Both inputs are local — a
    // request ceiling this device issued, against this device's own cursor — so
    // nothing remotely written enters the comparison.
    //
    // Meeting the CURSOR and not the REQ floor is deliberate, and costs the
    // `GROUP_RESUBSCRIBE_BUFFER_SECS` re-read of the band just under it on this
    // one path: that band was requested (it is inside every page's `since`) but
    // not proven drained. The buffer is a re-verification margin below a claim
    // the cursor already makes, not a band the cursor leaves unclaimed, so
    // stopping at it would refuse the composition in exactly the steady state it
    // exists for.
    if reached <= cursor_ms.div_euclid(1000) {
        established = FetchWindow {
            ceiling_secs: window_opened_at_secs,
            saturated: false,
            any_relay_drained: any_drained,
        };
        unfinished_below = None;
    }

    // THE WHOLE WINDOW, reconciled ([`reconciled_window`]), after the
    // pager's passes and the composition: what they took in is not asked for
    // again, and a covered window is claimed with the relays that answered.
    if let Some(window) = reconciled_window(
        &sweep,
        neg,
        (since_secs, window_opened_at_secs),
        out,
        &mut classified,
    )
    .await
    {
        established = window;
        unfinished_below = None;
    }

    // The clamp reads the clock AGAIN so a long sweep is measured against a
    // current wall clock, never the stale one the window opened with.
    let advance = cursor_advance_ms(
        established,
        &hold_backs(&classified),
        chrono::Utc::now().timestamp(),
    );
    // Exactly the negation of the advance condition, so the tally cannot say
    // "drained this circle" about a circle whose cursor was held.
    if advance.is_none() {
        out.windows_truncated += 1;
    }
    if let Some(ms) = advance {
        if circle_mgr.advance_sync_cursor(&stream, ms).is_ok() {
            out.cursors_advanced += 1;
        }
    }

    // Where the descent has to resume next. A floor an earlier sweep drove
    // deeper still stands — unless the cursor has since risen past it, which
    // makes it ground no REQ covers any more.
    let next_floor = unfinished_below.map(|secs| {
        stored_floor
            .filter(|f| *f > since_secs)
            .map_or(secs, |f| f.min(secs))
    });
    // Two writes, because the storage primitive only ever LOWERS a floor (so a
    // sweep that reached less far cannot undo an earlier one's descent) while
    // the repair above has to move one UP, off ground the cursor has passed.
    // Clearing first is what makes the insert unconditional. Best-effort either
    // way: a failed write leaves no floor, which is the restart-at-the-newest-
    // end a circle that never halted already gets.
    let _ = circle_mgr.clear_backfill_floor(&stream);
    if let Some(secs) = next_floor {
        let _ = circle_mgr.lower_backfill_floor(&stream, secs);
    }

    // The tolerance is spent whether or not it produced an advance, so a relay
    // that stays broken costs a bounded run of held sweeps and then another,
    // rather than disarming the rule from here on.
    let _ = if tolerate_cut_offs || advance.is_some() || !cut_off {
        circle_mgr.storage.clear_cutoff_holds(&stream)
    } else {
        circle_mgr.storage.bump_cutoff_holds(&stream)
    };
    caught_up
}

/// Runs `neg`, the routing's NIP-77 pass, when the sweep has room for it, and
/// the window `[since, ceiling]` it then establishes, if any.
///
/// Every relay of the routing answered a session over a band containing the
/// window with a set under the limit, everything any of them reported and
/// this device lacked was asked of the relay that reported it in an answer
/// it finished, and the engine holds, or the refused ledger owes, everything
/// that came back ([`negentropy::NegCoverage::whole`]). Both bounds of the band are local
/// clock readings, so nothing remote enters the comparison, and what the pass
/// took in joins `classified`, whose hold-backs still bound the advance. A
/// routing with a relay that does not speak NIP-77 keeps the pager's rule.
async fn reconciled_window(
    sweep: &CircleSweep<'_>,
    neg: Option<&NegRoute>,
    (since_secs, ceiling_secs): (i64, i64),
    out: &mut CatchupOutcome,
    classified: &mut Vec<(i64, ReceiveOnlyOutcome)>,
) -> Option<FetchWindow> {
    let route =
        neg.filter(|_| sweep.deadline.saturating_duration_since(Instant::now()) >= NEG_ROOM)?;
    let relays = sweep.plane.relays;
    relays.neg_prepare(&route.relays).await;
    let sink = CatchupSink {
        sweep,
        tally: std::sync::Mutex::new((CatchupOutcome::default(), Vec::new())),
    };
    let coverage =
        negentropy::reconcile_route(relays, sweep.circle_mgr.session(), route, &sink).await;
    sink.drain_into(out, classified);
    coverage
        .covers(since_secs, ceiling_secs)
        .then_some(FetchWindow {
            ceiling_secs,
            saturated: false,
            any_relay_drained: true,
        })
}

/// One circle's sweep: everything the paged fetch-and-ingest loop needs that
/// does not change from page to page.
///
/// A struct rather than a nine-argument function, and — like [`RoundSummary`] —
/// with no derived formatter, because it holds relay URLs and a group id.
struct CircleSweep<'a> {
    circle_mgr: &'a CircleManager,
    plane: &'a Plane<'a>,
    /// The circle whose traffic every page carries: its current epoch is
    /// what each page is ordered against.
    group_id: &'a GroupId,
    /// The PUBLIC `nostr_group_id`s in hex, which every page filters `#h` on
    /// (Security Rule 4 — never the MLS group id).
    ngid_hexes: Vec<String>,
    relays: &'a [String],
    deadline: Instant,
    /// The wake budget was ALREADY gone when this circle was entered, so this
    /// sweep never had time to spend and the progress floor in [`ingest_page`]
    /// does not apply to it.
    started_out_of_time: bool,
    /// Whether any event of this circle has been through `ingest_one` yet.
    /// Atomic rather than `Cell` so the sweep stays `Sync` and the futures
    /// holding `&self` across an await stay `Send`.
    ingested_any: AtomicBool,
    /// Whether the engine holds nothing of an event this sweep fetched: it
    /// had no room for it, erred on it, or was never handed it.
    owing: AtomicBool,
    /// This circle has been held on cut-off deliveries alone for
    /// [`CATCHUP_MAX_CUTOFF_HOLDS`] sweeps running, so this one treats a relay
    /// that hands over events without finishing as UNREACHED instead.
    tolerate_cut_offs: bool,
}

impl CircleSweep<'_> {
    /// Retrieves the band `[since_secs, ceiling_secs]` of one circle's window,
    /// paging BACKWARDS until a round brings back nothing new, and ingesting
    /// each page as it arrives.
    ///
    /// Appends what every ingested event said about the cursor to `classified`
    /// — shared across a sweep's passes, so a hold-back one pass found still
    /// bounds what another pass may claim — and returns the two FETCH-level
    /// facts [`cursor_advance_ms`] gates the advance on, plus the ceiling of
    /// whatever is left below (see [`PassResult`]).
    ///
    /// # One ceiling for the whole chain
    ///
    /// Every page shares the caller's single `ceiling_secs` and the same
    /// locally derived `since`; the clock is deliberately NOT re-read per page.
    /// Later pages go out later in wall-clock time, which can only ADD events a
    /// relay did not hold at the ceiling instant, never remove one it did — so
    /// "everything these relays held at the moment I asked", the claim the
    /// ceiling encodes, stays true of the union the chain builds.
    ///
    /// # Why the ingest is per page and not per window
    ///
    /// The pages of one chase are fetched newest-first, so ingesting each on
    /// arrival hands the engine a descending sequence rather than an ascending
    /// one. A commit that arrives before its predecessor is not merely delayed:
    /// a `kind:445`'s outer layer is keyed by the exporter of the epoch it was
    /// SENT in, so it does not peel at all, the engine reports `Stale` and
    /// retains it, and neither the predecessor landing a page later nor
    /// `ingest_one`'s convergence re-tick re-drives it inside this sweep. The
    /// pair converges on the NEXT sweep instead, whose floor sits below both —
    /// so the descending order costs a re-fetch, never a loss
    /// (`two_dependent_commits_split_across_pages_converge_on_the_next_sweep`
    /// drives exactly that pair through a real chase).
    /// The alternative costs more: a chase can outlast a 20–25 s wake, and
    /// collecting every page before applying any means a deadline landing
    /// mid-chase applies NOTHING — then does the same on the next wake, and the
    /// one after, because the cursor is rightly held and the backlog is still
    /// there. Buffering is recoverable; never applying anything is not.
    ///
    /// A commit is the exception, because MDK drops for good one it takes in
    /// before the proposal it commits (`docs/MDK_UPSTREAM_TRACKER.md`
    /// T-COMMIT-BEFORE-PROPOSAL), and newest-first the proposal can lie a
    /// page further down. So a page the chase goes on past holds its
    /// current-epoch commits until a later page has brought something;
    /// they are taken in at the chase's end, and at a halt they stay unread
    /// and hold the cursor instead.
    #[deny(clippy::wildcard_enum_match_arm)]
    #[allow(clippy::too_many_lines)]
    async fn fetch_and_ingest(
        &self,
        since_secs: i64,
        ceiling_secs: i64,
        out: &mut CatchupOutcome,
        classified: &mut Vec<(i64, ReceiveOnlyOutcome)>,
    ) -> PassResult {
        let mut window = FetchWindow {
            ceiling_secs,
            saturated: false,
            any_relay_drained: false,
        };
        let mut pager = Pager {
            since_secs,
            // One second ABOVE the ceiling: `bound_secs` is exclusive where a
            // REQ's `until` is inclusive, and the two ranges differ by exactly
            // the ceiling's own second. Without the offset, a band whose whole
            // content is dated in the second the pass opened at yields a
            // boundary AT the ceiling, is refused as non-descending, and holds —
            // a quiet circle loses a sweep, reported as backlog it does not
            // have, and a resumed backfill whose newest event sits on the floor
            // never descends at all. With it that second is re-asked ONCE, and
            // the answer decides: nothing new means drained, anything new means
            // something was withheld or has since arrived and the window holds.
            // Not a loop, because from round two `bound_secs` is the previous
            // `until` and the descent is strict again.
            bound_secs: ceiling_secs.saturating_add(1),
            until_secs: ceiling_secs,
            confirming: false,
            pages: 0,
            collected: 0,
        };
        let mut state = ChaseState::default();
        let mut cut_off = false;
        // Shrinks as relays drop out of the chase. A relay we could not read to
        // the end contributes nothing to any later round — it cannot propose an
        // `until` and cannot vouch for one — so re-asking it only spends the
        // wake budget on another fetch timeout. Left in, one dead relay eats the
        // whole budget and the chase halts on the deadline instead of finishing
        // on the relays that are answering.
        let mut active: Vec<String> = self.relays.to_vec();
        // EVERY page is bounded above, the first one by the ceiling itself, so
        // the band requested is exactly the `[since, ceiling]` the window
        // claims. Leave the first page unbounded and 500 future-dated
        // `kind:445`s — which any observer of the circle's PUBLIC `#h` can mint
        // — fill it, put the boundary at or above the band's ceiling, and halt
        // the chase on arrival: a frozen cursor, bought for one publish and
        // re-bought on every wake. A genuinely future-dated peer event is merely
        // deferred to the next sweep, whose floor sits below it.
        let mut until_secs = ceiling_secs;
        // The current-epoch commits of a page the chase goes on past, held
        // until a later page has brought something: the proposal a commit
        // commits is signed before it, so a newest-first chase can cut
        // between them.
        let mut held: Vec<Event> = Vec::new();

        loop {
            let filter = group_filter(&self.ngid_hexes, since_secs)
                .limit(CATCHUP_MAX_EVENTS_PER_PAGE)
                // Only a pre-1970 local clock can put a ceiling out of range
                // (`Pager::step` floors every boundary at `since_secs`, itself
                // floored at 0). `u64::MAX` then leaves the page unbounded
                // ABOVE, whose boundary necessarily sits at or over the band's
                // negative ceiling and HALTS the chase with the cursor held —
                // where a floored `0` would fabricate an empty page and read as
                // a completed window.
                .until(Timestamp::from(
                    u64::try_from(until_secs).unwrap_or(u64::MAX),
                ));
            let Ok(fetch_outcomes) = self
                .plane
                .relays
                .fetch_events_per_relay(filter, &active)
                .await
            else {
                // The primitive documents that it never fails as a whole; should
                // that ever change, an unanswered page is an unfinished chase,
                // and an unfinished chase holds the cursor.
                out.relay_errors += 1;
                window.saturated = true;
                self.defer_held(&held, out, classified);
                return PassResult {
                    window,
                    last_until_secs: until_secs,
                    cut_off,
                    full_at_until: false,
                };
            };
            pager.pages += 1;

            let round = summarize_round(&fetch_outcomes, &state, self.tolerate_cut_offs);
            window.any_relay_drained |= round.any_drained;
            cut_off |= !round.cut_off.is_empty();
            active.retain(|url| !round.cut_off.contains(url));
            out.relay_errors += round.unanswered;
            state.chasing = round.chasing;
            state.silent = round.silent;
            let full_at_until = !round.read_incomplete && full_at(&fetch_outcomes, until_secs);

            let mut page: Vec<Event> = Vec::new();
            for fo in fetch_outcomes {
                for ev in fo.events {
                    if state.seen.insert(ev.id) {
                        page.push(ev);
                    }
                }
            }
            pager.collected += page.len();
            if !page.is_empty() {
                let cut = !matches!(
                    pager.step(
                        round.boundary_secs,
                        round.repeat_page,
                        round.read_incomplete,
                        false
                    ),
                    PageStep::Complete
                );
                held = self
                    .ingest_page(page, std::mem::take(&mut held), cut, out, classified)
                    .await;
            }

            // The deadline bounds the CHASE too, not just the ingest inside it:
            // a circle whose relays keep answering in full must not eat the
            // whole wake budget and starve the circles after it.
            let out_of_time = Instant::now() >= self.deadline;
            match pager.step(
                round.boundary_secs,
                round.repeat_page,
                round.read_incomplete,
                out_of_time,
            ) {
                PageStep::Complete => {
                    if !held.is_empty() {
                        self.ingest_page(Vec::new(), held, false, out, classified)
                            .await;
                    }
                    return PassResult {
                        window,
                        last_until_secs: until_secs,
                        cut_off,
                        full_at_until: false,
                    };
                }
                // A commit still held is never handed over here: the page
                // that would bring its proposal was not read, and taken in
                // alone it is dropped for good. It holds the cursor instead,
                // and the next sweep fetches it again.
                PageStep::Halt => {
                    if out_of_time {
                        out.deadline_hit = true;
                    }
                    self.defer_held(&held, out, classified);
                    window.saturated = true;
                    return PassResult {
                        window,
                        last_until_secs: until_secs,
                        cut_off,
                        full_at_until,
                    };
                }
                PageStep::Next(until) => {
                    pager.bound_secs = until;
                    pager.until_secs = until;
                    pager.confirming = false;
                    until_secs = until;
                }
                // `bound_secs` deliberately stays where it was: a confirming
                // step already sits strictly below the `until` that produced it,
                // so any boundary it brings back descends without help.
                PageStep::Confirm(until) => {
                    pager.until_secs = until;
                    pager.confirming = true;
                    until_secs = until;
                }
            }
        }
    }

    /// Ingests ONE page with what an earlier page held, in the order
    /// [`SessionManager::order_for_ingest`] gives, recording what each says
    /// about the cursor; a current-epoch commit of a `cut` page is held
    /// instead, and returned.
    ///
    /// The batch is first sorted ascending `(created_at, id)`: a page
    /// arrives in no order this code may rely on, ascending is the order an
    /// ordering that fails open keeps, and going oldest-first is what makes a
    /// deadline landing mid-page leave the OLDEST un-ingested events for the
    /// hold-back below.
    ///
    /// A classification is captured HERE and never revised, so a hold-back
    /// stands for the rest of the sweep even if something later resolves what
    /// deferred it — a later page, or the publish work this same ingest went on
    /// to confirm. Revising would mean re-classifying after every convergence
    /// tick to save a re-fetch that costs one round; leaving a stale hold-back
    /// in place costs one sweep of delay and can never advance the cursor over
    /// something un-applied, which is the direction that matters.
    #[deny(clippy::wildcard_enum_match_arm)]
    async fn ingest_page(
        &self,
        mut page: Vec<Event>,
        carried: Vec<Event>,
        cut: bool,
        out: &mut CatchupOutcome,
        classified: &mut Vec<(i64, ReceiveOnlyOutcome)>,
    ) -> Vec<Event> {
        let carried_ids: HashSet<EventId> = carried.iter().map(|event| event.id).collect();
        page.extend(carried);
        page.sort_by(|a, b| a.created_at.cmp(&b.created_at).then(a.id.cmp(&b.id)));
        let mut held = Vec::new();
        let mut taken = Vec::with_capacity(page.len());
        for (class, event) in self
            .circle_mgr
            .session()
            .order_for_ingest(self.group_id, page)
            .await
        {
            if cut && class == IngestClass::Commit && !carried_ids.contains(&event.id) {
                held.push(event);
            } else {
                taken.push(event);
            }
        }
        // Fetched and not in: no location is sealed for the circle until an
        // ingest takes each in, on whichever plane (Security Rule 10).
        if !held.is_empty() {
            self.circle_mgr
                .session()
                .hold_pager_commits(self.group_id, held.iter().map(|event| &event.id));
        }
        let page = taken;
        for (idx, ev) in page.iter().enumerate() {
            // THE PROGRESS FLOOR. A sweep that entered with budget must apply
            // at least ONE of the events it spent that budget fetching. Bailing
            // at index 0 leaves the cursor exactly where the next wake starts,
            // so that wake re-fetches the same page and bails in the same place:
            // zero events applied, for as many wakes as it takes to never
            // converge. Whether any budget survives the opening fetch is a
            // property of the network and the machine, so without this floor the
            // guarantee holds by luck rather than by construction.
            //
            // The overrun it buys is one `ingest_one` — the deadline binds again
            // for event two onwards, including the rest of THIS page. A sweep
            // that was already out of time before it began gets no floor: it has
            // no spent budget to redeem, and staying a clean no-op is the
            // contract `an_expired_deadline_sweeps_nothing_and_reports_it` and
            // `a_deadline_that_cuts_the_batch_short_holds_the_cursor_at_the_unreached_tail`
            // pin.
            let owes_progress =
                !self.started_out_of_time && !self.ingested_any.load(Ordering::Relaxed);
            if !owes_progress && Instant::now() >= self.deadline {
                out.deadline_hit = true;
                // Everything from here on was FETCHED but never ingested. The
                // window is therefore not fully applied, and without this the
                // window-open anchor would happily claim it: the advance would
                // jump over an un-ingested tail that only a future sweep with a
                // lower floor could ever recover. Classify the remainder as
                // deferred so each one holds the cursor at or below itself.
                classified.extend(
                    page[idx..]
                        .iter()
                        .map(|pending| (created_secs(pending), ReceiveOnlyOutcome::Deferred)),
                );
                out.events_deferred += page.len() - idx;
                self.owing.store(true, Ordering::Relaxed);
                return held;
            }
            let secs = created_secs(ev);
            let (outcome, left) = ingest_judged(self.circle_mgr, self.plane, ev).await;
            self.ingested_any.store(true, Ordering::Relaxed);
            if outcome == ReceiveOnlyOutcome::NoEvidence {
                self.judge_refused(ev);
            }
            if left != Left::WithTheEngine {
                self.owing.store(true, Ordering::Relaxed);
            }
            match outcome {
                ReceiveOnlyOutcome::Applied => out.events_applied += 1,
                ReceiveOnlyOutcome::Deferred => out.events_deferred += 1,
                ReceiveOnlyOutcome::NoEvidence => out.events_rejected_pre_auth += 1,
                ReceiveOnlyOutcome::Stranded => out.events_stranded += 1,
            }
            classified.push((secs, outcome));
        }
        held
    }

    /// Records `ev`, which Haven's screen refused, as judged under the routing
    /// this page was asked for, and no other ([`SessionManager::neg_judge_refused`]).
    fn judge_refused(&self, ev: &Event) {
        if let [routing_hex] = self.ngid_hexes.as_slice() {
            if let Some(routing) = hex::decode(routing_hex)
                .ok()
                .and_then(|bytes| <[u8; 32]>::try_from(bytes.as_slice()).ok())
            {
                self.circle_mgr.session().neg_judge_refused(&routing, ev);
            }
        }
    }

    /// Records each of `held`, never handed to the engine, as deferred: it
    /// holds the cursor at or below itself, and the sweep is owing.
    fn defer_held(
        &self,
        held: &[Event],
        out: &mut CatchupOutcome,
        classified: &mut Vec<(i64, ReceiveOnlyOutcome)>,
    ) {
        if held.is_empty() {
            return;
        }
        // Each stays held unread (`ingest_page`) until an ingest takes it in.
        classified.extend(
            held.iter()
                .map(|event| (created_secs(event), ReceiveOnlyOutcome::Deferred)),
        );
        out.events_deferred += held.len();
        self.owing.store(true, Ordering::Relaxed);
    }
}

#[cfg(test)]
mod tests {
    use super::{
        cursor_advance_ms, drain_convergence, hold_backs, ingest_one, summarize_round, ChaseState,
        FetchWindow, HashSet, PageStep, Pager, ReceiveOnlyOutcome, ReceiveOnlyOutcome as O,
        RelayFetchOutcome, CATCHUP_MAX_EVENTS_PER_CIRCLE, CATCHUP_MAX_EVENTS_PER_PAGE,
        CATCHUP_MAX_PAGES_PER_CIRCLE,
    };

    /// The sweep a wake runs — it makes no commit — over a transport that
    /// takes no relay, with a budget no test here reaches.
    fn plane(relays: &crate::relay::RelayManager) -> super::Plane<'_> {
        plane_until(
            relays,
            std::time::Instant::now() + std::time::Duration::from_mins(10),
        )
    }

    /// [`plane`], ending at `deadline`.
    fn plane_until(
        relays: &crate::relay::RelayManager,
        deadline: std::time::Instant,
    ) -> super::Plane<'_> {
        let inert: &'static dyn super::FanoutSend = &crate::relay::fanout::scripted::Inert;
        let finishing: &'static super::Publishing<'static, dyn super::FanoutSend> =
            Box::leak(Box::new(super::Publishing {
                fanout: inert,
                publisher: &crate::relay::fanout::scripted::Inert,
                clock: &super::WallClock,
                deadline_ms: None,
                mode: &super::DriveMode::FinishOnly,
            }));
        super::Plane::driving(relays, finishing, deadline)
    }

    /// A `now` far past every timestamp these batches use, so the clamp is
    /// inert and each test isolates the rule it is actually about.
    const NOW: i64 = 2_000_000_000;

    /// The local clock reading a healthy window opened at. Every "advance to"
    /// assertion below is against THIS number, never against an event's.
    const OPENED: i64 = 1_000_000;

    /// A window that reached its relays and was not truncated.
    const fn healthy() -> FetchWindow {
        FetchWindow {
            ceiling_secs: OPENED,
            saturated: false,
            any_relay_drained: true,
        }
    }

    // ---- What holds a cursor (Security Rule 12): one classification, shared
    // with the driver's poll entry.

    /// Every engine answer, and whether a cursor may pass the event it was
    /// given for. What the engine refused for a local bound, what it kept no
    /// trace of and what it only buffered each hold; everything it applied or
    /// handled for good does not; and an answer of `Ignored` holds nothing
    /// even with no trace kept, because no redelivery can change it.
    #[tokio::test]
    async fn only_what_the_engine_refused_lost_or_buffered_holds_a_cursor() {
        use crate::nostr::mls::types::{
            EpochId, GroupId, InboundResourceLimit, IngestOutcome, InputRejectionCategory,
        };

        let dir = tempfile::TempDir::new().expect("temp dir");
        let circle =
            crate::circle::CircleManager::new_unencrypted(dir.path(), &nostr::Keys::generate())
                .expect("circle manager");
        let group = GroupId::new([0x5a; 32]);
        let refused = || IngestOutcome::ResourceRefused {
            group_id: group.clone(),
            resource: InboundResourceLimit::TransportDeferredCapacity,
        };
        let buffered = || IngestOutcome::Buffered {
            group_id: group.clone(),
            epoch: EpochId(3),
        };
        let ignored = || IngestOutcome::Ignored {
            category: InputRejectionCategory::UnknownGroup,
        };
        for (outcome, unpersisted, verdict) in [
            (refused(), true, O::Deferred),
            (refused(), false, O::Deferred),
            (IngestOutcome::Processed, true, O::Deferred),
            (buffered(), false, O::Deferred),
            (IngestOutcome::Processed, false, O::Applied),
            (ignored(), true, O::Applied),
            (ignored(), false, O::Applied),
        ] {
            assert_eq!(
                super::cursor_verdict(&circle, &nostr::EventId::all_zeros(), outcome, unpersisted)
                    .await,
                verdict,
                "the cursor's verdict for an engine answer (unpersisted: {unpersisted})",
            );
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
    fn a_window_of_only_screened_or_undecryptable_events_still_advances() {
        // Two shapes that both stalled the contiguous prefix at index 0 and can
        // each be produced remotely for free: a run of pre-auth-screened
        // (unparseable) events, and a run of engine-terminal ones (`Stale`,
        // which is what an undecryptable or future-epoch application message
        // yields).
        let all_screened = [(1, O::NoEvidence), (2, O::NoEvidence)];
        let all_stale = [(1, O::Applied), (2, O::Applied)];
        for batch in [all_screened.as_slice(), all_stale.as_slice()] {
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
        // sell an attacker a permanent stall for one forged event. Nor does
        // `Stranded`: the engine answers every redelivery of that event from
        // its own row, so a hold would fetch it again at every sweep.
        let batch = [
            (4, O::Stranded),
            (5, O::Applied),
            (6, O::NoEvidence),
            (7, O::Deferred),
        ];
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
            any_relay_drained: false,
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
            any_relay_drained: false,
            ..healthy()
        };
        assert_eq!(cursor_advance_ms(both, &[], NOW), None);
    }

    // ---- The backward pager's termination rule (pure — no relay involved).
    //
    // The rule these pin: the window may be called COMPLETE only when a round of
    // pages came back with no relay truncated — a local count of what arrived.
    // Every other outcome is `Halt`, which leaves `saturated` set and the cursor
    // held, because a conservative hold costs a re-fetch and a wrong advance
    // costs the backlog.

    /// A pager mid-chase: it has issued one page, holds a few events, and its
    /// band is `[SINCE, BOUND)`.
    const fn chasing_pager() -> Pager {
        Pager {
            since_secs: 1_000,
            bound_secs: 5_000,
            until_secs: 5_000,
            confirming: false,
            pages: 1,
            collected: CATCHUP_MAX_EVENTS_PER_PAGE,
        }
    }

    #[test]
    fn a_round_where_nobody_contributed_completes_the_window() {
        // The ONLY exit that may report a complete window, and it is decided by
        // local facts about the fetch — a count of what arrived and a membership
        // test against ids we already hold — never by anything an event says.
        assert_eq!(
            chasing_pager().step(None, false, false, false),
            PageStep::Complete,
            "no responding relay handed back a full page or an event we did not \
             already have, so there is nothing left below what we hold"
        );
    }

    #[test]
    fn a_truncated_round_pages_backwards_from_the_boundary() {
        assert_eq!(
            chasing_pager().step(Some(3_000), false, false, false),
            PageStep::Next(3_000),
            "a truncated page has an unretrieved tail below its oldest event; \
             the next page must go and get it"
        );
    }

    #[test]
    fn a_boundary_that_does_not_descend_halts_instead_of_spinning() {
        // THE TERMINATION GUARANTEE against adversarial input. A relay can
        // answer every page with the same events forever (or date a full page
        // inside one second, which is the same thing to the `until` chain).
        // Without a strict descent the loop would never end; with it, the window
        // is simply reported incomplete and the cursor holds.
        for repeated in [chasing_pager().bound_secs, chasing_pager().bound_secs + 1] {
            assert_eq!(
                chasing_pager().step(Some(repeated), false, false, false),
                PageStep::Halt,
                "a boundary of {repeated} does not descend below the band's \
                 ceiling and must not be followed",
            );
        }
    }

    #[test]
    fn the_windows_own_opening_second_is_asked_again_rather_than_refused() {
        // The rule above is reached WITHOUT an attacker by an ordinary quiet
        // circle: the first page's `until` is the window's own open second, so a
        // circle whose only new event is published in that second hands back a
        // boundary AT it. Refusing that boundary would cost the sweep — no
        // cursor advance, one circle reported as truncated backlog it does not
        // have — for a shape nobody chose. `bound_secs` is therefore EXCLUSIVE
        // and opens one second above the anchor, so the opening second is
        // re-requested once instead.
        let opening = Pager {
            since_secs: OPENED - 3_600,
            bound_secs: OPENED + 1,
            until_secs: OPENED,
            confirming: false,
            pages: 1,
            collected: 1,
        };
        assert_eq!(
            opening.step(Some(OPENED), false, false, false),
            PageStep::Next(OPENED),
            "the identical request, once: its answer is what tells drained from \
             still-hiding, and no other round can ask it"
        );

        // And the slack is spent: from the second round on, `bound_secs` is the
        // previous `until` and the descent is strict again — so a relay that
        // keeps answering inside that one second halts the chase instead of
        // spinning it, with the window left incomplete.
        let after_the_repeat = Pager {
            bound_secs: OPENED,
            until_secs: OPENED,
            pages: 2,
            ..opening
        };
        assert_eq!(
            after_the_repeat.step(Some(OPENED), false, false, false),
            PageStep::Halt,
        );
    }

    #[test]
    fn a_boundary_below_our_own_since_is_not_followed() {
        // The floor half of the band. A relay serving events below the `since`
        // WE chose is answering something we did not ask; its bottom is not a
        // point in this window, so it steers no request. Halting keeps the
        // window incomplete rather than accepting a claim about a range outside
        // the filter.
        assert_eq!(
            chasing_pager().step(Some(chasing_pager().since_secs - 1), false, false, false),
            PageStep::Halt,
        );
        assert_eq!(
            chasing_pager().step(Some(chasing_pager().since_secs), false, false, false),
            PageStep::Next(1_000),
            "the floor itself is still inside the band — the boundary may land \
             exactly on our own REQ floor",
        );
    }

    #[test]
    fn the_page_budget_stops_the_chase_without_claiming_completeness() {
        // Rule 12 backpressure: paging removed the per-page limit's second job
        // of bounding the SWEEP, so the bound lives here. Reaching it must NOT
        // read as "complete" — that would be exactly the silent drop of
        // legitimate offline backlog the limit exists to prevent.
        let exhausted = Pager {
            pages: CATCHUP_MAX_PAGES_PER_CIRCLE,
            ..chasing_pager()
        };
        assert_eq!(
            exhausted.step(Some(3_000), false, false, false),
            PageStep::Halt
        );
    }

    #[test]
    fn the_per_circle_event_budget_stops_the_chase() {
        // The memory ceiling, which binds before the page budget once a circle
        // has several relays each answering a full page per round.
        let stuffed = Pager {
            collected: CATCHUP_MAX_EVENTS_PER_CIRCLE,
            ..chasing_pager()
        };
        assert_eq!(
            stuffed.step(Some(3_000), false, false, false),
            PageStep::Halt
        );
    }

    #[test]
    fn the_deadline_stops_the_chase() {
        // The wake budget bounds the CHASE, not just the ingest: one circle
        // whose relays keep answering in full must not starve the circles after
        // it. Still incomplete, never complete.
        assert_eq!(
            chasing_pager().step(Some(3_000), false, false, true),
            PageStep::Halt
        );
    }

    #[test]
    fn being_late_does_not_make_a_complete_window_incomplete() {
        // The complement of the case above, and the reason `out_of_time` is read
        // only AFTER a relay has truncated. Hoisting that check to the top would
        // read identically on every test that asserts a chase stops — and would
        // silently mark every deadline-exceeded sweep's windows truncated,
        // freezing the cursor of every circle a slow wake reached last.
        assert_eq!(
            chasing_pager().step(None, false, false, true),
            PageStep::Complete,
            "nobody truncated, so the window is complete however late the round \
             finished — the deadline bounds the CHASE, it is not evidence about \
             the window"
        );
    }

    #[test]
    fn a_chase_that_produced_nothing_blocks_completeness() {
        // The hole a bare "no truncated page this round ⇒ complete" would leave:
        // the relay that truncated LAST round is the one with a known tail, and
        // if it produces nothing, the round's silence is not evidence of
        // completeness. It must not be readable as one.
        assert_eq!(
            chasing_pager().step(None, false, true, false),
            PageStep::Halt,
            "a round that lost the relay it was draining proves nothing about \
             that relay's tail"
        );
        assert_eq!(
            chasing_pager().step(Some(3_000), false, true, false),
            PageStep::Halt,
            "and it stops the chase outright rather than paging on for a window \
             this sweep can no longer complete"
        );
    }

    // ---- The round summary: where the one remote number is chosen.

    /// A page of `count` events whose OLDEST is dated `oldest_secs`. Only the
    /// length and the timestamps are read by the summary, so the filler events
    /// are clones — a page of 500 real signatures would cost far more than the
    /// property is worth.
    fn page(count: usize, oldest_secs: i64) -> Vec<nostr::Event> {
        let at = |secs: i64| {
            EventBuilder::new(Kind::Custom(445), "b3BhcXVl")
                .custom_created_at(Timestamp::from(u64::try_from(secs).unwrap()))
                .sign_with_keys(&Keys::generate())
                .unwrap()
        };
        let mut events = vec![at(oldest_secs + 1_000); count.saturating_sub(1)];
        events.push(at(oldest_secs));
        events
    }

    /// A relay that FINISHED answering: it served `events` and then signalled
    /// end-of-stored-events, so this page is the whole of what it holds here.
    fn answered(url: &str, events: Vec<nostr::Event>) -> RelayFetchOutcome {
        RelayFetchOutcome {
            relay_url: url.to_string(),
            responded: true,
            drained: true,
            events,
        }
    }

    /// A relay whose delivery was CUT OFF: `events` arrived, no
    /// end-of-stored-events ever did. Byte-for-byte an `answered` page in its
    /// content — which is the entire reason `drained` has to be carried
    /// alongside it.
    fn cut_off(url: &str, events: Vec<nostr::Event>) -> RelayFetchOutcome {
        RelayFetchOutcome {
            drained: false,
            ..answered(url, events)
        }
    }

    /// The state a previous round would have left behind after `url` served
    /// `page`: every id already seen, and `url` still being drained.
    fn after_serving(url: &str, served: &[nostr::Event]) -> ChaseState {
        ChaseState {
            chasing: std::iter::once(url.to_string()).collect(),
            silent: HashSet::new(),
            seen: served.iter().map(|ev| ev.id).collect(),
        }
    }

    #[test]
    fn a_page_carrying_anything_new_keeps_the_chase_alive_however_small_it_is() {
        // THE CLAMP DEFENCE. A relay serves fewer events than we asked for
        // either because it holds no more or because NIP-11
        // `limitation.max_limit` caps what it will serve, and the two are the
        // same page. Chasing on page SIZE alone never chases the second at all —
        // no page can reach a limit the relay has already clamped away — so the
        // window reads as complete and the cursor advances over everything below
        // the cap. A page that hands over an event we did not already hold is
        // therefore still a relay being drained, whatever its size.
        let round = summarize_round(
            &[answered("wss://a", page(3, 10))],
            &ChaseState::default(),
            false,
        );
        assert_eq!(round.boundary_secs, Some(10));
        assert!(round.chasing.contains("wss://a"));
        assert!(round.any_drained);
    }

    #[test]
    fn a_page_of_nothing_but_already_seen_events_is_confirmed_one_second_lower() {
        // THE TERMINATION HALF of the same rule: a relay drained down to `since`
        // answers the next, narrower page with events we already hold, so its
        // chase ends here.
        //
        // Ending the chase is NOT the same as the window being complete, and
        // reading it as one is a silent drop that needs no attacker. A relay
        // clamping our `limit` to its own NIP-11 `max_limit` serves the newest
        // `cap` events, so one whose cap sits at or below the number of events
        // sharing this `until`'s second hands back the identical already-seen
        // page every round while holding a backlog underneath it — a page
        // byte-for-byte the same as this genuinely-drained one. So the chase
        // asks one second lower instead of choosing between them.
        let served = page(3, 10);
        let state = after_serving("wss://a", &served);
        let round = summarize_round(&[answered("wss://a", served)], &state, false);
        assert_eq!(round.boundary_secs, None);
        assert!(round.chasing.is_empty());
        assert!(
            round.repeat_page,
            "a non-empty page that contributed nothing is the ambiguous shape"
        );
        assert_eq!(
            chasing_pager().step(
                round.boundary_secs,
                round.repeat_page,
                round.read_incomplete,
                false
            ),
            PageStep::Confirm(chasing_pager().until_secs - 1),
            "one step below the request that produced the repeat — the only \
             question whose answer separates 'nothing below' from 'clamped'"
        );
    }

    #[test]
    fn one_confirming_step_is_all_a_chase_gets() {
        // The bound that stops the confirming step becoming a second way to spin
        // the loop: a relay that repeats its page forever gets asked exactly
        // once more, and the round after that ends the chase.
        let confirmed = Pager {
            confirming: true,
            ..chasing_pager()
        };
        assert_eq!(
            confirmed.step(None, true, false, false),
            PageStep::Complete,
            "the second repeat is the answer we asked for: nothing was below"
        );
    }

    #[test]
    fn an_empty_round_completes_without_a_confirming_step() {
        // The common case, and the reason the confirming step does not cost a
        // page on every quiet wake: a relay that served ZERO events clamped
        // nothing, so there is no ambiguity to resolve and nothing to ask.
        let quiet = summarize_round(
            &[answered("wss://quiet", Vec::new())],
            &ChaseState::default(),
            false,
        );
        assert!(!quiet.repeat_page);
        assert_eq!(
            chasing_pager().step(
                quiet.boundary_secs,
                quiet.repeat_page,
                quiet.read_incomplete,
                false
            ),
            PageStep::Complete,
        );
    }

    #[test]
    fn a_confirming_step_is_never_taken_outside_the_band_or_the_budget() {
        // Same confinement as every other request this chase issues. Below our
        // own REQ floor there is nothing a clamp could be hiding, so the window
        // is complete rather than held — holding would repeat identically on
        // every later sweep, which is a permanent freeze and not a re-fetch.
        let at_the_floor = Pager {
            until_secs: chasing_pager().since_secs,
            ..chasing_pager()
        };
        assert_eq!(
            at_the_floor.step(None, true, false, false),
            PageStep::Complete,
        );

        // And a chase with nothing left to spend cannot ask, so it must not
        // claim: the window holds and the next sweep resumes at the floor this
        // leaves behind.
        for spent in [
            Pager {
                pages: CATCHUP_MAX_PAGES_PER_CIRCLE,
                ..chasing_pager()
            },
            Pager {
                collected: CATCHUP_MAX_EVENTS_PER_CIRCLE,
                ..chasing_pager()
            },
        ] {
            assert_eq!(spent.step(None, true, false, false), PageStep::Halt);
        }
        assert_eq!(
            chasing_pager().step(None, true, false, true),
            PageStep::Halt,
            "and the same when the wake budget ran out mid-question"
        );
    }

    #[test]
    fn a_full_page_of_already_seen_events_still_keeps_the_chase_alive() {
        // The complement that stops "nothing new ⇒ drained" from becoming the
        // whole rule. A relay holding more than one page inside a SINGLE second
        // answers the same full page forever: nothing in it is new, yet events
        // below it exist and no `until` can reach them. Reading that as drained
        // would advance the cursor straight over them.
        let served = page(CATCHUP_MAX_EVENTS_PER_PAGE, 3_000);
        let state = after_serving("wss://a", &served);
        let round = summarize_round(&[answered("wss://a", served)], &state, false);
        assert_eq!(
            round.boundary_secs,
            Some(3_000),
            "a page returned at our own limit was cut at the bottom, and that is \
             true whether or not we have seen its contents before"
        );
    }

    #[test]
    fn a_relay_that_produced_nothing_and_then_speaks_blocks_completeness() {
        // The mirror of `a_chase_that_produced_nothing_blocks_completeness`, and
        // it needs no attacker: one relay slow to answer the OPENING page is
        // enough. Every later page is bounded above by the previous boundary, so
        // whatever that relay holds above it was requested of nobody — and its
        // narrow answer must not be able to help call the window complete.
        let state = ChaseState {
            silent: std::iter::once("wss://late".to_string()).collect(),
            ..ChaseState::default()
        };
        let round = summarize_round(&[answered("wss://late", page(2, 3_000))], &state, false);
        assert!(round.read_incomplete);
        assert_eq!(
            chasing_pager().step(
                round.boundary_secs,
                round.repeat_page,
                round.read_incomplete,
                false
            ),
            PageStep::Halt,
        );

        // The complement, which is the difference between a conservative hold
        // and a self-inflicted outage: a relay that is simply unreachable stays
        // silent all the way through and must never freeze the circle.
        let still_silent = summarize_round(
            &[RelayFetchOutcome {
                relay_url: "wss://late".to_string(),
                responded: false,
                drained: false,
                events: Vec::new(),
            }],
            &state,
            false,
        );
        assert!(!still_silent.read_incomplete);
    }

    #[test]
    fn a_page_nobody_finished_delivering_blocks_completeness() {
        // THE SILENT-LOSS PATH this rule exists to close. A delivery cut off
        // part-way — by the fetch timeout, a dropped socket, a `CLOSED`, the
        // intake cap — hands back a SHORTER page and nothing else: its content
        // is byte-for-byte a complete short answer, and the pool's collection
        // returns `Ok` either way. Read as "this relay is drained", it advances
        // the cursor over everything the relay had not sent yet, permanently.
        //
        // The two rounds below differ in exactly one bit: whether the relay said
        // it was finished. That bit is the whole invariant.
        let served = page(3, 3_000);
        let finished = summarize_round(
            &[answered("wss://slow", served.clone())],
            &ChaseState::default(),
            false,
        );
        assert!(
            !finished.read_incomplete,
            "precondition: a relay that signalled end-of-stored-events IS \
             trustworthy, or the rule below would just be 'never complete a \
             window'"
        );

        let cut = summarize_round(
            &[cut_off("wss://slow", served)],
            &ChaseState::default(),
            false,
        );
        assert!(cut.read_incomplete);
        assert_eq!(
            chasing_pager().step(
                cut.boundary_secs,
                cut.repeat_page,
                cut.read_incomplete,
                false
            ),
            PageStep::Halt,
            "and it halts even though the page looks like an ordinary short one: \
             that is precisely the page that cannot be told from a complete \
             answer by its contents"
        );
    }

    #[test]
    fn a_tolerated_cut_off_relay_is_treated_as_unreached_too() {
        // The escape from a hold with no end (`CATCHUP_MAX_CUTOFF_HOLDS`). Once
        // spent, a relay whose delivery was cut off must land on exactly the
        // side of the line the relay above it sits on: it condemns nothing, it
        // vouches for nothing, and it steers nothing. Anything less than all
        // three leaves it able to hold the circle anyway — through the chase
        // instead of through the round.
        let served = page(3, 3_000);
        let strict = summarize_round(
            &[cut_off("wss://slow", served.clone())],
            &ChaseState::default(),
            false,
        );
        assert!(
            strict.read_incomplete,
            "precondition: this is the round that holds a circle when the \
             tolerance has NOT been spent"
        );

        let tolerated = summarize_round(
            &[cut_off("wss://slow", served)],
            &ChaseState::default(),
            true,
        );
        assert!(
            !tolerated.read_incomplete,
            "it no longer condemns the round"
        );
        assert!(
            !tolerated.any_drained,
            "and it still cannot answer FOR the window: tolerating a read is \
             not believing it finished"
        );
        assert_eq!(
            tolerated.boundary_secs, None,
            "nor propose where the next page goes — a page we could not read to \
             the end says nothing about where its bottom is"
        );
        assert!(
            tolerated.chasing.is_empty(),
            "nor be held to answering one, which would hold the circle again on \
             the very next round"
        );
        assert_eq!(
            tolerated.cut_off,
            vec!["wss://slow".to_string()],
            "and it is named, so the chase stops spending a fetch timeout on it \
             once per page"
        );
    }

    #[test]
    fn a_relay_that_finished_nothing_and_served_nothing_is_treated_as_unreached() {
        // The other half of the same bit, and the one that must NOT halt. A
        // relay whose REQ died before a single event arrived has told us neither
        // that it holds something nor that it holds nothing — the epistemic
        // position of a relay we never got a socket to, which
        // `cursor_advance_ms` deliberately lets a window advance past.
        //
        // Halting here instead would cap every sweep of a circle at its first
        // page for as long as ONE relay in the list stayed broken, so a real
        // backlog could never drain: forward progress traded for nothing, since
        // a relay that served nothing has nothing for the chase to lose.
        let stalled = cut_off("wss://stalled", Vec::new());
        let round = summarize_round(
            std::slice::from_ref(&stalled),
            &ChaseState::default(),
            false,
        );
        assert!(!round.read_incomplete);
        assert_eq!(
            chasing_pager().step(
                round.boundary_secs,
                round.repeat_page,
                round.read_incomplete,
                false
            ),
            PageStep::Complete,
            "the chase over the OTHER relays must be allowed to finish"
        );

        // But it is not an ANSWER either, so on its own it cannot license the
        // advance — `cursor_advance_ms`'s second gate catches the case where it
        // is the only relay, which is the silent loss a bare `responded` flag
        // waved through.
        assert!(!round.any_drained);
        assert_eq!(round.unanswered, 1, "and it is tallied as a relay error");
        assert_eq!(
            cursor_advance_ms(
                FetchWindow {
                    any_relay_drained: round.any_drained,
                    ..healthy()
                },
                &[],
                NOW
            ),
            None,
        );
    }

    #[test]
    fn the_boundary_is_the_maximum_across_truncating_relays() {
        // THE ATTACK backward paging could otherwise have introduced: a relay
        // that pads its full page with a forged ANCIENT event proposes an
        // ancient `until`, at which the next page legitimately comes back short
        // — so a minimum (or any single relay's value) would declare the window
        // complete and advance the cursor past the backlog the OTHER relays are
        // still visibly holding. `summarize_round` carries the full argument.
        let poisoned = answered("wss://poisoned", page(CATCHUP_MAX_EVENTS_PER_PAGE, 1));
        let honest = answered("wss://honest", page(CATCHUP_MAX_EVENTS_PER_PAGE, 4_000));
        let round = summarize_round(&[poisoned, honest], &ChaseState::default(), false);
        assert_eq!(
            round.boundary_secs,
            Some(4_000),
            "the ancient boundary must not win; the next page has to cover the \
             honest relay's unretrieved tail"
        );
        assert_eq!(
            round.chasing.len(),
            2,
            "both relays are still being drained"
        );
    }

    #[test]
    fn an_unanswered_relay_is_tallied_and_only_breaks_a_chase_it_was_part_of() {
        let dead = RelayFetchOutcome {
            relay_url: "wss://dead".to_string(),
            responded: false,
            drained: false,
            events: Vec::new(),
        };
        let fresh = summarize_round(std::slice::from_ref(&dead), &ChaseState::default(), false);
        assert_eq!(fresh.unanswered, 1);
        assert!(
            !fresh.read_incomplete,
            "a relay that never contributed a page is not being drained, so its \
             silence must not freeze the circle's cursor — that is the \
             permanently-dead-relay-URL outage `cursor_advance_ms` refuses to \
             cause"
        );

        let mid_chase = ChaseState {
            chasing: std::iter::once("wss://dead".to_string()).collect(),
            ..ChaseState::default()
        };
        assert!(
            summarize_round(std::slice::from_ref(&dead), &mid_chase, false).read_incomplete,
            "but the relay we were mid-chase with going dark is a known-missing \
             tail"
        );

        // And it must not join the SILENT set either, so the round after it can
        // still complete the window: a relay we never got a socket to has
        // contradicted nothing by speaking later. Composed exactly as the loop
        // composes it — this round's `silent` becomes the next round's state.
        let after_the_miss = ChaseState {
            silent: fresh.silent,
            ..ChaseState::default()
        };
        assert!(
            !summarize_round(
                &[answered("wss://dead", page(2, 3_000))],
                &after_the_miss,
                false
            )
            .read_incomplete,
            "otherwise one cold connect on page 1 — the ordinary shape of a \
             background wake, which builds a fresh relay pool every time —  \
             would freeze this circle's cursor on every wake"
        );
    }

    #[test]
    fn an_empty_page_from_a_chased_relay_is_a_failed_read_not_an_empty_range() {
        // A relay that contributed to the previous round still holds the event
        // AT its own bottom, and this round's `until` is inclusive and at or
        // above it, so an empty page from it is impossible unless the READ
        // failed — or the relay is contradicting itself.
        //
        // Staged as a relay that FINISHED answering with nothing, so this
        // isolates the chase rule from the end-of-stored-events rule beside it:
        // even a relay's own "that is everything I have" cannot settle a range
        // the previous round proved it holds something in.
        //
        // Reading that as "drained" is the silent drop this whole module exists
        // to prevent, and it needs no attacker: one slow radio on a background
        // wake, and the cursor advances over a tail we have local PROOF exists,
        // permanently (the next sweep's floor is only 60 s below the cursor).
        let stalled = answered("wss://stalled", Vec::new());
        let mid_chase = ChaseState {
            chasing: std::iter::once("wss://stalled".to_string()).collect(),
            ..ChaseState::default()
        };
        let round = summarize_round(std::slice::from_ref(&stalled), &mid_chase, false);
        assert!(round.read_incomplete);
        assert_eq!(
            round.boundary_secs, None,
            "precondition: an empty page contributes nothing, so without the \
             rule above this round would read as COMPLETE"
        );
        assert_eq!(
            chasing_pager().step(
                round.boundary_secs,
                round.repeat_page,
                round.read_incomplete,
                false
            ),
            PageStep::Halt,
            "and the pager must hold the window rather than call it complete"
        );

        // The complement, so the rule cannot quietly become "any empty page
        // halts": a relay nobody was chasing has simply nothing to give, which
        // is the ordinary shape of a quiet circle and must still advance.
        let quiet = answered("wss://quiet", Vec::new());
        let quiet_round =
            summarize_round(std::slice::from_ref(&quiet), &ChaseState::default(), false);
        assert!(!quiet_round.read_incomplete);
        assert!(
            quiet_round.any_drained,
            "and it IS an answer — 'I hold nothing in this range' is exactly \
             what an end-of-stored-events over an empty page says"
        );
    }

    // ---- The clamp: no window may push the cursor past the local clock.

    #[test]
    fn a_future_window_open_time_clamps_to_now() {
        // `ceiling_secs` is read before the fetch and `now_secs` after it, so
        // they normally satisfy opened <= now. A clock stepped BACKWARDS during
        // a long sweep inverts that; the cursor must still never land in the
        // future, where `since_for_stream` pins every REQ floor at `now` for the
        // duration of the skew.
        let now = 1_000_i64;
        let ahead = FetchWindow {
            ceiling_secs: now + 900,
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
            &plane_until(&relay_mgr, std::time::Instant::now()),
            &GroupId::new(ngid),
            ngid,
            std::slice::from_ref(&url),
            None,
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

    /// What a circle owes by id is asked for the moment a batch says its
    /// epoch has moved, BEFORE that circle is advanced again: after an
    /// ingest, ahead of the drain that ingest leaves owing, and inside the
    /// drain, after each advance's batch and so ahead of the next round. An
    /// advance made first may settle the circle past an event the new epoch
    /// could have opened — a member's leave, overtaken by the commit that
    /// evicts them.
    #[test]
    fn the_sweep_asks_for_what_a_circle_owes_before_it_advances_it_past_a_new_epoch() {
        let source = include_str!("catchup.rs");
        let production = &source[..source.find("#[cfg(test)]\nmod tests").expect("the tests")];
        let body = |name: &str| {
            let from = production
                .find(&format!("async fn {name}("))
                .unwrap_or_else(|| panic!("fn {name} exists"));
            let rest = &production[from..];
            let to = rest[1..]
                .find("\nasync fn ")
                .map_or(rest.len(), |next| next + 1);
            rest[..to].split_whitespace().collect::<String>()
        };
        let asks = "refetch_at_a_new_epoch(circle_mgr,plane,";
        let judged = body("ingest_judged");
        assert!(
            judged
                .find(&format!("{asks}&ingest.effects.events).await;"))
                .zip(judged.find("drain_convergence("))
                .is_some_and(|(asked, drained)| asked < drained),
            "an ingest that moved its circle's epoch drains it before asking for what it owes",
        );
        let drain = body("drain_convergence");
        let round = drain.find("forgidin&pending{").expect("the round's loop");
        let next = drain.find("next_receive_retick(").expect("the retick");
        assert!(
            drain[round..next].contains(&format!("{asks}&more.events).await;")),
            "an advance that moved its circle's epoch is followed by the next round before \
             what the circle owes is asked for",
        );
        assert_eq!(
            production.matches("refetch_at_a_new_epoch(").count(),
            3,
            "the refetch at a new epoch is asked for somewhere other than the sweep's ingest \
             and its drain",
        );
    }

    /// The NIP-40 `expiration` tag is not a validity signal (Marmot
    /// `transports/nostr.md:190-192`), so an already-expired event gets exactly
    /// the engine verdict the same event without the tag gets — never Haven's
    /// pre-authentication `NoEvidence`.
    #[tokio::test]
    async fn ingest_one_gives_an_expired_445_the_verdict_an_unexpired_one_gets() {
        let h = hex::encode([0x8Au8; 32]);
        let mut verdicts = Vec::new();
        for expired in [true, false] {
            let dir = TempDir::new().unwrap();
            let mgr = CircleManager::new_unencrypted(dir.path(), &Keys::generate()).unwrap();
            let event = unauthenticated_445(&h, expired);
            let relays = RelayManager::new();
            verdicts.push(ingest_one(&mgr, &plane(&relays), &event).await);
        }
        assert_ne!(verdicts[0], ReceiveOnlyOutcome::NoEvidence);
        assert_eq!(
            verdicts[0], verdicts[1],
            "the expiration tag must not change what the sweep makes of an event"
        );
    }

    /// A `kind:445` carrying TWO `#h` tags, the first being the circle's. A
    /// conformant relay serves it to a `#h` subscription (or fetch) for either
    /// value, and the pure pre-engine transport parse then refuses it —
    /// "exactly one h tag" — without touching key material.
    fn malformed_445(h: &str) -> nostr::Event {
        EventBuilder::new(Kind::Custom(445), "b3BhcXVl")
            .tags(vec![
                Tag::parse(["h", h]).unwrap(),
                Tag::parse(["h", &hex::encode([0x11u8; 32])]).unwrap(),
            ])
            .sign_with_keys(&Keys::generate())
            .unwrap()
    }

    #[tokio::test]
    async fn ingest_one_reports_no_evidence_for_a_malformed_envelope() {
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let mgr = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();
        let relay_mgr = RelayManager::new();
        let ngid = [0x8Au8; 32];
        let h = hex::encode(ngid);

        let malformed = malformed_445(&h);
        assert!(
            crate::nostr::mls::SessionManager::event_to_transport_message(&malformed).is_err(),
            "precondition: this envelope must really fail the PRE-ENGINE parse"
        );
        assert_eq!(
            ingest_one(&mgr, &plane(&relay_mgr), &malformed).await,
            ReceiveOnlyOutcome::NoEvidence,
            "an unparseable envelope was screened before authentication, so it \
             must contribute no cursor evidence — reporting `Deferred` would sell \
             an attacker a permanent stall for one minted event"
        );
    }

    #[tokio::test]
    async fn ingest_one_does_not_report_no_evidence_for_engine_verdicts() {
        // Anti-vacuity: an unauthenticated but PARSEABLE event reaches the
        // engine, so whatever comes back is an engine verdict — never
        // `NoEvidence`. Without this, the malformed-envelope gate above would
        // pass just as well if `ingest_one` returned `NoEvidence`
        // unconditionally.
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let mgr = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();
        let relay_mgr = RelayManager::new();
        let ngid = [0x8Au8; 32];
        let h = hex::encode(ngid);

        let unexpired = unauthenticated_445(&h, false);
        assert_ne!(
            ingest_one(&mgr, &plane(&relay_mgr), &unexpired).await,
            ReceiveOnlyOutcome::NoEvidence,
            "only Haven's own pre-auth screen may produce `NoEvidence`"
        );
    }

    // ── Member-directory wiring (picker plan §5.5) ───────────────────────────
    //
    // `ingest_one` is the OTHER production write site the plan's corrected §5.5
    // list names — the WorkManager background-isolate counterpart to
    // `live_sync::processor::EngineProcessor::process_group_event`, "the same
    // shape in the WorkManager isolate". These drive the REAL wiring: a real
    // MLS circle, a real inbound commit or location message, fed through
    // `ingest_one` itself, read back from the real SQLCipher directory table —
    // never a mock of `reconcile_member_directory_best_effort`.

    use crate::circle::{CircleConfig, DirectoryReconcile, DirectoryTier, MemberKeyPackage};
    use crate::location::LocationMessage;
    use crate::nostr::mls::types::GroupId;
    use crate::nostr::mls::SessionManager;
    use crate::relay::maintenance::build_kp_maintenance_events;
    use nostr::Event;

    /// See `live_sync::processor::tests::DIR_READ_AT` for why this is a fixed
    /// far-past constant rather than a real clock reading.
    const DIR_READ_AT: i64 = 20_000 * 86_400;

    async fn make_kp_event(manager: &CircleManager, keys: &Keys, relays: &[String]) -> Event {
        build_kp_maintenance_events(manager.session(), keys, relays, None, None)
            .await
            .expect("build key package event")
            .event
    }

    /// A freshly generated identity's `KeyPackage`, ready to be added to a
    /// circle. The throwaway session behind it is dropped after minting.
    async fn make_member_with_relays(relays: Vec<String>) -> MemberKeyPackage {
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let member = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();
        let event = make_kp_event(&member, &keys, &relays).await;
        MemberKeyPackage {
            key_package_event: event,
            inbox_relays: relays,
            nip65_relays: vec![],
            nip65_write_relays: vec![],
        }
    }

    /// A real two-party MLS circle (Alice admin, Bob member), converged: Alice
    /// creates and confirms, Bob holds and accepts the engine-produced welcome.
    struct AliceBob {
        alice: CircleManager,
        _alice_dir: TempDir,
        alice_keys: Keys,
        bob: CircleManager,
        _bob_dir: TempDir,
        mls_group_id: GroupId,
        relays: Vec<String>,
    }

    async fn setup_alice_bob() -> AliceBob {
        let relays = vec!["wss://relay.test.com".to_string()];

        let alice_dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap();

        let bob_dir = TempDir::new().unwrap();
        let bob_keys = Keys::generate();
        let bob = CircleManager::new_unencrypted(bob_dir.path(), &bob_keys).unwrap();

        let bob_kp_event = make_kp_event(&bob, &bob_keys, &relays).await;
        let bob_member = MemberKeyPackage {
            key_package_event: bob_kp_event,
            inbox_relays: relays.clone(),
            nip65_relays: vec![],
            nip65_write_relays: vec![],
        };

        let config = CircleConfig::new("Test Circle").with_relays(relays.clone());
        let creation = alice
            .create_circle(&alice_keys, vec![bob_member], &config)
            .await
            .expect("create two-party circle");

        let mls_group_id = creation.circle.mls_group_id.clone();

        let welcome = creation.welcome_events.first().expect("one welcome");
        bob.process_gift_wrapped_invitation(&bob_keys, &welcome.event)
            .await
            .expect("bob holds welcome");
        bob.accept_invitation(&welcome.event.id)
            .await
            .expect("bob accepts welcome");

        AliceBob {
            alice,
            _alice_dir: alice_dir,
            alice_keys,
            bob,
            _bob_dir: bob_dir,
            mls_group_id,
            relays,
        }
    }

    /// The drain waits out no deadline past the sweep's own. A commit that
    /// arrives is buffered until its convergence pass closes, a second or so
    /// later: a drain whose sweep is out of time makes its first advance —
    /// which costs no wait — and stops there, owing the circle to the next
    /// plane that drains. The same drain with time left waits the pass out,
    /// applies it, and leaves the circle owing nothing.
    #[tokio::test]
    async fn the_catchup_convergence_drain_stops_at_the_sweep_deadline() {
        let fx = setup_alice_bob().await;
        let relay_mgr = RelayManager::new();
        let commit = fx
            .alice
            .update_relays_for_test(&fx.mls_group_id, &fx.relays)
            .await
            .expect("alice makes a commit");
        let before = fx.bob.group_epoch(&fx.mls_group_id).await.expect("epoch");
        fx.bob
            .session()
            .process_event(&commit)
            .await
            .expect("bob's engine takes the commit");
        assert!(
            fx.bob
                .session()
                .receive_retick_after(&fx.mls_group_id)
                .await
                .is_some_and(|wait| !wait.is_zero()),
            "premise: the commit waits for its convergence pass to close",
        );
        let _ = fx.bob.session().take_owed_advance();

        let out_of_time = plane_until(&relay_mgr, std::time::Instant::now());
        drain_convergence(&fx.bob, &out_of_time, vec![fx.mls_group_id.clone()]).await;
        assert_eq!(
            fx.bob.group_epoch(&fx.mls_group_id).await.expect("epoch"),
            before,
            "a drain past its sweep's deadline waited a convergence pass out",
        );
        assert!(
            fx.bob
                .session()
                .take_owed_advance()
                .contains(&fx.mls_group_id),
            "a drain cut short left its circle to nobody",
        );

        drain_convergence(&fx.bob, &plane(&relay_mgr), vec![fx.mls_group_id.clone()]).await;
        assert_eq!(
            fx.bob.group_epoch(&fx.mls_group_id).await.expect("epoch"),
            before + 1,
            "a drain with time left did not apply the commit",
        );
        assert!(
            !fx.bob.session().still_owes_advance(&fx.mls_group_id).await,
            "a drain with time left left its circle owing work",
        );
    }

    #[tokio::test]
    async fn a_receive_advance_never_releases_a_queued_user_intent() {
        // The catch-up plane's two advance edges — the per-circle open advance
        // (`drain_convergence`) and the advance after an ingested input
        // (`ingest_one`) — must leave the user's queued change queued; see the
        // live plane's twin in `live_sync::processor`.
        let fx = setup_alice_bob().await;
        let relay_mgr = RelayManager::new();
        let bob_key: [u8; 32] = fx
            .bob
            .session()
            .self_id()
            .await
            .as_slice()
            .try_into()
            .expect("32-byte member id");
        let payload = SessionManager::admin_policy_payload_for_test(&[
            fx.alice_keys.public_key().to_bytes(),
            bob_key,
        ])
        .expect("payload");
        fx.alice
            .session()
            .queue_admin_policy_intent_for_test(&fx.mls_group_id, payload)
            .await
            .expect("queue the intent");
        let still_queued = || async {
            fx.alice
                .session()
                .queued_admin_policy_payloads_for_test(&fx.mls_group_id)
                .await
                .expect("read the queue")
                .len()
                == 1
                && matches!(
                    fx.alice.session().epoch_state(&fx.mls_group_id).await,
                    Some(crate::nostr::mls::types::EpochState::Stable { .. })
                )
        };

        drain_convergence(&fx.alice, &plane(&relay_mgr), vec![fx.mls_group_id.clone()]).await;
        assert!(
            still_queued().await,
            "the open advance must neither release nor stage the queued change"
        );

        let leave = fx
            .bob
            .propose_leave(&fx.mls_group_id)
            .await
            .expect("bob proposes leave")
            .expect("a first leave in this epoch proposes");
        ingest_one(&fx.alice, &plane(&relay_mgr), &leave).await;
        assert!(
            still_queued().await,
            "the ingest advance must neither release nor stage the queued change"
        );
    }

    #[tokio::test]
    async fn a_real_inbound_add_commit_drained_through_ingest_one_writes_a_directory_row() {
        // The catch-up counterpart of
        // `live_sync::processor::tests::a_real_inbound_add_commit_drained_through_process_group_event_writes_a_directory_row`.
        // Isolated the same way: Carol's pubkey never reaches Bob except
        // through this call.
        let fx = setup_alice_bob().await;
        let relay_mgr = RelayManager::new();
        let carol = make_member_with_relays(fx.relays.clone()).await;
        let carol_hex = carol.key_package_event.pubkey.to_hex();

        let before = fx
            .bob
            .ranked_directory_members(DIR_READ_AT)
            .expect("directory read");
        assert!(
            !before.iter().any(|e| e.pubkey_hex == carol_hex),
            "precondition: Carol is nobody to Bob yet"
        );

        let add = fx
            .alice
            .add_members_for_test(&fx.mls_group_id, &[carol])
            .await
            .expect("alice adds carol");

        let outcome = ingest_one(&fx.bob, &plane(&relay_mgr), &add.0).await;
        assert_eq!(
            outcome,
            ReceiveOnlyOutcome::Applied,
            "sanity: the commit really applied — a failure here would make the \
             absence check below meaningless"
        );

        let after = fx
            .bob
            .ranked_directory_members(DIR_READ_AT)
            .expect("directory read");
        let carol_row = after.iter().find(|e| e.pubkey_hex == carol_hex).expect(
            "ingest_one must reconcile the directory after a real inbound \
             commit — deleting that call, or making it a no-op, must fail this \
             assertion",
        );
        assert_eq!(carol_row.tier, DirectoryTier::Current);
    }

    #[tokio::test]
    async fn a_batch_of_only_location_messages_through_ingest_one_triggers_no_reconcile() {
        // The catch-up counterpart of
        // `live_sync::processor::tests::a_batch_of_only_location_messages_triggers_no_reconcile_at_all`
        // — see that test for why the oracle is a fixed far-past
        // `last_shared_day` stamp rather than a byte-diff of the row right
        // after setup.
        const FAR_PAST_DAY_SECS: i64 = 20_000 * 86_400; // 2024-10-04.

        let fx = setup_alice_bob().await;
        let relay_mgr = RelayManager::new();
        let alice_hex = fx.alice_keys.public_key().to_hex();

        assert!(
            fx.bob
                .reconcile_member_directory(DirectoryReconcile::Rewrite, FAR_PAST_DAY_SECS)
                .await
                .expect("reconcile"),
            "precondition: bob's converged roster is readable"
        );
        let before = fx
            .bob
            .ranked_directory_members(DIR_READ_AT)
            .expect("directory read");
        let before_row = before
            .iter()
            .find(|e| e.pubkey_hex == alice_hex)
            .cloned()
            .expect("precondition: alice is bob's co-member");
        assert_eq!(
            before_row.last_shared_day,
            FAR_PAST_DAY_SECS / 86_400,
            "precondition: the forced stamp really landed"
        );

        let loc = LocationMessage::new(3.0, 4.0);
        let (event, _ngid, _relays) = fx
            .alice
            .seal_location_for_test(&fx.mls_group_id, &loc)
            .await
            .expect("alice encrypts");

        let outcome = ingest_one(&fx.bob, &plane(&relay_mgr), &event).await;
        assert_eq!(
            outcome,
            ReceiveOnlyOutcome::Applied,
            "sanity: the location really applied — a failure here would make \
             the row-unchanged assertion below meaningless"
        );

        let after = fx
            .bob
            .ranked_directory_members(DIR_READ_AT)
            .expect("directory read");
        let after_row = after
            .iter()
            .find(|e| e.pubkey_hex == alice_hex)
            .cloned()
            .expect("alice's row must still exist");
        assert_eq!(
            after_row, before_row,
            "a location-only batch must never touch the directory row — any \
             difference here (including a bumped last_shared_day) means a \
             reconcile ran where the plan says one must not"
        );
    }
}
