//! **S16** — durable-storage growth: three arms, three different stores.
//!
//! The promise (Rule 12): a circle's durable store is grown only by input
//! that could still become legitimate backlog, and never without bound by
//! somebody who holds no key. At the pinned engine (MDK `e391adc`) that
//! promise is kept by ONE cap on ONE of three stores, and the three arms here
//! measure each store on its own terms — because "the engine bounds its
//! storage" is true of exactly one of them.
//!
//! The peel uses exactly one key: `Peeler::group_key` reads the group's
//! exporter secret and nothing else (`transport-nostr-peeler/src/peeler.rs`),
//! with no content-type discrimination, and it runs at
//! `cgka-engine/src/message_processor/ingest.rs:215` — after the `is_active`
//! gate and the `can_ingest` gate at `:198-209`, and BEFORE anything
//! convergence-related. Where an inbound event lands therefore depends on who
//! sealed it and on the group's epoch state when it arrives:
//!
//! * **`outsider-flood`** — the CAPPED `PeelDeferred` store. An adversary who
//!   has seen only the circle's public `#h` forges kind-445s the victim cannot
//!   peel at any epoch. `Err(PeelerError::DecryptFailed)` first retries against
//!   retained PAST snapshots (`ingest.rs:257-263`), then meets the cap:
//!   `reserve_peel_deferred_slot` at `:290` answers `false` once the group
//!   holds `MAX_PEEL_DEFERRED_ROWS_PER_GROUP` rows (`message_processor/mod.rs:48`,
//!   `pub`, read at runtime through [`peel_deferred_cap`]), the input is dropped
//!   UNPERSISTED with `Stale { PeelFailed }` (`:291-310`), and below the cap it
//!   is persisted `PeelDeferred` (`:312-317`) and retired after
//!   `MAX_DEFERRED_PEEL_ATTEMPTS` re-peels (`mod.rs:40`). The arm feeds MORE
//!   than the cap — an arm that stopped short would prove nothing about it —
//!   and asserts that exactly `cap` rows were persisted and every later one was
//!   not. *Observation caveat:* the engine's only outward signal at the cap is
//!   `Stale { PeelFailed }` with NO row persisted, identical to an ordinary
//!   peel failure; so `PeelDeferredCapped` is inferred from the ABSENCE of a
//!   row after the cap, and this arm is the classification's producer.
//!   *Rule-12 tension, stated rather than hidden:* dropping unpersisted above
//!   the cap is the engine silently discarding input. It is **not** a Rule-12
//!   violation, because the discarded input is un-peelable — it cannot be
//!   legitimate backlog for this device at this epoch — and because transport
//!   redelivery is the recovery path once the backlog drains
//!   (`ingest.rs:281-285`). "The engine drops events above a cap" reads like a
//!   breach until you know what the events are.
//!
//! * **`member-future-header-flood`** — the UNCAPPED convergence buffer
//!   (`buffer_openmls_convergence_message`, upstream #757, open). `msg_epoch`
//!   and `content_type` are read off the CLEARTEXT MLS wire header before any
//!   decryption (`ingest.rs:448-475`). A CO-MEMBER seals the outer layer at an
//!   epoch it legitimately holds — so the peel succeeds — and writes a
//!   far-future epoch into the inner `PrivateMessage` header; an application
//!   message above the tip takes the `:537-549` leg into the buffer, and
//!   canonicalisation never resolves a FUTURE application message. Only a
//!   member can mint this (it needs the group key), so the seal is haven-core's
//!   `forge_future_header_445_for_test`, published so the plane holds it, and
//!   received by the victim over the wire like any 445. The count is
//!   `convergence_buffer_len_for_test` — the one instrument that sees this
//!   store; `gating_input_count` provably cannot, because the scan skips rows
//!   above the future horizon — read BEFORE the flood in the same world as the
//!   in-arm control, and after every seal. `FLOOD_ROWS` is 8, a literal of this
//!   arm's own: more than one, so "monotonic growth" is a curve and not a
//!   point, and small enough to pay no ladder. Proof of vector: the stored row's
//!   STATE is read back — an openmls-wire row that projects, and not
//!   `PeelDeferred` — so the flood provably entered convergence; without that
//!   read this would be `outsider-flood` wearing this arm's label, reporting a
//!   bounded curve as a #757 result.
//!
//! * **`pending-window-flood`** — the UNCAPPED raw `Retryable` persist,
//!   OUTSIDER-reachable (owner decision OQ-B). While a group is
//!   `PendingPublish`, the `can_ingest` gate at `ingest.rs:198-209` persists
//!   EVERY inbound event as `MessageState::Retryable` — unconditionally, before
//!   the peel, with no cap — keyed on the raw transport id, which the sender
//!   chooses (content-id rebinding happens only after the peel, `:416-440`), so
//!   fresh ids defeat the dedup at `:108-118`. The only cap in the file is
//!   inside the `DecryptFailed` arm at `:290`, a branch this path never
//!   reaches. So anyone who has seen the circle's public `#h` can grow durable
//!   storage without bound for as long as the window stays open, and a raw
//!   `Retryable` row is never retired (`MARMOT_PROTOCOL_KNOWLEDGE.md`, beside
//!   #757). The window is opened the way the product opens it: a swallowed
//!   acknowledgement (`Fault::SwallowOk`) holds a staged relay-list commit in
//!   its publish-before-apply transition, `FLOOD_ROWS` forgeries are fed — not
//!   a flood past the other store's cap, because the confirm that closes the
//!   window replays every raw row it took (see the flood comment in
//!   `pending_window_flood`) — the plane is healed, and the same commit is
//!   acknowledged, confirmed, and the circle sends again.
//!   Composed with S22's undischargeable removal this window is permanent.
//!
//! # The recording story (decision 0.31)
//!
//! The bucket policy is `0 / 1 / 2-4 / 5+`: a flood renders `5+` from its
//! third sample and a byte delta renders `5+` always, so the growth CURVE is
//! unrepresentable in the timeline under Rule 15 as implemented. Every count
//! and every byte figure here is compared in process and never rendered; the
//! timeline carries one [`TimelineRecord::BufferGrew`] per arm with `grew` /
//! `did-not-grow` and nothing else.
//!
//! # The hard abort
//!
//! `Round::row_envelope` stays the in-arm abort for gating rows, and the
//! driver samples every world's session store at teardown against the rig's
//! declared ceiling (`SESSION_STORE_CEILING_BYTES`). Between the feeds of a
//! flood the same reading is taken here, and crossing the ceiling mid-arm is
//! rc 3 — the sim hitting its own guard — rather than a runner filling its
//! disk and dying as an anonymous timeout.
//!
//! # What each arm does NOT claim
//!
//! `outsider-flood` says nothing about the two uncapped stores, and the two
//! uncapped arms say nothing about a bound: they are the measurement OD-10
//! asks for, recorded as a classification, and the cap the product needs is
//! #757's to add.

