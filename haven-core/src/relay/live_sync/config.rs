//! Compile-time tuning constants for the persistent live-sync engine. They live
//! in one module so a tuning pass touches a single file.
//!
//! Most are reasoned defaults. A few carry LATENCY figures from M11's P-15
//! propagation probe (2026-07-11), and those are **HISTORICAL**: the two suites
//! that produced them — `tests/settle_window_tuning_test.rs` and
//! `tests/settle_window_real_relay_test.rs` — are `DELETED-WITH-SUBJECT`
//! tombstones under Dark Matter (DM-5a), so nothing in this tree reproduces
//! them and no CI lane re-measures them. This header said "not yet empirically
//! measured" while the body below said "measured 2026-07-11"; both readings
//! were wrong, and the honest one is that the numbers were real when taken and
//! have had no instrument behind them since.

/// Capacity of the internal `LiveSyncEvent` broadcast bus.
///
/// Sized well above any realistic per-second event rate so a momentarily slow
/// consumer (e.g. the Dart `StreamSink`) lags rather than blocks the producer.
/// A lagging consumer is recoverable (the cursor + catch-up replay any skipped
/// event); a blocked producer would stall the whole receive path.
pub const BUS_CAP: usize = 8192;

/// The live plane's Security Rule 12 intake cap.
///
/// Capacity of the bounded receive→decrypt channel between the supervisor's
/// notifications receiver and its decrypt worker, built by
/// [`super::supervisor::intake_queue`].
///
/// Sized to absorb a burst while a slow `SQLCipher` decrypt runs; on overflow
/// the receiver's `try_send` drops the DELIVERY (never blocking the pool) and
/// holds the dropped `kind:445`'s circle at its `created_at`, so the next REQ
/// asks for it again.
///
/// That hold-back is what makes the cap a THROTTLE rather than a discard, and
/// it is not optional. A cursor advance is anchored on the subscription's own
/// REQ open time, so a drop that left no trace would simply be covered by the
/// generation's `EOSE` — and the catch-up sweep re-derives its floor from that
/// SAME per-circle cursor, only [`GROUP_RESUBSCRIBE_BUFFER_SECS`] below it. An
/// event dropped out of an older backlog replay — which is exactly what
/// overflows this queue — would then be re-requested by no plane at all: the
/// silent loss of legitimate offline backlog Rule 12 forbids.
///
/// The cap is still sized so the drop does not happen rather than relied on to
/// be free when it does: a hold-back costs the whole window a re-fetch. Kept
/// independent of [`BUS_CAP`] so the decouple buffer can be tuned separately
/// (M11).
///
/// [`GROUP_RESUBSCRIBE_BUFFER_SECS`]: crate::relay::cursor::GROUP_RESUBSCRIBE_BUFFER_SECS
pub const WORKER_QUEUE_CAP: usize = 8192;

/// Capacity of the nostr pool's notification broadcast channel.
///
/// Matches [`BUS_CAP`]: the raw notifications receiver must not lag while a slow
/// `SQLCipher` decrypt runs, so the receive loop is decoupled from decrypt and
/// the channel is sized generously.
pub const POOL_NOTIF_CAP: usize = 8192;

