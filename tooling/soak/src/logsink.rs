//! Capturing what the subject logs, and proving it carries no identifier.
//!
//! The rig installs a `log::Log` for the whole process, keeps every record the
//! app's own sinks would keep, and hands each scenario's lines to
//! `haven-logscan` — the same scanner, the same expander and the same rc
//! taxonomy every CI lane runs. That is the runtime half of Security Rule 15:
//! the source guards prove no line was WRITTEN with an identifier in it, and
//! this proves none reached a file.
//!
//! # The allowlist is production's, not a convenience
//!
//! `rust_builder/src/api.rs`'s `log_target_allowed` is an ALLOWLIST of Haven's
//! own crates, matched on a `::` boundary, and every shipped build routes
//! through it: a dependency's records never reach a device log. The rule is
//! mirrored here exactly, and it has to be. `openmls::ciphersuite::kdf_label`
//! logs the whole MLS group context as contiguous hex at `DEBUG` — a real MLS
//! group id, a circle name and relay URLs, 643 lines in one two-device
//! scenario — and `nostr-relay-pool` logs relay URLs at the same level. A rig
//! transcript carrying what the app silences would not be the app's log: it
//! would be a leak the rig itself created, uploaded from a lane, and reported
//! against a product that never emitted it.
//!
//! The one addition is `haven_soak` itself, so the rig's own shape plants reach
//! the capture they exist to prove the reach of.
//!
//! # One world at a time
//!
//! `cargo test` runs test functions concurrently, and a process-wide logger
//! cannot tell which world a record came from: a record arrives on whatever
//! task the engine spawned it on, carrying nothing but its target. So a capture
//! takes a process-wide lease ([`SoakLogs::acquire`]) for as long as its world
//! lives, every record is stamped with the world the lease named, and a drain
//! answers with that lease's world alone. Two worlds cannot interleave into
//! each other's evidence, because the second one waits.
//!
//! The lease is why every test that EMITS through this sink lives in
//! `tests/logsink_capture.rs` rather than below. The lease serialises leaseholders,
//! not emitters — a world built by a test that never took the lease still logs,
//! and its records would land in the leaseholder's window under the
//! leaseholder's world id. One test binary whose every world takes the lease is
//! the only arrangement in which that cannot happen, and `cargo test` gives each
//! integration target its own process.
//!
//! # The buffer is bounded, and a drop is never silent
//!
//! Records accumulate for the life of a capture window and the consumed prefix
//! is dropped when the window is drained, so a long run holds one window rather
//! than a whole transcript. Past [`CAPTURE_CAP`] records in one window the sink
//! stops capturing and counts what it refused: a truncated capture is scanned
//! as far as it goes and folds [`Rc::ProvesTooLittle`], because a capture that
//! lost lines proves less than a complete one and must never read as clean.

use std::fmt;
use std::io::Write as _;
use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard, Once, OnceLock, PoisonError};
use std::time::Duration;

use haven_logscan::manifest::{add_host_decl, Declarations, Manifest, SealInputs, SealRefusal};
use haven_logscan::plants::{mint, DeclaredPlants};
use haven_logscan::policy::Policy;
use haven_logscan::rules::RuleSet;
use haven_logscan::scan::{scan_sinks, ScanMode, SinkArg};
use haven_logscan::{worse, RC_LEAK};

use crate::rc::Rc;
use crate::rig::{sim_magnitude, CapturedLine, LogDrain, WorldId};

/// The sink class every soak capture is scanned as.
pub const SINK_CLASS: &str = "soak";

/// The root every capture is written under.
///
/// Under `/tmp/haven-soak`, which `check_wire_proxy_test_only.sh` bans WHOLLY
/// from every upload: the evidence is the one tree that may hold a value, and
/// the ban is what keeps a green run from publishing one. The uploadable tree
/// is elsewhere and holds only the banner, the timeline and the rig's stdout.
const EVIDENCE_ROOT: &str = "/tmp/haven-soak/evidence";

/// The most records one capture window keeps.
///
/// Two orders of magnitude above the largest capture this rig has produced (a
/// two-device scenario at `Debug` is hundreds of lines), so it is a backstop
/// against a pathological window rather than a routine path — a weekly run at
/// `Debug` would otherwise hold its whole transcript in memory. Past it the
/// sink refuses records and counts them, and [`scan_capture`] folds
/// [`Rc::ProvesTooLittle`] for as long as any are outstanding.
pub const CAPTURE_CAP: usize = 50_000;

