//! **S08** — a commit buried on the live plane past the relay's replay cap,
//! and the device that missed it never converges again.
//!
//! A co-member's commit is pushed off the only page the relay serves by
//! outsider forgeries. `buried-past-the-cap` is **EXPECTED RED at rc 1** until
//! the product fix lands: C8 in `docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md`.
//!
//! The user-visible consequence: a device that was paused while a commit
//! landed — backgrounded, asleep, out of coverage — comes back, re-subscribes,
//! and is handed a page that does not contain the commit. It stays one epoch
//! behind for good: every later fix from its peers is sealed above it, the
//! map's other markers stop moving, and nothing says so. A buried COMMIT is a
//! permanent strand; a buried location merely ages out.
//!
//! # The mechanism, at haven-core as it stands
//!
//! 1. The live group REQ carries no `limit`
//!    (`haven-core/src/relay/live_sync/planes/group.rs:33-42`, `group_filter`):
//!    it asks for everything since the circle's cursor less
//!    `GROUP_RESUBSCRIBE_BUFFER_SECS` (`relay/cursor.rs`).
//! 2. A relay answers a filter with no `limit` at ITS default:
//!    `nostr-relay-builder`'s `default_filter_limit` is 500
//!    (`nostr-relay-builder-0.44.1/src/builder.rs:225`, applied at
//!    `local/inner.rs:852-854`). Only the newest 500 arrive, then `EOSE`.
//! 3. The live plane trusts that `EOSE` as "everything stored has been handed
//!    over" and advances the cursor to the REQ's own open time
//!    (`live_sync/anchor.rs`), held no lower than the oldest event on the page
//!    it could not apply — here a forgery, dated after the commit. Its intake
//!    hold-back (`live_sync/processor.rs:584-604`) covers a delivery Haven
//!    ITSELF dropped, never one the relay did not send.
//!    The catch-up sweep has a truncation rule since RLY-05(c) — a window is
//!    not finished because a page arrived (`relay/catchup.rs`,
//!    `CATCHUP_MAX_EVENTS_PER_PAGE`'s doc) — and the live plane has none.
//! 4. Anyone who has seen a circle's public `#h` can sign kind-445s carrying
//!    it. More than the cap of them, dated after a real event, push that event
//!    off the only page the relay serves.
//! 5. Once the cursor has advanced, nothing asks again: the next REQ's `since`
//!    and the catch-up sweep's floor are both the cursor less
//!    `GROUP_RESUBSCRIBE_BUFFER_SECS` (`catchup.rs` derives it through the
//!    same `since_for_stream`), which is above the buried event once the
//!    re-anchor lands at least that long plus one second after it.
//!
//! # Why the arm waits a lookback before the forgeries
//!
//! Sooner, the sweep's floor still reaches the buried event and the sweep —
//! which pages past a capped answer — recovers it: measured with the seed one
//! second after the commit, the live page lacked the commit and the sweep
//! fetched and applied it (`PLAN_PHASE2.md`'s 2c notes). The forgeries are
//! what the victim's cursor is left on (the live plane holds its advance at
//! the oldest event it could not apply), so they are minted only once the
//! lookback has passed. `since` is inclusive and a cursor is floored to whole
//! seconds, so a re-anchor inside the event's second plus the buffer still
//! asks for it; one wall second more is the least that does not. The
//! wait is [`Absence::ResubscribeLookback`], derived in `oracle::bounds` from
//! the product's constant and read back against the commit's `created_at` in
//! the relay's own store — a bounded condition on the wall clock, never a
//! sleep and never a policy-clock step (the cursor is a WALL fact,
//! `check_soak_clock_partition.sh`).
//!
//! # The seed is spread over wall seconds
//!
//! No second holds more than half a catch-up page ([`SEED_PER_SECOND`]). A
//! one-second pile-up a page cannot hold is the sweep's own residual, and it
//! reaches further than `catchup.rs` says: measured, 501 forgeries in ONE
//! second, one second after the commit, left the sweep with two pages of
//! forgeries, no commit, nothing applied and no truncation reported. A strand
//! bought that way would be the sweep's defect, not the one this arm grades.
//!
//! # Why the buried event is a commit, and which commit
//!
//! A location would age out and nobody would notice; a commit strands the
//! epoch chain, which the closing round's O2 can see. It is an admin handoff
//! (`hand_off_admin`), never a relay-list commit: a relay-list commit writes
//! the new relay into storage, and the catch-up sweep would then dial an
//! address no plane serves and fail on its own account.
//!
//! # Canaries are the burial's CONDITIONS, never its symptoms
//!
//! Every canary here holds just as well in a product that has been fixed: the
//! commit was real and live elsewhere, the lookback was waited, every store's
//! newest page is forgeries and the victim was served a full one, the victim
//! re-subscribed on every plane, and the sweep finished its window cleanly. The
//! strand itself — the commit never reaching the victim, its cursor passing
//! over it — is NOT a canary: a fixed product grades rc 0 rather than rc 3,
//! which is what lets `tests/oracles.rs` pin the day C8 is fixed. For the same
//! reason the arm waits for the first page's cursor advance without counting
//! it: a fix that HOLDS the cursor on a capped page is the other honest
//! answer, and a canary there would grade it unusable.
//!
//! # Graded, not recorded
//!
//! The closing round asks O6, O1 and O2 after both the second REQ and the
//! sweep, so the strand is GRADED: O1 reports the probe that never reaches the
//! victim and O2 the diverged epoch, both at rc 1 — S23's shape, for S23's
//! reason: the defect is neither decided nor intended. The WITNESS leads, so
//! the victim's first probe is a receive.
//!
//! # `packed-window` is not in Tier 1, measured
//!
//! PLAN §2.5 designed this scenario around the intake cap (`WORKER_QUEUE_CAP`,
//! 8 192): a replay big enough to fill the queue, and the hold the queue then
//! places on the cursor. Three facts measured on 2026-09-26 put it out of
//! reach, and none is the product's to change: the relay serves at most
//! [`RELAY_DEFAULT_REPLAY_CAP`] per REQ, so no replay reaches the queue; the
//! relay pool's 35 000-id tracker (`nostr-relay-pool-0.44.3/src/relay/inner.rs:1209-1239`)
//! swallows an id it has already seen this session, which defeats
//! `DoubleEveryEvent` and means a carried-over hold PINS the cursor rather
//! than being re-asked; and a relay rate-limits publishing to sixty events a
//! minute per connection, so a backlog can only be seeded, never published.
//! What that measurement found instead is the burial this arm grades.
//!
//! `unpacked-control` is the same shape with a seed strictly below the cap: the
//! commit is on the page, the victim applies it live, its cursor moves past it,
//! and its engine holds every REQ it expects. It isolates the cap
//! as the cause.
//!
//! # What Tier 1 does not assert
//!
//! When the app re-subscribes is Dart's schedule (resume, the
//! `subscriptionHealthInterval` backstop), which Tier 1 does not run; the rig
//! drives the re-anchor itself (`go_offline`/`come_online`) and asserts the
//! core's half. The schedule half is Tier 2's.
//!
//! The product fix — a follow-up page on the live plane when a replay comes
//! back at a relay's cap, or a hold that the next REQ re-asks — is NOT
//! designed here. It is a product change with its own plan.
//!
//! # `offline` is a paused engine, not an unplugged socket
//!
//! `go_offline` closes every REQ and disconnects nothing, so the recovery is
//! `Undisturbed` and each resume pays the subscribe ladder — S04's shape.

