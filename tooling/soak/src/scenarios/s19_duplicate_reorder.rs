//! **S19** — the same event twice, the same page backwards, and an `EOSE`
//! addressed to somebody else.
//!
//! The promise: a relay may repeat itself, page in any order and answer the
//! wrong subscription, and the application still sees each location exactly
//! once, in a state that still converges.
//!
//! # Which dedup layer each arm asserts, and why it matters
//!
//! There are two, and only one of them is Haven's. `nostr-relay-pool` keeps a
//! 35 000-id LRU in its POOL-wide shared state, so a second copy of an event on
//! the same client is absorbed before Haven ever sees it — and a second RELAY
//! does not change that, because every relay of one client shares that tracker.
//! The layer this scenario is about is Haven's own: the engine's message store,
//! which answers a second ingest of the same MLS content with a stale-already-
//! seen outcome. The duplicate arm therefore reaches it through a RESTART, which
//! is what resets the in-memory tracker, and its floor demands the two `EVENT`
//! frames in the plane's ledger — without them the arm would be asserting a
//! dedup nothing exercised.
//!
//! # The commit-gap arm
//!
//! Rule 12's shape is an application message the engine may not apply yet: it
//! must be HELD rather than dropped, and released once the transition that
//! blocked it ends. Which transition that can be at this pin — and which one it
//! deliberately is not — is written on the arm itself.

use std::time::Duration;

use haven_core::relay::live_sync::LiveSyncEvent;
use nostr::{Event, EventId};
use tokio::sync::broadcast::error::TryRecvError;
use tokio::sync::broadcast::Receiver;
use tokio::time::{Instant, MissedTickBehavior};

use crate::nemesis::types::Fault;
use crate::oracle::undecryptable::{self, StoredRow};
use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{bounds, Invariant, ProbeToken, Reach, Recovery};
use crate::rig::{
    kill_and_reopen, CircleTag, DeviceTag, KillKind, LogDrain, RelayPlane, RelayTag, RigError,
    Step, TimelineSink,
};
use crate::scenarios::{
    await_condition, closing_pairs, deliveries_for, grade_round, round, Absence, Arm, ArmOutcome,
    ScenarioWorld, WithheldAcks, NO_GATING_ROWS,
};

/// How often an arrival-order read re-checks a bus.
const ARRIVAL_POLL: Duration = Duration::from_millis(10);

/// The arms this scenario offers.
pub const ARMS: [Arm; 4] = [
    Arm {
        label: "duplicate-replay",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: true,
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
        label: "reordered-pages",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: true,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            faults_applied: 1,
            epochs_crossed: 0,
            deliveries_observed: 2,
            canaries_caught: 2,
        },
    },
    Arm {
        label: "cross-sub-eose",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: true,
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
        label: "commit-gap",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        // Nothing here re-opens a subscription: the gap is a local transition.
        resubscribes: false,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            // The only arm here that breaks no delivery: the gap is a state of
            // the INGESTER (its own commit is staged and unresolved), not
            // something a relay can do to a page.
            faults_applied: 0,
            // The commit itself. An arm that crossed no epoch has no gap.
            epochs_crossed: 1,
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
/// otherwise [`RigError`] naming the step that failed.
pub(crate) async fn run<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    arm: &Arm,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    let tags: Vec<DeviceTag> = world.devices().iter().map(|device| device.tag).collect();
    let [sender, receiver, ..] = *tags.as_slice() else {
        return Err(RigError::ShapeMismatch);
    };
    let plane = world
        .relays()
        .first()
        .map(RelayPlane::tag)
        .ok_or(RigError::ShapeMismatch)?;

    let mut classified = Vec::new();
    // No arm counts its own faults: the PLANE records what it took, and the
    // floor is graded against that.
    let canaries = match arm.label {
        "duplicate-replay" => duplicate(world, sender, receiver, plane).await?,
        "reordered-pages" => reordered(world, sender, receiver, plane).await?,
        "cross-sub-eose" => cross_eose(world, sender, receiver, plane).await?,
        "commit-gap" => commit_gap(world, sender, receiver, &mut classified).await?,
        _ => return Err(RigError::UnknownTarget),
    };

    apply(world, plane, Fault::Heal).await?;
    // The device whose delivery was broken SENDS first, and the chain is probed
    // both ways: a duplicate, a reorder or a buffered commit gap that left the
    // two devices on different branches shows up as a peer that cannot decrypt
    // what this one produces.
    let pairs = closing_pairs(world, receiver);
    let opened = [receiver];
    let invariants: &[Invariant] = if classified.is_empty() {
        &[Invariant::Quiescence, Invariant::LocationRoundTrip]
    } else {
        &[
            Invariant::Quiescence,
            Invariant::Undecryptable,
            Invariant::LocationRoundTrip,
        ]
    };
    let healed = round(
        1,
        Reach::These(&pairs),
        Recovery::Undisturbed,
        tick,
        NO_GATING_ROWS,
        &opened,
        &classified,
    );
    let graded = grade_round(world, &healed, invariants).await?;

    world.drain_buses();
    let observed = Observed::measure(world, canaries).await?;
    Ok(ArmOutcome {
        graded,
        observed,
        tick,
    })
}

