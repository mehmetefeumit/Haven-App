//! **S20** — the catch-up sweep against a relay that clamps its pages, refuses
//! one, answers late or serves a forged one, and the cursor that must neither
//! jump over a backlog nor freeze in front of it.
//!
//! RLY-05 was five defects in one function, and every one of them was a way for
//! `run_catchup_all_circles` to decide a window was finished when it was not —
//! or to decide it could never be. Each arm below rebuilds one of them against a
//! real relay double and requires the product's answer:
//!
//! | sub-defect | what it was | where it is asserted |
//! |---|---|---|
//! | (a) | an empty page from a relay still being drained read as an empty range | `refused-page`: the relay that served page one refuses page two; the circle holds its cursor, and the next sweep finishes the chase |
//! | (b) | a page of future-dated 445s, mintable by any observer of the public `#h`, froze the cursor | `future-dated-page`: a whole page of rewraps dated a day ahead sits in the store; none is served, and the cursor lands on the sweep's own open time |
//! | (c) | the page size was read as "the relay had more", so a relay clamping below the requested `limit` ended every chase at its first page | `clamped-limit`: every page is clamped below `CATCHUP_MAX_EVENTS_PER_PAGE`, so no page can ever look full; the chase goes on regardless and holds the cursor, and the next sweep advances |
//! | (d) | an inclusive/exclusive off-by-one froze a window whose content sat on its own ceiling | `clamped-limit`'s second sweep: the resumed backfill's band is ONE event, dated exactly on that band's ceiling — `since` is `>=` and `until` is `<=` in `nostr`'s filter, so a pager treating either as exclusive never descends and the circle freezes for good |
//! | (e) | a relay that missed page one on a cold connect was marked silent, and its answer to page two then read as a contradiction | `cold-first-connect`: the second plane refuses the sweep's first connection and answers every later page; every circle still advances in that one sweep |
//!
//! `healthy-drain` is the control: the same backlog `clamped-limit` walks down
//! over two sweeps drains in ONE when nothing is wrong, so "it never drains"
//! cannot pass and the clamp is what held the other arm. The fix's cross-relay
//! property — the next `until` is the MAXIMUM across truncating relays, so one
//! poisoned relay cannot cut the others' chase short — is pinned where it can
//! be driven exactly, `catchup.rs`'s
//! `the_boundary_is_the_maximum_across_truncating_relays`.
//!
//! # The backlog, and why the sweep is its only way in
//!
//! Every event the arms seed is a GENUINE kind-445: a location a member sealed
//! earlier in the arm, never published, written straight into every plane's
//! store with `SimRelay::store`. A seed reaches no live subscriber, and the live
//! engines' REQs are past their `EOSE` and never re-issued — nothing here
//! disturbs a socket — so every backlog event the sweeping device ever holds
//! arrived through `run_catchup_all_circles`. One event per circle per wall
//! second: a clamped page must carry its boundary second's event again plus
//! something below it, or the chase has nothing to descend to, and the arms
//! read a circle's oldest and newest event as "the bottom of page one" and "the
//! top of it".
//!
//! # Undisturbed, although the instinct is `Reconnect`
//!
//! The sweep is harness-driven, with the `max_duration_secs` the harness
//! injects (one undisturbed round trip), and it runs on the device's own
//! `RelayManager`, not on the live-sync pool. No arm closes a live socket — even
//! `cold-first-connect`'s refused connection is one the SWEEP opens — so the
//! pool's reconnect ladder is never in the path and pricing it would buy a wait
//! nothing takes.
//!
//! # Relay-global by construction, and what that costs an arm
//!
//! `run_catchup_all_circles` reads each circle's relays out of storage, which
//! holds the planes' CANONICAL endpoints, so every fault here reaches every
//! device's sweep and there is no per-device arm to write. It also sweeps every
//! circle, one after another, in an order the product chooses (most recently
//! updated first), over one connection per relay — and a single-shot fault
//! (the refused page, the refused connection) lands on whichever circle comes
//! first. So every circle is seeded identically, every canary is read over every
//! circle, and the one circle a single-shot fault met is found from the
//! evidence rather than assumed.
//!
//! # Cursor provenance
//!
//! `CatchupOutcome::cursors_advanced` counts a write that returned `Ok`, and the
//! write is a monotonic max that returns `Ok` while changing nothing. So an
//! advance is asserted on the VALUE read back with `read_sync_cursor`: strictly
//! above what it was, and inside a closed bracket of two readings of the wall
//! clock the sweep opens its window with — its provenance, which no event's
//! `created_at` can satisfy. A hold is bounded from ABOVE by the oldest backlog
//! event, the one direction a remote timestamp may appear in. `CatchupOutcome`
//! is otherwise read only where it is the thing described — a relay that did
//! not finish answering, a window held, a deadline — and as `healthy-drain`'s
//! one-pass tally (every circle swept, every event applied, a write per
//! circle), which the control needs beside the values read back.
//!
//! # What is not asserted
//!
//! The `since` edge of (d). A sweep's floor is its cursor less a re-verification
//! buffer, never an event's second, so no genuine event can be placed on it —
//! the one inclusive edge a harness can land an event on exactly is a band's
//! ceiling, and that is what the backfill's one-event band does.

