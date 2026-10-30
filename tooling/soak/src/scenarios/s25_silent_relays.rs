//! **S25** — one relay of a circle never answers and another never ends its
//! stored replay.
//!
//! The promise (owner decision, P2): a dead or silent relay does not stall a
//! circle, and Security Rule 12 is kept while it does not. Graded over real
//! relays, the receiver paused and resumed around each phase:
//!
//! * **A, the dead relay alone** (`unanswering`: every connection accepted and
//!   never answered). The resume's backlog wait settles on the relays that
//!   answer, waiting on none that never connected; the circle is caught up and
//!   its cursor advances; every fix an answering relay held arrives.
//! * **The lookback passes**, and one more resume re-anchors past it: from then
//!   on a REQ's ordinary `since` no longer reaches the fix only the dead relay
//!   holds, and only the floor that relay owes (`relay_floors`) does.
//! * **B, the silent relay too** (`withhold-eose`: every page served, its
//!   `EOSE` never sent). The silent relay holds the circle until the backlog
//!   wait is over and not after: caught up, advanced, every answering relay's
//!   fix arrived.
//! * **Health ticks**, the dead relay now refusing connections so the pool
//!   holds it dropped: three claimed ticks re-issue no REQ on any plane.
//! * **The heal**: the dead relay is asked from its floor once it answers,
//!   gives up the fix only it held, and its `EOSE` ends what it owed.
//!
//! # Where each fix lives
//!
//! Each fix is stored on ONE plane, through the plane's own store, while the
//! receiver is paused: so which fix arrives says which relay answered.
//!
//! # Planes
//!
//! Plane 0 is the dead relay, plane 1 the silent one; any further plane
//! answers throughout. The world's own first circle names them all.

use std::time::Duration;

use haven_core::nostr::mls::types::GroupId;
use haven_core::relay::live_sync::{group_cursor_stream, BacklogOutcome, Claim};
use nostr::{Event, RelayUrl};
use tokio::time::{Instant, MissedTickBehavior};

use crate::clock::{millis_to_secs, WallNow};
use crate::nemesis::types::Fault;
use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{bounds, Finding, Invariant, ProbeToken, Reach, Recovery, Verdict};
use crate::rig::{CircleTag, DeviceTag, LogDrain, RelayPlane, RigError, Step, TimelineSink};
use crate::scenarios::{
    await_condition, closing_pairs, deliveries_for, grade_round, round, Absence, Arm, ArmOutcome,
    Scenario, ScenarioReport, ScenarioWorld, WithheldAcks, NO_GATING_ROWS,
};

/// The arm this scenario offers.
pub const ARMS: [Arm; 1] = [Arm {
    label: "dead-and-silent-relays",
    recovery: Recovery::Reconnect,
    probe_rounds: 1,
    resubscribes: true,
    absence: Absence::ResubscribeLookback,
    withheld_acks: WithheldAcks::None,
    floor: ExpectationFloor {
        faults_applied: 3,
        epochs_crossed: 0,
        deliveries_observed: 3,
        canaries_caught: 6,
    },
}];

/// The probe round the planted fixes are minted from.
const FIX_ROUND: u32 = 125;

/// How often a delivery wait re-reads the buses.
const DELIVERY_POLL: Duration = Duration::from_millis(20);

/// Claimed health ticks taken while the dead relay is still dead. More than
/// one, so a session re-anchored on every tick could not pass as one
/// re-anchored once.
const HEALTH_TICKS: usize = 3;

/// The dead plane's index.
const DEAD: usize = 0;
/// The silent plane's index.
const SILENT: usize = 1;

/// Runs the arm.
///
/// # Errors
///
/// [`RigError::ShapeMismatch`] if the world has fewer than two devices or two
/// relays, otherwise [`RigError`] naming the step that failed.
pub(crate) async fn run<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    _arm: &Arm,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    silent_relays(world, tick, true).await
}

