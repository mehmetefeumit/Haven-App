//! Re-issuing a REQ that a relay ended on us (`CLOSED`), with per-(relay, sub)
//! backoff.
//!
//! # Why anything has to be done at all
//!
//! nostr-relay-pool 0.44.3 (`relay/inner.rs::handle_relay_message`) reacts to a
//! `CLOSED` in one of two ways, chosen by the message's machine-readable prefix:
//!
//! * `rate-limited:` / `auth-required:` → `MarkAsClosed`. The subscription stays
//!   in the relay's table with `closed = true`, which makes `should_resubscribe`
//!   answer `true`, so the pool re-issues the REQ on its next socket reconnect.
//! * every other prefix — `duplicate:`, `pow:`, `blocked:`, `invalid:`,
//!   `error:`, `unsupported:`, `restricted:` — **and a `CLOSED` with no prefix
//!   at all** → `Remove`. The entry is deleted outright, and
//!   `should_resubscribe` answers `false` for a subscription that is not there.
//!   **Nothing upstream ever re-issues it**, not even on a later reconnect.
//!
//! The second case is a permanent, silent receive blackout: the socket stays
//! open and every relay reads `Connected`, so connection-based health sees a
//! healthy engine while the REQ that carried this device's circles is gone.
//! Repairing it is Haven's job, and this module is the policy half.
//!
//! # Bounded work (Security Rule 12)
//!
//! A relay chooses when to send `CLOSED` and what to name in it, so an
//! unthrottled "re-subscribe on every `CLOSED`" is a relay-driven amplifier.
//! Three things bound it:
//!
//! * only a `CLOSED` naming a subscription this session actually owns is ever
//!   recorded (the caller screens against the live router), so the key set is a
//!   subset of the live `(relay, sub)` pairs — a relay cannot grow this table by
//!   inventing ids;
//! * one pending re-issue per key, never a queue of them;
//! * an exponential, jittered per-key backoff, so a relay that `CLOSED`s every
//!   REQ the instant it is issued is met with 1 s, 2 s, 4 s … capped at
//!   [`BACKOFF_MAX_SECS`] — or, for an inbox REQ refused until this device
//!   authenticates, a minute doubling to an hour — not a hot loop.
//!
//! The table's size is therefore bounded by the session's live `(relay, sub)`
//! pairs — tens, not an attacker's choice — and that bound holds with no pruning
//! at all. [`RepairSchedule::take_due`] additionally drops fully decayed entries,
//! which narrows it further to the ACTIVE incidents; it runs only when the repair
//! task wakes, so an idle session can hold decayed entries until the next
//! `CLOSED`. That is deliberate: pruning on a read would mean mutating in
//! `next_deadline`, and the residue is bounded by the same live-pair count.
//!
//! # Privacy
//!
//! A [`RepairKey`] holds a relay url and a subscription id — the two things
//! Security Rules 4/6 keep out of logs — so its `Debug` is presence-only, and
//! the repair path logs counts, never keys.

use std::collections::HashMap;
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

use nostr::message::MachineReadablePrefix;
use nostr::{RelayUrl, SubscriptionId};
use rand::rngs::OsRng;
use rand::Rng;
use tokio::sync::Notify;

use crate::log_alias::bucket;

use super::config::{
    BACKOFF_JITTER_FRACTION_BP, BACKOFF_MAX_SECS, BACKOFF_MIN_SECS, GATED_BACKOFF_MAX_SECS,
    GATED_BACKOFF_MIN_SECS,
};

/// What a relay's `CLOSED` reason means for how soon the REQ may be re-issued.
///
/// The first two mirror nostr-relay-pool's own `HandleClosedMsg` exactly,
/// because that is what decides whether the pool kept the subscription:
/// re-issuing over a `MarkAsClosed` would race the pool's own reconnect replay
/// AND ignore a relay that just asked us, in machine-readable terms, to slow
/// down. The third is Haven's, for the inbox alone.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClosedKind {
    /// The pool DELETED the subscription and will never re-issue it. Haven must.
    Dropped,
    /// The pool kept it and only marked it closed (`rate-limited:` /
    /// `auth-required:`): the relay is throttling us, or wants a NIP-42 AUTH the
    /// engine deliberately never sends. Wait the full backoff.
    Throttled,
    /// The INBOX REQ, refused until this device authenticates
    /// ([`refuses_read`]). Haven never sends AUTH (Security Rule 16), so every
    /// re-issue is refused again until the relay's policy changes: wait the
    /// gated backoff, [`GATED_BACKOFF_MIN_SECS`] doubling to
    /// [`GATED_BACKOFF_MAX_SECS`]. Never a group REQ, whose recovery must stay
    /// within [`BACKOFF_MAX_SECS`].
    ReadGated,
}