use std::collections::{HashMap, HashSet};
use std::time::Duration;

use haven_core::nostr::mls::types::GroupId;
use haven_core::relay::catchup::{run_catchup_all_circles, CATCHUP_MAX_EVENTS_PER_PAGE};
use haven_core::relay::live_sync::group_cursor_stream;
use haven_core::relay::live_sync::planes::group::group_filter;
use nostr::{Event, EventId, Filter};
use tokio::time::Instant;

use crate::clock::WallNow;
use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{bounds, Invariant, Reach, Recovery};
use crate::relay::{mint, Forgery, SimRelay, RELAY_DEFAULT_REPLAY_CAP};
use crate::rig::{DeviceTag, LogDrain, PublishVerdict, RigError, Step, TimelineSink};
use crate::scenarios::{
    await_condition, closing_pairs, grade_round, hand_off_admin, round, Absence, Arm, ArmOutcome,
    Scenario, ScenarioReport, ScenarioWorld, WithheldAcks, NO_GATING_ROWS,
};

/// The forgeries `buried-past-the-cap` seeds: one more than the relay serves,
/// so the page it does serve is forgeries and nothing else.
const PACKED_SEED: usize = RELAY_DEFAULT_REPLAY_CAP + 1;

/// The forgeries `unpacked-control` seeds: a page the relay serves whole, with
/// the commit on it.
const UNPACKED_SEED: usize = 16;

