//! Cursor anchors for the live plane: per-circle ([`CursorAnchors`]) and one
//! for the inbox ([`InboxAnchor`]).
//!
//! The live receive path never advances a sync cursor because an event arrived.
//! An inbound `kind:445`'s outer `created_at` is signed by a throwaway ephemeral
//! key and bound to nothing the engine authenticates, and a circle's `#h` is its
//! *public* `nostr_group_id` — so any relay observer can mint, or re-wrap an
//! observed ciphertext into, an event carrying whatever timestamp it likes. A
//! per-event advance therefore hands a remote party the persisted REQ floor.
//!
//! The same is true of the inbox plane, for a *cheaper* forgery: a `kind:1059`
//! gift wrap is routed by a `#p` tag holding the recipient's PUBLIC key, is
//! authored by a throwaway ephemeral key by construction, and is peeled with
//! NIP-59 alone — no MLS state is consulted, and nothing binds the outer
//! `created_at` to anything. See [`InboxAnchor`].
//!
//! What the live plane CAN vouch for is the relay's end-of-stored-events signal:
//! after `EOSE` on a REQ, everything the relay held matching that filter has
//! been delivered — as of the local instant the REQ was issued. That instant is
//! this module's advance anchor. It is a reading of the local clock, so no
//! amount of injected traffic can move it.
//!
//! Event timestamps enter in exactly one direction: an event the plane could not
//! APPLY (engine-buffered, or a hard ingest failure) holds the generation's
//! advance at or below its own `created_at`, so it is re-requested. Holding back
//! is safe against arbitrary input — the worst a hostile timestamp buys is a
//! wider refetch, and because the cursor write is monotonic-max it cannot even
//! move the cursor backwards.
//!
//! # Generations
//!
//! Each time a circle's REQ is (re-)issued — session start, background resume,
//! a delta subscribe, a bucket re-issue after a member leaves — a new
//! *generation* opens with a fresh open time, a cleared EOSE flag, and no
//! hold-backs. A generation advances the cursor at most once, on its first EOSE
//! — or not at all, if the deliveries it was meant to cover were skipped
//! wholesale before it could see them ([`CursorAnchors::suppress_open_generations`]).
//! Events delivered live afterwards do not advance it: they carry no
//! completeness information, only the next generation's REQ does. They can still
//! hold the NEXT generation back, which is the safe direction.

use std::collections::HashMap;
use std::sync::{Mutex, PoisonError};

use crate::relay::cursor::cursor_ms_for_window;

/// One circle's anchor for the current subscription generation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct CircleAnchor {
    /// LOCAL wall-clock reading taken when this generation's REQ was issued.
    opened_at_secs: i64,
    /// Whether this generation's one EOSE advance is spent — issued, or burned
    /// unissued by a delivery skip this generation cannot see past.
    eose_consumed: bool,
    /// Oldest `created_at` of an event this generation delivered but could not
    /// apply. The only remotely-written value here, and it can only lower the
    /// advance.
    hold_back_secs: Option<i64>,
}

impl CircleAnchor {
    /// Opens a generation, inheriting `carried_hold_back` from the one it
    /// replaces (see [`CursorAnchors::open_generation`]).
    const fn opened(opened_at_secs: i64, carried_hold_back: Option<i64>) -> Self {
        Self {
            opened_at_secs,
            eose_consumed: false,
            hold_back_secs: carried_hold_back,
        }
    }

    /// The hold-back the NEXT generation must inherit, if any.
    ///
    /// This is simply whatever hold-back has NOT yet been applied to the
    /// persisted cursor — [`Self::consume_eose`] clears the field at the moment
    /// it folds the value into an advance, so a hold-back that has already
    /// moved the cursor is never inherited (inheriting it would pin the cursor
    /// there permanently, since nothing clears an inherited value).
    ///
    /// A BURNED generation ([`CursorAnchors::suppress_open_generations`]) still
    /// carries: burning issues no advance, so its hold-back reached the cursor
    /// no more than an un-redeemed one did.
    const fn hold_back_to_carry(&self) -> Option<i64> {
        self.hold_back_secs
    }

