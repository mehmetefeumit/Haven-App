//! **S04** — a member is away, and comes back.
//!
//! Four spans of the same promise, from shortest to longest: away across
//! nothing, away across a commit, away while the group crosses the whole
//! retention window and one epoch more, and away across a change to the roster
//! itself. In every one of them the returning device must end up where its
//! peers are — same epoch, same roster, able to read and be read — and in the
//! long one it must ALSO stop being able to read ciphertext from before the
//! window Security Rule 5 bounds.
//!
//! # `offline` is a paused engine, not an unplugged socket
//!
//! `go_offline` settles first and then closes every REQ; nothing disconnects,
//! so the pool's reconnect ladder is genuinely not in the path and the honest
//! price of a resume is the subscribe ladder. That is why every arm here
//! recovers from `Undisturbed` and pays `resubscribes` instead.
//!
//! # O4 lives in the long arm, and what it adds over the unit gate
//!
//! `haven-core`'s own `rule5_retention_constants_are_pinned` and
//! `rule5_epoch_n_ciphertext_still_decrypts_at_the_window_edge` pin the constant
//! and the positive edge. What `offline-past-retention` adds is those same two
//! edges over a real relay and a real live plane, across a pause and a
//! catch-up — and nothing else. A green O4 is not new coverage of the constant.
//!
//! # The window is READ at runtime, never restated
//!
//! `DEFAULT_MAX_PAST_EPOCHS` is the engine's, and the arm crosses one more epoch
//! than it says. An engine that widened the window moves this arm rather than
//! breaking it; an arm that spelled `5` would go on grading a window the engine
//! no longer has.

use std::time::Duration;

use haven_core::location::LOCATION_MESSAGE_RETENTION_SECS;
use haven_core::nostr::mls::types::{ConvergedRoster, GroupId};
use haven_core::nostr::mls::DEFAULT_MAX_PAST_EPOCHS;
use nostr::Event;

use crate::oracle::undecryptable::{self, StoredRow};
use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{bounds, Invariant, ProbeToken, Reach, Recovery, RetentionEdge};
use crate::rig::{CircleTag, DeviceTag, LogDrain, PublishVerdict, RigError, Step, TimelineSink};
use crate::scenarios::{
    await_condition, deliveries_for, grade_round, relay_update, remove_member, round, Absence, Arm,
    ArmOutcome, ScenarioWorld, WithheldAcks, NO_GATING_ROWS,
};
use tokio::time::{Instant, MissedTickBehavior};

/// How often a bounded wait for a delivery re-reads the ledger. A harness
/// cadence; no expectation is derived from it.
const DELIVERY_POLL: Duration = Duration::from_millis(20);

/// How many epochs the long arm crosses: one more than the engine keeps
/// exporter secrets for, so the older of its two ciphertexts lands OUTSIDE the
/// window and the younger lands exactly on its edge.
///
/// A `const` expression over the engine's own constant, because an arm's floor
/// is a `const` — the runtime read is in the arm body, and the two are asserted
/// equal there.
const EPOCHS_PAST_RETENTION: u64 = DEFAULT_MAX_PAST_EPOCHS as u64 + 1;

/// How many confirmed commits land while the member is away.
///
/// One, and the reason is measured rather than chosen. A relay serves a stored
/// page NEWEST FIRST, and a kind-445 commit's outer layer is keyed at its
/// committer's pre-commit epoch — so of two backlogged commits the newer one
/// cannot peel until the older has been applied, and it is retained as a
/// deferred row instead. Those rows are retried by a sweep the engine runs on
/// its next PEELABLE inbound event, and a device one epoch behind its peers
/// never gets one: every fresh fix is sealed above it. Measured at this pin, a
/// two-commit backlog leaves the returning device exactly one epoch short and
/// three further fixes from the committer do not move it.
///
/// That is a PRODUCT DEFECT, not a design constraint. A device that missed two
/// chained commits never converges again on its own, and for Haven that means
/// its peers' fixes stop arriving: **sharing stops**, silently, with the circle
/// still reporting a healthy send path. It is recorded as **C7** in
/// `docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md` and it is owed a scenario of
/// its own that asserts it RED.
///
/// So `1` here is a WORKAROUND pending that fix, not a design: one commit is
/// redelivered and applied on its own, which keeps this scenario about member
/// absence. It is not a statement that one commit is the span the product
/// supports.
const COMMITS_WHILE_AWAY: u64 = 1;

