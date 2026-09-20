//! O6: when a world has stopped moving, and how long it is allowed to take.
//!
//! # Settle, then check
//!
//! Every liveness assertion in this crate runs after this module says the world
//! is quiescent. A miss under an unhealed fault is not a violation — it is the
//! fault — so a scenario applies its faults, heals them, waits here until the
//! derived deadline, and only then grades. That ordering is the difference
//! between a soak run that finds defects and one that manufactures them.
//!
//! # Two halves, and why neither alone is enough
//!
//! Quiescence is a PREDICATE over the engine's own counters, and separately the
//! world's [`WorldFingerprint`] being unchanged across
//! [`STABILITY_TICKS`] consecutive observations. The predicate alone would
//! declare a world settled in the gap between two commits; the fingerprint alone
//! would declare one settled while a publish was on the wire, because an
//! in-flight publish changes no epoch, no roster and no row until it lands.
//!
//! # What is deliberately NOT a term
//!
//! `ConvergenceSweep::is_settled()` — the only thing that produces one is
//! `sweep_unresolvable_inputs`, which WRITES on the caller's policy clock.
//! Sweeping once per tick would retire the very rows a stuck-row scenario
//! planted and then report the world settled, which is manufacturing the answer.
//! The non-mutating `gating_input_count` is a term instead, and it is what
//! `is_settled()` reads anyway. A sweep's verdict may only be read from the last
//! DELIBERATE sweep a scenario asked for.
//!
//! `wait_backlog_settled()` is not a term either: with no open burst window it
//! answers `TimedOut` at once by design, so inside a tick predicate it would
//! make every paused device permanently non-quiescent, and with a window open it
//! costs a whole `BURST_BACKLOG_WAIT` per silent endpoint per tick. It runs
//! once, at the settle-then-check boundary, through
//! [`confirm_backlog_settled`], for the devices whose window the harness itself
//! opened.

use std::time::Duration;

use haven_core::relay::live_sync::BacklogOutcome;
use tokio::time::{Instant, MissedTickBehavior};

use crate::oracle::bounds::{self, Recovery};
use crate::rig::{
    CircleTag, DeviceTag, LogDrain, RelayPlane, RigError, SimWorld, Step, TimelineSink,
    WorldFingerprint,
};

/// How many consecutive observations of one unchanged fingerprint make a world
/// stable.
///
/// Three, because two is satisfiable by a world that happens to be between two
/// steps of the same operation — a publish that has left one device and not yet
/// reached the other changes nothing observable for exactly one gap — while
/// three requires the world to be unchanged across two whole tick intervals.
pub const STABILITY_TICKS: u8 = 3;

/// The shortest interval a settle loop will re-read at.
///
/// A floor rather than an assertion because `tokio`'s interval panics on a zero
/// period, and a profile whose tick rounds to zero is a configuration mistake
/// that should not take the process down.
const POLL_FLOOR: Duration = Duration::from_millis(1);

/// Whether the world has stopped moving.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Quiescence {
    /// Every term holds for every online device.
    Quiescent,
    /// The first term that did not hold.
    Pending(PendingReason),
}

/// Which term of the predicate is still outstanding.
///
/// Value-free: a handle names WHICH device or circle, never what it is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PendingReason {
    /// The rig staged a commit it has neither confirmed nor rolled back. Rule
    /// 13's own state, and the one a fingerprint cannot see.
    StagedCommit,
    /// Every device is offline, so the predicate would hold over an empty set.
    /// Answered as pending rather than quiescent: a world nobody is running is
    /// not a world that settled.
    NoOnlineDevice,
    /// A publish is between SEND and OK.
    InFlightPublish(DeviceTag),
    /// A cursor-anchor generation has not spent its advance.
    AdvanceUnconsumed(DeviceTag),
    /// The pool holds fewer REQ pairs than the session expects — a deleted
    /// subscription the pool will never re-issue.
    SubscriptionShortfall(DeviceTag),
    /// A durable eviction obligation is unredeemed.
    RemovalOwed(DeviceTag),
    /// Stored inputs still gate this circle's outbound path.
    GatingInputs(DeviceTag, CircleTag),
    /// Outbound intents are durably queued for this circle.
    QueuedIntents(DeviceTag, CircleTag),
    /// A stored proposal is still waiting for a commit.
    PendingProposal(DeviceTag, CircleTag),
    /// The predicate holds, but the world's fingerprint is still moving.
    FingerprintMoving,
}

/// How a settle ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Settled {
    /// The world went quiet, and how long it took. The duration is a
    /// measurement, which is why it may be printed exactly.
    Quiescent(Duration),
    /// The derived deadline elapsed with this term still outstanding.
    TimedOut(PendingReason),
}

