//! Relay manager for Nostr event publishing and subscription.
//!
//! This module provides a relay manager that handles all communication
//! with Nostr relays via direct WSS connections.
//!
//! # Security Model
//!
//! - **WSS Only**: Plaintext ws:// connections are rejected

use std::borrow::Cow;
use std::collections::HashSet;
#[cfg(debug_assertions)]
use std::sync::OnceLock;
use std::time::Duration;

#[cfg(debug_assertions)]
use nostr::Url;
use nostr::{
    ClientMessage, Event, EventId, Filter, Kind, PublicKey, RelayMessage, RelayUrl, SubscriptionId,
};
use nostr_sdk::pool::relay::{RelayNotification, ReqExitPolicy};
// The pool's own per-socket status, aliased because `super::types` exports a
// Haven `RelayStatus` of its own (the UI-facing one).
use nostr_sdk::RelayStatus as PoolRelayStatus;
use nostr_sdk::{Client, Relay, RelayOptions, SubscribeAutoCloseOptions, SubscribeOptions};

use super::clock_skew;
use super::discovery::discovery_relays;
use super::error::{InvalidUrlReason, RelayError, RelayResult};
use super::types::{
    PublishResult, RelayConnectionStatus, RelayEventCheck, RelayFetchOutcome, RelayStatus,
};
use crate::log_alias::{self, bucket, RelayUrl as AliasRelayUrl};

/// Default timeout for relay operations.
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(10);

/// Ceiling on how many events ONE per-relay REQ may take in from a filter that
/// names no `limit` of its own.
///
/// Rule 12: a relay must not be able to make a single fetch unbounded in memory.
/// Every filter Haven builds carries a `limit`, and that limit is the cap
/// whenever it is present; this is only the fail-safe for one that does not.
/// Overflowing the cap stops the read WITHOUT an `EOSE`, so the page comes back
/// `drained == false` and no caller may treat it as the relay's whole answer.
const MAX_EVENTS_PER_UNLIMITED_REQ: usize = 1_000;

/// Process-static opt-in for plaintext `ws://` URLs targeting loopback /
/// emulator-host aliases. Set once via [`allow_ws_loopback_for_test`] in
/// debug builds and never observable in release (the sibling stub returns
/// `Err`).
///
/// `OnceLock<()>` gives install-once semantics — a second call returns an
/// error rather than silently re-arming the flag — and atomic reads with no
/// extra synchronisation in the validator hot path.
/// Gated behind `#[cfg(debug_assertions)]` so the static itself is not
/// emitted into release binaries — the release [`allow_ws_loopback_for_test`]
/// stub never touches it, and the release [`is_allowed_ws_loopback`] stub
/// returns `false` unconditionally without reading it.
#[cfg(debug_assertions)]
static ALLOW_WS_LOOPBACK_FOR_TEST: OnceLock<()> = OnceLock::new();

/// Hosts considered safe for plaintext `ws://` when the
/// [`ALLOW_WS_LOOPBACK_FOR_TEST`] flag is installed.
///
/// * `localhost` / `127.0.0.1` / `::1` — IPv4/IPv6 loopback.
/// * `10.0.2.2` — Android emulator's alias for the host's `127.0.0.1`. The
///   AVD cannot reach external networks via this address, so it is
///   semantically loopback even though it is not in `127.0.0.0/8`.
///
/// Any other host (including `0.0.0.0`, private LAN ranges, public FQDNs)
/// is rejected even with the test flag installed. Keeping this list short
/// and explicit guards against a misconfigured
/// `--dart-define=HAVEN_E2E_RELAY=ws://relay.example/` leaking events to a
/// real relay.
///
/// Gated behind `#[cfg(debug_assertions)]` so the literal hostnames
/// (notably `10.0.2.2`, the Android-emulator host-loopback alias) do not
/// end up in the release binary's `.rodata`. Their presence would be a
/// fingerprintable test-mode artifact in shipping `.so`s. Release builds
/// don't need this list — the sibling [`is_allowed_ws_loopback`] release
/// stub always returns `false`.
#[cfg(debug_assertions)]
const TEST_LOOPBACK_HOSTS: &[&str] = &["localhost", "127.0.0.1", "::1", "10.0.2.2"];

/// Timeout for waiting for relay WebSocket connections to establish.
const CONNECTION_TIMEOUT: Duration = Duration::from_secs(5);

/// Maximum number of attempts (initial try + retries) for [`RelayManager::publish_event`].
///
/// The first publish after a cold start — e.g. the app foregrounds and the
/// previous WebSocket was closed on background — races the 5 s connection
/// handshake against the per-event `OK` acknowledgement. When the handshake
/// loses that race the relay never acknowledges in time, `accepted_by` comes
/// back empty, and the event (an MLS commit, a welcome, a key package) is
/// silently dropped. Retrying re-drives
/// [`RelayManager::add_relays_and_connect`] — a fast no-op once the socket is
/// warm — and republishes the **same** event id, which relays dedupe by id, so
/// the retry is idempotent and lands on the now-established connection.
///
/// This ladder is worth its cost precisely for what it carries: a commit that
/// is neither confirmed nor rolled back forks the group (Security Rule 13), and
/// nothing later re-sends it. A LOCATION is the opposite — the next tick
/// carries a fresher one — so it takes
/// [`RelayManager::publish_location_event`]'s single bounded attempt instead.
///
/// Worst case (a genuinely unreachable relay): ~3 × (`CONNECTION_TIMEOUT` +
/// `DEFAULT_TIMEOUT`) + 2 × `PUBLISH_RETRY_BACKOFF` ≈ 49 s before
/// `AllRelaysFailed` surfaces.
const MAX_PUBLISH_ATTEMPTS: u32 = 3;

/// Backoff between [`RelayManager::publish_event`] attempts.
///
/// Short enough to keep worst-case publish latency bounded for foreground
/// location ticks, long enough to let an in-flight WebSocket handshake finish
/// before the next attempt sends into it.
const PUBLISH_RETRY_BACKOFF: Duration = Duration::from_secs(2);

/// Maximum attempts (initial try + one retry) for
/// [`RelayManager::publish_profile_event`].
///
/// Half the location ladder, because the two paths fail differently. A dropped
/// location is gone: the next tick publishes a *different* position, so the
/// retry budget is what buys back that sample. A profile publish is idempotent
/// and durable — the edit stays in the local outbox and is re-published by the
/// ordinary foreground/resume triggers — so a long in-call ladder buys nothing
/// except a user watching a spinner. One retry still covers the case the ladder
/// exists for (a cold socket losing the race against the first ack).
const PROFILE_PUBLISH_MAX_ATTEMPTS: u32 = 2;

/// Backoff between [`RelayManager::publish_profile_event`] attempts.
///
/// A second is enough for a handshake that was already in flight to complete,
/// and it is a second the user spends in front of a "syncing" line.
const PROFILE_PUBLISH_RETRY_BACKOFF: Duration = Duration::from_secs(1);

/// Per-relay bound on waiting for ONE relay's `OK` acknowledgement.
///
/// Strictly tighter than the 10 s `WAIT_FOR_OK_TIMEOUT` that `nostr-relay-pool`
/// applies inside `Relay::send_event`, so this is the deadline that fires and
/// the per-relay cost stays a number this module chose. Worst case for one
/// attempt is therefore `CONNECTION_TIMEOUT` (5 s) + this (6 s) = 11 s, and the
/// full ladder is `2 × 11 + PROFILE_PUBLISH_RETRY_BACKOFF` ≈ 23 s — roughly half
/// the commit path's ~49 s, and a bit over twice the location path's 10 s.
///
/// The one upstream path that could exceed the pool's own bound is the NIP-42
/// re-send: on `auth-required` it waits for authentication and sends AGAIN,
/// doubling the wait. It cannot trigger here — the client is built with no
/// signer, so `has_signer()` is false and the branch is skipped — but this
/// timeout bounds it regardless of that fact.
const PROFILE_PUBLISH_ACK_TIMEOUT: Duration = Duration::from_secs(6);

/// Per-relay bound on ONE relay's `OK` for a kind-445 LOCATION publish.
///
/// Tighter again than the profile plane's window, and strictly tighter than
/// the 10 s wait `nostr-relay-pool` applies inside `Relay::send_event`, so
/// this is the deadline that fires. With the connect it bounds the whole
/// publish at `CONNECTION_TIMEOUT` + this = 10 s of radio — the number that
/// decides how long one location tick keeps the modem awake.
///
/// Cutting at five seconds does not un-send the event: a relay that acks at
/// six has stored it, Haven simply records that relay as silent. If no relay
/// acked, the circle stays due and the next tick sends a fresh event; if one
/// did, the late relay's copy is an extra archive.
const LOCATION_ACK_WINDOW: Duration = Duration::from_secs(5);
/// `DEFAULT_TIMEOUT` stands in for the pool's own `WAIT_FOR_OK_TIMEOUT`
/// (`nostr-relay-pool-0.44.3 relay/constants.rs:10`), which is `pub(super)` and
/// so unreachable from here; the two are both 10 s, and a crate bump that
/// widened the upstream one would only make this proxy stricter. Strictly less
/// than, not at most: at equality the two deadlines race and which one fires is
/// scheduler-dependent — the whole point of this constant is that OURS is the
/// one that decides how long the modem stays awake.
const _: () = assert!(
    LOCATION_ACK_WINDOW.as_millis() < DEFAULT_TIMEOUT.as_millis(),
    "the per-relay window must stay tighter than the pool's own ack wait, or \
     it is not the deadline that fires",
);

/// Attempts (initial try + retries) for
/// [`RelayManager::publish_location_event`] — exactly one, forever.
///
/// A retry buys back a dropped sample only when the sample still matters, and
/// a location's does not: the next tick publishes a *fresher* position within
/// 168 s, so a second attempt spends a second radio wake re-sending a stale
/// one. That is the opposite trade from a COMMIT, which is neither superseded
/// nor re-sendable later — commits, welcomes, key packages and profiles keep
/// [`MAX_PUBLISH_ATTEMPTS`] (Security Rule 13).
///
/// The single attempt still runs through [`publish_with_retry`] so the ladder
/// keeps supplying the error contract Dart already handles — zero acks →
/// [`RelayError::AllRelaysFailed`], every answering relay blaming the clock →
/// [`RelayError::DeviceClockRejected`].
const LOCATION_PUBLISH_ATTEMPTS: u32 = 1;
const _: () = assert!(
    LOCATION_PUBLISH_ATTEMPTS == 1,
    "a location publish is ONE bounded attempt; anything more keeps the radio \
     awake to re-send a position the next tick already supersedes",
);

/// How long a publish socket may sit idle before the pool closes it.
///
/// Only has to be short enough that the FIRST idle poll after a burst already
/// sees the socket idle: the pool polls once a minute from inside the
/// connection task, so the real socket lifetime after the last send is
/// (60 s, 70 s] whatever value below a minute is chosen here.
const PUBLISH_POOL_IDLE_TIMEOUT: Duration = Duration::from_secs(10);

/// The options every relay in the publish pool is registered with.
///
/// This pool is a *burst* pool: it connects, sends, collects the `OK`s and then
/// has nothing to say until the next location tick, key-package rotation or
/// profile save — nothing here holds a standing REQ. So `ping(false)` removes a
/// keepalive frame that keeps nothing alive (~65 radio wakes an hour, one per
/// relay per 55 s), and `sleep_when_idle` lets the socket close between bursts
/// instead of being held open for the same reason.
///
/// `reconnect(false)` is not optional once sleeping is on: the idle monitor runs
/// only inside a live connection task, so a relay that DROPS while reconnection
/// is enabled never reaches `Sleeping` — it retries every 10–60 s forever,
/// waking the radio for a relay nobody is publishing to. Neither option can
/// strand a publish, because every send path re-drives
/// [`RelayManager::add_relays_and_connect`], and `try_connect_relay` reconnects
/// from `Sleeping` *and* `Terminated` inside the caller's own wake.
///
/// # These must be registered through `RelayPool::add_relay`, never `Client::add_relay`
///
/// For a URL already in the pool, `Client::add_relay` ORs its own flags onto the
/// live ones — `relay.flags().add(flag)` with `RelayServiceFlags::default()` =
/// `READ | WRITE | PING` (`nostr-sdk-0.44.1 client/mod.rs:300`,
/// `nostr-relay-pool-0.44.3 flags.rs:24-28`) — and the pinger re-reads that flag
/// on every tick (`inner.rs:982-994`), so one such call silently restores the
/// keepalive on every socket. `RelayPool::add_relay` returns `Ok(false)` and
/// leaves an existing relay untouched (`pool/mod.rs:281-284`). Pinned by
/// `a_second_add_of_the_same_url_never_restores_ping`, which re-runs all three
/// registration sites against a relay the pool already holds.
///
/// The ENGINE pool (`live_sync::session::build_engine_client`) deliberately does
/// NOT get these options: it holds standing REQs, so its socket carries no other
/// traffic and a ping-less NAT drop there would be silent until the 15-minute
/// health tick.
fn publish_relay_options() -> RelayOptions {
    RelayOptions::default()
        .ping(false)
        .reconnect(false)
        .sleep_when_idle(true)
        .idle_timeout(PUBLISH_POOL_IDLE_TIMEOUT)
}

/// Terminates ONE publish target's socket when it is **wedged** — it reports
/// itself `Connected` while the message Haven handed it is still sitting unread
/// in its outbound channel — and reports whether it did.
///
/// # The wedge
///
/// `nostr-relay-pool` loses a live socket when `Relay::try_connect` completes a
/// handshake in the instant a terminating connection task has already announced
/// its exit (`nostr-relay-pool-0.44.3 inner.rs:600`) but has not yet cleared the
/// flag the spawn gates on (`:609`): `_try_connect` sets `Connected` (`:678`),
/// then `spawn_connection_task` sees `is_running()` (`:510-513`), logs and
/// returns — **dropping the stream it was handed**. The relay is left
/// `Connected` with no task, and `Connected` is the one status the pool will
/// never re-dial (`can_connect()`, `status.rs:120-122`) while
/// `ensure_operational` (`:238-274`) still accepts sends. Every later publish
/// then queues into a channel nobody reads: no bytes leave, no relay answers,
/// no error surfaces, and nothing ever recovers it for the life of the process.
/// Haven's own burst options widen the window — `sleep_when_idle` announces
/// `Sleeping` before `post_connection` runs `close_ws` on the way out (`:788`),
/// and `Relay::disconnect` opens it too.
///
/// # Why `unsent`, and not simply "this relay did not acknowledge"
///
/// Because a relay that is merely SLOW must keep its socket. This pool hands a
/// relay exactly one message per attempt and this check runs only once that
/// attempt's ack window has closed, so an unread message is not backpressure —
/// it is a socket with no reader. A relay that took the bytes and answered late
/// (or never) reads zero here and is left alone, which is the difference between
/// recovering a wedge and re-handshaking the whole pool on every publish.
///
/// One residual: the fetch paths and any concurrent publish share this pool, so
/// a message of THEIRS enqueued in the microseconds before this reading lands
/// reads as a wedge, and it costs more than the re-dial. `disconnect` announces
/// `Terminated` and broadcasts `Shutdown` (`inner.rs:1255-1271`), so a
/// concurrent `wait_for_ok` on that relay ends as `NotConnected` (`:1383-1388`)
/// — that relay refuses that publish — and a concurrent per-relay REQ scores
/// not-drained, holding that circle's catch-up cursor for one round. Both
/// recover on the next tick, and both are spent against a relay that otherwise
/// swallows everything until the process restarts.
///
/// # Why only `Connected`
///
/// It is the only status that is both un-dialable and dead: `Pending` and
/// `Connecting` still have a task that will reach a dialable status by itself,
/// `Disconnected` belongs to a retrying task this pool never has
/// (`reconnect(false)`), and `Sleeping` / `Terminated` are already dialable.
/// Matched exhaustively so a crate bump that adds a status has to be decided
/// rather than silently folded into "not wedged".
fn terminate_wedged_socket(
    status: PoolRelayStatus,
    unsent: usize,
    terminate: impl FnOnce(),
) -> bool {
    if unsent == 0 {
        return false;
    }
    let wedged = match status {
        PoolRelayStatus::Connected => true,
        PoolRelayStatus::Initialized
        | PoolRelayStatus::Pending
        | PoolRelayStatus::Connecting
        | PoolRelayStatus::Disconnected
        | PoolRelayStatus::Terminated
        | PoolRelayStatus::Banned
        | PoolRelayStatus::Sleeping => false,
    };
    if wedged {
        terminate();
    }
    wedged
}

/// Frees every wedged publish target, so the NEXT send dials a live socket
/// instead of queueing into a channel nobody reads.
///
/// Runs at the tail of every publish attempt, including a successful one and
/// including a failed one: a publish that landed on two relays of three leaves
/// the third wedged for the life of the process, silently spending the
/// redundancy a user's peers depend on. It reads the attempt's outcome nowhere
/// and changes it in no way — which relays acknowledged is decided before this
/// runs and is never revisited, so Security Rule 13's "acked means acked" is
/// untouched.
///
/// `Relay::disconnect` is safe to call from any status and is a no-op once the
/// relay is `Terminated` (`inner.rs:1255-1271`), so this is idempotent; it
/// touches nothing but the publish pool's own sockets.
async fn recover_wedged_publish_sockets(client: &Client, relay_urls: &[RelayUrl]) {
    let mut freed: usize = 0;
    for url in relay_urls {
        if let Ok(relay) = client.relay(url.as_str()).await {
            if terminate_wedged_socket(relay.status(), relay.queue(), || relay.disconnect()) {
                freed += 1;
            }
        }
    }
    // Presence only: both which relay a device publishes to and how many it
    // keeps are linkable metadata (Security Rule 15).
    if freed > 0 {
        log::warn!("[RelayManager] freed wedged publish socket(s)");
    }
}

/// Runs an idempotent publish `attempt` up to `max_attempts` times,
/// returning the first result for which [`PublishResult::is_success`] holds.
///
/// Retries on BOTH a transport error (`Err`) and a "relays reached but none
/// acknowledged" outcome (`Ok` with empty `accepted_by`), because a cold
/// connection surfaces as the latter. Sleeps `backoff` between attempts (never
/// after the last). When every attempt fails the most recent error is
/// returned, defaulting to [`RelayError::AllRelaysFailed`] when the last
/// attempt produced a non-accepting `Ok` — preserving the historical contract
/// that a fully-unacknowledged publish is an `AllRelaysFailed` error.
///
/// The send logic is injected as a closure (receiving the zero-based attempt
/// index) so the retry policy is unit tested without a live relay.
///
/// # Device-clock rejections are not collapsed
///
/// A non-accepting `Ok` used to be flattened to a bare
/// [`RelayError::AllRelaysFailed`], discarding the per-relay reasons entirely.
/// That is where a fast-clock failure went silent: the relay had *said* the
/// timestamp was out of range, and no layer above the retry loop could ever
/// learn it. Now the reasons are classified
/// ([`clock_skew::classify_publish_outcome`]) and, when the clock is the
/// stated cause, surfaced as [`RelayError::DeviceClockRejected`].
///
/// When *every* relay that answered blamed the clock the loop also stops
/// early: a retry re-offers the same signed event with the same `created_at`,
/// so it is provably hopeless, and spending two more radio round trips on it
/// only drains a device that is already failing to share location.
async fn publish_with_retry<F, Fut>(
    max_attempts: u32,
    backoff: Duration,
    mut attempt: F,
) -> RelayResult<PublishResult>
where
    F: FnMut(u32) -> Fut,
    Fut: std::future::Future<Output = RelayResult<PublishResult>>,
{
    let attempts = max_attempts.max(1);
    let mut last_err = RelayError::AllRelaysFailed;
    for i in 0..attempts {
        match attempt(i).await {
            Ok(result) if result.is_success() => return Ok(result),
            // Relays reached but none acknowledged. Classify BEFORE collapsing
            // so the one actionable diagnosis the relays offered survives.
            Ok(result) => {
                let accepted = result.is_success();
                if let Some(complaint) =
                    clock_skew::classify_publish_outcome(accepted, &result.rejected_by)
                {
                    // log-scan-ok: rejected_by only feeds publish_retry_is_hopeless, a bool.
                    log::warn!(
                        "[RelayManager] publish rejected on timestamp grounds \
                         (device clock {}); not retrying={}",
                        complaint.wire_token(),
                        clock_skew::publish_retry_is_hopeless(accepted, &result.rejected_by)
                    );
                    if clock_skew::publish_retry_is_hopeless(accepted, &result.rejected_by) {
                        return Err(RelayError::DeviceClockRejected { complaint });
                    }
                    last_err = RelayError::DeviceClockRejected { complaint };
                } else {
                    // Preserve the historical contract that a fully
                    // unacknowledged publish with no stated cause is
                    // `AllRelaysFailed`.
                    last_err = RelayError::AllRelaysFailed;
                }
            }
            Err(e) => last_err = e,
        }
        if i + 1 < attempts {
            tokio::time::sleep(backoff).await;
        }
    }
    Err(last_err)
}

/// What ONE relay did with a harvested publish, before it is folded into a
/// [`PublishResult`].
///
/// The third case is the one the pooled send cannot express and both harvesting
/// callers need: a relay that neither accepted nor refused, because it never
/// answered. The profile plane retries on it; the location plane reports it and
/// moves on.
enum AckOutcome {
    /// The relay returned `OK true`.
    Accepted,
    /// The relay returned `OK false`, or the send failed against it. The
    /// relay-controlled reason is carried for
    /// [`clock_skew::classify_publish_outcome`] and never rendered.
    Refused(String),
    /// No answer inside the ack bound (or the relay was not in the pool).
    Unanswered,
}

/// Sends `event` to ONE relay and waits at most `bound` for that relay's `OK`.
///
/// The unit both harvesting fan-outs are built from, so the location and
/// profile planes cannot drift on what "this relay answered" means: only
/// `OK true` is [`AckOutcome::Accepted`]; an `OK false` and a transport-level
/// send failure arrive as the same `Err` and are both
/// [`AckOutcome::Refused`], exactly as they are in the pooled path's `failed`
/// list, because both are answers from a relay that spoke to us; silence
/// inside `bound` is [`AckOutcome::Unanswered`].
///
/// A URL missing from the pool is `Unanswered` rather than an error:
/// [`RelayManager::add_relays_and_connect`] logs and swallows an `add_relay`
/// failure, so a URL can legitimately not be there, and that is this relay's
/// outcome — never a verdict on the publish.
async fn send_to_one(
    client: &Client,
    url: &RelayUrl,
    event: &Event,
    bound: Duration,
) -> (String, AckOutcome) {
    let Ok(relay) = client.relay(url.as_str()).await else {
        return (url.to_string(), AckOutcome::Unanswered);
    };
    match tokio::time::timeout(bound, relay.send_event(event)).await {
        Ok(Ok(_)) => (url.to_string(), AckOutcome::Accepted),
        Ok(Err(e)) => (url.to_string(), AckOutcome::Refused(e.to_string())),
        Err(_) => (url.to_string(), AckOutcome::Unanswered),
    }
}