use std::time::Duration;

use haven_core::location::LOCATION_MESSAGE_RETENTION_SECS;
use haven_core::relay::catchup::{
    run_catchup_all_circles, CatchupOutcome, CATCHUP_MAX_EVENTS_PER_PAGE,
    CATCHUP_MAX_PAGES_PER_CIRCLE,
};
use haven_core::relay::live_sync::group_cursor_stream;
use nostr::Event;
use tokio::time::Instant;

use crate::clock::WallNow;
use crate::nemesis::types::{Fault, RigCount};
use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{bounds, Invariant, ProbeToken, Reach, Recovery};
use crate::relay::{mint, Forgery};
use crate::rig::{DeviceTag, LogDrain, RelayPlane, RigError, Step, TimelineSink};
use crate::scenarios::{
    await_condition, closing_pairs, grade_round, round, Absence, Arm, ArmOutcome, Scenario,
    ScenarioReport, ScenarioWorld, WithheldAcks, NO_GATING_ROWS,
};

/// The most events a clamped page carries.
///
/// Two, a literal of this arm's own and the smallest a chase can descend
/// through at one event per second: a page bounded by the previous boundary
/// carries that boundary's event again, and needs one more below it to move.
/// Strictly below `CATCHUP_MAX_EVENTS_PER_PAGE` by construction, which is the
/// whole of sub-defect (c): no clamped page can ever satisfy
/// `page.len() >= CATCHUP_MAX_EVENTS_PER_PAGE`, so a chase kept alive by page
/// size alone would end at the first one.
const CLAMP: usize = 2;

/// The backlog `clamped-limit` and its control seed into each circle.
///
/// Derived from the product's page budget rather than chosen: page one carries
/// `CLAMP` new events and every later page `CLAMP - 1`, so this many are all
/// fetched by the budget's second-to-last page and the LAST page is the
/// confirming step that finds nothing new. The sweep has then applied the whole
/// backlog and still cannot claim the window — the budget ran out before the
/// confirmation did — so it holds, persists that last request as the backfill
/// floor, and the next sweep's backfill starts on a band holding exactly one
/// event, dated on the band's own ceiling.
const CLAMPED_BACKLOG: usize = CLAMP + (CATCHUP_MAX_PAGES_PER_CIRCLE - 2) * (CLAMP - 1);

/// The backlog the other three arms seed into each circle: two seconds, the
/// least in which a circle's newest event is not also its oldest.
const SHORT_BACKLOG: usize = 2;

/// The page a relay refuses in `refused-page`: the second REQ its connection
/// carries after the arming.
///
/// The first page of the first circle swept is answered, so the relay has
/// CONTRIBUTED and the pager is still draining it; the second is the one whose
/// empty answer the old rule read as "nothing below".
const REFUSED_PAGE: usize = 2;

/// How far ahead of their source the forged page is dated.
///
/// A day, as S09's rewrap: far beyond any clock skew, so a cursor that took
/// the number would sit a day above every reading of the local clock.
const FORGED_AHEAD_SECS: i64 = 86_400;

/// The probe round the backlog's payloads are minted under. Any value; the
/// closing round's probes are the oracle's own.
const BACKLOG_ROUND: u32 = 20;