/// Whether a `CLOSED` refuses the read itself: `auth-required:` or
/// `restricted:`, the prefixes a relay that gates a filter behind NIP-42 ends
/// the REQ with.
///
/// strfry puts its own `ERROR: ` ahead of the NIP-01 prefix — relay.damus.io
/// answers `ERROR: auth-required: requested filter requires authentication`
/// (probed 2026-11-16) — so one leading `error:` is skipped before the parse.
#[must_use]
pub fn refuses_read(message: &str) -> bool {
    let message = message
        .strip_prefix("ERROR:")
        .or_else(|| message.strip_prefix("error:"))
        .map_or(message, str::trim_start);
    matches!(
        MachineReadablePrefix::parse(message),
        Some(MachineReadablePrefix::AuthRequired | MachineReadablePrefix::Restricted)
    )
}

impl ClosedKind {
    /// Classifies a `CLOSED` message by its NIP-01 machine-readable prefix.
    #[must_use]
    pub fn classify(message: &str) -> Self {
        match MachineReadablePrefix::parse(message) {
            Some(MachineReadablePrefix::RateLimited | MachineReadablePrefix::AuthRequired) => {
                Self::Throttled
            }
            // Every `Remove` prefix, and — the default a plain relay sends — no
            // prefix at all.
            _ => Self::Dropped,
        }
    }
}

/// One live `(relay, subscription)` REQ: what a repair is scheduled against.
///
/// `Debug` is presence-only (Security Rules 4/6): the relay url identifies who
/// this device talks to and the sub-id is the per-session salted handle a log
/// must not join across records.
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct RepairKey {
    /// The relay whose socket ended the REQ.
    pub relay_url: RelayUrl,
    /// The subscription id it named.
    pub sub_id: SubscriptionId,
}

impl std::fmt::Debug for RepairKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RepairKey")
            .field("relay_url", &"<redacted>")
            .field("sub_id", &"<redacted>")
            .finish()
    }
}

/// One key's re-issue state.
#[derive(Debug, Clone, Copy)]
struct Entry {
    /// Consecutive re-issues; drives the exponential delay.
    attempts: u32,
    /// Earliest instant a re-issue for this key may go out.
    next_allowed_at: Instant,
    /// When the pending re-issue is due, or `None` if none is pending.
    due_at: Option<Instant>,
    /// A [`ClosedKind::ReadGated`] incident: its windows are the gated
    /// backoff's until it decays.
    gated: bool,
}

/// Per-`(relay, sub)` re-issue schedule.
///
/// Pure over an injected `now`, so the whole backoff policy is unit-testable
/// without a runtime, a clock, or a sleep.
#[derive(Debug, Default)]
pub(crate) struct RepairSchedule {
    entries: HashMap<RepairKey, Entry>,
}