/// The most seed events any one wall second holds: half a catch-up page.
///
/// A page bounded at a seed second then carries that second again with room
/// for what lies below it, so the sweep can always descend through the seed. A
/// pile-up a page cannot hold is the SWEEP's own residual (`catchup.rs`'s
/// `Pager::step`, "the residual, which is a DROP"), and a strand caused by it
/// would be the sweep's finding rather than the live plane's.
const SEED_PER_SECOND: usize = CATCHUP_MAX_EVENTS_PER_PAGE / 2;

/// The arms this scenario offers.
pub const ARMS: [Arm; 2] = [
    Arm {
        label: "buried-past-the-cap",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: true,
        absence: Absence::ResubscribeLookback,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            // A seed is WRITTEN, as a relay that accepted it would hold it; a
            // store is not a plane fault. Canary 3 proves the page was there.
            faults_applied: 0,
            epochs_crossed: 1,
            deliveries_observed: 2,
            canaries_caught: 5,
        },
    },
    Arm {
        label: "unpacked-control",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: true,
        absence: Absence::ResubscribeLookback,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            faults_applied: 0,
            epochs_crossed: 1,
            deliveries_observed: 2,
            canaries_caught: 5,
        },
    },
];

/// Runs one arm.
///
/// # Errors
///
/// [`RigError::UnknownTarget`] if the label is not one this scenario offers,
/// [`RigError::ShapeMismatch`] if the world has fewer than three devices — the
/// burial needs a committer, a witness that takes the commit live and the
/// victim that misses it — [`RigError::PublishNeverAcked`] if the commit was
/// rolled back (Rule 13), otherwise [`RigError`] naming the step that failed.
pub(crate) async fn run<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    arm: &Arm,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    let (seed, packed) = match arm.label {
        "buried-past-the-cap" => (PACKED_SEED, true),
        "unpacked-control" => (UNPACKED_SEED, false),
        _ => return Err(RigError::UnknownTarget),
    };
    let cast = cast(world)?;
    let evidence = bury(world, cast, seed).await?;
    let canaries = if packed {
        evidence.burial_canaries()
    } else {
        evidence.unpacked_canaries()
    };
    close(world, cast, tick, canaries).await
}

/// `buried-past-the-cap` over a seed BELOW the cap.
///
/// The relay serves the whole window, the commit with it, so the burial this
/// arm grades never forms: the capped-page canary goes unmet while every oracle
/// holds. The mis-configuration control in `tests/oracles.rs` runs it and
/// requires rc 3.
///
/// # Errors
///
/// As [`run`].
pub async fn below_the_cap_control<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    tick: Duration,
) -> Result<ScenarioReport, RigError> {
    let started = Instant::now();
    let cast = cast(world)?;
    let evidence = bury(world, cast, UNPACKED_SEED).await?;
    let outcome = close(world, cast, tick, evidence.burial_canaries()).await?;
    Ok(Scenario::LivePlaneBurial.report(world, &ARMS[0], outcome, started))
}

/// Who plays which part.
#[derive(Clone, Copy)]
struct Cast {
    admin: DeviceTag,
    witness: DeviceTag,
    victim: DeviceTag,
}

/// The circle's admin commits, the first other device takes it live, the next
/// one misses it.
fn cast<T: TimelineSink, L: LogDrain>(world: &ScenarioWorld<T, L>) -> Result<Cast, RigError> {
    let admin = world
        .circles()
        .first()
        .ok_or(RigError::ShapeMismatch)?
        .admin();
    let others: Vec<DeviceTag> = world
        .devices()
        .iter()
        .map(|device| device.tag)
        .filter(|tag| *tag != admin)
        .collect();
    let [witness, victim, ..] = *others.as_slice() else {
        return Err(RigError::ShapeMismatch);
    };
    Ok(Cast {
        admin,
        witness,
        victim,
    })
}

