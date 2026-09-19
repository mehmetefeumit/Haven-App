//! **S13** — a device loses one group's `OpenMLS` state and reopens.
//!
//! The promise: hydration quarantine is per GROUP. A device that cannot load one
//! group's state freezes exactly that group for the life of the session and goes
//! on serving every other circle in the same store — it does not lose the store,
//! and it does not pretend the frozen group is fine.
//!
//! # The induction mechanism, and why it is allowed to fail loudly
//!
//! The engine sets the quarantine only at session open and offers no way to
//! induce one, so the only honest mechanism is to remove the rows the next open
//! hydrates from, on a CLOSED database, and reopen. The victim is identified by
//! set difference across one circle creation: `openmls_values.group_key` is an
//! opaque serde encoding, and decoding it here would be this crate holding a
//! real MLS group id. If that difference is not exactly one key, the pinned
//! engine's schema or key encoding has moved and the injection no longer aims at
//! what it names — which is the rig being broken (rc 2), never a finding about
//! the product.
//!
//! # The victim circle is not one of the world's
//!
//! It is created by this arm, joined by the same devices, and then broken. The
//! world's own circles stay healthy and readable, which is what lets the same
//! run assert both halves of the promise: the victim is frozen AND everything
//! else still converges and still sends.

use std::time::Duration;

use haven_core::circle::CircleManager;
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::storage::{
    delete_openmls_group_state_for_test, is_session_live, openmls_group_keys_for_test,
    OpenMlsGroupKey, StorageConfig,
};

use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{Invariant, Reach, Recovery};
use crate::rig::{poll_until, DeviceTag, LogDrain, RigError, Step, TimelineSink};
use crate::scenarios::{
    closing_pairs, grade_round, round, Absence, Arm, ArmOutcome, ScenarioWorld, WithheldAcks,
    NO_GATING_ROWS,
};

/// The arm this scenario offers.
pub const ARMS: [Arm; 1] = [Arm {
    label: "hydration-quarantine",
    recovery: Recovery::Undisturbed,
    probe_rounds: 1,
    resubscribes: true,
    absence: Absence::None,
    withheld_acks: WithheldAcks::None,
    floor: ExpectationFloor {
        faults_applied: 0,
        epochs_crossed: 0,
        deliveries_observed: 1,
        canaries_caught: 3,
    },
}];

/// How long the arm waits for a closed store to release its Rule-14 guard.
///
/// The same bound the rig's own restart uses, for the same reason: the guard
/// goes when the last task holding a manager handle finishes, which is not
/// instantaneous and is worth waiting for rather than racing.
const RELEASE_BOUND: Duration = Duration::from_secs(30);

/// How often that condition is re-read.
const RELEASE_POLL: Duration = Duration::from_millis(20);

