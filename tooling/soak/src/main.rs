//! The soak binary: parse an invocation, resolve a profile, run it.
//!
//! # Why this refuses to build in release
//!
//! haven-core turns on `test-utils` here, and haven-core makes that a compile
//! error without debug assertions. Independently, the `ws://` loopback opt-in
//! every device needs to dial the world's own relay is `cfg(debug_assertions)`
//! with a release stub that always fails. A release build of this binary would
//! therefore either not compile or not connect — so it says so at compile time
//! rather than at 3 a.m. in a lane.
#[cfg(not(debug_assertions))]
compile_error!(
    "haven-soak requires debug-assertions; the ws:// loopback opt-in is cfg(debug_assertions) \
     and haven-core rejects `test-utils` without them. Build with --profile soak."
);

use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

use haven_soak::banner::Provenance;
use haven_soak::driver::{self, chain_pairs, teardown_then, Refusal, RunPlan, RunWorld};
use haven_soak::logsink::{self, SoakLogs};
use haven_soak::nemesis::generator::Generator;
use haven_soak::nemesis::types::Schedule;
use haven_soak::oracle::bounds::WaitScale;
use haven_soak::oracle::{bounds, vacuity, Invariant, Reach, Recovery, Round, Verdict};
use haven_soak::profiles::{ProfileName, ProfileSpec, WorldShape};
use haven_soak::rc::Rc;
use haven_soak::relay::SimRelay;
use haven_soak::rig::{DeviceTag, RelayPlane, RelayTag, RigError, SimWorld};
use haven_soak::scenarios::registry;
use haven_soak::timeline::{self, Timeline};

/// The checked-in seed. A PR run is reproducible from the repository alone, so
/// the default is a constant rather than something minted per run.
const DEFAULT_SEED: u64 = 0;

/// What the invocation asked for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mode {
    /// Run the profile.
    Run,
    /// Print the scenarios the binary would run.
    ListScenarios,
    /// Run the shipped artifact end to end over a planted world.
    SelfTest,
    /// Print the version and exit.
    Version,
}

/// A parsed invocation.
#[derive(Clone, PartialEq)]
struct Cli {
    mode: Mode,
    profile: ProfileName,
    seed: u64,
    duration_secs: Option<u64>,
    members: Option<usize>,
    circles: Option<usize>,
    relays: Option<usize>,
    tick_ms: Option<u64>,
    scenario_filter: Option<String>,
    stop_at_step: Option<u64>,
    timeline_out: Option<PathBuf>,
    needle_manifest: Option<PathBuf>,
    commit: Option<String>,
    rustc: Option<String>,
    wait_scale: WaitScale,
}

// Presence-only for the paths: an invocation carries two of them, and a
// rendering is the easiest place in a binary to print one by accident.
impl std::fmt::Debug for Cli {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Cli")
            .field("mode", &self.mode)
            .field("profile", &self.profile)
            .field("timeline_out", &self.timeline_out.is_some())
            .field("needle_manifest", &self.needle_manifest.is_some())
            .finish_non_exhaustive()
    }
}

/// The environment knobs, read once and passed in so parsing is a pure
/// function of its inputs and can be tested without touching the process.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct Env {
    profile: Option<String>,
    seed: Option<String>,
    wait_scale: Option<String>,
}

impl Env {
    fn from_process() -> Self {
        Self {
            profile: std::env::var("HAVEN_SOAK_PROFILE").ok(),
            seed: std::env::var("HAVEN_SOAK_SEED").ok(),
            wait_scale: std::env::var("HAVEN_TEST_WAIT_SCALE").ok(),
        }
    }
}

/// Why an invocation was refused. Names the flag, never a value: an argument
/// can carry a path, and a rejection message is the easiest place in a binary
/// to print one by accident.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct CliError {
    flag: &'static str,
}

impl std::fmt::Display for CliError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "bad or missing value for {}", self.flag)
    }
}

impl Cli {
    fn parse(args: &[String], env: &Env) -> Result<Self, CliError> {
        let mut cli = Self::defaults();
        cli.apply_env(env)?;
        cli.apply_args(args)?;
        Ok(cli)
    }

    /// The invocation with nothing said about it.
    const fn defaults() -> Self {
        Self {
            mode: Mode::Run,
            profile: ProfileName::Pr,
            seed: DEFAULT_SEED,
            duration_secs: None,
            members: None,
            circles: None,
            relays: None,
            tick_ms: None,
            scenario_filter: None,
            stop_at_step: None,
            timeline_out: None,
            needle_manifest: None,
            commit: None,
            rustc: None,
            wait_scale: WaitScale::ONE,
        }
    }

