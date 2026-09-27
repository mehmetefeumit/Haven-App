//! **S21** — *"remove them and they stop seeing you."*
//!
//! A removed member stops reading the circle, on both delivery paths, and every
//! remaining member's next fix carries the post-removal epoch inside a bounded
//! lag. This is the user-visible promise, and it had no test before this
//! scenario.
//!
//! Three arms, two oracles. `removal-withheld-commit` and `removal-delivered-commit`
//! grade **O3** (`RemovalUnreadability`) through the removal probes they feed;
//! `removal-lag` grades **S8** (bounded removal-effectiveness lag) through an
//! absence window and its own canaries.
//!
//! # Why the two O3 arms are split, and what each proves
//!
//! MDK short-circuits EVERY message for a group whose local `OpenMLS` copy is no
//! longer `is_active()` to `Stale{SelfEvicted}` WITHOUT attempting a decrypt
//! (`cgka-engine/src/message_processor/ingest.rs:178-197`, which persists the
//! message `Failed`, runs `realize_self_eviction` and returns before the peel).
//! An oracle satisfied by that alone is satisfied by BOOKKEEPING: delete the key
//! deletion and it stays green. So the two paths are graded apart.
//!
//! `removal-delivered-commit` delivers the removal commit to the evictee and
//! asserts every later message is `Stale{SelfEvicted}`, none carrying the round's
//! token. **It asserts MDK's `!is_active()` gate and NOTHING about key material,
//! and is never reported as a forward-secrecy proof.**
//!
//! `removal-withheld-commit` holds the commit back — `DropClass::Handshake` on
//! the evictee's endpoint on every plane for the whole arm, so its `OpenMLS`
//! group stays active and the peel is genuinely attempted — and asserts every
//! post-removal probe is `Stale{PeelFailed}`, none carrying the token, and that
//! the stored row each leaves NEVER resolves (`PeelDeferred` or terminally
//! `Failed`, read after the closing round). A `PeelFailed` row is retained
//! `PeelDeferred` — the "not yet" that is not "never" — so the terminal read is
//! what turns it into a claim.
//!
//! # What O3 does NOT prove
//!
//! O3 is post-removal UNREADABILITY, not the RFC 9420 §12.4 forward-secrecy
//! property (a Remove's `UpdatePath` blanks the leaf so the new epoch secret is
//! unreachable). That property is openmls's, tested upstream, and is unreachable
//! from Haven's code — an evictee that never received the commit has no
//! epoch-N+1 exporter secret whether or not the `UpdatePath` was correct, so
//! `PeelFailed` on the withheld path is what any behind member sees and cannot
//! distinguish a broken Remove. See the oracle's own module doc
//! (`crate::oracle`, `Invariant::RemovalUnreadability`) for the full boundary.
//! §12.4 is stated here as openmls's property, the basis O3 relies on, never as
//! something this scenario measures.
//!
//! # The Rule-5 boundary (verbatim, PLAN §2.12)
//!
//! The evictee holds the epoch-`N` exporter secret legitimately and MDK retains
//! up to `DEFAULT_MAX_PAST_EPOCHS = 5` past epochs
//! (`cgka-engine/src/wire_format.rs:38`), so it can read EVERY 445 wrapped at
//! epochs `N−4 … N` — including the removal commit itself and any straggler
//! location a remaining member encrypted at `N` before its next fix. That is
//! expected and permitted, and asserting its absence would be asserting a
//! forward-secrecy property MLS does not have. The claim is a BOUNDARY: the
//! evictee's last readable fix has `epoch ≤ N`, and its timestamp lies within
//! `B(S21)` of the confirmation instant.
//!
//! # No catch-up sweep runs inside any arm here
//!
//! Everything reaching storage keeps the plane's CANONICAL endpoint, and
//! `run_catchup_all_circles` reads its relay list out of storage — so a scenario
//! that partitions a device's ENGINE endpoint must not run a catch-up sweep
//! while the partition stands, or the withheld removal commit arrives by the
//! other path and the arm grades a heal it never performed (§1.1, S02's twin).
//! `removal-withheld-commit` holds `DropClass::Handshake` for its whole length
//! and runs no sweep; the other two run none either.
//!
//! # A removal-bearing auto-commit is never rolled back
//!
//! `haven-core/tests/od4c_removal_deferral_e2e.rs:1025`
//! (`a_rolled_back_removal_commit_drops_the_removal_and_wedges_the_circle`) pins
//! that a rolled-back removal is the permanent silent drop the deferral docs
//! record, so no arm here may reach a rollback of the removal: every removal is
//! confirmed under Rule 13 before any probe is fed.
//!
//! # `removal-lag` and invariant S8
//!
//! After the removal is confirmed by ≥ 1 remaining member at `t`, no remaining
//! member publishes at the pre-removal epoch after `t + B(S21)`, and the
//! evictee's last readable fix lies inside that window:
//!
//! ```text
//! B(S21) = withheld_publish_ladder()   // the removal commit's own publish ladder, worst case (34 s)
//!        + settle()                    // COMMIT_SETTLE_WINDOW_SECS = 8
//!        + subscribe_ladder()          // a peer that must re-open a REQ to see it (9 s)
//!        + location_publish_window()   // the remaining members' next fix: 1 × 5 s
//! ```
//!
//! The trailing term is `location_publish_window()`, carried as
//! `Absence::RemovalPublishTail` (§1.9) — one bounded location attempt, not the
//! 168-second `kLocationPublishMaxInterval`, which is Tier 2's Dart constant with
//! no haven-core equivalent (in Tier 1 the rig is its own publish scheduler).
//! The identity `LOCATION_MESSAGE_RETENTION_SECS == 168 + 2 × 30` is pinned by
//! `haven-core/src/location/ttl.rs:59` and
//! `scripts/ci/check_publish_jitter_fraction_parity.sh`.
//!
//! In Tier 1 the epoch of an outbound 445 is known to the harness because the
//! harness published it; the WIRE form of the assertion has no relay-visible
//! epoch, so it is the harness ledger's, not a wire discriminator.
//!
//! # `offline` and the withhold, not an unplugged socket
//!
//! The O3 arms withhold the commit with `DropClass::Handshake` (a dropped frame,
//! no socket closed) and then pause the evictee's engine for the closing round so
//! the roster oracle grades only the remaining members — a removed device
//! legitimately reports a roster its former circle no longer agrees with. Every
//! arm recovers from `Undisturbed`, and none re-opens a REQ, so none pays the
//! subscribe ladder.

