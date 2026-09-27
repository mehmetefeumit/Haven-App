//! **S03** — a relay forgets a commit before a paused member returns, and the
//! member is stranded behind it. **KNOWN-BAD, recorded.**
//!
//! A member is away across one confirmed commit, and the relay's store is
//! wiped before it comes back. Its resume re-subscribes from the persisted
//! cursor and finds nothing, so it sits one epoch below its peers for ever:
//! every later commit and every later fix is sealed above what it holds. The
//! member's own fixes still reach its peers — the committer keeps the stranded
//! epoch's exporter secret for the whole retention window — so the
//! user-visible shape is one-directional silence: everybody else's locations
//! stop arriving, with nothing saying so.
//!
//! # The engine's signature, and what this arm keys on
//!
//! At this pin the stranded device's `PeelDeferred` store churns: each later
//! 445 is refused at the outer wrap, retained, retried up to
//! `MAX_DEFERRED_PEEL_ATTEMPTS` and retired. Nothing grows the `Buffered`
//! chain — a deferred peel is not a convergence input — so the observable
//! signature is a stranded EPOCH and a failed CROSS-DECRYPT, and those are what
//! the arm keys on. A buffered count would read zero on a stranded device and
//! would key on nothing.
//!
//! # Recorded, not graded
//!
//! The closing round asks O6 (the stranded world is quiet — nothing staged,
//! nothing in flight, no gating row) and O5 (every refusal is one the
//! classifier accounts for), and deliberately NOT O1 or O2: both would report
//! the epoch divergence the arm induced, at rc 1, for behaviour the product is
//! known to have. The strand itself is asserted as a CANARY: if it stops
//! happening (a real improvement) the floor is unmet and the arm is rc 3, "the
//! recorded expectation is stale"; if a verdict starts appearing the silence
//! canary is unmet and it is rc 3 again, which is the correct signal — the
//! recorded expectation must be replaced by a graded one in the same commit.
//! The silence is read on every surface haven-core has: `unrecoverable_circles`
//! and the bus, and the circle-health row, whose peer-event stamp is written
//! only by the app layer — so at this tier haven-core records nothing about
//! the strand at all.
//!
//! At this commit Haven raises no per-circle verdict for a device stranded
//! behind a lost commit. This arm asserts that silence. OD-1 is DECIDED — a
//! per-circle verdict inside the circle's details sheet — and is NOT BUILT.
//! When it lands, this arm's absence assertion becomes a presence assertion
//! within `silence_window()`; changing it in either direction without citing
//! OD-1 is a regression.
//!
//! # The control cycle runs FIRST
//!
//! The same pause, partition, commit, heal and resume with the store KEPT must
//! converge all three, or the partition alone stranded the device and the wipe
//! is not the cause. It runs before the wipe cycle rather than after, because a
//! device already stranded cannot converge a second cycle in the same circle,
//! and the world's smallest shape has no second circle to run it in.
//!
//! # The weekly arm waits out the silence window
//!
//! `lost-commit-unnamed` adds the product's own delivery-silence window
//! (`Absence::DeliverySilenceWindow`, three kind-445 retention windows) after
//! the strand, driving the engine's own health repair throughout, and asserts
//! that nothing named the circle across it and the device is still stranded
//! when it ends. An absence window is the one span that may never be scaled or
//! shortened, so that arm runs only in the `weekly` profile and is not in the
//! crate's own sweep, for exactly the reason S17's `full-intake` is not.
//!
//! # No catch-up sweep during the partition
//!
//! The handshake class is withheld on the stranded device's ENGINE endpoint;
//! a catch-up sweep dials the canonical one and would deliver the commit by
//! the other path. This scenario runs none.

use std::time::Duration;

use haven_core::location::LOCATION_MESSAGE_RETENTION_SECS;
use haven_core::nostr::mls::types::GroupId;
use nostr::{Event, EventId};

use crate::nemesis::types::{DropClass, Fault};
use crate::oracle::quiescence::{self, Settled};
use crate::oracle::undecryptable::{self, StoredRow};
use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{bounds, Invariant, ProbeToken, Reach, Recovery};
use crate::rig::{
    CircleTag, DeviceTag, LogDrain, PublishVerdict, RelayPlane, RigError, Step, TimelineSink,
};
use crate::scenarios::{
    await_condition, chain_pairs, grade_round, relay_update, round, Absence, Arm, ArmOutcome,
    ScenarioWorld, WithheldAcks, NO_GATING_ROWS,
};
use tokio::time::{Instant, MissedTickBehavior};

