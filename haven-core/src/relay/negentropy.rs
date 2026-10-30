//! Haven's own NIP-77 pass: a by-id recovery of what a relay holds of a
//! circle's window and this device lacks, inside wakes the app already has.
//!
//! # What a relay learns, and why MDK's call is not used
//!
//! MDK's `NostrSdkRelayClient::reconcile_subscription` hands the relay the
//! device's inventory as negentropy's local set, and a range of fewer than 32
//! items goes out as raw ids (negentropy 0.5.0 `lib.rs` 311-319): the relay is
//! told which ids the device holds, ids it never stored included. It also
//! merges every relay's answer, fetches from every relay, and saves its cursor
//! from inside the network call (v0.10.4 `transport-nostr-adapter/src/sdk_client.rs`
//! 80-93, 398-428; `docs/MDK_UPSTREAM_TRACKER.md` T-NIP77-DRIVER). So each
//! session here advertises an EMPTY set — its opening message is always
//! `6100000200` and it never sends a fingerprint — as a dry run in the
//! download direction, which sends no REQ and no EVENT
//! ([`RelayManager::neg_remote_ids`]). The device then diffs the relay's ids
//! against MDK's inventory locally and asks THAT relay alone, by id, for what
//! it lacks: the relay learns which of its own events in the window the device
//! does not hold, and by complement which it does — nothing about any other
//! circle, and nothing it does not itself store.
//!
//! # When it runs
//!
//! At most [`NEG_ROUTES_PER_PASS`] routings per pass, and a pass only
//! [`NEG_PASS_SPACING_MS`] after the last one began: inside a background
//! burst before its seal, once at a live foreground entry, and inside a
//! catch-up sweep. Never on a timer of its own.

use std::collections::{HashMap, HashSet};
use std::time::Duration;

use nostr::{Event, EventId, RelayUrl};
use tokio::time::Instant;

use super::RelayManager;
use crate::nostr::mls::types::GroupId;
use crate::nostr::mls::{IngestClass, SessionManager};

/// How long one routing's session and its by-id fetch may take: MDK's
/// per-route budget (`sdk_client.rs` 62, `SDK_RECONCILIATION_WAIT`).
pub const NEG_ROUTE_WAIT: Duration = Duration::from_secs(2);
/// How long a relay has to answer the opening message before it is read as
/// not speaking NIP-77 (`sdk_client.rs` 63).
pub const NEG_NEGOTIATION_WAIT: Duration = Duration::from_millis(500);
/// The session filter's `limit`, and the size of an answer read as capped.
///
/// MDK's inventory ceiling per route (`sdk_client.rs` 69, `storage-sqlite`
/// `TRANSPORT_RECONCILIATION_MAX_ITEMS_PER_ROUTE`).
pub const NEG_SET_LIMIT: usize = 16_384;
/// Ids asked for by id per relay per pass (`sdk_client.rs` 66).
pub const NEG_REPLAY_BATCH: usize = 128;
/// Routings one pass reconciles (`marmot-app/src/client/sync.rs` 52).
pub const NEG_ROUTES_PER_PASS: usize = 4;
/// Haven's own spacing between the starts of two passes.
///
/// MDK's ten-second quantum is a budget for one whole pass (`sync.rs` 49); a
/// burst's budget is shorter, so Haven runs the routes of a pass at once and
/// spaces the passes.
pub const NEG_PASS_SPACING_MS: u64 = 10_000;
/// How far back a session asks: MDK's retention window, read off the local
/// clock alone.
pub const NEG_WINDOW_SECS: u64 = storage_sqlite::TRANSPORT_RECONCILIATION_RETENTION_SECS;

/// How many records of one routing pass between two forgettings of what is
/// due ([`NegMemo::resolve`]).
const NEG_MEMO_SWEEP: usize = 1_024;

/// What one routing's judged ids are cut to once past [`NEG_SET_LIMIT`].
const NEG_MEMO_LOW_WATER: usize = NEG_SET_LIMIT / 4 * 3;

/// The texts the pool gives an explicit refusal of NIP-77
/// (`nostr-relay-pool` 0.44.3 `relay/error.rs` 169; negentropy 0.5.0
/// `error.rs` 61-62). Compared, never kept or formatted (Security Rule 15).
const NEG_REFUSALS: [&str; 2] = [
    "negentropy not supported",
    "server does not support our negentropy protocol version",
];

