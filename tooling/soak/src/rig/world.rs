//! The world: every device, every circle, every relay plane, and the schedule
//! that breaks them.
//!
//! The world is generic over its three environment planes so it compiles and is
//! testable on its own. Everything else about it is real: building one creates
//! genuine MLS groups over a genuine relay, and a tick applies genuine faults.

use std::fmt;
use std::sync::atomic::{AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use haven_core::circle::DecryptedIngest;
use haven_core::nostr::mls::storage::is_session_live;
use haven_core::nostr::mls::types::{ConvergedRoster, PendingStateRef};
use haven_core::relay::live_sync::processor::group_cursor_stream;
use haven_core::relay::live_sync::StopOutcome;
use nostr::Event;
use sha2::{Digest, Sha256};

use crate::clock::WallNow;
use crate::nemesis::types::{DeviceOp, Fault, Op, Schedule, ScheduledOp};
use crate::profiles::WorldShape;
use crate::rig::circle::{
    build_circle, publish_and_resolve, publish_witnessed, resolve_ingest, PublishVerdict,
};
use crate::rig::declare::DeclareSink;
use crate::rig::plane::{CapturedLine, LogDrain, RelayPlane, TimelineRecord, TimelineSink};
use crate::rig::{
    kill_and_reopen, poll_until, sim_magnitude, CircleTag, DeviceTag, RelayTag, RigError,
    SimCircle, SimDevice, Step, WorldId,
};

/// How long teardown waits for each device's session to be released.
const TEARDOWN_RELEASE_BOUND: Duration = Duration::from_secs(30);

/// How often teardown re-reads that condition.
const TEARDOWN_POLL: Duration = Duration::from_millis(20);

/// Installs the process-wide opt-ins the rig needs, exactly once.
///
/// `allow_ws_loopback_for_test` is install-once by design and returns an error
/// on a second call, so the verdict of the FIRST call is what every later
/// caller is told. An opt-in that never installed is rc 2: without it no device
/// can dial the world's own relay, and every liveness result would be a
/// fiction.
///
/// # Errors
///
/// [`RigError::LoopbackOptInRefused`] if the first install failed.
pub fn install_process_globals() -> Result<(), RigError> {
    static INSTALLED: OnceLock<bool> = OnceLock::new();
    if *INSTALLED.get_or_init(|| haven_core::relay::allow_ws_loopback_for_test().is_ok()) {
        Ok(())
    } else {
        Err(RigError::LoopbackOptInRefused)
    }
}

/// One staged-but-unresolved commit, counted while it is outstanding.
///
/// The rig is the world's only publisher, so it owns every `PendingStateRef`
/// there is — and a quiescence predicate that ignored them would call a world
/// settled while a commit was staged and unpublished, which is precisely the
/// state Rule 13 exists to make impossible.
#[derive(Debug)]
pub struct PendingGuard {
    outstanding: Arc<AtomicUsize>,
}

impl PendingGuard {
    /// Counts one staged commit against `outstanding` until this is dropped.
    ///
    /// `pub(crate)` because the world's own counter is private and a caller
    /// outside the rig has [`SimWorld::note_pending_staged`]; the create path
    /// needs this one because it stages its commit while the world is still
    /// being built.
    pub(crate) fn staged(outstanding: &Arc<AtomicUsize>) -> Self {
        outstanding.fetch_add(1, Ordering::AcqRel);
        Self {
            outstanding: Arc::clone(outstanding),
        }
    }
}

impl Drop for PendingGuard {
    fn drop(&mut self) {
        self.outstanding.fetch_sub(1, Ordering::Release);
    }
}

/// What one tick did.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct TickReport {
    /// The tick, counted from the world's origin.
    pub tick: u64,
    /// Ops applied.
    pub applied: usize,
    /// Faults healed.
    pub healed: usize,
    /// Bus events folded into device ledgers.
    pub delivered: usize,
    /// Whether the schedule asked for a probe round. The world surfaces the
    /// request; the scenario runs the probe, because only it knows which
    /// oracle it is satisfying.
    pub probe_requested: bool,
}

// Bucketed: how much a world did is a magnitude of its behaviour.
impl fmt::Debug for TickReport {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("TickReport")
            .field("tick", &self.tick)
            .field("applied", &sim_magnitude(self.applied))
            .field("healed", &sim_magnitude(self.healed))
            .field("delivered", &sim_magnitude(self.delivered))
            .field("probe_requested", &self.probe_requested)
            .finish()
    }
}

/// A circle's roster, reduced to something comparable but unreadable.
///
/// A roster is a list of pubkeys. The fingerprint needs to know whether it
/// changed, and nothing else — so it keeps a digest and renders none of it.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct RosterDigest([u8; 32]);

impl RosterDigest {
    /// Digests a roster verdict. The two non-roster verdicts get distinct
    /// constants: "the engine has no such group" and "a commit is in flight"
    /// are different states, and a fingerprint that folded them together would
    /// call a world stable across the transition.
    fn of(roster: &ConvergedRoster) -> Self {
        let mut hasher = Sha256::new();
        match roster {
            ConvergedRoster::Converged {
                member_pubkeys_hex,
                removed,
            } => {
                hasher.update([0_u8]);
                hasher.update([u8::from(*removed)]);
                let mut sorted: Vec<&String> = member_pubkeys_hex.iter().collect();
                sorted.sort();
                for pubkey in sorted {
                    hasher.update(pubkey.as_bytes());
                    hasher.update([0_u8]);
                }
            }
            ConvergedRoster::NotConverged => hasher.update([1_u8]),
            ConvergedRoster::Absent => hasher.update([2_u8]),
        }
        Self(hasher.finalize().into())
    }
}

// Presence-only: the digest is a stable join key for one exact roster.
impl fmt::Debug for RosterDigest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("RosterDigest(..)")
    }
}

/// One device's catch-up position in one circle, reduced.
///
/// The cursor and the backfill floor are the two terms a STORED-PAGE replay
/// moves and nothing else does: a page served out of a relay's store advances
/// the cursor without touching an epoch, a roster or a gating row, so a
/// fingerprint without them calls the world stable in the middle of one. They
/// are digested rather than kept, for the same reason a roster is — both are
/// absolute instants in milliseconds, and an instant is an identifier.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct ProgressDigest([u8; 32]);

