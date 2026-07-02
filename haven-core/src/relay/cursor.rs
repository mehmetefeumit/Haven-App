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
//! - **Inbox (`kind:1059`)**: a 7-day buffer ([`INBOX_GIFTWRAP_LOOKBACK_SECS`])
//!   applied to **every** REQ, because NIP-59 gift wraps are deliberately
//!   backdated by up to ±48h, so a freshly-delivered invitation can carry a
//!   `created_at` well before the cursor.
//!
//! All derived `since` values are floored at `0` and capped to the caller's
//! `now`, so a corrupt or future cursor can never produce a future-dated or
//! negative filter bound.

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

/// Gift-wrap lookback (seconds, 7 days) applied to the inbox cursor on every
/// REQ. Covers NIP-59's ±48h timestamp randomization plus a wide margin so a
/// backdated invitation is never filtered out.
pub const INBOX_GIFTWRAP_LOOKBACK_SECS: i64 = 604_800;

/// Which phase a (re)subscription is being issued in.
///
/// Only affects the group-stream buffer width; the inbox buffer is
/// phase-independent.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SubscribePhase {
    /// First subscription of a session (narrow group buffer).
    Initial,
    /// Re-subscription after a teardown / reconnect (wide group buffer).
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

/// Derives the REQ `since` (unix seconds) for `stream` from its persisted
/// cursor.
///
/// `cursor_ms` is the raw last-synced timestamp in **milliseconds**, exactly
/// as stored by [`crate::circle::storage::CircleStorage::read_sync_cursor`].
/// The per-stream lookback buffer (see the module docs) is subtracted, the
/// result is floored at `0`, then capped to `now_secs`.
///
/// `stream` is matched against [`STREAM_INBOX_1059`]; every other key
/// (including [`STREAM_GROUP_445`]) is treated as a group stream and uses the
/// phase-dependent group buffer.
///
/// # Examples
///
/// ```
/// use haven_core::relay::cursor::{since_for_stream, SubscribePhase, STREAM_GROUP_445};
///
/// // Cursor at 10_000 ms (= 10 s); initial group buffer of 10 s → since 0.
/// let since = since_for_stream(STREAM_GROUP_445, 10_000, SubscribePhase::Initial, 1_000);
/// assert_eq!(since, 0);
/// ```
#[must_use]
pub fn since_for_stream(stream: &str, cursor_ms: i64, phase: SubscribePhase, now_secs: i64) -> i64 {
    // Floor-divide so a (non-negative) ms cursor maps to whole seconds; nostr
    // filter granularity is one second.
    let cursor_secs = cursor_ms.div_euclid(1000);

    let buffer = if stream == STREAM_INBOX_1059 {
        INBOX_GIFTWRAP_LOOKBACK_SECS
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
    fn inbox_subtracts_7_days_regardless_of_phase() {
        let cursor_ms = 1_000_000_000; // 1_000_000 s
        let initial = since_for_stream(STREAM_INBOX_1059, cursor_ms, SubscribePhase::Initial, NOW);
        let resub = since_for_stream(
            STREAM_INBOX_1059,
            cursor_ms,
            SubscribePhase::Resubscribe,
            NOW,
        );
        assert_eq!(initial, 1_000_000 - INBOX_GIFTWRAP_LOOKBACK_SECS);
        assert_eq!(
            initial, resub,
            "inbox buffer must be phase-independent (7-day lookback always)"
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
