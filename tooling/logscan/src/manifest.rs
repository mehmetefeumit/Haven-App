//! The declaration channel and the sealed manifest.
//!
//! # Path discipline is a security property
//!
//! The manifest holds every value the run minted: real MLS group ids, pubkeys,
//! names, coordinates, and the commitments of the secrets. It is the one file on
//! the runner more sensitive than the wire journal, and it must never leave.
//! `scripts/ci/check_wire_proxy_test_only.sh:180-191` records the same ban being
//! defeated twice, both times because the path was caller-controlled, so:
//!
//! * the directory is `/tmp/haven-soak/needles` **unconditionally** — there is
//!   deliberately no environment override and no `--dir` flag;
//! * the file name must end in `.needles.json`, so the repo guard can key on
//!   what the file IS rather than on a prefix somebody can move;
//! * the directory is created `0700` and rejected if it is not one, the file is
//!   created `O_EXCL` with mode `0600`, so a second seal cannot silently
//!   overwrite the record of the first.
//!
//! # Secret-class values are committed, never serialised
//!
//! For an `nsec` or an exporter secret the manifest carries `sha256(raw)` and
//! `raw_withheld: true`; only the digest's encodings are searchable. The recall
//! that costs is carried by `scan-logs-for-secrets.sh`'s keyword-anchored
//! patterns and by S1/S2/S4/S8/S9.

use std::collections::BTreeMap;
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Component, Path};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::expand::{Declared, Dropped, Term};
use crate::ledger::Claim;
use crate::plants::{DeclaredPlant, DeclaredPlants, PlantSlot};
use crate::policy::{Policy, SinkSpec};

/// The one directory a manifest or a sidecar may live in.
pub const NEEDLE_DIR: &str = "/tmp/haven-soak/needles";

/// The extension the repo guard keys on.
pub const MANIFEST_SUFFIX: &str = ".needles.json";

/// The manifest schema this build reads and writes.
pub const SCHEMA: u32 = 1;

/// One declared value, as recorded in the manifest.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ValueEntry {
    /// Manifest-local id.
    pub id: String,
    /// The needle class.
    pub class: String,
    /// The proxy role that declared it, when it came off a sidecar.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    /// The proxy's per-role sequence number.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seq: Option<u64>,
    /// Whether the raw value was withheld (secret class).
    pub raw_withheld: bool,
    /// `sha256(the declared SPELLING)`, hex.
    ///
    /// Present for every class: it is what lets a later run prove two manifests
    /// named the same value without either holding it. It is deliberately NOT
    /// the same digest as the `sha256-hex` TERM, which the expander computes
    /// over the DECODED bytes — so a pubkey declared as hex and the same pubkey
    /// declared as an `npub` carry different commitments while expanding to the
    /// same terms. The commitment identifies a declaration, the term searches
    /// for a value; unifying them would mean teaching this module every class's
    /// decoder and moving every "that is not hex" error from the expander to the
    /// declaration channel.
    pub commitment: String,
    /// Whether the producer could confirm the value reached the world. A value
    /// that was minted but never applied proves nothing about what a log may
    /// hold, so the seal prices `false` at rc 4.
    pub planted_confirmed: bool,
}

/// A sealed manifest.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Manifest {
    /// Schema version.
    pub schema: u32,
    /// The run this manifest belongs to.
    pub run_id: String,
    /// The proxy roles that contributed declarations.
    pub roles: Vec<String>,
    /// The declared values.
    pub values: Vec<ValueEntry>,
    /// The searchable terms.
    pub terms: Vec<Term>,
    /// The labels that produced no term, and why.
    pub dropped: Vec<Dropped>,
    /// The coverage claims for the classes this run declared.
    pub ledger: Vec<Claim>,
    /// The declared positive controls.
    pub plants: Vec<PlantSlot>,
    /// Whether this run had a channel to hand the app a Dart token at all.
    /// Absent means `dart`: every manifest written before the host profile
    /// existed came off a lane with the proxy's declaration channel.
    #[serde(default)]
    pub declared_plants: DeclaredPlants,
    /// Line floors per sink class, after `--floor` overrides.
    pub floors: BTreeMap<String, u64>,
    /// The declaration floors the run was checked against.
    pub expect: BTreeMap<String, usize>,
    /// Sink classes each needle class is NOT searched in.
    pub scoped_out: BTreeMap<String, Vec<String>>,
    /// The sink specs, written at seal time for the record and RE-READ from the
    /// compiled-in policy on every [`read_manifest`].
    ///
    /// Written, because a manifest should say what the run was scanned under.
    /// Re-read, because a sink spec decides where the structural rules run,
    /// which classes are searched and which rules a shape may skip: honouring
    /// the file's copy would put the instrument's own rules under the caller's
    /// control, which is the one thing `policy.toml` is compiled in to prevent.
    /// Seal and scan run the same binary, so the two agree by construction; when
    /// they do not, the policy this binary was BUILT with is the honest answer.
    pub sinks: BTreeMap<String, SinkSpec>,
    /// S4's entropy floor. Written at seal time, re-read from the policy for the
    /// same reason as `sinks`: a floor of 9.0 in a manifest would silence S4.
    pub base64_entropy_bits: f64,
    /// Endpoint spellings S7 and S12 skip (the lane's own loopback relay and
    /// proxy). Nothing else is ever exempt from those two rules.
    pub exempt_endpoints: Vec<String>,
}