impl ProgressDigest {
    /// Digests a circle's cursor and backfill floor. `None` and a value are
    /// distinct states: an unseeded cursor is not a cursor at zero.
    fn of(cursor_ms: Option<i64>, backfill_floor_secs: Option<i64>) -> Self {
        let mut hasher = Sha256::new();
        for term in [cursor_ms, backfill_floor_secs] {
            match term {
                Some(value) => {
                    hasher.update([1_u8]);
                    hasher.update(value.to_be_bytes());
                }
                None => hasher.update([0_u8]),
            }
        }
        Self(hasher.finalize().into())
    }
}

// Presence-only: the digest is a stable join key for one exact position.
impl fmt::Debug for ProgressDigest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("ProgressDigest(..)")
    }
}

/// One device's view of one circle.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct CircleFingerprint {
    /// Which circle.
    pub circle: CircleTag,
    /// Epochs advanced since the world's origin. A delta, never the epoch.
    pub epoch_delta: u64,
    /// Convergence inputs still gating the circle's sends.
    pub gating_rows: usize,
    /// The roster, reduced.
    pub roster: RosterDigest,
    /// The catch-up position — cursor and backfill floor — reduced.
    pub progress: ProgressDigest,
}

// Bucketed: the fields are compared exactly and RENDERED as magnitudes. An
// epoch delta is exact because a delta names no epoch.
impl fmt::Debug for CircleFingerprint {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CircleFingerprint")
            .field("circle", &self.circle)
            .field("epoch_delta", &self.epoch_delta)
            .field("gating_rows", &sim_magnitude(self.gating_rows))
            .field("roster", &self.roster)
            .field("progress", &self.progress)
            .finish()
    }
}

/// One device's whole state.
#[derive(Clone, PartialEq, Eq)]
pub struct DeviceFingerprint {
    /// Which device.
    pub device: DeviceTag,
    /// Whether its engine is paused.
    pub offline: bool,
    /// Live subscriptions, as the engine's own health probe sees them.
    pub subscriptions_live: usize,
    /// Publishes the engine has not finished.
    pub in_flight_publishes: usize,
    /// Everything its bus has delivered, of every kind. A replay that lands
    /// events changes nothing else the fingerprint holds until the engine has
    /// applied them, so without this a world mid-replay reads as stable.
    pub deliveries: u64,
    /// Its view of every circle, in circle order.
    pub circles: Vec<CircleFingerprint>,
}

// Bucketed for the same reason as `CircleFingerprint`.
impl fmt::Debug for DeviceFingerprint {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("DeviceFingerprint")
            .field("device", &self.device)
            .field("offline", &self.offline)
            .field(
                "subscriptions_live",
                &sim_magnitude(self.subscriptions_live),
            )
            .field(
                "in_flight_publishes",
                &sim_magnitude(self.in_flight_publishes),
            )
            .field(
                "deliveries",
                &sim_magnitude(usize::try_from(self.deliveries).unwrap_or(usize::MAX)),
            )
            .field("circles", &self.circles)
            .finish()
    }
}

/// The whole world, reduced to something a stability check can compare.
///
/// Deliberately NOT the full §3.6 term list: the engine-processor terms
/// (`commit_activity_count`, `all_advances_consumed`) need an accessor that
/// does not exist at this pin, so they are read by the quiescence predicate
/// directly rather than being half-represented here. Everything a stored-page
/// replay moves IS here — the cursor and the backfill floor through
/// [`ProgressDigest`], the bus through [`DeviceFingerprint::deliveries`] —
/// because a replay changes no epoch, no roster and no row, and a fingerprint
/// blind to it would call the world stable in the middle of one.
#[derive(Clone, PartialEq, Eq)]
pub struct WorldFingerprint {
    /// Every device, in device order.
    pub devices: Vec<DeviceFingerprint>,
    /// Staged commits the rig has not resolved.
    pub outstanding_pending_refs: usize,
}

// Bucketed for the same reason as `CircleFingerprint`.
impl fmt::Debug for WorldFingerprint {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("WorldFingerprint")
            .field("devices", &self.devices)
            .field(
                "outstanding_pending_refs",
                &sim_magnitude(self.outstanding_pending_refs),
            )
            .finish()
    }
}

/// A whole simulated world.
pub struct SimWorld<R: RelayPlane, T: TimelineSink, L: LogDrain> {
    id: WorldId,
    devices: Vec<SimDevice>,
    circles: Vec<SimCircle>,
    relays: Vec<R>,
    schedule: Schedule,
    timeline: T,
    logs: L,
    origin: WallNow,
    outstanding: Arc<AtomicUsize>,
    declarations: Option<Arc<dyn DeclareSink>>,
    next_extra_circle: AtomicU32,
    /// The last tick the world reached. The world's own clock, so a record
    /// written by something that is not a tick — an arm publishing between
    /// ticks — still says WHEN in the schedule it happened.
    tick: AtomicU64,
}

impl<R: RelayPlane, T: TimelineSink, L: LogDrain> SimWorld<R, T, L> {
    /// Builds a world: devices, then circles, then engines.
    ///
    /// The relay planes, timeline and log drain are supplied rather than
    /// constructed — they are the environment, and the world is generic over
    /// them.
    ///
    /// # Errors
    ///
    /// [`RigError::ShapeMismatch`] if the planes do not match `shape`,
    /// [`RigError::WelcomeNeverAcked`] if a create could not be confirmed under
    /// Rule 13, or [`RigError::Core`] naming the step that failed.
    pub async fn build(
        shape: &WorldShape,
        schedule: Schedule,
        relays: Vec<R>,
        timeline: T,
        logs: L,
    ) -> Result<Self, RigError> {
        install_process_globals()?;
        if relays.len() != shape.relays || shape.members < 2 || shape.circles == 0 {
            return Err(RigError::ShapeMismatch);
        }

        let urls: Vec<String> = relays.iter().map(|relay| relay.url().to_string()).collect();
        let mut devices = Vec::with_capacity(shape.members);
        for ordinal in 0..shape.members {
            let tag = DeviceTag::new(u32::try_from(ordinal).map_err(|_| RigError::ShapeMismatch)?);
            devices.push(SimDevice::open(tag, &urls)?);
        }

        // Minted before the first create rather than with the struct: a create
        // IS a staged commit, and the counter has to exist while one is
        // outstanding.
        let outstanding = Arc::new(AtomicUsize::new(0));
        let mut circles = Vec::with_capacity(shape.circles);
        for ordinal in 0..shape.circles {
            let tag = CircleTag::new(u32::try_from(ordinal).map_err(|_| RigError::ShapeMismatch)?);
            circles.push(build_circle(tag, &devices, &relays, &urls, &outstanding).await?);
        }

        let specs: Vec<_> = circles.iter().map(|circle| circle.spec(&urls)).collect();
        for device in &mut devices {
            device.start_engine(specs.clone()).await?;
        }

        // The schedule is the timeline's first records, so a run that dies in
        // its first tick still says what it was going to do.
        for scheduled in schedule.ops() {
            timeline.record(TimelineRecord::Scheduled {
                tick: scheduled.tick,
                op: scheduled.op,
                heal_at_tick: scheduled.heal_at,
            });
        }

        Ok(Self {
            id: WorldId::new(next_world_ordinal()),
            devices,
            circles,
            relays,
            schedule,
            timeline,
            logs,
            origin: WallNow::now(),
            outstanding,
            declarations: None,
            next_extra_circle: AtomicU32::new(
                u32::try_from(shape.circles).map_err(|_| RigError::ShapeMismatch)?,
            ),
            tick: AtomicU64::new(0),
        })
    }

