//! One simulated device: a real store, a real manager, a real engine.
//!
//! Nothing here is a stand-in for the subject. A device is a `CircleManager`
//! over its own `SQLCipher` store in its own directory, optionally wrapped in a
//! `LiveSyncCore`, and it publishes through haven-core's own `RelayManager` —
//! so a Rule-13 ack is the same ack production waits for, not one the harness
//! invented.
//!
//! # Secret hygiene, and the one residual
//!
//! Every raw secret byte this harness materialises is `Zeroizing`
//! ([`SimDevice::secret_hex_for_declaration`] is the only place it does).
//! `nostr::Keys` itself CANNOT be zeroized — the type implements no `Zeroize`
//! at the pinned version, so neither `Zeroizing<Keys>` nor a `ZeroizeOnDrop`
//! derive over it compiles — and that residual is recorded rather than papered
//! over with a wrapper that would zero a copy while the original stays.

use std::fmt;
use std::path::PathBuf;
use std::sync::Arc;

use haven_core::circle::CircleManager;
use haven_core::nostr::mls::storage::{is_session_live, StorageConfig};
use haven_core::nostr::mls::SessionManager;
use haven_core::relay::live_sync::{CircleSpec, LiveSyncCore, LiveSyncEvent};
use haven_core::relay::RelayManager;
use nostr::Keys;
use tokio::sync::broadcast::error::TryRecvError;
use tokio::sync::broadcast::Receiver;
use zeroize::Zeroizing;

use crate::clock::{PolicyNow, WallNow};
use crate::rig::{CircleTag, DeviceTag, RigError, SimCircle, Step};

/// What a device has seen on its engine bus.
///
/// Counts only: the bus carries decrypted locations, sender pubkeys and
/// gift-wrap JSON, none of which this type keeps. Its `Debug` buckets even the
/// counts, because an exact magnitude is a fingerprint of the run.
#[derive(Clone, Default, PartialEq, Eq)]
pub struct DeviceLedger {
    locations: u64,
    group_updates: u64,
    welcomes: u64,
    unrecoverable: u64,
    statuses: u64,
    lagged: u64,
    per_circle: std::collections::BTreeMap<CircleTag, u64>,
}

impl DeviceLedger {
    /// Decrypted locations delivered.
    #[must_use]
    pub const fn locations(&self) -> u64 {
        self.locations
    }

    /// Roster/epoch updates delivered.
    #[must_use]
    pub const fn group_updates(&self) -> u64 {
        self.group_updates
    }

    /// Gift-wrapped invitations delivered.
    #[must_use]
    pub const fn welcomes(&self) -> u64 {
        self.welcomes
    }

    /// Terminal per-circle verdicts delivered.
    #[must_use]
    pub const fn unrecoverable(&self) -> u64 {
        self.unrecoverable
    }

    /// Sync-status signals delivered.
    #[must_use]
    pub const fn statuses(&self) -> u64 {
        self.statuses
    }

    /// Bus events dropped because the consumer fell behind. Anything but zero
    /// means the ledger under-counts and a delivery oracle reading it would be
    /// answering from an incomplete record.
    #[must_use]
    pub const fn lagged(&self) -> u64 {
        self.lagged
    }

    /// Locations delivered for one circle.
    #[must_use]
    pub fn deliveries_for(&self, circle: CircleTag) -> u64 {
        self.per_circle.get(&circle).copied().unwrap_or(0)
    }

    /// Everything delivered, of every kind.
    #[must_use]
    pub const fn total(&self) -> u64 {
        self.locations + self.group_updates + self.welcomes + self.unrecoverable + self.statuses
    }
}

// Bucketed: an exact delivery count is a magnitude of the world's behaviour.
impl fmt::Debug for DeviceLedger {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let bucket = |count: u64| crate::rig::sim_magnitude(usize::try_from(count).unwrap_or(5));
        f.debug_struct("DeviceLedger")
            .field("locations", &bucket(self.locations))
            .field("group_updates", &bucket(self.group_updates))
            .field("welcomes", &bucket(self.welcomes))
            .field("unrecoverable", &bucket(self.unrecoverable))
            .field("statuses", &bucket(self.statuses))
            .field("lagged", &bucket(self.lagged))
            .field(
                "per_circle",
                &crate::rig::sim_magnitude(self.per_circle.len()),
            )
            .finish()
    }
}