/// How long (seconds) a settle window stays open after our commit is staged,
/// collecting same-epoch competitor commits before the caller runs convergence.
///
/// Chosen above typical relay propagation (< 2 s) and below the membership
/// commit latency budget, and shorter than the group `since` buffer.
///
/// FORK-SAFETY, not merely latency. For CONCURRENT COMMITTERS (regime 2 — e.g.
/// two admins staging same-epoch commits) the window is a CORRECTNESS
/// prerequisite. If one admin's window closes empty while a peer's concurrent
/// commit is still in flight, that admin eager-merges its own commit through
/// [`crate::circle::CircleManager::converge_commit`]'s empty-competitor leg;
/// `merge_pending_commit` writes NO epoch snapshot, so MDK's native
/// `is_better_candidate` rollback can never fire on the peer commit that arrives
/// later, and the two `N+1` branches fork PERMANENTLY — a twin with the same
/// epoch number and member set but a different exporter secret, so cross-decrypt
/// fails. Only when the window COLLECTS the competitor and feeds it to
/// `converge_commit` do the admins converge (the loser adopts the winner). The
/// window MUST therefore be `>= 2x` the p99 commit propagation — the framing in
/// `docs/M11_ROLLOUT.md` §7/§H2, NOT the earlier "latency optimization" wording,
/// is correct.
///
/// **All of the above is PRE-DARK-MATTER and no longer describes this
/// constant.** Haven's own commit settle window is deleted: the engine owns
/// convergence, Haven installs `settlement_quiescence_ms = 0`
/// (`crate::nostr::mls::manager::session_convergence_policy`, which explains
/// why), `converge_commit` is gone with it, and both tests this paragraph used
/// to cite —
/// `rev1_or_m11_two_admin_window_miss_forks_but_in_window_converges` and
/// `no_pending_observers_converge_on_sibling_commits_via_native_rollback` — no
/// longer exist. Deterministic `CommitOrderingKey` branch selection plus durable
/// out-of-order buffering replaced the window, and the surviving convergence
/// proof is
/// `live_sync_two_engine_converge_e2e::two_engines_converge_over_one_relay_via_the_engine_loop`.
/// What `8 s` bounds TODAY is a background burst's socket lifetime after the last
/// commit activity — `session::BURST_SETTLE_WINDOW`, fed to
/// `settle_before_pause_with` — so the reasoning to re-derive it from is burst
/// liveness, not fork safety. Rewriting that derivation is a separate change;
/// this note exists so nobody reads the paragraphs above as current.
///
/// # HISTORICAL propagation figures (P-15 / A6) — why `8` was defensible
///
/// **Both instruments below are gone.** `tests/settle_window_tuning_test.rs` and
/// `tests/settle_window_real_relay_test.rs` are `DELETED-WITH-SUBJECT`
/// tombstones (Dark Matter, DM-5a) — 13- and 23-line headers, no probe, no
/// assertions. Nothing in this tree reproduces the percentiles below and no CI
/// lane re-measures them, so they are a record of a run on 2026-07-11 and not a
/// property this repo still checks. They are kept because they are the only
/// evidence the value was ever sized against a relay; do not restate them
/// anywhere as current.
///
/// The value sat in the band `[2x p99 propagation, membership-op UX ceiling]`,
/// at two relay tiers:
///
/// * the in-process probe: p50 ~= 2-3 ms, p99 ~= 3-5 ms. A loopback LOWER BOUND
///   (an in-process relay cannot inject WAN fan-out latency) — it only showed
///   `8 s` dwarfs the fastest-possible pipeline, not that it clears real
///   propagation.
/// * the real-relay probe, then the authoritative one (env-gated on
///   `HAVEN_E2E_RELAY`, never run by a CI lane): the SAME probe through a real
///   `strfry` daemon gave p50 ~= 104 ms, p99 ~= 106 ms, so `2x p99 ~= 212 ms`
///   and the `8000 ms` window cleared it by ~38x (host-local strfry, debug
///   build, idle single subscriber, n=100 x3, tightly clustered).
///
/// That sample includes strfry's real ingest->match->broadcast plus WebSocket
/// framing but NOT wide-area RTT or relay fan-out under load. Those terms only
/// widen p99, and the margin absorbs them generously: a congested `+1 s` RTT gives
/// `2x p99 ~= 2.2 s` (~3.6x under the `8 s` window); a severe `+2 s` gives
/// `2x p99 ~= 4.2 s`, still satisfying the fork-safety inequality `window > 2x p99`
/// (`8 s` vs `4.2 s`, ~1.9x margin). So `8 s` held its `>= 2x` margin over
/// realistic propagation while staying below the ~10 s window ceiling that keeps
/// window + publish + converge within a responsive add/remove (~<= 12 s). Do NOT
/// lower it; revisit upward only against a p99 someone has actually sampled,
/// which today means writing a new probe, because the old one cannot be re-run.
/// Note also that the ~10 s ceiling is reasoning and nothing more: NO
/// const-assert bounds this constant from above (the two that name it —
/// `STOP_DRAIN_TIMEOUT_SECS <` and `BURST_SETTLE_CAP_SECS >= ... + 10` — only
/// relate it to two other constants). This doc used to cite a `<= 10`
/// const-assert as the always-on backstop; there has never been one.
pub const COMMIT_SETTLE_WINDOW_SECS: u64 = 8;

