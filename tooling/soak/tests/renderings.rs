//! Every `Debug` and `Display` this crate defines, enumerated from source and
//! rendered on a real value.
//!
//! A rendering is the easiest way for an identifier to escape: a derived
//! `Debug` prints every field (which is how [`Schedule`]'s printed a raw 32-byte
//! digest), and a hand-written one prints what its author chose. The crate's
//! per-module tests already assert the renderings their authors thought about;
//! what this file adds is the ENUMERATION — the population is read from the
//! source on every run, so a type that gains a rendering and no sample reds
//! this test rather than waiting for a reviewer to notice.
//!
//! In the spirit of `scripts/ci/check_debug_impls_covered.sh`, which does the
//! same for haven-core and its 73 hand-written impls; the difference is that
//! derives are in scope here, because a derive is exactly what printed the
//! digest.
//!
//! # `src/main.rs` is out of scope, and why
//!
//! It is the BINARY's source: nothing in it is reachable from an integration
//! test, so a row for `Cli` could carry no rendering. Its four types are
//! covered where they live (`an_invocations_debug_renders_no_path` and the
//! plan-line test beside it), and the exclusion is asserted below rather than
//! left implicit.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

/// The crate's own source root.
fn src_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("src")
}

/// Every `.rs` file under `src`, except the binary's.
fn sources() -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![src_root()];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir).expect("the crate's own source is readable") {
            let path = entry.expect("a directory entry").path();
            if path.is_dir() {
                stack.push(path);
            } else if path.extension().is_some_and(|ext| ext == "rs")
                && path.file_name().is_some_and(|name| name != "main.rs")
            {
                out.push(path);
            }
        }
    }
    out.sort();
    out
}

/// `rig/world.rs::TickReport` — the file as well as the name, because two
/// modules define a `Verdict` and they are two different renderings.
fn key(file: &Path, name: &str) -> String {
    let relative = file
        .strip_prefix(src_root())
        .expect("every source is under src");
    format!("{}::{name}", relative.display())
}

/// Logical lines: a `#[derive(…)]` split over several physical lines is one.
fn logical_lines(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut pending: Option<String> = None;
    for raw in text.lines() {
        if let Some(mut open) = pending.take() {
            open.push(' ');
            open.push_str(raw.trim());
            if open.contains(")]") {
                out.push(open);
            } else {
                pending = Some(open);
            }
            continue;
        }
        let trimmed = raw.trim();
        if trimmed.starts_with("#[derive(") && !trimmed.contains(")]") {
            pending = Some(trimmed.to_owned());
        } else {
            out.push(trimmed.to_owned());
        }
    }
    if let Some(open) = pending {
        out.push(open);
    }
    out
}

/// The type name a PUBLIC item line declares, if it declares one.
///
/// Public only. A private type's rendering can leave this crate solely through
/// a public one that contains it — and that public one is in the population
/// with a sample of its own — while a row for a private type could carry no
/// sample at all, because an integration test cannot name it.
fn declared_name(line: &str) -> Option<&str> {
    let rest = line.strip_prefix("pub ")?.trim_start();
    for keyword in ["struct ", "enum ", "union "] {
        if let Some(tail) = rest.strip_prefix(keyword) {
            let name: &str = tail
                .split(|c: char| !(c.is_alphanumeric() || c == '_'))
                .next()
                .unwrap_or_default();
            if !name.is_empty() {
                return Some(name);
            }
        }
    }
    None
}

/// The type an `impl … Debug/Display for …` line names, if it is one.
fn implemented_name(line: &str) -> Option<&str> {
    if !line.starts_with("impl") {
        return None;
    }
    if !(line.contains("fmt::Debug for") || line.contains("fmt::Display for")) {
        return None;
    }
    let tail = line.split(" for ").nth(1)?;
    let name: &str = tail
        .split(|c: char| !(c.is_alphanumeric() || c == '_'))
        .next()
        .unwrap_or_default();
    (!name.is_empty()).then_some(name)
}

/// Every type in `src` (the binary aside) with a `Debug` or `Display`
/// rendering, derived or hand-written.
fn population() -> BTreeSet<String> {
    let mut found = BTreeSet::new();
    for file in sources() {
        let text = std::fs::read_to_string(&file).expect("a source file reads");
        let lines = logical_lines(&text);
        // Every public type this file declares, so an `impl … for X` over a
        // private one is skipped for the reason `declared_name` gives.
        let public: BTreeSet<&str> = lines
            .iter()
            .filter_map(|line| declared_name(line))
            .collect();
        let mut derived_debug = false;
        let mut in_handle_macro = false;
        for line in &lines {
            if in_handle_macro {
                // The handle macro's own shape: doc comments, then the name.
                if line.is_empty() || line.starts_with("//") {
                    continue;
                }
                let name = line.trim_end_matches(',');
                if !name.is_empty() {
                    found.insert(key(&file, name));
                }
                in_handle_macro = false;
                continue;
            }
            if line.starts_with("sim_handle!(") {
                in_handle_macro = true;
                continue;
            }
            if line.starts_with("#[derive(") {
                derived_debug = line.contains("Debug");
                continue;
            }
            if let Some(name) = implemented_name(line) {
                if public.contains(name) {
                    found.insert(key(&file, name));
                }
                continue;
            }
            if let Some(name) = declared_name(line) {
                if derived_debug {
                    found.insert(key(&file, name));
                }
                derived_debug = false;
                continue;
            }
            // A doc comment or another attribute may sit between the derive and
            // the item; anything else ends the association.
            if !(line.is_empty() || line.starts_with("//") || line.starts_with("#[")) {
                derived_debug = false;
            }
        }
    }
    found
}