/// The arms this scenario offers.
pub const ARMS: [Arm; 5] = [
    Arm {
        label: "healthy-drain",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: false,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            faults_applied: 0,
            epochs_crossed: 0,
            deliveries_observed: 1,
            canaries_caught: 2,
        },
    },
    Arm {
        label: "clamped-limit",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: false,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            faults_applied: 1,
            epochs_crossed: 0,
            deliveries_observed: 1,
            canaries_caught: 3,
        },
    },
    Arm {
        label: "refused-page",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: false,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            faults_applied: 1,
            epochs_crossed: 0,
            deliveries_observed: 1,
            canaries_caught: 3,
        },
    },
    Arm {
        label: "cold-first-connect",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: false,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            faults_applied: 1,
            epochs_crossed: 0,
            deliveries_observed: 1,
            canaries_caught: 2,
        },
    },
    Arm {
        label: "future-dated-page",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: false,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            // The forged page is WRITTEN, as a relay that accepted it would
            // hold it, and a store is not a plane fault: nothing is armed on
            // any endpoint. Canary 1 is what proves the page was really there.
            faults_applied: 0,
            epochs_crossed: 0,
            deliveries_observed: 1,
            canaries_caught: 3,
        },
    },
];

/// Runs one arm.
///
/// # Errors
///
/// [`RigError::UnknownTarget`] if the label is not one this scenario offers,
/// [`RigError::ShapeMismatch`] if the world has fewer than two devices, or —
/// for `cold-first-connect` — fewer than two relay planes, since a relay that
/// missed page one can only be contradicted by a page some OTHER relay made
/// necessary; [`RigError::Core`] if the backlog could not be minted or stored,
/// otherwise [`RigError`] naming the step that failed.
pub(crate) async fn run<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    arm: &Arm,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    let sweeper = sweeper(world)?;
    let canaries = match arm.label {
        "healthy-drain" => healthy(world, sweeper, CLAMPED_BACKLOG).await?,
        "clamped-limit" => clamped(world, sweeper).await?,
        "refused-page" => refused(world, sweeper).await?,
        "cold-first-connect" => cold(world, sweeper).await?,
        "future-dated-page" => future_dated(world, sweeper).await?,
        _ => return Err(RigError::UnknownTarget),
    };
    close(world, sweeper, tick, canaries).await
}

/// `healthy-drain` over an EMPTY store.
///
/// No backlog, so the sweep drains vacuously and the drain canary has nothing
/// to have drained. The mis-configuration control in `tests/oracles.rs` runs it
/// and requires rc 3.
///
/// # Errors
///
/// As [`run`].
pub async fn empty_store_control<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    tick: Duration,
) -> Result<ScenarioReport, RigError> {
    let started = Instant::now();
    let sweeper = sweeper(world)?;
    let canaries = healthy(world, sweeper, 0).await?;
    let outcome = close(world, sweeper, tick, canaries).await?;
    Ok(Scenario::CatchupSweep.report(world, &ARMS[0], outcome, started))
}

/// The device whose catch-up sweep every arm drives. The others are the
/// backlog's senders.
fn sweeper<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
) -> Result<DeviceTag, RigError> {
    world
        .devices()
        .get(1)
        .map(|device| device.tag)
        .ok_or(RigError::ShapeMismatch)
}