/// The same event, delivered twice, applied once.
async fn duplicate<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    sender: DeviceTag,
    receiver: DeviceTag,
    plane: RelayTag,
) -> Result<usize, RigError> {
    let circle_tag = world.circles().first().ok_or(RigError::ShapeMismatch)?.tag;
    let probe = ProbeToken::mint(19, 1);
    let event = publish_probe(world, sender, circle_tag, probe).await?;
    let id = event.id;

    // The application sees it once, the ordinary way.
    let sender_hex = world.device(sender)?.pubkey_hex();
    let group_routing = *world.circle(circle_tag)?.nostr_group_id();
    let mut bus = world.device(receiver)?.engine()?.bus().subscribe();
    let arrived = arrival_order(
        &mut bus,
        &group_routing,
        &sender_hex,
        &[probe],
        bounds::round_trip(Recovery::Undisturbed),
    )
    .await;
    world.drain_buses();
    let applied_once = deliveries_for(world.device(receiver)?, circle_tag);
    // The premise of canary 2 below. Without it, a world where the first copy
    // never arrived at all would satisfy "applied exactly once" with a count of
    // zero — a delivery failure reading as a dedup success.
    let first_arrived = arrived.len() == 1 && applied_once > 0;

    // The restart is the mechanism: it resets the pool's in-memory id tracker,
    // which is the only Phase-1 way a repeat reaches Haven's own dedup at all.
    // The doubling fault makes the replayed page carry each event twice, so the
    // ledger can show the two frames the floor demands.
    apply(world, plane, Fault::DoubleEveryEvent).await?;
    kill_and_reopen(world.device_mut(receiver)?, KillKind::Hard).await?;

    let mut canaries = 0_usize;
    // 1. Two `EVENT` frames really crossed towards the client.
    if await_condition(bounds::round_trip(Recovery::Undisturbed), || async {
        Ok(delivered(world, plane, &id)? >= 2)
    })
    .await?
    {
        canaries += 1;
    }
    // 2. …and the application still applied it once. Haven's own dedup — the
    //    engine's message store — is the layer this asserts; the pool's LRU was
    //    reset by the restart.
    world.drain_buses();
    if first_arrived && deliveries_for(world.device(receiver)?, circle_tag) == applied_once {
        canaries += 1;
    }
    Ok(canaries)
}