// ---------------------------------------------------------------------------
// The samples
// ---------------------------------------------------------------------------

/// A needle nothing this crate renders may carry: 64 hex, the shape of a
/// pubkey, an event id and an MLS group id at once.
const NEEDLE_HEX: &str = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08";
/// A needle-shaped endpoint.
const NEEDLE_URL: &str = "ws://198.51.100.7:7777";
/// A needle-shaped circle name.
const NEEDLE_NAME: &str = "Saturday Ride";
/// A magnitude of the world's BEHAVIOUR, which no rendering may print exactly.
/// Distinctive on purpose: a bucketed field renders `5+`, and this is what a
/// field that forgot to bucket prints instead.
///
/// Planted only where a field counts what a world DID. A declared floor, a
/// profile's shape and an arm's withheld-ack count are configuration checked
/// into this repository — the same class of fact as the profile name — and
/// they are held to the other shapes below rather than to this one.
const NEEDLE_COUNT: usize = 7919;
/// The same magnitude where the field is a `u64`.
const NEEDLE_COUNT_U64: u64 = 7919;
/// The same magnitude, as it would render.
const NEEDLE_COUNT_TEXT: &str = "7919";

/// Adds one rendering to the table.
fn add(into: &mut BTreeMap<String, Vec<String>>, key: &str, rendered: String) {
    into.entry(key.to_owned()).or_default().push(rendered);
}

