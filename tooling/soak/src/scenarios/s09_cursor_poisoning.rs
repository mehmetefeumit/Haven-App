//! **S09** — an adversary who forges all run long, and the two anchors that
//! never take a number from it.
//!
//! A circle's `nostr_group_id` is the `#h` of every one of its kind-445s, so it
//! is public to anyone who watches a relay. Anyone who has seen one can put an
//! event at that routing id on the wire: expired, malformed, undecodable, or an
//! observed ciphertext re-signed under a throwaway key at a `created_at` of
//! their choosing. The promise both receive planes make is that NONE of that
//! moves a cursor: each plane anchors on a LOCAL clock reading taken when its
//! observation window opened and redeems that anchor only once the window is
//! known complete, and event timestamps survive in one direction only — an
//! event that could not be APPLIED holds the anchor at or below itself.
//!
//! # The matched pair is the control, and it is not optional
//!
//! An arm that only asserted "no cursor moved" would pass on a build where
//! cursor advance had been deleted altogether. So every round that injects also
//! delivers a legitimate fix, and the arm closes by requiring the catch-up
//! plane to advance on its own trusted signal — strictly, and inside the local
//! window the sweep itself opened. That pairing is
//! `haven-core/tests/cursor_poisoning_e2e.rs`'s own discipline, and the reason
//! it is written here as one boolean per round rather than as two arms.
//!
//! # Where the evidence for each half comes from
//!
//! The WIRE half is the plane's ledger, never the client: a conformant
//! `nostr_sdk` drops an already-expired event before it emits any notification,
//! so for one of the three recipes there is nothing a subscriber could report.
//! What the plane records is that the forged frame was written towards a
//! subscribed client — and an injection no open subscription matched is refused
//! as a fault that did not fire, which is this arm's anti-vacuity floor.
//!
//! The CLASSIFICATION half is `EngineProcessor::process_group_event`, handed an
//! equivalent forgery this module minted from the same recipe. The recipe is the
//! subject: the plane's copy proves a forgery of that shape really crosses a
//! socket to a subscriber, and the processor's copy says what the product makes
//! of one. They are two events because a plane mints its own — an injected event
//! is never stored, so there is no third place to read one back from.
//!
//! # What the catch-up half can and cannot be
//!
//! The relay double is NIP-40-conformant: it refuses to store an expired event
//! and filters expired events out of every query, so the catch-up plane can
//! never be handed the expired case end to end. That is the screen's own premise
//! — only a malicious or non-conformant relay replays past a TTL — and it is why
//! every forgery here is injected live rather than seeded. What the catch-up
//! plane IS graded on is its advance's PROVENANCE: the sweep's own open time,
//! bracketed by two readings of the same wall clock the sweep uses, and never
//! any event's `created_at`.

use std::time::Duration;

use haven_core::location::LOCATION_MESSAGE_RETENTION_SECS;
use haven_core::nostr::mls::types::GroupId;
use haven_core::relay::catchup::run_catchup_all_circles;
use haven_core::relay::live_sync::{group_cursor_stream, GroupProcessOutcome};
use nostr::{Event, EventId};

use crate::clock::WallNow;
use crate::nemesis::types::Fault;
use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{bounds, Invariant, ProbeToken, Reach, Recovery};
use crate::relay::{mint, Forgery};
use crate::rig::{
    CircleTag, DeviceTag, LogDrain, RelayPlane, RelayTag, RigError, Step, TimelineSink,
};
use crate::scenarios::{
    await_condition, chain_pairs, closing_pairs, deliveries_for, grade_round, round, Absence, Arm,
    ArmOutcome, ScenarioWorld, WithheldAcks, NO_GATING_ROWS,
};

/// How many times the standing adversary cycles its three recipes.
///
/// Four, a literal of this arm's own: one round makes "the anchor did not move"
/// a point, and the claim is that it is a SEQUENCE — an adversary who keeps
/// forging for the whole arm buys nothing by repetition. Four is the smallest
/// count that says so and the largest that costs nothing measurable.
const CYCLES: usize = 4;

