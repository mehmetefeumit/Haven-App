//! The checked-in run profiles: what a `pr`, `nightly` or `weekly` run is.
//!
//! A profile is data, not code, so a reader can see the whole shape of a lane
//! in one file the repository reviews. The TOMLs are compiled in with
//! `include_str!` rather than read from disk: a run must resolve the same
//! profile from any working directory, and a profile that can be edited
//! underneath a running binary is a reproducibility hole (the banner's seed and
//! schedule tag are only a reproduction recipe if the profile is fixed at build
//! time).
//!
//! # What lives here and what does not
//!
//! The profile declares the world's shape, the run's budgets and **which
//! scenario arms run**. It never declares a deadline per arm: those are derived
//! from haven-core's own constants at run time, so a constant that moves in
//! production moves the bound with it instead of silently disagreeing with a
//! number typed here.

use serde::Deserialize;
use std::fmt;

/// The `pr` profile: the four scenarios the PR lane runs.
const PR_TOML: &str = include_str!("../profiles/pr.toml");
/// The `nightly` profile.
const NIGHTLY_TOML: &str = include_str!("../profiles/nightly.toml");
/// The `weekly` profile.
const WEEKLY_TOML: &str = include_str!("../profiles/weekly.toml");

/// One of the three checked-in profiles.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProfileName {
    /// The per-PR lane: minutes, four scenarios, one relay.
    Pr,
    /// The nightly lane: the scenarios whose bounds do not fit a PR budget.
    Nightly,
    /// The weekly lane: every scenario, every arm.
    Weekly,
}

impl ProfileName {
    /// Every profile, in escalation order.
    pub const ALL: [Self; 3] = [Self::Pr, Self::Nightly, Self::Weekly];

    /// The name as it is spelled on the command line and in the TOML.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Pr => "pr",
            Self::Nightly => "nightly",
            Self::Weekly => "weekly",
        }
    }

    /// Parses a command-line spelling.
    #[must_use]
    pub fn parse(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|name| name.as_str() == raw)
    }
}

impl fmt::Display for ProfileName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// How many of each thing the world holds.
///
/// Magnitudes only — nothing here identifies anybody, and the values come from
/// a file the repository reviews. They are still never printed: an exact count
/// of relays or members is a fingerprint of the run, and the profile name plus
/// the schedule tag identify the shape completely.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WorldShape {
    /// Devices, each with its own store, keys and engine. The first is the
    /// circle admin.
    pub members: usize,
    /// Circles, all created by the admin device, all in the same stores — a
    /// sibling circle is what proves a per-circle fault stayed per-circle.
    pub circles: usize,
    /// Relay planes the world runs over.
    pub relays: usize,
}

/// One scenario the profile runs, and which of its arms.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ScenarioSelection {
    /// The scenario id (`S01`, `S06`, …).
    pub id: String,
    /// The arm labels to run. The label is the contract between this file and
    /// the scenario's own `arms()`.
    pub arms: Vec<String>,
}

/// A whole profile.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProfileSpec {
    /// Which profile this is.
    pub name: ProfileName,
    /// The run budget: the wall seconds of scenario work the profile may spend.
    /// The lane's own deadline sits ABOVE it so a hung run is killed with time
    /// left to finalise.
    pub run_budget_secs: u64,
    /// The inner deadline the lane arms `run-with-deadline.sh` with.
    pub deadline_secs: u64,
    /// The headroom kept between the summed arm deadlines and the run budget.
    pub margin_secs: u64,
    /// How long the nemesis schedule spans.
    pub duration_secs: u64,
    /// The tick period. Ticks are the schedule's clock; they are counted, never
    /// slept through.
    pub tick_ms: u64,
    /// The world's shape.
    pub world: WorldShape,
    /// The scenarios and arms to run.
    pub scenarios: Vec<ScenarioSelection>,
}

impl ProfileSpec {
    /// Loads a checked-in profile.
    ///
    /// # Errors
    ///
    /// [`ProfileError`] if the compiled-in TOML is malformed or fails
    /// validation — both are build-time authoring mistakes, surfaced rather
    /// than defaulted around.
    pub fn embedded(name: ProfileName) -> Result<Self, ProfileError> {
        let raw = match name {
            ProfileName::Pr => PR_TOML,
            ProfileName::Nightly => NIGHTLY_TOML,
            ProfileName::Weekly => WEEKLY_TOML,
        };
        let spec = Self::from_toml_str(raw)?;
        if spec.name == name {
            Ok(spec)
        } else {
            Err(ProfileError::Invalid { field: "name" })
        }
    }

    /// Parses and validates a profile.
    ///
    /// # Errors
    ///
    /// [`ProfileError::Malformed`] if the text is not this schema (the parser's
    /// own message is deliberately dropped: it quotes the input), or
    /// [`ProfileError::Invalid`] naming the field that failed validation.
    pub fn from_toml_str(raw: &str) -> Result<Self, ProfileError> {
        let spec: Self = toml::from_str(raw).map_err(|_| ProfileError::Malformed)?;
        spec.validate()?;
        Ok(spec)
    }

