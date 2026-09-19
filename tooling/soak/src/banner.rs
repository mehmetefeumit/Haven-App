//! The banner: what this run is, printed before it starts.
//!
//! A run that dies at its own deadline — "the faults never fired" — still has to
//! leave its seed on record, so the banner is written first, to stdout and to
//! `banner.log` beside the timeline, and the measured line is appended when the
//! run ends.
//!
//! # What may be printed, and why
//!
//! The profile name and the seed identify the run completely, and both are
//! repository facts: every preimage of a scheduler seed is public metadata and
//! the PR seed is checked into `profiles/pr.toml`. They identify a SHAPE, not a
//! user, a circle or a device.
//!
//! The world's magnitudes are NOT printed — not `relays=3`, not a member count.
//! CLAUDE.md forbids exact counts outright, and the profile name plus the
//! schedule tag already identify the shape, the TOML being in the repository.
//!
//! # Why the two hex fields are short, and why their bindings are named as they
//! are
//!
//! This file is scanned as one of the run's own `soak` sinks, and
//! `haven-logscan`'s structural rule S2 matches 32–63 hex characters: a 40-hex
//! commit sha would red the run's own scan. So `commit_short` is at most 12 hex
//! and `schedule_tag` is 8. The BINDING names matter as much as the values,
//! because the identifier source guard reads argument identifiers and
//! `digest`/`hash`/`hex`/`sha256` are strong words there. No `log-scan-ok`
//! marker is budgeted for this file, so there is no escape hatch.
//!
//! # The S07 line
//!
//! It prints the literal words "not measured (Phase 2)", never an estimate.
//! PLAN §12's Phase-1 row asks the banner to print the S07 amplification factor
//! "replacing estimates"; §4.2 makes S07 weekly-only and Phase 1 does not run
//! it. Printing a number nothing measured would be the one thing worse than not
//! printing one (owner decision Q4).

use std::fmt;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::profiles::ProfileName;
use crate::rc::Rc;

/// The banner's file name, beside the timeline.
pub const BANNER_FILE: &str = "banner.log";

/// The most hex characters the commit field may carry.
///
/// Twelve: `haven-logscan`'s S2 matches 32 hex and up, and this file is one of
/// the run's own sinks.
const COMMIT_MAX_HEX: usize = 12;

/// What the S07 line says until Phase 2 measures it.
const S07_LINE: &str = "S07 amplification factor: not measured (Phase 2)";

/// The build this run came out of.
///
/// Both halves are supplied rather than discovered: a seed alone does not
/// reproduce a run across a compiler bump, and neither the commit nor the
/// toolchain version is knowable from inside a compiled binary without a build
/// script this crate deliberately does not have. A lane passes them; a local run
/// leaves them unknown and says so.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Provenance {
    /// The commit, as a short sha. Truncated to [`COMMIT_MAX_HEX`] and rejected
    /// if it is not hex.
    commit_short: String,
    /// The toolchain version.
    rustc: String,
}

impl Provenance {
    /// What a run knows about its own build.
    ///
    /// A `commit` that is not hex is dropped rather than printed: the field is
    /// a commit sha or it is unknown, and anything else reaching a scanned file
    /// is a string somebody else composed.
    #[must_use]
    pub fn new(commit: Option<&str>, rustc: Option<&str>) -> Self {
        let commit_short = commit
            .map(str::trim)
            .filter(|value| !value.is_empty() && value.chars().all(|c| c.is_ascii_hexdigit()))
            .map_or_else(
                || "unknown".to_owned(),
                |value| value[..value.len().min(COMMIT_MAX_HEX)].to_owned(),
            );
        let rustc = rustc
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map_or_else(|| "unknown".to_owned(), ToOwned::to_owned);
        Self {
            commit_short,
            rustc,
        }
    }

    /// The short commit sha, or `unknown`.
    #[must_use]
    pub fn commit_short(&self) -> &str {
        &self.commit_short
    }

    /// The toolchain version, or `unknown`.
    #[must_use]
    pub fn rustc(&self) -> &str {
        &self.rustc
    }
}

/// What a finished run measured about itself.
///
/// Exact, and that is deliberate: a wall time and a peak resident size are
/// measurements, which CLAUDE.md allows, and neither differentiates a user.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Measured {
    /// How long the run took.
    pub wall: Duration,
    /// Peak resident set size, in MiB, where the platform can say.
    pub peak_rss_mib: Option<u64>,
}