    /// Applies the CI-shaped knobs, which a flag may then override.
    fn apply_env(&mut self, env: &Env) -> Result<(), CliError> {
        let cli = self;
        if let Some(ref raw) = env.profile {
            cli.profile = ProfileName::parse(raw).ok_or(CliError {
                flag: "HAVEN_SOAK_PROFILE",
            })?;
        }
        if let Some(ref raw) = env.seed {
            cli.seed = parse_u64(raw).ok_or(CliError {
                flag: "HAVEN_SOAK_SEED",
            })?;
        }
        if let Some(ref raw) = env.wait_scale {
            // A whole multiplier, exactly as haven-core's own relay-backed
            // tests read it. Only ever stretches a delivery budget: below 1 it
            // would shrink one, and it never reaches an absence window at all —
            // an arm that asserts nothing happened for N seconds asserts
            // exactly N, whatever the machine (`oracle::bounds::WaitScale`).
            cli.wait_scale = raw.parse().ok().and_then(WaitScale::new).ok_or(CliError {
                flag: "HAVEN_TEST_WAIT_SCALE",
            })?;
        }
        Ok(())
    }

    /// Applies the command line.
    fn apply_args(&mut self, args: &[String]) -> Result<(), CliError> {
        let cli = self;
        let mut rest = args.iter();
        while let Some(arg) = rest.next() {
            let mut value = || rest.next().cloned();
            match arg.as_str() {
                "--profile" => {
                    let raw = value().ok_or(CliError { flag: "--profile" })?;
                    cli.profile = ProfileName::parse(&raw).ok_or(CliError { flag: "--profile" })?;
                }
                "--seed" => {
                    cli.seed = value()
                        .as_deref()
                        .and_then(parse_u64)
                        .ok_or(CliError { flag: "--seed" })?;
                }
                "--duration" => {
                    cli.duration_secs = Some(
                        value()
                            .as_deref()
                            .and_then(parse_u64)
                            .ok_or(CliError { flag: "--duration" })?,
                    );
                }
                "--members" => {
                    cli.members = Some(
                        value()
                            .as_deref()
                            .and_then(parse_usize)
                            .ok_or(CliError { flag: "--members" })?,
                    );
                }
                "--circles" => {
                    cli.circles = Some(
                        value()
                            .as_deref()
                            .and_then(parse_usize)
                            .ok_or(CliError { flag: "--circles" })?,
                    );
                }
                "--relays" => {
                    cli.relays = Some(
                        value()
                            .as_deref()
                            .and_then(parse_usize)
                            .ok_or(CliError { flag: "--relays" })?,
                    );
                }
                "--tick-ms" => {
                    cli.tick_ms = Some(
                        value()
                            .as_deref()
                            .and_then(parse_u64)
                            .ok_or(CliError { flag: "--tick-ms" })?,
                    );
                }
                "--scenario-filter" => {
                    cli.scenario_filter = Some(value().ok_or(CliError {
                        flag: "--scenario-filter",
                    })?);
                }
                "--stop-at-step" => {
                    cli.stop_at_step =
                        Some(value().as_deref().and_then(parse_u64).ok_or(CliError {
                            flag: "--stop-at-step",
                        })?);
                }
                "--timeline-out" => {
                    cli.timeline_out = Some(PathBuf::from(value().ok_or(CliError {
                        flag: "--timeline-out",
                    })?));
                }
                "--needle-manifest" => {
                    cli.needle_manifest = Some(PathBuf::from(value().ok_or(CliError {
                        flag: "--needle-manifest",
                    })?));
                }
                "--commit" => {
                    cli.commit = Some(value().ok_or(CliError { flag: "--commit" })?);
                }
                "--rustc" => {
                    cli.rustc = Some(value().ok_or(CliError { flag: "--rustc" })?);
                }
                "--list-scenarios" => cli.mode = Mode::ListScenarios,
                "--self-test" => cli.mode = Mode::SelfTest,
                "--version" => cli.mode = Mode::Version,
                _ => return Err(CliError { flag: "argument" }),
            }
        }
        Ok(())
    }