/// How many epochs the medium arm's group crosses in total: one the returning
/// member takes live, and one it misses.
const EPOCHS_CROSSED_MEDIUM: u64 = COMMITS_WHILE_AWAY + 1;

/// The arms this scenario offers.
pub const ARMS: [Arm; 4] = [
    Arm {
        label: "offline-quiet",
        recovery: Recovery::Undisturbed,
        probe_rounds: 2,
        resubscribes: true,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            faults_applied: 0,
            // The arm's whole content is that the span was quiet.
            epochs_crossed: 0,
            deliveries_observed: 2,
            canaries_caught: 3,
        },
    },
    Arm {
        // The span is ONE commit, for the reason `COMMITS_WHILE_AWAY` records.
        // The plural label stands because it is pinned in both profile TOMLs
        // and in three of `tests/oracles.rs`'s bodies, and a rename buys a
        // reader nothing the constant above does not already say.
        label: "offline-across-commits",
        recovery: Recovery::Undisturbed,
        probe_rounds: 2,
        resubscribes: true,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            faults_applied: 0,
            epochs_crossed: EPOCHS_CROSSED_MEDIUM,
            deliveries_observed: 2,
            canaries_caught: 3,
        },
    },
    Arm {
        label: "offline-past-retention",
        recovery: Recovery::Undisturbed,
        probe_rounds: 2,
        resubscribes: true,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            faults_applied: 0,
            epochs_crossed: EPOCHS_PAST_RETENTION,
            deliveries_observed: 2,
            canaries_caught: 5,
        },
    },
    Arm {
        label: "offline-across-removal",
        recovery: Recovery::Undisturbed,
        probe_rounds: 2,
        resubscribes: true,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            faults_applied: 0,
            epochs_crossed: 1,
            deliveries_observed: 2,
            canaries_caught: 3,
        },
    },
];

/// Runs one arm.
///
/// # Errors
///
/// [`RigError::UnknownTarget`] if the label is not one this scenario offers,
/// [`RigError::ShapeMismatch`] if the world is too small for it —
/// `offline-across-removal` needs a fourth device, because a removal that left
/// the circle with only the admin and the returning member would be testing an
/// empty roster — otherwise [`RigError`] naming the step that failed.
pub(crate) async fn run<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    arm: &Arm,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    let tags: Vec<DeviceTag> = world.devices().iter().map(|device| device.tag).collect();
    let [admin, witness, returner, ..] = *tags.as_slice() else {
        return Err(RigError::ShapeMismatch);
    };
    let circle_tag = world.circles().first().ok_or(RigError::ShapeMismatch)?.tag;

    // The control round: the world delivers before anybody goes away, so a
    // closing round that fails is a failure of the absence rather than of the
    // world.
    let opening_pairs = [(admin, witness), (witness, returner)];
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

    let mut classified: Vec<undecryptable::Verdict> = Vec::new();
    let mut edges: Vec<RetentionEdge> = Vec::new();
    let canaries = match arm.label {
        "offline-quiet" => quiet(world, admin, witness, returner, circle_tag).await?,
        "offline-across-commits" => {
            across_commits(world, admin, witness, returner, circle_tag).await?
        }
        "offline-past-retention" => {
            past_retention(
                world,
                admin,
                witness,
                returner,
                circle_tag,
                &mut classified,
                &mut edges,
            )
            .await?
        }
        "offline-across-removal" => {
            across_removal(world, admin, returner, tags.get(3).copied(), circle_tag).await?
        }
        _ => return Err(RigError::UnknownTarget),
    };

    // The returning device SENDS first: its subscriptions and its view of the
    // group were rebuilt from a persisted cursor, and a reuse there is
    // invisible to it and shows only as a peer that cannot read what it
    // produced. The removal arm's victim is not probed — it is not a member any
    // more, so a probe to it would be grading the product on a roster the
    // removal deliberately split.
    let pairs = [(returner, admin), (admin, returner), (witness, returner)];
    let opened = [returner];
    let closing = round(
        2,
        Reach::These(&pairs),
        Recovery::Undisturbed,
        tick,
        NO_GATING_ROWS,
        &opened,
        &classified,
    )
    .with_retention(&edges);
    let invariants: &[Invariant] = if edges.is_empty() {
        &[
            Invariant::Quiescence,
            Invariant::LocationRoundTrip,
            Invariant::SendPathLiveness,
        ]
    } else {
        &[
            Invariant::Quiescence,
            Invariant::RetentionWindow,
            Invariant::Undecryptable,
            Invariant::LocationRoundTrip,
            Invariant::SendPathLiveness,
        ]
    };
    graded.extend(grade_round(world, &closing, invariants).await?);

    world.drain_buses();
    let observed = Observed::measure(world, canaries).await?;
    Ok(ArmOutcome {
        graded,
        observed,
        tick,
    })
}