/// The arm with every relay answering: the same pause, planted fixes and
/// resume, no fault.
///
/// The mis-configuration control in `tests/oracles.rs` requires rc 3 — no
/// relay was dead or silent, so the arm proved nothing about one.
///
/// # Errors
///
/// As [`run`].
pub async fn answering_control<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    tick: Duration,
) -> Result<ScenarioReport, RigError> {
    let started = Instant::now();
    let outcome = silent_relays(world, tick, false).await?;
    Ok(Scenario::SilentRelays.report(world, &ARMS[0], outcome, started))
}

async fn silent_relays<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    tick: Duration,
    break_them: bool,
) -> Result<ArmOutcome, RigError> {
    let tags: Vec<DeviceTag> = world.devices().iter().map(|device| device.tag).collect();
    let [sender, receiver, ..] = *tags.as_slice() else {
        return Err(RigError::ShapeMismatch);
    };
    if world.relays().len() < 2 {
        return Err(RigError::ShapeMismatch);
    }
    let circle = world.circles().first().ok_or(RigError::ShapeMismatch)?;
    let at = At {
        sender,
        receiver,
        circle: circle.tag,
        group: circle.mls_group_id().clone(),
        stream: group_cursor_stream(circle.group_id_hex()),
        hex: circle.group_id_hex().to_owned(),
    };
    let planes = world.relays().len();
    let others = u64::try_from(planes - 1).unwrap_or(u64::MAX);
    let mut tally = Tally::default();
    world.drain_buses();
    let before = deliveries_for(world.device(receiver)?, at.circle);

    let dead_fix = dead_alone(world, &at, before + others, break_them, &mut tally).await?;
    let waited = past_the_lookback(world, &at, dead_fix).await?;
    silent_too(world, &at, before + 2 * others, break_them, &mut tally).await?;
    ticks_while_dropped(world, &at, break_them, &mut tally).await?;
    heal_and_redeem(world, &at, before + 2 * others + 1, waited, &mut tally).await?;

    let pairs = closing_pairs(world, sender);
    let closing = round(
        1,
        Reach::These(&pairs),
        Recovery::Reconnect,
        tick,
        NO_GATING_ROWS,
        &[],
        &[],
    );
    let mut graded = grade_round(
        world,
        &closing,
        &[
            Invariant::Quiescence,
            Invariant::LocationRoundTrip,
            Invariant::SendPathLiveness,
        ],
    )
    .await?;
    graded.extend(tally.extra);

    world.drain_buses();
    let observed = Observed::measure(world, tally.canaries).await?;
    Ok(ArmOutcome {
        graded,
        observed,
        tick,
    })
}

/// What the arm has caught and found so far.
#[derive(Default)]
struct Tally {
    canaries: usize,
    extra: Vec<(Invariant, Verdict)>,
}

/// Phase A: the dead relay alone, a fix on every plane. The resume's backlog
/// wait settles on the relays that answer, waiting on none that never
/// connected; the circle advances at once and gets every answering relay's
/// fix (`delivered` in all). The second the dead relay's fix was sealed in.
async fn dead_alone<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    at: &At,
    delivered: u64,
    break_them: bool,
    tally: &mut Tally,
) -> Result<i64, RigError> {
    if break_them {
        world.relays_mut()[DEAD].apply(Fault::Unanswering).await?;
    }
    let every: Vec<usize> = (0..world.relays().len()).collect();
    let resumed = resume_over(world, at, &every, 0).await?;
    let advanced = poll_world(world, bounds::round_trip(Recovery::Undisturbed), |world| {
        Ok(caught_up(world, at.receiver, &at.group)?
            && cursor_of(world, at.receiver, &at.stream)? > resumed.anchored)
    })
    .await?;
    if resumed.turned && !(resumed.outcome == BacklogOutcome::Settled && advanced) {
        tally.extra.push(stalled(at));
    }
    if !delivered_within(
        world,
        at,
        delivered,
        bounds::round_trip(Recovery::Undisturbed),
    )
    .await?
    {
        tally.extra.push(lost(at));
    }
    // 1. The dead relay took a connection and never answered it.
    if world.relays()[DEAD].ledger().unanswered_connects() >= 1 {
        tally.canaries += 1;
    }
    Ok(resumed.created_secs)
}