    /// The profile this invocation resolves to, overrides applied.
    fn spec(&self) -> Result<ProfileSpec, CliError> {
        let mut spec =
            ProfileSpec::embedded(self.profile).map_err(|_| CliError { flag: "--profile" })?;
        if let Some(duration) = self.duration_secs {
            spec.duration_secs = duration;
        }
        if let Some(members) = self.members {
            spec.world.members = members;
        }
        if let Some(circles) = self.circles {
            spec.world.circles = circles;
        }
        if let Some(relays) = self.relays {
            spec.world.relays = relays;
        }
        if let Some(tick_ms) = self.tick_ms {
            spec.tick_ms = tick_ms;
        }
        spec.validate()
            .map_err(|_| CliError { flag: "--profile" })?;
        Ok(spec)
    }

    /// Where the timeline goes: the lane's own path, or this run's default
    /// beside the working directory.
    fn timeline_path(&self) -> PathBuf {
        self.timeline_out
            .clone()
            .unwrap_or_else(|| timeline::default_path(Path::new("."), self.seed))
    }

    /// The one-line plan, printed before anything else runs.
    ///
    /// Rule 15: the profile name and the seed identify the run completely
    /// (both are repository facts), the spans are durations, and everything
    /// path-shaped is reported as presence rather than as a path.
    fn plan(&self) -> String {
        let presence = |set: bool| if set { "on" } else { "off" };
        format!(
            "haven-soak plan profile={} seed=0x{:016x} tick_ms={} duration_secs={} \
             stop_at_step={} wait_scale={} timeline={} manifest={} filter={}",
            self.profile,
            self.seed,
            self.tick_ms
                .map_or_else(|| "-".to_string(), |v| v.to_string()),
            self.duration_secs
                .map_or_else(|| "-".to_string(), |v| v.to_string()),
            self.stop_at_step
                .map_or_else(|| "-".to_string(), |v| v.to_string()),
            self.wait_scale.factor(),
            presence(self.timeline_out.is_some()),
            presence(self.needle_manifest.is_some()),
            presence(self.scenario_filter.is_some()),
        )
    }
}

fn parse_u64(raw: &str) -> Option<u64> {
    raw.strip_prefix("0x")
        .map_or_else(|| raw.parse().ok(), |hex| u64::from_str_radix(hex, 16).ok())
}