impl Measured {
    /// The measurement for a run that started `wall` ago.
    #[must_use]
    pub fn new(wall: Duration) -> Self {
        Self {
            wall,
            peak_rss_mib: peak_rss_mib(),
        }
    }
}

/// The run's peak resident set size in MiB, where the platform can say.
///
/// Linux only, through `/proc/self/status`'s `VmHWM`, which is the kernel's own
/// high-water mark. There is no portable alternative that does not mean either
/// an `unsafe` `getrusage` call (this crate denies `unsafe_code`) or a new
/// dependency for one number, so a platform that cannot answer says so rather
/// than being given a figure from somewhere else.
#[must_use]
pub fn peak_rss_mib() -> Option<u64> {
    let status = std::fs::read_to_string("/proc/self/status").ok()?;
    let line = status
        .lines()
        .find(|line| line.starts_with("VmHWM:"))?
        .split_whitespace()
        .nth(1)?
        .parse::<u64>()
        .ok()?;
    Some(line / 1024)
}

/// The banner of one run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Banner {
    profile: ProfileName,
    seed: u64,
    schedule_tag: String,
    provenance: Provenance,
}

impl Banner {
    /// The banner for `profile` at `seed`, running `schedule_tag`.
    #[must_use]
    pub fn new(
        profile: ProfileName,
        seed: u64,
        schedule_tag: &str,
        provenance: Provenance,
    ) -> Self {
        Self {
            profile,
            seed,
            schedule_tag: schedule_tag.to_owned(),
            provenance,
        }
    }

    /// The banner as it is printed before the run starts.
    #[must_use]
    pub fn head(&self) -> String {
        let mut out = format!(
            "haven-soak profile={} seed=0x{:016x} commit={} rustc={} schedule={}\n",
            self.profile,
            self.seed,
            self.provenance.commit_short(),
            self.provenance.rustc(),
            self.schedule_tag,
        );
        out.push_str("  rc_names=");
        for (index, rc) in [
            Rc::Clean,
            Rc::ViolationOrLeak,
            Rc::RigBroken,
            Rc::Unusable,
            Rc::ProvesTooLittle,
        ]
        .into_iter()
        .enumerate()
        {
            if index > 0 {
                out.push('/');
            }
            let _ = write!(out, "{}{}", rc.code(), rc.name());
        }
        out.push('\n');
        let _ = writeln!(out, "  {S07_LINE}");
        out
    }

    /// The banner with the measured line, as it is printed when the run ends.
    #[must_use]
    pub fn render(&self, measured: Option<Measured>) -> String {
        let mut out = self.head();
        // Before the run there is nothing to report, and the banner says so: a
        // zero here would be a measurement nobody took.
        match measured {
            Some(measured) => {
                let _ = writeln!(
                    out,
                    "  measured: wall={}s peak_rss={}",
                    measured.wall.as_secs(),
                    measured
                        .peak_rss_mib
                        .map_or_else(|| "unavailable".to_owned(), |mib| format!("{mib}MiB")),
                );
            }
            None => out.push_str("  measured: pending\n"),
        }
        out
    }

    /// Writes the banner into `dir` and returns its path.
    ///
    /// `dir` is the timeline's own directory: the lane uploads that tree whole,
    /// and a banner somewhere else is a banner nobody reads.
    ///
    /// # Errors
    ///
    /// The `io::Error` from creating the directory or writing the file.
    pub fn write_to(&self, dir: &Path, measured: Option<Measured>) -> std::io::Result<PathBuf> {
        std::fs::create_dir_all(dir)?;
        let path = dir.join(BANNER_FILE);
        std::fs::write(&path, self.render(measured))?;
        Ok(path)
    }
}

impl fmt::Display for Banner {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.render(None))
    }
}

#[cfg(test)]
mod tests {
    use super::{peak_rss_mib, Banner, Measured, Provenance, BANNER_FILE, COMMIT_MAX_HEX};
    use crate::profiles::ProfileName;
    use std::time::Duration;

    fn banner() -> Banner {
        Banner::new(
            ProfileName::Pr,
            0,
            "a91f3c2b",
            Provenance::new(
                Some("bb310e2f4a9c17de55c0ffee0123456789abcdef"),
                Some("1.97.1"),
            ),
        )
    }

