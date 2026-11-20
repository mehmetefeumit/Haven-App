//! **S27** — a Welcome to an inbox whose first relay will not serve it.
//!
//! The invitee lists two inbox relays, the first of them gated as
//! `relay.damus.io` gates gift wraps (`Fault::AuthGatedReads`: kind-1059
//! reads refused to a client that has not authenticated — and to the live
//! inbox socket, which answers the challenge (Security Rule 16), since the
//! gate accepts no answer; writes taken). The admin finds the invitee
//! with the product's lookup on its key-package relay, takes the inbox list
//! the invitee published, and invites it through its driver. The promise: the Welcome reaches every
//! inbox relay, so the invitee's own live inbox plane reads it from the
//! second and the invitee joins — a Welcome sent to the first relay alone
//! would sit there unread for good.
//!
//! Then both relays are gated and the admin invites again: the product's
//! anonymous per-relay read of the inbox
//! (`RelayManager::fetch_events_per_relay`, answering no challenge) is typed
//! `refused` on both, both relays hold the Welcome, neither ever hands it to
//! the invitee, and the invitee does not join. The Invitations page's own read
//! answers the challenge (A5) and is not what this rig makes; haven-core's
//! `own_inbox_read_e2e` proves it. Anchored on what the planes recorded — the
//! gate's refusals, the relays' own acknowledgements of the Welcome, the
//! deliveries they never made — and never on elapsed time.
//!
//! # The floor
//!
//! Two gates applied, a delivery observed, and five canaries: the gate fired
//! on the invitee's own inbox REQ; the gated relay acknowledged the Welcome
//! (it really held a copy); the invitee joined through its live plane; both
//! reads came back refused with nothing served; the second Welcome was held
//! by both relays and delivered by neither. A gate that never fired is rc 3:
//! [`ungated_control`] runs the arm with no gate at all.
//!
//! # Where the lists live
//!
//! The product's full lookup reads the invitee's inbox list from the
//! discovery plane, which a soak process holds dead; the admin therefore asks
//! the product for the key package on the invitee's key-package relay
//! (`lookup_key_package_on`, S26's pattern) and reads the kind-10050 the
//! invitee published from its own account relay. The inbox list the Welcome
//! goes to is the one the invitee published, never `stored_inbox()`.

use std::time::Duration;

use haven_core::circle::{MemberKeyPackage, RelayType};
use haven_core::nostr::mls::types::GroupId;
use haven_core::relay::{build_relay_list_event, MemberLookup, RelayManager};
use nostr::{Event, EventId, Filter, JsonUtil, Kind};

use crate::nemesis::types::Fault;
use crate::oracle::bounds;
use crate::oracle::vacuity::{Canaries, ExpectationFloor, Observed};
use crate::oracle::Recovery;
use crate::rig::{
    poll_until, DeviceTag, LogDrain, RelayPlane, RelayTag, RigError, Step, TimelineSink,
};
use crate::scenarios::{
    await_condition, Absence, Arm, ArmOutcome, Scenario, ScenarioReport, ScenarioWorld,
    WithheldAcks, CONDITION_POLL,
};

/// The arm this scenario offers.
pub const ARMS: [Arm; 1] = [Arm {
    label: "gated-inbox-welcome",
    recovery: Recovery::Undisturbed,
    // The Welcome's way to the invitee's live plane: one round trip.
    probe_rounds: 1,
    // The invitee's engine reopens its inbox REQs on the new list.
    resubscribes: true,
    absence: Absence::None,
    withheld_acks: WithheldAcks::None,
    floor: ExpectationFloor {
        faults_applied: 2,
        epochs_crossed: 0,
        deliveries_observed: 1,
        canaries_caught: 5,
    },
}];

/// Runs the arm.
///
/// # Errors
///
/// [`RigError::ShapeMismatch`] in a world with fewer than two devices or two
/// account relays; [`RigError::InductionMechanismMoved`] if the lookup or the
/// published inbox list are not what the arm staged; otherwise [`RigError`]
/// naming the step that failed.
pub(crate) async fn run<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    arm: &Arm,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    if arm.label != ARMS[0].label {
        return Err(RigError::UnknownTarget);
    }
    gated_inbox_welcome(world, tick, true).await
}

/// The arm with no gate: every read is served, so the gate never fires, the
/// second Welcome is delivered, and the floor is unmet. `tests/oracles.rs`
/// requires rc 3.
///
/// # Errors
///
/// As [`run`].
pub async fn ungated_control<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    tick: Duration,
) -> Result<ScenarioReport, RigError> {
    let started = tokio::time::Instant::now();
    let mut outcome = gated_inbox_welcome(world, tick, false).await?;
    outcome.graded.push((
        crate::oracle::Invariant::RelayPlaneContainment,
        crate::oracle::planes::plane_containment(world)?,
    ));
    Ok(Scenario::GatedInboxWelcome.report(world, &ARMS[0], outcome, started))
}