fn parse_usize(raw: &str) -> Option<usize> {
    raw.parse().ok()
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cli = match Cli::parse(&args, &Env::from_process()) {
        Ok(cli) => cli,
        Err(refused) => {
            eprintln!("haven-soak: {refused}");
            return exit_code(Rc::RigBroken);
        }
    };

    // Before anything derives a bound: a scale that moved mid-run would make
    // two arms of one run answer to different budgets.
    bounds::install_wait_scale(cli.wait_scale);

    match cli.mode {
        Mode::Version => {
            println!("haven-soak {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        Mode::ListScenarios => {
            list_scenarios();
            ExitCode::SUCCESS
        }
        Mode::SelfTest => exit_code(in_runtime(self_test())),
        Mode::Run => exit_code(in_runtime(async move { drive(&cli).await })),
    }
}

/// Drives `body` on a multi-threaded runtime.
///
/// Never `current_thread` and never `start_paused`: the subject's engines are
/// real tasks on real sockets, and a paused clock would advance the rig's waits
/// without advancing anything it is waiting FOR.
fn in_runtime<F: std::future::Future<Output = Rc>>(body: F) -> Rc {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(4)
        .enable_all()
        .build()
        .map_or_else(
            |_| {
                eprintln!("haven-soak: the runtime would not start");
                Rc::RigBroken
            },
            |runtime| runtime.block_on(body),
        )
}

/// Prints the REGISTRY's scenarios and their arms.
///
/// The registry, never the profile TOMLs: CI diffs this against them, and a
/// list read from the files it is checked against could not catch a scenario
/// that was declared and never implemented.
fn list_scenarios() {
    for scenario in registry() {
        println!("{scenario}");
        for arm in scenario.arms() {
            // Bound first: the field's own name is in the identifier guard's
            // vocabulary, and an argument position is where that matters.
            let spelled = arm.label;
            println!("  arm {spelled}");
        }
    }
}

/// Drives a run between this stream's own positive controls.
///
/// The lane redirects this process's stdout into the tree it scans as a `soak`
/// sink, so the stream is a capture of that class and its scan needs the same
/// opening plant every other capture carries: without one, a lane that read the
/// right tree and a lane that read a tree nothing wrote are the same verdict.
///
/// The token is therefore the FIRST line this binary writes for a run — ahead
/// of the plan line, the banner and the first world — so a run the lane's
/// reaper kills before any of those still answers for the stream it opened. The
/// closing token is the last, on every way out of the run including a refused
/// invocation.
///
/// `--self-test` and `--list-scenarios` stay plant-free: their output is
/// scanned as `rust-test`, which requires no shape plant, and a second stream
/// minting tokens of this shape is a way for one that never ran the profile to
/// satisfy the control of one that did.
async fn drive(cli: &Cli) -> Rc {
    if let Err(refused) = logsink::plant_stdout("open") {
        eprintln!("haven-soak: {refused}");
        return refused.rc();
    }
    let rc = drive_planned(cli).await;
    match logsink::plant_stdout("close") {
        Ok(_) => rc,
        Err(refused) => {
            eprintln!("haven-soak: {refused}");
            rc.folded(refused.rc())
        }
    }
}

/// Resolves the invocation into a plan and drives it.
///
/// Everything the CLI decides happens here — the profile, the overrides, the
/// seed, the schedule minted from it — and nothing else does: the driver takes
/// a plan, so a caller that is not a command line builds one directly.
async fn drive_planned(cli: &Cli) -> Rc {
    let spec = match cli.spec() {
        Ok(spec) => spec,
        Err(refused) => {
            eprintln!("haven-soak: {refused}");
            return Rc::RigBroken;
        }
    };
    println!("{}", cli.plan());
    let schedule = Generator::new(spec.clone(), cli.seed).schedule(&spec.world);
    let plan = RunPlan {
        spec,
        seed: cli.seed,
        schedule,
        timeline_out: cli.timeline_path(),
        needle_manifest: cli.needle_manifest.clone(),
        stop_at_step: cli.stop_at_step,
        scenario_filter: cli.scenario_filter.clone(),
        provenance: Provenance::new(cli.commit.as_deref(), cli.rustc.as_deref()),
    };
    driver::run(&plan).await
}

// ---------------------------------------------------------------------------
// --self-test
// ---------------------------------------------------------------------------

/// The world every self-test case runs over: two devices, one circle, one
/// relay — the smallest world in which one peer can receive what another sent.
const SELF_TEST_SHAPE: WorldShape = WorldShape {
    members: 2,
    circles: 1,
    relays: 1,
};

/// The tick these cases derive their bounds at. A harness cadence, not a
/// product bound.
const SELF_TEST_TICK: Duration = Duration::from_millis(20);

/// Runs the shipped artifact end to end: one planted defect per oracle family,
/// each required to redden, then a world with nothing wrong with it.
async fn self_test() -> Rc {
    match self_test_inner().await {
        Ok(rc) => rc,
        Err(refused) => {
            eprintln!("haven-soak: {refused}");
            refused.rc()
        }
    }
}

// Every case below runs unconditionally, and a case that refuses takes the
// whole self-test with it through `?`. There is deliberately no "declared
// versus ran" count: the cases are this function's own straight line, so such a
// count could not diverge, and a check that cannot fail is a check that reports
// coverage nobody has.
async fn self_test_inner() -> Result<Rc, Refusal> {
    let mut worst = Rc::Clean;
    // The self-test's own bound, derived like every other: the most disruptive
    // thing any case below waits on. A lease still held here is this binary
    // holding its own, which is a verdict rather than a hang.
    let logs = SoakLogs::acquire(bounds::quiescence(Recovery::Reconnect, SELF_TEST_TICK)).await?;

    // The bounds table first: every case below waits on a bound derived from
    // it, so a bounds table that no longer matches the product would make every
    // later verdict meaningless.
    worst = fold_case("bounds-table", bounds::self_check().is_ok(), worst);
    worst = fold_case("o1-swallowed-ack", case_o1(&logs).await?, worst);
    worst = fold_case("o6-staged-commit", case_o6(&logs).await?, worst);
    worst = fold_case("o5-unnamed-row", case_o5(&logs).await?, worst);
    worst = fold_case("floor-no-fault", case_floor(&logs).await?, worst);
    worst = fold_case("clean-world", case_clean(&logs).await?, worst);

    let verdict = worst.name();
    println!("self-test: {verdict}");
    Ok(worst)
}

/// Prints one case's line and folds it.
///
/// A case that did not behave as declared means the instrument is broken, never
/// that the subject is: these worlds are built by this binary and broken by it.
fn fold_case(case: &str, as_declared: bool, worst: Rc) -> Rc {
    let verdict = if as_declared {
        "as declared"
    } else {
        "UNEXPECTED"
    };
    println!("self-test {case}: {verdict}");
    if as_declared {
        worst
    } else {
        worst.folded(Rc::RigBroken)
    }
}

/// A world for one case.
async fn self_test_world(logs: &SoakLogs) -> Result<RunWorld, Refusal> {
    let relay = SimRelay::start(RelayTag::new(0)).await?;
    let world = SimWorld::build(
        &SELF_TEST_SHAPE,
        Schedule::new(Vec::new()),
        vec![relay],
        Timeline::in_memory(),
        logs.clone(),
    )
    .await?;
    logs.attribute_to(world.id());
    Ok(world)
}

/// A round over the world's chain pairs.
const fn self_test_round<'a>(
    ordinal: u32,
    pairs: &'a [(DeviceTag, DeviceTag)],
    classified: &'a [haven_soak::oracle::undecryptable::Verdict],
) -> Round<'a> {
    Round {
        ordinal,
        reach: Reach::These(pairs),
        recovery: Recovery::Undisturbed,
        tick: SELF_TEST_TICK,
        row_envelope: 0,
        burst_opened: &[],
        classified,
    }
}

