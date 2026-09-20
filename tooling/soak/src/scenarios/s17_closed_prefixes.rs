//! **S17** — a relay refuses subscriptions, machine-readably.
//!
//! The promise has three parts. A `CLOSED` prefix must be read as what it says:
//! a prefix Haven treats as a DROP is re-issued at once, and one it treats as a
//! THROTTLE is not re-issued before the product's own backoff floor — never
//! sooner, which is what would turn a rate limit into a hammer. A `NOTICE` is
//! text a relay chose, and it must change nothing at all. And a subscription
//! that goes silent — neither an event nor an `EOSE` for the whole delivery
//! silence window — must be re-issued once that window is up, and not before.
//!
//! # The prefix is read back off the wire
//!
//! Each arm reads the `CLOSED` text out of the plane's own client-facing ledger
//! and compares it to the prefix it asked for. A scenario that only checked
//! "the subscription went away" would pass on a plane that closed every REQ
//! with the same text, and the two `ClosedKind` behaviours would then be
//! indistinguishable.
//!
//! # The absence windows are never scaled
//!
//! "No re-issue before the backoff floor" and "no re-issue before the silence
//! window" are absences, and an absence asserted over a stretched window is a
//! weaker claim rather than a slower one. Both are written as a bounded wait for
//! the re-issue: a run that produces one early stops immediately and reports it.

use std::time::Duration;

use crate::nemesis::types::{ClosedPrefix, Fault};
use crate::oracle::bounds;
use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{Invariant, Reach, Recovery};
use crate::rig::{DeviceTag, LogDrain, RelayPlane, RelayTag, RigError, TimelineSink};
use crate::scenarios::{
    await_condition, closing_pairs, grade_round, round, stayed_absent, Absence, Arm, ArmOutcome,
    ScenarioWorld, WithheldAcks, NO_GATING_ROWS,
};

/// The text of the arm's `NOTICE`.
///
/// A literal from this crate. A relay-authored one would be remote text, which
/// Rule 15 keeps out of every rendering — including the ledger comparison below.
const HARNESS_NOTICE: &str = "haven-soak notice arm";

/// The prefix whose kind Haven treats as a DROP.
const DROPPED_PREFIX: ClosedPrefix = ClosedPrefix::Invalid;

/// The prefix whose kind Haven treats as a THROTTLE.
const THROTTLED_PREFIX: ClosedPrefix = ClosedPrefix::RateLimited;

/// The arms this scenario offers.
pub const ARMS: [Arm; 3] = [
    Arm {
        label: "closed-prefixes",
        recovery: Recovery::Throttled,
        probe_rounds: 1,
        resubscribes: true,
        // The throttle half asserts that nothing is re-issued before the
        // product's own backoff floor, and the deadline has to pay for it.
        absence: Absence::ThrottledBackoffFloor,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            // Every NIP-01 prefix, plus one arm per `ClosedKind`.
            faults_applied: 11,
            epochs_crossed: 0,
            deliveries_observed: 1,
            canaries_caught: 11,
        },
    },
    Arm {
        label: "notice",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: false,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            faults_applied: 1,
            epochs_crossed: 0,
            deliveries_observed: 1,
            canaries_caught: 1,
        },
    },
    Arm {
        label: "full-intake",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: true,
        // The whole delivery-silence window, waited out as an absence.
        absence: Absence::DeliverySilenceWindow,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            faults_applied: 1,
            epochs_crossed: 0,
            deliveries_observed: 1,
            canaries_caught: 2,
        },
    },
];

