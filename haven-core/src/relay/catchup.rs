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
//! (`saturated`) and at least one of the circle's relays answered. Anything the
//! sweep could not APPLY — an engine `Buffered`, a hard ingest failure, or an
//! event the deadline stopped us reaching — holds the advance at or below that
//! event so it is re-fetched next sweep.
//!
//! # Backward paging
//!
//! A truncated page is not the end of a window: the sweep re-issues the request
//! bounded above by the oldest event it has been served ([`Pager`]) until every
//! responding relay hands back a short page, so a saturated window can actually
//! COMPLETE instead of freezing its circle's cursor forever. That next `until`
//! is the one remotely-written number steering a request; [`summarize_round`]
//! argues where it may come from and [`Pager::step`] argues how far it may be
//! followed. Everything neither can establish from a local fact leaves the
//! window marked `saturated` and the cursor held.
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
    /// an expired NIP-40 replay, or an envelope the pure pre-engine transport
    /// parse could not read at all.
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
    /// authentication ran: expired NIP-40 replays, and envelopes the pure
    /// pre-engine transport parse could not read (forged or genuine). Neither
    /// applied nor deferred: they contribute no cursor evidence at all. A
    /// persistently non-zero count on a healthy circle means some relay is
    /// serving events past their advertised TTL, or something on the wire is
    /// emitting `kind:445`s Haven cannot parse.
    pub events_rejected_pre_auth: usize,
    /// Per-circle group cursors advanced.
    pub cursors_advanced: usize,
    /// The deadline was reached before every bucket was swept.
    pub deadline_hit: bool,
    /// Relay fetches that returned no response / errored (tallied, never fatal).
    pub relay_errors: usize,
    /// Circles whose fetch window could NOT be completed. Some relay truncated
    /// a page (returned the full `CATCHUP_MAX_EVENTS_PER_PAGE`) and the backward
    /// pager did not finish draining the tail below it — it ran out of pages,
    /// of the per-circle event budget, of deadline, or of a relay willing to
    /// answer. The cursor was deliberately NOT advanced for those circles, so
    /// the remainder is re-fetched next sweep. Non-zero means "this circle still
    /// has unretrieved backlog", not an error.
    pub windows_truncated: usize,
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
/// unfinished. Ingest then runs over everything the chase fetched — once, over
/// the sorted union, after the last page — so the engine still makes progress on
/// a window that stayed incomplete.
///
/// # This value MUST NOT exceed a relay's own `limit` cap
///
/// Truncation is detected as "the relay returned as many events as we asked
/// for". NIP-11 `limitation.max_limit` lets a relay CLAMP a larger `limit`
/// instead of rejecting it, and strfry — which all three of Haven's default
/// relays run, and which the E2E harness runs too — ships that cap at 500. Ask
/// for more than a relay will serve and every page comes back one short of our
/// own limit no matter how much backlog is left, so the signal never fires, the
/// chase never starts, and the cursor advances straight over the tail: the exact
/// silent loss above, arrived at through the request rather than the response.
/// 500 is therefore not a round number, it is the ecosystem's de-facto cap; a
/// relay capping BELOW it would still defeat the signal, which is the residual
/// this constant cannot fix on its own.
const CATCHUP_MAX_EVENTS_PER_PAGE: usize = 500;

