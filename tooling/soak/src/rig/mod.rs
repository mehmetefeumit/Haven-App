//! The rig: real devices, real circles, real engines, and the handles that name
//! them.
//!
//! Everything under this module is the *subject's* machinery driven for real —
//! a `SimDevice` is a genuine MLS store behind a genuine `LiveSyncCore`, not a
//! stand-in. The only doubles in this crate are the environment planes
//! ([`plane`]), which is why they are traits.
//!
//! # Handles
//!
//! The rig names its own things with deterministic ordinals — `simdev#3`,
//! `simcircle#0`, `simrelay#1`, `simevt#12` — minted by [`sim_tag`]. They are
//! deliberately NOT `haven_core::log_alias` handles: those are salted from the
//! OS CSPRNG per process and cannot be reproduced, and a determinism test that
//! cannot compare two runs' handle tables proves nothing. The two vocabularies
//! are disjoint on purpose, because production's `circle#a91f3c` lines and the
//! rig's land in the same evidence file from the same process, and a reader
//! must never have to guess which minted which.
//!
//! [`sim_magnitude`] is the other minting function, and it delegates to
//! haven-core's bucket policy rather than inventing a second one.

pub mod circle;
pub mod declare;
pub mod device;
#[cfg(test)]
pub mod doubles;
pub mod plane;
pub mod restart;
pub mod world;

use std::fmt;
use std::future::Future;
use std::time::Duration;

use serde::{Serialize, Serializer};
use tokio::time::{Instant, MissedTickBehavior};

pub use circle::{PublishVerdict, SimCircle};
pub use declare::DeclareSink;
pub use device::{DeviceLedger, SimDevice};
pub use plane::{CapturedLine, LogDrain, RelayPlane, TimelineRecord, TimelineSink};
pub use restart::{kill_and_reopen, KillKind, ReopenReport};
pub use world::{
    install_process_globals, CircleFingerprint, DeviceFingerprint, PendingGuard, RosterDigest,
    SimWorld, TickReport, WorldFingerprint,
};

/// The kinds of thing the rig names.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SimKind {
    /// A simulated device.
    Device,
    /// A simulated circle.
    Circle,
    /// A relay plane.
    Relay,
    /// An event the rig minted or observed.
    Event,
    /// One world, so concurrent worlds in one test process never read each
    /// other's captured lines.
    World,
}

impl SimKind {
    /// The handle prefix. Disjoint from `haven_core::log_alias`'s `circle#` /
    /// `peer#` / `event#` / `relay#` by design.
    #[must_use]
    pub const fn prefix(self) -> &'static str {
        match self {
            Self::Device => "simdev",
            Self::Circle => "simcircle",
            Self::Relay => "simrelay",
            Self::Event => "simevt",
            Self::World => "simworld",
        }
    }
}

/// Mints the rig's handle for `ordinal`.
///
/// Named outside the `*_handle` / `*_alias` vocabulary deliberately: those
/// names are reserved for wrappers that MUST delegate to
/// `haven_core::log_alias`, and this one must not — see the module docs.
#[must_use]
pub fn sim_tag(kind: SimKind, ordinal: u64) -> String {
    format!("{}#{ordinal}", kind.prefix())
}

/// Buckets a magnitude for rendering.
///
/// Delegates to haven-core's bucket policy (`0`, `1`, `2-4`, `5+`) so the tree
/// has one such policy rather than two that drift.
#[must_use]
pub const fn sim_magnitude(count: usize) -> &'static str {
    haven_core::log_alias::bucket(count)
}

/// Defines one ordinal handle type: `Display`, `Debug` and `Serialize` all
/// render the handle and nothing else.
macro_rules! sim_handle {
    ($(#[$meta:meta])* $name:ident, $kind:expr, $repr:ty) => {
        $(#[$meta])*
        #[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub struct $name($repr);

        impl $name {
            /// Builds the handle for `ordinal`.
            #[must_use]
            pub const fn new(ordinal: $repr) -> Self {
                Self(ordinal)
            }

            /// The ordinal behind the handle.
            #[must_use]
            pub const fn ordinal(self) -> $repr {
                self.0
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(&sim_tag($kind, u64::from(self.0)))
            }
        }

        // The handle IS the redacted form, so `{:?}` and `{}` agree: there is
        // no fuller rendering to fall back to.
        impl fmt::Debug for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                fmt::Display::fmt(self, f)
            }
        }

        impl Serialize for $name {
            fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                serializer.serialize_str(&self.to_string())
            }
        }
    };
}