/// One relay's answer to a session. No formatter: it holds event ids.
pub(crate) enum NegAnswer {
    /// The relay's ids for the window, fewer than [`NEG_SET_LIMIT`].
    Complete(HashSet<EventId>),
    /// As many ids as the limit, or more: a relay that applied the limit
    /// returned the newest of a larger set, and says nothing of the rest.
    /// Kept to the [`NEG_SET_LIMIT`] lowest ids.
    Saturated(HashSet<EventId>),
    /// The relay refused NIP-77 outright.
    Unsupported,
    /// Anything else: no answer in time, a socket that went away, a refusal
    /// of this one session.
    Failed,
}

impl NegAnswer {
    /// The answer a session that ended with `remote` gives.
    pub(crate) fn from_remote(remote: HashSet<EventId>) -> Self {
        if remote.len() < NEG_SET_LIMIT {
            return Self::Complete(remote);
        }
        let mut lowest: Vec<EventId> = remote.into_iter().collect();
        lowest.sort_unstable();
        lowest.truncate(NEG_SET_LIMIT);
        Self::Saturated(lowest.into_iter().collect())
    }

    /// The answer a session the pool failed with `text` gives.
    pub(crate) fn from_failure(text: &str) -> Self {
        if NEG_REFUSALS.contains(&text) {
            Self::Unsupported
        } else {
            Self::Failed
        }
    }
}

/// One routing of one circle that a pass reconciles: a routing id and the
/// relays it is listed at. No formatter: relay URLs and a group id.
#[derive(Clone)]
pub(crate) struct NegRoute {
    pub group_id: GroupId,
    pub routing_id: [u8; 32],
    pub relays: Vec<String>,
}

/// What a pass keeps for the life of the process. Nothing here is ever sent.
/// No formatter: relay URLs and event ids.
#[derive(Default)]
pub(crate) struct NegMemo {
    /// Relays that refused NIP-77 outright; skipped from then on. A relay
    /// that only failed to answer is never here (`sdk_client.rs` 180-183).
    unsupported: HashSet<String>,
    /// When the last pass began, on [`SessionManager::legacy_now_ms`].
    pass_began_ms: Option<u64>,
    /// Per routing id: ids this device has judged, each with the second at
    /// which it may be forgotten — taken in by the engine, or refused by
    /// Haven's screen before authentication.
    resolved: HashMap<[u8; 32], HashMap<EventId, u64>>,
    /// Per routing id and relay: ids that relay reported and did not serve
    /// when asked by id, in an answer it finished.
    unserved: HashMap<([u8; 32], String), HashSet<EventId>>,
}

impl NegMemo {
    /// Whether a pass may begin at `now_ms`, which it then does.
    pub(crate) fn begin_pass(&mut self, now_ms: u64) -> bool {
        if self
            .pass_began_ms
            .is_some_and(|began| now_ms >= began && now_ms - began < NEG_PASS_SPACING_MS)
        {
            return false;
        }
        self.pass_began_ms = Some(now_ms);
        true
    }

    /// Records `id` of `routing_id` as judged, until `forget_at` (seconds).
    /// What is due is forgotten every [`NEG_MEMO_SWEEP`] records, and past
    /// [`NEG_SET_LIMIT`] the soonest due go first, down to
    /// [`NEG_MEMO_LOW_WATER`] at once, so the sort is paid once per quarter
    /// of the cap and not per record: a forgotten id costs one more ask,
    /// never a hold.
    pub(crate) fn resolve(
        &mut self,
        routing_id: [u8; 32],
        id: EventId,
        forget_at: u64,
        now_secs: u64,
    ) {
        let judged = self.resolved.entry(routing_id).or_default();
        judged.insert(id, forget_at);
        if judged.len().is_multiple_of(NEG_MEMO_SWEEP) {
            judged.retain(|_, at| *at > now_secs);
        }
        if judged.len() > NEG_SET_LIMIT {
            let mut by_end: Vec<(u64, EventId)> =
                judged.iter().map(|(id, at)| (*at, *id)).collect();
            by_end.sort_unstable();
            for (_, id) in by_end.iter().take(judged.len() - NEG_MEMO_LOW_WATER) {
                judged.remove(id);
            }
        }
    }