async fn gated_inbox_welcome<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    tick: Duration,
    gated: bool,
) -> Result<ArmOutcome, RigError> {
    let tags: Vec<DeviceTag> = world.devices().iter().map(|device| device.tag).collect();
    let (&[admin, invitee, ..], [first, second]) = (tags.as_slice(), world.account_relays()) else {
        return Err(RigError::ShapeMismatch);
    };
    let (first, second) = (first.tag(), second.tag());
    let canonical: Vec<String> = world
        .account_relays()
        .iter()
        .map(|plane| plane.url().to_owned())
        .collect();
    let own: Vec<String> = world
        .account_relays()
        .iter()
        .map(|plane| plane.url_for(invitee).to_owned())
        .collect();
    let mut canaries = Canaries::new();

    // 1. The invitee lists both relays, the first one first, and publishes
    //    the list where the account plane keeps it.
    let device = world.device(invitee)?;
    let list = build_relay_list_event(&device.keys, RelayType::Inbox, &canonical, None)
        .map_err(|_| RigError::Core(Step::Publish))?;
    if world
        .publish_witnessed(invitee, std::slice::from_ref(&list))
        .await?
        .is_none()
    {
        return Err(RigError::Core(Step::Publish));
    }

    // 2. The first relay is gated before the invitee's engine opens its inbox
    //    REQs on the new list, so the gate meets a REQ of its own.
    if gated {
        world.plane_mut(first)?.apply(Fault::AuthGatedReads).await?;
    }
    world
        .device_mut(invitee)?
        .reopen_inbox(own, canonical.clone())
        .await?;
    let fired = poll_until(bounds::subscribe_ladder(), CONDITION_POLL, || async {
        Ok(ledger_of(world, first).is_some_and(|ledger| ledger.gated_refusals(Some(invitee)) > 0))
    })
    .await?;
    canaries.check(fired.is_some());

    // 3. The admin invites it, and the invitee's live plane takes the Welcome.
    let (group, welcome) = invite(world, admin, invitee, &canonical).await?;
    canaries.check(acknowledged(world, first, &welcome));
    canaries.check(joined_live(world, invitee, &group).await?);

    // 4. Both relays gated: the second Welcome reaches both and neither ever
    //    hands it over.
    if gated {
        world
            .plane_mut(second)?
            .apply(Fault::AuthGatedReads)
            .await?;
    }
    let (_, held) = invite(world, admin, invitee, &canonical).await?;
    canaries.check(refused_everywhere(world, invitee, &canonical).await?);
    let undelivered = [first, second].iter().all(|&plane| {
        acknowledged(world, plane, &held)
            && ledger_of(world, plane).is_some_and(|ledger| !ledger.delivered_to(invitee, &held))
    });
    world.drain_buses();
    let handed_up = world
        .device_mut(invitee)?
        .take_welcome_wraps()
        .iter()
        .any(|json| Event::from_json(json).is_ok_and(|wrap| wrap.id == held));
    canaries.check(undelivered && !handed_up);

    for plane in [first, second] {
        world.plane_mut(plane)?.apply(Fault::Heal).await?;
    }
    world.drain_buses();
    let observed = Observed::measure(world, canaries).await?;
    // The arm's own subject is its floor; O7 is graded over its whole wire by
    // `Scenario::run`.
    Ok(ArmOutcome {
        graded: Vec::new(),
        observed,
        tick,
    })
}

/// The admin looks the invitee up, takes the inbox list it published, and
/// founds a circle inviting it: the circle's group and the Welcome's id.
async fn invite<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    admin: DeviceTag,
    invitee: DeviceTag,
    listed: &[String],
) -> Result<(GroupId, EventId), RigError> {
    // Minted in a second of its own: a lookup ranks packages by `created_at`,
    // and one sharing a second with an earlier package of this device would
    // be told apart by its id alone.
    let started = crate::clock::WallNow::now().secs();
    if !await_condition(bounds::wall_second_turnover(), || async {
        Ok(crate::clock::WallNow::now().secs() > started)
    })
    .await?
    {
        return Err(RigError::Core(Step::MintKeyPackage));
    }
    let device = world.device(invitee)?;
    let built = device.mint_key_package().await?;
    if world
        .publish_witnessed(invitee, std::slice::from_ref(&built))
        .await?
        .is_none()
    {
        return Err(RigError::Core(Step::MintKeyPackage));
    }
    let acked_at = device.policy_now(crate::clock::WallNow::now())?.secs();
    device
        .session()?
        .promote_key_package(&built.id, acked_at)
        .await
        .map_err(|_| RigError::Core(Step::MintKeyPackage))?;

    let looking = world.device(admin)?;
    let admission = looking
        .session()?
        .key_package_admission_rule(None)
        .await
        .map_err(|_| RigError::Core(Step::MintKeyPackage))?;
    let MemberLookup::Found(found) = RelayManager::lookup_key_package_on(
        &device.pubkey_hex(),
        device.stored_key_package(),
        &admission,
    )
    .await
    .map_err(|_| RigError::Core(Step::Publish))?
    else {
        return Err(RigError::InductionMechanismMoved);
    };
    if found.key_package_event.id != built.id {
        return Err(RigError::InductionMechanismMoved);
    }
    let inbox = published_inbox(world, admin, invitee).await?;
    if inbox != listed {
        return Err(RigError::InductionMechanismMoved);
    }
    let member = MemberKeyPackage {
        inbox_relays: inbox,
        ..*found
    };

    let before = gift_wraps_held(world);
    let (group, _) = world.invite_to_new_circle(admin, vec![member]).await?;
    let welcome = gift_wraps_held(world)
        .into_iter()
        .find(|id| !before.contains(id))
        .ok_or(RigError::WelcomeNeverAcked)?;
    Ok((group, welcome))
}