/// Max backward pages one circle's window may cost in a single sweep.
///
/// Paging is what removed the per-page limit's second job (bounding the SWEEP,
/// not just one response), so the Rule-12 backpressure moved here: a relay that
/// answers every page in full cannot make one circle unbounded in requests, in
/// time, or in events held. Hitting this bound leaves the window marked
/// INCOMPLETE, so the cursor holds and nothing is silently treated as caught up.
///
/// # What hitting it does NOT do, and the residual that leaves
///
/// It does not schedule the remainder for later. Every sweep restarts the chase
/// at the newest end of the same `since`, so a window that stays above
/// `CATCHUP_MAX_PAGES_PER_CIRCLE × CATCHUP_MAX_EVENTS_PER_PAGE` events retrieves
/// the same newest ~4000 forever and its oldest tail is fetched by no sweep at
/// all. Nothing is DROPPED — the cursor never advances over it, so it stays
/// reachable — but it is also never reached. Resuming the descent across sweeps
/// needs a persisted per-circle backfill floor, which is a new piece of
/// remotely-influenced state to make safe (the boundary it would store is a
/// relay-chosen timestamp) and is deliberately a follow-up. In practice the
/// residual is narrow: kind-445 APPLICATION messages carry a NIP-40 expiration
/// of ~4 minutes so they age off relays long before they pile up, and the
/// commits/proposals that do persist are rare.
///
/// # And the wake-budget consequence, which is real
///
/// A wake budget is 20–25 s while one page's fetch is bounded by the relay
/// timeout, so the DEADLINE, not this constant, is what usually stops a long
/// chase. One badly backlogged circle can now spend the whole wake where it
/// previously cost a single round, after which `run_catchup_all_circles` breaks
/// before the remaining circles are swept at all — they simply wait for the next
/// wake, cursors untouched. Worse for that circle: the chase fetches every page
/// BEFORE any ingest, so a deadline landing mid-chase applies nothing at all and
/// classifies the whole union as deferred. Ingesting per page would trade that
/// for a smaller fetch batch and is the obvious follow-up; it is not built here
/// because it changes what a partially-swept window means to the engine.
const CATCHUP_MAX_PAGES_PER_CIRCLE: usize = 8;

/// Max unique events one circle's paged window may accumulate in a single sweep.
///
/// The page bound alone does not bound memory: every page is put to EVERY relay
/// in the circle's list, so a round costs `CATCHUP_MAX_EVENTS_PER_PAGE` × a
/// user-configurable relay count. Deliberately equal to a full single-relay
/// chase (pages × page size) so it only ever binds on a multi-relay circle.
///
/// It is a ceiling on the ACCUMULATED union, checked once a whole round has been
/// appended, so the true resident worst case is this plus one round —
/// `CATCHUP_MAX_EVENTS_PER_CIRCLE + relays.len() × CATCHUP_MAX_EVENTS_PER_PAGE`.
/// That extra round is not avoidable by checking earlier: the fetch fans out to
/// every relay concurrently, so its events are already resident inside
/// `fetch_events_per_relay`'s return value before this code can look at them.
/// Same honesty rule as above: reaching the ceiling marks the window incomplete.
const CATCHUP_MAX_EVENTS_PER_CIRCLE: usize =
    CATCHUP_MAX_PAGES_PER_CIRCLE * CATCHUP_MAX_EVENTS_PER_PAGE;

use std::collections::HashSet;
use std::time::{Duration, Instant};

use nostr::{Event, EventId, PublicKey, Timestamp};

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
    /// LOCAL wall-clock reading taken BEFORE this circle's FIRST REQ was issued
    /// — one anchor for the whole page chain. The advance target. Not writable
    /// by any remote party.
    pub opened_at_secs: i64,
    /// Some relay truncated a page and [`Pager`] did not finish retrieving the
    /// tail below it, so the window is INCOMPLETE (Security Rule 12).
    pub saturated: bool,
    /// At least one of the circle's relays answered. With none, the window is
    /// empty for a reason that says nothing about the circle's traffic.
    pub any_relay_responded: bool,
}

/// What the sweep does after one round of per-relay pages.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PageStep {
    /// Every responding relay handed back a SHORT page, so nothing is left
    /// below what we hold: the window is complete down to its own `since` and
    /// the cursor may advance.
    Complete,
    /// Issue one more page, bounded above by this `until` (unix seconds).
    Next(i64),
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
    /// Ceiling of the range still to retrieve. Starts at the window's own open
    /// time and must strictly DESCEND with every page.
    bound_secs: i64,
    /// Pages already issued for this circle in this sweep.
    pages: usize,
    /// Unique events collected across those pages.
    collected: usize,
}

