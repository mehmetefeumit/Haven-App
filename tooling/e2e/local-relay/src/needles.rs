//! The device→host NEEDLE DECLARATION channel and the wire-canary manifest
//! sidecar.
//!
//! # Why these files exist
//!
//! The runtime log scanner (`tooling/logscan`) asserts that a value is ABSENT
//! from every captured log. An absence assertion needs the value, and the value
//! cannot be derived from the logs — its absence there is the very thing being
//! asserted. Only the device knows the pubkeys, group ids, names and
//! coordinates its run minted, so the device hands them to the host over the
//! proxy's control channel, exactly as it already hands over the real MLS group
//! id ([`crate::proxy::MlsGroupIdSink`]).
//!
//! # These files are the most sensitive thing on the runner
//!
//! A `.needles.decl` holds declared values VERBATIM — up to and including
//! secret-class material — so it is banned from every upload, echo,
//! `$GITHUB_STEP_SUMMARY` write and issue body by
//! `scripts/ci/check_wire_proxy_test_only.sh`. That ban is keyed on what the
//! file IS (its extension), not on where it lives, because an earlier
//! location-keyed ban on the MLS sidecar was defeated twice by callers moving
//! the path. For the same reason there is deliberately **no environment
//! override here**: [`NEEDLE_DIR`] is a constant, and the only free parameter
//! is the proxy's own instance role, which the launcher already passes in argv.
//!
//! # Journalled nowhere, forwarded never
//!
//! Both verbs are intercepted in [`crate::proxy`] ahead of the recorder: the
//! journal is a corpus the scanner reads, so a declaration recorded there would
//! make every needle "leak" through the announcement the harness made itself.

use std::fs::{DirBuilder, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, PoisonError};

use serde_json::{Map, Value};

/// Directory every needle sidecar lives in.
///
/// A CONSTANT, with no environment override, because the guard that keeps these
/// files out of artifacts has to be able to name them: a relocatable path
/// defeats a path ban (`scripts/ci/check_wire_proxy_test_only.sh`, check 3).
pub const NEEDLE_DIR: &str = "/tmp/haven-soak/needles";

/// Mode the needle directory is created with when absent. Owner only: the file
/// it holds carries declared secret-class values.
#[cfg(unix)]
pub const NEEDLE_DIR_MODE: u32 = 0o700;

/// Mode every needle sidecar is created with.
#[cfg(unix)]
pub const NEEDLE_FILE_MODE: u32 = 0o600;

/// Extension of the per-role declaration sidecar (JSON lines).
pub const DECL_EXTENSION: &str = ".needles.decl";

/// Extension of the per-role wire-canary manifest.
pub const CANARIES_EXTENSION: &str = ".canaries.json";

/// Role used when the launcher passes no instance marker — the same "the
/// `default` instance's files are unsuffixed" convention `start-wire-proxy.sh`
/// uses for the journal and the MLS sidecar.
pub const DEFAULT_ROLE: &str = "default";

/// argv marker `start-wire-proxy.sh` launches every instance with, and the only
/// input that decides which role's sidecars this process writes.
pub const ROLE_ARG_PREFIX: &str = "--haven-wire-proxy-instance=";

/// Most bytes one control payload may carry.
///
/// Generous next to any plausible declaration (a coordinate pair, an npub, a
/// circle name) and bounded because the payload is appended to a file and the
/// sidecar would otherwise grow without limit. An oversized payload is REFUSED
/// and reported, never truncated: half a value is a needle that matches nothing
/// and a run that reports clean for the wrong reason.
pub const MAX_PAYLOAD_BYTES: usize = 4096;

/// Keys the DECLARATION sidecar writes itself, so a declaration payload may not
/// carry them.
///
/// The line is "the frame's object plus `role` and `seq`", and silently
/// overwriting a harness-supplied `role` would make the two disagree with no
/// trace. Refusing is loud, and the harness learns at once (no ack).
///
/// The canary manifest is exempt: nothing is added to it, and its own `role`
/// field (the scenario's device role, not the proxy instance) is part of the
/// object `check-wire-canaries.dart` parses.
pub const RESERVED_KEYS: [&str; 2] = ["role", "seq"];

/// Why a role could not be used.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RoleRejection {
    /// Empty, or contains a character outside `[A-Za-z0-9._-]`.
    ///
    /// The role becomes a path component, so the charset is the same one
    /// `start-wire-proxy.sh` validates its instance name against — a role
    /// carrying `/` or `..` would write outside [`NEEDLE_DIR`].
    NotAnInstanceName,
}

impl RoleRejection {
    /// A fixed, enumerable label for logs.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::NotAnInstanceName => "not an instance name ([A-Za-z0-9._-]+)",
        }
    }
}

/// The instance role this process serves, read from argv.
///
/// # Errors
///
/// [`RoleRejection`] when the marker carries something that cannot be a path
/// component. Absent marker is not an error — it means [`DEFAULT_ROLE`].
pub fn role_from_args<S: AsRef<str>>(args: &[S]) -> Result<String, RoleRejection> {
    let Some(raw) = args
        .iter()
        .filter_map(|a| a.as_ref().strip_prefix(ROLE_ARG_PREFIX))
        .next_back()
    else {
        return Ok(DEFAULT_ROLE.to_owned());
    };
    if raw.is_empty()
        || !raw
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
    {
        return Err(RoleRejection::NotAnInstanceName);
    }
    Ok(raw.to_owned())
}

/// Path of `role`'s declaration sidecar.
#[must_use]
pub fn decl_path(role: &str) -> PathBuf {
    Path::new(NEEDLE_DIR).join(format!("{role}{DECL_EXTENSION}"))
}

/// Path of `role`'s wire-canary manifest.
#[must_use]
pub fn canaries_path(role: &str) -> PathBuf {
    Path::new(NEEDLE_DIR).join(format!("{role}{CANARIES_EXTENSION}"))
}

/// Why the needle directory cannot be used.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DirRejection {
    /// A symlink sits at the path.
    ///
    /// Following it would write the declared values wherever it points — out
    /// from under the extension bans in
    /// `scripts/ci/check_wire_proxy_test_only.sh`, which is the relocation
    /// defeat arriving through the filesystem instead of through an env var.
    Symlink,
    /// Something that is not a directory sits at the path.
    NotADirectory,
    /// A directory whose mode is not exactly [`NEEDLE_DIR_MODE`].
    ///
    /// The files in it hold every value a run declared, secret-class material
    /// included, so group- or world-readable is a disclosure. The scanner side
    /// refuses anything but `0700` too; a proxy that accepted more would write
    /// a file the scanner then declines to read.
    WrongMode,
}

