//! Per-circle cursor anchors for the live plane.
//!
//! The live receive path never advances a sync cursor because an event arrived.
//! An inbound `kind:445`'s outer `created_at` is signed by a throwaway ephemeral
//! key and bound to nothing the engine authenticates, and a circle's `#h` is its
//! *public* `nostr_group_id` — so any relay observer can mint, or re-wrap an
//! observed ciphertext into, an event carrying whatever timestamp it likes. A
//! per-event advance therefore hands a remote party the persisted REQ floor.
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