/// O1: the relay stores the probe and the acknowledgement never reaches the
/// publisher, which Rule 13 says is not an ack.
async fn case_o1(logs: &SoakLogs) -> Result<bool, Refusal> {
    let mut world = self_test_world(logs).await?;
    let pairs = chain_pairs(&world);
    world.relays_mut()[0]
        .apply(haven_soak::nemesis::types::Fault::SwallowOk)
        .await?;
    let planted = Invariant::LocationRoundTrip
        .check(&mut world, &self_test_round(1, &pairs, &[]))
        .await?;
    world.relays_mut()[0]
        .apply(haven_soak::nemesis::types::Fault::Heal)
        .await?;
    let healed = Invariant::LocationRoundTrip
        .check(&mut world, &self_test_round(2, &pairs, &[]))
        .await?;
    let as_declared = planted != Verdict::Holds && healed == Verdict::Holds;
    teardown_then(world, as_declared).await
}

/// O6: a staged commit the rig never resolved. No engine counter and no world
/// fingerprint can see that state, which is why it is a term of the predicate.
async fn case_o6(logs: &SoakLogs) -> Result<bool, Refusal> {
    let mut world = self_test_world(logs).await?;
    let pairs = chain_pairs(&world);
    let leaked = world.note_pending_staged();
    let planted = Invariant::Quiescence
        .check(&mut world, &self_test_round(1, &pairs, &[]))
        .await?;
    drop(leaked);
    let healed = Invariant::Quiescence
        .check(&mut world, &self_test_round(2, &pairs, &[]))
        .await?;
    let as_declared = planted != Verdict::Holds && healed == Verdict::Holds;
    teardown_then(world, as_declared).await
}