/// A stored page delivered newest-first is still applied.
///
/// # "Backwards" is read off the plane, never assumed from the publish order
///
/// Both locations are published inside one second, so both carry the same
/// `created_at` and the relay's own tie-break — the event id, minted from a
/// per-message ephemeral key — decides which it serves first. That is a fresh
/// coin toss every run. So the arm asks the plane's store what order it WOULD
/// serve the page in, and then requires the device to have been delivered
/// exactly its reverse: a property of the fault rather than of the draw.
///
/// The plane holds a page per SUBSCRIPTION and releases it at that
/// subscription's own `EOSE`, which is what makes "the page" a well-defined
/// thing here: a device runs several subscriptions over one socket, and a hold
/// shared across them would be released by whichever ended first.
async fn reordered<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    sender: DeviceTag,
    receiver: DeviceTag,
    plane: RelayTag,
) -> Result<usize, RigError> {
    let circle_tag = world.circles().first().ok_or(RigError::ShapeMismatch)?.tag;
    // Paused first, so both locations are STORED rather than live-delivered:
    // the reordering is a property of the stored page, not of the socket.
    world.device_mut(receiver)?.go_offline().await?;

    let first = ProbeToken::mint(19, 2);
    let second = ProbeToken::mint(19, 3);
    let published = [
        publish_probe(world, sender, circle_tag, first).await?.id,
        publish_probe(world, sender, circle_tag, second).await?.id,
    ];

    apply(world, plane, Fault::ReversePages).await?;
    // The order the relay ITSELF would serve the two in, which is not the order
    // they were published: the whole arm runs inside one second, so both events
    // carry the same `created_at` and the store's tie-break decides — and that
    // is the event id, minted from a per-message ephemeral key and so different
    // every run. Reading it here is what makes "backwards" a property of the
    // fault rather than of a coin toss.
    let served = served_order(world, plane, &published).await?;
    let sender_hex = world.device(sender)?.pubkey_hex();
    let group_routing = *world.circle(circle_tag)?.nostr_group_id();
    let mut bus = world.device(receiver)?.engine()?.bus().subscribe();
    world.device_mut(receiver)?.come_online().await?;

    let order = arrival_order(
        &mut bus,
        &group_routing,
        &sender_hex,
        &[first, second],
        bounds::round_trip(Recovery::Undisturbed) + bounds::subscribe_ladder(),
    )
    .await;

    let mut canaries = 0_usize;
    // 1. The page really arrived backwards — the reverse of the order this
    //    plane's own store would have served. Without this the arm would be a
    //    plain catch-up test wearing a reordering label.
    let mut backwards = served.clone();
    backwards.reverse();
    if served.len() == published.len() && order == backwards {
        canaries += 1;
    }
    // 2. …and both locations were applied all the same.
    if order.len() == published.len() {
        canaries += 1;
    }
    Ok(canaries)
}

/// Where `published` sit in the order `plane`'s store would serve them, as
/// indices into `published` itself.
///
/// Read from the store rather than assumed: a page is served newest first and
/// ties are broken by event id, so the order events were published in is not
/// the order they come back in.
async fn served_order<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    plane: RelayTag,
    published: &[EventId],
) -> Result<Vec<usize>, RigError> {
    let page = world
        .relays()
        .iter()
        .find(|candidate| candidate.tag() == plane)
        .ok_or(RigError::UnknownTarget)?
        .stored_page(nostr::Filter::new().ids(published.iter().copied()))
        .await?;
    Ok(page
        .iter()
        .filter_map(|event| published.iter().position(|id| *id == event.id))
        .collect())
}