/// Upper bound (seconds) on a single engine relay control-plane op before the
/// engine gives up on a wedged pool call.
///
/// Covers `subscribe_with_id_to`, `unsubscribe_all`, and `client.shutdown`.
/// Mirrors the engine's publish timeout magnitude (10 s) and is 2x the 5 s
/// transport `CONNECTION_TIMEOUT`. These ops are local in nostr-sdk 0.44 (a
/// non-blocking channel `try_send` + an in-memory lock update), so a legitimate
/// call completes in << 1 s; 10 s is pure headroom that never trips a working
/// relay while bounding a true internal wedge. Defense-in-depth + consistency
/// with the publish timeout; REVISIT UPWARD only if the SDK is upgraded to a
/// version where subscribe awaits relay confirmation.
pub const RELAY_LIFECYCLE_OP_TIMEOUT_SECS: u64 = 10;

/// Handshake grace (seconds) after `connect()` and before the first REQ.
///
/// The engine waits this long for relay WebSocket handshakes to finish AFTER
/// [`nostr_sdk::Client::connect`] (which only *spawns* per-relay connect tasks
/// and returns immediately) and BEFORE issuing the first subscription REQ.
///
/// `connect()` is fire-and-forget, so a REQ sent right after can hit a relay
/// still mid-handshake; that relay's per-relay send then lands in the subscribe
/// `Output.failed` set while the overall call still returns `Ok` — silently
/// orphaning the subscription. This is a BOUNDED WAIT via
/// [`nostr_sdk::Client::wait_for_connection`], which RETURNS EARLY as soon as the
/// relays connect, giving the handshake time to complete so the first REQ has a
/// live socket. It bounds a wait, NEVER the subscribe call itself — a bound on
/// the `verify_subscriptions` cold subscribe previously regressed engine start
/// (run b7dba45) — so it cannot reintroduce that regression.
///
/// Sized to the transport `CONNECTION_TIMEOUT` (5 s, `relay::manager`): enough
/// for a cold WebSocket handshake on a slow CI emulator. On the happy path
/// (relays already connected) `wait_for_connection` returns in << 1 s.
pub const SUBSCRIBE_CONNECT_WAIT_SECS: u64 = 5;

/// Per-retry connection wait (seconds) between subscribe attempts in
/// [`super::LiveSyncCore`]'s bucket subscribe.
///
/// When a subscribe returns an EMPTY `Output.success` set (every relay in the
/// bucket dropped the REQ mid-handshake), the engine waits this long — again via
/// [`nostr_sdk::Client::wait_for_connection`], which returns early once connected
/// — for the sockets to finish before re-issuing the REQ. Shorter than
/// [`SUBSCRIBE_CONNECT_WAIT_SECS`] because that initial wait already absorbed the
/// bulk of a cold handshake; a retry only needs to cover the tail.
pub const SUBSCRIBE_RETRY_WAIT_SECS: u64 = 2;

/// Maximum subscribe attempts per bucket before the engine gives up.
///
/// On exhaustion the engine returns [`super::LiveSyncError::Relay`], so the
/// caller's teardown surfaces a VISIBLE failure instead of a silently orphaned
/// circle.
///
/// Bounded work: at most `N` LOCAL subscribe calls interleaved with `N − 1`
/// [`SUBSCRIBE_RETRY_WAIT_SECS`] waits (each early-returning on connect), so the
/// worst case adds only `~(N − 1) × SUBSCRIBE_RETRY_WAIT_SECS` — no unbounded
/// hang. Three attempts tolerate two lost REQs (a very slow cold reconnect)
/// while keeping the give-up latency small.
pub const SUBSCRIBE_MAX_ATTEMPTS: u32 = 3;

/// A bucket subscribe must attempt at least once.
const _: () = assert!(SUBSCRIBE_MAX_ATTEMPTS >= 1);