impl DirRejection {
    /// A fixed, enumerable label for logs.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Symlink => "is a symlink",
            Self::NotADirectory => "is not a directory",
            Self::WrongMode => "is not mode 0700",
        }
    }
}

/// Checks that `dir` is usable for the needle sidecars.
///
/// An ABSENT directory is fine — [`create_dir`] makes it owner-only. What is
/// refused is a pre-existing path that is a symlink, is not a directory, or is a
/// directory with any other mode.
///
/// # Errors
///
/// The [`DirRejection`] naming which rule the path broke.
pub fn verify_dir(dir: &Path) -> Result<(), DirRejection> {
    // `symlink_metadata`, never `metadata`: the latter follows the link and
    // would report the TARGET's type and mode, which is the case being refused.
    let Ok(metadata) = std::fs::symlink_metadata(dir) else {
        return Ok(());
    };
    if metadata.file_type().is_symlink() {
        return Err(DirRejection::Symlink);
    }
    if !metadata.is_dir() {
        return Err(DirRejection::NotADirectory);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o777 != NEEDLE_DIR_MODE {
            return Err(DirRejection::WrongMode);
        }
    }
    Ok(())
}

/// The startup line a refused needle directory is reported with.
///
/// Fixed text plus the constant path and the rejection's label — the same
/// discipline as every other notice here: nothing a reader of the CI log could
/// scan for.
#[must_use]
pub fn dir_refusal_notice(dir: &Path, reason: DirRejection) -> String {
    format!(
        "haven-wire-proxy: refusing to use the needle directory {} — it {}. It holds every value \
         a run declares, so it must be an owner-only directory (0700) and not a symlink. Remove \
         or fix it and start again.",
        dir.display(),
        reason.as_str()
    )
}

/// Why a control payload was refused.
///
/// The proxy validates the payload's SHAPE and nothing else: it never reads
/// `class`, `value` or any other field, so a new needle class needs no change
/// here and a malformed one is the scanner's to report.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PayloadRejection {
    /// Not a JSON object (the frame carried an array, a string, or nothing).
    NotAnObject,
    /// An object with no members declares nothing.
    Empty,
    /// Longer than [`MAX_PAYLOAD_BYTES`].
    TooLarge,
    /// A DECLARATION carrying one of [`RESERVED_KEYS`].
    ReservedKey,
}

impl PayloadRejection {
    /// A fixed, enumerable label for logs. Never the payload: the values it
    /// carries are exactly what the scanner asserts are absent from every log.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::NotAnObject => "not a JSON object",
            Self::Empty => "an empty object declares nothing",
            Self::TooLarge => "longer than 4096 bytes",
            Self::ReservedKey => "carries the reserved key 'role' or 'seq'",
        }
    }
}

/// Validates one control payload's SHAPE and returns its members.
///
/// "One JSON object on one line" is two properties and only the first needs
/// checking: the payload arrived inside a parsed WebSocket text frame and is
/// re-serialised with `serde_json`, which escapes every control character, so a
/// value carrying a newline cannot split the line.
///
/// # Errors
///
/// The [`PayloadRejection`] naming which rule the payload broke.
pub fn validate_payload(payload: &Value) -> Result<&Map<String, Value>, PayloadRejection> {
    let object = payload.as_object().ok_or(PayloadRejection::NotAnObject)?;
    if object.is_empty() {
        return Err(PayloadRejection::Empty);
    }
    if payload.to_string().len() > MAX_PAYLOAD_BYTES {
        return Err(PayloadRejection::TooLarge);
    }
    Ok(object)
}

/// Validates one NEEDLE DECLARATION: the shape, plus the keys the sidecar owns.
///
/// # Errors
///
/// The [`PayloadRejection`] naming which rule the payload broke.
pub fn validate_declaration(payload: &Value) -> Result<&Map<String, Value>, PayloadRejection> {
    let object = validate_payload(payload)?;
    if RESERVED_KEYS.iter().any(|key| object.contains_key(*key)) {
        return Err(PayloadRejection::ReservedKey);
    }
    Ok(object)
}

/// What the proxy did with one declaration.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Declared {
    /// Appended to the sidecar as line `seq`.
    Recorded(u64),
    /// Refused by [`validate_payload`]; nothing was written.
    Refused(PayloadRejection),
    /// No sidecar path is configured, so it went nowhere.
    Unconfigured,
    /// The sidecar could not be appended to.
    Unwritable(std::io::ErrorKind),
}

/// The outcome of one declaration plus what to answer the client with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Declaration {
    /// What happened to the payload.
    pub outcome: Declared,
    /// The line number to ack with, present exactly when the line is in the
    /// sidecar. A refused or lost declaration is NOT acked: an ack has to mean
    /// the host holds the needle, or a lane would scan for a value the scanner
    /// was never given and report clean.
    pub ack: Option<u64>,
}

/// Health of the declaration sidecar, for the shutdown summary.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct NeedleStats {
    /// Lines this process appended.
    pub recorded: u64,
    /// Declarations refused by [`validate_payload`].
    pub refused: u64,
    /// Declarations the host will never see (unwritable or unconfigured).
    pub lost: u64,
    /// `true` when the first write found the sidecar ALREADY THERE.
    ///
    /// A leftover file means a previous run's values are about to be handed to
    /// this run's scanner as ground truth, which can only ever ADD needles that
    /// were never on this wire — an assertion that cannot fail, the one failure
    /// mode a privacy oracle must not have. The lane rotates these files; this
    /// says so when it did not.
    pub stale: bool,
}

/// Append-only JSON-lines sink for the needles a device declares.
///
/// One line per declaration: the payload's members, plus `role` and `seq`, and
/// NO timestamp — an instant is an identifier (Security Rule 15), and the
/// sequence number carries the ordering a consumer actually needs.
pub struct NeedleSink {
    inner: Mutex<NeedleInner>,
}

struct NeedleInner {
    role: String,
    path: Option<PathBuf>,
    /// `false` until this process has created or appended to the file, which is
    /// what makes "create exclusively on FIRST write" a per-run property rather
    /// than a per-line one.
    opened: bool,
    next_seq: u64,
    stats: NeedleStats,
}

impl NeedleSink {
    /// A sink appending `role`'s declarations to `path`.
    #[must_use]
    pub fn new(role: String, path: PathBuf) -> Self {
        Self::with_optional_path(role, Some(path))
    }