sim_handle!(
    /// One device in the world: `simdev#k`.
    DeviceTag,
    SimKind::Device,
    u32
);
sim_handle!(
    /// One circle in the world: `simcircle#k`.
    CircleTag,
    SimKind::Circle,
    u32
);
sim_handle!(
    /// One relay plane: `simrelay#k`.
    RelayTag,
    SimKind::Relay,
    u32
);
sim_handle!(
    /// One event the rig minted or observed: `simevt#n`, assigned in
    /// observation order.
    EventTag,
    SimKind::Event,
    u64
);
sim_handle!(
    /// One world: `simworld#n`. Every captured line carries it, so two worlds
    /// running concurrently under `cargo test` never fold into each other's
    /// evidence.
    WorldId,
    SimKind::World,
    u64
);

/// Which rig step failed.
///
/// A classification, never a message: the underlying haven-core errors render
/// MLS group ids and absolute epochs, so they are matched and dropped here
/// rather than carried.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step {
    /// Opening a device's store.
    OpenStore,
    /// Minting a member's key package.
    MintKeyPackage,
    /// Creating a circle.
    CreateCircle,
    /// Publishing an event to a relay plane.
    Publish,
    /// Confirming a staged commit after its ack.
    ConfirmPublished,
    /// Rolling a staged commit back after no ack.
    RollBackPublish,
    /// Processing a gift-wrapped invitation.
    ProcessInvitation,
    /// Accepting an invitation.
    AcceptInvitation,
    /// Staging a commit the caller must then publish (Rule 13).
    StageCommit,
    /// Starting an engine.
    StartEngine,
    /// Pausing an engine.
    PauseEngine,
    /// Resuming an engine.
    ResumeEngine,
    /// Reading a circle's epoch.
    ReadEpoch,
    /// Reading a circle's converged roster.
    ReadRoster,
    /// Reading a circle's gating-input count.
    ReadGatingRows,
    /// Reading a circle's catch-up position: its sync cursor or its backfill
    /// floor. One step for both, because they are one question — how far this
    /// device has caught up — and two near-synonyms would be a vocabulary
    /// nobody could grep.
    ReadCursor,
    /// Reading a circle's convergence state: its gating inputs, its queued
    /// intents and whether a proposal is pending. One step for all three
    /// because they are one question asked three ways, and three near-synonyms
    /// would be a vocabulary nobody could grep.
    ReadConvergenceState,
    /// Reading a session's liveness.
    ReadSessionLiveness,
    /// Applying a fault to a relay plane.
    ApplyFault,
}

/// Which bounded wait ran out.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Wait {
    /// A killed device never released its session.
    SessionRelease,
    /// A restarted device never got its session back.
    SessionReopen,
}

/// Everything that can go wrong in the rig, as a classification.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RigError {
    /// `allow_ws_loopback_for_test` refused, so no device can dial the world's
    /// own relay. The rig is broken, not the subject.
    LoopbackOptInRefused,
    /// A restart control started from a device whose session was not live —
    /// the control would have proven nothing.
    SessionNotLive,
    /// A killed device's session never came back: something in the rig still
    /// holds a manager handle.
    SessionStillLive,
    /// A soft kill's `stop` timed out, so the engine's tasks may still hold the
    /// Rule-14 guard. Treated as "not released", never as a clean teardown.
    StopTimedOut,
    /// No relay ever witnessed an `OK` for a welcome, so the create was rolled
    /// back (Rule 13) and the world does not exist.
    WelcomeNeverAcked,
    /// No relay ever witnessed an `OK` for a staged commit, so Rule 13 forbids
    /// confirming it and the step that needed the commit applied cannot
    /// continue.
    PublishNeverAcked,
    /// A schedule named a device, circle or relay the world does not have.
    UnknownTarget,
    /// The world was handed a different number of relay planes than its shape
    /// declares.
    ShapeMismatch,
    /// The schedule asked to heal something that is not a fault. Only a fault
    /// can be healed, and a heal that quietly did not happen leaves every
    /// bound derived from it a fiction.
    Unhealable,
    /// A value the rig minted could not be declared: the class the wrapper
    /// names will not take that shape. Nothing the scanner does afterwards can
    /// search for a value that was never declared, so this is the instrument
    /// being broken rather than a finding.
    DeclarationRefused,
    /// An arm that induces a condition through the engine's own storage could
    /// not identify what to break: the set difference was not the single key a
    /// circle adds, or the delete matched no row. Either way the schema or the
    /// key encoding moved, and an induction aimed at something this arm did not
    /// identify would be worse than no arm at all.
    InductionMechanismMoved,
    /// A bounded wait ran out.
    Timeout(Wait),
    /// A haven-core call failed at this step.
    Core(Step),
    /// A policy clock could not be built.
    Clock(crate::clock::ClockError),
}

