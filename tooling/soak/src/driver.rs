//! The run driver: everything between a resolved plan and a folded verdict.
//!
//! In the library rather than in `main.rs` so a run is drivable by something
//! other than a command line. The rc-1 evidence contract — a marker file per
//! verdict, a first-violation snapshot beside the timeline — is a promise about
//! what a run LEAVES BEHIND, and the only way to test a promise like that is to
//! drive a real run with a real defect in it and look.
//!
//! # What a plan is
//!
//! [`RunPlan`] carries an already-materialised [`Schedule`] rather than a seed
//! to mint one from. Minting is the CLI's job (profile + seed), and taking the
//! schedule as a value is what lets a test hand the driver one fault it chose
//! instead of one a seed happened to draw — with no test-only branch anywhere
//! in this file.
//!
//! # Rule 15
//!
//! Every line this module prints is a classification, a rig handle, a bucket, a
//! duration, or one of the scanner's own `capture:line` locators — a capture
//! name this crate chose and an offset inside a file nobody may upload. It
//! prints no path, no magnitude of the world's behaviour and no endpoint,
//! because a lane redirects this stream into the tree it uploads.
//!
//! # A leak ends the run
//!
//! A capture that carried a declared value is deleted where it is found, and
//! the run stops there rather than going on to build more worlds: every later
//! world would mint more values into a manifest the run has already had to
//! contain, and every later capture would be written beside evidence nobody can
//! re-read. The verdict is still folded and the markers are still written — a
//! stop is not a silent exit.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use haven_logscan::manifest::{Manifest, MANIFEST_SUFFIX};

use crate::banner::{Banner, Measured, Provenance};
use crate::logsink::{self, Needles, SinkError, SoakLogs};
use crate::nemesis::types::{Op, Schedule, ScheduledOp};
use crate::oracle::{bounds, vacuity, Invariant, Reach, Recovery, Round, Verdict};
use crate::profiles::{ProfileName, ProfileSpec, WorldShape};
use crate::rc::{Rc, Verdicts};
use crate::relay::SimRelay;
use crate::rig::{
    sim_magnitude, CapturedLine, DeclareSink, DeviceTag, RelayTag, RigError, SimWorld,
};
use crate::scenarios::{Scenario, ScenarioReport, ScenarioWorld};
use crate::timeline::{self, Snapshot, Timeline};

/// What one run is asked to do.
///
/// Every field is a decision somebody made before the run started: the profile
/// and its shape, the seed the schedule was minted from, the schedule itself,
/// where the artifacts go, and what the build was.
pub struct RunPlan {
    /// The profile, overrides already applied and validated.
    pub spec: ProfileSpec,
    /// The seed the schedule came from. Printed; it is the reproduction recipe.
    pub seed: u64,
    /// The schedule this run walks.
    pub schedule: Schedule,
    /// The timeline's path. Its directory is the artifact tree.
    pub timeline_out: PathBuf,
    /// Where to write the sealed manifest, if anything is to read it.
    pub needle_manifest: Option<PathBuf>,
    /// Stop after this many applied ops and take the snapshot anyway.
    pub stop_at_step: Option<u64>,
    /// Which scenarios to run, as a glob over their ids.
    pub scenario_filter: Option<String>,
    /// What build this is.
    pub provenance: Provenance,
}

/// Runs `plan` and answers with the verdict the caller exits on.
///
/// Never returns an error: a refusal IS a verdict, and the one thing a run may
/// not do is exit 0 because something went wrong before it could grade.
pub async fn run(plan: &RunPlan) -> Rc {
    match run_inner(plan).await {
        Ok(rc) => rc,
        Err(refused) => {
            eprintln!("haven-soak: {refused}");
            refused.rc()
        }
    }
}

/// The run, top to bottom.
async fn run_inner(plan: &RunPlan) -> Result<Rc, Refusal> {
    let started = tokio::time::Instant::now();
    let dir = timeline::artifact_dir(&plan.timeline_out);
    let banner = Banner::new(
        plan.spec.name,
        plan.seed,
        &plan.schedule.tag(),
        plan.provenance.clone(),
    );
    // Before the run, not after: a run that dies in its first tick must still
    // have its seed and its schedule tag on record, because those two are the
    // whole reproduction recipe.
    banner.write_to(&dir, None).map_err(|_| Refusal::Artifact)?;
    print!("{}", banner.head());

    let timeline = Timeline::to_path(&plan.timeline_out).map_err(|_| Refusal::Artifact)?;
    timeline
        .write_schedule(&dir, &plan.schedule)
        .map_err(|_| Refusal::Artifact)?;

    let verdicts = drive(plan, &timeline, &dir).await?;
    timeline::write_markers(&dir, verdicts).map_err(|_| Refusal::Artifact)?;
    timeline.flush().map_err(|_| Refusal::Artifact)?;

    let measured = Measured::new(started.elapsed());
    banner
        .write_to(&dir, Some(measured))
        .map_err(|_| Refusal::Artifact)?;
    print!("{}", banner.render(Some(measured)));
    Ok(verdicts.rc())
}

/// Why a run could not finish. A classification: everything underneath it
/// renders a path, a value or remote-authored prose.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    /// The rig could not do its job.
    Rig(RigError),
    /// The capture could not do its job.
    Sink(SinkError),
    /// An artifact could not be written. The `io::Error` is dropped rather than
    /// rendered: its message carries the path.
    Artifact,
}