/// How many recipes one cycle injects.
///
/// Three: an already-expired kind-445, an envelope carrying two `#h` tags, and
/// one whose content no decoder accepts. Every one of them is mintable from a
/// circle's PUBLIC routing id and a key belonging to nobody, which is the whole
/// adversary this scenario is written against — and they are three rather than
/// one because they are refused in three different places, on two sides of the
/// authentication boundary.
const RECIPES_PER_CYCLE: usize = 3;

/// How far ahead of its source a rewrap is dated.
///
/// One day, a literal of this arm's own and deliberately far beyond any
/// plausible clock skew: an anchor that took this number would be a day ahead of
/// every reading of the local clock, which is what makes the provenance
/// assertion below a bound with a day of margin rather than a second-boundary
/// race.
const REWRAP_AHEAD_SECS: i64 = 86_400;

/// How often a bounded wait for a delivery re-reads a device's ledger. A
/// harness cadence; no expectation is derived from it.
const DELIVERY_POLL: Duration = Duration::from_millis(20);

/// The arms this scenario offers.
pub const ARMS: [Arm; 2] = [
    Arm {
        label: "standing-adversary",
        recovery: Recovery::Undisturbed,
        probe_rounds: 2,
        // Nothing re-opens a subscription: an injection rides the REQ the
        // engine already holds, and a resubscribe would re-anchor the very
        // cursor the arm is watching.
        resubscribes: false,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            // One cycle's three injections, as a minimum: the arm fires
            // `3 × CYCLES` and canary 1 is what holds it to the whole sequence.
            faults_applied: 3,
            // Nothing here commits: a forgery that advanced an epoch would be a
            // forgery that authenticated.
            epochs_crossed: 0,
            deliveries_observed: 2,
            canaries_caught: 6,
        },
    },
    Arm {
        label: "rewrap-created-at-binding",
        recovery: Recovery::Undisturbed,
        probe_rounds: 2,
        resubscribes: false,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            faults_applied: 1,
            epochs_crossed: 0,
            deliveries_observed: 2,
            canaries_caught: 2,
        },
    },
];

/// Runs one arm.
///
/// # Errors
///
/// [`RigError::UnknownTarget`] if the label is not one this scenario offers,
/// [`RigError::ShapeMismatch`] if the world has fewer than two devices or no
/// circle, [`RigError::Core`] with [`Step::ApplyFault`] if a forgery reached no
/// subscribed client — an injection nobody received did not happen — otherwise
/// [`RigError`] naming the step that failed.
pub(crate) async fn run<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    arm: &Arm,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    let tags: Vec<DeviceTag> = world.devices().iter().map(|device| device.tag).collect();
    let [publisher, victim, ..] = *tags.as_slice() else {
        return Err(RigError::ShapeMismatch);
    };
    let circle_tag = world.circles().first().ok_or(RigError::ShapeMismatch)?.tag;
    let plane = world
        .relays()
        .first()
        .map(RelayPlane::tag)
        .ok_or(RigError::ShapeMismatch)?;

    // The control round: the world delivers before the adversary starts, so a
    // closing round that fails is a failure of the forgeries rather than of a
    // world that never worked.
    let opening_pairs = chain_pairs(world);
    let opening = round(
        1,
        Reach::These(&opening_pairs),
        Recovery::Undisturbed,
        tick,
        NO_GATING_ROWS,
        &[],
        &[],
    );
    let mut graded = grade_round(world, &opening, &[Invariant::LocationRoundTrip]).await?;

    let canaries = match arm.label {
        "standing-adversary" => standing(world, publisher, victim, circle_tag, plane).await?,
        "rewrap-created-at-binding" => rewrap(world, publisher, victim, circle_tag, plane).await?,
        _ => return Err(RigError::UnknownTarget),
    };

    // The poisoned device SENDS first: its cursors and its view of the circle
    // are what the arm has been leaning on, and a plane that quietly stranded
    // its own history shows up as a peer that never hears from it again.
    let pairs = closing_pairs(world, victim);
    let closing = round(
        2,
        Reach::These(&pairs),
        Recovery::Undisturbed,
        tick,
        NO_GATING_ROWS,
        &[],
        &[],
    );
    graded.extend(
        grade_round(
            world,
            &closing,
            &[
                Invariant::Quiescence,
                Invariant::LocationRoundTrip,
                Invariant::SendPathLiveness,
            ],
        )
        .await?,
    );

    world.drain_buses();
    let observed = Observed::measure(world, canaries).await?;
    Ok(ArmOutcome {
        graded,
        observed,
        tick,
    })
}

