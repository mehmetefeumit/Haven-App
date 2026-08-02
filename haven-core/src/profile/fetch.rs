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
//! The [`RelayManager`] is constructed by the caller via [`RelayManager::new`]
//! with no signer (`Client::builder()`), so a relay's NIP-42 AUTH challenge can
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
    /// Authors queried whose assigned relay returned nothing.
    pub missed: Vec<PublicKey>,
    /// Authors dropped before any `REQ` (deadline hit, or no relay in rank).
    /// The caller MUST NOT stamp these as attempted — they retry next tick.
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
/// may advance an author's attempt counter (and therefore its disclosure) onto
/// a second relay.
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
    /// Authors whose assigned relay answered with nothing.
    missed: Vec<PublicKey>,
    /// Every author whose `REQ` completed, in either direction.
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
    let mut batches = group_by_assigned_relay(&deduped, salt, pool);
    shuffle_batches(&mut batches);

    let cycle = Mutex::new(Cycle::default());
    {
        // The per-relay drivers are materialized with `Iterator::map` and fed to
        // `stream::iter` as futures, rather than created inside a
        // `StreamExt::map` closure. That is load-bearing, not stylistic: a
        // closure returning a future that borrows its argument gets a
        // higher-ranked `FnOnce` obligation rustc cannot generalise, so the
        // resulting cycle future is `Send` only for *some* lifetime. Every
        // caller that needs `Send` for *any* lifetime — i.e. every
        // `flutter_rust_bridge` async FFI method — then fails to compile with
        // "implementation of `FnOnce` is not general enough". Building the
        // futures eagerly is behaviourally identical (an `async fn` body does
        // not run until polled) and keeps the same `buffer_unordered`
        // concurrency cap.
        let drivers: Vec<_> = batches
            .iter()
            .map(|batch| drain_relay_batch(relay, batch, now, &cycle))
            .collect();
        let work = stream::iter(drivers)
            .buffer_unordered(PROFILE_MAX_INFLIGHT_RELAYS)
            .for_each(|()| std::future::ready(()));

        // Authors not yet settled when the deadline fires stay UNSETTLED, and
        // so fall out of `partition_outcome` as `unattempted` — never as
        // `missed`. Stamping a deadline as a miss would advance the retry
        // ladder onto a second relay for a reason that has nothing to do with
        // the author.
        if tokio::time::timeout(deadline, work).await.is_err() {
            log::debug!("[profile] assigned fetch cycle hit its batch deadline");
        }
    }

    partition_outcome(
        &deduped,
        cycle.into_inner().unwrap_or_else(PoisonError::into_inner),
    )
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

        // A relay that answers a `REQ` with a rate-limit `CLOSED` is absorbed
        // by the SDK: the per-relay stream error is logged and swallowed, and
        // the fetch resolves `Ok` with whatever arrived first. That surfaces
        // here as an empty event set — i.e. a MISS, which is what it should
        // be. An `Err` from `fetch_events`, by contrast, only comes from
        // pre-`REQ` conditions (URL validation, relay not in the pool), so
        // nothing was disclosed and nothing may be stamped: leave the author
        // unsettled and abandon this batch, since the same condition would
        // recur for every remaining author on the same relay.
        let Ok(events) = relay
            .fetch_events(
                build_author_filter(author),
                &targets,
                Some(PROFILE_AUTHOR_FETCH_TIMEOUT),
            )
            .await
        else {
            log::debug!("[profile] assigned relay unusable; leaving its slice unattempted");
            break;
        };

        let resolved = resolve_author(author, &events, now);
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