    /// Re-checks the profile after command-line overrides.
    ///
    /// # Errors
    ///
    /// [`ProfileError::Invalid`] naming the first field that fails.
    pub fn validate(&self) -> Result<(), ProfileError> {
        let invalid = |field| Err(ProfileError::Invalid { field });
        // Two devices is the floor for any oracle that needs a peer to decrypt
        // what another device sent, which is every liveness oracle there is.
        if self.world.members < 2 {
            return invalid("world.members");
        }
        if self.world.circles == 0 {
            return invalid("world.circles");
        }
        if self.world.relays == 0 {
            return invalid("world.relays");
        }
        if self.tick_ms == 0 {
            return invalid("tick_ms");
        }
        if self.duration_secs == 0 {
            return invalid("duration_secs");
        }
        // The deadline exists to kill a hung run with time left to finalise, so
        // it must sit strictly above the work it bounds.
        if self.deadline_secs <= self.run_budget_secs {
            return invalid("deadline_secs");
        }
        if self.margin_secs >= self.run_budget_secs {
            return invalid("margin_secs");
        }
        if self.scenarios.is_empty() {
            return invalid("scenarios");
        }
        for (index, scenario) in self.scenarios.iter().enumerate() {
            if scenario.arms.is_empty() {
                return invalid("scenarios.arms");
            }
            if self.scenarios[..index].iter().any(|s| s.id == scenario.id) {
                return invalid("scenarios.id");
            }
        }
        Ok(())
    }

    /// The declared scenario ids, in declaration order.
    #[must_use]
    pub fn scenario_ids(&self) -> Vec<&str> {
        self.scenarios.iter().map(|s| s.id.as_str()).collect()
    }

    /// The arms declared for `id`, or `None` if the profile does not run it.
    #[must_use]
    pub fn arms(&self, id: &str) -> Option<&[String]> {
        self.scenarios
            .iter()
            .find(|s| s.id == id)
            .map(|s| s.arms.as_slice())
    }
}

/// Why a profile could not be loaded.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProfileError {
    /// The text is not this schema. The parser's own message is dropped
    /// deliberately: it quotes the input it choked on.
    Malformed,
    /// A field failed validation. The field NAME is safe to carry — it names a
    /// schema key, never a value.
    Invalid {
        /// The schema key that failed.
        field: &'static str,
    },
}

impl fmt::Display for ProfileError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Malformed => f.write_str("profile is not valid TOML for this schema"),
            Self::Invalid { field } => write!(f, "profile field out of range: {field}"),
        }
    }
}

impl std::error::Error for ProfileError {}

#[cfg(test)]
mod tests {
    use super::*;

    fn pr() -> ProfileSpec {
        ProfileSpec::embedded(ProfileName::Pr).expect("pr profile")
    }

    #[test]
    fn every_checked_in_profile_parses_and_validates() {
        for name in ProfileName::ALL {
            let spec = ProfileSpec::embedded(name).expect("embedded profile");
            assert_eq!(spec.name, name);
            spec.validate().expect("validates");
        }
    }

    #[test]
    fn the_pr_profile_runs_the_four_scenarios_it_is_pinned_to() {
        assert_eq!(pr().scenario_ids(), vec!["S01", "S06", "S11", "S13"]);
        assert_eq!(
            pr().arms("S01").map(<[String]>::len),
            Some(1),
            "S01 carries exactly its single-relay arm in the PR budget"
        );
        assert!(
            pr().arms("S17").is_none(),
            "S17's bound does not fit a PR run"
        );
    }

    #[test]
    fn a_profile_name_round_trips_through_its_command_line_spelling() {
        for name in ProfileName::ALL {
            assert_eq!(ProfileName::parse(name.as_str()), Some(name));
            assert_eq!(name.to_string(), name.as_str());
        }
        assert_eq!(ProfileName::parse("PR"), None);
        assert_eq!(ProfileName::parse(""), None);
    }

    #[test]
    fn an_unknown_key_is_refused_rather_than_ignored() {
        let mut raw = PR_TOML.to_string();
        raw.push_str("\nmispelled_budget = 12\n");
        assert_eq!(
            ProfileSpec::from_toml_str(&raw),
            Err(ProfileError::Malformed)
        );
    }

    #[test]
    fn validation_names_the_field_that_failed() {
        let mut spec = pr();
        spec.world.members = 1;
        assert_eq!(
            spec.validate(),
            Err(ProfileError::Invalid {
                field: "world.members"
            })
        );

        let mut spec = pr();
        spec.deadline_secs = spec.run_budget_secs;
        assert_eq!(
            spec.validate(),
            Err(ProfileError::Invalid {
                field: "deadline_secs"
            })
        );

        let mut spec = pr();
        spec.scenarios.push(ScenarioSelection {
            id: "S01".to_string(),
            arms: vec!["single-relay-outage".to_string()],
        });
        assert_eq!(
            spec.validate(),
            Err(ProfileError::Invalid {
                field: "scenarios.id"
            })
        );

        let mut spec = pr();
        spec.scenarios[0].arms.clear();
        assert_eq!(
            spec.validate(),
            Err(ProfileError::Invalid {
                field: "scenarios.arms"
            })
        );
    }

    #[test]
    fn the_error_rendering_names_a_schema_key_and_no_value() {
        let rendered = ProfileError::Invalid { field: "tick_ms" }.to_string();
        assert!(rendered.contains("tick_ms"), "{rendered}");
        assert!(!ProfileError::Malformed.to_string().is_empty());
    }
}