impl Refusal {
    /// The verdict this refusal folds into.
    #[must_use]
    pub fn rc(self) -> Rc {
        match self {
            Self::Artifact => Rc::RigBroken,
            Self::Rig(error) => error.rc(),
            Self::Sink(error) => error.rc(),
        }
    }
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Rig(error) => write!(f, "{error}"),
            Self::Sink(error) => write!(f, "{error}"),
            Self::Artifact => f.write_str("an artifact could not be written"),
        }
    }
}

impl From<RigError> for Refusal {
    fn from(error: RigError) -> Self {
        Self::Rig(error)
    }
}

impl From<SinkError> for Refusal {
    fn from(error: SinkError) -> Self {
        Self::Sink(error)
    }
}

/// The world a run drives: the real relay plane, the run's own timeline, the
/// process-wide capture.
///
/// Public because the binary's `--self-test` builds worlds of exactly this
/// shape: a self-test over a different world would be proving something about
/// a world no run ever has.
pub type RunWorld = ScenarioWorld<Timeline, SoakLogs>;

/// Drives every phase of a run.
///
/// # One world per phase, and one per arm
///
/// Not one world for the whole run. An arm's expectation floor counts what its
/// OWN world did — S11's "nothing was delivered while the circle was quiet" is
/// a floor term — so a world carrying the previous arm's in-flight deliveries
/// would fail a floor for the previous arm's reasons. Every in-crate control
/// grades a fresh world for the same reason, and a lane that did otherwise
/// would be red for a reason that is not the subject's.
/// The lease is taken here and passed on, so its life is the driven world's
/// and not this function's: `SoakLogs` is a process-wide capture lease, and the
/// next world waits on it.
async fn drive(plan: &RunPlan, timeline: &Timeline, dir: &Path) -> Result<Verdicts, Refusal> {
    // The run's own deadline bounds the wait: a lease still held here is a
    // leaked handle or a second run in this process, and either way the run has
    // to answer with a verdict rather than sit until the lane's reaper kills it
    // with an anonymous timeout.
    let logs = SoakLogs::acquire(Duration::from_secs(plan.spec.deadline_secs)).await?;
    drive_with(plan, timeline, dir, logs).await
}

/// Drives one run under an already-held capture lease.
async fn drive_with(
    plan: &RunPlan,
    timeline: &Timeline,
    dir: &Path,
    logs: SoakLogs,
) -> Result<Verdicts, Refusal> {
    let needles = Arc::new(NeedleSink::new()?);
    let mut run = Run {
        dir: dir.to_path_buf(),
        seed: plan.seed,
        tick: Duration::from_millis(plan.spec.tick_ms),
        stop_at_step: plan.stop_at_step,
        filter: plan.scenario_filter.clone(),
        id: run_id(plan.spec.name, plan.seed),
        logs,
        needles,
        // CI only. The lane's scan step is this file's reader and a landed
        // guard rotates and discards it; a local run passes no path, seals in
        // memory and leaves nothing on disk.
        manifest_out: plan.needle_manifest.clone(),
        seal_generation: 0,
        verdicts: Verdicts::new(),
        first_violation: false,
        last_scan: Vec::new(),
        stopped: false,
        phase_started: tokio::time::Instant::now(),
        active: Vec::new(),
    };

    run.nemesis_phase(&plan.spec.world, plan.schedule.clone(), timeline)
        .await?;
    if !run.stopped {
        run.scenario_phase(&plan.spec, timeline).await?;
    }
    Ok(run.verdicts)
}

/// The run's declaration sink: one [`Needles`] set behind a lock, because a
/// world declares through a shared handle while the run seals from the same
/// set afterwards.
struct NeedleSink {
    needles: Mutex<Needles>,
}

impl NeedleSink {
    /// An empty declaration set under the compiled-in policy.
    fn new() -> Result<Self, SinkError> {
        Ok(Self {
            needles: Mutex::new(Needles::new()?),
        })
    }

    /// Everything declared so far, sealed in memory.
    fn seal(&self, run_id: &str) -> Result<Manifest, SinkError> {
        self.locked().seal(run_id)
    }