/// The `log` targets the rig keeps, matched on a `::` boundary.
///
/// The first two are production's own (`rust_builder/src/api.rs`); the third is
/// this crate, whose shape plants have to reach the capture.
const OWN_TARGETS: [&str; 3] = ["haven_core", "rust_lib_haven", "haven_soak"];

/// The shape plant's emitter, as `haven-logscan`'s policy names it.
const PLANT_EMITTER: &str = "rust";

/// Whether `target` belongs to one of Haven's own crates.
///
/// Mirrors `log_target_allowed` exactly, including the `::` boundary: a crate
/// merely NAMED like one of ours (`haven_core_extra`) inherits nothing.
fn target_allowed(target: &str) -> bool {
    OWN_TARGETS.iter().any(|own| {
        target == *own
            || target
                .strip_prefix(own)
                .is_some_and(|rest| rest.starts_with("::"))
    })
}

/// Every line captured since the logger went in.
///
/// Append-only and process-wide: the logger is installed once, and a capture
/// remembers where its own window began rather than emptying a buffer another
/// capture is reading.
static CAPTURED: Mutex<Vec<CapturedLine>> = Mutex::new(Vec::new());

/// The next capture sequence number.
static NEXT_SEQ: AtomicU64 = AtomicU64::new(0);

/// Records the sink refused because the current window was at [`CAPTURE_CAP`].
///
/// Reset when a lease is taken, so one capture's losses are reported against
/// that capture and never against the next one's.
static DROPPED: AtomicU64 = AtomicU64::new(0);

/// The world records are currently attributed to, or [`UNATTRIBUTED`].
static CURRENT_WORLD: AtomicU64 = AtomicU64::new(UNATTRIBUTED);

/// No world holds the lease: a record now belongs to nobody's evidence, so it
/// is not captured at all. Keeping it would put lines from a world that has
/// already been torn down into the next world's file.
const UNATTRIBUTED: u64 = u64::MAX;

/// The process-wide capture lease.
static LEASE: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// Whether the rig's logger won the process-wide slot.
static OWNS_LOGGER: AtomicBool = AtomicBool::new(false);

/// Poison-tolerant lock: a panicking scenario must not turn every later capture
/// into a second panic that hides the first.
fn captured() -> MutexGuard<'static, Vec<CapturedLine>> {
    CAPTURED.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Why a capture could not do its job.
///
/// A classification, never a message: everything this module touches is either
/// a captured line or a declared value.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SinkError {
    /// Another logger owns the process, so this capture would see nothing at
    /// all and every assertion over it would be vacuously green.
    LoggerNotOwned,
    /// The compiled-in scanner policy would not load.
    PolicyUnreadable,
    /// A value could not be declared: the class the wrapper names is not one
    /// the policy declares, or the value is not the shape that class takes.
    DeclarationRefused,
    /// The declarations would not seal. Carries the refusal's own code so the
    /// run reports "proves too little" as itself rather than as a failure.
    SealRefused(i32),
    /// The evidence file could not be written or removed.
    EvidenceUnwritable,
    /// The scanner's rule set would not build.
    RulesUnbuildable,
    /// The OS CSPRNG would not mint a positive control.
    PlantUnmintable,
    /// The capture lease did not come inside the deadline the caller derived.
    ///
    /// A leaked handle or a second capture opened while the first still lives:
    /// either way the rig is holding its own lease, and the run has to say so
    /// rather than wait for a reaper to kill it anonymously.
    LeaseUnavailable,
}

impl SinkError {
    /// The exit verdict this error folds into.
    #[must_use]
    pub fn rc(self) -> Rc {
        match self {
            // The instrument is broken: none of these say anything about the
            // subject.
            Self::LoggerNotOwned
            | Self::PolicyUnreadable
            | Self::DeclarationRefused
            | Self::EvidenceUnwritable
            | Self::RulesUnbuildable
            | Self::PlantUnmintable
            | Self::LeaseUnavailable => Rc::RigBroken,
            Self::SealRefused(rc) => Rc::from_code(rc).unwrap_or(Rc::RigBroken),
        }
    }
}