/// Heals every plane and runs the closing round, with the sweeping device
/// sending first: it is the one whose catch-up state every arm moved.
async fn close<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    sweeper: DeviceTag,
    tick: Duration,
    canaries: usize,
) -> Result<ArmOutcome, RigError> {
    for plane in world.relays_mut() {
        plane.apply(Fault::Heal).await?;
    }
    let pairs = closing_pairs(world, sweeper);
    let closing = round(
        1,
        Reach::These(&pairs),
        Recovery::Undisturbed,
        tick,
        NO_GATING_ROWS,
        &[],
        &[],
    );
    let graded = grade_round(
        world,
        &closing,
        &[Invariant::Quiescence, Invariant::LocationRoundTrip],
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

/// The control: the backlog drains in ONE pass, and every cursor lands on the
/// sweep's own open time.
async fn healthy<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    sweeper: DeviceTag,
    per_circle: usize,
) -> Result<usize, RigError> {
    let backlog = seed(world, sweeper, per_circle).await?;
    let seeded: usize = backlog.iter().map(Vec::len).sum();
    let circles = world.circles().len();
    let swept = sweep(world, sweeper).await?;
    let out = swept.outcome;

    let mut canaries = 0_usize;
    // 1. One pass, every circle, every event, nothing held and nothing lost —
    //    over a backlog that exists, or "it drained" is a sweep over nothing.
    if seeded > 0
        && out.circles_swept == circles
        && out.events_applied == seeded
        && out.cursors_advanced == circles
        && !out.deadline_hit
        && out.relay_errors == 0
        && all_served(world, &backlog)
    {
        canaries += 1;
    }
    // 2. …and each advance is the sweep's own open time, read back.
    if (0..circles).all(|circle| swept.landed(circle)) {
        canaries += 1;
    }
    Ok(canaries)
}

/// (c) and (d): a clamp below the page size, a backlog past one sweep's page
/// budget, and a walk-down the second sweep composes.
async fn clamped<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    sweeper: DeviceTag,
) -> Result<usize, RigError> {
    let backlog = seed(world, sweeper, CLAMPED_BACKLOG).await?;
    let circles = world.circles().len();
    for plane in world.relays_mut() {
        plane.apply(Fault::ClampLimit(RigCount::new(CLAMP))).await?;
    }
    let first = sweep(world, sweeper).await?;
    let past_the_first_page = backlog
        .iter()
        .all(|events| events.iter().filter(|event| served(world, event)).count() > CLAMP);
    let second = sweep(world, sweeper).await?;

    let mut canaries = 0_usize;
    // 1. Saturation was reachable: every circle holds strictly more than one
    //    clamped page. Without it the clamp cuts nothing and the arm is a
    //    healthy drain wearing its label.
    if backlog.iter().all(|events| events.len() > CLAMP) {
        canaries += 1;
    }
    // 2. The chase went on past pages that could never look full, and the
    //    window it could not finish inside the page budget was HELD — never
    //    advanced over. The tally is the thing described: every window held,
    //    and none of them by the deadline.
    if past_the_first_page
        && (0..circles).all(|circle| first.held(circle, &backlog[circle]))
        && first.outcome.windows_truncated == circles
        && !first.outcome.deadline_hit
    {
        canaries += 1;
    }
    // 3. The next sweep resumes the descent at the floor the first one left
    //    — a band of one event, on its own ceiling — composes it with its own
    //    top-down pass, and advances every circle to its own open time.
    if (0..circles).all(|circle| second.landed(circle)) && all_served(world, &backlog) {
        canaries += 1;
    }
    Ok(canaries)
}

/// (a): the relay that served page one refuses page two.
async fn refused<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    sweeper: DeviceTag,
) -> Result<usize, RigError> {
    let backlog = seed(world, sweeper, SHORT_BACKLOG).await?;
    let circles = world.circles().len();
    let refusals = |world: &ScenarioWorld<T, L>| {
        world
            .relays()
            .first()
            .map_or(0, |plane| plane.ledger().closed_messages().len())
    };
    let before = refusals(world);
    world
        .relays_mut()
        .first_mut()
        .ok_or(RigError::ShapeMismatch)?
        .apply(Fault::RefusePage {
            nth: RigCount::new(REFUSED_PAGE),
        })
        .await?;
    let first = sweep(world, sweeper).await?;
    let refused_once = refusals(world) == before + 1;
    world
        .relays_mut()
        .first_mut()
        .ok_or(RigError::ShapeMismatch)?
        .apply(Fault::Heal)
        .await?;
    let second = sweep(world, sweeper).await?;
    let held: Vec<usize> = (0..circles)
        .filter(|circle| first.held(*circle, &backlog[*circle]))
        .collect();

    let mut canaries = 0_usize;
    // 1. Exactly one page was refused, and the sweep tallied the read as a
    //    relay that did not finish answering.
    if refused_once && first.outcome.relay_errors >= 1 {
        canaries += 1;
    }
    // 2. The refused page did not end the chase as complete: its circle held
    //    — and only its circle, so the hold is the refusal's and not a world
    //    that never advanced anything.
    if held.len() == 1
        && (0..circles)
            .filter(|circle| !held.contains(circle))
            .all(|circle| first.landed(circle))
        && first.outcome.windows_truncated == 1
    {
        canaries += 1;
    }
    // 3. …and the chase it interrupted is finished by the next sweep.
    if held.len() == 1 && second.landed(held[0]) {
        canaries += 1;
    }
    Ok(canaries)
}