    /// Poison-tolerant: a panicked declaration is not a reason to lose every
    /// value already declared.
    fn locked(&self) -> std::sync::MutexGuard<'_, Needles> {
        self.needles.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl DeclareSink for NeedleSink {
    fn declare_device(&self, secret_hex: &str, pubkey_hex: &str) -> Result<(), RigError> {
        let mut needles = self.locked();
        needles
            .declare_secret_key(secret_hex)
            .and_then(|()| needles.declare_pubkey(pubkey_hex))
            .map_err(|_| RigError::DeclarationRefused)
    }

    fn declare_circle(
        &self,
        mls_group_id_hex: &str,
        nostr_group_id_hex: &str,
        name: &str,
    ) -> Result<(), RigError> {
        let mut needles = self.locked();
        needles
            .declare_mls_group_id(mls_group_id_hex)
            .and_then(|()| needles.declare_nostr_group_id(nostr_group_id_hex))
            .and_then(|()| needles.declare_circle_name(name))
            .map_err(|_| RigError::DeclarationRefused)
    }

    fn declare_relay(&self, url: &str) -> Result<(), RigError> {
        self.locked()
            .declare_relay_url(url)
            .map_err(|_| RigError::DeclarationRefused)
    }
}

/// The run id the manifest carries. Deterministic in the two things that
/// reproduce a run, so two halves of one job are told apart by their paths
/// rather than by a clock.
fn run_id(profile: ProfileName, seed: u64) -> String {
    format!("soak-{profile}-{seed:016x}")
}

/// What the SCHEDULE declared, as against what the world did.
///
/// A pair rather than two arguments, so the two sources cannot be swapped at a
/// call site: the whole point of the floor below is that the declaration and
/// the observation come from different places.
struct Scheduled {
    /// Faults the generator placed in the op list.
    faults: usize,
    /// Probe rounds it placed there.
    probes: u64,
}

impl Scheduled {
    fn new(faults: usize, probes: usize) -> Self {
        Self {
            faults,
            probes: u64::try_from(probes).unwrap_or(u64::MAX),
        }
    }
}

/// One run's accumulated state.
struct Run {
    dir: PathBuf,
    seed: u64,
    tick: Duration,
    stop_at_step: Option<u64>,
    filter: Option<String>,
    id: String,
    logs: SoakLogs,
    needles: Arc<NeedleSink>,
    /// Where the sealed manifest is re-written, when anything is to read it.
    manifest_out: Option<PathBuf>,
    /// How many times this run has sealed. Part of the staging file's name, so
    /// two seals of one run never collide on a `create_new` open.
    seal_generation: u64,
    verdicts: Verdicts,
    first_violation: bool,
    /// What the last capture's scan found: class, encoding and `capture:line`,
    /// carried so a snapshot says what the scanner saw at the moment the oracle
    /// looked rather than leaving the field empty.
    last_scan: Vec<String>,
    stopped: bool,
    phase_started: tokio::time::Instant,
    /// The scheduled ops that have fired and not yet healed, as of the last
    /// tick. Carried so a snapshot says what was wrong with the world at the
    /// moment the oracle looked, rather than what the schedule held overall.
    active: Vec<ScheduledOp>,
}

impl Run {
    /// Walks the whole nemesis schedule, then grades what the world came out
    /// as.
    ///
    /// Before the arms, deliberately. The schedule is the run's background and
    /// every non-permanent fault in it carries its own heal, so walking it to
    /// completion first leaves a world that is broken-and-recovered rather than
    /// one with a fault firing under a scenario's control round — which would
    /// grade an arm against two causes at once and make the lane red for a
    /// reason that is not the subject's.
    async fn nemesis_phase(
        &mut self,
        shape: &WorldShape,
        schedule: Schedule,
        timeline: &Timeline,
    ) -> Result<(), Refusal> {
        let ops: Vec<ScheduledOp> = schedule.ops().to_vec();
        let last = schedule.last_tick();
        let (mut world, manifest) = self.world_for(shape, schedule, timeline).await?;
        // Torn down whatever the walk answered: a world left standing holds a
        // Rule-14 session and the process-wide capture lease with it.
        let walked = self.walk(&mut world, &ops, last, &manifest).await;
        let torn = teardown_then(world, ()).await;
        walked.and(torn)
    }

    /// Walks every tick of the schedule and grades what the world came out as.
    async fn walk(
        &mut self,
        world: &mut RunWorld,
        ops: &[ScheduledOp],
        last: u64,
        manifest: &Manifest,
    ) -> Result<(), Refusal> {
        let scheduled_faults = ops
            .iter()
            .filter(|op| matches!(op.op, Op::Fault { .. }))
            .count();
        let scheduled_probes = ops.iter().filter(|op| op.op == Op::Probe).count();
        let mut applied_faults = 0_usize;
        let mark = self.logs.mark();
        // The phase is the scanner's own vocabulary: it looks for an `open`
        // token per emitter and treats its absence as a missed positive
        // control, because a capture with no plant in it is indistinguishable
        // from a capture nothing ever reached.
        logsink::plant("open")?;

        let mut applied = 0_u64;
        let mut probes = 0_u32;
        self.phase_started = tokio::time::Instant::now();
        for index in 0..=last {
            let due: Vec<&ScheduledOp> = ops.iter().filter(|op| op.tick == index).collect();
            let report = world.tick(index).await?;
            self.active = active_ops(ops, index);
            applied += report.applied as u64;
            // Counted from what the world says it applied, never from what the
            // schedule says it would: a floor fed the schedule's own numbers
            // would be asserting the schedule against itself.
            if report.applied == due.len() {
                applied_faults += due
                    .iter()
                    .filter(|op| matches!(op.op, Op::Fault { .. }))
                    .count();
            }
            if report.probe_requested {
                probes += 1;
                self.grade_probe(world, probes).await?;
            }
            if self.stop_at_step.is_some_and(|stop| applied >= stop) {
                self.stop_at_step(world)?;
                return Ok(());
            }
        }

        if applied_faults != scheduled_faults {
            // A fault that did not fire makes every bound derived from it a
            // fiction, and the floor below is graded on what fired.
            self.verdicts.fold_invariant(Rc::Unusable);
        }
        self.grade_settled(
            world,
            &Scheduled::new(scheduled_faults, scheduled_probes),
            applied_faults,
            probes,
        )
        .await?;
        logsink::plant("close")?;
        let lines = world.drain_logs(mark);
        self.scan("nemesis", &lines, manifest)
    }