/// Reduces one author's `REQ` result to a cache row, or [`None`] on a miss.
///
/// [`parse_newest_metadata`] ignores events whose `pubkey` is not `author`, so
/// a relay that answers with somebody else's kind-0 cannot inject a row. A
/// [`ProfileState::Unknown`] outcome returns [`None`] rather than a blank row,
/// so a fetched-but-empty row can never mask a genuine miss.
fn resolve_author(author: &PublicKey, events: &[Event], now: i64) -> Option<CachedProfile> {
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

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn rate_limited_closed_is_a_miss_not_an_error() {
        // A relay under load answers a REQ with `CLOSED <sub> "rate-limited:
        // ..."`. The SDK absorbs that into an empty Ok result (the per-relay
        // stream error is logged and swallowed by the pool's driver task), so
        // it must land in `missed` — the ordinary "ask the next rung next
        // time" path — and MUST NOT abort the cycle for the other relays'
        // slices. Proven against a real socket rather than asserted from the
        // SDK source, because that absorption is an upstream implementation
        // detail that a version bump could change.
        let _ = crate::relay::allow_ws_loopback_for_test();
        let seen = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let server = nostr_relay_builder::prelude::LocalRelay::new(
            nostr_relay_builder::prelude::RelayBuilder::default().query_policy(
                RateLimitEveryQuery {
                    seen: std::sync::Arc::clone(&seen),
                },
            ),
        );
        server.run().await.expect("local relay runs");
        let url = server.url().await.to_string();

        let relay = RelayManager::new();
        let author = authors_n(1)[0];
        let out = fetch_profiles_assigned(&relay, &[(author, 0)], &salt(), &[url], 100)
            .await
            .expect("a rate-limit CLOSED must not surface as an error");

        assert!(
            seen.load(std::sync::atomic::Ordering::SeqCst) >= 1,
            "the relay never saw the REQ, so this test proved nothing about CLOSED",
        );
        assert!(out.resolved.is_empty());
        assert_eq!(
            out.missed,
            vec![author],
            "a rate-limit CLOSED is a miss, not an error",
        );
        assert!(
            out.unattempted.is_empty(),
            "the REQ was issued and answered, so the author was attempted",
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
    fn resolve_author_returns_none_for_an_empty_reply() {
        // A relay that answers with nothing is a MISS; the caller marks it
        // Unknown rather than caching a blank row that would look fetched.
        assert!(resolve_author(&authors_n(1)[0], &[], 42).is_none());
    }

    #[test]
    fn resolve_author_stamps_now_and_event_created_at() {
        let ks = keys_n(1);
        let author = ks[0].public_key();
        let events = vec![kind0(&ks[0], r#"{"name":"present"}"#, 1_000)];
        let row = resolve_author(&author, &events, 42).expect("resolved");
        assert_eq!(row.pubkey_hex, author.to_hex());
        assert_eq!(row.state, ProfileState::Known);
        assert_eq!(row.fetched_at, 42, "now is stamped into fetched_at");
        assert_eq!(row.event_created_at, 1_000);
    }

    #[test]
    fn resolve_author_picks_newest() {
        let ks = keys_n(1);
        let events = vec![
            kind0(&ks[0], r#"{"name":"old"}"#, 1_000),
            kind0(&ks[0], r#"{"name":"new"}"#, 2_000),
        ];
        let row = resolve_author(&ks[0].public_key(), &events, 7).expect("resolved");
        assert_eq!(row.metadata.name(), Some("new"));
    }

    #[test]
    fn resolve_author_ignores_unrequested_author_events() {
        // A relay answering a single-author REQ with somebody ELSE's kind-0
        // must not be able to inject a row (defensive).
        let ks = keys_n(2);
        let requested = &ks[0];
        let intruder = &ks[1];
        let events = vec![
            kind0(requested, r#"{"name":"wanted"}"#, 1_000),
            kind0(intruder, r#"{"name":"unwanted"}"#, 5_000),
        ];
        let row = resolve_author(&requested.public_key(), &events, 1).expect("resolved");
        assert_eq!(row.pubkey_hex, requested.public_key().to_hex());
        assert_eq!(row.metadata.name(), Some("wanted"));
        assert!(resolve_author(&intruder.public_key(), &events[..1], 1).is_none());
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
}
