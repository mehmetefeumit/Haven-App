//! Relay manager for Nostr event publishing and subscription.
//!
//! This module provides a relay manager that handles all communication
//! with Nostr relays via direct WSS connections.
//!
//! # Security Model
//!
//! - **WSS Only**: Plaintext ws:// connections are rejected

use std::borrow::Cow;
use std::collections::{HashMap, HashSet};
use std::net::IpAddr;
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use cgka_traits::app_components::{is_loopback_host, is_public_ip};
use cgka_traits::TransportEndpoint;
#[cfg(debug_assertions)]
use nostr::Url;
use nostr::{
    ClientMessage, Event, EventId, Filter, Kind, PublicKey, RelayMessage, RelayUrl, SubscriptionId,
};
use nostr_sdk::pool::relay::{RelayNotification, RelayServiceFlags, ReqExitPolicy};
// The pool's own per-socket status, aliased because `super::types` exports a
// Haven `RelayStatus` of its own (the UI-facing one).
use nostr_sdk::RelayStatus as PoolRelayStatus;
use nostr_sdk::{
    Client, ClientOptions, Relay, RelayOptions, SubscribeAutoCloseOptions, SubscribeOptions,
};
use transport_nostr_adapter::{NostrRelayClient, NostrSdkRelayClient};
use url::Host;

use super::clock_skew;
use super::discovery::discovery_relays;
use super::error::{InvalidUrlReason, RelayError, RelayResult};
use super::fanout::{self, FanoutTargetOutcome};
use super::maintenance::key_package::{
    is_pre_migration_key_package_of, kp_event_d_tag, KeyPackageCandidate,
};
use super::types::{PublishResult, RelayConnectionStatus, RelayFetchOutcome, RelayStatus};
use super::url_norm;
use super::verified::verified_client;
use crate::circle::MemberKeyPackage;
use crate::log_alias::{self, bucket, RelayUrl as AliasRelayUrl};
use crate::nostr::mls::types::{
    KeyPackageAdmissionRule, TransportEndpointFailureKind, TransportMessage,
};

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

/// A user's NIP-65 relay list (kind 10002), split by marker.
///
/// No `Debug`: every field is a relay URL (Security Rule 15).
#[derive(Clone, Default, PartialEq, Eq)]
pub struct Nip65Relays {
    /// Where the user reads: unmarked and `read` entries.
    pub read: Vec<String>,
    /// Where the user writes, so where others fetch the user's events —
    /// `KeyPackage`s included: unmarked and `write` entries.
    pub write: Vec<String>,
}

/// Most relays Haven takes from ONE other account's relay list (10002 or 10050).
///
/// The list is that account's to write and every entry is a socket this device
/// opens. MDK bounds a relay route at the same number (`marmot-app`
/// `relay_plane/safety.rs:12` @v0.10.4; `transport-nostr-peeler`
/// `MAX_WELCOME_RELAYS`).
const MAX_FOREIGN_LIST_RELAYS: usize = 16;

/// Timeout for waiting for relay WebSocket connections to establish.
pub const CONNECTION_TIMEOUT: Duration = Duration::from_secs(5);

/// Maximum number of attempts (initial try + retries) for [`RelayManager::publish_event`].
///
/// The first publish after a cold start — e.g. the app foregrounds and the
/// previous WebSocket was closed on background — races the 5 s connection
/// handshake against the per-event `OK` acknowledgement. When the handshake
/// loses that race the relay never acknowledges in time, `accepted_by` comes
/// back empty, and the event (a welcome, a key package, a relay list) is
/// silently dropped. Retrying re-drives
/// [`RelayManager::add_relays_and_connect`] — a fast no-op once the socket is
/// warm — and republishes the **same** event id, which relays dedupe by id, so
/// the retry is idempotent and lands on the now-established connection.
///
/// This ladder is worth its cost precisely for what it carries: an event no
/// fanout record holds, which nothing re-sends once this call gives up. A
/// commit never comes here — it leaves only through the fanout driver
/// (Security Rule 13) — and a location, superseded by the next tick, is sent
/// once by the driver.
///
/// Worst case (a genuinely unreachable relay): ~3 × (`CONNECTION_TIMEOUT` +
/// `DEFAULT_TIMEOUT`) + 2 × `PUBLISH_RETRY_BACKOFF` ≈ 49 s before
/// `AllRelaysFailed` surfaces.
const MAX_PUBLISH_ATTEMPTS: u32 = 3;

/// The longest [`RelayManager::publish_event`] takes with relays that never
/// answer, in milliseconds: every attempt's connect and wait, and the pauses
/// between them. The wait for a relay another send holds is not in it.
pub const PUBLISH_LADDER_MS: u64 = (MAX_PUBLISH_ATTEMPTS as u64
    * (CONNECTION_TIMEOUT.as_secs() + DEFAULT_TIMEOUT.as_secs())
    + (MAX_PUBLISH_ATTEMPTS as u64 - 1) * PUBLISH_RETRY_BACKOFF.as_secs())
    * 1_000;

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

