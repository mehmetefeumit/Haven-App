//! Two clocks that must never be confused, and no way to turn one into the
//! other.
//!
//! haven-core takes an injected instant at two kinds of seam, and they are not
//! interchangeable:
//!
//! * **Policy** seams decide whether something has aged out — a sweep horizon,
//!   a key-package rotation, a prune, a leave. Moving this clock forward is how
//!   the rig reaches a 288-second horizon inside a 120-second run.
//! * **Wall** seams decide where a relay cursor sits and when a delivery window
//!   opened. They are compared against timestamps a relay and a peer produced,
//!   so a rig that offsets them fabricates a fork, a replay or a silent
//!   subscription out of nothing.
//!
//! [`PolicyNow`] therefore has no conversion to [`WallNow`] — no `From`, no
//! `into_wall()`, no arithmetic that could stand in for one. A policy instant
//! reaching a cursor, anchor or processor-window seam is a defect that
//! `check_soak_clock_partition.sh` fails the build on; the type system is the
//! first half of that guard and the grep is the second.
//!
//! Neither type renders its value: an absolute instant is an identifier
//! (Rule 15). Offsets from the run origin are what the timeline carries.

use std::fmt;

/// A real, un-offset instant in Unix seconds: the only clock a cursor, anchor
/// or processor window may ever see.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct WallNow(i64);

impl WallNow {
    /// Reads the system clock.
    #[must_use]
    pub fn now() -> Self {
        Self(chrono::Utc::now().timestamp())
    }

    /// Wraps an instant the caller already holds in Unix seconds.
    #[must_use]
    pub const fn from_secs(secs: i64) -> Self {
        Self(secs)
    }

    /// The instant in Unix seconds, for a haven-core seam that takes one.
    #[must_use]
    pub const fn secs(self) -> i64 {
        self.0
    }

    /// Seconds elapsed since `origin` — the only shape of this clock that may
    /// be rendered, because it names no absolute instant.
    #[must_use]
    pub const fn secs_since(self, origin: Self) -> i64 {
        self.0 - origin.0
    }
}

// Presence-only: an absolute instant identifies when a device was live.
impl fmt::Debug for WallNow {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("WallNow(..)")
    }
}

/// An instant as the *policy* seams see it: wall time plus the run's deliberate
/// offset, in Unix seconds.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct PolicyNow(u64);

impl PolicyNow {
    /// Builds the policy instant for `wall` under `offset_secs`.
    ///
    /// The one-way direction is deliberate: a wall instant plus a known offset
    /// IS the policy instant, while the reverse would let an offset leak into a
    /// cursor comparison.
    ///
    /// # Errors
    ///
    /// [`ClockError::BeforeEpoch`] if the offset moves the instant below the
    /// Unix epoch — a schedule that stepped backwards further than the clock
    /// has run, which is a rig bug rather than a subject defect.
    pub fn from_wall_with_offset(wall: WallNow, offset_secs: i64) -> Result<Self, ClockError> {
        let shifted = wall
            .secs()
            .checked_add(offset_secs)
            .ok_or(ClockError::BeforeEpoch)?;
        u64::try_from(shifted)
            .map(Self)
            .map_err(|_| ClockError::BeforeEpoch)
    }

    /// The instant in Unix seconds, for a haven-core policy seam that takes one.
    #[must_use]
    pub const fn secs(self) -> u64 {
        self.0
    }
}

// Presence-only, for the same reason as `WallNow`.
impl fmt::Debug for PolicyNow {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("PolicyNow(..)")
    }
}

/// Why a policy instant could not be built.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClockError {
    /// The offset put the instant below the Unix epoch.
    BeforeEpoch,
}

impl fmt::Display for ClockError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::BeforeEpoch => f.write_str("policy offset moved the instant below the epoch"),
        }
    }
}

impl std::error::Error for ClockError {}

/// Milliseconds to seconds, truncating toward the past.
///
/// haven-core stamps its rotation state in milliseconds
/// (`CircleRotationState`'s `*_at_ms` columns) while every policy seam takes
/// seconds. The conversion lives here, once and named, because an expectation
/// computed from a hand-rolled `/ 1000` at one call site and a `/ 1000.0` at
/// another is how a gate expectation silently drifts by a second.
#[must_use]
pub const fn millis_to_secs(millis: i64) -> i64 {
    millis.div_euclid(1_000)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_policy_instant_is_wall_plus_the_offset() {
        let wall = WallNow::from_secs(1_700_000_000);
        let policy = PolicyNow::from_wall_with_offset(wall, 288).expect("policy instant");
        assert_eq!(policy.secs(), 1_700_000_288);

        let back = PolicyNow::from_wall_with_offset(wall, -288).expect("policy instant");
        assert_eq!(back.secs(), 1_699_999_712);
    }

    #[test]
    fn an_offset_below_the_epoch_is_refused_rather_than_wrapped() {
        let wall = WallNow::from_secs(10);
        assert_eq!(
            PolicyNow::from_wall_with_offset(wall, -100),
            Err(ClockError::BeforeEpoch)
        );
        assert_eq!(
            PolicyNow::from_wall_with_offset(WallNow::from_secs(i64::MAX), 1),
            Err(ClockError::BeforeEpoch)
        );
    }

    #[test]
    fn wall_time_is_only_rendered_relative_to_an_origin() {
        let origin = WallNow::from_secs(1_700_000_000);
        let later = WallNow::from_secs(1_700_000_042);
        assert_eq!(later.secs_since(origin), 42);
        assert_eq!(origin.secs_since(later), -42);
    }

    #[test]
    fn the_millisecond_conversion_truncates_toward_the_past() {
        assert_eq!(millis_to_secs(1_999), 1);
        assert_eq!(millis_to_secs(2_000), 2);
        assert_eq!(millis_to_secs(-1), -1);
    }

    #[test]
    fn neither_clock_renders_its_instant() {
        let needle = 1_337_424_242_i64;
        let wall = format!("{:?}", WallNow::from_secs(needle));
        let policy = format!(
            "{:?}",
            PolicyNow::from_wall_with_offset(WallNow::from_secs(needle), 0).expect("policy")
        );
        assert!(!wall.contains("1337424242"), "{wall}");
        assert!(wall.contains("WallNow"), "{wall}");
        assert!(!policy.contains("1337424242"), "{policy}");
        assert!(policy.contains("PolicyNow"), "{policy}");
    }

    #[test]
    fn the_now_reading_is_a_real_clock() {
        let a = WallNow::now();
        let b = WallNow::now();
        assert!(b.secs_since(a) >= 0);
        assert!(a.secs() > 1_600_000_000, "the system clock is before 2020");
    }
}
