//! **S26** — the identity planes under a fault.
//!
//! Every device publishes its profile to its profile pool while one profile
//! relay is down, and once it is back sends the owed event to that relay
//! alone; every peer reads it back, and every member's key package is looked
//! up where it published it.
//!
//! The promise is the plane separation (Rule 10), and O7 is what grades it
//! here: a device's kind 0 and its profile lookups reach the profile planes
//! and nothing else, its key package its own key-package plane, a lookup of
//! somebody else's the relay that somebody named — while the fault sends the
//! product down its retry ladders. The arm declares the profile plane driven
//! ([`crate::rig::SimWorld::exercise_profile`]), so O7 also requires it to
//! have carried a profile publish and a profile lookup.
//!
//! # The pool is the world's, by the product's own exclusion
//!
//! A device's profile pool is its Profile rows united with the curated public
//! pool, less every relay its contamination ledger names. The arm adds each
//! curated relay as an Inbox row and removes it again: the ledger is
//! append-only, so the curated relays are excluded for good and no row names
//! them. Nothing is dialled before the pool is read back and found to be the
//! world's own profile planes; a pool naming anything else is the induction
//! failing, refused before a byte leaves (rc 2).
//!
//! # Discovery is never reached
//!
//! The key-package lookup asks the member's own key-package relay first; only
//! an empty answer would fall to the discovery plane, which a soak process
//! points at a port that refuses every dial.
//!
//! # The control
//!
//! [`no_pool_control`] runs the same arm with no Profile row: the pool
//! underflows, the product publishes nothing and reads nothing — fail-closed,
//! and the curated pool still excluded, so nothing leaves the machine — and
//! the arm answers rc 3.

use std::time::Duration;

use haven_core::circle::{ProfileSyncOutcome, RelayType};
use haven_core::profile::{
    fetch_profiles_assigned, profile_relay_pool_default, PendingEdits, ProfileRelaySalt,
    PROFILE_MAX_RELAY_RANK, PROFILE_POOL_MIN,
};
use haven_core::relay::{canonicalize, MemberLookup, RelayManager};
use nostr::{PublicKey, Timestamp};

use crate::nemesis::types::Fault;
use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{Invariant, Reach, Recovery};
use crate::rig::{
    DeviceTag, LogDrain, RelayPlane, RelayTag, RigError, SimDevice, Step, TimelineSink,
};
use crate::scenarios::{
    closing_pairs, grade_round, round, Absence, Arm, ArmOutcome, Scenario, ScenarioReport,
    ScenarioWorld, WithheldAcks, NO_GATING_ROWS,
};

/// The arm this scenario offers.
pub const ARMS: [Arm; 1] = [Arm {
    label: "identity-planes-under-faults",
    recovery: Recovery::Undisturbed,
    probe_rounds: 1,
    resubscribes: false,
    absence: Absence::None,
    withheld_acks: WithheldAcks::IdentityTurns,
    floor: ExpectationFloor {
        faults_applied: 1,
        epochs_crossed: 0,
        deliveries_observed: 1,
        canaries_caught: 4,
    },
}];

/// Runs the arm.
///
/// # Errors
///
/// [`RigError::ShapeMismatch`] if the world has fewer than two devices or a
/// profile pool the product would refuse; [`RigError::InductionMechanismMoved`]
/// if a device's pool is anything but the world's profile planes; otherwise
/// [`RigError`] naming the step that failed.
pub(crate) async fn run<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    arm: &Arm,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    if arm.label != ARMS[0].label {
        return Err(RigError::UnknownTarget);
    }
    identity_planes(world, tick, true).await
}

/// The arm with no Profile row: the pool underflows and nothing is published
/// or read. `tests/oracles.rs` requires rc 3.
///
/// # Errors
///
/// As [`run`].
pub async fn no_pool_control<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    tick: Duration,
) -> Result<ScenarioReport, RigError> {
    let started = tokio::time::Instant::now();
    let mut outcome = identity_planes(world, tick, false).await?;
    outcome.graded.push((
        Invariant::RelayPlaneContainment,
        crate::oracle::planes::plane_containment(world)?,
    ));
    Ok(Scenario::IdentityPlanes.report(world, &ARMS[0], outcome, started))
}