    /// Attaches `sink` and declares everything this world already holds.
    ///
    /// One call rather than a free function over the world's tables, because
    /// the sink has to outlive it: a circle an ARM builds later
    /// ([`Self::build_extra_circle`]) is declared through the same seam, and a
    /// world whose extras went undeclared would hand the scan a manifest that
    /// cannot search for half of what the run minted.
    ///
    /// # Errors
    ///
    /// [`RigError::DeclarationRefused`] if a class will not take its value.
    pub fn declare_to(&mut self, sink: Arc<dyn DeclareSink>) -> Result<(), RigError> {
        for device in &self.devices {
            sink.declare_device(&device.secret_hex_for_declaration(), &device.pubkey_hex())?;
        }
        for circle in &self.circles {
            declare_one(sink.as_ref(), circle)?;
        }
        for relay in &self.relays {
            sink.declare_relay(relay.url())?;
        }
        self.declarations = Some(sink);
        Ok(())
    }

    /// Builds one more circle over this world's devices and relays, declares
    /// it, and hands it back.
    ///
    /// Deliberately NOT added to [`Self::circles`]. An arm that builds a
    /// further circle builds it to break it — S13 quarantines the one it
    /// creates — and a world-wide oracle grading a group the arm froze on
    /// purpose would report a violation the arm induced. The circle is still
    /// real, still joined by the same devices, and still declared.
    ///
    /// # Errors
    ///
    /// [`RigError::WelcomeNeverAcked`] if no welcome was acked (the create is
    /// rolled back first, which is what S18's create arm asserts), or
    /// [`RigError`] naming the step that failed.
    pub async fn build_extra_circle(&self) -> Result<SimCircle, RigError> {
        let ordinal = self.next_extra_circle.fetch_add(1, Ordering::AcqRel);
        let urls = self.relay_urls();
        let circle = build_circle(
            CircleTag::new(ordinal),
            &self.devices,
            &self.relays,
            &urls,
            &self.outstanding,
        )
        .await?;
        if let Some(sink) = &self.declarations {
            declare_one(sink.as_ref(), &circle)?;
        }
        Ok(circle)
    }

    /// Applies everything the schedule has for `tick`, then folds what the
    /// devices received.
    ///
    /// # Errors
    ///
    /// [`RigError`] naming the op that could not be applied. A fault that
    /// silently did not fire would make every bound derived from it a fiction,
    /// so nothing here is best-effort.
    pub async fn tick(&mut self, tick: u64) -> Result<TickReport, RigError> {
        self.tick.store(tick, Ordering::Release);
        let firing: Vec<ScheduledOp> = self.schedule.firing_at(tick).copied().collect();
        let healing: Vec<ScheduledOp> = self.schedule.healing_at(tick).copied().collect();

        let mut report = TickReport {
            tick,
            applied: 0,
            healed: 0,
            delivered: 0,
            probe_requested: false,
        };

        for scheduled in firing {
            match scheduled.op {
                Op::Fault { relay, fault } => {
                    self.apply_fault(relay, fault).await?;
                    if matches!(fault, Fault::Up | Fault::Heal) {
                        self.record_rebind(tick, relay);
                    }
                }
                Op::Device { device, op } => self.apply_device_op(tick, device, op).await?,
                Op::Probe => report.probe_requested = true,
            }
            self.timeline.record(TimelineRecord::Applied {
                tick,
                op: scheduled.op,
            });
            report.applied += 1;
        }

        for scheduled in healing {
            let Op::Fault { relay, .. } = scheduled.op else {
                // Only a fault can be healed; a schedule that asked to heal a
                // restart is a generator bug, and silently ignoring it would
                // leave a bound derived from a heal that never happened.
                return Err(RigError::Unhealable);
            };
            self.apply_fault(relay, Fault::Heal).await?;
            self.record_rebind(tick, relay);
            self.timeline.record(TimelineRecord::Healed {
                tick,
                op: scheduled.op,
            });
            report.healed += 1;
        }

        report.delivered = self.drain_buses();
        Ok(report)
    }

    /// Folds every device's waiting bus events into its ledger and returns how
    /// many were folded.
    ///
    /// A tick does this itself. It is public because a bounded wait for a
    /// delivery has to drain before it can see one.
    pub fn drain_buses(&mut self) -> usize {
        // Two disjoint fields, borrowed separately: a device's drain needs the
        // circle table to attribute a delivery.
        let circles = &self.circles;
        self.devices
            .iter_mut()
            .map(|device| device.drain_bus(circles))
            .sum()
    }

    async fn apply_fault(&mut self, relay: RelayTag, fault: Fault) -> Result<(), RigError> {
        self.relays
            .iter_mut()
            .find(|plane| plane.tag() == relay)
            .ok_or(RigError::UnknownTarget)?
            .apply(fault)
            .await
    }

    /// Records the rebind cost of a plane that just came back, when the plane
    /// measures one. Attempts are bucketed (a count of the rig's own retries,
    /// bucketed anyway so the timeline carries one magnitude vocabulary).
    fn record_rebind(&self, tick: u64, relay: RelayTag) {
        let Some((attempts, wait)) = self
            .relays
            .iter()
            .find(|plane| plane.tag() == relay)
            .and_then(RelayPlane::last_rebind)
        else {
            return;
        };
        let wait_ms = u64::try_from(wait.as_millis()).unwrap_or(u64::MAX);
        self.timeline.record(TimelineRecord::Rebound {
            tick,
            relay,
            attempts: sim_magnitude(attempts as usize),
            wait_ms,
        });
    }