/// Interprets ONE harvested profile-publish attempt for [`publish_with_retry`].
///
/// A harvest is a verdict only when every relay answered. `failed` holds the
/// relays that did not — an ack timeout, or a handle missing from the pool —
/// and about those this attempt learned nothing whatsoever.
///
/// That distinction is load-bearing because of how the retry loop gives up
/// early: [`clock_skew::publish_retry_is_hopeless`] reads `rejected_by` alone,
/// so an attempt whose ONLY answers came from clock-blaming relays reads as
/// provably hopeless even when another relay simply never spoke. It is not: the
/// silent relay may accept on the next attempt, and no relay ever judged this
/// event's timestamp on its behalf. Reporting that shape as an error keeps the
/// retry alive and keeps the clock verdict for the case where every relay
/// really did answer.
///
/// The location path never calls this: it has no second attempt to keep alive
/// and one ack is all it wants, so its harvest reaches the ladder as it is.
fn profile_attempt_outcome(result: PublishResult) -> RelayResult<PublishResult> {
    if result.is_success() || result.failed.is_empty() {
        return Ok(result);
    }
    // A fixed literal, not the silent relays' count: `Timeout`'s payload is
    // excluded from both renderings and no caller reads it, so a formatted count
    // would be an allocation nothing can observe — and one more place a
    // magnitude could leak from later (Security Rule 15).
    Err(RelayError::Timeout(
        "relays did not answer the publish".to_string(),
    ))
}

/// Manager for Nostr relay connections.
///
/// The `RelayManager` handles all communication with Nostr relays
/// using direct WSS connections via nostr-sdk.
///
/// # Example
///
/// ```rust,ignore
/// use haven_core::relay::RelayManager;
///
/// let manager = RelayManager::new();
///
/// // Publish an event
/// let result = manager.publish_event(&event, &relays).await?;
/// ```
pub struct RelayManager {
    /// The nostr-sdk client.
    client: Client,
}

impl RelayManager {
    /// Creates a new relay manager.
    #[must_use]
    pub fn new() -> Self {
        Self {
            client: Client::builder().build(),
        }
    }

    /// Adds relays and connects only to the specified ones.
    ///
    /// Uses `try_connect_relay` per URL to avoid reconnecting to every
    /// previously-added relay in the pool, which would leak connection
    /// metadata to unrelated relay operators.
    ///
    /// Takes the [`Client`] by reference (rather than `&self`) so the
    /// publish retry path can drive it from a closure that owns a cheap
    /// `Client` clone without borrowing the manager across `await` points.
    async fn add_relays_and_connect(client: &Client, relay_urls: &[RelayUrl]) {
        // Register relays sequentially (cheap metadata operation). Through the
        // POOL, never `Client::add_relay` — see `publish_relay_options`.
        for url in relay_urls {
            match client
                .pool()
                .add_relay(url.as_str(), publish_relay_options())
                .await
            {
                Ok(newly_added) => {
                    log::debug!(
                        "[RelayManager] add_relay {}: newly_added={newly_added}",
                        log_alias::relay(AliasRelayUrl(url.as_str()))
                    );
                }
                // The reason is the pool's own prose and can quote the URL, so
                // only the failure's presence is logged (Security Rule 15).
                Err(_) => {
                    log::debug!(
                        "[RelayManager] add_relay {} failed",
                        log_alias::relay(AliasRelayUrl(url.as_str()))
                    );
                }
            }
        }

        // Connect to all relays in parallel (each has CONNECTION_TIMEOUT)
        let connect_futures = relay_urls.iter().map(|url| async move {
            match client
                .try_connect_relay(url.as_str(), CONNECTION_TIMEOUT)
                .await
            {
                Ok(()) => {
                    log::debug!(
                        "[RelayManager] connected to {}",
                        log_alias::relay(AliasRelayUrl(url.as_str()))
                    );
                }
                Err(_) => {
                    log::debug!(
                        "[RelayManager] failed to connect to {}",
                        log_alias::relay(AliasRelayUrl(url.as_str()))
                    );
                }
            }
        });

        futures::future::join_all(connect_futures).await;
    }

    /// Publishes an event to the specified relays, with a retry ladder.
    ///
    /// The path for everything that is NOT a location: MLS commits, welcomes,
    /// proposals, key packages and relay lists. Each is lost for good if this
    /// call gives up — and a commit that is neither confirmed nor rolled back
    /// forks the group (Security Rule 13) — so they pay
    /// [`MAX_PUBLISH_ATTEMPTS`]. Locations take
    /// [`publish_location_event`](Self::publish_location_event).
    ///
    /// Returns a [`PublishResult`] indicating which relays accepted or
    /// rejected the event.
    ///
    /// # Arguments
    ///
    /// * `event` - The signed Nostr event to publish
    /// * `relays` - List of relay URLs (must be wss://)
    ///
    /// # Errors
    ///
    /// Returns an error if all relays reject the event or connection fails.
    pub async fn publish_event(
        &self,
        event: &Event,
        relays: &[String],
    ) -> RelayResult<PublishResult> {
        // Validate relay URLs (must be wss://)
        let relay_urls = Self::validate_relay_urls(relays)?;

        log::debug!(
            "[RelayManager] publish_event: sending kind {} to {} relay(s)",
            event.kind.as_u16(),
            bucket(relay_urls.len())
        );

        // Retry the connect+send a bounded number of times so the first
        // publish after a cold start (foreground resume / fresh process)
        // is not silently dropped when the WebSocket handshake loses the
        // race against the per-event OK ack. Each attempt owns cheap clones
        // (the `Client` is internally `Arc`-backed) so the retry closure
        // does not borrow `self` across `await` points. Republishing the
        // same event id is idempotent — relays dedupe by id.
        let client = self.client.clone();
        publish_with_retry(
            MAX_PUBLISH_ATTEMPTS,
            PUBLISH_RETRY_BACKOFF,
            move |attempt| {
                let client = client.clone();
                let relay_urls = relay_urls.clone();
                let event = event.clone();
                async move {
                    if attempt > 0 {
                        log::debug!("[RelayManager] publish_event: retry attempt {attempt}");
                    }
                    Self::try_publish_once(&client, &relay_urls, &event).await
                }
            },
        )
        .await
    }

    /// Performs a single connect-and-publish attempt.
    ///
    /// Returns `Ok` with a [`PublishResult`] that may be unsuccessful
    /// (empty `accepted_by`) when the relays were reached but none
    /// acknowledged in time; the caller's retry loop treats that the same
    /// as a transport error. Returns `Err` on a publish timeout or a
    /// transport-level send error.
    async fn try_publish_once(
        client: &Client,
        relay_urls: &[RelayUrl],
        event: &Event,
    ) -> RelayResult<PublishResult> {
        // Add relays, connect, and wait for WebSocket handshakes.
        Self::add_relays_and_connect(client, relay_urls).await;

        let sent = tokio::time::timeout(
            DEFAULT_TIMEOUT,
            client.send_event_to(relay_urls.iter().map(RelayUrl::as_str), event),
        )
        .await;

        // Before either failure is propagated: a socket that swallowed this
        // event is precisely why a send times out, and the ladder's next
        // attempt is worth nothing unless it dials a live one.
        recover_wedged_publish_sockets(client, relay_urls).await;

        let send_result = sent
            .map_err(|_| {
                log::warn!(
                    "[RelayManager] publish_event: timed out after {}s",
                    DEFAULT_TIMEOUT.as_secs()
                );
                RelayError::Timeout("Event publish timed out".to_string())
            })?
            .map_err(|e| {
                // The type only: a pool error's prose quotes relay URLs and the
                // relay's own refusal text (Security Rule 15 / Rule 8).
                log::debug!("[RelayManager] publish_event: send_event failed");
                RelayError::Publish(e.to_string())
            })?;
        log::debug!(
            "[RelayManager] publish_event: success={}, failed={}",
            bucket(send_result.success.len()),
            bucket(send_result.failed.len())
        );
        for url in send_result.failed.keys() {
            // The relay's own words are remote-authored prose, so the handle
            // says WHICH relay failed and nothing says what it claimed.
            log::debug!(
                "[RelayManager] publish_event: relay {} failed",
                log_alias::relay(AliasRelayUrl(url.as_str()))
            );
        }

        // Build the result from Output<EventId>
        let mut accepted_by = Vec::new();
        let mut rejected_by = Vec::new();

        for url in &send_result.success {
            accepted_by.push(url.to_string());
        }

        for (url, error) in &send_result.failed {
            rejected_by.push((url.to_string(), error.clone()));
        }

        Ok(PublishResult {
            event_id: event.id,
            accepted_by,
            rejected_by,
            failed: Vec::new(),
        })
    }

    /// Publishes a public-profile event, harvesting EVERY relay's answer.
    ///
    /// The sibling of [`publish_event`](Self::publish_event) for the profile
    /// plane. It differs in the two ways that plane needs:
    ///
    /// * **Every relay's outcome is reported.** The returned [`PublishResult`]
    ///   partitions the relay set into accepted / refused / unanswered, so a
    ///   caller can tell a full publish from a partial one and keep the edit
    ///   pending until it is fully covered. A location publish only needs to
    ///   know that it landed somewhere; a profile edit that landed on two of
    ///   eight relays is still invisible to most peers reading it.
    /// * **A shorter, tighter ladder.** Each relay's ack is bounded by
    ///   [`PROFILE_PUBLISH_ACK_TIMEOUT`] and the ladder by
    ///   [`PROFILE_PUBLISH_MAX_ATTEMPTS`], because a user is waiting on this and
    ///   the edit is durable if it fails.
    ///
    /// Retries re-send the SAME signed event, which relays dedupe by id, and can
    /// never re-send to a relay that already accepted: any acceptance ends the
    /// ladder ([`publish_with_retry`] returns on the first successful result).
    ///
    /// # Errors
    ///
    /// Returns an error when no relay accepted after the full ladder: the
    /// per-relay reasons where every relay answered (including
    /// [`RelayError::DeviceClockRejected`]), or a timeout when one or more
    /// relays never answered.
    pub async fn publish_profile_event(
        &self,
        event: &Event,
        relays: &[String],
    ) -> RelayResult<PublishResult> {
        let relay_urls = Self::validate_relay_urls(relays)?;

        log::debug!(
            "[RelayManager] publish_profile_event: sending kind {} to {} relay(s)",
            event.kind.as_u16(),
            bucket(relay_urls.len())
        );

        let client = self.client.clone();
        publish_with_retry(
            PROFILE_PUBLISH_MAX_ATTEMPTS,
            PROFILE_PUBLISH_RETRY_BACKOFF,
            move |attempt| {
                let client = client.clone();
                let relay_urls = relay_urls.clone();
                let event = event.clone();
                async move {
                    if attempt > 0 {
                        log::debug!(
                            "[RelayManager] publish_profile_event: retry attempt {attempt}"
                        );
                    }
                    let harvested = Self::try_publish_once_harvesting(
                        &client,
                        &relay_urls,
                        &event,
                        PROFILE_PUBLISH_ACK_TIMEOUT,
                    )
                    .await;
                    profile_attempt_outcome(harvested)
                }
            },
        )
        .await
    }

    /// Publishes a kind-445 LOCATION event: one bounded fan-out, no retry.
    ///
    /// The third publish path, and the cheapest, because a location sample is
    /// the only thing Haven publishes that is superseded rather than lost when
    /// it misses: validate, connect once (≤ [`CONNECTION_TIMEOUT`]), offer the
    /// event to every relay in parallel with each relay's `OK` bounded by
    /// [`LOCATION_ACK_WINDOW`], and return at the slowest bounded relay. Worst
    /// case 10 s of radio per tick, against ~49 s for the commit ladder. There
    /// is no second attempt and no separate drain phase.
    ///
    /// Success is **one relay's `OK`**, not a full harvest: a location that
    /// reached the network reached its circle. Relays that refused and relays
    /// that stayed silent are still reported — that partition is where a clock
    /// verdict is read from — but they never hold the publish back.
    ///
    /// # NEVER for anything carrying a `PendingStateRef` (Security Rule 13)
    ///
    /// Commits, welcomes, proposals, key packages, relay lists and profiles
    /// keep [`publish_event`](Self::publish_event)'s 3-attempt ladder. A
    /// location that misses is superseded by the next tick; a commit that is
    /// neither confirmed nor rolled back forks the group. Nothing that resolves
    /// a `PendingStateRef` may be published through here, and nothing on this
    /// path takes one — pinned by
    /// `security_rule_gates::rule13_commits_keep_the_retry_ladder_and_locations_do_not`.
    ///
    /// # Errors
    ///
    /// The same contract [`publish_event`](Self::publish_event) has, minus the
    /// retries: [`RelayError::AllRelaysFailed`] when no relay acknowledged, and
    /// [`RelayError::DeviceClockRejected`] when every relay that answered
    /// blamed the timestamp (the one publish failure a user can act on, mapped
    /// in Dart to `RelayClockRejectionException`). Also errors when a relay URL
    /// is not `wss://`.
    pub async fn publish_location_event(
        &self,
        event: &Event,
        relays: &[String],
    ) -> RelayResult<PublishResult> {
        let relay_urls = Self::validate_relay_urls(relays)?;

        log::debug!(
            "[RelayManager] publish_location_event: sending kind {} to {} relay(s)",
            event.kind.as_u16(),
            bucket(relay_urls.len())
        );

        let client = self.client.clone();
        publish_with_retry(LOCATION_PUBLISH_ATTEMPTS, Duration::ZERO, move |_| {
            let client = client.clone();
            let relay_urls = relay_urls.clone();
            let event = event.clone();
            // Always `Ok`: a relay that refused or stayed silent is that
            // relay's outcome, and the ladder reads the fan-out's own
            // partition — one ack is a success, no ack is classified for a
            // clock verdict before it collapses to `AllRelaysFailed`.
            async move {
                Ok(Self::try_publish_once_harvesting(
                    &client,
                    &relay_urls,
                    &event,
                    LOCATION_ACK_WINDOW,
                )
                .await)
            }
        })
        .await
    }

    /// Performs a single connect-and-publish attempt that waits for EVERY
    /// relay's acknowledgement, each bounded independently by `ack_timeout`.
    ///
    /// Never returns an error: a relay's failure is that relay's outcome, and
    /// folding it into the result rather than propagating it is the whole point
    /// — one unreachable relay must not discard the acks the others gave.
    /// `client.relay()` in particular is NOT propagated with `?`, because
    /// [`add_relays_and_connect`](Self::add_relays_and_connect) logs and
    /// swallows an `add_relay` failure, so a URL can legitimately be missing
    /// from the pool here.
    ///
    /// `ack_timeout` is a parameter because the two callers bound a relay
    /// differently — [`PROFILE_PUBLISH_ACK_TIMEOUT`] for an edit a user is
    /// waiting on, [`LOCATION_ACK_WINDOW`] for a sample the next tick replaces
    /// — and because a test can then prove the harvest against a hung relay
    /// without spending either bound in wall-clock time.
    ///
    /// # Why not `Client::send_event_to`
    ///
    /// The pooled send returns one merged `Output` and applies its own internal
    /// ack wait, which is looser than this one; it also saves the event into the
    /// pool's in-memory database on the way through. Haven has no reader for
    /// that database — nothing queries the pool's local store — so bypassing it
    /// loses nothing and keeps one fewer copy of a published event in memory.
    async fn try_publish_once_harvesting(
        client: &Client,
        relay_urls: &[RelayUrl],
        event: &Event,
        ack_timeout: Duration,
    ) -> PublishResult {
        // Add relays, connect, and wait for WebSocket handshakes.
        Self::add_relays_and_connect(client, relay_urls).await;

        let sends = relay_urls
            .iter()
            .map(|url| send_to_one(client, url, event, ack_timeout));

        let mut accepted_by = Vec::new();
        let mut rejected_by = Vec::new();
        let mut failed = Vec::new();
        for (url, outcome) in futures::future::join_all(sends).await {
            match outcome {
                AckOutcome::Accepted => accepted_by.push(url),
                AckOutcome::Refused(reason) => rejected_by.push((url, reason)),
                AckOutcome::Unanswered => failed.push(url),
            }
        }

        // A silent relay is EITHER slow or holding this event unsent forever;
        // only the second is freed here, and only after the ack window closed.
        recover_wedged_publish_sockets(client, relay_urls).await;

        // Counts only: which relays a device publishes to is itself linkable
        // metadata and a refusal is remote prose (Rule 8), so neither a URL nor
        // a reason is logged here (matching the per-relay fetch probe).
        log::debug!(
            "[RelayManager] publish harvest: accepted={}, refused={}, silent={}",
            bucket(accepted_by.len()),
            bucket(rejected_by.len()),
            bucket(failed.len())
        );

        PublishResult {
            event_id: event.id,
            accepted_by,
            rejected_by,
            failed,
        }
    }

    /// Publishes an event in the background without waiting for relay acknowledgment.
    ///
    /// Spawns a `tokio::spawn` task to perform the publish. Failures are
    /// logged but not returned to the caller. Suitable for location updates
    /// and key package re-publishes where the periodic timer ensures retries.
    ///
    /// # Errors
    ///
    /// Returns an error only if relay URL validation fails (before spawning).
    pub fn publish_event_background(&self, event: Event, relays: &[String]) -> RelayResult<()> {
        let relay_urls = Self::validate_relay_urls(relays)?;
        let client = self.client.clone();

        tokio::spawn(async move {
            // Register and connect. Through the POOL, never `Client::add_relay`
            // — see `publish_relay_options`.
            for url in &relay_urls {
                let _ = client
                    .pool()
                    .add_relay(url.as_str(), publish_relay_options())
                    .await;
            }
            let connect_futures = relay_urls.iter().map(|url| async {
                let _ = client
                    .try_connect_relay(url.as_str(), CONNECTION_TIMEOUT)
                    .await;
            });
            futures::future::join_all(connect_futures).await;

            // Publish with timeout
            match tokio::time::timeout(
                DEFAULT_TIMEOUT,
                client.send_event_to(relay_urls.iter().map(RelayUrl::as_str), &event),
            )
            .await
            {
                Ok(Ok(result)) => {
                    log::debug!(
                        "[RelayManager] background publish: {} accepted, {} failed",
                        bucket(result.success.len()),
                        bucket(result.failed.len())
                    );
                }
                Ok(Err(_)) => {
                    log::debug!("[RelayManager] background publish failed");
                }
                Err(_) => {
                    log::debug!("[RelayManager] background publish timed out");
                }
            }

            // This path has no retry of its own, so the wedge it would leave
            // behind would be paid for by whatever publishes next.
            recover_wedged_publish_sockets(&client, &relay_urls).await;
        });

        Ok(())
    }

    /// Gets the relay connection status for all connected relays.
    pub async fn get_relay_status(&self) -> Vec<RelayConnectionStatus> {
        let relays = self.client.relays().await;
        let mut statuses = Vec::new();

        for (url, relay) in relays {
            let status = if relay.is_connected() {
                RelayStatus::Connected
            } else {
                RelayStatus::Disconnected
            };

            statuses.push(RelayConnectionStatus {
                url: url.to_string(),
                status,
                last_seen: None,
            });
        }

        statuses
    }

    /// Fetches events matching the given filter from relays.
    ///
    /// Performs a one-shot fetch of events matching the filter,
    /// waiting for responses from all relays or until timeout.
    ///
    /// # Arguments
    ///
    /// * `filter` - Nostr filter for the query
    /// * `relays` - List of relay URLs to query
    /// * `timeout` - Optional timeout (defaults to 30 seconds)
    ///
    /// # Errors
    ///
    /// Returns an error if fetching fails.
    pub async fn fetch_events(
        &self,
        filter: Filter,
        relays: &[String],
        timeout: Option<Duration>,
    ) -> RelayResult<Vec<Event>> {
        let relay_urls = Self::validate_relay_urls(relays)?;

        // Add relays, connect, and wait for WebSocket handshakes
        Self::add_relays_and_connect(&self.client, &relay_urls).await;

        // Fetch events with timeout
        let timeout_duration = timeout.unwrap_or(DEFAULT_TIMEOUT);

        let fetch_result = self
            .client
            .fetch_events_from(
                relay_urls.iter().map(RelayUrl::as_str),
                filter,
                timeout_duration,
            )
            .await
            .map_err(|e| {
                log::debug!("[RelayManager] fetch_events failed");
                RelayError::Fetch(e.to_string())
            })?;

        Ok(fetch_result.into_iter().collect())
    }

    /// Extracts `wss://` relay URLs from `"relay"` tags.
    ///
    /// Used for kind 10050 (inbox) and kind 10051 (`KeyPackage`) events,
    /// which both use `["relay", "<url>"]` tag format.
    fn extract_relay_tag_urls(tags: &nostr::Tags) -> Vec<String> {
        tags.iter()
            .filter_map(|tag| {
                let values = tag.as_slice();
                if values.len() >= 2 && values[0] == "relay" && values[1].starts_with("wss://") {
                    Some(values[1].clone())
                } else {
                    None
                }
            })
            .collect()
    }

    /// Fetches a user's relay list for the given event kind.
    ///
    /// Queries the read-only discovery plane
    /// ([`discovery_relays`][crate::relay::discovery::discovery_relays]) for
    /// the user's replaceable relay list event and extracts `wss://` URLs
    /// from `"relay"` tags. Works for both kind 10050 (inbox) and kind 10051
    /// (`KeyPackage`) events. This resolves *another* user's relays by bare
    /// pubkey without ever publishing the local user's own list.
    ///
    /// # Errors
    ///
    /// Returns an error if the pubkey is invalid or fetching fails.
    async fn fetch_relay_list(&self, pubkey: &str, kind: Kind) -> RelayResult<Vec<String>> {
        let pk = PublicKey::parse(pubkey).map_err(|_| RelayError::InvalidPubkey)?;

        let filter = Filter::new().kind(kind).author(pk).limit(1);
        let discovery = discovery_relays();
        let events = self.fetch_events(filter, &discovery, None).await?;

        if events.is_empty() {
            return Ok(Vec::new());
        }

        Ok(Self::extract_relay_tag_urls(&events[0].tags))
    }

    /// Fetches a user's inbox relay list (kind 10050).
    ///
    /// Returns the relay URLs where the user receives gift-wrapped messages
    /// (NIP-17 / NIP-59). Used as the first tier in the Welcome delivery
    /// cascade per the Marmot Protocol reference implementation.
    ///
    /// # Errors
    ///
    /// Returns an error if the pubkey is invalid or fetching fails.
    pub async fn fetch_inbox_relays(&self, pubkey: &str) -> RelayResult<Vec<String>> {
        self.fetch_relay_list(pubkey, Kind::InboxRelays).await
    }

    /// Fetches a user's `KeyPackage` relay list (kind 10051).
    ///
    /// Returns the relay URLs where the user publishes MLS `KeyPackages`.
    /// Used for `KeyPackage` discovery, not for Welcome delivery.
    ///
    /// # Errors
    ///
    /// Returns an error if the pubkey is invalid or fetching fails.
    pub async fn fetch_keypackage_relays(&self, pubkey: &str) -> RelayResult<Vec<String>> {
        self.fetch_relay_list(pubkey, Kind::MlsKeyPackageRelays)
            .await
    }