/// Away across nothing: the shortest span, and the mirror of every other arm's
/// anti-vacuity.
///
/// If the epoch moved here, the world was not quiet and the other three arms'
/// "away across a commit" claims would be measuring something the world does
/// anyway.
async fn quiet<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    admin: DeviceTag,
    witness: DeviceTag,
    returner: DeviceTag,
    circle_tag: CircleTag,
) -> Result<usize, RigError> {
    let group = world.circle(circle_tag)?.mls_group_id().clone();
    let before = epoch_of(world, admin, &group).await?;
    world.device_mut(returner)?.go_offline().await?;

    // Drained FIRST: the opening round reads its peers' buses directly rather
    // than through the ledger, so a baseline taken before a drain would be
    // stale — and the first drain after it would then look like a delivery the
    // pause was supposed to have stopped.
    world.drain_buses();
    let witness_before = deliveries_for(world.device(witness)?, circle_tag);
    let returner_before = deliveries_for(world.device(returner)?, circle_tag);
    // One fix, published while the member is away. Its peer takes it live,
    // which is what makes "the absent device did not" a property of the pause
    // rather than of a world that delivered nothing to anybody.
    publish_fix(world, admin, circle_tag, 1).await?;
    let delivered_to_peer = await_delivery(
        world,
        witness,
        circle_tag,
        witness_before,
        bounds::round_trip(Recovery::Undisturbed),
    )
    .await?;

    let mut canaries = 0_usize;
    // 1. The pause is real: the world delivered that fix, and not to the device
    //    that is away. The ledger is freshly drained by the wait above, so the
    //    second half is a read of the same instant rather than of an earlier
    //    one.
    if delivered_to_peer && deliveries_for(world.device(returner)?, circle_tag) == returner_before {
        canaries += 1;
    }

    world.device_mut(returner)?.come_online().await?;
    // 2. …and the resume is real: the backlog the pause held back arrives.
    if await_delivery(
        world,
        returner,
        circle_tag,
        returner_before,
        bounds::round_trip(Recovery::Undisturbed) + bounds::subscribe_ladder(),
    )
    .await?
    {
        canaries += 1;
    }
    // 3. …and the span really was quiet: nothing advanced the epoch across it.
    if epoch_of(world, admin, &group).await? == before {
        canaries += 1;
    }
    Ok(canaries)
}