impl RigError {
    /// The exit verdict this error folds into.
    #[must_use]
    pub const fn rc(self) -> crate::rc::Rc {
        match self {
            // The instrument is broken: these say nothing about the subject.
            Self::LoopbackOptInRefused
            | Self::SessionNotLive
            | Self::SessionStillLive
            | Self::StopTimedOut
            | Self::UnknownTarget
            | Self::ShapeMismatch
            | Self::Unhealable
            | Self::DeclarationRefused
            | Self::InductionMechanismMoved
            | Self::Clock(_) => crate::rc::Rc::RigBroken,
            // The world did not reach the state the scenario needed, so nothing
            // it would have graded proves anything.
            Self::WelcomeNeverAcked
            | Self::PublishNeverAcked
            | Self::Timeout(_)
            | Self::Core(_) => crate::rc::Rc::Unusable,
        }
    }
}

impl fmt::Display for RigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::LoopbackOptInRefused => f.write_str("rig: loopback opt-in refused"),
            Self::SessionNotLive => f.write_str("rig: session was not live before the kill"),
            Self::SessionStillLive => f.write_str("rig: session still live after the kill"),
            Self::StopTimedOut => f.write_str("rig: engine stop timed out"),
            Self::WelcomeNeverAcked => f.write_str("rig: no welcome was acked, create rolled back"),
            Self::PublishNeverAcked => f.write_str("rig: no relay acked a staged commit"),
            Self::UnknownTarget => f.write_str("rig: schedule named a target the world lacks"),
            Self::ShapeMismatch => f.write_str("rig: relay planes do not match the world shape"),
            Self::Unhealable => f.write_str("rig: schedule asked to heal a non-fault op"),
            Self::DeclarationRefused => {
                f.write_str("rig: a value this run minted could not be declared")
            }
            Self::InductionMechanismMoved => {
                f.write_str("rig: the induction mechanism no longer matches the pinned engine")
            }
            Self::Timeout(wait) => write!(f, "rig: bounded wait elapsed ({wait:?})"),
            Self::Core(step) => write!(f, "rig: step failed ({step:?})"),
            Self::Clock(err) => write!(f, "rig: {err}"),
        }
    }
}

impl std::error::Error for RigError {}

impl From<crate::clock::ClockError> for RigError {
    fn from(err: crate::clock::ClockError) -> Self {
        Self::Clock(err)
    }
}