/// What the body saw, read by each arm for the canaries it counts.
#[allow(clippy::struct_excessive_bools)]
struct Evidence {
    seed: usize,
    /// Confirmed, in every store, dated after the victim's cursor, applied
    /// live by the witness, and missed by the paused victim alone.
    commit_landed: bool,
    /// The wall clock passed the commit's stored second plus the lookback.
    lookback_waited: bool,
    /// The seed spread over wall seconds, none holding more than
    /// [`SEED_PER_SECOND`], and every plane newly saved all of it.
    seeded: bool,
    /// Every store's newest page for the victim's filter is seed and nothing
    /// else.
    newest_page_is_seed: bool,
    /// Every plane served the victim at least one page's worth of seed and
    /// closed that page with an `EOSE`.
    page_served: bool,
    /// Every plane served the victim the commit and every seed event.
    window_served: bool,
    /// The victim applied the commit from its first page: its epoch met the
    /// admin's before the sweep ran.
    applied_live: bool,
    /// The victim's cursor moved past the commit it applied, to the oldest
    /// seed event's second: a forgery the live plane cannot apply holds the
    /// advance there, and nothing else on the page may.
    cursor_past_commit: bool,
    /// The second re-anchor reached every plane and each answered it with a
    /// page.
    re_anchored: bool,
    /// The victim's engine holds every REQ it expects.
    subscriptions_whole: bool,
    /// The sweep swept every circle and finished every window: no truncation,
    /// no deadline, no relay error.
    sweep_clean: bool,
}

impl Evidence {
    /// The burial's five conditions.
    fn burial_canaries(&self) -> usize {
        [
            self.commit_landed,
            self.lookback_waited,
            self.seed > RELAY_DEFAULT_REPLAY_CAP
                && self.seeded
                && self.newest_page_is_seed
                && self.page_served,
            self.re_anchored,
            self.sweep_clean,
        ]
        .into_iter()
        .filter(|held| *held)
        .count()
    }

    /// The control's five: the same world, a page the relay serves whole, and
    /// the live plane doing its job with it.
    fn unpacked_canaries(&self) -> usize {
        [
            self.commit_landed,
            self.lookback_waited,
            self.seed < RELAY_DEFAULT_REPLAY_CAP && self.seeded && self.window_served,
            self.applied_live && self.cursor_past_commit,
            self.subscriptions_whole,
        ]
        .into_iter()
        .filter(|held| *held)
        .count()
    }
}