/// The arms this scenario offers.
pub const ARMS: [Arm; 2] = [
    Arm {
        label: "lost-commit-strands",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: true,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            // Two handshake partitions and one wipe, on at least one plane.
            faults_applied: 3,
            epochs_crossed: 1,
            deliveries_observed: 1,
            canaries_caught: 6,
        },
    },
    Arm {
        label: "lost-commit-unnamed",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: true,
        absence: Absence::DeliverySilenceWindow,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            faults_applied: 3,
            epochs_crossed: 1,
            deliveries_observed: 1,
            canaries_caught: 7,
        },
    },
];

/// The round the cross-decrypt probes are stamped with: neither graded
/// round's ordinal.
const PROBE_ROUND: u32 = 103;

/// How often the silence window is re-read, and the product's own health
/// repair driven. A harness cadence: the shipped tick is fifteen minutes, and
/// a denser one can only make the absence claim stronger.
const SILENCE_POLL: Duration = Duration::from_secs(1);

/// Whether a cycle's relay store survives the commit.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Store {
    Kept,
    Wiped,
}

impl Store {
    /// The relay-list salt, so the two cycles' commits differ and each
    /// advances an epoch.
    const fn salt(self) -> &'static str {
        match self {
            Self::Kept => "kept",
            Self::Wiped => "wiped",
        }
    }
}

/// Runs one arm.
///
/// # Errors
///
/// [`RigError::UnknownTarget`] if the label is not one this scenario offers,
/// [`RigError::ShapeMismatch`] if the world has fewer than three devices — a
/// strand needs a committer, a witness that takes the commit live and the
/// member that misses it — otherwise [`RigError`] naming the step that failed.
pub(crate) async fn run<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    arm: &Arm,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    let waits_out_the_silence = match arm.label {
        "lost-commit-strands" => false,
        "lost-commit-unnamed" => true,
        _ => return Err(RigError::UnknownTarget),
    };
    let tags: Vec<DeviceTag> = world.devices().iter().map(|device| device.tag).collect();
    let [committer, witness, stranded, ..] = *tags.as_slice() else {
        return Err(RigError::ShapeMismatch);
    };
    let circle_tag = world.circles().first().ok_or(RigError::ShapeMismatch)?.tag;

    // The one probe round: the world delivers before anything is lost.
    let pairs = chain_pairs(world);
    let opening = round(
        1,
        Reach::These(&pairs),
        Recovery::Undisturbed,
        tick,
        NO_GATING_ROWS,
        &[],
        &[],
    );
    let mut graded = grade_round(world, &opening, &[Invariant::LocationRoundTrip]).await?;

    let mut classified: Vec<undecryptable::Verdict> = Vec::new();
    let mut canaries = 0_usize;
    canaries += cycle(world, committer, witness, stranded, circle_tag, Store::Kept).await?;
    canaries += cycle(
        world,
        committer,
        witness,
        stranded,
        circle_tag,
        Store::Wiped,
    )
    .await?;
    canaries += strand(
        world,
        committer,
        stranded,
        circle_tag,
        tick,
        &mut classified,
    )
    .await?;
    if waits_out_the_silence {
        canaries += silence_held(world, committer, stranded, circle_tag).await?;
    }

    // O6 and O5 only (see the module docs). The reach is declared for the
    // record; O1 is deliberately not asked.
    let opened = [stranded];
    let closing = round(
        2,
        Reach::These(&pairs),
        Recovery::Undisturbed,
        tick,
        NO_GATING_ROWS,
        &opened,
        &classified,
    );
    graded.extend(
        grade_round(
            world,
            &closing,
            &[Invariant::Quiescence, Invariant::Undecryptable],
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

/// One pause–partition–commit–heal–resume cycle, with the store kept or wiped
/// between the commit and the resume. The two differ in nothing else.
async fn cycle<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    committer: DeviceTag,
    witness: DeviceTag,
    stranded: DeviceTag,
    circle_tag: CircleTag,
    store: Store,
) -> Result<usize, RigError> {
    let group = world.circle(circle_tag)?.mls_group_id().clone();
    let bound = bounds::round_trip(Recovery::Undisturbed);
    let mut canaries = 0_usize;

    world.device_mut(stranded)?.go_offline().await?;
    // Belt and braces: the pause already stops delivery, and the drop keeps it
    // stopped through the resume.
    aim(world, stranded, Fault::DropClass(DropClass::Handshake)).await?;
    let commit = confirmed_commit(world, committer, circle_tag, store.salt()).await?;

    match store {
        Store::Kept => {
            aim(world, stranded, Fault::Heal).await?;
            world.device_mut(stranded)?.come_online().await?;
            // 4. The control: with the store kept, the resume's replay
            //    converges the returning member, holding the epoch's own
            //    secret. Run first — see the module docs.
            let caught_up = await_condition(bound + bounds::subscribe_ladder(), || async {
                Ok(epoch_of(world, stranded, &group).await?
                    == epoch_of(world, committer, &group).await?)
            })
            .await?;
            if caught_up && has_current_secret(world, stranded, &group).await? {
                canaries += 1;
            }
        }
        Store::Wiped => {
            // 1. The commit is really in every store before it is forgotten.
            if stored_on_every_plane(world, &commit.id).await? {
                canaries += 1;
            }
            for plane in world.relays_mut() {
                plane.apply(Fault::WipeStore).await?;
            }
            // 2. …and really gone from every one: read back, never assumed.
            if !stored_on_any_plane(world, &commit.id).await? {
                canaries += 1;
            }
            aim(world, stranded, Fault::Heal).await?;
            world.device_mut(stranded)?.come_online().await?;
            // 3. The witness, which took the commit live, is where the
            //    committer is.
            if await_condition(bound, || async {
                Ok(epoch_of(world, witness, &group).await?
                    == epoch_of(world, committer, &group).await?)
            })
            .await?
            {
                canaries += 1;
            }
        }
    }
    Ok(canaries)
}

/// The strand itself, and Haven's silence about it.
async fn strand<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    committer: DeviceTag,
    stranded: DeviceTag,
    circle_tag: CircleTag,
    tick: Duration,
    classified: &mut Vec<undecryptable::Verdict>,
) -> Result<usize, RigError> {
    let group = world.circle(circle_tag)?.mls_group_id().clone();
    let mut canaries = 0_usize;

    // 5. The known-bad, read once the world is QUIESCENT: the resume's
    //    generation has spent its EOSE, so the replay is over and "still
    //    below" is the settled outcome rather than a snapshot taken before the
    //    relay answered. The strand is one-directional at this distance: the
    //    committer's fix cannot be peeled by the stranded device, while the
    //    stranded device's own fix — sealed at an epoch the committer still
    //    keeps the secret for — is applied. The send path stays open, which is
    //    what makes the silence silent.
    let settled = quiescence::settle(world, Recovery::Undisturbed, tick).await?;
    let below =
        epoch_of(world, stranded, &group).await? < epoch_of(world, committer, &group).await?;
    let from_committer = seal(world, committer, &group, 1).await?;
    let stranded_reads =
        undecryptable::classify(world.device(stranded)?, &from_committer, StoredRow::Unknown)
            .await?;
    classified.push(stranded_reads);
    let committer_reads = match seal(world, stranded, &group, 2).await {
        Ok(from_stranded) => {
            let verdict = undecryptable::classify(
                world.device(committer)?,
                &from_stranded,
                StoredRow::Unknown,
            )
            .await?;
            classified.push(verdict);
            Some(verdict)
        }
        Err(_) => None,
    };
    if matches!(settled, Settled::Quiescent(_))
        && below
        && stranded_reads == undecryptable::Verdict::PeelFailed
        && committer_reads == Some(undecryptable::Verdict::Applied)
    {
        canaries += 1;
    }

    // 6. …and Haven says nothing about it. The OD-1 gap, recorded.
    world.drain_buses();
    if silent_about_the_strand(world, stranded, circle_tag) {
        canaries += 1;
    }
    Ok(canaries)
}