use std::time::Duration;

use haven_core::location::LOCATION_MESSAGE_RETENTION_SECS;
use haven_core::nostr::mls::types::{
    ConvergedRoster, GroupId, LocationMessageResult, MessageId, MessageState, ScreenedIngest,
};
use haven_core::nostr::mls::SessionManager;
use nostr::Event;

use crate::nemesis::types::{DropClass, Fault};
use crate::oracle::undecryptable::{self, Probe};
use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{
    bounds, Invariant, ProbeToken, Reach, Recovery, RemovalPath, RemovalProbe, RemovalRow,
    RemovalStage,
};
use crate::rig::{
    CircleTag, DeviceTag, LogDrain, PublishVerdict, RelayPlane, RigError, Step, TimelineSink,
};
use crate::scenarios::{
    await_condition, chain_pairs, grade_round, remove_member, round, stayed_absent, Absence, Arm,
    ArmOutcome, ScenarioWorld, WithheldAcks, NO_GATING_ROWS,
};

/// The round the arm's own probes are stamped with: neither graded round's
/// ordinal, so a probe from this arm can never satisfy a closing-round O1 probe
/// and vice versa.
const PROBE_ROUND: u32 = 121;

/// How many post-removal probes each O3 arm feeds the evictee. More than one, so
/// a single lucky refusal cannot pass the arm.
const AFTER_PROBES: u32 = 3;