/// Whether every online device's engine has stopped moving, right now.
///
/// Reads only; nothing here writes, sweeps or advances anything. Offline devices
/// are skipped — a paused engine holds no REQ and is legitimately behind, so
/// grading it would report a defect the product does not have — and a world with
/// no online device at all answers [`PendingReason::NoOnlineDevice`] rather than
/// vacuously quiescent.
///
/// # Errors
///
/// [`RigError`] naming the read that failed, or
/// [`RigError::SessionNotLive`] if a device is between a kill and its reopen.
pub async fn quiescent<R: RelayPlane, T: TimelineSink, L: LogDrain>(
    world: &SimWorld<R, T, L>,
) -> Result<Quiescence, RigError> {
    // First, because it is the cheapest AND the one Rule-13 term no engine
    // counter and no fingerprint can answer.
    if world.outstanding_pending_refs() != 0 {
        return Ok(Quiescence::Pending(PendingReason::StagedCommit));
    }

    let mut online = 0_usize;
    for device in world.devices() {
        if device.offline {
            continue;
        }
        online += 1;
        let engine = device.engine()?;
        if engine.in_flight_publishes() != 0 {
            return Ok(Quiescence::Pending(PendingReason::InFlightPublish(
                device.tag,
            )));
        }
        if !engine.processor().all_advances_consumed() {
            return Ok(Quiescence::Pending(PendingReason::AdvanceUnconsumed(
                device.tag,
            )));
        }
        let health = engine.relay_health().await;
        if health.subscriptions_live != health.subscriptions_expected {
            return Ok(Quiescence::Pending(PendingReason::SubscriptionShortfall(
                device.tag,
            )));
        }
        if !device.manager()?.owed_removal_commits().is_empty() {
            return Ok(Quiescence::Pending(PendingReason::RemovalOwed(device.tag)));
        }
        if let Some(reason) = circle_terms(world, device).await? {
            return Ok(Quiescence::Pending(reason));
        }
    }

    if online == 0 {
        return Ok(Quiescence::Pending(PendingReason::NoOnlineDevice));
    }
    Ok(Quiescence::Quiescent)
}

/// The per-circle half of the predicate for one device.
///
/// All three reads are non-mutating by construction — `gating_input_count`
/// counts without ageing anything out, and neither of the other two writes —
/// which is what lets the predicate run every tick without changing the world it
/// is grading.
async fn circle_terms<R: RelayPlane, T: TimelineSink, L: LogDrain>(
    world: &SimWorld<R, T, L>,
    device: &crate::rig::SimDevice,
) -> Result<Option<PendingReason>, RigError> {
    let session = device.session()?;
    for circle in world.circles() {
        let group = circle.mls_group_id();
        // One `Step` for all three: they are one question — is this circle's
        // convergence state clear — asked three ways, and a wrong-but-close
        // classification is worse than the shared one.
        let gating = session
            .gating_input_count(group)
            .await
            .map_err(|_| RigError::Core(Step::ReadConvergenceState))?;
        if gating != 0 {
            return Ok(Some(PendingReason::GatingInputs(device.tag, circle.tag)));
        }
        let queued = session
            .queued_intent_count_for_test(group)
            .await
            .map_err(|_| RigError::Core(Step::ReadConvergenceState))?;
        if queued != 0 {
            return Ok(Some(PendingReason::QueuedIntents(device.tag, circle.tag)));
        }
        if session
            .has_pending_proposal(group)
            .await
            .map_err(|_| RigError::Core(Step::ReadConvergenceState))?
        {
            return Ok(Some(PendingReason::PendingProposal(device.tag, circle.tag)));
        }
    }
    Ok(None)
}

/// A run of consecutive observations of one unchanged world fingerprint.
#[derive(Debug, Clone, Default)]
pub struct StabilityWindow {
    last: Option<WorldFingerprint>,
    streak: u8,
}

impl StabilityWindow {
    /// A window that has seen nothing.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            last: None,
            streak: 0,
        }
    }

    /// Folds one observation in and answers whether the world is now stable.
    ///
    /// A changed fingerprint restarts the run at one rather than at zero: the
    /// observation that differs is itself the first of the new run, and zeroing
    /// would charge the caller an extra tick for every change.
    pub fn observe(&mut self, fingerprint: &WorldFingerprint) -> bool {
        if self.last.as_ref() == Some(fingerprint) {
            self.streak = self.streak.saturating_add(1);
        } else {
            self.streak = 1;
            self.last = Some(fingerprint.clone());
        }
        self.is_stable()
    }

    /// Whether the run is long enough.
    #[must_use]
    pub const fn is_stable(&self) -> bool {
        self.streak >= STABILITY_TICKS
    }

    /// How many consecutive unchanged observations the window holds.
    #[must_use]
    pub const fn streak(&self) -> u8 {
        self.streak
    }
}