/// Waits out the delivery-silence window, driving the product's own health
/// repair throughout, and answers one canary: nothing named the circle across
/// the whole window and the device is still stranded when it ends.
async fn silence_held<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    committer: DeviceTag,
    stranded: DeviceTag,
    circle_tag: CircleTag,
) -> Result<usize, RigError> {
    let group = world.circle(circle_tag)?.mls_group_id().clone();
    let started = Instant::now();
    let mut ticker = tokio::time::interval(SILENCE_POLL);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    loop {
        // The repair that would notice a silent circle, if anything did.
        let _ = world
            .device(stranded)?
            .engine()?
            .maintain_subscription_health()
            .await;
        world.drain_buses();
        if !silent_about_the_strand(world, stranded, circle_tag) {
            return Ok(0);
        }
        if started.elapsed() >= bounds::silence_window() {
            break;
        }
        ticker.tick().await;
    }
    // 7. The window bought nothing: still stranded, still unnamed.
    let still_below =
        epoch_of(world, stranded, &group).await? < epoch_of(world, committer, &group).await?;
    Ok(usize::from(still_below))
}

/// Whether no device reports the circle unrecoverable on either surface, and
/// the stranded device's circle-health row reads back with no peer-event stamp.
///
/// The stamp is the app layer's: Dart writes it through
/// `CircleManagerFfi::note_peer_event` on every fix it draws, and nothing on
/// haven-core's own receive plane writes it. So at this tier the row is
/// readable and empty — the only evidence a stranded device could ever have is
/// a stamp that stops moving, and haven-core itself keeps none. A stamp
/// appearing here means haven-core started recording what it receives, and the
/// recorded expectation is stale.
fn silent_about_the_strand<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    stranded: DeviceTag,
    circle_tag: CircleTag,
) -> bool {
    let nobody_says_so = world.devices().iter().all(|device| {
        device.ledger().unrecoverable() == 0
            && device
                .manager()
                .is_ok_and(|manager| manager.unrecoverable_circles().is_empty())
    });
    let core_recorded_nothing = world.circle(circle_tag).is_ok_and(|circle| {
        world.device(stranded).is_ok_and(|device| {
            device.manager().is_ok_and(|manager| {
                manager
                    .circle_health(circle.nostr_group_id())
                    .is_ok_and(|health| health.last_peer_event_at_ms.is_none())
            })
        })
    });
    nobody_says_so && core_recorded_nothing
}