/// The arms this scenario offers.
pub const ARMS: [Arm; 3] = [
    Arm {
        // O3, the withheld path: the commit is held back, the peel is genuinely
        // attempted, and the stored row it leaves never resolves.
        label: "removal-withheld-commit",
        recovery: Recovery::Undisturbed,
        probe_rounds: 2,
        resubscribes: false,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            // DropClass::Handshake on the evictee's endpoint, ≥ 1 plane.
            faults_applied: 1,
            epochs_crossed: 1,
            deliveries_observed: 2,
            // baseline decrypts; roster excludes evictee; every After is
            // PeelFailed without the token; no SelfEvicted anywhere; remaining
            // converge; and the terminal row read never resolves.
            canaries_caught: 6,
        },
    },
    Arm {
        // O3, the delivered path: the bookkeeping gate. Asserts MDK's
        // `!is_active()` short-circuit and nothing about key material.
        label: "removal-delivered-commit",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: false,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            faults_applied: 1,
            epochs_crossed: 1,
            deliveries_observed: 1,
            // The baseline decrypts, the roster excludes the evictee, every
            // After probe is SelfEvicted without the token, the delivered
            // commit left no current secret, and the remaining members
            // converge. The last is covered by no oracle, so the floor is what
            // holds the arm to it.
            canaries_caught: 5,
        },
    },
    Arm {
        // S8: the bounded removal-effectiveness lag.
        label: "removal-lag",
        recovery: Recovery::Undisturbed,
        probe_rounds: 2,
        resubscribes: false,
        absence: Absence::RemovalPublishTail,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            faults_applied: 1,
            epochs_crossed: 1,
            deliveries_observed: 2,
            // remaining converge inside B with none left at the pre-removal
            // epoch over the tail; every remaining member's next fix is at the
            // post-removal epoch; the evictee's last readable fix is pre-removal.
            canaries_caught: 3,
        },
    },
];

/// Runs one arm.
///
/// # Errors
///
/// [`RigError::UnknownTarget`] if the label is not one this scenario offers,
/// [`RigError::ShapeMismatch`] if the world has fewer than four devices — a
/// removal needs an admin, two remaining members that can still talk, and the
/// evictee — otherwise [`RigError`] naming the step that failed.
pub(crate) async fn run<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    arm: &Arm,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    let tags: Vec<DeviceTag> = world.devices().iter().map(|device| device.tag).collect();
    let [admin, remaining_a, remaining_b, evictee, ..] = *tags.as_slice() else {
        return Err(RigError::ShapeMismatch);
    };
    let circle_tag = world.circles().first().ok_or(RigError::ShapeMismatch)?.tag;

    // The control round: the world delivers before anything is removed, so a
    // closing round that fails is a failure of the removal rather than of the
    // world.
    let pairs = chain_pairs(world);
    let control = round(
        1,
        Reach::These(&pairs),
        Recovery::Undisturbed,
        tick,
        NO_GATING_ROWS,
        &[],
        &[],
    );
    let mut graded = grade_round(world, &control, &[Invariant::LocationRoundTrip]).await?;

    let remaining = [admin, remaining_a, remaining_b];
    match arm.label {
        "removal-withheld-commit" => {
            unreadable_arm(
                world,
                admin,
                &remaining,
                evictee,
                circle_tag,
                tick,
                RemovalPath::Withheld,
                &mut graded,
            )
            .await
        }
        "removal-delivered-commit" => {
            unreadable_arm(
                world,
                admin,
                &remaining,
                evictee,
                circle_tag,
                tick,
                RemovalPath::Delivered,
                &mut graded,
            )
            .await
        }
        "removal-lag" => {
            lag_arm(
                world,
                admin,
                &remaining,
                evictee,
                circle_tag,
                tick,
                &mut graded,
            )
            .await
        }
        _ => Err(RigError::UnknownTarget),
    }
}