impl fmt::Display for SinkError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::LoggerNotOwned => f.write_str("logsink: another logger owns this process"),
            Self::PolicyUnreadable => f.write_str("logsink: the scanner policy would not load"),
            Self::DeclarationRefused => f.write_str("logsink: a value could not be declared"),
            Self::SealRefused(rc) => {
                write!(f, "logsink: the declarations would not seal (rc {rc})")
            }
            Self::EvidenceUnwritable => f.write_str("logsink: the evidence file is unwritable"),
            Self::RulesUnbuildable => f.write_str("logsink: the rule set would not build"),
            Self::PlantUnmintable => f.write_str("logsink: no positive control could be minted"),
            Self::LeaseUnavailable => {
                f.write_str("logsink: the capture lease was still held at the deadline")
            }
        }
    }
}

impl std::error::Error for SinkError {}

/// The rig's `log::Log`.
struct SoakLogSink;

impl log::Log for SoakLogSink {
    fn enabled(&self, metadata: &log::Metadata<'_>) -> bool {
        target_allowed(metadata.target())
    }

    fn log(&self, record: &log::Record<'_>) {
        if !self.enabled(record.metadata()) {
            return;
        }
        let world = CURRENT_WORLD.load(Ordering::Acquire);
        if world == UNATTRIBUTED {
            return;
        }
        let mut captured = captured();
        if captured.len() >= CAPTURE_CAP {
            // Counted, never silent: the scan folds a verdict on this, because
            // a capture that lost lines cannot certify that nothing leaked in
            // the ones it lost.
            DROPPED.fetch_add(1, Ordering::Relaxed);
            return;
        }
        let seq = NEXT_SEQ.fetch_add(1, Ordering::Relaxed);
        captured.push(CapturedLine {
            seq,
            world: WorldId::new(world),
            level: record.level(),
            target: record.target().to_owned(),
            text: record.args().to_string(),
        });
    }

    fn flush(&self) {}
}

/// A held capture lease. Dropping it stops attribution and lets the next world
/// take the lease.
struct Lease {
    _guard: tokio::sync::MutexGuard<'static, ()>,
    /// The world this lease named, so a drain answers with that world's lines
    /// and no other's.
    world: AtomicU64,
}

impl Drop for Lease {
    fn drop(&mut self) {
        CURRENT_WORLD.store(UNATTRIBUTED, Ordering::Release);
    }
}

/// The capture, as a handle a world can own and a runner can still read.
///
/// Cloneable because the world takes one (it is the world's [`LogDrain`]) while
/// the scenario runner keeps another to name the world and to read the window
/// back. The lease is released when the last clone goes.
#[derive(Clone)]
pub struct SoakLogs {
    // Shared by every clone, which is what makes a drain answer with the world
    // THIS capture named. Dropping the last clone stops attribution and lets
    // the next world take the lease.
    lease: std::sync::Arc<Lease>,
}

// Presence-only: everything a capture holds is the subject's own text.
impl fmt::Debug for SoakLogs {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("SoakLogs(held)")
    }
}

impl SoakLogs {
    /// Installs the logger (once per process) and takes the capture lease.
    ///
    /// Waits for the previous world's lease rather than interleaving with it.
    ///
    /// # Errors
    ///
    /// [`SinkError::LoggerNotOwned`] if another logger won the process-wide
    /// slot: `log` permits exactly one and reports the loser only through an
    /// `Err` a `let _ =` throws away, so the verdict of the FIRST install is
    /// recorded and asserted here instead. [`SinkError::LeaseUnavailable`] if
    /// the lease is still held at `within` — the rig holding its own lease is
    /// the rig being broken, and it folds to that verdict rather than hanging.
    pub async fn acquire(within: Duration) -> Result<Self, SinkError> {
        static INSTALL: Once = Once::new();
        INSTALL.call_once(|| {
            OWNS_LOGGER.store(
                log::set_boxed_logger(Box::new(SoakLogSink)).is_ok(),
                Ordering::SeqCst,
            );
            // The noisiest level any SHIPPED build emits: production's own
            // filter is Debug in a debug build and Warn in a release one, and
            // nothing shipped enables Trace. Capturing exactly that means the
            // evidence holds every line a user's device could hold.
            log::set_max_level(log::LevelFilter::Debug);
        });
        if !OWNS_LOGGER.load(Ordering::SeqCst) {
            return Err(SinkError::LoggerNotOwned);
        }
        // Bounded, because the one thing a harness may not do is hang: a leaked
        // handle or a second capture opened while the first lives would
        // otherwise wait for a reaper, and a reaper reports a timeout rather
        // than a verdict. The caller derives `within` — the driver from its run
        // deadline, a test from the bound its arm is entitled to.
        let Ok(guard) = tokio::time::timeout(within, LEASE.lock()).await else {
            return Err(SinkError::LeaseUnavailable);
        };
        // The previous capture has been scanned and reported by now, so its
        // losses belong to it and not to this one.
        DROPPED.store(0, Ordering::Relaxed);
        Ok(Self {
            lease: std::sync::Arc::new(Lease {
                _guard: guard,
                world: AtomicU64::new(UNATTRIBUTED),
            }),
        })
    }