/// The longest one location send holds the radio: the connect and the
/// acknowledgement window, once. What a location's record must have left
/// before its expiration for a send to be begun.
pub const LOCATION_SEND_MS: u64 =
    (CONNECTION_TIMEOUT.as_secs() + LOCATION_ACK_WINDOW.as_secs()) * 1_000;
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
/// from `Sleeping`, and from a `Terminated` its own task reached, inside the
/// caller's own wake. A relay Haven disconnects is dropped from the pool instead
/// (see [`RelayManager::shutdown`]).
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
/// `a_second_add_of_the_same_url_never_restores_ping`, which re-runs every
/// path that registers a relay against one the pool already holds. They all
/// register through [`RelayManager::register_publish_relays`].
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
/// `Connecting` still have a task that will reach a dialable status by itself
/// (save a dial its caller dropped, which leaves `Connecting` with none: the
/// residual of tracker `T-POOL-TERMINATE-PERMIT`),
/// `Disconnected` belongs to a retrying task this pool never has
/// (`reconnect(false)`), and `Sleeping` / `Terminated` are dialable unless
/// Haven disconnected the relay, which it then drops (see
/// [`RelayManager::shutdown`]).
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
/// A freed relay is dropped from the pool, and the next send registers a fresh
/// one: a wedge has no connection task, so its `disconnect` leaves a permit
/// that would end the next dial (see [`RelayManager::shutdown`]). It touches
/// nothing but the publish pool's own sockets.
async fn recover_wedged_publish_sockets(client: &Client, relay_urls: &[RelayUrl]) {
    let mut freed: usize = 0;
    for url in relay_urls {
        if let Ok(relay) = client.relay(url.as_str()).await {
            if terminate_wedged_socket(relay.status(), relay.queue(), || relay.disconnect()) {
                let _ = client.force_remove_relay(url.as_str()).await;
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
/// only drains a device that is already failing to share location. That
/// holds however old the event is; `age_secs` — how long ago it was signed,
/// read when a refusal is classified — decides only whether the refusal is
/// said to be about this device's clock ([`clock_skew::on_this_clock`]).
async fn publish_with_retry<F, Fut>(
    max_attempts: u32,
    backoff: Duration,
    age_secs: impl Fn() -> u64,
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
                let hopeless = clock_skew::publish_retry_is_hopeless(accepted, &result.rejected_by);
                // Preserve the historical contract that a fully unacknowledged
                // publish with no stated cause is `AllRelaysFailed`.
                last_err = RelayError::AllRelaysFailed;
                if let Some(complaint) =
                    clock_skew::classify_publish_outcome(accepted, &result.rejected_by)
                        .and_then(|complaint| clock_skew::on_this_clock(complaint, age_secs()))
                {
                    log::warn!(
                        "[RelayManager] publish rejected on timestamp grounds \
                         (device clock {}); not retrying={hopeless}",
                        complaint.wire_token(),
                    );
                    last_err = RelayError::DeviceClockRejected { complaint };
                }
                if hopeless {
                    return Err(last_err);
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
    /// What a publish reads an event's age off ([`SecondsClock`]).
    clock: SecondsClock,
    /// MDK's relay client over [`Self::client`], built on first use
    /// ([`Self::fanout_transport`]).
    relay_client: OnceLock<Arc<dyn NostrRelayClient>>,
    /// One fanout call per relay at a time on this pool — see
    /// [`FanoutTransport::publish`].
    fanout_gates: FanoutGates,
}

/// Unix seconds now, as a publish reads off it how long ago an event was
/// signed ([`clock_skew::on_this_clock`]): the device's clock, or one a test
/// sets.
type SecondsClock = Arc<dyn Fn() -> u64 + Send + Sync>;

fn device_clock() -> SecondsClock {
    Arc::new(|| nostr::Timestamp::now().as_secs())
}

/// How long ago `event` was signed by `clock`, read each time it is asked.
fn age_on<'a>(clock: &'a SecondsClock, event: &Event) -> impl Fn() -> u64 + 'a {
    let signed_at = event.created_at.as_secs();
    move || clock().saturating_sub(signed_at)
}

/// A lock per relay a fanout has been sent to, shared by every
/// [`FanoutTransport`] of one manager.
type FanoutGates = Arc<std::sync::Mutex<HashMap<RelayUrl, Arc<tokio::sync::Mutex<()>>>>>;

/// What [`RelayManager::neg_probe_ids`] heard from one relay. No formatter:
/// it holds event ids.
#[cfg(feature = "test-utils")]
pub enum NegProbe {
    /// The ids the relay reported for the window.
    Ids(HashSet<EventId>),
    /// The relay refused NIP-77 outright.
    Unsupported,
    /// No answer in time, a socket that went away, or a refusal of this one
    /// session.
    NoAnswer,
}

impl RelayManager {
    /// Creates a new relay manager.
    ///
    /// The client holds no signer and is told never to answer a NIP-42
    /// challenge: an answer would be the identity key's signature over a
    /// relay's challenge, on a socket that carries a circle's routing id. The
    /// two facts are pinned apart (`the_publish_client_holds_no_signer_and_never_authenticates`,
    /// and no source may install a signer:
    /// `scripts/ci/check_engine_client_options.sh` check 11).
    #[must_use]
    pub fn new() -> Self {
        Self {
            client: verified_client(
                ClientOptions::default().automatic_authentication(false),
                None,
            ),
            clock: device_clock(),
            relay_client: OnceLock::new(),
            fanout_gates: FanoutGates::default(),
        }
    }

    /// [`Self::new`] reading every event's age off a clock that always says
    /// `now_secs`.
    #[cfg(any(test, feature = "test-utils"))]
    #[must_use]
    pub fn at_for_test(now_secs: u64) -> Self {
        Self {
            clock: Arc::new(move || now_secs),
            ..Self::new()
        }
    }

    /// The durable fanout's transport, on this manager's own publish client.
    ///
    /// MDK's relay client is handed that client and builds none of its own
    /// (v0.10.4 `transport-nostr-adapter/src/sdk_client.rs` 258), so what it
    /// reads from a relay passes the same admission policy (Security Rule 16)
    /// and what it sends rides the sockets this pool already holds. One per
    /// manager: its publish-relay bookkeeping is per instance.
    #[must_use]
    pub fn fanout_transport(&self) -> FanoutTransport {
        let relay_client = self
            .relay_client
            .get_or_init(|| Arc::new(NostrSdkRelayClient::new(self.client.clone())));
        FanoutTransport {
            client: self.client.clone(),
            relay_client: Arc::clone(relay_client),
            gates: Arc::clone(&self.fanout_gates),
            clock: Arc::clone(&self.clock),
        }
    }

    /// [`Self::fanout_transport`] with `relay_client` in the place of MDK's:
    /// the real classifier and the real pool, under a relay client a test
    /// scripts. It dials nothing itself.
    #[cfg(any(test, feature = "test-utils"))]
    #[must_use]
    pub fn fanout_transport_over_for_test(
        &self,
        relay_client: Arc<dyn NostrRelayClient>,
    ) -> FanoutTransport {
        FanoutTransport {
            client: self.client.clone(),
            relay_client,
            gates: Arc::clone(&self.fanout_gates),
            clock: Arc::clone(&self.clock),
        }
    }

    /// Refuses an event that has a durable fanout row: the fanout driver is
    /// its only sender on any publish pool ([`fanout::is_owned`]).
    fn refuse_fanout_owned(event: &Event) -> RelayResult<()> {
        if fanout::is_owned(&event.id) {
            return Err(RelayError::FanoutOwned);
        }
        Ok(())
    }

    /// Registers `relay_urls` in the publish pool with
    /// [`publish_relay_options`], dialling nothing.
    ///
    /// Sequential: a cheap metadata operation. Through the POOL, never
    /// `Client::add_relay` — see `publish_relay_options`.
    async fn register_publish_relays(client: &Client, relay_urls: &[RelayUrl]) {
        for url in relay_urls {
            // A relay the pool holds is found under its read lock. Adding it
            // again would take the write lock, which queues behind every send
            // still waiting for an `OK` and holds up every reader behind it.
            if client.relay(url.as_str()).await.is_ok() {
                continue;
            }
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
        Self::register_publish_relays(client, relay_urls).await;

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
    /// The path for a signed event no fanout record holds: a founding
    /// circle's Welcome gift wraps, the relay-removal scrub, key packages,
    /// relay lists, and the one send of a proposal no record could be written
    /// for. Each is lost for good if this call gives up, so they pay
    /// [`MAX_PUBLISH_ATTEMPTS`]. A commit never comes here: it leaves only
    /// through the fanout driver, and an event a record holds is refused
    /// (Security Rule 13). Locations take
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
        Self::refuse_fanout_owned(event)?;
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
        let gates = Arc::clone(&self.fanout_gates);
        publish_with_retry(
            MAX_PUBLISH_ATTEMPTS,
            PUBLISH_RETRY_BACKOFF,
            age_on(&self.clock, event),
            move |attempt| {
                let client = client.clone();
                let gates = Arc::clone(&gates);
                let relay_urls = relay_urls.clone();
                let event = event.clone();
                async move {
                    if attempt > 0 {
                        log::debug!("[RelayManager] publish_event: retry attempt {attempt}");
                    }
                    // A fanout call under way to one of these relays can end
                    // in MDK's client disconnecting it (`sdk_client.rs`
                    // 1254-1274), which this send would read as that relay
                    // failing, and a send here can cut a fanout call's answer
                    // the same way. So neither runs while the other does.
                    let _no_fanout_call = hold_fanout_gates(&gates, &relay_urls).await;
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
        Self::refuse_fanout_owned(event)?;
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
            age_on(&self.clock, event),
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

    /// Offers a public-profile event to `relays` once, each relay sent the
    /// moment its own connect succeeds, and harvests every relay's answer.
    ///
    /// The sync pass's send. One relay's slow handshake holds back no other
    /// relay, and a relay whose connect failed is never sent (it is
    /// unanswered, not refused). There is no in-call retry: the cold-socket
    /// race the [`publish_profile_event`](Self::publish_profile_event) ladder
    /// covers cannot occur once each send follows its own connect, and the
    /// outbox's persisted ladder owns every retry.
    ///
    /// # Errors
    ///
    /// Only before any relay is dialled: an event a fanout record holds, or a
    /// relay URL that may not be dialled. Otherwise always `Ok`, even when no
    /// relay accepted.
    pub async fn offer_profile_event(
        &self,
        event: &Event,
        relays: &[String],
    ) -> RelayResult<PublishResult> {
        Self::refuse_fanout_owned(event)?;
        let relay_urls = Self::validate_relay_urls(relays)?;
        log::debug!(
            "[RelayManager] offer_profile_event: sending kind {} to {} relay(s)",
            event.kind.as_u16(),
            bucket(relay_urls.len())
        );
        Self::register_publish_relays(&self.client, &relay_urls).await;
        Ok(Self::offer_harvest(
            &self.client,
            &relay_urls,
            event,
            CONNECTION_TIMEOUT,
            PROFILE_PUBLISH_ACK_TIMEOUT,
        )
        .await)
    }

    /// Per relay concurrently: connect within `connect`, then send and wait
    /// `ack` for its `OK`. The relays must already be registered.
    async fn offer_harvest(
        client: &Client,
        relay_urls: &[RelayUrl],
        event: &Event,
        connect: Duration,
        ack: Duration,
    ) -> PublishResult {
        let offers = relay_urls.iter().map(|url| async move {
            if client
                .try_connect_relay(url.as_str(), connect)
                .await
                .is_err()
            {
                return (url.to_string(), AckOutcome::Unanswered);
            }
            send_to_one(client, url, event, ack).await
        });
        let outcomes = futures::future::join_all(offers).await;
        recover_wedged_publish_sockets(client, relay_urls).await;
        Self::fold_harvest(event, outcomes)
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
    /// blamed the timestamp (the one publish failure a user can act on, which
    /// reaches the caller as a typed clock complaint). Also errors when a
    /// relay URL is not `wss://`.
    pub async fn publish_location_event(
        &self,
        event: &Event,
        relays: &[String],
    ) -> RelayResult<PublishResult> {
        Self::refuse_fanout_owned(event)?;
        Self::send_location(&self.client, &self.clock, event, relays).await
    }

    /// [`Self::publish_location_event`] without the refusal of an event that
    /// has a fanout record: the one send the record's own driver makes
    /// ([`FanoutTransport`]), on the same pool, in the same window, read by
    /// the same classifier. The driver's bridge sends through it too — a
    /// fellow member's location, which has no record of this device's
    /// (`Publishing::bridge_locations`).
    async fn send_location(
        client: &Client,
        clock: &SecondsClock,
        event: &Event,
        relays: &[String],
    ) -> RelayResult<PublishResult> {
        let relay_urls = Self::validate_relay_urls(relays)?;

        log::debug!(
            "[RelayManager] publish_location_event: sending kind {} to {} relay(s)",
            event.kind.as_u16(),
            bucket(relay_urls.len())
        );

        let client = client.clone();
        publish_with_retry(
            LOCATION_PUBLISH_ATTEMPTS,
            Duration::ZERO,
            age_on(clock, event),
            move |_| {
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
            },
        )
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
        let outcomes = futures::future::join_all(sends).await;
        // A silent relay is EITHER slow or holding this event unsent forever;
        // only the second is freed here, and only after the ack window closed.
        recover_wedged_publish_sockets(client, relay_urls).await;
        Self::fold_harvest(event, outcomes)
    }

    /// Folds each relay's [`AckOutcome`] into a [`PublishResult`].
    fn fold_harvest(event: &Event, outcomes: Vec<(String, AckOutcome)>) -> PublishResult {
        let mut accepted_by = Vec::new();
        let mut rejected_by = Vec::new();
        let mut failed = Vec::new();
        for (url, outcome) in outcomes {
            match outcome {
                AckOutcome::Accepted => accepted_by.push(url),
                AckOutcome::Refused(reason) => rejected_by.push((url, reason)),
                AckOutcome::Unanswered => failed.push(url),
            }
        }

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
        Self::refuse_fanout_owned(&event)?;
        let relay_urls = Self::validate_relay_urls(relays)?;
        let client = self.client.clone();

        tokio::spawn(async move {
            Self::register_publish_relays(&client, &relay_urls).await;
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
    /// * `timeout` - Optional timeout (defaults to 10 seconds)
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

    /// Extracts the dialable relay URLs from `"relay"` tags — the
    /// `["relay", "<url>"]` format of the kind-10050 inbox list — capped: see
    /// [`retain_dialable_foreign_relays`].
    fn extract_relay_tag_urls(tags: &nostr::Tags) -> Vec<String> {
        retain_dialable_foreign_relays(tags.iter().filter_map(|tag| {
            let values = tag.as_slice();
            (values.len() >= 2 && values[0] == "relay").then(|| values[1].as_str())
        }))
    }

    /// Fetches a user's relay list for the given event kind.
    ///
    /// Queries the discovery plane
    /// ([`discovery_relays`][crate::relay::discovery::discovery_relays]) for
    /// the user's replaceable relay list event and extracts `wss://` URLs
    /// from `"relay"` tags. This resolves *another* user's relays by bare
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

        Ok(Self::newest_authored(events, &pk, kind, |_| true)
            .map_or_else(Vec::new, |list| Self::extract_relay_tag_urls(&list.tags)))
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

    /// Extracts read-capable relay URLs from NIP-65 "r" tags.
    ///
    /// Filters for relays the recipient reads from:
    /// - No marker (both read+write) → include
    /// - "read" → include (recipient fetches here)
    /// - "write" only → exclude (recipient doesn't read here)
    ///
    /// Kept only if dialable, and capped: see [`retain_dialable_foreign_relays`].
    fn extract_nip65_read_relays(tags: &nostr::Tags) -> Vec<String> {
        retain_dialable_foreign_relays(tags.iter().filter_map(|tag| {
            let values = tag.as_slice();
            let write_only = values.len() >= 3 && values[2] == "write";
            (values.len() >= 2 && values[0] == "r" && !write_only).then(|| values[1].as_str())
        }))
    }

    /// Extracts write-capable relay URLs from NIP-65 "r" tags.
    ///
    /// The mirror of [`Self::extract_nip65_read_relays`]. Filters for relays the
    /// author writes to (so *others* fetch the author's events there):
    /// - No marker (both read+write) → include
    /// - "write" → include (author publishes here)
    /// - "read" only → exclude (author doesn't publish here)
    ///
    /// Kept only if dialable, and capped: see [`retain_dialable_foreign_relays`].
    /// This is the set another user's `KeyPackage` is fetched from (Marmot
    /// `transports/nostr.md:297-302`).
    pub(crate) fn extract_nip65_write_relays(tags: &nostr::Tags) -> Vec<String> {
        retain_dialable_foreign_relays(tags.iter().filter_map(|tag| {
            let values = tag.as_slice();
            let read_only = values.len() >= 3 && values[2] == "read";
            (values.len() >= 2 && values[0] == "r" && !read_only).then(|| values[1].as_str())
        }))
    }

    /// Fetches a user's NIP-65 relay list (kind 10002) once, split by marker.
    ///
    /// # Errors
    ///
    /// Returns an error if the pubkey is invalid or fetching fails.
    pub async fn fetch_nip65_relay_list(&self, pubkey: &str) -> RelayResult<Nip65Relays> {
        let pk = PublicKey::parse(pubkey).map_err(|_| RelayError::InvalidPubkey)?;

        let filter = Filter::new().kind(Kind::RelayList).author(pk).limit(1);

        let discovery = discovery_relays();
        let events = self.fetch_events(filter, &discovery, None).await?;

        Ok(
            Self::newest_authored(events, &pk, Kind::RelayList, |_| true).map_or_else(
                Nip65Relays::default,
                |list| Nip65Relays {
                    read: Self::extract_nip65_read_relays(&list.tags),
                    write: Self::extract_nip65_write_relays(&list.tags),
                },
            ),
        )
    }

    /// Fetches a user's NIP-65 read-capable relays (kind 10002).
    ///
    /// Used as the second tier in the Welcome delivery cascade when inbox
    /// relays (kind 10050) are unavailable.
    ///
    /// # Errors
    ///
    /// Returns an error if the pubkey is invalid or fetching fails.
    pub async fn fetch_nip65_relays(&self, pubkey: &str) -> RelayResult<Vec<String>> {
        Ok(self.fetch_nip65_relay_list(pubkey).await?.read)
    }

    /// Fetches a user's key package (kind 30443) with no target in mind: every
    /// valid candidate is eligible.
    ///
    /// Test-only, as the two no-target fetches below are: an invite always has
    /// a target, and [`Self::lookup_member_for_invite`] is the one lookup a
    /// shipped build can reach. The tests of author binding, slot supersession
    /// and discovery use these to read selection without a session.
    ///
    /// Resolves the user's NIP-65 write-capable relays (kind 10002) and fetches
    /// from them, falling back to the discovery plane
    /// ([`discovery_relays`][crate::relay::discovery::discovery_relays]) when
    /// that set is empty or holds no usable `KeyPackage`.
    ///
    /// # Arguments
    ///
    /// * `pubkey` - The user's public key (hex or npub)
    ///
    /// # Returns
    ///
    /// The selected `KeyPackage` event ([`Self::pick_keypackage_from_events`]),
    /// or `None` if no tier returned one.
    ///
    /// # Errors
    ///
    /// Returns an error if the pubkey is invalid or fetching fails.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn fetch_keypackage(&self, pubkey: &str) -> RelayResult<Option<Event>> {
        // A failed list is treated as empty so the cascade still reaches the
        // discovery plane instead of aborting.
        let write = self
            .fetch_nip65_relay_list(pubkey)
            .await
            .map(|list| list.write)
            .unwrap_or_default();

        self.fetch_keypackage_with_cascade(pubkey, &write).await
    }

    /// Looks `pubkey` up to invite them into the target whose admission rule is
    /// `admit`
    /// ([`SessionManager::key_package_admission_rule`](crate::nostr::mls::SessionManager::key_package_admission_rule)),
    /// and says whether absence was proven.
    ///
    /// The inviter sequence of Marmot `transports/nostr.md` "Migration from
    /// kind 10051": the account's kind 10050 and 10002 from the read-only
    /// discovery plane, then its `KeyPackage`s from the 10002 write set, then
    /// from discovery when the write set is empty or holds nothing invitable.
    /// The rule is applied to every valid candidate BEFORE they are ranked
    /// ([`Self::pick_keypackage_from_events`]); when nothing is admissible the
    /// best valid candidate, failing that a pre-migration one, is still
    /// [`MemberLookup::Found`], so the caller's admission check can say why.
    ///
    /// Every REQ goes out on one client of its own, shut down before this
    /// returns: the shared pool never collects every invitee's relays, and a
    /// socket it left half-dead cannot answer for a lookup.
    ///
    /// # Errors
    ///
    /// Only for a `pubkey` that does not parse. An unreachable or unfinished
    /// relay is [`MemberLookup::Incomplete`], never an error.
    pub async fn lookup_member_for_invite(
        pubkey: &str,
        admit: &KeyPackageAdmissionRule,
    ) -> RelayResult<MemberLookup> {
        Self::member_lookup(pubkey, Some(admit), None, DEFAULT_TIMEOUT).await
    }

    /// [`Self::lookup_member_for_invite`] with each REQ bounded by
    /// `req_timeout`, so a test of a silent relay does not wait out
    /// [`DEFAULT_TIMEOUT`].
    ///
    /// # Errors
    ///
    /// As [`Self::lookup_member_for_invite`].
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn lookup_member_for_invite_within(
        pubkey: &str,
        admit: &KeyPackageAdmissionRule,
        req_timeout: Duration,
    ) -> RelayResult<MemberLookup> {
        Self::member_lookup(pubkey, Some(admit), None, req_timeout).await
    }

    /// [`Self::lookup_member_for_invite`]'s `KeyPackage` step alone, over a
    /// write set the caller already holds: no relay list is asked for, so the
    /// found member carries `write_relays` and no other list.
    ///
    /// # Errors
    ///
    /// As [`Self::lookup_member_for_invite`].
    #[cfg(feature = "test-utils")]
    pub async fn lookup_key_package_on(
        pubkey: &str,
        write_relays: &[String],
        admit: &KeyPackageAdmissionRule,
    ) -> RelayResult<MemberLookup> {
        Self::member_lookup(pubkey, Some(admit), Some(write_relays), DEFAULT_TIMEOUT).await
    }

    /// Runs the `KeyPackage` discovery cascade with no target in mind: every
    /// valid candidate is eligible.
    ///
    /// # Errors
    ///
    /// Returns an error if the pubkey is invalid.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn fetch_keypackage_with_cascade(
        &self,
        pubkey: &str,
        write_relays: &[String],
    ) -> RelayResult<Option<Event>> {
        Ok(
            match Self::member_lookup(pubkey, None, Some(write_relays), DEFAULT_TIMEOUT).await? {
                MemberLookup::Found(member) => Some(member.key_package_event),
                MemberLookup::NotFound | MemberLookup::Incomplete => None,
            },
        )
    }

    /// The lookup on a client of its own, shut down on every path.
    async fn member_lookup(
        pubkey: &str,
        admit: Option<&KeyPackageAdmissionRule>,
        write_relays: Option<&[String]>,
        req_timeout: Duration,
    ) -> RelayResult<MemberLookup> {
        let account = PublicKey::parse(pubkey).map_err(|_| RelayError::InvalidPubkey)?;
        let lookup = Self::new();
        // Boxed: a lookup holds several relays' answers at once, and every
        // caller's own future would otherwise carry them.
        let found =
            Box::pin(lookup.member_lookup_on(&account, admit, write_relays, req_timeout)).await;
        lookup.shutdown().await;
        found
    }

    /// The lookup's REQs, each through [`Self::fetch_events_per_relay_within`]
    /// so that every relay's answer says whether it was whole. `write_relays`
    /// stands in for the relay lists when the caller already holds them.
    async fn member_lookup_on(
        &self,
        account: &PublicKey,
        admit: Option<&KeyPackageAdmissionRule>,
        write_relays: Option<&[String]>,
        req_timeout: Duration,
    ) -> RelayResult<MemberLookup> {
        let discovery = discovery_relays();
        let (inbox_relays, nip65, lists_answered) = if let Some(write) = write_relays {
            let nip65 = Nip65Relays {
                read: Vec::new(),
                write: write.to_vec(),
            };
            (Vec::new(), nip65, true)
        } else {
            let list = |kind| Filter::new().kind(kind).author(*account).limit(1);
            let (inbox, nip65) = tokio::join!(
                self.fetch_events_per_relay_within(
                    list(Kind::InboxRelays),
                    &discovery,
                    req_timeout
                ),
                self.fetch_events_per_relay_within(list(Kind::RelayList), &discovery, req_timeout),
            );
            let (inbox, nip65) = (inbox?, nip65?);
            let inbox_relays =
                Self::newest_authored(all_events(&inbox), account, Kind::InboxRelays, |_| true)
                    .map_or_else(Vec::new, |list| Self::extract_relay_tag_urls(&list.tags));
            // A relay that connected and stopped short may hold a newer 10002
            // naming other write relays, so it withholds the holders as well.
            let lists_answered = answered_whole(&nip65);
            let nip65 =
                Self::newest_authored(all_events(&nip65), account, Kind::RelayList, |_| true)
                    .map_or_else(Nip65Relays::default, |list| Nip65Relays {
                        read: Self::extract_nip65_read_relays(&list.tags),
                        write: Self::extract_nip65_write_relays(&list.tags),
                    });
            (inbox_relays, nip65, lists_answered)
        };

        // `limit(10)`: well above any reasonable account's published slots.
        let filter = Filter::new()
            .kind(Kind::Custom(30443))
            .author(*account)
            .limit(10);
        let (mut seen, mut holders) = if nip65.write.is_empty() {
            (Vec::new(), None)
        } else {
            let answers = self
                .fetch_events_per_relay_within(filter.clone(), &nip65.write, req_timeout)
                .await?;
            (all_events(&answers), Some(answers))
        };
        let mut picked = Self::pick_keypackage_from_events(account, seen.clone(), admit);
        if !matches!(picked, Some(PickedKeyPackage::Invitable(_))) {
            // The second tier is judged together with what the first returned:
            // a slot's newest event stands for the slot across tiers, so a
            // relay that still serves a superseded event cannot revive it.
            let answers = self
                .fetch_events_per_relay_within(filter, &discovery, req_timeout)
                .await?;
            seen.extend(all_events(&answers));
            picked = Self::pick_keypackage_from_events(account, seen, admit);
            holders.get_or_insert(answers);
        }

        let Some(picked) = picked else {
            let holders = holders.unwrap_or_default();
            return Ok(if absence_proven(lists_answered, &holders) {
                MemberLookup::NotFound
            } else {
                MemberLookup::Incomplete
            });
        };
        Ok(MemberLookup::Found(Box::new(MemberKeyPackage {
            key_package_event: picked.into_event(),
            inbox_relays,
            nip65_relays: nip65.read,
            nip65_write_relays: nip65.write,
        })))
    }

    /// Fetches a user's key package (kind 30443) from the given relay list,
    /// with no target in mind.
    ///
    /// Uses the provided relay list directly, falling back to the read-only
    /// discovery plane
    /// ([`discovery_relays`][crate::relay::discovery::discovery_relays]) if the
    /// list is empty.
    ///
    /// # Arguments
    ///
    /// * `pubkey` - The user's public key (hex or npub)
    /// * `keypackage_relays` - The relays to query (the user's NIP-65
    ///   write-capable set)
    ///
    /// # Returns
    ///
    /// The selected key package event
    /// ([`Self::pick_keypackage_from_events`]), or `None` if not found.
    ///
    /// # Errors
    ///
    /// Returns an error if the pubkey is invalid or fetching fails.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn fetch_keypackage_from_relays(
        &self,
        pubkey: &str,
        keypackage_relays: &[String],
    ) -> RelayResult<Option<Event>> {
        let pk = PublicKey::parse(pubkey).map_err(|_| RelayError::InvalidPubkey)?;
        let events = self.key_package_events_on(&pk, keypackage_relays).await?;
        Ok(Self::pick_keypackage_from_events(&pk, events, None).map(PickedKeyPackage::into_event))
    }

    /// Every kind-30443 the given relays return for `account` — the discovery
    /// plane's when the list is empty.
    async fn key_package_events_on(
        &self,
        account: &PublicKey,
        keypackage_relays: &[String],
    ) -> RelayResult<Vec<Event>> {
        let discovery: Vec<String>;
        let relays = if keypackage_relays.is_empty() {
            discovery = discovery_relays();
            &discovery
        } else {
            keypackage_relays
        };

        // `limit(10)`: well above any reasonable account's published slots.
        let filter = Filter::new()
            .kind(Kind::Custom(30443))
            .author(*account)
            .limit(10);
        self.fetch_events(filter, relays, None).await
    }

    /// Selects `account`'s key package from what the relays returned, or
    /// `None`: nothing `account` published a `KeyPackage` in.
    ///
    /// The relay chooses what it answers, so only a kind-30443 `account`
    /// signed is looked at. Within one `d` slot the newest event stands for
    /// the slot (lower id on a tie, `transports/nostr.md:304-307`) even when
    /// it is invalid: an older one may name material its owner has deleted.
    /// Each slot's event is then validated ([`KeyPackageCandidate::validate`]:
    /// the Welcome goes to the event's author and the leaf joins under the
    /// package's credential, so both must be the account asked for), the
    /// valid ones are filtered by the target's admission rule `admit`, and
    /// only then ranked ([`KeyPackageCandidate::rank`]) — the order
    /// `foundation/key-packages.md:65-66,72-75` requires, and MDK's own
    /// (`marmot-app/src/key_package_records.rs:225-230`). Freshness therefore
    /// never puts a package the target cannot admit ahead of one it can.
    ///
    /// When nothing is admissible the best valid candidate is handed back, and
    /// when nothing is valid the newest pre-migration package of `account`, so
    /// the caller can say "cannot be invited" or "needs to update" instead of
    /// "not found". Neither is ever invited: the caller's admission check
    /// refuses both.
    ///
    /// Kept separate from the fetch so the selection logic can be unit-tested
    /// without a relay round-trip.
    fn pick_keypackage_from_events(
        account: &PublicKey,
        mut events: Vec<Event>,
        admit: Option<&KeyPackageAdmissionRule>,
    ) -> Option<PickedKeyPackage> {
        events.retain(|e| e.pubkey == *account && e.kind == Kind::Custom(30443));
        events.sort_by(|a, b| {
            b.created_at
                .cmp(&a.created_at)
                .then_with(|| a.id.cmp(&b.id))
        });
        let mut slots = HashSet::new();
        events.retain(|e| kp_event_d_tag(e).is_none_or(|d| d.is_empty() || slots.insert(d)));

        let valid: Vec<KeyPackageCandidate> = events
            .iter()
            .filter_map(|e| KeyPackageCandidate::validate(e, account))
            .collect();
        let admitted = valid
            .iter()
            .filter(|candidate| admit.is_none_or(|rule| rule.admits(&candidate.key_package)))
            .max_by(|a, b| a.rank(b));
        if let Some(best) = admitted {
            return Some(PickedKeyPackage::Invitable(best.event.clone()));
        }
        if let Some(best) = valid.iter().max_by(|a, b| a.rank(b)) {
            return Some(PickedKeyPackage::Inadmissible(best.event.clone()));
        }
        events
            .into_iter()
            .find(|e| is_pre_migration_key_package_of(e, account))
            .map(PickedKeyPackage::PreMigration)
    }

    /// The newest event `author` signed as `kind` that also passes `valid` —
    /// the only one a per-author fetch may act on.
    ///
    /// The relay chooses what it answers and this client does not hold it to
    /// the filter (`verify_subscriptions` is off), so a relay can hand back
    /// another account's validly signed event, or the right account's event of
    /// another kind (Marmot `transports/nostr.md:331-333`). Turning that option
    /// on would not replace this check, and is not done: its `limit` half drops
    /// a relay's over-limit events before [`Self::read_one_relays_answer`]
    /// counts them (`nostr-relay-pool-0.44.3 inner.rs:1152-1171`), so a
    /// flooding relay's page would read as drained (Rule 12). Ties go to the lower
    /// event id (`transports/nostr.md:306-307`, NIP-01), so arrival order — the
    /// relay's choice — decides nothing.
    fn newest_authored(
        events: Vec<Event>,
        author: &PublicKey,
        kind: Kind,
        valid: impl Fn(&Event) -> bool,
    ) -> Option<Event> {
        events
            .into_iter()
            .filter(|e| e.pubkey == *author && e.kind == kind && valid(e))
            .max_by(|a, b| {
                a.created_at
                    .cmp(&b.created_at)
                    .then_with(|| b.id.cmp(&a.id))
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
        self.fetch_events_per_relay_within(filter, relays, DEFAULT_TIMEOUT)
            .await
    }

    /// [`Self::fetch_events_per_relay`] with each relay's `REQ` bounded by
    /// `req_timeout` instead of [`DEFAULT_TIMEOUT`].
    ///
    /// The connect keeps [`CONNECTION_TIMEOUT`]. Every relay is asked at once.
    ///
    /// # Errors
    ///
    /// Never, as [`Self::fetch_events_per_relay`].
    pub async fn fetch_events_per_relay_within(
        &self,
        filter: Filter,
        relays: &[String],
        req_timeout: Duration,
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

                // Register the relay, then attempt a bounded handshake.
                // `try_connect_relay` returns Ok if the socket is (or becomes)
                // connected within CONNECTION_TIMEOUT — the transport-level
                // equivalent of the relay answering our knock.
                Self::register_publish_relays(client, std::slice::from_ref(&url)).await;
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

                let (drained, events) =
                    Self::read_one_relays_answer(&handle, filter, req_timeout).await;
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

    /// Registers and dials every relay of `relays` that may be dialled, for a
    /// NIP-77 pass, before any session of it opens: `sync_targeted` holds the
    /// pool's relay read lock for a whole session, and a registration queued
    /// behind it would hold up every reader after it.
    pub(crate) async fn neg_prepare(&self, relays: &[String]) {
        let urls: Vec<RelayUrl> = relays
            .iter()
            .filter_map(|relay| Self::validate_single_relay_url(relay).ok())
            .collect();
        Self::add_relays_and_connect(&self.client, &urls).await;
    }

    /// One NIP-77 session with `relay`, already dialled by
    /// [`Self::neg_prepare`], over `routing_id`'s `kind:445` window
    /// `[since, until]`, ending by `ends`.
    ///
    /// The session advertises nothing the device holds: its local set is
    /// empty (`Vec::new()`), so the opening message is `6100000200` and every
    /// later client message an empty `IdList` or a `Skip`. As a dry run in
    /// the download direction it sends no REQ and no EVENT
    /// (`nostr-relay-pool` 0.44.3 `relay/options.rs` 331-338), only NEG-OPEN,
    /// NEG-MSG and NEG-CLOSE. One relay per call: an answer is that relay's
    /// alone. The filter is MDK's (`sdk_client.rs` 292-298). Logs nothing,
    /// and keeps no relay text (Security Rule 15).
    pub(crate) async fn neg_remote_ids(
        &self,
        routing_id: &[u8; 32],
        relay: &str,
        since: u64,
        until: u64,
        ends: tokio::time::Instant,
    ) -> super::negentropy::NegAnswer {
        use super::negentropy::{NegAnswer, NEG_NEGOTIATION_WAIT, NEG_SET_LIMIT};
        let Ok(url) = Self::validate_single_relay_url(relay) else {
            return NegAnswer::Failed;
        };
        let Ok(handle) = self.client.relay(url.as_str()).await else {
            return NegAnswer::Failed;
        };
        if !handle.is_connected() {
            return NegAnswer::Failed;
        }
        let filter = super::live_sync::planes::group::group_filter(
            &[hex::encode(routing_id)],
            i64::try_from(since).unwrap_or(0),
        )
        .until(nostr::Timestamp::from(until))
        .limit(NEG_SET_LIMIT);
        let options = nostr_sdk::SyncOptions::new()
            .initial_timeout(NEG_NEGOTIATION_WAIT)
            .direction(nostr_sdk::SyncDirection::Down)
            .dry_run();
        let synced = tokio::time::timeout_at(
            ends,
            self.client
                .pool()
                .sync_targeted([(url.clone(), (filter, Vec::new()))], &options),
        )
        .await;
        let Ok(Ok(output)) = synced else {
            return NegAnswer::Failed;
        };
        if let Some(failure) = output.failed.get(&url) {
            return NegAnswer::from_failure(failure);
        }
        if !output.success.contains(&url) {
            return NegAnswer::Failed;
        }
        NegAnswer::from_remote(output.val.remote)
    }

    /// [`Self::neg_prepare`] and [`Self::neg_remote_ids`] for one relay over
    /// `routing_id`'s window `[since, until]`, within [`NEG_ROUTE_WAIT`]: the
    /// location-pool vetting probe gates on the session a circle's catch-up
    /// runs, not on a copy of it.
    ///
    /// [`NEG_ROUTE_WAIT`]: super::negentropy::NEG_ROUTE_WAIT
    #[cfg(feature = "test-utils")]
    pub async fn neg_probe_ids(
        &self,
        relay: &str,
        routing_id: &[u8; 32],
        since: u64,
        until: u64,
    ) -> NegProbe {
        use super::negentropy::{NegAnswer, NEG_ROUTE_WAIT};
        self.neg_prepare(&[relay.to_string()]).await;
        let ends = tokio::time::Instant::now() + NEG_ROUTE_WAIT;
        match self
            .neg_remote_ids(routing_id, relay, since, until, ends)
            .await
        {
            NegAnswer::Complete(ids) | NegAnswer::Saturated(ids) => NegProbe::Ids(ids),
            NegAnswer::Unsupported => NegProbe::Unsupported,
            NegAnswer::Failed => NegProbe::NoAnswer,
        }
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
    /// closes only when its own `req_timeout` expires. The REQ stays open
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
    /// the LOWER id first, is a total order this device computes: the first
    /// event of a replaceable coordinate is the one NIP-01 keeps (Marmot
    /// `transports/nostr.md:304-307`), and it is the order of the pooled
    /// `Events` collection this replaced.
    async fn read_one_relays_answer(
        relay: &Relay,
        filter: Filter,
        req_timeout: Duration,
    ) -> (bool, Vec<Event>) {
        let intake_cap = filter.limit.unwrap_or(MAX_EVENTS_PER_UNLIMITED_REQ);
        let id = SubscriptionId::generate();
        let mut notifications = relay.notifications();

        let opts = SubscribeOptions::default().close_on(Some(
            SubscribeAutoCloseOptions::default()
                .exit_policy(ReqExitPolicy::ExitOnEOSE)
                .timeout(Some(req_timeout)),
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
        let drained = tokio::time::timeout(req_timeout, async {
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
                .then_with(|| a.id.cmp(&b.id))
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
        // The rejected URL is deliberately not carried: this error crosses the
        // FFI and reaches a log line (Security Rule 15).
        let url = RelayUrl::parse(relay)
            .map_err(|_| RelayError::InvalidUrl(InvalidUrlReason::Unparseable))?;
        if !url_norm::may_dial(&url) {
            return Err(RelayError::InvalidUrl(InvalidUrlReason::PlaintextWs));
        }
        Ok(url)
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

    /// Disconnects from all relays and drops them: every send path registers
    /// what it needs again.
    ///
    /// Never kept: `disconnect` on a relay with no connection task stores a
    /// termination permit that its next dial consumes, leaving it `Connecting`,
    /// which no later dial leaves (`nostr-relay-pool-0.44.3 relay/inner.rs`
    /// 1255-1271, 659-698). The `disconnect` first ends every in-flight wait,
    /// so the removal's write lock is not queued behind a full `OK` timeout.
    pub async fn shutdown(&self) {
        self.client.disconnect().await;
        self.client.force_remove_all_relays().await;
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

/// Takes the fanout gate of each of `relay_urls`, waiting for whoever holds
/// one: held until the guards drop. In URL order, so two callers that name
/// the same relays can never each hold one the other waits for.
async fn hold_fanout_gates(
    gates: &FanoutGates,
    relay_urls: &[RelayUrl],
) -> Vec<tokio::sync::OwnedMutexGuard<()>> {
    let mut wanted: Vec<&RelayUrl> = relay_urls.iter().collect();
    wanted.sort();
    wanted.dedup();
    let mut held = Vec::with_capacity(wanted.len());
    for url in wanted {
        let gate = Arc::clone(
            gates
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .entry(url.clone())
                .or_default(),
        );
        held.push(gate.lock_owned().await);
    }
    held
}

/// Publishes one fanout event to one relay through MDK's relay client, on
/// Haven's publish pool ([`RelayManager::fanout_transport`]).
///
/// No `Debug`: it holds the publish client, whose own names every relay.
pub struct FanoutTransport {
    client: Client,
    relay_client: Arc<dyn NostrRelayClient>,
    gates: FanoutGates,
    clock: SecondsClock,
}

#[async_trait::async_trait]
impl fanout::FanoutSend for FanoutTransport {
    async fn take(&self, target: &str) -> Option<fanout::Taken> {
        Self::take(self, target).await
    }

    async fn publish(
        &self,
        target: &str,
        message: &TransportMessage,
        taken: fanout::Taken,
    ) -> FanoutTargetOutcome {
        Self::publish(self, target, message, taken).await
    }

    async fn publish_location(
        &self,
        event: &Event,
        targets: &[String],
    ) -> RelayResult<PublishResult> {
        RelayManager::send_location(&self.client, &self.clock, event, targets).await
    }
}

impl FanoutTransport {
    /// Takes `target`'s relay for one fanout call, or `None` when another
    /// send held it for the whole of [`fanout::GATE_WAIT_SECS`].
    ///
    /// One fanout call per relay at a time, whichever rows they are for, and
    /// none beside a legacy commit publish to it: after an ambiguous answer
    /// MDK's client disconnects the relay (`sdk_client.rs` 1254-1274), which
    /// would cut the other send short — a second fanout call left possibly
    /// exposed for good, a legacy publish read as a failure it then rolls
    /// its commit back on.
    ///
    /// Bounded, so a drive's budget is a true one: behind a legacy publish's
    /// whole ladder the wait could outlast the wake. The gate is a FIFO
    /// lock, so a waiter is served ahead of every later one — but a waiter
    /// that gives up here gives up its place.
    ///
    /// A target the relay policy refuses has no gate: it is never handed
    /// over ([`Self::publish`]).
    pub async fn take(&self, target: &str) -> Option<fanout::Taken> {
        let Ok(url) = RelayManager::validate_single_relay_url(target) else {
            return Some(fanout::Taken::nothing());
        };
        tokio::time::timeout(
            Duration::from_secs(fanout::GATE_WAIT_SECS),
            hold_fanout_gates(&self.gates, &[url]),
        )
        .await
        .ok()
        .map(fanout::Taken::holding)
    }

    /// Sends `message`'s signed event to `target` and returns MDK's
    /// classification of that relay's answer ([`fanout::publish_to_target`]).
    ///
    /// MDK's client adds a relay it does not know as a write relay with the
    /// SDK's defaults and takes no options (`sdk_client.rs` 1165-1190), and
    /// leaves one the pool already holds alone (1161-1163). So the target is
    /// registered here first, with [`publish_relay_options`].
    ///
    /// A target Haven's relay policy refuses is never handed over: MDK's client
    /// dials any `ws://` URL, and a routing entry is another client's to write.
    /// It comes back not exposed.
    ///
    /// `target` is the relay URL exactly as the fanout froze it; a failure is
    /// returned under that spelling. `taken` is that relay, held for this
    /// call ([`Self::take`]) until it has returned.
    pub async fn publish(
        &self,
        target: &str,
        message: &TransportMessage,
        taken: fanout::Taken,
    ) -> FanoutTargetOutcome {
        let _one_call = taken;
        let target = TransportEndpoint(target.to_owned());
        let Ok(url) = RelayManager::validate_single_relay_url(target.as_str()) else {
            return fanout::not_exposed(&target);
        };
        let relay_urls = [url];
        RelayManager::register_publish_relays(&self.client, &relay_urls).await;
        // Taken before the hand-over, so no answer to any attempt precedes it.
        let heard = self
            .client
            .relay(relay_urls[0].as_str())
            .await
            .ok()
            .map(|relay| relay.notifications());
        let outcome = fanout::publish_to_target(
            self.relay_client.as_ref(),
            &target,
            message,
            heard,
            (self.clock)(),
        )
        .await;
        // MDK's client adds a target it does not find in the pool through the
        // SDK, which ORs the keepalive onto a relay that appeared in between
        // (`sdk_client.rs` 1161-1169) — for that relay's life, unless taken
        // back off here. Only when set: the pool's `remove` is an XOR, so on a
        // relay without the flag it would turn the keepalive ON
        // (`nostr-relay-pool-0.44.3/src/relay/flags.rs` 58-61).
        if let Ok(relay) = self.client.relay(relay_urls[0].as_str()).await {
            if relay.flags().has_ping() {
                relay.flags().remove(RelayServiceFlags::PING);
            }
        }
        // MDK's client disconnects a relay after an ambiguous answer
        // (`sdk_client.rs` 1254-1275); on one with no connection task that
        // leaves a permit ending every later dial (see `RelayManager::shutdown`).
        // This relay's gate is held, so no other fanout call is cut.
        if matches!(&outcome, FanoutTargetOutcome::Failed(failure)
            if failure.kind() == TransportEndpointFailureKind::PossiblyExposed)
        {
            let _ = self.client.force_remove_relay(relay_urls[0].as_str()).await;
        }
        recover_wedged_publish_sockets(&self.client, &relay_urls).await;
        outcome
    }
}

/// Keeps the entries of ANOTHER account's relay list (10002 / 10050) that this
/// device may dial, without repeats, up to [`MAX_FOREIGN_LIST_RELAYS`].
///
/// Entries are dropped, never the list: rejecting all of it over one bad entry
/// would let an account make itself unresolvable (MDK draws the same line,
/// `marmot-app` `RelaySafetyPolicy::retain_safe_endpoints` @v0.10.4).
pub fn retain_dialable_foreign_relays<'a>(
    candidates: impl Iterator<Item = &'a str>,
) -> Vec<String> {
    let mut kept: Vec<String> = Vec::new();
    for url in candidates {
        if kept.len() == MAX_FOREIGN_LIST_RELAYS {
            break;
        }
        if foreign_relay_dialable(url) && !kept.iter().any(|k| k == url) {
            kept.push(url.to_owned());
        }
    }
    kept
}

/// Whether an entry of another account's relay list, or of a circle's routing
/// component, may be dialled: `wss://` to a host that is neither loopback nor a
/// non-public address, by MDK's canonical set
/// (`cgka_traits::app_components::{is_loopback_host, is_public_ip}`, Marmot
/// `implementation-model.md` "Network destination safety").
///
/// Another client chose the URL, not this device's user, so without this a
/// published list or an admin's routing steers Haven's sockets at the user's
/// own network, and a routing Haven wrote would steer every other member's. A
/// domain is accepted unresolved: the relay pool resolves it and owns the
/// socket, so a name resolving to a private address stays a residual, as it is
/// for MDK (`marmot-app` `reject_unsafe_relay_host`). A `ws://` URL is
/// [`url_norm::may_dial`]'s to decide, so the debug-only hermetic-test loopback
/// opt-in ([`ws_loopback_allowed_for_test`]) is the one exception; it names
/// hosts, not schemes, so it is asked about `ws://` only.
pub fn foreign_relay_dialable(url: &str) -> bool {
    let Ok(url) = RelayUrl::parse(url) else {
        return false;
    };
    if !url_norm::is_encrypted(&url) {
        return url_norm::may_dial(&url);
    }
    match url.host() {
        Some(host @ Host::Domain(_)) => !is_loopback_host(host),
        Some(Host::Ipv4(ip)) => is_public_ip(IpAddr::V4(ip)),
        Some(Host::Ipv6(ip)) => is_public_ip(IpAddr::V6(ip)),
        None => false,
    }
}

/// What an invite lookup established about one account
/// ([`RelayManager::lookup_member_for_invite`]).
///
/// No `Debug`: `Found` carries the account's relay lists (Security Rule 15).
pub enum MemberLookup {
    /// A package of the account's, with the lists its Welcome is routed by.
    /// It may be one the target cannot admit: the caller's admission check
    /// says why.
    Found(Box<MemberKeyPackage>),
    /// Every discovery relay that connected finished its answer to the
    /// 10002 REQ, as did every relay that holds the account's packages and
    /// connected — at least one of each — and none held one.
    NotFound,
    /// Some such relay did not finish, or none did, so absence is unproven:
    /// the account may well have a package.
    Incomplete,
}

/// Whether a lookup that selected no package proved there is none.
///
/// `holders` are the relays that hold the account's packages: its 10002 write
/// set, or the discovery plane when that set is empty (Marmot
/// `transports/nostr.md`: an absent list and an empty one both leave nothing
/// else to ask). Fetching from every one of them is not an interop
/// requirement, so a relay that never connected does not hold the verdict
/// back; one that connected and did not finish (`CLOSED`, a timeout, the
/// intake cap) does, and at least one must have finished. The 10002 REQ is
/// held to the same rule ([`answered_whole`], `lists_answered`): without it
/// the holders themselves are unknown.
fn absence_proven(lists_answered: bool, holders: &[RelayFetchOutcome]) -> bool {
    lists_answered && answered_whole(holders)
}

/// At least one relay finished its answer and every relay that connected did.
fn answered_whole(answers: &[RelayFetchOutcome]) -> bool {
    answers.iter().any(|answer| answer.drained)
        && answers
            .iter()
            .all(|answer| answer.drained || !answer.responded)
}

/// Every event of every relay's answer.
fn all_events(answers: &[RelayFetchOutcome]) -> Vec<Event> {
    answers
        .iter()
        .flat_map(|answer| answer.events.iter().cloned())
        .collect()
}

/// What [`RelayManager::pick_keypackage_from_events`] selected.
enum PickedKeyPackage {
    /// A valid, current package the target admits: the one to invite with.
    Invitable(Event),
    /// The account has valid packages and the target admits none of them: it
    /// cannot be invited there, and the caller says so.
    Inadmissible(Event),
    /// The account's only package is a pre-migration one: it cannot be
    /// invited, and the caller says so.
    PreMigration(Event),
}

impl PickedKeyPackage {
    fn into_event(self) -> Event {
        match self {
            Self::Invitable(event) | Self::Inadmissible(event) | Self::PreMigration(event) => event,
        }
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
    use crate::nostr::mls::SessionManager;
    use crate::nostr::KIND_GROUP_MESSAGE;
    use crate::relay::scripted_relay::{ScriptedRelay, Verdict};

    #[test]
    fn validate_relay_urls_rejects_plaintext() {
        let relays = vec!["ws://insecure.relay.com".to_string()];
        let result = RelayManager::validate_relay_urls(&relays);

        assert!(matches!(
            result,
            Err(RelayError::InvalidUrl(InvalidUrlReason::PlaintextWs))
        ));
    }

    /// The policy is about the scheme a URL HAS, not about how its text
    /// begins: each of these parses as plaintext `ws`.
    #[test]
    fn a_plaintext_relay_is_refused_however_its_scheme_is_spelled() {
        for spelling in [
            "ws://relay.example",
            "WS://relay.example",
            "wS://relay.example",
            "ws:relay.example",
            " ws://relay.example",
        ] {
            assert!(
                matches!(
                    RelayManager::validate_single_relay_url(spelling),
                    Err(RelayError::InvalidUrl(InvalidUrlReason::PlaintextWs))
                ),
                "a plaintext relay passed the wss-only policy under another \
                 spelling of its scheme",
            );
        }
        assert!(
            RelayManager::validate_single_relay_url("WSS://Relay.Example").is_ok(),
            "an encrypted relay is accepted however its scheme is spelled",
        );
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
        let result = publish_with_retry(
            3,
            Duration::ZERO,
            || 0,
            |_| {
                calls.set(calls.get() + 1);
                async { Ok(dummy_publish_result(true)) }
            },
        )
        .await;
        assert!(result.expect("success").is_success());
        assert_eq!(calls.get(), 1, "must not retry after the first acceptance");
    }

    #[tokio::test]
    async fn publish_with_retry_recovers_from_cold_connection() {
        // First two attempts reach the relays but get no OK (empty
        // accepted_by) — the cold-connect race — then the third lands.
        let result = publish_with_retry(
            3,
            Duration::ZERO,
            || 0,
            |attempt| async move {
                if attempt < 2 {
                    Ok(dummy_publish_result(false))
                } else {
                    Ok(dummy_publish_result(true))
                }
            },
        )
        .await;
        assert!(result.expect("eventual success").is_success());
    }

    #[tokio::test]
    async fn publish_with_retry_recovers_from_transport_error() {
        let result = publish_with_retry(
            3,
            Duration::ZERO,
            || 0,
            |attempt| async move {
                if attempt == 0 {
                    Err(RelayError::Timeout("cold socket".to_string()))
                } else {
                    Ok(dummy_publish_result(true))
                }
            },
        )
        .await;
        assert!(result.expect("recovered").is_success());
    }

    /// A publish every relay refused on timestamp grounds is not offered
    /// again however old the event is — the retry would carry the same
    /// timestamp — though for an event signed hours ago the refusal is no
    /// verdict on this device's clock.
    #[tokio::test]
    async fn an_old_event_every_relay_refused_on_timestamp_grounds_is_not_retried() {
        let calls = std::cell::Cell::new(0u32);
        let result = publish_with_retry(
            3,
            Duration::ZERO,
            || 3 * 3600,
            |_| {
                calls.set(calls.get() + 1);
                async {
                    Ok(rejected_publish_result(&[
                        "blocked: event too old",
                        "invalid: created_at too old",
                    ]))
                }
            },
        )
        .await;
        assert!(
            matches!(result, Err(RelayError::AllRelaysFailed)) && calls.get() == 1,
            "an event every relay refused on timestamp grounds was offered again, or its age \
             was read as this clock ({result:?}, {} attempt(s))",
            calls.get(),
        );
    }

    #[tokio::test]
    async fn publish_with_retry_exhausts_then_returns_all_relays_failed() {
        let calls = std::cell::Cell::new(0u32);
        let result = publish_with_retry(
            3,
            Duration::ZERO,
            || 0,
            |_| {
                calls.set(calls.get() + 1);
                async { Ok(dummy_publish_result(false)) }
            },
        )
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
        let result = publish_with_retry(
            3,
            Duration::ZERO,
            || 0,
            |_| async {
                Ok(rejected_publish_result(&[
                    "invalid: event too far off from the current time",
                ]))
            },
        )
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
        let result = publish_with_retry(
            3,
            Duration::ZERO,
            || 0,
            |_| {
                calls.set(calls.get() + 1);
                async {
                    Ok(rejected_publish_result(&[
                        "invalid: created_at is in the future",
                    ]))
                }
            },
        )
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
        let result = publish_with_retry(
            3,
            Duration::ZERO,
            || 0,
            |_| {
                calls.set(calls.get() + 1);
                async {
                    Ok(rejected_publish_result(&[
                        "invalid: event too far off from the current time",
                        "rate-limited: slow down",
                    ]))
                }
            },
        )
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
        let result = publish_with_retry(
            2,
            Duration::ZERO,
            || 0,
            |_| async { Ok(rejected_publish_result(&["blocked: pubkey not allowed"])) },
        )
        .await;
        assert!(matches!(result, Err(RelayError::AllRelaysFailed)));
    }

    #[tokio::test]
    async fn publish_with_retry_prefers_a_later_acceptance_over_a_clock_rejection() {
        // A transient clock complaint from one attempt must not mask a
        // subsequent success (e.g. the user fixed the clock, or a second relay
        // came up).
        let result = publish_with_retry(
            3,
            Duration::ZERO,
            || 0,
            |attempt| async move {
                if attempt == 0 {
                    Ok(rejected_publish_result(&[
                        "invalid: event too far off from the current time",
                        "rate-limited: slow down",
                    ]))
                } else {
                    Ok(dummy_publish_result(true))
                }
            },
        )
        .await;
        assert!(result.expect("later acceptance wins").is_success());
    }

    #[tokio::test]
    async fn publish_with_retry_surfaces_last_transport_error() {
        let result = publish_with_retry(
            2,
            Duration::ZERO,
            || 0,
            |_| async { Err(RelayError::Timeout("still cold".to_string())) },
        )
        .await;
        assert!(matches!(result, Err(RelayError::Timeout(_))));
    }

    #[tokio::test]
    async fn publish_with_retry_honours_single_attempt() {
        let calls = std::cell::Cell::new(0u32);
        let result = publish_with_retry(
            1,
            Duration::ZERO,
            || 0,
            |_| {
                calls.set(calls.get() + 1);
                async { Ok(dummy_publish_result(false)) }
            },
        )
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
        let exhausted = publish_with_retry(
            3,
            backoff,
            || 0,
            |_| async { Ok(dummy_publish_result(false)) },
        )
        .await;
        assert!(matches!(exhausted, Err(RelayError::AllRelaysFailed)));
        assert_eq!(
            started.elapsed(),
            backoff * 2,
            "three attempts pay two backoffs, and none after the final one",
        );

        let started = tokio::time::Instant::now();
        publish_with_retry(
            3,
            backoff,
            || 0,
            |_| async { Ok(dummy_publish_result(true)) },
        )
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
        let _ = publish_with_retry(
            0,
            Duration::ZERO,
            || 0,
            |_| {
                calls.set(calls.get() + 1);
                async { Ok(dummy_publish_result(false)) }
            },
        )
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
        let result = publish_with_retry(
            PROFILE_PUBLISH_MAX_ATTEMPTS,
            Duration::ZERO,
            || 0,
            |_| {
                let harvest = harvest.clone();
                async move { profile_attempt_outcome(harvest) }
            },
        )
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
        let result = publish_with_retry(
            PROFILE_PUBLISH_MAX_ATTEMPTS,
            Duration::ZERO,
            || 0,
            |_| {
                let harvest = harvest.clone();
                async move { profile_attempt_outcome(harvest) }
            },
        )
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
        let result = publish_with_retry(
            PROFILE_PUBLISH_MAX_ATTEMPTS,
            Duration::ZERO,
            || 0,
            |_| {
                calls.set(calls.get() + 1);
                async { profile_attempt_outcome(clock_rejection_harvest(true)) }
            },
        )
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
        let result = publish_with_retry(
            PROFILE_PUBLISH_MAX_ATTEMPTS,
            Duration::ZERO,
            || 0,
            |_| {
                calls.set(calls.get() + 1);
                async { profile_attempt_outcome(clock_rejection_harvest(false)) }
            },
        )
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

    /// Every extractor of another account's list, as the fetches apply them.
    fn foreign_extractions(url: &str) -> [Vec<String>; 3] {
        let tags = make_tags(vec![vec!["r", url], vec!["relay", url]]);
        [
            RelayManager::extract_nip65_read_relays(&tags),
            RelayManager::extract_nip65_write_relays(&tags),
            RelayManager::extract_relay_tag_urls(&tags),
        ]
    }

    /// Another account's list naming a host on the user's own network would
    /// otherwise point this device's sockets at it. Every host here is `wss://`,
    /// so the debug-only `ws://` loopback opt-in cannot excuse one.
    #[test]
    fn a_foreign_list_never_yields_a_loopback_or_non_public_host() {
        for refused in [
            "wss://127.0.0.1",
            "wss://127.8.9.10:7777",
            "wss://2130706433",
            "wss://0x7f.1",
            "wss://10.1.2.3",
            "wss://172.16.0.1",
            "wss://192.168.1.20",
            "wss://169.254.169.254",
            "wss://100.64.0.1",
            "wss://0.0.0.0",
            "wss://[::1]",
            "wss://[fe80::1]",
            "wss://[fd12:3456::1]",
            "wss://[::ffff:192.168.0.1]",
            "wss://localhost",
            "wss://LOCALHOST.",
            "wss://relay.localhost",
        ] {
            for extracted in foreign_extractions(refused) {
                assert!(extracted.is_empty(), "{refused} was kept");
            }
        }
        for kept in [
            "wss://relay.example.com",
            "wss://8.8.8.8",
            "wss://[2606:4700::1111]",
        ] {
            for extracted in foreign_extractions(kept) {
                assert_eq!(extracted, [kept]);
            }
        }
    }

    #[test]
    fn a_foreign_list_yields_at_most_the_cap_and_a_repeat_does_not_spend_it() {
        let distinct: Vec<String> = (0..MAX_FOREIGN_LIST_RELAYS + 4)
            .map(|i| format!("wss://r{i}.example.com"))
            .collect();
        let mut listed = vec!["wss://r0.example.com".to_owned(); 3];
        listed.extend(distinct.iter().cloned());
        let tags = make_tags(listed.iter().map(|url| vec!["r", url.as_str()]).collect());
        let relay_tags = make_tags(
            listed
                .iter()
                .map(|url| vec!["relay", url.as_str()])
                .collect(),
        );

        let expected = &distinct[..MAX_FOREIGN_LIST_RELAYS];
        assert_eq!(RelayManager::extract_nip65_read_relays(&tags), expected);
        assert_eq!(RelayManager::extract_nip65_write_relays(&tags), expected);
        assert_eq!(RelayManager::extract_relay_tag_urls(&relay_tags), expected);
    }

    // ------------------------------------------------------------------
    // KeyPackage selection tests
    // ------------------------------------------------------------------

    /// A real, valid kind-30443 of `keys`'s account in slot `d`: a package its
    /// own session minted, tagged by the production builder.
    async fn published_key_package(keys: &nostr::Keys, d: &str) -> Event {
        let dir = tempfile::TempDir::new().expect("temp dir");
        let session = SessionManager::new_unencrypted(dir.path(), keys).expect("session");
        crate::relay::maintenance::build_kp_maintenance_events(
            &session,
            keys,
            &["wss://own.example.com".to_string()],
            Some(d),
            None,
        )
        .await
        .expect("build")
        .event
    }

    /// `event` re-signed by `keys` as `kind` at `created_at_secs`, tags and
    /// content untouched.
    fn restamped(keys: &nostr::Keys, event: &Event, kind: Kind, created_at_secs: u64) -> Event {
        nostr::EventBuilder::new(kind, event.content.clone())
            .tags(event.tags.clone())
            .custom_created_at(nostr::Timestamp::from_secs(created_at_secs))
            .sign_with_keys(keys)
            .expect("event signing must succeed for tests")
    }

    fn slot(seed: u8) -> String {
        hex::encode([seed; 32])
    }

    fn invitable(account: &PublicKey, events: Vec<Event>) -> Option<Event> {
        match RelayManager::pick_keypackage_from_events(account, events, None) {
            Some(PickedKeyPackage::Invitable(event)) => Some(event),
            Some(PickedKeyPackage::Inadmissible(_) | PickedKeyPackage::PreMigration(_)) | None => {
                None
            }
        }
    }

    /// "Not found" is a claim about every relay that holds the account's
    /// packages, so only answers that ended in `EOSE` make it; a relay that
    /// never connected is no evidence either way, and one that connected and
    /// stopped short (`CLOSED`, timeout, intake cap) withholds it.
    #[test]
    fn absence_is_proven_only_by_finished_answers_from_every_connected_holder() {
        let answer = |responded: bool, drained: bool| RelayFetchOutcome {
            relay_url: String::new(),
            responded,
            drained,
            events: Vec::new(),
        };
        let finished = answer(true, true);
        let cut_short = answer(true, false);
        let unreachable = answer(false, false);
        let rows: [(&str, bool, Vec<RelayFetchOutcome>, bool); 9] = [
            ("one holder finished", true, vec![finished.clone()], true),
            (
                "every holder finished",
                true,
                vec![finished.clone(), finished.clone()],
                true,
            ),
            (
                "an unreachable holder does not hold the verdict back",
                true,
                vec![unreachable.clone(), finished.clone()],
                true,
            ),
            (
                "a holder that connected and stopped short does",
                true,
                vec![finished.clone(), cut_short.clone()],
                false,
            ),
            ("no holder connected", true, vec![unreachable], false),
            ("every holder stopped short", true, vec![cut_short], false),
            ("no holder at all", true, Vec::new(), false),
            (
                "the 10002 lookup never finished, so the holders are unknown",
                false,
                vec![finished.clone()],
                false,
            ),
            (
                "nor does an unfinished 10002 lookup with every holder finished",
                false,
                vec![finished.clone(), finished],
                false,
            ),
        ];
        for (case, lists_answered, holders, proven) in rows {
            assert_eq!(absence_proven(lists_answered, &holders), proven, "{case}");
        }
    }

    /// The 10002 REQ names the holders, so it is held to the holders' rule: a
    /// discovery relay that connected and stopped short may serve a newer
    /// list naming other write relays.
    #[test]
    fn the_relay_list_answer_is_held_to_the_holders_rule() {
        let answer = |responded: bool, drained: bool| RelayFetchOutcome {
            relay_url: String::new(),
            responded,
            drained,
            events: Vec::new(),
        };
        let (finished, cut_short, unreachable) = (
            answer(true, true),
            answer(true, false),
            answer(false, false),
        );
        let rows: [(&str, Vec<RelayFetchOutcome>, bool); 5] = [
            (
                "every indexer finished",
                vec![finished.clone(), finished.clone()],
                true,
            ),
            (
                "an unreachable indexer does not hold it back",
                vec![unreachable.clone(), finished.clone()],
                true,
            ),
            (
                "an indexer that connected and stopped short does",
                vec![cut_short.clone(), finished],
                false,
            ),
            ("no indexer connected", vec![unreachable], false),
            ("every indexer stopped short", vec![cut_short], false),
        ];
        for (case, lists, proven) in rows {
            assert_eq!(answered_whole(&lists), proven, "{case}");
        }
    }

    #[test]
    fn pick_keypackage_returns_none_for_empty_input() {
        let account = nostr::Keys::generate().public_key();
        assert!(RelayManager::pick_keypackage_from_events(&account, vec![], None).is_none());
    }

    #[tokio::test]
    async fn pick_keypackage_prefers_30443_over_443_even_when_443_is_newer() {
        let keys = nostr::Keys::generate();
        let kp = published_key_package(&keys, &slot(1)).await;
        let canonical_old = restamped(&keys, &kp, Kind::Custom(30443), 1_000);
        let legacy_new = restamped(&keys, &kp, Kind::MlsKeyPackage, 9_000);

        let picked = invitable(&keys.public_key(), vec![legacy_new, canonical_old.clone()])
            .expect("should pick a key package");

        assert_eq!(picked.id, canonical_old.id);
    }

    /// Within one slot the newest event is the slot (`transports/nostr.md:304-307`).
    #[tokio::test]
    async fn pick_keypackage_picks_the_newest_event_of_a_slot() {
        let keys = nostr::Keys::generate();
        let kp = published_key_package(&keys, &slot(1)).await;
        let old = restamped(&keys, &kp, Kind::Custom(30443), 1_000);
        let new = restamped(&keys, &kp, Kind::Custom(30443), 5_000);

        let picked =
            invitable(&keys.public_key(), vec![old, new.clone()]).expect("should pick a package");

        assert_eq!(picked.id, new.id);
    }

    /// A slot's newest event stands for the slot even when it is invalid: the
    /// older one may name material its owner already deleted.
    #[tokio::test]
    async fn an_invalid_newest_event_never_revives_the_one_it_replaced() {
        let keys = nostr::Keys::generate();
        let kp = published_key_package(&keys, &slot(1)).await;
        let valid_old = restamped(&keys, &kp, Kind::Custom(30443), 1_000);
        let mut hollow = kp;
        hollow.content = String::new();
        let invalid_new = restamped(&keys, &hollow, Kind::Custom(30443), 5_000);

        assert!(invitable(&keys.public_key(), vec![valid_old, invalid_new]).is_none());
    }

    /// Relays choose the order they answer in; a timestamp tie must not hand
    /// them the choice of package.
    #[tokio::test]
    async fn pick_keypackage_breaks_a_timestamp_tie_by_the_lower_id_in_any_order() {
        let keys = nostr::Keys::generate();
        let (first, second) = (
            published_key_package(&keys, &slot(1)).await,
            published_key_package(&keys, &slot(1)).await,
        );
        let a = restamped(&keys, &first, Kind::Custom(30443), 5_000);
        let b = restamped(&keys, &second, Kind::Custom(30443), 5_000);
        let lower = if a.id < b.id { a.id } else { b.id };

        for order in [vec![a.clone(), b.clone()], vec![b, a]] {
            let picked = invitable(&keys.public_key(), order).expect("should pick a key package");
            assert_eq!(picked.id, lower);
        }
    }

    #[tokio::test]
    async fn pick_keypackage_ignores_legacy_443_returns_none() {
        // A 443-only result (un-migrated member) is NOT usable — a 443
        // KeyPackage cannot be processed by the engine, so selection must
        // resolve to None rather than return an unprocessable KP.
        let keys = nostr::Keys::generate();
        let kp = published_key_package(&keys, &slot(1)).await;
        let legacy = restamped(&keys, &kp, Kind::MlsKeyPackage, 1_000);

        assert!(
            RelayManager::pick_keypackage_from_events(&keys.public_key(), vec![legacy], None)
                .is_none(),
            "a legacy 443 must never be selected as a usable key package"
        );
    }

    #[tokio::test]
    async fn pick_keypackage_ignores_unrelated_kinds() {
        let keys = nostr::Keys::generate();
        let kp = published_key_package(&keys, &slot(1)).await;
        let unrelated = restamped(&keys, &kp, Kind::TextNote, 9_000);

        assert!(
            RelayManager::pick_keypackage_from_events(&keys.public_key(), vec![unrelated], None)
                .is_none(),
            "unrelated kinds must not be returned"
        );
    }

    /// Content that is no `KeyPackage` is no candidate, however it is signed.
    #[tokio::test]
    async fn pick_keypackage_ignores_a_30443_that_carries_no_key_package() {
        let keys = nostr::Keys::generate();
        let mut hollow = published_key_package(&keys, &slot(1)).await;
        hollow.content = String::new();
        let hollow = restamped(&keys, &hollow, Kind::Custom(30443), 9_000);

        assert!(
            RelayManager::pick_keypackage_from_events(&keys.public_key(), vec![hollow], None)
                .is_none()
        );
    }

    /// Two valid last-resort packages in two slots: the more recently
    /// published wins, and on a tie the lower decoded `KeyPackageRef` does —
    /// in any arrival order.
    #[tokio::test]
    async fn across_slots_the_fresher_package_wins_then_the_lower_ref() {
        let keys = nostr::Keys::generate();
        let one = published_key_package(&keys, &slot(1)).await;
        let two = published_key_package(&keys, &slot(2)).await;

        let older = restamped(&keys, &one, Kind::Custom(30443), 1_000);
        let newer = restamped(&keys, &two, Kind::Custom(30443), 2_000);
        for order in [
            vec![older.clone(), newer.clone()],
            vec![newer.clone(), older],
        ] {
            assert_eq!(
                invitable(&keys.public_key(), order).map(|e| e.id),
                Some(newer.id)
            );
        }

        let a = restamped(&keys, &one, Kind::Custom(30443), 5_000);
        let b = restamped(&keys, &two, Kind::Custom(30443), 5_000);
        let key_package_ref = |event: &Event| -> String {
            event
                .tags
                .iter()
                .find(|t| t.as_slice()[0] == "i")
                .map(|t| t.as_slice()[1].clone())
                .expect("i tag")
        };
        let lower = if key_package_ref(&a) < key_package_ref(&b) {
            a.id
        } else {
            b.id
        };
        for order in [vec![a.clone(), b.clone()], vec![b, a]] {
            assert_eq!(
                invitable(&keys.public_key(), order).map(|e| e.id),
                Some(lower)
            );
        }
    }

    /// `event` as another app would have published it: the same package and
    /// tags plus that app's `client` label, signed at `created_at_secs`.
    fn client_tagged(keys: &nostr::Keys, event: &Event, created_at_secs: u64) -> Event {
        let mut labelled = event.clone();
        labelled
            .tags
            .push(nostr::Tag::parse(["client", "another-app"]).expect("tag"));
        restamped(keys, &labelled, Kind::Custom(30443), created_at_secs)
    }

    /// A Welcome built on another app's package reaches that app, so a package
    /// published without a `client` label is taken first — however much
    /// fresher the labelled one is, and whichever the relay answers first.
    #[tokio::test]
    async fn an_unlabelled_package_is_preferred_to_a_fresher_one_another_app_labelled() {
        let keys = nostr::Keys::generate();
        let own = published_key_package(&keys, &slot(1)).await;
        let foreign = published_key_package(&keys, &slot(2)).await;

        let unlabelled = restamped(&keys, &own, Kind::Custom(30443), 1_000);
        let labelled = client_tagged(&keys, &foreign, 9_000);
        for order in [
            vec![unlabelled.clone(), labelled.clone()],
            vec![labelled, unlabelled.clone()],
        ] {
            assert_eq!(
                invitable(&keys.public_key(), order).map(|e| e.id),
                Some(unlabelled.id)
            );
        }
    }

    /// An account that only uses another app stays invitable.
    #[tokio::test]
    async fn a_labelled_package_is_selected_when_it_is_the_only_one() {
        let keys = nostr::Keys::generate();
        let foreign = published_key_package(&keys, &slot(1)).await;
        let labelled = client_tagged(&keys, &foreign, 9_000);
        assert_eq!(
            invitable(&keys.public_key(), vec![labelled.clone()]).map(|e| e.id),
            Some(labelled.id)
        );
    }

    /// Between two labelled packages, and between two unlabelled ones, the
    /// spec's order decides — the label tier is the same for both.
    #[tokio::test]
    async fn the_label_tier_leaves_equals_to_the_spec_order_in_any_arrival_order() {
        let keys = nostr::Keys::generate();
        let one = published_key_package(&keys, &slot(1)).await;
        let two = published_key_package(&keys, &slot(2)).await;

        let older = client_tagged(&keys, &one, 1_000);
        let newer = client_tagged(&keys, &two, 2_000);
        for order in [
            vec![older.clone(), newer.clone()],
            vec![newer.clone(), older],
        ] {
            assert_eq!(
                invitable(&keys.public_key(), order).map(|e| e.id),
                Some(newer.id),
                "two labelled packages: the fresher"
            );
        }
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

        let outcome = fanned_out(&manager.fanout_transport(), &url).await;
        assert!(
            matches!(outcome, FanoutTargetOutcome::Accepted),
            "the fanout publish has to reach the relay before its registration \
             can be judged",
        );
        assert!(
            !relay.flags().has_ping(),
            "nor may a fanout publish: it registers its target here, and MDK's \
             client behind it must find the relay already held",
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

    // ------------------------------------------------------------------
    // The fanout transport: MDK's relay client on this pool.
    //
    // MDK's client takes no relay options and dials whatever it is named, so
    // these pin what Haven keeps around each call: the target registered with
    // the pool's own options, on the pool's own client, under Haven's relay
    // policy, with the wedge check after.
    // ------------------------------------------------------------------

    /// A signed kind-445 event in the shape the engine's are, as the transport
    /// message a fanout row freezes.
    fn fanout_message() -> TransportMessage {
        let event = nostr::EventBuilder::new(Kind::Custom(KIND_GROUP_MESSAGE), "ciphertext")
            .tag(nostr::Tag::parse(["h", &"ab".repeat(32)]).expect("an h tag"))
            .sign_with_keys(&nostr::Keys::generate())
            .expect("sign");
        SessionManager::event_to_transport_message(&event).expect("a kind-445 event converts")
    }

    impl FanoutTransport {
        /// One call as the driver makes it: the relay taken, then sent to.
        pub(crate) async fn call(
            &self,
            target: &str,
            message: &TransportMessage,
        ) -> FanoutTargetOutcome {
            let taken = self
                .take(target)
                .await
                .expect("the relay could not be had within the gate's wait");
            self.publish(target, message, taken).await
        }
    }

    /// One fanout call to `target` over `transport`.
    async fn fanned_out(transport: &FanoutTransport, target: &str) -> FanoutTargetOutcome {
        transport.call(target, &fanout_message()).await
    }

    /// One fanout publish through `manager`'s transport.
    async fn fanout_publish(
        manager: &RelayManager,
        url: &str,
        message: &TransportMessage,
    ) -> FanoutTargetOutcome {
        manager.fanout_transport().call(url, message).await
    }

    /// The relay as the publish pool holds it now, which must be as Haven
    /// registered it: MDK's client replaces a relay it added itself with a
    /// re-configured one, so a handle taken earlier would prove nothing.
    async fn assert_registered_with_haven_options(manager: &RelayManager, url: &str, after: &str) {
        let relays = manager.client.relays().await;
        assert!(
            relays.len() == 1,
            "{after}: the pool holds something other than the one target",
        );
        let relay = manager
            .client
            .relay(url)
            .await
            .unwrap_or_else(|_| panic!("{after}: the target is gone from the publish pool"));
        let flags = relay.flags();
        assert!(
            flags.has_read() && flags.has_write() && !flags.has_ping(),
            "{after}: the target's flags are no longer the publish pool's",
        );
        assert!(
            format!("{:?}", relay.opts()) == format!("{:?}", publish_relay_options()),
            "{after}: the target's options are no longer publish_relay_options()",
        );
    }

    /// Whatever MDK's client does with a target — accepts on it, is refused on
    /// it, tears its socket down after an ambiguous answer, dials it again — the
    /// relay the publish pool holds has the options Haven registered. After the
    /// ambiguous answer that is no relay at all: the one MDK reset is dropped,
    /// and the next call registers a fresh one.
    ///
    /// Pays three 600 ms adapter backoffs twice over (the refused and the
    /// ambiguous call each make three attempts); every answer is immediate.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn fanout_client_relays_keep_haven_options_across_every_adapter_call() {
        let relay = ScriptedRelay::start();
        let answer = std::sync::Arc::new(std::sync::Mutex::new(""));
        let scripted = std::sync::Arc::clone(&answer);
        relay.on_publish(move |_| match *scripted.lock().expect("script lock") {
            "" => Verdict::Keep,
            text => Verdict::Refuse(text.to_string()),
        });
        let manager = RelayManager::new();
        let transport = manager.fanout_transport();
        let target = relay.url();

        let accepted = fanned_out(&transport, target).await;
        assert!(matches!(accepted, FanoutTargetOutcome::Accepted));
        assert_registered_with_haven_options(&manager, relay.url(), "after an accepted publish")
            .await;

        *answer.lock().expect("script lock") = "blocked: not here";
        let refused = fanned_out(&transport, target).await;
        assert!(matches!(
            refused,
            FanoutTargetOutcome::Failed(failure)
                if failure.kind() == TransportEndpointFailureKind::TerminalRejected
        ));
        assert_registered_with_haven_options(&manager, relay.url(), "after a refused publish")
            .await;

        *answer.lock().expect("script lock") = "error: could not say";
        let held = manager
            .client
            .relay(relay.url())
            .await
            .expect("registered by the calls above");
        let ambiguous = fanned_out(&transport, target).await;
        assert!(matches!(
            ambiguous,
            FanoutTargetOutcome::Failed(failure)
                if failure.kind() == TransportEndpointFailureKind::PossiblyExposed
        ));
        assert_eq!(
            held.status(),
            PoolRelayStatus::Terminated,
            "MDK's client resets a relay after an ambiguous publish; if it no \
             longer does, the case below stops covering a re-dial",
        );
        assert!(
            manager.client.relay(relay.url()).await.is_err(),
            "the relay MDK reset must be dropped from the publish pool, not kept \
             for a dial its termination permit may end",
        );

        *answer.lock().expect("script lock") = "";
        let redialled = fanned_out(&transport, target).await;
        assert!(
            matches!(redialled, FanoutTargetOutcome::Accepted),
            "the publish after the disconnect has to dial the relay again",
        );
        assert_registered_with_haven_options(&manager, relay.url(), "after the re-dial").await;
    }

    /// MDK's client publishes on the publish pool's OWN client — the one
    /// `verified_client` built — not on one of its own: a relay the pool is
    /// already connected to sees no second socket (Security Rule 16).
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn the_fanout_transport_rides_the_publish_clients_own_socket() {
        let relay = ScriptedRelay::start();
        let manager = RelayManager::new();
        manager
            .publish_event(
                &throwaway_note("opens the socket"),
                &[relay.url().to_string()],
            )
            .await
            .expect("the relay is up");
        assert!(relay.connections() == 1, "one publish, one socket");

        let outcome = fanned_out(&manager.fanout_transport(), relay.url()).await;
        assert!(matches!(outcome, FanoutTargetOutcome::Accepted));
        assert!(
            relay.published().len() == 2,
            "both events reached the relay"
        );
        assert!(
            relay.connections() == 1,
            "the fanout publish opened a socket of its own: MDK's client was \
             handed some other client than the publish pool's",
        );
    }

    /// A fanout publish reaches its target and no other relay the pool holds:
    /// which relays a device connects to, and when, is what an observer of
    /// those relays learns. MDK's client connects every relay in the pool
    /// when it subscribes; its publish must not.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_fanout_publish_dials_its_target_alone() {
        let bystander = ScriptedRelay::start();
        let target = ScriptedRelay::start();
        let manager = RelayManager::new();
        manager
            .client
            .pool()
            .add_relay(bystander.url(), publish_relay_options())
            .await
            .expect("register a relay the pool holds and has not dialled");

        let outcome = fanned_out(&manager.fanout_transport(), target.url()).await;
        assert!(matches!(outcome, FanoutTargetOutcome::Accepted));
        assert!(target.connections() == 1, "the target was dialled once");
        // The pool's own status, which a dial changes before any socket opens:
        // the relay's connection count alone would miss a dial still in flight.
        let held = manager
            .client
            .relay(bystander.url())
            .await
            .expect("still registered");
        assert_eq!(
            held.status(),
            PoolRelayStatus::Initialized,
            "a fanout publish dialled a relay it was not sent to",
        );
        assert!(
            bystander.connections() == 0 && bystander.offers() == 0,
            "a fanout publish reached a relay it was not sent to",
        );
    }

    /// Why a fanout target is registered `READ | WRITE` here rather than left
    /// to MDK's client, which would add it write-only: this same client runs
    /// Haven's targeted fetches, and the pool skips a relay without the read
    /// flag — the fetch comes back empty, with no error to notice.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_targeted_fetch_on_the_publish_client_needs_the_read_flag() {
        let relay = ScriptedRelay::start();
        let stored = throwaway_note("stored on the relay");
        relay.answer(
            |_| true,
            vec![
                crate::relay::scripted_relay::Frame::Event(stored.clone()),
                crate::relay::scripted_relay::Frame::Eose,
            ],
        );
        let filter = Filter::new().kind(Kind::TextNote);
        let relays = [relay.url().to_string()];

        // The control: a relay registered as MDK's client registers one.
        let write_only = RelayManager::new();
        write_only
            .client
            .add_write_relay(relay.url())
            .await
            .expect("register write-only");
        write_only.client.connect().await;
        let unread = write_only
            .client
            .fetch_events_from(relays.clone(), filter.clone(), Duration::from_secs(30))
            .await
            .expect("the pool skips a relay it may not read, without an error");
        assert!(
            unread.is_empty(),
            "the pool read from a write-only relay: the read flag is no longer \
             what a targeted fetch needs, and this registration's reason is gone",
        );

        let manager = RelayManager::new();
        let outcome = fanned_out(&manager.fanout_transport(), relay.url()).await;
        assert!(matches!(outcome, FanoutTargetOutcome::Accepted));
        let fetched = manager
            .fetch_events(filter, &relays, Some(Duration::from_secs(30)))
            .await
            .expect("a fetch from a relay the fanout registered");
        assert!(
            fetched == [stored],
            "a targeted fetch after a fanout publish did not return the \
             relay's event",
        );
    }

    /// A relay client that hands the relay one event nobody reads, the reading
    /// a wedged socket gives, and answers as if it had been accepted.
    struct LeavesAnEventUnread(Relay);

    #[async_trait::async_trait]
    impl NostrRelayClient for LeavesAnEventUnread {
        async fn subscribe(
            &self,
            _subscription: transport_nostr_adapter::NostrSubscription,
        ) -> Result<(), cgka_traits::TransportAdapterError> {
            Err(cgka_traits::TransportAdapterError::Closed)
        }

        async fn unsubscribe(
            &self,
            _subscription: transport_nostr_adapter::NostrSubscription,
        ) -> Result<(), cgka_traits::TransportAdapterError> {
            Err(cgka_traits::TransportAdapterError::Closed)
        }

        async fn unsubscribe_account(
            &self,
            _account_id: &cgka_traits::MemberId,
        ) -> Result<(), cgka_traits::TransportAdapterError> {
            Err(cgka_traits::TransportAdapterError::Closed)
        }

        async fn publish_event(
            &self,
            endpoints: &[TransportEndpoint],
            _event: &transport_nostr_peeler::NostrTransportEvent,
            _required_acks: usize,
        ) -> Result<transport_nostr_adapter::NostrPublishOutcome, cgka_traits::TransportAdapterError>
        {
            // The connection task gets an empty channel and a fresh
            // cooperative budget here; nothing after this yields before the
            // transport's wedge check reads the queue.
            tokio::task::yield_now().await;
            self.0
                .batch_msg(vec![ClientMessage::event(throwaway_note("unread"))])
                .expect("the pool accepts the send");
            Ok(transport_nostr_adapter::NostrPublishOutcome::accepted(
                endpoints.iter().cloned(),
            ))
        }
    }

    /// The wedge check runs after a fanout publish as it does after every
    /// other send: a target left `Connected` with an event unread is freed, so
    /// the next publish dials a live socket.
    ///
    /// Single-threaded, for the reason
    /// `the_recovery_terminates_a_real_socket_that_holds_an_unread_message`
    /// gives: the unread reading is the one the relay client created, not a
    /// lucky sample.
    #[tokio::test(flavor = "current_thread")]
    async fn a_wedged_target_is_freed_after_a_fanout_publish() {
        let _ = allow_ws_loopback_for_test();
        let server = LocalRelay::new(RelayBuilder::default());
        server.run().await.expect("local relay runs");
        let url = server.url().await.to_string();
        let target = url.as_str();

        let manager = RelayManager::new();
        assert!(matches!(
            fanned_out(&manager.fanout_transport(), target).await,
            FanoutTargetOutcome::Accepted
        ));
        let relay = manager
            .client
            .relay(url.as_str())
            .await
            .expect("the publish registered the relay");
        assert_eq!(relay.status(), PoolRelayStatus::Connected);

        let wedging = FanoutTransport {
            client: manager.client.clone(),
            relay_client: Arc::new(LeavesAnEventUnread(relay.clone())),
            gates: FanoutGates::default(),
            clock: device_clock(),
        };
        let _ = fanned_out(&wedging, target).await;
        assert_eq!(
            relay.status(),
            PoolRelayStatus::Terminated,
            "a fanout publish left its target connected with an event unread: \
             nothing re-dials that socket, and every later publish to the \
             relay queues behind it",
        );

        assert!(
            matches!(
                fanned_out(&manager.fanout_transport(), target).await,
                FanoutTargetOutcome::Accepted
            ),
            "and the freed target must be one the very next publish reaches",
        );
    }

    /// The fast shape of the masking the transport closes. Another publish
    /// path's socket repair ends the first attempt with no answer while the
    /// relay holds the event; that path re-dials; MDK's later attempts are
    /// refused and MDK reports the refusal. No attempt count and no elapsed
    /// time tells this from three clean refusals — only the relay's own
    /// answers do.
    ///
    /// Possibly exposed in every interleaving: the first attempt is never
    /// answered, whether or not the re-dial lands before MDK's next attempt.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_refusal_that_follows_a_concurrent_disconnect_is_possibly_exposed() {
        let relay = ScriptedRelay::start();
        let stored = Arc::new(tokio::sync::Notify::new());
        let first = Arc::clone(&stored);
        let offered = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counter = Arc::clone(&offered);
        relay.on_publish(move |_| {
            if counter.fetch_add(1, std::sync::atomic::Ordering::SeqCst) == 0 {
                first.notify_one();
                Verdict::KeepSilently
            } else {
                Verdict::Refuse("blocked: not any more".to_string())
            }
        });
        let manager = RelayManager::new();
        manager
            .client
            .pool()
            .add_relay(relay.url(), publish_relay_options())
            .await
            .expect("register the target");
        let socket = manager
            .client
            .relay(relay.url())
            .await
            .expect("the target was just registered");
        let message = fanout_message();

        let (outcome, ()) = tokio::join!(fanout_publish(&manager, relay.url(), &message), async {
            // Bounded: a relay that never sees the event must fail the test,
            // not hang it.
            tokio::time::timeout(wait_budget(30), stored.notified())
                .await
                .expect("the relay stores the first attempt");
            socket.disconnect();
            let _ = manager
                .client
                .try_connect_relay(relay.url(), wait_budget(30))
                .await;
        });

        assert!(
            relay.published().len() == 1,
            "the relay stored the first attempt: that is the case",
        );
        assert!(
            matches!(
                &outcome,
                FanoutTargetOutcome::Failed(failure)
                    if failure.kind() == TransportEndpointFailureKind::PossiblyExposed
            ),
            "a refusal that followed an unanswered attempt was returned as \
             proof the relay does not hold the event",
        );
    }

    /// "Can never authenticate" is two facts, either of which is enough and
    /// both of which hold: the publish client has no signer to answer a NIP-42
    /// challenge with, and is told not to answer one. An answer would sign a
    /// relay's challenge with the identity key on a socket that carries a
    /// circle's routing id.
    #[tokio::test]
    async fn the_publish_client_holds_no_signer_and_never_authenticates() {
        let manager = RelayManager::new();
        assert!(
            !manager.client.has_signer().await,
            "the publish client holds a signer: MDK's relay client signs an \
             unsigned event with it, and the pool answers AUTH with it",
        );
        assert!(
            !manager
                .client
                .pool()
                .state()
                .is_auto_authentication_enabled(),
            "the publish client would answer a NIP-42 challenge the day it \
             held a signer",
        );
    }

    /// One MDK relay client per manager, however many transports are taken:
    /// its publish-relay bookkeeping and its lifecycle lock are per instance.
    #[tokio::test]
    async fn every_fanout_transport_of_a_manager_shares_one_mdk_relay_client() {
        let manager = RelayManager::new();
        let (first, second) = (manager.fanout_transport(), manager.fanout_transport());
        assert!(
            Arc::ptr_eq(&first.relay_client, &second.relay_client),
            "each fanout_transport() built an MDK relay client of its own",
        );
    }

    /// A relay the pool already holds is found, not registered again: the
    /// registration takes the pool's write lock, which waits behind a publish
    /// that is still waiting for its `OK`.
    #[tokio::test(flavor = "current_thread")]
    async fn a_relay_the_pool_already_holds_is_not_registered_again() {
        let relay = ScriptedRelay::start();
        let relays = [relay.url().to_string()];
        let manager = RelayManager::new();
        let registrations = |lines: Vec<String>| {
            lines
                .iter()
                .filter(|line| line.starts_with("[RelayManager] add_relay "))
                .count()
        };

        let first = crate::test_log::capture_log_lines(async {
            manager
                .publish_event(&throwaway_note("registers the relay"), &relays)
                .await
                .expect("the relay is up");
        })
        .await;
        assert!(registrations(first) == 1, "the first publish registers it");

        let second = crate::test_log::capture_log_lines(async {
            manager
                .publish_event(&throwaway_note("finds it registered"), &relays)
                .await
                .expect("the relay is still up");
        })
        .await;
        assert!(
            registrations(second) == 0,
            "a relay the pool already held was registered again",
        );
    }

    /// The same holds for the two other paths that register relays: a
    /// catch-up page or a fire-and-forget publish to a relay the pool holds
    /// takes no write lock, so it never waits behind a send that is waiting
    /// for its `OK` — and never makes the readers behind it wait either, MDK's
    /// next fanout attempt among them.
    ///
    /// The silent send holds the pool's read lock for the pool's whole `OK`
    /// wait (10 s). Each path must finish while it is still waiting; the red
    /// outcome is the send finishing first, so the wait is only paid then.
    #[tokio::test(flavor = "current_thread")]
    async fn no_path_registers_a_held_relay_behind_a_send_awaiting_its_ok() {
        let _ = allow_ws_loopback_for_test();
        let relay = ScriptedRelay::start();
        relay.on_publish(|event| {
            if event.content == "never answered" {
                Verdict::KeepSilently
            } else {
                Verdict::Keep
            }
        });
        let relays = [relay.url().to_string()];
        let manager = RelayManager::new();
        manager
            .publish_event(&throwaway_note("registers the relay"), &relays)
            .await
            .expect("the relay is up");
        let held = manager
            .client
            .relay(relay.url())
            .await
            .expect("the publish registered the relay");

        let silent = throwaway_note("never answered");
        let waiting = manager.client.send_event_to([relay.url()], &silent);
        tokio::pin!(waiting);

        let fetched = tokio::select! {
            biased;
            _ = &mut waiting => None,
            page = manager.fetch_events_per_relay(
                Filter::new().kind(Kind::TextNote).limit(1),
                &relays,
            ) => Some(page),
        };
        assert!(
            fetched.is_some_and(|page| page.is_ok_and(|outcomes| outcomes[0].responded)),
            "a per-relay fetch from a relay the pool holds waited behind a send \
             that was waiting for its OK",
        );

        let mut notifications = held.notifications();
        let backgrounded = throwaway_note("sent from the background path");
        let backgrounded_id = backgrounded.id;
        manager
            .publish_event_background(backgrounded, &relays)
            .expect("the fire-and-forget path validates its urls");
        let acked = tokio::select! {
            biased;
            _ = &mut waiting => false,
            acked = await_ok_for(&mut notifications, backgrounded_id, wait_budget(30)) => acked,
        };
        assert!(
            acked,
            "a background publish to a relay the pool holds waited behind a \
             send that was waiting for its OK",
        );
    }

    /// A relay client that does to the pool what MDK's does when the target
    /// appears between its check and its add (`sdk_client.rs` 1161-1169): adds
    /// it as a write relay through the SDK, which ORs `PING` onto the relay
    /// the pool already holds.
    struct AddsItsTargetAgain(Client);

    #[async_trait::async_trait]
    impl NostrRelayClient for AddsItsTargetAgain {
        async fn subscribe(
            &self,
            _: transport_nostr_adapter::NostrSubscription,
        ) -> Result<(), cgka_traits::TransportAdapterError> {
            Err(cgka_traits::TransportAdapterError::Closed)
        }

        async fn unsubscribe(
            &self,
            _: transport_nostr_adapter::NostrSubscription,
        ) -> Result<(), cgka_traits::TransportAdapterError> {
            Err(cgka_traits::TransportAdapterError::Closed)
        }

        async fn unsubscribe_account(
            &self,
            _: &cgka_traits::MemberId,
        ) -> Result<(), cgka_traits::TransportAdapterError> {
            Err(cgka_traits::TransportAdapterError::Closed)
        }

        async fn publish_event(
            &self,
            endpoints: &[TransportEndpoint],
            _event: &transport_nostr_peeler::NostrTransportEvent,
            _required_acks: usize,
        ) -> Result<transport_nostr_adapter::NostrPublishOutcome, cgka_traits::TransportAdapterError>
        {
            for endpoint in endpoints {
                self.0
                    .add_write_relay(endpoint.as_str())
                    .await
                    .expect("the SDK takes a second add of a held relay");
            }
            Ok(transport_nostr_adapter::NostrPublishOutcome::accepted(
                endpoints.iter().cloned(),
            ))
        }
    }

    /// No fanout call leaves its target with the keepalive: a publish-pool
    /// relay that pings holds a NAT binding and the radio for nothing.
    #[tokio::test]
    async fn a_fanout_publish_never_leaves_its_target_pinging() {
        let _ = allow_ws_loopback_for_test();
        let relay = ScriptedRelay::start();
        let manager = RelayManager::new();
        let racing = FanoutTransport {
            client: manager.client.clone(),
            relay_client: Arc::new(AddsItsTargetAgain(manager.client.clone())),
            gates: FanoutGates::default(),
            clock: device_clock(),
        };
        let _ = fanned_out(&racing, relay.url()).await;
        let held = manager
            .client
            .relay(relay.url())
            .await
            .expect("the publish registered the relay");
        assert!(
            held.flags().has_write() && held.flags().has_read(),
            "premise: the target is still a relay this pool reads and writes",
        );
        assert!(
            !held.flags().has_ping(),
            "a fanout publish left its target with the keepalive on",
        );
    }

    /// A target Haven's relay policy refuses is never registered, so never
    /// dialled, however its scheme is spelled; the publish comes back not
    /// exposed. The routing entry it comes from is another client's to write.
    #[tokio::test]
    async fn a_plaintext_fanout_target_is_never_dialled_however_it_is_spelled() {
        let manager = RelayManager::new();
        let transport = manager.fanout_transport();
        for target in [
            "ws://relay.example",
            "WS://relay.example",
            "ws:relay.example",
            " ws://relay.example",
            "https://relay.example",
            "not a relay",
        ] {
            let outcome = fanned_out(&transport, target).await;
            assert!(
                matches!(
                    &outcome,
                    FanoutTargetOutcome::Failed(failure)
                        if failure.kind() == TransportEndpointFailureKind::NotExposed
                            && failure.rejection_category().is_none()
                ),
                "a target Haven refused to dial has to come back as not exposed: \
                 nothing left the device, and a row that could only say \
                 \"possibly exposed\" could never end",
            );
            assert!(
                manager.client.relays().await.is_empty(),
                "a target Haven refuses was registered in the publish pool, \
                 which is what gets it dialled",
            );
        }
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

        let result = publish_with_retry(
            MAX_PUBLISH_ATTEMPTS,
            Duration::ZERO,
            || 0,
            |_| {
                let outcome = socket.publish_attempt();
                async move { Ok(outcome) }
            },
        )
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

        let result = publish_with_retry(
            MAX_PUBLISH_ATTEMPTS,
            Duration::ZERO,
            || 0,
            |_| {
                let outcome = socket.publish_attempt();
                async move { Ok(outcome) }
            },
        )
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
            publish_with_retry(
                LOCATION_PUBLISH_ATTEMPTS,
                Duration::ZERO,
                || 0,
                |_| {
                    let outcome = socket.publish_attempt();
                    async move { Ok(outcome) }
                },
            )
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
            manager.client.relay(url.as_str()).await.is_err(),
            "the freed relay must be dropped from the pool: a wedge has no \
             connection task, so the disconnect left a permit that would end \
             the next dial of this same object",
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

    // ------------------------------------------------------------------
    // A relay Haven disconnects is dropped, never dialled again.
    //
    // `disconnect` on a relay with no connection task stores a termination
    // permit, and the next dial of that object consumes it: `TerminationRequest`,
    // the status left `Connecting`, and every later dial a no-op while sends
    // queue into a channel nobody reads. Each test below leaves a relay with no
    // task in the state one product path does, has that path disconnect it, and
    // requires the next send to land.
    // ------------------------------------------------------------------

    /// A local relay and a manager that has not touched it yet.
    async fn local_relay_and_manager() -> (LocalRelay, String, RelayManager) {
        let _ = allow_ws_loopback_for_test();
        let server = LocalRelay::new(RelayBuilder::default());
        server.run().await.expect("local relay runs");
        let url = server.url().await.to_string();
        (server, url, RelayManager::new())
    }

    /// Registers `url` and drops its first dial after one poll, as a send
    /// cut short by its caller's bound does: `Connecting`, with no task.
    ///
    /// One poll on a single thread: the pool's locks are uncontended and the
    /// admission policy is ready at once, while the handshake needs the server,
    /// which cannot run until this returns.
    async fn strand_mid_dial(manager: &RelayManager, url: &str) {
        use futures::FutureExt;
        let relay_url = RelayUrl::parse(url).expect("loopback url");
        RelayManager::register_publish_relays(&manager.client, &[relay_url]).await;
        assert!(
            manager
                .client
                .try_connect_relay(url, CONNECTION_TIMEOUT)
                .now_or_never()
                .is_none(),
            "the dial finished in one poll, so nothing was cut short",
        );
        assert_eq!(
            manager
                .client
                .relay(url)
                .await
                .expect("registered")
                .status(),
            PoolRelayStatus::Connecting,
        );
    }

    /// Whether the pool's relay at `url` is connected now.
    async fn pool_relay_connected(manager: &RelayManager, url: &str) -> bool {
        manager
            .client
            .relay(url)
            .await
            .is_ok_and(|relay| relay.is_connected())
    }

    /// A relay the pool holds but never dialled is `Initialized`, with no task,
    /// and `disconnect` and `try_connect` take the same branches on it as on a
    /// `Sleeping` one. The pool must also stay usable across shutdown after
    /// shutdown: by the fanout, by a plain publish and by a NIP-77 pass.
    #[tokio::test(flavor = "current_thread")]
    async fn a_relay_registered_but_never_dialled_is_reachable_after_shutdown() {
        let (_server, url, manager) = local_relay_and_manager().await;
        let relay_url = RelayUrl::parse(&url).expect("loopback url");
        RelayManager::register_publish_relays(&manager.client, &[relay_url]).await;
        assert_eq!(
            manager
                .client
                .relay(url.as_str())
                .await
                .expect("registered")
                .status(),
            PoolRelayStatus::Initialized,
        );

        manager.shutdown().await;
        assert!(
            matches!(
                fanout_publish(&manager, &url, &fanout_message()).await,
                FanoutTargetOutcome::Accepted
            ),
            "a relay the shutdown disconnected before it was ever dialled must \
             still take the next fanout publish",
        );
        assert!(pool_relay_connected(&manager, &url).await);

        manager.shutdown().await;
        assert!(
            manager
                .publish_event(
                    &throwaway_note("after the second shutdown"),
                    std::slice::from_ref(&url)
                )
                .await
                .expect("the relay is up")
                .is_success(),
            "the pool must take a plain publish after another shutdown",
        );

        manager.shutdown().await;
        manager.neg_prepare(std::slice::from_ref(&url)).await;
        let ends = tokio::time::Instant::now() + wait_budget(30);
        assert!(
            matches!(
                manager
                    .neg_remote_ids(
                        &[0xab; 32],
                        &url,
                        0,
                        nostr::Timestamp::now().as_secs(),
                        ends
                    )
                    .await,
                crate::relay::negentropy::NegAnswer::Complete(_)
            ),
            "and a NIP-77 pass after a third",
        );
    }

    /// A dial its caller's bound cut short leaves the relay `Connecting` with
    /// no task, which no later dial leaves; the shutdown has to retire it.
    #[tokio::test(flavor = "current_thread")]
    async fn a_dial_cancelled_mid_handshake_is_healed_by_shutdown() {
        let (_server, url, manager) = local_relay_and_manager().await;
        strand_mid_dial(&manager, &url).await;

        manager.shutdown().await;
        assert!(
            matches!(
                fanout_publish(&manager, &url, &fanout_message()).await,
                FanoutTargetOutcome::Accepted
            ),
            "after the shutdown the relay a cut dial stranded must take the next \
             fanout publish",
        );
        assert!(pool_relay_connected(&manager, &url).await);
    }

    /// The burst pool's own idle sleep: a relay that slept after a burst is
    /// shut down at the pause and must take the next burst's send.
    ///
    /// The permit is stored whichever way the shutdown meets the sleeping
    /// task: the `Sleeping` broadcast is made inside the poll that ends the
    /// connection task's `select!`, and a termination waiter dropped notified
    /// but unreceived hands its `notify_one` on to the next waiter, or stores
    /// it when there is none (tokio 1.52.1 `sync/notify.rs` 1365-1374).
    ///
    /// ~60–70 s of wall clock, for the reason
    /// `the_publish_socket_sleeps_after_a_burst_and_wakes_for_the_next` gives.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_sleeping_publish_socket_is_reachable_after_shutdown() {
        let (_server, url, manager) = local_relay_and_manager().await;
        assert!(manager
            .publish_event(&throwaway_note("the burst"), std::slice::from_ref(&url))
            .await
            .expect("the burst reaches the relay")
            .is_success());
        let mut notifications = manager
            .client
            .relay(url.as_str())
            .await
            .expect("the publish added the relay to the pool")
            .notifications();
        assert_eq!(
            next_relay_status(&mut notifications, wait_budget(180)).await,
            Some(nostr_sdk::RelayStatus::Sleeping),
        );

        manager.shutdown().await;
        assert!(
            matches!(
                fanout_publish(&manager, &url, &fanout_message()).await,
                FanoutTargetOutcome::Accepted
            ),
            "a relay that slept before the shutdown must take the next fanout \
             publish",
        );
        assert!(pool_relay_connected(&manager, &url).await);
    }

    /// A fanout call that ends possibly exposed makes MDK's client disconnect
    /// the relay; on one with no task that stores the permit, and the target
    /// would answer every later call unavailable or ambiguous, holding its
    /// commit pending (Security Rule 13) until the next pause.
    ///
    /// The first call's ~20 s of MDK waits run on a paused clock: nothing is
    /// dialled while the relay is stranded, so only MDK's own timers advance.
    /// The clock is resumed before the call that does dial.
    #[tokio::test(flavor = "current_thread")]
    async fn a_relay_mdk_reset_after_an_ambiguous_publish_is_reachable_again() {
        let (_server, url, manager) = local_relay_and_manager().await;
        strand_mid_dial(&manager, &url).await;

        tokio::time::pause();
        let ambiguous = fanout_publish(&manager, &url, &fanout_message()).await;
        tokio::time::resume();
        assert!(matches!(
            ambiguous,
            FanoutTargetOutcome::Failed(failure)
                if failure.kind() == TransportEndpointFailureKind::PossiblyExposed
        ));

        assert!(
            matches!(
                fanout_publish(&manager, &url, &fanout_message()).await,
                FanoutTargetOutcome::Accepted
            ),
            "the relay MDK reset after the ambiguous call must take the next one",
        );
        assert!(pool_relay_connected(&manager, &url).await);
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

    /// The call every send path owes, and the four ways this file hands an
    /// event to a relay: the pooled fan-out, the harvest's per-relay unit, the
    /// `Relay` handle's own send — which is what that unit uses, and what a
    /// new function written against a relay handle directly would use — and
    /// the fanout transport's hand-over to MDK's relay client.
    const WEDGE_CHECK: &str = "recover_wedged_publish_sockets(";
    const SENDS: [&str; 4] = [
        "client.send_event_to(",
        "send_to_one(client,",
        "relay.send_event(",
        "fanout::publish_to_target(",
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
            "offer_harvest",
            "publish_event_background",
            "send_to_one",
            "publish",
        ] {
            assert!(
                senders.iter().any(|name| name == expected),
                "the scan has to reach `{expected}` or it is reading nothing: \
                 {senders:?}",
            );
        }
    }

    /// Every method that publishes an event a CALLER hands it refuses one
    /// that has a durable fanout row, before anything else: the fanout driver
    /// is such an event's only sender on any publish pool. The driver's own
    /// transport is the one sender that does not: its `publish_location` is
    /// how a recorded location is sent at all, and it reaches the pool
    /// through `send_location`, which is private to this module.
    #[test]
    fn every_method_that_publishes_a_callers_event_refuses_a_fanout_owned_one_first() {
        let takes_an_event = |function: &ScannedFn| {
            function.code.contains("(&self,event:&Event,")
                || function.code.contains("(&self,event:Event,")
        };
        let publishers: Vec<ScannedFn> = scan_production_functions(include_str!("manager.rs"))
            .into_iter()
            .filter(takes_an_event)
            .collect();
        let names: Vec<&str> = publishers.iter().map(|f| f.name.as_str()).collect();
        assert_eq!(
            names,
            [
                "publish_event",
                "publish_profile_event",
                "offer_profile_event",
                "publish_location_event",
                "publish_event_background",
                "publish_location"
            ],
            "the scan reads the publish entry points, or it is reading nothing",
        );
        let source: String = include_str!("manager.rs")
            .split("#[cfg(test)]\nmod tests")
            .next()
            .unwrap_or_default()
            .chars()
            .filter(|c| !c.is_whitespace())
            .collect();
        assert!(
            source.contains("implfanout::FanoutSendforFanoutTransport{")
                && source.matches("Self::send_location(").count() == 1
                && source.matches("RelayManager::send_location(").count() == 1
                && source.contains("asyncfnsend_location(client:&Client,"),
            "the send that refuses no fanout-owned event has a caller besides the legacy \
             entry, which refuses first, and the driver's transport — or is no longer private",
        );
        for function in publishers.iter().filter(|f| f.name != "publish_location") {
            let body = function.code.split_once('{').map_or("", |(_, body)| body);
            assert!(
                body.starts_with("Self::refuse_fanout_owned(event)?;")
                    || body.starts_with("Self::refuse_fanout_owned(&event)?;"),
                "`{}` can send an event that has a fanout row: a second sender's \
                 relay answers would be counted as the fanout's own",
                function.name,
            );
        }
    }

    /// One fanout call per relay at a time on a pool, whichever events they
    /// carry: the relay sees one call's three attempts, then the other's.
    ///
    /// Two calls, each refused three times 600 ms apart by MDK's own loop
    /// (about 2.5 s in all). Not a race: without the gate both calls send
    /// their first attempt at once, so the order is interleaved from the
    /// first frame.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn one_fanout_call_per_relay_at_a_time() {
        let _ = allow_ws_loopback_for_test();
        let relay = ScriptedRelay::start();
        let offered = Arc::new(std::sync::Mutex::new(Vec::new()));
        let seen = Arc::clone(&offered);
        relay.on_publish(move |event| {
            seen.lock().expect("offers").push(event.id);
            Verdict::Refuse("blocked: not here".to_string())
        });
        let manager = RelayManager::new();
        let (first, second) = (fanout_message(), fanout_message());
        // Two transports of one manager share the gate.
        let (a, b) = (manager.fanout_transport(), manager.fanout_transport());

        let outcomes: [FanoutTargetOutcome; 2] =
            tokio::join!(a.call(relay.url(), &first), b.call(relay.url(), &second)).into();
        for outcome in outcomes {
            assert!(
                matches!(
                    &outcome,
                    FanoutTargetOutcome::Failed(failure)
                        if failure.kind() == TransportEndpointFailureKind::TerminalRejected
                ),
                "premise: each call was refused on every attempt, and proved it",
            );
        }
        let order = offered.lock().expect("offers").clone();
        assert_eq!(order.len(), 6, "premise: three attempts per call");
        assert!(
            order[..3].iter().all(|id| *id == order[0])
                && order[3..].iter().all(|id| *id == order[3])
                && order[0] != order[3],
            "two fanout calls were under way to one relay at once",
        );
    }

    /// Waits, without sleeping, until some task other than this test stands
    /// at `gate`: a caller takes a handle on a relay's gate before it waits
    /// for it.
    async fn someone_waits_at(gate: &Arc<tokio::sync::Mutex<()>>, handles_before: usize) {
        while Arc::strong_count(gate) <= handles_before {
            tokio::task::yield_now().await;
        }
    }

    /// A fanout call that ends ambiguously makes MDK's client disconnect its
    /// relay, and a legacy commit publish under way to that relay would read
    /// a failure and roll its commit back. So neither is under way to a relay
    /// while the other is: each waits at that relay's gate.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_legacy_publish_and_a_fanout_call_never_run_to_one_relay_at_once() {
        let _ = allow_ws_loopback_for_test();
        let relay = ScriptedRelay::start();
        let bystander = ScriptedRelay::start();
        let manager = RelayManager::new();
        let url = RelayManager::validate_single_relay_url(relay.url()).expect("a relay url");
        let gate_of = |manager: &RelayManager| {
            Arc::clone(
                manager
                    .fanout_gates
                    .lock()
                    .expect("gates")
                    .get(&url)
                    .expect("the relay has a gate"),
            )
        };

        // A fanout call to the relay is under way: it holds the relay's gate.
        let fanout_call =
            hold_fanout_gates(&manager.fanout_gates, std::slice::from_ref(&url)).await;
        let gate = gate_of(&manager);
        let handles = Arc::strong_count(&gate);
        let note = throwaway_note("a commit published the legacy way");
        let targets = [relay.url().to_string(), bystander.url().to_string()];
        let legacy = manager.publish_event(&note, &targets);
        tokio::pin!(legacy);
        tokio::select! {
            biased;
            _ = &mut legacy => panic!(
                "a legacy publish ran to a relay while a fanout call to it was under way",
            ),
            () = someone_waits_at(&gate, handles) => {}
        }
        assert!(
            relay.connections() == 0 && bystander.published().is_empty(),
            "the legacy publish sent before it had the relay to itself",
        );
        drop(fanout_call);
        assert!(legacy.await.expect("the relays are up").is_success());
        assert!(relay.published().iter().any(|event| event.id == note.id));

        // And the other way round: a legacy publish under way holds it.
        let legacy_publish =
            hold_fanout_gates(&manager.fanout_gates, std::slice::from_ref(&url)).await;
        let handles = Arc::strong_count(&gate);
        let message = fanout_message();
        let transport = manager.fanout_transport();
        let call = transport.call(relay.url(), &message);
        tokio::pin!(call);
        let before = relay.published().len();
        tokio::select! {
            biased;
            _ = &mut call => panic!(
                "a fanout call ran to a relay while a legacy publish to it was under way",
            ),
            () = someone_waits_at(&gate, handles) => {}
        }
        assert_eq!(relay.published().len(), before);
        drop(legacy_publish);
        assert!(matches!(call.await, FanoutTargetOutcome::Accepted));
    }

    /// A drive waits for a relay another send holds for a bounded time and
    /// no longer: the relay is then not taken — nothing is registered,
    /// dialled or handed over — and a drive's budget stays a true one. Once
    /// the other send is done the relay is taken at once. On a paused clock,
    /// which only the wait itself can move.
    #[tokio::test(start_paused = true)]
    async fn a_relay_another_send_holds_is_not_taken_for_a_fanout_call_until_it_is_free() {
        let manager = RelayManager::new();
        let target = "wss://busy.gate-canary4e7a.example.com";
        let url = RelayManager::validate_single_relay_url(target).expect("a relay url");
        let held = hold_fanout_gates(&manager.fanout_gates, std::slice::from_ref(&url)).await;
        let transport = manager.fanout_transport();
        let began = tokio::time::Instant::now();

        let taken = transport.take(target).await.is_some();

        assert_eq!(
            began.elapsed(),
            Duration::from_secs(fanout::GATE_WAIT_SECS),
            "the call did not wait exactly its bound for the relay",
        );
        assert!(
            !taken,
            "a relay another send held was taken for a fanout call",
        );
        assert!(
            manager.client.relay(target).await.is_err(),
            "a relay was registered, or dialled, for a call that never had it",
        );
        drop(held);
        let began = tokio::time::Instant::now();
        assert!(transport.take(target).await.is_some());
        assert_eq!(
            began.elapsed(),
            Duration::ZERO,
            "a free relay was waited for"
        );
    }

    /// The relay's gate serves whoever waits for it in the order they came:
    /// a fanout call waiting for a relay is let in ahead of every send that
    /// asked after it, and that send waits until the call is done.
    // What each task holds, and for how long, is what is being shown.
    #[allow(clippy::significant_drop_tightening)]
    #[tokio::test(start_paused = true)]
    async fn a_fanout_call_waiting_for_a_relay_goes_ahead_of_every_later_send() {
        let manager = RelayManager::new();
        let target = "wss://queued.gate-canary4e7a.example.com";
        let url = RelayManager::validate_single_relay_url(target).expect("a relay url");
        let held = hold_fanout_gates(&manager.fanout_gates, std::slice::from_ref(&url)).await;
        let transport = Arc::new(manager.fanout_transport());

        let waiting = tokio::spawn({
            let transport = Arc::clone(&transport);
            async move { transport.take(target).await }
        });
        tokio::task::yield_now().await;
        let later = tokio::spawn({
            let gates = Arc::clone(&manager.fanout_gates);
            async move { hold_fanout_gates(&gates, std::slice::from_ref(&url)).await }
        });
        tokio::task::yield_now().await;
        assert!(!waiting.is_finished() && !later.is_finished(), "premise");

        drop(held);
        let taken = waiting
            .await
            .expect("the task ran")
            .expect("the waiting call was not let in when the relay came free");
        tokio::task::yield_now().await;
        assert!(
            !later.is_finished(),
            "a later send was let in beside the fanout call that was waiting first",
        );
        drop(taken);
        assert_eq!(later.await.expect("the task ran").len(), 1);
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

        let presence = crate::relay::maintenance::own_presence(
            &manager,
            &nostr::Keys::generate().public_key(),
            &crate::relay::maintenance::OwnRelayLists {
                inbox: &relays,
                key_package: &relays,
                lookup: &[],
            },
            None,
            crate::relay::maintenance::TrackedKpLifetime::Absent,
        )
        .await;
        let missing = crate::relay::maintenance::OwnEventPresence::Missing;
        assert!(
            presence[0].key_package == missing
                && presence[0].relay_list == missing
                && presence[0].inbox_relay_list == missing,
            "each of the three REQs was answered in full: {presence:?}",
        );
        assert_no_long_lived_subscription(&manager, "own_presence").await;

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
        let result = publish_with_retry(
            LOCATION_PUBLISH_ATTEMPTS,
            Duration::ZERO,
            || 0,
            |_| {
                attempts.set(attempts.get() + 1);
                async {
                    // The worst one attempt can cost: a full handshake against a
                    // relay that never completes it, then a fan-out that returns
                    // at its own window because nothing answered.
                    tokio::time::sleep(CONNECTION_TIMEOUT).await;
                    let _ =
                        tokio::time::timeout(LOCATION_ACK_WINDOW, futures::future::pending::<()>())
                            .await;
                    Ok(dummy_publish_result(false))
                }
            },
        )
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

    /// The one error contract the user is told of rather than merely shown a
    /// failure: the clock complaint, carried typed to the clock-skew check.
    /// Dropping the ladder around the fan-out would silently flatten it to
    /// `AllRelaysFailed` and the fast-clock outage would go quiet again.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn publish_location_event_reports_a_clock_rejection_without_retrying() {
        // NIP-01's `invalid:` prefix, as a relay refusing a timestamp sends it:
        // under a prefix other than `invalid:` or `blocked:` a timestamp
        // mention is no clock complaint (`clock_skew::classify_clock_refusal`).
        let relay = crate::relay::scripted_relay::ScriptedRelay::start();
        relay.on_publish(|_| {
            crate::relay::scripted_relay::Verdict::Refuse(
                "invalid: created_at is in the future".to_string(),
            )
        });

        let manager = RelayManager::new();
        let result = manager
            .publish_location_event(
                &throwaway_note("too new for this relay"),
                &[relay.url().to_string()],
            )
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
            relay.offers(),
            1,
            "a hopeless clock rejection is not retried either",
        );
    }

    /// khatru answers a timestamp out of its window under `blocked:`, not
    /// `invalid:` (its `handleNormal` prefixes every policy verdict so): the
    /// clock verdict and the no-retry rule read it all the same.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_khatru_relay_refusing_the_timestamp_is_a_clock_rejection_without_a_retry() {
        let relay = crate::relay::scripted_relay::ScriptedRelay::start();
        relay.on_publish(|_| {
            crate::relay::scripted_relay::Verdict::Refuse(
                "blocked: event too much in the future".to_string(),
            )
        });

        let result = RelayManager::new()
            .publish_location_event(
                &throwaway_note("too new for a khatru relay"),
                &[relay.url().to_string()],
            )
            .await;

        assert!(
            matches!(
                result,
                Err(RelayError::DeviceClockRejected {
                    complaint: clock_skew::DeviceClockComplaint::Ahead,
                }),
            ),
            "khatru's timestamp refusal was not read as the clock verdict: {result:?}",
        );
        assert_eq!(
            relay.offers(),
            1,
            "a hopeless clock rejection is not retried"
        );
    }

    /// An event signed hours ago and refused as too old is refused for its
    /// age: the publish fails as any unacknowledged one does, with no clock
    /// verdict, where the same refusal of a fresh event is one.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn an_old_event_refused_as_too_old_is_no_clock_rejection() {
        // The event's age is read off the manager's clock alone, never the
        // wall clock, so no stall of the test can change it.
        const NOW: u64 = 1_700_000_000;
        let relay = crate::relay::scripted_relay::ScriptedRelay::start();
        relay.on_publish(|_| {
            crate::relay::scripted_relay::Verdict::Refuse("blocked: event too old".to_string())
        });
        let signed_at = |secs: u64, content: &str| {
            nostr::EventBuilder::new(Kind::TextNote, content)
                .custom_created_at(nostr::Timestamp::from(secs))
                .sign_with_keys(&nostr::Keys::generate())
                .expect("sign")
        };
        let result = RelayManager::at_for_test(NOW)
            .publish_location_event(
                &signed_at(NOW - 3 * 3600, "signed hours ago"),
                &[relay.url().to_string()],
            )
            .await;
        assert!(
            !matches!(result, Err(RelayError::DeviceClockRejected { .. })),
            "a refusal of an event for its age was read as this device's clock: {result:?}",
        );

        let fresh = RelayManager::at_for_test(NOW)
            .publish_location_event(&signed_at(NOW, "fresh"), &[relay.url().to_string()])
            .await;
        assert!(
            matches!(
                fresh,
                Err(RelayError::DeviceClockRejected {
                    complaint: clock_skew::DeviceClockComplaint::Behind,
                })
            ),
            "a fresh event refused as too old is no longer a clock rejection: {fresh:?}",
        );
    }

    use crate::test_log::capture_log_lines;

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

    // ---- the profile offer and the per-relay read bound ----------------------

    /// A relay that was free a moment ago and now refuses every connection.
    async fn dead_relay_for_offer() -> String {
        format!("ws://127.0.0.1:{}", ephemeral_port().await)
    }

    /// The live relay's admission signal: the id of each event it is offered,
    /// so a test can wait for the offer to ARRIVE rather than for time to pass.
    /// It fires as the relay judges the event, before the relay records it, so
    /// a test reads the id it carries rather than racing `published()`.
    fn admissions_of(relay: &ScriptedRelay) -> tokio::sync::mpsc::UnboundedReceiver<EventId> {
        let (admitted, admissions) = tokio::sync::mpsc::unbounded_channel::<EventId>();
        relay.on_publish(move |event| {
            let _ = admitted.send(event.id);
            Verdict::Keep
        });
        admissions
    }

    /// The old shape connected EVERY relay before it sent to any, so one relay
    /// whose handshake never ends held back the whole offer. With the connect
    /// bound at an hour, that shape cannot deliver to the live relay inside the
    /// 60 s wait; one that sends each relay the moment its own connect succeeds
    /// delivers at once. The wait is a bound the outcome does not depend on.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_profile_offer_reaches_a_live_relay_while_another_relays_handshake_hangs() {
        let _ = allow_ws_loopback_for_test();
        let live = ScriptedRelay::start();
        let mut admissions = admissions_of(&live);
        let urls =
            RelayManager::validate_relay_urls(&[live.url().to_string(), hung_relay_url().await])
                .expect("ws:// loopback urls validate with the opt-in installed");
        let manager = RelayManager::new();
        RelayManager::register_publish_relays(&manager.client, &urls).await;
        let event = throwaway_note("offered past a hung handshake");

        let offering = RelayManager::offer_harvest(
            &manager.client,
            &urls,
            &event,
            Duration::from_hours(1),
            PROFILE_PUBLISH_ACK_TIMEOUT,
        );
        tokio::pin!(offering);
        let delivered = tokio::time::timeout(Duration::from_mins(1), async {
            tokio::select! {
                _ = &mut offering => None,
                got = admissions.recv() => got,
            }
        })
        .await;

        assert_eq!(
            delivered.ok().flatten(),
            Some(event.id),
            "the live relay was not offered the event while the other relay's handshake hung"
        );
        assert_eq!(live.offers(), 1);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_profile_offer_never_sends_to_a_relay_it_could_not_connect() {
        let live = ScriptedRelay::start();
        let dead = dead_relay_for_offer().await;
        let relays = vec![live.url().to_string(), dead];
        let expected = RelayManager::validate_relay_urls(&relays).expect("valid urls");
        let event = throwaway_note("never sent to a dead relay");

        let result = RelayManager::new()
            .offer_profile_event(&event, &relays)
            .await
            .expect("an offer is always a harvest");

        assert_eq!(result.event_id, event.id);
        assert_eq!(result.accepted_by, vec![expected[0].to_string()]);
        // A send into a socket that never opened would have been a refusal.
        // Not connected means not sent, which is silence.
        assert_eq!(result.failed, vec![expected[1].to_string()]);
        assert!(result.rejected_by.is_empty(), "{result:?}");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_profile_offer_is_one_attempt_and_reports_every_relay() {
        let keeping = ScriptedRelay::start();
        let refusing = ScriptedRelay::start();
        refusing.on_publish(|_| Verdict::Refuse("blocked: not here".to_string()));
        let relays = vec![
            keeping.url().to_string(),
            refusing.url().to_string(),
            dead_relay_for_offer().await,
        ];
        let expected = RelayManager::validate_relay_urls(&relays).expect("valid urls");

        let result = RelayManager::new()
            .offer_profile_event(&throwaway_note("one attempt"), &relays)
            .await
            .expect("an offer is always a harvest");

        assert_eq!(result.accepted_by, vec![expected[0].to_string()]);
        assert_eq!(result.rejected_by.len(), 1, "{result:?}");
        assert_eq!(result.rejected_by[0].0, expected[1].to_string());
        assert_eq!(result.failed, vec![expected[2].to_string()]);
        assert_eq!((keeping.offers(), refusing.offers()), (1, 1));

        // Even when nobody accepts, the offer is a harvest and not an error,
        // and a refusal is not asked again in the call: the persisted ladder
        // owns every retry.
        let alone = ScriptedRelay::start();
        alone.on_publish(|_| Verdict::Refuse("blocked: not here".to_string()));
        let refused = RelayManager::new()
            .offer_profile_event(&throwaway_note("refused once"), &[alone.url().to_string()])
            .await
            .expect("a refusal is a bucket");
        assert!(refused.accepted_by.is_empty() && refused.rejected_by.len() == 1);
        assert_eq!(alone.offers(), 1, "an offer is not retried within the call");
    }

    /// Every bucket of the harvest is non-empty, so a line that printed any of
    /// them instead of counting them leaks here: one relay refuses with prose
    /// that quotes a URL, one accepts, and nothing listens on the third port.
    #[tokio::test]
    async fn a_profile_offer_logs_counts_only() {
        let _ = allow_ws_loopback_for_test();
        let (_refuser, refused_url, _seen) =
            refusing_relay("blocked because wss://leak.example said so").await;
        let accepting = LocalRelay::new(RelayBuilder::default());
        accepting.run().await.expect("local relay runs");
        let relays = vec![
            refused_url,
            accepting.url().await.to_string(),
            format!("ws://127.0.0.1:{}", ephemeral_port().await),
        ];
        let event = throwaway_note("who is listening");

        let manager = RelayManager::new();
        let lines = capture_log_lines(async {
            let result = manager
                .offer_profile_event(&event, &relays)
                .await
                .expect("an offer is always a harvest");
            assert!(result.is_success(), "one relay accepted: {result:?}");
        })
        .await;

        assert!(
            lines
                .iter()
                .any(|line| line.starts_with("[RelayManager] offer_profile_event:")),
            "the offer path has to have spoken for its silence to mean anything: {lines:?}",
        );
        assert!(
            lines
                .iter()
                .any(|line| line.starts_with("[RelayManager] publish harvest:")),
            "the harvest summary is the line most likely to grow a url: {lines:?}",
        );
        let event_id = event.id.to_hex();
        for line in &lines {
            for needle in [
                "ws://",
                "wss://",
                "127.0.0.1",
                "leak.example",
                event_id.as_str(),
            ] {
                assert!(
                    !line.contains(needle),
                    "a profile offer named `{needle}` in its log: {line}"
                );
            }
            assert!(
                !line.contains(&event_id[..8]),
                "a profile offer logged an event id prefix: {line}"
            );
        }
    }

    /// A relay holding its answer can never end it, so the only thing that can
    /// stop the read is its own bound. With the bound at zero that is
    /// immediate, and nothing about the outcome depends on time passing.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_per_relay_read_ends_at_its_own_req_bound() {
        let (_never_opened, held) = tokio::sync::watch::channel(false);
        let holding = ScriptedRelay::start();
        holding.answer(
            |_| true,
            vec![crate::relay::scripted_relay::Frame::Hold(held)],
        );
        let answering = ScriptedRelay::start();
        let filter = Filter::new().kind(Kind::TextNote);
        let manager = RelayManager::new();

        let cut = manager
            .fetch_events_per_relay_within(
                filter.clone(),
                &[holding.url().to_string()],
                Duration::ZERO,
            )
            .await
            .expect("a read never fails as a whole");
        assert_eq!(cut.len(), 1);
        assert!(cut[0].responded, "the relay was reached");
        assert!(!cut[0].drained, "a held answer was reported as ended");

        // Anti-vacuity: with room to finish, the same call reports a relay
        // that ends its answer as drained, so the false above is the bound.
        let finished = manager
            .fetch_events_per_relay_within(
                filter,
                &[answering.url().to_string()],
                Duration::from_mins(1),
            )
            .await
            .expect("a read never fails as a whole");
        assert!(finished[0].responded && finished[0].drained);
    }

    /// Five relays each hold their `REQ` behind a gate, with the read's bound
    /// at an hour so nothing can end it early: all five must be asked before
    /// any is released. A read that kept fewer in flight could only reach the
    /// last ones by waiting out the bound.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn fetch_events_per_relay_within_asks_every_relay_at_once() {
        let (open, gate) = tokio::sync::watch::channel(false);
        let (asked_tx, mut asked_rx) = tokio::sync::mpsc::unbounded_channel::<usize>();
        let relays: Vec<ScriptedRelay> = (0..5)
            .map(|i| {
                let relay = ScriptedRelay::start();
                let asked_tx = asked_tx.clone();
                relay.answer(
                    move |_| {
                        let _ = asked_tx.send(i);
                        true
                    },
                    vec![
                        crate::relay::scripted_relay::Frame::Hold(gate.clone()),
                        crate::relay::scripted_relay::Frame::Eose,
                    ],
                );
                relay
            })
            .collect();
        let urls: Vec<String> = relays.iter().map(|r| r.url().to_string()).collect();

        let manager = RelayManager::new();
        let fetching = manager.fetch_events_per_relay_within(
            Filter::new().kind(Kind::TextNote),
            &urls,
            Duration::from_hours(1),
        );
        tokio::pin!(fetching);
        let mut asked = HashSet::new();
        let all_asked = tokio::time::timeout(Duration::from_mins(1), async {
            while asked.len() < urls.len() {
                tokio::select! {
                    _ = &mut fetching => return false,
                    got = asked_rx.recv() => match got {
                        Some(i) => { asked.insert(i); }
                        None => return false,
                    },
                }
            }
            true
        })
        .await;
        assert!(
            matches!(all_asked, Ok(true)),
            "only {} of 5 relays were asked while the others were held",
            asked.len(),
        );

        open.send(true).expect("release the relays");
        let outcomes = tokio::time::timeout(Duration::from_mins(1), fetching)
            .await
            .expect("released relays end their answers")
            .expect("a read never fails as a whole");
        assert_eq!(outcomes.len(), urls.len());
        assert!(outcomes.iter().all(|o| o.responded && o.drained));
    }

    #[test]
    fn the_own_read_bound_is_the_relay_layers_connect_bound_plus_one_author_fetch() {
        assert_eq!(
            crate::profile::config::PROFILE_OWN_READ_BOUND,
            CONNECTION_TIMEOUT + crate::profile::PROFILE_AUTHOR_FETCH_TIMEOUT,
            "the soak oracle's bound for an own-profile read drifted from the dial it waits on"
        );
    }
}