/// The two O3 arms, which differ only in whether the removal commit is delivered
/// to the evictee.
// The arm is one straight-line sequence — arm, baseline, remove, After probes,
// close, terminal read, grade — that reads worse split across helpers passing a
// shared probe vector back and forth than it does whole.
#[allow(clippy::too_many_lines)]
// The four roles, the path and the shared grade vector: a struct for two call
// sites is more code than the eighth argument.
#[allow(clippy::too_many_arguments)]
async fn unreadable_arm<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    admin: DeviceTag,
    remaining: &[DeviceTag],
    evictee: DeviceTag,
    circle_tag: CircleTag,
    tick: Duration,
    path: RemovalPath,
    graded: &mut Vec<(Invariant, crate::oracle::Verdict)>,
) -> Result<ArmOutcome, RigError> {
    let group = world.circle(circle_tag)?.mls_group_id().clone();
    let evictee_pubkey = world.device(evictee)?.pubkey_hex();
    let mut canaries = 0_usize;
    let mut probes: Vec<RemovalProbe> = Vec::new();

    // Hold the removal commit off the evictee's own live plane in BOTH arms: the
    // withheld arm never delivers it, the delivered arm delivers it
    // deterministically through the seam instead of racing the plane. This is
    // the arm's one fault.
    aim(world, evictee, Fault::DropClass(DropClass::Handshake)).await?;

    // The Before baseline, minted at the pre-removal epoch and fed to the
    // still-active evictee. It MUST decrypt and carry the token, or the refusals
    // that follow prove nothing (the evictee may simply never have been able to
    // read this circle). An evictee that already reached SelfEvicted here is
    // rc 3 — the removal leaked before the arm could establish its premise.
    let before_token = ProbeToken::mint(PROBE_ROUND, 0);
    let before_event = seal(world, admin, &group, before_token).await?;
    let (before_outcome, before_carried) =
        feed_probe(world, evictee, &before_event, before_token).await?;
    probes.push(RemovalProbe {
        device: evictee,
        circle: circle_tag,
        stage: RemovalStage::Before,
        path,
        outcome: before_outcome,
        carried_token: before_carried,
        terminal: RemovalRow::NotApplicable,
    });
    // 1. The baseline decrypted with the token, so the peel really was attempted
    //    on a group that could read this circle.
    if before_outcome == undecryptable::Verdict::Applied && before_carried {
        canaries += 1;
    }

    // The removal, confirmed under Rule 13 by the remaining members (the
    // evictee's endpoint drops the commit frame; the others apply it).
    let circle = world.circle(circle_tag)?;
    let (commit, verdict) = remove_member(world, admin, circle, evictee).await?;
    if verdict != PublishVerdict::Confirmed {
        // A rolled-back removal is the permanent silent drop od4c pins; nothing
        // was removed, so there is no post-removal state to grade.
        return Err(RigError::PublishNeverAcked);
    }
    // 2. The remaining members' roster agrees and excludes the evictee.
    if !roster_of(world, admin, &group)
        .await?
        .contains(&evictee_pubkey)
    {
        canaries += 1;
    }

    match path {
        RemovalPath::Withheld => {
            // The withhold is proven applied: the evictee never advanced and its
            // group is still active, so the post-removal peel is genuine.
            let held = epoch_of(world, evictee, &group).await?
                < epoch_of(world, admin, &group).await?
                && has_current_secret(world, evictee, &group).await?;
            if !held {
                // The commit leaked to the evictee before the probes: the arm
                // did not stage the state it grades.
                return Err(RigError::Unhealable);
            }
        }
        RemovalPath::Delivered => {
            // Deliver the removal commit through the seam, exactly once, so the
            // evictee's leaf goes inactive deterministically.
            feed_probe(world, evictee, &commit, before_token).await?;
        }
    }

    // The After probes, minted at the post-removal epoch and fed to the evictee.
    let mut after_events: Vec<(Event, undecryptable::Verdict)> = Vec::new();
    for index in 1..=AFTER_PROBES {
        let token = ProbeToken::mint(PROBE_ROUND, index);
        let event = seal(world, admin, &group, token).await?;
        let (outcome, carried) = feed_probe(world, evictee, &event, token).await?;
        probes.push(RemovalProbe {
            device: evictee,
            circle: circle_tag,
            stage: RemovalStage::After,
            path,
            outcome,
            carried_token: carried,
            // Filled after the closing round for the withheld path only.
            terminal: RemovalRow::NotApplicable,
        });
        after_events.push((event, outcome));
    }

    // 3. Every After probe produced its path's exact refusal and none carried
    //    the token.
    let want = match path {
        RemovalPath::Withheld => undecryptable::Verdict::PeelFailed,
        RemovalPath::Delivered => undecryptable::Verdict::SelfEvicted,
    };
    let afters = &probes[1..];
    if afters
        .iter()
        .all(|p| p.stage == RemovalStage::After && p.outcome == want && !p.carried_token)
    {
        canaries += 1;
    }
    // 4. (withheld only) No ingest in this arm answered SelfEvicted — neither the
    //    `is_active` gate nor the post-peel `UseAfterEviction` site (two sites).
    if path == RemovalPath::Withheld
        && probes
            .iter()
            .all(|p| p.outcome != undecryptable::Verdict::SelfEvicted)
    {
        canaries += 1;
    }
    // 4. (delivered only) The delivered commit made the evictee's group inactive.
    if path == RemovalPath::Delivered && !has_current_secret(world, evictee, &group).await? {
        canaries += 1;
    }

    // Pause the evictee's engine for the closing round: a removed device
    // legitimately reports a roster its former circle no longer agrees with, and
    // grading it would report a divergence the removal itself created. The
    // withhold is never healed — going offline is on top of it.
    world.device_mut(evictee)?.go_offline().await?;

    // The closing round over the remaining members: they converge and keep
    // delivering to each other. The lead is the admin (which committed the
    // removal), so a rebuilt epoch shows first as a peer failing to read it.
    let closing_pairs = both_ways(remaining, admin);
    let closing = round(
        2,
        Reach::These(&closing_pairs),
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
    // 5. …and they really converged: same epoch across the remaining members.
    if remaining_converged(world, remaining, &group).await? {
        canaries += 1;
    }

    // 6. (withheld only) The terminal read O3 requires: after the closing round,
    //    each withheld After probe's stored row is still deferred or terminally
    //    failed — never resolved.
    if path == RemovalPath::Withheld {
        let mut all_unread = true;
        for (i, (event, _)) in after_events.iter().enumerate() {
            let terminal = terminal_row(world, evictee, event).await?;
            probes[i + 1].terminal = terminal;
            all_unread &= matches!(terminal, RemovalRow::StillDeferred | RemovalRow::Retired);
        }
        if all_unread {
            canaries += 1;
        }
    }

    // Grade O3 last, with the completed probes (terminals filled). The reach is
    // immaterial — RemovalUnreadability reads only the round's probes.
    let o3 = round(
        3,
        Reach::EveryOrderedPair,
        Recovery::Undisturbed,
        tick,
        NO_GATING_ROWS,
        &[],
        &[],
    )
    .with_forward_secrecy(&probes);
    graded.extend(grade_round(world, &o3, &[Invariant::RemovalUnreadability]).await?);

    world.drain_buses();
    let observed = Observed::measure(world, canaries).await?;
    Ok(ArmOutcome {
        graded: std::mem::take(graded),
        observed,
        tick,
    })
}

/// The S8 lag arm: the removal effectiveness lag is bounded by `B(S21)`, and the
/// evictee's last readable fix is pre-removal.
async fn lag_arm<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    admin: DeviceTag,
    remaining: &[DeviceTag],
    evictee: DeviceTag,
    circle_tag: CircleTag,
    tick: Duration,
    graded: &mut Vec<(Invariant, crate::oracle::Verdict)>,
) -> Result<ArmOutcome, RigError> {
    let group = world.circle(circle_tag)?.mls_group_id().clone();
    let mut canaries = 0_usize;

    // The evictee's last readable fix, minted and fed BEFORE the removal, at the
    // pre-removal epoch. It must decrypt with the token.
    let pre_token = ProbeToken::mint(PROBE_ROUND, 0);
    let pre_event = seal(world, admin, &group, pre_token).await?;
    let (pre_outcome, pre_carried) = feed_probe(world, evictee, &pre_event, pre_token).await?;

    // Cut the evictee off its own live plane so it cannot receive anything past
    // the removal (its last readable fix stays the pre-removal one). This is the
    // arm's one fault.
    aim(world, evictee, Fault::DropClass(DropClass::Handshake)).await?;

    // The removal, confirmed under Rule 13 by ≥ 1 remaining member at t.
    let circle = world.circle(circle_tag)?;
    let (_, verdict) = remove_member(world, admin, circle, evictee).await?;
    if verdict != PublishVerdict::Confirmed {
        return Err(RigError::PublishNeverAcked);
    }
    let post_epoch = epoch_of(world, admin, &group).await?;

    // 1. Every remaining member reached the post-removal epoch inside B, and none
    //    is left at the pre-removal epoch over the RemovalPublishTail window.
    let converged = await_condition(bounds::round_trip(Recovery::Undisturbed), || async {
        remaining_converged(world, remaining, &group).await
    })
    .await?;
    let none_behind = stayed_absent(bounds::location_publish_window(), || async {
        any_at_epoch_below(world, remaining, &group, post_epoch).await
    })
    .await?;
    if converged && none_behind {
        canaries += 1;
    }

    // 2. Each remaining member's NEXT publish carries the post-removal epoch,
    //    read by feeding it to another remaining member and requiring it applies.
    let mut all_post = true;
    for (i, sender) in remaining.iter().enumerate() {
        let receiver = remaining[(i + 1) % remaining.len()];
        let token = ProbeToken::mint(PROBE_ROUND, 100 + u32::try_from(i).unwrap_or(0));
        let event = seal(world, *sender, &group, token).await?;
        let (outcome, _) = feed_probe(world, receiver, &event, token).await?;
        // A peer already at the sender's epoch answers a re-fed message either
        // Processed or (its own echo aside) as an already-seen duplicate; what
        // it must NOT be is a peel/commit gap, which is what a pre-removal-epoch
        // publish would produce against a post-removal peer.
        all_post &= matches!(
            outcome,
            undecryptable::Verdict::Applied
                | undecryptable::Verdict::Duplicate
                | undecryptable::Verdict::OwnEcho
        );
    }
    if all_post {
        canaries += 1;
    }

    // 3. The evictee's last readable fix is pre-removal: the pre-removal fix
    //    decrypted with the token, and a post-removal fix does not decrypt.
    let post_token = ProbeToken::mint(PROBE_ROUND, 200);
    let post_event = seal(world, admin, &group, post_token).await?;
    let (evictee_post, _) = feed_probe(world, evictee, &post_event, post_token).await?;
    if pre_outcome == undecryptable::Verdict::Applied
        && pre_carried
        && evictee_post != undecryptable::Verdict::Applied
    {
        canaries += 1;
    }

    // Pause the evictee for the closing round so the roster oracle grades only
    // the remaining members.
    world.device_mut(evictee)?.go_offline().await?;
    let closing_pairs = both_ways(remaining, admin);
    let closing = round(
        2,
        Reach::These(&closing_pairs),
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
        graded: std::mem::take(graded),
        observed,
        tick,
    })
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

