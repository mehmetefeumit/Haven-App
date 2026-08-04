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
//! hold-backs. A generation advances the cursor at most once, on its first EOSE.
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
    /// Whether this generation has already consumed its one EOSE advance.
    eose_consumed: bool,
    /// Oldest `created_at` of an event this generation delivered but could not
    /// apply. The only remotely-written value here, and it can only lower the
    /// advance.
    hold_back_secs: Option<i64>,
}

impl CircleAnchor {
    const fn opened(opened_at_secs: i64) -> Self {
        Self {
            opened_at_secs,
            eose_consumed: false,
            hold_back_secs: None,
        }
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
    const fn consume_eose(&mut self, now_secs: i64) -> Option<i64> {
        if self.eose_consumed {
            return None;
        }
        self.eose_consumed = true;
        Some(cursor_ms_for_window(
            self.opened_at_secs,
            self.hold_back_secs,
            now_secs,
        ))
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
    /// Replaces any previous generation outright: the previous one's hold-backs
    /// belong to a window that has been superseded, and the new REQ's `since` is
    /// derived from the (already held) persisted cursor.
    pub fn open_generation(&self, group_id_hex: &str, opened_at_secs: i64) {
        self.inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(
                group_id_hex.to_string(),
                CircleAnchor::opened(opened_at_secs),
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

    /// Consumes this generation's EOSE and returns the cursor value (ms) it
    /// justifies, or `None` when there is no open generation or the generation
    /// already advanced.
    pub fn note_eose(&self, group_id_hex: &str, now_secs: i64) -> Option<i64> {
        self.inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get_mut(group_id_hex)
            .and_then(|anchor| anchor.consume_eose(now_secs))
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
/// permanently, and across restarts. The 7-day inbox lookback bounds the
/// backward direction but does nothing here — it is subtracted from a cursor
/// that is already ahead of the clock.
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
/// instead by the stream's 7-day lookback ([`INBOX_GIFTWRAP_LOOKBACK_SECS`]):
/// the next REQ's floor is a full week below this advance, so a wrap that was
/// delivered in this window is re-requested for the next seven days.
///
/// [`INBOX_GIFTWRAP_LOOKBACK_SECS`]: super::super::cursor::INBOX_GIFTWRAP_LOOKBACK_SECS
#[derive(Default)]
pub struct InboxAnchor {
    inner: Mutex<Option<InboxGeneration>>,
}

/// One inbox subscription generation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct InboxGeneration {
    /// LOCAL wall-clock reading taken when this generation's REQ was issued.
    opened_at_secs: i64,
    /// Whether this generation has already consumed its one EOSE advance.
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
    fn a_new_generation_clears_the_previous_hold_back() {
        // Hold-backs describe ONE window. Carrying them forward would let a
        // single forged event pin a circle's cursor for the whole session.
        let anchors = CursorAnchors::default();
        anchors.open_generation("aa00", OPENED);
        anchors.note_unapplied("aa00", 1);
        anchors.open_generation("aa00", OPENED);
        assert_eq!(anchors.note_eose("aa00", NOW), Some(OPENED * 1000));
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
    fn forget_drops_the_anchor() {
        let anchors = CursorAnchors::default();
        anchors.open_generation("aa00", OPENED);
        anchors.forget("aa00");
        assert_eq!(anchors.note_eose("aa00", NOW), None);
    }

    #[test]
    fn hold_at_keeps_the_minimum_regardless_of_arrival_order() {
        let mut anchor = CircleAnchor::opened(OPENED);
        anchor.hold_at(30);
        anchor.hold_at(70);
        anchor.hold_at(10);
        assert_eq!(anchor.hold_back_secs, Some(10));
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