    /// A sink that records nothing, for callers with no host-side scanner.
    #[must_use]
    pub fn disabled() -> Self {
        Self::with_optional_path(DEFAULT_ROLE.to_owned(), None)
    }

    fn with_optional_path(role: String, path: Option<PathBuf>) -> Self {
        Self {
            inner: Mutex::new(NeedleInner {
                role,
                path,
                opened: false,
                next_seq: 0,
                stats: NeedleStats::default(),
            }),
        }
    }

    /// Validates and appends one declaration.
    ///
    /// Reports every outcome on stderr by LABEL and LENGTH — never the payload,
    /// which is the material the scanner asserts is absent from every log.
    pub fn declare(&self, conn_id: &str, payload: &Value) -> Declaration {
        let declared_len = payload.to_string().len();
        let mut inner = self.lock();

        let line = match validate_declaration(payload) {
            Ok(object) => sidecar_line(object, &inner.role, inner.next_seq),
            Err(reason) => {
                inner.stats.refused = inner.stats.refused.wrapping_add(1);
                drop(inner);
                let outcome = Declared::Refused(reason);
                eprintln!("{}", declaration_notice(conn_id, declared_len, outcome));
                return Declaration { outcome, ack: None };
            }
        };

        let seq = inner.next_seq;
        let Some(path) = inner.path.clone() else {
            inner.stats.lost = inner.stats.lost.wrapping_add(1);
            drop(inner);
            let outcome = Declared::Unconfigured;
            eprintln!("{}", declaration_notice(conn_id, declared_len, outcome));
            return Declaration { outcome, ack: None };
        };

        let first_write = !inner.opened;
        let outcome = match append_line(&path, &line, first_write) {
            Ok(existed) => {
                inner.opened = true;
                inner.next_seq = seq.wrapping_add(1);
                inner.stats.recorded = inner.stats.recorded.wrapping_add(1);
                inner.stats.stale |= first_write && existed;
                Declared::Recorded(seq)
            }
            Err(err) => {
                inner.stats.lost = inner.stats.lost.wrapping_add(1);
                Declared::Unwritable(err.kind())
            }
        };
        let stale = inner.stats.stale;
        drop(inner);

        eprintln!("{}", declaration_notice(conn_id, declared_len, outcome));
        if stale && first_write {
            eprintln!(
                "[haven-wire-proxy] {conn_id}: the needle sidecar ALREADY EXISTED at this \
                 process's first declaration, so an earlier run's values will be handed to this \
                 run's scanner as ground truth and can never be found. The lane rotates it; a \
                 hand-run should too."
            );
        }
        Declaration {
            ack: match outcome {
                Declared::Recorded(seq) => Some(seq),
                _ => None,
            },
            outcome,
        }
    }

    /// Current health snapshot.
    #[must_use]
    pub fn stats(&self) -> NeedleStats {
        self.lock().stats
    }

    /// A poison-tolerant lock: a panic elsewhere must not turn this sink into a
    /// way for the instrument to kill the traffic it observes.
    fn lock(&self) -> MutexGuard<'_, NeedleInner> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl Default for NeedleSink {
    fn default() -> Self {
        Self::disabled()
    }
}

/// What the proxy did with one wire-canary manifest.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Announced {
    /// Appended; the sidecar now holds this many manifest lines.
    Recorded(u64),
    /// Byte-identical to a manifest the sidecar already holds, so nothing was
    /// written. Carries the lines held.
    ///
    /// The harness re-announces on reconnect exactly as it re-declares a circle,
    /// and a repeat that says the same thing adds nothing.
    Unchanged(u64),
    /// Refused by [`validate_payload`].
    Refused(PayloadRejection),
    /// No manifest path is configured.
    Unconfigured,
    /// The manifest could not be written.
    Unwritable(std::io::ErrorKind),
}

/// The outcome of one announcement plus what to answer the client with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Announcement {
    /// What happened to the manifest.
    pub outcome: Announced,
    /// Manifest lines the sidecar holds, present exactly when the host holds
    /// THIS manifest. A refused or lost announcement is not acked: an ack has to
    /// mean the oracle can read it.
    pub ack: Option<u64>,
}

/// Health of the canary sidecar, for the shutdown summary.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CanaryStats {
    /// Distinct manifests this process appended.
    pub recorded: u64,
    /// Byte-identical re-announcements.
    pub repeats: u64,
    /// Announcements refused on shape.
    pub refused: u64,
    /// Announcements the host will never see.
    pub lost: u64,
    /// `true` when the first write found the sidecar ALREADY THERE — see
    /// [`NeedleStats::stale`].
    pub stale: bool,
}

/// Append-only JSON-lines sink for the wire-canary manifests a run announces.
///
/// One line per DISTINCT manifest, appended, never overwritten: the Android
/// lane's connect-flake retry re-runs the drive target inside the same proxy
/// instance and re-mints its plant, so a run legitimately announces more than
/// one manifest — and `check-wire-canaries.dart` grades every manifest it
/// parses, which is why it used to read all of them out of one concatenated
/// drive log. Overwriting would silently drop a planted manifest from the
/// verdict; refusing the second would lose a whole attempt's canaries.
pub struct CanarySink {
    inner: Mutex<CanaryInner>,
}

struct CanaryInner {
    path: Option<PathBuf>,
    /// `false` until this process has created or appended to the file — what
    /// makes "create exclusively on FIRST write" a per-run property.
    opened: bool,
    stats: CanaryStats,
}

impl CanarySink {
    /// A sink appending manifests to `path`.
    #[must_use]
    pub const fn new(path: PathBuf) -> Self {
        Self::with_optional_path(Some(path))
    }

    /// A sink that records nothing.
    #[must_use]
    pub const fn disabled() -> Self {
        Self::with_optional_path(None)
    }

    const fn with_optional_path(path: Option<PathBuf>) -> Self {
        Self {
            inner: Mutex::new(CanaryInner {
                path,
                opened: false,
                stats: CanaryStats {
                    recorded: 0,
                    repeats: 0,
                    refused: 0,
                    lost: 0,
                    stale: false,
                },
            }),
        }
    }