/// (e): the second plane refuses the sweep's first connection.
async fn cold<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    sweeper: DeviceTag,
) -> Result<usize, RigError> {
    if world.relays().len() < 2 {
        return Err(RigError::ShapeMismatch);
    }
    let backlog = seed(world, sweeper, SHORT_BACKLOG).await?;
    let circles = world.circles().len();
    world.relays_mut()[1].apply(Fault::ColdFirstConnect).await?;
    let swept = sweep(world, sweeper).await?;
    let cold_plane = world.relays()[1].ledger();
    // The circle the refused connection met: the cold plane never served its
    // newest event, which only page one asked for, and did serve its oldest,
    // which the next page asked for again.
    let answered_late = backlog.iter().any(|events| {
        events
            .last()
            .is_some_and(|newest| cold_plane.delivered(&newest.id) == 0)
            && events
                .first()
                .is_some_and(|oldest| cold_plane.delivered(&oldest.id) > 0)
    });

    let mut canaries = 0_usize;
    // 1. One connection was refused, the sweep tallied the relay that did not
    //    answer, and that relay then answered a later page of the same chase —
    //    the shape the old rule read as a contradiction.
    if cold_plane.refused_connects() == 1 && swept.outcome.relay_errors >= 1 && answered_late {
        canaries += 1;
    }
    // 2. Not marked silent, and no poisoned floor under the next page: every
    //    circle drained and advanced to its own open time in this one sweep.
    if (0..circles).all(|circle| swept.landed(circle)) && all_served(world, &backlog) {
        canaries += 1;
    }
    Ok(canaries)
}

/// (b): a whole page of rewraps dated a day ahead, in every circle's store.
async fn future_dated<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    sweeper: DeviceTag,
) -> Result<usize, RigError> {
    let backlog = seed(world, sweeper, SHORT_BACKLOG).await?;
    let circles = world.circles().len();
    let mut forged = Vec::with_capacity(CATCHUP_MAX_EVENTS_PER_PAGE * circles);
    for events in &backlog {
        let source = events.last().ok_or(RigError::ShapeMismatch)?;
        for _ in 0..CATCHUP_MAX_EVENTS_PER_PAGE {
            forged.push(mint(
                Forgery::Rewrap {
                    source: source.id,
                    offset_secs: FORGED_AHEAD_SECS,
                },
                Some(source),
            )?);
        }
    }
    let mut stored_everywhere = true;
    for plane in world.relays() {
        stored_everywhere &= plane.store(&forged).await? == forged.len();
    }
    let swept = sweep(world, sweeper).await?;

    let mut canaries = 0_usize;
    // 1. The page was there: every plane took a whole page of forgeries per
    //    circle, each dated after the sweep's window had already closed.
    if stored_everywhere && forged.iter().all(|event| secs_of(event) > swept.closed) {
        canaries += 1;
    }
    // 2. None of it was served: every page's upper bound is the window's own
    //    open time.
    if !forged.iter().any(|event| served(world, event)) {
        canaries += 1;
    }
    // 3. Neither frozen nor moved: every circle advanced to the sweep's own
    //    open time — never held, and never to the forged instant a day on.
    if (0..circles).all(|circle| swept.landed(circle)) && all_served(world, &backlog) {
        canaries += 1;
    }
    Ok(canaries)
}