    /// What each relay of `route` reported, in `answers`, that this device
    /// lacks — not `held` (MDK's inventory, the refused ledger), not judged
    /// here, not one that relay already failed to serve — and whether every
    /// relay answered in full and under the limit. A relay that refused
    /// NIP-77 outright is written off for the process.
    fn lacked<'r>(
        &mut self,
        route: &'r NegRoute,
        answers: Vec<NegAnswer>,
        skipped: &[bool],
        now_secs: u64,
        held: &dyn Fn(&EventId) -> bool,
    ) -> (Vec<(&'r String, HashSet<EventId>)>, bool) {
        self.forget_expired(&route.routing_id, now_secs);
        let mut whole = true;
        let mut missing = Vec::new();
        for ((relay, answer), skip) in route.relays.iter().zip(answers).zip(skipped) {
            let remote = match answer {
                NegAnswer::Complete(remote) => remote,
                NegAnswer::Saturated(remote) => {
                    whole = false;
                    remote
                }
                NegAnswer::Unsupported => {
                    whole = false;
                    if !skip {
                        self.unsupported.insert(relay_key(relay));
                    }
                    continue;
                }
                NegAnswer::Failed => {
                    whole = false;
                    continue;
                }
            };
            let unserved = self
                .unserved
                .entry((route.routing_id, relay_key(relay)))
                .or_default();
            unserved.retain(|id| remote.contains(id));
            let unserved = unserved.clone();
            let lacked: HashSet<EventId> = remote
                .into_iter()
                .filter(|id| {
                    !held(id) && !unserved.contains(id) && !self.is_resolved(&route.routing_id, id)
                })
                .collect();
            missing.push((relay, lacked));
        }
        (missing, whole)
    }

    /// What the by-id answers in `fetched` bring for the engine, and whether
    /// every relay finished its answer in time. An id a relay was asked for
    /// and left out of an answer it finished is that relay's unserved id; an
    /// event Haven's screen refuses is judged here and not handed on.
    fn judge(
        &mut self,
        route: &NegRoute,
        fetched: Vec<(&String, Vec<EventId>, Option<super::RelayFetchOutcome>)>,
        now_secs: u64,
    ) -> (Vec<Event>, bool) {
        let mut events: Vec<Event> = Vec::new();
        let mut drained = true;
        for (relay, asked, outcome) in fetched {
            let Some(outcome) = outcome.filter(|outcome| outcome.drained) else {
                drained = false;
                continue;
            };
            let served: HashSet<EventId> = outcome.events.iter().map(|event| event.id).collect();
            self.unserved
                .entry((route.routing_id, relay_key(relay)))
                .or_default()
                .extend(asked.iter().filter(|id| !served.contains(id)));
            for event in outcome.events {
                if !asked.contains(&event.id) || events.iter().any(|kept| kept.id == event.id) {
                    continue;
                }
                if SessionManager::passes_screen(&event) {
                    events.push(event);
                } else {
                    self.resolve(
                        route.routing_id,
                        event.id,
                        forget_at(&event, now_secs),
                        now_secs,
                    );
                }
            }
        }
        (events, drained)
    }

    fn forget_expired(&mut self, routing_id: &[u8; 32], now_secs: u64) {
        if let Some(judged) = self.resolved.get_mut(routing_id) {
            judged.retain(|_, forget_at| *forget_at > now_secs);
        }
    }

    /// How many routings hold judged ids.
    #[cfg(test)]
    pub(crate) fn judged_routings(&self) -> usize {
        self.resolved.len()
    }

    pub(crate) fn is_resolved(&self, routing_id: &[u8; 32], id: &EventId) -> bool {
        self.resolved
            .get(routing_id)
            .is_some_and(|judged| judged.contains_key(id))
    }
}

/// The second at which a judged `event` may be forgotten: its NIP-40
/// expiration, or the end of the window, whichever is sooner.
pub(crate) fn forget_at(event: &Event, now_secs: u64) -> u64 {
    let window_end = now_secs.saturating_add(NEG_WINDOW_SECS);
    event
        .tags
        .expiration()
        .map_or(window_end, |expires| expires.as_secs().min(window_end))
}

/// The relay key the memo is read under: the parsed URL, or the string as
/// given when it does not parse.
fn relay_key(relay: &str) -> String {
    RelayUrl::parse(relay).map_or_else(|_| relay.to_string(), |url| url.to_string())
}

/// What a routing's pass established, in the only terms a catch-up window
/// may compose on. No formatter: two absolute instants.
#[derive(Clone, Copy)]
pub(crate) struct NegCoverage {
    /// The session filter's `since`, a local clock reading.
    pub since_secs: i64,
    /// The session filter's `until`, read off the local clock before the
    /// first session opened.
    pub until_secs: i64,
    /// Every relay of the routing answered in full and under the limit,
    /// every id any of them reported and this device lacked was asked of the
    /// relay that reported it in an answer that relay finished, and the
    /// engine now holds, or the refused ledger owes, everything that came
    /// back.
    pub whole: bool,
}

