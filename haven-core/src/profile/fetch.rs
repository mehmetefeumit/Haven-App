//! Per-author, per-relay fetch of public kind-0 metadata.
//!
//! [`fetch_profiles_assigned`] resolves *other* users' public profiles from the
//! profile relay pool. It is deliberately **not** a standing subscription: each
//! call issues a small number of one-shot `REQ`s and returns.
//!
//! # One author per `REQ`, one relay per author
//!
//! The predecessor of this module put the union of every known member pubkey
//! into one filter's `authors` array and broadcast it to the whole relay set,
//! handing each of those relays a k-clique of the user's social graph in a
//! single request — the same disclosure Haven refuses to make as a kind-3
//! contact list. Instead, every author is requested ALONE, from the ONE relay
//! that [`assigned_relay_for_attempt`] pins it to, so no relay ever observes a
//! co-membership set. A relay only ever sees the install-specific ~`1/N` slice
//! of the blended cross-circle union that hashes to it; see
//! [`crate::profile::assignment`] for what that does and does NOT guarantee.
//!
//! # Why the schedule matters as much as the filter
//!
//! Splitting a roster into single-author `REQ`s is worthless if all of them
//! arrive on one socket in one burst: the burst itself is a fingerprint, and
//! its arrival order leaks roster ordering (and therefore new-member arrival).
//! So a cycle fans out ACROSS relays and stays SERIAL within a relay, shuffles
//! the author order within each relay every cycle from the OS CSPRNG, and
//! sleeps a CSPRNG-sampled [`PROFILE_INTER_REQ_JITTER_MS`] between consecutive
//! requests to the same relay.
//!
//! # A relay that does not answer is not a miss
//!
//! Only a relay's own `EOSE` says "I hold nothing for this author". A failed
//! connect, a `CLOSED`, or a `REQ` that outlives its timeout says nothing about
//! the author, so it must not advance that author's retry ladder: a device
//! that is offline would otherwise walk every unresolved member to the last
//! backoff rung with no relay ever having said no. Such an author is asked
//! once more in the same cycle, at the OTHER relay it may be disclosed to
//! ([`PROFILE_MAX_RELAY_RANK`][crate::profile::assignment::PROFILE_MAX_RELAY_RANK]
//! bounds the two), and is reported *unattempted* — nothing stamped — when
//! that one does not answer either.
//!
//! # Fail-closed
//!
//! An empty request set OR an empty pool returns an empty [`AssignedFetch`] —
//! the fetch path never falls back to some other relay. Pool underflow is
//! resolved (and fails closed, terminally) upstream in
//! [`crate::profile::relay_pool::resolve_profile_pool`]; by the time a pool
//! reaches this module it is already known-usable.
//!
//! # `author`, never `#p`
//!
//! The filter uses [`Filter::author`] (the event *author* field), NEVER
//! [`Filter::pubkey`] (the `#p` recipient tag). Getting this wrong would
//! query for events *addressed to* the pubkey rather than *authored by* it —
//! the exact gotcha called out in `CLAUDE.md`. A unit test pins the built
//! filter's JSON shape (a one-element `authors` array + `kinds:[0]`, no `#p`).
//!
//! # No NIP-42 AUTH
//!
//! The [`RelayManager`] is constructed by the caller via [`RelayManager::new`],
//! whose client is built with no signer, so a relay's NIP-42 AUTH challenge can
//! never be satisfied on this path — the fetch cannot be attributed to the
//! local user's identity. There is no AUTH-enabling knob here; an
//! AUTH-requiring relay simply yields no events (proven by an integration
//! test).
//!
//! # One manager, many relays
//!
//! Every `REQ` in a cycle rides ONE [`RelayManager`].
//! [`RelayManager::fetch_events`] takes an explicit relay slice and its
//! `add_relays_and_connect` is idempotent, so `M` requests to a relay cost one
//! handshake. Constructing a manager per relay would buy nothing — same
//! process, same IP — while paying `N` handshakes.

use std::collections::HashSet;
use std::sync::{Mutex, PoisonError};
use std::time::Duration;

use futures::stream::{self, StreamExt};
use nostr::{Event, Filter, Kind, PublicKey};
use rand::rngs::OsRng;
use rand::seq::SliceRandom;
use rand::Rng;

use super::assignment::{assigned_relay_for_attempt, ProfileRelaySalt};
use super::config::{
    PROFILE_AUTHOR_FETCH_TIMEOUT, PROFILE_BATCH_DEADLINE, PROFILE_INTER_REQ_JITTER_MS,
    PROFILE_MAX_INFLIGHT_RELAYS, PROFILE_PER_AUTHOR_LIMIT,
};
use super::error::Result;
use super::parse::parse_newest_metadata;
use super::types::{CachedProfile, ProfileState};
use crate::relay::RelayManager;

/// Outcome of one assigned-fetch cycle, partitioned by what the caller must do
/// next.
///
/// The three buckets are disjoint and, together, cover every de-duplicated
/// author in the request set.
#[derive(Debug, Default)]
pub struct AssignedFetch {
    /// Authors that resolved to a valid kind-0.
    pub resolved: Vec<CachedProfile>,
    /// Authors a relay ended its answer for (`EOSE`) without a kind-0.
    pub missed: Vec<PublicKey>,
    /// Authors no relay answered for (deadline hit, no relay in rank, or
    /// neither of their two relays answered). The caller MUST NOT stamp these
    /// as attempted — they retry next tick.
    pub unattempted: Vec<PublicKey>,
}

/// Fetches the newest public kind-0 metadata for each requested author.
///
/// Each entry of `requests` is `(author, attempt)`, where `attempt` is that
/// author's consecutive-miss count. It selects the rung of the retry ladder in
/// [`assigned_relay_for_attempt`], which is hard-capped at
/// [`PROFILE_MAX_RELAY_RANK`][crate::profile::assignment::PROFILE_MAX_RELAY_RANK]
/// so an author whose kind-0 does not exist anywhere is never walked across
/// the whole pool.
///
/// `now` is the Unix-seconds timestamp stamped into `fetched_at` (injected so
/// tests are deterministic — mirrors the avatar ingest clock pattern).
///
/// Authors are returned in exactly one of the three [`AssignedFetch`] buckets;
/// the `missed` / `unattempted` split is load-bearing, because only `missed`
/// may advance an author's attempt counter and its backoff.
///
/// # Errors
///
/// Returns [`Ok`] with an empty [`AssignedFetch`] when `requests` or `pool` is
/// empty (fail-closed — never a fallback relay). Per-relay failures are
/// absorbed into the `missed` / `unattempted` buckets rather than aborting the
/// cycle, so one unreachable relay cannot deny the other slices; the
/// [`Result`] is retained because the fail-closed contract and the caller's
/// error handling both live on this boundary.
pub async fn fetch_profiles_assigned(
    relay: &RelayManager,
    requests: &[(PublicKey, u8)],
    salt: &ProfileRelaySalt,
    pool: &[String],
    now: i64,
) -> Result<AssignedFetch> {
    // Fail-closed: nothing to ask, or nowhere safe to ask ⇒ resolve nothing.
    if requests.is_empty() || pool.is_empty() {
        return Ok(AssignedFetch::default());
    }
    Ok(run_cycle(relay, requests, salt, pool, now, PROFILE_BATCH_DEADLINE).await)
}

