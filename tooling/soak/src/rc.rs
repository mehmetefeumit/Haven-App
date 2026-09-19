//! The run's exit-code taxonomy, and the two verdicts that fold into it.
//!
//! The codes are `haven-logscan`'s, by value and by meaning: one taxonomy for
//! the whole tree. This module is the typed face of it plus the one thing the
//! scanner has no opinion on — that a run carries **two** independent verdicts
//! with opposite evidence contracts.
//!
//! # Why two verdicts fold separately
//!
//! Both a leak and an invariant violation are [`Rc::ViolationOrLeak`], and they
//! want opposite things from the evidence. A leak means the captured lines hold
//! a value that must never leave the runner, so the containment branch deletes
//! them. A violation means the run found a real defect, so the first-violation
//! snapshot is exactly what must be preserved and read. A single folded code
//! cannot tell a reader which of those to do, so the run emits a distinct
//! marker file per verdict and the lane branches on the marker, not the code.

use haven_logscan::{worse, RC_CLEAN, RC_GUARD, RC_LEAK, RC_META, RC_UNUSABLE};

/// The marker file a run writes when the scan verdict is a leak. The lane's
/// containment branch keys on this name: withhold the evidence, upload nothing.
pub const LEAK_MARKER: &str = "LEAK.marker";

/// The marker file a run writes when an invariant was violated. The lane
/// preserves and uploads the first-violation snapshot when it sees this one.
pub const VIOLATION_MARKER: &str = "VIOLATION.marker";

/// One run verdict.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Rc {
    /// Every scheduled fault fired and was observed, every floor was met, no
    /// invariant was violated, every scan was clean.
    Clean,
    /// A privacy leak in a captured line, or a violated invariant. The two are
    /// told apart by the marker, never by the code.
    ViolationOrLeak,
    /// The rig is broken, not the subject: a process global refused, a leaked
    /// handle kept a session live, an induction mechanism no longer matches the
    /// pinned engine.
    RigBroken,
    /// The world or the schedule proves nothing: a scheduled fault never fired,
    /// an expectation floor was unmet, a shape plant was missed.
    Unusable,
    /// An intact run that proves too little: no searchable term, a declaration
    /// floor unmet. The verdict is UNGRADED, not clean.
    ProvesTooLittle,
}

impl Rc {
    /// The process exit code, identical to `haven-logscan`'s constant.
    #[must_use]
    pub const fn code(self) -> i32 {
        match self {
            Self::Clean => RC_CLEAN,
            Self::ViolationOrLeak => RC_LEAK,
            Self::RigBroken => RC_GUARD,
            Self::Unusable => RC_UNUSABLE,
            Self::ProvesTooLittle => RC_META,
        }
    }

    /// The name printed in the banner's `rc_names` line.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Clean => "clean",
            Self::ViolationOrLeak => "violation-or-leak",
            Self::RigBroken => "rig",
            Self::Unusable => "unusable",
            Self::ProvesTooLittle => "meta",
        }
    }

    /// The code the caller must act on, given two verdicts (`1 > 2 > 3 > 4 > 0`).
    ///
    /// Delegates to `haven_logscan::worse` rather than re-implementing the
    /// order: a second copy of a precedence rule is a second thing to get
    /// wrong, and only one of them would be tested.
    #[must_use]
    pub fn folded(self, other: Self) -> Self {
        Self::from_code(worse(self.code(), other.code())).unwrap_or(Self::RigBroken)
    }

    /// The verdict for `code`, or `None` if it is outside the closed set.
    #[must_use]
    pub const fn from_code(code: i32) -> Option<Self> {
        match code {
            RC_CLEAN => Some(Self::Clean),
            RC_LEAK => Some(Self::ViolationOrLeak),
            RC_GUARD => Some(Self::RigBroken),
            RC_UNUSABLE => Some(Self::Unusable),
            RC_META => Some(Self::ProvesTooLittle),
            _ => None,
        }
    }
}

/// The run's two independent verdicts and the markers they owe.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Verdicts {
    scan: Rc,
    invariant: Rc,
}