    /// Builds one phase's world and seals the manifest that scans it.
    ///
    /// Every world mints its own keys, group ids and endpoints, so each is
    /// declared as it is built and the seal covers everything declared so far:
    /// a value the rig minted and never declared is one the scanner cannot
    /// search for.
    async fn world_for(
        &mut self,
        shape: &WorldShape,
        schedule: Schedule,
        timeline: &Timeline,
    ) -> Result<(RunWorld, Manifest), Refusal> {
        let mut relays = Vec::with_capacity(shape.relays);
        for ordinal in 0..shape.relays {
            let tag = RelayTag::new(u32::try_from(ordinal).map_err(|_| RigError::ShapeMismatch)?);
            relays.push(SimRelay::start(tag).await?);
        }
        let mut world =
            SimWorld::build(shape, schedule, relays, timeline.clone(), self.logs.clone()).await?;
        self.logs.attribute_to(world.id());
        // Attached, not merely called: a circle an ARM builds later declares
        // itself through the same seam.
        world.declare_to(Arc::clone(&self.needles) as Arc<dyn DeclareSink>)?;
        let manifest = self.needles.seal(&self.id)?;
        self.publish_manifest(&manifest)?;
        Ok((world, manifest))
    }

    /// Writes the sealed manifest where the lane's scan step reads it,
    /// replacing whatever was there.
    ///
    /// Called as each world is built and again as each arm finishes, rather
    /// than once at the end, because the end is not guaranteed to arrive: a run
    /// the lane's deadline reaps leaves its captures on disk with no manifest,
    /// and a capture scanned without one is searched by shape alone — nothing
    /// looks for the keys, group ids or endpoints THAT RUN minted. The window
    /// this leaves is a world's first mint to its first seal, which is the same
    /// instant.
    ///
    /// The seal is `create_new` by design — the first seal is the record of the
    /// run — so a re-seal writes a fresh sibling in the same directory and
    /// RENAMES it over the target. A reader that opens the path at any instant
    /// therefore sees a complete manifest: the previous seal or this one, never
    /// a half-written file.
    fn publish_manifest(&mut self, manifest: &Manifest) -> Result<(), Refusal> {
        let Some(target) = self.manifest_out.clone() else {
            return Ok(());
        };
        self.seal_generation += 1;
        let staging = target.with_file_name(format!(
            "{}-seal{}{}",
            self.id, self.seal_generation, MANIFEST_SUFFIX
        ));
        // Ours, in a 0700 directory the lane rotates: a leftover from a reaped
        // run must not make this one's seal fail on `create_new`.
        let _ = std::fs::remove_file(&staging);
        logsink::write_sealed_manifest(&staging, manifest)?;
        std::fs::rename(&staging, &target).map_err(|_| Refusal::Artifact)
    }

    /// Grades one probe round the schedule asked for.
    async fn grade_probe(&mut self, world: &mut RunWorld, ordinal: u32) -> Result<(), Refusal> {
        let pairs = chain_pairs(world);
        let round = Round {
            ordinal,
            reach: Reach::These(&pairs),
            // The generator places every probe after its slot's heal — in TICK
            // ORDINALS. Ticks are counted, not slept through, so a heal twenty
            // ticks before a probe is microseconds before it in wall time: the
            // ordering is the schedule's, and the recovery this round must be
            // graded against is the worst one any slot can carry.
            recovery: Recovery::Reconnect,
            tick: self.tick,
            row_envelope: 0,
            burst_opened: &[],
            classified: &[],
        };
        let verdict = Invariant::LocationRoundTrip.check(world, &round).await?;
        self.report_oracle(world, Invariant::LocationRoundTrip, verdict)
    }

    /// Grades the world the schedule left behind.
    ///
    /// O1, O2 and O6 only: O5's subject is a set of classifications, and the
    /// background schedule collects none — an empty set would grade as
    /// "nothing went unaccounted for" because nothing was looked at, which is
    /// exactly the vacuous pass the oracle refuses.
    ///
    /// This is the run's TEARDOWN round, so it probes every ordered pair rather
    /// than the spanning chain the intermediate rounds use: the chain spans
    /// every device without paying for every pair, which is the right trade
    /// while the run still has rounds left, and the wrong one for the last look
    /// a world ever gets.
    async fn grade_settled(
        &mut self,
        world: &mut RunWorld,
        scheduled: &Scheduled,
        faults: usize,
        probes: u32,
    ) -> Result<(), Refusal> {
        let round = Round {
            ordinal: probes + 1,
            reach: Reach::EveryOrderedPair,
            recovery: Recovery::Reconnect,
            tick: self.tick,
            row_envelope: 0,
            burst_opened: &[],
            classified: &[],
        };
        for invariant in [
            Invariant::LocationRoundTrip,
            Invariant::SendPathLiveness,
            Invariant::Quiescence,
        ] {
            let verdict = invariant.check(world, &round).await?;
            self.report_oracle(world, invariant, verdict)?;
        }

        // The schedule's own floor, DECLARED by the schedule and OBSERVED from
        // the world: the floor counts what the generator put in the op list,
        // the observation counts what the ticks reported applying and what the
        // devices' own ledgers folded. Grading the world's numbers against
        // themselves — which is what passing `faults` to both sides does —
        // cannot fail, and a floor that cannot fail is not a floor.
        world.drain_buses();
        let observed = vacuity::Observed::measure(world, 0).await?;
        let floor = vacuity::ExpectationFloor {
            faults_applied: scheduled.faults,
            epochs_crossed: 0,
            // One delivery per probe round the schedule asked for. The
            // background schedule stages no commit, so it crosses no epoch and
            // catches no canary, and declaring either would be declaring
            // something no op in the list can produce.
            deliveries_observed: scheduled.probes,
            canaries_caught: 0,
        };
        let verdict = vacuity::grade(&floor, &observed);
        self.verdicts.fold_invariant(verdict.rc());
        // Bucketed into bindings first: an exact magnitude is a fingerprint of
        // the run, and a source scanner cannot see through a call to know one
        // was bucketed.
        let fired = sim_magnitude(faults);
        let rounds = sim_magnitude(usize::try_from(probes).unwrap_or(usize::MAX));
        let rendered = verdict.to_string();
        println!("nemesis: faults={fired} probes={rounds} floor={rendered}");
        Ok(())
    }