/// One pool relay's answer to the own-profile `REQ`.
///
/// No `Debug`: raw relay events and a relay URL (Security Rule 15).
pub struct OwnRelayRead {
    /// The relay, as [`RelayManager::fetch_events_per_relay`] reports it.
    pub relay_url: String,
    /// Every event it served, including those sent before a missed `EOSE`:
    /// presence needs no `EOSE`, only absence does.
    pub served: Vec<Event>,
    /// Whether it ended its answer with `EOSE`.
    pub drained: bool,
}

/// Reads the local user's OWN kind-0 from EVERY relay in `pool` at once.
///
/// One entry per relay, in pool order, each relay bounded by its own connect
/// and one [`PROFILE_AUTHOR_FETCH_TIMEOUT`] `REQ` (together
/// [`PROFILE_OWN_READ_BOUND`](super::config::PROFILE_OWN_READ_BOUND)).
///
/// # Why the whole pool, not the salted assignment
///
/// The per-author assignment exists so no single relay learns a slice of the
/// user's social graph. Neither half applies to our own profile: it is
/// PUBLISHED to every pool relay (a peer's assignment salt is private to their
/// install, so we cannot know which one they read us from), and every one of
/// those relays therefore already holds it. Reading it back from one assigned
/// relay would only risk merging onto a stale copy and silently dropping fields
/// another client wrote.
///
/// Each relay is asked the way an assigned fetch asks one: one author per
/// `REQ`, a defensive per-author limit, and no signer (so a NIP-42 AUTH
/// challenge can never be answered).
pub async fn read_own_per_relay(
    relay: &RelayManager,
    own_pk: PublicKey,
    pool: &[String],
) -> Vec<OwnRelayRead> {
    relay
        .fetch_events_per_relay_within(
            build_author_filter(&own_pk),
            pool,
            PROFILE_AUTHOR_FETCH_TIMEOUT,
        )
        .await
        .unwrap_or_default()
        .into_iter()
        .map(|outcome| OwnRelayRead {
            relay_url: outcome.relay_url,
            served: outcome.events,
            drained: outcome.drained,
        })
        .collect()
}

/// What the relays of a pool hold of the local user's own kind-0.
pub enum OwnProfileOnRelays {
    /// The newest copy any relay served.
    Published(Box<CachedProfile>),
    /// EVERY relay answered, and none has one.
    Absent,
    /// Anything less: a relay that did not answer may be the one holding it.
    Unverified,
}

/// Reads the local user's own kind-0 from every relay of `pool`
/// ([`read_own_per_relay`]).
///
/// A caller here must tell "never published" from "could not ask" — a storage
/// reset wiped every local sign of a published profile, so a retraction that
/// read silence as absence would leave the profile public while reporting
/// success. The profile was published to the whole pool, but any one relay may
/// have dropped it, so one relay's empty answer proves nothing about the
/// others. Only a relay's own `EOSE` counts as an answer.
pub async fn read_own_profile_on_relays(
    relay: &RelayManager,
    own_pk: PublicKey,
    pool: &[String],
    now: i64,
) -> OwnProfileOnRelays {
    let reads = read_own_per_relay(relay, own_pk, pool).await;
    // Resolved over every relay's events at once, so the newest-wins rule and
    // its lowest-id tie-break run across relays too, and pool order — which
    // relay happens to be listed first — decides nothing.
    let served: Vec<Event> = reads
        .iter()
        .flat_map(|read| read.served.iter().cloned())
        .collect();
    if let Some(profile) = newest_own_copy(&own_pk, &served, now) {
        return OwnProfileOnRelays::Published(Box::new(profile));
    }
    let every_relay_answered = reads.len() == pool.len() && reads.iter().all(|read| read.drained);
    if !pool.is_empty() && every_relay_answered {
        OwnProfileOnRelays::Absent
    } else {
        OwnProfileOnRelays::Unverified
    }
}

/// One relay and the authors assigned to it for this cycle.
#[derive(Debug, Clone, PartialEq, Eq)]
struct RelayBatch {
    /// The assigned relay URL — the only relay these authors are asked of.
    relay: String,
    /// Authors to request, serially, from `relay`.
    authors: Vec<PublicKey>,
}

/// Mutable state shared by the per-relay drivers within one cycle.
///
/// Progress is recorded here as it happens rather than returned from each
/// driver, so that a cycle cancelled by the batch deadline still keeps the
/// profiles it had already resolved. Losing them would force a re-query of
/// authors that were already answered — pointless duplicate traffic to the
/// same relay.
#[derive(Debug, Default)]
struct Cycle {
    /// Authors that produced a usable kind-0.
    resolved: Vec<CachedProfile>,
    /// Authors a relay ended its answer for without a kind-0.
    missed: Vec<PublicKey>,
    /// Every author a relay answered for, in either direction.
    settled: HashSet<PublicKey>,
}

/// Runs one cycle under an injectable `deadline` (tests drive it to zero).
async fn run_cycle(
    relay: &RelayManager,
    requests: &[(PublicKey, u8)],
    salt: &ProfileRelaySalt,
    pool: &[String],
    now: i64,
    deadline: Duration,
) -> AssignedFetch {
    let deduped = dedup_requests(requests);
    let cycle = Mutex::new(Cycle::default());
    let work = async {
        drain_round(relay, &deduped, salt, pool, now, &cycle).await;
        let unanswered = other_relay_requests(&deduped, salt, pool, &cycle);
        drain_round(relay, &unanswered, salt, pool, now, &cycle).await;
    };

    // Authors not yet settled when the deadline fires stay UNSETTLED, and so
    // fall out of `partition_outcome` as `unattempted` — never as `missed`.
    // Stamping a deadline as a miss would advance the retry ladder for a
    // reason that has nothing to do with the author.
    if tokio::time::timeout(deadline, work).await.is_err() {
        log::debug!("[profile] assigned fetch cycle hit its batch deadline");
    }

    partition_outcome(
        &deduped,
        cycle.into_inner().unwrap_or_else(PoisonError::into_inner),
    )
}