/// The commit, the lookback, the seed, the two re-anchors and the sweep.
#[allow(clippy::too_many_lines)]
async fn bury<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    cast: Cast,
    seed_len: usize,
) -> Result<Evidence, RigError> {
    let Cast {
        admin,
        witness,
        victim,
    } = cast;
    let circle = world.circles().first().ok_or(RigError::ShapeMismatch)?;
    let circle_tag = circle.tag;
    let group = circle.mls_group_id().clone();
    let routing = *circle.nostr_group_id();
    let stream = group_cursor_stream(circle.group_id_hex());
    let hexes: Vec<String> = world
        .circles()
        .iter()
        .map(|circle| circle.group_id_hex().to_string())
        .collect();
    let bound = bounds::round_trip(Recovery::Undisturbed);
    let page = seed_len.min(RELAY_DEFAULT_REPLAY_CAP);
    let turnover = bounds::wall_second_turnover();

    // 1. The commit: the victim paused, the wall clock out of the second its
    //    cursor names, then a confirmed handoff the witness applies live.
    world.device_mut(victim)?.go_offline().await?;
    let cursor_before = cursor_of(world, victim, &stream)?;
    if let Some(named) = cursor_before.map(|ms| ms.div_euclid(1_000)) {
        await_condition(turnover, || async { Ok(WallNow::now().secs() > named) }).await?;
    }
    let commit = {
        let circle = world.circle(circle_tag)?;
        let (commit, verdict) = hand_off_admin(world, admin, circle, witness).await?;
        if verdict != PublishVerdict::Confirmed {
            return Err(RigError::PublishNeverAcked);
        }
        commit
    };
    let tip = epoch_of(world, admin, &group).await?;
    let witnessed = await_condition(bound, || async {
        Ok(epoch_of(world, witness, &group).await? == tip)
    })
    .await?;
    let stored_at = stored_created_at(world, &commit.id).await?;
    let commit_landed = witnessed
        && stored_at.is_some_and(|secs| cursor_before.is_none_or(|ms| secs * 1_000 > ms))
        && tip.saturating_sub(epoch_of(world, victim, &group).await?) == 1;

    // 2. The lookback, read back off the relay's own stamp.
    let lookback = Absence::ResubscribeLookback.window();
    let lookback_secs = i64::try_from(lookback.as_secs()).unwrap_or(i64::MAX);
    let lookback_waited = match stored_at {
        Some(secs) => {
            await_condition(lookback + turnover, || async {
                Ok(WallNow::now().secs() >= secs.saturating_add(lookback_secs))
            })
            .await?
        }
        None => false,
    };

    // 3. The seed, dated after the lookback and so after the commit, written
    //    into every store.
    let (forged, mut seeded) = spread_seed(routing, seed_len).await?;
    let ids: HashSet<EventId> = forged.iter().map(|event| event.id).collect();
    for plane in world.relays() {
        seeded &= plane.store(&forged).await? == forged.len();
    }
    let oldest_seed = forged.iter().map(secs_of).min().unwrap_or(i64::MAX);
    let mut newest_page_is_seed = true;
    for plane in world.relays() {
        let newest = plane
            .stored_page(group_filter(&hexes, 0).limit(RELAY_DEFAULT_REPLAY_CAP))
            .await?;
        newest_page_is_seed &=
            newest.len() == RELAY_DEFAULT_REPLAY_CAP && newest.iter().all(|e| ids.contains(&e.id));
    }

    // The first re-anchor: the page the relay chooses to serve.
    let eose_before: Vec<usize> = world
        .relays()
        .iter()
        .map(|plane| plane.ledger().eose())
        .collect();
    // Canary 1 re-read at the last instant it can hold: a victim that took the
    // commit live while it waited out the lookback was never buried, and would
    // otherwise pass for a fix of C8.
    let commit_landed =
        commit_landed && tip.saturating_sub(epoch_of(world, victim, &group).await?) == 1;
    world.device_mut(victim)?.come_online().await?;
    let page_served = await_condition(bound + bounds::subscribe_ladder(), || async {
        Ok(world
            .relays()
            .iter()
            .zip(&eose_before)
            .all(|(plane, before)| {
                plane.ledger().eose() > *before && served_to(plane, victim, &forged) >= page
            }))
    })
    .await?;
    let window_served = world.relays().iter().all(|plane| {
        plane.ledger().delivered_to(victim, &commit.id)
            && served_to(plane, victim, &forged) == forged.len()
    });
    // Only the control counts it, and only a page the relay served whole can
    // have carried the commit: a buried victim would spend the whole bound on
    // a wait no arm reads.
    let applied_live = seed_len < RELAY_DEFAULT_REPLAY_CAP
        && await_condition(bound, || async {
            Ok(epoch_of(world, victim, &group).await? == tip)
        })
        .await?;
    // Waited for, never counted: a fix that holds the cursor on a capped page
    // leaves it where it was, and that is a clean answer, not an unusable one.
    await_condition(bound, || async {
        Ok(cursor_of(world, victim, &stream)? != cursor_before)
    })
    .await?;
    let cursor_past_commit =
        cursor_of(world, victim, &stream)?.is_some_and(|ms| ms >= oldest_seed * 1_000);

    // 4. The second re-anchor: a fresh REQ on every plane, each answered.
    world.device_mut(victim)?.go_offline().await?;
    let replayed_before: Vec<usize> = world
        .relays()
        .iter()
        .map(|plane| replays(plane, &forged))
        .collect();
    world.device_mut(victim)?.come_online().await?;
    let re_anchored = await_condition(bound + bounds::subscribe_ladder(), || async {
        Ok(world
            .relays()
            .iter()
            .zip(&replayed_before)
            .all(|(plane, before)| replays(plane, &forged) >= before + page))
    })
    .await?;
    let subscriptions_whole = await_condition(bound, || async {
        let health = world.device(victim)?.engine()?.relay_health().await;
        Ok(health.subscriptions_expected > 0
            && health.subscriptions_expected == health.subscriptions_live)
    })
    .await?;

    // 5. The sweep a background wake runs, over the victim's own manager.
    let circles = world.circles().len();
    let device = world.device(victim)?;
    let swept = run_catchup_all_circles(device.manager()?, &device.relays, bound.as_secs()).await;
    let sweep_clean = swept.circles_swept == circles
        && swept.windows_truncated == 0
        && !swept.deadline_hit
        && swept.relay_errors == 0;

    Ok(Evidence {
        seed: seed_len,
        commit_landed,
        lookback_waited,
        seeded,
        newest_page_is_seed,
        page_served,
        window_served,
        applied_live,
        cursor_past_commit,
        re_anchored,
        subscriptions_whole,
        sweep_clean,
    })
}