impl Verdicts {
    /// A run that has observed nothing yet: both verdicts clean.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            scan: Rc::Clean,
            invariant: Rc::Clean,
        }
    }

    /// Folds one scan verdict in (worse wins).
    pub fn fold_scan(&mut self, rc: Rc) {
        self.scan = self.scan.folded(rc);
    }

    /// Folds one invariant verdict in (worse wins).
    pub fn fold_invariant(&mut self, rc: Rc) {
        self.invariant = self.invariant.folded(rc);
    }

    /// The scan half on its own.
    #[must_use]
    pub const fn scan(self) -> Rc {
        self.scan
    }

    /// The invariant half on its own.
    #[must_use]
    pub const fn invariant(self) -> Rc {
        self.invariant
    }

    /// The process exit verdict: the fold of both halves.
    #[must_use]
    pub fn rc(self) -> Rc {
        self.scan.folded(self.invariant)
    }

    /// The marker files this run owes, in a stable order. Empty when neither
    /// half reached [`Rc::ViolationOrLeak`].
    #[must_use]
    pub fn markers(self) -> Vec<&'static str> {
        let mut out = Vec::new();
        if self.scan == Rc::ViolationOrLeak {
            out.push(LEAK_MARKER);
        }
        if self.invariant == Rc::ViolationOrLeak {
            out.push(VIOLATION_MARKER);
        }
        out
    }
}

impl Default for Verdicts {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL: [Rc; 5] = [
        Rc::Clean,
        Rc::ViolationOrLeak,
        Rc::RigBroken,
        Rc::Unusable,
        Rc::ProvesTooLittle,
    ];

    #[test]
    fn codes_are_haven_logscans_codes() {
        assert_eq!(Rc::Clean.code(), RC_CLEAN);
        assert_eq!(Rc::ViolationOrLeak.code(), RC_LEAK);
        assert_eq!(Rc::RigBroken.code(), RC_GUARD);
        assert_eq!(Rc::Unusable.code(), RC_UNUSABLE);
        assert_eq!(Rc::ProvesTooLittle.code(), RC_META);
        for rc in ALL {
            assert_eq!(Rc::from_code(rc.code()), Some(rc));
        }
        assert_eq!(Rc::from_code(9), None);
    }

    #[test]
    fn folding_agrees_with_the_scanners_precedence_for_every_pair() {
        for a in ALL {
            for b in ALL {
                assert_eq!(
                    a.folded(b).code(),
                    worse(a.code(), b.code()),
                    "{} vs {}",
                    a.name(),
                    b.name()
                );
            }
        }
    }

    #[test]
    fn a_leak_and_a_violation_are_reported_as_separate_markers() {
        let mut v = Verdicts::new();
        assert!(v.markers().is_empty());
        assert_eq!(v.rc(), Rc::Clean);

        v.fold_scan(Rc::ViolationOrLeak);
        assert_eq!(v.markers(), vec![LEAK_MARKER]);

        v.fold_invariant(Rc::ViolationOrLeak);
        assert_eq!(v.markers(), vec![LEAK_MARKER, VIOLATION_MARKER]);
        assert_eq!(v.rc(), Rc::ViolationOrLeak);
    }

    #[test]
    fn an_unusable_run_owes_no_marker_and_does_not_read_as_clean() {
        let mut v = Verdicts::new();
        v.fold_invariant(Rc::Unusable);
        v.fold_scan(Rc::ProvesTooLittle);
        assert!(v.markers().is_empty());
        assert_eq!(v.rc(), Rc::Unusable);
        assert_eq!(v.scan(), Rc::ProvesTooLittle);
        assert_eq!(v.invariant(), Rc::Unusable);
    }

    #[test]
    fn a_worse_verdict_never_folds_back_to_a_milder_one() {
        let mut v = Verdicts::new();
        v.fold_invariant(Rc::ViolationOrLeak);
        v.fold_invariant(Rc::Clean);
        assert_eq!(v.invariant(), Rc::ViolationOrLeak);
    }

    #[test]
    fn debug_renders_only_the_verdict_names() {
        let rendered = format!("{:?}", Verdicts::new());
        assert!(rendered.contains("Clean"), "{rendered}");
        assert!(rendered.contains("Verdicts"), "{rendered}");
    }
}