    async fn apply_device_op(
        &mut self,
        tick: u64,
        device: DeviceTag,
        op: DeviceOp,
    ) -> Result<(), RigError> {
        let index = self
            .devices
            .iter()
            .position(|candidate| candidate.tag == device)
            .ok_or(RigError::UnknownTarget)?;
        match op {
            DeviceOp::Restart(kind) => {
                let report = kill_and_reopen(&mut self.devices[index], kind).await?;
                self.timeline.record(TimelineRecord::Restarted {
                    tick,
                    device,
                    kind,
                    release_ms: millis(report.release),
                    reopen_ms: millis(report.reopen),
                });
            }
            DeviceOp::GoOffline => self.devices[index].go_offline().await?,
            DeviceOp::ComeOnline => self.devices[index].come_online().await?,
            DeviceOp::StepPolicyOffset { secs } => self.devices[index].step_policy_offset(secs),
        }
        Ok(())
    }

    /// Publishes `events` from `device` and waits, bounded, for a relay plane
    /// to witness an `OK`.
    ///
    /// # Errors
    ///
    /// [`RigError`] if the witness condition could not be read.
    pub async fn publish_witnessed(
        &self,
        device: DeviceTag,
        events: &[Event],
    ) -> Result<Option<Duration>, RigError> {
        publish_witnessed(self.device(device)?, &self.relays, events).await
    }

    /// The crate's Rule-13 resolution: publish, then confirm on a witnessed ack
    /// or roll back without one — and drain whatever that resolution's own
    /// replay handed back, through the same rung.
    ///
    /// # Errors
    ///
    /// [`RigError::Core`] if haven-core refuses the confirm or the rollback.
    pub async fn publish_and_confirm(
        &self,
        device: DeviceTag,
        pending: PendingStateRef,
        events: &[Event],
    ) -> Result<PublishVerdict, RigError> {
        let guard = self.note_pending_staged();
        let (verdict, latency) =
            publish_and_resolve(self.device(device)?, &self.relays, pending, events).await?;
        drop(guard);
        self.timeline.record(TimelineRecord::Published {
            tick: self.current_tick(),
            device,
            outcome: verdict.label(),
            witness_ms: latency.map(millis),
            events: sim_magnitude(events.len()),
        });
        Ok(verdict)
    }

    /// [`crate::rig::circle::resolve_ingest`] against this world's relay planes.
    ///
    /// The callers that resolve a pending ref through haven-core DIRECTLY —
    /// because they need a step `publish_and_confirm` does not have, such as the
    /// relay-update finalize — still owe the batch a disposition, and this is
    /// the one they owe it to.
    ///
    /// # Errors
    ///
    /// [`RigError::Core`] if a rung of the ladder is refused.
    pub async fn resolve_ingest(
        &self,
        device: DeviceTag,
        ingest: DecryptedIngest,
    ) -> Result<(), RigError> {
        let guard = self.note_pending_staged();
        let outcome = resolve_ingest(self.device(device)?, &self.relays, ingest).await;
        drop(guard);
        outcome
    }

    /// The last tick this world reached.
    #[must_use]
    pub fn current_tick(&self) -> u64 {
        self.tick.load(Ordering::Acquire)
    }

    /// Counts one staged commit until the returned guard is dropped.
    ///
    /// [`Self::publish_and_confirm`] does this itself. A caller resolving a
    /// pending by another route (a relay update finalises through its own
    /// call) must hold one of these, or the world will call itself quiescent
    /// with a commit staged.
    #[must_use]
    pub fn note_pending_staged(&self) -> PendingGuard {
        PendingGuard::staged(&self.outstanding)
    }

    /// Staged commits the rig has not resolved.
    #[must_use]
    pub fn outstanding_pending_refs(&self) -> usize {
        self.outstanding.load(Ordering::Acquire)
    }

    /// Everything comparable about the world right now.
    ///
    /// # Errors
    ///
    /// [`RigError::Core`] naming the read that failed.
    pub async fn fingerprint(&self) -> Result<WorldFingerprint, RigError> {
        let mut devices = Vec::with_capacity(self.devices.len());
        for device in &self.devices {
            let manager = device.manager()?;
            let mut circles = Vec::with_capacity(self.circles.len());
            for circle in &self.circles {
                let epoch = manager
                    .group_epoch(circle.mls_group_id())
                    .await
                    .map_err(|_| RigError::Core(Step::ReadEpoch))?;
                let roster = device
                    .session()?
                    .converged_member_pubkeys(circle.mls_group_id())
                    .await
                    .map_err(|_| RigError::Core(Step::ReadRoster))?;
                let gating_rows = device
                    .session()?
                    .gating_input_count(circle.mls_group_id())
                    .await
                    .map_err(|_| RigError::Core(Step::ReadGatingRows))?;
                // The engine's own stream key, so the two reads are of the rows
                // the processor writes rather than of a key nothing is stored
                // under.
                let stream = group_cursor_stream(circle.group_id_hex());
                let cursor_ms = manager
                    .read_sync_cursor(&stream)
                    .map_err(|_| RigError::Core(Step::ReadCursor))?;
                let backfill_floor = manager
                    .read_backfill_floor(&stream)
                    .map_err(|_| RigError::Core(Step::ReadCursor))?;
                circles.push(CircleFingerprint {
                    circle: circle.tag,
                    epoch_delta: epoch.saturating_sub(circle.origin_epoch()),
                    gating_rows,
                    roster: RosterDigest::of(&roster),
                    progress: ProgressDigest::of(cursor_ms, backfill_floor),
                });
            }
            let health = device.engine()?.relay_health().await;
            devices.push(DeviceFingerprint {
                device: device.tag,
                offline: device.offline,
                subscriptions_live: health.subscriptions_live,
                in_flight_publishes: device.engine()?.in_flight_publishes(),
                deliveries: device.ledger().total(),
                circles,
            });
        }
        Ok(WorldFingerprint {
            devices,
            outstanding_pending_refs: self.outstanding_pending_refs(),
        })
    }