use std::time::Duration;

use haven_core::circle::CommitToPublish;
use haven_core::location::LOCATION_MESSAGE_RETENTION_SECS;
use haven_core::nostr::mls::max_rewind_commits;
use haven_core::nostr::mls::types::{GroupId, MessageId, MessageState, OpenMlsContentKind};
use nostr::{Event, EventId};

use crate::nemesis::types::Fault;
use crate::oracle::undecryptable::{self, StoredRow};
use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{bounds, Invariant, ProbeToken, Reach, Recovery};
use crate::rc::Rc;
use crate::relay::{mint, Forgery};
use crate::rig::{
    CircleTag, DeviceTag, LogDrain, RelayPlane, RelayTag, RigError, SessionStoreUse, SimCircle,
    Step, TimelineRecord, TimelineSink, BUFFER_DID_NOT_GROW, BUFFER_GREW,
};
use crate::scenarios::{
    await_condition, closing_pairs, deliveries_for, grade_round, relay_update, round, Absence, Arm,
    ArmOutcome, ScenarioWorld, WithheldAcks, NO_GATING_ROWS,
};
use tokio::time::{Instant, MissedTickBehavior};

/// How many rows the two uncapped floods are measured over, and how far past
/// the capped store's cap the outsider flood feeds.
///
/// Eight, a literal of this scenario's own: more than one, so a monotone curve
/// is a curve and not a point, and small enough that a flood pays no ladder.
/// Past the cap it is also the number of drops the arm must SEE — one would
/// be a boundary, eight is the drop path holding.
const FLOOD_ROWS: usize = 8;

/// How many commits the member flood lands after its seals: the one that
/// proves legitimate traffic still converges. The seals are placed above the
/// gating horizon by this much more, so that commit cannot drag one into the
/// window it proves they never enter.
const ARM_COMMITS: u64 = 1;

/// The round the arms' own fixes are stamped with: not the graded round's
/// ordinal, so a late replay can never satisfy a closing-round probe.
const FIX_ROUND: u32 = 116;

/// How often a bounded wait for a delivery re-reads the ledger. A harness
/// cadence; no expectation is derived from it.
const DELIVERY_POLL: Duration = Duration::from_millis(20);