    /// Validates and appends one manifest.
    pub fn announce(&self, conn_id: &str, payload: &Value) -> Announcement {
        let declared_len = payload.to_string().len();
        let mut inner = self.lock();

        if let Err(reason) = validate_payload(payload) {
            inner.stats.refused = inner.stats.refused.wrapping_add(1);
            drop(inner);
            let outcome = Announced::Refused(reason);
            eprintln!("{}", manifest_notice(conn_id, declared_len, outcome));
            return Announcement { outcome, ack: None };
        }

        let Some(path) = inner.path.clone() else {
            inner.stats.lost = inner.stats.lost.wrapping_add(1);
            drop(inner);
            let outcome = Announced::Unconfigured;
            eprintln!("{}", manifest_notice(conn_id, declared_len, outcome));
            return Announcement { outcome, ack: None };
        };

        // The manifest's own members and NOTHING else — no role, no seq, no
        // timestamp — so `check-wire-canaries.dart` reads the object the scenario
        // minted. Member order is the JSON writer's; the members are untouched.
        let line = format!("{payload}\n");
        // The FILE is the ground truth, never an in-memory mirror: an external
        // rotation must make a re-announcement write again rather than be waved
        // through as already held (the reasoning `sidecar_ids` records for the
        // MLS sink).
        let held = manifest_lines(&path);
        if held.iter().any(|existing| *existing == line.trim_end()) {
            inner.stats.repeats = inner.stats.repeats.wrapping_add(1);
            let lines = held.len() as u64;
            drop(inner);
            let outcome = Announced::Unchanged(lines);
            eprintln!("{}", manifest_notice(conn_id, declared_len, outcome));
            return Announcement {
                outcome,
                ack: Some(lines),
            };
        }

        let first_write = !inner.opened;
        let outcome = match append_line(&path, &line, first_write) {
            Ok(existed) => {
                inner.opened = true;
                inner.stats.recorded = inner.stats.recorded.wrapping_add(1);
                inner.stats.stale |= first_write && existed;
                Announced::Recorded(held.len() as u64 + 1)
            }
            Err(err) => {
                inner.stats.lost = inner.stats.lost.wrapping_add(1);
                Announced::Unwritable(err.kind())
            }
        };
        let stale = inner.stats.stale;
        drop(inner);

        eprintln!("{}", manifest_notice(conn_id, declared_len, outcome));
        if stale && first_write {
            eprintln!(
                "[haven-wire-proxy] {conn_id}: the canary sidecar ALREADY EXISTED at this \
                 process's first announcement, so an earlier run's manifest will be graded as \
                 part of this run. The lane rotates it; a hand-run should too."
            );
        }
        Announcement {
            ack: match outcome {
                Announced::Recorded(lines) => Some(lines),
                _ => None,
            },
            outcome,
        }
    }

    /// Current health snapshot.
    #[must_use]
    pub fn stats(&self) -> CanaryStats {
        self.lock().stats
    }

    fn lock(&self) -> MutexGuard<'_, CanaryInner> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl Default for CanarySink {
    fn default() -> Self {
        Self::disabled()
    }
}

/// The sidecar line for one declaration: the payload's members plus `role` and
/// `seq`, on one line, with no timestamp.
///
/// `serde_json::Map` is a `BTreeMap` here (the `preserve_order` feature is off),
/// so the rendering is deterministic whatever order the members arrived in.
fn sidecar_line(object: &Map<String, Value>, role: &str, seq: u64) -> String {
    let mut line = object.clone();
    line.insert("role".to_owned(), Value::String(role.to_owned()));
    line.insert("seq".to_owned(), Value::from(seq));
    format!("{}\n", Value::Object(line))
}

/// Appends one line, creating the directory and the file if needed.
///
/// `exclusive` asks for the file to be CREATED here (`O_EXCL`, mode 0600) —
/// true on a process's first write, so a run says so when it found a sidecar it
/// did not create. Answers whether the file already existed.
fn append_line(path: &Path, line: &str, exclusive: bool) -> std::io::Result<bool> {
    if let Some(parent) = path.parent() {
        create_dir(parent)?;
    }
    if exclusive {
        match create_exclusive(path) {
            Ok(mut file) => {
                write_all(&mut file, line)?;
                return Ok(false);
            }
            // The stale case: append rather than drop the declaration. A
            // declaration the host never receives narrows the scan silently,
            // which is strictly worse than a contaminated file the summary
            // names out loud.
            Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(err) => return Err(err),
        }
    }
    let mut file = OpenOptions::new().create(true).append(true).open(path)?;
    write_all(&mut file, line)?;
    Ok(true)
}

/// Creates `dir` (and its parents) owner-only when absent, and REFUSES a
/// pre-existing one that is not exactly an owner-only directory.
///
/// The write path enforces the same rule [`verify_dir`] does at startup, so a
/// directory swapped under a running proxy cannot make the next declaration land
/// somewhere world-readable or outside this path.
fn create_dir(dir: &Path) -> std::io::Result<()> {
    if let Err(reason) = verify_dir(dir) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            reason.as_str(),
        ));
    }
    if dir.is_dir() {
        return Ok(());
    }
    let mut builder = DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(NEEDLE_DIR_MODE);
    }
    builder.create(dir)?;
    // `mkdir(2)` masks the requested mode with the process umask, so the
    // creation alone does not guarantee 0700 — and the check above would then
    // refuse the directory this function just made. Set it explicitly.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(NEEDLE_DIR_MODE))?;
    }
    Ok(())
}

/// Creates a file that must not exist yet, owner-readable only.
fn create_exclusive(path: &Path) -> std::io::Result<std::fs::File> {
    if let Some(parent) = path.parent() {
        create_dir(parent)?;
    }
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(NEEDLE_FILE_MODE);
    }
    options.open(path)
}

fn write_all(file: &mut std::fs::File, line: &str) -> std::io::Result<()> {
    file.write_all(line.as_bytes())?;
    file.flush()
}

/// Builds the stderr line for one declaration.
///
/// SECURITY RULE 15: the declared value is never interpolated. The line carries
/// a length, a fixed label and the connection — enough to debug a refusal, and
/// nothing a reader of the CI log could scan for.
fn declaration_notice(conn_id: &str, declared_len: usize, outcome: Declared) -> String {
    match outcome {
        Declared::Recorded(seq) => format!(
            "[haven-wire-proxy] {conn_id}: needle declared ({declared_len} bytes) as line {seq}."
        ),
        Declared::Refused(reason) => format!(
            "[haven-wire-proxy] {conn_id}: REFUSED a needle declaration ({}, {declared_len} \
             bytes). It was neither forwarded nor journalled, and the host has no ground truth \
             for it — the scanner would search for nothing and report clean.",
            reason.as_str()
        ),
        Declared::Unconfigured => format!(
            "[haven-wire-proxy] {conn_id}: a needle was declared ({declared_len} bytes) but this \
             proxy has NO needle sidecar, so it went nowhere."
        ),
        Declared::Unwritable(kind) => format!(
            "[haven-wire-proxy] {conn_id}: could not append a declared needle ({declared_len} \
             bytes) to the sidecar ({kind:?}); the host will not see it."
        ),
    }
}