    /// Stops every engine, drops every handle, and waits — bounded — for every
    /// session to be released.
    ///
    /// # Errors
    ///
    /// [`RigError::StopTimedOut`] or [`RigError::SessionStillLive`]: a world
    /// that cannot be torn down has leaked a handle, and the next world over
    /// the same store would be a Rule-14 violation.
    pub async fn teardown(mut self) -> Result<(), RigError> {
        for device in &mut self.devices {
            if let Some(core) = device.take_engine() {
                let outcome = core.stop().await;
                drop(core);
                if outcome == StopOutcome::TimedOut {
                    return Err(RigError::StopTimedOut);
                }
            }
            drop(device.take_manager());
        }
        for device in &self.devices {
            let db = device.session_db_path();
            poll_until(TEARDOWN_RELEASE_BOUND, TEARDOWN_POLL, || async {
                is_session_live(&db)
                    .map(|live| !live)
                    .map_err(|_| RigError::Core(Step::ReadSessionLiveness))
            })
            .await?
            .ok_or(RigError::SessionStillLive)?;
        }
        Ok(())
    }

    /// Captured lines from THIS world since sequence `from`.
    ///
    /// The filter is the world's, not the drain's: `cargo test` runs worlds
    /// concurrently in one process, and a scenario graded on another
    /// scenario's lines is worse than one graded on none.
    #[must_use]
    pub fn drain_logs(&self, from: u64) -> Vec<CapturedLine> {
        self.logs
            .drain_since(from)
            .into_iter()
            .filter(|line| line.world == self.id)
            .collect()
    }

    /// This world's handle.
    #[must_use]
    pub const fn id(&self) -> WorldId {
        self.id
    }

    /// When the world was built. Only ever rendered as an offset.
    #[must_use]
    pub const fn origin(&self) -> WallNow {
        self.origin
    }

    /// Every device.
    #[must_use]
    pub fn devices(&self) -> &[SimDevice] {
        &self.devices
    }

    /// Every device, mutably.
    pub fn devices_mut(&mut self) -> &mut [SimDevice] {
        &mut self.devices
    }

    /// One device.
    ///
    /// # Errors
    ///
    /// [`RigError::UnknownTarget`] if the world has no such device.
    pub fn device(&self, tag: DeviceTag) -> Result<&SimDevice, RigError> {
        self.devices
            .iter()
            .find(|device| device.tag == tag)
            .ok_or(RigError::UnknownTarget)
    }

    /// One device, mutably.
    ///
    /// # Errors
    ///
    /// [`RigError::UnknownTarget`] if the world has no such device.
    pub fn device_mut(&mut self, tag: DeviceTag) -> Result<&mut SimDevice, RigError> {
        self.devices
            .iter_mut()
            .find(|device| device.tag == tag)
            .ok_or(RigError::UnknownTarget)
    }

    /// Every circle.
    #[must_use]
    pub fn circles(&self) -> &[SimCircle] {
        &self.circles
    }

    /// One circle.
    ///
    /// # Errors
    ///
    /// [`RigError::UnknownTarget`] if the world has no such circle.
    pub fn circle(&self, tag: CircleTag) -> Result<&SimCircle, RigError> {
        self.circles
            .iter()
            .find(|circle| circle.tag == tag)
            .ok_or(RigError::UnknownTarget)
    }

    /// Every relay plane.
    #[must_use]
    pub fn relays(&self) -> &[R] {
        &self.relays
    }

    /// Every relay plane, mutably.
    pub fn relays_mut(&mut self) -> &mut [R] {
        &mut self.relays
    }

    /// The relay URLs devices dial. Never rendered.
    #[must_use]
    pub fn relay_urls(&self) -> Vec<String> {
        self.relays
            .iter()
            .map(|relay| relay.url().to_string())
            .collect()
    }

    /// The schedule this world is running.
    #[must_use]
    pub const fn schedule(&self) -> &Schedule {
        &self.schedule
    }

    /// The timeline this world records to.
    #[must_use]
    pub const fn timeline(&self) -> &T {
        &self.timeline
    }
}

/// Declares one circle's two ids and its name.
fn declare_one(sink: &dyn DeclareSink, circle: &SimCircle) -> Result<(), RigError> {
    sink.declare_circle(
        &hex::encode(circle.mls_group_id().as_slice()),
        circle.group_id_hex(),
        circle.name(),
    )
}

/// Milliseconds, saturating: a duration is a measurement, and a measurement
/// that overflowed its rendering is better clamped than wrapped.
fn millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