/// The closing round, graded with the standard invariants after the second REQ
/// and the sweep: this is where a burial is GRADED. The witness leads, so the
/// victim's first probe is a receive.
async fn close<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    cast: Cast,
    tick: Duration,
    canaries: usize,
) -> Result<ArmOutcome, RigError> {
    let pairs = closing_pairs(world, cast.witness);
    let opened = [cast.victim];
    let closing = round(
        1,
        Reach::These(&pairs),
        Recovery::Undisturbed,
        tick,
        NO_GATING_ROWS,
        &opened,
        &[],
    );
    let graded = grade_round(
        world,
        &closing,
        &[
            Invariant::Quiescence,
            Invariant::LocationRoundTrip,
            Invariant::SendPathLiveness,
        ],
    )
    .await?;
    world.drain_buses();
    let observed = Observed::measure(world, canaries).await?;
    Ok(ArmOutcome {
        graded,
        observed,
        tick,
    })
}

/// Mints `count` outsider forgeries at `routing`, at most [`SEED_PER_SECOND`]
/// in any one wall second, and answers whether the spread held.
///
/// Each batch waits, bounded, for the second its newest event was minted in to
/// turn over before the next batch is minted.
async fn spread_seed(routing: [u8; 32], count: usize) -> Result<(Vec<Event>, bool), RigError> {
    let mut forged = Vec::with_capacity(count);
    let mut turned_over = true;
    while forged.len() < count {
        let batch = SEED_PER_SECOND.min(count - forged.len());
        for _ in 0..batch {
            forged.push(mint(Forgery::Unprocessable { group_id: routing }, None)?);
        }
        let newest = forged.iter().map(secs_of).max().unwrap_or(i64::MAX);
        turned_over &= await_condition(bounds::wall_second_turnover(), || async {
            Ok(WallNow::now().secs() > newest)
        })
        .await?;
    }
    let mut per_second: HashMap<i64, usize> = HashMap::new();
    for event in &forged {
        *per_second.entry(secs_of(event)).or_default() += 1;
    }
    let spread = per_second.values().all(|count| *count <= SEED_PER_SECOND);
    Ok((forged, turned_over && spread))
}

/// How many of `events` `plane` wrote towards `device`'s own endpoint.
fn served_to(plane: &SimRelay, device: DeviceTag, events: &[Event]) -> usize {
    events
        .iter()
        .filter(|event| plane.ledger().delivered_to(device, &event.id))
        .count()
}

/// Every `EVENT` frame naming one of `events` that `plane` has written, over
/// every endpoint. A seed reaches no live subscriber, so every frame is an
/// answer to a REQ that asked for it.
fn replays(plane: &SimRelay, events: &[Event]) -> usize {
    events
        .iter()
        .map(|event| plane.ledger().delivered(&event.id))
        .sum()
}

/// The `created_at` the first plane's store holds for `event_id`, if it holds
/// it in EVERY plane's store.
async fn stored_created_at<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    event_id: &EventId,
) -> Result<Option<i64>, RigError> {
    let mut stamp = None;
    for plane in world.relays() {
        let Some(event) = plane
            .stored_page(Filter::new().id(*event_id))
            .await?
            .into_iter()
            .next()
        else {
            return Ok(None);
        };
        stamp = stamp.or_else(|| Some(secs_of(&event)));
    }
    Ok(stamp)
}