/// One device in the world.
pub struct SimDevice {
    /// This device's handle — the only spelling of it anywhere.
    pub tag: DeviceTag,
    /// The device's identity. NOT `Zeroizing`: see the module docs.
    pub keys: Keys,
    /// The store's directory, retained so a restart reopens the same `SQLite`
    /// file rather than a fresh one (which would prove nothing).
    pub dir: tempfile::TempDir,
    /// The manager. An `Option` because a restart must be able to DROP it: the
    /// Rule-14 guard is released by the last `Arc` going away, and a field that
    /// cannot be emptied makes every restart arm vacuous.
    pub circle: Option<Arc<CircleManager>>,
    /// The engine. Also an `Option`, and dropped BEFORE the manager on a
    /// restart: it holds `Arc` clones of the manager and of the processor, and
    /// `stop()` takes `&self`, so stopping alone releases nothing.
    pub core: Option<LiveSyncCore>,
    /// The harness publish plane — haven-core's own client, so a publish is
    /// the production publish.
    pub relays: RelayManager,
    /// Whether the engine is paused. "Offline" is realised as the engine's own
    /// pause/resume, which is the only in-process way to stop receiving
    /// without dropping the session.
    pub offline: bool,
    /// How far this device's POLICY clock is stepped from wall time. Never
    /// applied to a cursor, anchor or processor window (see [`crate::clock`]).
    pub policy_offset_secs: i64,
    bus_rx: Option<Receiver<LiveSyncEvent>>,
    specs: Vec<CircleSpec>,
    inbox_relays: Vec<String>,
    ledger: DeviceLedger,
}

impl SimDevice {
    /// Opens a fresh device: new keys, new directory, new store.
    ///
    /// # Errors
    ///
    /// [`RigError::Core`] with [`Step::OpenStore`] if the store cannot be
    /// opened — which includes another live session already holding it
    /// (Rule 14).
    pub fn open(tag: DeviceTag, inbox_relays: &[String]) -> Result<Self, RigError> {
        let dir = tempfile::TempDir::new().map_err(|_| RigError::Core(Step::OpenStore))?;
        let keys = Keys::generate();
        let manager = CircleManager::new_unencrypted(dir.path(), &keys)
            .map_err(|_| RigError::Core(Step::OpenStore))?;
        Ok(Self {
            tag,
            keys,
            dir,
            circle: Some(Arc::new(manager)),
            core: None,
            relays: RelayManager::new(),
            offline: false,
            policy_offset_secs: 0,
            bus_rx: None,
            specs: Vec::new(),
            inbox_relays: inbox_relays.to_vec(),
            ledger: DeviceLedger::default(),
        })
    }

    /// The device's manager.
    ///
    /// # Errors
    ///
    /// [`RigError::SessionNotLive`] if the device is between a kill and its
    /// reopen — a caller reaching for a manager that is deliberately gone is a
    /// rig bug, not a subject defect.
    pub fn manager(&self) -> Result<&Arc<CircleManager>, RigError> {
        self.circle.as_ref().ok_or(RigError::SessionNotLive)
    }

    /// The device's MLS session.
    ///
    /// # Errors
    ///
    /// As [`Self::manager`].
    pub fn session(&self) -> Result<&Arc<SessionManager>, RigError> {
        Ok(self.manager()?.session())
    }

    /// The device's engine.
    ///
    /// # Errors
    ///
    /// [`RigError::SessionNotLive`] if no engine is running.
    pub fn engine(&self) -> Result<&LiveSyncCore, RigError> {
        self.core.as_ref().ok_or(RigError::SessionNotLive)
    }

    /// The device's identity public key, hex-encoded — how a welcome names its
    /// recipient. Never rendered.
    #[must_use]
    pub fn pubkey_hex(&self) -> String {
        self.keys.public_key().to_hex()
    }

    /// The device's secret key in the one raw encoding the needle manifest
    /// must be able to search for.
    ///
    /// `Zeroizing` because this is the only place the harness materialises a
    /// secret as bytes, and a declaration that outlives its use in the heap is
    /// exactly what Rule 7 is about.
    #[must_use]
    pub fn secret_hex_for_declaration(&self) -> Zeroizing<String> {
        Zeroizing::new(self.keys.secret_key().to_secret_hex())
    }

    /// The `session.sqlite` path — the key the Rule-14 registry is keyed by.
    ///
    /// Taking the directory instead would compute a key nothing is registered
    /// under, and every liveness answer would be a vacuous `false`.
    #[must_use]
    pub fn session_db_path(&self) -> PathBuf {
        StorageConfig::new(self.dir.path()).database_path()
    }