/// Every rendering of every type in a module that needs no world.
///
/// One long function on purpose: a row per type IS the table, and splitting it
/// into arbitrary halves would only make a missing row harder to see.
#[allow(clippy::too_many_lines)]
fn static_samples() -> BTreeMap<String, Vec<String>> {
    use haven_soak::banner::{Banner, Measured, Provenance};
    use haven_soak::clock::{ClockError, PolicyNow, WallNow};
    use haven_soak::driver::Refusal;
    use haven_soak::logsink::{ScanReport, SinkError};
    use haven_soak::nemesis::types::{ClosedPrefix, DeviceOp, Fault, Op, Schedule, ScheduledOp};
    use haven_soak::oracle::bounds::{BoundDefect, Recovery, WaitScale};
    use haven_soak::oracle::quiescence::{PendingReason, Quiescence, Settled, StabilityWindow};
    use haven_soak::oracle::undecryptable::{self, Cause, Probe, StoredRow};
    use haven_soak::oracle::vacuity::{ExpectationFloor, FloorTerm, Observed};
    use haven_soak::oracle::{Finding, Invariant, ProbeToken, Reach, Round, Verdict};
    use haven_soak::profiles::{
        ProfileError, ProfileName, ProfileSpec, ScenarioSelection, WorldShape,
    };
    use haven_soak::rc::{Rc, Verdicts};
    use haven_soak::relay::NativeClosed;
    use haven_soak::rig::{
        CapturedLine, CircleTag, DeviceTag, EventTag, KillKind, PublishVerdict, RelayTag,
        ReopenReport, RigError, SimKind, Step, TimelineRecord, Wait, WorldId,
    };
    use haven_soak::scenarios::{Absence, ScenarioReport, WithheldAcks};
    use haven_soak::timeline::{read_lines, Snapshot, Timeline};
    use std::time::Duration;

    let mut out: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let device = DeviceTag::new(3);
    let circle = CircleTag::new(2);
    let relay = RelayTag::new(1);

    // banner.rs
    let provenance = Provenance::new(Some("bb310e2f4a9c"), Some("1.97.1"));
    let banner = Banner::new(ProfileName::Pr, 0x5eed, "a1b2c3d4", provenance.clone());
    add(&mut out, "banner.rs::Banner", format!("{banner:?}"));
    add(&mut out, "banner.rs::Banner", banner.to_string());
    add(&mut out, "banner.rs::Provenance", format!("{provenance:?}"));
    let measured = Measured {
        wall: Duration::from_secs(271),
        peak_rss_mib: Some(412),
    };
    add(&mut out, "banner.rs::Measured", format!("{measured:?}"));

    // clock.rs
    add(
        &mut out,
        "clock.rs::ClockError",
        format!("{:?} {}", ClockError::BeforeEpoch, ClockError::BeforeEpoch),
    );
    let wall = WallNow::from_secs(1_764_500_000);
    add(&mut out, "clock.rs::WallNow", format!("{wall:?}"));
    add(
        &mut out,
        "clock.rs::PolicyNow",
        format!(
            "{:?}",
            PolicyNow::from_wall_with_offset(wall, 288).expect("a policy instant")
        ),
    );

    // driver.rs
    for refusal in [
        Refusal::Rig(RigError::WelcomeNeverAcked),
        Refusal::Sink(SinkError::EvidenceUnwritable),
        Refusal::Artifact,
    ] {
        add(
            &mut out,
            "driver.rs::Refusal",
            format!("{refusal:?} {refusal}"),
        );
    }

    // logsink.rs
    add(
        &mut out,
        "logsink.rs::ScanReport",
        format!(
            "{:?}",
            ScanReport {
                rc: Rc::ViolationOrLeak,
                findings: vec!["s01-outage:12 class=pubkey encoding=hex-lower rule=-".to_owned()],
                contained: true,
            }
        ),
    );
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
        add(
            &mut out,
            "logsink.rs::SinkError",
            format!("{error:?} {error}"),
        );
    }

    // nemesis/types.rs
    for prefix in ClosedPrefix::ALL {
        add(
            &mut out,
            "nemesis/types.rs::ClosedPrefix",
            format!("{prefix:?}"),
        );
    }
    for fault in [
        Fault::Down,
        Fault::Up,
        Fault::WipeStore,
        Fault::Closed(ClosedPrefix::RateLimited),
        Fault::Notice("the harness is holding this relay"),
        Fault::SwallowOk,
        Fault::DoubleEveryEvent,
        Fault::ReversePages,
        Fault::EoseForAnotherSubscription,
        Fault::Heal,
    ] {
        add(&mut out, "nemesis/types.rs::Fault", format!("{fault:?}"));
    }
    for op in [
        DeviceOp::Restart(KillKind::Soft),
        DeviceOp::Restart(KillKind::Hard),
        DeviceOp::GoOffline,
        DeviceOp::ComeOnline,
        DeviceOp::StepPolicyOffset { secs: 288 },
    ] {
        add(&mut out, "nemesis/types.rs::DeviceOp", format!("{op:?}"));
        add(
            &mut out,
            "nemesis/types.rs::Op",
            format!("{:?}", Op::Device { device, op }),
        );
    }
    add(
        &mut out,
        "nemesis/types.rs::Op",
        format!(
            "{:?} {:?}",
            Op::Probe,
            Op::Fault {
                relay,
                fault: Fault::Down
            }
        ),
    );
    let scheduled = ScheduledOp {
        tick: 4,
        op: Op::Probe,
        heal_at: Some(9),
    };
    add(
        &mut out,
        "nemesis/types.rs::ScheduledOp",
        format!("{scheduled:?}"),
    );
    let schedule = Schedule::new(vec![scheduled]);
    add(
        &mut out,
        "nemesis/types.rs::Schedule",
        format!("{schedule:?} {schedule}"),
    );

    // oracle/bounds.rs
    for defect in [
        BoundDefect::SubscribeLadder,
        BoundDefect::ThrottledBackoff,
        BoundDefect::Settle,
        BoundDefect::SilenceWindow,
        BoundDefect::UnresolvableInputMaxAge,
        BoundDefect::BurstBacklogWait,
    ] {
        add(
            &mut out,
            "oracle/bounds.rs::BoundDefect",
            format!("{defect:?}"),
        );
    }
    for recovery in [
        Recovery::Undisturbed,
        Recovery::Reconnect,
        Recovery::Throttled,
    ] {
        add(
            &mut out,
            "oracle/bounds.rs::Recovery",
            format!("{recovery:?}"),
        );
    }
    add(
        &mut out,
        "oracle/bounds.rs::WaitScale",
        format!("{:?}", WaitScale::new(4).expect("a whole scale")),
    );

    // oracle/mod.rs
    for finding in [
        Finding::ProbeNotPublished { device, circle },
        Finding::ProbeNotDelivered {
            from: device,
            to: DeviceTag::new(1),
            circle,
        },
    ] {
        add(
            &mut out,
            "oracle/mod.rs::Finding",
            format!("{finding:?} {finding}"),
        );
        add(
            &mut out,
            "oracle/mod.rs::Verdict",
            format!(
                "{:?} {}",
                Verdict::Failed(finding),
                Verdict::Failed(finding)
            ),
        );
    }
    add(
        &mut out,
        "oracle/mod.rs::Verdict",
        format!("{:?} {}", Verdict::Holds, Verdict::Holds),
    );
    for invariant in Invariant::REGISTRY {
        add(
            &mut out,
            "oracle/mod.rs::Invariant",
            format!("{invariant:?} {invariant}"),
        );
    }
    add(
        &mut out,
        "oracle/mod.rs::ProbeToken",
        format!("{:?}", ProbeToken::mint(7, 3)),
    );
    let pairs = [(device, DeviceTag::new(1))];
    add(
        &mut out,
        "oracle/mod.rs::Reach",
        format!("{:?} {:?}", Reach::EveryOrderedPair, Reach::These(&pairs)),
    );
    add(
        &mut out,
        "oracle/mod.rs::Round",
        format!(
            "{:?}",
            Round {
                ordinal: 3,
                reach: Reach::These(&pairs),
                recovery: Recovery::Reconnect,
                tick: Duration::from_millis(250),
                row_envelope: 0,
                burst_opened: &[device],
                classified: &[undecryptable::Verdict::Applied],
            }
        ),
    );

    // oracle/quiescence.rs
    for reason in [
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
    ] {
        add(
            &mut out,
            "oracle/quiescence.rs::PendingReason",
            format!("{reason:?}"),
        );
        add(
            &mut out,
            "oracle/quiescence.rs::Quiescence",
            format!("{:?}", Quiescence::Pending(reason)),
        );
        add(
            &mut out,
            "oracle/quiescence.rs::Settled",
            format!("{:?}", Settled::TimedOut(reason)),
        );
    }
    add(
        &mut out,
        "oracle/quiescence.rs::Quiescence",
        format!("{:?}", Quiescence::Quiescent),
    );
    add(
        &mut out,
        "oracle/quiescence.rs::Settled",
        format!("{:?}", Settled::Quiescent(Duration::from_secs(9))),
    );
    add(
        &mut out,
        "oracle/quiescence.rs::StabilityWindow",
        format!("{:?}", StabilityWindow::new()),
    );

    // oracle/undecryptable.rs
    for cause in [
        Cause::EngineFailure,
        Cause::BranchLossUndetermined,
        Cause::ProbeUnreadable,
        Cause::OpaqueSendError,
    ] {
        add(
            &mut out,
            "oracle/undecryptable.rs::Cause",
            format!("{cause:?}"),
        );
        add(
            &mut out,
            "oracle/undecryptable.rs::Verdict",
            format!("{:?}", undecryptable::Verdict::Defect(cause)),
        );
    }
    for verdict in [
        undecryptable::Verdict::Expired,
        undecryptable::Verdict::PreAuth,
        undecryptable::Verdict::Applied,
        undecryptable::Verdict::CommitGap,
        undecryptable::Verdict::ForwardDistance,
        undecryptable::Verdict::Duplicate,
        undecryptable::Verdict::PastEpochOrBranchLoss { branch_loss: true },
        undecryptable::Verdict::OwnEcho,
        undecryptable::Verdict::SelfEvicted,
        undecryptable::Verdict::Quarantined,
        undecryptable::Verdict::Routing,
        undecryptable::Verdict::PeelFailed,
        undecryptable::Verdict::Fork,
        undecryptable::Verdict::SendDeferred,
        undecryptable::Verdict::EpochNotStable,
        undecryptable::Verdict::EpochUnrecoverable,
    ] {
        add(
            &mut out,
            "oracle/undecryptable.rs::Verdict",
            format!("{verdict:?}"),
        );
    }
    for probe in [Probe::Read(None), Probe::Unnamed, Probe::Unreadable] {
        add(
            &mut out,
            "oracle/undecryptable.rs::Probe",
            format!("{probe:?}"),
        );
    }
    // The row the classifier was handed, named by the engine's own content id —
    // which is 64 hex, i.e. the one shape this whole file is about.
    let message_id = haven_core::nostr::mls::types::MessageId::new(
        hex::decode(NEEDLE_HEX).expect("the needle is hex"),
    );
    add(
        &mut out,
        "oracle/undecryptable.rs::StoredRow",
        format!(
            "{:?} {:?}",
            StoredRow::Named(&message_id),
            StoredRow::Unknown
        ),
    );

    // oracle/vacuity.rs
    // A floor is the arm's own DECLARATION, checked into a profile: it is a
    // repository fact like the profile name, and the needle count below belongs
    // where a magnitude of the world's BEHAVIOUR is rendered instead.
    let floor = ExpectationFloor {
        faults_applied: 1,
        epochs_crossed: 1,
        deliveries_observed: 1,
        canaries_caught: 1,
    };
    add(
        &mut out,
        "oracle/vacuity.rs::ExpectationFloor",
        format!("{floor:?}"),
    );
    add(
        &mut out,
        "oracle/vacuity.rs::Observed",
        format!(
            "{:?}",
            Observed {
                faults_applied: NEEDLE_COUNT,
                // A DELTA from the world's origin, which the crate renders
                // exactly on purpose: a delta names no epoch.
                epochs_crossed: 2,
                deliveries_observed: NEEDLE_COUNT_U64,
                canaries_caught: NEEDLE_COUNT,
            }
        ),
    );
    for term in [
        FloorTerm::FaultsApplied,
        FloorTerm::EpochsCrossed,
        FloorTerm::DeliveriesObserved,
        FloorTerm::CanariesCaught,
    ] {
        add(
            &mut out,
            "oracle/vacuity.rs::FloorTerm",
            format!("{term:?}"),
        );
    }

    // profiles.rs
    for error in [
        ProfileError::Malformed,
        ProfileError::Invalid { field: "members" },
    ] {
        add(
            &mut out,
            "profiles.rs::ProfileError",
            format!("{error:?} {error}"),
        );
    }
    for profile in ProfileName::ALL {
        add(
            &mut out,
            "profiles.rs::ProfileName",
            format!("{profile:?} {profile}"),
        );
    }
    let spec = ProfileSpec::embedded(ProfileName::Pr).expect("the pr profile parses");
    add(&mut out, "profiles.rs::ProfileSpec", format!("{spec:?}"));
    add(
        &mut out,
        "profiles.rs::ScenarioSelection",
        format!(
            "{:?}",
            ScenarioSelection {
                id: "S01".to_owned(),
                arms: vec!["single-relay-outage".to_owned()],
            }
        ),
    );
    add(
        &mut out,
        "profiles.rs::WorldShape",
        format!(
            "{:?}",
            WorldShape {
                members: 2,
                circles: 1,
                relays: 1,
            }
        ),
    );

    // rc.rs
    for rc in [
        Rc::Clean,
        Rc::ViolationOrLeak,
        Rc::RigBroken,
        Rc::Unusable,
        Rc::ProvesTooLittle,
    ] {
        add(&mut out, "rc.rs::Rc", format!("{rc:?}"));
    }
    let mut verdicts = Verdicts::new();
    verdicts.fold_scan(Rc::ViolationOrLeak);
    verdicts.fold_invariant(Rc::Unusable);
    add(&mut out, "rc.rs::Verdicts", format!("{verdicts:?}"));

    // relay/policies.rs
    for native in [NativeClosed::RateLimited, NativeClosed::AuthRequired] {
        add(
            &mut out,
            "relay/policies.rs::NativeClosed",
            format!("{native:?}"),
        );
    }

    // rig/*
    for verdict in [PublishVerdict::Confirmed, PublishVerdict::RolledBack] {
        add(
            &mut out,
            "rig/circle.rs::PublishVerdict",
            format!("{verdict:?}"),
        );
    }
    add(
        &mut out,
        "rig/mod.rs::CircleTag",
        format!("{circle:?} {circle}"),
    );
    add(
        &mut out,
        "rig/mod.rs::DeviceTag",
        format!("{device:?} {device}"),
    );
    add(
        &mut out,
        "rig/mod.rs::RelayTag",
        format!("{relay:?} {relay}"),
    );
    let event = EventTag::new(12);
    add(
        &mut out,
        "rig/mod.rs::EventTag",
        format!("{event:?} {event}"),
    );
    let world_id = WorldId::new(7);
    add(
        &mut out,
        "rig/mod.rs::WorldId",
        format!("{world_id:?} {world_id}"),
    );
    for kind in [
        SimKind::Device,
        SimKind::Circle,
        SimKind::Relay,
        SimKind::Event,
        SimKind::World,
    ] {
        add(&mut out, "rig/mod.rs::SimKind", format!("{kind:?}"));
    }
    for step in [
        Step::OpenStore,
        Step::MintKeyPackage,
        Step::CreateCircle,
        Step::Publish,
        Step::ConfirmPublished,
        Step::RollBackPublish,
        Step::ProcessInvitation,
        Step::AcceptInvitation,
        Step::StageCommit,
        Step::StartEngine,
        Step::PauseEngine,
        Step::ResumeEngine,
        Step::ReadEpoch,
        Step::ReadRoster,
        Step::ReadGatingRows,
        Step::ReadCursor,
        Step::ReadConvergenceState,
        Step::ReadSessionLiveness,
        Step::ApplyFault,
    ] {
        add(&mut out, "rig/mod.rs::Step", format!("{step:?}"));
        add(
            &mut out,
            "rig/mod.rs::RigError",
            format!("{:?} {}", RigError::Core(step), RigError::Core(step)),
        );
    }
    for wait in [Wait::SessionRelease, Wait::SessionReopen] {
        add(&mut out, "rig/mod.rs::Wait", format!("{wait:?}"));
        add(
            &mut out,
            "rig/mod.rs::RigError",
            format!("{:?} {}", RigError::Timeout(wait), RigError::Timeout(wait)),
        );
    }
    for error in [
        RigError::LoopbackOptInRefused,
        RigError::SessionNotLive,
        RigError::SessionStillLive,
        RigError::StopTimedOut,
        RigError::WelcomeNeverAcked,
        RigError::PublishNeverAcked,
        RigError::UnknownTarget,
        RigError::ShapeMismatch,
        RigError::Unhealable,
        RigError::DeclarationRefused,
        RigError::InductionMechanismMoved,
        RigError::Clock(ClockError::BeforeEpoch),
    ] {
        add(
            &mut out,
            "rig/mod.rs::RigError",
            format!("{error:?} {error}"),
        );
    }
    add(
        &mut out,
        "rig/plane.rs::CapturedLine",
        format!(
            "{:?}",
            CapturedLine {
                seq: 4,
                world: world_id,
                level: log::Level::Warn,
                target: "haven_core::relay".to_owned(),
                text: format!("peer {NEEDLE_HEX} joined from {NEEDLE_URL} in {NEEDLE_NAME}"),
            }
        ),
    );
    for record in [
        TimelineRecord::Scheduled {
            tick: 4,
            op: Op::Fault {
                relay,
                fault: Fault::Notice("the harness is holding this relay"),
            },
            heal_at_tick: Some(9),
        },
        TimelineRecord::Applied {
            tick: 5,
            op: Op::Probe,
        },
        TimelineRecord::Healed {
            tick: 6,
            op: Op::Fault {
                relay,
                fault: Fault::Heal,
            },
        },
        TimelineRecord::Restarted {
            tick: 7,
            device,
            kind: KillKind::Hard,
            release_ms: 40,
            reopen_ms: 90,
        },
        TimelineRecord::Published {
            tick: 8,
            device,
            outcome: PublishVerdict::RolledBack.label(),
            witness_ms: None,
            events: "2-4",
        },
        TimelineRecord::Rebound {
            tick: 9,
            relay,
            attempts: "1",
            wait_ms: 60,
        },
    ] {
        add(
            &mut out,
            "rig/plane.rs::TimelineRecord",
            format!("{record:?}"),
        );
    }
    for kind in [KillKind::Soft, KillKind::Hard] {
        add(
            &mut out,
            "rig/restart.rs::KillKind",
            format!("{kind:?} {kind}"),
        );
    }
    add(
        &mut out,
        "rig/restart.rs::ReopenReport",
        format!(
            "{:?}",
            ReopenReport {
                release: Duration::from_millis(40),
                reopen: Duration::from_millis(90),
                engine_restarted: true,
            }
        ),
    );

    // scenarios/mod.rs — the arms come from the registry rather than from a
    // literal, so an arm that gains a field is rendered as the scenario really
    // declares it.
    for absence in [
        Absence::None,
        Absence::ThrottledBackoffFloor,
        Absence::DeliverySilenceWindow,
    ] {
        add(
            &mut out,
            "scenarios/mod.rs::Absence",
            format!("{absence:?}"),
        );
    }
    for withheld in [
        WithheldAcks::None,
        WithheldAcks::Fixed(1),
        WithheldAcks::PerInvitedMember,
    ] {
        add(
            &mut out,
            "scenarios/mod.rs::WithheldAcks",
            format!("{withheld:?}"),
        );
    }
    for scenario in haven_soak::scenarios::registry().iter().copied() {
        add(
            &mut out,
            "scenarios/mod.rs::Scenario",
            format!("{scenario:?} {scenario}"),
        );
        for arm in scenario.arms() {
            add(&mut out, "scenarios/mod.rs::Arm", format!("{arm:?}"));
            add(
                &mut out,
                "scenarios/mod.rs::ScenarioReport",
                format!(
                    "{report:?} {report}",
                    report = ScenarioReport {
                        scenario,
                        arm: arm.label,
                        graded: vec![(Invariant::LocationRoundTrip, Verdict::Holds)],
                        floor: Verdict::Failed(Finding::ProbeNotPublished { device, circle }),
                        observed: Observed {
                            faults_applied: NEEDLE_COUNT,
                            epochs_crossed: 2,
                            deliveries_observed: NEEDLE_COUNT_U64,
                            canaries_caught: NEEDLE_COUNT,
                        },
                        elapsed: Duration::from_secs(12),
                        deadline: Duration::from_secs(90),
                    }
                ),
            );
        }
    }

    // timeline.rs
    add(
        &mut out,
        "timeline.rs::Snapshot",
        format!(
            "{:?}",
            Snapshot {
                scenario: "S01",
                arm: "single-relay-outage",
                violated: "O1 LOCATION ROUND-TRIP".to_owned(),
                finding: "probe not delivered from simdev#0 to simdev#1".to_owned(),
                bound_secs: 145,
                observed_secs: 190,
                active: vec![scheduled],
                devices: vec!["simdev#0 offline=false".to_owned()],
                relays: vec!["simrelay#0 accepting=false".to_owned()],
                scan: vec!["s01:12 class=pubkey encoding=hex-lower rule=-".to_owned()],
            }
        ),
    );
    add(
        &mut out,
        "timeline.rs::Timeline",
        format!("{:?}", Timeline::in_memory()),
    );
    add(
        &mut out,
        "timeline.rs::TimelineLine",
        format!(
            "{:?}",
            read_lines("{\"record\":\"applied\",\"tick\":3}\n")
                .expect("one line parses")
                .remove(0)
        ),
    );

    out
}