impl Manifest {
    /// The manifest `scan --rules-only` runs against: the policy's sink specs
    /// and line floors, and nothing at all to search for.
    ///
    /// It is built in memory and never written: a manifest on disk is the record
    /// of what a run minted, and a rules-only scan is precisely the case where
    /// nothing was declared.
    #[must_use]
    pub fn rules_only(policy: &Policy) -> Self {
        Self {
            schema: SCHEMA,
            run_id: "rules-only".to_owned(),
            roles: Vec::new(),
            values: Vec::new(),
            terms: Vec::new(),
            dropped: Vec::new(),
            ledger: Vec::new(),
            plants: Vec::new(),
            declared_plants: DeclaredPlants::None,
            floors: policy
                .sinks
                .iter()
                .map(|(name, spec)| (name.clone(), spec.min_lines))
                .collect(),
            expect: BTreeMap::new(),
            scoped_out: policy
                .classes
                .iter()
                .map(|(name, spec)| (name.clone(), spec.scoped_out.clone()))
                .collect(),
            sinks: policy.sinks.clone(),
            base64_entropy_bits: policy.base64_entropy_bits,
            // No `--exempt-endpoint`: exemptions are a property of the run that
            // sealed them, and a rules-only scan sealed nothing. A lane that
            // needs its loopback relay forgiven must declare and seal.
            exempt_endpoints: Vec::new(),
        }
    }

    /// The line floor for `class`.
    #[must_use]
    pub fn floor(&self, class: &str) -> u64 {
        self.floors
            .get(class)
            .copied()
            .or_else(|| self.sinks.get(class).map(|s| s.min_lines))
            .unwrap_or(0)
    }
}

/// One line of a `.needles.decl` sidecar.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeclLine {
    /// The needle class, or `plant`.
    pub class: String,
    /// The value, or the plant token.
    pub value: String,
    /// The proxy role.
    #[serde(default)]
    pub role: Option<String>,
    /// The proxy's per-role sequence number.
    #[serde(default)]
    pub seq: Option<u64>,
    /// The plant emitter.
    #[serde(default)]
    pub sink: Option<String>,
    /// The plant phase.
    #[serde(default)]
    pub phase: Option<String>,
    /// Whether the producer confirmed the value reached the world. Absent means
    /// yes: a value declared over the app's own socket is a value the app
    /// minted, so a producer only says `false` when it knows better.
    #[serde(default)]
    pub planted_confirmed: Option<bool>,
}

/// Everything one or more sidecars declared.
#[derive(Debug, Default)]
pub struct Declarations {
    /// Non-plant values, in declaration order.
    pub values: Vec<(Declared, ValueEntry)>,
    /// Plant declarations.
    pub plants: Vec<DeclaredPlant>,
    /// The roles seen.
    pub roles: Vec<String>,
}