    /// Whether this device's session is currently held.
    ///
    /// # Errors
    ///
    /// [`RigError::Core`] with [`Step::ReadSessionLiveness`] if the path
    /// cannot be reduced to a registry key.
    pub fn session_is_live(&self) -> Result<bool, RigError> {
        is_session_live(&self.session_db_path())
            .map_err(|_| RigError::Core(Step::ReadSessionLiveness))
    }

    /// The circles this device subscribes to, as it was started with.
    #[must_use]
    pub fn specs(&self) -> &[CircleSpec] {
        &self.specs
    }

    /// The relays this device takes invitations on.
    #[must_use]
    pub fn inbox_relays(&self) -> &[String] {
        &self.inbox_relays
    }

    /// This device's policy instant for `wall`.
    ///
    /// # Errors
    ///
    /// [`RigError::Clock`] if the accumulated offset moves the instant below
    /// the Unix epoch.
    pub fn policy_now(&self, wall: WallNow) -> Result<PolicyNow, RigError> {
        Ok(PolicyNow::from_wall_with_offset(
            wall,
            self.policy_offset_secs,
        )?)
    }

    /// Steps this device's policy clock. Only ever called between quiescent
    /// phases: stepping under in-flight work would age out rows the world is
    /// still converging.
    pub const fn step_policy_offset(&mut self, secs: i64) {
        self.policy_offset_secs = self.policy_offset_secs.saturating_add(secs);
    }

    /// Starts the engine over `specs`, subscribing to this device's inbox.
    ///
    /// # Errors
    ///
    /// [`RigError::Core`] with [`Step::StartEngine`] if a subscription fails.
    pub async fn start_engine(&mut self, specs: Vec<CircleSpec>) -> Result<(), RigError> {
        let manager = Arc::clone(self.manager()?);
        let core = LiveSyncCore::new_local(manager, self.keys.public_key());
        // Subscribed BEFORE start: a broadcast receiver only sees what is sent
        // after it subscribes, and the first deliveries can land inside start.
        let bus_rx = core.bus().subscribe();
        core.start(&specs, &self.inbox_relays)
            .await
            .map_err(|_| RigError::Core(Step::StartEngine))?;
        self.specs = specs;
        self.bus_rx = Some(bus_rx);
        self.core = Some(core);
        self.offline = false;
        Ok(())
    }

    /// Pauses the engine: it keeps its session and stops receiving.
    ///
    /// # Errors
    ///
    /// [`RigError::SessionNotLive`] if no engine is running.
    pub async fn go_offline(&mut self) -> Result<(), RigError> {
        let core = self.engine()?;
        // Production's order: settle first, so the convergence traffic a commit
        // provoked lands on a socket that is still open, and only then close
        // every REQ.
        core.settle_before_pause().await;
        core.pause_subscriptions()
            .await
            .map_err(|_| RigError::Core(Step::PauseEngine))?;
        self.offline = true;
        Ok(())
    }

    /// Resumes the engine and re-anchors it.
    ///
    /// # Errors
    ///
    /// [`RigError::Core`] with [`Step::ResumeEngine`] if the re-subscription
    /// fails.
    pub async fn come_online(&mut self) -> Result<(), RigError> {
        self.engine()?
            .resume_after_background()
            .await
            .map_err(|_| RigError::Core(Step::ResumeEngine))?;
        self.offline = false;
        Ok(())
    }

    /// Folds every bus event waiting for this device into its ledger and
    /// returns how many were folded.
    ///
    /// Non-blocking by design: a tick drains what has arrived, and a delivery
    /// that has not arrived yet is the *absence* a bounded wait is for.
    pub fn drain_bus(&mut self, circles: &[SimCircle]) -> usize {
        let Some(rx) = self.bus_rx.as_mut() else {
            return 0;
        };
        let mut drained = 0;
        loop {
            match rx.try_recv() {
                Ok(event) => {
                    drained += 1;
                    match event {
                        LiveSyncEvent::Location {
                            ref nostr_group_id, ..
                        } => {
                            self.ledger.locations += 1;
                            if let Some(circle) = circles.iter().find(|c| {
                                c.nostr_group_id().as_slice() == nostr_group_id.as_slice()
                            }) {
                                *self.ledger.per_circle.entry(circle.tag).or_insert(0) += 1;
                            }
                        }
                        LiveSyncEvent::GroupUpdate { .. } => self.ledger.group_updates += 1,
                        LiveSyncEvent::Welcome { .. } => self.ledger.welcomes += 1,
                        LiveSyncEvent::GroupUnrecoverable { .. } => self.ledger.unrecoverable += 1,
                        LiveSyncEvent::Status { .. } => self.ledger.statuses += 1,
                    }
                }
                // The consumer fell behind: the events are GONE, so the ledger
                // is recorded as incomplete rather than quietly under-counting.
                Err(TryRecvError::Lagged(skipped)) => self.ledger.lagged += skipped,
                Err(TryRecvError::Empty | TryRecvError::Closed) => return drained,
            }
        }
    }