/// Asks each of `requests` of the relay its attempt assigns, across relays at
/// once and serially within one.
async fn drain_round(
    relay: &RelayManager,
    requests: &[(PublicKey, u8)],
    salt: &ProfileRelaySalt,
    pool: &[String],
    now: i64,
    cycle: &Mutex<Cycle>,
) {
    let mut batches = group_by_assigned_relay(requests, salt, pool);
    shuffle_batches(&mut batches);
    // The per-relay drivers are materialized with `Iterator::map` and fed to
    // `stream::iter` as futures, rather than created inside a `StreamExt::map`
    // closure. That is load-bearing, not stylistic: a closure returning a
    // future that borrows its argument gets a higher-ranked `FnOnce`
    // obligation rustc cannot generalise, so the resulting cycle future is
    // `Send` only for *some* lifetime. Every caller that needs `Send` for
    // *any* lifetime — i.e. every `flutter_rust_bridge` async FFI method —
    // then fails to compile with "implementation of `FnOnce` is not general
    // enough". Building the futures eagerly is behaviourally identical (an
    // `async fn` body does not run until polled) and keeps the same
    // `buffer_unordered` concurrency cap.
    let drivers: Vec<_> = batches
        .iter()
        .map(|batch| drain_relay_batch(relay, batch, now, cycle))
        .collect();
    stream::iter(drivers)
        .buffer_unordered(PROFILE_MAX_INFLIGHT_RELAYS)
        .for_each(|()| std::future::ready(()))
        .await;
}

/// The authors of `requests` no relay has answered for, each at its OTHER
/// relay: the next attempt, which [`assigned_relay_for_attempt`] wraps over the
/// ranks an author may be disclosed to. An author with no second relay (a
/// one-relay pool) is left out.
fn other_relay_requests(
    requests: &[(PublicKey, u8)],
    salt: &ProfileRelaySalt,
    pool: &[String],
    cycle: &Mutex<Cycle>,
) -> Vec<(PublicKey, u8)> {
    let state = cycle.lock().unwrap_or_else(PoisonError::into_inner);
    requests
        .iter()
        .filter(|(author, _)| !state.settled.contains(author))
        .map(|(author, attempt)| (*author, attempt.wrapping_add(1)))
        .filter(|(author, other)| {
            assigned_relay_for_attempt(salt, author, pool, *other)
                != assigned_relay_for_attempt(salt, author, pool, other.wrapping_sub(1))
        })
        .collect()
}

/// Requests every author of `batch`, serially, from that batch's one relay.
///
/// Serial-within-relay is the property that removes the burst signature; the
/// CSPRNG gap between consecutive requests removes the regular inter-arrival
/// period that would replace it.
async fn drain_relay_batch(
    relay: &RelayManager,
    batch: &RelayBatch,
    now: i64,
    cycle: &Mutex<Cycle>,
) {
    let targets = [batch.relay.clone()];
    for (index, author) in batch.authors.iter().enumerate() {
        if index > 0 {
            tokio::time::sleep(inter_req_delay()).await;
        }

        // One `REQ` to the one relay, read off that relay's own stream so its
        // `EOSE` is seen: the pooled fetch folds a failed connect, a `CLOSED`
        // and a timeout into the same empty page as "holds nothing".
        let answer = relay
            .fetch_events_per_relay_within(
                build_author_filter(author),
                &targets,
                PROFILE_AUTHOR_FETCH_TIMEOUT,
            )
            .await
            .unwrap_or_default()
            .pop();
        let (events, drained) = answer.map_or((Vec::new(), false), |a| (a.events, a.drained));

        let resolved = newest_own_copy(author, &events, now);
        // Presence needs no `EOSE`; absence does. A relay that did not answer
        // this author is not asked for the rest of its slice either — the same
        // condition would recur, each at the cost of a full timeout.
        if resolved.is_none() && !drained {
            log::debug!("[profile] assigned relay did not answer; leaving its slice unanswered");
            break;
        }
        let mut state = cycle.lock().unwrap_or_else(PoisonError::into_inner);
        state.settled.insert(*author);
        match resolved {
            Some(profile) => state.resolved.push(profile),
            None => state.missed.push(*author),
        }
    }
}

/// De-duplicates `requests` by author, preserving first-seen order.
///
/// The union across circles can repeat a pubkey (a member of two circles).
/// Collapsing duplicates keeps a single author from being asked for twice in
/// one cycle — which would double the traffic its assigned relay sees for no
/// benefit. On a conflicting attempt count the FIRST wins, so a stale higher
/// attempt can never promote an author onto its second relay.
fn dedup_requests(requests: &[(PublicKey, u8)]) -> Vec<(PublicKey, u8)> {
    let mut seen: HashSet<PublicKey> = HashSet::with_capacity(requests.len());
    let mut out = Vec::with_capacity(requests.len());
    for (author, attempt) in requests {
        if seen.insert(*author) {
            out.push((*author, *attempt));
        }
    }
    out
}

/// Groups `requests` by the relay each author is assigned to.
///
/// Pure and deterministic: the returned batches depend only on
/// `(salt, author, attempt, pool)`. An author whose rank resolves to nothing
/// (an empty pool) is simply omitted — it never reaches a `REQ` and so falls
/// out as `unattempted`.
fn group_by_assigned_relay(
    requests: &[(PublicKey, u8)],
    salt: &ProfileRelaySalt,
    pool: &[String],
) -> Vec<RelayBatch> {
    // Linear scan rather than a map: the pool is a handful of relays, and a
    // `Vec` keeps the batch order deterministic for tests (the shuffle that
    // follows is where unpredictability is introduced, deliberately).
    let mut batches: Vec<RelayBatch> = Vec::new();
    for (author, attempt) in requests {
        let Some(relay) = assigned_relay_for_attempt(salt, author, pool, *attempt) else {
            continue;
        };
        if let Some(batch) = batches.iter_mut().find(|b| b.relay == relay) {
            batch.authors.push(*author);
        } else {
            batches.push(RelayBatch {
                relay,
                authors: vec![*author],
            });
        }
    }
    batches
}

/// Shuffles the relay order and, within each relay, the author order.
///
/// Re-drawn every cycle from the OS CSPRNG. Without it a relay could read
/// roster ordering straight off the `REQ` sequence — and, because a new member
/// would appear at a stable position, spot the moment one is added.
fn shuffle_batches(batches: &mut [RelayBatch]) {
    let mut rng = OsRng;
    batches.shuffle(&mut rng);
    for batch in batches.iter_mut() {
        batch.authors.shuffle(&mut rng);
    }
}

/// Samples the delay between two consecutive `REQ`s on the same relay.
///
/// `OsRng` only (a thin `getrandom` wrapper with no seeded expansion): the gap
/// must be unpredictable to the relay observing it. `clippy.toml` bans
/// `thread_rng`, and the profile privacy guard additionally bans every seeded
/// generator.
fn inter_req_delay() -> Duration {
    let mut rng = OsRng;
    Duration::from_millis(rng.gen_range(PROFILE_INTER_REQ_JITTER_MS))
}

/// Builds the metadata filter for exactly ONE author.
///
/// Uses `author` (singular — the event author field), a `kind:0` constraint,
/// and a defensive [`PROFILE_PER_AUTHOR_LIMIT`] so a non-pruning relay that
/// holds several historical revisions is still bounded. NEVER uses `#p`, and
/// never more than one author: a multi-author filter is a social-graph
/// disclosure and is banned by a CI guard.
fn build_author_filter(author: &PublicKey) -> Filter {
    Filter::new()
        .author(*author)
        .kind(Kind::Metadata)
        .limit(PROFILE_PER_AUTHOR_LIMIT)
}