/// The newest kind-10050 the invitee published, read where it published it:
/// the relays its `relay` tags name, in order.
async fn published_inbox<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    admin: DeviceTag,
    invitee: DeviceTag,
) -> Result<Vec<String>, RigError> {
    let author = world.device(invitee)?.keys.public_key();
    let filter = Filter::new()
        .kind(Kind::InboxRelays)
        .author(author)
        .limit(1);
    let first = world
        .account_relays()
        .first()
        .map(|plane| plane.url().to_owned())
        .ok_or(RigError::ShapeMismatch)?;
    let lists = world
        .device(admin)?
        .relays
        .fetch_events(
            filter,
            &[first],
            Some(bounds::round_trip(Recovery::Undisturbed)),
        )
        .await
        .map_err(|_| RigError::Core(Step::Publish))?;
    let newest = lists
        .into_iter()
        .filter(|list| list.pubkey == author)
        .max_by_key(|list| list.created_at)
        .ok_or(RigError::InductionMechanismMoved)?;
    Ok(newest
        .tags
        .iter()
        .filter_map(|tag| match tag.as_slice() {
            [name, url, ..] if name == "relay" => Some(url.clone()),
            _ => None,
        })
        .collect())
}

/// Every event id an account plane took a write of: a create's Welcome is the
/// one new among them.
fn gift_wraps_held<T: TimelineSink, L: LogDrain>(world: &ScenarioWorld<T, L>) -> Vec<EventId> {
    world
        .account_relays()
        .iter()
        .filter_map(RelayPlane::plane_ledger)
        .flat_map(crate::relay::Ledger::published_ids)
        .collect()
}

/// The plane `tag` names.
fn plane_of<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    tag: RelayTag,
) -> Option<&crate::relay::SimRelay> {
    world.all_planes().find(|plane| plane.tag() == tag)
}

/// What the plane `tag` names recorded.
fn ledger_of<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    tag: RelayTag,
) -> Option<&crate::relay::Ledger> {
    plane_of(world, tag).and_then(RelayPlane::plane_ledger)
}

/// Whether `plane` acknowledged `event` to the publisher: it holds it.
fn acknowledged<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    plane: RelayTag,
    event: &EventId,
) -> bool {
    plane_of(world, plane).is_some_and(|plane| plane.witnessed_ok(event))
}

/// Whether the invitee's engine handed up a Welcome for `group` and the
/// invitee joined through it, within one round trip — the app's way: the bus
/// carries the gift wrap, the app processes and accepts it.
async fn joined_live<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    invitee: DeviceTag,
    group: &GroupId,
) -> Result<bool, RigError> {
    let mut wraps: Vec<String> = Vec::new();
    let deadline = tokio::time::Instant::now() + bounds::round_trip(Recovery::Undisturbed);
    // `poll_until`'s ticker, inline: the condition needs the world mutably to
    // drain the bus.
    let mut ticker = tokio::time::interval(CONDITION_POLL);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        ticker.tick().await;
        world.drain_buses();
        wraps.extend(world.device_mut(invitee)?.take_welcome_wraps());
        let device = world.device(invitee)?;
        let manager = device.manager()?;
        for json in std::mem::take(&mut wraps) {
            let Ok(wrap) = Event::from_json(&json) else {
                continue;
            };
            if manager
                .process_gift_wrapped_invitation(&device.keys, &wrap)
                .await
                .is_err()
            {
                continue;
            }
            let joined = manager
                .accept_invitation(&wrap.id)
                .await
                .map_err(|_| RigError::Core(Step::AcceptInvitation))?;
            if joined.circle.mls_group_id == *group {
                return Ok(true);
            }
        }
        if tokio::time::Instant::now() >= deadline {
            return Ok(false);
        }
    }
}

/// Whether the product's anonymous per-relay read of the invitee's inbox
/// came back typed `refused`, with nothing served, from every relay it lists.
async fn refused_everywhere<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    invitee: DeviceTag,
    listed: &[String],
) -> Result<bool, RigError> {
    let device = world.device(invitee)?;
    let filter = Filter::new()
        .kind(Kind::GiftWrap)
        .pubkey(device.keys.public_key());
    let reads = device
        .relays
        .fetch_events_per_relay(filter, listed)
        .await
        .map_err(|_| RigError::Core(Step::Publish))?;
    Ok(reads.len() == listed.len()
        && reads
            .iter()
            .all(|read| read.refused && !read.drained && read.events.is_empty()))
}