/// `device`'s persisted catch-up cursor for `stream`.
fn cursor_of<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    stream: &str,
) -> Result<Option<i64>, RigError> {
    world
        .device(device)?
        .manager()?
        .read_sync_cursor(stream)
        .map_err(|_| RigError::Core(Step::ReadCursor))
}

/// One device's epoch for one circle.
async fn epoch_of<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    group: &GroupId,
) -> Result<u64, RigError> {
    world
        .device(device)?
        .manager()?
        .group_epoch(group)
        .await
        .map_err(|_| RigError::Core(Step::ReadEpoch))
}

/// An event's `created_at` in the signed seconds the cursor layer speaks.
fn secs_of(event: &Event) -> i64 {
    i64::try_from(event.created_at.as_secs()).unwrap_or(i64::MAX)
}

#[cfg(test)]
mod tests {
    use haven_core::relay::catchup::{CATCHUP_MAX_EVENTS_PER_PAGE, CATCHUP_MAX_PAGES_PER_CIRCLE};

    use super::{ARMS, PACKED_SEED, SEED_PER_SECOND, UNPACKED_SEED};
    use crate::oracle::vacuity::ExpectationFloor;
    use crate::oracle::{bounds, Recovery};
    use crate::relay::RELAY_DEFAULT_REPLAY_CAP;
    use crate::scenarios::{Absence, WithheldAcks};

    const FLOOR: ExpectationFloor = ExpectationFloor {
        faults_applied: 0,
        epochs_crossed: 1,
        deliveries_observed: 2,
        canaries_caught: 5,
    };

    #[test]
    fn both_arms_are_one_undisturbed_round_behind_a_lookback() {
        let tick = std::time::Duration::from_millis(250);
        for arm in &ARMS {
            assert!(
                arm.recovery == Recovery::Undisturbed,
                "a paused engine closes no socket, so the pool's ladder is not in the path"
            );
            assert!(arm.probe_rounds == 1, "one closing round");
            assert!(arm.resubscribes, "the victim re-opens its own REQs");
            assert!(
                arm.absence == Absence::ResubscribeLookback,
                "the lookback is waited out, and priced"
            );
            assert!(
                arm.withheld_acks == WithheldAcks::None,
                "the commit is acknowledged and the seed is stored, never published"
            );
            assert!(
                arm.deadline(tick, &crate::scenarios::MINIMAL_SHAPE)
                    == bounds::quiescence(Recovery::Undisturbed, tick)
                        + bounds::subscribe_ladder()
                        + bounds::round_trip(Recovery::Undisturbed)
                        + bounds::resubscribe_lookback(),
                "quiescence, the subscribe ladder, one round trip and the lookback"
            );
        }
    }

    #[test]
    fn the_floors_are_pinned_beside_their_labels() {
        for (arm, label) in ARMS.iter().zip(["buried-past-the-cap", "unpacked-control"]) {
            assert!(
                arm.label == label,
                "the arms, in the order the docs list them"
            );
            assert!(
                arm.floor == FLOOR,
                "each arm's floor, pinned beside its label"
            );
        }
    }

    #[test]
    fn the_packed_seed_outgrows_the_relays_page_and_not_the_sweeps_budget() {
        const {
            assert!(
                PACKED_SEED > RELAY_DEFAULT_REPLAY_CAP,
                "a seed the relay serves whole buries nothing"
            );
            assert!(
                PACKED_SEED < CATCHUP_MAX_EVENTS_PER_PAGE * CATCHUP_MAX_PAGES_PER_CIRCLE,
                "the sweep must be able to finish the window, or its clean pass is not a \
                 condition the burial can rely on"
            );
            assert!(
                UNPACKED_SEED + 1 < RELAY_DEFAULT_REPLAY_CAP,
                "the control's seed and its commit fit one page"
            );
            assert!(
                SEED_PER_SECOND >= 1 && SEED_PER_SECOND * 2 <= CATCHUP_MAX_EVENTS_PER_PAGE,
                "a page bounded at a seed second must carry that second and room below it"
            );
        }
    }
}