/// The next world ordinal for this process.
fn next_world_ordinal() -> u64 {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    NEXT.fetch_add(1, Ordering::Relaxed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nemesis::types::{DeviceOp, ScheduledOp};
    use crate::rig::doubles::{RecordingTimeline, StubDrain, TestRelay};
    use crate::rig::plane::CapturedLine;
    use crate::rig::KillKind;
    use haven_core::location::LocationMessage;
    use tokio::time::{Instant, MissedTickBehavior};

    type TestWorld = SimWorld<TestRelay, RecordingTimeline, StubDrain>;

    /// Two devices, one circle, one relay: the smallest world in which a peer
    /// can receive what another peer sent, which is the smallest world that
    /// proves anything.
    const fn smallest_shape() -> WorldShape {
        WorldShape {
            members: 2,
            circles: 1,
            relays: 1,
        }
    }

    async fn build_world(schedule: Schedule) -> TestWorld {
        let relay = TestRelay::start(RelayTag::new(0)).await;
        SimWorld::build(
            &smallest_shape(),
            schedule,
            vec![relay],
            RecordingTimeline::default(),
            StubDrain::default(),
        )
        .await
        .unwrap_or_else(|failure| panic!("world builds: {failure}"))
    }

    /// How long one location may take to reach a peer over a fresh world:
    /// the subscribe ladder plus an undisturbed round trip, from the bounds
    /// table rather than a number the test remembers.
    fn one_delivery_bound() -> Duration {
        crate::oracle::bounds::subscribe_ladder()
            + crate::oracle::bounds::round_trip(crate::oracle::Recovery::Undisturbed)
    }

    /// A bounded wait that needs `&mut world`, which `poll_until` cannot
    /// express: a future returned from an `FnMut` closure cannot hold a
    /// mutable borrow of the closure's environment.
    async fn drain_until(
        world: &mut TestWorld,
        bound: Duration,
        mut satisfied: impl FnMut(&TestWorld) -> bool,
    ) -> bool {
        let started = Instant::now();
        let mut ticker = tokio::time::interval(Duration::from_millis(20));
        ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
        loop {
            world.drain_buses();
            if satisfied(world) {
                return true;
            }
            if started.elapsed() >= bound {
                return false;
            }
            ticker.tick().await;
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_built_world_carries_a_peers_location_over_its_own_relay() {
        let mut world = build_world(Schedule::new(Vec::new())).await;
        let alice = DeviceTag::new(0);
        let bob = DeviceTag::new(1);
        let circle_tag = world.circles()[0].tag;
        let group = world.circles()[0].mls_group_id().clone();

        // A world whose two members disagree about the epoch or the roster is
        // not a world; it is two devices that both happen to exist.
        let built = world.fingerprint().await.expect("fingerprint");
        assert_eq!(
            built.devices[0].circles[0].epoch_delta,
            built.devices[1].circles[0].epoch_delta
        );
        assert_eq!(
            built.devices[0].circles[0].roster,
            built.devices[1].circles[0].roster
        );
        assert_eq!(built.devices[0].circles[0].gating_rows, 0);
        assert_eq!(built.outstanding_pending_refs, 0);

        let sender = world.device(alice).expect("alice");
        let (event, _, _) = sender
            .manager()
            .expect("manager")
            .encrypt_location(
                &group,
                &sender.keys.public_key(),
                &LocationMessage::new(40.12, -74.34),
                300,
            )
            .await
            .expect("alice encrypts a location");

        assert!(
            world
                .publish_witnessed(alice, std::slice::from_ref(&event))
                .await
                .expect("witness reads")
                .is_some(),
            "the relay acknowledged the location to its publisher"
        );

        assert!(
            drain_until(&mut world, one_delivery_bound(), |world| {
                world
                    .device(bob)
                    .is_ok_and(|device| device.ledger().locations() >= 1)
            })
            .await,
            "bob's engine never delivered alice's location"
        );
        let bobs = world.device(bob).expect("bob");
        assert_eq!(bobs.ledger().deliveries_for(circle_tag), 1);
        assert_eq!(
            bobs.ledger().lagged(),
            0,
            "a lagged bus means the ledger under-counts and cannot be graded on"
        );

        world
            .teardown()
            .await
            .expect("teardown releases every session");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_delivery_moves_the_fingerprint_even_though_no_epoch_or_roster_did() {
        // The stored-page shape, at its smallest: one event crosses, the
        // engines apply it, and nothing about the GROUP changes. A fingerprint
        // that only watched epochs, rosters and gating rows would call this
        // world unchanged across the whole replay and let a stability window
        // declare it settled in the middle of one.
        let mut world = build_world(Schedule::new(Vec::new())).await;
        let alice = DeviceTag::new(0);
        let bob = DeviceTag::new(1);
        let group = world.circles()[0].mls_group_id().clone();
        let before = world.fingerprint().await.expect("fingerprint");

        let sender = world.device(alice).expect("alice");
        let (event, _, _) = sender
            .manager()
            .expect("manager")
            .encrypt_location(
                &group,
                &sender.keys.public_key(),
                &LocationMessage::new(51.5, -0.12),
                300,
            )
            .await
            .expect("alice encrypts a location");
        world
            .publish_witnessed(alice, std::slice::from_ref(&event))
            .await
            .expect("witness reads");
        assert!(
            drain_until(&mut world, one_delivery_bound(), |world| {
                world
                    .device(bob)
                    .is_ok_and(|device| device.ledger().locations() >= 1)
            })
            .await,
            "bob's engine never delivered alice's location"
        );

        let after = world.fingerprint().await.expect("fingerprint");
        assert_eq!(
            before.devices[1].circles[0].epoch_delta, after.devices[1].circles[0].epoch_delta,
            "an application message advances no epoch, which is what makes this test the case \
             it is about"
        );
        assert_eq!(
            before.devices[1].circles[0].roster, after.devices[1].circles[0].roster,
            "and it changes no roster"
        );
        assert_ne!(
            before.devices[1], after.devices[1],
            "the receiving device's fingerprint did not move for a delivery it applied"
        );
        assert_ne!(before, after, "and neither did the world's");

        world.teardown().await.expect("teardown");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_create_whose_welcome_is_never_acked_is_rolled_back_not_confirmed() {
        let relay = TestRelay::start_swallowing_acks(RelayTag::new(0)).await;
        let outcome = SimWorld::build(
            &smallest_shape(),
            Schedule::new(Vec::new()),
            vec![relay],
            RecordingTimeline::default(),
            StubDrain::default(),
        )
        .await;

        assert!(
            matches!(outcome, Err(RigError::WelcomeNeverAcked)),
            "a create confirmed without a witnessed ack would merge an unpublished commit"
        );
        assert_eq!(RigError::WelcomeNeverAcked.rc(), crate::rc::Rc::Unusable);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_tick_applies_a_fault_heals_it_and_records_both() {
        let schedule = Schedule::new(vec![
            ScheduledOp {
                tick: 1,
                op: Op::Fault {
                    relay: RelayTag::new(0),
                    fault: Fault::SwallowOk,
                },
                heal_at: Some(2),
            },
            ScheduledOp {
                tick: 3,
                op: Op::Probe,
                heal_at: None,
            },
        ]);
        let mut world = build_world(schedule).await;

        let first = world.tick(1).await.expect("tick 1");
        assert_eq!(first.applied, 1);
        assert_eq!(first.healed, 0);
        assert!(!first.probe_requested);
        assert_eq!(world.relays()[0].applied(), vec![Fault::SwallowOk]);

        let second = world.tick(2).await.expect("tick 2");
        assert_eq!(second.applied, 0);
        assert_eq!(second.healed, 1);
        assert_eq!(
            world.relays()[0].applied(),
            vec![Fault::SwallowOk, Fault::Heal]
        );

        let third = world.tick(3).await.expect("tick 3");
        assert!(
            third.probe_requested,
            "the world surfaces the probe; the scenario runs it"
        );

        let records = world.timeline().records();
        assert!(
            records
                .iter()
                .filter(|record| matches!(record, TimelineRecord::Scheduled { .. }))
                .count()
                == 2,
            "the materialised schedule is the timeline's first records"
        );
        assert!(records
            .iter()
            .any(|record| matches!(record, TimelineRecord::Applied { .. })));
        assert!(records
            .iter()
            .any(|record| matches!(record, TimelineRecord::Healed { .. })));

        world.teardown().await.expect("teardown");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_published_record_carries_the_worlds_tick_and_only_a_witness_it_measured() {
        let mut world = build_world(Schedule::new(Vec::new())).await;
        let alice = DeviceTag::new(0);
        let group = world.circles()[0].mls_group_id().clone();

        world.tick(5).await.expect("tick 5");
        let mut widened = world.relay_urls();
        widened.push("wss://second.example.com".to_owned());
        let staged = world
            .device(alice)
            .expect("alice")
            .manager()
            .expect("manager")
            .update_circle_relays(&group, &widened)
            .await
            .expect("alice stages a relay update");
        assert_eq!(
            world
                .publish_and_confirm(alice, staged.pending, &[staged.commit_event])
                .await
                .expect("the publish resolves"),
            PublishVerdict::Confirmed
        );

        // The plane keeps the event and withholds the acknowledgement, which
        // Rule 13 says is not an ack — so this one rolls back with no witness
        // latency to report.
        world.relays_mut()[0]
            .apply(Fault::SwallowOk)
            .await
            .expect("the fault applies");
        world.tick(7).await.expect("tick 7");
        widened.push("wss://third.example.com".to_owned());
        let withheld = world
            .device(alice)
            .expect("alice")
            .manager()
            .expect("manager")
            .update_circle_relays(&group, &widened)
            .await
            .expect("alice stages a second relay update");
        assert_eq!(
            world
                .publish_and_confirm(alice, withheld.pending, &[withheld.commit_event])
                .await
                .expect("the publish resolves"),
            PublishVerdict::RolledBack
        );

        let published: Vec<(u64, Option<u64>)> = world
            .timeline()
            .records()
            .into_iter()
            .filter_map(|record| match record {
                TimelineRecord::Published {
                    tick, witness_ms, ..
                } => Some((tick, witness_ms)),
                _ => None,
            })
            .collect();
        assert_eq!(
            published.iter().map(|(tick, _)| *tick).collect::<Vec<_>>(),
            vec![5, 7],
            "a publish is recorded at the tick the world was at, not at zero"
        );
        assert!(
            published[0].1.is_some(),
            "a confirmed publish measured how long the ack took to be witnessed"
        );
        assert!(
            published[1].1.is_none(),
            "a rolled-back publish has no witness latency, and the bound it waited is a \
             constant this crate chose rather than something the world took"
        );
        let json = serde_json::to_string(&TimelineRecord::Published {
            tick: 7,
            device: alice,
            outcome: PublishVerdict::RolledBack.label(),
            witness_ms: None,
            events: sim_magnitude(1),
        })
        .expect("a record serialises");
        assert!(
            !json.contains("witness_ms"),
            "an absent measurement is absent, never a zero somebody reads as one: {json}"
        );

        world.teardown().await.expect("teardown");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_heal_scheduled_against_something_that_is_not_a_fault_is_refused() {
        let schedule = Schedule::new(vec![ScheduledOp {
            tick: 1,
            op: Op::Device {
                device: DeviceTag::new(1),
                op: DeviceOp::GoOffline,
            },
            heal_at: Some(1),
        }]);
        let mut world = build_world(schedule).await;
        assert_eq!(world.tick(1).await, Err(RigError::Unhealable));
        world.teardown().await.expect("teardown");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_scheduled_op_against_an_absent_target_is_refused() {
        let schedule = Schedule::new(vec![ScheduledOp {
            tick: 1,
            op: Op::Fault {
                relay: RelayTag::new(9),
                fault: Fault::SwallowOk,
            },
            heal_at: None,
        }]);
        let mut world = build_world(schedule).await;
        assert_eq!(world.tick(1).await, Err(RigError::UnknownTarget));
        world.teardown().await.expect("teardown");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_scheduled_restart_keeps_the_circle_and_records_its_latencies() {
        let bob = DeviceTag::new(1);
        let schedule = Schedule::new(vec![
            ScheduledOp {
                tick: 1,
                op: Op::Device {
                    device: bob,
                    op: DeviceOp::Restart(KillKind::Soft),
                },
                heal_at: None,
            },
            ScheduledOp {
                tick: 2,
                op: Op::Device {
                    device: bob,
                    op: DeviceOp::StepPolicyOffset { secs: 288 },
                },
                heal_at: None,
            },
        ]);
        let mut world = build_world(schedule).await;
        let before = world.fingerprint().await.expect("fingerprint");

        world.tick(1).await.expect("tick 1");

        // The store survived: same epoch, same roster, same gating rows, read
        // back through a manager that was dropped and reopened. The catch-up
        // POSITION is deliberately not in this comparison — a restart
        // re-anchors, so a moved cursor is the restart working rather than the
        // store failing.
        let after = world.fingerprint().await.expect("fingerprint");
        let (was, now) = (&before.devices[1].circles[0], &after.devices[1].circles[0]);
        assert_eq!(was.epoch_delta, now.epoch_delta);
        assert_eq!(was.roster, now.roster);
        assert_eq!(was.gating_rows, now.gating_rows);
        assert!(world.device(bob).expect("bob").engine().is_ok());

        world.tick(2).await.expect("tick 2");
        assert_eq!(world.device(bob).expect("bob").policy_offset_secs, 288);

        let restarted = world
            .timeline()
            .records()
            .into_iter()
            .find_map(|record| match record {
                TimelineRecord::Restarted {
                    device, release_ms, ..
                } if device == bob => Some(release_ms),
                _ => None,
            });
        assert!(
            restarted.is_some(),
            "a restart's release latency is the Rule-14 measurement and must be recorded"
        );

        world.teardown().await.expect("teardown");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_paused_device_reports_itself_offline_and_resumes() {
        let bob = DeviceTag::new(1);
        let schedule = Schedule::new(vec![
            ScheduledOp {
                tick: 1,
                op: Op::Device {
                    device: bob,
                    op: DeviceOp::GoOffline,
                },
                heal_at: None,
            },
            ScheduledOp {
                tick: 2,
                op: Op::Device {
                    device: bob,
                    op: DeviceOp::ComeOnline,
                },
                heal_at: None,
            },
        ]);
        let mut world = build_world(schedule).await;

        world.tick(1).await.expect("tick 1");
        assert!(world.device(bob).expect("bob").offline);
        assert!(world
            .device(bob)
            .expect("bob")
            .engine()
            .expect("engine")
            .is_paused());
        assert!(world.fingerprint().await.expect("fingerprint").devices[1].offline);

        world.tick(2).await.expect("tick 2");
        assert!(!world.device(bob).expect("bob").offline);
        assert!(!world
            .device(bob)
            .expect("bob")
            .engine()
            .expect("engine")
            .is_paused());

        world.teardown().await.expect("teardown");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_world_reads_only_its_own_captured_lines() {
        let relay = TestRelay::start(RelayTag::new(0)).await;
        let drain = StubDrain::default();
        // The same drain, kept on this side of the move: the lines are planted
        // AFTER the world exists, so both ids are known and neither assertion
        // can pass by matching nothing.
        let planter = drain.clone();
        let world = SimWorld::build(
            &smallest_shape(),
            Schedule::new(Vec::new()),
            vec![relay],
            RecordingTimeline::default(),
            drain,
        )
        .await
        .unwrap_or_else(|failure| panic!("world builds: {failure}"));

        planter.push(CapturedLine {
            seq: 1,
            world: world.id(),
            level: log::Level::Info,
            target: "haven_core".to_string(),
            text: "this world's".to_string(),
        });
        planter.push(CapturedLine {
            seq: 2,
            world: WorldId::new(world.id().ordinal().wrapping_add(1_000)),
            level: log::Level::Info,
            target: "haven_core".to_string(),
            text: "another world's".to_string(),
        });

        let lines = world.drain_logs(0);
        assert_eq!(
            lines.len(),
            1,
            "a scenario graded on another world's lines is worse than one graded on none"
        );
        assert_eq!(lines[0].world, world.id());
        assert_eq!(lines[0].text, "this world's");
        assert!(
            world.drain_logs(2).is_empty(),
            "the sequence cursor is honoured"
        );

        world.teardown().await.expect("teardown");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn an_outstanding_pending_ref_is_counted_until_it_is_resolved() {
        let world = build_world(Schedule::new(Vec::new())).await;
        assert_eq!(world.outstanding_pending_refs(), 0);
        {
            let _staged = world.note_pending_staged();
            assert_eq!(
                world.outstanding_pending_refs(),
                1,
                "a staged commit the rig has not resolved is exactly what quiescence must not ignore"
            );
        }
        assert_eq!(world.outstanding_pending_refs(), 0);
        world.teardown().await.expect("teardown");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_world_shape_the_planes_do_not_match_is_refused() {
        let relay = TestRelay::start(RelayTag::new(0)).await;
        let outcome = SimWorld::build(
            &WorldShape {
                members: 2,
                circles: 1,
                relays: 2,
            },
            Schedule::new(Vec::new()),
            vec![relay],
            RecordingTimeline::default(),
            StubDrain::default(),
        )
        .await;
        assert!(matches!(outcome, Err(RigError::ShapeMismatch)));
    }

    #[test]
    fn the_process_opt_in_installs_once_and_reports_the_first_verdict() {
        install_process_globals().expect("the loopback opt-in installs");
        install_process_globals().expect("a second caller is told the first verdict");
    }

    #[test]
    fn a_roster_digest_separates_the_three_verdicts_and_renders_none_of_them() {
        let converged = RosterDigest::of(&ConvergedRoster::Converged {
            member_pubkeys_hex: vec!["aa".repeat(32), "bb".repeat(32)],
            removed: false,
        });
        let reordered = RosterDigest::of(&ConvergedRoster::Converged {
            member_pubkeys_hex: vec!["bb".repeat(32), "aa".repeat(32)],
            removed: false,
        });
        let removed = RosterDigest::of(&ConvergedRoster::Converged {
            member_pubkeys_hex: vec!["aa".repeat(32), "bb".repeat(32)],
            removed: true,
        });
        assert_eq!(converged, reordered, "roster order is not roster identity");
        assert_ne!(converged, removed);
        assert_ne!(
            RosterDigest::of(&ConvergedRoster::NotConverged),
            RosterDigest::of(&ConvergedRoster::Absent),
            "an in-flight commit and an absent group are different states"
        );

        let rendered = format!("{converged:?}");
        assert!(rendered.contains("RosterDigest"), "{rendered}");
        assert!(!rendered.contains("aa"), "{rendered}");
    }

    #[test]
    fn a_fingerprint_renders_magnitudes_as_buckets_and_epochs_as_deltas() {
        let fingerprint = WorldFingerprint {
            devices: vec![DeviceFingerprint {
                device: DeviceTag::new(0),
                offline: false,
                subscriptions_live: 7,
                in_flight_publishes: 3,
                deliveries: 11,
                circles: vec![CircleFingerprint {
                    circle: CircleTag::new(0),
                    epoch_delta: 2,
                    gating_rows: 9,
                    roster: RosterDigest::of(&ConvergedRoster::Absent),
                    progress: ProgressDigest::of(Some(1_764_500_000_000), Some(1_764_499_000)),
                }],
            }],
            outstanding_pending_refs: 6,
        };
        let rendered = format!("{fingerprint:?}");
        assert!(rendered.contains("simdev#0"), "{rendered}");
        assert!(
            rendered.contains("epoch_delta: 2"),
            "a delta names no epoch"
        );
        assert!(!rendered.contains(": 7"), "{rendered}");
        assert!(!rendered.contains(": 9"), "{rendered}");
        assert!(!rendered.contains(": 6"), "{rendered}");
        assert!(!rendered.contains(": 11"), "{rendered}");
        assert!(rendered.contains("5+"), "{rendered}");
        assert!(
            !rendered.contains("1764"),
            "a cursor is an absolute instant: {rendered}"
        );
    }

    #[test]
    fn a_progress_digest_separates_every_position_and_renders_none_of_them() {
        let seeded = ProgressDigest::of(Some(1_764_500_000_000), None);
        assert_ne!(
            seeded,
            ProgressDigest::of(Some(1_764_500_000_001), None),
            "a cursor that moved by one millisecond is a world that moved"
        );
        assert_ne!(
            seeded,
            ProgressDigest::of(Some(1_764_500_000_000), Some(0)),
            "a backfill floor the chase persisted is a world that moved"
        );
        assert_ne!(
            ProgressDigest::of(None, None),
            ProgressDigest::of(Some(0), None),
            "an unseeded cursor is not a cursor at zero"
        );
        let rendered = format!("{seeded:?}");
        assert!(rendered.contains("ProgressDigest"), "{rendered}");
        assert!(!rendered.contains("1764"), "{rendered}");
    }

    #[test]
    fn a_tick_report_buckets_what_the_world_did() {
        let rendered = format!(
            "{:?}",
            TickReport {
                tick: 7,
                applied: 3,
                healed: 1,
                delivered: 9,
                probe_requested: true,
            }
        );
        assert!(rendered.contains("2-4"), "{rendered}");
        assert!(rendered.contains("5+"), "{rendered}");
        assert!(!rendered.contains(" 9"), "{rendered}");
        assert!(
            rendered.contains("tick: 7"),
            "a tick is a delta, not an instant"
        );
    }
}
