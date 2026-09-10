//! Relay sync-cursor logic: per-stream `since` derivation.
//!
//! A *sync cursor* is the newest successfully-processed event timestamp for a
//! logical relay stream, persisted in `circles.db` (see
//! [`crate::circle::storage`]). On a cold start or a resubscribe the cursor —
//! minus a per-stream lookback buffer — becomes the `since` lower bound of the
//! next REQ, so the client never re-opens a `since = NULL` "send all history"
//! window and never skips an event that arrived while it was offline.
//!
//! # Why the buffer is applied here, not at write time
//!
//! The cursor stores the **raw** event/rumor timestamp. The lookback buffer is
//! a property of *how we re-query*, not of *what we processed*, so it is
//! applied live in [`since_for_stream`] each time a REQ is issued:
//!
//! - **Group (`kind:445`)**: a small clock-skew buffer ([`GROUP_INITIAL_BUFFER_SECS`]
//!   on the first subscription, [`GROUP_RESUBSCRIBE_BUFFER_SECS`] when
//!   re-subscribing after a teardown) so a commit whose `created_at` is a few
//!   seconds behind the cursor is still re-requested.
//! - **Inbox (`kind:1059`)**: a much wider buffer, because NIP-59 gift wraps are
//!   deliberately backdated by up to 48h, so a freshly-delivered invitation can
//!   carry a `created_at` well before the cursor. 7 days when NO inbox cursor is
//!   persisted yet ([`INBOX_GIFTWRAP_LOOKBACK_SECS`] — that device cannot know
//!   how long it was gone), 2 days + 1 hour whenever one is
//!   ([`INBOX_RESUBSCRIBE_LOOKBACK_SECS`], which carries the two residuals that
//!   bound buys).
//!
//! All derived `since` values are floored at `0` and capped to the caller's
//! `now`, so a corrupt or future cursor can never produce a future-dated or
//! negative filter bound.
//!
//! # The governing asymmetry: advance from local facts, hold back on timestamps
//!
//! A cursor ADVANCE is a claim about what this device has already seen. An
//! inbound event's `created_at` is chosen by whoever signed the wrapper and is
//! authenticated by nothing on the receive path — the engine authenticates the
//! *inner* MLS message, and no receive-side check binds the outer envelope's
//! timestamp to it. Deriving an advance from that field is therefore
//! remotely writable, and writable in the one direction that destroys
//! availability permanently (see [`cursor_ms_for_window`]).
//!
//! So the two receive planes derive every advance from a **local clock reading
//! taken when the observation window opened** — the catch-up fetch's open time,
//! the live subscription's REQ time — and use event timestamps ONLY to hold the
//! advance back. Holding back is safe against arbitrary input: the worst an
//! attacker buys with a hostile timestamp is a refetch of events we already
//! have, and the cursor write is monotonic-max, so a hold-back can never even
//! move the cursor backwards.

/// Logical stream key for `kind:445` group messages (multiplexed by `#h`).
pub const STREAM_GROUP_445: &str = "group_445";

/// Logical stream key for `kind:1059` gift-wrapped invitations (by `#p`).
pub const STREAM_INBOX_1059: &str = "inbox_1059";

/// Clock-skew buffer (seconds) for the group cursor on the FIRST subscription
/// of a session.
pub const GROUP_INITIAL_BUFFER_SECS: i64 = 10;

/// Clock-skew buffer (seconds) for the group cursor when RE-subscribing after
/// a teardown / reconnect. Wider than the initial buffer to tolerate the gap
/// during which the socket was down.
///
/// # Invariant (native-rollback re-fetch coupling)
///
/// This buffer also bounds MDK's concurrent-commit convergence across a
/// resubscribe. When the engine advances the group cursor on an applied commit
/// that MDK may later roll back in favour of a better same-epoch sibling
/// (regime 1), that better sibling is re-fetched on resubscribe only if its
/// `created_at >= cursor - GROUP_RESUBSCRIBE_BUFFER_SECS`. Concurrent commits
/// race within seconds, so this holds with wide margin — but it is a real
/// invariant: this value MUST exceed the maximum plausible inter-sibling
/// `created_at` skew (relay/clock skew between two committers) for native
/// rollback to remain complete across a teardown. Do not shrink it below that.
pub const GROUP_RESUBSCRIBE_BUFFER_SECS: i64 = 60;