    /// Attributes every later record to `world`, and answers every later drain
    /// with that world's lines.
    ///
    /// Called once the world exists, because a world mints its own handle when
    /// it is built.
    pub fn attribute_to(&self, world: WorldId) {
        self.lease.world.store(world.ordinal(), Ordering::Release);
        CURRENT_WORLD.store(world.ordinal(), Ordering::Release);
    }

    /// Records this capture lost because its window was at [`CAPTURE_CAP`].
    #[must_use]
    #[allow(clippy::unused_self)] // The counter is process-wide; the lease is what scopes it.
    pub fn dropped(&self) -> u64 {
        DROPPED.load(Ordering::Relaxed)
    }

    /// The next sequence number — the start of a window a caller is about to
    /// open.
    #[must_use]
    #[allow(clippy::unused_self)] // The counter is process-wide; the lease is what makes reading it meaningful.
    pub fn mark(&self) -> u64 {
        NEXT_SEQ.load(Ordering::Relaxed)
    }
}

impl LogDrain for SoakLogs {
    /// This lease's world's lines since `from`, and the end of the consumed
    /// prefix.
    ///
    /// Two properties, both load-bearing. The world filter is attribution: a
    /// record carries whatever world last held the lease, and a drain that
    /// answered with all of them would hand one capture another's lines.
    /// Dropping everything below `from` is what keeps a long run holding one
    /// window instead of a whole transcript — `mark()` only ever moves forward,
    /// so nothing that is dropped can be asked for again.
    fn drain_since(&self, from: u64) -> Vec<CapturedLine> {
        let world = WorldId::new(self.lease.world.load(Ordering::Acquire));
        let mut captured = captured();
        captured.retain(|line| line.seq >= from);
        captured
            .iter()
            .filter(|line| line.world == world)
            .cloned()
            .collect()
    }
}

/// Mints one `rust` shape plant and emits it THROUGH the installed sink.
///
/// Through the sink deliberately: a token written straight into the evidence
/// file would prove only that the rig can write a file, which is not what a
/// positive control is for. Emitted as `log::info!`, it proves the log backend
/// reached the capture — the one failure mode (a wrong path, an uninstalled
/// logger, a dead capture) that otherwise reads exactly like a clean run.
///
/// # Errors
///
/// [`SinkError::PlantUnmintable`] if the OS CSPRNG is unavailable. There is no
/// fallback: a guessable control would let one scenario's capture satisfy
/// another's.
pub fn plant(phase: &str) -> Result<String, SinkError> {
    let token = mint(PLANT_EMITTER, phase).map_err(|_| SinkError::PlantUnmintable)?;
    log::info!("{token}");
    Ok(token)
}

/// Every value the rig minted, declared through typed wrappers.
///
/// The class is never a caller's string. `add_host_decl` decides whether a
/// value's raw encodings are searchable from the class name alone, so one
/// mixed-up string would expand a private key into the manifest's own terms —
/// which is the one file in the tree more sensitive than a wire journal. Each
/// wrapper below passes a `const`, and [`Declarations`] is never built
/// field-by-field.
pub struct Needles {
    policy: Policy,
    declarations: Declarations,
    ids: usize,
}

/// The needle class of a device's secret key.
const CLASS_SECRET_KEY: &str = "nsec";
/// The needle class of a public key.
const CLASS_PUBKEY: &str = "pubkey";
/// The needle class of a real MLS group id (Security Rule 4).
const CLASS_MLS_GROUP_ID: &str = "mls_group_id";
/// The needle class of the `#h` routing tag.
const CLASS_NOSTR_GROUP_ID: &str = "nostr_group_id";
/// The needle class of a circle's name.
const CLASS_CIRCLE_NAME: &str = "circle_name";
/// The needle class of a local display-name override.
const CLASS_PETNAME: &str = "petname";
/// The needle class of a relay endpoint.
const CLASS_RELAY_URL: &str = "relay_url";
/// The needle class of an event id.
const CLASS_EVENT_ID: &str = "event_id";
/// The needle class of a latitude/longitude pair.
const CLASS_COORDINATE: &str = "coordinate";