/// Waits, bounded, for `device`'s folded delivery count for `circle` to rise
/// above `above`.
///
/// Drains the buses on every read, because the ledger is only written by a
/// drain: a bounded wait that did not drain would be waiting for a number
/// nothing was updating.
async fn await_delivery<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    device: DeviceTag,
    circle: CircleTag,
    above: u64,
    bound: Duration,
) -> Result<bool, RigError> {
    let started = Instant::now();
    let mut ticker = tokio::time::interval(DELIVERY_POLL);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
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

/// Away across a confirmed commit, in a group that crossed two.
async fn across_commits<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    admin: DeviceTag,
    witness: DeviceTag,
    returner: DeviceTag,
    circle_tag: CircleTag,
) -> Result<usize, RigError> {
    let group = world.circle(circle_tag)?.mls_group_id().clone();
    // One commit the returning member takes live, so the closing round's
    // agreement is about the one it MISSED rather than about a group that never
    // moved while it was here.
    advance(
        world,
        admin,
        circle_tag,
        EPOCHS_CROSSED_MEDIUM - COMMITS_WHILE_AWAY,
        "live",
    )
    .await?;
    world.device_mut(returner)?.go_offline().await?;
    advance(world, admin, circle_tag, COMMITS_WHILE_AWAY, "away").await?;

    let mut canaries = 0_usize;
    // 1. The device really is behind: its peer, which took the commits live, is
    //    strictly ahead of it.
    let ahead = await_condition(bounds::round_trip(Recovery::Undisturbed), || async {
        Ok(epoch_of(world, witness, &group).await? > epoch_of(world, returner, &group).await?)
    })
    .await?;
    if ahead {
        canaries += 1;
    }

    // 2. …and it catches up to where the COMMITTER is. The committer, not a
    //    peer: a peer's own engine may still be applying the same backlog, and
    //    two devices that are equally behind agree about nothing.
    if resume_and_catch_up(world, admin, returner, circle_tag, COMMITS_WHILE_AWAY).await? {
        canaries += 1;
    }
    // 3. …holding the epoch's own exporter secret, rather than merely its
    //    number.
    if has_current_secret(world, returner, &group).await? {
        canaries += 1;
    }
    Ok(canaries)
}