    /// What this device has seen.
    #[must_use]
    pub const fn ledger(&self) -> &DeviceLedger {
        &self.ledger
    }

    /// Takes the engine out for a restart. The caller must DROP the returned
    /// core: holding it keeps the manager `Arc`s — and the Rule-14 guard —
    /// alive.
    #[must_use]
    pub fn take_engine(&mut self) -> Option<LiveSyncCore> {
        self.bus_rx = None;
        self.core.take()
    }

    /// Takes the manager out for a restart, with the same obligation.
    #[must_use]
    pub const fn take_manager(&mut self) -> Option<Arc<CircleManager>> {
        self.circle.take()
    }

    /// Puts a freshly reopened manager back.
    pub fn restore_manager(&mut self, manager: Arc<CircleManager>) {
        self.circle = Some(manager);
    }
}

// Presence-only: the keys, the store path and the roster are all identifiers.
impl fmt::Debug for SimDevice {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SimDevice")
            .field("tag", &self.tag)
            .field("offline", &self.offline)
            .field("ledger", &self.ledger)
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rig::CircleTag;

    fn device(ordinal: u32) -> SimDevice {
        SimDevice::open(DeviceTag::new(ordinal), &["ws://127.0.0.1:1".to_string()])
            .expect("device opens")
    }

    #[test]
    fn a_devices_debug_renders_its_handle_and_nothing_it_holds() {
        let device = device(4);
        let rendered = format!("{device:?}");
        assert!(rendered.contains("simdev#4"), "{rendered}");
        assert!(!rendered.contains(&device.pubkey_hex()), "{rendered}");
        assert!(
            !rendered.contains(device.secret_hex_for_declaration().as_str()),
            "{rendered}"
        );
        assert!(
            !rendered.contains(device.dir.path().to_string_lossy().as_ref()),
            "{rendered}"
        );
        assert!(!rendered.contains("ws://"), "{rendered}");
    }

    #[test]
    fn the_declarable_secret_is_this_devices_own_key_in_the_raw_encoding() {
        let one = device(0);
        let other = device(1);
        let secret = one.secret_hex_for_declaration();
        assert_eq!(
            secret.len(),
            64,
            "the needle manifest searches for this form"
        );
        assert!(secret.chars().all(|c| c.is_ascii_hexdigit()));
        assert_ne!(*secret, *other.secret_hex_for_declaration());
        assert_ne!(one.pubkey_hex(), other.pubkey_hex());
    }

    #[test]
    fn a_session_path_is_the_database_file_the_registry_is_keyed_by() {
        let device = device(0);
        let path = device.session_db_path();
        assert_eq!(
            path.file_name().map(std::ffi::OsStr::to_string_lossy),
            Some(std::borrow::Cow::Borrowed("session.sqlite")),
            "the registry key is the file; a directory answers `not live` for ever"
        );
        assert!(device.session_is_live().expect("liveness"));
    }

    #[test]
    fn a_ledger_counts_exactly_and_renders_buckets() {
        let mut ledger = DeviceLedger {
            locations: 7,
            lagged: 2,
            ..DeviceLedger::default()
        };
        ledger.per_circle.insert(CircleTag::new(0), 7);
        assert_eq!(ledger.locations(), 7);
        assert_eq!(ledger.total(), 7);
        assert_eq!(ledger.deliveries_for(CircleTag::new(0)), 7);
        assert_eq!(ledger.deliveries_for(CircleTag::new(1)), 0);

        let rendered = format!("{ledger:?}");
        assert!(rendered.contains("5+"), "{rendered}");
        assert!(!rendered.contains('7'), "{rendered}");
        assert!(rendered.contains("DeviceLedger"), "{rendered}");
    }

    #[test]
    fn a_policy_offset_accumulates_and_never_wraps() {
        let mut device = device(0);
        device.step_policy_offset(288);
        device.step_policy_offset(288);
        assert_eq!(device.policy_offset_secs, 576);
        device.step_policy_offset(i64::MAX);
        assert_eq!(device.policy_offset_secs, i64::MAX);
    }
}