/// Parses one sidecar's text.
///
/// # Errors
///
/// Returns a message naming the line NUMBER and nothing else. A serde message
/// can quote the offending input, and the offending input here is a pubkey.
pub fn parse_decl(
    policy: &Policy,
    text: &str,
    next_id: &mut usize,
    order: &mut usize,
    into: &mut Declarations,
) -> Result<(), String> {
    for (index, line) in text.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        let parsed: DeclLine = serde_json::from_str(line).map_err(|_| {
            format!(
                "line {} of a declaration sidecar does not match the declaration schema \
                 (one JSON object per line: class, value, and optionally role, seq, sink, phase, planted_confirmed)",
                index + 1
            )
        })?;
        // The class is looked up WITHOUT interpolating it into any error: a
        // declaration payload is app-authored text, the proxy validates its
        // shape and not its contents, and a harness bug that put a pubkey in
        // `class` would otherwise print it to a public step log (Rule 15).
        let spec = policy.classes.get(&parsed.class).ok_or_else(|| {
            format!(
                "line {} names a needle class the policy does not declare (the name is withheld: a declaration payload is app-authored)",
                index + 1
            )
        })?;
        if let Some(role) = parsed.role.clone() {
            if !into.roles.contains(&role) {
                into.roles.push(role);
            }
        }
        if matches!(spec.kind, crate::policy::ClassKind::Plant) {
            let (Some(sink), Some(phase)) = (parsed.sink.clone(), parsed.phase.clone()) else {
                return Err(format!(
                    "line {} declares a plant without a sink and a phase",
                    index + 1
                ));
            };
            into.plants.push(DeclaredPlant {
                sink,
                phase,
                token: parsed.value,
                seq: parsed.seq,
                order: *order,
            });
            *order += 1;
            continue;
        }
        *next_id += 1;
        let id = format!("v{next_id}");
        let commitment = hex::encode(Sha256::digest(parsed.value.as_bytes()));
        into.values.push((
            Declared {
                id: id.clone(),
                class: parsed.class.clone(),
                raw: parsed.value,
            },
            ValueEntry {
                id,
                class: parsed.class,
                role: parsed.role,
                seq: parsed.seq,
                raw_withheld: spec.secret,
                commitment,
                planted_confirmed: parsed.planted_confirmed.unwrap_or(true),
            },
        ));
        *order += 1;
    }
    Ok(())
}

/// Adds a `--host-decl <class>=<value>` declaration.
///
/// # Errors
///
/// Returns a message when the class is not declared in the policy, when a plant
/// is declared on the host, or when a `coordinate` is not `lat,lon`.
///
/// A host declaration comes from a runner's argument list rather than from the
/// app, so a typo there is silent in a way a sidecar declaration is not: the
/// expander would refuse the value later with the same rc, but only after the
/// operator has read a message about an expander they never invoked. The
/// coordinate shape is checked HERE, where the flag is, and the value is still
/// withheld — a runner's argv reaches a public step log.
pub fn add_host_decl(
    policy: &Policy,
    class: &str,
    value: &str,
    next_id: &mut usize,
    into: &mut Declarations,
) -> Result<(), String> {
    let spec = policy.class(class)?;
    if matches!(spec.kind, crate::policy::ClassKind::Plant) {
        return Err(
            "a plant cannot be declared on the host: a plant proves that the APP reached the sink"
                .to_owned(),
        );
    }
    if matches!(spec.kind, crate::policy::ClassKind::Coordinate) && !is_lat_lon(value) {
        return Err(format!(
            "`--host-decl {class}=` needs `lat,lon` in decimal degrees (the value is withheld)"
        ));
    }
    *next_id += 1;
    let id = format!("v{next_id}");
    into.values.push((
        Declared {
            id: id.clone(),
            class: class.to_owned(),
            raw: value.to_owned(),
        },
        ValueEntry {
            id,
            class: class.to_owned(),
            role: None,
            seq: None,
            raw_withheld: spec.secret,
            commitment: hex::encode(Sha256::digest(value.as_bytes())),
            planted_confirmed: true,
        },
    ));
    Ok(())
}

/// Whether `text` is two decimal axes separated by one comma.
fn is_lat_lon(text: &str) -> bool {
    text.split_once(',').is_some_and(|(lat, lon)| {
        lat.trim().parse::<f64>().is_ok() && lon.trim().parse::<f64>().is_ok()
    })
}

/// Every spelling of an exempt endpoint S7 and S12 skip.
///
/// Host, `host:port` and the URL forms — exactly those, so an exemption for the
/// loopback relay cannot become an exemption for a path under it.
#[must_use]
pub fn endpoint_spellings(endpoint: &str) -> Vec<String> {
    let trimmed = endpoint.trim().trim_end_matches('/');
    let mut out = vec![trimmed.to_owned()];
    if let Some((scheme, rest)) = trimmed.split_once("://") {
        out.push(rest.to_owned());
        out.push(format!("{scheme}://{rest}"));
        if let Some((host, port)) = rest.rsplit_once(':') {
            if port.chars().all(|c| c.is_ascii_digit()) {
                out.push(host.to_owned());
            }
        }
    } else if let Some((host, port)) = trimmed.rsplit_once(':') {
        if port.chars().all(|c| c.is_ascii_digit()) {
            out.push(host.to_owned());
        }
    }
    out.sort_unstable();
    out.dedup();
    out
}