    /// Records an event that was delivered but not applied.
    const fn hold_at(&mut self, created_at_secs: i64) {
        self.hold_back_secs = Some(match self.hold_back_secs {
            Some(existing) if existing <= created_at_secs => existing,
            _ => created_at_secs,
        });
    }

    /// The cursor value (ms) this generation's EOSE justifies, or `None` if the
    /// generation has already consumed its advance.
    ///
    /// Clears the hold-back as it folds it into the advance: from here the value
    /// IS the persisted cursor, so [`Self::hold_back_to_carry`] must not hand it
    /// to the next generation as if it were still outstanding.
    const fn consume_eose(&mut self, now_secs: i64) -> Option<i64> {
        if self.eose_consumed {
            return None;
        }
        self.eose_consumed = true;
        let advance = cursor_ms_for_window(self.opened_at_secs, self.hold_back_secs, now_secs);
        self.hold_back_secs = None;
        Some(advance)
    }
}

/// The live plane's per-circle anchor table, keyed by `hex(nostr_group_id)`.
///
/// Interior-mutable so the processor can stay `&self` on the ingest path.
/// Presence-only `Debug` (counts, never a group id) so it cannot leak
/// (Security Rule 4).
#[derive(Default)]
pub struct CursorAnchors {
    inner: Mutex<HashMap<String, CircleAnchor>>,
}

impl std::fmt::Debug for CursorAnchors {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let len = self
            .inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .len();
        f.debug_struct("CursorAnchors")
            .field("circles", &len)
            .finish()
    }
}

impl CursorAnchors {
    /// Opens a fresh generation for `group_id_hex`, anchored at the local clock
    /// reading `opened_at_secs` taken when its REQ was issued.
    ///
    /// Replaces the previous generation's open time and spends-a-single-advance
    /// state outright — the new REQ's `since` is derived from the persisted
    /// cursor — but **inherits an un-redeemed hold-back**.
    ///
    /// # Why the hold-back has to survive
    ///
    /// A bucket's anchor is keyed by circle, while its REQ is issued to SEVERAL
    /// relays, and a repair re-issues to only the one that ended it
    /// ([`super::session`]). So a generation opened at `T2` by a repair can be
    /// redeemed by a co-bucketed relay's `EOSE` for the REQ issued at `T0` —
    /// which vouches for nothing after `T0`. If the `T0` generation's hold-backs
    /// were dropped, that stale `EOSE` would advance the cursor to `T2`, over
    /// events the plane recorded as un-applied. Carrying them forward makes the
    /// advance stop at them instead.
    ///
    /// Only a hold-back not yet APPLIED to the cursor is carried (see
    /// [`CircleAnchor::hold_back_to_carry`]), so this cannot pin a cursor
    /// forever: the moment a generation's `EOSE` folds the hold-back into an
    /// advance, the value stops being inherited and a later generation is free
    /// to advance again.
    ///
    /// The accepted cost: a hold-back is the one remotely-influenced number
    /// here, so a forged un-appliable event now reaches one generation FURTHER
    /// than it used to — until an `EOSE` applies it, rather than until the next
    /// REQ. It buys a wider re-fetch and never a skip (the advance is a `min`,
    /// and the cursor write is monotonic-max), which is the trade this module
    /// makes everywhere: a stall costs bandwidth, a skip costs the backlog.
    pub fn open_generation(&self, group_id_hex: &str, opened_at_secs: i64) {
        let mut anchors = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        let carried = anchors
            .get(group_id_hex)
            .and_then(CircleAnchor::hold_back_to_carry);
        anchors.insert(
            group_id_hex.to_string(),
            CircleAnchor::opened(opened_at_secs, carried),
        );
    }

    /// Records a delivered-but-unapplied event, holding this generation's
    /// advance at or below `created_at_secs`.
    ///
    /// A no-op for a circle with no open generation: with no REQ there is no
    /// window to hold back, and inventing one would let unsolicited traffic
    /// create anchor state.
    pub fn note_unapplied(&self, group_id_hex: &str, created_at_secs: i64) {
        if let Some(anchor) = self
            .inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get_mut(group_id_hex)
        {
            anchor.hold_at(created_at_secs);
        }
    }