/// Runs the arm.
///
/// # Errors
///
/// [`RigError::InductionMechanismMoved`] if the store's key set no longer says
/// which group a fresh circle added, or the delete matches no row — the schema
/// or the key encoding moved and this arm can no longer aim.
///
/// [`RigError::ShapeMismatch`] if the world has fewer than two devices or fewer
/// than two circles (there would be no healthy sibling to prove the quarantine
/// stayed scoped), or if the key set difference is not exactly one — the
/// induction mechanism no longer matches the pinned engine. Otherwise
/// [`RigError`] naming the step that failed.
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
    if world.circles().len() < 2 || world.devices().len() < 2 {
        return Err(RigError::ShapeMismatch);
    }
    // The device whose store is broken is never the admin: the admin creates
    // every circle in the world, and breaking its store would break the world
    // rather than one group in it.
    let victim = world
        .devices()
        .get(1)
        .map(|device| device.tag)
        .ok_or(RigError::ShapeMismatch)?;
    let sibling = world.circles().first().ok_or(RigError::ShapeMismatch)?.tag;
    let db = world.device(victim)?.session_db_path();
    let key = StorageConfig::test_sqlcipher_key().map_err(|_| RigError::Core(Step::OpenStore))?;

    let mut canaries = 0_usize;

    // Snapshot the store's group keys with the store CLOSED — Rule 14: a live
    // session holds its own connection and its own in-memory state.
    close(world, victim).await?;
    let before =
        openmls_group_keys_for_test(&db, &key).map_err(|_| RigError::Core(Step::OpenStore))?;
    reopen(world, victim).await?;

    // One more circle, joined by the same devices. It is the victim.
    //
    // Through the world, so it is DECLARED like every other value the run
    // minted: a circle built by the free function would carry two group ids and
    // a name the needle scan could never search for.
    let victim_circle = world.build_extra_circle().await?;

    close(world, victim).await?;
    let after =
        openmls_group_keys_for_test(&db, &key).map_err(|_| RigError::Core(Step::OpenStore))?;
    let added: Vec<OpenMlsGroupKey> = after
        .iter()
        .filter(|candidate| !before.contains(candidate))
        .cloned()
        .collect();
    // 1. Creating one circle adds exactly one group key. Anything else means
    //    the schema or the key encoding moved, and a delete aimed at a key this
    //    arm did not identify would be worse than no arm at all.
    let [victim_key] = added.as_slice() else {
        return Err(RigError::InductionMechanismMoved);
    };
    canaries += 1;

    let removed = delete_openmls_group_state_for_test(&db, &key, victim_key)
        .map_err(|_| RigError::Core(Step::OpenStore))?;
    if removed == 0 {
        // A key matching no row would make the reopen below vacuous: the
        // session would hydrate cleanly and the arm would report a quarantine
        // it never induced.
        return Err(RigError::InductionMechanismMoved);
    }
    reopen(world, victim).await?;

    // 2. That group, and only that group, is frozen for the life of the
    //    session.
    let quarantined = world
        .device(victim)?
        .session()?
        .quarantined_group_ids()
        .await;
    let sibling_group = world.circle(sibling)?.mls_group_id().clone();
    if quarantined.contains(victim_circle.mls_group_id()) && !quarantined.contains(&sibling_group) {
        canaries += 1;
    }

    // 3. …and the sibling circle in the SAME store still sends.
    let sends = world
        .device(victim)?
        .manager()?
        .encrypt_location(
            &sibling_group,
            &world.device(victim)?.keys.public_key(),
            &LocationMessage::new(7.5, 8.25),
            haven_core::location::LOCATION_MESSAGE_RETENTION_SECS,
        )
        .await
        .is_ok();
    if sends {
        canaries += 1;
    }

    // The world's own circles are untouched, so the whole registry still
    // applies to them: a quarantine that had frozen more than its group would
    // show up here rather than being asserted away. The REOPENED device sends
    // first: its epoch and exporter state were rebuilt from disk, and a reuse
    // there is invisible to it and visible only to a peer that cannot decrypt
    // what it produced.
    let pairs = closing_pairs(world, victim);
    let opened = [victim];
    let after_reopen = round(
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
        &after_reopen,
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

/// Closes one device's store and waits, bounded, for its Rule-14 guard to go.
///
/// The engine goes first and is DROPPED: it holds `Arc` clones of the manager,
/// and `stop` takes `&self`, so stopping alone releases nothing.
async fn close<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    device: DeviceTag,
) -> Result<(), RigError> {
    let db = world.device(device)?.session_db_path();
    let handle = world.device_mut(device)?;
    if let Some(core) = handle.take_engine() {
        let outcome = core.stop().await;
        drop(core);
        if outcome == haven_core::relay::live_sync::StopOutcome::TimedOut {
            return Err(RigError::StopTimedOut);
        }
    }
    drop(handle.take_manager());
    poll_until(RELEASE_BOUND, RELEASE_POLL, || async {
        is_session_live(&db)
            .map(|live| !live)
            .map_err(|_| RigError::Core(Step::ReadSessionLiveness))
    })
    .await?
    .ok_or(RigError::SessionStillLive)?;
    Ok(())
}

/// Reopens one device's store on the same directory and restarts its engine.
async fn reopen<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    device: DeviceTag,
) -> Result<(), RigError> {
    let handle = world.device_mut(device)?;
    let manager = CircleManager::new_unencrypted(handle.dir.path(), &handle.keys)
        .map_err(|_| RigError::Core(Step::OpenStore))?;
    handle.restore_manager(std::sync::Arc::new(manager));
    let specs = handle.specs().to_vec();
    handle.start_engine(specs).await
}

#[cfg(test)]
mod tests {
    use super::ARMS;

    #[test]
    fn the_arm_pays_for_a_resubscribe_and_demands_all_three_observations() {
        let arm = ARMS[0];
        assert!(
            arm.resubscribes,
            "the victim device re-opens its own REQs, so the ladder is in the path"
        );
        assert!(
            arm.floor.canaries_caught == 3,
            "the key difference, the scoped quarantine and the surviving sibling"
        );
        assert!(
            arm.floor.faults_applied == 0,
            "no relay is broken: the store is"
        );
    }
}