/// Upper bound (seconds) [`super::LiveSyncCore::stop`] waits for in-flight
/// path-B converge tasks to wind down before proceeding best-effort.
///
/// Once a task's settle wait is interrupted it only needs to acquire the
/// per-circle gate + run the network-free MDK converge (sub-second), so 3 s is
/// ample headroom while keeping logout/teardown/session-replace snappy. On
/// timeout `stop` proceeds: an escaped task's writes are fork-safe — the single
/// process-global `SessionManager` (`tokio::sync::Mutex<AccountDeviceSession>`,
/// Rule 14) serializes all MLS writes into one epoch lineage (a raced late
/// converge degrades to `RolledBack`/retryable, never a fork). Kept below
/// `COMMIT_SETTLE_WINDOW_SECS` so a (precluded) missed interrupt degrades to a
/// 3 s wait, never the full window.
pub const STOP_DRAIN_TIMEOUT_SECS: u64 = 3;

/// The drain must not itself outlast the settle window it interrupts.
const _: () = assert!(STOP_DRAIN_TIMEOUT_SECS < COMMIT_SETTLE_WINDOW_SECS);

/// Extra grace (seconds) after a settle window's deadline before it is pruned,
/// so a competitor arriving slightly late is not lost to an eager prune.
pub const SETTLE_WINDOW_TTL_SECS: i64 = 30;

/// Upper bound on competitor commits retained per settle window.
///
/// A memory-safety guard against a relay/peer flooding forged competitors; it
/// is **not** a correctness mechanism (convergence re-validates every retained
/// commit through MDK). Retention is by MIP-03 order key (smallest kept), not
/// arrival order, so two members observing the same competitor set retain the
/// same subset and therefore agree on the winner — see
/// [`super::settle::CommitSettleBuffer`].
pub const MAX_SETTLE_COMMITS: usize = 16;

/// Minimum supervisor reconnect backoff (seconds).
pub const BACKOFF_MIN_SECS: u64 = 1;

/// Maximum supervisor reconnect backoff (seconds).
pub const BACKOFF_MAX_SECS: u64 = 30;

/// Spread (basis points, `10_000` = 100%) applied to every re-subscribe backoff
/// in [`super::repair`].
///
/// PRIVACY, not politeness. A relay that ends one of our REQs with `CLOSED`
/// chooses the instant we react; an un-jittered delay would make the re-issue
/// land at an exactly predictable offset from that instant, which is a
/// per-device timing signature a relay can provoke at will — and, by ending the
/// same client's REQ on two relays at once, correlate sockets that carry
/// different sub-ids precisely so they cannot be linked (PSI-2). Sampling from
/// `±25%` costs nothing and removes the provoked signature. `OsRng` only, for
/// the same reason [`crate::location::ttl`] gives.
pub const BACKOFF_JITTER_FRACTION_BP: u16 = 2_500;

/// The jitter must never consume the whole delay (a zero delay is no backoff).
const _: () = assert!(BACKOFF_JITTER_FRACTION_BP < 10_000);

/// How many kind-445 retention windows a group REQ may deliver NOTHING — no
/// event, no `EOSE` — before the health tick re-anchors it.
///
/// The window itself is [`delivery_silence_window_secs`]; this is the multiple.
/// Three is the smallest value that cannot fire on a healthy circle whose only
/// publisher is at the cadence ceiling: a member re-publishes at most every
/// `168 s`, [`LOCATION_MESSAGE_RETENTION_SECS`] adds the network buffer on top,
/// and the relay drops each event at that TTL — so three consecutive retention
/// windows with nothing delivered means no active publisher's event has landed
/// across three full relay-residency periods.
///
/// [`LOCATION_MESSAGE_RETENTION_SECS`]: crate::location::ttl::LOCATION_MESSAGE_RETENTION_SECS
pub const DELIVERY_SILENCE_RETENTION_MULTIPLE: i64 = 3;

/// Seconds of complete delivery silence on one REQ that make the health tick
/// re-anchor it (see [`DELIVERY_SILENCE_RETENTION_MULTIPLE`]).
///
/// Derived from the publish cadence, never a magic number: it is
/// `DELIVERY_SILENCE_RETENTION_MULTIPLE ×` the group's kind-445 retention.
///
/// # What this arm can and cannot claim
///
/// A receiver CANNOT know whether a peer is publishing — every circle whose
/// members have sharing off is legitimately silent forever. So silence is never
/// read as failure, and it never escalates to a whole-session re-anchor
/// ([`super::health::health_needs_targeted_reanchor`] is its own predicate for
/// exactly that reason). The remedy is re-issuing the specific `(relay, sub)`
/// endpoints that went quiet, through the same jittered per-endpoint backoff a
/// relay `CLOSED` uses — bounded work (Security Rule 12), and a successful
/// re-issue's own `EOSE` resets that endpoint's window.
///
/// It applies to GROUP REQs only. A silent inbox REQ is the normal state, and
/// re-issuing it means asking for a 49-hour gift-wrap replay keyed on this
/// device's `#p`, every quarter of an hour, forever; see [`super::health`] for
/// why that arm was removed rather than tuned.
#[must_use]
pub const fn delivery_silence_window_secs() -> i64 {
    DELIVERY_SILENCE_RETENTION_MULTIPLE
        * crate::location::ttl::LOCATION_MESSAGE_RETENTION_SECS.cast_signed()
}