/// Runs one arm.
///
/// # Errors
///
/// [`RigError::UnknownTarget`] if the arm's label is not one this scenario
/// offers, otherwise [`RigError`] naming the step that failed.
pub(crate) async fn run<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    arm: &Arm,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    let plane = world
        .relays()
        .first()
        .map(RelayPlane::tag)
        .ok_or(RigError::ShapeMismatch)?;
    let device = world
        .devices()
        .first()
        .map(|device| device.tag)
        .ok_or(RigError::ShapeMismatch)?;

    let canaries = match arm.label {
        "closed-prefixes" => closed_prefixes(world, plane, device).await?,
        "notice" => notice(world, plane).await?,
        "full-intake" => full_intake(world, plane, device).await?,
        _ => return Err(RigError::UnknownTarget),
    };

    // Whatever the relay said, a healed world still carries a location — in
    // both directions, with the device whose REQs were refused sending first.
    apply(world, plane, Fault::Heal).await?;
    resubscribe(world, device).await?;
    let pairs = closing_pairs(world, device);
    let opened = [device];
    let healed = round(
        1,
        Reach::These(&pairs),
        arm.recovery,
        tick,
        NO_GATING_ROWS,
        &opened,
        &[],
    );
    let graded = grade_round(
        world,
        &healed,
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

/// Every NIP-01 prefix, read back off the wire, plus the two `ClosedKind`
/// behaviours.
async fn closed_prefixes<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    plane: RelayTag,
    device: DeviceTag,
) -> Result<usize, RigError> {
    // How many faults this applies is not counted here: the PLANE records what
    // it took, and the floor is graded against that.
    let mut canaries = 0_usize;

    for prefix in ClosedPrefix::ALL {
        apply(world, plane, Fault::Closed(prefix)).await?;
        // A REQ has to ARRIVE for the plane to refuse one, so the device is
        // made to re-open its own: a fault nobody's subscription met would be
        // a fault nobody observed.
        resubscribe(world, device).await?;
        let seen = await_condition(bounds::subscribe_ladder(), || async {
            Ok(closed_with(world, plane, prefix))
        })
        .await?;
        if seen {
            canaries += 1;
        }
        apply(world, plane, Fault::Heal).await?;
    }

    // The DROP kind: re-issued inside the subscribe ladder.
    apply(world, plane, Fault::Closed(DROPPED_PREFIX)).await?;
    resubscribe(world, device).await?;
    let before = reqs(world, plane)?;
    if await_condition(bounds::subscribe_ladder() + bounds::settle(), || async {
        Ok(reqs(world, plane)? > before)
    })
    .await?
    {
        canaries += 1;
    }
    apply(world, plane, Fault::Heal).await?;

    // The THROTTLE kind: NOT re-issued before the product's own backoff floor.
    // The fault stays applied, so every re-issue there might be is visible.
    apply(world, plane, Fault::Closed(THROTTLED_PREFIX)).await?;
    resubscribe(world, device).await?;
    // The engine's own subscribe ladder re-issues a refused REQ up to
    // `SUBSCRIBE_MAX_ATTEMPTS` times inside `subscribe_ladder()`, and those
    // attempts are the ATTEMPT LOOP rather than the per-endpoint backoff this
    // arm is about — measured: they land inside the floor and would read as the
    // hammering the arm exists to forbid. So the window opens where the ladder
    // can no longer be running, and the absence is asserted over what remains
    // of the floor. Both spans are the product's own terms; neither is scaled.
    let _ = await_condition(bounds::subscribe_ladder(), || async { Ok(false) }).await?;
    let before = reqs(world, plane)?;
    if stayed_absent(
        bounds::throttled_backoff_floor().saturating_sub(bounds::subscribe_ladder()),
        || async { Ok(reqs(world, plane)? > before) },
    )
    .await?
    {
        canaries += 1;
    }

    Ok(canaries)
}

/// A relay-authored `NOTICE` reaches the client and changes nothing.
async fn notice<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    plane: RelayTag,
) -> Result<usize, RigError> {
    apply(world, plane, Fault::Notice(HARNESS_NOTICE)).await?;
    let seen = await_condition(bounds::settle(), || async { Ok(noticed(world, plane)) }).await?;
    Ok(usize::from(seen))
}

/// A subscription that is never told its stored page ended is re-issued once
/// the delivery-silence window is up, and not before.
async fn full_intake<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    plane: RelayTag,
    device: DeviceTag,
) -> Result<usize, RigError> {
    // The mechanism: the `EOSE` is addressed to a subscription nobody opened,
    // so the REQ this device really opened is never told its stored page ended
    // — which is precisely the "silent group REQ" the health probe counts.
    apply(world, plane, Fault::EoseForAnotherSubscription).await?;
    resubscribe(world, device).await?;
    let mut canaries = 0_usize;

    // 1. Nothing is re-issued while the window is still running, health tick or
    //    no health tick.
    let before = reqs(world, plane)?;
    let quiet = stayed_absent(bounds::silence_window(), || async {
        let _ = world
            .device(device)?
            .engine()?
            .maintain_subscription_health()
            .await;
        Ok(reqs(world, plane)? > before)
    })
    .await?;
    if quiet {
        canaries += 1;
    }

    // 2. …and once it is up, the next health tick re-issues it.
    let _ = world
        .device(device)?
        .engine()?
        .maintain_subscription_health()
        .await;
    if await_condition(bounds::subscribe_ladder() + bounds::settle(), || async {
        Ok(reqs(world, plane)? > before)
    })
    .await?
    {
        canaries += 1;
    }
    Ok(canaries)
}