impl RepairSchedule {
    /// Records a `CLOSED` for `key`, returning when its re-issue is due.
    ///
    /// A first (or fully decayed) `Dropped` incident is due immediately — the
    /// blackout it repairs is permanent, so the first repair must not be
    /// delayed. Everything else waits: a `Throttled` close waits the full
    /// [`BACKOFF_MAX_SECS`], a `ReadGated` one the gated backoff, and a close
    /// arriving inside a key's backoff window waits for that window to end. A
    /// second close while one is already pending changes nothing (one pending
    /// re-issue per key, never a queue).
    fn note_closed(&mut self, key: &RepairKey, kind: ClosedKind, now: Instant) -> Instant {
        let entry = self.entries.entry(key.clone()).or_insert(Entry {
            attempts: 0,
            next_allowed_at: now,
            due_at: None,
            gated: false,
        });

        // A key quiet for a full max-backoff past its window is a fresh
        // incident, not the continuation of an old storm: decay the attempts so
        // an occasional CLOSED does not inherit yesterday's 30 s delay.
        if entry.due_at.is_none() && now >= entry.next_allowed_at + entry.decay() {
            entry.attempts = 0;
            entry.next_allowed_at = now;
            entry.gated = false;
        }

        if let Some(due) = entry.due_at {
            return due;
        }

        let due = match kind {
            // Never EARLIER than the window an earlier incident already armed:
            // a `rate-limited:` close is a request to slow down, so it may only
            // ever push the re-issue further out, never pull it in.
            ClosedKind::Throttled => entry
                .next_allowed_at
                .max(now + jittered(Duration::from_secs(BACKOFF_MAX_SECS))),
            ClosedKind::Dropped => entry.next_allowed_at.max(now),
            ClosedKind::ReadGated => {
                entry.gated = true;
                entry.next_allowed_at.max(now + gated_delay(entry.attempts))
            }
        };
        entry.due_at = Some(due);
        due
    }

    /// Takes every key whose re-issue is due at `now`, arming each one's next
    /// backoff window, and prunes fully decayed entries.
    fn take_due(&mut self, now: Instant) -> Vec<RepairKey> {
        let mut due: Vec<RepairKey> = Vec::new();
        self.entries.retain(|key, entry| {
            if entry.due_at.is_some_and(|at| at <= now) {
                entry.due_at = None;
                entry.attempts = entry.attempts.saturating_add(1);
                entry.next_allowed_at = now
                    + if entry.gated {
                        gated_delay(entry.attempts)
                    } else {
                        backoff_delay(entry.attempts)
                    };
                due.push(key.clone());
                return true;
            }
            // Nothing pending and the window has fully decayed: the key carries
            // no state worth remembering, so it must not outlive its incident.
            entry.due_at.is_some() || now < entry.next_allowed_at + entry.decay()
        });
        due
    }

    /// The earliest pending due instant, if any (what the repair task sleeps to).
    fn next_deadline(&self) -> Option<Instant> {
        self.entries.values().filter_map(|e| e.due_at).min()
    }

    /// Keys with a re-issue still pending (diagnostics + tests).
    #[cfg(test)]
    fn pending_len(&self) -> usize {
        self.entries.values().filter(|e| e.due_at.is_some()).count()
    }
}

impl Entry {
    /// How long the key must stay quiet past its window to start over. A
    /// gated key decays only after a full hour: one that decayed sooner would
    /// let whoever paces its trigger (a flooder lagging the consumer) buy a
    /// whole inbox-lookback re-download every couple of minutes.
    const fn decay(&self) -> Duration {
        Duration::from_secs(if self.gated {
            GATED_BACKOFF_MAX_SECS
        } else {
            BACKOFF_MAX_SECS
        })
    }
}

/// The gated wait after `attempts` re-issues of one key:
/// [`GATED_BACKOFF_MIN_SECS`] doubling, capped at [`GATED_BACKOFF_MAX_SECS`],
/// jittered.
fn gated_delay(attempts: u32) -> Duration {
    // Saturating, not a shift: `60 << 62` wraps to zero, and a session up
    // for days reaches its 62nd refusal.
    let secs = GATED_BACKOFF_MIN_SECS
        .saturating_mul(2_u64.saturating_pow(attempts))
        .min(GATED_BACKOFF_MAX_SECS);
    jittered(Duration::from_secs(secs))
}

/// Exponential backoff for the `attempts`-th consecutive re-issue of one key,
/// jittered and capped at [`BACKOFF_MAX_SECS`].
fn backoff_delay(attempts: u32) -> Duration {
    let shift = attempts.saturating_sub(1).min(u32::BITS - 1);
    let secs = BACKOFF_MIN_SECS
        .checked_shl(shift)
        .unwrap_or(BACKOFF_MAX_SECS)
        .min(BACKOFF_MAX_SECS);
    jittered(Duration::from_secs(secs))
}