/// Bytes of the SHA-256 sub-id digest used as the subscription-id prefix.
///
/// Eight bytes render to 16 lowercase-hex characters, sitting exactly at the
/// `redact_hex_sequences` floor so a sub-id is auto-redacted if ever logged.
pub const SUB_ID_PREFIX_BYTES: usize = 8;

/// Upper bound (seconds) a background burst waits for its own REQs' backlog to
/// drain before it publishes anyway.
///
/// A burst opens the sockets, re-issues every REQ at its persisted cursor and
/// then waits for each `(relay, subscription)` ENDPOINT it issued to answer
/// `EOSE` (or `CLOSED`), so a peer's commit that landed while the engine was
/// paused is APPLIED before this device encrypts its own location — i.e. the
/// location goes out at the current epoch.
///
/// Sized between the two bounds that matter: at least
/// [`SUBSCRIBE_CONNECT_WAIT_SECS`] (a burst that spent its whole budget on the
/// WebSocket handshake would never see a single `EOSE`), and far below the 10 s
/// per-relay OK wait the publish that follows is bounded by (so the wait is a
/// small fraction of the burst, not its dominant term). A relay that never
/// `EOSE`s therefore costs one bounded wait and the burst publishes regardless —
/// exactly what the foreground does today when a REQ is slow — and the outcome
/// is reported as [`super::processor::BacklogOutcome::TimedOut`] rather than
/// swallowed.
///
/// HISTORICAL context (I-P4-1): a host-local `strfry` answered a group REQ's
/// `EOSE` in ~100 ms when the P-15 probe was run on 2026-07-11, so this bound is
/// expected never to bind on a healthy relay. That probe lived in
/// `tests/settle_window_real_relay_test.rs`, which is now a
/// `DELETED-WITH-SUBJECT` tombstone (Dark Matter, DM-5a) — the figure is a
/// record, not something the tree re-checks, and it is the SAME sample the
/// [`COMMIT_SETTLE_WINDOW_SECS`] doc quotes rather than a second observation.
pub const BURST_BACKLOG_WAIT_SECS: u64 = 5;

/// The backlog wait must cover the handshake grace, or a burst could spend its
/// whole budget connecting and never observe an `EOSE`.
const _: () = assert!(BURST_BACKLOG_WAIT_SECS >= SUBSCRIBE_CONNECT_WAIT_SECS);

/// Upper bound (seconds) on how long a background burst holds its sockets open
/// after the last commit activity, waiting for FOLLOW-ON commit traffic to
/// quiesce before it pauses.
///
/// The settle itself is [`COMMIT_SETTLE_WINDOW_SECS`] measured from the LAST
/// commit activity; this caps the total. It bounds IDLE FOLLOW-ON ACTIVITY
/// ONLY — never an in-flight publish. A commit between SEND and its OK is held
/// by the in-flight publish gauge (`EngineProcessor::in_flight_publishes`),
/// which has no cap at all, because cutting the socket there would make
/// `wait_for_ok` return `Err` and roll a commit back that the relay may have
/// stored and served: a roster fork every burst (Security Rule 13).
///
/// Sized so a commit landing at the very end of the settle still gets its FULL
/// window: with the cap measured from the settle's start, a commit at
/// `cap − window` still settles inside the cap, and the `+ 10` headroom below
/// keeps that true with the crate's 10 s per-relay OK wait in front of it.
pub const BURST_SETTLE_CAP_SECS: u64 = 18;