/// Runs the world until it is quiescent AND stable, or until the derived
/// deadline.
///
/// The deadline is [`bounds::quiescence`] for `recovery` — never a number this
/// function chose — so a red result reads "expected within the reconnect ladder
/// plus the settle window, observed longer". Each pass drains the devices' buses
/// first, because a delivery nobody folded is a delivery the ledgers under-count
/// and a fingerprint that keeps moving for a reason no term can name.
///
/// # Errors
///
/// [`RigError`] naming the read that failed.
pub async fn settle<R: RelayPlane, T: TimelineSink, L: LogDrain>(
    world: &mut SimWorld<R, T, L>,
    recovery: Recovery,
    tick: Duration,
) -> Result<Settled, RigError> {
    let deadline = bounds::quiescence(recovery, tick);
    let started = Instant::now();
    let mut window = StabilityWindow::new();
    let mut ticker = tokio::time::interval(tick.max(POLL_FLOOR));
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    loop {
        world.drain_buses();
        let fingerprint = world.fingerprint().await?;
        let stable = window.observe(&fingerprint);
        let verdict = quiescent(world).await?;
        match verdict {
            Quiescence::Quiescent if stable => return Ok(Settled::Quiescent(started.elapsed())),
            _ => {
                if started.elapsed() >= deadline {
                    return Ok(Settled::TimedOut(match verdict {
                        Quiescence::Pending(reason) => reason,
                        Quiescence::Quiescent => PendingReason::FingerprintMoving,
                    }));
                }
            }
        }
        ticker.tick().await;
    }
}