    /// Burns the pending advance of EVERY open generation, issuing none: the
    /// delivery stream skipped an unknown set of events, so no REQ open at that
    /// moment can still claim its `EOSE` covered everything.
    ///
    /// The COARSE hold-back, for a loss reported as a bare count: with no
    /// `created_at` there is nothing to hold at, and with no `#h` there is no
    /// circle to attribute it to, so the ignorance is every circle with a REQ in
    /// flight and the suppression is exactly that wide. Anything narrower would
    /// advance some circle's cursor over events this process never saw.
    ///
    /// Writes no cursor, so it can only stall an advance, never lower one, and
    /// it is generation-scoped: the next REQ re-arms, deriving its `since` from
    /// the cursor this left alone, and so re-requests the skipped window.
    pub fn suppress_open_generations(&self) {
        for anchor in self
            .inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .values_mut()
        {
            anchor.eose_consumed = true;
        }
    }

    /// Consumes this generation's EOSE and returns the cursor value (ms) it
    /// justifies, or `None` when there is no open generation or the generation
    /// already advanced.
    ///
    /// A generation is opened per CIRCLE while its REQ is issued to SEVERAL
    /// relays, so this cannot be called on one relay's `EOSE` alone: the caller
    /// must first have established that every relay which accepted the REQ has
    /// finished its stored replay
    /// ([`super::processor::EngineProcessor::note_eose_endpoint`]). One relay's
    /// `EOSE` is one relay's completeness claim.
    pub fn note_eose(&self, group_id_hex: &str, now_secs: i64) -> Option<i64> {
        self.inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get_mut(group_id_hex)
            .and_then(|anchor| anchor.consume_eose(now_secs))
    }

    /// Whether EVERY open generation has spent its advance — nothing is still
    /// owed an `EOSE`.
    ///
    /// Presence-only (a bool over the whole table, never a group id), and read
    /// as "advance burned", NOT as "EOSE seen": a generation suppressed by
    /// [`Self::suppress_open_generations`] (the Rule-12 delivery-gap path)
    /// counts as consumed, because from the cursor's point of view the two are
    /// the same fact — this generation will not advance. Vacuously `true` with
    /// no generation open.
    ///
    /// The burst's observability read: after one burst has settled, this says
    /// whether the burst's own REQs resolved their advances.
    #[must_use]
    pub fn all_consumed(&self) -> bool {
        self.inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .values()
            .all(|anchor| anchor.eose_consumed)
    }

    /// Drops a circle's anchor (its subscription was closed).
    pub fn forget(&self, group_id_hex: &str) {
        self.inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(group_id_hex);
    }
}