impl Needles {
    /// An empty declaration set under the compiled-in policy.
    ///
    /// # Errors
    ///
    /// [`SinkError::PolicyUnreadable`] if the compiled-in policy will not load.
    pub fn new() -> Result<Self, SinkError> {
        Ok(Self {
            policy: Policy::load().map_err(|_| SinkError::PolicyUnreadable)?,
            declarations: Declarations::default(),
            ids: 0,
        })
    }

    /// Declares one value of `class`.
    fn declare(&mut self, class: &'static str, value: &str) -> Result<(), SinkError> {
        add_host_decl(
            &self.policy,
            class,
            value,
            &mut self.ids,
            &mut self.declarations,
        )
        .map_err(|_| SinkError::DeclarationRefused)
    }

    /// Declares a device's secret key. Committed, never serialised.
    ///
    /// # Errors
    ///
    /// [`SinkError::DeclarationRefused`] if the value is not the shape the class
    /// takes.
    pub fn declare_secret_key(&mut self, hex: &str) -> Result<(), SinkError> {
        self.declare(CLASS_SECRET_KEY, hex)
    }

    /// Declares a public key.
    ///
    /// # Errors
    ///
    /// As [`Self::declare_secret_key`].
    pub fn declare_pubkey(&mut self, hex: &str) -> Result<(), SinkError> {
        self.declare(CLASS_PUBKEY, hex)
    }

    /// Declares a real MLS group id.
    ///
    /// # Errors
    ///
    /// As [`Self::declare_secret_key`].
    pub fn declare_mls_group_id(&mut self, hex: &str) -> Result<(), SinkError> {
        self.declare(CLASS_MLS_GROUP_ID, hex)
    }

    /// Declares a `nostr_group_id`.
    ///
    /// # Errors
    ///
    /// As [`Self::declare_secret_key`].
    pub fn declare_nostr_group_id(&mut self, hex: &str) -> Result<(), SinkError> {
        self.declare(CLASS_NOSTR_GROUP_ID, hex)
    }

    /// Declares a circle name.
    ///
    /// # Errors
    ///
    /// As [`Self::declare_secret_key`].
    pub fn declare_circle_name(&mut self, name: &str) -> Result<(), SinkError> {
        self.declare(CLASS_CIRCLE_NAME, name)
    }

    /// Declares a petname.
    ///
    /// # Errors
    ///
    /// As [`Self::declare_secret_key`].
    pub fn declare_petname(&mut self, name: &str) -> Result<(), SinkError> {
        self.declare(CLASS_PETNAME, name)
    }

    /// Declares a relay endpoint.
    ///
    /// # Errors
    ///
    /// As [`Self::declare_secret_key`].
    pub fn declare_relay_url(&mut self, url: &str) -> Result<(), SinkError> {
        self.declare(CLASS_RELAY_URL, url)
    }

    /// Declares an event id.
    ///
    /// # Errors
    ///
    /// As [`Self::declare_secret_key`].
    pub fn declare_event_id(&mut self, hex: &str) -> Result<(), SinkError> {
        self.declare(CLASS_EVENT_ID, hex)
    }

    /// Declares a probe coordinate.
    ///
    /// # Errors
    ///
    /// As [`Self::declare_secret_key`].
    pub fn declare_coordinate(&mut self, lat: f64, lon: f64) -> Result<(), SinkError> {
        // The spelling the class takes, minted here rather than by a caller:
        // `lat,lon` in decimal degrees is what the expander's ladder decodes.
        self.declare(CLASS_COORDINATE, &format!("{lat},{lon}"))
    }

    /// Seals every declaration into a manifest, in memory.
    ///
    /// Nothing is written: the manifest holds every value the run minted, and
    /// only CI — which has a reader for it and a landed guard that removes it —
    /// asks for it on disk.
    ///
    /// # Errors
    ///
    /// [`SinkError::SealRefused`] carrying the refusal's own code.
    pub fn seal(&self, run_id: &str) -> Result<Manifest, SinkError> {
        let inputs = SealInputs {
            run_id: run_id.to_owned(),
            // The rig is a Rust process with no Dart channel at all, so there is
            // nothing that could hand it a declared token to print. Its `rust`
            // shape plant is what proves sink reach.
            declared_plants: DeclaredPlants::None,
            ..SealInputs::default()
        };
        haven_logscan::manifest::seal_from_declarations(&self.policy, &self.declarations, &inputs)
            .map_err(|refusal: SealRefusal| SinkError::SealRefused(refusal.rc))
    }
}