/// An `EOSE` addressed to a subscription nobody opened changes nothing.
async fn cross_eose<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    sender: DeviceTag,
    receiver: DeviceTag,
    plane: RelayTag,
) -> Result<usize, RigError> {
    let circle_tag = world.circles().first().ok_or(RigError::ShapeMismatch)?.tag;
    let before = eose(world, plane)?;
    apply(world, plane, Fault::EoseForAnotherSubscription).await?;
    world.device_mut(receiver)?.go_offline().await?;
    world.device_mut(receiver)?.come_online().await?;

    let mut canaries = 0_usize;
    // 1. The frame really crossed.
    if await_condition(bounds::subscribe_ladder(), || async {
        Ok(eose(world, plane)? > before)
    })
    .await?
    {
        canaries += 1;
    }

    // 2. …and a freshly minted location still arrives, decrypted, at the peer
    //    whose subscription was never told its page ended.
    let probe = ProbeToken::mint(19, 4);
    let sender_hex = world.device(sender)?.pubkey_hex();
    let group_routing = *world.circle(circle_tag)?.nostr_group_id();
    let mut bus = world.device(receiver)?.engine()?.bus().subscribe();
    let _ = publish_probe(world, sender, circle_tag, probe).await?;
    let order = arrival_order(
        &mut bus,
        &group_routing,
        &sender_hex,
        &[probe],
        bounds::round_trip(Recovery::Undisturbed),
    )
    .await;
    if order.len() == 1 {
        canaries += 1;
    }
    Ok(canaries)
}

/// A location that arrives while the ingesting device's OWN commit is staged is
/// named as a GAP and not applied, and the same shape applies once the
/// transition ends.
///
/// Rule 12's shape, and the one shape that produces it at this pin. A message
/// sealed at an epoch the ingester has not reached cannot be buffered at all:
/// the kind-445 outer layer is keyed by the sender's epoch exporter, which a
/// device an epoch behind cannot derive, so such an event peel-fails instead
/// (measured; `tests/classifier.rs` carries that case beside this one). The
/// engine's buffering outcome is the publish-before-apply transition — this
/// device has a commit staged and unresolved, so it may not apply anything
/// until Rule 13 says what happened to it.
///
/// # The second location is the control, and it is what makes the first mean
/// something
///
/// Without it, "the engine did not apply this" would be satisfied by a message
/// the engine could never apply — a corrupt payload, a foreign group, a screen
/// that rejected it. The same sender mints the same shape again once the commit
/// is confirmed, and that one MUST apply.
///
/// # What this arm deliberately does not claim
///
/// It does not claim the held message is later delivered. Measured at this pin:
/// the gap leaves no gating row, and neither `advance_convergence` nor a later
/// ingest hands it back afterwards. Where a message named `CommitGap` goes is a
/// question for the phase that owns the engine's own retry tick; asserting a
/// re-delivery this rig cannot observe would be reporting coverage it does not
/// have.
async fn commit_gap<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    stager: DeviceTag,
    speaker: DeviceTag,
    classified: &mut Vec<undecryptable::Verdict>,
) -> Result<usize, RigError> {
    let circle_tag = world.circles().first().ok_or(RigError::ShapeMismatch)?.tag;
    let group = world.circle(circle_tag)?.mls_group_id().clone();
    let urls = world.relay_urls();
    let mut canaries = 0_usize;

    // The gap: the ADMIN stages a commit and leaves it unresolved — the admin
    // because a relay-list commit is an admin operation, so the device that can
    // be put into a publish-before-apply transition is the one that can commit.
    // Staged through the manager rather than through `relay_update`, because
    // that helper resolves the pending in the same call and the whole point
    // here is the window in which it is not yet resolved.
    let outstanding = world.note_pending_staged();
    let pending = world
        .device(stager)?
        .manager()?
        .update_circle_relays(&group, &urls)
        .await
        .map_err(|_| RigError::Core(Step::StageCommit))?;

    // Never published: an event the engine has already ingested cannot be
    // classified afterwards, because the store answers a second look with a
    // stale-already-seen outcome and the gap would read as a duplicate. One
    // event, one ingest, one call.
    let during = mint_probe(world, speaker, circle_tag, ProbeToken::mint(19, 5)).await?;
    let before = deliveries_for(world.device(stager)?, circle_tag);

    // 1. The gap has a NAME. `CommitGap` is the engine's own buffering outcome,
    //    which is what tells a caller to wait rather than to treat the message
    //    as junk.
    let gap = undecryptable::classify(world.device(stager)?, &during, StoredRow::Unknown).await?;
    classified.push(gap);
    if gap == undecryptable::Verdict::CommitGap {
        canaries += 1;
    }

    // 2. …and nothing was handed to the application: a message the engine may
    //    not apply yet must not reach a caller that would draw it on a map.
    world.drain_buses();
    if deliveries_for(world.device(stager)?, circle_tag) == before {
        canaries += 1;
    }

    // The transition ends the only way Rule 13 allows: on an acknowledgement
    // that reached us.
    let witnessed = world
        .publish_witnessed(stager, std::slice::from_ref(&pending.commit_event))
        .await?;
    if witnessed.is_none() {
        // Nothing was acked, so the commit rolls back and the transition never
        // ends — the arm would be grading a world it did not reach.
        world
            .device(stager)?
            .manager()?
            .publish_failed(pending.pending)
            .await
            .map_err(|_| RigError::Core(Step::RollBackPublish))?;
        drop(outstanding);
        return Err(RigError::WelcomeNeverAcked);
    }
    world
        .device(stager)?
        .manager()?
        .finalize_relay_update(pending.pending, &group)
        .await
        .map_err(|_| RigError::Core(Step::ConfirmPublished))?;
    drop(outstanding);

    // 3. The control: the same sender, the same shape, once the transition is
    //    over. This one must APPLY, or the gap above said nothing about the
    //    transition and everything about the message.
    let after = mint_probe(world, speaker, circle_tag, ProbeToken::mint(19, 6)).await?;
    let applied =
        undecryptable::classify(world.device(stager)?, &after, StoredRow::Unknown).await?;
    classified.push(applied);
    if applied == undecryptable::Verdict::Applied {
        canaries += 1;
    }
    Ok(canaries)
}