/// Seals `per_circle` locations into every circle, one per circle per wall
/// second, from every device but `sweeper` in turn, and writes them into every
/// plane's store. Returned per circle, oldest first.
///
/// None of them in the second a cursor already names. The sweep counts
/// everything at or below its cursor as retrieved — that is the claim the
/// cursor makes — so a backlog starting in that second would let a halted
/// chase meet the cursor and advance, and no arm could tell a hold from a
/// backlog the cursor had already claimed.
///
/// The senders rotate so no one sender's run of messages outgrows the ratchet's
/// out-of-order window: a descending chase hands the engine each page newest
/// first.
async fn seed<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    sweeper: DeviceTag,
    per_circle: usize,
) -> Result<Vec<Vec<Event>>, RigError> {
    let senders: Vec<DeviceTag> = world
        .devices()
        .iter()
        .map(|device| device.tag)
        .filter(|tag| *tag != sweeper)
        .collect();
    if senders.is_empty() {
        return Err(RigError::ShapeMismatch);
    }
    leave_the_named_second(world, sweeper).await?;
    let mut backlog: Vec<Vec<Event>> = vec![Vec::with_capacity(per_circle); world.circles().len()];
    for index in 0..per_circle {
        let mut newest = i64::MIN;
        for (circle, events) in backlog.iter_mut().enumerate() {
            let event = seal(
                world,
                senders[(index + circle) % senders.len()],
                circle,
                index,
            )
            .await?;
            newest = newest.max(secs_of(&event));
            events.push(event);
        }
        // The next second, before the next event of any circle: two events of
        // one circle in one second would put two on a clamped page's boundary.
        if index + 1 < per_circle
            && !await_condition(bounds::round_trip(Recovery::Undisturbed), || async {
                Ok(WallNow::now().secs() > newest)
            })
            .await?
        {
            return Err(RigError::Core(Step::Publish));
        }
    }
    let all: Vec<Event> = backlog.iter().flatten().cloned().collect();
    for plane in world.relays() {
        if plane.store(&all).await? != all.len() {
            // A seed that did not land is a backlog that is not there.
            return Err(RigError::Core(Step::ApplyFault));
        }
    }
    Ok(backlog)
}

/// Seals one location from `sender` into the world's `circle`-th circle,
/// unpublished.
async fn seal<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    sender: DeviceTag,
    circle: usize,
    index: usize,
) -> Result<Event, RigError> {
    let group = world
        .circles()
        .get(circle)
        .ok_or(RigError::ShapeMismatch)?
        .mls_group_id()
        .clone();
    let device = world.device(sender)?;
    let token = ProbeToken::mint(BACKLOG_ROUND, u32::try_from(index).unwrap_or(u32::MAX));
    device
        .manager()?
        .encrypt_location(
            &group,
            &device.keys.public_key(),
            &token.as_location(),
            LOCATION_MESSAGE_RETENTION_SECS,
        )
        .await
        .map(|(event, _, _)| event)
        .map_err(|_| RigError::Core(Step::Publish))
}

/// One sweep, with the cursors either side of it and the wall-clock bracket
/// its windows were opened inside.
struct Sweep {
    outcome: CatchupOutcome,
    opened: i64,
    closed: i64,
    before: Vec<Option<i64>>,
    after: Vec<Option<i64>>,
}

impl Sweep {
    /// Whether the `circle`-th circle's cursor moved strictly up, to an instant
    /// inside the sweep's own bracket.
    fn landed(&self, circle: usize) -> bool {
        let (Some(before), Some(Some(after))) = (self.before.get(circle), self.after.get(circle))
        else {
            return false;
        };
        before.is_none_or(|before| *after > before)
            && *after >= self.opened.saturating_mul(1_000)
            && *after <= self.closed.saturating_mul(1_000)
    }

    /// Whether the `circle`-th circle's cursor did not move, and sits at or
    /// below the oldest event of its `backlog`.
    fn held(&self, circle: usize, backlog: &[Event]) -> bool {
        let (Some(before), Some(after), Some(oldest)) = (
            self.before.get(circle),
            self.after.get(circle),
            backlog.first(),
        ) else {
            return false;
        };
        before == after && after.is_none_or(|after| after <= secs_of(oldest).saturating_mul(1_000))
    }
}

/// Runs one catch-up sweep on `sweeper`, the way a background wake does.
///
/// Opened only once the wall clock has left the second any cursor already
/// names: the write is a monotonic max, so a sweep opened inside that second
/// cannot move it, and "it advanced" would turn on where the run fell against
/// a second boundary.
async fn sweep<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    sweeper: DeviceTag,
) -> Result<Sweep, RigError> {
    leave_the_named_second(world, sweeper).await?;
    let before = cursors(world, sweeper)?;
    let device = world.device(sweeper)?;
    let opened = WallNow::now().secs();
    let outcome = run_catchup_all_circles(
        device.manager()?,
        &device.relays,
        bounds::round_trip(Recovery::Undisturbed).as_secs(),
    )
    .await;
    let closed = WallNow::now().secs();
    let after = cursors(world, sweeper)?;
    Ok(Sweep {
        outcome,
        opened,
        closed,
        before,
        after,
    })
}