impl NegCoverage {
    /// Whether this pass covers `[since_secs, ceiling_secs]` whole.
    pub(crate) const fn covers(&self, since_secs: i64, ceiling_secs: i64) -> bool {
        self.whole && self.since_secs <= since_secs && self.until_secs >= ceiling_secs
    }
}

/// Where a pass's recovered events are taken in. The catch-up sweep's sink
/// records what each says about its cursor; the live plane's ingests on the
/// worker's own path.
#[async_trait::async_trait]
pub(crate) trait NegSink: Sync {
    /// Takes `events` of `route`, already in ingest order, in; answers
    /// whether the engine now holds, or the refused ledger owes, every one.
    async fn take_in(&self, route: &NegRoute, events: Vec<(IngestClass, Event)>) -> bool;

    /// Whether the wake this sink serves still stands: read before the pass
    /// dials, and before it fetches. The live plane's ends with its lifecycle.
    fn stands(&self) -> bool {
        true
    }
}

/// Holds `group_id`'s sends while what a pass fetched is not yet taken in
/// (Security Rule 10), released however the pass ends.
struct UnreadHold<'a> {
    session: &'a SessionManager,
    group_id: GroupId,
}

impl<'a> UnreadHold<'a> {
    fn take(session: &'a SessionManager, group_id: &GroupId) -> Self {
        session.hold_live_replay(group_id);
        Self {
            session,
            group_id: group_id.clone(),
        }
    }
}

impl Drop for UnreadHold<'_> {
    fn drop(&mut self) {
        self.session.release_live_replay(&self.group_id);
    }
}

/// Begins a pass over `routes` if the spacing allows: the routes, deduplicated
/// and sorted by routing id, rotated to start after MDK's durable route cursor
/// and cut to [`NEG_ROUTES_PER_PASS`]. The cursor moves to the last route
/// taken before any network I/O, as MDK's does (`sync.rs` 931-932), so a pass
/// a kill cuts short cannot pin the routes behind it. Empty when no pass may
/// begin.
pub(crate) async fn begin_pass(
    session: &SessionManager,
    mut routes: Vec<NegRoute>,
) -> Vec<NegRoute> {
    routes.sort_by_key(|route| route.routing_id);
    routes.dedup_by_key(|route| route.routing_id);
    routes.retain(|route| !route.relays.is_empty());
    if routes.is_empty() || !session.neg_memo().begin_pass(session.legacy_now_ms()) {
        return Vec::new();
    }
    let cursor = session.neg_route_cursor().await;
    let start = cursor
        .and_then(|cursor| routes.iter().position(|route| route.routing_id > cursor))
        .unwrap_or(0);
    routes.rotate_left(start);
    routes.truncate(NEG_ROUTES_PER_PASS);
    if let Some(last) = routes.last() {
        session.neg_advance_route_cursor(&last.routing_id).await;
    }
    routes
}

/// Runs every route of a pass at once, on `relays`, each within
/// [`NEG_ROUTE_WAIT`] of its sessions opening; what comes back goes to `sink`.
/// Every relay is dialled before any session opens.
pub(crate) async fn run_pass(
    relays: &RelayManager,
    session: &SessionManager,
    routes: &[NegRoute],
    sink: &dyn NegSink,
) {
    let mut every: Vec<String> = routes
        .iter()
        .flat_map(|route| route.relays.iter().cloned())
        .collect();
    every.sort();
    every.dedup();
    if !sink.stands() {
        return;
    }
    relays.neg_prepare(&every).await;
    futures::future::join_all(
        routes
            .iter()
            .map(|route| reconcile_route(relays, session, route, sink)),
    )
    .await;
}