/// Samples `base` uniformly within `±BACKOFF_JITTER_FRACTION_BP`.
///
/// `OsRng` because the sample must be unpredictable to the relay that provoked
/// it (see [`BACKOFF_JITTER_FRACTION_BP`]); `thread_rng` is banned repo-wide.
fn jittered(base: Duration) -> Duration {
    let base_ms = u64::try_from(base.as_millis()).unwrap_or(u64::MAX);
    let spread = base_ms.saturating_mul(u64::from(BACKOFF_JITTER_FRACTION_BP)) / 10_000;
    if spread == 0 {
        return base;
    }
    let offset = OsRng.gen_range(0..=spread.saturating_mul(2));
    Duration::from_millis(base_ms.saturating_sub(spread).saturating_add(offset))
}

/// The shared, wakeable repair queue: a [`RepairSchedule`] plus the notification
/// the repair task parks on.
///
/// `Debug` is presence-only — it reports how many re-issues are pending, never
/// for which relay or subscription.
#[derive(Default)]
pub struct RepairQueue {
    schedule: Mutex<RepairSchedule>,
    wake: Notify,
    /// How many times the repair task has woken and evaluated this queue.
    ///
    /// The ONE thing that tells a PARKED repair task from a spinning one. This
    /// schedule is a backoff (see the module docs), so while the session is
    /// paused — when the gate defers every due entry without clearing its
    /// `due_at` — the task must wake once per notification and park again. A
    /// loop that re-polls an elapsed deadline instead burns a core for the whole
    /// pause while passing every functional assertion: nothing is re-issued,
    /// nothing is consumed, nothing is observable except battery.
    ///
    /// Counted unconditionally, so the loop a test observes is the loop that
    /// ships; only the accessor is test-only.
    wakeups: std::sync::atomic::AtomicU64,
    /// Relays that came up connected since the repair task last looked.
    reconnected: Mutex<Vec<RelayUrl>>,
    /// The live pool lost every relay and has one back, and the repair task
    /// has not acted on it yet ([`Self::note_network_back`]).
    network_back: std::sync::atomic::AtomicBool,
    /// How many times the network was said to be back, never reset: what a
    /// test reads to tell one edge from two.
    network_backs: std::sync::atomic::AtomicU64,
}

impl std::fmt::Debug for RepairQueue {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let pending = self
            .schedule
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .entries
            .values()
            .filter(|e| e.due_at.is_some())
            .count();
        f.debug_struct("RepairQueue")
            .field("pending", &bucket(pending))
            .finish_non_exhaustive()
    }
}

impl RepairQueue {
    /// Records a `CLOSED` for a subscription this session owns and wakes the
    /// repair task.
    ///
    /// The caller MUST have screened `key` against the live router first: a
    /// `CLOSED` naming an id we never issued must reach neither this table nor
    /// the relay again.
    pub(crate) fn note_closed(&self, key: &RepairKey, kind: ClosedKind) {
        self.schedule
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .note_closed(key, kind, Instant::now());
        // `notify_one` stores a permit when nobody is parked, so a close that
        // lands between the task's deadline read and its park is not lost.
        self.wake.notify_one();
    }

    /// Records a relay that came up connected and wakes the repair task, which
    /// re-issues alone each REQ of it the pool does not hold.
    pub(crate) fn note_reconnected(&self, relay_url: RelayUrl) {
        self.reconnected
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(relay_url);
        self.wake.notify_one();
    }

    /// Records that the live pool, having lost every relay while live, has
    /// one back, and wakes the repair task, which makes every relay a pending
    /// record could not reach due again at most once a minute
    /// (`EngineProcessor::network_back`).
    pub(crate) fn note_network_back(&self) {
        self.network_backs
            .fetch_add(1, std::sync::atomic::Ordering::AcqRel);
        self.network_back
            .store(true, std::sync::atomic::Ordering::Release);
        self.wake.notify_one();
    }

    /// Whether the network came back since the last call.
    pub(crate) fn take_network_back(&self) -> bool {
        self.network_back
            .swap(false, std::sync::atomic::Ordering::AcqRel)
    }