/// Away while the group crosses the whole retention window and one epoch more.
///
/// The two ciphertexts are sealed one epoch apart and then left alone while the
/// group advances, so after the catch-up one of them sits exactly on the
/// window's edge and the other one past it. Neither is ever published: a peer
/// with a live engine would ingest one the moment it crossed the relay, and the
/// engine answers a second ingest of one MLS message with a duplicate — the edge
/// would then be graded on a repeat rather than on the window.
///
/// # Where the absence sits inside the span, and why it is not the whole of it
///
/// The device is away across the LAST `COMMITS_WHILE_AWAY` of the
/// `window + 1` advances rather than across all of them. What the arm claims is
/// the retention window measured from a tip the device reached by catching up,
/// and a device that is away for the whole chain never reaches that tip at this
/// pin — the deferred-peel retries that would drain such a backlog are driven by
/// inbound events, so a quiet world leaves the chain half-applied (see
/// [`advance`]). Stretching the absence would not strengthen the claim; it would
/// replace it with an unrelated one about backlog drainage, which wants a
/// scenario and an owner decision of its own.
async fn past_retention<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    admin: DeviceTag,
    witness: DeviceTag,
    returner: DeviceTag,
    circle_tag: CircleTag,
    classified: &mut Vec<undecryptable::Verdict>,
    edges: &mut Vec<RetentionEdge>,
) -> Result<usize, RigError> {
    let group = world.circle(circle_tag)?.mls_group_id().clone();
    let window = u64::try_from(DEFAULT_MAX_PAST_EPOCHS).unwrap_or(u64::MAX);

    // Each ciphertext's own source epoch is READ at the moment it is sealed, so
    // the distance the oracle grades is a measurement rather than the shape the
    // arm intended. A world that did not reach the intended shape then answers
    // "this proved nothing" (O4 sees only one side of the window) instead of
    // reporting a violation the arm manufactured.
    let outside_at = epoch_of(world, witness, &group).await?;
    let outside = seal(world, witness, &group, 2).await?;
    advance(world, admin, circle_tag, 1, "edge").await?;
    // The sealing device has to have APPLIED that commit, or its ciphertext
    // lands an epoch below where the arm means to put it.
    await_condition(bounds::round_trip(Recovery::Undisturbed), || async {
        Ok(epoch_of(world, witness, &group).await? > outside_at)
    })
    .await?;
    let inside_at = epoch_of(world, witness, &group).await?;
    let inside = seal(world, witness, &group, 3).await?;

    advance(
        world,
        admin,
        circle_tag,
        window.saturating_sub(COMMITS_WHILE_AWAY),
        "window",
    )
    .await?;

    world.device_mut(returner)?.go_offline().await?;
    advance(world, admin, circle_tag, COMMITS_WHILE_AWAY, "past").await?;
    let mut canaries = 0_usize;
    // 1. The returning device caught up to the COMMITTER — not to a peer, which
    //    may still be applying the same backlog. The window this arm grades is
    //    measured from the returning device's own tip, so a tip that is one
    //    epoch short moves BOTH ciphertexts inside the window and the oracle
    //    would then be grading one side of it twice.
    if resume_and_catch_up(world, admin, returner, circle_tag, COMMITS_WHILE_AWAY).await? {
        canaries += 1;
    }
    // 2. …and holds the current epoch's own exporter secret.
    if has_current_secret(world, returner, &group).await? {
        canaries += 1;
    }

    let tip = epoch_of(world, returner, &group).await?;
    let inside_outcome =
        undecryptable::classify(world.device(returner)?, &inside, StoredRow::Unknown).await?;
    let outside_outcome =
        undecryptable::classify(world.device(returner)?, &outside, StoredRow::Unknown).await?;
    classified.push(inside_outcome);
    classified.push(outside_outcome);
    let circle = world.circle(circle_tag)?.tag;
    edges.push(RetentionEdge {
        device: returner,
        circle,
        distance: tip.saturating_sub(inside_at),
        outcome: inside_outcome,
    });
    edges.push(RetentionEdge {
        device: returner,
        circle,
        distance: tip.saturating_sub(outside_at),
        outcome: outside_outcome,
    });
    // 3. Ciphertext at the window's own edge still decrypts…
    if inside_outcome == undecryptable::Verdict::Applied {
        canaries += 1;
    }
    // 4. …and ciphertext one epoch older does not, anywhere.
    if outside_outcome != undecryptable::Verdict::Applied {
        canaries += 1;
    }
    // 5. …and that refusal is one the classifier ACCOUNTS for. A ciphertext
    //    that aged out of the window is an expected disposition, never a defect
    //    the run cannot explain.
    if !matches!(outside_outcome, undecryptable::Verdict::Defect(_)) {
        canaries += 1;
    }
    Ok(canaries)
}

/// Away across a change to the roster itself.
///
/// The victim's engine is paused BEFORE the removal and stays paused, and the
/// closing round never probes it. That is not a convenience: a removed device
/// legitimately reports a roster its former circle no longer agrees with, and a
/// world-wide roster oracle grading it would report a divergence the removal
/// itself created.
async fn across_removal<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    admin: DeviceTag,
    returner: DeviceTag,
    victim: Option<DeviceTag>,
    circle_tag: CircleTag,
) -> Result<usize, RigError> {
    let Some(victim) = victim else {
        return Err(RigError::ShapeMismatch);
    };
    let group = world.circle(circle_tag)?.mls_group_id().clone();
    let victim_pubkey = world.device(victim)?.pubkey_hex();
    let before = epoch_of(world, admin, &group).await?;

    world.device_mut(victim)?.go_offline().await?;
    world.device_mut(returner)?.go_offline().await?;

    let circle = world.circle(circle_tag)?;
    let (_, verdict) = remove_member(world, admin, circle, victim).await?;
    if verdict != PublishVerdict::Confirmed {
        // Rule 13 rolled it back, so the roster never changed and there is
        // nothing for the returning member to agree with.
        return Err(RigError::PublishNeverAcked);
    }

    let mut canaries = 0_usize;
    // 1. The removal really landed: the epoch advanced and the admin's own
    //    roster lost the victim.
    if epoch_of(world, admin, &group).await? > before
        && !roster_of(world, admin, &group)
            .await?
            .contains(&victim_pubkey)
    {
        canaries += 1;
    }

    world.device_mut(returner)?.come_online().await?;
    // 2. The returning member catches up to the admin's epoch…
    if await_condition(catchup_bound(1), || async {
        Ok(epoch_of(world, admin, &group).await? == epoch_of(world, returner, &group).await?)
    })
    .await?
    {
        canaries += 1;
    }
    // 3. …and agrees about who is in the circle, which is the half an epoch
    //    number cannot carry.
    let roster = roster_of(world, returner, &group).await?;
    if !roster.is_empty()
        && !roster.contains(&victim_pubkey)
        && roster == roster_of(world, admin, &group).await?
    {
        canaries += 1;
    }
    Ok(canaries)
}