/// Reconciles one route, its relays already dialled: one session per relay,
/// then a by-id fetch from each relay of what it reported and this device
/// lacks, taken in through `sink`.
pub(crate) async fn reconcile_route(
    relays: &RelayManager,
    session: &SessionManager,
    route: &NegRoute,
    sink: &dyn NegSink,
) -> NegCoverage {
    let until = u64::try_from(chrono::Utc::now().timestamp()).unwrap_or(0);
    let since = until.saturating_sub(NEG_WINDOW_SECS);
    let mut coverage = NegCoverage {
        since_secs: i64::try_from(since).unwrap_or(i64::MAX),
        until_secs: i64::try_from(until).unwrap_or(i64::MAX),
        whole: false,
    };
    let Some(inventory) = session.neg_inventory(&route.routing_id, until).await else {
        return coverage;
    };
    let ends = Instant::now() + NEG_ROUTE_WAIT;
    let skipped: Vec<bool> = {
        let memo = session.neg_memo();
        route
            .relays
            .iter()
            .map(|relay| memo.unsupported.contains(&relay_key(relay)))
            .collect()
    };
    let answers: Vec<NegAnswer> = futures::future::join_all(route.relays.iter().zip(&skipped).map(
        |(relay, skip)| async move {
            if *skip {
                NegAnswer::Unsupported
            } else {
                relays
                    .neg_remote_ids(&route.routing_id, relay, since, until, ends)
                    .await
            }
        },
    ))
    .await;
    let owed = session.refused_owes(&route.group_id);
    let (missing, mut whole) = session
        .neg_memo()
        .lacked(route, answers, &skipped, until, &|id| {
            inventory.contains(id) || owed.contains(id)
        });
    if missing.iter().all(|(_, lacked)| lacked.is_empty()) {
        coverage.whole = whole;
        return coverage;
    }
    let (asks, cursor, every_one) =
        batches(&missing, session.neg_replay_cursor(&route.routing_id).await);
    whole &= every_one;
    // Saved before the fetch, as MDK's progress is (`sdk_client.rs` 72-74).
    if let Some(cursor) = cursor {
        session
            .neg_advance_replay_cursor(&route.routing_id, &cursor)
            .await;
    }
    if !sink.stands() {
        return coverage;
    }
    let _unread = UnreadHold::take(session, &route.group_id);
    let fetched = fetch_asks(relays, route, asks, ends).await;
    let now_secs = u64::try_from(chrono::Utc::now().timestamp()).unwrap_or(0);
    let (mut events, all_drained) = session.neg_memo().judge(route, fetched, now_secs);
    whole &= all_drained;
    events.sort_by_key(|event| (event.created_at, event.id));
    let ordered = session.order_for_ingest(&route.group_id, events).await;
    if !ordered.is_empty() && !sink.take_in(route, ordered).await {
        whole = false;
    }
    coverage.whole = whole;
    coverage
}

/// The ids each relay is asked for by id.
type Asks<'a> = Vec<(&'a String, Vec<EventId>)>;

/// Each relay's own by-id batch, rotated after the route's one cursor — a
/// relay reporting any number of ids cannot crowd another relay's out — and
/// the cursor to save: where the relay that got least far stopped, so every
/// relay's next batch begins past what it was asked this time. Last, whether
/// every id was asked of the relay that reported it.
fn batches<'a>(
    missing: &[(&'a String, HashSet<EventId>)],
    after: Option<EventId>,
) -> (Asks<'a>, Option<EventId>, bool) {
    let mut asks = Vec::new();
    let (mut slowest, mut furthest): (Option<EventId>, Option<EventId>) = (None, None);
    for (relay, lacked) in missing {
        let mut sorted: Vec<EventId> = lacked.iter().copied().collect();
        sorted.sort_unstable();
        let batch = choose(&sorted, after);
        let Some(last) = batch.last().copied() else {
            continue;
        };
        furthest = furthest.max(Some(last));
        if batch.len() < sorted.len() {
            slowest = Some(slowest.map_or(last, |seen| seen.min(last)));
        }
        asks.push((*relay, batch));
    }
    (asks, slowest.or(furthest), slowest.is_none())
}

/// Asks each relay for its batch, by id, under the route's deadline; each
/// relay's answer, `None` when it did not come in time.
async fn fetch_asks<'a>(
    relays: &RelayManager,
    route: &NegRoute,
    asks: Asks<'a>,
    ends: Instant,
) -> Vec<(&'a String, Vec<EventId>, Option<super::RelayFetchOutcome>)> {
    let routing_hex = hex::encode(route.routing_id);
    let asking = asks.into_iter().map(|(relay, asked)| {
        let routing_hex = routing_hex.as_str();
        async move {
            let outcome = tokio::time::timeout_at(
                ends,
                super::catchup::fetch_ids(
                    relays,
                    &asked,
                    Some(routing_hex),
                    std::slice::from_ref(relay),
                ),
            )
            .await
            .ok()
            .and_then(|outcomes| outcomes.into_iter().next());
            (relay, asked, outcome)
        }
    });
    futures::future::join_all(asking).await
}