/// The live plane's anchor for the ONE inbox (`kind:1059`) stream.
///
/// Same generation model as [`CursorAnchors`], collapsed to a single unkeyed
/// generation because there is exactly one inbox subscription per session.
///
/// # Why the inbox needs this at all — the forgery is cheaper here
///
/// A gift wrap is routed by a `#p` tag carrying the recipient's public key.
/// That key is published in the user's own `kind:0` profile, their `kind:10002`
/// / `kind:10050` relay lists and every `kind:30443` `KeyPackage`, so the
/// routing address of any Haven user is public by design. The wrapper is
/// authored by a throwaway ephemeral key *by construction* (NIP-59), and
/// peeling it consults NIP-59 alone — a valid seal over a `kind:444` rumor with
/// a well-formed `e` tag, a well-formed `relays` tag and non-empty base64
/// content is accepted; **no MLS state is touched and nothing binds the outer
/// `created_at` to the payload**. So anyone who knows a user's npub can mint a
/// wrap that peels cleanly, at any `created_at`, for the cost of one NIP-44
/// encryption. Deriving a cursor advance from that field would hand the inbox
/// REQ floor to the entire network.
///
/// # Why parking the cursor in the FUTURE is the damaging direction
///
/// [`super::super::cursor::since_for_stream`] caps the derived floor at `now`,
/// so a cursor above the wall clock pins EVERY subsequent inbox floor at `now`
/// for the whole duration of the skew. And NIP-59 deliberately backdates every
/// gift wrap by up to 48h, so with the floor at `now` even a wrap published
/// *this second* fails the `since` filter: invitation delivery stops entirely,
/// permanently, and across restarts. The inbox lookback (7 days cold, 49 hours
/// on a re-subscribe) bounds the backward direction but does nothing here — it
/// is subtracted from a cursor that is already ahead of the clock.
///
/// # What this anchors on instead
///
/// The local clock reading taken when the inbox REQ was issued, redeemed on
/// that REQ's `EOSE`. No remote party can write it. Nothing is passed in from
/// the consumer, so there is no remotely-written input to defend at all: the
/// hold-back arm of [`cursor_ms_for_window`] is deliberately unused here.
///
/// # Why no hold-back
///
/// A wrap the foreground could not hold is either (a) unpeelable — nothing
/// about it authenticated, which is the inbox's exact analogue of the group
/// plane's `RejectedBeforeAuth`, and letting it hold would sell anyone who
/// knows the victim's npub a permanent cursor stall for one free event — or (b)
/// a local storage failure, which no remote party caused. Case (b) is covered
/// instead by the stream's lookback: a stream with no persisted cursor subtracts
/// a full week ([`INBOX_GIFTWRAP_LOOKBACK_SECS`]) and every REQ derived from one
/// subtracts 49 hours ([`INBOX_RESUBSCRIBE_LOOKBACK_SECS`]), so a wrap delivered
/// in this window is re-requested for that long — the recovery window narrowed
/// with the bound, which is the cost that constant's doc records.
///
/// [`INBOX_GIFTWRAP_LOOKBACK_SECS`]: super::super::cursor::INBOX_GIFTWRAP_LOOKBACK_SECS
/// [`INBOX_RESUBSCRIBE_LOOKBACK_SECS`]: super::super::cursor::INBOX_RESUBSCRIBE_LOOKBACK_SECS
#[derive(Default)]
pub struct InboxAnchor {
    inner: Mutex<Option<InboxGeneration>>,
}

/// One inbox subscription generation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct InboxGeneration {
    /// LOCAL wall-clock reading taken when this generation's REQ was issued.
    opened_at_secs: i64,
    /// Whether this generation's one EOSE advance is spent — issued, or burned
    /// unissued by a delivery skip this generation cannot see past.
    eose_consumed: bool,
}

impl InboxGeneration {
    /// The cursor value (ms) this generation's EOSE justifies, or `None` if the
    /// generation has already consumed its advance.
    const fn consume_eose(&mut self, now_secs: i64) -> Option<i64> {
        if self.eose_consumed {
            return None;
        }
        self.eose_consumed = true;
        // `None` hold-back: see "Why no hold-back" on `InboxAnchor`. The clamp
        // to `now_secs` and the floor at 0 both live in `cursor_ms_for_window`.
        Some(cursor_ms_for_window(self.opened_at_secs, None, now_secs))
    }
}

impl std::fmt::Debug for InboxAnchor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let open = self
            .inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .is_some();
        f.debug_struct("InboxAnchor")
            .field("generation_open", &open)
            .finish()
    }
}

impl InboxAnchor {
    /// Opens a fresh generation anchored at `opened_at_secs` — a LOCAL clock
    /// reading taken when the inbox REQ was (re-)issued.
    ///
    /// Callers MUST pass the same `now` they derived the REQ's `since` from.
    /// Passing an EARLIER time is safe (it claims less); a later one is not.
    pub fn open(&self, opened_at_secs: i64) {
        *self.inner.lock().unwrap_or_else(PoisonError::into_inner) = Some(InboxGeneration {
            opened_at_secs,
            eose_consumed: false,
        });
    }

    /// Consumes this generation's EOSE and returns the cursor value (ms) it
    /// justifies, or `None` when no generation is open or it already advanced.
    ///
    /// A relay that flaps re-EOSEs on the same REQ; the open time has not
    /// moved, so the second EOSE carries no new completeness claim and must not
    /// re-advance.
    pub fn consume_eose(&self, now_secs: i64) -> Option<i64> {
        self.inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .as_mut()
            .and_then(|generation| generation.consume_eose(now_secs))
    }