/// Gift-wrap lookback (seconds, 7 days) applied to the inbox cursor when there
/// is NO persisted inbox cursor ([`SubscribePhase::Initial`]).
///
/// A device with no cursor cannot know how long it was gone, so it pays for the
/// widest replay we are willing to fund — once. Every REQ made against a known
/// cursor uses [`INBOX_RESUBSCRIBE_LOOKBACK_SECS`], including the first REQ of a
/// freshly-started engine: the cursor outlives the process, so a restart is not
/// a cold start.
///
/// `CircleStorage::PROCESSED_GIFT_WRAP_RETENTION_SECS` is derived from THIS
/// constant, and that derivation is correct only while this stays the WIDER of
/// the two inbox lookbacks (a dedup row must outlive every window that can
/// re-request its wrapper). Asserted at compile time there.
pub const INBOX_GIFTWRAP_LOOKBACK_SECS: i64 = 604_800;

/// Gift-wrap lookback (seconds, 2 days + 1 hour) applied to the inbox cursor
/// whenever one is already persisted ([`SubscribePhase::Resubscribe`]).
///
/// # Why a re-subscribe does not pay the cold-start price
///
/// Re-anchoring is not rare: a foreground resume, a relay `CLOSED` repair, the
/// 15-minute health tick and — since the engine is STOPPED while background
/// sharing is off — every fresh engine start re-issue the inbox REQ, and each
/// one at 7 days asks every inbox relay to replay a week of gift wraps keyed on
/// this device's `#p` — radio, relay load, and a standing re-advertisement of
/// the one query that links this npub to itself.
///
/// # Why 2 days + 1 hour, exactly
///
/// A NIP-59 sender subtracts a uniform random offset in `0..172_800` seconds
/// from the wrapper's build time (`nostr::nips::nip59::RANGE_RANDOM_TIMESTAMP_TWEAK`
/// — always subtracted, never added), so two days is the largest gap a
/// conformant sender can put between a wrap's ARRIVAL and its `created_at`. The
/// extra hour is the sender/relay clock-skew margin, and it is the only margin
/// there is.
///
/// # What the floor actually tracks
///
/// The floor is `clamp(cursor − L, 0, now)`, and the inbox cursor advances ONLY
/// when an inbox REQ's own EOSE is consumed (`live_sync::anchor::InboxAnchor`).
/// So the window slides with the last EOSE, not with the wall clock: while the
/// device is offline the cursor is FROZEN, and a three-day outage with the
/// process alive still leaves the floor at `T_lastEOSE − 49 h`. A wrap is
/// fetched whenever its `created_at` is no more than 48 h below its own arrival,
/// however long the outage lasted.
///
/// # Residual 1 — the exact boundary at which a wrap is missed
///
/// A wrap is missed if and only if BOTH hold: its sender's clock is slow by more
/// than the 1 h margin, AND that sender used a near-maximal backdate — together
/// putting `created_at` below `T_lastEOSE − 49 h` for a wrap that arrived after
/// `T_lastEOSE`. Either condition alone lands above the floor.
///
/// Nothing re-requests such a wrap later: the 7-day window is spent on the one
/// REQ made before any inbox cursor exists, and the first start persists one. So
/// the invitation is lost silently — and an invitation that is never fetched is
/// indistinguishable from one that was never sent. That is the price of not
/// re-advertising this npub's `#p` query across a week of history on every
/// restart, and it is bounded by a condition no conformant sender meets (a clock
/// slow by over an hour AND a near-maximal backdate).
///
/// # Residual 2 — one anchor, several inbox relays
///
/// There is ONE inbox cursor for the whole inbox relay set — the anchor is not
/// keyed per relay, and the first EOSE of a generation consumes its advance. An
/// inbox relay unreachable for longer than this lookback, while another inbox
/// relay keeps EOSE-ing and advancing that shared anchor, therefore loses
/// exactly the wraps only IT held: by the time it answers again, the floor has
/// moved past them. Not a new failure — the same loss exists at 7 days — but the
/// bound moves its threshold from ≈ 7 days of unreachability to ≈ 49 hours.
pub const INBOX_RESUBSCRIBE_LOOKBACK_SECS: i64 = 2 * 86_400 + 3_600;