/// Reduces one author's `REQ` result to a cache row, or [`None`] on a miss —
/// for the own profile's reads and for each author of an assigned fetch.
///
/// [`parse_newest_metadata`] ignores events whose `pubkey` is not `author`, so
/// a relay that answers with somebody else's kind-0 cannot inject a row. A
/// [`ProfileState::Unknown`] outcome returns [`None`] rather than a blank row,
/// so a fetched-but-empty row can never mask a genuine miss.
pub(crate) fn newest_own_copy(
    author: &PublicKey,
    events: &[Event],
    now: i64,
) -> Option<CachedProfile> {
    let (state, metadata, event_created_at) = parse_newest_metadata(events, author);
    (state == ProfileState::Known).then(|| CachedProfile {
        pubkey_hex: author.to_hex(),
        metadata,
        state,
        event_created_at,
        fetched_at: now,
    })
}

/// Splits the cycle's recorded progress into the three caller-facing buckets.
///
/// Anything the cycle did not settle — never scheduled, dropped at the
/// deadline, or abandoned with its relay — is `unattempted`, in the caller's
/// original request order.
fn partition_outcome(requests: &[(PublicKey, u8)], cycle: Cycle) -> AssignedFetch {
    let unattempted = requests
        .iter()
        .map(|(author, _)| *author)
        .filter(|author| !cycle.settled.contains(author))
        .collect();
    AssignedFetch {
        resolved: cycle.resolved,
        missed: cycle.missed,
        unattempted,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::{EventBuilder, JsonUtil, Keys, Timestamp};

    fn keys_n(n: usize) -> Vec<Keys> {
        (0..n).map(|_| Keys::generate()).collect()
    }

    fn authors_n(n: usize) -> Vec<PublicKey> {
        keys_n(n).iter().map(Keys::public_key).collect()
    }

    /// Whether the own kind-0 is on the relays of `pool`: `Some(true)` when
    /// any relay serves it, `Some(false)` only when EVERY relay answered
    /// without it, `None` otherwise.
    async fn own_profile_on_relays(
        relay: &RelayManager,
        own_pk: PublicKey,
        pool: &[String],
        now: i64,
    ) -> Option<bool> {
        match read_own_profile_on_relays(relay, own_pk, pool, now).await {
            OwnProfileOnRelays::Published(_) => Some(true),
            OwnProfileOnRelays::Absent => Some(false),
            OwnProfileOnRelays::Unverified => None,
        }
    }

    /// Fixed salt — assignment must never depend on a random draw in a test,
    /// or a failure would be irreproducible.
    fn salt() -> ProfileRelaySalt {
        ProfileRelaySalt::from_bytes([0xAA; 32])
    }

    fn pool(n: usize) -> Vec<String> {
        (0..n).map(|i| format!("wss://relay{i}.example")).collect()
    }

    /// A pool of hosts under the reserved `.invalid` TLD: guaranteed never to
    /// resolve, so a unit test can drive the scheduling paths without any
    /// chance of touching a real relay.
    fn unreachable_pool() -> Vec<String> {
        (0..3)
            .map(|i| format!("wss://relay{i}.batch-deadline.invalid"))
            .collect()
    }

    fn kind0(keys: &Keys, content: &str, created_at: u64) -> Event {
        EventBuilder::new(Kind::Metadata, content)
            .custom_created_at(Timestamp::from(created_at))
            .sign_with_keys(keys)
            .expect("sign kind0")
    }

    /// A relay-side policy that answers EVERY `REQ` with a rate-limit `CLOSED`.
    ///
    /// Counts the requests it saw, so the test that uses it can prove the
    /// `REQ` really reached the relay. Without that counter the test would
    /// pass just as happily on a failed connection — which also produces a
    /// miss — and would therefore assert nothing.
    #[derive(Debug)]
    struct RateLimitEveryQuery {
        seen: std::sync::Arc<std::sync::atomic::AtomicUsize>,
    }

    impl nostr_relay_builder::prelude::QueryPolicy for RateLimitEveryQuery {
        fn admit_query<'a>(
            &'a self,
            _query: &'a Filter,
            _addr: &'a std::net::SocketAddr,
        ) -> nostr::util::BoxedFuture<'a, nostr_relay_builder::prelude::PolicyResult> {
            self.seen.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Box::pin(async {
                nostr_relay_builder::prelude::PolicyResult::Reject(
                    "rate-limited: slow down".to_string(),
                )
            })
        }
    }

    /// Admits every `REQ` and counts it, relay-side, at admission.
    ///
    /// Counting before the filter is evaluated is what lets a zero mean *never
    /// asked*: a test that inspected returned events could not tell that from
    /// "asked and had nothing".
    #[derive(Debug)]
    struct CountEveryQuery {
        seen: std::sync::Arc<std::sync::atomic::AtomicUsize>,
    }

    impl nostr_relay_builder::prelude::QueryPolicy for CountEveryQuery {
        fn admit_query<'a>(
            &'a self,
            _query: &'a Filter,
            _addr: &'a std::net::SocketAddr,
        ) -> nostr::util::BoxedFuture<'a, nostr_relay_builder::prelude::PolicyResult> {
            self.seen.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Box::pin(async { nostr_relay_builder::prelude::PolicyResult::Accept })
        }
    }

    /// Starts an in-process relay counting the `REQ`s it is asked to serve.
    /// The returned relay MUST be kept alive for the whole test.
    async fn counting_relay() -> (
        nostr_relay_builder::prelude::LocalRelay,
        String,
        std::sync::Arc<std::sync::atomic::AtomicUsize>,
    ) {
        let seen = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let relay = nostr_relay_builder::prelude::LocalRelay::new(
            nostr_relay_builder::prelude::RelayBuilder::default().query_policy(CountEveryQuery {
                seen: std::sync::Arc::clone(&seen),
            }),
        );
        relay.run().await.expect("local relay runs");
        let url = relay.url().await.to_string();
        (relay, url, seen)
    }

    /// A loopback URL that refuses every connection: reserve an ephemeral port,
    /// then drop the listener. Refusal is instant and deterministic — no sleep,
    /// no race.
    fn dead_relay_url() -> String {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind ephemeral port");
        let port = listener.local_addr().expect("local addr").port();
        drop(listener);
        format!("ws://127.0.0.1:{port}")
    }

    fn filter_json(author: &PublicKey) -> serde_json::Value {
        serde_json::from_str(&build_author_filter(author).as_json()).expect("filter is valid JSON")
    }

    #[test]
    fn filter_has_exactly_one_author() {
        // THE invariant of this module: a k-author filter hands one relay a
        // k-clique of the user's social graph in a single REQ.
        let json = filter_json(&authors_n(1)[0]);
        let authors = json
            .get("authors")
            .and_then(serde_json::Value::as_array)
            .expect("filter must carry an authors array");
        assert_eq!(
            authors.len(),
            1,
            "exactly one author per REQ, got {authors:?}",
        );
    }

    #[test]
    fn filter_is_kind0_and_carries_no_pubkey_tag() {
        // Pins the `CLAUDE.md` #p gotcha: the filter must key on the event
        // AUTHOR, never the `#p` recipient tag (which filters recipients).
        let author = authors_n(1)[0];
        let json = filter_json(&author);
        assert_eq!(
            json.get("kinds").and_then(serde_json::Value::as_array),
            Some(&vec![serde_json::json!(0)]),
            "must be kind:0 only: {json}",
        );
        assert!(
            json.get("#p").is_none(),
            "must NOT carry a #p pubkey tag (that filters recipients, not authors): {json}",
        );
        assert_eq!(
            json["authors"][0].as_str(),
            Some(author.to_hex().as_str()),
            "the requested author must be the filter's author",
        );
    }

    #[test]
    fn filter_has_defensive_limit() {
        // A missing limit lets a non-pruning relay return every historical
        // revision it holds for the pubkey.
        let json = filter_json(&authors_n(1)[0]);
        assert_eq!(
            json.get("limit").and_then(serde_json::Value::as_u64),
            Some(PROFILE_PER_AUTHOR_LIMIT as u64),
            "defensive per-author limit expected: {json}",
        );
    }

    #[test]
    fn each_author_maps_to_its_assigned_relay_only() {
        // No author may be requested from a relay other than the one its
        // salted rendezvous rank pins it to — that is what bounds per-author
        // disclosure. Checked AFTER the shuffle, since the shuffle is what
        // runs in production.
        let relays = pool(8);
        let salt = salt();
        let requests: Vec<(PublicKey, u8)> = authors_n(40)
            .into_iter()
            .enumerate()
            .map(|(i, author)| (author, u8::try_from(i % 2).expect("0 or 1")))
            .collect();
        let attempt_of: std::collections::HashMap<PublicKey, u8> =
            requests.iter().copied().collect();

        let mut batches = group_by_assigned_relay(&requests, &salt, &relays);
        shuffle_batches(&mut batches);

        let mut seen = 0usize;
        for batch in &batches {
            for author in &batch.authors {
                let attempt = attempt_of[author];
                assert_eq!(
                    assigned_relay_for_attempt(&salt, author, &relays, attempt).as_ref(),
                    Some(&batch.relay),
                    "author scheduled on a relay it is not assigned to",
                );
                seen += 1;
            }
        }
        assert_eq!(seen, requests.len(), "every request must be scheduled once");

        let unique_relays: HashSet<&String> = batches.iter().map(|b| &b.relay).collect();
        assert_eq!(
            unique_relays.len(),
            batches.len(),
            "a relay must appear in at most one batch, or it would be queried concurrently with itself",
        );
    }

    #[test]
    fn grouping_skips_authors_with_no_assignable_relay() {
        // An unassignable author must never be silently attached to some other
        // relay's batch; it is dropped here and reported unattempted.
        let batches = group_by_assigned_relay(&[(authors_n(1)[0], 0)], &salt(), &[]);
        assert!(batches.is_empty());
    }

    #[tokio::test]
    async fn batch_deadline_leaves_authors_unattempted_not_missed() {
        // A zero budget guarantees the deadline wins the race, and the pool is
        // unresolvable so no REQ could complete anyway. Everything must land
        // in `unattempted`: stamping a deadline as a MISS would advance the
        // retry ladder and disclose every author to a second relay for a
        // reason that has nothing to do with the authors.
        let relay = RelayManager::new();
        let requests: Vec<(PublicKey, u8)> = authors_n(6).into_iter().map(|a| (a, 0)).collect();

        let out = run_cycle(
            &relay,
            &requests,
            &salt(),
            &unreachable_pool(),
            100,
            Duration::ZERO,
        )
        .await;

        assert!(out.resolved.is_empty(), "nothing could have resolved");
        assert!(
            out.missed.is_empty(),
            "deadline-dropped authors must NEVER be reported as missed",
        );
        let unattempted: HashSet<PublicKey> = out.unattempted.iter().copied().collect();
        for (author, _) in &requests {
            assert!(
                unattempted.contains(author),
                "an author dropped at the deadline must be reported unattempted",
            );
        }
    }

    #[test]
    fn unsettled_authors_are_reported_unattempted_never_missed() {
        // The pure half of the deadline contract: whatever the cycle did not
        // settle is unattempted, in the caller's original order, and the
        // `missed` bucket carries only what a completed REQ actually produced.
        let authors = authors_n(4);
        let requests: Vec<(PublicKey, u8)> = authors.iter().map(|a| (*a, 0)).collect();
        let mut cycle = Cycle::default();
        cycle.settled.insert(authors[1]);
        cycle.missed.push(authors[1]);

        let out = partition_outcome(&requests, cycle);
        assert_eq!(out.missed, vec![authors[1]]);
        assert_eq!(
            out.unattempted,
            vec![authors[0], authors[2], authors[3]],
            "unsettled authors, in request order",
        );
    }

    /// An author whose first relay is `first` and whose other relay is
    /// `other`, under the fixed test salt. The ranking is a salted hash, so
    /// this is a bounded search, and the caller's assertions re-prove it.
    fn author_ranked(pool: &[String], first: &str, other: &str) -> Keys {
        loop {
            let keys = Keys::generate();
            let rank =
                |attempt| assigned_relay_for_attempt(&salt(), &keys.public_key(), pool, attempt);
            if rank(0).as_deref() == Some(first) && rank(1).as_deref() == Some(other) {
                return keys;
            }
        }
    }

    /// Starts an in-process relay that answers every `REQ` with a rate-limit
    /// `CLOSED`, counting the requests it saw.
    async fn closing_relay() -> (
        nostr_relay_builder::prelude::LocalRelay,
        String,
        std::sync::Arc<std::sync::atomic::AtomicUsize>,
    ) {
        let seen = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let relay = nostr_relay_builder::prelude::LocalRelay::new(
            nostr_relay_builder::prelude::RelayBuilder::default().query_policy(
                RateLimitEveryQuery {
                    seen: std::sync::Arc::clone(&seen),
                },
            ),
        );
        relay.run().await.expect("local relay runs");
        let url = relay.url().await.to_string();
        (relay, url, seen)
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_relay_that_closes_the_req_has_not_answered_and_stamps_nothing() {
        // `CLOSED <sub> "rate-limited: ..."` is the relay declining to answer,
        // not the relay saying it holds nothing. Reported as a miss it would
        // advance the author's backoff on the word of a relay that never
        // looked. Proven against a real socket, and with the request counted,
        // so a failed connection cannot stand in for the `CLOSED`.
        let _ = crate::relay::allow_ws_loopback_for_test();
        let (_server, url, seen) = closing_relay().await;

        let relay = RelayManager::new();
        let author = authors_n(1)[0];
        let out = fetch_profiles_assigned(&relay, &[(author, 0)], &salt(), &[url], 100)
            .await
            .expect("a rate-limit CLOSED must not surface as an error");

        assert_eq!(
            seen.load(std::sync::atomic::Ordering::SeqCst),
            1,
            "a one-relay pool has no other relay to ask, and the same one is not asked twice",
        );
        assert!(out.resolved.is_empty());
        assert!(
            out.missed.is_empty(),
            "a relay that closed the REQ never said it holds nothing",
        );
        assert_eq!(out.unattempted, vec![author]);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_author_whose_relay_does_not_answer_resolves_from_its_other_relay() {
        // The same cycle, not the next trigger: a relay that is down or
        // shedding load must not cost a member their name until a later miss
        // walks the ladder — and the third relay must never hear of them.
        let _ = crate::relay::allow_ws_loopback_for_test();
        let (_closing, closing_url, closing_seen) = closing_relay().await;
        let (_holder, holder_url, holder_seen) = counting_relay().await;
        let (_bystander, bystander_url, bystander_seen) = counting_relay().await;
        let pool = vec![closing_url.clone(), holder_url.clone(), bystander_url];
        let keys = author_ranked(&pool, &closing_url, &holder_url);

        let relay = RelayManager::new();
        seed(
            &relay,
            &kind0(&keys, r#"{"name":"Found"}"#, 10),
            &holder_url,
        )
        .await;

        let out = fetch_profiles_assigned(&relay, &[(keys.public_key(), 0)], &salt(), &pool, 100)
            .await
            .expect("cycle runs");

        let count =
            |seen: &std::sync::atomic::AtomicUsize| seen.load(std::sync::atomic::Ordering::SeqCst);
        assert_eq!(
            count(&closing_seen),
            1,
            "the assigned relay was asked first"
        );
        assert_eq!(
            count(&holder_seen),
            1,
            "then the author's other relay, once"
        );
        assert_eq!(
            count(&bystander_seen),
            0,
            "an author is disclosed to two relays at most",
        );
        assert_eq!(out.resolved.len(), 1);
        assert_eq!(out.resolved[0].metadata.name(), Some("Found"));
        assert!(out.missed.is_empty() && out.unattempted.is_empty());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_relay_that_ends_its_answer_without_a_kind0_is_a_miss_and_the_other_is_not_asked() {
        // An `EOSE` with nothing is the relay's answer. It advances the ladder
        // to the other relay on the NEXT attempt, behind the backoff; asking
        // it in the same cycle would spend the second disclosure on every
        // author who has simply not published.
        let _ = crate::relay::allow_ws_loopback_for_test();
        let (_first, first_url, first_seen) = counting_relay().await;
        let (_other, other_url, other_seen) = counting_relay().await;
        let pool = vec![first_url.clone(), other_url.clone()];
        let author = author_ranked(&pool, &first_url, &other_url).public_key();

        let relay = RelayManager::new();
        let out = fetch_profiles_assigned(&relay, &[(author, 0)], &salt(), &pool, 100)
            .await
            .expect("cycle runs");

        assert_eq!(first_seen.load(std::sync::atomic::Ordering::SeqCst), 1);
        assert_eq!(other_seen.load(std::sync::atomic::Ordering::SeqCst), 0);
        assert_eq!(out.missed, vec![author]);
        assert!(out.resolved.is_empty() && out.unattempted.is_empty());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_author_neither_relay_answers_for_is_unattempted_not_missed() {
        // Offline is this shape for every author at once. Counted as misses,
        // a few triggers without a network would park every unresolved member
        // on the last backoff rung.
        let _ = crate::relay::allow_ws_loopback_for_test();
        let pool = vec![dead_relay_url(), dead_relay_url(), dead_relay_url()];
        let requests: Vec<(PublicKey, u8)> = authors_n(4).into_iter().map(|a| (a, 0)).collect();

        let relay = RelayManager::new();
        let out = fetch_profiles_assigned(&relay, &requests, &salt(), &pool, 100)
            .await
            .expect("cycle runs");

        assert!(out.resolved.is_empty() && out.missed.is_empty());
        assert_eq!(
            out.unattempted,
            requests.iter().map(|(a, _)| *a).collect::<Vec<_>>(),
        );
    }

    #[tokio::test]
    async fn empty_pool_fails_closed() {
        let relay = RelayManager::new();
        let author = authors_n(1)[0];
        // A non-empty request set with NO pool must resolve nothing and never
        // touch the network (fail-closed; no fallback relay).
        let out = fetch_profiles_assigned(&relay, &[(author, 0)], &salt(), &[], 100)
            .await
            .expect("an empty pool is Ok(empty), never an error");
        assert!(out.resolved.is_empty());
        assert!(
            out.missed.is_empty(),
            "nothing was queried, so nothing missed"
        );
        assert!(out.unattempted.is_empty());
    }

    #[tokio::test]
    async fn empty_requests_returns_empty() {
        let relay = RelayManager::new();
        let out = fetch_profiles_assigned(&relay, &[], &salt(), &pool(4), 100)
            .await
            .expect("an empty request set is Ok");
        assert!(out.resolved.is_empty());
        assert!(out.missed.is_empty());
        assert!(out.unattempted.is_empty());
    }

    #[test]
    fn dedup_collapses_repeats_preserving_order() {
        let a = authors_n(3);
        let out = dedup_requests(&[(a[0], 0), (a[1], 1), (a[0], 1), (a[2], 0), (a[1], 0)]);
        assert_eq!(
            out,
            vec![(a[0], 0), (a[1], 1), (a[2], 0)],
            "first-seen order and first-seen attempt, no repeats",
        );
    }

    #[test]
    fn dedup_keeps_a_repeated_author_off_a_second_relay() {
        // A duplicate entry carrying a HIGHER attempt must not win: that would
        // promote the author onto its rank-2 relay, widening disclosure on the
        // strength of a stale row.
        let relays = pool(8);
        let salt = salt();
        let author = authors_n(1)[0];
        let batches =
            group_by_assigned_relay(&dedup_requests(&[(author, 0), (author, 1)]), &salt, &relays);
        assert_eq!(batches.len(), 1, "one author ⇒ one REQ, never two");
        assert_eq!(
            Some(&batches[0].relay),
            assigned_relay_for_attempt(&salt, &author, &relays, 0).as_ref(),
        );
    }

    #[test]
    fn inter_req_delay_stays_within_the_configured_range() {
        let lo = Duration::from_millis(*PROFILE_INTER_REQ_JITTER_MS.start());
        let hi = Duration::from_millis(*PROFILE_INTER_REQ_JITTER_MS.end());
        let mut distinct = HashSet::new();
        for _ in 0..256 {
            let delay = inter_req_delay();
            assert!((lo..=hi).contains(&delay), "jitter escaped its range");
            distinct.insert(delay);
        }
        assert!(
            distinct.len() > 1,
            "a constant delay is not jitter — the regular inter-arrival period is exactly what it must destroy",
        );
    }

    // ----------------------------------------------------------------------
    // read_own_profile_on_relays — the whole-pool read of our OWN kind-0.
    //
    // Every relay here is in-process or a reserved-but-closed loopback port, so
    // nothing waits on wall-clock luck and no assertion is about elapsed time.
    // ----------------------------------------------------------------------

    /// Publishes `event` to `url` through the ordinary publish transport.
    async fn seed(relay: &RelayManager, event: &Event, url: &str) {
        relay
            .publish_event(event, &[url.to_string()])
            .await
            .expect("the local relay accepts the seeded kind-0");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn own_presence_is_unknown_when_no_relay_answers() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let pool = vec![dead_relay_url(), dead_relay_url()];
        assert_eq!(
            own_profile_on_relays(&RelayManager::new(), authors_n(1)[0], &pool, 100).await,
            None,
            "silence from every relay is not proof that nothing was published",
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn own_presence_is_unknown_while_any_relay_is_unanswered() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let (_live, live_url, _) = counting_relay().await;
        let pool = vec![dead_relay_url(), live_url];
        assert_eq!(
            own_profile_on_relays(&RelayManager::new(), authors_n(1)[0], &pool, 100).await,
            None,
            "one relay's empty answer says nothing about the relay that never answered",
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn own_presence_is_absent_only_when_every_relay_answers_without_it() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let (_a, url_a, _) = counting_relay().await;
        let (_b, url_b, _) = counting_relay().await;
        assert_eq!(
            own_profile_on_relays(&RelayManager::new(), authors_n(1)[0], &[url_a, url_b], 100)
                .await,
            Some(false),
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn own_presence_is_found_past_a_dead_relay() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let (_live, live_url, _) = counting_relay().await;
        let ks = keys_n(1);
        let relay = RelayManager::new();
        seed(
            &relay,
            &kind0(&ks[0], r#"{"name":"public"}"#, 1_000),
            &live_url,
        )
        .await;
        let pool = vec![dead_relay_url(), live_url];
        assert_eq!(
            own_profile_on_relays(&relay, ks[0].public_key(), &pool, 100).await,
            Some(true),
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn own_presence_read_serves_the_newest_copy_across_relays() {
        // The caller caches what this returns; a stale relay's copy winning
        // would hand the user back a name they have since replaced.
        let _ = crate::relay::allow_ws_loopback_for_test();
        let (_stale_relay, stale_url, _) = counting_relay().await;
        let (_fresh_relay, fresh_url, _) = counting_relay().await;
        let ks = keys_n(1);
        let relay = RelayManager::new();
        seed(
            &relay,
            &kind0(&ks[0], r#"{"name":"new"}"#, 2_000),
            &fresh_url,
        )
        .await;
        seed(
            &relay,
            &kind0(&ks[0], r#"{"name":"old"}"#, 1_000),
            &stale_url,
        )
        .await;

        for pool in [
            [stale_url.clone(), fresh_url.clone()],
            [fresh_url, stale_url],
        ] {
            let OwnProfileOnRelays::Published(newest) =
                read_own_profile_on_relays(&relay, ks[0].public_key(), &pool, 7).await
            else {
                panic!("both relays serve a copy");
            };
            assert_eq!(newest.metadata.name(), Some("new"));
            assert_eq!(newest.event_created_at, 2_000);
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn own_presence_read_breaks_a_tie_by_lowest_id_not_pool_order() {
        // Two copies with one `created_at`, each on its own relay: NIP-01 gives
        // the lower id, and which relay is listed first must not change that.
        let _ = crate::relay::allow_ws_loopback_for_test();
        let (_relay_a, url_a, _) = counting_relay().await;
        let (_relay_b, url_b, _) = counting_relay().await;
        let ks = keys_n(1);
        let one = kind0(&ks[0], r#"{"name":"one"}"#, 1_000);
        let two = kind0(&ks[0], r#"{"name":"two"}"#, 1_000);
        let relay = RelayManager::new();
        seed(&relay, &one, &url_a).await;
        seed(&relay, &two, &url_b).await;
        let lowest = if one.id < two.id { "one" } else { "two" };

        for pool in [[url_a.clone(), url_b.clone()], [url_b, url_a]] {
            let OwnProfileOnRelays::Published(winner) =
                read_own_profile_on_relays(&relay, ks[0].public_key(), &pool, 7).await
            else {
                panic!("both relays serve a copy");
            };
            assert_eq!(winner.metadata.name(), Some(lowest));
        }
    }

    #[tokio::test]
    async fn own_presence_is_never_absent_on_an_empty_pool() {
        // No relay was asked, so "every relay answered without it" is vacuous:
        // read as absence, a retraction would report nothing to retract.
        let relay = RelayManager::new();
        let own = authors_n(1)[0];
        assert!(matches!(
            read_own_profile_on_relays(&relay, own, &[], 100).await,
            OwnProfileOnRelays::Unverified
        ));
        assert_eq!(own_profile_on_relays(&relay, own, &[], 100).await, None);
    }

    #[test]
    fn shuffle_preserves_the_scheduled_author_set() {
        // The shuffle may only permute: dropping or duplicating an author here
        // would silently starve a member's profile forever.
        let relays = pool(4);
        let requests: Vec<(PublicKey, u8)> = authors_n(24).into_iter().map(|a| (a, 0)).collect();
        let before = group_by_assigned_relay(&requests, &salt(), &relays);
        let mut after = before.clone();
        shuffle_batches(&mut after);

        let flat = |batches: &[RelayBatch]| -> Vec<(String, PublicKey)> {
            let mut pairs: Vec<(String, PublicKey)> = batches
                .iter()
                .flat_map(|b| b.authors.iter().map(|a| (b.relay.clone(), *a)))
                .collect();
            pairs.sort_by(|l, r| l.0.cmp(&r.0).then_with(|| l.1.to_hex().cmp(&r.1.to_hex())));
            pairs
        };
        assert_eq!(flat(&before), flat(&after));
    }

    // ----------------------------------------------------------------------
    // read_own_per_relay — the per-relay own-profile read the sync pass and
    // the tri-state read are both built on.
    // ----------------------------------------------------------------------

    use crate::profile::outbox::{served_against, Served};
    use crate::relay::scripted_relay::{Frame, ScriptedRelay};

    fn same_relay(a: &str, b: &str) -> bool {
        nostr::RelayUrl::parse(a).expect("a relay url")
            == nostr::RelayUrl::parse(b).expect("a relay url")
    }

    #[test]
    fn newest_own_copy_returns_none_for_an_empty_reply() {
        assert!(newest_own_copy(&authors_n(1)[0], &[], 42).is_none());
    }

    #[test]
    fn newest_own_copy_picks_the_newest_and_stamps_now() {
        let ks = keys_n(1);
        let author = ks[0].public_key();
        let events = vec![
            kind0(&ks[0], r#"{"name":"old"}"#, 1_000),
            kind0(&ks[0], r#"{"name":"new"}"#, 2_000),
        ];
        let row = newest_own_copy(&author, &events, 42).expect("resolved");
        assert_eq!(row.metadata.name(), Some("new"));
        assert_eq!(row.pubkey_hex, author.to_hex());
        assert_eq!(row.state, ProfileState::Known);
        assert_eq!((row.event_created_at, row.fetched_at), (2_000, 42));
    }

    #[test]
    fn newest_own_copy_ignores_another_authors_events() {
        let ks = keys_n(2);
        let events = vec![
            kind0(&ks[0], r#"{"name":"wanted"}"#, 1_000),
            kind0(&ks[1], r#"{"name":"unwanted"}"#, 5_000),
        ];
        let row = newest_own_copy(&ks[0].public_key(), &events, 1).expect("resolved");
        assert_eq!(row.pubkey_hex, ks[0].public_key().to_hex());
        assert_eq!(row.metadata.name(), Some("wanted"));
        assert!(newest_own_copy(&ks[1].public_key(), &events[..1], 1).is_none());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn own_presence_read_asks_every_pool_relay() {
        // Reading our own profile from a SUBSET would merge onto whatever that
        // subset happened to hold. Counted relay-side, because a fetch that
        // never reached a socket would satisfy any event-based assertion
        // vacuously.
        let _ = crate::relay::allow_ws_loopback_for_test();
        let (_a, url_a, seen_a) = counting_relay().await;
        let (_b, url_b, seen_b) = counting_relay().await;
        let (_c, url_c, seen_c) = counting_relay().await;

        let read = read_own_profile_on_relays(
            &RelayManager::new(),
            authors_n(1)[0],
            &[url_a, url_b, url_c],
            100,
        )
        .await;

        assert!(matches!(read, OwnProfileOnRelays::Absent));
        for (label, seen) in [("a", &seen_a), ("b", &seen_b), ("c", &seen_c)] {
            assert!(
                seen.load(std::sync::atomic::Ordering::SeqCst) >= 1,
                "pool relay {label} was never asked for the own profile",
            );
        }
    }

    #[tokio::test]
    async fn own_presence_is_unknown_for_a_relay_that_cannot_be_asked() {
        // A structurally unusable relay yields no answer at all, which is
        // never the absence of a profile.
        let relay = RelayManager::new();
        let own = authors_n(1)[0];
        let pool = ["not-a-relay-url".to_string()];
        assert_eq!(own_profile_on_relays(&relay, own, &pool, 100).await, None);
        let reads = read_own_per_relay(&relay, own, &pool).await;
        assert_eq!(reads.len(), 1, "every relay of the pool is reported");
        assert!(!reads[0].drained && reads[0].served.is_empty());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn own_presence_read_asks_every_pool_relay_at_once() {
        // Five relays each hold their REQ behind a gate. A read that kept four
        // in flight could ask the fifth only once one of them ended, and before
        // the release a held read ends only at its REQ bound, with no EOSE: so
        // every read must come back drained. The waits are bounds, not
        // durations the outcome depends on.
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
                    vec![Frame::Hold(gate.clone()), Frame::Eose],
                );
                relay
            })
            .collect();
        let urls: Vec<String> = relays.iter().map(|r| r.url().to_string()).collect();

        let manager = RelayManager::new();
        let reading = read_own_per_relay(&manager, authors_n(1)[0], &urls);
        tokio::pin!(reading);
        let mut asked = HashSet::new();
        let all_asked = tokio::time::timeout(Duration::from_mins(1), async {
            while asked.len() < urls.len() {
                tokio::select! {
                    _ = &mut reading => return false,
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
            "only {} of 5 pool relays were asked while the others were held",
            asked.len(),
        );

        open.send(true).expect("release the relays");
        let reads = tokio::time::timeout(Duration::from_mins(1), reading)
            .await
            .expect("released relays end their answers");
        assert_eq!(reads.len(), urls.len());
        for (read, url) in reads.iter().zip(&urls) {
            assert!(
                same_relay(&read.relay_url, url),
                "reads come back in pool order"
            );
            assert!(
                read.drained,
                "a read ended at its bound before the release: the relays were not all asked at once"
            );
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_relay_that_did_not_end_its_answer_is_read_as_unread() {
        // A CLOSED ends the answer without an EOSE, and a relay that cannot be
        // dialled gives none at all: neither may stand for "this relay holds
        // nothing", or a retraction would read silence as absence.
        let _ = crate::relay::allow_ws_loopback_for_test();
        let seen = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let closing = nostr_relay_builder::prelude::LocalRelay::new(
            nostr_relay_builder::prelude::RelayBuilder::default().query_policy(
                RateLimitEveryQuery {
                    seen: std::sync::Arc::clone(&seen),
                },
            ),
        );
        closing.run().await.expect("local relay runs");
        let pool = vec![closing.url().await.to_string(), dead_relay_url()];

        let relay = RelayManager::new();
        let own = authors_n(1)[0];
        let reads = read_own_per_relay(&relay, own, &pool).await;

        assert!(
            seen.load(std::sync::atomic::Ordering::SeqCst) >= 1,
            "the REQ never reached the relay, so the CLOSED arm proved nothing",
        );
        assert_eq!(reads.len(), 2);
        for (read, url) in reads.iter().zip(&pool) {
            assert!(same_relay(&read.relay_url, url));
            assert!(!read.drained, "an answer that never ended is not drained");
            assert!(read.served.is_empty());
        }
        assert!(matches!(
            read_own_profile_on_relays(&relay, own, &pool, 100).await,
            OwnProfileOnRelays::Unverified
        ));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn an_answer_cut_short_keeps_what_the_relay_served() {
        // A relay that served our own event and then went over the REQ's limit
        // without an EOSE still holds it: presence needs no EOSE, only absence
        // does. The sync pass relies on this to count such a relay covered.
        let keys = Keys::generate();
        let own = keys.public_key();
        let ours = kind0(&keys, r#"{"name":"ours"}"#, 5_000);
        let mut frames = vec![Frame::Event(ours.clone())];
        for i in 0..PROFILE_PER_AUTHOR_LIMIT {
            let older = kind0(&keys, &format!(r#"{{"name":"older-{i}"}}"#), 100 + i as u64);
            frames.push(Frame::Event(older));
        }
        let relay = ScriptedRelay::start();
        relay.answer(|_| true, frames);

        let manager = RelayManager::new();
        let urls = [relay.url().to_string()];
        let reads = read_own_per_relay(&manager, own, &urls).await;

        assert_eq!(reads.len(), 1);
        assert!(
            !reads[0].drained,
            "the relay went over the limit, so it never ended its answer"
        );
        assert_eq!(
            served_against(&own, &ours, &reads[0].served),
            Served::Holds,
            "the event the relay served before the cut was discarded"
        );
        let OwnProfileOnRelays::Published(newest) =
            read_own_profile_on_relays(&manager, own, &urls, 7).await
        else {
            panic!("a served copy is a published profile, drained or not");
        };
        assert_eq!(newest.event_created_at, 5_000);
    }
}