/// Asks each named device whether the endpoints ITS burst opened have finished
/// their stored replay, and returns the ones that had not.
///
/// # Only devices whose window this phase opened
///
/// `wait_backlog_settled` answers `TimedOut` immediately when no burst window is
/// open — deliberately, because the honest answer for "did the REQs this burst
/// opened settle" when there is no burst is not `Settled`. So passing a device
/// the harness did not just start, resume or open a burst on manufactures a
/// failure. Paused devices are skipped here for that reason rather than
/// reported, and the caller owes the rest of the discipline.
///
/// Sequential, one device at a time: this crate takes no futures dependency, and
/// the call is bounded by the product's own burst backlog wait per device and
/// runs once per settle boundary rather than per tick.
///
/// # Errors
///
/// [`RigError::UnknownTarget`] if a named device is not in the world, or
/// [`RigError::SessionNotLive`] if it holds no engine.
pub async fn confirm_backlog_settled<R: RelayPlane, T: TimelineSink, L: LogDrain>(
    world: &SimWorld<R, T, L>,
    devices: &[DeviceTag],
) -> Result<Vec<DeviceTag>, RigError> {
    let mut unsettled = Vec::new();
    for &tag in devices {
        let device = world.device(tag)?;
        if device.offline {
            continue;
        }
        if device.engine()?.wait_backlog_settled().await != BacklogOutcome::Settled {
            unsettled.push(tag);
        }
    }
    Ok(unsettled)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nemesis::types::Schedule;
    use crate::profiles::WorldShape;
    use crate::rig::doubles::{RecordingTimeline, StubDrain, TestRelay};
    use crate::rig::RelayTag;

    type TestWorld = SimWorld<TestRelay, RecordingTimeline, StubDrain>;

    const fn smallest_shape() -> WorldShape {
        WorldShape {
            members: 2,
            circles: 1,
            relays: 1,
        }
    }

    async fn build_world() -> TestWorld {
        let relay = TestRelay::start(RelayTag::new(0)).await;
        SimWorld::build(
            &smallest_shape(),
            Schedule::new(Vec::new()),
            vec![relay],
            RecordingTimeline::default(),
            StubDrain::default(),
        )
        .await
        .unwrap_or_else(|failure| panic!("world builds: {failure}"))
    }

    /// A fingerprint that differs from another only in the one field this test
    /// needs to move.
    fn fingerprint_with(pending: usize) -> WorldFingerprint {
        WorldFingerprint {
            devices: Vec::new(),
            outstanding_pending_refs: pending,
        }
    }

    #[test]
    fn every_pending_reason_renders_a_term_and_at_most_a_handle() {
        let device = DeviceTag::new(4);
        let circle = CircleTag::new(2);
        let reasons = [
            PendingReason::StagedCommit,
            PendingReason::NoOnlineDevice,
            PendingReason::InFlightPublish(device),
            PendingReason::AdvanceUnconsumed(device),
            PendingReason::SubscriptionShortfall(device),
            PendingReason::RemovalOwed(device),
            PendingReason::GatingInputs(device, circle),
            PendingReason::QueuedIntents(device, circle),
            PendingReason::PendingProposal(device, circle),
            PendingReason::FingerprintMoving,
        ];
        for reason in reasons {
            let rendered = format!("{:?}", Quiescence::Pending(reason));
            assert!(rendered.starts_with("Pending("), "{rendered}");
            // The rig's own vocabulary, never production's and never a value.
            assert!(!rendered.contains("ws://"), "{rendered}");
            assert!(!rendered.contains("npub"), "{rendered}");
            // At a WORD BOUNDARY, which is where a reader and a scanner look:
            // the rig's `simcircle#2` contains `circle#` and is not production's
            // handle, and the `sim` prefix is exactly what keeps it off that
            // boundary.
            for production in ["circle#", "peer#", "relay#", "subscription#"] {
                if let Some(at) = rendered.find(production) {
                    assert!(
                        at > 0 && rendered.as_bytes()[at - 1].is_ascii_alphanumeric(),
                        "{rendered}"
                    );
                }
            }
        }
        assert!(
            format!("{:?}", reasons[6]).contains("simdev#4"),
            "a reason that names a device renders its handle, so two lines can be \
             tied together without either naming the device"
        );
        assert!(format!("{:?}", reasons[6]).contains("simcircle#2"));
        assert_eq!(format!("{:?}", Quiescence::Quiescent), "Quiescent");
    }

    #[test]
    fn a_window_needs_three_unchanged_observations_and_a_change_restarts_the_run() {
        let mut window = StabilityWindow::new();
        let steady = fingerprint_with(0);
        for _ in 1..STABILITY_TICKS {
            assert!(!window.observe(&steady));
        }
        assert!(window.observe(&steady));
        assert_eq!(window.streak(), STABILITY_TICKS);

        // One change and the world is no longer stable, however long it was
        // steady before.
        assert!(!window.observe(&fingerprint_with(1)));
        assert!(!window.is_stable());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_built_world_settles_and_reports_how_long_it_took() {
        let mut world = build_world().await;
        let settled = settle(&mut world, Recovery::Undisturbed, Duration::from_millis(20))
            .await
            .expect("settle reads");
        assert!(
            matches!(settled, Settled::Quiescent(_)),
            "a world that has only just been built has nothing outstanding"
        );
        assert_eq!(
            quiescent(&world).await.expect("predicate reads"),
            Quiescence::Quiescent
        );
        world.teardown().await.expect("teardown");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_staged_commit_the_rig_has_not_resolved_withholds_quiescence() {
        let mut world = build_world().await;
        let staged = world.note_pending_staged();
        assert_eq!(
            quiescent(&world).await.expect("predicate reads"),
            Quiescence::Pending(PendingReason::StagedCommit),
            "Rule 13's own state: no engine counter and no fingerprint can see it"
        );
        let settled = settle(&mut world, Recovery::Undisturbed, Duration::from_millis(5))
            .await
            .expect("settle reads");
        assert_eq!(settled, Settled::TimedOut(PendingReason::StagedCommit));
        drop(staged);

        assert_eq!(
            quiescent(&world).await.expect("predicate reads"),
            Quiescence::Quiescent
        );
        world.teardown().await.expect("teardown");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_world_whose_every_device_is_paused_is_pending_not_quiescent() {
        let mut world = build_world().await;
        for device in world.devices_mut() {
            device.go_offline().await.expect("pause");
        }
        assert_eq!(
            quiescent(&world).await.expect("predicate reads"),
            Quiescence::Pending(PendingReason::NoOnlineDevice),
            "a world nobody is running is not a world that settled"
        );
        world.teardown().await.expect("teardown");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_paused_device_is_skipped_by_the_backlog_confirmation_not_failed_by_it() {
        let mut world = build_world().await;
        let bob = world.devices()[1].tag;
        world
            .device_mut(bob)
            .expect("bob")
            .go_offline()
            .await
            .expect("pause");
        assert!(
            confirm_backlog_settled(&world, &[bob])
                .await
                .expect("backlog reads")
                .is_empty(),
            "a closed burst window answers TimedOut by design; reporting it would \
             manufacture a failure"
        );
        world.teardown().await.expect("teardown");
    }
}