/// Rejects an output path that is not under [`NEEDLE_DIR`] with the
/// [`MANIFEST_SUFFIX`] extension.
///
/// # Errors
///
/// Returns the reason. The caller's contract is rc 2: a relocatable path defeats
/// a path ban, so this is a broken guard, not a failed scan.
pub fn validate_out_path(path: &Path) -> Result<(), String> {
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| "the manifest path has no file name".to_owned())?;
    if !name.ends_with(MANIFEST_SUFFIX) {
        return Err(format!(
            "a manifest file name must end in `{MANIFEST_SUFFIX}` — the upload ban keys on the extension, not on a prefix somebody can move"
        ));
    }
    if path
        .components()
        .any(|c| matches!(c, Component::ParentDir | Component::CurDir))
    {
        return Err("a manifest path may not contain `.` or `..`".to_owned());
    }
    let parent = path
        .parent()
        .ok_or_else(|| "the manifest path has no directory".to_owned())?;
    if parent != Path::new(NEEDLE_DIR) {
        return Err(format!(
            "a manifest must live in `{NEEDLE_DIR}` — there is deliberately no override, because a relocatable path defeats the upload ban"
        ));
    }
    Ok(())
}

/// Creates [`NEEDLE_DIR`] `0700` and refuses anything else in its place.
///
/// # Errors
///
/// Returns the reason. A world-readable or symlinked needle directory is a
/// disclosure, so this fails closed.
pub fn ensure_needle_dir() -> Result<(), String> {
    ensure_dir_chain(Path::new(NEEDLE_DIR))
}

/// The body of [`ensure_needle_dir`], over an explicit path so the refusals can
/// be tested without a symlink in the real `/tmp/haven-soak`.
///
/// The path itself stays un-parameterised at every call site: there is exactly
/// one needle directory and no way to name another.
fn ensure_dir_chain(dir: &Path) -> Result<(), String> {
    // A symlinked PARENT is as good as a symlinked directory — the values land
    // wherever the link points — and `create_dir_all` would happily follow it.
    // Checked before creating, because after creating it is too late.
    if let Some(parent) = dir.parent() {
        if let Ok(meta) = std::fs::symlink_metadata(parent) {
            if meta.file_type().is_symlink() {
                return Err(
                    "the needle directory's parent is a symlink; refusing to write values through it"
                        .to_owned(),
                );
            }
        }
    }
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .map_err(|e| format!("cannot create the needle directory: {:?}", e.kind()))?;
    let meta = std::fs::symlink_metadata(dir)
        .map_err(|e| format!("cannot stat the needle directory: {:?}", e.kind()))?;
    if meta.file_type().is_symlink() || !meta.is_dir() {
        return Err("the needle directory is not a directory".to_owned());
    }
    let mode = std::os::unix::fs::PermissionsExt::mode(&meta.permissions()) & 0o777;
    if mode != 0o700 {
        return Err(
            "the needle directory is not mode 0700; refusing to write values into a directory others can read"
                .to_owned(),
        );
    }
    Ok(())
}

/// Writes `manifest` to `path` with `O_EXCL` and mode `0600`.
///
/// # Errors
///
/// Returns the reason, including "a manifest is already sealed at that path" —
/// which is never overwritten, because the first seal is the record of the run.
pub fn write_manifest(path: &Path, manifest: &Manifest) -> Result<(), String> {
    validate_out_path(path)?;
    ensure_needle_dir()?;
    let json = serde_json::to_vec_pretty(manifest)
        .map_err(|_| "the manifest does not serialise".to_owned())?;
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(|e| match e.kind() {
            std::io::ErrorKind::AlreadyExists => {
                "a manifest is already sealed at that path; the first seal is the record of the run"
                    .to_owned()
            }
            other => format!("cannot create the manifest: {other:?}"),
        })?;
    file.write_all(&json)
        .map_err(|e| format!("cannot write the manifest: {:?}", e.kind()))?;
    Ok(())
}