/// Where both of a circle's persisted catch-up positions stand for one device.
#[derive(Clone, Copy, PartialEq, Eq)]
struct Anchors {
    cursor_ms: Option<i64>,
    backfill_secs: Option<i64>,
}

/// Reads `device`'s persisted anchors for `stream`.
fn anchors<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    stream: &str,
) -> Result<Anchors, RigError> {
    let manager = world.device(device)?.manager()?;
    Ok(Anchors {
        cursor_ms: manager
            .read_sync_cursor(stream)
            .map_err(|_| RigError::Core(Step::ReadCursor))?,
        backfill_secs: manager
            .read_backfill_floor(stream)
            .map_err(|_| RigError::Core(Step::ReadCursor))?,
    })
}

/// The standing adversary: three recipes, every cycle, for the whole arm.
async fn standing<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    publisher: DeviceTag,
    victim: DeviceTag,
    circle_tag: CircleTag,
    plane: RelayTag,
) -> Result<usize, RigError> {
    let circle = world.circle(circle_tag)?;
    let routing = *circle.nostr_group_id();
    let stream = group_cursor_stream(circle.group_id_hex());
    let group = circle.mls_group_id().clone();
    let recipes: [Forgery; RECIPES_PER_CYCLE] = [
        Forgery::Expired { group_id: routing },
        Forgery::MalformedDoubleH { group_id: routing },
        Forgery::Unprocessable { group_id: routing },
    ];

    let mut outcomes: Vec<GroupProcessOutcome> = Vec::with_capacity(RECIPES_PER_CYCLE * CYCLES);
    let mut held_every_round = true;
    let mut delivered_every_round = true;
    let mut injected = 0_usize;

    for index in 0..CYCLES {
        let before = anchors(world, victim, &stream)?;
        for recipe in recipes {
            inject(world, plane, recipe).await?;
            injected += 1;
            outcomes.push(classify_on_the_live_plane(world, victim, recipe, &routing).await?);
        }
        held_every_round &= anchors(world, victim, &stream)? == before;

        let index = u32::try_from(index).unwrap_or(u32::MAX);
        delivered_every_round &=
            matched_positive(world, publisher, victim, circle_tag, &group, index).await?;
    }

    let mut canaries = 0_usize;
    // 1. Every forgery really went out, and every one of them was written
    //    towards a client. An injection no open subscription matched is refused
    //    by the plane, so reaching this at all is already the floor; what this
    //    adds is that the adversary stood for the WHOLE arm.
    if wire_carried_them_all(world, plane, injected) {
        canaries += 1;
    }
    // 2. The two pre-authentication recipes are refused BEFORE the signature,
    //    the ephemeral author or the ciphertext are looked at — every cycle.
    if pre_auth_rejections(&outcomes) == 2 * CYCLES {
        canaries += 1;
    }
    // 3. …and the third is not: an envelope the parse CAN read is an engine-side
    //    failure, which is a different classification and a different cursor
    //    disposition. An arm where all three collapsed into one would be
    //    grading a boundary that no longer exists.
    if engine_side_refusals(&outcomes) == CYCLES {
        canaries += 1;
    }
    // 4. No injection round moved either anchor.
    if held_every_round {
        canaries += 1;
    }
    // 5. The matched positive: every cycle's legitimate fix really was
    //    delivered, so "nothing moved" is not a property of a world that
    //    delivered nothing.
    if delivered_every_round {
        canaries += 1;
    }
    // 6. …and the catch-up plane still advances, on its own local window.
    if catchup_advances_locally(world, victim, &stream).await? {
        canaries += 1;
    }
    Ok(canaries)
}