/// Which phase a (re)subscription is being issued in.
///
/// Both streams read it: the group buffer widens on a resubscribe (the socket
/// was down), the inbox lookback NARROWS (a resubscribe knows when it last
/// heard EOSE; a cold start does not).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SubscribePhase {
    /// First subscription of a session (narrow group buffer); on the inbox, a
    /// stream with no persisted cursor at all.
    Initial,
    /// Re-subscription after a teardown / reconnect (wide group buffer); on the
    /// inbox, any REQ derived from a persisted cursor.
    Resubscribe,
}

/// Caps a unix-seconds timestamp so it never exceeds `now_secs`.
///
/// # Examples
///
/// ```
/// use haven_core::relay::cursor::cap_timestamp_to_now;
///
/// assert_eq!(cap_timestamp_to_now(100, 50), 50);
/// assert_eq!(cap_timestamp_to_now(40, 50), 40);
/// ```
#[must_use]
pub const fn cap_timestamp_to_now(ts_secs: i64, now_secs: i64) -> i64 {
    if ts_secs > now_secs {
        now_secs
    } else {
        ts_secs
    }
}

/// Converts an event's `created_at` (unix **seconds**) into a millisecond cursor
/// value, clamping it to `now_secs` first.
///
/// # NOT the cursor advance — use [`cursor_ms_for_window`]
///
/// Neither receive plane derives a cursor ADVANCE from this any more, and none
/// may start again. An event's `created_at` is chosen by whoever signed the
/// envelope and is bound to nothing the MLS engine authenticates, so a cursor
/// taken from it is remotely writable in the one direction that strands
/// legitimate history permanently. [`cursor_ms_for_window`] carries the full
/// argument, and is the only sanctioned advance computation.
///
/// What survives here is the clamp below, which both planes still depend on
/// through `cursor_ms_for_window`. Kept public because the clamp's reasoning is
/// worth reading on its own and a caller that legitimately needs "this event's
/// timestamp, bounded by the local clock" (a hold-back floor, a diagnostic)
/// should not re-derive it.
///
/// # Why the clamp
///
/// A cursor is only ever read back through [`since_for_stream`], which caps the
/// derived REQ floor at `now`. So a cursor sitting in the FUTURE does not
/// produce a future-dated filter — it silently pins the floor at `now` for as
/// long as the future timestamp exceeds the wall clock. Catch-up then degrades
/// to "only what was published after this fetch started": everything a peer
/// published while the device was offline is below the floor and is never
/// requested again. `created_at` is chosen by whoever built the event, so this
/// needs no attacker — one co-member whose clock runs an hour fast, or a relay
/// that accepts loosely-bounded timestamps (a spec-conformant one still allows
/// `now + 900s`), is enough. Clamping keeps the persisted cursor inside the
/// window the local clock can actually vouch for.
///
/// # Examples
///
/// ```
/// use haven_core::relay::cursor::cursor_ms_for_event;
///
/// // A normal, past event: cursor lands exactly on it.
/// assert_eq!(cursor_ms_for_event(1_700_000_000, 1_700_000_050), 1_700_000_000_000);
/// // A future-dated event: cursor stops at `now`.
/// assert_eq!(cursor_ms_for_event(1_700_009_999, 1_700_000_050), 1_700_000_050_000);
/// ```
#[must_use]
pub const fn cursor_ms_for_event(event_created_at_secs: i64, now_secs: i64) -> i64 {
    cap_timestamp_to_now(event_created_at_secs, now_secs).saturating_mul(1000)
}