/// The arms this scenario offers.
pub const ARMS: [Arm; 3] = [
    Arm {
        label: "outsider-flood",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: false,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            // The one forgery the plane carries after the cap is hit.
            faults_applied: 1,
            epochs_crossed: 0,
            deliveries_observed: 1,
            canaries_caught: 4,
        },
    },
    Arm {
        label: "member-future-header-flood",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: false,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            // An outsider's re-signed replay of one member seal.
            faults_applied: 1,
            // The commit that proves legitimate traffic still converges with
            // the buffer full.
            epochs_crossed: 1,
            deliveries_observed: 1,
            canaries_caught: 4,
        },
    },
    Arm {
        label: "pending-window-flood",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: false,
        absence: Absence::None,
        // The staged commit published into the swallowed acknowledgement.
        withheld_acks: WithheldAcks::Fixed(1),
        floor: ExpectationFloor {
            // The swallowed acknowledgement, and the one forgery the plane
            // carries into the open window.
            faults_applied: 2,
            epochs_crossed: 0,
            deliveries_observed: 1,
            canaries_caught: 4,
        },
    },
];

/// The engine's per-group cap on retained `PeelDeferred` rows, read from the
/// engine rather than restated (decision 0.37).
#[must_use]
pub const fn peel_deferred_cap() -> usize {
    cgka_engine::message_processor::MAX_PEEL_DEFERRED_ROWS_PER_GROUP
}

/// Runs one arm.
///
/// # Errors
///
/// [`RigError::UnknownTarget`] if the label is not one this scenario offers,
/// [`RigError::ShapeMismatch`] if the world has fewer than two devices or, for
/// the member flood, fewer than two circles (the sibling is what proves the
/// rest of the store still converges), [`RigError::Core`] with
/// [`Step::SessionStoreCeiling`] if a flood crossed the rig's declared
/// ceiling, otherwise [`RigError`] naming the step that failed.
pub(crate) async fn run<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    arm: &Arm,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    let tags: Vec<DeviceTag> = world.devices().iter().map(|device| device.tag).collect();
    let [admin, peer, ..] = *tags.as_slice() else {
        return Err(RigError::ShapeMismatch);
    };
    let circle_tag = world.circles().first().ok_or(RigError::ShapeMismatch)?.tag;
    let plane = world
        .relays()
        .first()
        .map(RelayPlane::tag)
        .ok_or(RigError::ShapeMismatch)?;

    let mut classified: Vec<undecryptable::Verdict> = Vec::new();
    // The device whose store the arm floods: an outsider aims at any member,
    // a co-member's seal at a peer, and the window is the committer's own.
    let (canaries, victim) = match arm.label {
        "outsider-flood" => (
            outsider_flood(world, admin, peer, circle_tag, plane, &mut classified).await?,
            peer,
        ),
        "member-future-header-flood" => (
            member_future_header_flood(world, admin, peer, circle_tag, plane).await?,
            peer,
        ),
        "pending-window-flood" => (
            pending_window_flood(world, admin, circle_tag, plane, &mut classified).await?,
            admin,
        ),
        _ => return Err(RigError::UnknownTarget),
    };

    // The flooded device SENDS first: its store is what the arm leaned on, and
    // a send gate its flood closed shows up as a peer that never hears from it.
    let pairs = closing_pairs(world, victim);
    let closing = round(
        1,
        Reach::These(&pairs),
        Recovery::Undisturbed,
        tick,
        NO_GATING_ROWS,
        &[],
        &classified,
    );
    let mut invariants = vec![
        Invariant::Quiescence,
        Invariant::LocationRoundTrip,
        Invariant::SendPathLiveness,
    ];
    // The member flood is delivered over the wire, so it classifies nothing
    // itself; O5 over an empty set would report that nothing was looked at.
    if !classified.is_empty() {
        invariants.push(Invariant::Undecryptable);
    }
    let graded = grade_round(world, &closing, &invariants).await?;

    world.drain_buses();
    let observed = Observed::measure(world, canaries).await?;
    Ok(ArmOutcome {
        graded,
        observed,
        tick,
    })
}