/// The rewrap: an observed ciphertext, re-signed by nobody, dated a day ahead.
///
/// # "Observed" means observed by the RECEIVER too, and that is not pedantry
///
/// A rewrap copies a genuine ciphertext, so the outer layer opens and the inner
/// MLS message authenticates: the CONTENT is a member's own and applying it
/// would be correct. What must never follow is a cursor advance, because the
/// envelope's `created_at` is bound to nothing the engine authenticates. So the
/// arm waits for the victim to have folded the original before it forges a copy
/// — otherwise the copy is the first sighting of authentic content and the
/// engine rightly applies it, which is a race, not a finding. Measured at this
/// pin: a rewrap that arrives before the original IS applied.
async fn rewrap<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    publisher: DeviceTag,
    victim: DeviceTag,
    circle_tag: CircleTag,
    plane: RelayTag,
) -> Result<usize, RigError> {
    let circle = world.circle(circle_tag)?;
    let stream = group_cursor_stream(circle.group_id_hex());
    let routing = *circle.nostr_group_id();
    let group = circle.mls_group_id().clone();

    // A genuine ciphertext the plane really carried, and the arm's own copy of
    // it: the plane resolves a rewrap's source from its store, and this module
    // needs the same bytes to hand the processor an equivalent forgery.
    world.drain_buses();
    let folded_before = deliveries_for(world.device(victim)?, circle_tag);
    let source = seal(world, publisher, &group, 1).await?;
    if world
        .publish_witnessed(publisher, std::slice::from_ref(&source))
        .await?
        .is_none()
    {
        // Nothing crossed the wire, so there is no observed ciphertext to copy.
        return Err(RigError::PublishNeverAcked);
    }
    observed_by_the_plane(world, plane, &source.id).await?;
    if !await_delivery(world, victim, circle_tag, folded_before).await? {
        // The victim never saw the original, so a copy of it would be the first
        // sighting of authentic content rather than a replay of one.
        return Err(RigError::PublishNeverAcked);
    }

    let before = anchors(world, victim, &stream)?;
    inject(
        world,
        plane,
        Forgery::Rewrap {
            source: source.id,
            offset_secs: REWRAP_AHEAD_SECS,
        },
    )
    .await?;
    let forged = mint(
        Forgery::Rewrap {
            source: source.id,
            offset_secs: REWRAP_AHEAD_SECS,
        },
        Some(&source),
    )?;
    let outcome = world
        .device(victim)?
        .engine()?
        .processor()
        .process_group_event(&forged, &routing)
        .await;

    let mut canaries = 0_usize;
    // 1. The outer layer opens and the inner MLS authenticates — the ciphertext
    //    is a member's own — and the receiver still applies nothing a second
    //    time and moves neither anchor. A re-signed envelope carries no claim
    //    about when anything was seen.
    if outcome != GroupProcessOutcome::Applied && anchors(world, victim, &stream)? == before {
        canaries += 1;
    }
    // 2. …and the plane still advances on its own trusted signal afterwards.
    //    Without this half, a build that had deleted cursor advance altogether
    //    would satisfy canary 1.
    if catchup_advances_locally(world, victim, &stream).await? {
        canaries += 1;
    }
    Ok(canaries)
}

/// Hands `victim` an equivalent forgery and reads what the live plane made of
/// it.
///
/// The recipe is minted again here rather than read back off the plane: an
/// injected event is never stored, so the plane can name the id it forged and
/// nothing can hand back its bytes.
async fn classify_on_the_live_plane<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    victim: DeviceTag,
    recipe: Forgery,
    routing: &[u8; 32],
) -> Result<GroupProcessOutcome, RigError> {
    let forged = mint(recipe, None)?;
    Ok(world
        .device(victim)?
        .engine()?
        .processor()
        .process_group_event(&forged, routing)
        .await)
}

/// How many outcomes are Haven's own pre-authentication refusal.
fn pre_auth_rejections(outcomes: &[GroupProcessOutcome]) -> usize {
    outcomes
        .iter()
        .filter(|outcome| **outcome == GroupProcessOutcome::RejectedBeforeAuth)
        .count()
}

/// How many outcomes are an ENGINE-side refusal — the authenticated path
/// failing, which is the disposition that legitimately holds a generation back.
fn engine_side_refusals(outcomes: &[GroupProcessOutcome]) -> usize {
    outcomes
        .iter()
        .filter(|outcome| **outcome == GroupProcessOutcome::Unprocessable)
        .count()
}