    /// How many times the network was said to be back (tests only).
    #[cfg(test)]
    pub(crate) fn network_backs(&self) -> u64 {
        self.network_backs
            .load(std::sync::atomic::Ordering::Acquire)
    }

    /// The relays that came up connected since the last call.
    pub(crate) fn take_reconnected(&self) -> Vec<RelayUrl> {
        std::mem::take(
            &mut *self
                .reconnected
                .lock()
                .unwrap_or_else(PoisonError::into_inner),
        )
    }

    /// Keys whose re-issue is due now, each armed with its next backoff window.
    pub(crate) fn take_due(&self) -> Vec<RepairKey> {
        self.schedule
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take_due(Instant::now())
    }

    /// The earliest pending due instant (what the repair task sleeps to).
    pub(crate) fn next_deadline(&self) -> Option<Instant> {
        self.schedule
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .next_deadline()
    }

    /// Parks until a `CLOSED` is recorded.
    pub(crate) async fn wake(&self) {
        self.wake.notified().await;
    }

    /// Drops every scheduled re-issue.
    ///
    /// Called when the session PAUSES. A background burst re-issues every REQ
    /// under a fresh anchor generation by construction, so a repair that fired
    /// after the burst opened would replace a live REQ and reset its generation
    /// mid-burst — the anchor would then vouch for a window the burst's own REQ
    /// never asked for. Dropping the queue costs only the `next_allowed_at`
    /// throttle of a `rate-limited:` close, which today's `resume_after_background`
    /// already ignores for the same reason.
    ///
    /// The schedule is derived state — every entry came from a `CLOSED` on a REQ
    /// the next burst re-issues anyway — so clearing it can lose no delivery.
    pub(crate) fn clear(&self) {
        self.schedule
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .entries
            .clear();
        self.reconnected
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clear();
        self.network_back
            .store(false, std::sync::atomic::Ordering::Release);
    }

    /// Records one wake of the repair task (see [`Self::wakeups`]).
    pub(crate) fn note_wakeup(&self) {
        self.wakeups
            .fetch_add(1, std::sync::atomic::Ordering::AcqRel);
    }

    /// How many times the repair task has woken (tests only).
    #[cfg(test)]
    pub(crate) fn wakeups(&self) -> u64 {
        self.wakeups.load(std::sync::atomic::Ordering::Acquire)
    }