/// Reads a sealed manifest.
///
/// # Errors
///
/// Returns the reason, never the content: a parse error that quoted the input
/// would quote a pubkey.
pub fn read_manifest(path: &Path) -> Result<Manifest, String> {
    let text = std::fs::read_to_string(path)
        .map_err(|e| format!("cannot read the manifest: {:?}", e.kind()))?;
    let mut manifest: Manifest = serde_json::from_str(&text)
        .map_err(|_| "the manifest does not match the manifest schema".to_owned())?;
    if manifest.schema != SCHEMA {
        return Err(format!(
            "manifest schema {} is not the {SCHEMA} this build understands",
            manifest.schema
        ));
    }
    // The POLICY halves of the manifest are re-read from the compiled-in policy
    // rather than honoured from the file. A manifest arrives on `--manifest
    // <path>`, i.e. from the caller, and a sink spec decides where the
    // structural rules run, which classes are searched and — since the cargo
    // exemption — which rules a shape may skip. Honouring the file's copy would
    // make the instrument's own rules caller-controlled through a second door,
    // the one `scripts/ci/check_wire_proxy_test_only.sh:180-191` records being
    // opened twice. What the file stays authoritative for is what the RUN
    // minted or chose: terms, values, plants, roles, line floors and the
    // endpoints it sealed.
    let policy = Policy::load()?;
    manifest.sinks.clone_from(&policy.sinks);
    manifest.scoped_out = policy
        .classes
        .iter()
        .map(|(name, spec)| (name.clone(), spec.scoped_out.clone()))
        .collect();
    manifest.base64_entropy_bits = policy.base64_entropy_bits;
    Ok(manifest)
}

#[cfg(test)]
mod tests {
    use std::path::{Path, PathBuf};

    use super::{
        add_host_decl, endpoint_spellings, parse_decl, read_manifest, validate_out_path,
        write_manifest, Declarations, Manifest, MANIFEST_SUFFIX, NEEDLE_DIR, SCHEMA,
    };
    use crate::policy::Policy;

    /// A unique path inside the real needle directory, removed on drop.
    ///
    /// The real directory, because the path discipline IS the thing under test:
    /// a temp-dir stand-in would assert the opposite of the rule.
    struct SealedPath(PathBuf);