/// Encrypts one probe WITHOUT publishing it.
async fn mint_probe<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    sender: DeviceTag,
    circle: CircleTag,
    probe: ProbeToken,
) -> Result<Event, RigError> {
    let group = world.circle(circle)?.mls_group_id().clone();
    let device = world.device(sender)?;
    device
        .manager()?
        .encrypt_location(
            &group,
            &device.keys.public_key(),
            &probe.as_location(),
            haven_core::location::LOCATION_MESSAGE_RETENTION_SECS,
        )
        .await
        .map(|(event, _, _)| event)
        .map_err(|_| RigError::Core(Step::Publish))
}

/// Encrypts one probe and publishes it, waiting for a witnessed acknowledgement.
async fn publish_probe<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    sender: DeviceTag,
    circle: crate::rig::CircleTag,
    probe: ProbeToken,
) -> Result<Event, RigError> {
    let group = world.circle(circle)?.mls_group_id().clone();
    let device = world.device(sender)?;
    let (event, _, _) = device
        .manager()?
        .encrypt_location(
            &group,
            &device.keys.public_key(),
            &probe.as_location(),
            haven_core::location::LOCATION_MESSAGE_RETENTION_SECS,
        )
        .await
        .map_err(|_| RigError::Core(Step::Publish))?;
    if world
        .publish_witnessed(sender, std::slice::from_ref(&event))
        .await?
        .is_none()
    {
        // Nothing was acked, so nothing is stored to be duplicated or
        // reordered, and every later observation would be about an empty page.
        return Err(RigError::WelcomeNeverAcked);
    }
    Ok(event)
}