    /// Burns the open generation's pending advance, issuing none — the same
    /// rule as [`CursorAnchors::suppress_open_generations`], and the inbox sits
    /// inside the same ignorance: ONE notification stream carries both planes,
    /// so a skip on it can have swallowed a gift wrap as easily as a `kind:445`.
    ///
    /// Cheap here in particular: the inbox REQ already re-requests a whole
    /// lookback window (7 days cold, 49 hours on a re-subscribe), so a
    /// suppressed generation widens that window by the length of one generation
    /// rather than adding a fetch.
    pub fn suppress_open_generation(&self) {
        if let Some(generation) = self
            .inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .as_mut()
        {
            generation.eose_consumed = true;
        }
    }

    /// Whether the open generation has spent its advance, or no generation is
    /// open at all.
    ///
    /// The inbox counterpart of [`CursorAnchors::all_consumed`], with the same
    /// "advance burned" reading: a generation suppressed by
    /// [`Self::suppress_open_generation`] answers `true`.
    #[must_use]
    pub fn is_consumed(&self) -> bool {
        self.inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .is_none_or(|generation| generation.eose_consumed)
    }

    /// Drops the generation (the inbox REQ was closed / the session stopped),
    /// so a later stray EOSE cannot redeem an anchor for a REQ we no longer own.
    pub fn forget(&self) {
        *self.inner.lock().unwrap_or_else(PoisonError::into_inner) = None;
    }
}

#[cfg(test)]
mod inbox_tests {
    use super::InboxAnchor;

    /// A `now` far past every timestamp here, so the clamp is inert and each
    /// test isolates the rule it is about.
    const NOW: i64 = 2_000_000_000;
    const OPENED: i64 = 1_000_000;

    #[test]
    fn eose_advances_to_the_req_open_time() {
        let anchor = InboxAnchor::default();
        anchor.open(OPENED);
        assert_eq!(anchor.consume_eose(NOW), Some(OPENED * 1000));
    }

    #[test]
    fn nothing_a_gift_wrap_carries_appears_in_the_advance() {
        // THE HEADLINE, stated as a type property: `consume_eose` takes only a
        // local clock reading. There is no parameter a wrap's `created_at`
        // could be threaded through, at any magnitude, in either direction —
        // which is the whole point of the shape. Anyone who knows the victim's
        // npub can mint a wrap that peels cleanly at an arbitrary `created_at`,
        // so the advance must not have an input for it.
        let anchor = InboxAnchor::default();
        anchor.open(OPENED);
        assert_eq!(anchor.consume_eose(NOW), Some(OPENED * 1000));
    }

    #[test]
    fn no_open_generation_never_advances() {
        // No REQ ⇒ no window ⇒ nothing to claim. This is what stops unsolicited
        // inbox traffic (or a stray EOSE for a closed REQ) from conjuring an
        // anchor.
        let anchor = InboxAnchor::default();
        assert_eq!(anchor.consume_eose(NOW), None);
    }

    #[test]
    fn a_generation_advances_at_most_once() {
        // A flapping relay re-EOSEs the same REQ. The open time has not moved,
        // so the second EOSE claims nothing new — otherwise a relay could pump
        // the inbox cursor forward by reconnecting in a loop.
        let anchor = InboxAnchor::default();
        anchor.open(OPENED);
        assert_eq!(anchor.consume_eose(NOW), Some(OPENED * 1000));
        assert_eq!(anchor.consume_eose(NOW), None);
        assert_eq!(anchor.consume_eose(NOW), None);
    }

    #[test]
    fn a_fresh_generation_re_arms_the_advance() {
        let anchor = InboxAnchor::default();
        anchor.open(OPENED);
        assert_eq!(anchor.consume_eose(NOW), Some(OPENED * 1000));
        anchor.open(OPENED + 500);
        assert_eq!(anchor.consume_eose(NOW), Some((OPENED + 500) * 1000));
    }

    #[test]
    fn a_future_open_time_clamps_to_now() {
        // A device clock stepped backwards mid-session must still not park the
        // cursor above the wall clock: `since_for_stream` caps the derived floor
        // at `now`, so a future cursor pins EVERY inbox floor at `now` — and
        // since NIP-59 backdates every gift wrap by up to 48h, a floor at `now`
        // rejects even wraps published this second. That is the failure mode
        // this clamp exists to make unreachable.
        let now = 1_000_i64;
        let anchor = InboxAnchor::default();
        anchor.open(now + 10_000);
        assert_eq!(anchor.consume_eose(now), Some(now * 1000));
    }