/// Waits past the product's own lookback from `sealed`, then re-anchors there
/// once: from then on a REQ's ordinary `since` no longer reaches the dead
/// relay's fix, and only the floor that relay owes does (Rule 12). Whether the
/// lookback passed.
async fn past_the_lookback<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    at: &At,
    sealed: i64,
) -> Result<bool, RigError> {
    let lookback = bounds::resubscribe_lookback();
    let past = sealed.saturating_add(i64::try_from(lookback.as_secs()).unwrap_or(i64::MAX));
    let waited = await_condition(lookback + bounds::wall_second_turnover(), || async {
        Ok(WallNow::now().secs() >= past)
    })
    .await?;
    let _ = resume_over(world, at, &[], 0).await?;
    Ok(waited)
}

/// Phase B: the silent relay too, a fix on every plane but the dead one. The
/// silent relay holds the circle until the backlog wait is over and not
/// after (`delivered` in all by then).
async fn silent_too<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    at: &At,
    delivered: u64,
    break_them: bool,
    tally: &mut Tally,
) -> Result<(), RigError> {
    if break_them {
        world.relays_mut()[SILENT]
            .apply(Fault::WithholdEose)
            .await?;
    }
    let planes = world.relays().len();
    let answering: Vec<usize> = (0..planes).filter(|&index| index != DEAD).collect();
    let first = u64::try_from(planes).unwrap_or(u64::MAX);
    let resumed = resume_over(world, at, &answering, first).await?;
    // 2. The silent relay kept an EOSE from a client.
    if world.relays()[SILENT].ledger().withheld_eose() >= 1 {
        tally.canaries += 1;
    }
    // 3. …and that EOSE held the circle until the wait was over.
    if resumed.held && resumed.turned {
        tally.canaries += 1;
    }
    let released = poll_world(world, bounds::round_trip(Recovery::Undisturbed), |world| {
        Ok(caught_up(world, at.receiver, &at.group)?
            && cursor_of(world, at.receiver, &at.stream)? > resumed.anchored)
    })
    .await?;
    if resumed.turned && !released {
        tally.extra.push(stalled(at));
    }
    if !delivered_within(
        world,
        at,
        delivered,
        bounds::round_trip(Recovery::Undisturbed),
    )
    .await?
    {
        tally.extra.push(lost(at));
    }
    Ok(())
}

/// The dead relay refusing connections, so the receiver's pool holds it
/// dropped: claimed health ticks re-issue no REQ on any plane, the pool
/// retrying the relay alone.
async fn ticks_while_dropped<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    at: &At,
    break_them: bool,
    tally: &mut Tally,
) -> Result<(), RigError> {
    if break_them {
        world.relays_mut()[DEAD].apply(Fault::Down).await?;
    }
    // 4. The receiver's pool holds the dead relay dropped.
    let dropped = await_condition(bounds::round_trip(Recovery::Undisturbed), || async {
        Ok(world
            .device(at.receiver)?
            .engine()?
            .relay_health()
            .await
            .disconnected
            >= 1)
    })
    .await?;
    if dropped {
        tally.canaries += 1;
    }
    let reqs = |world: &ScenarioWorld<T, L>| -> usize {
        world
            .relays()
            .iter()
            .map(|plane| plane.ledger().reqs())
            .sum()
    };
    let reqs_before = reqs(world);
    for _ in 0..HEALTH_TICKS {
        world
            .device(at.receiver)?
            .engine()?
            .maintain_subscription_health(Claim::Foreground)
            .await
            .map_err(|_| RigError::Core(Step::ResumeEngine))?;
    }
    if reqs(world) != reqs_before {
        tally.extra.push((
            Invariant::Quiescence,
            Verdict::Failed(Finding::ResubscribeUnbounded {
                device: at.receiver,
            }),
        ));
    }
    Ok(())
}