/// What one scenario's scan concluded. Classes and `capture:line` only.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScanReport {
    /// The folded verdict.
    pub rc: Rc,
    /// One value-free sentence per finding, in scan order.
    pub findings: Vec<String>,
    /// Whether the evidence file was removed because it held a declared value.
    pub contained: bool,
}

/// Writes one scenario's captured lines and scans them.
///
/// The evidence file lives under the upload-banned tree and is scanned in
/// place. What becomes of it afterwards is the verdict's:
///
/// * **clean** — removed. A run that proved nothing leaked has no reason to
///   leave the subject's own lines on a disk somebody else can read;
/// * **leak** — removed, and reported as contained. A file that might carry a
///   needle is cheap to lose and expensive to publish;
/// * **anything else** — kept. An unusable or too-thin capture is diagnosed by
///   reading it, and it is the one case where the lines are the evidence.
///
/// # Errors
///
/// [`SinkError::EvidenceUnwritable`] if the file cannot be written or removed,
/// [`SinkError::RulesUnbuildable`] if the structural rules will not compile.
pub fn scan_capture(
    scenario: &str,
    lines: &[CapturedLine],
    manifest: &Manifest,
) -> Result<ScanReport, SinkError> {
    let path = write_evidence(scenario, lines)?;
    let rules = RuleSet::new(
        manifest.base64_entropy_bits,
        now_unix(),
        &manifest.exempt_endpoints,
        Vec::new(),
    )
    .map_err(|_| SinkError::RulesUnbuildable)?;
    let outcome = scan_sinks(
        manifest,
        &[SinkArg {
            class: SINK_CLASS.to_owned(),
            paths: vec![path.clone()],
        }],
        &std::collections::BTreeMap::new(),
        &std::collections::BTreeMap::new(),
        &rules,
        false,
        ScanMode::Full,
    );

    let mut rc = outcome.rc();
    for problem in &outcome.problems {
        rc = worse(rc, problem.rc);
    }
    // Class, encoding, rule and `capture:line` — never the matched text, which
    // is the value the finding exists to say nothing about, and never the PATH:
    // the evidence directory is minted per process, so its name is neither
    // reproducible nor anybody's business, and a problem's own sentence
    // interpolates both it and an exact line count.
    let mut findings: Vec<String> = outcome
        .findings
        .iter()
        .map(|finding| {
            format!(
                "{scenario}:{} class={} encoding={} rule={}",
                finding.line,
                finding.class.as_deref().unwrap_or("-"),
                finding.encoding.as_deref().unwrap_or("-"),
                finding.rule.as_deref().unwrap_or("-"),
            )
        })
        .chain(outcome.problems.iter().map(|problem| {
            let named = Rc::from_code(problem.rc).map_or("unclassified", Rc::name);
            format!("{scenario}: problem verdict={named}")
        }))
        .collect();

    // A capture the sink truncated is scanned as far as it goes and says so:
    // nothing it concluded covers the records it never held.
    let dropped = DROPPED.load(Ordering::Relaxed);
    if dropped > 0 {
        let magnitude = sim_magnitude(usize::try_from(dropped).unwrap_or(usize::MAX));
        findings.push(format!(
            "{scenario}: capture truncated, dropped={magnitude}"
        ));
        rc = worse(rc, haven_logscan::RC_META);
    }

    let contained = rc == RC_LEAK;
    if contained || rc == haven_logscan::RC_CLEAN {
        std::fs::remove_file(&path).map_err(|_| SinkError::EvidenceUnwritable)?;
    }
    Ok(ScanReport {
        rc: Rc::from_code(rc).unwrap_or(Rc::RigBroken),
        findings,
        contained,
    })
}

/// This process's evidence directory, created on first use.
///
/// Per process, because the path was fixed and two soak binaries on one runner
/// wrote each other's scenarios; and never rotated into, because a name minted
/// here is the only thing that keeps a previous run's captures out of this
/// run's scan. The name is never printed: it is a path, and the findings above
/// carry the capture's LABEL instead.
///
/// # Errors
///
/// [`SinkError::EvidenceUnwritable`] if the root will not take the same
/// discipline the needle directory takes, or the directory cannot be created.
fn evidence_dir() -> Result<&'static Path, SinkError> {
    static DIR: OnceLock<Option<PathBuf>> = OnceLock::new();
    DIR.get_or_init(|| mint_evidence_dir().ok())
        .as_deref()
        .ok_or(SinkError::EvidenceUnwritable)
}