/// Feeds `event` to `device` exactly once through the ingest seam and answers
/// what its ingest made of it AND whether the decrypted content carried
/// `token` — both from the ONE ingest (one event, one ingest).
async fn feed_probe<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    event: &Event,
    token: ProbeToken,
) -> Result<(undecryptable::Verdict, bool), RigError> {
    let session = world.device(device)?.session()?;
    let ingested = session.process_event_typed_for_test(event).await;
    let carried = match &ingested {
        Ok(ScreenedIngest::Ingested(effects)) => effects.effects.events.iter().any(|group_event| {
            matches!(
                SessionManager::location_result_from_event(group_event),
                Some(LocationMessageResult::Location { content, .. }) if token.carried_by(&content)
            )
        }),
        Ok(ScreenedIngest::RejectedBeforeAuth(_)) | Err(_) => false,
    };
    Ok((
        undecryptable::classify_ingest(&ingested, Probe::Unnamed),
        carried,
    ))
}

/// The evictee's stored-row state for a probe it was fed, read after the closing
/// round: the "not yet" vs "never" distinction a `PeelFailed` alone cannot make.
async fn terminal_row<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    event: &Event,
) -> Result<RemovalRow, RigError> {
    // The engine keys a raw transport row by the event hash (the peeler binds
    // `TransportMessage.id` to it), which is what a withheld application 445
    // leaves as a `PeelDeferred` row.
    let id = MessageId::new(event.id.to_bytes().to_vec());
    let probe = world
        .device(device)?
        .session()?
        .stored_message_record_for_test(&id)
        .await
        .map_err(|_| RigError::Core(Step::ReadConvergenceState))?;
    Ok(match probe.map(|p| p.state) {
        Some(MessageState::PeelDeferred) => RemovalRow::StillDeferred,
        Some(MessageState::Failed) => RemovalRow::Retired,
        // Any live/applied disposition is a read past the removal.
        Some(_) => RemovalRow::Resolved,
        // No row at all is not evidence of unreadability; O3 treats it as
        // inconclusive rather than as a hold.
        None => RemovalRow::NotApplicable,
    })
}