/// Advances `circle` by `count` confirmed relay-list commits, letting every
/// device that is still receiving apply each one before the next is staged.
///
/// Each commit carries a DIFFERENT relay list: a repeat of the list the group
/// already holds is a no-op, and a no-op advances no epoch — which would leave
/// the window uncrossed while the arm believed it had crossed it.
///
/// The per-commit wait is not politeness. A kind-445 commit's outer layer is
/// keyed at its committer's PRE-commit epoch, and a relay serves a page newest
/// first, so a device that is several commits behind cannot peel any of them
/// until the oldest arrives — the rest are retained as deferred rows and retried
/// by a sweep that INBOUND EVENTS drive. In a world that has gone quiet, that
/// leaves a long chain draining a row or two and then stopping (measured at this
/// pin: five chained commits published back to back left a resumed device short
/// of the tip after three minutes). Staging the chain at the rate the group can
/// apply it is what keeps this arm measuring the absence it names rather than
/// that backlog behaviour, which is a scenario of its own.
async fn advance<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    circle_tag: CircleTag,
    count: u64,
    salt: &str,
) -> Result<(), RigError> {
    let group = world.circle(circle_tag)?.mls_group_id().clone();
    for index in 0..count {
        let mut relays = world.relay_urls();
        relays.push(format!("wss://s04-{salt}-{index}.example.com"));
        let circle = world.circle(circle_tag)?;
        let (_, verdict) = relay_update(world, device, circle, &relays).await?;
        if verdict != PublishVerdict::Confirmed {
            // Nothing merged, so the absent device is not behind anything and
            // every later observation would be about an epoch nobody crossed.
            return Err(RigError::PublishNeverAcked);
        }
        let tip = epoch_of(world, device, &group).await?;
        await_condition(bounds::round_trip(Recovery::Undisturbed), || async {
            for peer in world.devices() {
                if peer.offline || peer.tag == device {
                    continue;
                }
                if epoch_of(world, peer.tag, &group).await? != tip {
                    return Ok(false);
                }
            }
            Ok(true)
        })
        .await?;
    }
    Ok(())
}

/// How long a resumed device is given to reach the committer's epoch.
///
/// One round-trip budget per commit it has to take, plus the subscribe ladder
/// the resume itself pays. Composed from named terms like every other bound
/// here: a device that missed `backlog` commits has `backlog` deliveries to
/// take and settle, and the ladder is what re-opens the REQ they arrive on.
fn catchup_bound(backlog: u64) -> Duration {
    bounds::round_trip(Recovery::Undisturbed) * u32::try_from(backlog).unwrap_or(1)
        + bounds::subscribe_ladder()
}

/// Resumes `returner` and waits for it to reach the committer's epoch.
///
/// The commit it missed is redelivered by the resume's own re-subscription,
/// from the persisted cursor, and applies on its own: it is sealed at the epoch
/// the returning device still holds, so the peel needs nothing the device does
/// not have. See [`COMMITS_WHILE_AWAY`] for why the absence spans exactly one.
async fn resume_and_catch_up<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    committer: DeviceTag,
    returner: DeviceTag,
    circle_tag: CircleTag,
    backlog: u64,
) -> Result<bool, RigError> {
    let group = world.circle(circle_tag)?.mls_group_id().clone();
    world.device_mut(returner)?.come_online().await?;
    await_condition(catchup_bound(backlog), || async {
        Ok(epoch_of(world, committer, &group).await? == epoch_of(world, returner, &group).await?)
    })
    .await
}