async fn identity_planes<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    tick: Duration,
    pooled: bool,
) -> Result<ArmOutcome, RigError> {
    let tags: Vec<DeviceTag> = world.devices().iter().map(|device| device.tag).collect();
    let planes = world.profile_relays().len();
    let (Some(&admin), true) = (tags.first(), tags.len() >= 2 && planes >= PROFILE_POOL_MIN) else {
        return Err(RigError::ShapeMismatch);
    };
    for &tag in &tags {
        own_pool(world, tag, pooled)?;
    }
    world.exercise_profile();
    let now = i64::try_from(Timestamp::now().as_secs()).map_err(|_| RigError::ShapeMismatch)?;
    let mut canaries = 0_usize;

    // 1. Every device publishes with one profile relay down: the product
    //    publishes to its whole pool, the up relays acknowledge, and the event
    //    stays owed to the down one.
    let down = world.profile_relays()[0].tag();
    world.plane_mut(down)?.apply(Fault::Down).await?;
    let mut published = 0_usize;
    for &tag in &tags {
        let name = name_of(tag);
        world.declare_name(&name)?;
        let device = world.device(tag)?;
        let manager = device.manager()?;
        let edits = PendingEdits {
            display_name: Some(name),
            ..PendingEdits::default()
        };
        manager
            .stage_own_profile_edits(&device.pubkey_hex(), &edits, now)
            .map_err(|_| RigError::Core(Step::Publish))?;
        let synced = manager
            .sync_own_profile(&device.keys.public_key(), Some(&device.keys), || now)
            .await
            .map_err(|_| RigError::Core(Step::Publish))?;
        if synced.outcome == ProfileSyncOutcome::Published && synced.still_pending {
            published += 1;
        }
    }
    world.plane_mut(down)?.apply(Fault::Heal).await?;
    if published == tags.len() {
        canaries += 1;
    }

    // 2. Back up, the healed relay is the only one sent anything: each device
    //    re-sends the owed event to it alone, reads it back, and is done.
    if healed_relay_alone_completes(world, &tags, down, now).await? {
        canaries += 1;
    }

    // 3. Every device reads every peer's profile, walking the product's own
    //    retry ladder past the relay that missed the publish.
    let mut read = 0_usize;
    for &reader in &tags {
        let device = world.device(reader)?;
        let Ok(pool) = device.manager()?.usable_profile_relays() else {
            continue;
        };
        let salt = device
            .manager()?
            .profile_relay_salt()
            .map_err(|_| RigError::Core(Step::OpenStore))?;
        for &author in tags.iter().filter(|&&author| author != reader) {
            let key = world.device(author)?.keys.public_key();
            if read_profile(device, (&pool, &salt), key, &name_of(author), now).await {
                read += 1;
            }
        }
    }
    if read == tags.len() * (tags.len() - 1) {
        canaries += 1;
    }

    // 4. Every member's key package, published to its own key-package plane,
    //    is found there by the admin's invite lookup.
    let mut found = 0_usize;
    for &member in tags.iter().filter(|&&member| member != admin) {
        if key_package_found(world, admin, member).await? {
            found += 1;
        }
    }
    if found == tags.len() - 1 {
        canaries += 1;
    }

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

/// Whether a second sync of every device completes the owed event while the
/// healed relay `down` is the only profile plane sent anything.
async fn healed_relay_alone_completes<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    tags: &[DeviceTag],
    down: RelayTag,
    now: i64,
) -> Result<bool, RigError> {
    let before = profile_traffic(world);
    let mut completed = 0_usize;
    for &tag in tags {
        let device = world.device(tag)?;
        let synced = device
            .manager()?
            .sync_own_profile(&device.keys.public_key(), Some(&device.keys), || now)
            .await
            .map_err(|_| RigError::Core(Step::Publish))?;
        if synced.outcome == ProfileSyncOutcome::Published && !synced.still_pending {
            completed += 1;
        }
    }
    let after = profile_traffic(world);
    let only_the_healed = world
        .profile_relays()
        .iter()
        .zip(before.iter().zip(&after))
        .all(|(plane, (before, after))| match (before, after) {
            (Some(before), Some(after)) if plane.tag() == down => after > before,
            (Some(before), Some(after)) => after == before,
            _ => false,
        });
    Ok(completed == tags.len() && only_the_healed)
}

/// Every `REQ` and `EVENT` frame each profile plane has been sent, in plane
/// order; `None` for a plane that records no frames.
fn profile_traffic<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
) -> Vec<Option<usize>> {
    world
        .profile_relays()
        .iter()
        .map(|plane| {
            plane.plane_ledger().map(|ledger| {
                ledger.reqs()
                    + ledger
                        .published_ids()
                        .iter()
                        .map(|id| ledger.published(id))
                        .sum::<usize>()
            })
        })
        .collect()
}