/// The capped store: an outsider's un-peelable forgeries fill `PeelDeferred`
/// to its cap and not one row past it.
async fn outsider_flood<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    publisher: DeviceTag,
    victim: DeviceTag,
    circle_tag: CircleTag,
    plane: RelayTag,
    classified: &mut Vec<undecryptable::Verdict>,
) -> Result<usize, RigError> {
    let circle = world.circle(circle_tag)?;
    let routing = *circle.nostr_group_id();
    let group = circle.mls_group_id().clone();
    let cap = peel_deferred_cap();
    let bound = bounds::round_trip(Recovery::Undisturbed);
    let buffer_before = convergence_len(world, victim, &group).await?;
    let mut canaries = 0_usize;

    // The flood, fed through production's own ingest body one event at a time
    // so every row's disposition is read the instant it was written.
    let mut every_peel_failed = true;
    let mut persisted = 0_usize;
    let mut first_dropped_at: Option<usize> = None;
    for index in 0..cap + FLOOD_ROWS {
        let forged = mint(Forgery::OutsiderSeal { group_id: routing }, None)?;
        let verdict =
            undecryptable::classify(world.device(victim)?, &forged, StoredRow::Unknown).await?;
        every_peel_failed &= verdict == undecryptable::Verdict::PeelFailed;
        match row_state(world, victim, &forged.id).await? {
            Some(MessageState::PeelDeferred) => {
                persisted += 1;
                classified.push(verdict);
            }
            // The cap's only outward sign: no row where a peel failure below
            // it leaves one. The classification is set here, never by the
            // classifier, which sees one ingest and cannot tell the two apart.
            None => {
                first_dropped_at.get_or_insert(index);
                classified.push(undecryptable::Verdict::PeelDeferredCapped);
            }
            Some(_) => classified.push(verdict),
        }
        under_ceiling(world)?;
    }
    // 1. The cap was HIT: every feed peel-failed, and exactly `cap` of them
    //    were retained. Fewer would be an arm that never reached the cap;
    //    more would be the cap not holding.
    if every_peel_failed && persisted == cap {
        canaries += 1;
    }
    // 2. …and everything after it was dropped unpersisted, from the first
    //    feed past the cap to the last: the drop path held for all
    //    `FLOOD_ROWS` of them, not for a boundary case.
    if first_dropped_at == Some(cap)
        && classified
            .iter()
            .filter(|verdict| **verdict == undecryptable::Verdict::PeelDeferredCapped)
            .count()
            == FLOOD_ROWS
    {
        canaries += 1;
    }
    world.timeline().record(TimelineRecord::BufferGrew {
        tick: world.current_tick(),
        device: victim,
        circle: circle_tag,
        grew: grew(persisted > 0),
    });

    // 3. The live plane too: one more forgery, carried over the wire to the
    //    victim's own subscription after the cap, leaves no row either. A
    //    legitimate fix published BEHIND it is folded first, so the absence is
    //    read after the engine has passed the forgery, never while it is still
    //    in flight.
    inject(world, plane, Forgery::OutsiderSeal { group_id: routing }).await?;
    let injected = last_injected(world, plane).ok_or(RigError::Core(Step::ApplyFault))?;
    let carried = await_condition(bound, || async {
        Ok(relay_of(world, plane)?.ledger().delivered(&injected) >= 1)
    })
    .await?;
    let delivered = matched_positive(world, publisher, victim, circle_tag, 1).await?;
    if carried && delivered && row_state(world, victim, &injected).await?.is_none() {
        canaries += 1;
    }
    // 4. The flood never touched the OTHER stores: the convergence buffer is
    //    where it was before, and nothing gates the victim's outbound path.
    //    Without this the arm could be measuring the uncapped store and
    //    calling the number a cap.
    if convergence_len(world, victim, &group).await? == buffer_before
        && gating(world, victim, &group).await? == 0
    {
        canaries += 1;
    }
    Ok(canaries)
}