/// Applies `fault` to `device`'s own endpoint on every plane.
async fn aim<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    device: DeviceTag,
    fault: Fault,
) -> Result<(), RigError> {
    for plane in world.relays_mut() {
        plane.apply_for(device, fault).await?;
    }
    Ok(())
}

/// Whether every plane's store holds `event_id`.
async fn stored_on_every_plane<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    event_id: &EventId,
) -> Result<bool, RigError> {
    for plane in world.relays() {
        if !plane.stored(event_id).await? {
            return Ok(false);
        }
    }
    Ok(true)
}

/// Whether any plane's store holds `event_id`.
async fn stored_on_any_plane<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    event_id: &EventId,
) -> Result<bool, RigError> {
    for plane in world.relays() {
        if plane.stored(event_id).await? {
            return Ok(true);
        }
    }
    Ok(false)
}

/// One confirmed relay-list commit from `device`, carrying a relay list the
/// group does not already hold — a repeat is a no-op and advances no epoch.
async fn confirmed_commit<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    circle_tag: CircleTag,
    salt: &str,
) -> Result<Event, RigError> {
    let mut relays = world.relay_urls();
    relays.push(format!("wss://s03-{salt}.example.com"));
    let circle = world.circle(circle_tag)?;
    let (event, verdict) = relay_update(world, device, circle, &relays).await?;
    if verdict != PublishVerdict::Confirmed {
        // Nothing merged, so there is no commit to lose.
        return Err(RigError::PublishNeverAcked);
    }
    Ok(event)
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
            &ProbeToken::mint(PROBE_ROUND, index).as_location(),
            LOCATION_MESSAGE_RETENTION_SECS,
        )
        .await
        .map(|(event, _, _)| event)
        .map_err(|_| RigError::Core(Step::Publish))
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

/// Whether `device` holds the CURRENT epoch's exporter secret for `group`.
async fn has_current_secret<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    group: &GroupId,
) -> Result<bool, RigError> {
    world
        .device(device)?
        .session()?
        .has_current_exporter_secret(group)
        .await
        .map_err(|_| RigError::Core(Step::ReadEpoch))
}

#[cfg(test)]
mod tests {
    use super::{Store, ARMS, PROBE_ROUND};
    use crate::oracle::{bounds, Recovery};
    use crate::scenarios::Absence;

    #[test]
    fn both_arms_pay_for_a_resume_and_declare_the_same_three_faults() {
        for arm in &ARMS {
            assert!(
                arm.recovery == Recovery::Undisturbed,
                "a paused engine closes no socket, so the pool's ladder is not in the path"
            );
            assert!(
                arm.resubscribes,
                "the stranded device re-opens its own REQs, so the subscribe ladder is"
            );
            assert!(
                arm.floor.faults_applied == 3,
                "two handshake partitions and one wipe, on at least one plane"
            );
            assert!(
                arm.floor.epochs_crossed == 1,
                "the kept-store cycle alone crosses one, and the arm is about the second"
            );
        }
    }

    #[test]
    fn the_weekly_arm_adds_the_products_own_silence_window_and_one_canary() {
        assert!(
            ARMS[0].absence == Absence::None,
            "the nightly arm records the strand and waits out nothing"
        );
        assert!(
            ARMS[1].absence.window() == bounds::silence_window(),
            "the weekly arm waits out the whole delivery-silence window, unscaled"
        );
        assert!(
            ARMS[0].floor.canaries_caught == 6,
            "the kept-store control, the stored commit, the wiped commit, the witness's \
             convergence, the strand and Haven's silence about it"
        );
        assert!(
            ARMS[1].floor.canaries_caught == ARMS[0].floor.canaries_caught + 1,
            "the same six, and the silence held across the whole window"
        );
    }

    #[test]
    fn the_two_cycles_commit_different_relay_lists() {
        assert!(
            Store::Kept.salt() != Store::Wiped.salt(),
            "a repeated relay list is a no-op and advances no epoch"
        );
    }

    #[test]
    fn cross_decrypt_probes_are_stamped_outside_both_graded_rounds() {
        // A handed-over probe must never satisfy a graded round's own.
        const { assert!(PROBE_ROUND != 1 && PROBE_ROUND != 2) }
    }
}