/// Seals one location at `device`'s current epoch, unpublished.
async fn seal<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    group: &GroupId,
    token: ProbeToken,
) -> Result<Event, RigError> {
    let sender = world.device(device)?;
    sender
        .manager()?
        .encrypt_location(
            group,
            &sender.keys.public_key(),
            &token.as_location(),
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

/// Whether `device` holds the CURRENT epoch's exporter secret for `group` — and
/// therefore whether its `OpenMLS` group is still active (openmls refuses the
/// export after eviction).
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

/// One device's converged roster for one circle, sorted; empty when the device
/// holds no converged roster.
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

/// Whether every remaining member holds the same, non-origin epoch for `group`.
async fn remaining_converged<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    remaining: &[DeviceTag],
    group: &GroupId,
) -> Result<bool, RigError> {
    let mut epochs = Vec::with_capacity(remaining.len());
    for device in remaining {
        epochs.push(epoch_of(world, *device, group).await?);
    }
    Ok(epochs.windows(2).all(|pair| pair[0] == pair[1]))
}

/// Whether any remaining member's epoch is strictly below `at_least`.
async fn any_at_epoch_below<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    remaining: &[DeviceTag],
    group: &GroupId,
    at_least: u64,
) -> Result<bool, RigError> {
    for device in remaining {
        if epoch_of(world, *device, group).await? < at_least {
            return Ok(true);
        }
    }
    Ok(false)
}

