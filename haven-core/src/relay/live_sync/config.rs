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
/// in `docs/M11_ROLLOUT.md` §7/§H2, NOT the earlier "latency optimization"
/// wording, is correct.
///
/// The "slower `Unprocessable -> clear -> adopt` path still converges" claim
/// holds ONLY for regime-1 OBSERVERS (no own pending commit): carrying no
/// un-snapshotted merge, they are reconciled by MDK's native rollback plus
/// lossless cursor replay without a window (see
/// `no_pending_observers_converge_on_sibling_commits_via_native_rollback`).
///
/// # Measured propagation (P-15 / A6) — why `8` is defensible
///
/// The value sits in the defensible band `[2x p99 propagation, membership-op UX
/// ceiling]`, confirmed at two relay tiers:
///
/// * `tests/settle_window_tuning_test.rs` samples publish->observe over an
///   in-process relay: p50 ~= 2-3 ms, p99 ~= 3-5 ms. A loopback LOWER BOUND (the
///   in-process relay cannot inject WAN fan-out latency) — it only proves `8 s`
///   dwarfs the fastest-possible pipeline, not that it clears real propagation.
/// * `tests/settle_window_real_relay_test.rs` — the authoritative real-relay
///   MEASUREMENT the in-process numbers defer to (a reproducible on-demand
///   instrument, env-gated on `HAVEN_E2E_RELAY`; the always-on regression backstop
///   is the in-process test above plus the `<= 10` const-assert below, NOT this
///   file — no CI lane runs it with the env set). It drives the SAME probe through
///   a real `strfry` daemon (the pinned `dockurr/strfry` image the Flutter e2e
///   lanes provision): p50 ~= 104 ms, p99 ~= 106 ms, so `2x p99 ~= 212 ms`; the
///   `8000 ms` window clears it by ~38x (measured 2026-07-11 against a host-local
///   strfry, debug build, idle single subscriber, n=100 x3, tightly clustered).
///
/// That sample includes strfry's real ingest->match->broadcast plus WebSocket
/// framing but NOT wide-area RTT or relay fan-out under load. Those terms only
/// widen p99, and the margin absorbs them generously: a congested `+1 s` RTT gives
/// `2x p99 ~= 2.2 s` (~3.6x under the `8 s` window); a severe `+2 s` gives
/// `2x p99 ~= 4.2 s`, still satisfying the fork-safety inequality `window > 2x p99`
/// (`8 s` vs `4.2 s`, ~1.9x margin). So `8 s` holds its `>= 2x` fork-safety margin
/// over realistic propagation while staying below the ~10 s window ceiling that
/// keeps window + publish + converge within a responsive add/remove (~<= 12 s). Do
/// NOT lower it; revisit upward only if a measured p99 exceeds ~4 s (then capped by
/// the UX ceiling). To fold in true WAN RTT, point `HAVEN_E2E_RELAY` at a remote
/// relay you operate and re-run the test.
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

/// Scheduled health-check cadence (seconds, 15 minutes). Body lands in M8.
pub const HEALTH_CHECK_SECS: u64 = 900;

/// Scheduled relay-list maintenance cadence (seconds, 30 minutes). Body in M8.
pub const RELAY_LIST_SECS: u64 = 1800;

/// Bytes of the SHA-256 sub-id digest used as the subscription-id prefix.
///
/// Eight bytes render to 16 lowercase-hex characters, sitting exactly at the
/// `redact_hex_sequences` floor so a sub-id is auto-redacted if ever logged.
pub const SUB_ID_PREFIX_BYTES: usize = 8;