/// The display name `tag` publishes. Not a rig handle, for a circle name's
/// reason (`rig/circle.rs`), and declared before it is published.
fn name_of(tag: DeviceTag) -> String {
    format!("soak-profile-{}", tag.ordinal())
}

/// Gives `tag` the rows its pool is resolved from: its inbox, the curated
/// pool added and removed as Inbox so the ledger excludes it, and — `pooled`
/// — its own endpoint on every profile plane. Then refuses a pool that names
/// anything else.
fn own_pool<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    tag: DeviceTag,
    pooled: bool,
) -> Result<(), RigError> {
    let device = world.device(tag)?;
    let manager = device.manager()?;
    let row = |_| RigError::Core(Step::OpenStore);
    let inbox = device
        .stored_inbox()
        .first()
        .ok_or(RigError::ShapeMismatch)?;
    manager
        .add_user_relay(inbox, RelayType::Inbox)
        .map_err(row)?;
    for curated in profile_relay_pool_default() {
        manager
            .add_user_relay(&curated, RelayType::Inbox)
            .map_err(row)?;
        manager
            .remove_user_relay(&curated, RelayType::Inbox)
            .map_err(row)?;
    }
    let own: Vec<String> = world
        .profile_relays()
        .iter()
        .map(|plane| canonicalize(plane.url_for(tag)))
        .collect();
    if pooled {
        for url in &own {
            manager
                .add_user_relay(url, RelayType::Profile)
                .map_err(row)?;
        }
    }
    match manager.usable_profile_relays() {
        Ok(pool) if pooled && pool.iter().all(|url| own.contains(&canonicalize(url))) => Ok(()),
        Err(_) if !pooled => Ok(()),
        _ => Err(RigError::InductionMechanismMoved),
    }
}

/// Whether `reader` resolves `author`'s profile as `name`, asking each rung
/// of the product's retry ladder in turn while the last one missed.
async fn read_profile(
    reader: &SimDevice,
    (pool, salt): (&[String], &ProfileRelaySalt),
    author: PublicKey,
    name: &str,
    now: i64,
) -> bool {
    for rung in 0..=PROFILE_MAX_RELAY_RANK {
        let Ok(rung) = u8::try_from(rung) else {
            return false;
        };
        let Ok(fetched) =
            fetch_profiles_assigned(&reader.relays, &[(author, rung)], salt, pool, now).await
        else {
            return false;
        };
        if fetched
            .resolved
            .iter()
            .any(|profile| profile.metadata.display_name() == Some(name))
        {
            return true;
        }
        if fetched.missed.is_empty() {
            return false;
        }
    }
    false
}

/// Whether `admin`'s invite lookup finds the key package `member` just
/// published to its own key-package plane, on the relays `member` lists.
async fn key_package_found<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    admin: DeviceTag,
    member: DeviceTag,
) -> Result<bool, RigError> {
    let device = world.device(member)?;
    let built = device.mint_key_package().await?;
    if world
        .publish_witnessed(member, std::slice::from_ref(&built))
        .await?
        .is_none()
    {
        return Ok(false);
    }
    device
        .session()?
        .promote_key_package(&built.id)
        .await
        .map_err(|_| RigError::Core(Step::MintKeyPackage))?;
    let looking = world.device(admin)?;
    let admission = looking
        .session()?
        .key_package_admission_rule(None)
        .await
        .map_err(|_| RigError::Core(Step::MintKeyPackage))?;
    let found = RelayManager::lookup_key_package_on(
        &device.pubkey_hex(),
        device.stored_key_package(),
        &admission,
    )
    .await
    .map_err(|_| RigError::Core(Step::Publish))?;
    Ok(matches!(found, MemberLookup::Found(member) if member.key_package_event.id == built.id))
}

#[cfg(test)]
mod tests {
    use super::{name_of, ARMS};
    use crate::rig::DeviceTag;
    use crate::scenarios::WithheldAcks;

    #[test]
    fn the_arm_takes_one_fault_and_pays_one_identity_turn_per_member() {
        assert_eq!(ARMS[0].floor.faults_applied, 1);
        assert_eq!(ARMS[0].floor.canaries_caught, 4);
        assert_eq!(ARMS[0].withheld_acks, WithheldAcks::IdentityTurns);
    }

    #[test]
    fn a_published_name_is_never_a_rig_handle() {
        let name = name_of(DeviceTag::new(2));
        assert!(!name.contains('#'), "{name}");
        assert!(!name.contains("simdev"), "{name}");
    }
}