/// The millisecond cursor value one completed OBSERVATION WINDOW justifies.
///
/// This is the only function either receive plane may use to compute a cursor
/// advance. Both planes route through it so the argument below lives in exactly
/// one place.
///
/// # What the two arguments are, and why only one of them may raise the cursor
///
/// * `window_opened_at_secs` — a reading of the **local** wall clock, taken
///   before the request that opened this window was issued. A completed window
///   means "the relay handed over everything it held matching this filter as of
///   the moment I asked", so this local timestamp — and nothing else — is what
///   the device has actually earned the right to claim. It is not writable by
///   any remote party.
/// * `hold_back_secs` — the `created_at` of the oldest event in the window that
///   could NOT be applied (engine-buffered, hard ingest failure, or never
///   reached because a deadline cut the batch short). Used ONLY as an upper
///   bound, so that un-applied event is re-requested next time.
///
/// # How this defeats arbitrary attacker timestamps
///
/// A circle's `nostr_group_id` is the public `#h` tag of every one of its
/// `kind:445`s, so any relay observer can mint — or re-wrap an observed
/// ciphertext into — an event carrying a `created_at` of its choosing. The
/// engine will authenticate the inner MLS message (or not) and report
/// `Processed` / `Stale` / `Buffered`, but **no receive-side check binds the
/// outer `created_at` to that inner message**, for ANY of those outcomes.
///
/// The advance here is `min(window_opened_at_secs, hold_back_secs)`, so an
/// attacker's timestamp can only ever appear on the `min`'s LOW side:
///
/// * it can never raise the result above `window_opened_at_secs`, which the
///   attacker cannot influence at all; and
/// * lowering the result only causes a wider re-request — and since the cursor
///   write is monotonic-max, a value below the stored cursor is a no-op.
///
/// So no number of injected `kind:445`s, at any `created_at`, can push the
/// persisted REQ floor past a legitimate event and strand it. (That was the
/// defect: with a per-event advance, ONE forged event dated `now` buried every
/// genuine event below it, permanently and across restarts — a stranded
/// location merely ages out, but a stranded COMMIT breaks the epoch chain.)
///
/// The result is additionally clamped to `now_secs` and floored at `0`, so a
/// window opened against a fast local clock still cannot park the cursor in the
/// future, where [`since_for_stream`] would pin every REQ floor at `now`.
///
/// # Examples
///
/// ```
/// use haven_core::relay::cursor::cursor_ms_for_window;
///
/// // A clean window: the advance is the local open time, not any event's.
/// assert_eq!(cursor_ms_for_window(1_700_000_000, None, 1_700_000_050), 1_700_000_000_000);
/// // One event could not be applied: hold at it so it is re-requested.
/// assert_eq!(
///     cursor_ms_for_window(1_700_000_000, Some(1_699_999_000), 1_700_000_050),
///     1_699_999_000_000,
/// );
/// // A hold-back ABOVE the window open time cannot raise the advance.
/// assert_eq!(
///     cursor_ms_for_window(1_700_000_000, Some(1_700_009_999), 1_700_000_050),
///     1_700_000_000_000,
/// );
/// ```
#[must_use]
pub const fn cursor_ms_for_window(
    window_opened_at_secs: i64,
    hold_back_secs: Option<i64>,
    now_secs: i64,
) -> i64 {
    let target = match hold_back_secs {
        Some(hold) if hold < window_opened_at_secs => hold,
        _ => window_opened_at_secs,
    };
    let capped = cap_timestamp_to_now(target, now_secs);
    if capped < 0 {
        0
    } else {
        capped.saturating_mul(1000)
    }
}