    #[test]
    fn the_head_names_the_run_and_no_magnitude_of_its_world() {
        let head = banner().head();
        assert!(head.contains("profile=pr"), "{head}");
        assert!(head.contains("seed=0x0000000000000000"), "{head}");
        assert!(head.contains("schedule=a91f3c2b"), "{head}");
        for magnitude in ["relays=", "members=", "circles=", "devices="] {
            assert!(!head.contains(magnitude), "{head}");
        }
    }

    #[test]
    fn every_hex_field_is_short_enough_that_the_structural_rules_cannot_match_it() {
        let head = banner().head();
        // S2 matches 32-63 hex, S1 64: the longest run of hex in this file has
        // to stay well under both, because the banner is scanned as a `soak`
        // sink like every other capture.
        let longest = head
            .split(|c: char| !c.is_ascii_hexdigit())
            .map(str::len)
            .max()
            .unwrap_or(0);
        assert!(longest < 32, "the banner rendered a 32-hex run: {head}");
        assert!(banner().provenance.commit_short().len() == COMMIT_MAX_HEX);
    }

    #[test]
    fn a_commit_that_is_not_a_sha_is_dropped_rather_than_printed() {
        // The field is a commit sha or it is unknown: anything else reaching a
        // scanned file is a string somebody else composed.
        let provenance = Provenance::new(Some("refs/heads/main"), None);
        assert!(provenance.commit_short() == "unknown");
        assert!(provenance.rustc() == "unknown");
        assert!(Provenance::new(Some("  "), Some(" ")).commit_short() == "unknown");
        assert!(Provenance::default().commit_short().is_empty());
    }

    #[test]
    fn the_rc_names_line_carries_every_code_in_the_taxonomy() {
        let head = banner().head();
        for expected in ["0clean", "1violation-or-leak", "2rig", "3unusable", "4meta"] {
            assert!(head.contains(expected), "{head}");
        }
    }

    #[test]
    fn the_s07_factor_is_the_literal_words_and_never_a_number() {
        let head = banner().head();
        assert!(head.contains("S07 amplification factor: not measured (Phase 2)"));
        assert!(!head.contains("S07 amplification factor: 1"), "{head}");
    }

    #[test]
    fn the_measured_line_says_pending_before_the_run_and_measures_after_it() {
        let before = banner().render(None);
        assert!(before.contains("measured: pending"), "{before}");

        let after = banner().render(Some(Measured {
            wall: Duration::from_secs(271),
            peak_rss_mib: Some(412),
        }));
        assert!(
            after.contains("measured: wall=271s peak_rss=412MiB"),
            "{after}"
        );

        let unmeasurable = banner().render(Some(Measured {
            wall: Duration::from_secs(1),
            peak_rss_mib: None,
        }));
        assert!(
            unmeasurable.contains("peak_rss=unavailable"),
            "a platform that cannot say must say so: {unmeasurable}"
        );
    }

    #[test]
    fn the_banner_is_written_beside_the_timeline() {
        let dir = tempfile::tempdir().expect("temp dir");
        let path = banner()
            .write_to(dir.path(), None)
            .expect("banner is written");
        assert!(path.ends_with(BANNER_FILE));
        let text = std::fs::read_to_string(&path).expect("read back");
        assert!(text.contains("haven-soak profile=pr"), "{text}");
    }

    #[test]
    fn a_measurement_is_taken_from_the_platform_where_it_can_be() {
        // On Linux this is the kernel's own high-water mark; anywhere else the
        // honest answer is None, and the banner prints that rather than a zero.
        let measured = Measured::new(Duration::from_secs(3));
        let later = peak_rss_mib();
        assert!(measured.wall.as_secs() == 3);
        assert!(
            measured.peak_rss_mib.is_some() == later.is_some(),
            "the measurement and the reading must come from the same source"
        );
        // A high-water mark, compared as one: two samples of a peak can differ
        // while another test in this process allocates, and they may only ever
        // differ in one direction. Asserting equality would be asserting that
        // nothing else ran.
        if let (Some(taken), Some(after)) = (measured.peak_rss_mib, later) {
            assert!(taken <= after, "a peak went backwards");
        }
        if cfg!(target_os = "linux") {
            assert!(
                measured.peak_rss_mib.is_some_and(|mib| mib > 0),
                "a running process has a peak resident size"
            );
        }
    }
}