/// Waits for `condition`, checking it every `every` until `bound` elapses.
///
/// The rig never sleeps a fixed span as a stand-in for a condition: every wait
/// is this, so a run that is faster than its bound finishes sooner and a run
/// that misses one reports what it waited for. The elapsed time is returned
/// because several of those spans — a session release, a reconnect — ARE the
/// measurement the scenario wanted.
///
/// `Ok(None)` is the timeout; an `Err` is the condition itself failing to read.
///
/// # Errors
///
/// Whatever `condition` returns.
pub async fn poll_until<F, Fut>(
    bound: Duration,
    every: Duration,
    mut condition: F,
) -> Result<Option<Duration>, RigError>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<bool, RigError>>,
{
    let started = Instant::now();
    let mut ticker = tokio::time::interval(every);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    loop {
        if condition().await? {
            return Ok(Some(started.elapsed()));
        }
        if started.elapsed() >= bound {
            return Ok(None);
        }
        ticker.tick().await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handles_render_as_their_own_vocabulary_and_never_productions() {
        assert_eq!(DeviceTag::new(3).to_string(), "simdev#3");
        assert_eq!(CircleTag::new(0).to_string(), "simcircle#0");
        assert_eq!(RelayTag::new(1).to_string(), "simrelay#1");
        assert_eq!(EventTag::new(12).to_string(), "simevt#12");
        assert_eq!(WorldId::new(7).to_string(), "simworld#7");
        // Production's handles are `circle#a91f3c`, `peer#…`, `relay#…`,
        // `event#…`, `key_package#…`, `subscription#…`, and a reader (or a
        // scanner) finds them at a WORD BOUNDARY. The rig's `sim` prefix is
        // what keeps every one of its tags off that boundary, so both
        // vocabularies can share an evidence file without either being
        // mistaken for the other.
        for rendered in [
            DeviceTag::new(3).to_string(),
            CircleTag::new(0).to_string(),
            RelayTag::new(1).to_string(),
            EventTag::new(12).to_string(),
            WorldId::new(7).to_string(),
        ] {
            assert!(rendered.starts_with("sim"), "{rendered}");
            for production in [
                "circle#",
                "peer#",
                "event#",
                "relay#",
                "key_package#",
                "subscription#",
            ] {
                if let Some(at) = rendered.find(production) {
                    assert!(
                        at > 0 && rendered.as_bytes()[at - 1].is_ascii_alphanumeric(),
                        "{rendered} renders {production} at a word boundary"
                    );
                }
            }
        }
    }

    #[test]
    fn a_handles_debug_is_its_display() {
        assert_eq!(format!("{:?}", DeviceTag::new(2)), "simdev#2");
        assert_eq!(
            serde_json::to_string(&RelayTag::new(4)).expect("serialises"),
            "\"simrelay#4\""
        );
    }

    #[test]
    fn handles_keep_their_ordinal_for_the_rig_to_index_by() {
        assert_eq!(DeviceTag::new(9).ordinal(), 9);
        assert_eq!(
            EventTag::new(u64::from(u32::MAX) + 1).ordinal(),
            4_294_967_296
        );
    }

    #[test]
    fn magnitudes_are_bucketed_by_haven_cores_own_policy() {
        assert_eq!(sim_magnitude(0), "0");
        assert_eq!(sim_magnitude(1), "1");
        assert_eq!(sim_magnitude(3), "2-4");
        assert_eq!(sim_magnitude(4_000), "5+");
    }

    #[test]
    fn errors_render_a_classification_and_never_a_value() {
        let rendered = RigError::Core(Step::CreateCircle).to_string();
        assert!(rendered.contains("CreateCircle"), "{rendered}");
        assert_eq!(
            RigError::Core(Step::CreateCircle).rc(),
            crate::rc::Rc::Unusable
        );
        assert_eq!(
            RigError::SessionStillLive.rc(),
            crate::rc::Rc::RigBroken,
            "a leaked handle is the rig's fault, not the subject's"
        );
        assert_eq!(
            RigError::from(crate::clock::ClockError::BeforeEpoch).rc(),
            crate::rc::Rc::RigBroken
        );
        for error in [
            RigError::LoopbackOptInRefused,
            RigError::SessionNotLive,
            RigError::StopTimedOut,
            RigError::WelcomeNeverAcked,
            RigError::PublishNeverAcked,
            RigError::UnknownTarget,
            RigError::ShapeMismatch,
            RigError::Unhealable,
            RigError::DeclarationRefused,
            RigError::InductionMechanismMoved,
            RigError::Timeout(Wait::SessionReopen),
        ] {
            let text = error.to_string();
            assert!(text.starts_with("rig: "), "{text}");
            assert!(!text.contains("wss"), "{text}");
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_bounded_wait_returns_as_soon_as_the_condition_holds() {
        let polls = std::sync::atomic::AtomicU32::new(0);
        let elapsed = poll_until(Duration::from_secs(5), Duration::from_millis(1), || async {
            Ok(polls.fetch_add(1, std::sync::atomic::Ordering::Relaxed) >= 2)
        })
        .await
        .expect("condition read")
        .expect("condition held");
        assert!(elapsed < Duration::from_secs(5));
        assert_eq!(polls.load(std::sync::atomic::Ordering::Relaxed), 3);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_bounded_wait_reports_its_own_timeout_rather_than_hanging() {
        let outcome = poll_until(
            Duration::from_millis(20),
            Duration::from_millis(1),
            || async { Ok(false) },
        )
        .await
        .expect("condition read");
        assert!(outcome.is_none());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_condition_that_cannot_be_read_is_an_error_not_a_timeout() {
        let outcome = poll_until(Duration::from_secs(5), Duration::from_millis(1), || async {
            Err(RigError::Core(Step::ReadEpoch))
        })
        .await;
        assert_eq!(outcome, Err(RigError::Core(Step::ReadEpoch)));
    }
}