/// Every adjacent pair of `devices`, both directions, with `lead` sending first.
///
/// A local mirror of [`crate::scenarios::closing_pairs`] over a device subset,
/// because the removal arms probe only the members that are LEFT — the evictee
/// is not a member any more, so a pair to it would grade the product on a roster
/// the removal deliberately split.
fn both_ways(devices: &[DeviceTag], lead: DeviceTag) -> Vec<(DeviceTag, DeviceTag)> {
    let mut pairs = Vec::with_capacity(devices.len().saturating_sub(1) * 2);
    for pair in devices.windows(2) {
        let (from, to) = (pair[0], pair[1]);
        if to == lead {
            pairs.push((to, from));
            pairs.push((from, to));
        } else {
            pairs.push((from, to));
            pairs.push((to, from));
        }
    }
    pairs
}

#[cfg(test)]
mod tests {
    use super::{both_ways, ARMS, PROBE_ROUND};
    use crate::oracle::Recovery;
    use crate::rig::DeviceTag;
    use crate::scenarios::{Absence, WithheldAcks};

    #[test]
    fn every_arm_is_undisturbed_and_never_resubscribes() {
        for arm in &ARMS {
            assert!(
                arm.recovery == Recovery::Undisturbed,
                "a dropped frame closes no socket and a paused evictee re-opens \
                 nothing, so the pool's ladder is not in the path"
            );
            assert!(
                !arm.resubscribes,
                "nobody re-opens a REQ in these arms, so the subscribe ladder is not paid"
            );
            assert!(
                arm.withheld_acks == WithheldAcks::None,
                "every publish here is acknowledged; the removal is confirmed under Rule 13"
            );
            assert!(
                arm.floor.faults_applied == 1,
                "each arm holds exactly one DropClass on one endpoint of at least one plane"
            );
            assert!(
                arm.floor.epochs_crossed == 1,
                "one confirmed removal is the epoch the arm turns on"
            );
        }
    }