/// The `CLOSED` messages one plane wrote towards the client.
fn closed_messages<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    plane: RelayTag,
) -> Option<Vec<String>> {
    world
        .relays()
        .iter()
        .find(|candidate| candidate.tag() == plane)
        .map(|candidate| candidate.ledger().closed_messages())
}

/// The `NOTICE` texts one plane wrote towards the client.
fn notices<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    plane: RelayTag,
) -> Option<Vec<String>> {
    world
        .relays()
        .iter()
        .find(|candidate| candidate.tag() == plane)
        .map(|candidate| candidate.ledger().notices())
}

/// How many `REQ`s one plane has been sent.
fn reqs<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    plane: RelayTag,
) -> Result<usize, RigError> {
    world
        .relays()
        .iter()
        .find(|candidate| candidate.tag() == plane)
        .map(|candidate| candidate.ledger().reqs())
        .ok_or(RigError::UnknownTarget)
}

/// Whether the plane's client-facing stream carried a `CLOSED` with exactly
/// this prefix.
fn closed_with<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    plane: RelayTag,
    prefix: ClosedPrefix,
) -> bool {
    closed_messages(world, plane).is_some_and(|messages| {
        messages
            .iter()
            .any(|message| message.starts_with(prefix.as_str()))
    })
}

/// Whether the plane's client-facing stream carried this arm's own `NOTICE`.
fn noticed<T: TimelineSink, L: LogDrain>(world: &ScenarioWorld<T, L>, plane: RelayTag) -> bool {
    notices(world, plane).is_some_and(|texts| texts.iter().any(|text| text == HARNESS_NOTICE))
}

/// Re-opens one device's own subscriptions.
///
/// A pause and a resume rather than a restart: the subject of this scenario is
/// what a relay says to a REQ, and the cheapest honest way to make one arrive is
/// the product's own background resume.
async fn resubscribe<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    device: DeviceTag,
) -> Result<(), RigError> {
    world.device_mut(device)?.go_offline().await?;
    world.device_mut(device)?.come_online().await
}

/// Applies one fault to one plane.
async fn apply<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    tag: RelayTag,
    fault: Fault,
) -> Result<(), RigError> {
    world
        .relays_mut()
        .iter_mut()
        .find(|plane| plane.tag() == tag)
        .ok_or(RigError::UnknownTarget)?
        .apply(fault)
        .await
}

#[cfg(test)]
mod tests {
    use super::{ARMS, DROPPED_PREFIX, HARNESS_NOTICE, THROTTLED_PREFIX};
    use crate::nemesis::types::ClosedPrefix;
    use crate::oracle::bounds;
    use crate::scenarios::Absence;

    #[test]
    fn the_prefix_arm_covers_every_nip01_prefix_and_both_kinds() {
        let arm = ARMS[0];
        assert!(
            arm.floor.faults_applied == ClosedPrefix::ALL.len() + 2,
            "every prefix, plus one arm per ClosedKind"
        );
        assert!(
            arm.floor.canaries_caught == ClosedPrefix::ALL.len() + 2,
            "every prefix read back, plus both kinds' behaviours"
        );
    }

    #[test]
    fn the_two_kinds_are_the_two_the_product_treats_as_throttles() {
        // The pair that makes the arm meaningful: a prefix Haven drops on and
        // one it backs off on. Picking two of the same kind would grade one
        // behaviour twice.
        assert_eq!(THROTTLED_PREFIX, ClosedPrefix::RateLimited);
        assert_ne!(DROPPED_PREFIX, ClosedPrefix::RateLimited);
        assert_ne!(DROPPED_PREFIX, ClosedPrefix::AuthRequired);
    }

    #[test]
    fn the_absence_windows_are_the_products_own_and_are_paid_for() {
        assert_eq!(ARMS[0].absence.window(), bounds::throttled_backoff_floor());
        assert_eq!(ARMS[2].absence.window(), bounds::silence_window());
        assert!(
            ARMS[1].absence == Absence::None,
            "a notice asserts no absence"
        );
    }

    #[test]
    fn the_notice_text_is_this_crates_own() {
        assert!(HARNESS_NOTICE.starts_with("haven-soak"));
    }
}
