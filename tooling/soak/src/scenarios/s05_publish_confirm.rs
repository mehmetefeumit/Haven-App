//! **S05** — the publish→confirm window, and what a failure inside it is NOT.
//!
//! Security Rule 13's newest clause has one shape and it is counter-intuitive:
//! an `Err` from `confirm_published` is **not** a publish failure. The relay
//! acknowledged the commit, the engine may already have merged it, and only the
//! replay that follows the merge failed — so rolling the commit back would
//! discard a commit the group may already have, and retrying it would apply one
//! twice. The disposition is: fold what the failing call already delivered,
//! return the original error, and leave the staged commit exactly as staged.
//!
//! # What the rig adds over the unit pin
//!
//! `haven-core`'s own `commit_gap_replay_e2e` proves the fold and
//! `security_rule_gates` pins the rung. What this arm adds is the same
//! disposition over a real relay: a commit that a relay really acknowledged, a
//! peer fix that really crossed a real MLS session, and a device that goes on
//! serving every other circle afterwards.
//!
//! # The victim circle is not one of the world's, and it stays staged
//!
//! A confirm that fails mid-replay leaves the group in its publish-before-apply
//! transition — measured, and asserted here as canary 5, because that is exactly
//! what a rollback would have undone. A circle in that state refuses sends, so
//! it may not be one a world-wide oracle grades: the arm would then be reporting
//! a violation Rule 13 itself requires. Both circles this arm uses are built
//! with `build_extra_circle`, which keeps them out of `world.circles()` for that
//! reason — and it is also why this arm declares `epochs_crossed: 0`, since
//! `Observed::measure` walks the world's table and cannot see them.
//!
//! # The other three arms
//!
//! §2.4 of the Phase-2 plan gives S05 three more arms — two app-kills inside the
//! window and the five OD4-c negative gates. They need an `AutoCommitPublisher`
//! double the rig does not have yet and land with it; this one needs no new
//! machinery, which is why it is here first.

use std::time::Duration;

use haven_core::location::LOCATION_MESSAGE_RETENTION_SECS;
use haven_core::nostr::mls::storage::{set_stored_message_write_fault_for_test, StorageConfig};
use nostr::Event;

use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{Invariant, ProbeToken, Reach, Recovery};
use crate::rig::{DeviceTag, LogDrain, RigError, SimCircle, Step, TimelineSink};
use crate::scenarios::{
    closing_pairs, grade_round, round, Absence, Arm, ArmOutcome, ScenarioWorld, WithheldAcks,
    NO_GATING_ROWS,
};

/// The arm this scenario offers today.
pub const ARMS: [Arm; 1] = [Arm {
    label: "confirm-err-is-not-a-failure",
    recovery: Recovery::Undisturbed,
    probe_rounds: 1,
    // Nothing restarts and nothing pauses: the failure is a storage fault
    // inside one call.
    resubscribes: false,
    absence: Absence::None,
    withheld_acks: WithheldAcks::None,
    floor: ExpectationFloor {
        // A storage fault is not something a relay plane does, so the plane's
        // own counter must stay at zero: an arm that reported one here would be
        // counting a fault it never applied.
        faults_applied: 0,
        // Both circles are outside the world's table (see the module docs), so
        // this term cannot see their epochs and the canaries carry the claims.
        epochs_crossed: 0,
        deliveries_observed: 1,
        canaries_caught: 5,
    },
}];

/// Runs the arm.
///
/// # Errors
///
/// [`RigError::UnknownTarget`] if the label is not the one this scenario
/// offers, [`RigError::PublishNeverAcked`] if no relay acknowledged the commit —
/// Rule 13 then forbids confirming it, so there is no confirm that could fail —
/// otherwise [`RigError`] naming the step that failed.
pub(crate) async fn run<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    arm: &Arm,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    if arm.label != ARMS[0].label {
        // A label this scenario does not offer means the dispatch table and the
        // registry disagree, which is the rig being wrong about itself.
        return Err(RigError::UnknownTarget);
    }
    let tags: Vec<DeviceTag> = world.devices().iter().map(|device| device.tag).collect();
    let [admin, peer, ..] = *tags.as_slice() else {
        return Err(RigError::ShapeMismatch);
    };

    let canaries = confirm_err(world, admin, peer).await?;

    // Graded over the WORLD's circles, which this arm never touches: the
    // failure is scoped to one circle's transition, and the device goes on
    // serving every other one.
    let pairs = closing_pairs(world, admin);
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