/// The renderings only a real world can produce, plus the identifiers that
/// world actually minted.
///
/// A hand-made sample proves what its author thought to plant; these prove the
/// stronger thing — that a rendering of a LIVE device, circle, relay and
/// fingerprint carries none of the values that world really has.
// The world is CONSUMED by `teardown` at the end, which is the only point it
// may be released: every reading below is of a live world, and a session
// released earlier would take its own fingerprints with it. The length is the
// same table shape as `static_samples`, one row per type.
#[allow(clippy::significant_drop_tightening, clippy::too_many_lines)]
async fn world_samples() -> (BTreeMap<String, Vec<String>>, Vec<String>) {
    use haven_soak::driver::RunWorld;
    use haven_soak::logsink::SoakLogs;
    use haven_soak::nemesis::types::Schedule;
    use haven_soak::profiles::WorldShape;
    use haven_soak::relay::SimRelay;
    use haven_soak::rig::{install_process_globals, RelayPlane, RelayTag, SimWorld};
    use haven_soak::timeline::Timeline;

    install_process_globals().expect("the ws:// loopback opt-in installs");
    // Derived, never invented: the settle window this crate takes from the
    // product's own constant, and the lease is free in this binary.
    let logs = SoakLogs::acquire(haven_soak::oracle::bounds::settle())
        .await
        .expect("the capture lease");
    let relay = SimRelay::start(RelayTag::new(0))
        .await
        .expect("a relay plane starts");
    let mut world: RunWorld = SimWorld::build(
        &WorldShape {
            members: 2,
            circles: 1,
            relays: 1,
        },
        Schedule::new(Vec::new()),
        vec![relay],
        Timeline::in_memory(),
        logs.clone(),
    )
    .await
    .unwrap_or_else(|failure| panic!("a world builds: {failure}"));
    logs.attribute_to(world.id());

    // Everything this world minted, which nothing below may render.
    let mut needles = vec![
        world.relays()[0].url().to_owned(),
        world.circles()[0].name().to_owned(),
        world.circles()[0].group_id_hex().to_owned(),
        hex::encode(world.circles()[0].mls_group_id().as_slice()),
    ];
    for device in world.devices() {
        needles.push(device.pubkey_hex());
        needles.push(device.secret_hex_for_declaration().to_string());
        needles.push(device.dir.path().display().to_string());
    }

    let mut out: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let report = world.tick(3).await.expect("a tick applies nothing");
    add(&mut out, "rig/world.rs::TickReport", format!("{report:?}"));
    add(
        &mut out,
        "rig/world.rs::PendingGuard",
        format!("{:?}", world.note_pending_staged()),
    );
    add(
        &mut out,
        "relay/mod.rs::SimRelay",
        format!("{:?}", world.relays()[0]),
    );
    add(
        &mut out,
        "relay/ledger.rs::Ledger",
        format!("{:?}", world.relays()[0].ledger()),
    );
    add(
        &mut out,
        "rig/circle.rs::SimCircle",
        format!("{:?}", world.circles()[0]),
    );
    add(
        &mut out,
        "rig/device.rs::SimDevice",
        format!("{:?}", world.devices()[0]),
    );
    add(
        &mut out,
        "rig/device.rs::DeviceLedger",
        format!("{:?}", world.devices()[0].ledger()),
    );
    add(&mut out, "logsink.rs::SoakLogs", format!("{logs:?}"));

    let fingerprint = world.fingerprint().await.expect("a fingerprint reads");
    add(
        &mut out,
        "rig/world.rs::WorldFingerprint",
        format!("{fingerprint:?}"),
    );
    add(
        &mut out,
        "rig/world.rs::DeviceFingerprint",
        format!("{:?}", fingerprint.devices[0]),
    );
    add(
        &mut out,
        "rig/world.rs::CircleFingerprint",
        format!("{:?}", fingerprint.devices[0].circles[0]),
    );
    add(
        &mut out,
        "rig/world.rs::RosterDigest",
        format!("{:?}", fingerprint.devices[0].circles[0].roster),
    );
    add(
        &mut out,
        "rig/world.rs::ProgressDigest",
        format!("{:?}", fingerprint.devices[0].circles[0].progress),
    );

    world.teardown().await.expect("the world tears down");
    drop(logs);
    (out, needles)
}

