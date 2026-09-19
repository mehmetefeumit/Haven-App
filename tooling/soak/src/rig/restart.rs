//! Killing a device and bringing it back on the same store.
//!
//! # Why the drop order is the contract
//!
//! The Rule-14 session guard is released when the LAST `Arc<CircleManager>`
//! goes away, and the rig's is not the last one: a `LiveSyncCore` holds a
//! manager `Arc` *and* a processor `Arc` which holds its own, and the repair
//! plane clones both into a spawned task. `stop()` takes `&self`, so it neither
//! consumes the core nor drops those clones, and it does not abort tasks when
//! its join budget elapses. So a restart takes the core OUT and drops it, then
//! takes the manager out and drops it, and only then waits — bounded — for the
//! registry to say the session is free.
//!
//! That wait is allowed to lag, because a task holding a clone has to finish
//! first. It is not allowed to never end: a timeout is
//! [`RigError::SessionStillLive`], which is the rig's own fault (rc 2), never a
//! silent pass on a restart that never happened.

use std::fmt;
use std::time::Duration;

use haven_core::circle::CircleManager;
use haven_core::nostr::mls::storage::is_session_live;
use haven_core::relay::live_sync::StopOutcome;
use serde::Serialize;
use tokio::time::{Instant, MissedTickBehavior};

use crate::rig::{poll_until, RigError, SimDevice, Step, Wait};

/// How long the rig waits for a killed device's session to be released.
///
/// Six times the engine's own five-second stop-join budget: a soft kill is
/// bounded by that budget, a hard kill drops the core with tasks still running
/// and waits on whichever of them holds the last clone. The observed latency is
/// recorded either way, so a bound that is generous costs a slow failure and
/// nothing else.
const RELEASE_BOUND: Duration = Duration::from_secs(30);

/// How long the rig waits for the store to be reopenable.
const REOPEN_BOUND: Duration = Duration::from_secs(30);

/// How often either condition is re-read.
const RESTART_POLL: Duration = Duration::from_millis(20);

/// How a device dies.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum KillKind {
    /// The app closes: the engine is stopped first and its tasks joined.
    Soft,
    /// The OS kills the process: nothing is stopped, nothing is joined. The
    /// honest shape of a background kill.
    Hard,
}

impl KillKind {
    /// The literal the timeline records.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Soft => "soft",
            Self::Hard => "hard",
        }
    }

    /// The schedule-digest discriminant.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Soft => 0,
            Self::Hard => 1,
        }
    }
}

impl fmt::Display for KillKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.label())
    }
}

/// What a restart measured.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReopenReport {
    /// How long the session took to be released after the handles were
    /// dropped. This span IS the Rule-14 measurement.
    pub release: Duration,
    /// How long the store took to become reopenable.
    pub reopen: Duration,
    /// Whether the device's engine was restarted with it.
    pub engine_restarted: bool,
}

/// Kills `device` and brings it back on the same store.
///
/// # Errors
///
/// * [`RigError::SessionNotLive`] if the session was not held to begin with —
///   the control would have proven nothing.
/// * [`RigError::StopTimedOut`] if a soft kill's `stop` did not drain.
/// * [`RigError::SessionStillLive`] if the session was never released: the rig
///   leaked a handle.
/// * [`RigError::Timeout`] if the store never became reopenable.
pub async fn kill_and_reopen(
    device: &mut SimDevice,
    kind: KillKind,
) -> Result<ReopenReport, RigError> {
    let db = device.session_db_path();
    if !device.session_is_live()? {
        return Err(RigError::SessionNotLive);
    }

    let engine_restarted = device.core.is_some();
    let specs = device.specs().to_vec();

    if let Some(core) = device.take_engine() {
        if kind == KillKind::Soft {
            let outcome = core.stop().await;
            if outcome == StopOutcome::TimedOut {
                // The tasks are still running and still hold the guard. Say so
                // rather than reporting a teardown that did not happen.
                return Err(RigError::StopTimedOut);
            }
        }
        drop(core);
    }
    drop(device.take_manager());

    let release = poll_until(RELEASE_BOUND, RESTART_POLL, || async {
        is_session_live(&db)
            .map(|live| !live)
            .map_err(|_| RigError::Core(Step::ReadSessionLiveness))
    })
    .await?
    .ok_or(RigError::SessionStillLive)?;

    // A bounded retry rather than one attempt: `LiveSessionGuard::acquire`
    // fails closed while the guard is held, and the registry entry and the
    // file lock are released by different code paths.
    let started = Instant::now();
    let mut ticker = tokio::time::interval(RESTART_POLL);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let manager = loop {
        match CircleManager::new_unencrypted(device.dir.path(), &device.keys) {
            Ok(manager) => break manager,
            Err(_) if started.elapsed() < REOPEN_BOUND => {
                ticker.tick().await;
            }
            Err(_) => return Err(RigError::Timeout(Wait::SessionReopen)),
        }
    };
    let reopen = started.elapsed();
    device.restore_manager(std::sync::Arc::new(manager));

    if engine_restarted {
        device.start_engine(specs).await?;
    }

    Ok(ReopenReport {
        release,
        reopen,
        engine_restarted,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rig::{DeviceTag, SimDevice};

    /// A device with no engine and no circle: enough to hold a session, which
    /// is the whole subject of a restart.
    fn lone_device() -> SimDevice {
        SimDevice::open(DeviceTag::new(0), &["ws://127.0.0.1:1".to_string()]).expect("device opens")
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_hard_kill_releases_the_session_and_reopens_the_same_store() {
        let mut device = lone_device();
        let db = device.session_db_path();
        assert!(device.session_is_live().expect("liveness"));

        let report = kill_and_reopen(&mut device, KillKind::Hard)
            .await
            .expect("restart");

        assert!(!report.engine_restarted, "this device had no engine");
        assert_eq!(device.session_db_path(), db, "the store did not move");
        assert!(
            device.session_is_live().expect("liveness"),
            "the reopened device holds the session again"
        );
        assert!(device.manager().is_ok());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_soft_kill_reaches_the_same_state_with_nothing_to_stop() {
        let mut device = lone_device();
        kill_and_reopen(&mut device, KillKind::Soft)
            .await
            .expect("restart");
        assert!(device.session_is_live().expect("liveness"));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn killing_a_device_that_holds_no_session_is_refused() {
        let mut device = lone_device();
        drop(device.take_manager());
        assert_eq!(
            kill_and_reopen(&mut device, KillKind::Hard).await,
            Err(RigError::SessionNotLive),
            "a restart control that starts from a dead session proves nothing"
        );
    }

    /// The anti-vacuity control for every restart arm: if the rig leaks a
    /// handle, the session is never released, and the restart that follows
    /// would silently be a no-op on a store that never closed.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_leaked_manager_handle_is_reported_rather_than_waited_out_forever() {
        let mut device = lone_device();
        let leaked = std::sync::Arc::clone(device.manager().expect("manager"));

        assert_eq!(
            kill_and_reopen(&mut device, KillKind::Hard).await,
            Err(RigError::SessionStillLive)
        );
        assert_eq!(
            RigError::SessionStillLive.rc(),
            crate::rc::Rc::RigBroken,
            "a leaked handle is the instrument's fault, never the subject's"
        );
        drop(leaked);
    }

    #[test]
    fn a_kill_kind_renders_as_a_literal() {
        assert_eq!(KillKind::Soft.to_string(), "soft");
        assert_eq!(KillKind::Hard.label(), "hard");
        assert_ne!(KillKind::Soft.code(), KillKind::Hard.code());
    }
}