    impl SealedPath {
        fn new(tag: &str) -> Self {
            let nanos = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.subsec_nanos());
            Self(Path::new(NEEDLE_DIR).join(format!(
                "selftest-{}-{tag}-{nanos}{MANIFEST_SUFFIX}",
                std::process::id()
            )))
        }
    }

    impl Drop for SealedPath {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }

    fn manifest() -> Manifest {
        Manifest {
            schema: SCHEMA,
            run_id: "test".to_owned(),
            roles: vec![],
            values: vec![],
            terms: vec![],
            dropped: vec![],
            ledger: vec![],
            plants: vec![],
            declared_plants: super::DeclaredPlants::Dart,
            floors: std::collections::BTreeMap::new(),
            expect: std::collections::BTreeMap::new(),
            scoped_out: std::collections::BTreeMap::new(),
            sinks: std::collections::BTreeMap::new(),
            base64_entropy_bits: 4.2,
            exempt_endpoints: vec![],
        }
    }

    #[test]
    fn the_out_path_must_carry_the_banned_extension_in_the_banned_directory() {
        validate_out_path(Path::new("/tmp/haven-soak/needles/r1.needles.json"))
            .expect("the sanctioned shape");
        for bad in [
            "/tmp/haven-soak/needles/r1.json",
            "/tmp/haven-soak/needles/r1.needles.json.log",
            "/tmp/r1.needles.json",
            "/tmp/haven-soak/needles/sub/r1.needles.json",
            "/tmp/haven-soak/needles/../r1.needles.json",
        ] {
            assert!(
                validate_out_path(Path::new(bad)).is_err(),
                "`{bad}` must be rejected"
            );
        }
    }

    #[test]
    fn a_sealed_manifest_is_0600_and_never_overwritten() {
        let path = SealedPath::new("excl");
        write_manifest(&path.0, &manifest()).expect("first seal");
        let mode = std::os::unix::fs::PermissionsExt::mode(
            &std::fs::metadata(&path.0).expect("stat").permissions(),
        ) & 0o777;
        assert_eq!(mode, 0o600, "the manifest must not be readable by others");
        let again = write_manifest(&path.0, &manifest()).expect_err("O_EXCL must refuse");
        assert!(again.contains("already sealed"), "{again}");
        let read = read_manifest(&path.0).expect("round trip");
        assert_eq!(read.run_id, "test");
    }

    /// A manifest cannot relax the policy, only record it.
    ///
    /// The sink specs decide where the rules run, which of them a cargo-shaped
    /// line may skip and which emitter's records are searched for one class
    /// less, so a manifest that claimed `logcat` exempts cargo status lines,
    /// that S4's entropy floor is unreachable, or that some daemon is scoped
    /// out of every class would be a caller turning the instrument down through
    /// its input file. All are overwritten on read, while everything the RUN
    /// chose (its floors, its endpoints) survives.
    #[test]
    fn the_policy_halves_of_a_manifest_are_re_read_and_never_honoured() {
        let path = SealedPath::new("policyauthority");
        let policy = Policy::load().expect("policy");
        let mut tampered = manifest();
        tampered.sinks = policy.sinks.clone();
        for spec in tampered.sinks.values_mut() {
            spec.cargo_status = crate::policy::CargoStatus::Exempt;
            spec.structural_rules = false;
            // The needle exemption is the most valuable one to forge, in both
            // shapes: a program the policy names nothing about, and — the
            // subtler one — the program it DOES name, carrying an extra class.
            // Either would stop the search for a value the run really minted.
            spec.emitter_scoped_out = vec![
                crate::policy::EmitterScope {
                    process: "locationd".to_owned(),
                    emitter: "locationd".to_owned(),
                    classes: vec!["coordinate".to_owned(), "pubkey".to_owned()],
                },
                crate::policy::EmitterScope {
                    process: "locationd".to_owned(),
                    emitter: "com.apple.locationd.Position".to_owned(),
                    classes: vec!["coordinate".to_owned(), "pubkey".to_owned()],
                },
            ];
        }
        tampered.base64_entropy_bits = 9.0;
        tampered
            .scoped_out
            .insert("mls_group_id".to_owned(), vec!["logcat".to_owned()]);
        tampered.floors.insert("logcat".to_owned(), 7);
        tampered.exempt_endpoints = vec!["ws://10.0.2.2:7777".to_owned()];
        write_manifest(&path.0, &tampered).expect("seal");

        let read = read_manifest(&path.0).expect("round trip");
        assert_eq!(
            read.sinks["logcat"].cargo_status,
            crate::policy::CargoStatus::Scanned,
            "only `rust-test` exempts cargo status lines, and only the policy says so"
        );
        assert!(read.sinks["logcat"].structural_rules);
        assert!(
            read.sinks
                .values()
                .all(|spec| spec.emitter_scope("locationd", "locationd").is_empty()),
            "a forged emitter scope is not honoured; only the policy names one"
        );
        // …and the one scope the policy DOES declare comes back as the policy
        // wrote it, not as the file widened it: a manifest that added `pubkey`
        // to it would stop a pubkey being searched on the daemon's records.
        assert_eq!(
            read.sinks["ios"].emitter_scope("locationd", "com.apple.locationd.Position"),
            ["coordinate"],
            "a widened scope on the real emitter is not honoured either"
        );
        assert!((read.base64_entropy_bits - policy.base64_entropy_bits).abs() < f64::EPSILON);
        assert!(
            !read.scoped_out["mls_group_id"].contains(&"logcat".to_owned()),
            "the real MLS group id is scoped out of nothing"
        );
        // …and the run's own choices are untouched.
        assert_eq!(read.floor("logcat"), 7);
        assert_eq!(read.exempt_endpoints, vec!["ws://10.0.2.2:7777".to_owned()]);
    }

    #[test]
    fn the_needle_directory_is_0700() {
        let path = SealedPath::new("mode");
        write_manifest(&path.0, &manifest()).expect("seal");
        let mode = std::os::unix::fs::PermissionsExt::mode(
            &std::fs::metadata(NEEDLE_DIR).expect("stat").permissions(),
        ) & 0o777;
        assert_eq!(mode, 0o700);
    }

    /// The three literals that must agree: this crate's, the proxy's, and the
    /// shell's.
    ///
    /// The proxy writes the sidecars and this crate reads them, so a divergence
    /// means a lane seals an empty manifest and reads as clean. The repo guard
    /// bans the extension wherever it appears; nothing else pins the DIRECTORY
    /// across the two crates.
    #[test]
    fn the_proxy_and_the_scanner_name_the_same_needle_directory() {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../e2e/local-relay/src/needles.rs");
        let text = std::fs::read_to_string(&path).unwrap_or_else(|e| {
            panic!(
                "cannot read the proxy's needle module ({:?}); the sidecar directory literal must stay in step with {NEEDLE_DIR}",
                e.kind()
            )
        });
        let literal = text
            .lines()
            .find_map(|line| {
                line.trim()
                    .strip_prefix("pub const NEEDLE_DIR: &str = \"")?
                    .split('"')
                    .next()
            })
            .expect("the proxy must declare `pub const NEEDLE_DIR`");
        assert_eq!(
            literal, NEEDLE_DIR,
            "the proxy writes its sidecars somewhere this scanner does not read"
        );
    }

    #[test]
    fn a_symlinked_needle_directory_or_parent_is_refused() {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.subsec_nanos());
        let root = std::env::temp_dir().join(format!(
            "haven-logscan-dirchain-{}-{nanos}",
            std::process::id()
        ));
        std::fs::create_dir_all(root.join("real")).expect("scratch");

        // A fresh chain is created 0700 and accepted.
        let fresh = root.join("real").join("needles");
        super::ensure_dir_chain(&fresh).expect("a fresh directory is fine");
        let mode = std::os::unix::fs::PermissionsExt::mode(
            &std::fs::metadata(&fresh).expect("stat").permissions(),
        ) & 0o777;
        assert_eq!(mode, 0o700);

        // A symlinked PARENT is refused, even though the directory under it is
        // an ordinary one.
        std::os::unix::fs::symlink(root.join("real"), root.join("link")).expect("symlink");
        let through_link = root.join("link").join("needles");
        let err =
            super::ensure_dir_chain(&through_link).expect_err("a symlinked parent must be refused");
        assert!(err.contains("parent is a symlink"), "{err}");

        // And so is a symlinked directory itself.
        std::os::unix::fs::symlink(root.join("real"), root.join("needles")).expect("symlink");
        let err = super::ensure_dir_chain(&root.join("needles"))
            .expect_err("a symlinked needle directory must be refused");
        assert!(err.contains("not a directory"), "{err}");

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_manifest_with_another_schema_is_refused() {
        let path = SealedPath::new("schema");
        let mut future = manifest();
        future.schema = SCHEMA + 1;
        write_manifest(&path.0, &future).expect("seal");
        let err = read_manifest(&path.0).expect_err("a future schema must be refused");
        assert!(err.contains("is not the"), "{err}");
    }

    #[test]
    fn a_malformed_declaration_names_the_line_and_never_the_value() {
        let policy = Policy::load().expect("policy");
        let mut ids = 0;
        let mut order = 0;
        let mut into = Declarations::default();
        let secret = "0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9";
        let text = format!(
            "{{\"class\":\"pubkey\",\"value\":\"{secret}\"}}\n{{\"class\":\"pubkey\",\"value\":\"{secret}\",\"seq\":\"not-a-number\"}}\n"
        );
        let err = parse_decl(&policy, &text, &mut ids, &mut order, &mut into)
            .expect_err("a type error must be rejected");
        assert!(err.contains("line 2"), "{err}");
        assert!(
            !err.contains(secret) && !err.contains(&secret[..8]),
            "a declaration error must never quote the declaration"
        );
    }

    #[test]
    fn an_unknown_field_is_refused_so_a_channel_change_cannot_pass_silently() {
        let policy = Policy::load().expect("policy");
        let mut ids = 0;
        let mut order = 0;
        let mut into = Declarations::default();
        let text = "{\"class\":\"pubkey\",\"value\":\"0a1b\",\"stamp\":123}\n";
        assert!(parse_decl(&policy, text, &mut ids, &mut order, &mut into).is_err());
    }

    #[test]
    fn a_secret_class_declaration_withholds_the_raw_value() {
        let policy = Policy::load().expect("policy");
        let mut ids = 0;
        let mut order = 0;
        let mut into = Declarations::default();
        let text = "{\"class\":\"nsec\",\"value\":\"0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9\",\"role\":\"alice\",\"seq\":4}\n";
        parse_decl(&policy, text, &mut ids, &mut order, &mut into).expect("parse");
        let (_, entry) = &into.values[0];
        assert!(entry.raw_withheld);
        assert_eq!(entry.commitment.len(), 64);
        assert_eq!(into.roles, vec!["alice".to_owned()]);
        assert!(entry.planted_confirmed, "absent means confirmed");
    }

    #[test]
    fn planted_confirmed_false_survives_into_the_manifest_entry() {
        let policy = Policy::load().expect("policy");
        let mut ids = 0;
        let mut order = 0;
        let mut into = Declarations::default();
        let text = "{\"class\":\"pubkey\",\"value\":\"0a1b2c3d\",\"planted_confirmed\":false}\n";
        parse_decl(&policy, text, &mut ids, &mut order, &mut into).expect("parse");
        assert!(!into.values[0].1.planted_confirmed);
    }

    #[test]
    fn a_plant_cannot_be_declared_on_the_host() {
        let policy = Policy::load().expect("policy");
        let mut ids = 0;
        let mut into = Declarations::default();
        let err = add_host_decl(
            &policy,
            "plant",
            "logscan-plant-dart-open-ABCDEFGHJK",
            &mut ids,
            &mut into,
        )
        .expect_err("a host plant proves nothing about the app");
        assert!(err.contains("the APP"), "{err}");
    }

    #[test]
    fn a_host_declared_coordinate_must_be_lat_lon() {
        let policy = Policy::load().expect("policy");
        let mut ids = 0;
        let mut into = Declarations::default();
        for bad in [
            "12.345678",
            "12.345678;87.654321",
            "north,east",
            " , ",
            "12,",
        ] {
            let err = add_host_decl(&policy, "coordinate", bad, &mut ids, &mut into)
                .expect_err("a coordinate that is not `lat,lon` must be refused");
            assert!(err.contains("lat,lon"), "{err}");
            assert!(
                !err.contains(bad),
                "an error must not quote the value: {err}"
            );
        }
        add_host_decl(
            &policy,
            "coordinate",
            "-47.209318,-127.478205",
            &mut ids,
            &mut into,
        )
        .expect("the sanctioned shape");
        assert_eq!(into.values.len(), 1);
    }

    /// A canary STEM is a legal host declaration, and it survives the strictest
    /// sink's term floor — which is the whole reason a stem is worth declaring.
    #[test]
    fn a_host_declared_name_stem_is_searchable_in_the_strictest_sink() {
        let policy = Policy::load().expect("policy");
        let mut ids = 0;
        let mut into = Declarations::default();
        add_host_decl(&policy, "circle_name", "Qzvx CIRCLE ", &mut ids, &mut into)
            .expect("a stem is a legal host declaration");
        let declared: Vec<crate::expand::Declared> =
            into.values.iter().map(|(d, _)| d.clone()).collect();
        let expansion = crate::expand::expand(&policy, &declared).expect("expand");
        let floor = policy.sinks["logcat"].term_floor;
        let searchable = expansion
            .terms
            .iter()
            .filter(|t| t.text.chars().count() >= floor)
            .count();
        assert!(
            expansion.terms.iter().any(|t| t.text == "Qzvx CIRCLE "),
            "the stem itself must be searched verbatim"
        );
        assert!(
            searchable > 0,
            "a stem below every sink's term floor would be a declaration that searches for nothing"
        );
    }

    #[test]
    fn a_rules_only_manifest_carries_the_floors_and_nothing_to_search_for() {
        let policy = Policy::load().expect("policy");
        let manifest = Manifest::rules_only(&policy);
        assert!(manifest.terms.is_empty());
        assert!(manifest.plants.is_empty());
        assert!(manifest.values.is_empty());
        assert!(manifest.exempt_endpoints.is_empty());
        assert_eq!(
            manifest.floor("rust-test"),
            policy.sinks["rust-test"].min_lines
        );
        assert_eq!(manifest.floor("drive"), policy.sinks["drive"].min_lines);
    }

    #[test]
    fn endpoint_spellings_cover_host_hostport_and_url() {
        assert_eq!(
            endpoint_spellings("ws://10.0.2.2:7777/"),
            vec![
                "10.0.2.2".to_owned(),
                "10.0.2.2:7777".to_owned(),
                "ws://10.0.2.2:7777".to_owned(),
            ]
        );
        assert_eq!(
            endpoint_spellings("127.0.0.1:7788"),
            vec!["127.0.0.1".to_owned(), "127.0.0.1:7788".to_owned()]
        );
    }
}