    /// Takes the same snapshot a violation would, and stops.
    fn stop_at_step(&mut self, world: &RunWorld) -> Result<(), Refusal> {
        let snapshot = Snapshot {
            scenario: "nemesis",
            arm: "schedule",
            violated: "none: the run stopped where it was asked to".to_owned(),
            finding: "stop-at-step".to_owned(),
            bound_secs: 0,
            observed_secs: 0,
            active: self.active.clone(),
            devices: rendered_devices(world),
            relays: rendered_relays(world),
            scan: self.last_scan.clone(),
        };
        self.snapshot(world, &snapshot)?;
        self.stopped = true;
        println!("stopped at the requested step; the snapshot is beside the timeline");
        Ok(())
    }

    /// Runs every arm the profile declares, in declaration order, until one of
    /// them leaks.
    async fn scenario_phase(
        &mut self,
        spec: &ProfileSpec,
        timeline: &Timeline,
    ) -> Result<(), Refusal> {
        for selection in &spec.scenarios {
            let scenario = Scenario::with_id(&selection.id).ok_or(RigError::UnknownTarget)?;
            if !self.selected(scenario) {
                continue;
            }
            for label in &selection.arms {
                if self.stopped {
                    return Ok(());
                }
                let arm = scenario.arm(label).ok_or(RigError::UnknownTarget)?;
                self.arm(scenario, label, arm, spec, timeline).await?;
            }
        }
        Ok(())
    }

    /// Runs one arm against a world of its own.
    async fn arm(
        &mut self,
        scenario: Scenario,
        label: &str,
        arm: &crate::scenarios::Arm,
        spec: &ProfileSpec,
        timeline: &Timeline,
    ) -> Result<(), Refusal> {
        let (mut world, manifest) = self
            .world_for(&spec.world, Schedule::new(Vec::new()), timeline)
            .await?;
        let graded = self
            .graded(scenario, label, arm, &mut world, &manifest)
            .await;
        let torn = teardown_then(world, ()).await;
        graded.and(torn)
    }

    /// Runs one arm over `world` and folds everything it answered.
    async fn graded(
        &mut self,
        scenario: Scenario,
        label: &str,
        arm: &crate::scenarios::Arm,
        world: &mut RunWorld,
        manifest: &Manifest,
    ) -> Result<(), Refusal> {
        self.phase_started = tokio::time::Instant::now();
        // An arm's world is built with an empty schedule, so nothing of the
        // nemesis phase's is still active while it runs.
        self.active.clear();
        let mark = self.logs.mark();
        let capture = format!("{}-{label}", scenario.id());
        logsink::plant("open")?;
        let report = scenario.run(world, arm, self.tick).await?;
        logsink::plant("close")?;
        let lines = world.drain_logs(mark);
        self.scan(&capture, &lines, manifest)?;
        self.fold(world, &report)?;
        // After the arm, not only before its world: an arm builds circles of
        // its own, and every value they minted was declared through the same
        // seam.
        let sealed = self.needles.seal(&self.id)?;
        self.publish_manifest(&sealed)
    }

    /// Whether `--scenario-filter` selected this scenario.
    fn selected(&self, scenario: Scenario) -> bool {
        self.filter
            .as_deref()
            .is_none_or(|pattern| glob_matches(pattern, scenario.id()))
    }

    /// Folds one arm's answer in, and takes the snapshot if it is the first
    /// thing that broke.
    fn fold(&mut self, world: &RunWorld, report: &ScenarioReport) -> Result<(), Refusal> {
        let rc = report.rc();
        self.verdicts.fold_invariant(rc);
        // The bound is printed beside the measurement rather than folded a
        // second time: every span that matters is already enforced inside an
        // oracle's own bounded wait, and grading the arm's total again would
        // double-count the same constants and make a loaded runner look like a
        // defect.
        let rendered = report.to_string();
        let within = if report.within_deadline() {
            "within"
        } else {
            "over"
        };
        println!("{rendered} bound={within}");
        for (invariant, verdict) in &report.graded {
            self.verdicts.fold_invariant(verdict.rc());
            let rendered = format!("{invariant}: {verdict}");
            println!("{rendered}");
        }
        if rc != Rc::Clean && !self.first_violation {
            let snapshot = self.violation(world, report);
            self.snapshot(world, &snapshot)?;
            self.first_violation = true;
        }
        Ok(())
    }

    /// The first-violation snapshot for `report`.
    fn violation(&self, world: &RunWorld, report: &ScenarioReport) -> Snapshot {
        let broken = report
            .graded
            .iter()
            .find(|(_, verdict)| *verdict != Verdict::Holds);
        Snapshot {
            scenario: report.scenario.id(),
            arm: report.arm,
            violated: broken.map_or_else(
                || "the arm's expectation floor".to_owned(),
                |(invariant, _)| invariant.to_string(),
            ),
            finding: broken.map_or_else(
                || report.floor.to_string(),
                |(_, verdict)| verdict.to_string(),
            ),
            bound_secs: report.deadline.as_secs(),
            observed_secs: report.elapsed.as_secs(),
            active: Vec::new(),
            devices: rendered_devices(world),
            relays: rendered_relays(world),
            scan: self.last_scan.clone(),
        }
    }