/// Forges one event onto every subscription on `plane` whose filter matches it.
async fn inject<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    plane: RelayTag,
    recipe: Forgery,
) -> Result<(), RigError> {
    world
        .relays_mut()
        .iter_mut()
        .find(|candidate| candidate.tag() == plane)
        .ok_or(RigError::UnknownTarget)?
        .apply(Fault::Inject(recipe))
        .await
}

/// Whether the plane forged `expected` events and wrote every one of them
/// towards a client.
fn wire_carried_them_all<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    plane: RelayTag,
    expected: usize,
) -> bool {
    let Some(relay) = world
        .relays()
        .iter()
        .find(|candidate| candidate.tag() == plane)
    else {
        return false;
    };
    let ledger = relay.ledger();
    let injected = ledger.injected_ids();
    injected.len() == expected && injected.iter().all(|id| ledger.delivered(id) >= 1)
}

/// Waits, bounded, for the plane to have carried `event_id` from the client.
async fn observed_by_the_plane<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    plane: RelayTag,
    event_id: &EventId,
) -> Result<(), RigError> {
    let carried = await_condition(bounds::round_trip(Recovery::Undisturbed), || async {
        world
            .relays()
            .iter()
            .find(|candidate| candidate.tag() == plane)
            .ok_or(RigError::UnknownTarget)?
            .stored(event_id)
            .await
    })
    .await?;
    if carried {
        Ok(())
    } else {
        // A rewrap copies an OBSERVED ciphertext; without one in the plane's
        // own store the fault has nothing to copy and would be refused.
        Err(RigError::PublishNeverAcked)
    }
}

/// Publishes one legitimate fix and waits for `victim` to fold it.
async fn matched_positive<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    publisher: DeviceTag,
    victim: DeviceTag,
    circle_tag: CircleTag,
    group: &GroupId,
    index: u32,
) -> Result<bool, RigError> {
    world.drain_buses();
    let before = deliveries_for(world.device(victim)?, circle_tag);
    let event = seal(world, publisher, group, index).await?;
    if world
        .publish_witnessed(publisher, std::slice::from_ref(&event))
        .await?
        .is_none()
    {
        return Ok(false);
    }
    await_delivery(world, victim, circle_tag, before).await
}

/// Waits, bounded, for `device`'s folded delivery count for `circle` to rise
/// above `above`.
///
/// An interval rather than a yield loop: the ledger is only written by a drain,
/// so the wait has to drain — and a tight yield loop would starve the very
/// engine worker whose delivery it is waiting for.
async fn await_delivery<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    device: DeviceTag,
    circle: CircleTag,
    above: u64,
) -> Result<bool, RigError> {
    let bound = bounds::round_trip(Recovery::Undisturbed);
    let started = tokio::time::Instant::now();
    let mut ticker = tokio::time::interval(DELIVERY_POLL);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        world.drain_buses();
        if deliveries_for(world.device(device)?, circle) > above {
            return Ok(true);
        }
        if started.elapsed() >= bound {
            return Ok(false);
        }
        ticker.tick().await;
    }
}