    #[test]
    fn a_negative_open_time_floors_at_zero() {
        // `since_for_stream` div_euclid's the stored value, so a negative cursor
        // must never be persisted.
        let anchor = InboxAnchor::default();
        anchor.open(-5);
        assert_eq!(anchor.consume_eose(NOW), Some(0));
    }

    #[test]
    fn a_delivery_skip_suppresses_the_open_generation_but_not_the_next() {
        // ONE notification stream carries both planes, so a skip on it can have
        // swallowed a gift wrap as easily as a group event: the open generation
        // loses its advance. Only that generation — the next REQ re-arms, so an
        // unattributable loss costs a wider window, never a wedged cursor.
        let anchor = InboxAnchor::default();
        anchor.open(OPENED);
        anchor.suppress_open_generation();
        assert_eq!(anchor.consume_eose(NOW), None);
        anchor.open(OPENED + 500);
        assert_eq!(anchor.consume_eose(NOW), Some((OPENED + 500) * 1000));
    }

    #[test]
    fn forget_drops_the_generation() {
        let anchor = InboxAnchor::default();
        anchor.open(OPENED);
        anchor.forget();
        assert_eq!(anchor.consume_eose(NOW), None);
    }

    #[test]
    fn the_debug_impl_is_presence_only() {
        let anchor = InboxAnchor::default();
        assert!(format!("{anchor:?}").contains("generation_open: false"));
        anchor.open(OPENED);
        assert!(format!("{anchor:?}").contains("generation_open: true"));
    }
}

#[cfg(test)]
mod tests {
    use super::{CircleAnchor, CursorAnchors};

    /// A `now` far past every timestamp here, so the clamp is inert and each
    /// test isolates the rule it is about.
    const NOW: i64 = 2_000_000_000;
    const OPENED: i64 = 1_000_000;

    #[test]
    fn eose_advances_to_the_req_open_time() {
        let anchors = CursorAnchors::default();
        anchors.open_generation("aa00", OPENED);
        assert_eq!(anchors.note_eose("aa00", NOW), Some(OPENED * 1000));
    }

    #[test]
    fn a_circle_with_no_open_generation_never_advances() {
        // No REQ ⇒ no window ⇒ nothing to claim. This is also what stops
        // unsolicited traffic from conjuring anchor state.
        let anchors = CursorAnchors::default();
        assert_eq!(anchors.note_eose("aa00", NOW), None);
        anchors.note_unapplied("aa00", 5);
        assert_eq!(anchors.note_eose("aa00", NOW), None);
    }

    #[test]
    fn a_generation_advances_at_most_once() {
        // A relay reconnect re-issues the REQ and EOSEs again. The second EOSE
        // carries no NEW completeness claim (the open time has not moved), so it
        // must not re-advance — otherwise a relay could pump the cursor by
        // flapping.
        let anchors = CursorAnchors::default();
        anchors.open_generation("aa00", OPENED);
        assert_eq!(anchors.note_eose("aa00", NOW), Some(OPENED * 1000));
        assert_eq!(anchors.note_eose("aa00", NOW), None);
    }

    #[test]
    fn a_fresh_generation_re_arms_the_advance() {
        let anchors = CursorAnchors::default();
        anchors.open_generation("aa00", OPENED);
        assert_eq!(anchors.note_eose("aa00", NOW), Some(OPENED * 1000));
        anchors.open_generation("aa00", OPENED + 500);
        assert_eq!(anchors.note_eose("aa00", NOW), Some((OPENED + 500) * 1000));
    }

    #[test]
    fn an_unapplied_event_holds_the_generation_at_itself() {
        let anchors = CursorAnchors::default();
        anchors.open_generation("aa00", OPENED);
        anchors.note_unapplied("aa00", OPENED - 40);
        assert_eq!(anchors.note_eose("aa00", NOW), Some((OPENED - 40) * 1000));
    }