/// Both relays left out owe the circle a floor; healed, the dead relay is
/// asked from its floor, gives up the fix only it held (`delivered` in all)
/// and its `EOSE` ends what it owed.
async fn heal_and_redeem<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    at: &At,
    delivered: u64,
    waited: bool,
    tally: &mut Tally,
) -> Result<(), RigError> {
    // The addresses the receiver's engine dials, in the form its floors are
    // keyed by.
    let engine_url = |index: usize| -> Result<String, RigError> {
        let plane = world.relays().get(index).ok_or(RigError::ShapeMismatch)?;
        RelayUrl::parse(plane.url_for(at.receiver))
            .map(|url| url.as_str().to_owned())
            .map_err(|_| RigError::ShapeMismatch)
    };
    let (dead_url, silent_url) = (engine_url(DEAD)?, engine_url(SILENT)?);
    // 5. Both relays left out owe the circle its history from where they were
    //    asked.
    let manager = world.device(at.receiver)?.manager()?;
    let owed = manager.relay_floor_for_test(&at.hex, &dead_url).is_some()
        && manager.relay_floor_for_test(&at.hex, &silent_url).is_some();
    if owed {
        tally.canaries += 1;
    }

    for index in [DEAD, SILENT] {
        world.relays_mut()[index].apply(Fault::Heal).await?;
    }
    let reconnect = bounds::round_trip(Recovery::Reconnect);
    if !delivered_within(world, at, delivered, reconnect).await? {
        tally.extra.push(lost(at));
    }
    // 6. …and its EOSE ends what it owed.
    let manager = world.device(at.receiver)?.manager()?;
    if owed
        && waited
        && poll_world(world, reconnect, |_| {
            Ok(manager.relay_floor_for_test(&at.hex, &dead_url).is_none())
        })
        .await?
    {
        tally.canaries += 1;
    }
    Ok(())
}

/// The circle the arm is about, on whom.
struct At {
    sender: DeviceTag,
    receiver: DeviceTag,
    circle: CircleTag,
    group: GroupId,
    stream: String,
    hex: String,
}

/// What one pause and resume of the receiver saw.
struct Resumed {
    /// The cursor before the resume.
    anchored: Option<i64>,
    /// Whether the wall clock left the cursor's second before the resume, so
    /// an advance can be read.
    turned: bool,
    /// Whether the circle was neither caught up nor advanced when the resume
    /// returned.
    held: bool,
    /// What the backlog wait answered.
    outcome: BacklogOutcome,
    /// The earliest second a fix planted here was sealed in: the first
    /// plane's, which is planted first.
    created_secs: i64,
}

/// Pauses the receiver, stores one fix from the sender on each plane of
/// `planes` (that plane's alone), resumes it and waits out its backlog wait.
async fn resume_over<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    at: &At,
    planes: &[usize],
    first: u64,
) -> Result<Resumed, RigError> {
    let anchored = cursor_of(world, at.receiver, &at.stream)?;
    world.device_mut(at.receiver)?.go_offline().await?;
    let mut created_secs = i64::MAX;
    for (offset, &index) in planes.iter().enumerate() {
        let ordinal = first + u64::try_from(offset).unwrap_or(u64::MAX);
        let fix = seal(world, at.sender, &at.group, ordinal).await?;
        created_secs = created_secs.min(i64::try_from(fix.created_at.as_secs()).unwrap_or(0));
        let plane = world.relays().get(index).ok_or(RigError::ShapeMismatch)?;
        if plane.store(std::slice::from_ref(&fix)).await? != 1 {
            return Err(RigError::Core(Step::ApplyFault));
        }
    }
    // A cursor counts whole seconds: an advance in the anchor's own second
    // would read as none, so an advance is graded only past it.
    let anchor_secs = anchored.map_or(0, millis_to_secs);
    let turned = await_condition(bounds::wall_second_turnover(), || async {
        Ok(WallNow::now().secs() > anchor_secs)
    })
    .await?;
    world.device_mut(at.receiver)?.come_online().await?;
    // Read before the wait: nothing else here can release a relay still
    // owing its EOSE.
    let held = !caught_up(world, at.receiver, &at.group)?
        && cursor_of(world, at.receiver, &at.stream)? == anchored;
    let outcome = world
        .device(at.receiver)?
        .engine()?
        .wait_backlog_settled()
        .await;
    Ok(Resumed {
        anchored,
        turned,
        held,
        outcome,
        created_secs,
    })
}