    /// Re-issues still pending (tests only).
    #[cfg(test)]
    pub(crate) fn pending_len(&self) -> usize {
        self.schedule
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .pending_len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(relay: &str, sub: &str) -> RepairKey {
        RepairKey {
            relay_url: RelayUrl::parse(relay).unwrap(),
            sub_id: SubscriptionId::new(sub),
        }
    }

    #[test]
    fn a_closed_with_no_prefix_is_the_dropped_case() {
        // The default a plain relay sends, and the one nostr-relay-pool deletes
        // the subscription for — so it is the case Haven MUST repair. Reading it
        // as merely throttled would leave the blackout in place for the full max
        // backoff on every incident.
        assert_eq!(ClosedKind::classify(""), ClosedKind::Dropped);
        assert_eq!(ClosedKind::classify("closed"), ClosedKind::Dropped);
    }

    #[test]
    fn every_pool_remove_prefix_classifies_as_dropped() {
        for m in [
            "duplicate: already have this",
            "pow: difficulty too low",
            "blocked: you are banned",
            "invalid: bad filter",
            "error: internal",
            "unsupported: filter not supported",
            "restricted: not authorized",
        ] {
            assert_eq!(
                ClosedKind::classify(m),
                ClosedKind::Dropped,
                "nostr-relay-pool REMOVES the subscription for {m:?}, so nothing \
                 upstream re-issues it"
            );
        }
    }

    #[test]
    fn the_two_pool_mark_as_closed_prefixes_classify_as_throttled() {
        assert_eq!(
            ClosedKind::classify("rate-limited: slow down"),
            ClosedKind::Throttled
        );
        assert_eq!(
            ClosedKind::classify("auth-required: we need an AUTH"),
            ClosedKind::Throttled
        );
    }

    #[test]
    fn a_first_dropped_close_is_due_immediately() {
        // The blackout a `Remove` CLOSED leaves is permanent, so the FIRST
        // repair must not be delayed by a backoff that exists only to bound a
        // storm.
        let mut s = RepairSchedule::default();
        let now = Instant::now();
        assert_eq!(
            s.note_closed(&key("wss://a.example", "s0"), ClosedKind::Dropped, now),
            now
        );
        assert_eq!(s.take_due(now).len(), 1, "it must be taken at that instant");
    }

    #[test]
    fn a_second_close_inside_the_backoff_window_does_not_re_issue() {
        // The Rule-12 bound: a relay that CLOSEs every REQ the instant it is
        // issued must not be able to make Haven hammer it.
        let mut s = RepairSchedule::default();
        let k = key("wss://a.example", "s0");
        let t0 = Instant::now();

        assert_eq!(s.note_closed(&k, ClosedKind::Dropped, t0), t0);
        assert_eq!(s.take_due(t0).len(), 1);

        // Immediately CLOSED again: recorded, but NOT due yet.
        let due = s.note_closed(&k, ClosedKind::Dropped, t0);
        assert!(
            due > t0,
            "a close inside the window must be deferred, not re-issued"
        );
        assert!(
            s.take_due(t0).is_empty(),
            "no re-issue may go out inside the backoff window"
        );
        assert_eq!(s.pending_len(), 1, "...but it stays pending, not dropped");

        // Once the window elapses it is taken exactly once.
        let after = due + Duration::from_millis(1);
        assert_eq!(s.take_due(after).len(), 1);
        assert!(s.take_due(after).is_empty(), "a due re-issue is taken once");
    }

    #[test]
    fn repeated_closes_back_off_exponentially_up_to_the_cap() {
        let mut s = RepairSchedule::default();
        let k = key("wss://a.example", "s0");
        let mut now = Instant::now();
        let mut previous = Duration::ZERO;

        for i in 0..12 {
            let due = s.note_closed(&k, ClosedKind::Dropped, now);
            let waited = due.saturating_duration_since(now);
            now = due;
            assert_eq!(s.take_due(now).len(), 1);
            if i >= 1 {
                // Jitter is ±25%, so consecutive nominal doublings cannot cross:
                // the growth is monotone until the cap.
                assert!(
                    waited >= previous || waited >= Duration::from_secs(BACKOFF_MAX_SECS) * 3 / 4,
                    "attempt {i}: {waited:?} must not shrink below {previous:?} before the cap"
                );
            }
            assert!(
                waited <= Duration::from_secs(BACKOFF_MAX_SECS) * 5 / 4,
                "attempt {i}: {waited:?} must never exceed the jittered cap"
            );
            previous = waited;
        }
    }

    #[test]
    fn a_rate_limited_close_waits_the_full_max_backoff_before_re_issuing() {
        // A relay saying `rate-limited:` KEPT the subscription (the pool only
        // marks it closed and replays it on reconnect), so re-issuing now would
        // both race that replay and ignore an explicit machine-readable request
        // to slow down.
        let mut s = RepairSchedule::default();
        let k = key("wss://a.example", "s0");
        let now = Instant::now();

        let due = s.note_closed(&k, ClosedKind::Throttled, now);
        assert!(
            s.take_due(now).is_empty(),
            "a throttled close must never re-issue immediately"
        );
        let waited = due.saturating_duration_since(now);
        let cap = Duration::from_secs(BACKOFF_MAX_SECS);
        assert!(
            waited >= cap * 3 / 4 && waited <= cap * 5 / 4,
            "a throttled close waits the jittered max backoff, got {waited:?}"
        );
    }

    #[test]
    fn only_auth_required_and_restricted_refuse_the_read() {
        for m in [
            "auth-required: requested filter requires authentication",
            "restricted: not your inbox",
            // relay.damus.io's own words, strfry's `ERROR: ` and all.
            "ERROR: auth-required: requested filter requires authentication",
            "error: restricted: not your inbox",
        ] {
            assert!(refuses_read(m), "{m:?}");
        }
        for m in [
            "",
            "closed",
            "rate-limited: slow down",
            "error: shutting down",
            "ERROR: rate-limited: slow down",
            "ERROR: ERROR: auth-required: twice",
            "blocked: you are banned",
            "invalid: bad filter",
        ] {
            assert!(!refuses_read(m), "{m:?}");
        }
    }

    /// Haven never authenticates, so a gated relay refuses every re-issue:
    /// a minute, doubling, capped at an hour — never the 30 s throttle,
    /// which would ask a relay that has said no a hundred and twenty times an
    /// hour.
    #[test]
    fn a_read_gated_key_backs_off_from_a_minute_to_an_hour() {
        let mut s = RepairSchedule::default();
        let k = key("wss://a.example", "s_inbox");
        let mut now = Instant::now();
        let (min, max) = (
            Duration::from_secs(GATED_BACKOFF_MIN_SECS),
            Duration::from_secs(GATED_BACKOFF_MAX_SECS),
        );
        let mut waits = Vec::new();
        for _ in 0..10 {
            let due = s.note_closed(&k, ClosedKind::ReadGated, now);
            assert!(
                s.take_due(now).is_empty(),
                "never re-issued before its wait"
            );
            waits.push(due.saturating_duration_since(now));
            now = due;
            assert_eq!(s.take_due(now).len(), 1);
        }
        assert!(
            waits[0] >= min * 3 / 4 && waits[0] <= min * 5 / 4,
            "the first refusal waits a jittered minute: {waits:?}"
        );
        for pair in waits.windows(2) {
            assert!(
                pair[1] >= pair[0] || pair[1] >= max * 3 / 4,
                "the wait never shrinks before the cap: {waits:?}"
            );
        }
        assert!(
            waits.iter().all(|w| *w <= max * 5 / 4),
            "the wait never passes the jittered hour: {waits:?}"
        );
        assert!(
            waits[9] >= max * 3 / 4,
            "ten refusals in, the wait is the hour: {waits:?}"
        );
    }

    /// A relay that keeps refusing for days must never be asked at once
    /// again: the wait stays the hour however many refusals came before.
    #[test]
    fn the_gated_wait_stays_the_hour_however_many_refusals_came_before() {
        let max = Duration::from_secs(GATED_BACKOFF_MAX_SECS);
        for attempts in [6, 58, 61, 62, 63, 64, 1_000, u32::MAX] {
            let wait = gated_delay(attempts);
            assert!(
                wait >= max * 3 / 4 && wait <= max * 5 / 4,
                "{attempts} refusals: {wait:?}"
            );
        }
    }

    /// A trigger paced just past the throttle's 30 s decay must not restart
    /// the gated wait at a minute: only an hour's quiet does.
    #[test]
    fn a_read_gated_key_decays_only_after_an_hours_quiet() {
        let mut s = RepairSchedule::default();
        let k = key("wss://a.example", "s_inbox");
        let t0 = Instant::now();
        let first = s.note_closed(&k, ClosedKind::ReadGated, t0);
        assert_eq!(s.take_due(first).len(), 1);

        let paced = first + Duration::from_secs(GATED_BACKOFF_MIN_SECS * 4);
        let second = s.note_closed(&k, ClosedKind::ReadGated, paced);
        assert!(
            second.saturating_duration_since(paced)
                >= Duration::from_secs(GATED_BACKOFF_MIN_SECS * 2) * 3 / 4,
            "a gated key re-triggered within the hour keeps doubling"
        );
        assert_eq!(s.take_due(second).len(), 1);

        let quiet = second + Duration::from_secs(GATED_BACKOFF_MAX_SECS * 3);
        let fresh = s.note_closed(&k, ClosedKind::ReadGated, quiet);
        assert!(
            fresh.saturating_duration_since(quiet)
                <= Duration::from_secs(GATED_BACKOFF_MIN_SECS) * 5 / 4,
            "a gated key quiet for hours starts over at a minute"
        );
    }

    #[test]
    fn a_key_quiet_past_a_full_decay_starts_over_at_no_delay() {
        // Otherwise one bad afternoon would leave every later single CLOSED
        // waiting 30 s before the receive plane came back.
        let mut s = RepairSchedule::default();
        let k = key("wss://a.example", "s0");
        let t0 = Instant::now();
        for _ in 0..6 {
            let due = s.note_closed(&k, ClosedKind::Dropped, t0);
            let _ = s.take_due(due);
        }

        let long_after = t0 + Duration::from_secs(BACKOFF_MAX_SECS * 4);
        assert_eq!(
            s.note_closed(&k, ClosedKind::Dropped, long_after),
            long_after,
            "a decayed key must be repaired immediately again"
        );
    }

    #[test]
    fn a_decayed_key_with_nothing_pending_is_pruned() {
        // The table's keys are bounded by the live (relay, sub) pairs, but a
        // session that outlives many subscription generations must not keep
        // their corpses.
        let mut s = RepairSchedule::default();
        let k = key("wss://a.example", "s0");
        let t0 = Instant::now();
        let due = s.note_closed(&k, ClosedKind::Dropped, t0);
        assert_eq!(s.take_due(due).len(), 1);
        assert_eq!(s.entries.len(), 1);

        let _ = s.take_due(t0 + Duration::from_secs(BACKOFF_MAX_SECS * 4));
        assert!(s.entries.is_empty(), "a fully decayed key must be pruned");
    }

    #[test]
    fn keys_are_independent_per_relay_and_per_subscription() {
        // A CLOSED from one relay must never throttle the repair of another
        // relay's REQ (nor of a different sub on the same relay) — that would
        // let one hostile relay suppress the whole receive plane's healing.
        let mut s = RepairSchedule::default();
        let now = Instant::now();
        let a = key("wss://a.example", "s0");
        let b = key("wss://b.example", "s0");
        let c = key("wss://a.example", "s1");

        for k in [&a, &b, &c] {
            assert_eq!(s.note_closed(k, ClosedKind::Dropped, now), now);
        }
        assert_eq!(s.take_due(now).len(), 3);
    }

    #[test]
    fn next_deadline_is_the_earliest_pending_re_issue() {
        let mut s = RepairSchedule::default();
        let now = Instant::now();
        assert!(s.next_deadline().is_none(), "nothing pending ⇒ no deadline");

        s.note_closed(&key("wss://a.example", "s0"), ClosedKind::Throttled, now);
        s.note_closed(&key("wss://b.example", "s0"), ClosedKind::Dropped, now);
        assert_eq!(
            s.next_deadline(),
            Some(now),
            "the immediate one must win over the throttled one"
        );
    }

    #[test]
    fn repair_key_and_repair_queue_debug_redacts_relay_and_sub_id() {
        let k: RepairKey = key("wss://secret-relay.example", "s_group_0_SECRETSUB");
        let dbg = format!("{k:?}");
        assert!(!dbg.contains("wss://"), "leaked relay scheme: {dbg}");
        crate::assert_debug_redacted!(
            k,
            "RepairKey",
            &["secret-relay.example", "s_group_0_SECRETSUB"]
        );

        // How many REQs are awaiting repair is a relay-set magnitude, so the
        // queue reports a bucket rather than a count (Rule 15).
        let q = RepairQueue::default();
        q.note_closed(&k, ClosedKind::Dropped);
        assert!(format!("{q:?}").contains("pending: \"1\""));
        for n in 0..5 {
            q.note_closed(
                &key("wss://b.example", &format!("s{n}")),
                ClosedKind::Dropped,
            );
        }
        let dbg = format!("{q:?}");
        assert!(
            dbg.contains("pending: \"5+\""),
            "six pending repairs must render as the 5+ bucket: {dbg}"
        );
        crate::assert_debug_redacted!(
            q,
            "RepairQueue",
            &["secret-relay.example", "s_group_0_SECRETSUB"]
        );
    }

    #[tokio::test]
    async fn the_queue_wakes_a_parked_repair_task_and_hands_it_the_key() {
        // `notify_one` stores a permit, so a CLOSED recorded before the task
        // parks is not lost — the wedge a `Notify::notified()` created too late
        // would produce.
        let q = RepairQueue::default();
        let k = key("wss://a.example", "s0");
        q.note_closed(&k, ClosedKind::Dropped);

        tokio::time::timeout(Duration::from_secs(2), q.wake())
            .await
            .expect("a close recorded before the park must still wake the task");
        assert_eq!(q.take_due(), vec![k]);
    }
}