/// Waits, bounded, for the wall clock to pass the latest second any of
/// `device`'s cursors names.
async fn leave_the_named_second<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
) -> Result<(), RigError> {
    let Some(named) = cursors(world, device)?
        .into_iter()
        .flatten()
        .map(|ms| ms.div_euclid(1_000))
        .max()
    else {
        return Ok(());
    };
    if await_condition(bounds::round_trip(Recovery::Undisturbed), || async {
        Ok(WallNow::now().secs() > named)
    })
    .await?
    {
        Ok(())
    } else {
        Err(RigError::Core(Step::ReadCursor))
    }
}

/// Every circle's persisted catch-up cursor on `device`, in world order.
fn cursors<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
) -> Result<Vec<Option<i64>>, RigError> {
    let manager = world.device(device)?.manager()?;
    world
        .circles()
        .iter()
        .map(|circle| {
            manager
                .read_sync_cursor(&group_cursor_stream(circle.group_id_hex()))
                .map_err(|_| RigError::Core(Step::ReadCursor))
        })
        .collect()
}

/// Whether any plane wrote `event` towards a client. A stored event reaches no
/// live subscription, so the only reader it can have been written to is a sweep.
fn served<T: TimelineSink, L: LogDrain>(world: &ScenarioWorld<T, L>, event: &Event) -> bool {
    world
        .relays()
        .iter()
        .any(|plane| plane.ledger().delivered(&event.id) > 0)
}

/// Whether every event of `backlog` reached a sweep.
fn all_served<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    backlog: &[Vec<Event>],
) -> bool {
    backlog.iter().flatten().all(|event| served(world, event))
}

/// An event's `created_at` in the signed seconds the cursor layer speaks.
fn secs_of(event: &Event) -> i64 {
    i64::try_from(event.created_at.as_secs()).unwrap_or(i64::MAX)
}

#[cfg(test)]
mod tests {
    use haven_core::relay::catchup::CATCHUP_MAX_EVENTS_PER_PAGE;

    use super::{ARMS, CLAMP, CLAMPED_BACKLOG, SHORT_BACKLOG};
    use crate::oracle::vacuity::ExpectationFloor;
    use crate::oracle::Recovery;
    use crate::scenarios::{Absence, WithheldAcks};

    const fn floor(faults: usize, canaries: usize) -> ExpectationFloor {
        ExpectationFloor {
            faults_applied: faults,
            epochs_crossed: 0,
            deliveries_observed: 1,
            canaries_caught: canaries,
        }
    }

    #[test]
    fn every_arm_is_one_undisturbed_round_and_nothing_else() {
        for arm in &ARMS {
            assert!(
                arm.recovery == Recovery::Undisturbed,
                "the sweep is harness-driven and no live socket is closed"
            );
            assert!(arm.probe_rounds == 1, "one closing round");
            assert!(!arm.resubscribes, "no live REQ is re-issued");
            assert!(arm.absence == Absence::None, "nothing is waited out");
            assert!(
                arm.withheld_acks == WithheldAcks::None,
                "the backlog is stored, never published"
            );
        }
    }

    #[test]
    fn the_floors_are_the_five_sub_defects_and_their_control() {
        let expected = [
            ("healthy-drain", floor(0, 2)),
            ("clamped-limit", floor(1, 3)),
            ("refused-page", floor(1, 3)),
            ("cold-first-connect", floor(1, 2)),
            ("future-dated-page", floor(0, 3)),
        ];
        for (arm, (label, floor)) in ARMS.iter().zip(expected) {
            assert!(
                arm.label == label,
                "the arms, in the order the table lists them"
            );
            assert!(
                arm.floor == floor,
                "each arm's floor, pinned beside its label"
            );
        }
    }

    #[test]
    fn no_clamped_page_can_look_full_and_the_backlog_outgrows_one_sweep() {
        const {
            assert!(
                CLAMP >= 2 && CLAMP < CATCHUP_MAX_EVENTS_PER_PAGE,
                "a clamp the chase can descend through, and below the page size"
            );
            assert!(
                CLAMPED_BACKLOG > CLAMP,
                "a backlog one clamped page could hold never saturates"
            );
            assert!(
                SHORT_BACKLOG >= 2,
                "a circle's newest event must not also be its oldest"
            );
        }
    }
}