    #[test]
    fn the_floors_match_the_two_delivery_paths_and_the_lag() {
        // Withheld: two probe rounds and the terminal read as its sixth canary.
        assert!(
            ARMS[0].label == "removal-withheld-commit",
            "arm 0 is the withheld path"
        );
        assert!(ARMS[0].probe_rounds == 2 && ARMS[0].floor.canaries_caught == 6);
        assert!(
            ARMS[0].absence == Absence::None,
            "the withheld path asserts no absence window"
        );
        // Delivered: one probe round, and every canary the path catches — the
        // no-current-secret one has no oracle behind it.
        assert!(
            ARMS[1].label == "removal-delivered-commit",
            "arm 1 is the delivered path"
        );
        assert!(ARMS[1].probe_rounds == 1 && ARMS[1].floor.canaries_caught == 5);
        assert!(
            ARMS[1].absence == Absence::None,
            "the delivered path asserts no absence window"
        );
        // Lag: the removal-publish tail, three canaries.
        assert!(ARMS[2].label == "removal-lag", "arm 2 is the S8 lag arm");
        assert!(ARMS[2].probe_rounds == 2 && ARMS[2].floor.canaries_caught == 3);
        assert!(
            ARMS[2].absence == Absence::RemovalPublishTail,
            "S8's trailing window is the location publish window, not the commit ladder"
        );
    }

    #[test]
    fn the_probe_round_is_outside_both_graded_rounds() {
        const { assert!(PROBE_ROUND != 1 && PROBE_ROUND != 2 && PROBE_ROUND != 3) }
    }

    #[test]
    fn closing_pairs_lead_and_exclude_the_absent_member() {
        let (a, b, c) = (DeviceTag::new(0), DeviceTag::new(1), DeviceTag::new(2));
        let pairs = both_ways(&[a, b, c], a);
        // Every adjacent pair, both ways, and the lead sends before it receives.
        assert!(pairs.contains(&(a, b)) && pairs.contains(&(b, a)));
        assert!(pairs.contains(&(b, c)) && pairs.contains(&(c, b)));
        let send = pairs.iter().position(|&(from, _)| from == a);
        let receive = pairs.iter().position(|&(_, to)| to == a);
        assert!(send < receive, "the lead sends before anything sends to it");
        // A device not in the subset never appears.
        let d = DeviceTag::new(9);
        assert!(pairs.iter().all(|&(from, to)| from != d && to != d));
    }
}