    #[test]
    fn the_oldest_unapplied_event_is_the_one_that_holds() {
        let anchors = CursorAnchors::default();
        anchors.open_generation("aa00", OPENED);
        anchors.note_unapplied("aa00", OPENED - 10);
        anchors.note_unapplied("aa00", OPENED - 90);
        anchors.note_unapplied("aa00", OPENED - 50);
        assert_eq!(anchors.note_eose("aa00", NOW), Some((OPENED - 90) * 1000));
    }

    #[test]
    fn a_hold_back_can_never_raise_the_advance() {
        // The security direction: the hold-back is the only remotely-written
        // number in this module, and an absurd one must be inert.
        let anchors = CursorAnchors::default();
        anchors.open_generation("aa00", OPENED);
        anchors.note_unapplied("aa00", i64::MAX);
        assert_eq!(anchors.note_eose("aa00", NOW), Some(OPENED * 1000));
    }

    #[test]
    fn a_carried_hold_back_is_bounded_by_the_next_advance_it_is_applied_to() {
        // SUPERSEDES `a_new_generation_clears_the_previous_hold_back`, which
        // pinned "a new generation clears the hold-back" outright. That is
        // unsound: a repair re-issues ONE relay of a multiplexed bucket, so a
        // co-bucketed relay's stale EOSE can redeem the new generation and
        // advance straight over the un-applied events the old one recorded.
        //
        // The property that test was really protecting — a single forged event
        // must not pin a circle's cursor for the whole session — is kept, and is
        // what this asserts: the carry survives exactly until an EOSE folds it
        // into an advance, and not one generation longer.
        let anchors = CursorAnchors::default();
        anchors.open_generation("aa00", OPENED);
        anchors.note_unapplied("aa00", 1);

        // Re-issued before any EOSE: still owed, so still carried.
        anchors.open_generation("aa00", OPENED);
        assert_eq!(
            anchors.note_eose("aa00", NOW),
            Some(1000),
            "an un-applied hold-back must survive a re-issue"
        );

        // That advance APPLIED it. It must not be inherited again, or the pin
        // would last forever.
        anchors.open_generation("aa00", OPENED);
        assert_eq!(
            anchors.note_eose("aa00", NOW),
            Some(OPENED * 1000),
            "one forged event buys ONE held-back advance, never a permanent pin"
        );
    }

    #[test]
    fn circles_do_not_share_anchors() {
        // A busy circle's EOSE must not advance a quiet co-multiplexed circle
        // that has not been vouched for.
        let anchors = CursorAnchors::default();
        anchors.open_generation("aa00", OPENED);
        anchors.note_unapplied("aa00", OPENED - 10);
        anchors.open_generation("bb11", OPENED);
        assert_eq!(anchors.note_eose("bb11", NOW), Some(OPENED * 1000));
        assert_eq!(anchors.note_eose("aa00", NOW), Some((OPENED - 10) * 1000));
    }

    #[test]
    fn a_delivery_skip_suppresses_every_open_generation_but_not_the_next() {
        // A skip arrives as a COUNT — no `created_at` to hold at, no `#h` to
        // attribute it to — so it burns the advance of every circle with a REQ
        // in flight. Anything narrower would advance one of them over an event
        // this process never saw. And only those: the next REQ re-arms, so the
        // loss costs a re-fetch rather than a wedged cursor.
        let anchors = CursorAnchors::default();
        anchors.open_generation("aa00", OPENED);
        anchors.open_generation("bb11", OPENED);
        anchors.suppress_open_generations();
        assert_eq!(anchors.note_eose("aa00", NOW), None);
        assert_eq!(anchors.note_eose("bb11", NOW), None);
        anchors.open_generation("aa00", OPENED + 500);
        assert_eq!(anchors.note_eose("aa00", NOW), Some((OPENED + 500) * 1000));
    }

    #[test]
    fn a_delivery_skip_conjures_no_anchor_for_a_circle_that_has_none() {
        // Same rule as `note_unapplied`: no REQ ⇒ no window to suppress. A latch
        // left behind here would suppress a generation opened long after the
        // skip, which is a stall nothing recovers from on its own.
        let anchors = CursorAnchors::default();
        anchors.suppress_open_generations();
        assert_eq!(anchors.note_eose("aa00", NOW), None);
        anchors.open_generation("aa00", OPENED);
        assert_eq!(anchors.note_eose("aa00", NOW), Some(OPENED * 1000));
    }