/// Forces one `confirm_published` to fail after the engine has already
/// delivered, and reads what the product did with the wreckage.
///
/// # How the failure is induced, and why it is the honest shape
///
/// The engine writes each replayed message's terminal state through its stored
/// message table AFTER it has pushed that message's decrypted content into its
/// own effect buffer. An abort trigger on that table therefore reproduces
/// exactly the state a mid-replay fork abort produces — a caller that gets an
/// `Err` and no effects, with a peer's fix already delivered into a buffer only
/// the next drain will ever see — without having to build two sibling commits to
/// get there.
///
/// The stranded fix is minted for a SECOND circle on purpose. The engine's
/// effect buffers are global, so one failing resolution drains every circle's
/// work; keying the assertion on a circle other than the one whose commit is
/// staged is what makes "the batch was folded" a claim about the drain rather
/// than about the commit.
async fn confirm_err<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    admin: DeviceTag,
    peer: DeviceTag,
) -> Result<usize, RigError> {
    let victim = world.build_extra_circle().await?;
    let sibling = world.build_extra_circle().await?;
    let db = world.device(admin)?.session_db_path();
    let key = StorageConfig::test_sqlcipher_key().map_err(|_| RigError::Core(Step::OpenStore))?;
    let mut canaries = 0_usize;

    let mut relays = world.relay_urls();
    relays.push("wss://s05-confirm-err.example.com".to_string());
    let guard = world.note_pending_staged();
    let staged = world
        .device(admin)?
        .manager()?
        .update_circle_relays(victim.mls_group_id(), &relays)
        .await
        .map_err(|_| RigError::Core(Step::StageCommit))?;

    // 1. The window is real: with the commit staged and unresolved, the
    //    circle's own outbound path is held shut until Rule 13 says what
    //    happened to the publish.
    if seal(world, admin, &victim, 1).await.is_err() {
        canaries += 1;
    }

    // Rule 13: only an acknowledgement a relay's own client-facing stream
    // carried licenses a confirm.
    if world
        .publish_witnessed(admin, std::slice::from_ref(&staged.commit_event))
        .await?
        .is_none()
    {
        let ingest = world
            .device(admin)?
            .manager()?
            .publish_failed(staged.pending)
            .await
            .map_err(|_| RigError::Core(Step::RollBackPublish))?;
        world.resolve_ingest(admin, ingest).await?;
        drop(guard);
        return Err(RigError::PublishNeverAcked);
    }

    set_stored_message_write_fault_for_test(&db, &key, true)
        .map_err(|_| RigError::Core(Step::OpenStore))?;
    // A peer's fix for the OTHER circle, ingested while the fault stands: the
    // ingest aborts on the state write with the content already in the engine's
    // buffer. Deliberately NOT classified — a storage fault this arm induced is
    // not an ingest disposition, and feeding it to O5 would report the harness's
    // own plant as an outcome the product could not account for.
    let stranded = seal(world, peer, &sibling, 2).await?;
    let refused = world
        .device(admin)?
        .session()?
        .process_event_typed_for_test(&stranded)
        .await
        .is_err();
    // 2. The strand's premise: the fault really did abort that ingest.
    if refused {
        canaries += 1;
    }

    let outcome = world
        .device(admin)?
        .manager()?
        .confirm_published(staged.pending)
        .await;
    set_stored_message_write_fault_for_test(&db, &key, false)
        .map_err(|_| RigError::Core(Step::OpenStore))?;
    // The pending state is NOT resolved, and that is the point of the arm: Rule
    // 13 forbids turning this error into a `publish_failed`. The rig's own
    // staged-commit count may not outlive the call, or the closing round could
    // never settle — so the guard goes here and the engine's staged commit
    // stays, which canary 5 reads back.
    drop(guard);

    // 3. The confirm really failed.
    if outcome.is_err() {
        canaries += 1;
    }
    // 4. …and the fix the engine had already delivered is in the durable store
    //    anyway, written by the failing call's own drain. Nothing will ever
    //    deliver it again: the engine hands a replayed message back exactly
    //    once.
    if folded(world, admin, peer, &sibling)? {
        canaries += 1;
    }
    // 5. …and nothing was rolled back or retried: the commit is still staged,
    //    which is precisely what a `publish_failed` would have undone, and the
    //    device reports no circle unrecoverable over it.
    let still_staged = seal(world, admin, &victim, 3).await.is_err();
    let quiet = world
        .device(admin)?
        .manager()?
        .unrecoverable_circles()
        .is_empty();
    if still_staged && quiet {
        canaries += 1;
    }
    Ok(canaries)
}

/// Whether `peer`'s fix for `circle` reached `admin`'s durable last-known store.
fn folded<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    admin: DeviceTag,
    peer: DeviceTag,
    circle: &SimCircle,
) -> Result<bool, RigError> {
    let peer_hex = world.device(peer)?.pubkey_hex();
    let rows = world
        .device(admin)?
        .manager()?
        .snapshot_last_known_for_circle(
            circle.nostr_group_id(),
            crate::clock::WallNow::now().secs(),
        )
        .map_err(|_| RigError::Core(Step::OpenStore))?;
    Ok(rows.iter().any(|row| row.sender_pubkey == peer_hex))
}

/// Seals one location for `circle` at `device`'s current epoch, unpublished.
async fn seal<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    circle: &SimCircle,
    index: u32,
) -> Result<Event, RigError> {
    let sender = world.device(device)?;
    sender
        .manager()?
        .encrypt_location(
            circle.mls_group_id(),
            &sender.keys.public_key(),
            &ProbeToken::mint(5, index).as_location(),
            LOCATION_MESSAGE_RETENTION_SECS,
        )
        .await
        .map(|(event, _, _)| event)
        .map_err(|_| RigError::Core(Step::Publish))
}

#[cfg(test)]
mod tests {
    use super::ARMS;
    use crate::oracle::Recovery;

    #[test]
    fn the_arm_breaks_no_relay_and_demands_all_five_observations() {
        let arm = ARMS[0];
        assert!(
            arm.recovery == Recovery::Undisturbed,
            "nothing is unplugged: the failure is a storage abort inside one call"
        );
        assert!(
            arm.floor.faults_applied == 0,
            "a storage fault is not something a relay plane does"
        );
        assert!(
            !arm.resubscribes,
            "no device re-opens a REQ, so the subscribe ladder is not in the bound"
        );
        assert!(
            arm.floor.canaries_caught == 5,
            "the window, the strand, the error, the fold, and the commit that was \
             neither rolled back nor retried"
        );
        assert!(
            arm.floor.deliveries_observed == 1,
            "the closing round over the world's own circles still has to deliver"
        );
    }
}