/// Creates the per-process directory under a root that passed the four checks
/// `haven_logscan::manifest`'s own `ensure_dir_chain` applies.
///
/// The checks are duplicated rather than imported because that function is
/// private to the needle path and says "needle directory" in every refusal;
/// what matters is that this tree gets the same discipline, since `/tmp` is
/// world-writable and both trees hold the subject's own text.
fn mint_evidence_dir() -> Result<PathBuf, SinkError> {
    let root = Path::new(EVIDENCE_ROOT);
    // A symlinked PARENT is as good as a symlinked directory — the lines land
    // wherever the link points — and `create_dir_all` follows it happily.
    // Checked before creating, because afterwards it is too late.
    if let Some(parent) = root.parent() {
        if std::fs::symlink_metadata(parent).is_ok_and(|meta| meta.file_type().is_symlink()) {
            return Err(SinkError::EvidenceUnwritable);
        }
    }
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(root)
        .map_err(|_| SinkError::EvidenceUnwritable)?;
    let meta = std::fs::symlink_metadata(root).map_err(|_| SinkError::EvidenceUnwritable)?;
    if meta.file_type().is_symlink() || !meta.is_dir() {
        return Err(SinkError::EvidenceUnwritable);
    }
    if std::os::unix::fs::PermissionsExt::mode(&meta.permissions()) & 0o777 != 0o700 {
        return Err(SinkError::EvidenceUnwritable);
    }
    // `create` is not recursive here, so a name that already exists — another
    // process's directory, or something planted — is refused rather than
    // shared.
    let mine = root.join(format!(
        "run-{}-{:016x}",
        std::process::id(),
        rand::random::<u64>()
    ));
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(&mine)
        .map_err(|_| SinkError::EvidenceUnwritable)?;
    Ok(mine)
}

/// Writes `lines` to this scenario's evidence file and returns its path.
///
/// `0600` and truncating: the file holds whatever the subject logged, and the
/// directory it lands in was created by this process at `0700`, so nothing
/// could have planted a symlink for the open to follow.
fn write_evidence(scenario: &str, lines: &[CapturedLine]) -> Result<PathBuf, SinkError> {
    let path = evidence_dir()?.join(format!("{scenario}.log"));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&path)
        .map_err(|_| SinkError::EvidenceUnwritable)?;
    for line in lines {
        // Level and target beside the text, because a finding's own report says
        // `capture:line` and a reader needs to know which component wrote it.
        writeln!(file, "{} {} {}", line.level, line.target, line.text)
            .map_err(|_| SinkError::EvidenceUnwritable)?;
    }
    Ok(path)
}

/// Whether `scenario`'s evidence file is still on disk.
///
/// A predicate rather than the path, deliberately: the only question anything
/// outside this module asks is whether a capture was discarded, and a path
/// handed out is a path something eventually prints.
#[must_use]
pub fn evidence_exists(scenario: &str) -> bool {
    evidence_dir().is_ok_and(|dir| dir.join(format!("{scenario}.log")).exists())
}

/// Writes a sealed manifest to `path`.
///
/// Only CI asks for this. The path discipline — the directory, the mode, the
/// `O_EXCL` — is the scanner's own and is not re-implemented here.
///
/// # Errors
///
/// [`SinkError::EvidenceUnwritable`] if the path is refused or already taken.
pub fn write_sealed_manifest(path: &Path, manifest: &Manifest) -> Result<(), SinkError> {
    haven_logscan::manifest::write_manifest(path, manifest)
        .map_err(|_| SinkError::EvidenceUnwritable)
}

/// Unix seconds, for the rule set's own expiry arithmetic.
fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

/// Everything that EMITS through the sink is in `tests/logsink_capture.rs`, for
/// the reason the module docs give: the lease serialises leaseholders, not
/// emitters, so a capture is only attributable in a binary where every world
/// takes the lease. What is left here needs no capture at all.
#[cfg(test)]
mod tests {
    use super::{target_allowed, Needles, SinkError};
    use crate::rc::Rc;

    /// A needle-shaped value nothing in the tree should ever log.
    const NEEDLE_HEX: &str = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08";