    #[test]
    fn forget_drops_the_anchor() {
        let anchors = CursorAnchors::default();
        anchors.open_generation("aa00", OPENED);
        anchors.forget("aa00");
        assert_eq!(anchors.note_eose("aa00", NOW), None);
    }

    #[test]
    fn hold_at_keeps_the_minimum_regardless_of_arrival_order() {
        let mut anchor = CircleAnchor::opened(OPENED, None);
        anchor.hold_at(30);
        anchor.hold_at(70);
        anchor.hold_at(10);
        assert_eq!(anchor.hold_back_secs, Some(10));
    }

    #[test]
    fn an_unredeemed_hold_back_survives_a_re_issued_req() {
        // A bucket's anchor is keyed by circle, but its REQ goes to several
        // relays and a repair re-issues to only the one that ended it. So a
        // co-bucketed relay's EOSE for the OLD REQ can redeem the generation the
        // repair just opened. If the old generation's hold-backs were dropped,
        // that stale EOSE would advance the cursor past events recorded as
        // un-applied — the loss the hold-back exists to prevent.
        let anchors = CursorAnchors::default();
        anchors.open_generation("aa00", OPENED);
        anchors.note_unapplied("aa00", OPENED - 500);

        // The repair re-issues on one relay: a fresh generation, much later.
        anchors.open_generation("aa00", OPENED + 1_000);

        let advanced = anchors
            .note_eose("aa00", NOW + 5_000)
            .expect("the fresh generation still has its advance");
        assert_eq!(
            advanced,
            (OPENED - 500) * 1000,
            "the advance must still stop at the un-applied event, not jump to \
             the re-issue's open time"
        );
    }

    #[test]
    fn a_redeemed_hold_back_is_not_inherited_and_cannot_pin_the_cursor() {
        // The other half: once an EOSE has applied a hold-back to the persisted
        // cursor, inheriting it would pin every later generation at that
        // position forever, because nothing ever clears an inherited value.
        let anchors = CursorAnchors::default();
        anchors.open_generation("aa00", OPENED);
        anchors.note_unapplied("aa00", OPENED - 500);
        assert_eq!(
            anchors.note_eose("aa00", NOW),
            Some((OPENED - 500) * 1000),
            "the first generation applies the hold-back"
        );

        // The event has since been applied, so the next generation records no
        // hold-back of its own — and must be free to advance.
        anchors.open_generation("aa00", OPENED + 1_000);
        assert_eq!(
            anchors.note_eose("aa00", NOW + 5_000),
            Some((OPENED + 1_000) * 1000),
            "a spent hold-back must not be inherited, or the cursor would stall \
             at it permanently"
        );
    }

    #[test]
    fn a_burned_generations_hold_back_is_also_carried_forward() {
        // `suppress_open_generations` burns the advance WITHOUT issuing one, so
        // the hold-back reached the persisted cursor no more than an un-redeemed
        // one did. Treating "burned" as "applied" would let the next
        // generation's advance jump straight over the un-applied event — the
        // same loss, reached by the other door.
        let anchors = CursorAnchors::default();
        anchors.open_generation("aa00", OPENED);
        anchors.note_unapplied("aa00", OPENED - 500);
        anchors.suppress_open_generations();

        anchors.open_generation("aa00", OPENED + 1_000);
        assert_eq!(
            anchors.note_eose("aa00", NOW + 5_000),
            Some((OPENED - 500) * 1000),
            "a burned generation applied nothing, so its hold-back is still owed"
        );
    }

    #[test]
    fn the_debug_impl_leaks_no_group_id() {
        // Security Rule 4: the anchor table is keyed by `nostr_group_id` hex.
        let anchors = CursorAnchors::default();
        anchors.open_generation("deadbeef", OPENED);
        let rendered = format!("{anchors:?}");
        assert!(
            !rendered.contains("deadbeef"),
            "the anchor table must render presence-only: {rendered}"
        );
        assert!(rendered.contains("circles: 1"));
    }
}