    /// Writes a snapshot beside the timeline.
    fn snapshot(&self, world: &RunWorld, snapshot: &Snapshot) -> Result<(), Refusal> {
        world
            .timeline()
            .write_snapshot(&self.dir, self.seed, snapshot)
            .map_err(|_| Refusal::Artifact)?;
        Ok(())
    }

    /// Scans one capture window, folds the scan verdict, and ends the run if it
    /// was a leak.
    fn scan(
        &mut self,
        capture: &str,
        lines: &[CapturedLine],
        manifest: &Manifest,
    ) -> Result<(), Refusal> {
        let report = logsink::scan_capture(capture, lines, manifest)?;
        self.verdicts.fold_scan(report.rc);
        let verdict = report.rc.name();
        let contained = report.contained;
        println!("scan {capture}: {verdict} contained={contained}");
        for finding in &report.findings {
            println!("  {finding}");
        }
        // Kept for the snapshot: a first-violation snapshot taken after this
        // one is the reader's only account of what the scanner saw, and a field
        // that is always empty is a promise the artifact does not keep.
        self.last_scan.clone_from(&report.findings);
        if scan_halts(report.rc) {
            self.stopped = true;
        }
        Ok(())
    }

    /// Prints one oracle's answer and folds it, taking the first-violation
    /// snapshot if this is the first thing that broke.
    ///
    /// The snapshot is owed wherever the violation happened: a schedule that
    /// broke the world before any arm ran is exactly the case a reader has the
    /// least other evidence for.
    ///
    /// # Errors
    ///
    /// [`Refusal::Artifact`] if the snapshot cannot be written.
    fn report_oracle(
        &mut self,
        world: &RunWorld,
        invariant: Invariant,
        verdict: Verdict,
    ) -> Result<(), Refusal> {
        self.verdicts.fold_invariant(verdict.rc());
        // The oracle's own rendering: a classification and the rig's handles.
        let rendered = format!("{invariant}: {verdict}");
        println!("{rendered}");
        if verdict != Verdict::Holds && !self.first_violation {
            let snapshot = Snapshot {
                scenario: "nemesis",
                arm: "schedule",
                violated: invariant.to_string(),
                finding: verdict.to_string(),
                bound_secs: bounds::quiescence(Recovery::Reconnect, self.tick).as_secs(),
                observed_secs: self.phase_started.elapsed().as_secs(),
                active: self.active.clone(),
                devices: rendered_devices(world),
                relays: rendered_relays(world),
                scan: self.last_scan.clone(),
            };
            self.snapshot(world, &snapshot)?;
            self.first_violation = true;
        }
        Ok(())
    }
}

/// Whether a scan verdict ends the run.
///
/// Only a leak does. An unusable or too-thin capture is diagnosed by reading
/// the rest of the run; a capture that carried a DECLARED value is deleted
/// where it is found, so everything after it would be written beside evidence
/// nobody can re-read, and every later world would mint more values into a
/// manifest the run has already had to contain (§3.8).
const fn scan_halts(rc: Rc) -> bool {
    matches!(rc, Rc::ViolationOrLeak)
}

/// Tears `world` down and answers with what the caller measured.
///
/// A helper rather than two statements, so the world's own handles — the
/// capture lease above all — end with the last thing that used them rather
/// than at the end of a function that goes on to write artifacts. Public for
/// the binary's `--self-test`, which owes its worlds the same teardown.
///
/// # Errors
///
/// [`Refusal`] if the world could not be torn down: a leaked handle keeps a
/// Rule-14 session alive and the next world would be a second one over the
/// same store.
pub async fn teardown_then<T>(world: RunWorld, answer: T) -> Result<T, Refusal> {
    world.teardown().await?;
    Ok(answer)
}

/// The ordered pairs a background probe round covers: a chain over the world's
/// devices, which spans every device without paying for every pair.
///
/// Public for the binary's `--self-test`, whose planted-defect rounds probe the
/// same pairs a run's own do.
#[must_use]
pub fn chain_pairs(world: &RunWorld) -> Vec<(DeviceTag, DeviceTag)> {
    let tags: Vec<DeviceTag> = world.devices().iter().map(|device| device.tag).collect();
    tags.windows(2).map(|pair| (pair[0], pair[1])).collect()
}

/// The scheduled ops that have fired by `index` and not yet healed.
fn active_ops(ops: &[ScheduledOp], index: u64) -> Vec<ScheduledOp> {
    ops.iter()
        .filter(|op| op.tick <= index && op.heal_at.is_none_or(|heal| heal > index))
        .copied()
        .collect()
}

/// Every device, through the rig's own bucketed rendering.
fn rendered_devices(world: &RunWorld) -> Vec<String> {
    world
        .devices()
        .iter()
        .map(|device| format!("{device:?}"))
        .collect()
}

/// Every relay plane, the same way.
fn rendered_relays(world: &RunWorld) -> Vec<String> {
    world
        .relays()
        .iter()
        .map(|relay| format!("{relay:?}"))
        .collect()
}

/// Whether `pattern` (a glob whose only wildcard is `*`) matches `value`.
fn glob_matches(pattern: &str, value: &str) -> bool {
    let mut segments = pattern.split('*');
    let Some(first) = segments.next() else {
        return true;
    };
    let Some(mut rest) = value.strip_prefix(first) else {
        return false;
    };
    let mut trailing = true;
    for segment in segments {
        trailing = segment.is_empty();
        if segment.is_empty() {
            continue;
        }
        let Some(at) = rest.find(segment) else {
            return false;
        };
        rest = &rest[at + segment.len()..];
    }
    trailing || rest.is_empty()
}

#[cfg(test)]
mod tests {
    /// What a test waits for the capture lease: the product's own settle
    /// window, derived rather than invented, and longer than any lease this
    /// binary holds — so a leaked one fails instead of hanging.
    fn lease_bound() -> Duration {
        crate::oracle::bounds::settle()
    }