/// At most [`NEG_REPLAY_BATCH`] of `sorted`, starting after `after` and
/// wrapping: MDK's `bounded_reconciliation_remote_ids` (`sdk_client.rs`
/// 96-110), so a batch the engine keeps refusing cannot starve the ids
/// behind it.
fn choose(sorted: &[EventId], after: Option<EventId>) -> Vec<EventId> {
    let mut ids = sorted.to_vec();
    if let Some(after) = after.filter(|_| !ids.is_empty()) {
        let start = ids.partition_point(|id| *id <= after) % ids.len();
        ids.rotate_left(start);
    }
    ids.truncate(NEG_REPLAY_BATCH);
    ids
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(seed: u16) -> EventId {
        let mut bytes = [0u8; 32];
        bytes[..2].copy_from_slice(&seed.to_be_bytes());
        EventId::from_byte_array(bytes)
    }

    #[test]
    fn an_answer_at_the_limit_is_saturated_and_kept_to_the_lowest_ids() {
        let under: HashSet<EventId> = (0..10).map(id).collect();
        assert!(
            matches!(NegAnswer::from_remote(under), NegAnswer::Complete(set) if set.len() == 10)
        );
        let at: HashSet<EventId> = (0..u16::try_from(NEG_SET_LIMIT + 5).unwrap())
            .map(id)
            .collect();
        let NegAnswer::Saturated(kept) = NegAnswer::from_remote(at) else {
            panic!("an answer at or past the limit is never complete");
        };
        assert_eq!(kept.len(), NEG_SET_LIMIT);
        assert!(kept.contains(&id(0)));
        assert!(!kept.contains(&id(u16::try_from(NEG_SET_LIMIT).unwrap())));
    }

    #[test]
    fn only_the_pools_two_refusal_texts_read_as_unsupported() {
        for refusal in NEG_REFUSALS {
            assert!(matches!(
                NegAnswer::from_failure(refusal),
                NegAnswer::Unsupported
            ));
        }
        for other in [
            "timeout",
            "relay not connected",
            "unsupported negentropy protocol version",
            "negentropy not supported ",
        ] {
            assert!(matches!(NegAnswer::from_failure(other), NegAnswer::Failed));
        }
    }

    #[test]
    fn a_pass_begins_only_its_spacing_after_the_last_one_began() {
        let mut memo = NegMemo::default();
        assert!(memo.begin_pass(100_000));
        assert!(!memo.begin_pass(100_000 + NEG_PASS_SPACING_MS - 1));
        assert!(memo.begin_pass(100_000 + NEG_PASS_SPACING_MS));
        // A clock stepped back is not held to a start it has not reached.
        assert!(memo.begin_pass(50_000));
    }

    #[test]
    fn the_by_id_batch_rotates_after_the_cursor_and_wraps() {
        let sorted: Vec<EventId> = (0..300).map(id).collect();
        let first = choose(&sorted, None);
        assert_eq!(first.len(), NEG_REPLAY_BATCH);
        assert_eq!(first[0], id(0));
        let second = choose(&sorted, first.last().copied());
        assert_eq!(second[0], id(128));
        let third = choose(&sorted, Some(id(250)));
        assert_eq!(third[0], id(251));
        assert_eq!(third[49], id(0), "the batch wraps to the start");
    }

    #[test]
    fn judged_ids_are_forgotten_when_due_and_held_to_the_cap() {
        let mut memo = NegMemo::default();
        let route = [7u8; 32];
        memo.resolve(route, id(1), 10, 0);
        memo.resolve(route, id(2), 30, 0);
        memo.forget_expired(&route, 20);
        assert!(!memo.is_resolved(&route, &id(1)));
        assert!(memo.is_resolved(&route, &id(2)));
        for seed in 0..u16::try_from(NEG_SET_LIMIT + 1).unwrap() {
            memo.resolve(route, id(seed), 1_000 + u64::from(seed), 0);
        }
        assert_eq!(
            memo.resolved[&route].len(),
            12_288,
            "past the cap the memo is cut to three quarters of it at once, so the \
             next quarter's records pay no sort"
        );
        assert!(
            !memo.is_resolved(&route, &id(0)),
            "the soonest due goes first"
        );
        assert!(memo.is_resolved(&route, &id(u16::try_from(NEG_SET_LIMIT).unwrap())));
    }
}