    /// Extracts read-capable relay URLs from NIP-65 "r" tags.
    ///
    /// Filters for relays the recipient reads from:
    /// - No marker (both read+write) → include
    /// - "read" → include (recipient fetches here)
    /// - "write" only → exclude (recipient doesn't read here)
    ///
    /// Also filters to `wss://` scheme only for security.
    fn extract_nip65_read_relays(tags: &nostr::Tags) -> Vec<String> {
        tags.iter()
            .filter_map(|tag| {
                let values = tag.as_slice();
                if values.len() >= 2 && values[0] == "r" {
                    // Exclude write-only relays
                    if values.len() >= 3 && values[2] == "write" {
                        return None;
                    }
                    let url = &values[1];
                    // Only accept wss:// URLs
                    if url.starts_with("wss://") {
                        Some(url.clone())
                    } else {
                        None
                    }
                } else {
                    None
                }
            })
            .collect()
    }

    /// Extracts write-capable relay URLs from NIP-65 "r" tags.
    ///
    /// The mirror of [`Self::extract_nip65_read_relays`]. Filters for relays the
    /// author writes to (so *others* fetch the author's events there):
    /// - No marker (both read+write) → include
    /// - "write" → include (author publishes here)
    /// - "read" only → exclude (author doesn't publish here)
    ///
    /// Also filters to `wss://` scheme only for security. Used by the
    /// public-profile publish path to target the user's own write relays.
    #[allow(
        dead_code,
        reason = "consumed by the profile publish path (M5, next wave); exercised now by unit tests"
    )]
    pub(crate) fn extract_nip65_write_relays(tags: &nostr::Tags) -> Vec<String> {
        tags.iter()
            .filter_map(|tag| {
                let values = tag.as_slice();
                if values.len() >= 2 && values[0] == "r" {
                    // Exclude read-only relays.
                    if values.len() >= 3 && values[2] == "read" {
                        return None;
                    }
                    let url = &values[1];
                    // Only accept wss:// URLs.
                    if url.starts_with("wss://") {
                        Some(url.clone())
                    } else {
                        None
                    }
                } else {
                    None
                }
            })
            .collect()
    }

    /// Fetches a user's NIP-65 relay list (kind 10002).
    ///
    /// Returns read-capable relay URLs from the user's general-purpose relay
    /// list. Used as the second tier in the Welcome delivery cascade when
    /// inbox relays (kind 10050) are unavailable.
    ///
    /// # Errors
    ///
    /// Returns an error if the pubkey is invalid or fetching fails.
    pub async fn fetch_nip65_relays(&self, pubkey: &str) -> RelayResult<Vec<String>> {
        let pk = PublicKey::parse(pubkey).map_err(|_| RelayError::InvalidPubkey)?;

        let filter = Filter::new().kind(Kind::RelayList).author(pk).limit(1);

        let discovery = discovery_relays();
        let events = self.fetch_events(filter, &discovery, None).await?;

        if events.is_empty() {
            return Ok(Vec::new());
        }

        let relays = Self::extract_nip65_read_relays(&events[0].tags);

        Ok(relays)
    }

    /// Fetches a user's key package (kind 30443 or legacy kind 443).
    ///
    /// Performs a three-tier discovery cascade:
    /// 1. Kind 10051 relays (`KeyPackage` relay list) — preferred, purpose-built.
    /// 2. Kind 10002 relays (NIP-65) — general-purpose fallback.
    /// 3. [`discovery_relays`][crate::relay::discovery::discovery_relays] —
    ///    last resort (read-only discovery plane).
    ///
    /// Each tier is tried in order; the cascade stops as soon as a `KeyPackage`
    /// is found. Empty tiers are skipped without issuing a redundant query.
    ///
    /// # Arguments
    ///
    /// * `pubkey` - The user's public key (hex or npub)
    ///
    /// # Returns
    ///
    /// The most recent valid `KeyPackage` event, or `None` if no tier returned
    /// an event.
    ///
    /// # Errors
    ///
    /// Returns an error if the pubkey is invalid or fetching fails.
    pub async fn fetch_keypackage(&self, pubkey: &str) -> RelayResult<Option<Event>> {
        // Fetch both relay lists once, then delegate to the shared cascade.
        // Either fetch may fail transiently; treat a failed list as empty so
        // the cascade can fall through to the next tier instead of aborting.
        let kp_relays = self
            .fetch_keypackage_relays(pubkey)
            .await
            .unwrap_or_default();
        let nip65_relays = self.fetch_nip65_relays(pubkey).await.unwrap_or_default();

        self.fetch_keypackage_with_cascade(pubkey, &kp_relays, &nip65_relays)
            .await
    }

    /// Runs the `KeyPackage` discovery cascade with pre-fetched relay lists.
    ///
    /// Tiers, in order: `keypackage_relays` (kind 10051) → `nip65_relays`
    /// (kind 10002) →
    /// [`discovery_relays`][crate::relay::discovery::discovery_relays].
    /// Empty tiers are skipped. The cascade stops as soon as a
    /// `KeyPackage` is found.
    ///
    /// Callers that have already resolved the user's relay lists (e.g., the
    /// FFI layer, which fetches 10051 and 10002 concurrently alongside 10050)
    /// can use this directly to avoid re-fetching.
    ///
    /// # Errors
    ///
    /// Returns an error if the pubkey is invalid or any tier's fetch fails.
    pub async fn fetch_keypackage_with_cascade(
        &self,
        pubkey: &str,
        keypackage_relays: &[String],
        nip65_relays: &[String],
    ) -> RelayResult<Option<Event>> {
        if !keypackage_relays.is_empty() {
            let result = self
                .fetch_keypackage_from_relays(pubkey, keypackage_relays)
                .await?;
            if result.is_some() {
                return Ok(result);
            }
        }

        if !nip65_relays.is_empty() {
            let result = self
                .fetch_keypackage_from_relays(pubkey, nip65_relays)
                .await?;
            if result.is_some() {
                return Ok(result);
            }
        }

        // Final fallback: fetch_keypackage_from_relays queries the read-only
        // discovery plane internally when given an empty slice.
        self.fetch_keypackage_from_relays(pubkey, &[]).await
    }

    /// Fetches a user's key package (kind 30443 or legacy kind 443) from the
    /// given relay list.
    ///
    /// Issues a **single** REQ for both kinds (`kinds([30443, 443])`) so a
    /// legacy 443 stays visible for un-migrated-member detection (migration plan
    /// §6 step 4 / F11) without a second round-trip. **Selection is 30443-only**
    /// ([`Self::pick_keypackage_from_events`]): a 443 is never usable under the
    /// Dark Matter engine, so it is fetched for detection but never returned as a
    /// `KeyPackage`. Returns the latest kind-30443, or `None` if none is present.
    ///
    /// Uses the provided relay list directly, falling back to the read-only
    /// discovery plane
    /// ([`discovery_relays`][crate::relay::discovery::discovery_relays]) if the
    /// list is empty.
    ///
    /// # Arguments
    ///
    /// * `pubkey` - The user's public key (hex or npub)
    /// * `keypackage_relays` - Pre-fetched relay list (kind 10051 result)
    ///
    /// # Returns
    ///
    /// The most recent valid key package event, or `None` if not found.
    ///
    /// # Errors
    ///
    /// Returns an error if the pubkey is invalid or fetching fails.
    pub async fn fetch_keypackage_from_relays(
        &self,
        pubkey: &str,
        keypackage_relays: &[String],
    ) -> RelayResult<Option<Event>> {
        let pk = PublicKey::parse(pubkey).map_err(|_| RelayError::InvalidPubkey)?;

        // If no relay list, fall back to the read-only discovery plane.
        let discovery: Vec<String>;
        let relays = if keypackage_relays.is_empty() {
            discovery = discovery_relays();
            &discovery
        } else {
            keypackage_relays
        };

        // Single REQ for both kinds. `limit(10)` lets the relay return up to
        // 10 events covering both the canonical and legacy variants — well
        // above any reasonable account's published count.
        let filter = Filter::new()
            .kinds([Kind::Custom(30443), Kind::MlsKeyPackage])
            .author(pk)
            .limit(10);
        let events = self.fetch_events(filter, relays, None).await?;

        Ok(Self::pick_keypackage_from_events(events))
    }

    /// Selects the usable key package event — the most recent kind-30443 —
    /// from a combined-kind result set.
    ///
    /// **30443-only (Dark Matter):** a legacy kind-443 `KeyPackage` carries the
    /// old MLS wire format the new engine cannot parse
    /// ([`SessionManager::key_package_from_event`] would decode it but the engine
    /// rejects it on invite), so a 443 is NEVER usable and is ignored here. An
    /// un-migrated member (443-only, no 30443) therefore resolves to `None`; the
    /// "needs to update" detection UX is layered at the FFI over the same
    /// combined-kind REQ (migration plan §6 step 4 / F11), never by returning a
    /// `KeyPackage` the engine will reject. When multiple 30443 events are present
    /// (multiple slots / relays), the latest by `created_at` wins.
    ///
    /// Kept separate from [`Self::fetch_keypackage_from_relays`] so the
    /// selection logic can be unit-tested without a relay round-trip.
    ///
    /// [`SessionManager::key_package_from_event`]: crate::nostr::mls::SessionManager::key_package_from_event
    fn pick_keypackage_from_events(events: Vec<Event>) -> Option<Event> {
        events
            .into_iter()
            .filter(|e| e.kind == Kind::Custom(30443))
            .max_by_key(|e| e.created_at)
    }

    /// Checks whether events matching a filter exist on a specific relay.
    ///
    /// Queries a single relay for events matching the given filter and returns
    /// a summary of what was found.
    ///
    /// # Errors
    ///
    /// Returns an error if the relay URL is invalid or the fetch fails.
    pub async fn check_event_on_relay(
        &self,
        relay_url: &str,
        filter: Filter,
    ) -> RelayResult<RelayEventCheck> {
        let relay_urls = Self::validate_relay_urls(&[relay_url.to_string()])?;

        // Add relay, connect, and wait for WebSocket handshake
        Self::add_relays_and_connect(&self.client, &relay_urls).await;

        // Fetch events from this specific relay
        let events = self
            .client
            .fetch_events_from(
                relay_urls.iter().map(nostr::RelayUrl::as_str),
                filter,
                DEFAULT_TIMEOUT,
            )
            .await
            .map_err(|e| {
                log::debug!("[RelayManager] check_event_on_relay failed");
                RelayError::Fetch(e.to_string())
            })?;

        let event_count = events.len();
        let newest_timestamp = events
            .iter()
            .map(|e| e.created_at.as_secs().cast_signed())
            .max();

        Ok(RelayEventCheck {
            relay_url: relay_url.to_string(),
            found: event_count > 0,
            event_count,
            newest_timestamp,
        })
    }

    /// Fetches events matching `filter` from each relay independently,
    /// reporting per-relay reachability AND whether each relay finished
    /// answering.
    ///
    /// For every relay this attempts the WebSocket handshake (bounded by
    /// [`CONNECTION_TIMEOUT`]); on success it issues one REQ and reads that
    /// relay's own message stream (bounded by [`DEFAULT_TIMEOUT`]), marking the
    /// relay `responded`. A relay whose handshake fails is marked not responded
    /// and is not queried. Relays are processed concurrently.
    ///
    /// Unlike [`fetch_events`](Self::fetch_events), one unreachable relay never
    /// fails the whole call: each relay's outcome is independent. This is what
    /// lets a caller report an accurate reached/unreached tally (e.g. the
    /// Invitations refresh feedback) instead of a single merged result that
    /// hides which relays were reached. A relay that answers with zero events
    /// is `responded == true` with an empty `events` list — distinct from an
    /// unreachable relay (`responded == false`).
    ///
    /// # Why this drives the REQ itself instead of calling `fetch_events_from`
    ///
    /// [`RelayFetchOutcome::drained`] cannot be derived from a pooled fetch.
    /// `RelayPool::fetch_events_from` collects a merged stream and returns
    /// `Ok(collected)` however that stream ended, and its driver task logs and
    /// DROPS each per-relay stream error; `Relay::stream_events` is no better on
    /// its own, because the timeout, an idle timeout and a mid-delivery
    /// disconnect all end its stream with `None` — exactly as a clean `EOSE`
    /// does. So a cut-off delivery is byte-for-byte a complete short page, and a
    /// caller reading that page as "this relay is drained" advances over
    /// whatever the relay had not sent yet.
    ///
    /// Reading the relay's own notification stream recovers the one signal that
    /// distinguishes them: NIP-01 `EOSE`, the relay stating it has served
    /// everything it stores for this REQ. Everything else the stream can end
    /// with — the timeout, a `CLOSED`, a disconnect, a lagged broadcast, our own
    /// intake cap — leaves `drained == false`.
    ///
    /// A **malformed / non-`wss://` URL is fault-isolated too**: it yields one
    /// `responded == false` outcome (structurally excluded from any
    /// responders-only republish target, consistent with the fail-closed
    /// maintenance design) instead of collapsing the whole probe. A single bad
    /// entry in a user's stored relay list therefore never disables the probe
    /// for their other, valid relays. The bad URL is validated PER relay via
    /// [`validate_single_relay_url`](Self::validate_single_relay_url); the
    /// original string is preserved verbatim in the outcome so a caller's
    /// `relay_url == configured_entry` matching still works.
    ///
    /// # Errors
    ///
    /// This call never returns a top-level error: both URL validation and
    /// per-relay connection/fetch failures are captured in the returned
    /// outcomes (as non-responders). The `Result` is retained for signature
    /// stability with the other fetch primitives and for forward-compatibility.
    pub async fn fetch_events_per_relay(
        &self,
        filter: Filter,
        relays: &[String],
    ) -> RelayResult<Vec<RelayFetchOutcome>> {
        let client = &self.client;

        let fetch_futures = relays.iter().map(|relay| {
            let filter = filter.clone();
            async move {
                // Validate PER relay: a malformed / non-`wss://` URL becomes a
                // single non-responder outcome, not a whole-probe abort. The
                // raw string is echoed back verbatim so URL-equality matching
                // in the caller is unaffected.
                let Ok(url) = Self::validate_single_relay_url(relay) else {
                    // Presence-only log: no URL string at debug/error level
                    // (it may be sensitive); only that one entry was invalid.
                    log::debug!(
                        "[RelayManager] per-relay: skipping one invalid relay url (non-responder)"
                    );
                    return RelayFetchOutcome {
                        relay_url: relay.clone(),
                        responded: false,
                        drained: false,
                        events: Vec::new(),
                    };
                };
                let relay_url = url.as_str().to_string();

                // Register the relay (cheap; through the POOL, never
                // `Client::add_relay` — see `publish_relay_options`) then
                // attempt a bounded handshake. `try_connect_relay` returns Ok if
                // the socket is (or becomes) connected within CONNECTION_TIMEOUT
                // — the transport-level equivalent of the relay answering our
                // knock.
                let _ = client
                    .pool()
                    .add_relay(url.as_str(), publish_relay_options())
                    .await;
                let responded = client
                    .try_connect_relay(url.as_str(), CONNECTION_TIMEOUT)
                    .await
                    .is_ok();

                if !responded {
                    // Presence-only: never log the own-relay URL (may be
                    // sensitive), matching the invalid-URL branch above.
                    log::debug!("[RelayManager] per-relay: one own relay did not respond");
                    return RelayFetchOutcome {
                        relay_url,
                        responded: false,
                        drained: false,
                        events: Vec::new(),
                    };
                }

                // Connected a moment ago, yet no handle in the pool: nothing was
                // read, so nothing may be reported as this relay's whole answer.
                let Ok(handle) = client.relay(url.as_str()).await else {
                    log::debug!("[RelayManager] per-relay: one own relay left the pool");
                    return RelayFetchOutcome {
                        relay_url,
                        responded: true,
                        drained: false,
                        events: Vec::new(),
                    };
                };

                let (drained, events) = Self::read_one_relays_answer(&handle, filter).await;
                RelayFetchOutcome {
                    relay_url,
                    responded: true,
                    drained,
                    events,
                }
            }
        });

        Ok(futures::future::join_all(fetch_futures).await)
    }

    /// Issues ONE REQ to ONE relay and reads that relay's own answer, reporting
    /// whether the relay finished giving it (`EOSE`) alongside what arrived.
    ///
    /// # Why the notification stream and not the subscription's event stream
    ///
    /// `Relay::stream_events` hands back a stream that ends with `None` on a
    /// clean `EOSE`, on the subscription timeout, on the idle timeout and on a
    /// mid-delivery disconnect alike — the reason is dropped before it reaches
    /// the caller. The relay's raw notification stream still carries it, and
    /// `EOSE` is the only member of that set which says the page is whole.
    ///
    /// # Ordering, and the two races that are closed by construction
    ///
    /// The notification receiver is taken BEFORE the REQ goes out, because
    /// `notifications()` yields nothing that arrived before the call and a relay
    /// can answer inside the subscribe. And the relay's socket reader handles
    /// messages strictly sequentially, so the `EOSE` notification cannot
    /// overtake an `EVENT` the relay sent ahead of it — stopping at the `EOSE`
    /// therefore cannot leave a delivered event unread.
    ///
    /// The subscription is auto-closing on `EOSE` (it registers its filter
    /// BEFORE sending the REQ, so it is not exposed to the registration race
    /// that bars `verify_subscriptions`), and its handler sends the NIP-01
    /// `CLOSE` when it sees that `EOSE`.
    ///
    /// # Why an early exit sends its own `CLOSE`
    ///
    /// That handler is a separate task with its own receiver, so it learns
    /// NOTHING from this loop giving up: on the intake cap, on a `CLOSED`, or on
    /// a disconnect it goes on waiting for an `EOSE` that may never come, and
    /// closes only when its own [`DEFAULT_TIMEOUT`] expires. The REQ stays open
    /// for the rest of that timeout while the relay keeps streaming into a
    /// bounded broadcast channel nobody is reading — the next page's read shares
    /// that channel, so it can be pushed into `Lagged` and reported unfinished
    /// itself. That is the same "a page nobody finished" evidence that holds a
    /// circle's cursor, self-inflicted. `Relay::unsubscribe` cannot help (it is
    /// a no-op for an auto-closing subscription), so the `CLOSE` is sent
    /// directly. A duplicate reaching the relay when the handler later times out
    /// is inert: NIP-01 closes an unknown subscription id by ignoring it.
    ///
    /// # The intake cap (Rule 12)
    ///
    /// A relay is free to ignore the REQ's `limit`, so the read is bounded by
    /// that limit (or [`MAX_EVENTS_PER_UNLIMITED_REQ`] when the filter names
    /// none), counted over what ARRIVES rather than what is kept — a relay that
    /// repeats one event forever must be bounded in work, not only in memory.
    /// Reaching the cap stops the read short of any `EOSE`, so the page is
    /// reported NOT drained and the overflow is throttled without being silently
    /// treated as the relay's whole answer.
    ///
    /// Repeats are dropped rather than collected, because the pooled collection
    /// this replaced was a SET: callers counting a relay's events (the
    /// `KeyPackage` and relay-list maintenance probes) would otherwise start
    /// seeing a duplicate as a second on-relay event.
    ///
    /// # Why the page is sorted before it is returned
    ///
    /// Arrival order is the relay's to choose, and one caller resolves an
    /// ambiguity positionally (the `KeyPackage` probe's first entry for a `d`
    /// slot), so leaving it unsorted hands a relay a lever over which of two
    /// events a maintenance decision reads. Newest-first by `created_at`, then
    /// by id, is a total order this device computes, and it is the order the
    /// pooled `Events` collection this replaced already had.
    async fn read_one_relays_answer(relay: &Relay, filter: Filter) -> (bool, Vec<Event>) {
        let intake_cap = filter.limit.unwrap_or(MAX_EVENTS_PER_UNLIMITED_REQ);
        let id = SubscriptionId::generate();
        let mut notifications = relay.notifications();

        let opts = SubscribeOptions::default().close_on(Some(
            SubscribeAutoCloseOptions::default()
                .exit_policy(ReqExitPolicy::ExitOnEOSE)
                .timeout(Some(DEFAULT_TIMEOUT)),
        ));
        // auto-closing REQ: `opts` exits on EOSE, so this registers nothing in
        // the pool's long-lived subscription map and the socket can still sleep.
        // The marker is what `check_engine_client_options.sh` check 7 allows it
        // by; an unmarked subscribe anywhere in this file is a standing REQ.
        // auto-closing REQ
        let issued = relay.subscribe_with_id(id.clone(), filter, opts).await;
        if issued.is_err() {
            // Presence-only: neither the own-relay URL nor the relay's own
            // words (Security Rule 15), matching the branches above.
            log::debug!("[RelayManager] per-relay REQ failed (one own relay)");
            return (false, Vec::new());
        }

        let mut events: Vec<Event> = Vec::new();
        let mut seen: HashSet<EventId> = HashSet::new();
        let mut arrivals: usize = 0;
        let drained = tokio::time::timeout(DEFAULT_TIMEOUT, async {
            loop {
                match notifications.recv().await {
                    Ok(RelayNotification::Message { message }) => match message {
                        RelayMessage::Event {
                            subscription_id,
                            event,
                        } if subscription_id.as_ref() == &id => {
                            if arrivals >= intake_cap {
                                return false;
                            }
                            arrivals += 1;
                            if seen.insert(event.id) {
                                events.push(event.into_owned());
                            }
                        }
                        RelayMessage::EndOfStoredEvents(sub) if sub.as_ref() == &id => return true,
                        // The relay ended this subscription itself (rate limit,
                        // auth required, refusal). Whatever it had not sent, it
                        // is not going to.
                        RelayMessage::Closed {
                            subscription_id, ..
                        } if subscription_id.as_ref() == &id => return false,
                        _ => {}
                    },
                    // The socket went away mid-delivery, the pool shut down, or a
                    // lagged broadcast dropped deliveries we will never see —
                    // after which an `EOSE` would vouch for a page we did not
                    // receive whole. None of them is the relay saying it is
                    // done, which is the only thing that ends this read as
                    // drained.
                    Ok(
                        RelayNotification::RelayStatus {
                            status:
                                nostr_sdk::RelayStatus::Disconnected
                                | nostr_sdk::RelayStatus::Terminated
                                | nostr_sdk::RelayStatus::Banned,
                        }
                        | RelayNotification::Shutdown,
                    )
                    | Err(_) => return false,
                    Ok(_) => {}
                }
            }
        })
        .await
        .unwrap_or(false);

        if !drained {
            // Nothing else closes this REQ until the auto-close handler spends
            // its own timeout; see above for what the relay does in between.
            let _ = relay.send_msg(ClientMessage::Close(Cow::Owned(id)));
        }

        events.sort_unstable_by(|a, b| {
            b.created_at
                .cmp(&a.created_at)
                .then_with(|| b.id.cmp(&a.id))
        });
        (drained, events)
    }

    /// Validates relay URLs and ensures they use wss://.
    ///
    /// Plaintext `ws://` is rejected unless the debug-only
    /// [`allow_ws_loopback_for_test`] opt-in has been installed AND the URL
    /// targets a host in [`TEST_LOOPBACK_HOSTS`]. Release builds physically
    /// cannot install the opt-in, so the loopback branch is unreachable
    /// outside of debug-built test binaries.
    fn validate_relay_urls(relays: &[String]) -> RelayResult<Vec<RelayUrl>> {
        let mut urls = Vec::with_capacity(relays.len());

        for relay in relays {
            urls.push(Self::validate_single_relay_url(relay)?);
        }

        Ok(urls)
    }

    /// Validates ONE relay URL, enforcing the `wss://`-only policy (with the
    /// debug-only loopback opt-in).
    ///
    /// This is the per-URL primitive behind [`validate_relay_urls`]. It exists
    /// so a caller that must be per-relay fault-isolated
    /// ([`fetch_events_per_relay`](Self::fetch_events_per_relay)) can validate
    /// each URL independently — one malformed / non-`wss://` entry becomes one
    /// per-relay failure instead of collapsing the whole batch — while the
    /// batch validator keeps its fail-fast semantics for the write paths that
    /// want it.
    ///
    /// # Errors
    ///
    /// Returns [`RelayError::InvalidUrl`] for a plaintext `ws://` URL (outside
    /// the debug loopback opt-in) or an unparseable URL.
    fn validate_single_relay_url(relay: &str) -> RelayResult<RelayUrl> {
        if relay.starts_with("ws://") && !Self::is_allowed_ws_loopback(relay) {
            return Err(RelayError::InvalidUrl(InvalidUrlReason::PlaintextWs));
        }

        // The rejected URL is deliberately not carried: this error crosses the
        // FFI and reaches a log line (Security Rule 15).
        RelayUrl::parse(relay).map_err(|_| RelayError::InvalidUrl(InvalidUrlReason::Unparseable))
    }

    /// Returns `true` iff `relay` is a `ws://` URL targeting a known
    /// loopback / emulator-host alias AND the debug-only test opt-in has
    /// been installed via [`allow_ws_loopback_for_test`].
    ///
    /// The two conditions are AND-ed deliberately: the opt-in alone does
    /// not relax the policy for arbitrary hosts, and the host list alone
    /// does not relax it for production callers.
    #[cfg(debug_assertions)]
    fn is_allowed_ws_loopback(relay: &str) -> bool {
        if ALLOW_WS_LOOPBACK_FOR_TEST.get().is_none() {
            return false;
        }
        // Parse via `Url` so we get robust host extraction even when the
        // URL includes a port, path, or IPv6-bracketed authority.
        let Ok(parsed) = Url::parse(relay) else {
            return false;
        };
        let Some(host) = parsed.host_str() else {
            return false;
        };
        // Strip the brackets the url crate keeps around IPv6 literals so
        // `[::1]` compares equal to the bare `::1` in `TEST_LOOPBACK_HOSTS`.
        let normalised = host
            .strip_prefix('[')
            .and_then(|s| s.strip_suffix(']'))
            .unwrap_or(host);
        TEST_LOOPBACK_HOSTS
            .iter()
            .any(|allowed| normalised.eq_ignore_ascii_case(allowed))
    }

    /// Release-build stub: `ws://` URLs are never allowed in production.
    ///
    /// The release [`allow_ws_loopback_for_test`] stub can never install
    /// `ALLOW_WS_LOOPBACK_FOR_TEST`, so the only honest answer is `false`.
    /// Declared `const fn` so LLVM constant-folds the call site in
    /// [`validate_relay_urls`] into an unconditional rejection branch for
    /// `ws://`, with no host-list lookup compiled in and no
    /// `TEST_LOOPBACK_HOSTS` literals in `.rodata`.
    #[cfg(not(debug_assertions))]
    const fn is_allowed_ws_loopback(_relay: &str) -> bool {
        false
    }

    /// Disconnects from all relays.
    pub async fn shutdown(&self) {
        self.client.disconnect().await;
    }

    /// Removes a relay from the connection pool and tears down its WebSocket.
    ///
    /// Used by the user-configurable relay flow when the user explicitly
    /// removes a relay from their preferences. Without this call, the
    /// `nostr_sdk::Client` keeps an idle WebSocket open to the user-removed
    /// relay until process exit, leaking metadata.
    ///
    /// The URL is rejected if it is not `wss://`. Relays the client never
    /// connected to are silently ignored.
    ///
    /// # Errors
    ///
    /// Returns [`RelayError::InvalidUrl`] for non-`wss://` input. Other
    /// failures from `nostr_sdk` are logged but not returned, since the
    /// caller's intent ("stop talking to this relay") is satisfied by best
    /// effort: even an error path leaves the relay disconnected on next
    /// publish (because the storage no longer references it).
    pub async fn remove_relay(&self, url: &str) -> RelayResult<()> {
        // Defense in depth: validate before passing to nostr-sdk so that
        // operators reading logs cannot see surprising URL strings.
        let _ = Self::validate_relay_urls(&[url.to_string()])?;
        if self.client.remove_relay(url).await.is_err() {
            log::debug!(
                "[RelayManager] remove_relay {} failed",
                log_alias::relay(AliasRelayUrl(url))
            );
        } else {
            log::debug!(
                "[RelayManager] remove_relay {} ok",
                log_alias::relay(AliasRelayUrl(url))
            );
        }
        Ok(())
    }
}