    #[test]
    fn the_allowlist_is_productions_and_ends_on_a_module_boundary() {
        assert!(target_allowed("haven_core"));
        assert!(target_allowed("haven_core::relay::live_sync::session"));
        assert!(target_allowed("rust_lib_haven::api"));
        assert!(target_allowed("haven_soak::scenarios::s01"));
        // The records that make this a rule rather than a preference: OpenMLS
        // logs the whole group context as contiguous hex at DEBUG, and the pool
        // logs relay URLs.
        assert!(!target_allowed("openmls::ciphersuite"));
        assert!(!target_allowed("nostr_relay_pool::relay::inner"));
        assert!(!target_allowed("tungstenite"));
        // A crate merely NAMED like one of ours inherits nothing.
        assert!(!target_allowed("haven_core_extra"));
        assert!(!target_allowed("haven_soakier"));
    }

    #[test]
    fn a_secret_declared_through_the_wrapper_is_committed_and_never_serialised() {
        let mut needles = Needles::new().expect("policy");
        needles
            .declare_secret_key(NEEDLE_HEX)
            .expect("declare a secret");
        needles
            .declare_pubkey("3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d")
            .expect("declare a pubkey");
        let manifest = needles.seal("logsink-secret").expect("seal");
        let entry = manifest
            .values
            .iter()
            .find(|value| value.class == "nsec")
            .expect("the secret is recorded");
        assert!(entry.raw_withheld, "a secret's raw value was not withheld");
        let serialised = serde_json::to_string(&manifest).expect("serialises");
        assert!(
            !serialised.contains(NEEDLE_HEX),
            "a secret's raw encoding reached the manifest"
        );
        assert!(
            !manifest.terms.iter().any(|term| term.text == NEEDLE_HEX),
            "a secret's raw encoding became a searchable term"
        );
    }

    #[test]
    fn every_wrapper_declares_the_class_it_names() {
        let mut needles = Needles::new().expect("policy");
        needles.declare_secret_key(NEEDLE_HEX).expect("nsec");
        needles.declare_pubkey(NEEDLE_HEX).expect("pubkey");
        needles.declare_mls_group_id(NEEDLE_HEX).expect("mls");
        needles.declare_nostr_group_id(NEEDLE_HEX).expect("nostr");
        needles.declare_circle_name("Saturday Ride").expect("name");
        needles.declare_petname("Bee").expect("petname");
        needles
            .declare_relay_url("ws://127.0.0.1:7777")
            .expect("relay");
        needles.declare_event_id(NEEDLE_HEX).expect("event id");
        needles.declare_coordinate(48.85, 2.35).expect("coordinate");

        let manifest = needles.seal("logsink-classes").expect("seal");
        let classes: Vec<&str> = manifest
            .values
            .iter()
            .map(|value| value.class.as_str())
            .collect();
        for class in [
            "nsec",
            "pubkey",
            "mls_group_id",
            "nostr_group_id",
            "circle_name",
            "petname",
            "relay_url",
            "event_id",
            "coordinate",
        ] {
            assert!(classes.contains(&class), "no wrapper declared {class}");
        }
    }

    #[test]
    fn a_coordinate_is_declared_in_the_spelling_the_class_takes() {
        let mut needles = Needles::new().expect("policy");
        // The wrapper mints `lat,lon`; a caller that had to spell it would be a
        // caller that could spell it wrong, and the class would refuse it.
        assert!(needles.declare_coordinate(-33.86, 151.21).is_ok());
    }

    #[test]
    fn a_seal_with_nothing_declared_proves_too_little_rather_than_passing() {
        let needles = Needles::new().expect("policy");
        let refused = needles.seal("logsink-nothing").expect_err("refused");
        assert!(
            refused.rc() == Rc::ProvesTooLittle,
            "a manifest that searches for nothing cannot certify a capture"
        );
        assert!(!refused.to_string().is_empty());
    }

    #[test]
    fn every_sink_error_renders_a_classification_and_no_value() {
        for error in [
            SinkError::LoggerNotOwned,
            SinkError::PolicyUnreadable,
            SinkError::DeclarationRefused,
            SinkError::SealRefused(4),
            SinkError::EvidenceUnwritable,
            SinkError::RulesUnbuildable,
            SinkError::PlantUnmintable,
            SinkError::LeaseUnavailable,
        ] {
            let rendered = error.to_string();
            assert!(rendered.starts_with("logsink: "), "{rendered}");
            assert!(!rendered.contains('/'), "{rendered}");
        }
        assert!(SinkError::LoggerNotOwned.rc() == Rc::RigBroken);
        assert!(SinkError::SealRefused(4).rc() == Rc::ProvesTooLittle);
    }
}