/// The cap must leave a whole settle window plus the crate's 10 s OK wait, so
/// it can never be the thing that cuts a commit's window short.
const _: () = assert!(BURST_SETTLE_CAP_SECS >= COMMIT_SETTLE_WINDOW_SECS + 10);

/// How many background bursts pass between two inbox (`kind:1059`) REQs.
///
/// `1` = every burst carries the inbox REQ, which is today's behaviour and the
/// lowest invitation latency. The constant exists because inbox relays and
/// circle relays are INDEPENDENT sets: a relay that carries this device's
/// `kind:10050` inbox but none of its circles sees no `kind:445`, so a `#p` REQ
/// on every burst is a "this pubkey is background-sharing right now" cadence
/// signal for that relay class alone. Raising `k` so that
/// `k × kLocationUpdateInterval >= 10 min` removes the cadence at the cost of up
/// to that much background invitation latency.
///
/// Every statement that depends on this names the CONSTANT, never a value, so it
/// stays true whichever way that decision goes.
///
/// BACKGROUND bursts only. A foreground re-anchor (the app-resume and the health
/// tick) closes the standing inbox REQ with its own `unsubscribe_all`, so one
/// that folded the inbox away would leave the device unable to receive an
/// invitation for as long as the app stayed open — and it neither consumes nor
/// reads a position in this period (`LiveSyncCore::resume_after_background`).
pub const INBOX_BURSTS_PER_REQ: u32 = 1;

/// A period of zero would divide by zero in [`burst_issues_inbox`].
const _: () = assert!(INBOX_BURSTS_PER_REQ >= 1);

/// Whether the `seq`-th background burst (0-based) carries the inbox REQ, for a
/// fold period of `every`.
///
/// Pure so the "one inbox REQ per `k` bursts" arithmetic is unit-testable
/// without a relay, and so the burst-open path has exactly one place to state
/// it. Burst `0` always carries it: the first burst after a foreground session
/// ends is the one most likely to be holding a real invitation backlog.
#[must_use]
pub const fn burst_issues_inbox(seq: u64, every: u32) -> bool {
    every <= 1 || seq.is_multiple_of(every as u64)
}

#[cfg(test)]
mod tests {
    use super::{burst_issues_inbox, INBOX_BURSTS_PER_REQ};

    #[test]
    fn every_burst_carries_the_inbox_req_at_the_shipped_period() {
        // The shipped value is `1`, so the fold is a no-op today and background
        // invitation latency is one publish interval. This pins the SHIPPED
        // behaviour, not the arithmetic — the arithmetic is below.
        assert_eq!(INBOX_BURSTS_PER_REQ, 1);
        for seq in 0..8 {
            assert!(
                burst_issues_inbox(seq, INBOX_BURSTS_PER_REQ),
                "burst {seq} must carry the inbox REQ at k = 1"
            );
        }
    }

    #[test]
    fn a_longer_period_folds_the_inbox_req_onto_every_kth_burst() {
        // The privacy lever: with k = 4 an inbox-only relay sees one `#p` REQ
        // per four publish instants instead of one per publish, and the count
        // over N bursts is exactly ceil(N / k).
        let issued: Vec<u64> = (0..12).filter(|s| burst_issues_inbox(*s, 4)).collect();
        assert_eq!(
            issued,
            vec![0, 4, 8],
            "the fold must fire on burst 0 and every k-th burst after it"
        );
        assert_eq!(
            issued.len(),
            12_usize.div_ceil(4),
            "N bursts at period k must issue ceil(N / k) inbox REQs"
        );
    }

    #[test]
    fn the_first_burst_always_carries_the_inbox_req() {
        // Burst 0 is the first one after a foreground session ended, so it is the
        // one most likely to hold a real invitation backlog. No period may skip
        // it.
        for every in 1..=16u32 {
            assert!(
                burst_issues_inbox(0, every),
                "burst 0 must carry the inbox REQ at every period (k = {every})"
            );
        }
    }

    #[test]
    fn a_zero_period_degrades_to_every_burst_rather_than_dividing_by_zero() {
        // `INBOX_BURSTS_PER_REQ >= 1` is const-asserted, so this is unreachable
        // in production; the guard is here because the failure mode of the
        // obvious `seq % every` would be a panic in the burst-open path — a
        // receive outage — rather than a wrong cadence.
        assert!(burst_issues_inbox(3, 0));
    }
}