/// O5: a genuine same-epoch commit race, classified WITHOUT naming the stored
/// row the ingest wrote. A past-epoch disposition with no row to read cannot be
/// folded into "no branch was lost", and the oracle has to say so.
async fn case_o5(logs: &SoakLogs) -> Result<bool, Refusal> {
    use haven_soak::oracle::undecryptable::{self, StoredRow};

    let mut world = self_test_world(logs).await?;
    let alice = world.devices()[0].tag;
    let bob = world.devices()[1].tag;
    let group = world.circles()[0].mls_group_id().clone();

    // Bob has to be able to commit at all, so alice hands him the admin bit and
    // his live engine applies it — the last thing either engine does.
    let successor = world.device(bob)?.keys.public_key();
    let handoff = world
        .device(alice)?
        .manager()?
        .propose_admin_handoff(&group, &successor)
        .await
        .map_err(|_| RigError::Core(haven_soak::rig::Step::StageCommit))?;
    world
        .publish_and_confirm(alice, handoff.pending, &[handoff.commit_event])
        .await?;
    if !epochs_agree(&world, &group).await? {
        return Err(Refusal::Rig(RigError::Timeout(
            haven_soak::rig::Wait::SessionReopen,
        )));
    }

    // Paused, both of them: a live engine would ingest the peer's commit first,
    // and the classifier would then be reading the second look, where a lost
    // branch reads as a duplicate.
    for device in world.devices_mut() {
        device.go_offline().await?;
    }

    let mut commits = Vec::with_capacity(2);
    for (index, tag) in [alice, bob].into_iter().enumerate() {
        let mut relays = world.relay_urls();
        relays.push(format!("wss://race-{index}.example.com"));
        let staged = world
            .device(tag)?
            .manager()?
            .update_circle_relays(&group, &relays)
            .await
            .map_err(|_| RigError::Core(haven_soak::rig::Step::StageCommit))?;
        let outstanding = world.note_pending_staged();
        // Rule 13, in the one place a self-test could quietly skip it: the
        // finalise below APPLIES the staged commit, so it may only run once a
        // relay has been seen to acknowledge the publish. A dropped `Option`
        // here would make the case's world a forked one and everything it then
        // classified a fiction.
        if world
            .publish_witnessed(tag, std::slice::from_ref(&staged.commit_event))
            .await?
            .is_none()
        {
            return Err(Refusal::Rig(RigError::PublishNeverAcked));
        }
        let ingest = world
            .device(tag)?
            .manager()?
            .finalize_relay_update(staged.pending, &group)
            .await
            .map_err(|_| RigError::Core(haven_soak::rig::Step::ConfirmPublished))?;
        // The confirm's own replay can stage further work; the self-test is a
        // real world and leaving a ref unresolved in it would fork the group.
        world.resolve_ingest(tag, ingest).await?;
        drop(outstanding);
        commits.push(staged.commit_event);
    }

    let mut classified = Vec::with_capacity(2);
    for (ingester, source) in [(bob, 0_usize), (alice, 1_usize)] {
        classified.push(
            undecryptable::classify(
                world.device(ingester)?,
                &commits[source],
                StoredRow::Unknown,
            )
            .await?,
        );
    }

    let pairs = chain_pairs(&world);
    let verdict = Invariant::Undecryptable
        .check(&mut world, &self_test_round(1, &pairs, &classified))
        .await?;
    let as_declared = verdict != Verdict::Holds;
    teardown_then(world, as_declared).await
}

/// The expectation floor: a world that delivered, graded against a floor whose
/// scheduled fault never fired.
async fn case_floor(logs: &SoakLogs) -> Result<bool, Refusal> {
    let mut world = self_test_world(logs).await?;
    let pairs = chain_pairs(&world);
    // A real round trip first, so the world genuinely delivered and the only
    // unmet term is the one this case is about.
    let delivered = Invariant::LocationRoundTrip
        .check(&mut world, &self_test_round(1, &pairs, &[]))
        .await?;
    world.drain_buses();
    let observed = vacuity::Observed::measure(&world, 1).await?;
    let floor = vacuity::ExpectationFloor {
        faults_applied: 1,
        epochs_crossed: 0,
        deliveries_observed: 1,
        canaries_caught: 1,
    };
    let verdict = vacuity::grade(&floor, &observed);
    let as_declared = delivered == Verdict::Holds && verdict.rc() == Rc::Unusable;
    teardown_then(world, as_declared).await
}

/// Every registered oracle on a world with nothing wrong with it.
async fn case_clean(logs: &SoakLogs) -> Result<bool, Refusal> {
    let mut world = self_test_world(logs).await?;
    let pairs = chain_pairs(&world);
    let classified = [haven_soak::oracle::undecryptable::Verdict::Applied];
    let mut held = true;
    for invariant in Invariant::REGISTRY {
        let verdict = invariant
            .check(&mut world, &self_test_round(1, &pairs, &classified))
            .await?;
        held = held && verdict == Verdict::Holds;
    }
    teardown_then(world, held).await
}

/// Whether every device holds the same epoch for `group`, within the
/// undisturbed round-trip bound.
async fn epochs_agree(
    world: &RunWorld,
    group: &haven_core::nostr::mls::types::GroupId,
) -> Result<bool, Refusal> {
    let bound = bounds::round_trip(Recovery::Undisturbed);
    let outcome = haven_soak::rig::poll_until(bound, Duration::from_millis(20), || async {
        let mut epochs = Vec::with_capacity(world.devices().len());
        for device in world.devices() {
            epochs.push(
                device
                    .manager()?
                    .group_epoch(group)
                    .await
                    .map_err(|_| RigError::Core(haven_soak::rig::Step::ReadEpoch))?,
            );
        }
        Ok(epochs.windows(2).all(|pair| pair[0] == pair[1]))
    })
    .await?;
    Ok(outcome.is_some())
}