/// The uncapped convergence buffer: a co-member's future-header seals grow it
/// one row each, and nothing legitimate drains or is blocked by them.
async fn member_future_header_flood<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    sealer: DeviceTag,
    victim: DeviceTag,
    circle_tag: CircleTag,
    plane: RelayTag,
) -> Result<usize, RigError> {
    let sibling_tag = world.circles().get(1).ok_or(RigError::ShapeMismatch)?.tag;
    let group = world.circle(circle_tag)?.mls_group_id().clone();
    let bound = bounds::round_trip(Recovery::Undisturbed);
    let tip = epoch_of(world, victim, &group).await?;
    // The first epoch the gating scan will not look at even after this arm's
    // own commit has moved the tip: every seal sits above it, so
    // `gating_input_count` cannot move and no seal ever gates a send, and every
    // one is distinct, so every one is a row of its own.
    let horizon = tip
        .saturating_add(max_rewind_commits())
        .saturating_add(1)
        .saturating_add(ARM_COMMITS);
    let mut canaries = 0_usize;

    // The in-arm control: the same counter, before the flood, in this world.
    let before = convergence_len(world, victim, &group).await?;
    let gating_before = gating(world, victim, &group).await?;
    let mut samples = vec![before];
    let mut seals: Vec<Event> = Vec::with_capacity(FLOOD_ROWS);
    for index in 0..FLOOD_ROWS {
        let inner_epoch = horizon.saturating_add(index as u64);
        let seal = world
            .device(sealer)?
            .session()?
            .forge_future_header_445_for_test(&group, inner_epoch)
            .await
            .map_err(|_| RigError::Core(Step::Publish))?;
        if world
            .publish_witnessed(sealer, std::slice::from_ref(&seal))
            .await?
            .is_none()
        {
            // Nothing crossed the wire, so there is no seal for the victim to
            // receive and no flood to measure.
            return Err(RigError::PublishNeverAcked);
        }
        observed_by_the_plane(world, plane, &seal.id).await?;
        let previous = *samples.last().unwrap_or(&before);
        let grew = await_condition(bound, || async {
            Ok(convergence_len(world, victim, &group).await? > previous)
        })
        .await?;
        samples.push(convergence_len(world, victim, &group).await?);
        under_ceiling(world)?;
        seals.push(seal);
        if !grew {
            // The curve is already broken; feeding more measures nothing.
            break;
        }
    }
    // 1. The count grew with every seal — a strictly increasing curve over
    //    the whole flood, compared in process and never rendered.
    if samples.len() == FLOOD_ROWS + 1 && samples.windows(2).all(|pair| pair[0] < pair[1]) {
        canaries += 1;
    }
    world.timeline().record(TimelineRecord::BufferGrew {
        tick: world.current_tick(),
        device: victim,
        circle: circle_tag,
        grew: grew(samples.last().is_some_and(|last| *last > before)),
    });
    // 2. Proof of vector: the newest stored application row above the horizon
    //    PROJECTED — an openmls-wire row the locator read an epoch off, not a
    //    raw `PeelDeferred` one — so it is in convergence, and the gating count
    //    never moved. Without this read the arm would be the outsider flood
    //    wearing this arm's label.
    if entered_convergence(world, victim, &group, horizon).await?
        && gating(world, victim, &group).await? == gating_before
    {
        canaries += 1;
    }

    // 3. An outsider's re-signed replay of one seal is carried to the victim
    //    and grows nothing: the store is keyed by content, so a member's seal
    //    cannot be amplified by somebody re-signing it. A legitimate fix
    //    published behind the replay is folded first, so "grew nothing" is
    //    read after the engine has passed it.
    let after_flood = *samples.last().unwrap_or(&before);
    if let Some(first) = seals.first() {
        inject(
            world,
            plane,
            Forgery::FutureInnerHeader {
                source: first.id,
                inner_epoch: horizon,
            },
        )
        .await?;
        let injected = last_injected(world, plane).ok_or(RigError::Core(Step::ApplyFault))?;
        let carried = await_condition(bound, || async {
            Ok(relay_of(world, plane)?.ledger().delivered(&injected) >= 1)
        })
        .await?;
        let delivered = matched_positive(world, sealer, victim, circle_tag, 1).await?;
        if carried && delivered && convergence_len(world, victim, &group).await? == after_flood {
            canaries += 1;
        }
    }

    // 4. Legitimate traffic still converges with the buffer full: one real
    //    commit lands and the victim follows it, a fix crosses the SIBLING
    //    circle in the same store, and the far-future rows are still there —
    //    nothing drained them, because nothing can.
    let commit = confirmed_commit(world, sealer, circle_tag).await?;
    let followed = await_condition(bound, || async {
        Ok(epoch_of(world, victim, &group).await? == epoch_of(world, sealer, &group).await?)
    })
    .await?;
    let sibling_delivered = matched_positive(world, sealer, victim, sibling_tag, 2).await?;
    if commit
        && followed
        && sibling_delivered
        && convergence_len(world, victim, &group).await? == after_flood
    {
        canaries += 1;
    }
    Ok(canaries)
}