/// The order in which `probes` arrived on `bus`, as indices into `probes`.
///
/// Returns as soon as every probe has arrived, or when the bound elapses with
/// whatever did. An arrival nobody can attribute is not counted.
async fn arrival_order(
    bus: &mut Receiver<LiveSyncEvent>,
    group_routing: &[u8; 32],
    sender_pubkey_hex: &str,
    probes: &[ProbeToken],
    bound: Duration,
) -> Vec<usize> {
    let started = Instant::now();
    let mut order: Vec<usize> = Vec::with_capacity(probes.len());
    let mut ticker = tokio::time::interval(ARRIVAL_POLL);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    loop {
        loop {
            match bus.try_recv() {
                Ok(LiveSyncEvent::Location {
                    ref nostr_group_id,
                    ref sender_pubkey,
                    ref content,
                    ..
                }) => {
                    if nostr_group_id.as_slice() != group_routing.as_slice()
                        || sender_pubkey != sender_pubkey_hex
                    {
                        continue;
                    }
                    if let Some(index) = probes.iter().position(|probe| probe.carried_by(content)) {
                        if !order.contains(&index) {
                            order.push(index);
                        }
                    }
                }
                Ok(_) => {}
                // The events are gone; reporting the order from a truncated
                // read would be reporting an order that was never observed.
                Err(TryRecvError::Lagged(_)) => return order,
                Err(TryRecvError::Empty | TryRecvError::Closed) => break,
            }
        }
        if order.len() == probes.len() || started.elapsed() >= bound {
            return order;
        }
        ticker.tick().await;
    }
}

/// How many `EVENT` frames one plane wrote towards the client for `event`.
fn delivered<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    plane: RelayTag,
    event: &EventId,
) -> Result<usize, RigError> {
    Ok(world
        .relays()
        .iter()
        .find(|candidate| candidate.tag() == plane)
        .ok_or(RigError::UnknownTarget)?
        .ledger()
        .delivered(event))
}

/// How many `EOSE` frames one plane wrote towards the client.
fn eose<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    plane: RelayTag,
) -> Result<usize, RigError> {
    Ok(world
        .relays()
        .iter()
        .find(|candidate| candidate.tag() == plane)
        .ok_or(RigError::UnknownTarget)?
        .ledger()
        .eose())
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
    use super::ARMS;

    #[test]
    fn every_delivery_arm_breaks_one_plane_behaviour_and_demands_both_halves() {
        // The commit-gap arm is not one of these: its gap is a state of the
        // INGESTER, so it breaks no delivery, re-opens no subscription, and
        // is held to the terms in the test below instead.
        for arm in ARMS.iter().filter(|arm| arm.label != "commit-gap") {
            assert!(
                arm.floor.faults_applied == 1,
                "{} applies exactly one delivery fault",
                arm.label
            );
            assert!(
                arm.floor.canaries_caught >= 2,
                "{} must observe the fault on the wire AND the application's answer",
                arm.label
            );
            assert!(
                arm.resubscribes,
                "{} re-opens a subscription, so the ladder is in its bound",
                arm.label
            );
        }
    }

    #[test]
    fn the_reordering_arm_needs_two_stored_locations() {
        // One location cannot be delivered out of order, so the arm's delivery
        // floor is what stops it being satisfied by a single page.
        assert!(ARMS[1].floor.deliveries_observed >= 2);
    }

    #[test]
    fn only_the_commit_gap_arm_commits_and_it_breaks_no_delivery() {
        // The gap arm is the only one that commits: its gap IS a commit staged
        // and unresolved, and the epoch moves when that commit is confirmed.
        // The other three are pure delivery faults, which advance nothing and
        // stage nothing.
        assert_eq!(ARMS[0].floor.epochs_crossed, 0);
        assert_eq!(ARMS[1].floor.epochs_crossed, 0);
        assert_eq!(ARMS[2].floor.epochs_crossed, 0);
        assert_eq!(ARMS[3].floor.epochs_crossed, 1);
        assert!(
            ARMS[3].floor.faults_applied == 0,
            "a transition of this device's own is not something a relay does"
        );
        assert!(
            ARMS[3].floor.canaries_caught == 3,
            "the named gap, nothing handed to the application, and the same \
             shape applying once the transition ends"
        );
    }
}