/// A verdict as a process exit code. Every code in the taxonomy is 0..=4, so
/// the conversion cannot truncate.
fn exit_code(rc: Rc) -> ExitCode {
    ExitCode::from(u8::try_from(rc.code()).unwrap_or(2))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(raw: &[&str]) -> Vec<String> {
        raw.iter().map(|s| (*s).to_string()).collect()
    }

    #[test]
    fn the_default_invocation_is_the_pr_profile_at_the_checked_in_seed() {
        let cli = Cli::parse(&[], &Env::default()).expect("parses");
        assert_eq!(cli.profile, ProfileName::Pr);
        assert_eq!(cli.seed, DEFAULT_SEED);
        assert_eq!(cli.mode, Mode::Run);
        assert_eq!(cli.spec().expect("resolves").name, ProfileName::Pr);
    }

    #[test]
    fn every_flag_is_parsed() {
        let cli = Cli::parse(
            &args(&[
                "--profile",
                "weekly",
                "--seed",
                "0x2a",
                "--duration",
                "600",
                "--members",
                "4",
                "--circles",
                "2",
                "--relays",
                "3",
                "--tick-ms",
                "125",
                "--scenario-filter",
                "S1*",
                "--stop-at-step",
                "9",
                "--timeline-out",
                "/dev/null",
                "--needle-manifest",
                "/dev/null",
            ]),
            &Env::default(),
        )
        .expect("parses");
        assert_eq!(cli.profile, ProfileName::Weekly);
        assert_eq!(cli.seed, 42);
        assert_eq!(cli.duration_secs, Some(600));
        assert_eq!(cli.members, Some(4));
        assert_eq!(cli.circles, Some(2));
        assert_eq!(cli.relays, Some(3));
        assert_eq!(cli.tick_ms, Some(125));
        assert_eq!(cli.scenario_filter.as_deref(), Some("S1*"));
        assert_eq!(cli.stop_at_step, Some(9));
        assert!(cli.timeline_out.is_some());
        assert!(cli.needle_manifest.is_some());
    }

    #[test]
    fn the_three_modes_are_mutually_recognised() {
        assert_eq!(
            Cli::parse(&args(&["--list-scenarios"]), &Env::default())
                .expect("parses")
                .mode,
            Mode::ListScenarios
        );
        assert_eq!(
            Cli::parse(&args(&["--self-test"]), &Env::default())
                .expect("parses")
                .mode,
            Mode::SelfTest
        );
        assert_eq!(
            Cli::parse(&args(&["--version"]), &Env::default())
                .expect("parses")
                .mode,
            Mode::Version
        );
    }

    #[test]
    fn a_flag_without_its_value_is_refused_by_name() {
        assert_eq!(
            Cli::parse(&args(&["--seed"]), &Env::default()),
            Err(CliError { flag: "--seed" })
        );
        assert_eq!(
            Cli::parse(&args(&["--profile", "hourly"]), &Env::default()),
            Err(CliError { flag: "--profile" })
        );
        assert_eq!(
            Cli::parse(&args(&["--unknown"]), &Env::default()),
            Err(CliError { flag: "argument" })
        );
    }

    #[test]
    fn the_environment_supplies_the_ci_shaped_knobs() {
        let env = Env {
            profile: Some("nightly".to_string()),
            seed: Some("7".to_string()),
            wait_scale: Some("4".to_string()),
        };
        let cli = Cli::parse(&[], &env).expect("parses");
        assert_eq!(cli.profile, ProfileName::Nightly);
        assert_eq!(cli.seed, 7);
        assert_eq!(cli.wait_scale, WaitScale::new(4).expect("a whole scale"));
    }

    #[test]
    fn a_flag_overrides_the_environment() {
        let env = Env {
            profile: Some("nightly".to_string()),
            seed: Some("7".to_string()),
            wait_scale: None,
        };
        let cli = Cli::parse(&args(&["--profile", "weekly", "--seed", "8"]), &env).expect("parses");
        assert_eq!(cli.profile, ProfileName::Weekly);
        assert_eq!(cli.seed, 8);
    }

    #[test]
    fn a_wait_scale_below_one_is_refused_because_it_would_shrink_a_budget() {
        for raw in ["0", "0.5", "-1", "nan", "banana"] {
            let env = Env {
                profile: None,
                seed: None,
                wait_scale: Some(raw.to_string()),
            };
            assert_eq!(
                Cli::parse(&[], &env),
                Err(CliError {
                    flag: "HAVEN_TEST_WAIT_SCALE"
                }),
                "{raw}"
            );
        }
    }

    #[test]
    fn overrides_reach_the_profile_and_are_validated() {
        let cli = Cli::parse(
            &args(&["--members", "2", "--circles", "1", "--relays", "1"]),
            &Env::default(),
        )
        .expect("parses");
        let spec = cli.spec().expect("resolves");
        assert_eq!(spec.world.members, 2);
        assert_eq!(spec.world.circles, 1);
        assert_eq!(spec.world.relays, 1);

        let refused = Cli::parse(&args(&["--members", "1"]), &Env::default()).expect("parses");
        assert_eq!(refused.spec(), Err(CliError { flag: "--profile" }));
    }

    #[test]
    fn the_plan_line_names_no_path_and_no_world_magnitude() {
        let cli = Cli::parse(
            &args(&[
                "--members",
                "3",
                "--timeline-out",
                "/tmp/haven-soak/needle-path.log",
                "--needle-manifest",
                "/tmp/haven-soak/needles/needle.json",
                "--scenario-filter",
                "S01",
            ]),
            &Env::default(),
        )
        .expect("parses");
        let plan = cli.plan();
        assert!(plan.contains("profile=pr"), "{plan}");
        assert!(plan.contains("seed=0x0000000000000000"), "{plan}");
        assert!(!plan.contains("needle-path"), "{plan}");
        assert!(!plan.contains("/tmp/"), "{plan}");
        assert!(!plan.contains("members"), "{plan}");
        assert!(plan.contains("timeline=on"), "{plan}");
        assert!(plan.contains("manifest=on"), "{plan}");
        assert!(plan.contains("filter=on"), "{plan}");
    }

    #[test]
    fn an_invocations_debug_renders_no_path() {
        let cli = Cli::parse(
            &args(&["--timeline-out", "/tmp/haven-soak/needle-path.log"]),
            &Env::default(),
        )
        .expect("parses");
        let rendered = format!("{cli:?}");
        assert!(rendered.contains("Cli"), "{rendered}");
        assert!(!rendered.contains("needle-path"), "{rendered}");
        assert!(!rendered.contains("/tmp"), "{rendered}");
    }

    #[test]
    fn the_build_provenance_is_taken_from_the_command_line() {
        let cli = Cli::parse(
            &args(&["--commit", "abc123def456789", "--rustc", "1.92.0"]),
            &Env::default(),
        )
        .expect("parses");
        assert_eq!(cli.commit.as_deref(), Some("abc123def456789"));
        assert_eq!(cli.rustc.as_deref(), Some("1.92.0"));
        assert_eq!(
            Cli::parse(&args(&["--commit"]), &Env::default()),
            Err(CliError { flag: "--commit" })
        );
        assert_eq!(
            Cli::parse(&args(&["--rustc"]), &Env::default()),
            Err(CliError { flag: "--rustc" })
        );
    }

    #[test]
    fn the_timeline_path_is_the_lanes_when_it_names_one() {
        let lane = Cli::parse(
            &args(&["--timeline-out", "/tmp/haven-soak-upload/soak-timeline.log"]),
            &Env::default(),
        )
        .expect("parses");
        assert_eq!(
            lane.timeline_path(),
            PathBuf::from("/tmp/haven-soak-upload/soak-timeline.log")
        );

        let local = Cli::parse(&args(&["--seed", "7"]), &Env::default()).expect("parses");
        let path = local.timeline_path();
        assert!(
            path.to_string_lossy().contains("soak-timeline-"),
            "a local run still writes a timeline it can be reproduced from"
        );
    }

    #[test]
    fn an_unexpected_self_test_case_is_the_instrument_being_broken() {
        assert_eq!(fold_case("case", true, Rc::Clean), Rc::Clean);
        assert_eq!(fold_case("case", false, Rc::Clean), Rc::RigBroken);
        assert_eq!(
            fold_case("case", true, Rc::RigBroken),
            Rc::RigBroken,
            "a later good case never unwinds an earlier bad one"
        );
    }

    #[test]
    fn a_seed_is_accepted_in_both_spellings() {
        assert_eq!(parse_u64("0x10"), Some(16));
        assert_eq!(parse_u64("16"), Some(16));
        assert_eq!(parse_u64("0xzz"), None);
        assert_eq!(parse_u64(""), None);
    }
}