/// The uncapped raw `Retryable` persist: an outsider's forgeries land one row
/// each for as long as the publish window stays open, with nothing counting
/// them, and the circle recovers once the window closes.
async fn pending_window_flood<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    admin: DeviceTag,
    circle_tag: CircleTag,
    plane: RelayTag,
    classified: &mut Vec<undecryptable::Verdict>,
) -> Result<usize, RigError> {
    let circle = world.circle(circle_tag)?;
    let routing = *circle.nostr_group_id();
    let group = circle.mls_group_id().clone();
    let bound = bounds::round_trip(Recovery::Undisturbed);
    let mut relays = world.relay_urls();
    relays.push("wss://s16-window.example.com".to_owned());
    let mut canaries = 0_usize;

    swallow(world, true).await?;
    let before_epoch = epoch_of(world, admin, &group).await?;
    let guard = world.note_pending_staged();
    let staged = world
        .device(admin)?
        .manager()?
        .update_circle_relays(&group, &relays)
        .await
        .map_err(|_| RigError::Core(Step::StageCommit))?;
    let acked = world
        .publish_witnessed(admin, std::slice::from_ref(&staged.commit_event))
        .await?;
    // Rule 13 in both directions: an acknowledgement that DID arrive licenses
    // the confirm at once and closes the window before any flood. That is the
    // mis-configuration's shape, and the arm then measures a window that
    // never opened rather than holding one open by hand.
    let window_open = acked.is_none();
    if !window_open {
        let ingest = world
            .device(admin)?
            .manager()?
            .finalize_relay_update(staged.pending, &group)
            .await
            .map_err(|_| RigError::Core(Step::ConfirmPublished))?;
        world.resolve_ingest(admin, ingest).await?;
    }
    // 1. The window is open the way the product opens it: the relay HAS the
    //    commit, the committer never heard so, and its send gate is closed.
    if window_open
        && stored_but_unacked(world, &staged.commit_event).await?
        && seal(world, admin, &group, 0).await.is_err()
    {
        canaries += 1;
    }

    // The flood. `FLOOD_ROWS` rather than past the other store's cap, because
    // the confirm that closes the window REPLAYS every raw row it took —
    // measured 2026-09-26 at roughly a quarter of a second per row, so a flood
    // past the cap costs the confirm a minute the arm's bound does not hold.
    // That the persist reserves no slot is the cited mechanism; the growth
    // measured here is one row per forgery with nothing counting them.
    let buffer_before = convergence_len(world, admin, &group).await?;
    let gating_before = gating(world, admin, &group).await?;
    let mut fed: Vec<EventId> = Vec::with_capacity(FLOOD_ROWS);
    let mut every_buffered = true;
    let mut every_row_retryable = true;
    for _ in 0..FLOOD_ROWS {
        let forged = mint(Forgery::OutsiderSeal { group_id: routing }, None)?;
        let verdict =
            undecryptable::classify(world.device(admin)?, &forged, StoredRow::Unknown).await?;
        classified.push(verdict);
        every_buffered &= verdict == undecryptable::Verdict::CommitGap;
        every_row_retryable &=
            row_state(world, admin, &forged.id).await? == Some(MessageState::Retryable);
        fed.push(forged.id);
        under_ceiling(world)?;
        if !(every_buffered && every_row_retryable) {
            // A row that did not land raw is the window not being open;
            // feeding more measures nothing.
            break;
        }
    }
    // 2. Every forgery was buffered BEFORE the peel and persisted raw, one row
    //    each: the persist at `ingest.rs:198-209` reserves no slot.
    if every_buffered && every_row_retryable && fed.len() == FLOOD_ROWS {
        canaries += 1;
    }
    world.timeline().record(TimelineRecord::BufferGrew {
        tick: world.current_tick(),
        device: admin,
        circle: circle_tag,
        grew: grew(every_row_retryable && !fed.is_empty()),
    });
    // 3. The live plane too — one forgery carried over the wire into the open
    //    window lands raw — and the flood touched neither other store: the
    //    convergence buffer and the gating count are where they were.
    inject(world, plane, Forgery::OutsiderSeal { group_id: routing }).await?;
    let injected = last_injected(world, plane).ok_or(RigError::Core(Step::ApplyFault))?;
    let landed = await_condition(bound, || async {
        Ok(row_state(world, admin, &injected).await? == Some(MessageState::Retryable))
    })
    .await?;
    if landed
        && convergence_len(world, admin, &group).await? == buffer_before
        && gating(world, admin, &group).await? == gating_before
    {
        canaries += 1;
    }

    // The heal: the same commit, acknowledged this time, confirmed under
    // Rule 13 — and the circle sends again.
    swallow(world, false).await?;
    let recovered = if window_open {
        confirm_after_heal(world, admin, &group, &staged).await?
    } else {
        false
    };
    drop(guard);
    // 4. Recovered: the epoch advanced, every device follows it, and the send
    //    gate is open again. The rows the window took are still in the store
    //    — a raw `Retryable` row is never retired — which is the finding
    //    OQ-B records, not a promise this arm grades.
    if recovered
        && epoch_of(world, admin, &group).await? > before_epoch
        && seal(world, admin, &group, 1).await.is_ok()
    {
        canaries += 1;
    }
    Ok(canaries)
}

/// Publishes the window's commit again onto healed planes, confirms it on the
/// acknowledgement, drains the replay, and waits for every device to reach the
/// epoch it advanced.
async fn confirm_after_heal<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    admin: DeviceTag,
    group: &GroupId,
    staged: &CommitToPublish,
) -> Result<bool, RigError> {
    if world
        .publish_witnessed(admin, std::slice::from_ref(&staged.commit_event))
        .await?
        .is_none()
    {
        return Err(RigError::PublishNeverAcked);
    }
    let ingest = world
        .device(admin)?
        .manager()?
        .finalize_relay_update(staged.pending, group)
        .await
        .map_err(|_| RigError::Core(Step::ConfirmPublished))?;
    world.resolve_ingest(admin, ingest).await?;
    await_condition(bounds::round_trip(Recovery::Undisturbed), || async {
        let tip = epoch_of(world, admin, group).await?;
        for device in world.devices() {
            if epoch_of(world, device.tag, group).await? != tip {
                return Ok(false);
            }
        }
        Ok(true)
    })
    .await
}