/// Whether a catch-up sweep advances `device`'s cursor to an instant the SWEEP's
/// own local clock produced.
///
/// Bracketed by two readings of the same wall clock `run_catchup_all_circles`
/// takes when it opens its window, which is what makes this a claim about the
/// advance's PROVENANCE rather than about its arithmetic: an implementation that
/// read the advance off an event's `created_at` could not land inside a bracket
/// the events are not in — the rewrap this scenario injects is dated a whole day
/// above it.
///
/// Two sweeps, and the first one is not graded: it drains whatever the world
/// left outstanding, so the graded one runs over a window whose every event is
/// already applied and therefore holds nothing back. A hold-back is legitimate
/// and would put the advance below the bracket, which would be this helper
/// reporting the world's backlog instead of the plane's provenance.
///
/// Between the two, a bounded wait for the wall clock to leave the second the
/// priming sweep anchored in. Without it the two sweeps can open their windows
/// inside ONE second, the cursor write is monotonic-max, and "it advanced"
/// becomes a coin toss on where the run fell against a second boundary — the
/// same trap `haven-core`'s own catch-up gates document and wait out. The wait
/// is a condition, not a sleep: it returns the instant the second turns, and its
/// ceiling is a derived delivery budget rather than a number chosen here.
async fn catchup_advances_locally<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    stream: &str,
) -> Result<bool, RigError> {
    let deadline_secs = bounds::round_trip(Recovery::Undisturbed).as_secs();
    let manager = world.device(device)?.manager()?;
    let relays = &world.device(device)?.relays;
    let _ = run_catchup_all_circles(manager, relays, deadline_secs).await;

    let Some(before) = anchors(world, device, stream)?.cursor_ms else {
        // The priming sweep advanced nothing, so there is no anchor whose
        // provenance the graded sweep could be read against.
        return Ok(false);
    };
    let anchored_in = before.div_euclid(1_000);
    if !await_condition(bounds::round_trip(Recovery::Undisturbed), || async {
        Ok(WallNow::now().secs() > anchored_in)
    })
    .await?
    {
        return Ok(false);
    }

    let opened = WallNow::now().secs();
    let _ = run_catchup_all_circles(manager, relays, deadline_secs).await;
    let closed = WallNow::now().secs();
    let Some(advanced) = anchors(world, device, stream)?.cursor_ms else {
        return Ok(false);
    };
    Ok(advanced > before
        && advanced >= opened.saturating_mul(1_000)
        && advanced <= closed.saturating_mul(1_000))
}

/// Seals one location at `device`'s current epoch, unpublished.
async fn seal<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    group: &GroupId,
    index: u32,
) -> Result<Event, RigError> {
    let sender = world.device(device)?;
    sender
        .manager()?
        .encrypt_location(
            group,
            &sender.keys.public_key(),
            &ProbeToken::mint(9, index).as_location(),
            LOCATION_MESSAGE_RETENTION_SECS,
        )
        .await
        .map(|(event, _, _)| event)
        .map_err(|_| RigError::Core(Step::Publish))
}

#[cfg(test)]
mod tests {
    use super::{ARMS, CYCLES, RECIPES_PER_CYCLE, REWRAP_AHEAD_SECS};
    use crate::oracle::Recovery;

    #[test]
    fn neither_arm_disturbs_a_socket_or_crosses_an_epoch() {
        for arm in &ARMS {
            assert!(
                arm.recovery == Recovery::Undisturbed,
                "an injection rides the REQ the engine already holds"
            );
            assert!(
                !arm.resubscribes,
                "a resubscribe would re-anchor the very cursor the arm is watching"
            );
            assert!(
                arm.floor.epochs_crossed == 0,
                "a forgery that advanced an epoch would be a forgery that authenticated"
            );
            assert!(
                arm.floor.deliveries_observed >= 2,
                "a control round and a closing round, both of which must really deliver"
            );
        }
    }

    #[test]
    fn the_standing_arm_declares_one_cycles_worth_of_faults_and_reads_the_whole_sequence() {
        assert!(
            ARMS[0].floor.faults_applied == RECIPES_PER_CYCLE && CYCLES > 1,
            "the floor is ONE cycle's recipes — the minimum a plane must record — \
             and the arm fires them again and again, because one round makes `the \
             anchor did not move` a point rather than a sequence"
        );
        assert!(
            ARMS[0].floor.canaries_caught == 6,
            "the wire, the two pre-auth refusals, the engine-side one, the anchors \
             that held, the matched positive, and the advance that still happens"
        );
    }

    #[test]
    fn the_rewrap_arm_dates_its_forgery_far_beyond_any_clock_skew() {
        assert!(
            ARMS[1].floor.faults_applied == 1 && REWRAP_AHEAD_SECS > 0,
            "one injection of one observed ciphertext, dated FORWARDS: that is the \
             dangerous direction, because an anchor pulled ahead strands every \
             legitimate event below it"
        );
        assert!(
            ARMS[1].floor.canaries_caught == 2,
            "the refusal that moved no anchor, and the advance that still happens"
        );
    }
}