/// The shapes no rendering may carry, whatever else it says.
fn offending_shape(rendered: &str) -> Option<String> {
    // A run of 32 hex or more: a pubkey, an event id, an MLS group id and a
    // schedule digest are all exactly that, and a structural rule cannot tell
    // them apart either.
    let mut run = 0_usize;
    for character in rendered.chars() {
        if character.is_ascii_hexdigit() {
            run += 1;
            if run >= 32 {
                return Some("a hex run a structural rule matches".to_owned());
            }
        } else {
            run = 0;
        }
    }
    if rendered.contains("://") {
        return Some("an endpoint".to_owned());
    }
    // Four dot-separated numbers: an address, however it got there.
    for candidate in rendered.split(|c: char| !(c.is_ascii_digit() || c == '.')) {
        let parts: Vec<&str> = candidate.split('.').collect();
        if parts.len() == 4
            && parts
                .iter()
                .all(|part| !part.is_empty() && part.chars().all(|c| c.is_ascii_digit()))
        {
            return Some("a dotted quad".to_owned());
        }
    }
    if rendered.contains(NEEDLE_COUNT_TEXT) {
        return Some("an exact count".to_owned());
    }
    None
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn every_rendering_this_crate_defines_is_sampled_and_value_free() {
    let (world_rendered, world_needles) = world_samples().await;
    let mut samples = static_samples();
    for (key, renderings) in world_rendered {
        samples.entry(key).or_default().extend(renderings);
    }

    // Half one: the population is read from the source, so a type that gains a
    // rendering and no sample reds this rather than waiting for a reviewer.
    let population = population();
    let covered: BTreeSet<String> = samples.keys().cloned().collect();
    // Joined rather than `{:?}`-ed, here and below: these are type NAMES, and a
    // list of them is prose a reader acts on, not a rendering of a value.
    let unsampled = population
        .difference(&covered)
        .cloned()
        .collect::<Vec<String>>()
        .join(", ");
    assert!(
        unsampled.is_empty(),
        "these types render and nothing proves what they render: {unsampled}"
    );
    let stale = covered
        .difference(&population)
        .cloned()
        .collect::<Vec<String>>()
        .join(", ");
    assert!(
        stale.is_empty(),
        "these samples name a type that no longer renders: {stale}"
    );

    // Half two: what each one actually renders. Every offence is collected
    // rather than panicked on, so one run names all of them instead of the
    // first — a rendering test that stops at the first leak is a rendering test
    // somebody runs five times.
    let planted: Vec<String> = [NEEDLE_HEX, NEEDLE_URL, NEEDLE_NAME]
        .iter()
        .map(|needle| (*needle).to_owned())
        .chain(
            world_needles
                .into_iter()
                .filter(|needle| !needle.is_empty()),
        )
        .collect();
    let mut offences: Vec<String> = Vec::new();
    for (key, renderings) in &samples {
        if renderings.is_empty() {
            offences.push(format!("{key}: a row with no rendering behind it"));
        }
        for rendered in renderings {
            if rendered.trim().is_empty() {
                offences.push(format!(
                    "{key}: rendered nothing at all, so every assertion over it would pass on \
                     an empty string"
                ));
                continue;
            }
            if let Some(shape) = offending_shape(rendered) {
                offences.push(format!("{key}: renders {shape}"));
            }
            if planted.iter().any(|needle| rendered.contains(needle)) {
                offences.push(format!("{key}: renders a value the run minted"));
            }
        }
    }
    assert!(
        offences.is_empty(),
        "these renderings carry what Rule 15 keeps out of one:\n  {}",
        offences.join("\n  ")
    );
}

#[test]
fn the_extractor_finds_the_population_it_is_meant_to() {
    let found = population();
    for expected in [
        "rig/world.rs::TickReport",
        "rig/mod.rs::DeviceTag",
        "nemesis/types.rs::Schedule",
        "oracle/mod.rs::Verdict",
        "oracle/undecryptable.rs::Verdict",
    ] {
        assert!(found.contains(expected), "the extractor missed {expected}");
    }
    assert!(
        !found.iter().any(|name| name.starts_with("main.rs")),
        "the binary's own types cannot be rendered from here; see the module docs"
    );
    // Anti-vacuity: an extractor that stopped recognising anything would make
    // the enumeration above pass over an empty population.
    assert!(
        found.len() >= 60,
        "the extractor found far fewer renderings than this crate defines, so it has stopped \
         recognising one of the shapes it reads"
    );
}

#[test]
fn the_shape_check_refuses_what_it_is_for() {
    assert!(offending_shape("TickReport { tick: 7 }").is_none());
    assert!(offending_shape(&format!("Planted({})", "ab".repeat(32))).is_some());
    assert!(offending_shape("SimRelay { dialled: \"ws://loopback:7777\" }").is_some());
    assert!(offending_shape("Endpoint(127.0.0.1)").is_some());
    assert!(offending_shape("DeviceLedger { locations: 7919 }").is_some());
    assert!(
        offending_shape("Provenance { commit_short: \"bb310e2f4a9c\" }").is_none(),
        "a short commit is a repository fact and under the shape a rule matches"
    );
}