impl Pager {
    /// Decides the next move after one round of per-relay pages.
    ///
    /// `boundary_secs` is [`RoundSummary::boundary_secs`]: the oldest
    /// `created_at` served by a relay that TRUNCATED, maximised across such
    /// relays, or `None` when no responding relay truncated. `chase_lost` is
    /// [`RoundSummary::chase_lost`]: a relay we were still draining produced
    /// nothing this round.
    ///
    /// # The termination rule, and the attack it is written against
    ///
    /// Exactly ONE exit reports a complete window: a round with no `chase_lost`
    /// in which no responding relay truncated. "Truncated" is
    /// `page.len() >= CATCHUP_MAX_EVENTS_PER_PAGE` — a LOCAL count of how many
    /// events came back, a fact about the FETCH in the same sense
    /// [`cursor_advance_ms`]'s two gates are, never a claim read out of an
    /// event's contents. Every other path through this function returns
    /// [`PageStep::Halt`], which leaves the window `saturated` and the cursor
    /// held. (Being merely LATE is not one of them: `out_of_time` is read only
    /// once a relay has actually truncated, because a deadline that expires over
    /// a window nobody truncated has not made that window incomplete.)
    ///
    /// The next page's `until` is, unavoidably, a remote number: the oldest
    /// `created_at` in a page the relay itself cut short. A relay that forges an
    /// ANCIENT bottom gets the next page requested at that ancient `until`,
    /// which then legitimately comes back short — so a bare "short page ⇒
    /// complete" would let it declare a window complete while withholding
    /// everything in between. Two properties contain that:
    ///
    /// * **The boundary is the MAXIMUM across truncating relays**, so the chain
    ///   descends only as fast as the slowest-draining relay allows and one
    ///   poisoned entry in a circle's relay list cannot curtail the paging of
    ///   the others — see [`summarize_round`], which carries that argument.
    /// * **The remote number is CONFINED to a locally chosen band.** It is
    ///   obeyed only while `since_secs <= boundary < bound_secs`: floored at our
    ///   own REQ floor, ceilinged at the window's own open time, and strictly
    ///   descending — so a relay that repeats one page forever, or dates a full
    ///   page inside a single second, terminates the loop instead of spinning
    ///   it. A value outside the band is not followed; it halts the chase with
    ///   the window incomplete.
    ///
    /// # What "short page" cannot tell us, and the two residuals that leaves
    ///
    /// A short page is a local count, but it is a count of what ARRIVED, which
    /// is not the same as what the relay chose to serve:
    ///
    /// * **A partial read reads as a short page.**
    ///   `RelayPool::fetch_events_from` collects a merged stream and returns
    ///   `Ok(collected)` however that stream ended, per-relay stream errors are
    ///   logged and dropped inside its driver task, and the subscription's whole
    ///   life is wrapped in `time::timeout` — so a fetch that times out
    ///   mid-delivery is byte-for-byte a short page at this layer, and so is a
    ///   post-handshake error (which [`RelayManager::fetch_events_per_relay`]
    ///   turns into an empty page with `responded == true`). No flag derived
    ///   from that call's `Result` could see it: the call returns `Ok`. What IS
    ///   caught is the total-failure half — an empty page from a relay we were
    ///   still draining is proof of a failed read rather than of an empty range,
    ///   because `until` is inclusive and the boundary is at or above that
    ///   relay's own bottom, so it still holds at least the event AT the
    ///   boundary (see [`summarize_round`]). Closing the partial half means
    ///   observing per-relay EOSE, i.e. driving `Relay::stream_events` instead
    ///   of `fetch_events_from` — a change to the shared fetch primitive and
    ///   every one of its callers, and a follow-up rather than part of this.
    /// * **A relay lying about its own ordering** still ends its own chain
    ///   early. That one is not a new exposure: the identical outcome is
    ///   available to it by answering the FIRST page short while holding a
    ///   backlog, i.e. plain withholding, which no receive-side rule can detect
    ///   and which this design already treats as out of scope ("a relay that
    ///   withholds events can already withhold them outright",
    ///   [`cursor_advance_ms`]).
    ///
    /// Everywhere completeness cannot be established the answer is `Halt`: a
    /// conservative hold costs one re-fetch, a wrong advance costs the backlog.
    #[must_use]
    const fn step(
        self,
        boundary_secs: Option<i64>,
        chase_lost: bool,
        out_of_time: bool,
    ) -> PageStep {
        // A relay we were still draining produced nothing. Its tail is KNOWN to
        // exist and we did not get it, so no round can establish completeness
        // this sweep; spending more of the deadline on the other relays' pages
        // would only delay the remaining circles for a window that cannot be
        // finished now anyway.
        if chase_lost {
            return PageStep::Halt;
        }
        let Some(boundary) = boundary_secs else {
            return PageStep::Complete;
        };
        if boundary < self.since_secs
            || boundary >= self.bound_secs
            || self.pages >= CATCHUP_MAX_PAGES_PER_CIRCLE
            || self.collected >= CATCHUP_MAX_EVENTS_PER_CIRCLE
            || out_of_time
        {
            return PageStep::Halt;
        }
        PageStep::Next(boundary)
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
    /// At least one relay answered this round.
    any_responded: bool,
    /// Relays that did not answer (tallied as relay errors, never fatal).
    unanswered: usize,
    /// A relay that truncated the PREVIOUS page produced NOTHING this round —
    /// it either did not answer, or answered with an empty page. Both are
    /// failed reads (see below), and both mean this round cannot establish
    /// completeness.
    chase_lost: bool,
    /// The `until` for the next page: the oldest `created_at` served by a relay
    /// that truncated, MAXIMISED across such relays. `None` means nobody
    /// truncated.
    boundary_secs: Option<i64>,
    /// The relays that truncated this round — the ones still being drained, so
    /// one of them producing nothing next round is a hold rather than a "nobody
    /// truncated, therefore complete".
    chasing: HashSet<String>,
}

/// Summarises one round's per-relay pages, given the relays that truncated the
/// PREVIOUS round.
///
/// # Truncation is per relay, before dedup
///
/// A relay returning exactly the limit is the signal that ITS page was cut at
/// the bottom. Measuring the deduped union instead would mask two relays that
/// each truncate but overlap enough to leave the union under the cap.
///
/// # Why the boundary is the MAXIMUM across truncating relays
///
/// It is the one remotely-written number that steers a request, so which
/// truncating relay it comes from matters. Taking the maximum makes the chain
/// descend only as fast as the SLOWEST-draining relay allows, so a relay that
/// pads its full page with a forged ANCIENT event — proposing an `until` at
/// which the next page legitimately comes back short — cannot curtail the
/// paging of the honest relays beside it. That cross-relay curtailment is the
/// only NEW power backward paging could have granted: forging the bottom of a
/// page is otherwise available only to the relay serving it, and an honest
/// relay's bottom is not attacker-writable at all, since `limit: n` returns ITS
/// newest n by `created_at` and an injected event dated below the cut is simply
/// not in the page.
///
/// # Why an EMPTY page from a chased relay is a failed read, not an empty range
///
/// A relay that truncated the previous page still holds the event AT its own
/// bottom `b`, and this round's request covers it: `until` is inclusive and the
/// boundary is the maximum across truncating relays, hence `>= b`, while
/// `since` has not moved. So that relay MUST return at least one event. Nothing
/// back means we failed to read it —
/// [`RelayManager::fetch_events_per_relay`] reports a post-handshake fetch
/// error as `responded == true` with no events — and reading that as "drained"
/// would advance the cursor over a tail we have local proof exists. (A page
/// emptied instead by a NIP-40 expiry landing between two rounds milliseconds
/// apart resolves the same way: one conservative hold, re-fetched next sweep.)
#[must_use]
fn summarize_round(outcomes: &[RelayFetchOutcome], chasing: &HashSet<String>) -> RoundSummary {
    let mut round = RoundSummary::default();
    for fo in outcomes {
        if fo.responded {
            round.any_responded = true;
        } else {
            round.unanswered += 1;
        }
        round.chase_lost |= fo.events.is_empty() && chasing.contains(&fo.relay_url);
        if fo.events.len() >= CATCHUP_MAX_EVENTS_PER_PAGE {
            round.boundary_secs = round
                .boundary_secs
                .max(fo.events.iter().map(created_secs).min());
            round.chasing.insert(fo.relay_url.clone());
        }
    }
    round
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
///   indistinguishable from a complete window. Only the fetch layer knows. The
///   sweep pages backwards to drain that tail, and this flag survives as
///   "the chase did not finish" (see [`Pager::step`]).
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
    // An `Err` is an ENGINE-side ingest failure (the envelope parsed and the
    // engine took the message), so something at this position is genuinely
    // outstanding and the cursor must stop at it. An envelope that would not
    // parse never reaches here — it comes back as a pre-auth rejection below.
    let Ok(screened) = circle_mgr.session().process_event(ev).await else {
        return ReceiveOnlyOutcome::Deferred;
    };

    let ingest = match screened {
        // Rejected by Haven's local screen BEFORE any MLS authentication (an
        // expired replay, or an envelope that would not parse). Nothing here is
        // verified, so persist nothing, publish nothing, drain nothing — and
        // report `NoEvidence` so the event's unauthenticated `created_at` can
        // neither become this circle's cursor nor hold it back.
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
    let (window, mut events) = fetch_window_paged(
        relay_mgr,
        std::slice::from_ref(&hex),
        relays,
        since_secs,
        window_opened_at_secs,
        deadline,
        out,
    )
    .await;
    if window.saturated {
        out.windows_truncated += 1;
    }
    // Ascending (created_at, id): pages arrive newest-first and out of order
    // relative to each other, and this sort is what makes an early deadline
    // break leave the OLDEST un-ingested events for the hold-back below.
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
            classified.extend(
                events[idx..]
                    .iter()
                    .map(|pending| (created_secs(pending), ReceiveOnlyOutcome::Deferred)),
            );
            out.events_deferred += events.len() - idx;
            break;
        }
        let secs = created_secs(ev);
        let outcome = ingest_one(circle_mgr, relay_mgr, ev, &ngid, own_hex).await;
        match outcome {
            ReceiveOnlyOutcome::Applied => out.events_applied += 1,
            ReceiveOnlyOutcome::Deferred => out.events_deferred += 1,
            ReceiveOnlyOutcome::NoEvidence => out.events_rejected_pre_auth += 1,
        }
        classified.push((secs, outcome));
    }

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

/// Fetches one circle's whole window, paging BACKWARDS past every truncated
/// page until each responding relay hands back a short one.
///
/// Returns the deduped events — UNSORTED, because pages arrive newest-first and
/// the caller sorts the union ascending before ingest — plus the two
/// FETCH-level facts [`cursor_advance_ms`] gates the advance on.
///
/// # One anchor for the whole chain
///
/// Every page shares the caller's single `opened_at_secs` and the same locally
/// derived `since`; the clock is deliberately NOT re-read per page. Later pages
/// go out later in wall-clock time, which can only ADD events a relay did not
/// hold at the anchor instant, never remove one it did — so "everything these
/// relays held at the moment I asked", the claim the anchor encodes, stays true
/// of the union the chain builds.
///
/// # Residual: a relay that joins the chain late
///
/// A relay unreachable for the FIRST page but answering a later one is only ever
/// asked for `[since, boundary]`, so whatever it holds ABOVE that boundary was
/// requested of nobody — yet its short page still counts toward completeness.
/// That is the same coverage assumption [`cursor_advance_ms`] already documents
/// for a circle carrying an unreachable relay ("a relay that withholds events
/// can already withhold them outright"), reached inside one chain rather than
/// across sweeps. Closing it means recording round one's responder set and
/// requiring the completing round's responders to be a subset of it; left as a
/// follow-up because the residual is pre-existing in kind, not new in kind.
#[deny(clippy::wildcard_enum_match_arm)]
async fn fetch_window_paged(
    relay_mgr: &RelayManager,
    group_ids_hex: &[String],
    relays: &[String],
    since_secs: i64,
    opened_at_secs: i64,
    deadline: Instant,
    out: &mut CatchupOutcome,
) -> (FetchWindow, Vec<Event>) {
    let mut window = FetchWindow {
        opened_at_secs,
        saturated: false,
        any_relay_responded: false,
    };
    let mut pager = Pager {
        since_secs,
        bound_secs: opened_at_secs,
        pages: 0,
        collected: 0,
    };
    let mut seen: HashSet<EventId> = HashSet::new();
    let mut events: Vec<Event> = Vec::new();
    let mut chasing: HashSet<String> = HashSet::new();
    // EVERY page is bounded above, the first one by the anchor itself, so the
    // band requested is exactly the `[since, opened_at]` the anchor claims.
    // Leave the first page unbounded and 500 future-dated `kind:445`s — which
    // any observer of the circle's PUBLIC `#h` can mint — fill it, put the
    // boundary at or above the band's ceiling, and halt the chase on arrival: a
    // frozen cursor, bought for one publish and re-bought on every wake. A
    // genuinely future-dated peer event is merely deferred to the next sweep,
    // whose floor sits below it.
    let mut until_secs = opened_at_secs;

    loop {
        let filter = group_filter(group_ids_hex, since_secs)
            .limit(CATCHUP_MAX_EVENTS_PER_PAGE)
            // Widening, never narrowing, in the impossible case: a pre-1970
            // local clock drops the ceiling rather than fabricating an empty
            // page that would read as a completed window. (`Pager::step` floors
            // every boundary at `since_secs`, itself floored at 0.)
            .until(Timestamp::from(
                u64::try_from(until_secs).unwrap_or(u64::MAX),
            ));
        let Ok(fetch_outcomes) = relay_mgr.fetch_events_per_relay(filter, relays).await else {
            // The primitive documents that it never fails as a whole; should
            // that ever change, an unanswered page is an unfinished chase, and
            // an unfinished chase holds the cursor.
            out.relay_errors += 1;
            window.saturated = true;
            return (window, events);
        };
        pager.pages += 1;

        let round = summarize_round(&fetch_outcomes, &chasing);
        window.any_relay_responded |= round.any_responded;
        out.relay_errors += round.unanswered;
        chasing = round.chasing;
        for fo in fetch_outcomes {
            for ev in fo.events {
                if seen.insert(ev.id) {
                    events.push(ev);
                }
            }
        }
        pager.collected = events.len();

        // The deadline bounds the CHASE too, not just the ingest below it: a
        // circle whose relays keep answering in full must not eat the whole
        // wake budget and starve the circles after it.
        let out_of_time = Instant::now() >= deadline;
        match pager.step(round.boundary_secs, round.chase_lost, out_of_time) {
            PageStep::Complete => return (window, events),
            PageStep::Halt => {
                if out_of_time {
                    out.deadline_hit = true;
                }
                window.saturated = true;
                return (window, events);
            }
            PageStep::Next(until) => {
                pager.bound_secs = until;
                until_secs = until;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        cursor_advance_ms, hold_backs, ingest_one, summarize_round, FetchWindow, HashSet, PageStep,
        Pager, ReceiveOnlyOutcome, ReceiveOnlyOutcome as O, RelayFetchOutcome,
        CATCHUP_MAX_EVENTS_PER_CIRCLE, CATCHUP_MAX_EVENTS_PER_PAGE, CATCHUP_MAX_PAGES_PER_CIRCLE,
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
            pages: 1,
            collected: CATCHUP_MAX_EVENTS_PER_PAGE,
        }
    }

    #[test]
    fn a_round_where_nobody_truncated_completes_the_window() {
        // The ONLY exit that may report a complete window, and it is decided by
        // a local count of returned events — never by anything an event says.
        assert_eq!(
            chasing_pager().step(None, false, false),
            PageStep::Complete,
            "every responding relay handed back a short page, so there is \
             nothing left below what we hold"
        );
    }

    #[test]
    fn a_truncated_round_pages_backwards_from_the_boundary() {
        assert_eq!(
            chasing_pager().step(Some(3_000), false, false),
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
                chasing_pager().step(Some(repeated), false, false),
                PageStep::Halt,
                "a boundary of {repeated} does not descend below the band's \
                 ceiling and must not be followed",
            );
        }
    }

    #[test]
    fn a_boundary_below_our_own_since_is_not_followed() {
        // The floor half of the band. A relay serving events below the `since`
        // WE chose is answering something we did not ask; its bottom is not a
        // point in this window, so it steers no request. Halting keeps the
        // window incomplete rather than accepting a claim about a range outside
        // the filter.
        assert_eq!(
            chasing_pager().step(Some(chasing_pager().since_secs - 1), false, false),
            PageStep::Halt,
        );
        assert_eq!(
            chasing_pager().step(Some(chasing_pager().since_secs), false, false),
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
        assert_eq!(exhausted.step(Some(3_000), false, false), PageStep::Halt);
    }

    #[test]
    fn the_per_circle_event_budget_stops_the_chase() {
        // The memory ceiling, which binds before the page budget once a circle
        // has several relays each answering a full page per round.
        let stuffed = Pager {
            collected: CATCHUP_MAX_EVENTS_PER_CIRCLE,
            ..chasing_pager()
        };
        assert_eq!(stuffed.step(Some(3_000), false, false), PageStep::Halt);
    }

    #[test]
    fn the_deadline_stops_the_chase() {
        // The wake budget bounds the CHASE, not just the ingest: one circle
        // whose relays keep answering in full must not starve the circles after
        // it. Still incomplete, never complete.
        assert_eq!(
            chasing_pager().step(Some(3_000), false, true),
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
            chasing_pager().step(None, false, true),
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
            chasing_pager().step(None, true, false),
            PageStep::Halt,
            "a round that lost the relay it was draining proves nothing about \
             that relay's tail"
        );
        assert_eq!(
            chasing_pager().step(Some(3_000), true, false),
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

    fn answered(url: &str, events: Vec<nostr::Event>) -> RelayFetchOutcome {
        RelayFetchOutcome {
            relay_url: url.to_string(),
            responded: true,
            events,
        }
    }

    #[test]
    fn only_a_truncated_page_contributes_a_boundary() {
        // A relay that answered SHORT has handed over everything it holds down
        // to `since`; its oldest event says nothing about where anyone else's
        // tail begins, so it must not steer the next request.
        let round = summarize_round(&[answered("wss://a", page(3, 10))], &HashSet::new());
        assert_eq!(round.boundary_secs, None);
        assert!(round.any_responded);
        assert!(round.chasing.is_empty());
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
        let round = summarize_round(&[poisoned, honest], &HashSet::new());
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
            events: Vec::new(),
        };
        let fresh = summarize_round(std::slice::from_ref(&dead), &HashSet::new());
        assert_eq!(fresh.unanswered, 1);
        assert!(
            !fresh.chase_lost,
            "a relay that never truncated a page is not being drained, so its \
             silence must not freeze the circle's cursor — that is the \
             permanently-dead-relay-URL outage `cursor_advance_ms` refuses to \
             cause"
        );

        let mut chasing = HashSet::new();
        chasing.insert("wss://dead".to_string());
        assert!(
            summarize_round(std::slice::from_ref(&dead), &chasing).chase_lost,
            "but the relay we were mid-chase with going dark is a known-missing \
             tail"
        );
    }

    #[test]
    fn an_empty_page_from_a_chased_relay_is_a_failed_read_not_an_empty_range() {
        // A relay that truncated the previous page still holds the event AT its
        // own bottom, and this round's `until` is inclusive and at or above it,
        // so an empty page from it is impossible unless the READ failed —
        // which is exactly what `fetch_events_per_relay` reports for a
        // post-handshake fetch error: `responded == true`, no events.
        //
        // Reading that as "drained" is the silent drop this whole module exists
        // to prevent, and it needs no attacker: one slow radio on a background
        // wake, and the cursor advances over a tail we have local PROOF exists,
        // permanently (the next sweep's floor is only 60 s below the cursor).
        let stalled = RelayFetchOutcome {
            relay_url: "wss://stalled".to_string(),
            responded: true,
            events: Vec::new(),
        };
        let mut chasing = HashSet::new();
        chasing.insert("wss://stalled".to_string());
        let round = summarize_round(std::slice::from_ref(&stalled), &chasing);
        assert!(round.chase_lost);
        assert_eq!(
            round.boundary_secs, None,
            "precondition: an empty page truncates nothing, so without the rule \
             above this round would read as COMPLETE"
        );
        assert_eq!(
            chasing_pager().step(round.boundary_secs, round.chase_lost, false),
            PageStep::Halt,
            "and the pager must hold the window rather than call it complete"
        );

        // The complement, so the rule cannot quietly become "any empty page
        // halts": a relay nobody was chasing has simply nothing to give, which
        // is the ordinary shape of a quiet circle and must still advance.
        let quiet = RelayFetchOutcome {
            relay_url: "wss://quiet".to_string(),
            responded: true,
            events: Vec::new(),
        };
        assert!(!summarize_round(std::slice::from_ref(&quiet), &HashSet::new()).chase_lost);
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
        let own = keys.public_key().to_hex();

        let malformed = malformed_445(&h);
        assert!(
            crate::nostr::mls::SessionManager::event_to_transport_message(&malformed).is_err(),
            "precondition: this envelope must really fail the PRE-ENGINE parse"
        );
        assert_eq!(
            ingest_one(&mgr, &relay_mgr, &malformed, &ngid, &own).await,
            ReceiveOnlyOutcome::NoEvidence,
            "an unparseable envelope was screened before authentication, so it \
             must contribute no cursor evidence — reporting `Deferred` would sell \
             an attacker a permanent stall for one minted event"
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