impl Default for RelayManager {
    fn default() -> Self {
        Self::new()
    }
}

/// Opt in to plaintext `ws://` URLs targeting loopback / emulator-host
/// aliases for hermetic E2E tests.
///
/// Intended exclusively for harnesses that need to point [`RelayManager`]
/// — and every other call site that goes through [`validate_relay_urls`]
/// — at a local strfry on `ws://10.0.2.2:7777` (Android emulator host
/// loopback) or `ws://localhost:7777` (direct host). Without this opt-in
/// the validator hard-rejects every `ws://` URL.
///
/// Even with the opt-in, only the hosts in [`TEST_LOOPBACK_HOSTS`] are
/// accepted. Any other host (LAN address, public FQDN) continues to be
/// rejected. The two checks are AND-ed, so a misconfigured
/// `--dart-define=HAVEN_E2E_RELAY=ws://relay.example/` cannot leak through.
///
/// # Errors
///
/// * Returns `Err` if called more than once in the same process — the
///   opt-in is install-once via [`OnceLock`].
///
/// In release builds the opt-in is unreachable; the sibling stub returns
/// an error so callers fail loudly.
#[cfg(debug_assertions)]
pub fn allow_ws_loopback_for_test() -> Result<(), String> {
    ALLOW_WS_LOOPBACK_FOR_TEST
        .set(())
        .map_err(|_existing| "allow_ws_loopback_for_test already installed".to_string())
}

/// Release-build stub for [`allow_ws_loopback_for_test`].
///
/// Always returns an error so release callers fail closed — the opt-in
/// path is physically unreachable here.
///
/// # Errors
///
/// Always returns an error.
#[cfg(not(debug_assertions))]
pub fn allow_ws_loopback_for_test() -> Result<(), String> {
    Err("allow_ws_loopback_for_test is disabled in release builds".to_string())
}

/// Test-only predicate: `true` iff `relay` is a `ws://` loopback /
/// emulator-host URL **and** the [`allow_ws_loopback_for_test`] opt-in is
/// installed.
///
/// This re-exposes [`RelayManager::is_allowed_ws_loopback`] so that
/// storage-layer validators — specifically
/// [`crate::circle::storage_relay_prefs::normalize_url`] — can honor the
/// **same** install-once opt-in and the **same** [`TEST_LOOPBACK_HOSTS`]
/// allowlist already used at publish/connect time by
/// [`RelayManager::validate_relay_urls`]. There is exactly one flag and one
/// host list in the codebase; the storage `add_user_relay` path and the
/// publish path relax `ws://` together, never independently.
///
/// Behaviour is byte-for-byte identical to today in production: the release
/// sibling is a `const fn` returning `false`, so any `ws://`-gating caller
/// constant-folds back to an unconditional rejection and no host literals
/// are emitted into the shipping binary.
#[cfg(debug_assertions)]
#[must_use]
pub fn ws_loopback_allowed_for_test(relay: &str) -> bool {
    RelayManager::is_allowed_ws_loopback(relay)
}