/// Publishes one location into `circle` and waits for a relay's own ack.
async fn publish_fix<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    sender: DeviceTag,
    circle_tag: CircleTag,
    index: u32,
) -> Result<(), RigError> {
    let group = world.circle(circle_tag)?.mls_group_id().clone();
    let event = seal(world, sender, &group, index).await?;
    if world
        .publish_witnessed(sender, std::slice::from_ref(&event))
        .await?
        .is_none()
    {
        // Nothing was acked, so nothing is stored for the returning device to
        // catch up on.
        return Err(RigError::PublishNeverAcked);
    }
    Ok(())
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
            &ProbeToken::mint(4, index).as_location(),
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

/// One device's converged roster for one circle, sorted. Empty when the device
/// holds no converged roster at all.
async fn roster_of<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    group: &GroupId,
) -> Result<Vec<String>, RigError> {
    let roster = world
        .device(device)?
        .session()?
        .converged_member_pubkeys(group)
        .await
        .map_err(|_| RigError::Core(Step::ReadRoster))?;
    let ConvergedRoster::Converged {
        mut member_pubkeys_hex,
        ..
    } = roster
    else {
        return Ok(Vec::new());
    };
    member_pubkeys_hex.sort();
    Ok(member_pubkeys_hex)
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

/// The circle every arm here runs in, for the module's own tests.
#[cfg(test)]
mod tests {
    use super::{ARMS, COMMITS_WHILE_AWAY, EPOCHS_CROSSED_MEDIUM, EPOCHS_PAST_RETENTION};
    use crate::oracle::Recovery;
    use haven_core::nostr::mls::DEFAULT_MAX_PAST_EPOCHS;

    #[test]
    fn every_arm_pays_for_its_resume_and_breaks_no_relay() {
        for arm in &ARMS {
            assert!(
                arm.recovery == Recovery::Undisturbed,
                "a paused engine closes no socket, so the pool's ladder is not in the path"
            );
            assert!(
                arm.resubscribes,
                "the returning device re-opens its own REQs, so the subscribe ladder is"
            );
            assert!(
                arm.floor.faults_applied == 0,
                "nothing here is done to a relay: the absence is the fault"
            );
            assert!(
                arm.floor.deliveries_observed >= 2,
                "a control round and a closing round, both of which must really deliver"
            );
        }
    }

    #[test]
    fn the_spans_grow_and_the_quiet_one_crosses_nothing() {
        assert!(
            ARMS[0].floor.epochs_crossed == 0,
            "the short arm's whole content is that the span was quiet"
        );
        assert!(
            ARMS[1].floor.epochs_crossed == EPOCHS_CROSSED_MEDIUM
                && EPOCHS_CROSSED_MEDIUM > COMMITS_WHILE_AWAY,
            "the medium arm's group crosses one epoch the member takes live and \
             one it misses, so its agreement is about the one it missed"
        );
        assert!(
            ARMS[2].floor.epochs_crossed > ARMS[1].floor.epochs_crossed,
            "the long arm is the one that leaves the retention window behind"
        );
        assert!(
            ARMS[3].floor.epochs_crossed == 1,
            "a removal is one commit, and the arm is about the roster it changed"
        );
    }

    #[test]
    fn the_long_arms_floor_is_the_engines_own_window_plus_one() {
        // The floor is a `const`, so it cannot call the runtime accessor; this
        // is what keeps the two in step. An engine that widened the window
        // moves both together.
        assert!(
            EPOCHS_PAST_RETENTION == DEFAULT_MAX_PAST_EPOCHS as u64 + 1,
            "one epoch past the last one the engine keeps a secret for"
        );
        assert!(
            ARMS[2].floor.epochs_crossed == EPOCHS_PAST_RETENTION,
            "an arm that crossed fewer epochs never left the window it grades"
        );
        assert!(
            ARMS[2].floor.canaries_caught == 5,
            "the catch-up, the current secret, the edge that decrypts, the one that \
             does not, and the account for the refusal"
        );
    }
}