    use super::{
        active_ops, glob_matches, run, run_id, scan_halts, NeedleSink, Run, RunPlan,
        MANIFEST_SUFFIX,
    };
    use crate::banner::Provenance;
    use crate::logsink::SoakLogs;
    use crate::nemesis::types::{Fault, Op, Schedule, ScheduledOp};
    use crate::profiles::{ProfileName, ProfileSpec, ScenarioSelection, WorldShape};
    use crate::rc::{Rc, Verdicts};
    use crate::rig::{CapturedLine, RelayTag, WorldId};
    use crate::timeline::Timeline;
    use std::path::PathBuf;
    use std::sync::Arc;
    use std::time::Duration;

    #[test]
    fn a_scenario_filter_selects_by_glob() {
        assert!(glob_matches("S01", "S01"));
        assert!(!glob_matches("S01", "S06"));
        assert!(glob_matches("*", "S13"));
        assert!(glob_matches("S1*", "S13"));
        assert!(!glob_matches("S1*", "S06"));
        assert!(glob_matches("*1*", "S11"));
        assert!(!glob_matches("*9*", "S11"));
        assert!(glob_matches("S*3", "S13"));
        assert!(!glob_matches("S*3", "S11"));
    }

    #[test]
    fn a_snapshot_carries_the_faults_that_had_fired_and_not_healed() {
        let ops = vec![
            ScheduledOp {
                tick: 1,
                op: Op::Fault {
                    relay: RelayTag::new(0),
                    fault: Fault::SwallowOk,
                },
                heal_at: Some(9),
            },
            ScheduledOp {
                tick: 2,
                op: Op::Fault {
                    relay: RelayTag::new(0),
                    fault: Fault::Down,
                },
                heal_at: Some(3),
            },
            ScheduledOp {
                tick: 8,
                op: Op::Probe,
                heal_at: None,
            },
        ];
        let active = active_ops(&ops, 5);
        assert!(active.len() == 1, "the healed one is no longer active");
        assert!(active[0].tick == 1, "and the unhealed one still is");
        assert!(
            active_ops(&ops, 8).len() == 2,
            "a permanent op stays active once it has fired"
        );
        assert!(
            active_ops(&ops, 0).is_empty(),
            "nothing is active before its tick"
        );
    }

    /// A run whose scenario phase is two cheap arms of two different
    /// scenarios.
    fn two_scenario_spec() -> ProfileSpec {
        let mut spec = ProfileSpec::embedded(ProfileName::Pr).expect("the pr profile parses");
        spec.world = WorldShape {
            members: 2,
            circles: 1,
            relays: 1,
        };
        spec.scenarios = vec![
            ScenarioSelection {
                id: "S06".to_owned(),
                arms: vec!["stuck-row-sweep".to_owned()],
            },
            ScenarioSelection {
                id: "S11".to_owned(),
                arms: vec!["quiet-circle-resume".to_owned()],
            },
        ];
        spec
    }

    /// A run in its initial state, over an already-held capture lease.
    fn bare_run(logs: SoakLogs, dir: PathBuf, manifest_out: Option<PathBuf>) -> Run {
        Run {
            dir,
            seed: 7,
            tick: Duration::from_millis(20),
            stop_at_step: None,
            filter: None,
            id: run_id(ProfileName::Pr, 7),
            logs,
            needles: Arc::new(NeedleSink::new().expect("a declaration set")),
            manifest_out,
            seal_generation: 0,
            verdicts: Verdicts::new(),
            first_violation: false,
            last_scan: Vec::new(),
            stopped: false,
            phase_started: tokio::time::Instant::now(),
            active: Vec::new(),
        }
    }