/// The manifest lines the sidecar holds, read fresh (see [`CanarySink`]).
fn manifest_lines(path: &Path) -> Vec<String> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .filter(|line| !line.is_empty())
        .map(str::to_owned)
        .collect()
}

/// Builds the stderr line for one manifest announcement. Same rule: label,
/// length, connection — never the manifest.
fn manifest_notice(conn_id: &str, declared_len: usize, outcome: Announced) -> String {
    match outcome {
        Announced::Recorded(lines) => format!(
            "[haven-wire-proxy] {conn_id}: wire-canary manifest recorded ({declared_len} bytes); \
             {lines} manifest line(s) in the sidecar."
        ),
        Announced::Unchanged(lines) => format!(
            "[haven-wire-proxy] {conn_id}: wire-canary manifest re-announced unchanged \
             ({declared_len} bytes); nothing was rewritten, {lines} line(s) held."
        ),
        Announced::Refused(reason) => format!(
            "[haven-wire-proxy] {conn_id}: REFUSED a wire-canary manifest ({}, {declared_len} \
             bytes); the oracle has no manifest to read.",
            reason.as_str()
        ),
        Announced::Unconfigured => format!(
            "[haven-wire-proxy] {conn_id}: a wire-canary manifest was announced \
             ({declared_len} bytes) but this proxy has NO manifest path, so it went nowhere."
        ),
        Announced::Unwritable(kind) => format!(
            "[haven-wire-proxy] {conn_id}: could not write the wire-canary manifest \
             ({declared_len} bytes) ({kind:?}); the oracle has nothing to read."
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(tag: &str) -> PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.subsec_nanos());
        std::env::temp_dir().join(format!(
            "haven-wire-proxy-needles-{}-{tag}-{nanos}",
            std::process::id()
        ))
    }

    fn payload(json: &str) -> Value {
        serde_json::from_str(json).expect("fixture payload is JSON")
    }

    fn lines(path: &Path) -> Vec<String> {
        std::fs::read_to_string(path)
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    // THE LINE FORMAT, which `haven-logscan seal` parses and agent H's harness
    // writes against: the frame's object verbatim, plus role and seq, and NO
    // timestamp (an instant is an identifier — Security Rule 15).
    #[test]
    fn a_declaration_lands_as_the_frames_object_plus_role_and_seq() {
        let dir = scratch("line");
        let path = dir.join("alice.needles.decl");
        let sink = NeedleSink::new("alice".to_owned(), path.clone());

        let declaration = sink.declare("c0", &payload(r#"{"class":"pubkey","value":"abcd"}"#));

        assert_eq!(declaration.outcome, Declared::Recorded(0));
        assert_eq!(declaration.ack, Some(0));
        assert_eq!(
            lines(&path),
            vec![r#"{"class":"pubkey","role":"alice","seq":0,"value":"abcd"}"#],
            "the sidecar line is a contract: the payload's members plus role and seq, nothing else"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn each_declaration_takes_the_next_seq_and_one_line() {
        let dir = scratch("seq");
        let path = dir.join("alice.needles.decl");
        let sink = NeedleSink::new("alice".to_owned(), path.clone());

        for expected in 0..3_u64 {
            let declaration = sink.declare("c0", &payload(r#"{"class":"event_id","value":"ab"}"#));
            assert_eq!(declaration.ack, Some(expected));
        }

        let seqs: Vec<Value> = lines(&path)
            .iter()
            .map(|l| {
                serde_json::from_str::<Value>(l).expect("one JSON object per line")["seq"].clone()
            })
            .collect();
        assert_eq!(seqs, vec![Value::from(0), Value::from(1), Value::from(2)]);
        assert_eq!(sink.stats().recorded, 3);
        // A repeated value is NOT de-duplicated: unlike an MLS group id, two
        // declarations of one value can be two different needles (two circles
        // may share a display name), and dropping one would narrow the scan.
        assert_eq!(lines(&path).len(), 3);
        let _ = std::fs::remove_dir_all(&dir);
    }

    // A value carrying a newline must not be able to forge a second line.
    #[test]
    fn a_value_with_a_newline_stays_one_line() {
        let dir = scratch("newline");
        let path = dir.join("alice.needles.decl");
        let sink = NeedleSink::new("alice".to_owned(), path.clone());

        sink.declare(
            "c0",
            &payload(r#"{"class":"display_name","value":"a\nb\r\nc"}"#),
        );

        let held = lines(&path);
        assert_eq!(held.len(), 1, "a newline in a value split the sidecar line");
        let parsed: Value = serde_json::from_str(&held[0]).expect("still one JSON object");
        assert_eq!(
            parsed["value"], "a\nb\r\nc",
            "...without altering the value"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_directory_is_created_owner_only_and_the_file_is_created_owner_only() {
        let dir = scratch("modes");
        let path = dir.join("nested").join("alice.needles.decl");
        let sink = NeedleSink::new("alice".to_owned(), path.clone());

        assert_eq!(
            sink.declare("c0", &payload(r#"{"class":"nsec"}"#)).ack,
            Some(0)
        );

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let dir_mode = std::fs::metadata(path.parent().expect("parent"))
                .expect("the sidecar directory exists")
                .permissions()
                .mode()
                & 0o777;
            let file_mode = std::fs::metadata(&path)
                .expect("the sidecar exists")
                .permissions()
                .mode()
                & 0o777;
            assert_eq!(
                dir_mode, NEEDLE_DIR_MODE,
                "the needle directory must be owner-only"
            );
            assert_eq!(
                file_mode, NEEDLE_FILE_MODE,
                "the sidecar holds declared secret-class values and must be owner-only"
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    // A leftover file from an earlier run would hand this run's scanner needles
    // that were never on this wire — an assertion that cannot fail. The
    // declaration is still kept (losing it narrows the scan silently), and the
    // contamination is reported.
    #[test]
    fn a_pre_existing_sidecar_is_appended_to_and_reported_as_stale() {
        let dir = scratch("stale");
        // The PRODUCT's directory creation, not `create_dir_all`: an owner-only
        // directory is what a real run has, and a fixture that built a
        // group-readable one would exercise the unsafe-directory refusal
        // instead of the stale-file path this test is about.
        create_dir(&dir).expect("fixture dir");
        let path = dir.join("alice.needles.decl");
        std::fs::write(
            &path,
            "{\"class\":\"pubkey\",\"role\":\"alice\",\"seq\":0}\n",
        )
        .expect("seed a previous run's file");
        let sink = NeedleSink::new("alice".to_owned(), path.clone());

        assert!(sink
            .declare("c0", &payload(r#"{"class":"pubkey"}"#))
            .ack
            .is_some());

        assert_eq!(lines(&path).len(), 2, "the declaration must not be dropped");
        assert!(
            sink.stats().stale,
            "a sidecar this process did not create must be reported, or a previous run's values \
             become this run's ground truth in silence"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_payload_that_is_not_an_object_is_refused_and_never_written() {
        let dir = scratch("shape");
        let path = dir.join("alice.needles.decl");
        let sink = NeedleSink::new("alice".to_owned(), path.clone());

        for (raw, want) in [
            ("[]", PayloadRejection::NotAnObject),
            (r#""a string""#, PayloadRejection::NotAnObject),
            ("null", PayloadRejection::NotAnObject),
            ("{}", PayloadRejection::Empty),
            (
                r#"{"role":"x","class":"pubkey"}"#,
                PayloadRejection::ReservedKey,
            ),
            (
                r#"{"seq":1,"class":"pubkey"}"#,
                PayloadRejection::ReservedKey,
            ),
        ] {
            let declaration = sink.declare("c0", &payload(raw));
            assert_eq!(declaration.outcome, Declared::Refused(want), "{raw}");
            assert!(
                declaration.ack.is_none(),
                "a refused payload must not be acked"
            );
        }
        let mut big = Map::new();
        big.insert(
            "value".to_owned(),
            Value::String("x".repeat(MAX_PAYLOAD_BYTES)),
        );
        let oversized = Value::Object(big);
        assert_eq!(
            sink.declare("c0", &oversized).outcome,
            Declared::Refused(PayloadRejection::TooLarge)
        );
        assert!(
            !path.exists(),
            "a refused payload must not even create the sidecar"
        );
        assert_eq!(sink.stats().refused, 7);
        assert_eq!(sink.stats().recorded, 0);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_sink_with_no_path_loses_the_declaration_loudly_instead_of_acking_it() {
        let sink = NeedleSink::disabled();

        let declaration = sink.declare("c0", &payload(r#"{"class":"pubkey"}"#));

        assert_eq!(declaration.outcome, Declared::Unconfigured);
        assert!(
            declaration.ack.is_none(),
            "an ack must mean the host holds the needle"
        );
        assert_eq!(sink.stats().lost, 1);
    }

    #[test]
    fn an_unwritable_sidecar_is_counted_and_not_acked() {
        let dir = scratch("unwritable");
        create_dir(&dir).expect("fixture dir");
        // A DIRECTORY where the file belongs: every open for writing fails with
        // EISDIR, and no privilege makes it succeed.
        let path = dir.join("alice.needles.decl");
        std::fs::create_dir_all(&path).expect("fixture directory in place of the file");
        let sink = NeedleSink::new("alice".to_owned(), path);

        let declaration = sink.declare("c0", &payload(r#"{"class":"pubkey"}"#));

        assert!(matches!(declaration.outcome, Declared::Unwritable(_)));
        assert!(declaration.ack.is_none());
        assert_eq!(sink.stats().lost, 1);
        assert_eq!(sink.stats().recorded, 0);
        let _ = std::fs::remove_dir_all(&dir);
    }

    // SECURITY RULE 15. Every line these sinks emit outlives the runner in a CI
    // log, so none of them may carry a declared value.
    #[test]
    fn no_notice_ever_interpolates_the_payload() {
        const VALUE: &str = "npub1exampleexampleexample";
        for outcome in [
            Declared::Recorded(3),
            Declared::Refused(PayloadRejection::NotAnObject),
            Declared::Unconfigured,
            Declared::Unwritable(std::io::ErrorKind::PermissionDenied),
        ] {
            let notice = declaration_notice("c0", VALUE.len(), outcome);
            assert!(
                !notice.contains(VALUE),
                "{outcome:?} leaked the payload: {notice}"
            );
        }
        for outcome in [
            Announced::Recorded(2),
            Announced::Unchanged(2),
            Announced::Refused(PayloadRejection::Empty),
            Announced::Unconfigured,
            Announced::Unwritable(std::io::ErrorKind::PermissionDenied),
        ] {
            let notice = manifest_notice("c0", VALUE.len(), outcome);
            assert!(
                !notice.contains(VALUE),
                "{outcome:?} leaked the manifest: {notice}"
            );
        }
    }

    #[test]
    fn every_rejection_label_is_distinct_and_non_empty() {
        let labels: Vec<&str> = [
            PayloadRejection::NotAnObject,
            PayloadRejection::Empty,
            PayloadRejection::TooLarge,
            PayloadRejection::ReservedKey,
        ]
        .iter()
        .map(|r| r.as_str())
        .chain(std::iter::once(RoleRejection::NotAnInstanceName.as_str()))
        .collect();
        let mut unique = labels.clone();
        unique.sort_unstable();
        unique.dedup();
        assert_eq!(unique.len(), labels.len(), "labels must be distinguishable");
        assert!(labels.iter().all(|l| !l.is_empty()));
    }

    // ---------------------------------------------------------------------
    // The canary manifest
    // ---------------------------------------------------------------------

    #[test]
    fn a_manifest_is_appended_with_its_members_untouched() {
        let dir = scratch("manifest");
        let path = dir.join("alice.canaries.json");
        let sink = CanarySink::new(path.clone());
        let manifest = payload(r#"{"role":"alice","petname":"Quiet Wanderer","latitude":-47.2}"#);

        let announcement = sink.announce("c0", &manifest);

        assert_eq!(announcement.outcome, Announced::Recorded(1));
        assert_eq!(
            announcement.ack,
            Some(1),
            "the ack counts the manifest lines the oracle can read"
        );
        assert_eq!(
            std::fs::read_to_string(&path).expect("the manifest exists"),
            format!("{manifest}\n"),
            "the manifest's members must reach the file untouched — check-wire-canaries.dart \
             parses the object the scenario minted, not a re-shaped one"
        );
        assert_eq!(sink.stats().recorded, 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    // A reconnecting harness re-announces; a repeat that says the same thing adds
    // nothing, and appending it would make the oracle grade one manifest twice.
    #[test]
    fn a_byte_identical_re_announcement_is_idempotent() {
        let dir = scratch("repeat");
        let path = dir.join("alice.canaries.json");
        let sink = CanarySink::new(path.clone());
        let manifest = payload(r#"{"role":"alice","petname":"Quiet Wanderer"}"#);

        assert_eq!(
            sink.announce("c0", &manifest).outcome,
            Announced::Recorded(1)
        );
        let announcement = sink.announce("c1", &manifest);

        assert_eq!(announcement.outcome, Announced::Unchanged(1));
        assert_eq!(
            announcement.ack,
            Some(1),
            "a repeat must still be acked, or a reconnecting harness would hang"
        );
        assert_eq!(sink.stats().repeats, 1);
        assert_eq!(sink.stats().recorded, 1, "nothing was appended");
        assert_eq!(
            std::fs::read_to_string(&path).expect("the manifest exists"),
            format!("{manifest}\n")
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    // A second, DIFFERENT manifest is a second attempt's plant, not a fault: the
    // Android lane's connect-flake retry re-runs the drive target inside this
    // same proxy instance and re-mints its canaries. `check-wire-canaries.dart`
    // grades every manifest it parses, so both lines must be there — overwriting
    // would drop an attempt's canaries from the verdict in silence.
    #[test]
    fn a_second_distinct_manifest_is_appended_as_a_further_line() {
        let dir = scratch("append");
        let path = dir.join("alice.canaries.json");
        let sink = CanarySink::new(path.clone());
        let first = payload(r#"{"role":"alice","petname":"Quiet Wanderer"}"#);
        let second = payload(r#"{"role":"alice","petname":"Loud Wanderer"}"#);

        assert_eq!(sink.announce("c0", &first).outcome, Announced::Recorded(1));
        let announcement = sink.announce("c1", &second);

        assert_eq!(announcement.outcome, Announced::Recorded(2));
        assert_eq!(announcement.ack, Some(2), "the ack counts both lines");
        assert_eq!(
            lines(&path),
            vec![first.to_string(), second.to_string()],
            "both manifests must be held, in the order announced"
        );
        let stats = sink.stats();
        assert_eq!(stats.recorded, 2);
        assert_eq!(stats.repeats, 0);
        assert!(!stats.stale);
        let _ = std::fs::remove_dir_all(&dir);
    }

    // A leftover file from an earlier run is appended to and REPORTED, exactly
    // like the declaration sidecar: dropping this run's manifest would leave the
    // oracle grading only the previous run's canaries, which is worse than
    // grading both and saying so.
    #[test]
    fn a_stale_manifest_from_an_earlier_run_is_appended_to_and_reported() {
        let dir = scratch("stale-manifest");
        // The PRODUCT's directory creation, not `create_dir_all`: an owner-only
        // directory is what a real run has, and a fixture that built a
        // group-readable one would exercise the unsafe-directory refusal
        // instead of the stale-file path this test is about.
        create_dir(&dir).expect("fixture dir");
        let path = dir.join("alice.canaries.json");
        std::fs::write(&path, "{\"role\":\"alice\",\"petname\":\"Previous Run\"}\n")
            .expect("seed a previous run's manifest");
        let sink = CanarySink::new(path.clone());

        let announcement = sink.announce("c0", &payload(r#"{"role":"alice","petname":"Now"}"#));

        assert_eq!(announcement.outcome, Announced::Recorded(2));
        assert_eq!(announcement.ack, Some(2));
        let held = lines(&path);
        assert_eq!(held.len(), 2, "this run's manifest must not be dropped");
        assert!(
            held[0].contains("Previous Run"),
            "a stale manifest must not be silently overwritten either"
        );
        assert!(
            sink.stats().stale,
            "a sidecar this process did not create must be reported, or an earlier run's \
             canaries are graded as this run's in silence"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    // An external rotation must not leave an ack unbacked: the file is the ground
    // truth, so a re-announcement after one writes again rather than being waved
    // through as already held.
    #[test]
    fn a_manifest_rotated_out_of_the_sidecar_is_re_recorded() {
        let dir = scratch("manifest-rotated");
        let path = dir.join("alice.canaries.json");
        let sink = CanarySink::new(path.clone());
        let manifest = payload(r#"{"role":"alice","petname":"Quiet Wanderer"}"#);
        assert_eq!(
            sink.announce("c0", &manifest).outcome,
            Announced::Recorded(1)
        );

        std::fs::remove_file(&path).expect("rotate");
        let announcement = sink.announce("c1", &manifest);

        assert_eq!(announcement.outcome, Announced::Recorded(1));
        assert_eq!(
            announcement.ack,
            Some(1),
            "an ack must mean the host holds it"
        );
        assert_eq!(lines(&path), vec![manifest.to_string()]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_refused_or_unconfigured_manifest_is_not_acked() {
        let dir = scratch("manifest-refused");
        let path = dir.join("alice.canaries.json");
        let sink = CanarySink::new(path.clone());

        let announcement = sink.announce("c0", &payload("[]"));
        assert_eq!(
            announcement.outcome,
            Announced::Refused(PayloadRejection::NotAnObject)
        );
        assert!(announcement.ack.is_none());
        assert!(!path.exists());

        let disabled = CanarySink::disabled();
        let announcement = disabled.announce("c0", &payload(r#"{"role":"alice"}"#));
        assert_eq!(announcement.outcome, Announced::Unconfigured);
        assert!(
            announcement.ack.is_none(),
            "an ack must mean the oracle can read this manifest"
        );
        assert_eq!(disabled.stats().lost, 1);
        assert_eq!(disabled.stats().recorded, 0);
        let _ = std::fs::remove_dir_all(&dir);
    }

    // ---------------------------------------------------------------------
    // The directory these files live in
    // ---------------------------------------------------------------------

    // An ABSENT directory is the normal case: the sink creates it owner-only.
    #[test]
    fn an_absent_needle_directory_is_accepted_and_created_owner_only() {
        let dir = scratch("verify-absent");
        assert_eq!(verify_dir(&dir), Ok(()));

        create_dir(&dir).expect("an absent directory must be created");

        assert_eq!(
            verify_dir(&dir),
            Ok(()),
            "the directory this function creates must satisfy its own check, whatever the umask"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    // The files in it hold every value a run declared, so anything readable by
    // another user is a disclosure — and the scanner refuses anything but 0700
    // too, so accepting more here would write files it then declines to read.
    #[cfg(unix)]
    #[test]
    fn a_pre_existing_needle_directory_must_be_owner_only() {
        use std::os::unix::fs::PermissionsExt;

        let dir = scratch("verify-mode");
        std::fs::create_dir_all(&dir).expect("fixture dir");
        for mode in [0o755, 0o777, 0o750, 0o500] {
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(mode))
                .expect("fixture mode");
            assert_eq!(
                verify_dir(&dir),
                Err(DirRejection::WrongMode),
                "mode {mode:o} must be refused"
            );
        }
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(NEEDLE_DIR_MODE))
            .expect("fixture mode");
        assert_eq!(verify_dir(&dir), Ok(()), "0700 is the one accepted mode");
        let _ = std::fs::remove_dir_all(&dir);
    }

    // A symlink is the relocation defeat arriving through the filesystem: the
    // declared values would land wherever it points, out from under the
    // extension bans that keep them out of every artifact.
    #[cfg(unix)]
    #[test]
    fn a_symlinked_needle_directory_is_refused_even_when_the_target_is_owner_only() {
        let target = scratch("verify-symlink-target");
        let link = scratch("verify-symlink");
        create_dir(&target).expect("target dir");

        std::os::unix::fs::symlink(&target, &link).expect("fixture symlink");

        assert_eq!(
            verify_dir(&link),
            Err(DirRejection::Symlink),
            "the TARGET's mode must not decide this — following the link is the hazard"
        );
        let _ = std::fs::remove_file(&link);
        let _ = std::fs::remove_dir_all(&target);
    }

    #[test]
    fn a_file_in_place_of_the_needle_directory_is_refused() {
        let path = scratch("verify-file");
        std::fs::write(&path, b"not a directory").expect("fixture file");

        assert_eq!(verify_dir(&path), Err(DirRejection::NotADirectory));
        let _ = std::fs::remove_file(&path);
    }

    // The write path enforces the same rule, so a directory swapped under a
    // running proxy cannot make the NEXT declaration land somewhere unsafe. The
    // declaration is then lost and said out loud — never written anyway.
    #[cfg(unix)]
    #[test]
    fn an_unsafe_directory_loses_the_declaration_instead_of_writing_into_it() {
        use std::os::unix::fs::PermissionsExt;

        let dir = scratch("verify-write");
        std::fs::create_dir_all(&dir).expect("fixture dir");
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755))
            .expect("fixture mode");
        let path = dir.join("alice.needles.decl");
        let sink = NeedleSink::new("alice".to_owned(), path.clone());

        let declaration = sink.declare("c0", &payload(r#"{"class":"pubkey"}"#));

        assert_eq!(
            declaration.outcome,
            Declared::Unwritable(std::io::ErrorKind::PermissionDenied),
            "a group-readable directory must refuse the write, not accept it"
        );
        assert!(declaration.ack.is_none());
        assert!(
            !path.exists(),
            "nothing may be written into an unsafe directory"
        );
        assert_eq!(sink.stats().lost, 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    // The startup refusal has to say WHICH rule the directory broke, or whoever
    // reads a red lane cannot tell a symlink from a bad mode.
    #[test]
    fn the_directory_refusal_names_the_path_and_the_rule_it_broke() {
        for reason in [
            DirRejection::Symlink,
            DirRejection::NotADirectory,
            DirRejection::WrongMode,
        ] {
            let notice = dir_refusal_notice(Path::new(NEEDLE_DIR), reason);
            assert!(notice.contains(NEEDLE_DIR), "{notice}");
            assert!(notice.contains(reason.as_str()), "{notice}");
            assert!(
                notice.contains("0700") && notice.contains("symlink"),
                "the line must say what a usable directory looks like: {notice}"
            );
        }
    }

    #[test]
    fn every_directory_rejection_label_is_distinct_and_non_empty() {
        let labels: Vec<&str> = [
            DirRejection::Symlink,
            DirRejection::NotADirectory,
            DirRejection::WrongMode,
        ]
        .iter()
        .map(|r| r.as_str())
        .collect();
        let mut unique = labels.clone();
        unique.sort_unstable();
        unique.dedup();
        assert_eq!(unique.len(), labels.len());
        assert!(labels.iter().all(|l| !l.is_empty()));
    }

    // ---------------------------------------------------------------------
    // Role and paths
    // ---------------------------------------------------------------------

    // The PATH CONTRACT: the guard that keeps these files out of every artifact
    // keys on the extension, and `haven-logscan seal --decl` is handed exactly
    // these names.
    #[test]
    fn the_sidecar_paths_are_derived_from_the_role_under_one_fixed_directory() {
        assert_eq!(
            decl_path("default"),
            PathBuf::from("/tmp/haven-soak/needles/default.needles.decl")
        );
        assert_eq!(
            canaries_path("planeA"),
            PathBuf::from("/tmp/haven-soak/needles/planeA.canaries.json")
        );
        for path in [decl_path("default"), canaries_path("default")] {
            assert!(
                path.starts_with(NEEDLE_DIR),
                "a needle file outside {NEEDLE_DIR} escapes the guard's ban: {path:?}"
            );
        }
    }

    #[test]
    fn the_role_comes_from_the_launchers_instance_marker_and_defaults() {
        assert_eq!(role_from_args::<String>(&[]).as_deref(), Ok("default"));
        assert_eq!(
            role_from_args(&["--haven-wire-proxy-instance=planeA"]).as_deref(),
            Ok("planeA")
        );
        // The marker is positional noise among other argv entries, and the LAST
        // one wins — the same reading `start-wire-proxy.sh` would give.
        assert_eq!(
            role_from_args(&[
                "--self-test-unrelated",
                "--haven-wire-proxy-instance=planeA",
                "--haven-wire-proxy-instance=planeB",
            ])
            .as_deref(),
            Ok("planeB")
        );
    }

    // A role becomes a path component, so one that could escape the directory
    // must be refused rather than sanitised: silently rewriting it would put
    // the sidecar somewhere the guard does not look.
    #[test]
    fn a_role_that_could_escape_the_needle_directory_is_refused() {
        for bad in [
            "--haven-wire-proxy-instance=",
            "--haven-wire-proxy-instance=../../etc/haven",
            "--haven-wire-proxy-instance=a/b",
            "--haven-wire-proxy-instance=a b",
            "--haven-wire-proxy-instance=a\nb",
        ] {
            assert_eq!(
                role_from_args(&[bad]),
                Err(RoleRejection::NotAnInstanceName),
                "{bad}"
            );
        }
    }
}