/// Derives the REQ `since` (unix seconds) for `stream` from its persisted
/// cursor.
///
/// `cursor_ms` is the raw last-synced timestamp in **milliseconds**, exactly
/// as stored by [`crate::circle::storage::CircleStorage::read_sync_cursor`].
/// The per-stream lookback buffer (see the module docs) is subtracted, the
/// result is floored at `0`, then capped to `now_secs`.
///
/// `stream` is matched against [`STREAM_INBOX_1059`]; every other key
/// (including [`STREAM_GROUP_445`]) is treated as a group stream. Both branches
/// are phase-dependent, and in OPPOSITE directions: a resubscribe widens the
/// group buffer (the socket was down for an unknown gap) and narrows the inbox
/// lookback (the cursor still marks the last EOSE it consumed).
///
/// # Examples
///
/// ```
/// use haven_core::relay::cursor::{
///     since_for_stream, SubscribePhase, STREAM_GROUP_445, STREAM_INBOX_1059,
/// };
///
/// // Cursor at 10_000 ms (= 10 s); initial group buffer of 10 s → since 0.
/// let since = since_for_stream(STREAM_GROUP_445, 10_000, SubscribePhase::Initial, 1_000);
/// assert_eq!(since, 0);
///
/// // The inbox: 7 days on a cold start, 2 days + 1 hour on every re-anchor.
/// let cursor_ms = 1_000_000_000; // 1_000_000 s
/// let now = 2_000_000;
/// assert_eq!(
///     since_for_stream(STREAM_INBOX_1059, cursor_ms, SubscribePhase::Initial, now),
///     1_000_000 - 604_800,
/// );
/// assert_eq!(
///     since_for_stream(STREAM_INBOX_1059, cursor_ms, SubscribePhase::Resubscribe, now),
///     1_000_000 - 176_400,
/// );
/// ```
#[must_use]
pub fn since_for_stream(stream: &str, cursor_ms: i64, phase: SubscribePhase, now_secs: i64) -> i64 {
    // Floor-divide so a (non-negative) ms cursor maps to whole seconds; nostr
    // filter granularity is one second.
    let cursor_secs = cursor_ms.div_euclid(1000);

    let buffer = if stream == STREAM_INBOX_1059 {
        match phase {
            SubscribePhase::Initial => INBOX_GIFTWRAP_LOOKBACK_SECS,
            SubscribePhase::Resubscribe => INBOX_RESUBSCRIBE_LOOKBACK_SECS,
        }
    } else {
        match phase {
            SubscribePhase::Initial => GROUP_INITIAL_BUFFER_SECS,
            SubscribePhase::Resubscribe => GROUP_RESUBSCRIBE_BUFFER_SECS,
        }
    };

    let since = cursor_secs.saturating_sub(buffer).max(0);
    cap_timestamp_to_now(since, now_secs)
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 2_000_000_000; // well past any buffer; not limiting here

    #[test]
    fn cap_timestamp_clamps_future_to_now() {
        assert_eq!(cap_timestamp_to_now(100, 50), 50);
        assert_eq!(cap_timestamp_to_now(50, 50), 50);
        assert_eq!(cap_timestamp_to_now(40, 50), 40);
    }

    #[test]
    fn cursor_ms_for_event_clamps_the_future_and_scales_to_ms() {
        // Past event: lands exactly on it (seconds → milliseconds).
        assert_eq!(
            cursor_ms_for_event(1_700_000_000, 1_700_000_050),
            1_700_000_000_000
        );
        // Exactly `now`: the boundary is inclusive, not off by one second.
        assert_eq!(
            cursor_ms_for_event(1_700_000_050, 1_700_000_050),
            1_700_000_050_000
        );
        // Future event: clamped to `now`, never beyond.
        assert_eq!(
            cursor_ms_for_event(1_700_009_999, 1_700_000_050),
            1_700_000_050_000
        );
    }

    // ---- `cursor_ms_for_window`: the only sanctioned advance computation.

    #[test]
    fn a_window_advance_is_the_local_open_time_not_any_event() {
        // The headline property: nothing an event carries appears in the result.
        assert_eq!(
            cursor_ms_for_window(1_700_000_000, None, 1_700_000_050),
            1_700_000_000_000
        );
    }

    #[test]
    fn a_hold_back_below_the_open_time_wins() {
        assert_eq!(
            cursor_ms_for_window(1_700_000_000, Some(1_699_999_000), 1_700_000_050),
            1_699_999_000_000,
            "an un-applied event must keep the cursor at (or below) itself so it \
             is re-requested"
        );
    }

    #[test]
    fn a_hold_back_can_never_raise_the_advance() {
        // The security direction, stated as arithmetic: this is the ONLY place a
        // remotely-chosen number enters the computation, and `min` confines it to
        // lowering the result. Both a near and an absurd attacker value.
        for forged in [1_700_000_001, i64::MAX] {
            assert_eq!(
                cursor_ms_for_window(1_700_000_000, Some(forged), 1_700_000_050),
                1_700_000_000_000,
                "a forged created_at of {forged} must not raise the advance",
            );
        }
    }

    #[test]
    fn a_window_advance_is_still_clamped_to_now() {
        // A fast local clock (or a caller passing a stale `now`) must not park
        // the cursor in the future, where `since_for_stream` pins every REQ floor
        // at `now` for the duration of the skew.
        let now = 1_000_i64;
        assert_eq!(cursor_ms_for_window(now + 10_000, None, now), now * 1000);
        assert_eq!(
            cursor_ms_for_window(now + 10_000, Some(now + 5_000), now),
            now * 1000
        );
    }

    #[test]
    fn a_window_advance_is_floored_at_zero() {
        // A hold-back of 0 (or a nonsensical negative, which a malformed
        // `created_at` could produce upstream) must never yield a negative
        // cursor: `since_for_stream` div_euclid's the stored value.
        assert_eq!(cursor_ms_for_window(1_000, Some(0), 2_000), 0);
        assert_eq!(cursor_ms_for_window(1_000, Some(-5), 2_000), 0);
        assert_eq!(cursor_ms_for_window(-5, None, 2_000), 0);
    }

    #[test]
    fn a_cursor_parked_in_the_future_pins_every_since_at_now() {
        // Why `cursor_ms_for_event` clamps at all: a future cursor does not
        // produce a future-dated filter (that is already capped) — it silently
        // pins the REQ floor at `now`, so nothing published before the fetch is
        // ever requested again. This asserts the failure mode the clamp removes.
        let now = 1_000_i64;
        let unclamped_future_cursor_ms = (now + 10_000) * 1000;
        assert_eq!(
            since_for_stream(
                STREAM_GROUP_445,
                unclamped_future_cursor_ms,
                SubscribePhase::Resubscribe,
                now
            ),
            now,
            "an unclamped future cursor collapses the lookback window entirely"
        );
        // With the clamp applied at write time the floor keeps its full buffer.
        let clamped = cursor_ms_for_event(now + 10_000, now);
        assert_eq!(
            since_for_stream(STREAM_GROUP_445, clamped, SubscribePhase::Resubscribe, now),
            now - GROUP_RESUBSCRIBE_BUFFER_SECS,
        );
    }

    #[test]
    fn group_initial_subtracts_10s() {
        // cursor 1_000_000 ms = 1_000_000 s; -10 = 999_990.
        let since = since_for_stream(
            STREAM_GROUP_445,
            1_000_000_000,
            SubscribePhase::Initial,
            NOW,
        );
        assert_eq!(since, 1_000_000 - 10);
    }

    #[test]
    fn group_resubscribe_subtracts_60s() {
        let since = since_for_stream(
            STREAM_GROUP_445,
            1_000_000_000,
            SubscribePhase::Resubscribe,
            NOW,
        );
        assert_eq!(since, 1_000_000 - 60);
    }

    #[test]
    fn inbox_initial_subtracts_seven_days() {
        // A cold start cannot know how long the process was gone, so it pays for
        // the widest replay we allow. Pinned by VALUE, not by "at least as wide
        // as the resubscribe one": the gift-wrap dedup retention
        // (`CircleStorage::PROCESSED_GIFT_WRAP_RETENTION_SECS`) is derived from
        // this number.
        assert_eq!(INBOX_GIFTWRAP_LOOKBACK_SECS, 7 * 86_400);
        let since = since_for_stream(
            STREAM_INBOX_1059,
            1_000_000_000, // 1_000_000 s
            SubscribePhase::Initial,
            NOW,
        );
        assert_eq!(since, 1_000_000 - 604_800);
    }

    #[test]
    fn inbox_resubscribe_subtracts_two_days_plus_one_hour() {
        // Every re-anchor — foreground resume, `CLOSED` repair, health tick —
        // lands here, so this is the number that runs constantly.
        assert_eq!(INBOX_RESUBSCRIBE_LOOKBACK_SECS, 2 * 86_400 + 3_600);
        let since = since_for_stream(
            STREAM_INBOX_1059,
            1_000_000_000, // 1_000_000 s
            SubscribePhase::Resubscribe,
            NOW,
        );
        assert_eq!(since, 1_000_000 - 176_400);
    }

    #[test]
    fn inbox_resubscribe_lookback_covers_nip59_backdating_plus_skew() {
        // Against the PINNED CRATE CONSTANT, not a literal: `RANGE_RANDOM_TIMESTAMP_TWEAK`
        // is what every rust-nostr sender actually subtracts from a wrap's
        // `created_at`, so a crate bump that widens it must fail here rather
        // than silently start dropping invitations.
        let max_backdate =
            i64::try_from(nostr::nips::nip59::RANGE_RANDOM_TIMESTAMP_TWEAK.end).unwrap();
        assert_eq!(max_backdate, 2 * 86_400);
        assert!(
            INBOX_RESUBSCRIBE_LOOKBACK_SECS > max_backdate,
            "the resubscribe lookback must exceed NIP-59's maximum backdate \
             ({max_backdate} s) STRICTLY: the excess is the whole clock-skew \
             margin, and at equality a sender one second slow is already lost"
        );
        assert_eq!(
            INBOX_RESUBSCRIBE_LOOKBACK_SECS - max_backdate,
            3_600,
            "and the margin is one hour — the residual documented on the \
             constant is derived from exactly this number"
        );
    }

    #[test]
    fn inbox_resubscribe_asks_for_a_strictly_narrower_window_than_initial() {
        // The successor to `inbox_subtracts_7_days_regardless_of_phase`, whose
        // phase-INDEPENDENCE claim this change reverses. The pair still has an
        // exact relationship, so it is still pinned exactly: same cursor, same
        // clock, and the two floors differ by the replay the bound removes.
        let cursor_ms = 1_000_000_000; // 1_000_000 s
        let initial = since_for_stream(STREAM_INBOX_1059, cursor_ms, SubscribePhase::Initial, NOW);
        let resub = since_for_stream(
            STREAM_INBOX_1059,
            cursor_ms,
            SubscribePhase::Resubscribe,
            NOW,
        );
        assert_eq!(
            resub - initial,
            INBOX_GIFTWRAP_LOOKBACK_SECS - INBOX_RESUBSCRIBE_LOOKBACK_SECS,
        );
        assert_eq!(
            resub - initial,
            428_400,
            "≈ 4.96 days of gift-wrap replay that no longer rides every \
             re-anchor — and the width of the window in which a cold start can \
             still recover a wrap a resubscribe missed"
        );
        assert!(
            resub > initial,
            "a resubscribe must ask for STRICTLY less history than a cold start"
        );
    }

    #[test]
    fn ms_cursor_is_converted_to_seconds() {
        // 10_000 ms = 10 s; initial group buffer 10 s → 0.
        let since = since_for_stream(STREAM_GROUP_445, 10_000, SubscribePhase::Initial, NOW);
        assert_eq!(since, 0);
    }

    #[test]
    fn since_is_floored_at_zero() {
        // Cursor smaller than the buffer must never go negative.
        let since = since_for_stream(STREAM_INBOX_1059, 1_000, SubscribePhase::Initial, NOW);
        assert_eq!(since, 0);
    }

    #[test]
    fn since_is_capped_to_now() {
        // A future-dated cursor (after subtracting the buffer) is clamped so the
        // filter bound never sits in the future.
        let now = 500_i64;
        let cursor_ms = 1_000_000 * 1000; // 1_000_000 s, far ahead of `now`
        let since = since_for_stream(STREAM_GROUP_445, cursor_ms, SubscribePhase::Initial, now);
        assert_eq!(since, now);
    }

    #[test]
    fn unknown_stream_is_treated_as_group() {
        let known = since_for_stream(
            STREAM_GROUP_445,
            1_000_000_000,
            SubscribePhase::Initial,
            NOW,
        );
        let unknown = since_for_stream(
            "some_future_stream",
            1_000_000_000,
            SubscribePhase::Initial,
            NOW,
        );
        assert_eq!(known, unknown);
    }

    #[test]
    fn inbox_future_cursor_is_capped_to_now() {
        // Even on the inbox branch, a cursor far ahead of `now` (after the 7d
        // subtract) must clamp to `now`, never a future-dated filter bound.
        let now = 1_000_i64;
        let cursor_ms = 10_000_000 * 1000; // 10_000_000 s, far ahead of now
        let since = since_for_stream(
            STREAM_INBOX_1059,
            cursor_ms,
            SubscribePhase::Resubscribe,
            now,
        );
        assert_eq!(since, now);
    }

    #[test]
    fn zero_cursor_yields_zero_since() {
        // An unseeded-but-zero cursor must floor at 0 on both streams, never
        // negative.
        assert_eq!(
            since_for_stream(STREAM_GROUP_445, 0, SubscribePhase::Initial, NOW),
            0
        );
        assert_eq!(
            since_for_stream(STREAM_INBOX_1059, 0, SubscribePhase::Resubscribe, NOW),
            0
        );
    }
}