/// The finding for a circle a dead or silent relay held.
const fn stalled(at: &At) -> (Invariant, Verdict) {
    (
        Invariant::Quiescence,
        Verdict::Failed(Finding::SilentRelayStalled {
            device: at.receiver,
            circle: at.circle,
        }),
    )
}

/// The finding for a fix a relay held that never arrived.
const fn lost(at: &At) -> (Invariant, Verdict) {
    (
        Invariant::LocationRoundTrip,
        Verdict::Failed(Finding::HeldEventLost {
            device: at.receiver,
            circle: at.circle,
        }),
    )
}

/// Seals one fix from `device` at its current epoch, unpublished.
async fn seal<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    group: &GroupId,
    index: u64,
) -> Result<Event, RigError> {
    let index = u32::try_from(index).map_err(|_| RigError::ShapeMismatch)?;
    let sender = world.device(device)?;
    sender
        .manager()?
        .seal_location_for_test(group, &ProbeToken::mint(FIX_ROUND, index).as_location())
        .await
        .map(|(event, _, _)| event)
        .map_err(|_| RigError::Core(Step::Publish))
}

/// Whether `device`'s session holds `group` caught up.
fn caught_up<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    group: &GroupId,
) -> Result<bool, RigError> {
    Ok(world.device(device)?.session()?.caught_up_for_test(group))
}

/// `device`'s persisted group cursor for `stream`.
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

/// Waits, bounded, for the receiver's folded delivery count for the circle to
/// reach `count`.
async fn delivered_within<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    at: &At,
    count: u64,
    bound: Duration,
) -> Result<bool, RigError> {
    let started = Instant::now();
    let mut ticker = tokio::time::interval(DELIVERY_POLL);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    loop {
        world.drain_buses();
        if deliveries_for(world.device(at.receiver)?, at.circle) >= count {
            return Ok(true);
        }
        if started.elapsed() >= bound {
            return Ok(false);
        }
        ticker.tick().await;
    }
}

/// Waits, bounded, for `condition` over `world` to hold.
async fn poll_world<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    bound: Duration,
    condition: impl Fn(&ScenarioWorld<T, L>) -> Result<bool, RigError>,
) -> Result<bool, RigError> {
    let started = Instant::now();
    let mut ticker = tokio::time::interval(DELIVERY_POLL);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    loop {
        if condition(world)? {
            return Ok(true);
        }
        if started.elapsed() >= bound {
            return Ok(false);
        }
        ticker.tick().await;
    }
}

#[cfg(test)]
mod tests {
    use super::ARMS;
    use crate::oracle::Recovery;
    use crate::scenarios::{Absence, WithheldAcks};

    #[test]
    fn the_arm_breaks_two_relays_and_prices_the_reconnect() {
        let arm = ARMS[0];
        assert!(
            arm.recovery == Recovery::Reconnect && arm.floor.faults_applied == 3,
            "a dead relay, then dropped, and a silent one, healed into the pool's own reconnect"
        );
        assert!(
            arm.absence == Absence::ResubscribeLookback,
            "the arm lets the product's lookback pass, so only a floor reaches the dead relay"
        );
        assert!(
            arm.withheld_acks == WithheldAcks::None,
            "every publish the arm makes is acknowledged"
        );
        assert!(
            arm.floor.canaries_caught == 6,
            "the held connection, the withheld EOSE, the held circle, the dropped relay, both \
             floors and the dead relay's ended floor"
        );
    }
}