/// The classification a flood's reading renders.
const fn grew(grew: bool) -> &'static str {
    if grew {
        BUFFER_GREW
    } else {
        BUFFER_DID_NOT_GROW
    }
}

/// Reads every device's session store against the rig's declared ceiling.
///
/// A raw count compared in process; crossing the ceiling is the sim hitting
/// its own guard, and the arm stops there rather than fill the runner's disk.
fn under_ceiling<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
) -> Result<(), RigError> {
    if SessionStoreUse::of(world.session_store_bytes()?).rc() == Rc::Clean {
        Ok(())
    } else {
        Err(RigError::Core(Step::SessionStoreCeiling))
    }
}

/// The disposition of the stored row keyed by `event_id` on `device`, or
/// `None` when no row carries it.
///
/// A raw transport row — the two outsider stores — is keyed by the event id
/// itself; a peeled row is rebound to its content id and cannot be named this
/// way, which is what [`entered_convergence`] is for.
async fn row_state<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    event_id: &EventId,
) -> Result<Option<MessageState>, RigError> {
    world
        .device(device)?
        .session()?
        .stored_message_record_for_test(&MessageId::new(event_id.to_bytes().to_vec()))
        .await
        .map(|probe| probe.map(|probe| probe.state))
        .map_err(|_| RigError::Core(Step::ReadConvergenceState))
}

/// Whether `device` holds an application row for `group` at or above `epoch`
/// that PROJECTED — an openmls-wire row the locator could read an epoch off —
/// and is not a raw `PeelDeferred` one. (At this pin canonicalisation leaves an
/// unresolvable future row in `Retryable`; the claim here is the STORE, not
/// the disposition the engine chose for it.)
async fn entered_convergence<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    group: &GroupId,
    epoch: u64,
) -> Result<bool, RigError> {
    Ok(world
        .device(device)?
        .session()?
        .stored_convergence_input_for_test(group, OpenMlsContentKind::Application, epoch)
        .await
        .is_ok_and(|record| record.state != MessageState::PeelDeferred))
}

/// How many rows `device` holds in `group`'s convergence buffer.
async fn convergence_len<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    group: &GroupId,
) -> Result<usize, RigError> {
    world
        .device(device)?
        .session()?
        .convergence_buffer_len_for_test(group)
        .await
        .map_err(|_| RigError::Core(Step::ReadConvergenceState))
}

/// How many rows are gating `group` on `device`.
async fn gating<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    group: &GroupId,
) -> Result<usize, RigError> {
    world
        .device(device)?
        .session()?
        .gating_input_count(group)
        .await
        .map_err(|_| RigError::Core(Step::ReadGatingRows))
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

/// Forges one event onto every subscription on `plane` whose filter matches
/// it.
async fn inject<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    plane: RelayTag,
    recipe: Forgery,
) -> Result<(), RigError> {
    world
        .relays_mut()
        .iter_mut()
        .find(|candidate| candidate.tag() == plane)
        .ok_or(RigError::UnknownTarget)?
        .apply(Fault::Inject(recipe))
        .await
}

/// The plane `tag` names.
fn relay_of<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    tag: RelayTag,
) -> Result<&crate::relay::SimRelay, RigError> {
    world
        .relays()
        .iter()
        .find(|candidate| candidate.tag() == tag)
        .ok_or(RigError::UnknownTarget)
}

/// The id of the event `plane` forged most recently.
fn last_injected<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    plane: RelayTag,
) -> Option<EventId> {
    relay_of(world, plane)
        .ok()?
        .ledger()
        .injected_ids()
        .last()
        .copied()
}

/// Waits, bounded, for `plane` to have carried `event_id` from a client.
async fn observed_by_the_plane<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    plane: RelayTag,
    event_id: &EventId,
) -> Result<(), RigError> {
    let carried = await_condition(bounds::round_trip(Recovery::Undisturbed), || async {
        relay_of(world, plane)?.stored(event_id).await
    })
    .await?;
    if carried {
        Ok(())
    } else {
        // A replay copies an OBSERVED seal; a plane that never carried it has
        // nothing to copy.
        Err(RigError::PublishNeverAcked)
    }
}

/// Turns the swallowed acknowledgement on or off across every plane.
async fn swallow<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    on: bool,
) -> Result<(), RigError> {
    let fault = if on { Fault::SwallowOk } else { Fault::Heal };
    for plane in world.relays_mut() {
        plane.apply(fault).await?;
    }
    Ok(())
}

/// Whether some plane holds `event` while none acknowledged it client-ward.
async fn stored_but_unacked<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    event: &Event,
) -> Result<bool, RigError> {
    let mut stored = false;
    for plane in world.relays() {
        if plane.stored(&event.id).await? {
            stored = true;
        }
        if plane.witnessed_ok(&event.id) {
            return Ok(false);
        }
    }
    Ok(stored)
}

