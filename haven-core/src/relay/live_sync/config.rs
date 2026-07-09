//! Compile-time tuning constants for the persistent live-sync engine.
//!
//! These are reasoned defaults, not yet empirically measured against a real
//! relay; M11 tunes the window/capacity values against observed strfry
//! propagation latency. They live in one module so a tuning pass touches a
//! single file.

/// Capacity of the internal `LiveSyncEvent` broadcast bus.
///
/// Sized well above any realistic per-second event rate so a momentarily slow
/// consumer (e.g. the Dart `StreamSink`) lags rather than blocks the producer.
/// A lagging consumer is recoverable (the cursor + catch-up replay any skipped
/// event); a blocked producer would stall the whole receive path.
pub const BUS_CAP: usize = 8192;

/// Capacity of the bounded receive→decrypt channel between the supervisor's
/// notifications receiver and its decrypt worker.
///
/// Sized to absorb a burst while a slow `SQLCipher` decrypt runs; on overflow the
/// receiver's `try_send` drops the event (never blocking the pool), and the
/// dropped event is re-fetched via the cursor on the next subscribe — lossless,
/// since the cursor advances only on applied events. Kept independent of
/// [`BUS_CAP`] so the decouple buffer can be tuned separately (M11).
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
/// `converge_commit` do the admins converge (the loser adopts the winner). This
/// is pinned by
/// `circle::manager::tests::rev1_or_m11_two_admin_window_miss_forks_but_in_window_converges`.
/// The window MUST therefore be `>= 2x` the p99 commit propagation — the framing
/// in `docs/M11_ROLLOUT_PLAN.md` §7/§H2, NOT the earlier "latency optimization"
/// wording, is correct.
///
/// The "slower `Unprocessable -> clear -> adopt` path still converges" claim
/// holds ONLY for regime-1 OBSERVERS (no own pending commit): carrying no
/// un-snapshotted merge, they are reconciled by MDK's native rollback plus
/// lossless cursor replay without a window (see
/// `no_pending_observers_converge_on_sibling_commits_via_native_rollback`).
pub const COMMIT_SETTLE_WINDOW_SECS: u64 = 8;

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

/// Scheduled health-check cadence (seconds, 15 minutes). Body lands in M8.
pub const HEALTH_CHECK_SECS: u64 = 900;

/// Scheduled relay-list maintenance cadence (seconds, 30 minutes). Body in M8.
pub const RELAY_LIST_SECS: u64 = 1800;

/// Bytes of the SHA-256 sub-id digest used as the subscription-id prefix.
///
/// Eight bytes render to 16 lowercase-hex characters, sitting exactly at the
/// `redact_hex_sequences` floor so a sub-id is auto-redacted if ever logged.
pub const SUB_ID_PREFIX_BYTES: usize = 8;