    #[test]
    fn only_a_leak_ends_a_run() {
        // An unusable or too-thin capture is diagnosed by reading the rest of
        // the run; a leak is the one verdict that makes everything after it
        // unreadable, because the evidence is deleted where it is found.
        assert!(scan_halts(Rc::ViolationOrLeak));
        for survivable in [Rc::Clean, Rc::RigBroken, Rc::Unusable, Rc::ProvesTooLittle] {
            assert!(
                !scan_halts(survivable),
                "only a leak ends the run; everything else is diagnosed by \
                 reading what the rest of it produced"
            );
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_capture_carrying_a_declared_value_stops_the_run_and_is_recorded() {
        // Half one of "a leak in scenario k stops scenario k+1": the scan sets
        // the run's stop. Half two is the test below.
        const NEEDLE: &str = "SoakLeakControlCircleName";
        let dir = tempfile::TempDir::new().expect("an artifact directory");
        // Acquired inline: the lease is a handle whose whole life is this run's.
        let mut leaking = bare_run(
            SoakLogs::acquire(lease_bound())
                .await
                .expect("the capture lease"),
            dir.path().to_path_buf(),
            None,
        );
        leaking
            .needles
            .locked()
            .declare_circle_name(NEEDLE)
            .expect("the name is declarable");
        let manifest = leaking
            .needles
            .seal(&leaking.id)
            .expect("a sealed manifest");

        let planted = [CapturedLine {
            seq: 1,
            world: WorldId::new(0),
            level: log::Level::Warn,
            target: "haven_soak::control".to_owned(),
            text: format!("a line that should never have carried {NEEDLE}"),
        }];
        leaking
            .scan("leak-control", &planted, &manifest)
            .expect("the scan reads");

        assert!(
            leaking.verdicts.rc() == Rc::ViolationOrLeak,
            "a declared value in a capture is a leak, and the run folds it as one"
        );
        assert!(
            leaking.stopped,
            "and the run stops there rather than building more worlds into a \
             manifest it has already had to contain"
        );
        assert!(
            !leaking.last_scan.is_empty(),
            "the finding is kept for the snapshot, which would otherwise carry \
             an empty field where the scanner's account belongs"
        );
        // Explicit: the capture lease is process-wide, and the next test in
        // this binary waits on it.
        drop(leaking);
        drop(dir);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_stopped_run_builds_no_further_world() {
        // Half two: whatever set the stop, the next scenario does not run. The
        // observable is the SEALED MANIFEST — a world declares its devices'
        // keys as it is built and the run re-seals right there, so a phase that
        // built nothing leaves no manifest at all.
        let spec = two_scenario_spec();
        let dir = tempfile::TempDir::new().expect("an artifact directory");
        let target = PathBuf::from(haven_logscan::manifest::NEEDLE_DIR)
            .join(format!("soak-driver-stop-control{MANIFEST_SUFFIX}"));
        let _ = std::fs::remove_file(&target);

        let mut stopped = bare_run(
            SoakLogs::acquire(lease_bound())
                .await
                .expect("the capture lease"),
            dir.path().to_path_buf(),
            Some(target.clone()),
        );
        stopped.stopped = true;
        stopped
            .scenario_phase(&spec, &Timeline::in_memory())
            .await
            .expect("the phase returns");
        assert!(
            !target.exists(),
            "a stopped run must build no world, so it mints nothing and has \
             nothing to seal"
        );
        // Load-bearing, not tidiness: the capture lease is exclusive, so the
        // control below would spend its whole bound waiting on this run and
        // then fail as `LeaseUnavailable` — a rig verdict, where the finding
        // this test is about is the manifest.
        drop(stopped);

        // The control: the same phase, not stopped, really does run and really
        // does declare. Without it the assertion above would hold on a phase
        // that never ran anything under any condition.
        let mut running = bare_run(
            SoakLogs::acquire(lease_bound())
                .await
                .expect("the capture lease"),
            dir.path().to_path_buf(),
            Some(target.clone()),
        );
        running
            .scenario_phase(&spec, &Timeline::in_memory())
            .await
            .expect("the phase returns");
        assert!(
            target.exists(),
            "the same phase, unstopped, builds its worlds and seals what they mint"
        );
        drop(running);
        drop(dir);
        let _ = std::fs::remove_file(&target);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_run_killed_before_it_finishes_still_left_a_manifest_covering_what_it_minted() {
        // The lane's deadline reaps a hung run with a signal, so nothing this
        // crate writes at the END of a run can be relied on. `--stop-at-step`
        // is the same shape reachable from a test: the run leaves after its
        // first applied op, having built exactly one world.
        let dir = tempfile::TempDir::new().expect("an artifact directory");
        let target = PathBuf::from(haven_logscan::manifest::NEEDLE_DIR)
            .join(format!("soak-driver-reseal-control{MANIFEST_SUFFIX}"));
        let _ = std::fs::remove_file(&target);

        let mut spec = two_scenario_spec();
        spec.scenarios.clear();
        spec.scenarios.push(ScenarioSelection {
            id: "S06".to_owned(),
            arms: vec!["stuck-row-sweep".to_owned()],
        });
        let plan = RunPlan {
            spec,
            seed: 11,
            schedule: Schedule::new(vec![ScheduledOp {
                tick: 0,
                op: Op::Fault {
                    relay: RelayTag::new(0),
                    fault: Fault::SwallowOk,
                },
                heal_at: Some(1),
            }]),
            timeline_out: dir.path().join("soak-timeline.log"),
            needle_manifest: Some(target.clone()),
            // One applied op, and then out — before the scenario phase and
            // before anything a run does on its way to a clean exit.
            stop_at_step: Some(1),
            scenario_filter: None,
            provenance: Provenance::new(None, None),
        };
        let _ = run(&plan).await;

        let sealed = std::fs::read(&target).expect("the manifest is on disk before the run ends");
        let manifest: serde_json::Value =
            serde_json::from_slice(&sealed).expect("the manifest on disk is complete JSON");
        let terms = manifest
            .get("terms")
            .and_then(serde_json::Value::as_array)
            .expect("a sealed manifest carries its searchable terms");
        assert!(
            !terms.is_empty(),
            "a run reaped mid-flight must already have sealed the values its \
             worlds minted, or its captures are searched by shape alone"
        );
        let _ = std::fs::remove_file(&target);
    }

    #[test]
    fn a_run_id_names_the_two_things_that_reproduce_a_run() {
        let id = run_id(ProfileName::Pr, 42);
        assert!(id.contains("pr"), "the profile is half the recipe");
        assert!(
            id.contains("000000000000002a"),
            "and the seed is the other half"
        );
    }
}