/// Release-build stub for [`ws_loopback_allowed_for_test`].
///
/// `const fn` returning `false` so callers (e.g. `normalize_url`'s `ws://`
/// branch) constant-fold to an unconditional rejection — preserving the
/// production invariant that no plaintext `ws://` relay can ever be stored,
/// published to, or connected to.
#[cfg(not(debug_assertions))]
#[must_use]
pub const fn ws_loopback_allowed_for_test(_relay: &str) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use nostr_relay_builder::prelude::{BoxedFuture, PolicyResult, QueryPolicy};
    use nostr_relay_builder::{LocalRelay, RelayBuilder};

    use super::*;

    #[test]
    fn validate_relay_urls_rejects_plaintext() {
        let relays = vec!["ws://insecure.relay.com".to_string()];
        let result = RelayManager::validate_relay_urls(&relays);

        assert!(matches!(
            result,
            Err(RelayError::InvalidUrl(InvalidUrlReason::PlaintextWs))
        ));
    }

    #[test]
    fn validate_relay_urls_accepts_wss() {
        let relays = vec!["wss://relay.damus.io".to_string()];
        let result = RelayManager::validate_relay_urls(&relays);

        assert!(result.is_ok());
    }

    #[test]
    fn validate_relay_urls_rejects_multiple_plaintext() {
        let relays = vec![
            "wss://good.relay.com".to_string(),
            "ws://bad.relay.com".to_string(),
        ];
        let result = RelayManager::validate_relay_urls(&relays);

        assert!(result.is_err());
    }

    #[test]
    fn validate_relay_urls_accepts_multiple_wss() {
        let relays = vec![
            "wss://relay.damus.io".to_string(),
            "wss://relay.primal.net".to_string(),
            "wss://nos.lol".to_string(),
        ];
        let result = RelayManager::validate_relay_urls(&relays);

        assert!(result.is_ok());
        assert_eq!(result.unwrap().len(), 3);
    }

    #[test]
    fn validate_relay_urls_empty_list() {
        let relays: Vec<String> = vec![];
        let result = RelayManager::validate_relay_urls(&relays);

        assert!(result.is_ok());
        assert!(result.unwrap().is_empty());
    }

    #[test]
    fn validate_relay_urls_invalid_url_format() {
        let relays = vec!["not-a-url".to_string()];
        let result = RelayManager::validate_relay_urls(&relays);

        assert!(matches!(result, Err(RelayError::InvalidUrl(_))));
    }

    // ----------------------------------------------------------------------
    // ws:// loopback test opt-in (debug-only)
    //
    // Install-once OnceLock semantics mean the flag pollutes any test that
    // runs in the same binary. Cargo's default per-binary process isolation
    // does NOT extend to inter-test isolation within a binary, so each
    // negative-path test below explicitly avoids depending on the flag's
    // pre-state. The positive-path test runs last (alphabetically last
    // among its file's tests via the `_z_` prefix would be unreliable
    // because cargo doesn't guarantee ordering), so we instead encode the
    // host-rejection check as a unit assertion on `is_allowed_ws_loopback`
    // directly — it only reads the flag, so the positive and negative
    // sub-cases compose without ordering hazard.
    // ----------------------------------------------------------------------

    #[test]
    fn is_allowed_ws_loopback_rejects_when_flag_unset() {
        // Without the flag, every ws:// URL must be rejected even for
        // loopback. Note: this assertion is robust to flag state set by
        // another test in the same binary, because if the flag IS set,
        // the host-list still gates the result.
        if ALLOW_WS_LOOPBACK_FOR_TEST.get().is_none() {
            assert!(!RelayManager::is_allowed_ws_loopback("ws://localhost:7777"));
        }
    }

    #[test]
    fn is_allowed_ws_loopback_rejects_nonloopback_hosts() {
        // Set the flag (idempotent for repeat runs within a binary).
        let _ = allow_ws_loopback_for_test();
        // Public + LAN + bogus + 0.0.0.0 must all stay rejected.
        for host in [
            "ws://relay.damus.io",
            "ws://192.168.1.10:7777",
            "ws://10.0.0.5:7777",  // similar prefix but NOT 10.0.2.2
            "ws://0.0.0.0:7777",   // wildcard, not loopback
            "ws://relay.example/", // FQDN
        ] {
            assert!(
                !RelayManager::is_allowed_ws_loopback(host),
                "expected {host} to be rejected even with the opt-in installed",
            );
        }
    }

    #[test]
    fn is_allowed_ws_loopback_accepts_loopback_hosts_when_optin_installed() {
        let _ = allow_ws_loopback_for_test();
        for host in [
            "ws://localhost:7777",
            "ws://127.0.0.1:7777",
            "ws://[::1]:7777",
            "ws://10.0.2.2:7777",
        ] {
            assert!(
                RelayManager::is_allowed_ws_loopback(host),
                "expected {host} to be accepted once the opt-in is installed",
            );
        }
    }

    #[test]
    fn validate_relay_urls_accepts_ws_loopback_with_optin() {
        let _ = allow_ws_loopback_for_test();
        // strfry-style URL the e2e harness uses.
        let relays = vec!["ws://10.0.2.2:7777".to_string()];
        let result = RelayManager::validate_relay_urls(&relays);
        assert!(
            result.is_ok(),
            "ws:// loopback must round-trip the validator with the opt-in installed"
        );
    }

    #[test]
    fn allow_ws_loopback_for_test_install_once() {
        // First install may or may not be the first call in this binary,
        // but a subsequent install MUST always error.
        let _ = allow_ws_loopback_for_test();
        let err =
            allow_ws_loopback_for_test().expect_err("second install must report already-installed");
        assert!(err.contains("already installed"), "got: {err}");
    }

    #[tokio::test]
    async fn check_event_on_relay_rejects_plaintext() {
        let manager = RelayManager::new();
        let filter = Filter::new().kind(Kind::Custom(443)).limit(1);
        let result = manager
            .check_event_on_relay("ws://insecure.relay.com", filter)
            .await;
        assert!(matches!(
            result,
            Err(RelayError::InvalidUrl(InvalidUrlReason::PlaintextWs))
        ));
    }

    #[tokio::test]
    async fn check_event_on_relay_rejects_invalid_url() {
        let manager = RelayManager::new();
        let filter = Filter::new().kind(Kind::Custom(443)).limit(1);
        let result = manager.check_event_on_relay("not-a-url", filter).await;
        assert!(matches!(result, Err(RelayError::InvalidUrl(_))));
    }

    #[tokio::test]
    async fn fetch_events_per_relay_plaintext_is_a_non_responder_not_a_whole_probe_error() {
        // A plaintext ws:// URL is fault-isolated PER relay: it yields one
        // `responded == false` outcome instead of collapsing the whole probe.
        // This is what stops a single bad own-relay entry from disabling
        // maintenance for the user's other, valid relays. The outcome is never
        // a responder (fail-closed: never a republish target, never "healthy").
        let manager = RelayManager::new();
        let filter = Filter::new().kind(Kind::GiftWrap).limit(1);
        let result = manager
            .fetch_events_per_relay(filter, &["ws://insecure.relay.com".to_string()])
            .await
            .expect("a bad url must not fail the whole probe");
        assert_eq!(result.len(), 1, "one input url ⇒ one per-relay outcome");
        assert!(
            !result[0].responded,
            "a plaintext ws:// url is a non-responder (never a republish target)"
        );
        assert!(result[0].events.is_empty());
    }

    #[tokio::test]
    async fn fetch_events_per_relay_invalid_url_is_a_non_responder_not_a_whole_probe_error() {
        let manager = RelayManager::new();
        let filter = Filter::new().kind(Kind::GiftWrap).limit(1);
        let result = manager
            .fetch_events_per_relay(filter, &["not-a-url".to_string()])
            .await
            .expect("a malformed url must not fail the whole probe");
        assert_eq!(result.len(), 1, "one input url ⇒ one per-relay outcome");
        assert!(
            !result[0].responded,
            "a malformed url is a non-responder (never a republish target)"
        );
        assert!(result[0].events.is_empty());
    }

    #[tokio::test]
    async fn fetch_events_per_relay_empty_returns_empty() {
        // No relays => no connections attempted => an empty outcome list,
        // never an error. The Invitations refresh relies on this to render
        // its zero-relays state without pinging anything.
        let manager = RelayManager::new();
        let filter = Filter::new().kind(Kind::GiftWrap).limit(1);
        let result = manager.fetch_events_per_relay(filter, &[]).await;
        assert!(result.is_ok());
        assert!(result.unwrap().is_empty());
    }

    #[tokio::test]
    async fn fetch_events_per_relay_one_bad_url_does_not_collapse_the_probe() {
        // HEADLINE robustness fix: a single malformed URL in the relay set must
        // NOT collapse the whole probe. Before the fix, `validate_relay_urls`
        // ran up-front with `?`, so ONE bad entry returned a top-level Err and
        // NONE of the (valid) relays were probed at all — silently disabling
        // maintenance for every good relay.
        //
        // After the fix the probe validates PER relay: the malformed entry
        // becomes one non-responder outcome while the well-formed relays are
        // each attempted independently. We use a well-formed `wss://` URL to an
        // unreachable host as the "valid" relay: it is a non-responder too
        // (handshake fails), but crucially it is STILL PRESENT in the per-relay
        // outcome list, proving the bad URL did not abort the batch. (Live
        // responder behaviour is covered by the MockRelay integration test.)
        let manager = RelayManager::new();
        let filter = Filter::new().kind(Kind::GiftWrap).limit(1);

        let bad = "not-a-url".to_string();
        // Documentation-reserved TLD; well-formed wss:// that resolves nowhere.
        let good_but_unreachable = "wss://relay.invalid.example".to_string();
        let relays = vec![bad.clone(), good_but_unreachable.clone()];

        let outcomes = manager
            .fetch_events_per_relay(filter, &relays)
            .await
            .expect("one bad url must not fail the whole probe");

        // Both inputs yield a per-relay outcome — the malformed one did NOT
        // short-circuit the valid one out of the batch (the mutation this test
        // kills: revert to `validate_relay_urls(relays)?` ⇒ this call is Err ⇒
        // `.expect` panics / zero probed relays).
        assert_eq!(outcomes.len(), 2, "each input url ⇒ one per-relay outcome");

        // The malformed URL is echoed back verbatim and is a non-responder
        // (fail-closed: never a republish target, never healthy).
        let bad_outcome = outcomes
            .iter()
            .find(|o| o.relay_url == bad)
            .expect("the malformed url must appear as its own outcome");
        assert!(
            !bad_outcome.responded,
            "a malformed url is structurally a non-responder"
        );
        assert!(bad_outcome.events.is_empty());

        // The well-formed relay was independently attempted (present in the
        // outcomes under its canonical url) rather than skipped.
        assert!(
            outcomes.iter().any(|o| o.relay_url == good_but_unreachable),
            "the well-formed relay must be probed independently of the bad one"
        );
    }

    #[test]
    fn new_creates_manager() {
        let manager = RelayManager::new();
        // Just verify it can be created without panicking
        drop(manager);
    }

    #[test]
    fn default_creates_manager() {
        let manager = RelayManager::default();
        drop(manager);
    }

    // ----------------------------------------------------------------------
    // publish_with_retry — bounded, idempotent retry policy
    //
    // The send logic is injected as a closure, so these cover the retry
    // policy end-to-end without a live relay. `Duration::ZERO` backoff keeps
    // them instant.
    // ----------------------------------------------------------------------

    fn dummy_publish_result(accepted: bool) -> PublishResult {
        PublishResult {
            event_id: nostr::EventId::from_slice(&[0u8; 32]).expect("32-byte id"),
            accepted_by: if accepted {
                vec!["wss://relay.example.com".to_string()]
            } else {
                vec![]
            },
            rejected_by: vec![],
            failed: vec![],
        }
    }

    #[tokio::test]
    async fn publish_with_retry_returns_on_first_success() {
        let calls = std::cell::Cell::new(0u32);
        let result = publish_with_retry(3, Duration::ZERO, |_| {
            calls.set(calls.get() + 1);
            async { Ok(dummy_publish_result(true)) }
        })
        .await;
        assert!(result.expect("success").is_success());
        assert_eq!(calls.get(), 1, "must not retry after the first acceptance");
    }

    #[tokio::test]
    async fn publish_with_retry_recovers_from_cold_connection() {
        // First two attempts reach the relays but get no OK (empty
        // accepted_by) — the cold-connect race — then the third lands.
        let result = publish_with_retry(3, Duration::ZERO, |attempt| async move {
            if attempt < 2 {
                Ok(dummy_publish_result(false))
            } else {
                Ok(dummy_publish_result(true))
            }
        })
        .await;
        assert!(result.expect("eventual success").is_success());
    }

    #[tokio::test]
    async fn publish_with_retry_recovers_from_transport_error() {
        let result = publish_with_retry(3, Duration::ZERO, |attempt| async move {
            if attempt == 0 {
                Err(RelayError::Timeout("cold socket".to_string()))
            } else {
                Ok(dummy_publish_result(true))
            }
        })
        .await;
        assert!(result.expect("recovered").is_success());
    }

    #[tokio::test]
    async fn publish_with_retry_exhausts_then_returns_all_relays_failed() {
        let calls = std::cell::Cell::new(0u32);
        let result = publish_with_retry(3, Duration::ZERO, |_| {
            calls.set(calls.get() + 1);
            async { Ok(dummy_publish_result(false)) }
        })
        .await;
        assert!(matches!(result, Err(RelayError::AllRelaysFailed)));
        assert_eq!(calls.get(), 3, "must use the full attempt budget");
    }

    // ----------------------------------------------------------------------
    // Device-clock rejections. These are the tests that prove
    // `relay::clock_skew` is REACHED from the production publish path rather
    // than merely existing: they drive `publish_with_retry` — the same
    // function `RelayManager::publish_event` calls — with the wire text a
    // spec-conformant relay actually returns.
    // ----------------------------------------------------------------------

    /// A no-acceptance result whose relays all rejected with `reason`.
    fn rejected_publish_result(reasons: &[&str]) -> PublishResult {
        PublishResult {
            event_id: nostr::EventId::from_slice(&[0u8; 32]).expect("32-byte id"),
            accepted_by: vec![],
            rejected_by: reasons
                .iter()
                .enumerate()
                .map(|(i, r)| (format!("wss://relay{i}.example.com"), (*r).to_string()))
                .collect(),
            failed: vec![],
        }
    }

    #[tokio::test]
    async fn publish_with_retry_reports_a_clock_rejection_instead_of_swallowing_it() {
        // Before the fix this returned a bare `AllRelaysFailed` and the
        // relay's stated reason never left this function — the fast-clock
        // failure mode was invisible to every layer above.
        let result = publish_with_retry(3, Duration::ZERO, |_| async {
            Ok(rejected_publish_result(&[
                "invalid: event too far off from the current time",
            ]))
        })
        .await;
        assert!(
            matches!(
                result,
                Err(RelayError::DeviceClockRejected {
                    complaint: clock_skew::DeviceClockComplaint::Unspecified
                })
            ),
            "a timestamp rejection must survive the retry loop as a clock \
             diagnosis, not collapse to AllRelaysFailed"
        );
    }

    #[tokio::test]
    async fn publish_with_retry_stops_retrying_a_hopeless_clock_rejection() {
        let calls = std::cell::Cell::new(0u32);
        let result = publish_with_retry(3, Duration::ZERO, |_| {
            calls.set(calls.get() + 1);
            async {
                Ok(rejected_publish_result(&[
                    "invalid: created_at is in the future",
                ]))
            }
        })
        .await;
        assert!(matches!(
            result,
            Err(RelayError::DeviceClockRejected {
                complaint: clock_skew::DeviceClockComplaint::Ahead
            })
        ));
        assert_eq!(
            calls.get(),
            1,
            "re-offering the same signed event with the same created_at to a \
             relay that already judged it out of range cannot succeed"
        );
    }

    #[tokio::test]
    async fn publish_with_retry_keeps_retrying_a_mixed_rejection() {
        // One relay blames the clock, another rate-limits. The second may well
        // accept next time, so the normal retry budget must stand — and the
        // clock diagnosis must still be the reported cause when it does not.
        let calls = std::cell::Cell::new(0u32);
        let result = publish_with_retry(3, Duration::ZERO, |_| {
            calls.set(calls.get() + 1);
            async {
                Ok(rejected_publish_result(&[
                    "invalid: event too far off from the current time",
                    "rate-limited: slow down",
                ]))
            }
        })
        .await;
        assert!(matches!(
            result,
            Err(RelayError::DeviceClockRejected {
                complaint: clock_skew::DeviceClockComplaint::Unspecified
            })
        ));
        assert_eq!(calls.get(), 3, "a recoverable relay must still be retried");
    }

    #[tokio::test]
    async fn publish_with_retry_does_not_blame_the_clock_for_ordinary_rejections() {
        // The negative control for the whole mechanism: a non-timestamp
        // rejection must keep producing the historical error, or every
        // ordinary outage would be misreported to the user as a broken clock.
        let result = publish_with_retry(2, Duration::ZERO, |_| async {
            Ok(rejected_publish_result(&["blocked: pubkey not allowed"]))
        })
        .await;
        assert!(matches!(result, Err(RelayError::AllRelaysFailed)));
    }

    #[tokio::test]
    async fn publish_with_retry_prefers_a_later_acceptance_over_a_clock_rejection() {
        // A transient clock complaint from one attempt must not mask a
        // subsequent success (e.g. the user fixed the clock, or a second relay
        // came up).
        let result = publish_with_retry(3, Duration::ZERO, |attempt| async move {
            if attempt == 0 {
                Ok(rejected_publish_result(&[
                    "invalid: event too far off from the current time",
                    "rate-limited: slow down",
                ]))
            } else {
                Ok(dummy_publish_result(true))
            }
        })
        .await;
        assert!(result.expect("later acceptance wins").is_success());
    }

    #[tokio::test]
    async fn publish_with_retry_surfaces_last_transport_error() {
        let result = publish_with_retry(2, Duration::ZERO, |_| async {
            Err(RelayError::Timeout("still cold".to_string()))
        })
        .await;
        assert!(matches!(result, Err(RelayError::Timeout(_))));
    }

    #[tokio::test]
    async fn publish_with_retry_honours_single_attempt() {
        let calls = std::cell::Cell::new(0u32);
        let result = publish_with_retry(1, Duration::ZERO, |_| {
            calls.set(calls.get() + 1);
            async { Ok(dummy_publish_result(false)) }
        })
        .await;
        assert!(matches!(result, Err(RelayError::AllRelaysFailed)));
        assert_eq!(calls.get(), 1, "max_attempts=1 must not retry");
    }

    /// The ladder's wall-clock cost is `attempts × attempt + (attempts − 1) ×
    /// backoff`: the backoff runs BETWEEN attempts and never after the last
    /// one. That relation is what bounds how long a single publish keeps the
    /// radio awake, so it is pinned rather than left to the doc comment.
    ///
    /// Pure futures under a paused clock — with no I/O to wait on, tokio
    /// auto-advances straight to each deadline, so the elapsed time is exact
    /// and the test costs no wall clock. Measured against a real socket the
    /// same assertion would race the handshake.
    #[tokio::test(start_paused = true)]
    async fn publish_with_retry_pays_the_backoff_between_attempts_and_never_after_the_last() {
        let backoff = Duration::from_secs(7);

        let started = tokio::time::Instant::now();
        let exhausted =
            publish_with_retry(3, backoff, |_| async { Ok(dummy_publish_result(false)) }).await;
        assert!(matches!(exhausted, Err(RelayError::AllRelaysFailed)));
        assert_eq!(
            started.elapsed(),
            backoff * 2,
            "three attempts pay two backoffs, and none after the final one",
        );

        let started = tokio::time::Instant::now();
        publish_with_retry(3, backoff, |_| async { Ok(dummy_publish_result(true)) })
            .await
            .expect("first attempt accepted");
        assert_eq!(
            started.elapsed(),
            Duration::ZERO,
            "a publish that lands on the first attempt pays no backoff at all",
        );
    }

    #[tokio::test]
    async fn publish_with_retry_clamps_zero_attempts_to_one() {
        let calls = std::cell::Cell::new(0u32);
        let _ = publish_with_retry(0, Duration::ZERO, |_| {
            calls.set(calls.get() + 1);
            async { Ok(dummy_publish_result(false)) }
        })
        .await;
        assert_eq!(calls.get(), 1, "zero attempts clamps to a single try");
    }

    // ----------------------------------------------------------------------
    // Profile-plane publish: a shorter ladder that harvests every ack.
    //
    // The transport is kind-agnostic, and these tests deliberately publish a
    // kind-1: a kind-0 may only be constructed inside `haven-core/src/profile`
    // (CI-enforced by check_profile_privacy_boundaries.sh check 4), and nothing
    // under test here depends on the kind.
    // ----------------------------------------------------------------------

    /// One relay's clock complaint, plus optionally one relay that said nothing.
    fn clock_rejection_harvest(with_a_silent_relay: bool) -> PublishResult {
        PublishResult {
            event_id: nostr::EventId::from_slice(&[0u8; 32]).expect("32-byte id"),
            accepted_by: vec![],
            rejected_by: vec![(
                "wss://answered.example.com".to_string(),
                "invalid: created_at is in the future".to_string(),
            )],
            failed: if with_a_silent_relay {
                vec!["wss://silent.example.com".to_string()]
            } else {
                vec![]
            },
        }
    }

    /// Renamed with the location path's move off this ladder: `publish_event`
    /// is now the COMMIT/welcome/key-package/relay-list ladder, and the
    /// location worst case is pinned separately (and is shorter than both) by
    /// `location_ladder_worst_case_equals_one_publish_attempt`.
    #[test]
    fn profile_publish_ladder_is_strictly_shorter_than_the_commit_ladder() {
        // Worst case for a ladder: every attempt pays a full handshake plus a
        // full per-relay wait, with a backoff between attempts.
        let worst = |attempts: u32, wait: Duration, backoff: Duration| {
            CONNECTION_TIMEOUT.saturating_mul(attempts)
                + wait.saturating_mul(attempts)
                + backoff.saturating_mul(attempts.saturating_sub(1))
        };
        let profile = worst(
            PROFILE_PUBLISH_MAX_ATTEMPTS,
            PROFILE_PUBLISH_ACK_TIMEOUT,
            PROFILE_PUBLISH_RETRY_BACKOFF,
        );
        let commit = worst(MAX_PUBLISH_ATTEMPTS, DEFAULT_TIMEOUT, PUBLISH_RETRY_BACKOFF);

        assert_eq!(
            profile,
            Duration::from_secs(23),
            "the documented profile worst case moved",
        );
        assert!(
            profile < commit,
            "a user is waiting on the profile publish and the edit survives a \
             failure in the outbox; a commit that is neither confirmed nor \
             rolled back forks the group, so it keeps the longer ladder: \
             {profile:?} vs {commit:?}",
        );
        assert!(
            PROFILE_PUBLISH_ACK_TIMEOUT < DEFAULT_TIMEOUT,
            "the per-relay ack bound must be strictly tighter than the pooled \
             send's own wait, or it is not the deadline that fires",
        );
    }

    #[tokio::test]
    async fn profile_publish_succeeds_on_a_partial_ack_and_still_reports_the_rest() {
        // One acceptance is enough to succeed — but the relays that refused and
        // the relay that never answered must survive into the result, because
        // that is how the caller learns the edit is only partially covered and
        // must stay pending.
        let harvest = PublishResult {
            event_id: nostr::EventId::from_slice(&[0u8; 32]).expect("32-byte id"),
            accepted_by: vec!["wss://took-it.example.com".to_string()],
            rejected_by: vec![(
                "wss://refused.example.com".to_string(),
                "rate-limited: slow down".to_string(),
            )],
            failed: vec!["wss://silent.example.com".to_string()],
        };
        let result = publish_with_retry(PROFILE_PUBLISH_MAX_ATTEMPTS, Duration::ZERO, |_| {
            let harvest = harvest.clone();
            async move { profile_attempt_outcome(harvest) }
        })
        .await
        .expect("one acceptance is a successful publish");

        assert!(result.is_success());
        assert_eq!(result.accepted_by.len(), 1);
        assert_eq!(result.rejected_by.len(), 1);
        assert_eq!(
            result.failed.len(),
            1,
            "an unanswered relay must be reported, not swallowed by the success",
        );
        assert_eq!(result.total_attempted(), 3, "every relay is accounted for");
    }

    #[tokio::test]
    async fn profile_publish_fails_when_no_relay_accepted() {
        let harvest = PublishResult {
            event_id: nostr::EventId::from_slice(&[0u8; 32]).expect("32-byte id"),
            accepted_by: vec![],
            rejected_by: vec![(
                "wss://refused.example.com".to_string(),
                "rate-limited: slow down".to_string(),
            )],
            failed: vec![],
        };
        let result = publish_with_retry(PROFILE_PUBLISH_MAX_ATTEMPTS, Duration::ZERO, |_| {
            let harvest = harvest.clone();
            async move { profile_attempt_outcome(harvest) }
        })
        .await;
        assert!(matches!(result, Err(RelayError::AllRelaysFailed)));
    }

    #[tokio::test]
    async fn a_silent_relay_keeps_profile_retries_alive_past_a_clock_verdict() {
        // THE trap this pins: `publish_retry_is_hopeless` reads `rejected_by`
        // alone, so a harvest whose only ANSWER blamed the device clock looks
        // provably hopeless — even when another relay never spoke at all and
        // has, by definition, no opinion about our timestamp. Abandoning the
        // publish after one attempt on that basis would strand the edit.
        let calls = std::cell::Cell::new(0u32);
        let result = publish_with_retry(PROFILE_PUBLISH_MAX_ATTEMPTS, Duration::ZERO, |_| {
            calls.set(calls.get() + 1);
            async { profile_attempt_outcome(clock_rejection_harvest(true)) }
        })
        .await;

        assert!(result.is_err(), "nothing was accepted");
        assert_eq!(
            calls.get(),
            PROFILE_PUBLISH_MAX_ATTEMPTS,
            "the silent relay must still get its second chance",
        );
    }

    #[tokio::test]
    async fn a_fully_answered_clock_rejection_still_stops_the_profile_ladder() {
        // The negative control for the test above: with every relay answering,
        // the clock verdict IS the whole truth about this event, and re-offering
        // the same `created_at` cannot succeed. The early exit must survive.
        let calls = std::cell::Cell::new(0u32);
        let result = publish_with_retry(PROFILE_PUBLISH_MAX_ATTEMPTS, Duration::ZERO, |_| {
            calls.set(calls.get() + 1);
            async { profile_attempt_outcome(clock_rejection_harvest(false)) }
        })
        .await;

        assert!(matches!(
            result,
            Err(RelayError::DeviceClockRejected {
                complaint: clock_skew::DeviceClockComplaint::Ahead
            })
        ));
        assert_eq!(calls.get(), 1, "a unanimous clock verdict is not retried");
    }

    /// A TCP listener that completes the connection and then says nothing.
    ///
    /// This is the wedged-relay shape, distinct from a departed one (which
    /// refuses the connection and fails fast): the WebSocket handshake can only
    /// end at the connection timeout, and any send into it can only end at the
    /// ack bound. Accepted sockets are held so the peer never sees EOF.
    async fn hung_relay_url() -> String {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind ephemeral port");
        let port = listener.local_addr().expect("local addr").port();
        tokio::spawn(async move {
            while let Ok((socket, _)) = listener.accept().await {
                tokio::spawn(hold_socket_open_in_silence(socket));
            }
        });
        format!("ws://127.0.0.1:{port}")
    }

    /// Owns an accepted socket for the rest of the test without ever writing to
    /// it. Dropping it instead would close the connection, and the peer would
    /// fail fast rather than wait — which is the opposite of "hung".
    async fn hold_socket_open_in_silence(_socket: tokio::net::TcpStream) {
        std::future::pending::<()>().await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn profile_publish_harvests_every_ack_despite_a_hung_relay() {
        // The reason this path exists: one relay that never answers must not
        // cost the acks the others gave. The ack bound is injected (rather than
        // the production 6 s) so the test spends only the connection timeout the
        // wedged socket forces, and no wall-clock assertion depends on either.
        let _ = allow_ws_loopback_for_test();
        let alpha = nostr_relay_builder::prelude::LocalRelay::new(
            nostr_relay_builder::prelude::RelayBuilder::default(),
        );
        alpha.run().await.expect("local relay alpha runs");
        let beta = nostr_relay_builder::prelude::LocalRelay::new(
            nostr_relay_builder::prelude::RelayBuilder::default(),
        );
        beta.run().await.expect("local relay beta runs");

        let urls = RelayManager::validate_relay_urls(&[
            alpha.url().await.to_string(),
            beta.url().await.to_string(),
            hung_relay_url().await,
        ])
        .expect("ws:// loopback urls validate with the opt-in installed");

        let event = nostr::EventBuilder::new(Kind::TextNote, "harvest me")
            .sign_with_keys(&nostr::Keys::generate())
            .expect("sign");

        let manager = RelayManager::new();
        let result = RelayManager::try_publish_once_harvesting(
            &manager.client,
            &urls,
            &event,
            Duration::from_millis(500),
        )
        .await;

        assert_eq!(
            result.accepted_by.len(),
            2,
            "both live relays acknowledged; a wedged third relay must not \
             discard their acks: {result:?}",
        );
        assert!(result.is_success());
        assert_eq!(
            result.total_attempted(),
            3,
            "every relay lands in exactly one bucket: {result:?}",
        );
    }

    // ------------------------------------------------------------------
    // NIP-65 relay tag parsing tests
    // ------------------------------------------------------------------

    /// Helper to build a `Tags` from a vec of parsed tags.
    fn make_tags(tag_data: Vec<Vec<&str>>) -> nostr::Tags {
        let tags: Vec<nostr::Tag> = tag_data
            .into_iter()
            .map(|t| nostr::Tag::parse(t).expect("should parse tag"))
            .collect();
        nostr::Tags::from_list(tags)
    }

    #[test]
    fn nip65_includes_unmarked_relay() {
        let tags = make_tags(vec![vec!["r", "wss://relay.example.com"]]);
        let relays = RelayManager::extract_nip65_read_relays(&tags);
        assert_eq!(relays, vec!["wss://relay.example.com"]);
    }

    #[test]
    fn nip65_includes_read_marked_relay() {
        let tags = make_tags(vec![vec!["r", "wss://read.example.com", "read"]]);
        let relays = RelayManager::extract_nip65_read_relays(&tags);
        assert_eq!(relays, vec!["wss://read.example.com"]);
    }

    #[test]
    fn nip65_excludes_write_only_relay() {
        let tags = make_tags(vec![vec!["r", "wss://write.example.com", "write"]]);
        let relays = RelayManager::extract_nip65_read_relays(&tags);
        assert!(relays.is_empty(), "Write-only relays must be excluded");
    }

    #[test]
    fn nip65_mixed_markers_filters_correctly() {
        let tags = make_tags(vec![
            vec!["r", "wss://both.example.com"],
            vec!["r", "wss://read.example.com", "read"],
            vec!["r", "wss://write.example.com", "write"],
        ]);
        let relays = RelayManager::extract_nip65_read_relays(&tags);
        assert_eq!(
            relays,
            vec!["wss://both.example.com", "wss://read.example.com"]
        );
    }

    #[test]
    fn nip65_excludes_non_wss_urls() {
        let tags = make_tags(vec![
            vec!["r", "ws://insecure.example.com"],
            vec!["r", "http://web.example.com"],
            vec!["r", "wss://secure.example.com"],
        ]);
        let relays = RelayManager::extract_nip65_read_relays(&tags);
        assert_eq!(relays, vec!["wss://secure.example.com"]);
    }

    #[test]
    fn nip65_empty_tags_returns_empty() {
        let tags = nostr::Tags::from_list(vec![]);
        let relays = RelayManager::extract_nip65_read_relays(&tags);
        assert!(relays.is_empty());
    }

    #[test]
    fn nip65_ignores_non_r_tags() {
        let tags = make_tags(vec![
            vec!["p", "wss://not-a-relay.example.com"],
            vec!["e", "wss://also-not.example.com"],
            vec!["r", "wss://real-relay.example.com"],
        ]);
        let relays = RelayManager::extract_nip65_read_relays(&tags);
        assert_eq!(relays, vec!["wss://real-relay.example.com"]);
    }

    // ------------------------------------------------------------------
    // NIP-65 WRITE-relay extraction (mirror of the read-relay tests above)
    // ------------------------------------------------------------------

    #[test]
    fn nip65_write_includes_unmarked_relay() {
        let tags = make_tags(vec![vec!["r", "wss://relay.example.com"]]);
        let relays = RelayManager::extract_nip65_write_relays(&tags);
        assert_eq!(relays, vec!["wss://relay.example.com"]);
    }

    #[test]
    fn nip65_write_includes_write_marked_relay() {
        let tags = make_tags(vec![vec!["r", "wss://write.example.com", "write"]]);
        let relays = RelayManager::extract_nip65_write_relays(&tags);
        assert_eq!(relays, vec!["wss://write.example.com"]);
    }

    #[test]
    fn nip65_write_excludes_read_only_relay() {
        let tags = make_tags(vec![vec!["r", "wss://read.example.com", "read"]]);
        let relays = RelayManager::extract_nip65_write_relays(&tags);
        assert!(relays.is_empty(), "Read-only relays must be excluded");
    }

    #[test]
    fn nip65_write_mixed_markers_filters_correctly() {
        let tags = make_tags(vec![
            vec!["r", "wss://both.example.com"],
            vec!["r", "wss://read.example.com", "read"],
            vec!["r", "wss://write.example.com", "write"],
        ]);
        let relays = RelayManager::extract_nip65_write_relays(&tags);
        assert_eq!(
            relays,
            vec!["wss://both.example.com", "wss://write.example.com"]
        );
    }

    #[test]
    fn nip65_write_excludes_non_wss_urls() {
        let tags = make_tags(vec![
            vec!["r", "ws://insecure.example.com"],
            vec!["r", "http://web.example.com"],
            vec!["r", "wss://secure.example.com"],
        ]);
        let relays = RelayManager::extract_nip65_write_relays(&tags);
        assert_eq!(relays, vec!["wss://secure.example.com"]);
    }

    #[test]
    fn nip65_write_empty_tags_returns_empty() {
        let tags = nostr::Tags::from_list(vec![]);
        let relays = RelayManager::extract_nip65_write_relays(&tags);
        assert!(relays.is_empty());
    }

    // ------------------------------------------------------------------
    // "relay" tag parsing tests (kind 10050 / 10051)
    // ------------------------------------------------------------------

    #[test]
    fn relay_tag_extracts_wss_url() {
        let tags = make_tags(vec![vec!["relay", "wss://inbox.example.com"]]);
        let relays = RelayManager::extract_relay_tag_urls(&tags);
        assert_eq!(relays, vec!["wss://inbox.example.com"]);
    }

    #[test]
    fn relay_tag_excludes_non_wss() {
        let tags = make_tags(vec![
            vec!["relay", "ws://insecure.example.com"],
            vec!["relay", "http://web.example.com"],
            vec!["relay", "wss://secure.example.com"],
        ]);
        let relays = RelayManager::extract_relay_tag_urls(&tags);
        assert_eq!(relays, vec!["wss://secure.example.com"]);
    }

    #[test]
    fn relay_tag_ignores_r_tags() {
        let tags = make_tags(vec![
            vec!["r", "wss://nip65.example.com"],
            vec!["relay", "wss://inbox.example.com"],
        ]);
        let relays = RelayManager::extract_relay_tag_urls(&tags);
        assert_eq!(relays, vec!["wss://inbox.example.com"]);
    }

    #[test]
    fn relay_tag_multiple_urls() {
        let tags = make_tags(vec![
            vec!["relay", "wss://inbox1.example.com"],
            vec!["relay", "wss://inbox2.example.com"],
        ]);
        let relays = RelayManager::extract_relay_tag_urls(&tags);
        assert_eq!(
            relays,
            vec!["wss://inbox1.example.com", "wss://inbox2.example.com"]
        );
    }

    #[test]
    fn relay_tag_empty_returns_empty() {
        let tags = nostr::Tags::from_list(vec![]);
        let relays = RelayManager::extract_relay_tag_urls(&tags);
        assert!(relays.is_empty());
    }

    #[test]
    fn relay_tag_malformed_single_element_ignored() {
        let tags = make_tags(vec![
            vec!["relay"],
            vec!["relay", "wss://valid.example.com"],
        ]);
        let relays = RelayManager::extract_relay_tag_urls(&tags);
        assert_eq!(relays, vec!["wss://valid.example.com"]);
    }

    #[test]
    fn relay_tag_extra_element_still_accepted() {
        let tags = make_tags(vec![vec!["relay", "wss://relay.example.com", "extra"]]);
        let relays = RelayManager::extract_relay_tag_urls(&tags);
        assert_eq!(relays, vec!["wss://relay.example.com"]);
    }

    #[test]
    fn relay_tag_empty_url_excluded() {
        let tags = make_tags(vec![
            vec!["relay", ""],
            vec!["relay", "wss://valid.example.com"],
        ]);
        let relays = RelayManager::extract_relay_tag_urls(&tags);
        assert_eq!(relays, vec!["wss://valid.example.com"]);
    }

    // ------------------------------------------------------------------
    // KeyPackage selection tests (combined-kind fetch result handling)
    // ------------------------------------------------------------------

    /// Builds a signed key package event of the given kind and `created_at`,
    /// using `keys` so the returned events share a single author. Used by
    /// the `pick_keypackage_from_events` tests below.
    fn make_kp_event(keys: &nostr::Keys, kind: Kind, created_at_secs: u64) -> Event {
        let timestamp = nostr::Timestamp::from_secs(created_at_secs);
        nostr::EventBuilder::new(kind, "")
            .custom_created_at(timestamp)
            .sign_with_keys(keys)
            .expect("event signing must succeed for tests")
    }

    #[test]
    fn pick_keypackage_returns_none_for_empty_input() {
        assert!(RelayManager::pick_keypackage_from_events(vec![]).is_none());
    }

    #[test]
    fn pick_keypackage_prefers_30443_over_443_even_when_443_is_newer() {
        let keys = nostr::Keys::generate();
        let canonical_old = make_kp_event(&keys, Kind::Custom(30443), 1_000);
        let legacy_new = make_kp_event(&keys, Kind::MlsKeyPackage, 9_000);

        let picked =
            RelayManager::pick_keypackage_from_events(vec![legacy_new, canonical_old.clone()])
                .expect("should pick a key package");

        assert_eq!(
            picked.kind,
            Kind::Custom(30443),
            "must prefer canonical 30443 over legacy 443 even when 443 is newer"
        );
        assert_eq!(picked.id, canonical_old.id);
    }

    #[test]
    fn pick_keypackage_picks_newest_30443_when_multiple_present() {
        let keys = nostr::Keys::generate();
        let old_canonical = make_kp_event(&keys, Kind::Custom(30443), 1_000);
        let new_canonical = make_kp_event(&keys, Kind::Custom(30443), 5_000);

        let picked =
            RelayManager::pick_keypackage_from_events(vec![old_canonical, new_canonical.clone()])
                .expect("should pick a key package");

        assert_eq!(picked.id, new_canonical.id);
    }

    #[test]
    fn pick_keypackage_ignores_legacy_443_returns_none() {
        // Dark Matter: a 443-only result (un-migrated member) is NOT usable — a
        // 443 KeyPackage cannot be processed by the new engine, so selection
        // must resolve to None rather than return an unprocessable KP.
        let keys = nostr::Keys::generate();
        let legacy = make_kp_event(&keys, Kind::MlsKeyPackage, 1_000);

        assert!(
            RelayManager::pick_keypackage_from_events(vec![legacy]).is_none(),
            "a legacy 443 must never be selected as a usable key package"
        );
    }

    #[test]
    fn pick_keypackage_ignores_all_legacy_443() {
        let keys = nostr::Keys::generate();
        let old_legacy = make_kp_event(&keys, Kind::MlsKeyPackage, 1_000);
        let new_legacy = make_kp_event(&keys, Kind::MlsKeyPackage, 7_000);

        assert!(
            RelayManager::pick_keypackage_from_events(vec![old_legacy, new_legacy]).is_none(),
            "multiple legacy 443s still yield no usable key package"
        );
    }

    #[test]
    fn pick_keypackage_ignores_unrelated_kinds() {
        let keys = nostr::Keys::generate();
        let unrelated = make_kp_event(&keys, Kind::TextNote, 9_000);

        assert!(
            RelayManager::pick_keypackage_from_events(vec![unrelated]).is_none(),
            "unrelated kinds must not be returned"
        );
    }

    // ------------------------------------------------------------------
    // Publish-pool relay options.
    //
    // This pool connects, sends, collects the `OK`s and then has nothing more
    // to say until the next tick — it holds no standing REQ. These tests pin
    // what that makes possible (no keepalive frame, no self-driven retry loop,
    // a socket that closes between bursts) and the crate trap that silently
    // undoes the first of them.
    // ------------------------------------------------------------------

    /// A relay that is never dialled: the flag assertions read what the pool
    /// recorded at registration, which needs no socket.
    const UNDIALLED_RELAY: &str = "wss://relay.example";

    #[tokio::test]
    async fn publish_relay_options_turn_ping_off() {
        let manager = RelayManager::new();
        manager
            .client
            .pool()
            .add_relay(UNDIALLED_RELAY, publish_relay_options())
            .await
            .expect("register a relay in a fresh pool");

        let relay = manager
            .client
            .relay(UNDIALLED_RELAY)
            .await
            .expect("the relay was just registered");

        assert!(
            !relay.flags().has_ping(),
            "the publish pool must send no keepalive frame: nothing here listens \
             between bursts, so a ping is a radio wake that keeps nothing alive",
        );
        assert!(
            relay.flags().has_write(),
            "a publish pool that cannot write is not a publish pool",
        );
        assert!(
            relay.flags().has_read(),
            "...and it has to read the OK acknowledging what it published",
        );
    }

    /// The trap that would silently undo the whole thing: every publish and
    /// every fetch RE-registers its relays, and on an already-known relay a bare
    /// `Client::add_relay` ORs `PING` back on. So the assertion is made after
    /// each of the three registration sites has run against a relay the pool
    /// already knows — a bare call at any one of them turns this red.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_second_add_of_the_same_url_never_restores_ping() {
        let _ = allow_ws_loopback_for_test();
        let server = LocalRelay::new(RelayBuilder::default());
        server.run().await.expect("local relay runs");
        let url = server.url().await.to_string();
        let relays = vec![url.clone()];

        let manager = RelayManager::new();
        manager
            .publish_event(&throwaway_note("registers the relay"), &relays)
            .await
            .expect("the relay is up");
        let relay = manager
            .client
            .relay(url.as_str())
            .await
            .expect("the publish added the relay to the pool");
        assert!(!relay.flags().has_ping(), "the first publish registers it");

        manager
            .publish_event(&throwaway_note("re-registers it"), &relays)
            .await
            .expect("the relay is still up");
        assert!(
            !relay.flags().has_ping(),
            "add_relays_and_connect must not OR the keepalive back onto a relay \
             the pool already holds",
        );

        let mut notifications = relay.notifications();
        let backgrounded = throwaway_note("re-registers it from the background path");
        let backgrounded_id = backgrounded.id;
        manager
            .publish_event_background(backgrounded, &relays)
            .expect("the fire-and-forget path validates its urls");
        assert!(
            await_ok_for(&mut notifications, backgrounded_id, wait_budget(30)).await,
            "the background publish has to reach the relay before its \
             registration can be judged",
        );
        assert!(
            !relay.flags().has_ping(),
            "publish_event_background must not OR the keepalive back on either",
        );

        manager
            .fetch_events_per_relay(Filter::new().kind(Kind::TextNote).limit(1), &relays)
            .await
            .expect("per-relay probe never fails as a whole");
        assert!(
            !relay.flags().has_ping(),
            "nor may the per-relay fetch, which registers its relays itself",
        );
    }

    /// `true` once the relay has acknowledged `event_id`, which is the earliest
    /// point at which the fire-and-forget publish is known to have registered
    /// and used its relay.
    async fn await_ok_for(
        notifications: &mut tokio::sync::broadcast::Receiver<RelayNotification>,
        event_id: EventId,
        budget: Duration,
    ) -> bool {
        tokio::time::timeout(budget, async {
            loop {
                match notifications.recv().await {
                    Ok(RelayNotification::Message {
                        message: RelayMessage::Ok { event_id: id, .. },
                    }) if id == event_id => return true,
                    Ok(_) => {}
                    Err(_) => return false,
                }
            }
        })
        .await
        .unwrap_or(false)
    }

    /// Documents the crate behaviour the pool-level call exists to avoid, so a
    /// silent change to it in a future `nostr-sdk` surfaces here rather than as
    /// a keepalive nobody asked for.
    ///
    /// The ONE deliberate `Client::add_relay` in this file, kept on a single
    /// line and marked, so the guard that bans the call everywhere else can
    /// exclude exactly this one.
    #[tokio::test]
    async fn client_add_relay_ors_ping_back_onto_a_registered_relay() {
        let manager = RelayManager::new();
        manager
            .client
            .pool()
            .add_relay(UNDIALLED_RELAY, publish_relay_options())
            .await
            .expect("register without a ping");

        let client = manager.client.clone();
        client.add_relay(UNDIALLED_RELAY).await.expect("re-add"); // negative control

        let relay = manager
            .client
            .relay(UNDIALLED_RELAY)
            .await
            .expect("still registered");
        assert!(
            relay.flags().has_ping(),
            "nostr-sdk 0.44.1 `Client::add_relay` ORs READ|WRITE|PING onto an \
             existing relay (client/mod.rs:300); the day that stops being true \
             the pool-level call is no longer load-bearing, and this is how we \
             find out",
        );
    }

    /// Scales the wall-clock budget of the relay-backed waits below, as the
    /// `*_e2e` targets do. Each budget bounds how long a TRANSITION may take,
    /// never the property under test, so a larger budget can only remove a
    /// false negative: a transition that never happens exhausts any budget.
    fn wait_budget(base_secs: u64) -> Duration {
        let scale: u64 = std::env::var("HAVEN_TEST_WAIT_SCALE")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .filter(|s| *s >= 1)
            .unwrap_or(1);
        Duration::from_secs(base_secs * scale)
    }

    /// The next relay status transition broadcast on `notifications`, or `None`
    /// if the budget expires first. Panics if the channel closes, which is a
    /// dropped relay handle rather than an answer about the relay.
    ///
    /// Event-driven on purpose: polling `status()` could both miss a transition
    /// and pass on a lucky sample.
    async fn next_relay_status(
        notifications: &mut tokio::sync::broadcast::Receiver<RelayNotification>,
        budget: Duration,
    ) -> Option<nostr_sdk::RelayStatus> {
        tokio::time::timeout(budget, async {
            loop {
                match notifications.recv().await {
                    Ok(RelayNotification::RelayStatus { status }) => return status,
                    // Any other notification — and an overrun, which means
                    // messages were SKIPPED, not that the relay stood still.
                    // Giving up on an overrun would turn a busy machine into a
                    // `None` nobody can tell apart from a timeout.
                    Ok(_) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => panic!(
                        "the relay's notification channel closed before any \
                         status transition; the relay handle was dropped, so \
                         this test cannot observe what it is asserting",
                    ),
                }
            }
        })
        .await
        .ok()
    }

    /// A loopback port that was free at the instant it was returned.
    ///
    /// Stale by construction (TOCTOU): the probe socket is released before
    /// returning, so a foreign socket arriving there turns an expected
    /// connection refusal into a live relay.
    async fn ephemeral_port() -> u16 {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind ephemeral port");
        listener.local_addr().expect("local addr").port()
    }

    /// A loopback front door to a relay, on a port the TEST holds for its whole
    /// life, whose open connections the test can cut.
    ///
    /// This is how a test drops the relay's side of a socket, because
    /// `LocalRelay::shutdown` cannot promise to: it is a
    /// `Notify::notify_waiters`, which stores no permit, so a relay connection
    /// task that is not parked in its `select!` at that instant (still
    /// finishing the EVENT it just acknowledged) never hears it and keeps the
    /// socket open. It also returns before the relay's listener is released,
    /// so re-binding that port races the relay's own task.
    struct CuttableDoor {
        url: String,
        open: std::sync::Arc<std::sync::Mutex<tokio::task::JoinSet<()>>>,
    }

    impl CuttableDoor {
        async fn in_front_of(relay: &LocalRelay) -> Self {
            let target = relay
                .url()
                .await
                .as_str_without_trailing_slash()
                .trim_start_matches("ws://")
                .to_string();
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
                .await
                .expect("bind the front door");
            let url = format!("ws://{}", listener.local_addr().expect("local addr"));
            let open = std::sync::Arc::new(std::sync::Mutex::new(tokio::task::JoinSet::new()));
            let accepted = std::sync::Arc::clone(&open);
            tokio::spawn(async move {
                while let Ok((inbound, _)) = listener.accept().await {
                    let splice = Self::splice(inbound, target.clone());
                    accepted.lock().expect("door lock").spawn(splice);
                }
            });
            Self { url, open }
        }

        /// Carries one accepted connection to the relay until either side
        /// closes it — or until the test cuts the task holding both sockets.
        async fn splice(mut inbound: tokio::net::TcpStream, target: String) {
            if let Ok(mut outbound) = tokio::net::TcpStream::connect(target).await {
                let _ = tokio::io::copy_bidirectional(&mut inbound, &mut outbound).await;
            }
        }

        /// Closes every connection accepted so far, returning once their
        /// sockets are closed.
        async fn cut(&self) {
            let mut open = std::mem::take(&mut *self.open.lock().expect("door lock"));
            open.shutdown().await;
        }
    }

    /// Refuses every REQ that names `0` as an author, so ONE relay can serve
    /// both the ordinary `EOSE` read path and the `CLOSED` one.
    #[derive(Debug)]
    struct RefuseAuthor(PublicKey);

    impl QueryPolicy for RefuseAuthor {
        fn admit_query<'a>(
            &'a self,
            query: &'a Filter,
            _addr: &'a std::net::SocketAddr,
        ) -> BoxedFuture<'a, PolicyResult> {
            Box::pin(async move {
                if query
                    .authors
                    .as_ref()
                    .is_some_and(|authors| authors.contains(&self.0))
                {
                    PolicyResult::Reject("author not served here".to_string())
                } else {
                    PolicyResult::Accept
                }
            })
        }
    }

    /// A signed note nobody reads, for driving one publish.
    fn throwaway_note(content: &str) -> Event {
        nostr::EventBuilder::new(Kind::TextNote, content)
            .sign_with_keys(&nostr::Keys::generate())
            .expect("sign")
    }

    /// The socket a burst leaves behind must close itself, and the next burst
    /// must bring it back.
    ///
    /// ~60–70 s of wall clock by construction: the pool's idle poll is a
    /// one-minute crate constant evaluated inside the live connection task, so
    /// no clock trick reaches it against a real socket. The wait is bounded and
    /// event-driven, so a build whose socket never sleeps fails at the budget
    /// rather than hanging.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn the_publish_socket_sleeps_after_a_burst_and_wakes_for_the_next() {
        let _ = allow_ws_loopback_for_test();
        let server = LocalRelay::new(RelayBuilder::default());
        server.run().await.expect("local relay runs");
        let url = server.url().await.to_string();

        let manager = RelayManager::new();
        assert!(manager
            .publish_event(&throwaway_note("burst one"), std::slice::from_ref(&url))
            .await
            .expect("the first burst reaches the relay")
            .is_success(),);

        let relay = manager
            .client
            .relay(url.as_str())
            .await
            .expect("the publish added the relay to the pool");
        let mut notifications = relay.notifications();
        assert_eq!(
            relay.queue(),
            0,
            "a finished burst leaves nothing unsent, so the wedge check cannot \
             fire inside the burst model and never races the idle monitor for \
             this socket",
        );

        assert_eq!(
            next_relay_status(&mut notifications, wait_budget(180)).await,
            Some(nostr_sdk::RelayStatus::Sleeping),
            "an idle publish socket must close itself; with nothing else \
             happening, the only transition after a finished burst is to sleep",
        );

        assert!(
            manager
                .publish_event(&throwaway_note("burst two"), &[url])
                .await
                .expect("the second burst reaches the relay")
                .is_success(),
            "a sleeping socket must be woken by the next publish, inside that \
             publish's own wake",
        );
        assert!(relay.is_connected(), "the woken relay is connected again");
        assert_eq!(
            relay.queue(),
            0,
            "the woken socket sent what it was given, so the wake costs one \
             handshake and no teardown",
        );
    }

    /// `reconnect(false)`: a dropped publish socket goes straight to
    /// `Terminated` and stays there.
    ///
    /// With reconnection on it would go `Disconnected` and retry every 10–60 s
    /// forever — and never reach `Sleeping`, because the idle monitor lives
    /// inside the connection task. The second half proves the option cannot
    /// strand a later publish (a commit, a welcome): every send path re-drives
    /// `add_relays_and_connect`, and `try_connect_relay` connects from
    /// `Terminated`.
    ///
    /// Single-threaded on purpose, which HIDES an upstream defect rather than
    /// fixing it. The pool announces `Terminated`
    /// (`nostr-relay-pool-0.44.3 inner.rs:600`) BEFORE its connection task
    /// clears the flag `spawn_connection_task` checks (`inner.rs:510-513` vs
    /// `:609`), so a socket connected inside that window is silently dropped
    /// and the relay left `Connected` with no task — every later send then
    /// queues into a channel nobody reads. Nothing between those two lines
    /// yields, so one thread cannot interleave them. A multi-threaded runtime
    /// can: this body stranded ~2% of runs under CPU oversubscription (24-way,
    /// 1127 runs), each one reporting `Connected` at the failed publish. Treat
    /// that rate as harness-specific — a 16-worker run on 2 cores reproduced it
    /// 0 times in 3000, which is consistent with a window of tens of ns rather
    /// than evidence against it. The app's runtime IS multi-threaded
    /// (`flutter_rust_bridge`'s `tokio::runtime::Runtime::new`), so this is a
    /// product exposure, not a loopback artefact. It is mitigated on the
    /// publish path by `terminate_wedged_socket`, which frees exactly that
    /// socket at the tail of every attempt; this body is the ordering that
    /// reaches it. The READ paths share the pool and are NOT mitigated.
    #[tokio::test(flavor = "current_thread")]
    async fn a_dropped_publish_socket_does_not_reconnect_on_its_own() {
        let _ = allow_ws_loopback_for_test();
        let server = LocalRelay::new(RelayBuilder::default());
        server.run().await.expect("local relay runs");
        let door = CuttableDoor::in_front_of(&server).await;
        let url = door.url.clone();

        let manager = RelayManager::new();
        assert!(manager
            .publish_event(
                &throwaway_note("before the drop"),
                std::slice::from_ref(&url)
            )
            .await
            .expect("the relay is up")
            .is_success(),);

        let relay = manager
            .client
            .relay(url.as_str())
            .await
            .expect("the publish added the relay to the pool");
        let mut notifications = relay.notifications();
        door.cut().await;

        assert_eq!(
            next_relay_status(&mut notifications, wait_budget(30)).await,
            Some(nostr_sdk::RelayStatus::Terminated),
            "a dropped publish socket must terminate, not enter a retry loop \
             that wakes the radio every 10-60 s for a relay nobody is \
             publishing to",
        );

        assert!(
            manager
                .publish_event(&throwaway_note("after the drop"), &[url])
                .await
                .expect("the next publish reconnects")
                .is_success(),
            "reconnect(false) must never strand a later publish: the send path \
             reconnects from Terminated inside its own attempt",
        );
    }

    // ------------------------------------------------------------------
    // The wedged publish socket.
    //
    // `nostr-relay-pool` drops a live socket when a handshake finishes in the
    // instant a terminating connection task has announced its exit but not yet
    // cleared the flag the spawn gates on, and leaves the relay `Connected`
    // with no task: a status the pool will never re-dial, that accepts sends,
    // and that writes none of them. One such relay in the publish pool swallows
    // every location, commit and welcome aimed at it for the life of the
    // process, with no error anywhere — see `terminate_wedged_socket`.
    //
    // The state CANNOT be built against a real pool in-process: it needs the
    // pool's connection task interleaved between `inner.rs:600` (it announces
    // `Terminated`) and `:609` (it clears the flag), and nothing between those
    // two statements yields, so one thread cannot interleave them and a
    // multi-threaded runtime cannot be made to on demand. So the recovery is
    // driven through the real ladder against a modelled socket, the two
    // readings the model stands on are measured separately on a real one
    // (`a_real_publish_socket_reads_empty_until_nothing_is_reading_it`,
    // `a_relay_that_took_the_publish_and_went_silent_keeps_its_socket`), and
    // what the recovery DOES with those readings is measured on a real one too
    // (`the_recovery_terminates_a_real_socket_that_holds_an_unread_message`).
    //
    // A proxy that stops READING client -> relay reaches the same two readings
    // through TCP backpressure, and was rejected rather than written: pushing
    // until `queue() > 0` proves nothing (the channel is 1024 deep and
    // `batch_msg` is a `try_send`, so any push loop outruns a healthy writer),
    // and the one shape that IS stable — a single message larger than every
    // buffer between the pool and the proxy, which blocks the writer in
    // `send_ws_msgs` — rests on this host's `tcp_wmem` ceiling and on
    // tungstenite's unbounded write buffer, against `WEBSOCKET_TX_TIMEOUT`'s
    // 10 s. It would observe the same status transition the test above already
    // observes, on machine properties no test here can read.
    // ------------------------------------------------------------------

    /// Which sockets the wedge check touches, over every status the pool can
    /// report. Both halves are promises, and they pull in opposite directions:
    /// a wedged socket MUST be freed, or the pool swallows events until the
    /// process restarts, and nothing else may be, because every needless
    /// termination is a handshake the next publish pays for in radio time.
    ///
    /// The expectations are written out rather than recomputed from the
    /// predicate, so the test states the intent instead of restating the code.
    #[test]
    fn only_a_connected_socket_holding_an_unread_message_is_freed() {
        let cases = [
            // The wedge: connected, and our bytes never left.
            (PoolRelayStatus::Connected, 1usize, true),
            (PoolRelayStatus::Connected, 9, true),
            // Connected and empty — the shape of every healthy publish, and of
            // a relay that took the event and answered slowly or not at all.
            (PoolRelayStatus::Connected, 0, false),
            // A task is still running towards a dialable status by itself.
            (PoolRelayStatus::Pending, 1, false),
            (PoolRelayStatus::Connecting, 1, false),
            (PoolRelayStatus::Disconnected, 1, false),
            // Already dialable: the next attempt reconnects without help.
            (PoolRelayStatus::Initialized, 1, false),
            (PoolRelayStatus::Terminated, 1, false),
            (PoolRelayStatus::Sleeping, 1, false),
            // Banned is the pool's refusal, never ours to overturn.
            (PoolRelayStatus::Banned, 1, false),
        ];

        for (status, unsent, expected) in cases {
            let terminated = std::cell::Cell::new(false);
            let freed = terminate_wedged_socket(status, unsent, || terminated.set(true));
            assert_eq!(
                freed, expected,
                "{status} with {unsent} unread message(s): freed={freed}, \
                 expected={expected}",
            );
            assert_eq!(
                terminated.get(),
                expected,
                "{status} with {unsent} unread message(s) must {} terminate \
                 the socket",
                if expected { "" } else { "not" },
            );
        }

        let covered: std::collections::HashSet<PoolRelayStatus> =
            cases.iter().map(|(status, ..)| *status).collect();
        assert_eq!(
            covered.len(),
            8,
            "every status the pool can report has to be decided here, or a \
             status nobody thought about decides itself: {covered:?}",
        );
    }

    /// One publish target's socket, modelling the three upstream rules that
    /// decide whether a publish reaches a relay: the pool re-dials only from a
    /// status `can_connect()` accepts (`status.rs:120-122`), a send is accepted
    /// whenever the status is `Connected` (`ensure_operational`,
    /// `inner.rs:238-274`), and a socket whose connection task was dropped
    /// keeps what it is handed in its channel instead of writing it
    /// (`inner.rs:74`, `:510-513`).
    struct FakeSocket {
        status: std::cell::Cell<PoolRelayStatus>,
        /// Messages handed to the socket that nothing has read.
        unsent: std::cell::Cell<usize>,
        /// Whether a connection task is draining the outbound channel.
        reading: std::cell::Cell<bool>,
        /// Whether the relay behind the socket answers what it receives.
        answers: std::cell::Cell<bool>,
        dials: std::cell::Cell<u32>,
        terminations: std::cell::Cell<u32>,
    }

    impl FakeSocket {
        /// A socket the pool left `Connected` with no connection task.
        fn wedged() -> Self {
            Self {
                status: std::cell::Cell::new(PoolRelayStatus::Connected),
                unsent: std::cell::Cell::new(0),
                reading: std::cell::Cell::new(false),
                answers: std::cell::Cell::new(true),
                dials: std::cell::Cell::new(0),
                terminations: std::cell::Cell::new(0),
            }
        }

        /// A live socket to a relay that never answers: it reads every byte
        /// Haven hands it and returns no `OK` — a slow relay, or one whose
        /// answer is lost on the way back.
        fn silent() -> Self {
            let socket = Self::wedged();
            socket.reading.set(true);
            socket.answers.set(false);
            socket
        }

        /// What [`RelayManager::add_relays_and_connect`] does to this socket
        /// before a send: a handshake, but only from a status the pool will
        /// dial.
        fn dial(&self) {
            if matches!(
                self.status.get(),
                PoolRelayStatus::Initialized
                    | PoolRelayStatus::Terminated
                    | PoolRelayStatus::Sleeping
            ) {
                self.dials.set(self.dials.get() + 1);
                self.status.set(PoolRelayStatus::Connected);
                self.reading.set(true);
            }
        }

        /// Offers one event; `true` when the relay acknowledged it. A reading
        /// socket drains its whole backlog, which is what the pool's connection
        /// task does with the channel it inherits.
        fn offer_event(&self) -> bool {
            if self.status.get() != PoolRelayStatus::Connected {
                return false;
            }
            if self.reading.get() {
                self.unsent.set(0);
                return self.answers.get();
            }
            self.unsent.set(self.unsent.get() + 1);
            false
        }

        /// `Relay::disconnect`: the socket goes, the channel's contents stay.
        fn terminate(&self) {
            self.terminations.set(self.terminations.get() + 1);
            self.status.set(PoolRelayStatus::Terminated);
            self.reading.set(false);
        }

        /// ONE publish attempt, in the order the production attempt runs it:
        /// connect, send, then free the socket if it turned out to be wedged.
        fn publish_attempt(&self) -> PublishResult {
            self.dial();
            let acked = self.offer_event();
            terminate_wedged_socket(self.status.get(), self.unsent.get(), || self.terminate());
            dummy_publish_result(acked)
        }
    }

    /// A target wedged on the first attempt is freed, and the SAME publish
    /// lands on the next one.
    ///
    /// This is the whole point of the mitigation: an MLS commit, a welcome or a
    /// key package is lost for good if the ladder gives up (Security Rule 13),
    /// and before this every attempt after the first queued into the same dead
    /// channel — three attempts, ~49 s of timeouts, zero bytes sent.
    #[tokio::test]
    async fn a_wedged_publish_target_is_freed_so_the_next_attempt_lands() {
        let socket = FakeSocket::wedged();

        let result = publish_with_retry(MAX_PUBLISH_ATTEMPTS, Duration::ZERO, |_| {
            let outcome = socket.publish_attempt();
            async move { Ok(outcome) }
        })
        .await;

        assert!(
            result
                .expect("the freed socket carries the retry")
                .is_success(),
            "a wedged relay must cost ONE publish attempt, not every publish \
             for the life of the process",
        );
        assert_eq!(
            socket.terminations.get(),
            1,
            "freed once, on the attempt that found it wedged",
        );
        assert_eq!(
            socket.dials.get(),
            1,
            "the worst case is ONE extra handshake per wedged target per \
             publish: the dial the freed socket needs to send at all",
        );
    }

    /// A relay that TOOK the publish and stayed silent keeps its socket, for
    /// the whole ladder.
    ///
    /// The power promise, and the reason the trigger reads the unsent count
    /// rather than "this relay did not acknowledge": a slow relay is
    /// indistinguishable from a silent one inside the ack window, and tearing
    /// it down would buy a fresh handshake on every publish — exactly the radio
    /// work `publish_relay_options` exists to remove.
    #[tokio::test]
    async fn a_silent_target_that_took_the_publish_keeps_its_socket() {
        let socket = FakeSocket::silent();

        let result = publish_with_retry(MAX_PUBLISH_ATTEMPTS, Duration::ZERO, |_| {
            let outcome = socket.publish_attempt();
            async move { Ok(outcome) }
        })
        .await;

        assert!(
            matches!(result, Err(RelayError::AllRelaysFailed)),
            "nothing acknowledged, so the publish still fails: {result:?}",
        );
        assert_eq!(
            socket.terminations.get(),
            0,
            "a socket that sent what it was given is never torn down, however \
             the publish ended",
        );
        assert_eq!(
            socket.dials.get(),
            0,
            "and not one extra handshake is paid for across the full ladder",
        );
    }

    /// On the LOCATION path a wedged target costs exactly one sample, and the
    /// next sample lands.
    ///
    /// [`LOCATION_PUBLISH_ATTEMPTS`] is 1, so the recovery has no attempt of
    /// its own to be rescued by: the sample that met the wedge is gone, and
    /// what the user is promised is that the wedge does not outlive it — the
    /// difference between one missing fix and a peer who never moves again
    /// until the app restarts. Two successive single-attempt publishes over one
    /// socket are exactly that promise, and the only place it is observable.
    #[tokio::test]
    async fn a_wedged_location_target_costs_one_sample_and_the_next_lands() {
        let socket = FakeSocket::wedged();
        let sample = || {
            publish_with_retry(LOCATION_PUBLISH_ATTEMPTS, Duration::ZERO, |_| {
                let outcome = socket.publish_attempt();
                async move { Ok(outcome) }
            })
        };

        let lost = sample().await;
        assert!(
            matches!(lost, Err(RelayError::AllRelaysFailed)),
            "the one attempt queued into the wedged socket, so this sample is \
             lost whatever the recovery does: {lost:?}",
        );

        assert!(
            sample()
                .await
                .expect("the freed socket carries the next sample")
                .is_success(),
            "the NEXT sample must land: with one attempt per publish, a wedge \
             that survives the publish that found it swallows every location \
             this device sends to that relay for the life of the process",
        );
        assert_eq!(
            socket.terminations.get(),
            1,
            "freed once, by the sample that found it wedged",
        );
        assert_eq!(
            socket.dials.get(),
            1,
            "and the second sample pays the one handshake that costs",
        );
    }

    /// The two readings the wedge check is built on, taken from a REAL pool
    /// socket in both directions.
    ///
    /// `Relay::queue()` counts the messages Haven handed the socket that its
    /// connection task has not read (`inner.rs:102-104` over the channel at
    /// `:74`), and the whole mitigation rests on that being zero exactly when
    /// the bytes left. Measured here after a publish the relay acknowledged,
    /// and after a send into a relay with no connection task at all — the
    /// second being the reading a wedged socket gives, on a relay the pool
    /// still accepts sends for.
    ///
    /// Single-threaded, and no await between the send and the reading, so no
    /// other task can run in between: the count is what the pool holds rather
    /// than a lucky sample.
    #[tokio::test(flavor = "current_thread")]
    async fn a_real_publish_socket_reads_empty_until_nothing_is_reading_it() {
        let _ = allow_ws_loopback_for_test();
        let server = LocalRelay::new(RelayBuilder::default());
        server.run().await.expect("local relay runs");
        let url = server.url().await.to_string();

        let manager = RelayManager::new();
        assert!(manager
            .publish_event(&throwaway_note("acknowledged"), std::slice::from_ref(&url))
            .await
            .expect("the relay is up")
            .is_success(),);

        let relay = manager
            .client
            .relay(url.as_str())
            .await
            .expect("the publish added the relay to the pool");
        assert_eq!(relay.status(), PoolRelayStatus::Connected);
        assert_eq!(
            relay.queue(),
            0,
            "a relay that acknowledged the publish read every byte of it",
        );
        assert!(
            !terminate_wedged_socket(relay.status(), relay.queue(), || panic!(
                "a socket that sent what it was given must never be terminated"
            )),
            "the shape every healthy publish leaves behind must not be read as \
             a wedge, or the pool re-handshakes on every send",
        );

        // Take the connection task away, then hand the socket another event:
        // `ensure_operational` still accepts it (it gates on a success rate,
        // not on the status), and nothing is left to read it.
        relay.disconnect();
        relay
            .batch_msg(vec![ClientMessage::event(throwaway_note("unread"))])
            .expect("the pool accepts a send it has nobody to write");
        assert_eq!(
            relay.queue(),
            1,
            "an unread message is what a socket with no reader looks like",
        );
        assert!(
            terminate_wedged_socket(PoolRelayStatus::Connected, relay.queue(), || {}),
            "that reading, on the `Connected` status the upstream race leaves \
             behind, is the wedge the check has to recognise",
        );
    }

    /// What the recovery DOES to a real pool socket it finds `Connected`
    /// holding an unread message: it terminates it, and the next publish dials
    /// a live one.
    ///
    /// The predicate's table above says which readings mean "wedged"; this says
    /// that `recover_wedged_publish_sockets` acts on them — the one link a
    /// modelled socket cannot make, because the thing being pinned is that the
    /// closure it hands the predicate really is the pool's `disconnect`. A
    /// mitigation whose closure did nothing would leave every reading below
    /// unchanged and every other test in this file green.
    ///
    /// Single-threaded, and the reading the recovery takes is the one the
    /// `batch_msg` two lines above it created: `yield_now` hands the connection
    /// task an empty channel and a fresh cooperative budget, and nothing
    /// between there and the recovery's own `client.relay()` (one uncontended
    /// read lock) can return `Pending`, so on one thread nothing else runs in
    /// between. The message is therefore unread for the same reason a wedged
    /// socket's is — nothing is reading it — rather than by a lucky sample.
    #[tokio::test(flavor = "current_thread")]
    async fn the_recovery_terminates_a_real_socket_that_holds_an_unread_message() {
        let _ = allow_ws_loopback_for_test();
        let server = LocalRelay::new(RelayBuilder::default());
        server.run().await.expect("local relay runs");
        let url = server.url().await.to_string();
        let relay_urls = vec![RelayUrl::parse(&url).expect("loopback url")];

        let manager = RelayManager::new();
        assert!(manager
            .publish_event(
                &throwaway_note("before the wedge"),
                std::slice::from_ref(&url)
            )
            .await
            .expect("the relay is up")
            .is_success(),);

        let relay = manager
            .client
            .relay(url.as_str())
            .await
            .expect("the publish added the relay to the pool");
        tokio::task::yield_now().await;
        assert_eq!(relay.status(), PoolRelayStatus::Connected);
        assert_eq!(relay.queue(), 0, "the finished publish left nothing unsent");

        relay
            .batch_msg(vec![ClientMessage::event(throwaway_note("unread"))])
            .expect("the pool accepts the send");
        assert_eq!(relay.queue(), 1);
        recover_wedged_publish_sockets(&manager.client, &relay_urls).await;

        assert_eq!(
            relay.status(),
            PoolRelayStatus::Terminated,
            "the recovery has to FREE the socket, not merely recognise it: a \
             relay left `Connected` here is one the pool will never re-dial and \
             will keep accepting sends it cannot write",
        );
        assert_eq!(
            relay.queue(),
            1,
            "what was already queued is not recovered — the event is lost and \
             only the socket comes back, which is why the ladder's next attempt \
             is what lands it",
        );
        assert!(
            manager
                .publish_event(&throwaway_note("after the wedge"), &[url])
                .await
                .expect("the next publish reconnects")
                .is_success(),
            "and freeing it must leave a target the very next publish reaches, \
             or the recovery trades a silent wedge for a dead relay",
        );
    }

    /// A loopback front door that can stop carrying what the relay SAYS while
    /// still carrying everything the client sends.
    ///
    /// This is how a test gets a relay that took the publish and never
    /// answered: `LocalRelay` has no hook for withholding an `OK`, and cutting
    /// the socket answers a different question — a cut socket terminates, a
    /// muted one stays `Connected` with an empty queue, which is the shape a
    /// slow relay has.
    struct MutingDoor {
        url: String,
        muted: std::sync::Arc<std::sync::atomic::AtomicBool>,
    }

    impl MutingDoor {
        async fn in_front_of(relay: &LocalRelay) -> Self {
            let target = relay
                .url()
                .await
                .as_str_without_trailing_slash()
                .trim_start_matches("ws://")
                .to_string();
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
                .await
                .expect("bind the front door");
            let url = format!("ws://{}", listener.local_addr().expect("local addr"));
            let muted = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
            let accepted = std::sync::Arc::clone(&muted);
            tokio::spawn(async move {
                while let Ok((inbound, _)) = listener.accept().await {
                    tokio::spawn(Self::splice(
                        inbound,
                        target.clone(),
                        std::sync::Arc::clone(&accepted),
                    ));
                }
            });
            Self { url, muted }
        }

        /// Carries one accepted connection. The relay's side is always READ —
        /// so the relay is never backpressured into looking slow — and only
        /// forwarded while the door is unmuted.
        async fn splice(
            inbound: tokio::net::TcpStream,
            target: String,
            muted: std::sync::Arc<std::sync::atomic::AtomicBool>,
        ) {
            use tokio::io::{AsyncReadExt, AsyncWriteExt};

            let Ok(outbound) = tokio::net::TcpStream::connect(target).await else {
                return;
            };
            let (mut from_client, mut to_client) = inbound.into_split();
            let (mut from_relay, mut to_relay) = outbound.into_split();
            let upstream = tokio::spawn(async move {
                let _ = tokio::io::copy(&mut from_client, &mut to_relay).await;
            });

            let mut buf = [0u8; 8192];
            loop {
                match from_relay.read(&mut buf).await {
                    Ok(0) | Err(_) => break,
                    Ok(read) => {
                        if !muted.load(std::sync::atomic::Ordering::SeqCst)
                            && to_client.write_all(&buf[..read]).await.is_err()
                        {
                            break;
                        }
                    }
                }
            }
            upstream.abort();
        }

        /// Drops everything the relay says from here on.
        fn mute(&self) {
            self.muted.store(true, std::sync::atomic::Ordering::SeqCst);
        }
    }

    /// A real relay that received the publish and answered nothing keeps its
    /// socket, and pays no new handshake.
    ///
    /// The power promise on a real socket, and the one case that separates this
    /// trigger from "terminate every target that did not acknowledge": the
    /// bytes DID leave, so there is nothing to recover — the relay was slow, or
    /// its answer was lost, and its socket is still the cheapest way to reach
    /// it.
    ///
    /// Costs one [`LOCATION_ACK_WINDOW`] of wall clock by construction: the
    /// answer is dropped on the floor, so the only way out is the window
    /// closing. Deterministic for the same reason — no `OK` can arrive.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_relay_that_took_the_publish_and_went_silent_keeps_its_socket() {
        let _ = allow_ws_loopback_for_test();
        let server = LocalRelay::new(RelayBuilder::default());
        server.run().await.expect("local relay runs");
        let door = MutingDoor::in_front_of(&server).await;
        let url = door.url.clone();

        let manager = RelayManager::new();
        assert!(manager
            .publish_event(&throwaway_note("heard"), std::slice::from_ref(&url))
            .await
            .expect("the relay is up")
            .is_success(),);

        let relay = manager
            .client
            .relay(url.as_str())
            .await
            .expect("the publish added the relay to the pool");
        let handshakes = relay.stats().attempts();
        door.mute();

        let silent = manager
            .publish_location_event(&throwaway_note("unanswered"), &[url])
            .await;
        assert!(
            matches!(silent, Err(RelayError::AllRelaysFailed)),
            "the relay's OK never reaches us, so nothing acknowledged: \
             {silent:?}",
        );
        assert_eq!(
            relay.queue(),
            0,
            "the publish LEFT — the socket read every byte of it, and what \
             went missing is the answer",
        );
        assert_eq!(
            relay.status(),
            PoolRelayStatus::Connected,
            "so the socket must survive: terminating a silent relay would \
             re-handshake it on every publish for as long as it stays slow",
        );
        assert_eq!(
            relay.stats().attempts(),
            handshakes,
            "and not one new handshake was paid for",
        );
    }

    /// The call every send path owes, and the three ways this file hands an
    /// event to a relay: the pooled fan-out, the harvest's per-relay unit, and
    /// the `Relay` handle's own send — which is what that unit uses, and what a
    /// new function written against a relay handle directly would use.
    const WEDGE_CHECK: &str = "recover_wedged_publish_sockets(";
    const SENDS: [&str; 3] = [
        "client.send_event_to(",
        "send_to_one(client,",
        "relay.send_event(",
    ];

    /// One production function, comment-free and whitespace-free.
    struct ScannedFn {
        name: String,
        code: String,
    }

    impl ScannedFn {
        /// Whether this body runs the wedge check after the LAST event it hands
        /// a relay — the promise itself. A check that runs before the send
        /// cannot observe the attempt it exists to repair, and reads as
        /// compliant to anything that only looks for the call.
        fn checks_after_sending(&self) -> bool {
            let last_send = SENDS.iter().filter_map(|send| self.code.rfind(send)).max();
            match (last_send, self.code.rfind(WEDGE_CHECK)) {
                (Some(send), Some(check)) => check > send,
                _ => false,
            }
        }

        fn sends(&self) -> bool {
            SENDS.iter().any(|send| self.code.contains(send))
        }
    }

    /// `line` up to the `//` that starts a comment, string literals respected.
    ///
    /// Without the literal state a `wss://` URL truncates its own line; without
    /// the strip, a commented-out call site counts as a call site.
    fn code_before_comment(line: &str) -> &str {
        let bytes = line.as_bytes();
        let mut in_string = false;
        let mut i = 0;
        while i < bytes.len() {
            match bytes[i] {
                b'\\' if in_string => i += 1,
                b'"' => in_string = !in_string,
                b'/' if !in_string && bytes.get(i + 1) == Some(&b'/') => return &line[..i],
                _ => {}
            }
            i += 1;
        }
        line
    }

    /// The name a function-declaring line declares, if it is one.
    ///
    /// Every modifier Rust allows before `fn` has to be stripped, `pub(crate)`
    /// included: a declaration this misses is not a function, so its body is
    /// appended to the previous one and inherits whatever THAT one does.
    fn declared_name(line: &str) -> Option<&str> {
        let mut rest = line.trim_start();
        loop {
            if let Some(after_pub) = rest.strip_prefix("pub(") {
                let close = after_pub.find(')')?;
                rest = after_pub[close + 1..].trim_start();
                continue;
            }
            match ["pub ", "async ", "const "]
                .iter()
                .find_map(|prefix| rest.strip_prefix(prefix))
            {
                Some(stripped) => rest = stripped.trim_start(),
                None => break,
            }
        }
        rest.strip_prefix("fn ")?.split(['(', '<', ' ']).next()
    }

    /// Every production function in `source`, in declaration order.
    ///
    /// Whitespace is squeezed out of each body so a call rustfmt broke over
    /// three lines is still the same call: `self\n.client\n.send_event_to(`
    /// matches nothing a line-at-a-time substring search looks for.
    fn scan_production_functions(source: &str) -> Vec<ScannedFn> {
        let production = &source[..source
            .find("#[cfg(test)]")
            .expect("this module's own tests are not production source")];
        assert!(
            !production.contains("/*"),
            "this scan strips `//` comments only, so a block comment would be \
             read back as code; teach `code_before_comment` about it rather \
             than trusting what it says about this file",
        );

        let mut functions: Vec<ScannedFn> = Vec::new();
        for line in production.lines() {
            let code = code_before_comment(line);
            if let Some(name) = declared_name(code) {
                functions.push(ScannedFn {
                    name: name.to_string(),
                    code: String::new(),
                });
            }
            if let Some(function) = functions.last_mut() {
                function
                    .code
                    .extend(code.chars().filter(|c| !c.is_whitespace()));
            }
        }
        functions
    }

    /// How a send path breaks the promise. Named rather than described, so a
    /// fixture asserts the fault it means instead of counting faults — a
    /// different fault arriving at the same count is how a blind spot hides.
    #[derive(Debug, PartialEq, Eq)]
    enum SendPathFault {
        /// Hands an event to a relay and nothing recovers the socket after: one
        /// left `Connected` with the event unsent swallows every later publish
        /// to that relay for the life of the process.
        NoWedgeCheck(String),
        /// Checks before the send it exists to repair, so it can only ever see
        /// the previous attempt's socket.
        CheckBeforeSend(String),
        /// A per-relay unit is covered by its callers — and this caller does
        /// not run the check after calling it.
        DelegatedToUnchecked { sender: String, caller: String },
    }

    /// Which functions hand an event to a relay, and which of them break the
    /// promise that the wedge check runs after they do.
    fn audit_send_paths(source: &str) -> (Vec<String>, Vec<SendPathFault>) {
        let functions = scan_production_functions(source);
        let mut senders = Vec::new();
        let mut faults = Vec::new();

        for function in functions.iter().filter(|f| f.sends()) {
            senders.push(function.name.clone());
            if function.checks_after_sending() {
                continue;
            }
            if function.code.contains(WEDGE_CHECK) {
                faults.push(SendPathFault::CheckBeforeSend(function.name.clone()));
                continue;
            }
            // Or it delegates: a per-relay unit whose every caller runs the
            // check after calling it is covered, and tearing the socket down
            // inside the unit would do it once per relay per attempt.
            let mut callers = functions
                .iter()
                .filter(|other| other.name != function.name)
                .filter(|other| other.code.contains(&format!("{}(", function.name)))
                .peekable();
            if callers.peek().is_none() {
                faults.push(SendPathFault::NoWedgeCheck(function.name.clone()));
            } else if let Some(unchecked) = callers.find(|caller| !caller.checks_after_sending()) {
                faults.push(SendPathFault::DelegatedToUnchecked {
                    sender: function.name.clone(),
                    caller: unchecked.name.clone(),
                });
            }
        }
        (senders, faults)
    }

    /// Every function that hands an event to a relay runs the wedge check
    /// afterwards — including one written after this.
    ///
    /// Structural, and deliberately so for the ORDER: what the check does is
    /// pinned against a real socket by
    /// `the_recovery_terminates_a_real_socket_that_holds_an_unread_message`,
    /// but that it runs after each production send cannot be, because a wedge
    /// cannot be built against a real pool in-process (see this section's
    /// header). A path that moved the call before its send, or stopped making
    /// it, would look identical from outside until a relay went silent forever
    /// in the field.
    #[test]
    fn every_function_that_sends_an_event_runs_the_wedge_check_after_sending() {
        let (senders, faults) = audit_send_paths(include_str!("manager.rs"));
        assert!(
            faults.is_empty(),
            "the publish paths have to recover a wedged socket AFTER handing it \
             an event: {faults:?}",
        );
        for expected in [
            "try_publish_once",
            "try_publish_once_harvesting",
            "publish_event_background",
            "send_to_one",
        ] {
            assert!(
                senders.iter().any(|name| name == expected),
                "the scan has to reach `{expected}` or it is reading nothing: \
                 {senders:?}",
            );
        }
    }

    /// Wraps a fixture as a whole production half, so the scan treats it the
    /// way it treats this file.
    fn fixture(production: &str) -> String {
        format!("{production}\n#[cfg(test)]\nmod tests {{}}\n")
    }

    /// A commented-out call site is not a call site.
    #[test]
    fn the_scan_reads_code_and_not_comments() {
        let (senders, faults) = audit_send_paths(&fixture(
            "async fn publish(client: &Client) {
                 client.send_event_to(urls, event).await;
                 // recover_wedged_publish_sockets(client, urls).await;
             }",
        ));
        assert_eq!(senders, ["publish"]);
        assert_eq!(
            faults,
            [SendPathFault::NoWedgeCheck("publish".to_string())],
            "a `//` in front of the call site is the whole of {WEDGE_CHECK}, \
             and it cannot be allowed to read as a call",
        );
    }

    /// A URL is not a comment: the literal that carries `wss://` keeps its
    /// line, or every send written on one is invisible to this scan.
    #[test]
    fn the_scan_keeps_a_line_that_carries_a_url_literal() {
        let (senders, faults) = audit_send_paths(&fixture(
            "async fn publish(client: &Client) {
                 let urls = [\"wss://relay.example.com\"]; client.send_event_to(urls, event).await;
             }",
        ));
        assert_eq!(senders, ["publish"]);
        assert_eq!(faults, [SendPathFault::NoWedgeCheck("publish".to_string())]);
    }

    /// A call rustfmt broke over lines is still that call.
    #[test]
    fn the_scan_follows_a_send_split_over_lines() {
        let (senders, faults) = audit_send_paths(&fixture(
            "async fn publish(&self) {
                 let _sent = self
                     .client
                     .send_event_to(urls, event)
                     .await;
             }",
        ));
        assert_eq!(senders, ["publish"], "the split send has to be found");
        assert_eq!(faults, [SendPathFault::NoWedgeCheck("publish".to_string())]);
    }

    /// A `pub(crate)` body belongs to itself, not to whatever came before it.
    #[test]
    fn the_scan_attributes_a_pub_crate_body_to_its_own_function() {
        let (senders, faults) = audit_send_paths(&fixture(
            "async fn checked(client: &Client) {
                 client.send_event_to(urls, event).await;
                 recover_wedged_publish_sockets(client, urls).await;
             }

             pub(crate) async fn unchecked(client: &Client) {
                 client.send_event_to(urls, event).await;
             }",
        ));
        assert_eq!(senders, ["checked", "unchecked"], "{senders:?}");
        assert_eq!(
            faults,
            [SendPathFault::NoWedgeCheck("unchecked".to_string())],
            "a declaration the scan misses appends its body to the function \
             before it, where it inherits that one's check",
        );
    }

    /// The `Relay` handle's own send counts as handing an event to a relay.
    #[test]
    fn the_scan_knows_the_relay_handles_own_send() {
        let (senders, faults) = audit_send_paths(&fixture(
            "async fn hand_it_over(relay: &Relay, event: &Event) {
                 let _ = relay.send_event(event).await;
             }",
        ));
        assert_eq!(senders, ["hand_it_over"], "{senders:?}");
        assert_eq!(
            faults,
            [SendPathFault::NoWedgeCheck("hand_it_over".to_string())],
        );
    }

    /// A check that runs before the send is not a check.
    #[test]
    fn the_scan_rejects_a_check_that_runs_before_the_send() {
        let (_, faults) = audit_send_paths(&fixture(
            "async fn publish(client: &Client) {
                 recover_wedged_publish_sockets(client, urls).await;
                 client.send_event_to(urls, event).await;
             }",
        ));
        assert_eq!(
            faults,
            [SendPathFault::CheckBeforeSend("publish".to_string())],
            "a check that runs first never sees the socket its own attempt \
             wedged, and reads as compliant to anything that only looks for \
             the call",
        );
    }

    /// A per-relay unit is covered by its callers, and only while they cover
    /// it.
    #[test]
    fn the_scan_accepts_a_send_unit_every_caller_checks_after() {
        let delegating = "async fn send_to_one(client: &Client, url: &RelayUrl) {
                 let _ = relay.send_event(event).await;
             }";
        let (senders, faults) = audit_send_paths(&fixture(&format!(
            "{delegating}

             async fn harvest(client: &Client) {{
                 let _outcomes = urls.map(|url| send_to_one(client, url, event, bound));
                 recover_wedged_publish_sockets(client, urls).await;
             }}",
        )));
        assert_eq!(senders, ["send_to_one", "harvest"], "{senders:?}");
        assert_eq!(
            faults,
            [],
            "the caller checks after the call, so both are covered and the unit \
             must not be asked to tear a socket down once per relay"
        );

        let (_, reversed) = audit_send_paths(&fixture(&format!(
            "{delegating}

             async fn harvest(client: &Client) {{
                 recover_wedged_publish_sockets(client, urls).await;
                 let _outcomes = urls.map(|url| send_to_one(client, url, event, bound));
             }}",
        )));
        assert_eq!(
            reversed,
            [
                SendPathFault::DelegatedToUnchecked {
                    sender: "send_to_one".to_string(),
                    caller: "harvest".to_string(),
                },
                SendPathFault::CheckBeforeSend("harvest".to_string()),
            ],
            "the delegation is good only while the caller's check follows the \
             call",
        );
    }

    /// A REQ Haven forgets to close is a socket that can never sleep:
    /// `should_sleep` is false while ANY subscription is registered
    /// (`nostr-relay-pool-0.44.3 inner.rs:444-456`), and this pool no longer
    /// pings, so such a socket stays open carrying nothing at all.
    ///
    /// Two assertions, because neither can see the other's leak.
    /// `subscriptions()` reports only LONG-LIVED registrations (`inner.rs:294`
    /// filters the auto-closing ones out) — the `subscribe_to` class, caught
    /// the instant a fetch returns. The auto-closing REQs are invisible there
    /// and are covered by the socket actually reaching `Sleeping`, which reads
    /// the unfiltered map.
    ///
    /// # What is driven, and what is NOT
    ///
    /// Two of `read_one_relays_answer`'s exits run here: the clean `EOSE`, and
    /// the `CLOSED` arm — the interesting one, because it returns while the
    /// pool's own auto-close handler is still waiting for an `EOSE` that will
    /// never come, which is why that arm sends its own `CLOSE`.
    ///
    /// Its remaining exits are NOT covered by this test and are unproven here:
    /// the intake cap (an in-process relay serves a bounded fixture, so it never
    /// overflows) and the outer [`DEFAULT_TIMEOUT`], which would need a relay
    /// that accepts the REQ and then goes silent for ten seconds — a wall-clock
    /// cost with no way to shorten it, since the bound is a production constant
    /// rather than an injected one. Both exits return `drained == false` through
    /// the same tail as the `CLOSED` arm, so what is unproven is the exit
    /// CONDITION, not the cleanup that follows it.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn every_fetch_primitive_leaves_no_subscription_registered() {
        let _ = allow_ws_loopback_for_test();
        let refused_author = nostr::Keys::generate().public_key();
        let server =
            LocalRelay::new(RelayBuilder::default().query_policy(RefuseAuthor(refused_author)));
        server.run().await.expect("local relay runs");
        let url = server.url().await.to_string();
        let relays = vec![url.clone()];

        let manager = RelayManager::new();
        let answered = Filter::new().kind(Kind::TextNote).limit(4);
        let refused = Filter::new().author(refused_author).limit(4);

        manager
            .fetch_events(answered.clone(), &relays, None)
            .await
            .expect("the relay answers");
        assert_no_long_lived_subscription(&manager, "fetch_events").await;

        manager
            .check_event_on_relay(&url, answered.clone())
            .await
            .expect("the relay answers");
        assert_no_long_lived_subscription(&manager, "check_event_on_relay").await;

        let drained = manager
            .fetch_events_per_relay(answered, &relays)
            .await
            .expect("per-relay probe never fails as a whole");
        assert!(
            drained[0].drained,
            "the relay served this filter, so the page ends at an EOSE: {drained:?}",
        );
        assert_no_long_lived_subscription(&manager, "fetch_events_per_relay (EOSE)").await;

        let closed = manager
            .fetch_events_per_relay(refused, &relays)
            .await
            .expect("per-relay probe never fails as a whole");
        assert!(closed[0].responded, "the socket was up: {closed:?}");
        assert!(
            !closed[0].drained,
            "a relay that CLOSED the REQ never vouched for the page: {closed:?}",
        );
        assert_no_long_lived_subscription(&manager, "fetch_events_per_relay (CLOSED)").await;

        let relay = manager
            .client
            .relay(url.as_str())
            .await
            .expect("the fetches added the relay to the pool");
        let mut notifications = relay.notifications();
        assert_eq!(
            next_relay_status(&mut notifications, wait_budget(180)).await,
            Some(nostr_sdk::RelayStatus::Sleeping),
            "a socket the fetches left a REQ on can never sleep, and this pool \
             sends no keepalive — it would stay open forever carrying nothing",
        );
    }

    /// Fails with the name of the primitive that left a REQ behind, so a red
    /// run names the leak instead of only reporting a non-empty map.
    async fn assert_no_long_lived_subscription(manager: &RelayManager, after: &str) {
        let registered = manager.client.subscriptions().await;
        assert!(
            registered.is_empty(),
            "{after} left a long-lived subscription registered; the socket can \
             never sleep while one exists: {registered:?}",
        );
    }

    // ------------------------------------------------------------------
    // Location publish: ONE bounded fan-out, never a retry.
    //
    // A location sample is neither durable nor worth a ladder — the next tick
    // carries a fresher position within 168 s — so the entire budget is one
    // attempt bounded by `CONNECTION_TIMEOUT + LOCATION_ACK_WINDOW`. What must
    // survive from the 3-attempt ladder is its ERROR contract, which Dart
    // matches on (`AllRelaysFailed`, `DeviceClockRejected`).
    // ------------------------------------------------------------------

    /// The whole location ladder costs one attempt and nothing else: no
    /// backoff (there is no second attempt to space) and no second connect.
    /// Worst case is `CONNECTION_TIMEOUT + LOCATION_ACK_WINDOW` = 10 s, which
    /// is what bounds how long one publish keeps the radio awake.
    ///
    /// Driven through the REAL [`publish_with_retry`] with the REAL constants,
    /// on a pure attempt future: the ladder's arithmetic is the thing under
    /// test, and a socket would only add a race to it.
    #[tokio::test(start_paused = true)]
    async fn location_ladder_worst_case_equals_one_publish_attempt() {
        let attempts = std::cell::Cell::new(0u32);

        let started = tokio::time::Instant::now();
        let result = publish_with_retry(LOCATION_PUBLISH_ATTEMPTS, Duration::ZERO, |_| {
            attempts.set(attempts.get() + 1);
            async {
                // The worst one attempt can cost: a full handshake against a
                // relay that never completes it, then a fan-out that returns
                // at its own window because nothing answered.
                tokio::time::sleep(CONNECTION_TIMEOUT).await;
                let _ = tokio::time::timeout(LOCATION_ACK_WINDOW, futures::future::pending::<()>())
                    .await;
                Ok(dummy_publish_result(false))
            }
        })
        .await;

        assert!(
            matches!(result, Err(RelayError::AllRelaysFailed)),
            "a publish no relay acknowledged is still an error, so Dart's \
             existing failure handling is unchanged",
        );
        assert_eq!(
            attempts.get(),
            1,
            "a location is never re-sent: the retry would spend a second wake \
             on a position the next tick already supersedes",
        );
        assert_eq!(
            started.elapsed(),
            CONNECTION_TIMEOUT + LOCATION_ACK_WINDOW,
            "one connect plus one per-relay window is the whole budget",
        );
        assert_eq!(
            started.elapsed(),
            Duration::from_secs(10),
            "the documented worst case moved",
        );

        let commit_ladder = (CONNECTION_TIMEOUT + DEFAULT_TIMEOUT)
            .saturating_mul(MAX_PUBLISH_ATTEMPTS)
            + PUBLISH_RETRY_BACKOFF.saturating_mul(MAX_PUBLISH_ATTEMPTS - 1);
        assert!(
            started.elapsed() * 4 < commit_ladder,
            "the point of the location path is that it is a fraction of the \
             ladder a commit still pays: {:?} vs {commit_ladder:?}",
            started.elapsed(),
        );
    }

    /// Counts every event a relay was asked to store and refuses each one with
    /// `reason`, so "how many times was this relay asked" is observable from
    /// the test rather than inferred from timing.
    #[derive(Debug)]
    struct RefuseAndCount {
        reason: String,
        seen: std::sync::Arc<std::sync::atomic::AtomicUsize>,
    }

    impl nostr_relay_builder::prelude::WritePolicy for RefuseAndCount {
        fn admit_event<'a>(
            &'a self,
            _event: &'a Event,
            _addr: &'a std::net::SocketAddr,
        ) -> BoxedFuture<'a, PolicyResult> {
            Box::pin(async move {
                self.seen.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                PolicyResult::Reject(self.reason.clone())
            })
        }
    }

    /// A relay that refuses every event with `reason`, plus the counter of how
    /// many events it was offered.
    async fn refusing_relay(
        reason: &str,
    ) -> (
        LocalRelay,
        String,
        std::sync::Arc<std::sync::atomic::AtomicUsize>,
    ) {
        let seen = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let server = LocalRelay::new(RelayBuilder::default().write_policy(RefuseAndCount {
            reason: reason.to_string(),
            seen: std::sync::Arc::clone(&seen),
        }));
        server.run().await.expect("local relay runs");
        let url = server.url().await.to_string();
        (server, url, seen)
    }

    /// One relay that never answers must not extend the publish past its own
    /// window, and must not cost the ack the other relay gave.
    ///
    /// # Why the wall-clock bound is two-sided, and tight
    ///
    /// [`LOCATION_ACK_WINDOW`] is the only thing that decides how long ONE
    /// location tick holds the modem awake, and nothing else pins its VALUE: a
    /// window widened to [`DEFAULT_TIMEOUT`] keeps every other assertion in this
    /// file green (the outcome partition is identical) while a wedged relay
    /// holds the radio for 15 s instead of 10. So the upper bound is the
    /// documented sum plus a small scaled slack, not "twice the contract".
    ///
    /// The lower bound is that same sum, because the wedged relay forces BOTH
    /// phases in sequence: the WebSocket handshake can only end at
    /// [`CONNECTION_TIMEOUT`], and the send that follows can only end at the ack
    /// window. A timer never fires early, so this cannot flake — and it is what
    /// catches the opposite regression, a window cut so short that a healthy but
    /// slow relay is recorded silent.
    ///
    /// The arithmetic of the LADDER (one attempt, no backoff) is pinned without
    /// a socket by `location_ladder_worst_case_equals_one_publish_attempt`.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn publish_location_event_folds_a_stalled_relay_after_its_own_window() {
        let _ = allow_ws_loopback_for_test();
        let fast = LocalRelay::new(RelayBuilder::default());
        fast.run().await.expect("local relay runs");
        let relays = vec![fast.url().await.to_string(), hung_relay_url().await];
        let expected = RelayManager::validate_relay_urls(&relays)
            .expect("ws:// loopback urls validate with the opt-in installed");

        let manager = RelayManager::new();
        let started = std::time::Instant::now();
        let result = manager
            .publish_location_event(&throwaway_note("one live relay is enough"), &relays)
            .await
            .expect("one relay accepted, so the publish succeeded");
        let elapsed = started.elapsed();

        assert_eq!(
            result.accepted_by,
            vec![expected[0].to_string()],
            "a location needs one ack, and it got one: {result:?}",
        );
        assert_eq!(
            result.failed,
            vec![expected[1].to_string()],
            "the relay that never spoke is silent, not a rejection: {result:?}",
        );
        assert!(
            result.rejected_by.is_empty(),
            "nobody refused this event: {result:?}",
        );
        assert!(
            elapsed >= CONNECTION_TIMEOUT + LOCATION_ACK_WINDOW,
            "the wedged relay forces the connect timeout and then the full ack \
             window; finishing sooner means one of the two was shortened, and a \
             shortened ack window records a healthy-but-slow relay as silent; \
             took {elapsed:?}",
        );
        assert!(
            elapsed < CONNECTION_TIMEOUT + LOCATION_ACK_WINDOW + wait_budget(3),
            "a wedged relay must not hold the radio awake past this publish's \
             own bound of {:?}; took {elapsed:?}. Widening LOCATION_ACK_WINDOW \
             to DEFAULT_TIMEOUT changes no outcome anywhere else in this file — \
             this is the assertion that costs it",
            CONNECTION_TIMEOUT + LOCATION_ACK_WINDOW,
        );
    }

    /// Zero acks is an error, and the refused event is offered exactly once.
    ///
    /// Both halves in one test on purpose: "never retries" is only meaningful
    /// on the outcome that WOULD retry on the commit ladder.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn publish_location_event_never_retries() {
        let _ = allow_ws_loopback_for_test();
        let (_server, url, seen) = refusing_relay("rate-limited: slow down").await;

        let manager = RelayManager::new();
        let result = manager
            .publish_location_event(&throwaway_note("refused everywhere"), &[url])
            .await;

        assert!(
            matches!(result, Err(RelayError::AllRelaysFailed)),
            "no relay acknowledged, so the publish failed: {result:?}",
        );
        assert_eq!(
            seen.load(std::sync::atomic::Ordering::SeqCst),
            1,
            "the location was offered once; a retry spends another radio wake \
             re-sending a position the next tick supersedes",
        );
    }

    /// One relay's `OK true` is the whole success condition — but the relay
    /// that said `OK false` still has to survive into the result, because that
    /// is the only place a clock verdict can be read from.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn publish_location_event_succeeds_on_one_ok_and_still_reports_the_refusal() {
        let _ = allow_ws_loopback_for_test();
        let accepting = LocalRelay::new(RelayBuilder::default());
        accepting.run().await.expect("local relay runs");
        let (_refuser, refused_url, _seen) = refusing_relay("rate-limited: slow down").await;
        let relays = vec![accepting.url().await.to_string(), refused_url];
        let expected = RelayManager::validate_relay_urls(&relays)
            .expect("ws:// loopback urls validate with the opt-in installed");

        let manager = RelayManager::new();
        let result = manager
            .publish_location_event(&throwaway_note("one ack is enough"), &relays)
            .await
            .expect("one relay accepted");

        assert!(result.is_success());
        assert_eq!(
            result.accepted_by,
            vec![expected[0].to_string()],
            "only the relay that returned OK true accepted it: {result:?}",
        );
        assert_eq!(
            result.rejected_by.len(),
            1,
            "the refusal is an answer and must be reported: {result:?}",
        );
        assert_eq!(result.rejected_by[0].0, expected[1].to_string());
        assert!(result.failed.is_empty(), "both relays answered: {result:?}");
    }

    /// The one error contract Dart acts on rather than merely reports.
    ///
    /// `nostr_relay_service.dart` maps this variant's token to
    /// `RelayClockRejectionException`, which drives the clock-skew banner
    /// (`b8_clock_skew_test.dart` pins the branch on the production service).
    /// Dropping the ladder around the fan-out would silently flatten it to
    /// `AllRelaysFailed` and the fast-clock outage would go quiet again.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn publish_location_event_reports_a_clock_rejection_without_retrying() {
        let _ = allow_ws_loopback_for_test();
        let (_server, url, seen) = refusing_relay("created_at is in the future").await;

        let manager = RelayManager::new();
        let result = manager
            .publish_location_event(&throwaway_note("too new for this relay"), &[url])
            .await;

        assert!(
            matches!(
                result,
                Err(RelayError::DeviceClockRejected {
                    complaint: clock_skew::DeviceClockComplaint::Ahead,
                }),
            ),
            "the relay said the timestamp was in the future, and that verdict \
             is the one publish failure the user can act on: {result:?}",
        );
        assert_eq!(
            seen.load(std::sync::atomic::Ordering::SeqCst),
            1,
            "a hopeless clock rejection is not retried either",
        );
    }

    /// Captures `log` records emitted on the CURRENT thread while armed.
    ///
    /// Thread-local, so a test that arms it sees only its own records however
    /// many other tests run beside it; the publish under test runs on a
    /// current-thread runtime, so every line it emits lands here.
    struct ThreadLocalCapture;

    thread_local! {
        static CAPTURED: std::cell::RefCell<Option<Vec<String>>> =
            const { std::cell::RefCell::new(None) };
    }

    impl log::Log for ThreadLocalCapture {
        fn enabled(&self, _metadata: &log::Metadata<'_>) -> bool {
            true
        }

        fn log(&self, record: &log::Record<'_>) {
            // Haven's own lines only. Everything else on this thread belongs to
            // the in-process relay and the WebSocket stack, which log whole
            // frames at trace — including the relay's own refusal prose. What
            // this app promises about its diagnostics is what THIS crate
            // writes.
            if !record.target().starts_with("haven_core") {
                return;
            }
            CAPTURED.with_borrow_mut(|captured| {
                if let Some(lines) = captured.as_mut() {
                    lines.push(record.args().to_string());
                }
            });
        }

        fn flush(&self) {}
    }

    /// Runs `body` with capture armed on this thread and returns what it
    /// logged.
    async fn capture_log_lines(body: impl std::future::Future<Output = ()>) -> Vec<String> {
        static INSTALL: std::sync::Once = std::sync::Once::new();
        /// Whether OUR logger won the process-wide slot. `log` allows exactly
        /// one logger per process and reports the loser only as an `Err` from
        /// `set_boxed_logger` — a value a `let _ =` throws away. Any future
        /// helper that installs its own logger would therefore make this one
        /// capture NOTHING, and the anti-vacuity assertions below would be the
        /// only thing standing between that and a silently green test. Record
        /// the verdict and fail on it directly instead.
        static OWNS_LOGGER: std::sync::atomic::AtomicBool =
            std::sync::atomic::AtomicBool::new(false);
        INSTALL.call_once(|| {
            OWNS_LOGGER.store(
                log::set_boxed_logger(Box::new(ThreadLocalCapture)).is_ok(),
                std::sync::atomic::Ordering::SeqCst,
            );
            log::set_max_level(log::LevelFilter::Trace);
        });
        assert!(
            OWNS_LOGGER.load(std::sync::atomic::Ordering::SeqCst),
            "another logger already owns this process, so this capture sees \
             nothing at all. `log` permits exactly one; whoever installed the \
             other one has to route through ThreadLocalCapture instead.",
        );

        CAPTURED.with_borrow_mut(|captured| *captured = Some(Vec::new()));
        body.await;
        CAPTURED
            .with_borrow_mut(Option::take)
            .expect("capture was armed above")
    }

    /// The location publish names no relay in its own log lines: the relay set
    /// a device publishes to is linkable metadata, and a relay's refusal text
    /// is remote prose (Rule 8).
    ///
    /// The connect helper's per-URL debug lines are shared by every publish
    /// path and predate this packet, so they are exempted BY PREFIX — which
    /// means a NEW url-bearing line, or a rename of one of theirs, fails here
    /// rather than being silently swallowed by the exemption.
    #[tokio::test]
    async fn publish_location_event_logs_counts_only() {
        /// The pre-existing per-URL debug lines of
        /// [`RelayManager::add_relays_and_connect`], shared by every publish
        /// path and unchanged by the location one.
        const CONNECT_PHASE_PREFIXES: &[&str] = &[
            "[RelayManager] add_relay(",
            "[RelayManager] connected to ",
            "[RelayManager] failed to connect to ",
        ];

        let _ = allow_ws_loopback_for_test();
        // Every bucket of the fold is non-empty, so a summary that printed any
        // of them instead of counting them leaks a url here: one relay refuses
        // (with prose it chose), one accepts, and nothing listens on the third
        // port at all.
        let (_refuser, refused_url, _seen) =
            refusing_relay("blocked because wss://leak.example said so").await;
        let accepting = LocalRelay::new(RelayBuilder::default());
        accepting.run().await.expect("local relay runs");
        let relays = vec![
            refused_url,
            accepting.url().await.to_string(),
            format!("ws://127.0.0.1:{}", ephemeral_port().await),
        ];

        let manager = RelayManager::new();
        let lines = capture_log_lines(async {
            manager
                .publish_location_event(&throwaway_note("who is listening"), &relays)
                .await
                .expect("one relay accepted");
        })
        .await;

        let is_connect_phase =
            |line: &String| CONNECT_PHASE_PREFIXES.iter().any(|p| line.starts_with(p));

        assert!(
            lines.iter().any(is_connect_phase),
            "nothing was captured, so this test proves nothing: {lines:?}",
        );
        assert!(
            lines
                .iter()
                .any(|line| line.starts_with("[RelayManager] publish_location_event:")),
            "the publish path has to have spoken for its silence to mean \
             anything: {lines:?}",
        );
        assert!(
            lines
                .iter()
                .any(|line| line.starts_with("[RelayManager] publish harvest:")),
            "the fan-out's summary is the line most likely to grow a url, so \
             it has to be present: {lines:?}",
        );
        for line in lines.iter().filter(|line| !is_connect_phase(line)) {
            assert!(
                !line.contains("ws://") && !line.contains("wss://"),
                "a location publish must not name a relay: {line}",
            );
        }
    }
}