/// One confirmed relay-list commit from `device`, carrying a relay list the
/// group does not already hold — a repeat is a no-op and advances no epoch.
async fn confirmed_commit<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    circle_tag: CircleTag,
) -> Result<bool, RigError> {
    let mut relays = world.relay_urls();
    relays.push("wss://s16-full-buffer.example.com".to_owned());
    let circle: &SimCircle = world.circle(circle_tag)?;
    let (_, verdict) = relay_update(world, device, circle, &relays).await?;
    Ok(verdict == crate::rig::PublishVerdict::Confirmed)
}

/// Publishes one legitimate fix into `circle` from `publisher` and waits for
/// `victim` to fold it.
async fn matched_positive<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    publisher: DeviceTag,
    victim: DeviceTag,
    circle_tag: CircleTag,
    index: u32,
) -> Result<bool, RigError> {
    let group = world.circle(circle_tag)?.mls_group_id().clone();
    world.drain_buses();
    let before = deliveries_for(world.device(victim)?, circle_tag);
    let event = seal(world, publisher, &group, index).await?;
    if world
        .publish_witnessed(publisher, std::slice::from_ref(&event))
        .await?
        .is_none()
    {
        return Ok(false);
    }
    await_delivery(world, victim, circle_tag, before).await
}

/// Waits, bounded, for `device`'s folded delivery count for `circle` to rise
/// above `above`, draining the buses on every read.
async fn await_delivery<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    device: DeviceTag,
    circle: CircleTag,
    above: u64,
) -> Result<bool, RigError> {
    let bound = bounds::round_trip(Recovery::Undisturbed);
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
            &ProbeToken::mint(FIX_ROUND, index).as_location(),
            LOCATION_MESSAGE_RETENTION_SECS,
        )
        .await
        .map(|(event, _, _)| event)
        .map_err(|_| RigError::Core(Step::Publish))
}

#[cfg(test)]
mod tests {
    use super::{peel_deferred_cap, ARMS, FIX_ROUND, FLOOD_ROWS};
    use crate::oracle::Recovery;
    use crate::scenarios::WithheldAcks;

    #[test]
    fn every_arm_floods_undisturbed_and_reads_four_things() {
        for arm in &ARMS {
            assert!(
                arm.recovery == Recovery::Undisturbed,
                "a flood closes no socket, so the pool's ladder is not in the path"
            );
            assert!(
                !arm.resubscribes && arm.probe_rounds == 1,
                "one closing round; nothing re-opens a subscription"
            );
            assert!(
                arm.floor.canaries_caught == 4,
                "the growth, its proof of store, the wire's copy of it, and the \
                 legitimate traffic that still lands"
            );
            assert!(
                arm.floor.deliveries_observed >= 1,
                "a flood that delivered nothing legitimate proves only that nothing crashed"
            );
        }
    }

    #[test]
    fn the_outsider_flood_carries_one_forgery_and_crosses_no_epoch() {
        assert!(
            ARMS[0].floor.faults_applied == 1 && ARMS[0].floor.epochs_crossed == 0,
            "an outsider's forgery that advanced an epoch would be one that authenticated"
        );
    }

    #[test]
    fn the_member_flood_replays_one_seal_and_still_crosses_an_epoch() {
        assert!(
            ARMS[1].floor.faults_applied == 1,
            "the outsider's re-signed replay is the one plane fault"
        );
        assert!(
            ARMS[1].floor.epochs_crossed == 1,
            "a commit must land with the buffer full, or `still converges` is unproven"
        );
    }

    #[test]
    fn the_window_flood_pays_for_its_withheld_commit_and_two_faults() {
        assert!(
            ARMS[2].withheld_acks == WithheldAcks::Fixed(1),
            "the staged commit is published into the swallowed acknowledgement once"
        );
        assert!(
            ARMS[2].floor.faults_applied == 2 && ARMS[2].floor.epochs_crossed == 0,
            "the swallowed acknowledgement and the forgery carried into the window; \
             the epoch the confirm crosses is carried as a canary"
        );
    }

    #[test]
    fn the_cap_is_the_engines_own_and_the_flood_reaches_past_it() {
        assert!(
            peel_deferred_cap() == cgka_engine::message_processor::MAX_PEEL_DEFERRED_ROWS_PER_GROUP,
            "the cap is read from the engine, never restated"
        );
        const { assert!(FLOOD_ROWS > 1, "one sample is a point, not a curve") }
    }

    #[test]
    fn arm_fixes_are_stamped_outside_the_graded_round() {
        const { assert!(FIX_ROUND != 1) }
    }
}
