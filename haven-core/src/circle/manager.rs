//! High-level circle management API.
//!
//! This module provides the [`CircleManager`] which combines MLS operations
//! (via [`SessionManager`]) with application-level storage ([`CircleStorage`])
//! to provide a unified API for circle management.
//!
//! # Privacy Model
//!
//! Haven uses a privacy-first approach where:
//! - User profiles (kind 0) are public-by-default; all other group metadata
//!   stays local
//! - Contact info (petnames) is stored locally only
//! - Relays only see pubkeys and the pseudonymous `nostr_group_id`
//!
//! # Dark Matter engine (DM-3)
//!
//! The circle layer sits on the Dark Matter [`SessionManager`] (one hydrated
//! `AccountDeviceSession` behind a `tokio` mutex). Its mutating calls are
//! `async` and take `&mut self` internally, so every `CircleManager` method
//! that touches the session is `async`. The engine owns convergence,
//! out-of-order sequencing, and publish-before-apply (`PendingStateRef`); the
//! hand-rolled settle-window / staged-commit / un-poison machinery that used to
//! live here is deleted (plan §5.3/§5.4).
//!
//! [`SessionManager`]: crate::nostr::mls::SessionManager

use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::Path;
use std::sync::{Arc, Mutex};

use nostr::{Event, EventId, Keys, PublicKey};

use super::contamination::ContaminationSource;
use super::error::{CircleError, Result};
use super::leave::{plan_leave, LeavePlan};
use super::rotation::{rotation_decision, RotationDecision, RotationInputs, SkipReason};
use super::storage::{CircleStorage, PriorRouting};
use super::storage_key_packages::CONSUMED_HOLD_OVER;
use super::storage_member_directory::DirectoryTier;
use super::types::{
    Circle, CircleConfig, CircleEngineState, CircleMember, CircleMembership, CircleType,
    CircleWithMembers, Contact, GiftWrappedWelcome, Invitation, MemberKeyPackage, MembershipStatus,
};
use crate::location::LocationMessage;
use crate::log_alias::{self, bucket, EventIdHex};
use crate::nostr::mls::types::{
    ConvergedRoster, ConvergenceSweep, FanoutId, FanoutSettlement, FoundingWelcome, GroupEvent,
    GroupId, GroupIdExt, GroupStateChange, KeyPackage, LeftGroup, LocationGroupConfig,
    LocationMessageResult, MemberId, MessageId, PendingStateRef, PublishWork, QueuedIntentRef,
    RejoinConfirmation, RejoinOffer, SessionEffects, Staged, StoredFanout, TransportMessage,
    WelcomeAcceptance,
};
use crate::nostr::mls::{bounded_retention_secs, redact_hex_sequences};
use crate::nostr::mls::{CommitNotes as _, PendingWelcome, PendingWelcomeStore, SessionManager};
use crate::relay::fanout::{DriveMode, Still};

/// How long a prior routing keeps a standing REQ after its row was written
/// (decision 237): a day.
const PRIOR_ROUTING_STANDS_SECS: i64 = 86_400;

/// How many epochs back a prior routing stays an address its traffic is
/// fetched at: the wider of the engine's two retained-history windows, the
/// rewind horizon for commits and proposals and the past-epoch window for
/// application messages.
fn routing_retained_epochs() -> u64 {
    crate::nostr::mls::max_rewind_commits()
        .max(u64::try_from(crate::nostr::mls::DEFAULT_MAX_PAST_EPOCHS).unwrap_or(u64::MAX))
}

/// The entries of a circle's routing component this device may dial.
///
/// Another client's admin writes that component, and MDK admits any spelling
/// that parses to `ws` or `wss`, on any host, into it. An entry that fails
/// Haven's rule for another client's relays
/// ([`crate::relay::foreign_relay_dialable`]: `wss` to a public host) is
/// dropped HERE, where the circle's own relay list is derived — never
/// the list, and never the component: every publish validates its whole target
/// list and the live-sync engine its whole session, so one plaintext entry
/// would otherwise stop every publish to the circle, the relay update that
/// repairs it, and receiving for every other circle on the device.
fn usable_relays(named: Vec<String>) -> Vec<String> {
    named
        .into_iter()
        .filter(|relay| crate::relay::foreign_relay_dialable(relay))
        .collect()
}

/// The wall clock in Unix seconds, floored at the epoch.
///
/// `unsigned_abs()` would be the obvious conversion and is wrong: on a device
/// whose clock has slipped before 1970 it turns a small negative timestamp into
/// a huge positive one, and every age comparison built on it then reports every
/// stored row as ancient — mass-retiring rows that are seconds old. Saturating
/// to `0` instead makes a pre-epoch clock retire NOTHING, which is the direction
/// a clock this broken should fail in.
fn now_secs() -> u64 {
    u64::try_from(chrono::Utc::now().timestamp()).unwrap_or(0)
}

/// Converts a stored millisecond instant to Unix seconds, dropping a pre-epoch
/// value rather than wrapping it.
///
/// Same fail-safe direction as [`now_secs`]: a negative stamp is a clock this
/// device cannot trust, and reading it as "never observed" makes the rotation
/// gates fall back on the gates that do not depend on it.
fn secs_from_ms(at_ms: Option<i64>) -> Option<u64> {
    at_ms
        .and_then(|ms| u64::try_from(ms).ok())
        .map(|ms| ms / 1_000)
}

/// Re-renders a storage error with any hex sequence removed.
///
/// A `rusqlite::Error` message can quote the failing statement and its bound
/// parameters, and on the circle tables those parameters carry the circle's
/// `nostr_group_id`. Rule 8 keeps that off the FFI boundary, so a storage
/// failure crosses it as prose that says what broke and nothing about which
/// circle it broke on.
pub fn redact_storage_error(err: &CircleError) -> CircleError {
    CircleError::Storage(redact_hex_sequences(&err.to_string()))
}

/// File name of the encrypted circle-metadata database. New with the MDK
/// v0.10.4 store, so a pre-migration file is never opened
/// (`crate::storage_reset` deletes it).
pub const CIRCLES_DB_FILENAME: &str = "circles-v2.db";

/// How long a consumed `KeyPackage` waits for a held invitation: 72 hours.
///
/// Counted from the first maintenance tick that waited
/// ([`CircleManager::consumed_key_package_replacement_waits`]). Long enough to
/// answer an invitation over a weekend; short enough that a stranger's
/// unanswerable invitation costs three days of one init key and no more.
pub const CONSUMED_KEY_PACKAGE_HOLD_SECS: u64 = 72 * 60 * 60;

/// What a circle whose epoch cannot be read is taken as when it names a
/// routing id under a prior routing ([`CircleManager::other_circle_with_routing_id`]).
#[derive(Clone, Copy, PartialEq, Eq)]
enum UnreadEpoch {
    /// Holding it: MDK has already moved the route, and a store that cannot
    /// say must not leave the circle it may have taken it from sharing.
    Holds,
    /// An error, asked again at the next reconcile: the hold a reconcile
    /// sets ends only with a leave, never on a transient read.
    Errs,
}

/// High-level API for circle management.
///
/// Combines MLS operations with application-level storage to provide a unified
/// interface for creating and managing circles.
pub struct CircleManager {
    /// The single, process-global Dark Matter session (Rule 14: one live
    /// [`SessionManager`] per DB file across ALL isolates — the M7 background
    /// catch-up path MUST reuse this handle, never open a second session).
    session: Arc<SessionManager>,
    /// Hold-before-ingest pending-welcome store (F3): the still-encrypted 1059
    /// gift wraps awaiting the user's accept / decline. In-memory; re-seeded
    /// from relays on each poll (gift wraps are permanent on relays).
    pending_welcomes: PendingWelcomeStore,
    /// The data directory both stores live in, where the storage reset's
    /// notice marker is read (`crate::storage_reset`).
    data_dir: std::path::PathBuf,
    /// Binds each repair rotation staged under a durable fanout, keyed by
    /// that fanout's commit, to the circle whose 24-hour rate limit it
    /// spends: spent when the fanout driver's confirm applies it
    /// ([`Self::confirm_fanout`]).
    rotation_fanouts: Mutex<HashMap<MessageId, [u8; 32]>>,
    /// Proposals no record could be written for that a fold handed back to
    /// a call which may call no relay — a mesh drive, a seal for the mesh
    /// alone — each owed its one send by the next relay drive
    /// ([`Self::owe_proposals`]).
    owed_proposals: Mutex<Vec<Event>>,
    /// Fired whenever a circle's row moved to new relays, by whichever plane
    /// applied the change: the live session's follow waits on it
    /// ([`Self::routing_moved`]).
    routing_moved: tokio::sync::Notify,
    /// A test's stand-in for a process killed between a commit and its
    /// persist: the next follow at the persist is not made.
    #[cfg(any(test, feature = "test-utils"))]
    skip_next_follow: std::sync::atomic::AtomicBool,
    /// Serializes everything that publishes or retracts the OWN public profile
    /// — see [`Self::profile_sync_lock`].
    profile_sync_lock: tokio::sync::Mutex<()>,
    /// Serializes the member-directory reconcile's read-union → write-union
    /// against itself and against [`Self::remove_members`]' row delete.
    ///
    /// Without it the walk is invoked concurrently from live sync, catch-up and
    /// the Dart FFI with no ordering: a pass that read a circle's roster before
    /// the user tapped Remove would re-insert the removed person afterwards, and
    /// because the union rewrite DEMOTES rather than deletes, they would come
    /// back with a three-day timer instead of being gone (owner decision D3).
    directory_lock: tokio::sync::Mutex<()>,
    /// Single-flight state for [`Self::reconcile_member_directory_best_effort`].
    ///
    /// A peer leaving a circle of M produces up to M−1 competing auto-commits,
    /// and each reconcile walks every circle through
    /// `has_pending_convergence_inputs`, which deserialises every retained MLS
    /// message at epoch ≥ tip−5 — a circle's whole location history, because a
    /// circle's epoch only advances on a membership commit. Collapsing a storm
    /// into one walk (carrying the strongest verdict asked for while it ran) is
    /// what keeps that off the latency of Add / Remove / Create Member, whose
    /// drive Dart awaits inline through the fanout driver's confirm.
    directory_flight: Mutex<DirectoryFlight>,
    /// How many invitations were held unanswered when this process opened
    /// (`usize::MAX` when that could not be read): until as many are held
    /// again, some may not have been polled back yet.
    held_at_open: usize,
    /// Whether as many invitations as were held at the open have been held
    /// again since.
    held_polled_back: std::sync::atomic::AtomicBool,
    /// How many convergence re-ticks the publish-resolution fold has SLEPT for
    /// over this manager's life.
    ///
    /// The only observable that separates "this confirm did not sleep" from
    /// "this confirm slept and happened to be quick", which is what makes the
    /// quiet-path guarantee (a circle with nothing pending pays no delay) a
    /// testable promise rather than a wall-clock guess.
    ///
    /// Compiled into shipped builds for a `cfg(test)`-only reader, deliberately:
    /// one relaxed `fetch_add` on a path that is about to sleep 20 ms is cheaper
    /// than a `cfg`-split field, and a field that exists only under test is a
    /// field the shipped code path is not the one being measured.
    convergence_reticks: std::sync::atomic::AtomicUsize,
    pub(crate) storage: Arc<CircleStorage>,
}

/// Single-flight bookkeeping for the member-directory reconcile.
///
/// `running` and `owed` are read and written under ONE lock so a runner that
/// finds nothing owed and a caller that queues a verdict cannot interleave into
/// a lost wake-up: the runner clears `running` in the same critical section in
/// which it observes `owed` empty.
#[derive(Default)]
struct DirectoryFlight {
    /// A walk is in progress and will drain `owed` before it finishes.
    running: bool,
    /// The strongest verdict asked for while a walk was in progress.
    owed: Option<DirectoryReconcile>,
}

/// The relay set an admin asked for, canonical — each entry normalized as the
/// user's own relay list is (a relay Haven may dial), on a public host
/// ([`crate::relay::foreign_relay_dialable`]: every member's client dials it),
/// sorted and deduplicated — and one MDK's routing component takes
/// (`NostrRoutingV1::new`: at most 16 relays, each a bounded `ws`/`wss` URL
/// with a host and no credentials or fragment). The refusals are fixed text:
/// MDK's names the count, and no refusal names a relay.
fn circle_relays(new_relays: &[String]) -> Result<Vec<String>> {
    let mut canonical: Vec<String> = Vec::with_capacity(new_relays.len());
    for relay in new_relays {
        let relay = super::storage_relay_prefs::normalize_url(relay)?;
        if !crate::relay::foreign_relay_dialable(&relay) {
            return Err(CircleError::InvalidData(
                "A circle relay must be on a public host".to_string(),
            ));
        }
        canonical.push(relay);
    }
    canonical.sort();
    canonical.dedup();
    if canonical.is_empty() {
        return Err(CircleError::InvalidData(
            "A circle must have at least one relay".to_string(),
        ));
    }
    cgka_traits::app_components::NostrRoutingV1::new([0; 32], canonical)
        .map(|routing| routing.relays)
        .map_err(|_| CircleError::InvalidData("A circle cannot carry this relay set".to_string()))
}

impl CircleManager {
    /// Creates a new circle manager bound to the device identity `keys`.
    ///
    /// Initializes both the MLS session and circle storage at the given path.
    /// The identity keys bind the engine's account identity, its NIP-59 welcome
    /// signer, and its hardened account-identity-proof signer (Rule 1).
    ///
    /// # Arguments
    ///
    /// * `data_dir` - Base directory for all Haven data
    /// * `keys` - The device's Nostr identity keys
    /// * `circle_db_hex_key` - Optional hex-encoded encryption key for
    ///   circles.db. When provided, the database is encrypted with `SQLCipher`.
    ///
    /// # Errors
    ///
    /// Returns an error if initialization fails.
    pub fn new(data_dir: &Path, keys: &Keys, circle_db_hex_key: Option<&str>) -> Result<Self> {
        std::fs::create_dir_all(data_dir)
            .map_err(|e| CircleError::Storage(format!("Failed to create data directory: {e}")))?;
        // Before either store opens, in every isolate: whichever process opens
        // first on an upgraded install is the one that clears the old stores.
        let _ = crate::storage_reset::reset_pre_v2_storage(data_dir);

        // The circle store first: the session's open notes what it finds in
        // it.
        let db_path = data_dir.join(CIRCLES_DB_FILENAME);
        let storage = Arc::new(CircleStorage::new(&db_path, circle_db_hex_key)?);
        let mut session = SessionManager::new_with_notes(data_dir, keys, Some(storage.clone()))
            .map_err(CircleError::from_session)?;
        let held_at_open = storage.held_invitation_count().unwrap_or(usize::MAX);
        session.install_refused_ledger(storage.clone());
        session.install_stall_evidence(storage.clone());
        session.install_mesh_keys(storage.clone());
        Self::backfill_contamination_ledger(&storage);
        Self::prune_retired_profile_pool(&storage);
        Self::sweep_expired_directory_members(&storage);

        Ok(Self {
            session: Arc::new(session),
            pending_welcomes: PendingWelcomeStore::new(),
            data_dir: data_dir.to_path_buf(),
            rotation_fanouts: Mutex::new(HashMap::new()),
            owed_proposals: Mutex::new(Vec::new()),
            routing_moved: tokio::sync::Notify::new(),
            #[cfg(any(test, feature = "test-utils"))]
            skip_next_follow: std::sync::atomic::AtomicBool::new(false),
            profile_sync_lock: tokio::sync::Mutex::new(()),
            directory_lock: tokio::sync::Mutex::new(()),
            directory_flight: Mutex::new(DirectoryFlight::default()),
            held_at_open,
            held_polled_back: std::sync::atomic::AtomicBool::new(held_at_open == 0),
            convergence_reticks: std::sync::atomic::AtomicUsize::new(0),
            storage,
        })
    }

    /// Runs the startup contamination fold, best-effort.
    ///
    /// Backfills installs that predate the per-event write sites: their circles,
    /// inbox relays and `KeyPackage` relays already carry location-plane traffic
    /// but have no ledger rows, so without this their profile pool would happily
    /// include a relay that has been routing their kind-445 for months. On a
    /// current install every URL is already present and the fold is a no-op.
    ///
    /// It is also the ONLY write site for the discovery plane, which has no
    /// per-query recorder because the discovery set is a process constant — see
    /// [`CircleStorage::refresh_contamination_ledger`].
    ///
    /// Failure is logged rather than propagated: a manager that refuses to open
    /// because a diagnostic backfill failed would take location sharing down
    /// with it. The fold is idempotent, so the next launch retries. The
    /// per-event write sites remain fail-closed (they propagate), so this is a
    /// net for HISTORY, never the primary guarantee.
    fn backfill_contamination_ledger(storage: &CircleStorage) {
        match storage.refresh_contamination_ledger(chrono::Utc::now().timestamp()) {
            Ok(0) => {}
            Ok(n) => log::info!(
                "contamination ledger: backfilled {} relay(s) at startup",
                bucket(n)
            ),
            Err(e) => log::warn!(
                "contamination ledger backfill failed (retries next launch): {}",
                e.code()
            ),
        }
    }

    /// Runs the startup retired-relay prune, best-effort.
    ///
    /// Removes relays retired from the curated profile pool
    /// ([`crate::profile::RETIRED_PROFILE_RELAYS`]) from the stored Profile
    /// category, so an upgraded install stops assigning authors to relays that
    /// vetting proved dead or write-rejecting. See
    /// [`CircleStorage::prune_retired_profile_relays`].
    ///
    /// Failure is logged rather than propagated for the same reason the
    /// contamination fold's is: the prune is idempotent and retries next
    /// launch, and a manager that refuses to open over it would take location
    /// sharing down with a profile-plane repair.
    fn prune_retired_profile_pool(storage: &CircleStorage) {
        match storage.prune_retired_profile_relays() {
            Ok(0) => {}
            Ok(n) => log::info!(
                "profile pool: pruned {} retired relay row(s) at startup",
                bucket(n)
            ),
            Err(e) => log::warn!(
                "retired profile-relay prune failed (retries next launch): {}",
                e.code()
            ),
        }
    }

    /// Enforces the member directory's retention deadline at process start,
    /// best-effort.
    ///
    /// The three-day window is a promise about the DISK, and every other caller
    /// of the purge needs something to happen first: a membership change, a
    /// publish resolution, a welcome accept, or the user opening the picker. An
    /// install with a stable circle produces none of those, so without this a
    /// departed co-member's pubkey outlives the window by however long the user
    /// goes without inviting anyone.
    ///
    /// Process start is the trigger because it is the one an idle device still
    /// produces — every foreground launch and every background wake builds a
    /// manager — and because a bare purge is a single indexed DELETE on
    /// `circles.db`: no roster read, no MLS session, nothing that could make it
    /// a new wake or a new battery cost. It rides an open this constructor was
    /// already performing, beside the two maintenance passes above it.
    ///
    /// Failure is logged rather than propagated, as they are: the next launch
    /// retries, the ranked read sweeps the same rows before it can show one, and
    /// a manager that refused to open over a retention sweep would take location
    /// sharing down with the picker's index.
    fn sweep_expired_directory_members(storage: &CircleStorage) {
        match storage.prune_expired_directory_members(chrono::Utc::now().timestamp()) {
            Ok(0) => {}
            Ok(n) => log::info!(
                "member directory: purged {} expired row(s) at startup",
                bucket(n)
            ),
            Err(e) => log::warn!(
                "member directory retention sweep failed (retries next launch): {}",
                e.code()
            ),
        }
    }

    /// Creates a new circle manager with a fixed-key (test) MLS session.
    ///
    /// # Warning
    ///
    /// Uses a constant passphrase for the encrypted session DB. Only for
    /// testing or development.
    ///
    /// # Errors
    ///
    /// Returns an error if initialization fails.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn new_unencrypted(data_dir: &Path, keys: &Keys) -> Result<Self> {
        std::fs::create_dir_all(data_dir)
            .map_err(|e| CircleError::Storage(format!("Failed to create data directory: {e}")))?;

        let db_path = data_dir.join(CIRCLES_DB_FILENAME);
        let storage = Arc::new(CircleStorage::new(&db_path, None)?);
        let mut session =
            SessionManager::new_unencrypted_with_notes(data_dir, keys, Some(storage.clone()))
                .map_err(CircleError::from_session)?;
        let held_at_open = storage.held_invitation_count().unwrap_or(usize::MAX);
        session.install_refused_ledger(storage.clone());
        session.install_stall_evidence(storage.clone());
        session.install_mesh_keys(storage.clone());
        Self::backfill_contamination_ledger(&storage);
        Self::prune_retired_profile_pool(&storage);
        Self::sweep_expired_directory_members(&storage);

        Ok(Self {
            session: Arc::new(session),
            pending_welcomes: PendingWelcomeStore::new(),
            data_dir: data_dir.to_path_buf(),
            rotation_fanouts: Mutex::new(HashMap::new()),
            owed_proposals: Mutex::new(Vec::new()),
            routing_moved: tokio::sync::Notify::new(),
            #[cfg(any(test, feature = "test-utils"))]
            skip_next_follow: std::sync::atomic::AtomicBool::new(false),
            profile_sync_lock: tokio::sync::Mutex::new(()),
            directory_lock: tokio::sync::Mutex::new(()),
            directory_flight: Mutex::new(DirectoryFlight::default()),
            held_at_open,
            held_polled_back: std::sync::atomic::AtomicBool::new(held_at_open == 0),
            convergence_reticks: std::sync::atomic::AtomicUsize::new(0),
            storage,
        })
    }

    /// Whether no storage-reset notice is waiting for the user
    /// ([`crate::storage_reset::storage_reset_acknowledged`]). While one is, no
    /// relay list is published.
    #[must_use]
    pub fn storage_reset_acknowledged(&self) -> bool {
        crate::storage_reset::storage_reset_acknowledged(&self.data_dir)
    }

    /// Retries hydrating a quarantined circle (MDK
    /// `retry_hydrate_quarantined_group`: non-destructive, never re-joins).
    /// `true` when the circle is live again.
    ///
    /// # Errors
    ///
    /// Returns an error if the circle is not quarantined or the retry failed.
    pub async fn retry_quarantined_circle(&self, mls_group_id: &GroupId) -> Result<bool> {
        self.session
            .retry_quarantined_group(mls_group_id)
            .await
            .map_err(CircleError::from)
    }

    /// A shared handle to the underlying session (for a group-scoped context).
    #[must_use]
    pub const fn session(&self) -> &Arc<SessionManager> {
        &self.session
    }

    /// Returns the current MLS epoch for a group.
    ///
    /// The epoch is a monotonic commit counter: it advances by exactly one for
    /// every applied commit (membership change or key update). It carries no
    /// key material and no group identifier, so it is safe to surface in the
    /// UI — the circle-details sheet shows it so members can compare epochs
    /// when messages stop decrypting.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::NotFound`] if the group does not exist, or
    /// [`CircleError::Mls`] if the query fails.
    pub async fn group_epoch(&self, mls_group_id: &GroupId) -> Result<u64> {
        let group = self
            .session
            .find_group(mls_group_id)
            .await
            .map_err(CircleError::from_session)?
            .ok_or_else(|| CircleError::NotFound("Group not found: <redacted>".to_string()))?;
        Ok(group.epoch.0)
    }

    /// The NIP-40 window Haven asks relays to keep the location messages **this
    /// device** sends into `mls_group_id`.
    ///
    /// This is the EFFECTIVE value — [`bounded_retention_secs`] applied to the
    /// group's declared `0x8005` component — and not the declaration itself,
    /// because it is the number that actually reaches the wire on this device's
    /// own 445s, and the two differ in both directions: an undeclared or
    /// over-long group policy collapses to Haven's own window, and a shorter one
    /// is honoured as declared. It is never zero and never absent.
    ///
    /// The circle-details sheet surfaces it so a foreign creator's very short
    /// window — which has relays dropping this device's location almost
    /// immediately — is visible rather than indistinguishable from a bug.
    ///
    /// The group lookup is not redundant with the component read: a circle with
    /// no live MLS group would otherwise report an undeclared policy, i.e.
    /// Haven's own window, for a circle that cannot send at all.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::NotFound`] if the group does not exist, or
    /// [`CircleError::Mls`] if the component cannot be read.
    pub async fn outgoing_location_expiry_secs(&self, mls_group_id: &GroupId) -> Result<u64> {
        if self
            .session
            .find_group(mls_group_id)
            .await
            .map_err(CircleError::from_session)?
            .is_none()
        {
            return Err(CircleError::NotFound(
                "Group not found: <redacted>".to_string(),
            ));
        }
        let declared = self
            .session
            .group_message_retention_secs(mls_group_id)
            .await
            .map_err(CircleError::from_session)?;
        Ok(bounded_retention_secs(declared))
    }

    /// Returns whether `pubkey_hex` is still present in the group's current
    /// roster — the REV-1 leaver-backstop liveness predicate.
    ///
    /// Fails SAFE to `false` when the group is gone or the caller has been
    /// evicted, so a removed leaver stops re-issuing.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::Mls`] if the roster cannot be read.
    pub async fn still_a_member(&self, mls_group_id: &GroupId, pubkey_hex: &str) -> Result<bool> {
        if self
            .session
            .find_group(mls_group_id)
            .await
            .map_err(CircleError::from_session)?
            .is_none()
        {
            return Ok(false);
        }

        Ok(self
            .session
            .member_pubkeys(mls_group_id)
            .await
            .map_err(CircleError::from_session)?
            .iter()
            .any(|pk| pk == pubkey_hex))
    }

    // ==================== Circle Lifecycle ====================

    /// Creates a new circle with gift-wrapped welcome events.
    ///
    /// Creates the underlying MLS group and stores circle metadata. The engine
    /// produces the per-member gift-wrapped Welcomes (kind 1059) itself (the
    /// peeler owns the NIP-59 crypto now); Haven only routes each Welcome to
    /// its recipient's inbox relays ([`welcome_route`]), so an invitee with no
    /// inbox relay Haven may dial is uninvitable (the intended two-plane
    /// tradeoff).
    ///
    /// A founding create has no group-message obligation (Rule 13): the engine
    /// returns the group already canonical (`PublishWork::FoundingGroupCreated`,
    /// MDK `cgka-session/src/lib.rs:268-270`), so nothing is confirmed or
    /// rolled back. Each Welcome is a delivery obligation of its own, with a
    /// record written before this returns
    /// (`SessionManager::record_founding_welcomes`) and sent from it by the
    /// fanout driver; a Welcome no relay accepted leaves the circle in place
    /// with that invitee not yet joined.
    ///
    /// Test builds only: the app creates through
    /// `relay::fanout::Publishing::create_circle`, which sends each founding
    /// Welcome from its record, so no shipped path holds a founding Welcome
    /// it could publish by any other way.
    ///
    /// # Errors
    ///
    /// Returns an error if circle creation or welcome routing fails.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn create_circle(
        &self,
        sender_keys: &Keys,
        members: Vec<MemberKeyPackage>,
        config: &CircleConfig,
    ) -> Result<CircleCreationResult> {
        let now_ms = u64::try_from(chrono::Utc::now().timestamp_millis()).unwrap_or(0);
        self.create_circle_at(sender_keys, members, config, now_ms)
            .await
    }

    /// [`Self::create_circle`] with its Welcomes' records written on a
    /// caller's clock, `now_ms`.
    pub(crate) async fn create_circle_at(
        &self,
        sender_keys: &Keys,
        members: Vec<MemberKeyPackage>,
        config: &CircleConfig,
        now_ms: u64,
    ) -> Result<CircleCreationResult> {
        // Fail closed BEFORE creating the MLS group: a member is deliverable iff
        // it advertises an inbox relay that may be dialled. Pre-validate so the
        // fail-closed path leaves storage untouched.
        for member in &members {
            welcome_route(member)?;
        }

        // Picked before the group exists, so a refusal leaves nothing behind.
        let effective_relays: Vec<String> = if config.relays.is_empty() {
            crate::circle::location_pool::pick_location_relays(
                &self.storage.identity_relay_authorities()?,
                &invitee_relay_authorities(&members),
            )?
        } else {
            config.relays.clone()
        };

        let mut mls_config = LocationGroupConfig::new(&config.name)
            .with_relays(effective_relays.iter().map(String::as_str))
            .with_admin(sender_keys.public_key().to_hex());
        if let Some(ref description) = config.description {
            mls_config = mls_config.with_description(description);
        }

        let key_package_events: Vec<Event> = members
            .iter()
            .map(|m| m.key_package_event.clone())
            .collect();

        let mut cfg = config.clone();
        cfg.relays = effective_relays;

        self.create_circle_with_config(&members, key_package_events, mls_config, &cfg, now_ms)
            .await
    }

    /// Internal helper for circle creation with a configured MLS config.
    async fn create_circle_with_config(
        &self,
        members: &[MemberKeyPackage],
        key_package_events: Vec<Event>,
        mls_config: LocationGroupConfig,
        config: &CircleConfig,
        now_ms: u64,
    ) -> Result<CircleCreationResult> {
        let key_packages = parse_key_packages(&key_package_events)?;

        let effects = self
            .session
            .create_group(key_packages, mls_config)
            .await
            .map_err(CircleError::from_session)?;
        let group_id = effects.group_id.clone();

        // The transport routing id comes from the engine's freshly-minted
        // `marmot.transport.nostr.routing.v1` component (Rule 4: never the real
        // MLS group id).
        let (nostr_group_id, _) = self
            .session
            .group_routing(&group_id)
            .await
            .map_err(CircleError::from_session)?;

        // Extract BEFORE persisting any storage row, so an extraction failure
        // leaves storage untouched.
        let welcomes = match self.take_group_created(effects.effects).await {
            Ok(welcomes) => welcomes,
            Err(e) => {
                self.abandon_founded_group(&group_id).await;
                return Err(e);
            }
        };

        // A founded group cannot be rolled back, so every failure from here on
        // — a row that will not save, a Welcome that cannot be routed — abandons
        // it locally, MLS state and circle rows, rather than leaving a ghost
        // circle. Nothing has left the device yet.
        let founded =
            self.record_founded_circle(&group_id, nostr_group_id, config, members, welcomes);
        let (circle, welcome_events, founding) = match founded {
            Ok(founded) => founded,
            Err(e) => {
                self.abandon_founded_group(&group_id).await;
                return Err(e);
            }
        };
        let founding_welcomes = match self
            .session
            .record_founding_welcomes(&group_id, founding, now_ms)
            .await
        {
            Ok(ids) => ids,
            Err(e) => {
                self.abandon_founded_group(&group_id).await;
                return Err(CircleError::from_session(e));
            }
        };
        // A founded group is canonical on return (MDK v0.10.4
        // `PublishWork::FoundingGroupCreated`), so its invitees are co-members
        // now; at v0.9.4 the create's confirm wrote them.
        self.reconcile_member_directory_best_effort(DirectoryReconcile::Rewrite)
            .await;

        Ok(CircleCreationResult {
            circle,
            welcome_events,
            founding_welcomes,
        })
    }

    /// Saves a freshly founded circle's rows and routes its Welcomes: the part
    /// of a create that can fail after the group exists.
    fn record_founded_circle(
        &self,
        group_id: &GroupId,
        nostr_group_id: [u8; 32],
        config: &CircleConfig,
        members: &[MemberKeyPackage],
        welcomes: Vec<TransportMessage>,
    ) -> Result<(Circle, Vec<GiftWrappedWelcome>, Vec<FoundingWelcome>)> {
        let now = chrono::Utc::now().timestamp();
        // The STORED circle, not the struct assembled here: `save_circle`
        // sanitizes the display name, and this value is handed straight back to
        // the caller for rendering.
        let circle = self.storage.save_circle(&Circle {
            mls_group_id: group_id.clone(),
            nostr_group_id,
            display_name: config.name.clone(),
            circle_type: config.circle_type,
            relays: config.relays.clone(),
            created_at: now,
            updated_at: now,
        })?;
        // Contamination ledger: this set is about to carry the circle's kind-445
        // traffic and its commits, so it is permanently excluded from the
        // profile pool. Recorded BEFORE the welcomes go out — over-recording is
        // the safe direction; the ledger is append-only precisely because
        // under-recording fails OPEN.
        self.record_contaminated(&circle.relays, ContaminationSource::CircleRouting)?;
        self.storage.save_membership(&CircleMembership {
            mls_group_id: group_id.clone(),
            status: MembershipStatus::Accepted,
            inviter_pubkey: None,
            invited_at: now,
            responded_at: Some(now),
        })?;
        let (welcome_events, founding) = self.route_welcomes_with_cascade(members, welcomes)?;
        Ok((circle, welcome_events, founding))
    }

    /// Forgets a group this device founded moments ago and nobody else knows
    /// about: its MLS state through MDK's `forget_group_local`, and its circle
    /// rows. Best-effort — each half logs its own failure code.
    async fn abandon_founded_group(&self, group_id: &GroupId) {
        if let Err(e) = self.session.forget_group_local(group_id).await {
            log::warn!(
                "abandoning a founded group: MLS forget failed: {}",
                e.code()
            );
        }
        if let Err(e) = self.storage.delete_circle(group_id) {
            log::warn!(
                "abandoning a founded group: circle-row cleanup failed (self-heals on logout wipe): {}",
                e.code()
            );
        }
    }

    /// Appends `relays` to the append-only contamination ledger.
    ///
    /// Called at every point a relay is handed location-plane traffic, so the
    /// profile pool can subtract it forever after (see
    /// [`super::contamination`]). The error is PROPAGATED rather than logged: a
    /// silently-dropped ledger write leaves a relay looking clean while it
    /// carries the user's encrypted traffic, which is exactly the fail-open the
    /// plane separation exists to prevent. The ledger shares circles.db with the
    /// row being written alongside it, so a failure here means that write was
    /// not durable either.
    fn record_contaminated(&self, relays: &[String], source: ContaminationSource) -> Result<()> {
        self.storage
            .record_contaminated_relays(relays, source, chrono::Utc::now().timestamp())
    }

    /// Routes engine-produced gift-wrapped Welcomes to their recipients' relays.
    ///
    /// The Dark Matter peeler owns the NIP-59 1059 crypto, so Haven no longer
    /// wraps welcomes — it fans the engine's wrapped 1059s out to the
    /// fail-closed delivery cascade. Each welcome is matched to its `members`
    /// entry by the recipient pubkey carried in the 1059's `p` tag.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::Mls`] on a count/recipient mismatch, or
    /// [`CircleError::MissingWelcomeRelays`] if a member has no advertised relay
    /// and there is no sender fallback.
    ///
    /// # Contamination
    ///
    /// Each resolved `recipient_relays` set is appended to the contamination
    /// ledger under [`ContaminationSource::Welcome`] before the welcomes are
    /// handed back for dispatch. This is the one location-plane relay set Haven
    /// persists NOWHERE else: the cascade resolves an invitee's relays from the
    /// key-package event at send time, and the result is not written to
    /// `circles` or `user_relays`. Without this write site those relays would be
    /// invisible to the profile-pool exclusion — and unlike circle and user
    /// relays they cannot be recovered later by
    /// [`CircleStorage::refresh_contamination_ledger`], because there is nothing
    /// on device to fold in.
    ///
    /// Recording happens on the success path only, and covers exactly the
    /// welcomes returned to the caller for publication. An error aborts before
    /// any welcome is dispatched, so nothing is recorded for a fan-out that
    /// never happened.
    fn route_welcomes_with_cascade(
        &self,
        members: &[MemberKeyPackage],
        welcomes: Vec<TransportMessage>,
    ) -> Result<(Vec<GiftWrappedWelcome>, Vec<FoundingWelcome>)> {
        if welcomes.len() != members.len() {
            return Err(CircleError::Mls(format!(
                "Expected {} welcome(s), got {}",
                members.len(),
                welcomes.len()
            )));
        }

        let mut welcome_events = Vec::with_capacity(welcomes.len());
        let mut founding = Vec::with_capacity(welcomes.len());
        for wt in welcomes {
            let event = SessionManager::transport_message_to_event(&wt)
                .map_err(CircleError::from_session)?;

            let recipient_pubkey = welcome_recipient(&event).ok_or_else(|| {
                CircleError::Mls("Welcome gift wrap missing recipient 'p' tag".to_string())
            })?;

            let member = members
                .iter()
                .find(|m| m.key_package_event.pubkey == recipient_pubkey)
                .ok_or_else(|| {
                    CircleError::Mls("No member matches welcome recipient".to_string())
                })?;
            let recipient_relays = welcome_route(member)?;
            founding.push(FoundingWelcome {
                message: wt,
                recipient: recipient_pubkey.to_hex(),
                relays: recipient_relays.clone(),
                not_after: key_package_not_after(member),
            });

            welcome_events.push(GiftWrappedWelcome {
                recipient_pubkey: recipient_pubkey.to_hex(),
                recipient_relays,
                event,
            });
        }

        // The gap this write site closes: a Welcome delivery relay is recorded
        // NOWHERE else on device, so this is its only chance to enter the
        // ledger. Flattened to a bare URL set — which relay served WHICH
        // invitee is co-membership metadata the ledger deliberately does not
        // hold (the table has no circle/group column).
        let welcome_relays: Vec<String> = welcome_events
            .iter()
            .flat_map(|w| w.recipient_relays.iter().cloned())
            .collect();
        self.record_contaminated(&welcome_relays, ContaminationSource::Welcome)?;

        Ok((welcome_events, founding))
    }

    /// Retrieves a circle with its members.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub async fn get_circle(&self, mls_group_id: &GroupId) -> Result<Option<CircleWithMembers>> {
        let Some(circle) = self.storage.get_circle(mls_group_id)? else {
            return Ok(None);
        };

        let membership = self.storage.get_membership(mls_group_id)?.ok_or_else(|| {
            CircleError::NotFound("Membership not found for circle: <redacted>".to_string())
        })?;

        let engine_state = self.engine_state(mls_group_id).await;
        let members = if engine_state == CircleEngineState::Live {
            self.get_members(mls_group_id).await?
        } else {
            Vec::new()
        };

        Ok(Some(CircleWithMembers {
            circle,
            membership,
            members,
            engine_state,
        }))
    }

    /// Where MDK holds `mls_group_id`, as every circle read reports it. A
    /// record the engine cannot read is not a verdict: it reads live.
    pub(crate) async fn engine_state(&self, mls_group_id: &GroupId) -> CircleEngineState {
        if self
            .session
            .quarantined_group_ids()
            .await
            .contains(mls_group_id)
        {
            CircleEngineState::Quarantined
        } else if self.session.disbanded(mls_group_id).await {
            CircleEngineState::Disbanded
        } else if self.session.unrecoverable(mls_group_id).await == Some(true) {
            CircleEngineState::Unrecoverable
        } else {
            CircleEngineState::Live
        }
    }

    /// Retrieves all circles.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub async fn get_circles(&self) -> Result<Vec<CircleWithMembers>> {
        let circles = self.storage.get_all_circles()?;
        let quarantined = self.session.quarantined_group_ids().await;
        let mut result = Vec::with_capacity(circles.len());

        for circle in circles {
            if let Some(membership) = self.storage.get_membership(&circle.mls_group_id)? {
                let engine_state = if quarantined.contains(&circle.mls_group_id) {
                    CircleEngineState::Quarantined
                } else if self.session.disbanded(&circle.mls_group_id).await {
                    CircleEngineState::Disbanded
                } else if self.session.unrecoverable(&circle.mls_group_id).await == Some(true) {
                    // A record the engine cannot read is not a verdict: one
                    // circle never fails the list (AM-R3-5).
                    CircleEngineState::Unrecoverable
                } else {
                    CircleEngineState::Live
                };
                let members = if engine_state == CircleEngineState::Live {
                    self.get_members(&circle.mls_group_id)
                        .await
                        .unwrap_or_default()
                } else {
                    Vec::new()
                };
                result.push(CircleWithMembers {
                    circle,
                    membership,
                    members,
                    engine_state,
                });
            }
        }

        Ok(result)
    }

    /// The visible circles a receive plane follows and a sweep reads: those
    /// that read live ([`CircleEngineState::Live`], MDK's own reads). Not a
    /// disbanded circle, whose traffic nobody sends any more; not one MDK
    /// holds unrecoverable, which applies nothing it receives until a
    /// Welcome — which arrives on the inbox — repairs it; and not one MDK
    /// holds quarantined, which failed to load in this process. (Haven opens
    /// its session with every group hydrated at the open, so none is left
    /// unhydrated.) Nothing of a circle left out is advanced or ended by its
    /// absence: a plane that reads it again takes it up from where it stood.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub(crate) async fn routable_circles(&self) -> Result<Vec<CircleWithMembers>> {
        Ok(self
            .get_visible_circles()
            .await?
            .into_iter()
            .filter(|circle| circle.engine_state == CircleEngineState::Live)
            .collect())
    }

    /// Who disbanded the circle of `mls_group_id`, as lowercase hex, for the
    /// notice the user is shown (`app-components/group-lifecycle-v1.md` 97);
    /// `None` for a circle not disbanded. Never logged.
    pub async fn disbanded_by(&self, mls_group_id: &GroupId) -> Option<String> {
        self.session.disbanded_by(mls_group_id).await
    }

    /// Clears what Haven keeps for a disbanded circle that nothing can use
    /// any more: its Welcome routes, the notes that a Welcome or a re-invite
    /// is owed, and its location records. MDK's settle deleted its own
    /// (records, queued changes, offers, `cgka-engine/src/disband.rs`
    /// 557-604). Idempotent: run at every open and at each disband seen.
    async fn reconcile_disbanded(&self, mls_group_id: &GroupId) {
        let _ = self.storage.forget_welcome_routes(mls_group_id);
        self.session.clear_owed_notes(mls_group_id);
        self.session.end_location_records(mls_group_id).await;
    }

    /// Retrieves visible circles (excludes declined invitations).
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub async fn get_visible_circles(&self) -> Result<Vec<CircleWithMembers>> {
        let circles = self.get_circles().await?;
        Ok(circles
            .into_iter()
            .filter(|c| c.membership.status.is_visible())
            .collect())
    }

    /// Classifies what the caller must do to leave the circle.
    ///
    /// See [`LeavePlan`]. Admin exits are gated by the engine's `SelfRemove` rules
    /// (`AdminCannotSelfRemove`/`AdminDepletion`): an admin exits the admin set
    /// first.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::Mls`] if the engine query fails for a reason other
    /// than "group not found" (which maps to `OrphanLocalOnly`).
    pub async fn plan_leave(
        &self,
        mls_group_id: &GroupId,
        self_pubkey: &PublicKey,
    ) -> Result<LeavePlan> {
        plan_leave(&self.session, mls_group_id, self_pubkey).await
    }

    /// The group's current admin set plus `successor`.
    async fn admins_with(
        &self,
        mls_group_id: &GroupId,
        successor: &PublicKey,
    ) -> Result<Vec<[u8; 32]>> {
        let mut admins = self
            .session
            .admin_pubkeys(mls_group_id)
            .await
            .map_err(CircleError::from_session)?;
        admins.push(successor.to_bytes());
        Ok(admins)
    }

    /// [`Self::propose_admin_handoff`] in staging mode: the commit is staged
    /// under its durable fanout and nothing is handed back to publish.
    ///
    /// # Errors
    ///
    /// As [`Self::propose_admin_handoff`].
    pub(crate) async fn propose_admin_handoff_staging(
        &self,
        mls_group_id: &GroupId,
        successor: &PublicKey,
        now_ms: u64,
        still: Still<'_>,
    ) -> Result<StagedChange> {
        let admins = self.admins_with(mls_group_id, successor).await?;
        self.admin_change(mls_group_id, &admins, now_ms, still)
            .await
    }

    /// A change of `mls_group_id`'s admins to `admins`, staged under its
    /// durable fanout — or answered as already made, with nothing staged,
    /// when the circle has those admins.
    async fn admin_change(
        &self,
        mls_group_id: &GroupId,
        admins: &[[u8; 32]],
        now_ms: u64,
        still: Still<'_>,
    ) -> Result<StagedChange> {
        match self
            .session
            .change_admin_policy_staging(mls_group_id, admins, now_ms, still)
            .await
            .map_err(CircleError::from_session)?
        {
            Some(staged) => self.staged_change(mls_group_id, staged).await,
            None => Ok(StagedChange {
                commit: None,
                also: Vec::new(),
                welcomes: Vec::new(),
                unrecorded: false,
                already: true,
            }),
        }
    }

    /// What a staging-mode send left, as the change its caller asked for:
    /// `mls_group_id`'s own commit record, or the engine's word that the
    /// change is queued behind what the circle is still resolving.
    ///
    /// The locations the send drained are persisted ([`Self::note_send_drain`]).
    /// Its publish work is NOT surfaced: a commit still in it is one the hold
    /// could neither record nor roll back, which is staged, unsent, and undone
    /// at the next hold that stages (`SessionManager::retry_unrecorded`);
    /// handed to anything that sends it, it would go out with no record and
    /// then be rolled back by that next hold after a relay may have taken it
    /// (Security Rule 13).
    async fn staged_change(&self, mls_group_id: &GroupId, staged: Staged) -> Result<StagedChange> {
        let Staged {
            effects,
            fanouts,
            welcomes,
            proposals,
            unrecorded,
            waiting: _,
        } = staged;
        self.note_send_drain(&effects.events).await;
        let queued = effects
            .queued
            .iter()
            .any(|intent| &intent.group_id == mls_group_id);
        // The change is staged and could be neither recorded nor undone: it
        // is not an error to report as "nothing was staged".
        let unrecorded = unrecorded.contains(mls_group_id);
        // A queued change's circle can still have a record in this batch: the
        // eviction the engine staged ahead of it.
        let (own, also): (Vec<FanoutId>, Vec<FanoutId>) = fanouts
            .into_iter()
            .partition(|id| !queued && id.group() == mls_group_id);
        let mut own = own.into_iter();
        let commit = own.next();
        if commit.is_none() && !queued && !unrecorded {
            return Err(CircleError::Mls(
                "operation produced no commit and queued nothing".to_string(),
            ));
        }
        let welcomes = welcomes
            .into_iter()
            .find(|(id, _)| commit.as_ref() == Some(id))
            .map(|(_, welcomes)| welcomes)
            .unwrap_or_default();
        Ok(StagedChange {
            unrecorded: unrecorded && commit.is_none() && !queued,
            commit,
            also: also.into_iter().chain(own).chain(proposals).collect(),
            welcomes,
            already: false,
        })
    }

    /// The relay set an admin asked for, canonical, checked and recorded as
    /// carrying this device's group traffic.
    fn new_circle_relays(&self, new_relays: &[String]) -> Result<Vec<String>> {
        let canonical = circle_relays(new_relays)?;
        // Recorded for the NEW set before the change is applied, and whether
        // or not it ever is: the ledger errs towards a relay that was only
        // named, never towards one that carried traffic unrecorded. Never for
        // a set the engine would refuse.
        self.record_contaminated(&canonical, ContaminationSource::CircleRouting)?;
        Ok(canonical)
    }

    /// [`Self::update_circle_relays`] in staging mode. The commit's fanout is
    /// frozen for the relays of the epoch it leaves, and the circle row follows
    /// the engine's routing component once the commit is applied (the fold).
    ///
    /// # Errors
    ///
    /// As [`Self::update_circle_relays`].
    pub async fn update_circle_relays_staging(
        &self,
        mls_group_id: &GroupId,
        new_relays: &[String],
        now_ms: u64,
    ) -> Result<StagedChange> {
        let canonical = self.new_circle_relays(new_relays)?;
        // The engine commits whatever it is handed: the list the circle
        // already has would cost an epoch and change nothing. Not while a
        // commit of this device's is pending: the applied list it would be
        // compared with is not where the circle is going.
        let (_, current) = self
            .session
            .group_routing(mls_group_id)
            .await
            .map_err(CircleError::from_session)?;
        let normalized: Vec<Option<String>> = current
            .iter()
            .map(|relay| super::storage_relay_prefs::normalize_url(relay).ok())
            .collect();
        // An entry this device may not dial is not in the list it shows, and
        // re-saving that list is how it is taken out of the component.
        let refused_entry = normalized.iter().any(Option::is_none);
        let mut current: Vec<String> = normalized.into_iter().flatten().collect();
        current.sort();
        current.dedup();
        if !refused_entry
            && current == canonical
            && self.session.holds_no_own_commit(mls_group_id).await
        {
            return Ok(StagedChange {
                commit: None,
                also: Vec::new(),
                welcomes: Vec::new(),
                unrecorded: false,
                already: true,
            });
        }
        let staged = self
            .session
            .update_relays_staging(mls_group_id, canonical, now_ms)
            .await
            .map_err(CircleError::from_session)?;
        self.staged_change(mls_group_id, staged).await
    }

    /// Re-derives the app-level circle row — its routing id and its
    /// `circle.relays` — from the engine's routing component after a commit.
    /// Idempotent; an EMPTY component never overwrites a non-empty
    /// `circle.relays` (never bricks 445 routing).
    ///
    /// The row holds the component's entries this device may dial
    /// ([`usable_relays`]). A component that names relays and none of them
    /// usable leaves the row empty: the circle then has no relay, and saying
    /// so is the truth — keeping the previous list would send its traffic to
    /// relays the circle no longer names.
    ///
    /// A routing id another client's admin rotated
    /// (`app-components/nostr-routing-v1.md` 44-63) is followed: the row
    /// and every store keyed by the id move to the new one, with the
    /// routing it leaves kept as a prior routing, in one transaction
    /// ([`CircleStorage::follow_routing`]). Except onto an id another circle
    /// on this device holds, now or as a prior routing: MDK has then given
    /// that id's route to this group, so the other circle no longer hears
    /// its traffic, and both circles' sends are held
    /// ([`ChangeNote::RoutingCollision`](crate::nostr::mls::ChangeNote::RoutingCollision)).
    ///
    /// Run after every commit a plane applies and, so that a follow a kill
    /// or an error missed is made later, for every circle at each start,
    /// sweep and burst open ([`Self::reconcile_routing`]).
    ///
    /// Returns whether the row's routing changed.
    ///
    /// # Errors
    ///
    /// Returns an error if the engine or storage access fails.
    async fn resync_circle_relays_from_mdk(&self, mls_group_id: &GroupId) -> Result<bool> {
        let (routing_id, named) = self
            .session
            .group_routing(mls_group_id)
            .await
            .map_err(CircleError::from_session)?;

        let Some(circle) = self.storage.get_circle(mls_group_id)? else {
            return Ok(false);
        };

        let mut current = circle.relays.clone();
        current.sort();
        current.dedup();
        let from_engine = !named.is_empty();
        let engine_relays = if from_engine {
            let mut engine_relays = usable_relays(named);
            engine_relays.sort();
            engine_relays.dedup();
            engine_relays
        } else {
            current.clone()
        };
        let rotated = routing_id != circle.nostr_group_id;
        if current == engine_relays && !rotated {
            return Ok(false);
        }
        // The receiving end of an admin's relay update: a non-admin member
        // learns the new routing set from the engine's component rather than
        // from `update_circle_relays`, so this is that member's write site.
        // Before the collision check: the engine sends the circle's traffic
        // to these relays whether or not the row follows.
        let recorded = if from_engine {
            self.record_contaminated(&engine_relays, ContaminationSource::CircleRouting)
        } else {
            Ok(())
        };
        if rotated {
            match self
                .other_circle_with_routing_id(&routing_id, mls_group_id, UnreadEpoch::Holds)
                .await
            {
                // MDK has moved the id's route to this group, in memory and
                // on disk, so the other circle's traffic no longer reaches
                // it: both are held, and the row stays where it was.
                Ok(Some(other)) => {
                    self.session
                        .note_routing_collision(&[mls_group_id, &other])
                        .map_err(CircleError::from_session)?;
                    log::warn!(
                        "a circle's routing id moved onto one another circle holds; both \
                         circles' sends are held"
                    );
                    return recorded.map(|()| false);
                }
                Ok(None) => {}
                // MDK has moved the route already, and a store that cannot
                // say whose the id was cannot name the circle it may have
                // deafened: this one is held now, and that one from the next
                // reconcile that reads the store (`hold_shared`).
                Err(e) => {
                    self.hold_unchecked(mls_group_id)?;
                    log::warn!(
                        "a circle's routing id moved and whether another circle holds it could \
                         not be read; its sends are held"
                    );
                    return Err(e);
                }
            }
        }
        recorded?;
        // The routing it leaves served every epoch before this one: kept, in
        // the move's own transaction, while those can still be fetched, so
        // their traffic is fetched again where it was sent.
        let epoch = self
            .session
            .epoch(mls_group_id)
            .await
            .map_err(CircleError::from_session)?;
        let oldest_kept = epoch.saturating_sub(routing_retained_epochs());
        let prior = PriorRouting {
            nostr_group_id: circle.nostr_group_id,
            relays: &current,
            until_epoch: epoch,
            oldest_kept,
            written_at: chrono::Utc::now().timestamp(),
        };
        // The new id is asked from the oldest instant the engine keeps of the
        // circle's recent epochs — the rotating commit's among them, however
        // late it was applied — or, when nothing it keeps says, from the
        // stream's cold start.
        let cursor_floor_ms = if rotated {
            self.session
                .oldest_kept_transport_secs(mls_group_id, oldest_kept)
                .await
                .map(|secs| i64::try_from(secs).unwrap_or(i64::MAX).saturating_mul(1000))
        } else {
            None
        };
        let mut moved = circle.clone();
        moved.relays = engine_relays;
        moved.nostr_group_id = routing_id;
        moved.updated_at = chrono::Utc::now().timestamp();
        self.storage
            .follow_routing(&moved, &prior, cursor_floor_ms)?;
        self.routing_moved.notify_one();
        Ok(true)
    }

    /// A circle other than `mls_group_id` whose route MDK may give away to
    /// a group naming `routing_id`: one whose routing id it is, or one whose
    /// prior routing used it while an epoch that used it is still retained
    /// (`app-components/nostr-routing-v1.md` 56-62). A prior routing past
    /// that window is nobody's: MDK's in-memory index still keeps its route
    /// until the session ends (mdk#896), but nothing sent under it can be
    /// peeled any more, the epochs' exporter secrets being gone. A circle
    /// whose epoch cannot be read is taken as `unread` says.
    ///
    /// # Errors
    ///
    /// Returns the store's error: a store that cannot say is not read as an
    /// answer either way.
    async fn other_circle_with_routing_id(
        &self,
        routing_id: &[u8; 32],
        mls_group_id: &GroupId,
        unread: UnreadEpoch,
    ) -> Result<Option<GroupId>> {
        for (holder, until_epoch) in self.storage.routing_id_holders(routing_id, mls_group_id)? {
            let Some(until_epoch) = until_epoch else {
                return Ok(Some(holder));
            };
            let stands = match self.session.epoch(&holder).await {
                Ok(epoch) => until_epoch >= epoch.saturating_sub(routing_retained_epochs()),
                Err(e) if unread == UnreadEpoch::Errs => return Err(CircleError::from_session(e)),
                Err(_) => true,
            };
            if stands {
                return Ok(Some(holder));
            }
        }
        Ok(None)
    }

    /// Holds `mls_group_id` as a routing collision does
    /// ([`ChangeNote::RoutingCollision`](crate::nostr::mls::ChangeNote::RoutingCollision)),
    /// for a routing id MDK has given it
    /// that the store could not check: whether another circle held the id is
    /// not known, and the circle that would have lost its route cannot be
    /// named here — [`Self::hold_shared`] names it at the next reconcile
    /// that reads the store, and until then it is not held. Like a
    /// collision's, the hold ends when the circle is left — a transient store
    /// error costs this circle its sharing until then.
    fn hold_unchecked(&self, mls_group_id: &GroupId) -> Result<()> {
        self.session
            .note_routing_collision(&[mls_group_id])
            .map_err(CircleError::from_session)
    }

    /// Follows, for every circle this device holds, the routing its engine
    /// state names and its row does not: a follow a kill between a commit
    /// and its persist missed, or one an error stopped. First it holds every
    /// circle the store says shares its routing id ([`Self::hold_shared`]).
    /// Best-effort; one line says how many failed, in buckets, and names
    /// none.
    pub async fn reconcile_routing(&self) {
        let circles = match self.storage.get_all_circles() {
            Ok(circles) => circles,
            Err(e) => {
                log::debug!("routing reconcile: the circles were not read: {}", e.code());
                return;
            }
        };
        let mut failed = 0;
        for circle in &circles {
            if self.hold_shared(circle).await.is_err() {
                failed += 1;
            }
        }
        for circle in circles {
            if self
                .resync_circle_relays_from_mdk(&circle.mls_group_id)
                .await
                .is_err()
            {
                failed += 1;
            }
        }
        if failed > 0 {
            log::debug!(
                "routing reconcile: {} circle(s) not followed (retried at the next)",
                bucket(failed)
            );
        }
    }

    /// Holds `circle` and the other circle that names its routing id — as its
    /// own, or as a prior routing still inside its window
    /// ([`Self::other_circle_with_routing_id`]) — as a routing collision,
    /// unless both are held already. What a Welcome joined under a store
    /// error leaves is the joined circle held and the one MDK took the route
    /// from not: this holds that one from the next reconcile on, a repair
    /// after the fact rather than a prevention.
    ///
    /// # Errors
    ///
    /// The store's error, or the note's: nothing was held, and the next
    /// reconcile asks again.
    async fn hold_shared(&self, circle: &Circle) -> Result<()> {
        let Some(other) = self
            .other_circle_with_routing_id(
                &circle.nostr_group_id,
                &circle.mls_group_id,
                UnreadEpoch::Errs,
            )
            .await?
        else {
            return Ok(());
        };
        if self.session.routing_collided(&circle.mls_group_id)
            && self.session.routing_collided(&other)
        {
            return Ok(());
        }
        self.session
            .note_routing_collision(&[&circle.mls_group_id, &other])
            .map_err(CircleError::from_session)?;
        log::warn!("two circles were found to share a routing id; both circles' sends are held");
        Ok(())
    }

    /// The circle routed by `routing_id`: the one whose routing id it is, or
    /// one a prior routing of which used it — what an event still addressed
    /// to a rotated circle's prior `#h` is for.
    ///
    /// # Errors
    ///
    /// Returns the store's error.
    pub(crate) fn circle_routed_by(&self, routing_id: &[u8; 32]) -> Result<Option<Circle>> {
        let found = match self.storage.circles_named_by(routing_id)?.as_slice() {
            [] => self.storage.circle_with_prior_routing_id(routing_id)?,
            [one] => self.storage.get_circle(one)?,
            // Two rows name the id — a Welcome named one this device already
            // held: neither circle is told what the other's traffic or writes
            // said.
            _ => None,
        };
        // A circle held for a routing collision is routed by nothing: MDK may
        // give its id's traffic to the other circle, which would then be
        // published to this one's relays or mark it caught up.
        Ok(found.filter(|circle| !self.session.routing_collided(&circle.mls_group_id)))
    }

    /// Resolves once a circle's row has moved to new relays since the last
    /// time it resolved, whichever plane applied the change: one wake held
    /// for a waiter not yet waiting, never a queue of them.
    pub(crate) async fn routing_moved(&self) {
        self.routing_moved.notified().await;
    }

    /// Where `mls_group_id`'s traffic of an epoch that can still be fetched
    /// was sent: `current`, its relays now, and the relays of every prior
    /// routing an epoch inside the retained-history windows used
    /// (`app-components/nostr-routing-v1.md` 56-62), each held to the one
    /// relay policy. A store that cannot say gives `current` alone.
    pub async fn routing_addresses(
        &self,
        mls_group_id: &GroupId,
        current: &[String],
    ) -> Vec<String> {
        let mut addresses = current.to_vec();
        for (_, relays) in self.prior_routings(mls_group_id, None).await {
            addresses.extend(relays);
        }
        addresses.sort();
        addresses.dedup();
        addresses
    }

    /// Each routing id `mls_group_id` is listened for at now (`now`,
    /// seconds), with the relays it is listened at: `routing_id`, its id now,
    /// at `current` first; then each id a prior routing used, at the relays
    /// it was used with — a prior relay set of the same id joins
    /// `routing_id`'s — for a day from that routing's own write (a clock
    /// reading earlier than the write reads as the day over) and while an
    /// epoch inside the window still used it (decision 237). A routing left
    /// keeps no standing REQ for longer, though its traffic is still fetched
    /// there by id ([`Self::routing_addresses`]); and an id is asked for only
    /// where it was sent, so a relay that never carried a rotated circle's
    /// new id is not told it.
    pub async fn standing_routings(
        &self,
        mls_group_id: &GroupId,
        routing_id: [u8; 32],
        current: &[String],
        now: i64,
    ) -> Vec<([u8; 32], Vec<String>)> {
        self.routings(
            mls_group_id,
            routing_id,
            current,
            Some((now.saturating_sub(PRIOR_ROUTING_STANDS_SECS), now)),
        )
        .await
    }

    /// [`Self::standing_routings`] without the day: each routing id the
    /// circle's traffic of an epoch that can still be fetched was sent under,
    /// with the relays it was sent to — what a refetch of a range of its
    /// history asks, one id at its own relays at a time.
    pub async fn kept_routings(
        &self,
        mls_group_id: &GroupId,
        routing_id: [u8; 32],
        current: &[String],
    ) -> Vec<([u8; 32], Vec<String>)> {
        self.routings(mls_group_id, routing_id, current, None).await
    }

    async fn routings(
        &self,
        mls_group_id: &GroupId,
        routing_id: [u8; 32],
        current: &[String],
        written_since: Option<(i64, i64)>,
    ) -> Vec<([u8; 32], Vec<String>)> {
        let mut routings = vec![(routing_id, current.to_vec())];
        for (id, relays) in self.prior_routings(mls_group_id, written_since).await {
            match routings.iter_mut().find(|(seen, _)| *seen == id) {
                Some((_, kept)) => kept.extend(relays),
                None => routings.push((id, relays)),
            }
        }
        for (_, relays) in &mut routings {
            relays.sort();
            relays.dedup();
        }
        routings
    }

    /// The first second, after `now`, at which a prior routing that stands
    /// now no longer does: where the session's follow wakes by itself, so a
    /// day is a day and not "until the next follow". `None` when none
    /// stands, or the store cannot say.
    pub(crate) fn next_prior_routing_end(&self, now: i64) -> Option<i64> {
        self.storage
            .earliest_prior_routing_written(now.saturating_sub(PRIOR_ROUTING_STANDS_SECS), now)
            .ok()
            .flatten()
            .map(|written| written.saturating_add(PRIOR_ROUTING_STANDS_SECS + 1))
    }

    /// Wakes the session's follow as a routing move would, with no row
    /// moved: after the app changes what the session lists, and when a
    /// circle is left.
    pub(crate) fn wake_routing_follow(&self) {
        self.routing_moved.notify_one();
    }

    /// Keeps a circle row routed by `nostr_group_id` with no engine group
    /// behind it: what a test of a store keyed by routing id writes under.
    ///
    /// # Panics
    ///
    /// When the store refuses the row: a test's setup.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn keep_circle_row_for_test(&self, nostr_group_id: [u8; 32]) {
        self.storage
            .save_circle(&Circle {
                mls_group_id: GroupId::from_slice(&nostr_group_id),
                nostr_group_id,
                display_name: "Test".to_string(),
                circle_type: CircleType::LocationSharing,
                relays: Vec::new(),
                created_at: 1,
                updated_at: 1,
            })
            .expect("the row is kept");
    }

    /// Makes the next follow a persist would make not happen, as a process
    /// killed between the engine's commit and Haven's persist would leave it.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn skip_next_follow_for_test(&self) {
        self.skip_next_follow
            .store(true, std::sync::atomic::Ordering::SeqCst);
    }

    /// [`Self::wake_routing_follow`], for a test that dated a routing.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn wake_routing_follow_for_test(&self) {
        self.wake_routing_follow();
    }

    /// A location sealed as a background burst seals one — a plane that
    /// makes no commit — over a transport that takes no relay, its record
    /// ended as a completed send ends it: how a test hands one member's fix
    /// to another.
    ///
    /// # Errors
    ///
    /// The seal's own error; [`CircleError::EngineHeld`] when the location
    /// was deferred.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn seal_location_for_test(
        &self,
        mls_group_id: &GroupId,
        location: &LocationMessage,
    ) -> Result<(Event, [u8; 32], Vec<String>)> {
        use crate::relay::fanout::{scripted::Inert, LocationSeal, Publishing, WallClock};
        let publishing: Publishing<'_, Inert> = Publishing {
            fanout: &Inert,
            publisher: &Inert,
            clock: &WallClock,
            deadline_ms: None,
            mode: &DriveMode::FinishOnly,
        };
        match publishing
            .seal_location(self, mls_group_id, location)
            .await?
            .seal
        {
            LocationSeal::Sealed {
                event,
                nostr_group_id,
                relays,
            } => {
                let _ = self
                    .session
                    .end_location(&MessageId::new(event.id.as_bytes().to_vec()))
                    .await;
                Ok((*event, nostr_group_id, relays))
            }
            LocationSeal::Deferred(_) => Err(CircleError::EngineHeld),
        }
    }

    /// `event` taken in as the app's foreground poll takes one — the full
    /// mode, so what the engine stages is recorded — over a transport that
    /// takes no relay: every record stays pending. What the call folded.
    ///
    /// # Errors
    ///
    /// The ingest's error.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn ingest_staging_for_test(
        &self,
        event: &Event,
    ) -> Result<Vec<LocationMessageResult>> {
        use crate::relay::fanout::{scripted::Inert, Publishing, WallClock};
        let publishing: Publishing<'_, Inert> = Publishing {
            fanout: &Inert,
            publisher: &Inert,
            clock: &WallClock,
            deadline_ms: None,
            mode: &DriveMode::Full,
        };
        Ok(publishing.ingest_for_poll(self, event).await?.replayed)
    }

    /// [`Self::ingest_staging_for_test`] with every relay accepting, so what
    /// the ingest staged lands in the same call: what was folded, and each
    /// event its relays were sent — the commits and proposals it made.
    ///
    /// # Errors
    ///
    /// The ingest's error.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn ingest_landing_for_test(
        &self,
        event: &Event,
    ) -> Result<(Vec<LocationMessageResult>, Vec<Event>)> {
        use crate::relay::fanout::{scripted::Accepting, Publishing, WallClock};
        let accepting = Accepting::default();
        let publishing = Publishing {
            fanout: &accepting,
            publisher: &accepting,
            clock: &WallClock,
            deadline_ms: None,
            mode: &DriveMode::Full,
        };
        let replayed = publishing.ingest_for_poll(self, event).await?.replayed;
        Ok((replayed, accepting.sent()))
    }

    /// A change made through the fanout driver in the full mode, every relay
    /// accepting, and landed: the commit its relays were sent — what the
    /// circle's other members take in — and what was published beside it
    /// with no record (each invitee's Welcome). How a test makes a change.
    ///
    /// # Errors
    ///
    /// The change's own error; [`CircleError::EngineHeld`] when it did not
    /// land.
    #[cfg(any(test, feature = "test-utils"))]
    async fn land_for_test<F>(&self, change: F) -> Result<(Event, Vec<Event>)>
    where
        F: AsyncFnOnce(
            &crate::relay::fanout::Publishing<'_, crate::relay::fanout::scripted::Accepting>,
        ) -> Result<crate::relay::fanout::EvolutionOutcome>,
    {
        use crate::relay::fanout::{scripted::Accepting, EvolutionStatus, Publishing, WallClock};
        let accepting = Accepting::default();
        let publishing = Publishing {
            fanout: &accepting,
            publisher: &accepting,
            clock: &WallClock,
            deadline_ms: None,
            mode: &DriveMode::Full,
        };
        let outcome = change(&publishing).await?;
        match accepting.sent().pop() {
            Some(commit) if outcome.status == EvolutionStatus::Confirmed => {
                Ok((commit, accepting.handed()))
            }
            _ => Err(CircleError::EngineHeld),
        }
    }

    /// Every stored record driven in the full mode, every relay accepting:
    /// what lands a change a test staged. The events relays were sent.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn land_staged_for_test(&self) -> Vec<Event> {
        use crate::relay::fanout::{scripted::Accepting, Publishing, WallClock};
        let accepting = Accepting::default();
        let _ = Publishing {
            fanout: &accepting,
            publisher: &accepting,
            clock: &WallClock,
            deadline_ms: None,
            mode: &DriveMode::Full,
        }
        .resume(self)
        .await;
        accepting.sent()
    }

    /// Every stored record driven in the full mode, every relay refusing:
    /// what undoes a change a test staged.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn refuse_staged_for_test(&self) {
        use crate::relay::fanout::{scripted::Refusing, Publishing, WallClock};
        let _ = Publishing {
            fanout: &Refusing,
            publisher: &Refusing,
            clock: &WallClock,
            deadline_ms: None,
            mode: &DriveMode::Full,
        }
        .resume(self)
        .await;
    }

    /// What the user is told first about `mls_group_id`
    /// (`Publishing::circle_recovery`), read by a caller in the foreground or
    /// not, as the bridge reads it.
    ///
    /// # Errors
    ///
    /// As `Publishing::circle_recovery`.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn circle_recovery_for_test(
        &self,
        mls_group_id: &GroupId,
        foreground: bool,
    ) -> Result<Option<crate::relay::fanout::RecoveryCause>> {
        use crate::relay::fanout::{scripted::Inert, Publishing, WallClock};
        let mode = if foreground {
            DriveMode::Full
        } else {
            DriveMode::FinishOnly
        };
        let publishing: Publishing<'_, Inert> = Publishing {
            fanout: &Inert,
            publisher: &Inert,
            clock: &WallClock,
            deadline_ms: None,
            mode: &mode,
        };
        publishing.circle_recovery(self, mls_group_id).await
    }

    /// [`Self::repair_rotation_for_test`] with every relay refusing.
    ///
    /// # Errors
    ///
    /// The repair's own error.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn repair_rotation_refused_for_test(
        &self,
        mls_group_id: &GroupId,
        now_secs: u64,
    ) -> Result<crate::relay::fanout::RepairOutcome> {
        use crate::relay::fanout::{
            scripted::{FixedClock, Refusing},
            Publishing,
        };
        Publishing {
            fanout: &Refusing,
            publisher: &Refusing,
            clock: &FixedClock(now_secs.saturating_mul(1_000)),
            deadline_ms: None,
            mode: &DriveMode::Full,
        }
        .repair_rotation(self, mls_group_id)
        .await
    }

    /// The epoch-rotation repair through the fanout driver in the full
    /// mode at `now_secs`, every relay accepting: what it answered, and the
    /// commit its relays were sent when it rotated.
    ///
    /// # Errors
    ///
    /// The repair's own error.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn repair_rotation_for_test(
        &self,
        mls_group_id: &GroupId,
        now_secs: u64,
    ) -> Result<(crate::relay::fanout::RepairOutcome, Option<Event>)> {
        use crate::relay::fanout::{
            scripted::{Accepting, FixedClock},
            Publishing,
        };
        let accepting = Accepting::default();
        let publishing = Publishing {
            fanout: &accepting,
            publisher: &accepting,
            clock: &FixedClock(now_secs.saturating_mul(1_000)),
            deadline_ms: None,
            mode: &DriveMode::Full,
        };
        let outcome = publishing.repair_rotation(self, mls_group_id).await?;
        Ok((outcome, accepting.sent().pop()))
    }

    /// The product's full resume over a transport on which every relay
    /// accepts and nothing is stored: what it sent under a record, in order.
    /// How a test lands what a full drive makes — a joiner's post-join
    /// self-update among it — without leaving it on any relay.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn resume_accepted_for_test(&self) -> Vec<Event> {
        use crate::relay::fanout::{scripted::Accepting, Publishing, WallClock};
        let accepting = Accepting::default();
        let publishing = Publishing {
            fanout: &accepting,
            publisher: &accepting,
            clock: &WallClock,
            deadline_ms: None,
            mode: &DriveMode::Full,
        };
        let _ = publishing.resume(self).await;
        accepting.sent()
    }

    /// `members` invited ([`Self::land_for_test`]): the commit, and the
    /// Welcomes.
    ///
    /// # Errors
    ///
    /// As [`Self::land_for_test`].
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn add_members_for_test(
        &self,
        mls_group_id: &GroupId,
        members: &[MemberKeyPackage],
    ) -> Result<(Event, Vec<Event>)> {
        self.land_for_test(async |publishing| {
            publishing.add_members(self, mls_group_id, members).await
        })
        .await
    }

    /// `member_pubkeys` removed ([`Self::land_for_test`]): the commit.
    ///
    /// # Errors
    ///
    /// As [`Self::land_for_test`].
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn remove_members_for_test(
        &self,
        mls_group_id: &GroupId,
        member_pubkeys: &[String],
    ) -> Result<Event> {
        self.land_for_test(async |publishing| {
            publishing
                .remove_members(self, mls_group_id, member_pubkeys)
                .await
        })
        .await
        .map(|(commit, _)| commit)
    }

    /// The relay list replaced, under its record, and landed on every relay
    /// accepting: the commit. A commit is made even for the list the circle
    /// already has — what a test that moves an epoch needs; the driver's own
    /// entry answers that list `AlreadySo`.
    ///
    /// # Errors
    ///
    /// The staging's own error; [`CircleError::EngineHeld`] when no record
    /// was written or the commit did not land.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn update_relays_for_test(
        &self,
        mls_group_id: &GroupId,
        relays: &[String],
    ) -> Result<Event> {
        let canonical = self.new_circle_relays(relays)?;
        let canonical_relays = canonical.clone();
        let now_ms = u64::try_from(chrono::Utc::now().timestamp_millis()).unwrap_or(0);
        let staged = self
            .session
            .update_relays_staging(mls_group_id, canonical, now_ms)
            .await
            .map_err(CircleError::from_session)?;
        let [id] = staged.fanouts.as_slice() else {
            return Err(CircleError::EngineHeld);
        };
        let commit = self
            .session
            .fanout_probe_for_test(id)
            .await
            .map_err(CircleError::from_session)?
            .ok_or(CircleError::EngineHeld)?;
        let commit = <Event as nostr::JsonUtil>::from_json(&commit.payload)
            .map_err(|_| CircleError::EngineHeld)?;
        // A live plane beside the test may hold the record when this drive
        // reaches it (`FanoutStatus::Busy`), or answer it first: the record
        // is driven again once that plane lets go, and landed by whichever
        // drive's answer applied the change — never two drives at once
        // (Security Rule 13).
        for _ in 0..8 {
            if self
                .land_staged_for_test()
                .await
                .iter()
                .any(|sent| sent.id == commit.id)
            {
                return Ok(commit);
            }
            if self
                .session
                .fanout_probe_for_test(id)
                .await
                .map_err(CircleError::from_session)?
                .is_none()
            {
                let applied = self
                    .get_circle(mls_group_id)
                    .await?
                    .is_some_and(|circle| circle.circle.relays == canonical_relays);
                return if applied {
                    Ok(commit)
                } else {
                    Err(CircleError::EngineHeld)
                };
            }
            crate::relay::fanout::fanout_row_let_go_for_test(id).await;
        }
        Err(CircleError::EngineHeld)
    }

    /// `successor` made an admin ([`Self::land_for_test`]): the commit.
    ///
    /// # Errors
    ///
    /// As [`Self::land_for_test`].
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn admin_handoff_for_test(
        &self,
        mls_group_id: &GroupId,
        successor: &PublicKey,
    ) -> Result<Event> {
        self.land_for_test(async |publishing| {
            publishing
                .admin_handoff(self, mls_group_id, successor)
                .await
        })
        .await
        .map(|(commit, _)| commit)
    }

    /// The caller dropped from the admins ([`Self::land_for_test`]): the
    /// commit.
    ///
    /// # Errors
    ///
    /// As [`Self::land_for_test`].
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn self_demote_for_test(&self, mls_group_id: &GroupId) -> Result<Event> {
        self.land_for_test(async |publishing| publishing.self_demote(self, mls_group_id).await)
            .await
            .map(|(commit, _)| commit)
    }

    /// `event` taken in as the app's poll takes one in a plane that makes no
    /// commit, over a transport that takes no relay: what the call folded.
    ///
    /// # Errors
    ///
    /// The ingest's error.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn ingest_for_test(&self, event: &Event) -> Result<Vec<LocationMessageResult>> {
        use crate::relay::fanout::{scripted::Inert, Publishing, WallClock};
        let publishing: Publishing<'_, Inert> = Publishing {
            fanout: &Inert,
            publisher: &Inert,
            clock: &WallClock,
            deadline_ms: None,
            mode: &DriveMode::FinishOnly,
        };
        Ok(publishing.ingest_for_poll(self, event).await?.replayed)
    }

    /// Every routing id `mls_group_id` has used that a prior routing it keeps
    /// names, beside the one it has now, standing or not: what a listing of
    /// the circle can hold.
    pub(crate) fn routing_ids_of(&self, mls_group_id: &GroupId) -> Vec<[u8; 32]> {
        let mut ids: Vec<[u8; 32]> = self.nostr_group_id_for(mls_group_id).into_iter().collect();
        if let Ok(prior) = self.storage.prior_routings(mls_group_id, 0, None) {
            for (id, _) in prior {
                if !ids.contains(&id) {
                    ids.push(id);
                }
            }
        }
        ids
    }

    async fn prior_routings(
        &self,
        mls_group_id: &GroupId,
        written_since: Option<(i64, i64)>,
    ) -> Vec<([u8; 32], Vec<String>)> {
        let Ok(epoch) = self.session.epoch(mls_group_id).await else {
            return Vec::new();
        };
        match self.storage.prior_routings(
            mls_group_id,
            epoch.saturating_sub(routing_retained_epochs()),
            written_since,
        ) {
            Ok(prior) => prior
                .into_iter()
                .map(|(id, relays)| (id, usable_relays(relays)))
                .collect(),
            Err(e) => {
                log::warn!("a circle's prior routing was not read: {}", e.code());
                Vec::new()
            }
        }
    }

    /// Moves the instant every prior routing of `mls_group_id` was written
    /// to `written_at` (seconds): how a test ages a routing change, or plants
    /// one written after a clock that has since been set back.
    ///
    /// # Panics
    ///
    /// When the store's lock is poisoned or the write fails: a test's setup.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn date_prior_routing_for_test(&self, mls_group_id: &GroupId, written_at: i64) {
        self.storage
            .conn()
            .lock()
            .expect("the store's lock")
            .execute(
                "UPDATE routing_history SET written_at = ?2 WHERE mls_group_id = ?1",
                rusqlite::params![mls_group_id.as_slice(), written_at],
            )
            .expect("the routing history is dated");
    }

    /// The group's current admin set without this device, refused when that
    /// would leave it empty.
    async fn admins_without_self(&self, mls_group_id: &GroupId) -> Result<Vec<[u8; 32]>> {
        let self_id = self.session.self_id().await;
        let admins: Vec<[u8; 32]> = self
            .session
            .admin_pubkeys(mls_group_id)
            .await
            .map_err(CircleError::from_session)?
            .into_iter()
            .filter(|admin| admin.as_slice() != self_id.as_slice())
            .collect();
        if admins.is_empty() {
            return Err(CircleError::Mls(
                "cannot demote the last admin — promote a successor first".to_string(),
            ));
        }
        Ok(admins)
    }

    /// [`Self::propose_self_demote`] in staging mode.
    ///
    /// # Errors
    ///
    /// As [`Self::propose_self_demote`].
    pub(crate) async fn propose_self_demote_staging(
        &self,
        mls_group_id: &GroupId,
        now_ms: u64,
        still: Still<'_>,
    ) -> Result<StagedChange> {
        let admins = self.admins_without_self(mls_group_id).await?;
        self.admin_change(mls_group_id, &admins, now_ms, still)
            .await
    }

    // ==================== Epoch-rotation repair (C4) ========================

    /// Every gate [`Self::repair_epoch_rotation_staging`] reads before it asks
    /// the engine for the self-update.
    async fn rotation_preflight(
        &self,
        mls_group_id: &GroupId,
        now_secs: u64,
    ) -> Result<RotationPreflight> {
        // Storage errors reach the FFI boundary as prose, and a rusqlite message
        // can quote the failing statement — which on these two tables carries
        // the circle's `nostr_group_id` as hex. Every other fallible call in
        // this function is redacted; these two were the gap.
        let circle = self
            .storage
            .get_circle(mls_group_id)
            .map_err(|e| redact_storage_error(&e))?
            .ok_or_else(|| CircleError::NotFound("Circle not found: <redacted>".to_string()))?;

        let rotation_state = self
            .storage
            .circle_rotation_state(&circle.nostr_group_id)
            .map_err(|e| redact_storage_error(&e))?;
        // Fail CLOSED: a store this device cannot read is not evidence that
        // nobody is about to commit, and a rotation raced against a peer's
        // auto-commit is exactly the same-epoch sibling the engine's in-memory
        // `committed_from` cannot reconcile across a restart (M11 §H2).
        let pending_proposal = match self.session.has_pending_proposal(mls_group_id).await {
            Ok(pending) => pending,
            Err(e) => {
                log::warn!(
                    "epoch-rotation repair: reading the proposal window failed; \
                     declining the repair: {}",
                    e.code()
                );
                true
            }
        };

        let decision = rotation_decision(&RotationInputs {
            // The transient non-`Stable` states are refused by the send itself,
            // read under its own session lock, and arrive as the typed
            // rejection below.
            group_is_unrecoverable: self
                .session
                .unrecoverable(mls_group_id)
                .await
                .unwrap_or(true),
            last_epoch_change_at: secs_from_ms(rotation_state.last_epoch_change_seen_at_ms),
            last_rotation_at: secs_from_ms(rotation_state.last_rotation_at_ms),
            last_inbound_event_at: secs_from_ms(rotation_state.last_inbound_event_at_ms),
            pending_proposal,
            now: now_secs,
        });
        if let RotationDecision::Skip(reason) = decision {
            return Ok(RotationPreflight::Skip(reason));
        }

        // The send gate, checked BEFORE the intent exists. `do_send` does not
        // reject a send it cannot perform — it QUEUES it, durably, and the queue
        // drains later into a real commit with none of the gates above
        // re-evaluated and no rate limit charged. Queued intent ids are not
        // deduplicated either, so without this every Repair tap on a stalled
        // circle would bank another epoch bump, all landing in a burst the
        // moment the circle unblocks. Asking the gate first means the intent is
        // never issued at all.
        if self.session.send_gated(mls_group_id).await {
            return Ok(RotationPreflight::Gated);
        }
        Ok(RotationPreflight::Go {
            nostr_group_id: circle.nostr_group_id,
        })
    }

    /// The epoch-rotation repair in staging mode: a self-update of this
    /// device's leaf ([`SessionManager::repair_self_update_staging`]), staged
    /// under its durable fanout; its 24-hour rate limit is spent when the
    /// fanout driver's confirm applies it, in this session
    /// ([`Self::confirm_fanout`]). Any member may make it.
    ///
    /// # Errors
    ///
    /// A redacted storage or engine error; nothing was staged.
    pub(crate) async fn repair_epoch_rotation_staging(
        &self,
        mls_group_id: &GroupId,
        now_secs: u64,
        now_ms: u64,
        still: Still<'_>,
    ) -> Result<StagedRepair> {
        let nostr_group_id = match self.rotation_preflight(mls_group_id, now_secs).await? {
            RotationPreflight::Skip(reason) => return Ok(StagedRepair::Skipped(reason)),
            RotationPreflight::Gated => {
                let (handed_back, recorded) = self
                    .repair_deferred_send_staging(mls_group_id, now_secs, now_ms, still)
                    .await;
                return Ok(StagedRepair::Deferred {
                    recorded,
                    handed_back,
                });
            }
            RotationPreflight::Go { nostr_group_id } => nostr_group_id,
        };
        let staged = match self
            .session
            .repair_self_update_staging(mls_group_id, now_ms, still)
            .await
        {
            Ok(staged) => staged,
            Err(crate::nostr::NostrError::EpochNotStable) => {
                return Ok(StagedRepair::Skipped(SkipReason::EpochNotStable));
            }
            Err(crate::nostr::NostrError::EpochUnrecoverable) => {
                return Ok(StagedRepair::Skipped(SkipReason::EpochUnrecoverable));
            }
            Err(e) => return Err(CircleError::from_session(e)),
        };
        // Gate 7: the engine queued the self-update instead of staging it,
        // and the hold that queued it retired it. What the hold left besides
        // is folded as a staging hold's batch is: a commit still in it stays
        // staged and unsent ([`Self::staged_change`]), and the deferral is
        // repaired.
        if staged
            .effects
            .queued
            .iter()
            .any(|queued| &queued.group_id == mls_group_id)
        {
            let staged_here = staged.fanouts.iter().any(|id| id.group() == mls_group_id);
            let mut recorded = staged.fanouts;
            recorded.extend(staged.proposals);
            let (mut handed_back, more) =
                self.fold_staged(staged.effects, false, now_ms, still).await;
            recorded.extend(more);
            // A commit this hold recorded in the circle is what queued the
            // self-update: nothing is stuck, and there is nothing to repair.
            if !staged_here {
                let (repaired, more) = self
                    .repair_deferred_send_staging(mls_group_id, now_secs, now_ms, still)
                    .await;
                handed_back.results.extend(repaired.results);
                handed_back.proposals.extend(repaired.proposals);
                recorded.extend(more);
            }
            return Ok(StagedRepair::Deferred {
                recorded,
                handed_back,
            });
        }
        let change = self.staged_change(mls_group_id, staged).await?;
        if let Some(commit) = &change.commit {
            self.rotation_fanouts
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .insert(commit.message().clone(), nostr_group_id);
        }
        Ok(StagedRepair::Rotated(change))
    }

    /// The post-join self-update MDK's obligation owes for `mls_group_id`
    /// ([`SessionManager::post_join_self_update_staging`]), with none of the
    /// repair's gates and no rate limit charged: the caller has read the
    /// circle due ([`SessionManager::post_join_due`]). Made only by a full
    /// drive (`Publishing::resume`).
    pub(crate) async fn post_join_self_update_staging(
        &self,
        mls_group_id: &GroupId,
        now_ms: u64,
        still: Still<'_>,
    ) -> StagedPostJoin {
        // Not stable, terminal or failed: the obligation stays open, and a
        // later drive makes it.
        let Ok(staged) = self
            .session
            .post_join_self_update_staging(mls_group_id, now_ms, still)
            .await
        else {
            return StagedPostJoin::NotMade(Vec::new(), DecryptedIngest::default());
        };
        if staged
            .effects
            .queued
            .iter()
            .any(|queued| &queued.group_id == mls_group_id)
        {
            let mut recorded = staged.fanouts;
            recorded.extend(staged.proposals);
            let (handed_back, more) = self.fold_staged(staged.effects, false, now_ms, still).await;
            recorded.extend(more);
            return StagedPostJoin::NotMade(recorded, handed_back);
        }
        self.staged_change(mls_group_id, staged).await.map_or_else(
            |_| StagedPostJoin::NotMade(Vec::new(), DecryptedIngest::default()),
            StagedPostJoin::Made,
        )
    }

    /// Final step of every non-abandoning leave: returns a `SelfRemove` proposal
    /// event so peers can advance past the caller.
    ///
    /// A bare proposal has no `PendingStateRef` — a remaining member commits it
    /// later (RFC 9420 §12.1.2). The caller publishes the returned event, then
    /// calls [`Self::complete_leave`]; there is nothing to confirm. `None` when
    /// this epoch's proposal already exists: the leave stands, nothing new is
    /// published, and the caller proceeds exactly as after a publish.
    ///
    /// The leave intent is written FIRST, before the engine is asked for
    /// anything: from that instant no location of the circle is sealed or
    /// sent, on any plane ([`CircleError::LeaveInProgress`]). It ends with the
    /// circle, or when the engine refuses the leave for good.
    ///
    /// # Errors
    ///
    /// Returns the store's error when the intent cannot be written — nothing
    /// was asked of the engine — and an error if the engine rejects the
    /// leave: [`CircleError::AdminSelfDemoteRequired`] and
    /// [`CircleError::NotFound`] end the intent; any other leaves it
    /// standing.
    pub async fn propose_leave(&self, mls_group_id: &GroupId) -> Result<Option<Event>> {
        self.storage
            .mark_leave_intent(mls_group_id, i64::try_from(now_secs()).unwrap_or(i64::MAX))?;
        let effects = match self.session.leave_group(mls_group_id).await {
            Ok(effects) => effects,
            Err(e) => return Err(self.refused_leave(mls_group_id, e)),
        };
        match effects {
            // Queued behind what the engine staged first: the leave stands,
            // and the engine's drain mints its proposal later.
            Some(effects)
                if effects
                    .queued
                    .iter()
                    .any(|queued| &queued.group_id == mls_group_id) =>
            {
                self.note_send_drain(&effects.events).await;
                Ok(None)
            }
            Some(effects) => Ok(Some(self.take_proposal(effects).await?)),
            None => Ok(None),
        }
    }

    /// When this device asked to leave `mls_group_id`, unix seconds on the
    /// clock that asked ([`CircleStorage::mark_leave_intent`]).
    ///
    /// # Errors
    ///
    /// Returns the store's error.
    pub fn leave_intent_at(&self, mls_group_id: &GroupId) -> Result<Option<i64>> {
        self.storage.leave_intent_at(mls_group_id)
    }

    /// Records that this device asks to leave `mls_group_id` at `at_secs` —
    /// keeping an earlier instant unless `renewed` — from here no location of
    /// the circle is sealed or sent.
    ///
    /// # Errors
    ///
    /// Returns the store's error; nothing was marked.
    pub(crate) fn mark_leave_intent(
        &self,
        mls_group_id: &GroupId,
        at_secs: i64,
        renewed: bool,
    ) -> Result<()> {
        if renewed {
            self.storage.renew_leave_intent(mls_group_id, at_secs)
        } else {
            self.storage.mark_leave_intent(mls_group_id, at_secs)
        }?;
        // Nothing sealed before the leave was asked goes out by mesh.
        self.session.mesh_silence(mls_group_id);
        Ok(())
    }

    /// The engine's refusal of a leave, at the circle boundary. The two no
    /// retry changes — an admin who must demote first, a circle the engine
    /// does not hold — end the intent, and the circle shares again; any
    /// other leaves it standing, sharing off, for the next attempt.
    fn refused_leave(&self, mls_group_id: &GroupId, e: crate::nostr::NostrError) -> CircleError {
        let permanent = matches!(
            e,
            crate::nostr::NostrError::AdminSelfDemoteRequired
                | crate::nostr::NostrError::GroupNotFound(_)
        );
        if permanent {
            if let Err(cleared) = self.storage.clear_leave_intent(mls_group_id) {
                log::warn!(
                    "a refused leave's intent was not cleared; the circle stays held: {}",
                    cleared.code()
                );
            }
        }
        match e {
            crate::nostr::NostrError::GroupNotFound(_) => {
                CircleError::NotFound("Circle not found: <redacted>".to_string())
            }
            other => CircleError::from(other),
        }
    }

    /// [`Self::propose_leave`]'s engine step in staging mode, for
    /// [`Publishing::resume_leave`](crate::relay::fanout::Publishing::resume_leave):
    /// the proposal's durable fanout is written in the hold that minted it,
    /// with whatever else that hold staged. The intent is the caller's.
    ///
    /// # Errors
    ///
    /// As [`Self::refused_leave`], and [`CircleError::EngineHeld`].
    pub(crate) async fn propose_leave_staging(
        &self,
        mls_group_id: &GroupId,
        now_ms: u64,
        still: Still<'_>,
    ) -> Result<LeaveStep> {
        let staged = match self
            .session
            .leave_group_staging(mls_group_id, now_ms, still)
            .await
        {
            Ok(Some(staged)) => staged,
            // Proposed only where it is recorded: a proposal the engine holds
            // that no record stands or stood for was never sent by this device.
            Ok(None) if self.leave_recorded(mls_group_id).await => {
                return Ok(LeaveStep::AlreadyProposed)
            }
            Ok(None) => return Ok(LeaveStep::Unrecorded(Vec::new())),
            Err(crate::nostr::NostrError::EpochNotStable) => {
                return Ok(LeaveStep::AwaitsStable(Vec::new()))
            }
            Err(crate::nostr::NostrError::EngineHeld) => return Err(CircleError::EngineHeld),
            // The driver plans again with the intent kept: the engine's own
            // preflight may have made this device an admin since its plan.
            Err(crate::nostr::NostrError::AdminSelfDemoteRequired) => {
                return Err(CircleError::AdminSelfDemoteRequired)
            }
            Err(e) => return Err(self.refused_leave(mls_group_id, e)),
        };
        self.note_send_drain(&staged.effects.events).await;
        let rows = staged.fanouts.into_iter().chain(staged.proposals).collect();
        if staged
            .effects
            .queued
            .iter()
            .any(|intent| &intent.group_id == mls_group_id)
        {
            return Ok(LeaveStep::AwaitsStable(rows));
        }
        if self.leave_recorded(mls_group_id).await {
            Ok(LeaveStep::Recorded(rows))
        } else {
            Ok(LeaveStep::Unrecorded(rows))
        }
    }

    /// Whether the leave proposal the engine minted for `mls_group_id` in its
    /// latest proposing epoch was recorded: a record of that epoch's proposal
    /// stands and is not spent — and then this is noted
    /// ([`CircleStorage::mark_leave_recorded`]) — or one did and a relay's
    /// acknowledgement ended it, as the note says. An earlier epoch's record
    /// says nothing of this one's, and what cannot be read is no record.
    async fn leave_recorded(&self, mls_group_id: &GroupId) -> bool {
        let Some(minted) = self.session.leave_proposed_epoch(mls_group_id) else {
            return false;
        };
        if self
            .session
            .proposal_recorded_at(mls_group_id, minted)
            .await
        {
            // Written after the record, so a crash between them understates
            // the leave and never overstates it; a mark that cannot be
            // written does the same.
            let _ = self.storage.mark_leave_recorded(mls_group_id, minted);
            return true;
        }
        self.storage
            .leave_recorded_epoch(mls_group_id)
            .is_ok_and(|marked| marked == Some(minted))
    }

    /// Finalizes a leave: the circle's MLS state is forgotten
    /// ([`Self::forget_left_group`]), then its local row removed. Safe for the
    /// `OrphanLocalOnly` plan, and after a process that died between the two:
    /// a group the engine no longer holds has nothing to forget.
    ///
    /// Reconciles the member directory afterwards, in the ORDINARY (`Rewrite`)
    /// mode. `delete_circle` deliberately does not cascade to the directory, so
    /// without this the circle's co-members would keep `is_current = 1` and the
    /// never-purge sentinel for ever: not merely past retention but *unable to
    /// expire*, still rendered under "Members of your circles" — a claim about
    /// a member list that no longer exists on this device. Demotion, never
    /// deletion, is the point (plan §5.5's trap): this is also the finalizer of
    /// a VOLUNTARY leave, and the person the user just left a circle with is
    /// exactly the contact requirement R5 exists to keep for three days.
    ///
    /// `now_unix_secs` is the clock that retention deadline is computed against;
    /// it is a parameter so the outcome is pinned to a value rather than to when
    /// the test happens to run.
    ///
    /// # Errors
    ///
    /// Returns an error if the engine refuses the forget or the circle-row
    /// deletion fails; the row is then kept, and so is the leave's intent,
    /// which the next attempt carries on. The directory refresh is
    /// best-effort and never fails the leave.
    pub async fn complete_leave(&self, mls_group_id: &GroupId, now_unix_secs: i64) -> Result<()> {
        let kept = self.forget_left_group(mls_group_id).await?;
        let _existed = self.storage.delete_left_circle(mls_group_id, kept)?;
        // Every routing id the circle held is now no one's: the session's
        // follow stops listening for each.
        self.wake_routing_follow();
        // A left circle's locations go unsent; its leave proposals are read
        // as spent and send nothing (`SessionManager::proposal_is_spent`).
        self.session.end_location_records(mls_group_id).await;
        self.reconcile_member_directory_at(DirectoryReconcile::Rewrite, now_unix_secs)
            .await;
        Ok(())
    }

    /// Abandons a circle where the caller is the sole remaining member.
    ///
    /// Same local-teardown semantics as [`Self::complete_leave`] (no relay
    /// publish — there is no one to receive a `SelfRemove`).
    ///
    /// # Errors
    ///
    /// Returns an error if the circle-row deletion fails.
    pub async fn abandon_circle_local_only(
        &self,
        mls_group_id: &GroupId,
        now_unix_secs: i64,
    ) -> Result<()> {
        self.complete_leave(mls_group_id, now_unix_secs).await
    }

    /// Forgets the MLS state of `mls_group_id`, whose circle has ended,
    /// through MDK's `forget_group_local` (Security Rule 5). Kept instead,
    /// and asked about again ([`Self::forget_left_groups`]), when:
    ///
    /// * it was disbanded — the forget would delete the tombstone that keeps
    ///   it from being joined again (`app-components/group-lifecycle-v1.md`
    ///   29-32; MDK `storage-sqlite/src/account_projection.rs` 1510-1516);
    /// * the engine cannot say where it stands;
    /// * an invitation from one of its members may be held unanswered: the
    ///   forget makes MDK refuse every Welcome written before it
    ///   (`cgka-engine/src/group_lifecycle.rs` 1152-1157), so a re-invite
    ///   made before this device saw its removal could never join. Its old
    ///   epochs' keys stay on the device until that invitation is answered.
    ///
    /// Returns whether the group was kept; a kept group stays on the
    /// circle store's list of left groups still to forget
    /// (`CircleStorage::left_groups`), which every later ask reads.
    ///
    /// # Errors
    ///
    /// The engine's refusal of the forget: nothing was deleted.
    async fn forget_left_group(&self, mls_group_id: &GroupId) -> Result<bool> {
        let forgets = match self.session.left_group(mls_group_id).await {
            LeftGroup::Held(members) => !self.reinvite_may_be_held(&members),
            LeftGroup::Unread => false,
            LeftGroup::Gone | LeftGroup::Disbanded => {
                let _ = self.storage.clear_left_group(mls_group_id);
                return Ok(false);
            }
        };
        if !forgets {
            return Ok(true);
        }
        self.session
            .forget_group_local(mls_group_id)
            .await
            .map_err(CircleError::from_session)?;
        let _ = self.storage.clear_left_group(mls_group_id);
        Ok(false)
    }

    /// Whether an invitation from one of `members` may be held unanswered.
    /// Until as many invitations are held again as were held before a
    /// restart, one not yet polled back counts, and so does a store that
    /// cannot say.
    fn reinvite_may_be_held(&self, members: &[MemberId]) -> bool {
        let held = self.pending_welcomes.previews();
        if held.is_empty() || !self.held_polled_back(held.len()) {
            return !matches!(self.storage.held_invitation_outstanding(), Ok(false));
        }
        held.iter().any(|(_, preview)| {
            hex::decode(&preview.inviter_pubkey).map_or(true, |inviter| {
                members.iter().any(|member| member.as_slice() == inviter)
            })
        })
    }

    /// Asks again about every ended circle whose MLS state was kept
    /// ([`Self::forget_left_group`]): it is forgotten once nothing keeps it,
    /// and let go of once its circle has a row again — it was joined anew.
    /// A forget that fails is asked about again at the next call.
    pub(crate) async fn forget_left_groups(&self) {
        let Ok(kept) = self.storage.left_groups() else {
            return;
        };
        for group_id in kept {
            match self.storage.get_circle(&group_id) {
                Ok(Some(_)) => {
                    let _ = self.storage.clear_left_group(&group_id);
                }
                Ok(None) => {
                    let _ = self.forget_left_group(&group_id).await;
                }
                Err(_) => {}
            }
        }
    }

    /// Forgets, as [`Self::forget_left_groups`] does, every group this
    /// session held at its open that no circle row names and no consented
    /// join is still owed for: a create, a join or a leave that a process
    /// died in the middle of left MLS state nothing on the device would ever
    /// end. A group made after the open is never a candidate, and anything
    /// that cannot be read keeps the group.
    async fn sweep_orphaned_groups(&self) {
        let Some(at_open) = self.session.groups_at_open().map(<[GroupId]>::to_vec) else {
            return;
        };
        let Some(owed) = self.session.owed_joins().await else {
            return;
        };
        for group_id in at_open {
            if !owed.iter().any(|join| join.group_id == group_id)
                && matches!(self.storage.get_circle(&group_id), Ok(None))
            {
                let _ = self.storage.mark_left_group(&group_id);
            }
        }
        self.forget_left_groups().await;
    }

    /// Whether as many invitations as were held when this process opened are
    /// held again (`held` now), latched once they have been.
    fn held_polled_back(&self, held: usize) -> bool {
        use std::sync::atomic::Ordering;
        if held >= self.held_at_open {
            self.held_polled_back.store(true, Ordering::Release);
        }
        self.held_polled_back.load(Ordering::Acquire)
    }

    /// The count of held invitations to keep durably for `held` now: never
    /// fewer than were held at the open until those have been polled back,
    /// so a second restart still knows of them.
    fn held_to_record(&self, held: usize) -> usize {
        if self.held_polled_back(held) {
            held
        } else {
            held.max(self.held_at_open)
        }
    }

    // ==================== Publish-before-apply (Rule 13) ====================

    /// The fanout driver's confirm: at least one relay acknowledged the
    /// commit `fanout` holds. Folds what the engine hands back.
    ///
    /// An error in what it returns is NEVER a reason to roll back: the merge
    /// may have happened, and the stored row says whether it did.
    pub(crate) async fn confirm_fanout(
        &self,
        fanout: &mut StoredFanout,
        now_ms: u64,
        mode: DriveMode,
        still: Still<'_>,
    ) -> Option<FanoutResolution> {
        let settlement = self
            .session
            .confirm_fanout(fanout, now_ms, mode, still)
            .await?;
        // The row says whether the commit was applied, never the call's
        // result. A repair rotation spends its circle's rate limit here.
        if fanout.applied() {
            if let Some(nostr_group_id) =
                self.take_rotation_fanout(fanout.as_mdk_fanout().message_id())
            {
                let now_ms = chrono::Utc::now().timestamp_millis();
                if let Err(e) = self
                    .storage
                    .note_rotation_confirmed(&nostr_group_id, now_ms)
                {
                    log::warn!(
                        "epoch-rotation repair: recording the rate limit failed; the circle may \
                         accept another repair sooner than intended: {}",
                        e.code()
                    );
                }
            }
        }
        Some(self.settle_fanout(settlement, now_ms, still).await)
    }

    /// Removes and returns the circle bound to a repair rotation's fanout.
    fn take_rotation_fanout(&self, commit: &MessageId) -> Option<[u8; 32]> {
        self.rotation_fanouts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(commit)
    }

    /// Finishes a confirm the engine stored and did not complete
    /// ([`SessionManager::finish_confirmed_fanout`]).
    pub(crate) async fn finish_confirmed_fanout(
        &self,
        pending: PendingStateRef,
        now_ms: u64,
        still: Still<'_>,
    ) -> FanoutResolution {
        let settlement = self
            .session
            .finish_confirmed_fanout(pending, now_ms, still.decided())
            .await;
        self.settle_fanout(settlement, now_ms, still).await
    }

    /// The fanout driver's rollback: every relay proved it did not take the
    /// commit `fanout` holds and none was ever possibly exposed.
    pub(crate) async fn roll_back_fanout(
        &self,
        fanout: &mut StoredFanout,
        now_ms: u64,
        still: Still<'_>,
    ) -> Option<FanoutResolution> {
        let settlement = self.session.roll_back_fanout(fanout, now_ms, still).await?;
        // A rolled-back rotation spent nothing.
        if fanout.rolled_back() {
            let _ = self.take_rotation_fanout(fanout.as_mdk_fanout().message_id());
        }
        Some(self.settle_fanout(settlement, now_ms, still).await)
    }

    /// Folds what a fanout resolution handed back.
    ///
    /// The engine call behind it ran in staging mode, so the batch carries no
    /// commit: each one already has its row, written in the hold that made
    /// the call — after a failed call too — and comes back as a handle. So do
    /// the fold's own advances ([`SessionManager::advance_for_drive`]): the
    /// next eviction of a cascade, a change the user had queued and a leave
    /// proposed again are each recorded in the hold that released them, and
    /// their handles join [`FanoutResolution::staged`] for the same drive.
    ///
    /// A failed call's error comes back BESIDE what it left, never instead
    /// of it: the fold's products and the staged handles are the only way
    /// their owner learns of them.
    ///
    /// While a rolled-back commit's own row is still stored as sent, this
    /// fold persists the batch and advances nothing: a convergence pass
    /// would merge that commit (T-ROLLBACK-RESURRECT).
    ///
    /// In [`DriveMode::FinishOnly`] the fold's advances are inputs-only
    /// ([`Disposition::Settle`]): what the confirm replayed is applied and
    /// stored, and nothing new is made. In the full mode each of them asks
    /// `still` again with the engine held, and is inputs-only once the mode
    /// the resolution was decided in has ended.
    async fn settle_fanout(
        &self,
        settlement: FanoutSettlement,
        now_ms: u64,
        still: Still<'_>,
    ) -> FanoutResolution {
        let FanoutSettlement {
            staged,
            error,
            unretired,
        } = settlement;
        let Staged {
            effects,
            mut fanouts,
            proposals,
            ..
        } = staged;
        fanouts.extend(proposals);
        let disposition = Disposition::recording(now_ms, still);
        if let Some(e) = error {
            // Whatever the failed call had already emitted is folded, and the
            // original error stands.
            let replayed = if effects.is_empty() {
                DecryptedIngest::default()
            } else {
                let (replayed, _, recorded) = self
                    .fold_resolved_publish_advancing(
                        effects,
                        BatchOrigin::Drained,
                        !unretired,
                        disposition,
                    )
                    .await;
                fanouts.extend(recorded);
                replayed
            };
            return FanoutResolution {
                replayed,
                staged: fanouts,
                error: Some(CircleError::from_session(e)),
            };
        }
        let mode = self.publish_outcome_verdict(&effects.events);
        let (replayed, drained, recorded) = self
            .fold_resolved_publish_advancing(
                effects,
                BatchOrigin::TopLevel,
                !unretired,
                disposition,
            )
            .await;
        fanouts.extend(recorded);
        let mode = drained.map_or(mode, |drained| mode.max(drained));
        self.reconcile_member_directory_best_effort(mode).await;
        FanoutResolution {
            replayed,
            staged: fanouts,
            error: None,
        }
    }

    /// [`Self::fold_resolved_publish`]; with `advance` off, the batch is
    /// persisted and disposed of and no group is advanced. `disposition`
    /// says what becomes of what the fold's own advances release; the
    /// handles of whatever they recorded come back third.
    async fn fold_resolved_publish_advancing(
        &self,
        seed: SessionEffects,
        origin: BatchOrigin,
        advance: bool,
        disposition: Disposition<'_>,
    ) -> (DecryptedIngest, Option<DirectoryReconcile>, Vec<FanoutId>) {
        // MDK reports a replayed input's quiescence hold only as a deadline,
        // so the groups the resolution touched are asked for one at the end.
        let mut seed_groups = SessionManager::groups_of(&seed.events);
        let mut worklist = std::collections::VecDeque::from([(seed, origin)]);
        let mut convergence: Vec<GroupId> = Vec::new();
        let mut out = DecryptedIngest::default();
        let mut staged: Vec<FanoutId> = Vec::new();
        let mut verdict: Option<DirectoryReconcile> = None;
        let mut ticks_left = crate::relay::retick::MAX_CONVERGENCE_RETICKS;
        let mut batches = 0_usize;
        // Whether a re-advance has already run in this call, and how long the
        // next one waits for the engine's nearest deadline.
        let (mut advanced, mut capped) = (false, false);
        let mut wait = std::time::Duration::ZERO;

        loop {
            while let Some((effects, origin)) = worklist.pop_front() {
                batches += 1;
                // The cap stops the fold GENERATING work — no further advance,
                // no further re-tick — and stops nothing else. A batch the
                // engine has already handed back is still folded here, because
                // dropping one is precisely the loss this fold exists to
                // prevent: its replayed locations are delivered at most once
                // (their rows are written `Processed` as they are pushed), and
                // its staged commits carry live refs that nothing but
                // `dispose_publish_work` records an obligation for.
                //
                // The drain still terminates. The only batch a disposal can
                // release is a rollback's, each rollback resolves a ref
                // `resolved` will not hand out twice, and the eviction MDK
                // re-arms after a rollback is held until the epoch moves.
                if batches > MAX_FOLD_BATCHES {
                    capped = true;
                }

                out.results
                    .extend(self.fold_resolved_batch(&effects.events).await);
                match origin {
                    BatchOrigin::TopLevel => {
                        self.note_inbound_arrival_for_message_received(&effects.events);
                    }
                    BatchOrigin::Drained => self.note_inbound_group_events(&effects.events),
                }
                verdict = verdict.max(self.directory_verdict_for_events(&effects.events));

                for group_id in SessionManager::groups_owing_advance(&effects) {
                    // A held eviction would only spin (`eviction_retick_held`).
                    if !convergence.contains(&group_id)
                        && !self.session.eviction_retick_held(&group_id).await
                    {
                        convergence.push(group_id);
                    }
                }

                for item in effects.publish {
                    self.dispose_publish_work(item, &mut out).await;
                }
            }

            if advance && !advanced && convergence.is_empty() {
                let (owing, after) = crate::relay::retick::next_receive_retick(
                    &self.session,
                    &std::mem::take(&mut seed_groups),
                    Vec::new(),
                )
                .await;
                if !owing.is_empty() {
                    convergence = owing;
                    wait = after;
                    // The deadline is paid before this first advance: nothing
                    // is due until it passes.
                    advanced = true;
                }
            }
            if !advance || capped || convergence.is_empty() || ticks_left == 0 {
                break;
            }
            // A group the engine still owes a deadline after the round that
            // advanced it — a convergence pass closing, a due `SelfRemove`
            // auto-commit — is re-advanced once that deadline falls due, which
            // the engine reads off a real clock. The wait is paid once per
            // re-advance, never before the first one (work whose time has come
            // surfaces with no delay at all) and never when nothing is owed.
            if advanced {
                ticks_left -= 1;
                self.convergence_reticks
                    .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                tokio::time::sleep(wait).await;
            }
            advanced = true;
            let round = std::mem::take(&mut convergence);
            for group_id in &round {
                match self.advance_as(group_id, disposition, &mut staged).await {
                    Ok(more) => worklist.push_back((more, BatchOrigin::Drained)),
                    // Re-added rather than dropped: the group still owes an
                    // advance, and the next tick retries it.
                    Err(e) => {
                        log::warn!(
                            "publish resolution: advancing convergence failed: {}",
                            e.code()
                        );
                        convergence.push(group_id.clone());
                    }
                }
            }
            let (next, after) =
                crate::relay::retick::next_receive_retick(&self.session, &round, convergence).await;
            convergence = next;
            wait = after;
        }
        if capped {
            // A runaway guard, not a business bound. Nothing is dangling and
            // nothing is lost: every batch already handed back was folded, so
            // every auto-commit in one is surfaced with its obligation recorded
            // and every replayed location is persisted. The groups that never
            // got their advance are NAMED rather than dropped in silence — no
            // schedule is lost either, the engine keeps its own `SelfRemove`
            // schedule and re-marks the group pending on the next advance — but
            // a cap that reported only half of what it stood down from would
            // understate the bug that reached it.
            log::warn!(
                "publish resolution stopped generating at the batch cap; owed commits stand, \
                 everything already handed back was folded and {} group(s) still await an advance",
                bucket(convergence.len())
            );
        } else if ticks_left < crate::relay::retick::MAX_CONVERGENCE_RETICKS {
            log::debug!(
                "publish resolution drained convergence after {} re-tick(s)",
                bucket(crate::relay::retick::MAX_CONVERGENCE_RETICKS - ticks_left)
            );
        }
        (out, verdict, staged)
    }

    /// One advance of the fold, as `disposition` asks: what a staging advance
    /// recorded joins `staged`.
    async fn advance_as(
        &self,
        group_id: &GroupId,
        disposition: Disposition<'_>,
        staged: &mut Vec<FanoutId>,
    ) -> std::result::Result<SessionEffects, crate::nostr::NostrError> {
        let advanced = match disposition {
            // Asked again with the engine held: every wait behind the
            // decision — for the engine, for a deadline of its own — is
            // where the mode it was made in can end.
            Disposition::Stage { now_ms, still } => self
                .session
                .advance_for_drive_while(group_id, now_ms, still)
                .await
                .map(|advanced| recorded_by(advanced, staged)),
            Disposition::Settle { now_ms } => self
                .session
                .settle_inputs_for_drive(group_id, now_ms)
                .await
                .map(|advanced| recorded_by(advanced, staged)),
        };
        self.forget_dropped_removals().await;
        advanced
    }

    /// Deletes the directory rows of members whose queued removal the
    /// session retired because they were already gone
    /// (`SessionManager::retire_unmakeable_queued_changes`), and of those a
    /// removal the driver confirmed took out: the user asked for them to be
    /// removed, so the row goes outright, as it does for a removal the
    /// engine announces — a reconcile would only demote it.
    pub(crate) async fn forget_dropped_removals(&self) {
        let dropped = self.session.take_dropped_removals();
        if dropped.is_empty() {
            return;
        }
        let _directory = self.directory_lock.lock().await;
        self.forget_removed(&dropped);
    }

    /// Asks the engine for `mls_group_id`'s next deadline and serves it, as a
    /// receive plane would, for a caller that is not one: the fold's own
    /// advance-and-retick loop over a batch that owes that one circle an
    /// advance, in staging mode — the full advance, or in
    /// [`DriveMode::FinishOnly`] the inputs-only one. What the advances hand
    /// back is folded and returned beside the handles of what they recorded.
    pub(crate) async fn serve_deadlines(
        &self,
        mls_group_id: &GroupId,
        now_ms: u64,
        still: Still<'_>,
    ) -> (DecryptedIngest, Vec<FanoutId>) {
        let seed = SessionEffects {
            events: Vec::new(),
            publish: Vec::new(),
            queued: Vec::new(),
            pending_convergence: vec![mls_group_id.clone()],
        };
        self.fold_staged(seed, true, now_ms, still).await
    }

    /// Folds one batch a plane that drives received — an ingest's, an
    /// advance's — whose commits and proposals were recorded in the hold
    /// that produced them; with `advance`, everything the batch leaves owing
    /// is advanced the same way ([`Self::fold_resolved_publish`]). Returns
    /// what was folded and the handles of what the advances recorded.
    pub(crate) async fn fold_staged(
        &self,
        effects: SessionEffects,
        advance: bool,
        now_ms: u64,
        still: Still<'_>,
    ) -> (DecryptedIngest, Vec<FanoutId>) {
        let (ingest, verdict, staged) = self
            .fold_resolved_publish_advancing(
                effects,
                BatchOrigin::Drained,
                advance,
                Disposition::recording(now_ms, still),
            )
            .await;
        if let Some(mode) = verdict {
            self.reconcile_member_directory_best_effort(mode).await;
        }
        (ingest, staged)
    }

    /// The update a mesh packet carried, as the engine announced it
    /// (`SessionManager::ingest_from_mesh`): persisted and folded as every
    /// receive plane's fold does, and stamped as no inbound arrival
    /// ([`Self::note_inbound_group_events`]). That stamp holds the
    /// epoch-rotation repair back (`circle::rotation` gate 4), and a repair
    /// is a commit the relays see: whether one is made may not turn on what
    /// a phone in radio range sent.
    pub(crate) async fn fold_mesh_update(&self, update: GroupEvent) -> Vec<LocationMessageResult> {
        self.fold_resolved_batch(std::slice::from_ref(&update))
            .await
    }

    /// One batch of a resolution, persisted and folded
    /// ([`Self::persist_and_fold`]), with the two things only a resolution's
    /// fold owes: the arrival stamp for each fix it replayed, and the
    /// directory row of each member this device's own commit removed.
    async fn fold_resolved_batch(&self, events: &[GroupEvent]) -> Vec<LocationMessageResult> {
        let folded = self.persist_and_fold(events).await;
        self.note_replayed_fixes(&folded);
        self.forget_members_this_device_removed(events).await;
        folded
    }

    /// Stamps a circle's "a peer's fix arrived" time for every location a
    /// resolution replayed and this fold persisted.
    ///
    /// The receive planes' callers stamp what they route; a fix replayed
    /// inside a resolution has no such caller, and unstamped it leaves the
    /// circle reading as one nothing arrives in. Best-effort: an unrecorded
    /// arrival only makes that reading more cautious.
    fn note_replayed_fixes(&self, folded: &[LocationMessageResult]) {
        let now_ms = chrono::Utc::now().timestamp_millis();
        let mut stamped: Vec<&GroupId> = Vec::new();
        for result in folded {
            let LocationMessageResult::Location { group_id, .. } = result else {
                continue;
            };
            if stamped.contains(&group_id) {
                continue;
            }
            stamped.push(group_id);
            if let Ok(Some(circle)) = self.storage.get_circle(group_id) {
                let _ = self.storage.note_peer_event(&circle.nostr_group_id, now_ms);
            }
        }
    }

    /// Deletes from the member directory everyone a commit of THIS device's
    /// removed, the moment the engine reports the removal applied.
    ///
    /// [`Self::remove_members`] deletes the row when the removal is staged.
    /// That is not enough for a removal the engine queued: a reconcile that
    /// runs while it waits finds the person still on the roster and writes the
    /// row back, and the reconcile after the removal lands only DEMOTES a row
    /// it finds — three more days one tap from live location (owner decision
    /// D3). The reconcile that follows restores anyone another circle still
    /// has. `actor` is the committer; a removal someone else made is theirs.
    async fn forget_members_this_device_removed(&self, events: &[GroupEvent]) {
        let own = self.session.identity_pubkey().to_bytes();
        let removed: Vec<String> = events
            .iter()
            .filter_map(|event| match event {
                GroupEvent::GroupStateChanged {
                    actor: Some(actor),
                    change: GroupStateChange::MemberRemoved { member },
                    ..
                } if actor.as_slice() == own.as_slice() => Some(hex::encode(member.as_slice())),
                _ => None,
            })
            .collect();
        if removed.is_empty() {
            return;
        }
        let _directory = self.directory_lock.lock().await;
        self.forget_removed(&removed);
    }

    /// Deletes `member_pubkeys` from the member directory, best-effort.
    fn forget_removed(&self, member_pubkeys: &[String]) {
        for pubkey_hex in member_pubkeys {
            if let Err(e) = self.storage.delete_directory_member(pubkey_hex) {
                log::warn!(
                    "member directory: removal row not deleted (the next reconcile \
                     demotes it instead of deleting it): {}",
                    e.code()
                );
            }
        }
    }

    /// Re-derives the row of every circle `results` report updated
    /// ([`Self::resync_circle_relays_from_mdk`]). Best-effort: the next
    /// commit the circle applies retries it.
    async fn resync_updated_circles(&self, results: &[LocationMessageResult]) {
        #[cfg(any(test, feature = "test-utils"))]
        if results
            .iter()
            .any(|result| matches!(result, LocationMessageResult::GroupUpdate { .. }))
            && self
                .skip_next_follow
                .swap(false, std::sync::atomic::Ordering::SeqCst)
        {
            return;
        }
        let mut updated: Vec<&GroupId> = Vec::new();
        for result in results {
            if let LocationMessageResult::GroupUpdate { group_id } = result {
                if !updated.contains(&group_id) {
                    updated.push(group_id);
                }
            }
        }
        for group_id in updated {
            if let Err(e) = self.resync_circle_relays_from_mdk(group_id).await {
                log::debug!(
                    "relay re-sync failed (will retry on next commit): {}",
                    e.code()
                );
            }
        }
    }

    /// One [`PublishWork`] item's disposition inside the fold.
    #[deny(clippy::wildcard_enum_match_arm)]
    async fn dispose_publish_work(&self, item: PublishWork, out: &mut DecryptedIngest) {
        match item {
            // A commit in a batch is one its hold could neither record nor
            // roll back (`SessionManager::stage_commits`, which said so, told
            // its circle and kept the ref): every hold that hands a batch here
            // records what it stages. It is not published: the usual reason
            // it has no record is an earlier commit of its circle a relay may
            // hold, and a second one sent beside that would fork the circle.
            // It stays staged; the next staging hold tries the rollback again,
            // and failing that the next open settles it.
            PublishWork::AutoPublish { .. }
            | PublishWork::GroupEvolution { .. }
            | PublishWork::GroupCreated { .. }
            | PublishWork::FoundingGroupCreated { .. } => {}
            // The local user's own re-proposed leave (a peer commit landing
            // while a leave request stands re-mints it for the accepted epoch).
            // Dropping it wedges the leave behind the engine's send gate.
            PublishWork::Proposal { msg, queued_intent } => {
                match SessionManager::transport_message_to_event(&msg) {
                    Ok(event) => out.proposals.push(event),
                    Err(e) => log::warn!(
                        "publish resolution: dropping an unserializable proposal: {}",
                        e.code()
                    ),
                }
                self.retire_released_intent(queued_intent.as_ref()).await;
            }
            // Argued drop: a location intent released by the drain is superseded
            // by the fresher fix the next cadence tick sends, and publishing a
            // stale one would put an out-of-date pin on every peer's map. Its
            // durable intent is retired, or the engine would regenerate the
            // stale fix after the next restart.
            PublishWork::ApplicationMessage { queued_intent, .. } => {
                log::debug!(
                    "publish resolution observed an application message it does not publish"
                );
                self.retire_released_intent(queued_intent.as_ref()).await;
            }
        }
    }

    /// Answers a queued intent a drain regenerated but Haven does not publish
    /// itself (MDK `confirm_regenerated_queued_intent` retires the durable row).
    ///
    /// Unanswered, the engine keeps the intent in flight for the session and
    /// regenerates it after the next restart — a stale location sent late, or a
    /// leave proposed twice. A released leave stays durable without it: the
    /// engine's leave request re-proposes it on each epoch.
    async fn retire_released_intent(&self, intent: Option<&QueuedIntentRef>) {
        let Some(intent) = intent else {
            return;
        };
        if let Err(e) = self.session.retire_queued_intent(intent).await {
            log::warn!("retiring a released queued intent failed: {}", e.code());
        }
    }

    /// How many convergence re-ticks this manager's publish resolutions have
    /// slept for — the quiet-path budget, observable.
    #[cfg(any(test, feature = "test-utils"))]
    #[must_use]
    pub fn convergence_reticks(&self) -> usize {
        self.convergence_reticks
            .load(std::sync::atomic::Ordering::Relaxed)
    }

    /// The directory verdict a resolved publish implies — at least a rewrite,
    /// and a WITHDRAWING one when the engine's own effects say so.
    ///
    /// Never hard-coded to [`DirectoryReconcile::Rewrite`]. Resolving a pending
    /// ref does not merely apply or discard the staged commit: confirming ends
    /// in `replay_buffered_messages` (`cgka-engine/src/publish.rs:360`), which
    /// runs a full ingest including convergence, so this batch can carry the
    /// `GroupStateInvalidated` of a commit branch selection has just withdrawn.
    /// Reading that as an ordinary rewrite would demote a member who never
    /// existed to a three-day "recent contact" instead of deleting them,
    /// leaving them searchable and one tap from live location.
    fn publish_outcome_verdict(&self, events: &[GroupEvent]) -> DirectoryReconcile {
        // The send-side epoch-change write site: confirming our own commit is an
        // epoch change, and it is the one that does NOT arrive through a receive
        // funnel. Not an INBOUND observation, so the quiescence stamp is
        // deliberately not written here.
        self.note_epoch_changes(events);
        self.directory_verdict_for_events(events)
            .map_or(DirectoryReconcile::Rewrite, |verdict| {
                verdict.max(DirectoryReconcile::Rewrite)
            })
    }

    // ==================== Member Management ====================

    /// [`Self::add_members_with_welcomes`] in staging mode.
    ///
    /// The Welcomes are frozen in the commit's fanout and handed over by its
    /// confirm alone (Security Rule 13). What is kept here is only where each
    /// one goes: resolved for every invitee BEFORE anything is staged, so an
    /// invitee with no inbox refuses the invite instead of being added to a
    /// circle they can never be welcomed into, and kept durably
    /// ([`CommitNotes::keep_welcome_route`]) so a restart leaves no Welcome
    /// without a route.
    ///
    /// # Errors
    ///
    /// As [`Self::add_members_with_welcomes`]; and a storage error when a
    /// route could not be kept — nothing was staged.
    pub async fn add_members_staging(
        &self,
        mls_group_id: &GroupId,
        members: &[MemberKeyPackage],
        now_ms: u64,
    ) -> Result<StagedChange> {
        let routes = welcome_routes_of(members)?;
        self.touch_circle(mls_group_id)?;
        let packages = key_packages_of(members)?;
        let prior = self.keep_welcome_routes(mls_group_id, &routes)?;
        let staged = match self
            .session
            .add_members_staging(mls_group_id, packages, now_ms)
            .await
        {
            Ok(staged) => staged,
            Err(e) => {
                // Nothing was staged: no Welcome will ever need these.
                self.restore_welcome_routes(mls_group_id, &prior);
                return Err(CircleError::from_session(e));
            }
        };
        // Undone in its own hold, or staged with no record: no Welcome will
        // go. Queued, the advance that stages it reads them.
        let change = self.staged_change(mls_group_id, staged).await;
        // Nothing that will stage it: no record, and not queued.
        let staged_nothing = change.as_ref().map_or(true, |change| {
            change.commit.is_none()
                && (change.unrecorded
                    || !routes.iter().all(|(recipient, _, _)| {
                        self.session.invite_is_queued(mls_group_id, recipient)
                    }))
        });
        if staged_nothing {
            self.restore_welcome_routes(mls_group_id, &prior);
        }
        change
    }

    /// Keeps where each of `members`' Welcomes to `mls_group_id` is to go
    /// ([`welcome_route`]), before anything that can stage their invite: the
    /// confirm hands each Welcome to a record of its own with this route.
    ///
    /// # Errors
    ///
    /// [`CircleError::MissingWelcomeRelays`] when an invitee has no inbox
    /// relay Haven may dial, and a storage error when a route was not kept:
    /// nothing is kept then.
    pub(crate) fn keep_welcome_routes(
        &self,
        mls_group_id: &GroupId,
        routes: &[WelcomeRoute],
    ) -> Result<Vec<PriorRoute>> {
        let mut prior = Vec::with_capacity(routes.len());
        for (recipient, relays, not_after) in routes {
            // What stood before, put back if this invite stages nothing: an
            // earlier invite of the same person to the same circle may still
            // need it.
            let Ok(before) = self.storage.welcome_route(mls_group_id, recipient) else {
                self.restore_welcome_routes(mls_group_id, &prior);
                return Err(CircleError::Storage(
                    "a Welcome's route was not read".into(),
                ));
            };
            if !self
                .storage
                .keep_welcome_route(mls_group_id, recipient, relays, *not_after)
            {
                self.restore_welcome_routes(mls_group_id, &prior);
                return Err(CircleError::Storage(
                    "a Welcome's route was not kept".into(),
                ));
            }
            prior.push((recipient.clone(), before));
        }
        Ok(prior)
    }

    /// Puts back what [`Self::keep_welcome_routes`] found: nothing will stage
    /// the invite it kept routes for.
    pub(crate) fn restore_welcome_routes(&self, mls_group_id: &GroupId, prior: &[PriorRoute]) {
        for (recipient, before) in prior {
            match before {
                Some((relays, not_after)) => {
                    let _ = self.storage.keep_welcome_route(
                        mls_group_id,
                        recipient,
                        relays,
                        *not_after,
                    );
                }
                None => self.storage.forget_welcome_route(mls_group_id, recipient),
            }
        }
    }

    /// Enters a Welcome's relays into the contamination ledger before the
    /// Welcome is sent there: see [`Self::route_welcomes_with_cascade`] for
    /// why that ledger entry has no second chance. A Welcome whose relays
    /// could not be recorded is not sent.
    pub(crate) fn record_welcome_relays(&self, relays: &[String]) -> bool {
        self.record_contaminated(relays, ContaminationSource::Welcome)
            .is_ok()
    }

    /// [`Self::remove_members`] in staging mode. A removal the engine queued
    /// is accepted too, but its rows stay: until it is applied the member is
    /// still in the circle and still sent its locations, and a member list
    /// that had already dropped them would lie. They go when the engine
    /// reports the removal applied ([`Self::forget_members_this_device_removed`]).
    ///
    /// # Errors
    ///
    /// As [`Self::remove_members`].
    pub async fn remove_members_staging(
        &self,
        mls_group_id: &GroupId,
        member_pubkeys: &[String],
        now_ms: u64,
    ) -> Result<StagedChange> {
        self.removal_staging(mls_group_id, member_pubkeys, now_ms, true)
            .await
    }

    /// [`Self::remove_members_staging`] for decision 180's ask: one the
    /// engine queues is taken back in its hold
    /// (`SessionManager::requeue_removal_staging`).
    pub(crate) async fn requeue_removal_staging(
        &self,
        mls_group_id: &GroupId,
        member_pubkeys: &[String],
        now_ms: u64,
    ) -> Result<StagedChange> {
        self.removal_staging(mls_group_id, member_pubkeys, now_ms, false)
            .await
    }

    async fn removal_staging(
        &self,
        mls_group_id: &GroupId,
        member_pubkeys: &[String],
        now_ms: u64,
        keep_queued: bool,
    ) -> Result<StagedChange> {
        // No reconcile between the stage and the delete: it would write back
        // the row the delete takes out.
        let _directory = self.directory_lock.lock().await;
        self.touch_circle(mls_group_id)?;
        let staged = if keep_queued {
            self.session
                .remove_members_staging(mls_group_id, member_pubkeys, now_ms)
                .await
        } else {
            self.session
                .requeue_removal_staging(mls_group_id, member_pubkeys, now_ms)
                .await
        }
        .map_err(CircleError::from_session)?;
        let change = self.staged_change(mls_group_id, staged).await?;
        if change.commit.is_some() {
            self.forget_removed(member_pubkeys);
        }
        Ok(change)
    }

    /// Stamps the circle row as changed now.
    fn touch_circle(&self, mls_group_id: &GroupId) -> Result<()> {
        if let Some(mut circle) = self.storage.get_circle(mls_group_id)? {
            circle.updated_at = chrono::Utc::now().timestamp();
            self.storage.save_circle(&circle)?;
        }
        Ok(())
    }

    /// Gets members of a circle with resolved contact info.
    ///
    /// # Errors
    ///
    /// Returns an error if retrieving members fails.
    pub async fn get_members(&self, mls_group_id: &GroupId) -> Result<Vec<CircleMember>> {
        let member_hexes = self
            .session
            .member_pubkeys(mls_group_id)
            .await
            .map_err(CircleError::from_session)?;

        // Admin pubkeys are raw x-only bytes; hex-encode to compare with members.
        let admin_hexes: std::collections::HashSet<String> = self
            .session
            .admin_pubkeys(mls_group_id)
            .await
            .unwrap_or_default()
            .iter()
            .map(hex::encode)
            .collect();

        let mut members = Vec::with_capacity(member_hexes.len());
        for pubkey_hex in member_hexes {
            let is_admin = admin_hexes.contains(&pubkey_hex);
            let contact = self.storage.get_contact(&pubkey_hex)?;
            members.push(CircleMember {
                pubkey: pubkey_hex,
                display_name: contact.as_ref().and_then(|c| c.display_name.clone()),
                is_admin,
            });
        }

        Ok(members)
    }

    // ==================== Contact Management ====================

    /// Sets or updates a contact (stored locally only, never synced to relays).
    ///
    /// # Errors
    ///
    /// Returns an error if saving the contact fails.
    pub fn set_contact(
        &self,
        pubkey: &str,
        display_name: Option<&str>,
        notes: Option<&str>,
    ) -> Result<Contact> {
        let now = chrono::Utc::now().timestamp();
        let existing = self.storage.get_contact(pubkey)?;
        let created_at = existing.as_ref().map_or(now, |c| c.created_at);

        let contact = Contact {
            pubkey: pubkey.to_string(),
            display_name: display_name.map(ToString::to_string),
            notes: notes.map(ToString::to_string),
            created_at,
            updated_at: now,
        };

        self.storage.save_contact(&contact)?;
        Ok(contact)
    }

    /// Gets a contact by pubkey.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn get_contact(&self, pubkey: &str) -> Result<Option<Contact>> {
        self.storage.get_contact(pubkey)
    }

    /// Gets all contacts.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn get_all_contacts(&self) -> Result<Vec<Contact>> {
        self.storage.get_all_contacts()
    }

    /// Deletes a contact.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn delete_contact(&self, pubkey: &str) -> Result<()> {
        self.storage.delete_contact(pubkey)
    }

    // ==================== Member directory (picker) ====================

    /// Rewrites the local member directory from the union of current
    /// co-members across every visible circle, then sweeps expired rows.
    ///
    /// Returns `false` when the pass DEFERRED: a circle's membership commit is
    /// still in flight, so its roster is the engine's optimistic projection and
    /// nothing was written or purged. The caller simply reads the directory as
    /// it stands; the next membership change reconciles again.
    ///
    /// Passing the union — never a per-circle roster — is also what keeps the
    /// table free of circle attribution: every current co-member is stamped in
    /// one pass, so no row can be tied to a circle even by write timing.
    ///
    /// # Circles this pass refuses to trust
    ///
    /// Two engine states answer a roster read `Ok` while the answer is not
    /// applied state, and both SKIP rather than defer — deferring on either
    /// would freeze the whole directory for the life of the session, which is
    /// the failure the skip exists to avoid, reached from the other side. Their
    /// members age out on the ordinary window and are restored by the first
    /// reconcile after the group recovers:
    ///
    /// * a circle quarantined at session-open hydration, which cannot heal
    ///   before the next session open; and
    /// * a circle the engine has reported `Unrecoverable`, whose roster is
    ///   frozen at its last stable epoch — re-stamping it every pass would pin
    ///   those people `Current` with the never-purge sentinel for ever, and no
    ///   removal there could ever be observed. It never heals on its own:
    ///   only joining a replacement Welcome (a re-invite) clears the halt.
    ///
    /// # What may enter it
    ///
    /// Only rosters from groups the engine reports settled
    /// ([`ConvergedRoster::Converged`]). A roster read while a commit is staged
    /// is the engine's optimistic projection, and branch selection can withdraw
    /// a commit that was already published and confirmed — a row created from
    /// that state would describe a co-membership that never happened.
    ///
    /// [`DirectoryReconcile::RewriteWithdrawing`] is the other half of that
    /// rule: when the engine HAS withdrawn state, anyone who drops out of the
    /// union is deleted rather than aged out, because storage cannot tell a
    /// withdrawn add from an ordinary departure (the schema carries no
    /// `first_seen_day` — it is a partition leak) and the fold that surfaces the
    /// withdrawal keeps only the group id, so the individual superseded commit
    /// is not recoverable either. That verdict is DURABLE: it is recorded before
    /// the pass runs and cleared only by a withdrawing pass that completed, so a
    /// deferral, an error or a process death re-arms it instead of losing it.
    ///
    /// # What this does NOT promise
    ///
    /// It is not all-or-nothing. Nothing is written while any roster is still
    /// unread, so a partial union can never be persisted, and an error before
    /// the deletes leaves the directory exactly as it was. The retire set lands
    /// as ONE transaction, so it is applied whole or not at all; a failure
    /// after it still leaves those rows deleted, which is the safe direction —
    /// an over-eager delete costs a convenience the next successful pass
    /// restores, while the alternative leaves someone whose membership ended
    /// still offered as a co-member.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::Mls`] if a circle's roster read failed for any
    /// reason other than the engine not holding that group, and
    /// [`CircleError::Database`]/[`CircleError::Storage`] on a directory write
    /// failure.
    pub async fn reconcile_member_directory(
        &self,
        mode: DirectoryReconcile,
        now_unix_secs: i64,
    ) -> Result<bool> {
        // Serializes the read-union → write-union against every other reconcile
        // and against `remove_members` (see [`Self::directory_lock`]).
        let _serialized = self.directory_lock.lock().await;
        // A member whose queued removal was retired as moot is deleted, not
        // aged out: this pass would only demote the row it found
        // ([`Self::forget_dropped_removals`]). Anyone another circle still
        // has is written back below.
        self.forget_removed(&self.session.take_dropped_removals());

        // A withdrawal is owed until a withdrawing pass actually completes.
        // Recorded BEFORE any read, because the reasons this pass may not finish
        // — a circle mid-publish, a transient backend failure — are exactly the
        // conditions a multi-admin commit race produces, i.e. the conditions
        // that generate withdrawals in the first place.
        if mode == DirectoryReconcile::RewriteWithdrawing {
            self.storage.set_directory_withdrawal_owed(true)?;
        }
        let mode = if self.storage.directory_withdrawal_owed()? {
            DirectoryReconcile::RewriteWithdrawing
        } else {
            mode
        };

        // Read once: the set is fixed for the life of the session, so a
        // per-circle query would buy a lock acquisition per circle for an
        // answer that cannot change between them.
        let quarantined: HashSet<GroupId> = self
            .session
            .quarantined_group_ids()
            .await
            .into_iter()
            .collect();

        let mut union: BTreeSet<String> = BTreeSet::new();
        // Rosters of circles this device has been EVICTED from by someone else.
        // Their members are former co-members whose relationship was severed
        // without the user's say (owner decision D3, the "they remove you"
        // direction), so they are deleted rather than aged out — but only if no
        // live circle still puts them in the union.
        let mut severed: BTreeSet<String> = BTreeSet::new();

        for circle in self.storage.get_all_circles()? {
            let group_id = &circle.mls_group_id;
            // Quarantine is read explicitly rather than inferred from the
            // engine's `UnknownGroup` mapping, so the skip does not depend on
            // that mapping staying in place.
            // A disbanded circle is neither a live roster nor a removal: its
            // former members age out as after a leave, never deleted as
            // severed (`disband_commit_is_not_presented_as_member_removals`).
            // An unrecoverable group answers roster reads with the roster
            // frozen at its last stable epoch: trusting it would re-stamp
            // those people present on every pass, and no removal there could
            // ever be observed. A flag that cannot be read stamps nothing.
            if quarantined.contains(group_id)
                || self.session.disbanded(group_id).await
                || self.session.unrecoverable(group_id).await.unwrap_or(true)
            {
                continue;
            }
            let Some(membership) = self.storage.get_membership(group_id)? else {
                continue;
            };
            if !membership.status.is_visible() {
                continue;
            }
            match self.session.converged_member_pubkeys(group_id).await {
                Ok(ConvergedRoster::Converged {
                    member_pubkeys_hex,
                    removed,
                }) => {
                    if removed {
                        // `Group.removed` is set from a pure roster diff and
                        // says only that this device is out, never who decided
                        // — a peer committing the user's OWN `SelfRemove` sets
                        // it exactly as an eviction does. Severing on a leave
                        // the user chose would erase the co-members of the
                        // circle they just left, which is the very case the
                        // three-day window exists for, so a circle with a
                        // recorded local leave intent contributes to NEITHER
                        // set and its members age out normally.
                        if !self.storage.has_leave_intent(group_id)? {
                            severed.extend(member_pubkeys_hex);
                        }
                    } else {
                        union.extend(member_pubkeys_hex);
                    }
                }
                // No live group behind this circle row: nothing to read, and an
                // empty roster is not evidence that its members left.
                Ok(ConvergedRoster::Absent) => {}
                Ok(ConvergedRoster::NotConverged) => return Ok(false),
                Err(e) => return Err(CircleError::from_session(e)),
            }
        }

        // Every roster contains this device. The directory is a list of OTHER
        // people; a self row would offer the user to themselves in "members of
        // your circles".
        let own_hex = self.session.identity_pubkey().to_hex();
        union.remove(&own_hex);
        severed.remove(&own_hex);

        // One deduplicated delete pass over both destructive sets, rather than
        // one loop each: under the withdrawing verdict the severed set is
        // largely a subset of the sweep set, and a person can only be deleted
        // once.
        let withdrawn: Vec<String> = if mode == DirectoryReconcile::RewriteWithdrawing {
            self.storage
                .ranked_directory_members(now_unix_secs)?
                .into_iter()
                .filter(|entry| entry.tier == DirectoryTier::Current)
                .map(|entry| entry.pubkey_hex)
                .filter(|pubkey_hex| !union.contains(pubkey_hex))
                .collect()
        } else {
            Vec::new()
        };
        let retire: Vec<String> = severed
            .difference(&union)
            .chain(&withdrawn)
            .collect::<BTreeSet<&String>>()
            .into_iter()
            .cloned()
            .collect();
        self.storage.delete_directory_members(&retire)?;

        let union: Vec<String> = union.into_iter().collect();
        self.storage.sync_co_members(&union, now_unix_secs)?;
        self.storage
            .prune_expired_directory_members(now_unix_secs)?;
        if mode == DirectoryReconcile::RewriteWithdrawing {
            self.storage.set_directory_withdrawal_owed(false)?;
        }
        Ok(true)
    }

    /// The whole member directory in picker order — current co-members first,
    /// then recent ones.
    ///
    /// Deletes everyone past the retention window before selecting, so the
    /// three days hold on an install that never reaches
    /// [`Self::reconcile_member_directory`] — nothing here hides a row it
    /// leaves on disk (owner decision D3). `now_unix_secs` is the current Unix
    /// seconds clock.
    ///
    /// # Errors
    ///
    /// Returns an error if the database read fails.
    pub fn ranked_directory_members(
        &self,
        now_unix_secs: i64,
    ) -> Result<Vec<super::DirectoryEntry>> {
        self.storage.ranked_directory_members(now_unix_secs)
    }

    /// Runs a reconcile as a best-effort side effect of a write site, logging a
    /// failure instead of failing the operation that triggered it.
    ///
    /// The directory is a convenience surface: a membership change must not fail
    /// because the picker's index could not be refreshed. A deferral is silent
    /// (a commit in flight is ordinary); a genuine failure is logged, because
    /// while it persists a departed co-member keeps reading as current.
    pub(crate) async fn reconcile_member_directory_best_effort(&self, mode: DirectoryReconcile) {
        self.reconcile_member_directory_at(mode, chrono::Utc::now().timestamp())
            .await;
    }

    /// [`Self::reconcile_member_directory_best_effort`] against a caller-owned
    /// clock, single-flighted.
    ///
    /// At most one walk runs at a time. A caller that arrives while one is in
    /// progress leaves its verdict behind — folded to the STRONGEST asked for,
    /// so a withdrawal is never downgraded by an ordinary rewrite queued beside
    /// it — and returns immediately; the running walk drains the slot before it
    /// finishes. That is what collapses a commit storm (a peer leaving a circle
    /// of M produces up to M−1 competing auto-commits, each of which would
    /// otherwise walk every circle) and a catch-up backlog into one pass.
    ///
    /// A verdict picked up by an in-flight walk is reconciled against THAT
    /// walk's clock, not the queuing caller's — the two are the same wall clock
    /// in production, and only a caller that owns its clock (the leave path)
    /// passes anything else, at a moment when nothing else is running.
    async fn reconcile_member_directory_at(&self, mode: DirectoryReconcile, now_unix_secs: i64) {
        {
            let mut flight = self
                .directory_flight
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            flight.owed = Some(flight.owed.map_or(mode, |owed| owed.max(mode)));
            if flight.running {
                return;
            }
            flight.running = true;
        }
        loop {
            // `owed` is taken and `running` cleared in ONE critical section, so
            // a caller that queues a verdict either sees `running` and is
            // adopted by this walk, or finds it clear and runs the walk itself.
            // Splitting them would drop a verdict queued in the gap.
            let next = {
                let mut flight = self
                    .directory_flight
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                let taken = flight.owed.take();
                if taken.is_none() {
                    flight.running = false;
                }
                drop(flight);
                taken
            };
            let Some(next) = next else { return };
            if let Err(e) = self.reconcile_member_directory(next, now_unix_secs).await {
                log::warn!(
                    "member directory reconcile failed (retries on the next membership change): {}",
                    e.code()
                );
            }
        }
    }

    /// The directory verdict for a raw engine event batch.
    ///
    /// Records nothing. The epoch-change and inbound-observation facts have
    /// exactly ONE write site per path — the receive planes call
    /// [`Self::note_inbound_group_events`], the publish-before-apply
    /// resolution calls [`Self::note_epoch_changes`] — so that a plane doing
    /// both cannot record the same fact twice; and whether a group is
    /// unrecoverable is MDK's persisted flag, read where it is needed.
    #[allow(clippy::unused_self)]
    pub(crate) fn directory_verdict_for_events(
        &self,
        events: &[GroupEvent],
    ) -> Option<DirectoryReconcile> {
        DirectoryReconcile::for_group_events(events)
    }

    /// Records that an MLS-AUTHENTICATED inbound group event arrived for every
    /// circle named in `events`, and the epoch-change instant for each
    /// `EpochChanged` among them.
    ///
    /// Call this ONLY from a receive funnel. Two properties depend on it:
    ///
    /// * **Only authenticated events may stamp it.** An engine event batch is
    ///   the output of MLS authentication, so nothing an observer of the
    ///   circle's public `#h` can mint reaches here. Stamping on "a kind-445
    ///   arrived" instead would hand that observer a way to hold the repair gate
    ///   shut for free (`circle::rotation` gate 4).
    /// * **Only INBOUND events may stamp it.** `publish_outcome_verdict` runs
    ///   the same fold for our OWN confirm/rollback, which is why that path
    ///   calls [`Self::note_epoch_changes`] and not this.
    pub(crate) fn note_inbound_group_events(&self, events: &[GroupEvent]) {
        self.note_inbound_arrivals(events);
        self.note_epoch_changes(events);
    }

    /// The arrival half of [`Self::note_inbound_group_events`], WITHOUT the
    /// epoch-change write.
    ///
    /// Split out for the publish-resolution funnel, which reaches both facts by
    /// different routes: a DRAINED batch is ordinary inbound traffic and takes
    /// this plus `note_epoch_changes`, while the TOP-LEVEL batch of a confirm
    /// already records its own epoch change through
    /// [`Self::publish_outcome_verdict`]. Keeping each fact to exactly one
    /// write site per path is what stops a plane doing both from recording it
    /// twice.
    fn note_inbound_arrivals(&self, events: &[GroupEvent]) {
        self.note_arrivals(events.iter());
    }

    /// [`Self::note_inbound_arrivals`] over the `MessageReceived` events alone.
    ///
    /// The top-level rule (R2): a peer message replayed out of the
    /// publish-before-apply window is MLS-authenticated evidence that the peer
    /// is active, and is indistinguishable from the same message arriving a
    /// moment later — so it stamps the quiescence gate. Nothing else in that
    /// batch may: an `EpochChanged` there is this device's OWN commit being
    /// applied, and stamping on it would let every local repair hold the gate
    /// shut for itself.
    fn note_inbound_arrival_for_message_received(&self, events: &[GroupEvent]) {
        self.note_arrivals(
            events
                .iter()
                .filter(|event| matches!(event, GroupEvent::MessageReceived { .. })),
        );
    }

    /// One arrival stamp per distinct circle named in `events`.
    fn note_arrivals<'a>(&self, events: impl Iterator<Item = &'a GroupEvent>) {
        let now_ms = chrono::Utc::now().timestamp_millis();
        let mut stamped: HashSet<&GroupId> = HashSet::new();
        for event in events {
            let group_id = group_id_of(event);
            if !stamped.insert(group_id) {
                continue;
            }
            match self.storage.get_circle(group_id) {
                Ok(Some(circle)) => {
                    if let Err(e) = self
                        .storage
                        .note_inbound_group_event(&circle.nostr_group_id, now_ms)
                    {
                        log::warn!("inbound group-event observation not recorded: {}", e.code());
                    }
                }
                Ok(None) => {}
                Err(e) => log::warn!(
                    "inbound group-event observation: circle lookup failed: {}",
                    e.code()
                ),
            }
        }
    }

    /// Records the wall-clock instant of every `EpochChanged` in `events`.
    ///
    /// `EpochChanged` is the ONLY MLS-authenticated statement that a group's
    /// sender ratchets restarted, and the engine emits it from all three places
    /// an epoch can move: applying a peer's commit, confirming our own, and a
    /// convergence reorg. The folded [`LocationMessageResult::GroupUpdate`]
    /// cannot stand in for it — that variant also covers `PendingCommitRecovered`
    /// and `GroupHydrationRecovered`, neither of which resets a ratchet, and
    /// treating them as epoch changes would park a genuinely stuck circle behind
    /// gate 3 for a day for no reason.
    ///
    /// Best-effort: an unrecorded epoch change only makes the repair gate more
    /// permissive on the next tap, which the rate limit and the quiescence gate
    /// still bound.
    fn note_epoch_changes(&self, events: &[GroupEvent]) {
        let now_ms = chrono::Utc::now().timestamp_millis();
        for event in events {
            let GroupEvent::EpochChanged { group_id, .. } = event else {
                continue;
            };
            match self.storage.get_circle(group_id) {
                Ok(Some(circle)) => {
                    if let Err(e) = self
                        .storage
                        .note_epoch_change_seen(&circle.nostr_group_id, now_ms)
                    {
                        log::warn!("epoch-change observation not recorded: {}", e.code());
                    }
                }
                // A group with no circle row (a create still mid-flight, or a
                // circle already deleted) has nothing to record against.
                Ok(None) => {}
                Err(e) => log::warn!(
                    "epoch-change observation: circle lookup failed: {}",
                    e.code()
                ),
            }
        }
    }

    /// The circles MDK holds unrecoverable, as pseudonymous
    /// `nostr_group_id`s (Security Rule 4): its persisted flag, read for
    /// every circle row, so the verdict reads the same on every call and
    /// after every restart, and ends when a rejoin repairs the circle. A
    /// quarantined circle, and one whose record cannot be read, is not
    /// counted.
    pub async fn unrecoverable_circles(&self) -> Vec<[u8; 32]> {
        let quarantined = self.session.quarantined_group_ids().await;
        let mut out = Vec::new();
        for circle in self.storage.get_all_circles().unwrap_or_default() {
            if !quarantined.contains(&circle.mls_group_id)
                && self.session.unrecoverable(&circle.mls_group_id).await == Some(true)
            {
                out.push(circle.nostr_group_id);
            }
        }
        out
    }

    // ==================== Invitation Handling ====================

    /// Processes a gift-wrapped Welcome event (kind 1059) into a held pending
    /// welcome (hold-before-ingest, F3).
    ///
    /// The still-encrypted 1059 is held locally and a non-secret preview is
    /// derived via a transient peel. Pre-join, the kind-444 rumor carries only
    /// the `KeyPackage` `e` tag and the `relays` tag, and the MLS Welcome's
    /// `GroupInfo` is encrypted — so the full roster and group name are
    /// unavailable by design. The one member the preview DOES prove is the
    /// inviter, the NIP-59 seal author, and that identity is the whole of what
    /// an [`Invitation`] may claim: a roster size cannot be derived from an
    /// encrypted roster. Nothing is ingested until [`Self::accept_invitation`];
    /// declining leaves no on-wire trace (Rule 10).
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::AlreadyProcessed`] for a duplicate, or
    /// [`CircleError::Mls`] if the gift wrap cannot be peeled.
    pub async fn process_gift_wrapped_invitation(
        &self,
        _recipient_keys: &Keys,
        gift_wrap_event: &Event,
    ) -> Result<Invitation> {
        log::debug!(
            "[CircleManager] process_gift_wrapped_invitation: wrapper={} kind={}",
            log_alias::event(EventIdHex(&gift_wrap_event.id.to_hex())),
            gift_wrap_event.kind.as_u16(),
        );

        // A resolved (accepted/declined) wrap is skipped; a still-held one is a
        // no-op (the store is idempotent per gift-wrap id).
        if self
            .storage
            .is_gift_wrap_processed(&gift_wrap_event.id)?
            .is_some()
        {
            return Err(CircleError::AlreadyProcessed);
        }
        if self.pending_welcomes.contains(&gift_wrap_event.id) {
            return Err(CircleError::AlreadyProcessed);
        }

        // Peel a non-secret preview WITHOUT ingesting; the encrypted 1059 is held
        // verbatim (the decrypted welcome bytes carry MLS join secrets and are
        // never stored — F3).
        let preview = self
            .session
            .preview_welcome(gift_wrap_event)
            .await
            .map_err(|e| {
                CircleError::Mls(format!(
                    "Failed to preview welcome: {}",
                    redact_hex_sequences(&e.to_string())
                ))
            })?;
        let inviter_pubkey = preview.inviter_pubkey.clone();

        // Durable before the invitation is held: the held copy is gone after a
        // restart, and the `KeyPackage` it was made for must outlive that.
        self.pending_welcomes.insert_marked(
            PendingWelcome::new(gift_wrap_event.clone(), preview),
            |held| {
                self.storage
                    .set_held_invitation_count(self.held_to_record(held))
            },
        )?;

        let now = chrono::Utc::now().timestamp();
        Ok(Invitation {
            // Pre-join the real MLS group id is unavailable (it lives inside the
            // still-encrypted welcome). Key the invitation by the gift-wrap id as
            // a stand-in until Accept ingests and `GroupJoined` yields the real
            // id. DM-4: the Dart accept path passes the gift-wrap id.
            mls_group_id: GroupId::from_slice(gift_wrap_event.id.as_bytes()),
            circle_name: "New Circle".to_string(),
            inviter_pubkey,
            invited_at: now,
        })
    }

    /// Gets all pending invitations (from the held-welcome store).
    ///
    /// Each entry carries only what the transient peel proves — the
    /// NIP-59-seal-authenticated inviter — see
    /// [`Self::process_gift_wrapped_invitation`].
    ///
    /// # Errors
    ///
    /// Never errors; the `Result` is kept for API stability.
    pub fn get_pending_invitations(&self) -> Result<Vec<Invitation>> {
        Ok(self
            .pending_welcomes
            .previews()
            .into_iter()
            .map(|(id, preview)| Invitation {
                mls_group_id: GroupId::from_slice(id.as_bytes()),
                circle_name: "New Circle".to_string(),
                inviter_pubkey: preview.inviter_pubkey,
                invited_at: 0,
            })
            .collect())
    }

    /// Accepts an invitation to join a circle by ingesting the held welcome.
    ///
    /// Feeds the still-encrypted 1059 to the engine, which peels + joins and
    /// emits `GroupJoined` carrying the real MLS group id. Haven then
    /// materializes the circle row + accepted membership and drops the held
    /// welcome.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::NotFound`] if no welcome is held for `gift_wrap_id`,
    /// or [`CircleError::Mls`] if the join fails.
    pub async fn accept_invitation(&self, gift_wrap_id: &EventId) -> Result<CircleWithMembers> {
        let held = self
            .pending_welcomes
            .get(gift_wrap_id)
            .ok_or_else(|| CircleError::NotFound("No held welcome for invitation".to_string()))?;
        // The preview's inviter is a NIP-59 seal author, always 32 bytes of
        // hex (`inviter_from_sender`); anything else can match no welcomer.
        let inviter = hex::decode(&held.preview().inviter_pubkey).unwrap_or_default();
        // An intent already standing is an earlier accept's whose circle was
        // never recorded: recording one clears it in the same transaction.
        let unrecorded = self
            .storage
            .accept_intent_inviter(gift_wrap_id.as_bytes())?
            .is_some();
        // The user's consent, durable before the engine can join: a join
        // handed back at the next open is shown only with it.
        self.storage.record_accept_intent(gift_wrap_id, &inviter)?;

        let (group_id, effects, welcomer) = match self
            .session
            .accept_welcome(held.gift_wrap())
            .await
            .map_err(CircleError::from_session)?
        {
            WelcomeAcceptance::Ingested(ingest) => {
                let (group_id, welcomer) = ingest
                    .effects
                    .events
                    .iter()
                    .find_map(|ev| match ev {
                        GroupEvent::GroupJoined {
                            group_id, welcomer, ..
                        } => Some((group_id.clone(), Some(welcomer.clone()))),
                        _ => None,
                    })
                    .ok_or_else(|| {
                        CircleError::Mls("welcome accept did not yield a joined group".to_string())
                    })?;
                (group_id, ingest.effects, welcomer)
            }
            // An earlier accept joined, and its rows never committed: record
            // the circle now instead of telling the user to ask again. Who
            // wrote the Welcome is read from the join the engine still owes.
            WelcomeAcceptance::AlreadyJoined { group_id, effects } => {
                let via = MessageId::new(gift_wrap_id.to_bytes().to_vec());
                let welcomer = self.session.owed_joins().await.and_then(|owed| {
                    owed.into_iter()
                        .find(|join| join.via_welcome == via)
                        .map(|join| join.welcomer)
                });
                (group_id, effects, welcomer)
            }
            // Terminal: the same Welcome can never succeed, so it is resolved
            // exactly as a decline is — held copy dropped, gift wrap marked so
            // the next poll does not surface it again, nothing on the wire.
            WelcomeAcceptance::NeedsNewInvite => {
                self.resolve_invitation(gift_wrap_id);
                return Err(CircleError::NeedsNewInvite);
            }
            // Held, not declined: the Welcome stays valid for the explicit
            // replacement consent MDK requires.
            WelcomeAcceptance::RejoinConfirmationRequired => {
                return Err(CircleError::RejoinConfirmationRequired);
            }
        };
        match welcomer {
            Some(Some(welcomer)) if welcomer.as_slice() == inviter.as_slice() => {}
            Some(Some(_)) => {
                self.refuse_unconsented_join(&group_id, gift_wrap_id, &effects)
                    .await?;
                return Err(CircleError::NeedsNewInvite);
            }
            // The join is no longer owed and no earlier accept stood
            // unrecorded: it was recorded, and its record was checked.
            None if !unrecorded => {}
            // Who wrote it cannot be told now — a join no longer owed though
            // an accept stood unrecorded, or one MDK names no author for:
            // nothing is written and nothing undone.
            Some(None) | None => {
                return Err(CircleError::Storage(
                    "the inviter of a joined circle was not read".into(),
                ))
            }
        }

        let (circle, membership) = self
            .joined_circle_rows(&group_id, Some(held.preview().inviter_pubkey.clone()))
            .await?;
        let now = circle.created_at;
        // A row from before the join is a copy this Welcome replaced in place:
        // one MDK held unrecoverable, which no plane followed.
        let replaced = matches!(self.storage.get_circle(&group_id), Ok(Some(_)));

        // Atomically persist the circle + membership + dedup row, then drop the
        // held welcome (terminal).
        self.storage
            .record_processed_invitation(gift_wrap_id, &circle, &membership, now)?;
        // A joined circle carries the INVITER's routing relays, which is the
        // most common way a relay this user never chose starts seeing their
        // kind-445 — and the most likely way a profile-pool relay would get
        // contaminated. Record before the circle is usable.
        self.record_contaminated(&circle.relays, ContaminationSource::CircleRouting)?;
        self.release_invitation(gift_wrap_id);
        // The join is recorded, so the batch's persist acknowledges it, with
        // its locations, at the one persist-then-acknowledge site; a join an
        // earlier accept left owed is not in this batch, and is acknowledged
        // here.
        self.persist_replayed_locations(&effects.events).await;
        self.session
            .acknowledge_outputs(&[MessageId::new(gift_wrap_id.to_bytes().to_vec())])
            .await;
        if replaced {
            self.wake_routing_follow();
        }

        // Accepting is what makes the roster real, so it is the directory write
        // site — never the preview above, which is seal-authenticated only
        // (anyone can gift-wrap a welcome) and where a row would break
        // decline-leaves-no-trace. Placed after the storage write so the circle
        // the union is about to read is already persisted.
        self.reconcile_member_directory_best_effort(DirectoryReconcile::Rewrite)
            .await;
        // An ended circle kept for this invitation is let go of, or forgotten
        // if nothing else keeps it.
        self.forget_left_groups().await;

        self.get_circle(&group_id)
            .await?
            .ok_or_else(|| CircleError::NotFound("Circle not found after acceptance".to_string()))
    }

    /// The replacement offers MDK holds for the held invitation
    /// `gift_wrap_id` — what an accept answered
    /// [`CircleError::RejoinConfirmationRequired`] for: joining it would
    /// discard this device's still-active copy of its circle, which MDK does
    /// only on the user's explicit consent ([`Self::confirm_group_rejoin`]).
    ///
    /// An offer is matched by the gift wrap it arrived in; MDK keeps the
    /// first wrapper's id for the same content (`ingest.rs` 293-313), so one
    /// arriving in another is matched by its author, the inviter the
    /// invitation showed. An offer whose author is not that inviter, or for
    /// a circle this device has asked to leave — or whose leave MDK still
    /// holds a request for, which a rejoin would carry into the new branch
    /// (`docs/MDK_UPSTREAM_TRACKER.md` T-REJOIN-LEAVE) — is declined, with
    /// the invitation, and answered [`CircleError::NeedsNewInvite`]. Haven
    /// never joins one without the user's press.
    ///
    /// # Errors
    ///
    /// [`CircleError::NotFound`] when no such invitation is held, and as
    /// above.
    pub async fn rejoin_offers_for_invitation(
        &self,
        gift_wrap_id: &EventId,
    ) -> Result<Vec<RejoinOffer>> {
        let (inviter, offers) = self.offers_for(gift_wrap_id, None).await?;
        let mut shown = Vec::with_capacity(offers.len());
        for offer in offers {
            if offer.welcomer.as_slice() == inviter.as_slice() && !self.being_left(&offer.group_id)
            {
                shown.push(offer);
            } else {
                let _ = self.session.decline_rejoin(&offer.welcome_id).await;
                self.resolve_invitation(gift_wrap_id);
                return Err(CircleError::NeedsNewInvite);
            }
        }
        Ok(shown)
    }

    /// The user's consent to the replacement offer of the held invitation
    /// `gift_wrap_id` whose local-branch token is `local_state_token`, as
    /// [`Self::rejoin_offers_for_invitation`] showed it: the circle is joined
    /// again on the new branch, its row follows MDK's record, and the
    /// discarded copy's records go with it.
    ///
    /// # Errors
    ///
    /// [`CircleError::RejoinConfirmationRequired`] when the local branch moved
    /// since the token was read — nothing changed, and the offer is read
    /// again; [`CircleError::NeedsNewInvite`] when MDK no longer holds the
    /// offer, or [`Self::rejoin_offers_for_invitation`] would decline it; and
    /// the store's or engine's error otherwise.
    pub async fn confirm_group_rejoin(
        &self,
        gift_wrap_id: &EventId,
        local_state_token: &[u8],
    ) -> Result<CircleWithMembers> {
        let (inviter, offers) = self
            .offers_for(gift_wrap_id, Some(local_state_token))
            .await?;
        let Some(offer) = offers.into_iter().next() else {
            return Err(CircleError::RejoinConfirmationRequired);
        };
        if offer.welcomer.as_slice() != inviter.as_slice() || self.being_left(&offer.group_id) {
            let _ = self.session.decline_rejoin(&offer.welcome_id).await;
            self.resolve_invitation(gift_wrap_id);
            return Err(CircleError::NeedsNewInvite);
        }
        match self
            .session
            .confirm_rejoin(&offer, local_state_token)
            .await
            .map_err(CircleError::from_session)?
        {
            RejoinConfirmation::Joined => {}
            RejoinConfirmation::Stale => return Err(CircleError::RejoinConfirmationRequired),
            RejoinConfirmation::Gone => {
                self.resolve_invitation(gift_wrap_id);
                return Err(CircleError::NeedsNewInvite);
            }
        }
        let group_id = offer.group_id;
        let (circle, membership) = self
            .joined_circle_rows(&group_id, Some(hex::encode(&inviter)))
            .await?;
        self.storage.record_processed_invitation(
            gift_wrap_id,
            &circle,
            &membership,
            circle.created_at,
        )?;
        self.record_contaminated(&circle.relays, ContaminationSource::CircleRouting)?;
        self.release_invitation(gift_wrap_id);
        self.session
            .acknowledge_outputs(std::slice::from_ref(&offer.welcome_id))
            .await;
        // The new branch may route where the old copy did not.
        self.wake_routing_follow();
        self.reconcile_member_directory_best_effort(DirectoryReconcile::Rewrite)
            .await;
        self.forget_left_groups().await;
        self.get_circle(&group_id)
            .await?
            .ok_or_else(|| CircleError::NotFound("Circle not found after rejoin".to_string()))
    }

    /// Declines every replacement offer of the held invitation
    /// `gift_wrap_id`, and the invitation with them: redelivery opens none
    /// again, and nothing is sent.
    ///
    /// # Errors
    ///
    /// [`CircleError::NotFound`] when no such invitation is held; the
    /// engine's error when an offer could not be declined, the invitation
    /// then still held.
    pub async fn decline_group_rejoin(&self, gift_wrap_id: &EventId) -> Result<()> {
        let (_, offers) = self.offers_for(gift_wrap_id, None).await?;
        for offer in offers {
            self.session
                .decline_rejoin(&offer.welcome_id)
                .await
                .map_err(CircleError::from_session)?;
        }
        self.resolve_invitation(gift_wrap_id);
        Ok(())
    }

    /// The inviter (raw key) the held invitation `gift_wrap_id` showed, and
    /// the replacement offers that are its: the one MDK keyed by its gift
    /// wrap, else those by that inviter — and of those, when `token` is
    /// given, only the one whose local branch it names (AM-5).
    async fn offers_for(
        &self,
        gift_wrap_id: &EventId,
        token: Option<&[u8]>,
    ) -> Result<(Vec<u8>, Vec<RejoinOffer>)> {
        let held = self
            .pending_welcomes
            .get(gift_wrap_id)
            .ok_or_else(|| CircleError::NotFound("No held welcome for invitation".to_string()))?;
        let inviter = hex::decode(&held.preview().inviter_pubkey).unwrap_or_default();
        let wrap = MessageId::new(gift_wrap_id.to_bytes().to_vec());
        let mut offers = Vec::new();
        for group_id in self
            .session
            .live_group_ids()
            .await
            .map_err(CircleError::from_session)?
        {
            offers.extend(self.session.rejoin_offers(&group_id).await);
        }
        let by_wrap: Vec<RejoinOffer> = offers
            .iter()
            .filter(|offer| offer.welcome_id == wrap)
            .cloned()
            .collect();
        let mut matched = if by_wrap.is_empty() {
            offers
                .into_iter()
                .filter(|offer| offer.welcomer.as_slice() == inviter.as_slice())
                .collect()
        } else {
            by_wrap
        };
        if let Some(token) = token {
            matched.retain(|offer| offer.local_state_token.as_slice() == token);
        }
        Ok((inviter, matched))
    }

    /// Whether this device asked to leave `group_id`'s circle, or MDK still
    /// holds a leave request for it; a store that cannot say reads as yes.
    fn being_left(&self, group_id: &GroupId) -> bool {
        self.session.leaving(group_id) || self.session.leave_requested(group_id)
    }

    /// The first half of [`Self::accept_invitation`] alone — the consent
    /// recorded and the Welcome handed to the engine, which joins — as a
    /// process that died right after the engine's join leaves it.
    ///
    /// # Errors
    ///
    /// As [`Self::accept_invitation`] up to the join.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn accept_and_die_for_test(&self, gift_wrap_id: &EventId) -> Result<()> {
        let held = self
            .pending_welcomes
            .get(gift_wrap_id)
            .ok_or_else(|| CircleError::NotFound("No held welcome for invitation".to_string()))?;
        let inviter = hex::decode(&held.preview().inviter_pubkey).unwrap_or_default();
        self.storage.record_accept_intent(gift_wrap_id, &inviter)?;
        self.session
            .accept_welcome(held.gift_wrap())
            .await
            .map_err(CircleError::from_session)?;
        Ok(())
    }

    /// Undoes a join the user did not consent to: its Welcome's
    /// MLS-authenticated author is not the inviter the invitation showed.
    /// The group is forgotten, the invitation resolved as a decline, and
    /// the engine's owed join acknowledged with the rest of the batch. A
    /// circle row the join replaced a removed or unrecoverable copy under
    /// goes too, as a leave's does: nothing of that circle is left on the
    /// device to show. The `KeyPackage` the Welcome consumed stays consumed
    /// — MDK names a Welcome's author only by joining.
    ///
    /// # Errors
    ///
    /// The engine's refusal of the forget: the intent and the held
    /// invitation stand, and the next accept tries again.
    async fn refuse_unconsented_join(
        &self,
        group_id: &GroupId,
        gift_wrap_id: &EventId,
        effects: &SessionEffects,
    ) -> Result<()> {
        self.undo_unconsented_join(group_id, gift_wrap_id).await?;
        self.session
            .acknowledge_outputs(&[MessageId::new(gift_wrap_id.to_bytes().to_vec())])
            .await;
        // After the undo, so nothing of the refused join lands in a row it
        // deleted; the rest of the batch is still persisted (Rule 12).
        self.persist_replayed_locations(&effects.events).await;
        Ok(())
    }

    /// [`Self::refuse_unconsented_join`]'s undo: the group forgotten, the
    /// invitation resolved as a decline, and a row the join replaced a copy
    /// under ended as at a leave.
    ///
    /// # Errors
    ///
    /// The engine's refusal of the forget, or the store's: what is left
    /// stands for the next try.
    async fn undo_unconsented_join(
        &self,
        group_id: &GroupId,
        gift_wrap_id: &EventId,
    ) -> Result<()> {
        self.session
            .forget_group_local(group_id)
            .await
            .map_err(CircleError::from_session)?;
        self.resolve_invitation(gift_wrap_id);
        if self.storage.get_circle(group_id)?.is_some() {
            self.complete_leave(group_id, chrono::Utc::now().timestamp())
                .await?;
        }
        Ok(())
    }

    /// The circle and accepted membership rows for a group this device joined,
    /// from the engine's own record and routing (`group_record`,
    /// `group_routing`).
    async fn joined_circle_rows(
        &self,
        group_id: &GroupId,
        inviter_pubkey: Option<String>,
    ) -> Result<(Circle, CircleMembership)> {
        let (nostr_group_id, relays) = self
            .session
            .group_routing(group_id)
            .await
            .map_err(CircleError::from_session)?;
        // A Welcome naming a routing id another circle here holds has had MDK
        // give that id's route to the joined group: both are held, as for a
        // rotation onto it (`resync_circle_relays_from_mdk`).
        match self
            .other_circle_with_routing_id(&nostr_group_id, group_id, UnreadEpoch::Holds)
            .await
        {
            Ok(Some(other)) => {
                self.session
                    .note_routing_collision(&[group_id, &other])
                    .map_err(CircleError::from_session)?;
                log::warn!(
                    "a joined circle's routing id is one another circle holds; both circles' \
                     sends are held"
                );
            }
            Ok(None) => {}
            // As for a rotation (`resync_circle_relays_from_mdk`): the joined
            // circle is held, and the join is recorded; a circle the Welcome
            // took the route from is held from the next reconcile that reads
            // the store (`hold_shared`).
            Err(e) => {
                self.hold_unchecked(group_id)?;
                log::warn!(
                    "whether a joined circle's routing id is another circle's could not be read \
                     ({}); its sends are held",
                    e.code()
                );
            }
        }
        let group = self
            .session
            .group_record(group_id)
            .await
            .map_err(CircleError::from_session)?;

        let now = chrono::Utc::now().timestamp();
        let resolved_name = if group.name.is_empty() {
            "New Circle".to_string()
        } else {
            group.name
        };
        let circle = Circle {
            mls_group_id: group_id.clone(),
            nostr_group_id,
            display_name: resolved_name,
            circle_type: CircleType::LocationSharing,
            // Never topped up from the account's own relays: an empty list
            // is a circle with no relay, not a circle on the identity plane.
            relays: usable_relays(relays),
            created_at: now,
            updated_at: now,
        };
        let membership = CircleMembership {
            mls_group_id: group_id.clone(),
            status: MembershipStatus::Accepted,
            inviter_pubkey,
            invited_at: now,
            responded_at: Some(now),
        };
        Ok((circle, membership))
    }

    /// Declines an invitation: drops the held 1059 locally, with the
    /// replacement offer MDK holds for this gift wrap, if any — the offer
    /// keeps the replacement branch's decrypted state, and nothing could
    /// confirm it once the invitation is gone (Rule 5). Only the offer keyed
    /// by this wrap: one matched by its inviter may be another invitation's.
    ///
    /// The welcome is never ingested, so there is no join commit, no
    /// self-remove, nothing on the wire (Rule 10). The gift wrap is marked
    /// resolved so a re-poll does not re-surface it.
    ///
    /// # Errors
    ///
    /// The engine's error when the offer could not be declined, the
    /// invitation then still held.
    pub async fn decline_invitation(&self, gift_wrap_id: &EventId) -> Result<()> {
        let wrap = MessageId::new(gift_wrap_id.to_bytes().to_vec());
        for group_id in self
            .session
            .live_group_ids()
            .await
            .map_err(CircleError::from_session)?
        {
            for offer in self.session.rejoin_offers(&group_id).await {
                if offer.welcome_id == wrap {
                    self.session
                        .decline_rejoin(&offer.welcome_id)
                        .await
                        .map_err(CircleError::from_session)?;
                }
            }
        }
        self.resolve_invitation(gift_wrap_id);
        Ok(())
    }

    /// Drops the held invitation `gift_wrap_id` and marks it resolved, for a
    /// path that has already answered its replacement offers.
    fn resolve_invitation(&self, gift_wrap_id: &EventId) {
        self.release_invitation(gift_wrap_id);
        let _ = self.storage.clear_accept_intent(gift_wrap_id);
        let now = chrono::Utc::now().timestamp();
        // Reuse the failure-sentinel row as a "resolved, do not re-surface" mark.
        let _ = self.storage.record_gift_wrap_failure(gift_wrap_id, now);
    }

    /// Whether an invitation is being held for the user's answer — in memory
    /// now, or durably from before a restart that has not polled it back yet.
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub fn held_invitations_outstanding(&self) -> Result<bool> {
        Ok(!self.pending_welcomes.is_empty() || self.storage.held_invitation_outstanding()?)
    }

    /// Whether, at `now_secs`, the replacement of a `KeyPackage` a Welcome
    /// consumed still waits for an invitation the user holds unanswered.
    ///
    /// Replacing a consumed package deletes its private material at the first
    /// relay acknowledgement, and every other invitation made for that
    /// package would die unanswered. So the maintenance tick leaves it in
    /// place while one is held — for at most
    /// [`CONSUMED_KEY_PACKAGE_HOLD_SECS`], counted from the first call that
    /// found one held. The preview that makes Haven hold an invitation is
    /// only seal-authenticated, so a stranger can cause a hold; the bound is
    /// what stops them extending it, and an invitation that arrives later
    /// does not move it. Nor does the clock: a start that is ahead of it ends
    /// the hold, and a hold that has ended stays ended until the replacement
    /// is acknowledged. Rotation, a lost bundle and the `not_after` deletion
    /// are never held back by it.
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub fn consumed_key_package_replacement_waits(&self, now_secs: u64) -> Result<bool> {
        if !self.held_invitations_outstanding()? {
            return Ok(false);
        }
        match self.storage.consumed_hold_since()? {
            None => {
                self.storage.set_consumed_hold_since(Some(now_secs))?;
                Ok(true)
            }
            Some(CONSUMED_HOLD_OVER) => Ok(false),
            Some(since)
                if now_secs
                    .checked_sub(since)
                    .is_some_and(|waited| waited < CONSUMED_KEY_PACKAGE_HOLD_SECS) =>
            {
                Ok(true)
            }
            // Past the bound, or the clock reads earlier than the start:
            // counting again from "now" would let a clock set back keep the
            // consumed key. A failed write only lets a later clock step
            // resume the same window; it never widens it.
            Some(_) => {
                let _ = self
                    .storage
                    .set_consumed_hold_since(Some(CONSUMED_HOLD_OVER));
                Ok(false)
            }
        }
    }

    /// A replacement `KeyPackage` was acknowledged and promoted.
    ///
    /// The hold it ended is over, so a later consumption starts its own. The
    /// durable held-invitation marker goes too when nothing is held in memory
    /// — nothing held from before a restart can still open the superseded
    /// package — unless `replacement_consumed`: the package just promoted was
    /// itself consumed while its publish was in flight, and an invitation
    /// from before a restart may be the other one made for it.
    pub fn note_key_package_replaced(&self, replacement_consumed: bool) {
        // A failed clear only shortens the next hold; it never lengthens one.
        let _ = self.storage.set_consumed_hold_since(None);
        if !replacement_consumed {
            self.pending_welcomes.unmark_if_empty(|| {
                // Nothing held before the restart can open a superseded
                // package: none of it is waited for any more.
                self.held_polled_back
                    .store(true, std::sync::atomic::Ordering::Release);
                let _ = self.storage.set_held_invitation_outstanding(false);
            });
        }
    }

    /// Drops the held invitation `gift_wrap_id`, and the durable marker with
    /// the last one.
    fn release_invitation(&self, gift_wrap_id: &EventId) {
        self.pending_welcomes
            .remove_recording(gift_wrap_id, |held| {
                // A failed write only makes a consumed package wait out its
                // bounded hold; the next answer or acknowledgement clears it.
                let _ = self
                    .storage
                    .set_held_invitation_count(self.held_to_record(held));
            });
    }

    // ==================== Location Sharing ====================

    /// A location sealed in staging mode, for
    /// [`Publishing::seal_location`](crate::relay::fanout::Publishing::seal_location):
    /// whatever the engine stages on the way — an eviction its preflight
    /// commits ahead of the location, a change the pre-send drain releases —
    /// gets its durable fanout in the hold that staged it, and comes back as
    /// a handle for the driver. Nothing is handed back to be sent.
    ///
    /// A send the engine queued is answered with no event; the queued fix is
    /// discarded (the next tick carries a fresher one) and nothing is
    /// retried. Inside the wait a refused eviction earned, and for a `mode`
    /// that makes no new commit while one is due, the send is not made at
    /// all (`SessionManager::departure_holds_a_send`).
    ///
    /// The pre-send drain begins an advance only while the wake, which ends
    /// at `deadline_ms` on `clock`, still has room for one and for the send
    /// behind it; a drain cut short leaves the send to MDK's preflight, which
    /// queues it behind what is still untried.
    ///
    /// `mesh_only` is recorded with the location in the hold that seals it
    /// (`SessionManager::send_location_staging`).
    ///
    /// # Errors
    ///
    /// [`CircleError::NotFound`] for a circle this device does not hold, a
    /// store or engine failure otherwise. A deferral is not an error here.
    #[allow(
        clippy::too_many_arguments,
        reason = "one send: its circle, its fix, its instant and mode, its wake, and its carrier"
    )]
    pub(crate) async fn seal_location_staging(
        &self,
        mls_group_id: &GroupId,
        location: &LocationMessage,
        now_ms: u64,
        still: Still<'_>,
        clock: &dyn crate::relay::fanout::FanoutClock,
        deadline_ms: Option<u64>,
        mesh_only: bool,
    ) -> Result<StagedSeal> {
        let circle = self
            .storage
            .get_circle(mls_group_id)?
            .ok_or_else(|| CircleError::NotFound("Circle not found: <redacted>".to_string()))?;
        let content = location.to_string().map_err(|e| {
            CircleError::Mls(format!(
                "Failed to serialize location: {}",
                redact_hex_sequences(&e.to_string())
            ))
        })?;
        let mut seal = StagedSeal::default();

        let held = self
            .session
            .departure_holds_a_send(mls_group_id, Some(now_ms), still)
            .await
            .map_err(CircleError::from_session)?;
        if let Some((settled, held)) = held {
            self.fold_into(&mut seal, settled, now_ms, still).await;
            if held {
                seal.departure_due = true;
                return Ok(seal);
            }
        }
        // Every deferred-peel row gets its try before the send, or MDK's
        // preflight queues the send behind it. The inputs-only advance, in
        // either mode: trying a parked row makes no commit, and the full one
        // also drains the queue and the engine's maintenance, which a send
        // must not have made here.
        let room = |deadline: u64| {
            clock
                .now_ms()
                .saturating_add(cgka_engine::message_processor::BACKGROUND_CONVERGENCE_BUDGET_MS)
                .saturating_add(crate::relay::fanout::LOCATION_SEND_MS)
                <= deadline
        };
        for _ in 0..crate::nostr::mls::SEND_PEEL_DRAIN_ADVANCES {
            if !self.session.deferred_peels_due(mls_group_id).await {
                break;
            }
            if !deadline_ms.is_none_or(room) {
                seal.drain_cut = true;
                break;
            }
            let Ok(drained) = self
                .advance_as(
                    mls_group_id,
                    Disposition::Settle { now_ms },
                    &mut seal.recorded,
                )
                .await
            else {
                break;
            };
            self.fold_into(&mut seal, drained, now_ms, still).await;
        }

        let (staged, recorded) = self
            .session
            .send_location_staging(mls_group_id, content, now_ms, still, mesh_only)
            .await
            .map_err(CircleError::from_session)?;
        let Staged {
            mut effects,
            fanouts,
            proposals,
            waiting,
            ..
        } = staged;
        seal.recorded.extend(fanouts);
        seal.recorded.extend(proposals);
        seal.departure_due = waiting.contains(mls_group_id);
        let queued = !effects.queued.is_empty();
        // Taken out before the fold, which retires a location it finds in a
        // batch as one a drain released.
        let sealed = effects
            .publish
            .iter()
            .position(|work| matches!(work, PublishWork::ApplicationMessage { .. }))
            .filter(|_| !queued)
            .map(|at| effects.publish.remove(at));
        self.fold_into(&mut seal, effects, now_ms, still).await;
        if queued {
            self.discard_queued_location_intents(mls_group_id).await;
            return Ok(seal);
        }
        if sealed.is_none() && seal.departure_due {
            return Ok(seal);
        }
        let (Some(PublishWork::ApplicationMessage { msg, .. }), Some(recorded)) =
            (sealed, recorded)
        else {
            return Err(CircleError::Mls(
                "send produced no ApplicationMessage publish work".to_string(),
            ));
        };
        let event =
            SessionManager::transport_message_to_event(&msg).map_err(CircleError::from_session)?;
        // The relays are the record's: what was frozen with the event in the
        // hold that sealed it, not what the circle's row says a moment later.
        seal.sealed = Some((event, circle.nostr_group_id, recorded.relays));
        Ok(seal)
    }

    /// Folds one batch of a staging send into `seal`, advancing nothing: a
    /// send is not a resolution.
    async fn fold_into(
        &self,
        seal: &mut StagedSeal,
        effects: SessionEffects,
        now_ms: u64,
        still: Still<'_>,
    ) {
        let (folded, recorded) = self.fold_staged(effects, false, now_ms, still).await;
        seal.handed_back.results.extend(folded.results);
        seal.handed_back.proposals.extend(folded.proposals);
        seal.recorded.extend(recorded);
    }

    /// The deferred-send repair ([`Self::repair_deferred_send`]) for a plane
    /// that drives: what its advance releases — a change the user queued,
    /// the eviction of a member who left, a leave proposed again — is
    /// recorded in the hold that released it and handed to the driver.
    ///
    /// Not for a deferral whose own call recorded a commit in the circle, or
    /// held the send back for a departure: nothing is stuck then. The circle
    /// is swept — the queued fix discarded and every stored input the relay
    /// can no longer redeliver retired — and served as a plane that drives
    /// serves it ([`Self::serve_deadlines`]): the full advance, which gives
    /// a queued change its one attempt, or in [`DriveMode::FinishOnly`] the
    /// inputs-only one.
    pub(crate) async fn repair_deferred_send_staging(
        &self,
        mls_group_id: &GroupId,
        now_secs: u64,
        now_ms: u64,
        still: Still<'_>,
    ) -> (DecryptedIngest, Vec<FanoutId>) {
        // Best-effort: a circle the sweep could not clear is answered as
        // still gated by what it holds, which is read after this.
        let _ = self
            .session
            .sweep_unresolvable_inputs_for_group(mls_group_id, now_secs)
            .await;
        self.serve_deadlines(mls_group_id, now_ms, still).await
    }

    /// Gives `mls_group_id` the full advance of a plane that drives and folds
    /// what it releases, advancing no further: how a full drive stages an
    /// eviction that is due and not made
    /// (`SessionManager::evictions_left_due`). Inputs-only once the full
    /// mode `still` was decided in has ended.
    pub(crate) async fn stage_due_eviction(
        &self,
        mls_group_id: &GroupId,
        now_ms: u64,
        still: Still<'_>,
    ) -> (DecryptedIngest, Vec<FanoutId>) {
        let mut recorded = Vec::new();
        let Ok(advanced) = self
            .advance_as(
                mls_group_id,
                Disposition::Stage { now_ms, still },
                &mut recorded,
            )
            .await
        else {
            return (DecryptedIngest::default(), recorded);
        };
        let (folded, more) = self.fold_staged(advanced, false, now_ms, still).await;
        recorded.extend(more);
        (folded, recorded)
    }

    /// Forgets that the circle routed by `ngid` is caught up
    /// (`SessionManager::forget_caught_up`).
    pub(crate) fn forget_caught_up(&self, ngid: &[u8; 32]) {
        // A store that cannot say which circle is meant forgets them all.
        match self.circle_routed_by(ngid) {
            Ok(Some(circle)) => self.session.forget_caught_up(Some(&circle.mls_group_id)),
            Ok(None) => {}
            Err(_) => self.session.forget_caught_up(None),
        }
    }

    /// Records the circle routed by `ngid` as caught up in this session
    /// (`SessionManager::mark_caught_up`) — unless another routing id of
    /// the circle's is still owed its end of stored events
    /// (`awaits_eose`, by hex): a commit sealed under a prior id by a member
    /// that had not yet taken the rotation in is a branch at the circle's
    /// epoch like any other.
    pub(crate) fn note_caught_up(&self, ngid: &[u8; 32], awaits_eose: impl Fn(&str) -> bool) {
        let Ok(Some(circle)) = self.circle_routed_by(ngid) else {
            return;
        };
        if !self
            .routing_ids_of(&circle.mls_group_id)
            .iter()
            .any(|id| id != ngid && awaits_eose(&hex::encode(id)))
        {
            self.session.mark_caught_up(&circle.mls_group_id);
        }
    }

    /// Records that `relay` owes the routing id `group_id_hex` its history
    /// from `since_secs` (Security Rule 12). Whether it was recorded: a relay
    /// whose debt could not be written must stay in its REQ's coverage.
    pub(crate) fn owe_relay_floor(&self, group_id_hex: &str, relay: &str, since_secs: i64) -> bool {
        let Some(id) = routing_id_of_hex(group_id_hex) else {
            return false;
        };
        self.storage
            .owe_relay_floor(&id, relay, since_secs)
            .inspect_err(|_| log::warn!("a relay's owed floor was not recorded"))
            .is_ok()
    }

    /// The floor `relay` owes the routing id `group_id_hex`, if any. A store
    /// that cannot say answers none, said in the log.
    pub(crate) fn relay_floor(&self, group_id_hex: &str, relay: &str) -> Option<i64> {
        let id = routing_id_of_hex(group_id_hex)?;
        self.storage
            .relay_floor(&id, relay)
            .inspect_err(|_| log::warn!("a relay's owed floor was not read"))
            .ok()
            .flatten()
    }

    /// [`Self::relay_floor`], for a test.
    #[cfg(any(test, feature = "test-utils"))]
    #[must_use]
    pub fn relay_floor_for_test(&self, group_id_hex: &str, relay: &str) -> Option<i64> {
        self.relay_floor(group_id_hex, relay)
    }

    /// Ends the floor `relay` owes `group_id_hex` once a REQ it answered to
    /// its end asked from `covered_since` or earlier.
    pub(crate) fn clear_relay_floor(&self, group_id_hex: &str, relay: &str, covered_since: i64) {
        if let Some(id) = routing_id_of_hex(group_id_hex) {
            if self
                .storage
                .clear_relay_floor(&id, relay, covered_since)
                .is_err()
            {
                log::warn!("a relay's owed floor was not cleared");
            }
        }
    }

    /// Keeps `proposals` — each a proposal of this device's no record could
    /// be written for, which a fold handed back to a call that may send
    /// nothing — for the next relay drive, which sends each once as it would
    /// have sent it itself (`Publishing::send_owed`). In memory, one an
    /// event id and the newest [`OWED_PROPOSALS_CAP`]: one a process's end
    /// or the cap loses, the engine proposes again at its circle's next
    /// epoch.
    pub(crate) fn owe_proposals(&self, proposals: Vec<Event>) {
        owe(
            &mut self
                .owed_proposals
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner),
            proposals,
        );
    }

    /// What [`Self::owe_proposals`] kept, taken.
    pub(crate) fn take_owed_proposals(&self) -> Vec<Event> {
        std::mem::take(
            &mut *self
                .owed_proposals
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner),
        )
    }

    /// Adds what the mesh counted to its stored totals (plan §7.5): updates
    /// from this device's circles a mesh drive read, and packets the mesh
    /// engine passed on. Once a drive, never per packet, and nothing when
    /// there is nothing to add. A write that fails loses what was counted
    /// since the last one, as a kill would; a total never decreases.
    pub fn fold_mesh_counts(&self, from_circles: u64, passed_on: u64) {
        if from_circles != 0 || passed_on != 0 {
            let _ = self.storage.add_mesh_counts(from_circles, passed_on);
        }
    }

    /// The mesh's counts, to show: exact numbers, logged nowhere.
    ///
    /// # Errors
    ///
    /// Returns an error if the store cannot be read.
    pub fn mesh_counts(&self) -> Result<super::MeshCounts> {
        self.storage.mesh_counts()
    }

    /// The circle a `kind:445` event is addressed to, by its `#h` tag: what
    /// the event claims, before anything about it is authenticated.
    pub(crate) fn group_of_event(&self, event: &Event) -> Option<GroupId> {
        let ngid = nostr_group_id_from_commit_event(event)?;
        self.circle_routed_by(&ngid)
            .ok()
            .flatten()
            .map(|circle| circle.mls_group_id)
    }

    /// Discards the circle's queued location intents, or `0` if the store
    /// cannot be written.
    ///
    /// Best-effort for the same reason every other step of a deferral is: the
    /// outcome must stay an actionable "sharing is stalled" signal, never be
    /// replaced by an unrelated storage error.
    async fn discard_queued_location_intents(&self, mls_group_id: &GroupId) -> usize {
        self.session
            .discard_queued_location_intents(mls_group_id)
            .await
            .unwrap_or_else(|e| {
                log::warn!(
                    "deferred send: discarding the queued location intent failed: {}",
                    e.code()
                );
                0
            })
    }

    /// Gives a terminal disposition to stored convergence inputs the relay can
    /// no longer redeliver, across every circle, and reports what is still
    /// gating outbound sends.
    ///
    /// The manual counterpart to the sweep that already runs at session open:
    /// this is the entrypoint a "repair sharing" affordance calls. `now_secs`
    /// is the wall clock in Unix seconds.
    ///
    /// # Errors
    ///
    /// Returns an error if the MLS message store cannot be read or written.
    pub async fn sweep_unresolvable_inputs(&self, now_secs: u64) -> Result<ConvergenceSweep> {
        self.session
            .sweep_unresolvable_inputs(now_secs)
            .await
            .map_err(CircleError::from_session)
    }

    /// The group relays a `kind:445` routes to, resolved from its `#h`
    /// (`nostr_group_id`) tag against the local circle rows.
    ///
    /// Used by the fanout driver to send a proposal no record could be
    /// written for to its circle's relays. Returns `None` (fail closed — the
    /// proposal is then sent nowhere) when the `#h` tag is absent/malformed
    /// or no local circle matches.
    #[must_use]
    pub fn relays_for_commit_event(&self, event: &Event) -> Option<Vec<String>> {
        let ngid = nostr_group_id_from_commit_event(event)?;
        self.circle_routed_by(&ngid)
            .ok()
            .flatten()
            .map(|c| c.relays)
    }

    // ==================== Last-Known Location Cache ====================

    /// The circle's public `nostr_group_id` for an MLS group id, or `None` when
    /// this device holds no circle row for it.
    pub(crate) fn nostr_group_id_for(&self, group_id: &GroupId) -> Option<[u8; 32]> {
        self.storage
            .get_circle(group_id)
            .ok()
            .flatten()
            .map(|circle| circle.nostr_group_id)
    }

    /// Persists every decrypted peer location in an engine batch as a
    /// last-known-location row.
    ///
    /// The ONE persist site every receive plane shares, and the one place MDK's
    /// application outputs are acknowledged: only after their rows commit, so
    /// an output whose row failed — or whose process died first — is handed
    /// back at the next open instead of lost.
    ///
    /// Three filters, in this order:
    ///
    /// * the ngid comes from each event's OWN `group_id`, never an ambient one:
    ///   a `SessionEffects` drains GLOBAL engine buffers, so one batch can span
    ///   circles and an ambient key would file a peer under the wrong one;
    /// * a self-echo is dropped against the non-locking
    ///   [`SessionManager::identity_pubkey`], which is byte-identical to the
    ///   MLS-authenticated `sender` and lowercase-hex on both sides;
    /// * a sender the circle's CURRENT roster no longer names is skipped — the
    ///   departed-member pin Haven already evicts everywhere else. If the roster
    ///   read itself FAILS the location is persisted anyway: a transient read
    ///   error must never cost a legitimate offline backlog (Rule 12), and the
    ///   display layer still gates.
    ///
    /// And the one site every plane's circle row follows the routing a
    /// commit of the batch applied ([`Self::resync_updated_circles`]).
    async fn persist_locations_from_events(&self, events: &[GroupEvent]) -> RosterDeclined {
        let mut declined = RosterDeclined::default();
        let mut handled: Vec<crate::nostr::mls::types::MessageId> = Vec::new();
        let own_hex = self.session.identity_pubkey().to_hex();
        // One roster read per distinct group per batch. `None` records a read
        // that FAILED, which is the fail-open case, not an empty roster.
        let mut rosters: HashMap<GroupId, Option<HashSet<String>>> = HashMap::new();
        let mut joined_any = false;
        for event in events {
            match event {
                GroupEvent::MessageReceived { message_id, .. } => {
                    if self
                        .persist_one_location(event, &own_hex, &mut rosters, &mut declined)
                        .await
                    {
                        handled.push(message_id.clone());
                    }
                }
                GroupEvent::GroupJoined {
                    group_id,
                    via_welcome,
                    welcomer,
                    ..
                } => match self
                    .record_unrecorded_join(group_id, via_welcome, welcomer.as_ref())
                    .await
                {
                    JoinRecord::Materialized => {
                        joined_any = true;
                        handled.push(via_welcome.clone());
                    }
                    JoinRecord::Recorded => handled.push(via_welcome.clone()),
                    JoinRecord::Owed => {}
                },
                GroupEvent::GroupStateChanged {
                    group_id,
                    change: GroupStateChange::GroupDisbanded,
                    ..
                } => self.reconcile_disbanded(group_id).await,
                _ => {}
            }
        }
        // Only now, with the rows committed: an output whose row failed stays
        // owed, so MDK hands it back at the next open rather than losing it.
        self.session.acknowledge_outputs(&handled).await;
        if joined_any {
            self.reconcile_member_directory_best_effort(DirectoryReconcile::Rewrite)
                .await;
        }
        // A commit in the batch may have moved the circle's routing: the row
        // follows here, before the caller collects what the engine staged on
        // the way — a commit sealed under a rotated routing id is owed under
        // the id the row then names.
        let updated: Vec<LocationMessageResult> = events
            .iter()
            .filter_map(SessionManager::location_result_from_event)
            .collect();
        self.resync_updated_circles(&updated).await;
        declined
    }

    /// Makes sure a `GroupJoined` the user consented to has its circle.
    ///
    /// A join MDK handed back at an open because the accept that made it died
    /// before its rows committed would otherwise leave the user a member the
    /// app never shows — and the next accept of the same invitation a repeat
    /// MDK refuses. Consent is the accept intent recorded for its gift wrap
    /// (`via_welcome`, the Welcome's transport id): the engine joins any
    /// Welcome it is handed, so a join with no intent — a Welcome nobody
    /// accepted, or a circle since left whose join was handed back again — is
    /// acknowledged and kept hidden, never turned into a circle that would be
    /// sent the user's location.
    async fn record_unrecorded_join(
        &self,
        group_id: &GroupId,
        via_welcome: &crate::nostr::mls::types::MessageId,
        welcomer: Option<&MemberId>,
    ) -> JoinRecord {
        // Read first: a standing intent means the join's circle was never
        // recorded, whatever row a replaced copy left — recording one clears
        // the intent in the same transaction.
        let inviter = match self.storage.accept_intent_inviter(via_welcome.as_slice()) {
            Ok(Some(inviter)) => inviter,
            Ok(None) => return JoinRecord::Recorded,
            Err(_) => return JoinRecord::Owed,
        };
        if self.storage.get_circle(group_id).is_err() {
            return JoinRecord::Owed;
        }
        // A group since left or lost is no circle to show: the join is spent.
        if !self.session.group_is_live(group_id).await {
            return JoinRecord::Recorded;
        }
        // Consent was given to the inviter the invitation showed: a Welcome
        // someone else wrote is undone, as at the accept. One MDK names no
        // author for is not known yet, and stays owed.
        let Some(welcomer) = welcomer else {
            return JoinRecord::Owed;
        };
        if welcomer.as_slice() != inviter.as_slice() {
            let Ok(gift_wrap_id) = EventId::from_slice(via_welcome.as_slice()) else {
                return JoinRecord::Owed;
            };
            return match self.undo_unconsented_join(group_id, &gift_wrap_id).await {
                Ok(()) => JoinRecord::Recorded,
                Err(_) => JoinRecord::Owed,
            };
        }
        let Ok((circle, membership)) = self.joined_circle_rows(group_id, None).await else {
            return JoinRecord::Owed;
        };
        if self
            .storage
            .record_joined_circle(&circle, &membership, via_welcome.as_slice())
            .is_err()
            || self
                .record_contaminated(&circle.relays, ContaminationSource::CircleRouting)
                .is_err()
        {
            return JoinRecord::Owed;
        }
        JoinRecord::Materialized
    }

    /// Persists what the engine handed back at this session's open — every
    /// output an earlier process never acknowledged — through the shared
    /// persist site. Run once per session, by the first receive plane, before
    /// it reads the circle list, so a join recovered here is swept with the
    /// rest.
    pub async fn recover_owed_outputs(&self) {
        let owed = self.session.drain().await;
        self.persist_replayed_locations(&owed.events).await;
        self.sweep_orphaned_groups().await;
        if let Ok(circles) = self.storage.get_all_circles() {
            for circle in circles {
                if self.session.disbanded(&circle.mls_group_id).await {
                    self.reconcile_disbanded(&circle.mls_group_id).await;
                }
            }
        }
    }

    /// Persists one `MessageReceived` if it is a peer location this device
    /// keeps, and reports whether it is fully handled — persisted, or one Haven
    /// keeps no row for by design. `false` only when the row failed to write.
    async fn persist_one_location(
        &self,
        event: &GroupEvent,
        own_hex: &str,
        rosters: &mut HashMap<GroupId, Option<HashSet<String>>>,
        declined: &mut RosterDeclined,
    ) -> bool {
        let Some(LocationMessageResult::Location {
            sender_pubkey,
            content,
            group_id,
            ..
        }) = SessionManager::location_result_from_event(event)
        else {
            return true;
        };
        if sender_pubkey == own_hex {
            return true;
        }
        let Some(nostr_group_id) = self.nostr_group_id_for(&group_id) else {
            return true;
        };
        if !rosters.contains_key(&group_id) {
            let roster = self
                .session
                .member_pubkeys(&group_id)
                .await
                .ok()
                .map(|members| members.into_iter().collect::<HashSet<String>>());
            rosters.insert(group_id.clone(), roster);
        }
        if rosters
            .get(&group_id)
            .and_then(Option::as_ref)
            .is_some_and(|roster| !roster.contains(&sender_pubkey))
        {
            // Recorded, not merely skipped: the CALLER has to drop the same
            // one from what it hands back, or the pin this refused to write
            // arrives across the FFI and is written by the other side.
            declined.reject(&group_id, &sender_pubkey);
            return true;
        }
        let Ok(msg) = serde_json::from_str::<LocationMessage>(&content) else {
            return true;
        };
        let row = super::LastKnownLocation {
            nostr_group_id,
            sender_pubkey,
            latitude: msg.latitude,
            longitude: msg.longitude,
            geohash: msg.geohash,
            display_name: msg.display_name,
            timestamp: msg.timestamp.timestamp(),
            expires_at: msg.expires_at.timestamp(),
            purge_after: 0, // recomputed authoritatively by upsert
            updated_at: chrono::Utc::now().timestamp(),
        };
        if let Err(e) = self.upsert_last_known_location(&row) {
            log::warn!("replayed peer location not persisted: {}", e.code());
            return false;
        }
        true
    }

    /// [`Self::persist_and_fold`]'s persist half, for a plane that routes raw
    /// engine events and folds no results of its own (the catch-up sweep).
    ///
    /// The roster refusals go with it: there is no second half here for them to
    /// be applied to.
    pub(crate) async fn persist_replayed_locations(&self, events: &[GroupEvent]) {
        let _ = self.persist_locations_from_events(events).await;
    }

    /// Persists a batch and returns each event's own result for a plane that
    /// routes per event (the live plane), minus the fixes of senders the
    /// circle's roster no longer names — the same single roster decision
    /// [`Self::persist_and_fold`] applies, so a departed member's fix is
    /// neither stored nor put on anyone's map.
    pub(crate) async fn persist_for_routing(
        &self,
        events: &[GroupEvent],
    ) -> Vec<LocationMessageResult> {
        let declined = self.persist_locations_from_events(events).await;
        events
            .iter()
            .filter_map(SessionManager::location_result_from_event)
            .filter(|result| !declined.rejects(result))
            .collect()
    }

    /// Persists a batch's locations and folds the batch, with the ROSTER
    /// decision applied once to both halves.
    ///
    /// One decision, one place. Filtering only the persist would leave the
    /// departed member's fix in the results the caller hands across the FFI,
    /// where the other side writes it to its own store — the filter undone one
    /// layer up. Fail-OPEN is preserved exactly: a roster read that FAILED
    /// declines nothing, so the location is both persisted and returned.
    async fn persist_and_fold(&self, events: &[GroupEvent]) -> Vec<LocationMessageResult> {
        let declined = self.persist_locations_from_events(events).await;
        fold_group_events(events)
            .into_iter()
            .filter(|result| !declined.rejects(result))
            .collect()
    }

    /// Persists a last-known-location row (authoritative retention-window and
    /// display-name sanitization enforcement point).
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn upsert_last_known_location(&self, location: &super::LastKnownLocation) -> Result<()> {
        let retention_i64 =
            i64::try_from(crate::location::LOCATION_RETENTION_SECS).unwrap_or(i64::MAX);
        let derived_purge_after = location.timestamp.saturating_add(retention_i64);

        // Under the id the circle's row names now, whatever id the caller
        // read it under; an id no circle holds writes nothing.
        let Some(circle) = self.circle_routed_by(&location.nostr_group_id)? else {
            return Ok(());
        };
        let mut clamped = location.clone();
        clamped.nostr_group_id = circle.nostr_group_id;
        clamped.purge_after = derived_purge_after;
        clamped.display_name = crate::directory::sanitize_display_name(clamped.display_name);

        self.storage.upsert_last_known_location(&clamped)
    }

    /// Returns all non-purged last-known locations for a circle (display names
    /// re-sanitized on read).
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn snapshot_last_known_for_circle(
        &self,
        nostr_group_id: &[u8; 32],
        now_unix_secs: i64,
    ) -> Result<Vec<super::LastKnownLocation>> {
        let mut rows = self
            .storage
            .snapshot_last_known_for_circle(nostr_group_id, now_unix_secs)?;
        for row in &mut rows {
            row.display_name = crate::directory::sanitize_display_name(row.display_name.take());
        }
        Ok(rows)
    }

    // ==================== Delivery Health ====================

    /// Records a relay-acknowledged location publish for a circle (presence only).
    ///
    /// The three delivery-health entries take whatever routing id the caller
    /// read the circle under and act on the circle it routes to, under the id
    /// its row names now: a stamp made with an id a rotation has since moved
    /// lands on the circle, never on an orphan row, and an id no circle holds
    /// writes nothing.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn note_publish_acked(&self, nostr_group_id: &[u8; 32], at_ms: i64) -> Result<()> {
        match self.circle_routed_by(nostr_group_id)? {
            Some(circle) => self
                .storage
                .note_publish_acked(&circle.nostr_group_id, at_ms),
            None => Ok(()),
        }
    }

    /// Records a decrypted, persisted peer location for a circle (presence
    /// only).
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn note_peer_event(&self, nostr_group_id: &[u8; 32], at_ms: i64) -> Result<()> {
        match self.circle_routed_by(nostr_group_id)? {
            Some(circle) => self.storage.note_peer_event(&circle.nostr_group_id, at_ms),
            None => Ok(()),
        }
    }

    /// Reads a circle's delivery-health timestamps. A circle held for a
    /// routing collision reads as unknown, with no instant: the row under the
    /// shared id is either circle's to have written.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn circle_health(&self, nostr_group_id: &[u8; 32]) -> Result<super::CircleHealth> {
        match self.circle_routed_by(nostr_group_id)? {
            Some(circle) => self.storage.circle_health(&circle.nostr_group_id),
            None => Ok(super::CircleHealth::default()),
        }
    }

    /// Reads a circle's epoch-rotation stamps.
    ///
    /// Test-only. A harness that steps a policy clock must compute what a
    /// rotation gate will decide from the stamps the WRITE side actually
    /// recorded — which it stamps from real time
    /// ([`Self::note_inbound_group_events`], `note_epoch_changes`,
    /// [`Self::confirm_fanout`]) — and never from the offset it applied,
    /// because the two are different clocks. The stamps are milliseconds and the
    /// gates take seconds; convert at the call site.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn circle_rotation_state(
        &self,
        nostr_group_id: &[u8; 32],
    ) -> Result<super::CircleRotationState> {
        self.storage.circle_rotation_state(nostr_group_id)
    }

    /// Removes the last-known location for a single sender in a circle.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn remove_last_known_member(
        &self,
        nostr_group_id: &[u8; 32],
        sender_pubkey: &str,
    ) -> Result<()> {
        self.storage
            .remove_last_known_member(nostr_group_id, sender_pubkey)
    }

    /// Removes every last-known location row for a circle.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn remove_last_known_circle(&self, nostr_group_id: &[u8; 32]) -> Result<()> {
        self.storage.remove_last_known_circle(nostr_group_id)
    }

    /// Wipes every last-known location row.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn wipe_all_last_known_locations(&self) -> Result<()> {
        self.storage.wipe_all_last_known_locations()
    }

    /// Deletes every row whose `purge_after < now_unix_secs`.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn prune_expired_last_known(&self, now_unix_secs: i64) -> Result<usize> {
        self.storage.prune_expired_last_known(now_unix_secs)
    }

    // ==================== Sync Cursors ====================

    /// Reads the persisted relay sync cursor (raw ms) for `stream`.
    ///
    /// # Errors
    ///
    /// Propagates storage errors.
    pub fn read_sync_cursor(&self, stream: &str) -> Result<Option<i64>> {
        self.storage.read_sync_cursor(stream)
    }

    /// Seeds `stream`'s cursor to `ms` only if it is currently unseeded.
    ///
    /// # Errors
    ///
    /// Propagates storage errors.
    pub fn seed_sync_cursor_if_unset(&self, stream: &str, ms: i64) -> Result<()> {
        self.storage.seed_sync_cursor_if_unset(stream, ms)
    }

    /// Advances `stream`'s cursor to `ms` (monotonic max; never backward).
    ///
    /// # Errors
    ///
    /// Propagates storage errors.
    pub fn advance_sync_cursor(&self, stream: &str, ms: i64) -> Result<()> {
        self.storage.update_sync_cursor_max(stream, ms)
    }

    /// Lowers `stream`'s cursor to `ms` if it is currently ABOVE it (monotonic
    /// min). Returns whether a row changed.
    ///
    /// The only sanctioned backward move, and only for repairing a cursor
    /// parked in the future — see
    /// [`CircleStorage::clamp_sync_cursor_down_to`] for why the normal advance
    /// path can never undo one.
    ///
    /// # Errors
    ///
    /// Propagates storage errors.
    pub fn clamp_sync_cursor_down_to(&self, stream: &str, ms: i64) -> Result<bool> {
        self.storage.clamp_sync_cursor_down_to(stream, ms)
    }

    /// Resets `stream`'s cursor to the unseeded state.
    ///
    /// # Errors
    ///
    /// Propagates storage errors.
    pub fn reset_sync_cursor(&self, stream: &str) -> Result<()> {
        self.storage.reset_sync_cursor(stream)
    }

    /// Removes ALL sync-cursor rows — and the catch-up backfill floors derived
    /// from them — for the wipe-on-logout path.
    ///
    /// # Errors
    ///
    /// Returns an error if the storage write fails.
    pub fn reset_all_sync_cursors(&self) -> Result<()> {
        self.storage.reset_all_sync_cursors()
    }

    /// Reads `stream`'s catch-up backfill floor (unix seconds), if any.
    ///
    /// # Errors
    ///
    /// Propagates storage errors.
    pub fn read_backfill_floor(&self, stream: &str) -> Result<Option<i64>> {
        self.storage.read_backfill_floor(stream)
    }

    /// Installs or lowers `stream`'s catch-up backfill floor (monotonic min).
    ///
    /// # Errors
    ///
    /// Propagates storage errors.
    pub fn lower_backfill_floor(&self, stream: &str, secs: i64) -> Result<()> {
        self.storage.lower_backfill_floor(stream, secs)
    }

    /// Clears `stream`'s catch-up backfill floor.
    ///
    /// # Errors
    ///
    /// Propagates storage errors.
    pub fn clear_backfill_floor(&self, stream: &str) -> Result<()> {
        self.storage.clear_backfill_floor(stream)
    }

    /// Prunes the `processed_gift_wraps` dedup cache. Returns the number removed.
    ///
    /// # Errors
    ///
    /// Returns an error if the storage write fails.
    pub fn prune_processed_gift_wraps(&self, now_secs: i64) -> Result<u64> {
        self.storage.prune_processed_gift_wraps(now_secs)
    }

    /// Removes ALL `processed_gift_wraps` rows (wipe-on-logout).
    ///
    /// # Errors
    ///
    /// Returns an error if the storage write fails.
    pub fn wipe_all_processed_gift_wraps(&self) -> Result<()> {
        self.storage.wipe_all_processed_gift_wraps()
    }

    // ==================== Relay Preferences ====================

    /// See [`CircleStorage::seed_defaults_if_unseeded`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn seed_relay_defaults_if_unseeded(&self) -> Result<bool> {
        self.storage.seed_defaults_if_unseeded()
    }

    /// See [`CircleStorage::list_user_relays`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn list_user_relays(
        &self,
        relay_type: super::relay_prefs::RelayType,
    ) -> Result<Vec<String>> {
        self.storage.list_user_relays(relay_type)
    }

    /// See [`CircleStorage::add_user_relay`].
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::InvalidRelayInput`] for malformed URLs and
    /// database errors otherwise.
    pub fn add_user_relay(
        &self,
        url: &str,
        relay_type: super::relay_prefs::RelayType,
    ) -> Result<()> {
        self.storage.add_user_relay(url, relay_type)
    }

    /// See [`CircleStorage::remove_user_relay`].
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::InvalidRelayInput`] when the URL is invalid
    /// ([`RelayInputRejection::LastInCategory`] when the removal would empty the
    /// category). Database errors otherwise.
    pub fn remove_user_relay(
        &self,
        url: &str,
        relay_type: super::relay_prefs::RelayType,
    ) -> Result<bool> {
        self.storage.remove_user_relay(url, relay_type)
    }

    /// See [`CircleStorage::restore_defaults_for`] (non-destructive).
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn restore_relay_defaults_for(
        &self,
        relay_type: super::relay_prefs::RelayType,
    ) -> Result<()> {
        self.storage.restore_defaults_for(relay_type)
    }

    /// See [`CircleStorage::wipe_and_reset_defaults_for`] (destructive).
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn wipe_and_reset_relay_defaults_for(
        &self,
        relay_type: super::relay_prefs::RelayType,
    ) -> Result<()> {
        self.storage.wipe_and_reset_defaults_for(relay_type)
    }

    /// See [`CircleStorage::get_publish_kp_relay_list`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn get_publish_kp_relay_list(&self) -> Result<bool> {
        self.storage.get_publish_kp_relay_list()
    }

    /// See [`CircleStorage::set_publish_kp_relay_list`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn set_publish_kp_relay_list(&self, value: bool) -> Result<()> {
        self.storage.set_publish_kp_relay_list(value)
    }

    /// See [`CircleStorage::get_publish_inbox_relay_list`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn get_publish_inbox_relay_list(&self) -> Result<bool> {
        self.storage.get_publish_inbox_relay_list()
    }

    /// See [`CircleStorage::set_publish_inbox_relay_list`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn set_publish_inbox_relay_list(&self, value: bool) -> Result<()> {
        self.storage.set_publish_inbox_relay_list(value)
    }

    /// See [`CircleStorage::record_published_event`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn record_published_event(
        &self,
        kind: u16,
        d_tag: &str,
        event_id: &nostr::EventId,
        pubkey: &nostr::PublicKey,
        published_at: i64,
    ) -> Result<()> {
        self.storage
            .record_published_event(kind, d_tag, event_id, pubkey, published_at)
    }

    /// See [`CircleStorage::last_published_event`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn last_published_event(
        &self,
        kind: u16,
        d_tag: &str,
        pubkey: &nostr::PublicKey,
    ) -> Result<Option<super::storage_relay_prefs::PublishedEventRecord>> {
        self.storage.last_published_event(kind, d_tag, pubkey)
    }

    // ==================== KeyPackage maintenance (storage) ====================

    /// See [`CircleStorage::kp_slot_retirement_done`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn kp_slot_retirement_done(&self) -> Result<bool> {
        self.storage.kp_slot_retirement_done()
    }

    /// See [`CircleStorage::mark_kp_slot_retirement_done`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn mark_kp_slot_retirement_done(&self) -> Result<()> {
        self.storage.mark_kp_slot_retirement_done()
    }

    // ==================== Public-profile cache (storage) ====================

    /// The lock every own-profile PUBLISH and RETRACTION must hold for its whole
    /// body.
    ///
    /// [`Self::sync_own_profile`] takes it internally. The retraction paths live
    /// in the FFI layer (they build the blank kind-0 and the NIP-09 deletion),
    /// so they take it through this accessor — BEFORE their
    /// `has_published_profile` gate read, or the gate would be evaluated against
    /// state an in-flight sync is about to change.
    ///
    /// Skipping it re-opens the resurrection race: a sync that started before a
    /// retraction would republish the deleted metadata with a NEWER
    /// `created_at`, so relays would serve the profile the user just deleted
    /// while every local check reported the delete had succeeded.
    #[must_use]
    pub const fn profile_sync_lock(&self) -> &tokio::sync::Mutex<()> {
        &self.profile_sync_lock
    }

    /// See [`CircleStorage::stage_own_profile_edits`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn stage_own_profile_edits(
        &self,
        pubkey_hex: &str,
        edits: &crate::profile::PendingEdits,
        now: i64,
    ) -> Result<crate::profile::CachedProfile> {
        self.storage.stage_own_profile_edits(pubkey_hex, edits, now)
    }

    /// See [`CircleStorage::stage_own_profile_picture`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn stage_own_profile_picture(
        &self,
        pubkey_hex: &str,
        picture: &crate::avatar::StagedPicture,
        now: i64,
    ) -> Result<()> {
        self.storage
            .stage_own_profile_picture(pubkey_hex, picture, now)
    }

    /// See [`CircleStorage::pending_profile_sync`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn pending_profile_sync(
        &self,
        pubkey_hex: &str,
    ) -> Result<Option<crate::profile::PendingSnapshot>> {
        self.storage.pending_profile_sync(pubkey_hex)
    }

    /// See [`CircleStorage::commit_profile_sync`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn commit_profile_sync(
        &self,
        commit: &super::storage_profile_sync::ProfileSyncCommit<'_>,
    ) -> Result<crate::profile::CachedProfile> {
        self.storage.commit_profile_sync(commit)
    }

    /// See [`CircleStorage::record_profile_sync_attempt`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn record_profile_sync_attempt(&self, pubkey_hex: &str, now: i64) -> Result<()> {
        self.storage.record_profile_sync_attempt(pubkey_hex, now)
    }

    /// See [`CircleStorage::profile_pending_state`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn profile_pending_state(
        &self,
        pubkey_hex: &str,
        now: i64,
    ) -> Result<super::storage_profile_sync::ProfilePendingState> {
        self.storage.profile_pending_state(pubkey_hex, now)
    }

    /// See [`CircleStorage::profile_picture_is_staged`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn profile_picture_is_staged(&self, pubkey_hex: &str) -> Result<bool> {
        self.storage.profile_picture_is_staged(pubkey_hex)
    }

    /// See [`CircleStorage::cancel_staged_profile_picture`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn cancel_staged_profile_picture(&self, pubkey_hex: &str) -> Result<()> {
        self.storage.cancel_staged_profile_picture(pubkey_hex)
    }

    /// See [`CircleStorage::clear_profile_sync_state`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn clear_profile_sync_state(&self, pubkey_hex: &str) -> Result<()> {
        self.storage.clear_profile_sync_state(pubkey_hex)
    }

    /// See [`CircleStorage::upsert_profile`], including why the row is returned
    /// as STORED rather than as assembled.
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn upsert_profile(
        &self,
        cached: &crate::profile::CachedProfile,
    ) -> Result<crate::profile::CachedProfile> {
        self.storage.upsert_profile(cached)
    }

    /// See [`CircleStorage::upsert_profile_if_newer`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn upsert_profile_if_newer(&self, cached: &crate::profile::CachedProfile) -> Result<bool> {
        self.storage.upsert_profile_if_newer(cached)
    }

    /// See [`CircleStorage::get_profile`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn get_profile(&self, pubkey_hex: &str) -> Result<Option<crate::profile::CachedProfile>> {
        self.storage.get_profile(pubkey_hex)
    }

    /// See [`CircleStorage::get_profiles`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn get_profiles(
        &self,
        pubkeys_hex: &[String],
    ) -> Result<Vec<crate::profile::CachedProfile>> {
        self.storage.get_profiles(pubkeys_hex)
    }

    /// See [`CircleStorage::profiles_due`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn profiles_due(
        &self,
        pubkeys_hex: &[String],
        now_unix_secs: i64,
        max_age_secs: i64,
    ) -> Result<Vec<(String, u8)>> {
        self.storage
            .profiles_due(pubkeys_hex, now_unix_secs, max_age_secs)
    }

    /// See [`CircleStorage::profile_retry_due`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn profile_retry_due(&self, pubkey_hex: &str, now_unix_secs: i64) -> Result<bool> {
        self.storage.profile_retry_due(pubkey_hex, now_unix_secs)
    }

    /// See [`CircleStorage::touch_profiles_hit`].
    ///
    /// Pairs with [`Self::record_profile_misses`]: under one-relay-per-member
    /// assignment the hit/miss split is load-bearing, so callers must never
    /// collapse the two back into a single "stamp every attempted author" call
    /// (the deleted `touch_profiles_fetched_at`) — that is what pinned a member
    /// `Unknown` for a whole staleness tier after one relay's miss.
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn touch_profiles_hit(&self, pubkeys_hex: &[String], now_unix_secs: i64) -> Result<()> {
        self.storage.touch_profiles_hit(pubkeys_hex, now_unix_secs)
    }

    /// See [`CircleStorage::record_profile_misses`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn record_profile_misses(&self, pubkeys_hex: &[String], now_unix_secs: i64) -> Result<()> {
        self.storage
            .record_profile_misses(pubkeys_hex, now_unix_secs)
    }

    /// See [`CircleStorage::upsert_profile_picture`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn upsert_profile_picture(
        &self,
        pubkey_hex: &str,
        url: &str,
        sha256: &[u8],
        canonical: &[u8],
        thumbnail: &[u8],
        updated_at: i64,
    ) -> Result<()> {
        self.storage
            .upsert_profile_picture(pubkey_hex, url, sha256, canonical, thumbnail, updated_at)
    }

    /// See [`CircleStorage::get_profile_thumbnail`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn get_profile_thumbnail(
        &self,
        pubkey_hex: &str,
    ) -> Result<Option<zeroize::Zeroizing<Vec<u8>>>> {
        self.storage.get_profile_thumbnail(pubkey_hex)
    }

    /// See [`CircleStorage::get_profile_picture`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn get_profile_picture(
        &self,
        pubkey_hex: &str,
    ) -> Result<Option<zeroize::Zeroizing<Vec<u8>>>> {
        self.storage.get_profile_picture(pubkey_hex)
    }

    /// See [`CircleStorage::get_profile_picture_url`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn get_profile_picture_url(&self, pubkey_hex: &str) -> Result<Option<String>> {
        self.storage.get_profile_picture_url(pubkey_hex)
    }

    /// See [`CircleStorage::get_profile_picture_sha256_hex`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn get_profile_picture_sha256_hex(&self, pubkey_hex: &str) -> Result<Option<String>> {
        self.storage.get_profile_picture_sha256_hex(pubkey_hex)
    }

    /// See [`CircleStorage::has_current_picture`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn has_current_picture(&self, pubkey_hex: &str, current_url: Option<&str>) -> Result<bool> {
        self.storage.has_current_picture(pubkey_hex, current_url)
    }

    /// See [`CircleStorage::delete_profile_picture`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn delete_profile_picture(&self, pubkey_hex: &str) -> Result<()> {
        self.storage.delete_profile_picture(pubkey_hex)
    }

    /// See [`CircleStorage::has_published_profile`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn has_published_profile(&self, pubkey: &PublicKey) -> Result<bool> {
        self.storage.has_published_profile(pubkey)
    }

    /// See [`CircleStorage::wipe_all_profiles`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn wipe_all_profiles(
        &self,
        own_pubkey: &PublicKey,
        blank_id: &EventId,
        blank_created_at: i64,
        fully_acked: bool,
        now: i64,
    ) -> Result<()> {
        self.storage
            .wipe_all_profiles(own_pubkey, blank_id, blank_created_at, fully_acked, now)
    }

    // ==================== Profile plane (relays + salt) ====================
    //
    // This block is the ONLY bridge between the circle layer and the profile
    // plane, and it is deliberately narrow: bare relay URLs and an opaque salt,
    // in and out. Nothing here names a circle, a group, or an MLS identifier.
    //
    // That is a hard requirement, not a style preference. The FFI wrappers for
    // these two methods live inside the profile block of
    // `haven/rust_builder/src/api.rs`, which `scripts/ci/check_profile_privacy_
    // boundaries.sh` (Check 2) scans for the tokens `nostr_group_id`,
    // `MlsGroupId`, `mls_group_id`, `GroupId`, `circle_id`, `circleId` and
    // `CircleId`. A signature that took or returned any circle type would force
    // the FFI caller to spell one and break that gate — which is the gate doing
    // its job, because the profile plane must stay unlinkable to circles at the
    // source level.

    /// The profile-plane relays that are safe to use right now.
    ///
    /// The curated pool unioned with the user's stored profile relays, minus
    /// every relay in the append-only contamination ledger. Returns bare URLs;
    /// see [`CircleStorage::usable_profile_relays`] for the union rationale.
    ///
    /// # Errors
    ///
    /// Returns [`crate::profile::ProfileError::PoolUnderflow`] when fewer than
    /// [`crate::profile::PROFILE_POOL_MIN`] relays survive exclusion.
    ///
    /// Underflow is TERMINAL. A caller MUST surface the failure, never
    /// substitute the discovery plane, the account seed, or an excluded relay:
    /// that fallback would route profile lookups to a relay already holding this
    /// account's encrypted location traffic, handing one observer both halves of
    /// the join the plane separation exists to break.
    pub fn usable_profile_relays(&self) -> crate::profile::Result<Vec<String>> {
        self.storage.usable_profile_relays()
    }

    /// See [`CircleStorage::get_or_create_profile_relay_salt`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn profile_relay_salt(&self) -> Result<crate::profile::ProfileRelaySalt> {
        self.storage.get_or_create_profile_relay_salt()
    }

    /// See [`CircleStorage::refresh_contamination_ledger`].
    ///
    /// Already run once per process by [`Self::new`] / [`Self::new_unencrypted`];
    /// exposed so a caller can re-fold after a bulk configuration change.
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn refresh_contamination_ledger(&self, now: i64) -> Result<usize> {
        self.storage.refresh_contamination_ledger(now)
    }

    /// See [`CircleStorage::list_contaminated_relays`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn list_contaminated_relays(&self) -> Result<Vec<String>> {
        self.storage.list_contaminated_relays()
    }

    // NOTE: there is deliberately no `clear_contaminated_relays`. The ledger is
    // append-only in the strongest sense available — no API can remove a row.
    // The one legitimate "forget" (logout, where the identity those relays
    // observed is itself destroyed) happens by deleting the `circles.db` file,
    // so it needs no method here. See `circle::contamination`'s module docs.
}

/// The recipient of a gift-wrapped Welcome: the identity its `p` tag names.
fn welcome_recipient(event: &Event) -> Option<PublicKey> {
    event.tags.iter().find_map(|tag| {
        let v = tag.as_slice();
        if v.len() >= 2 && v[0] == "p" {
            PublicKey::from_hex(&v[1]).ok()
        } else {
            None
        }
    })
}

/// Where one invitee's Welcome is delivered: their kind-10050 inbox relays
/// that may be dialled (the foreign-relay filter, applied here whatever the
/// caller resolved), else nowhere — and then the invite is refused rather
/// than sent with a Welcome that cannot arrive.
///
/// No other tier. Marmot sends a Welcome to the recipient's 10050 list
/// (`transports/nostr.md` 209-215); a NIP-65 hint reaches no Haven invitee,
/// whose app fetches and subscribes to gift wraps on its inbox list alone;
/// and the sender's own inbox would hand the invitee's gift wrap to relays
/// the invitee never reads (`welcome_never_sent_to_sender_inbox`).
fn welcome_route(member: &MemberKeyPackage) -> Result<Vec<String>> {
    let relays = crate::relay::retain_dialable_foreign_relays(
        member.inbox_relays.iter().map(String::as_str),
    );
    if relays.is_empty() {
        Err(CircleError::MissingWelcomeRelays)
    } else {
        Ok(relays)
    }
}

/// The servers ([`location_pool::relay_authority`]s) that see an invitee's
/// pubkey: their inbox and both halves of their NIP-65 list. A new circle
/// avoids them while enough other relays remain.
///
/// [`location_pool::relay_authority`]: crate::circle::location_pool::relay_authority
fn invitee_relay_authorities(members: &[MemberKeyPackage]) -> BTreeSet<String> {
    members
        .iter()
        .flat_map(|member| {
            member
                .inbox_relays
                .iter()
                .chain(&member.nip65_relays)
                .chain(&member.nip65_write_relays)
        })
        .filter_map(|relay| crate::circle::location_pool::relay_authority(relay))
        .collect()
}

/// One invitee's Welcome route: the invitee as lowercase hex, their inbox
/// relays, and their `KeyPackage`'s `not_after` when it can be read.
pub type WelcomeRoute = (String, Vec<String>, Option<u64>);

/// What [`CircleManager::keep_welcome_routes`] found kept for an invitee
/// before it wrote theirs: the relays and `not_after`, or nothing.
pub type PriorRoute = (String, Option<crate::nostr::mls::KeptWelcomeRoute>);

/// Where each of `members`' Welcomes goes ([`welcome_route`]), keyed by
/// invitee, with the `not_after` of the `KeyPackage` it is made for.
///
/// # Errors
///
/// [`CircleError::MissingWelcomeRelays`] for an invitee with no inbox relay
/// Haven may dial.
pub fn welcome_routes_of(members: &[MemberKeyPackage]) -> Result<Vec<WelcomeRoute>> {
    members
        .iter()
        .map(|member| {
            Ok((
                member.key_package_event.pubkey.to_hex(),
                welcome_route(member)?,
                key_package_not_after(member),
            ))
        })
        .collect()
}

/// The `not_after` of `member`'s `KeyPackage`, read through MDK's own
/// parser; `None` when it cannot be read. The metadata is never formatted:
/// it names the package (Security Rule 15).
fn key_package_not_after(member: &MemberKeyPackage) -> Option<u64> {
    let package = SessionManager::key_package_from_event(&member.key_package_event).ok()?;
    cgka_engine::key_package_metadata(&package)
        .ok()
        .map(|metadata| metadata.not_after)
}

/// The engine's [`KeyPackage`] of each of `members`.
pub fn key_packages_of(members: &[MemberKeyPackage]) -> Result<Vec<KeyPackage>> {
    let events: Vec<Event> = members
        .iter()
        .map(|member| member.key_package_event.clone())
        .collect();
    parse_key_packages(&events)
}

/// Parses invitee `KeyPackage` events (kind 30443) into engine [`KeyPackage`]s.
fn parse_key_packages(events: &[Event]) -> Result<Vec<KeyPackage>> {
    events
        .iter()
        .map(|e| {
            SessionManager::key_package_from_event(e)
                .map_err(|err| CircleError::Mls(redact_hex_sequences(&err.to_string())))
        })
        .collect()
}

/// Emits a redacted debug note if a send/create drain would drop a Rule-13
/// resync signal, so the occurrence is never SILENT (Rust F1).
///
/// The `take_*` helpers extract only [`PublishWork`]; they intentionally ignore
/// `effects.events`. Engine [`GroupEvent`]s are folded to location results ONLY
/// on the ingest / `advance_convergence` path
/// (`Publishing::ingest_for_poll` → [`fold_group_events`]),
/// which is Haven's authoritative resync driver and always runs first after open
/// (startup relay catch-up) — so a hydrate-emitted `PendingCommitRecovered` /
/// `GroupHydrationRecovered` surfaces there and maps to a `GroupUpdate`. In the
/// corner case where a send/create is somehow the first post-open drain, these
/// events would be consumed here; this logs a redacted, group-id-free note
/// rather than dropping them without a trace.
fn note_dropped_resync_events(events: &[GroupEvent]) {
    let dropped = events
        .iter()
        .filter(|e| {
            matches!(
                e,
                GroupEvent::PendingCommitRecovered { .. }
                    | GroupEvent::GroupHydrationRecovered { .. }
            )
        })
        .count();
    if dropped > 0 {
        log::debug!(
            "send/create drain observed {} resync signal(s); \
             resync is authoritatively driven by the receive path",
            bucket(dropped)
        );
    }
}

impl CircleManager {
    /// Everything a SEND drained besides the item it was after.
    ///
    /// `do_send` settles stored convergence before it encrypts: a peer message that
    /// could not be peeled when it arrived is re-ingested there and lands in THIS
    /// send's own batch — delivered at most once, with its durable row written. So
    /// the locations are persisted here, at the highest-frequency instance of that
    /// drop there is (every publish cycle).
    ///
    /// The folded results are not returned: the send's contract is the event it
    /// produced, every location in them is already in the last-known store, and
    /// widening it would change the FFI shape for a signal the receive path already
    /// drives. Deliberately NO convergence drain either — a send is not a
    /// resolution, and what it leaves pending the next receive pass picks up.
    ///
    /// # What is still dropped here, and the design deviation that leaves it so
    ///
    /// The LOCATIONS are persisted; the RESYNC SIGNALS are not surfaced.
    /// `PendingCommitRecovered` / `GroupHydrationRecovered` in a send's batch get
    /// [`note_dropped_resync_events`]' bucketed note and nothing else, and
    /// Rule 13 calls the first of those a MANDATORY resync. The reviewed plan
    /// for this work specified deleting that function on the premise that the
    /// fold would surface the events instead; it was kept, because surfacing
    /// them means
    /// widening the seal's return across the FFI for a signal the
    /// RECEIVE path already drives authoritatively (catch-up runs first after
    /// every open, and its fold maps both events to a `GroupUpdate`). What would
    /// close it is that same FFI widening. Recorded rather than assumed away:
    /// a deviation from an approved design is not a detail.
    async fn note_send_drain(&self, events: &[GroupEvent]) {
        note_dropped_resync_events(events);
        self.persist_replayed_locations(events).await;
    }

    /// Extracts the `FoundingGroupCreated { welcomes }` publish work from a
    /// create-group's effects. A current-profile create never stages: the
    /// group is canonical on return, so there is no pending ref to resolve.
    async fn take_group_created(&self, effects: SessionEffects) -> Result<Vec<TransportMessage>> {
        self.note_send_drain(&effects.events).await;
        for work in effects.publish {
            if let PublishWork::FoundingGroupCreated { welcomes } = work {
                return Ok(welcomes);
            }
        }
        Err(CircleError::Mls(
            "create_group produced no FoundingGroupCreated publish work".to_string(),
        ))
    }

    /// Extracts the bare `Proposal { msg }` (`SelfRemove`) transport event.
    async fn take_proposal(&self, effects: SessionEffects) -> Result<Event> {
        self.note_send_drain(&effects.events).await;
        for work in effects.publish {
            if let PublishWork::Proposal { msg, .. } = work {
                return SessionManager::transport_message_to_event(&msg)
                    .map_err(CircleError::from_session);
            }
        }
        Err(CircleError::Mls(
            "leave produced no Proposal publish work".to_string(),
        ))
    }
}

/// The circle an engine [`GroupEvent`] is about.
///
/// Exhaustive on purpose: every variant at MDK v0.10.4 carries a `group_id`,
/// so a new one that does not breaks compilation here instead of silently
/// dropping out of the receive observation that gate 4 reads.
const fn group_id_of(event: &GroupEvent) -> &GroupId {
    match event {
        GroupEvent::GroupCreated { group_id }
        | GroupEvent::GroupJoined { group_id, .. }
        | GroupEvent::MessageReceived { group_id, .. }
        | GroupEvent::AppMessageInvalidated { group_id, .. }
        | GroupEvent::GroupStateChanged { group_id, .. }
        | GroupEvent::GroupHydrationQuarantined { group_id, .. }
        | GroupEvent::EpochChanged { group_id, .. }
        | GroupEvent::CommitRolledBack { group_id, .. }
        | GroupEvent::GroupStateInvalidated { group_id, .. }
        | GroupEvent::GroupStateRevalidated { group_id, .. }
        | GroupEvent::TransportObjectResourceRefused { group_id, .. }
        | GroupEvent::GroupUnrecoverable { group_id }
        | GroupEvent::PendingCommitRecovered { group_id, .. }
        | GroupEvent::GroupHydrationRecovered { group_id, .. } => group_id,
    }
}

/// Folds an engine [`GroupEvent`] batch into location-facing results.
fn fold_group_events(events: &[GroupEvent]) -> Vec<LocationMessageResult> {
    events
        .iter()
        .filter_map(SessionManager::location_result_from_event)
        .collect()
}

/// The routing id a REQ's `#h` hex names; `None` when it names none.
fn routing_id_of_hex(group_id_hex: &str) -> Option<[u8; 32]> {
    hex::decode(group_id_hex)
        .ok()
        .and_then(|bytes| <[u8; 32]>::try_from(bytes).ok())
}

/// Reads the 32-byte `nostr_group_id` from a `kind:445` event's `#h` tag
/// (`["h", "<hex>"]`), or `None` if the tag is absent / malformed. Never exposes
/// the real MLS group id (Rule 4) — the `#h` tag carries only the pseudonymous
/// routing id.
fn nostr_group_id_from_commit_event(event: &Event) -> Option<[u8; 32]> {
    let hex_str = event.tags.iter().find_map(|t| {
        let slice = t.as_slice();
        if slice.first().map(String::as_str) == Some("h") {
            slice.get(1).cloned()
        } else {
            None
        }
    })?;
    let bytes = hex::decode(hex_str).ok()?;
    bytes.try_into().ok()
}

/// Result of circle creation.
///
/// The circle is canonical already (a founding create has no group-message
/// obligation, Rule 13); `welcome_events` are published independently.
pub struct CircleCreationResult {
    /// The created circle.
    pub circle: Circle,
    /// Gift-wrapped Welcome events (engine-produced 1059s) ready to publish.
    pub welcome_events: Vec<GiftWrappedWelcome>,
    /// The transport id of each founding Welcome's delivery record.
    pub(crate) founding_welcomes: Vec<MessageId>,
}

impl std::fmt::Debug for CircleCreationResult {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CircleCreationResult")
            .field("circle", &"<redacted>")
            .field("welcome_events", &bucket(self.welcome_events.len()))
            .finish_non_exhaustive()
    }
}

/// What the engine step of a leave did ([`CircleManager::propose_leave_staging`]).
pub enum LeaveStep {
    /// Proposed: these fanouts — the proposal's, and an eviction its
    /// preflight committed — are to be driven.
    Recorded(Vec<FanoutId>),
    /// This epoch's proposal already stands, under its record.
    AlreadyProposed,
    /// The engine made the proposal and no record of it stands: it was not
    /// sent. These fanouts are driven; the leave is pending.
    Unrecorded(Vec<FanoutId>),
    /// Not proposed: the circle is not stable, or the engine queued the
    /// leave behind what it staged first — an eviction, under these
    /// fanouts, which are driven now. Proposed once the circle is stable.
    AwaitsStable(Vec<FanoutId>),
}

/// What a send-side change left when it was staged in staging mode.
pub struct StagedChange {
    /// The change's own commit, under its durable fanout. `None` when the
    /// engine queued the change behind what the circle is still resolving: it
    /// is accepted and durable, and staged by a later advance.
    pub commit: Option<FanoutId>,
    /// Every other commit the same call staged: an eviction the engine's own
    /// preflight committed — in this circle, ahead of a change it then
    /// queued, or in another.
    pub also: Vec<FanoutId>,
    /// The Welcomes `commit` carries, by transport id: an invite's.
    pub welcomes: Vec<MessageId>,
    /// The change is staged and has no record: the record could not be
    /// written and the rollback failed too. It was not sent and is not
    /// driven; see `ChangeNote::ChangeUnrecorded`.
    pub unrecorded: bool,
    /// The circle already was as the change asks: nothing was staged.
    pub already: bool,
}

/// Whether the change itself was staged, and nothing else: how many other
/// commits the call staged is how many members left a circle, how many
/// Welcomes it carries is how many were invited (Security Rule 15), and each
/// handle is an MDK id.
impl std::fmt::Debug for StagedChange {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("StagedChange")
            .field("staged", &self.commit.is_some())
            .finish_non_exhaustive()
    }
}

/// What [`CircleManager::seal_location_staging`] left.
///
/// **No `Debug`, deliberately**: it carries a signed event and MDK handles.
#[derive(Default)]
pub struct StagedSeal {
    /// The location, encrypted: its event, the circle's public id and its
    /// relays. `None` when the send was deferred.
    pub sealed: Option<(Event, [u8; 32], Vec<String>)>,
    /// Records of what the engine staged on the way.
    pub recorded: Vec<FanoutId>,
    /// What was folded, and each proposal no record could be written for.
    pub handed_back: DecryptedIngest,
    /// The removal of a member who left is due and was not made: the wait a
    /// refusal earned is running, or the call's mode makes no new commit.
    pub departure_due: bool,
    /// The pre-send drain stopped at the wake's end with a deferred-peel row
    /// still untried.
    pub drain_cut: bool,
}

/// What [`CircleManager::repair_epoch_rotation_staging`] did.
///
/// **No `Debug`, deliberately**: the deferral's work carries signed events.
pub enum StagedRepair {
    /// The self-update is staged.
    Rotated(StagedChange),
    /// A gate declined the repair; nothing was staged and nothing changed.
    Skipped(SkipReason),
    /// The circle is send-gated, or the engine queued the self-update (and
    /// it was retired in the hold that queued it): the deferred-send repair
    /// ran instead ([`CircleManager::repair_deferred_send_staging`]).
    Deferred {
        /// Records of what the engine staged and released on the way.
        recorded: Vec<FanoutId>,
        /// What was folded, and each proposal no record could be written
        /// for.
        handed_back: DecryptedIngest,
    },
}

/// What [`CircleManager::post_join_self_update_staging`] did.
///
/// **No `Debug`, deliberately**: what it folded carries signed events.
pub enum StagedPostJoin {
    /// The self-update is staged.
    Made(StagedChange),
    /// Nothing was made: the circle would not take a staged commit, or the
    /// engine queued the self-update and the hold that queued it retired
    /// it. What the hold recorded and folded besides.
    NotMade(Vec<FanoutId>, DecryptedIngest),
}

/// What [`CircleManager::rotation_preflight`] decided.
enum RotationPreflight {
    Skip(SkipReason),
    /// Stored input gates the circle's sends: the deferred-send repair runs
    /// instead of the rotation, in the form its caller's plane uses.
    Gated,
    Go {
        nostr_group_id: [u8; 32],
    },
}

/// What resolving one fanout's commit left: the folded batch, and the fanouts
/// staged for whatever the engine's replay committed.
pub struct FanoutResolution {
    /// The folded batch.
    pub replayed: DecryptedIngest,
    /// The fanouts staged while resolving.
    pub staged: Vec<FanoutId>,
    /// The engine's error, when the call behind this failed.
    pub error: Option<CircleError>,
}

/// The folded outcome of one engine batch.
///
/// What a fold of a received `kind:445`, an advance, or a fanout
/// resolution's replay hands on. It carries no commit: every hold that hands
/// a batch to the fold records what it stages.
#[derive(Default)]
pub struct DecryptedIngest {
    /// The folded location-facing results (locations, joins, updates, …).
    pub results: Vec<LocationMessageResult>,
    /// Bare proposals to publish — no pending ref, nothing to confirm. At MDK
    /// `fcc85edd` this is the local user's own re-proposed leave, re-minted for
    /// the epoch a peer's commit just accepted; dropping it leaves the device
    /// behind the engine's leave send gate with no proposal in flight.
    ///
    /// Usually empty, and NOT dead code. The fold is not atomic — it takes and
    /// releases the session mutex once per call — so a `Leave` another task
    /// proposes between a resolution and the fold's next `advance_convergence`
    /// lands in the engine's global auto-proposal buffer, of which this fold is
    /// the one drain. Narrow window, real one, and a silently dropped user leave
    /// is the worse failure (Rule 12). See the "NOT TESTED, and why" note in
    /// `tests/commit_gap_replay_e2e.rs` before deleting this.
    pub proposals: Vec<Event>,
}

impl std::fmt::Debug for DecryptedIngest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DecryptedIngest")
            .field("results", &bucket(self.results.len()))
            .field("proposals", &bucket(self.proposals.len()))
            .finish()
    }
}

/// Where a batch reaching the publish-resolution fold came from.
///
/// The only thing the fold's inbound observation (R2) and its `GroupEvolution`
/// disposition (a released queued intent, which only an advance can hand
/// back) need to differ on.
/// What [`CircleManager::record_unrecorded_join`] made of one `GroupJoined`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum JoinRecord {
    /// Its circle was missing and is now recorded.
    Materialized,
    /// Nothing to record: the circle exists, nobody accepted the join, or the
    /// group is no longer live.
    Recorded,
    /// Its circle could not be recorded; the join stays owed.
    Owed,
}

/// What the publish-resolution fold does with what its own advances release.
///
/// No `Debug`: one arm carries an instant (Security Rule 15).
#[derive(Clone, Copy)]
enum Disposition<'a> {
    /// Each commit and each proposal is recorded in the hold that released
    /// it, at `now_ms` on the fanout clock, and its handle returned: the
    /// fanout driver's own resolutions and the planes that drive. `still`
    /// is the full mode the caller decided this in, asked again by each
    /// advance once it holds the engine.
    Stage { now_ms: u64, still: Still<'a> },
    /// As [`Self::Stage`], for a drive that makes no new commit
    /// ([`DriveMode::FinishOnly`]): each advance is inputs-only, so nothing
    /// is released to record but a leave the engine proposes again.
    Settle { now_ms: u64 },
}

impl<'a> Disposition<'a> {
    /// The disposition of a hold that records, in the mode `still` was
    /// decided in.
    const fn recording(now_ms: u64, still: Still<'a>) -> Self {
        match still.decided() {
            DriveMode::Full => Self::Stage { now_ms, still },
            DriveMode::FinishOnly => Self::Settle { now_ms },
        }
    }
}

/// A staging advance's effects, its handles joined to `staged`.
fn recorded_by(advanced: Staged, staged: &mut Vec<FanoutId>) -> SessionEffects {
    staged.extend(advanced.fanouts);
    staged.extend(advanced.proposals);
    advanced.effects
}

/// How many proposals [`CircleManager::owe_proposals`] keeps.
const OWED_PROPOSALS_CAP: usize = 16;

/// Adds `proposals` to `owed`, one an event id, and drops the oldest past
/// [`OWED_PROPOSALS_CAP`].
fn owe(owed: &mut Vec<Event>, proposals: Vec<Event>) {
    for proposal in proposals {
        if owed.iter().all(|kept| kept.id != proposal.id) {
            owed.push(proposal);
        }
    }
    let over = owed.len().saturating_sub(OWED_PROPOSALS_CAP);
    owed.drain(..over);
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BatchOrigin {
    /// The batch the confirm or the rollback itself returned.
    TopLevel,
    /// A batch an `advance_convergence` or a rollback inside the fold produced.
    Drained,
}

/// The (circle, sender) pairs a persist declined because the circle's CURRENT
/// roster no longer names the sender.
///
/// Carried back out rather than kept private so the ROSTER decision is made
/// once and applied to both halves of the same batch — the rows written and the
/// results handed to the caller. Only roster refusals are recorded: a self-echo,
/// an unknown circle or an unparseable payload are not the caller's business,
/// and a roster read that FAILED declines nothing at all (Rule 12's fail-open).
#[derive(Default)]
struct RosterDeclined(HashSet<(Vec<u8>, String)>);

impl RosterDeclined {
    fn reject(&mut self, group_id: &GroupId, sender_pubkey: &str) {
        self.0
            .insert((group_id.as_slice().to_vec(), sender_pubkey.to_owned()));
    }

    /// Whether `result` is one of the refusals.
    fn rejects(&self, result: &LocationMessageResult) -> bool {
        let LocationMessageResult::Location {
            sender_pubkey,
            group_id,
            ..
        } = result
        else {
            return false;
        };
        self.0
            .contains(&(group_id.as_slice().to_vec(), sender_pubkey.clone()))
    }
}

/// How many engine batches one publish resolution generates work from before it
/// stops.
///
/// A runaway guard, not a business bound: a resolution's replay releases a
/// handful of batches, and anything near this is a bug in the engine or in the
/// fold. Crossing it stops the advances and the re-ticks and NOTHING else —
/// every batch already handed back is still folded, so no ref dangles, no
/// obligation goes unrecorded and no replayed location is dropped — and it loses
/// no schedule either: the groups that never got their advance keep theirs in
/// the engine, which re-marks them pending on the next advance.
///
/// **No production path reaches it**, which is a property of the engine's
/// buffers rather than a bound anyone chose. A fold's convergence set is seeded
/// by `replay_buffered_messages`, which is single-group, and `collect_effects`
/// empties the engine's global pending-convergence buffer on the way out of
/// EVERY call — so nothing accumulates groups across calls, the stored-message
/// write fault included (it breaks the terminal row write of an
/// application-message ingest, which schedules no convergence at all). Measured
/// over this tree's whole suite: three batches and one re-tick, at the most. The
/// disposition is therefore driven where the fold can be handed its batch
/// directly, by
/// `tests::the_batch_cap_stops_generating_without_dropping_what_it_holds`.
const MAX_FOLD_BATCHES: usize = 32;

/// How strongly a receive batch asks the member directory to be rewritten.
///
/// Ordered by strength: `Rewrite < RewriteWithdrawing`, so a batch carrying both
/// an ordinary departure and a withdrawal folds — through `Option::max` over the
/// derived [`Ord`] — to the withdrawing verdict, and no reconcile ever runs
/// mid-drain on a partial view.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum DirectoryReconcile {
    /// Re-derive the union; anyone who drops out of it is demoted to a recent
    /// contact and expires on the ordinary retention window.
    Rewrite,
    /// The engine has WITHDRAWN state it previously surfaced, so a pubkey that
    /// drops out of the union may be someone a superseded commit added and who
    /// was never a member. Delete them instead of ageing them out: storage
    /// cannot tell the two apart (the schema carries no `first_seen_day` — a
    /// partition leak), and the fold keeps only the group id, so the individual
    /// superseded commit is not recoverable either.
    RewriteWithdrawing,
}

impl DirectoryReconcile {
    /// The strongest verdict a folded receive batch implies, or `None` when
    /// nothing in it is a membership signal.
    ///
    /// * `Invalidated` → [`Self::RewriteWithdrawing`]. Deliberately not named
    ///   after commits: the fold collapses `AppMessageInvalidated` into the same
    ///   result, so this also fires for a dropped application message. Harmless
    ///   for a re-read, and the engine has already written the rolled-back state
    ///   by the time the app can drain the event.
    /// * `GroupUpdate` / `Joined` → [`Self::Rewrite`].
    /// * `Location` → `None`. An application message may be sealed up to
    ///   `app_message_past_epoch_limit` epochs behind the tip, so treating its
    ///   sender as a co-member would resurrect someone removed several epochs
    ///   ago.
    /// * `Unrecoverable` → `None`. That group's roster is frozen at its last
    ///   stable epoch; reading it is what
    ///   [`CircleManager::reconcile_member_directory`] skips, so asking for a
    ///   pass on its account would achieve nothing.
    #[must_use]
    pub fn for_receive_results(results: &[LocationMessageResult]) -> Option<Self> {
        results.iter().fold(None, |verdict, result| {
            let implied = match result {
                LocationMessageResult::Invalidated { .. } => Some(Self::RewriteWithdrawing),
                LocationMessageResult::GroupUpdate { .. }
                | LocationMessageResult::Joined { .. } => Some(Self::Rewrite),
                LocationMessageResult::Location { .. }
                | LocationMessageResult::Unrecoverable { .. } => None,
            };
            verdict.max(implied)
        })
    }

    /// [`Self::for_receive_results`] over a raw engine event batch.
    ///
    /// Callers inside `haven-core` should prefer
    /// [`CircleManager::directory_verdict_for_events`], which additionally
    /// records the `Unrecoverable` groups the reconcile must skip.
    #[must_use]
    pub fn for_group_events(events: &[GroupEvent]) -> Option<Self> {
        events.iter().fold(None, |verdict, event| {
            let implied = SessionManager::location_result_from_event(event)
                .and_then(|result| Self::for_receive_results(&[result]));
            verdict.max(implied)
        })
    }
}

#[cfg(test)]
mod tests {
    //! Dark Matter (DM-5a) re-expression of the `CircleManager` test suite.
    //!
    //! The pre-migration suite tested the hand-rolled convergence / settle-window
    //! / staged-commit-marker / peek / self-update stack that the engine now owns
    //! (plan §5.3/§5.4). Those tests are **deleted with their subject** — the
    //! subject no longer exists to test:
    //!
    //! * `converge_commit` / `CommitConvergence` / `CommitIntent` fork-selection
    //!   internals, `decrypt_receive_only` / `ReceiveOnlyOutcome::Skipped`, the
    //!   `receive_only_until_applied` contention helper, `mdk_process_message_*`,
    //!   the `no_pending_observers_*` / `sibling_commit_*` / `blind_apply_*` /
    //!   `exact_original_bug_*` / `eager_finalize_*` / `converge_*` /
    //!   `concurrent_admin_remove_*` / `rev1_*` / `auto_commit_*` /
    //!   `engine_processor_*` / `decrypt_for_engine_*` families — the engine's
    //!   `advance_convergence` + branch selection replaces Haven's picker. The
    //!   surviving INVARIANT (real out-of-order multi-party convergence with no
    //!   loss) is **re-expressed as the black-box F2 gate**
    //!   `tests/live_sync_out_of_order_commit_e2e.rs`, not here.
    //! * `m7_*` / `should3_*` staged-commit-marker tests — the marker + its
    //!   `staged_commits` table are deleted; crash recovery is now the engine's
    //!   `PendingCommitRecovered` at hydrate.
    //! * `rev1_peek_*` — `peek_crypto` is deleted (the peeler's non-destructive
    //!   outer decrypt replaces it).
    //! * `self_update` / `groups_needing_self_update` / `epoch_stable_across_idle`
    //!   — the engine converges; Haven's periodic self-update ritual is gone.
    //! * per-send NIP-40 expiration tests (`encrypt_location_attaches_expiration_*`,
    //!   `*_evolution_event_has_no_expiration_tag`, `decrypt_location_drops_expired`)
    //!   — per-message TTL is dropped (retention is a group-level
    //!   `message-retention.v1` component now, `dm2_report` #2).
    //! * `has_live_key_material_*` / `create_key_package_with_d_*` /
    //!   `*_login_key_package_*` — the M8-2 gate + `create_key_package_with_d`
    //!   dissolve (last-resort KP semantics); KP lifetime tracking is DM-2b's
    //!   `relay/maintenance/key_package.rs` suite.
    //! * (`admin_handoff_end_to_end` survives unchanged in spirit — it is
    //!   re-expressed below over the engine's `admin_pubkeys` view, since
    //!   `propose_admin_handoff`/`propose_self_demote` now ride
    //!   `UpdateAppComponents(admin-policy.v1)` rather than the deleted
    //!   pre-Dark-Matter admin API.)
    //! * `m7b_every_mdk_write_site_acquires_the_writer_lock` — the process-global
    //!   `write_lock` is superseded by the engine's single
    //!   `tokio::sync::Mutex<AccountDeviceSession>`; the invariant is re-expressed
    //!   structurally as `single_account_device_session_construction_site` below
    //!   (Rule 14: at most one session per DB file).

    use super::*;
    use crate::circle::types::LastKnownLocation;
    use crate::nostr::mls::types::LocationMessageResult;
    use crate::nostr::mls::PlaneStanding;
    use crate::relay::fanout::RepairOutcome;
    use crate::relay::maintenance::build_kp_maintenance_events;
    use nostr::JsonUtil as _;
    use tempfile::TempDir;

    /// Independent detector for a contiguous hex run >= 16 chars (the shape of
    /// a circle's `nostr_group_id`). Written from scratch — NOT via the
    /// redactor — so it cannot mask a redactor regression.
    fn has_hex_run_ge16(s: &str) -> bool {
        let mut run = 0usize;
        for b in s.bytes() {
            if b.is_ascii_hexdigit() {
                run += 1;
                if run >= 16 {
                    return true;
                }
            } else {
                run = 0;
            }
        }
        false
    }

    /// Rule 8: a storage failure on the repair surface crosses the FFI boundary
    /// as prose, and a rusqlite message can quote the failing statement — which
    /// on `circles` and `circle_health` carries the circle's `nostr_group_id`.
    #[test]
    fn a_storage_error_carrying_a_group_id_is_redacted_on_the_repair_surface() {
        let group_id_hex = hex::encode([0xab_u8; 32]);
        assert!(
            has_hex_run_ge16(&group_id_hex),
            "detector sanity: a 32-byte id is a >=16 hex run"
        );
        let sqlite_prose = format!(
            "no such column in UPDATE circle_health SET ... WHERE nostr_group_id = \
             x'{group_id_hex}'"
        );
        // Fixture sanity on the SYNTHETIC prose, not on an error's rendering:
        // `CircleError`'s `Display` no longer carries a payload at all, so a
        // control that required one would forbid the stronger guarantee.
        assert!(
            has_hex_run_ge16(&sqlite_prose),
            "fixture sanity: the raw SQLite prose DOES carry the id"
        );
        assert!(
            !has_hex_run_ge16(&redact_hex_sequences(&sqlite_prose)),
            "redactor sanity: the run is collapsed"
        );

        let raw = CircleError::Storage(sqlite_prose);
        let surfaced = redact_storage_error(&raw);
        let rendered = surfaced.to_string();

        // Two independent layers, both asserted: the variant still says a
        // storage failure happened (what the two async siblings read as "the
        // map_err is on the path"), and NEITHER rendering carries the id — the
        // detail now lives only in the payload, which nothing renders.
        assert!(matches!(surfaced, CircleError::Storage(_)), "{rendered}");
        crate::assert_display_redacted!(
            &surfaced,
            "CircleError",
            marker = "Storage error",
            &[&group_id_hex, "circle_health"]
        );
        crate::assert_debug_redacted!(&surfaced, "CircleError", &[&group_id_hex, "circle_health"]);
        assert!(
            !has_hex_run_ge16(&rendered),
            "a long hex run survived redaction: {rendered}"
        );
    }

    /// The `circles` read is on the same surface and needs its own proof.
    ///
    /// Its query failure is a `rusqlite::Error`, which reaches `CircleError`
    /// as `Database` through the `#[from]` — a different variant from the lock
    /// path's `Storage` two lines above it. So `Storage` here can only mean the
    /// value passed through the redactor, and dropping the `map_err` shows up
    /// as `Database`, which no string assertion could catch.
    #[tokio::test]
    async fn a_broken_circles_read_arrives_redacted_not_raw() {
        let (manager, keys, temp_dir) = create_test_manager();
        let (group_id, _member) = create_confirmed_circle(&manager, &keys, "Circles").await;

        crate::sqlcipher_init::ensure().expect("SQLite initialises");
        let conn = rusqlite::Connection::open(temp_dir.path().join(CIRCLES_DB_FILENAME)).unwrap();
        conn.execute_batch("ALTER TABLE circles RENAME TO circles_x")
            .unwrap();
        drop(conn);

        let err = manager
            .repair_rotation_for_test(&group_id, now_secs())
            .await
            .expect_err("a missing table must not read as an absent circle");

        assert!(
            matches!(err, CircleError::Storage(_)),
            "the circles read bypassed the redactor: {err:?}"
        );
        assert!(
            !has_hex_run_ge16(&err.to_string()),
            "a long hex run reached the boundary: {err}"
        );
    }

    /// The mapping is ON the path, not merely defined beside it.
    ///
    /// `circle_rotation_state` returns `CircleError::Database` natively, so a
    /// real storage failure reaching the caller as `Database` would prove the
    /// `map_err` had been dropped — which no string assertion could catch,
    /// because rusqlite's own message for a missing table carries no hex.
    #[tokio::test]
    async fn a_storage_failure_on_the_repair_surface_arrives_redacted_not_raw() {
        let (manager, keys, temp_dir) = create_test_manager();
        let (group_id, _member) = create_confirmed_circle(&manager, &keys, "Redaction").await;

        // Break the table the rotation-state read depends on, from a second
        // connection to the same unencrypted file.
        crate::sqlcipher_init::ensure().expect("SQLite initialises");
        let conn = rusqlite::Connection::open(temp_dir.path().join(CIRCLES_DB_FILENAME)).unwrap();
        conn.execute_batch("DROP TABLE circle_health").unwrap();
        drop(conn);

        let err = manager
            .repair_rotation_for_test(&group_id, now_secs())
            .await
            .expect_err("a missing table must not read as a clean rotation state");

        assert!(
            matches!(err, CircleError::Storage(_)),
            "the storage error bypassed the redactor: {err:?}"
        );
        assert!(
            !has_hex_run_ge16(&err.to_string()),
            "a long hex run reached the boundary: {err}"
        );
    }

    // ── Construction helpers (new-stack idiom) ───────────────────────────────

    fn create_test_manager() -> (CircleManager, Keys, TempDir) {
        let temp_dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let manager = CircleManager::new_unencrypted(temp_dir.path(), &keys).unwrap();
        (manager, keys, temp_dir)
    }

    /// Mints a signed kind-30443 `KeyPackage` event via the DM-2b maintenance
    /// builder (the real publish path), so `create_group`/`add_members` consume a
    /// `KeyPackage` the receiver actually produced, exactly as in production.
    async fn make_kp_event(manager: &CircleManager, keys: &Keys, relays: &[String]) -> Event {
        build_kp_maintenance_events(manager.session(), keys, relays, None, None)
            .await
            .expect("build key package event")
            .event
    }

    /// Builds a `MemberKeyPackage` for a fresh identity with caller-controlled
    /// delivery relays, for exercising the Welcome-delivery cascade. The member's
    /// throwaway session is dropped after minting the KP event.
    async fn make_member_with_relays(
        inbox_relays: Vec<String>,
        nip65_relays: Vec<String>,
    ) -> MemberKeyPackage {
        let kp_relays = vec!["wss://kp.example.com".to_string()];
        let member_keys = Keys::generate();
        let kp_dir = TempDir::new().unwrap();
        let member = CircleManager::new_unencrypted(kp_dir.path(), &member_keys).unwrap();
        let event = make_kp_event(&member, &member_keys, &kp_relays).await;
        MemberKeyPackage {
            key_package_event: event,
            inbox_relays,
            nip65_relays,
            nip65_write_relays: Vec::new(),
        }
    }

    /// A real two-party MLS circle established over the Dark Matter stack.
    struct TwoPartyCircle {
        alice: CircleManager,
        alice_dir: TempDir,
        alice_keys: Keys,
        bob: CircleManager,
        _bob_dir: TempDir,
        bob_keys: Keys,
        mls_group_id: GroupId,
        nostr_group_id: [u8; 32],
        relays: Vec<String>,
    }

    /// Establishes a two-party circle: Alice founds it with Bob's `KeyPackage`
    /// (canonical at once), then Bob holds and accepts the engine-produced
    /// gift-wrapped (1059) welcome.
    async fn setup_two_party_circle() -> TwoPartyCircle {
        let relays = vec!["wss://relay.test.com".to_string()];

        let alice_dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap();

        let bob_dir = TempDir::new().unwrap();
        let bob_keys = Keys::generate();
        let bob = CircleManager::new_unencrypted(bob_dir.path(), &bob_keys).unwrap();

        let bob_kp_event = make_kp_event(&bob, &bob_keys, &relays).await;
        let bob_member = MemberKeyPackage {
            key_package_event: bob_kp_event,
            inbox_relays: relays.clone(),
            nip65_relays: vec![],
            nip65_write_relays: vec![],
        };

        // Created as the app creates one: its founding Welcome sent from its
        // record and acknowledged, so no later drive sends it again.
        let config = CircleConfig::new("Test Circle").with_relays(relays.clone());
        let accepting = crate::relay::fanout::scripted::Accepting::default();
        let creation = crate::relay::fanout::Publishing {
            fanout: &accepting,
            publisher: &accepting,
            clock: &crate::relay::fanout::WallClock,
            deadline_ms: None,
            mode: &DriveMode::Full,
        }
        .create_circle(&alice, &alice_keys, vec![bob_member], &config)
        .await
        .expect("create two-party circle");
        assert_eq!(creation.welcomes_sent, 1, "premise: the Welcome was taken");

        let mls_group_id = creation.circle.mls_group_id.clone();
        let nostr_group_id = creation.circle.nostr_group_id;

        let welcome = accepting
            .handed()
            .into_iter()
            .find(|event| event.kind.as_u16() == 1059)
            .expect("one welcome");
        bob.process_gift_wrapped_invitation(&bob_keys, &welcome)
            .await
            .expect("bob holds welcome");
        bob.accept_invitation(&welcome.id)
            .await
            .expect("bob accepts welcome");

        TwoPartyCircle {
            alice,
            alice_dir,
            alice_keys,
            bob,
            _bob_dir: bob_dir,
            bob_keys,
            mls_group_id,
            nostr_group_id,
            relays,
        }
    }

    #[tokio::test]
    async fn a_drained_proposal_is_handed_back_never_dropped() {
        // A proposal a fold drains (the user's own leave, re-minted) has no
        // staged state to confirm: the caller must receive it as a signed
        // event to publish, or the leave has nothing in flight and no peer can
        // ever commit it.
        let tp = setup_two_party_circle().await;
        let effects = tp
            .bob
            .session()
            .leave_group(&tp.mls_group_id)
            .await
            .expect("bob leaves")
            .expect("a first leave in this epoch proposes");
        assert!(
            effects
                .publish
                .iter()
                .any(|work| matches!(work, PublishWork::Proposal { .. })),
            "precondition: the leave is a bare proposal"
        );

        let (folded, recorded) = tp
            .bob
            .fold_staged(
                effects,
                false,
                0,
                Still::new(&DriveMode::Full, DriveMode::Full),
            )
            .await;

        assert_eq!(folded.proposals.len(), 1, "the proposal reaches the caller");
        assert_eq!(folded.proposals[0].kind, nostr::Kind::Custom(445));
        assert!(recorded.is_empty(), "and nothing was invented beside it");
    }

    #[tokio::test]
    async fn one_batch_persists_each_location_under_its_own_circle() {
        // Keying the persist off anything but each event's own `group_id` files
        // a peer under the wrong circle — visible to members of a circle that
        // peer is not in, which is the privacy failure, not merely a wrong pin.
        // The batch is two REAL engine events from two circles folded together,
        // the shape a drained batch or a resolution replay hands the fold.
        let tp = setup_two_party_circle().await;
        let carol_dir = TempDir::new().unwrap();
        let carol_keys = Keys::generate();
        let carol = CircleManager::new_unencrypted(carol_dir.path(), &carol_keys).unwrap();
        let carol_member = MemberKeyPackage {
            key_package_event: make_kp_event(&carol, &carol_keys, &tp.relays).await,
            inbox_relays: tp.relays.clone(),
            nip65_relays: vec![],
            nip65_write_relays: vec![],
        };
        let sibling = tp
            .alice
            .create_circle(
                &tp.alice_keys,
                vec![carol_member],
                &CircleConfig::new("Sibling").with_relays(tp.relays.clone()),
            )
            .await
            .expect("create the sibling circle");
        let welcome = sibling.welcome_events.first().expect("one welcome");
        carol
            .process_gift_wrapped_invitation(&carol_keys, &welcome.event)
            .await
            .expect("carol holds the welcome");
        carol
            .accept_invitation(&welcome.event.id)
            .await
            .expect("carol accepts");

        let bob_fix = LocationMessage::new(51.5, -0.12);
        let carol_fix = LocationMessage::new(-33.86, 151.21);
        let (bob_event, _, _) = tp
            .bob
            .seal_location_for_test(&tp.mls_group_id, &bob_fix)
            .await
            .expect("bob sends");
        let (carol_event, _, _) = carol
            .seal_location_for_test(&sibling.circle.mls_group_id, &carol_fix)
            .await
            .expect("carol sends");
        let mut batch = Vec::new();
        for event in [&bob_event, &carol_event] {
            let screened = tp
                .alice
                .session()
                .process_event(event)
                .await
                .expect("alice's engine takes the event");
            batch.extend(
                screened
                    .ingested()
                    .expect("an authenticated location")
                    .effects
                    .events
                    .clone(),
            );
        }
        let results = tp.alice.persist_and_fold(&batch).await;
        assert_eq!(
            results
                .iter()
                .filter(|r| matches!(r, LocationMessageResult::Location { .. }))
                .count(),
            2,
            "precondition: one batch really carried both circles' locations"
        );

        let now = chrono::Utc::now().timestamp();
        let bob_hex = tp.bob_keys.public_key().to_hex();
        let carol_hex = carol_keys.public_key().to_hex();
        let first = tp
            .alice
            .snapshot_last_known_for_circle(&tp.nostr_group_id, now)
            .expect("first circle's rows");
        let second = tp
            .alice
            .snapshot_last_known_for_circle(&sibling.circle.nostr_group_id, now)
            .expect("sibling circle's rows");
        let row = |rows: &[LastKnownLocation], hex: &str| {
            rows.iter().find(|r| r.sender_pubkey == hex).cloned()
        };
        assert!((row(&first, &bob_hex).expect("bob's row").latitude - 51.5).abs() < 1e-9);
        assert!((row(&second, &carol_hex).expect("carol's row").latitude - (-33.86)).abs() < 1e-9);
        assert!(
            row(&first, &carol_hex).is_none() && row(&second, &bob_hex).is_none(),
            "and neither peer appears under the other circle's id"
        );
    }

    fn sorted_relays(v: &[String]) -> Vec<String> {
        let mut out = v.to_vec();
        out.sort();
        out.dedup();
        out
    }

    /// A random 32-byte `GroupId` for storage-only fixtures (no live MLS group).
    fn random_group_id() -> GroupId {
        GroupId::from_slice(&Keys::generate().public_key().to_bytes())
    }

    /// Returns the first `Location` result (or panics) in a decrypt batch.
    fn expect_location(results: &[LocationMessageResult]) -> (&str, &str) {
        for r in results {
            if let LocationMessageResult::Location {
                sender_pubkey,
                content,
                ..
            } = r
            {
                return (sender_pubkey, content);
            }
        }
        panic!("expected a Location result, got {results:?}");
    }

    fn save_stored_circle(manager: &CircleManager, status: MembershipStatus) {
        let now = chrono::Utc::now().timestamp();
        let gid = random_group_id();
        let circle = Circle {
            mls_group_id: gid.clone(),
            nostr_group_id: [1u8; 32],
            display_name: "Stored".to_string(),
            circle_type: CircleType::LocationSharing,
            relays: vec!["wss://relay.test.com".to_string()],
            created_at: now,
            updated_at: now,
        };
        manager.storage.save_circle(&circle).unwrap();
        manager
            .storage
            .save_membership(&CircleMembership {
                mls_group_id: gid,
                status,
                inviter_pubkey: None,
                invited_at: now,
                responded_at: Some(now),
            })
            .unwrap();
    }

    // ── Member directory (picker plan §5/§6) ─────────────────────────────────

    /// Day 20 000 (2024-10-04) as unix seconds. Every directory test drives the
    /// clock as an explicit `i64` so retention lands on exact values, never a
    /// band, and never on wall-clock chance.
    const DIR_DAY: i64 = 20_000;
    const DIR_NOW: i64 = DIR_DAY * 86_400;
    /// [`DIRECTORY_RETENTION_SECS`] restated where the assertions read it, so a
    /// change to the window fails these tests rather than sliding past them.
    const DIR_RETENTION: i64 = 3 * 86_400;
    /// Day 40 000 (2079-07-27) as unix seconds — beyond any wall clock a test
    /// run can hold.
    ///
    /// Used by the two tests that must distinguish DELETED from DEMOTED across
    /// a production write site, whose own reconcile necessarily runs on the wall
    /// clock. A row stamped here is demoted with a deadline three days past day
    /// 40 000, which no wall-clock purge can reach — so "the row is gone" can
    /// only mean something deleted it, never that it quietly expired.
    const DIR_FAR_FUTURE: i64 = 40_000 * 86_400;

    /// One row as it stands at [`DIR_FAR_FUTURE`] — see that constant for why
    /// the two severed-path tests read there rather than at [`DIR_NOW`].
    fn far_future_row(
        manager: &CircleManager,
        pubkey_hex: &str,
    ) -> Option<crate::circle::DirectoryEntry> {
        manager
            .ranked_directory_members(DIR_FAR_FUTURE)
            .expect("directory read")
            .into_iter()
            .find(|e| e.pubkey_hex == pubkey_hex)
    }

    /// Reads the directory at [`DIR_NOW`], which is inside the window of every
    /// row these tests write — so the read's own retention sweep can never
    /// remove a row, and a missing row is always attributable to the code under
    /// test rather than to the act of looking.
    fn directory_of(manager: &CircleManager) -> Vec<(String, DirectoryTier)> {
        manager
            .ranked_directory_members(DIR_NOW)
            .expect("directory read")
            .into_iter()
            .map(|e| (e.pubkey_hex, e.tier))
            .collect()
    }

    /// One row, read at [`DIR_NOW`] for the reason on [`directory_of`].
    fn directory_row(
        manager: &CircleManager,
        pubkey_hex: &str,
    ) -> Option<crate::circle::DirectoryEntry> {
        manager
            .ranked_directory_members(DIR_NOW)
            .expect("directory read")
            .into_iter()
            .find(|e| e.pubkey_hex == pubkey_hex)
    }

    /// Runs `sql` against the engine's `session.sqlite` under the test
    /// passphrase, to inject a storage fault the engine cannot produce on
    /// demand.
    ///
    /// If this stops finding a table, MDK renamed it at the pinned rev — the
    /// invariant under test is unchanged, only the injection needs re-aiming.
    fn tamper_session_db(data_dir: &std::path::Path, sql: &str) {
        let key = crate::nostr::mls::StorageConfig::test_sqlcipher_key().expect("test key");
        crate::sqlcipher_init::ensure().expect("SQLite initialises");
        let conn =
            rusqlite::Connection::open(crate::nostr::mls::storage::session_db_path(data_dir))
                .expect("open");
        conn.pragma_update(None, "cipher_compatibility", 4i64)
            .expect("cipher compatibility");
        conn.pragma_update(None, "key", key.as_secret_str())
            .expect("sqlcipher key");
        conn.execute_batch(sql).expect("tamper");
    }

    /// Creates and confirms a circle with one freshly-minted invitee, returning
    /// its group id and the invitee's pubkey hex.
    async fn create_confirmed_circle(
        manager: &CircleManager,
        keys: &Keys,
        name: &str,
    ) -> (GroupId, String) {
        let relays = vec!["wss://relay.test.com".to_string()];
        let member = make_member_with_relays(relays.clone(), vec![]).await;
        let member_hex = member.key_package_event.pubkey.to_hex();
        let config = CircleConfig::new(name).with_relays(relays.clone());
        let creation = manager
            .create_circle(keys, vec![member], &config)
            .await
            .expect("create circle");
        (creation.circle.mls_group_id, member_hex)
    }

    #[tokio::test]
    async fn a_staged_add_is_never_written_to_the_directory() {
        // The hazard §5.2 names: `session.members()` returns the engine's
        // OPTIMISTIC PROJECTION while a commit is staged, so the invitee is in
        // the roster before any relay has seen the commit — and branch
        // selection can still withdraw it. The gate, not the roster, is what
        // keeps that person off disk. (A founding create is canonical on
        // return, so the staged change here is an Add to an existing circle.)
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let relays = vec!["wss://relay.test.com".to_string()];
        let manager = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();

        let (group_id, founder_hex) = create_confirmed_circle(&manager, &keys, "Staged").await;
        let before = directory_of(&manager);
        let member = make_member_with_relays(relays.clone(), vec![]).await;
        let member_hex = member.key_package_event.pubkey.to_hex();
        manager
            .add_members_staging(&group_id, &[member], 0)
            .await
            .expect("stage the add");

        assert!(
            manager
                .session()
                .member_pubkeys(&group_id)
                .await
                .unwrap()
                .contains(&member_hex),
            "precondition: the projected roster already carries the un-published invitee"
        );
        assert_eq!(
            manager
                .session()
                .converged_member_pubkeys(&group_id)
                .await
                .unwrap(),
            ConvergedRoster::NotConverged
        );

        assert!(
            !manager
                .reconcile_member_directory(DirectoryReconcile::Rewrite, DIR_NOW)
                .await
                .unwrap(),
            "a circle mid-publish must defer the whole reconcile"
        );
        assert_eq!(
            directory_of(&manager),
            before,
            "nothing may be written from a projection"
        );
        assert!(!before.iter().any(|(pubkey, _)| pubkey == &member_hex));

        assert_eq!(
            manager.land_staged_for_test().await.len(),
            1,
            "premise: the add lands"
        );
        assert!(manager
            .reconcile_member_directory(DirectoryReconcile::Rewrite, DIR_NOW)
            .await
            .unwrap());
        let written = directory_of(&manager);
        assert_eq!(
            written.len(),
            2,
            "and everything may be written once the commit is applied"
        );
        for pubkey in [founder_hex, member_hex] {
            assert!(written.contains(&(pubkey, DirectoryTier::Current)));
        }
    }

    #[tokio::test]
    async fn opening_the_manager_erases_a_row_no_reconcile_would_have_reached() {
        // The three days are a promise about the DISK. Every other purge caller
        // needs something to happen first — a membership change, a publish
        // resolution, a welcome accept, or the user opening the picker — and an
        // install with a stable circle produces none of them, so without a sweep
        // at process start a departed co-member's pubkey outlives the window by
        // however long the user goes without inviting anyone.
        //
        // The rows are stamped at unix second 0, so their deadline is
        // 1970-01-04: past for any clock a test run can hold, which is what lets
        // this assert against the constructor's real `Utc::now()` without a
        // timing race. The read is RAW — going through `ranked_directory_members`
        // would sweep the same row itself and prove nothing about the open.
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        {
            let manager = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();
            manager
                .storage
                .sync_co_members(&["aa".to_string(), "bb".to_string()], 0)
                .unwrap();
            manager
                .storage
                .sync_co_members(&["bb".to_string()], 0)
                .unwrap();
        } // dropped: nothing is running, and nothing has reconciled.

        let manager = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();
        let conn = manager.storage.conn().lock().unwrap();
        let mut stmt = conn
            .prepare("SELECT pubkey FROM member_directory ORDER BY pubkey")
            .unwrap();
        let stored = stmt
            .query_map([], |r| r.get::<_, String>(0))
            .unwrap()
            .collect::<rusqlite::Result<Vec<_>>>()
            .unwrap();
        drop(stmt);
        drop(conn);
        assert_eq!(
            stored,
            vec!["bb".to_string()],
            "the expired row must be off the disk by the time the manager is \
             usable, and the current co-member must survive — a sweep that \
             emptied the table would pass a one-sided assertion"
        );
    }

    #[tokio::test]
    async fn an_ordinary_departure_ages_out_over_the_retention_window() {
        let circle = setup_two_party_circle().await;
        let bob_hex = circle.bob_keys.public_key().to_hex();
        assert!(circle
            .alice
            .reconcile_member_directory(DirectoryReconcile::Rewrite, DIR_NOW)
            .await
            .unwrap());
        assert_eq!(
            directory_row(&circle.alice, &bob_hex).unwrap().tier,
            DirectoryTier::Current
        );

        // Alice leaves: Bob drops out of the union without anything being
        // withdrawn.
        circle
            .alice
            .abandon_circle_local_only(&circle.mls_group_id, DIR_NOW)
            .await
            .unwrap();
        assert!(circle
            .alice
            .reconcile_member_directory(DirectoryReconcile::Rewrite, DIR_NOW)
            .await
            .unwrap());

        let row = directory_row(&circle.alice, &bob_hex).expect("recent contact retained");
        assert_eq!(row.tier, DirectoryTier::Recent);
        assert_eq!(row.last_shared_day, DIR_DAY);
        assert_eq!(row.purge_after, DIR_NOW + DIR_RETENTION);
    }

    #[tokio::test]
    async fn leaving_a_circle_gives_its_co_members_a_real_deadline() {
        // `delete_circle` deliberately does not cascade to the directory, so
        // without a reconcile at the leave finalizer the co-members of the
        // circle just left keep `is_current = 1` and the never-purge sentinel:
        // not merely past retention, but UNABLE TO EXPIRE, and still offered
        // under "Members of your circles" — a claim about a member list that no
        // longer exists on this device.
        let circle = setup_two_party_circle().await;
        let bob_hex = circle.bob_keys.public_key().to_hex();
        assert!(circle
            .alice
            .reconcile_member_directory(DirectoryReconcile::Rewrite, DIR_NOW)
            .await
            .unwrap());
        assert_eq!(
            directory_row(&circle.alice, &bob_hex).unwrap().purge_after,
            crate::circle::DIRECTORY_PURGE_NEVER,
            "precondition: a current co-member has no deadline"
        );

        circle
            .alice
            .complete_leave(&circle.mls_group_id, DIR_NOW)
            .await
            .expect("complete leave");

        // Read WITHOUT a further reconcile: the leave itself has to have done it.
        let row = directory_row(&circle.alice, &bob_hex).expect("kept as a recent contact");
        assert_eq!(
            row.tier,
            DirectoryTier::Recent,
            "leaving must stop claiming them as a current member"
        );
        assert_eq!(
            row.purge_after,
            DIR_NOW + DIR_RETENTION,
            "and must give them a real deadline, not the never-sentinel"
        );
    }

    #[tokio::test]
    async fn a_voluntary_leave_does_not_delete_its_co_members() {
        // The engine's `Group.removed` is set from a pure roster diff
        // (`cgka-engine/src/message_processor/ingest.rs:928-934`): a peer
        // committing the user's OWN `SelfRemove` and an admin evicting them are
        // the SAME signal, and the `self_removed` set computed a few lines above
        // is used only to attribute the notification. So the commit ingested
        // below is deliberately an admin Remove — it produces exactly the state
        // a committed voluntary leave produces, which is the whole point: only
        // Haven's own record of the intent can tell them apart, and without it
        // the severed-delete erases the person the user just left a circle with
        // — the motivating case for requirement R5.
        let circle = setup_two_party_circle().await;
        let alice_hex = circle.alice_keys.public_key().to_hex();
        circle
            .bob
            .storage
            .sync_co_members(std::slice::from_ref(&alice_hex), DIR_FAR_FUTURE)
            .unwrap();

        // Bob asks to leave. The proposal never has to reach a relay for the
        // intent to be real — and it must survive a process death, which is why
        // the marker is durable rather than in memory.
        circle
            .bob
            .propose_leave(&circle.mls_group_id)
            .await
            .expect("non-admin bob may propose SelfRemove")
            .expect("a first leave in this epoch proposes");
        assert!(
            circle
                .bob
                .storage
                .has_leave_intent(&circle.mls_group_id)
                .unwrap(),
            "precondition: proposing a leave records the intent"
        );

        let commit = circle
            .alice
            .remove_members_for_test(
                &circle.mls_group_id,
                &[circle.bob_keys.public_key().to_hex()],
            )
            .await
            .expect("the commit that takes bob out lands");
        circle
            .bob
            .ingest_for_test(&commit)
            .await
            .expect("bob applies the commit that removed him");

        assert!(
            matches!(
                circle
                    .bob
                    .session()
                    .converged_member_pubkeys(&circle.mls_group_id)
                    .await
                    .unwrap(),
                ConvergedRoster::Converged { removed: true, .. }
            ),
            "precondition: the engine reports the identical `removed` state it \
             reports for an eviction"
        );
        let row = far_future_row(&circle.bob, &alice_hex)
            .expect("a circle you chose to leave keeps its co-members for three days");
        assert_eq!(row.tier, DirectoryTier::Recent);
        assert!(
            row.purge_after < crate::circle::DIRECTORY_PURGE_NEVER,
            "and gives them a deadline rather than pinning them current"
        );
    }

    #[tokio::test]
    async fn a_withdrawn_add_is_deleted_rather_than_kept_as_a_recent_contact() {
        // §5.2: a commit can be withdrawn by branch selection AFTER it was
        // published and confirmed, so a row written from it describes a
        // co-membership that never happened. Storage cannot tell that from a
        // departure — the schema deliberately carries no `first_seen_day` — so
        // the caller must delete instead of demote. Driving a real branch
        // selection needs two concurrent publishers (covered black-box by the
        // F2 convergence gate); what is asserted here is the half this layer
        // owns: under the withdrawing verdict, dropping out of the union DELETES.
        let circle = setup_two_party_circle().await;
        let bob_hex = circle.bob_keys.public_key().to_hex();
        assert!(circle
            .alice
            .reconcile_member_directory(DirectoryReconcile::Rewrite, DIR_NOW)
            .await
            .unwrap());
        assert!(directory_row(&circle.alice, &bob_hex).is_some());

        // The circle row goes directly, NOT through the leave API: a leave
        // finalizer runs its own ordinary rewrite, which would demote Bob to a
        // recent contact before the withdrawing pass could see him as current —
        // and the withdrawing sweep's subject is exactly a row that is still
        // current and has just dropped out of the union.
        circle
            .alice
            .storage
            .delete_circle(&circle.mls_group_id)
            .unwrap();
        assert!(circle
            .alice
            .reconcile_member_directory(DirectoryReconcile::RewriteWithdrawing, DIR_NOW)
            .await
            .unwrap());

        assert!(
            directory_row(&circle.alice, &bob_hex).is_none(),
            "a withdrawn add must leave no durable row, not a three-day one"
        );
        // And it stays gone: the row is deleted, not hidden by a read filter.
        assert_eq!(
            circle
                .alice
                .storage
                .prune_expired_directory_members(DIR_NOW)
                .unwrap(),
            0
        );
    }

    #[tokio::test]
    async fn a_publish_outcome_carrying_a_withdrawal_is_not_downgraded_to_a_rewrite() {
        // Resolving a pending ref is not just "apply or discard": confirming
        // ends in `replay_buffered_messages` (`cgka-engine/src/publish.rs:360`),
        // a full ingest that runs convergence and therefore emits
        // `GroupStateInvalidated`. Hard-coding `Rewrite` at the two publish
        // seams throws that away, and a phantom member gets a three-day timer
        // instead of being deleted.
        let (manager, _keys, _dir) = create_test_manager();
        let group_id = random_group_id();
        assert_eq!(
            manager.publish_outcome_verdict(&[]),
            DirectoryReconcile::Rewrite,
            "an ordinary publish outcome still refreshes the union"
        );
        assert_eq!(
            manager.publish_outcome_verdict(&[GroupEvent::EpochChanged {
                group_id: group_id.clone(),
                from: crate::nostr::mls::types::EpochId(1),
                to: crate::nostr::mls::types::EpochId(2),
            }]),
            DirectoryReconcile::Rewrite
        );
        assert_eq!(
            manager.publish_outcome_verdict(&[GroupEvent::GroupStateInvalidated {
                group_id,
                epoch: crate::nostr::mls::types::EpochId(1),
                invalidated_commit_id: crate::nostr::mls::types::MessageId::new(vec![1]),
                reason:
                    cgka_traits::engine::GroupStateInvalidationReason::SupersededByBranchSelection,
            }]),
            DirectoryReconcile::RewriteWithdrawing,
            "a withdrawal that arrives through a publish outcome is a withdrawal"
        );
    }

    #[tokio::test]
    async fn a_deferred_withdrawal_is_re_armed_rather_than_lost() {
        // §14 blamed process death, but the likelier loss is a deferral: ANY
        // circle mid-publish returns the whole pass without writing, and a
        // circle is most likely mid-publish during exactly the multi-admin
        // commit race that produces a withdrawal. The debt is therefore durable
        // and upgrades the next ordinary rewrite.
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let relays = vec!["wss://elsewhere.test.com".to_string()];
        let manager = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();

        let (settled_gid, member_hex) = create_confirmed_circle(&manager, &keys, "Settled").await;
        assert!(manager
            .reconcile_member_directory(DirectoryReconcile::Rewrite, DIR_NOW)
            .await
            .unwrap());
        assert_eq!(
            directory_row(&manager, &member_hex).unwrap().tier,
            DirectoryTier::Current
        );

        // A second circle stuck mid-publish — a relay update staged and no
        // relay answered: from here every pass defers.
        let (staged_gid, _) = create_confirmed_circle(&manager, &keys, "Staged").await;
        manager
            .update_circle_relays_staging(&staged_gid, &relays, 0)
            .await
            .expect("stage a relay update");
        // The settled circle's member drops out of the union.
        manager.storage.delete_circle(&settled_gid).unwrap();

        assert!(
            !manager
                .reconcile_member_directory(DirectoryReconcile::RewriteWithdrawing, DIR_NOW)
                .await
                .unwrap(),
            "the withdrawal arrives while another circle is mid-publish"
        );
        assert_eq!(
            directory_row(&manager, &member_hex).unwrap().tier,
            DirectoryTier::Current,
            "a deferral writes nothing at all"
        );
        assert!(
            manager.storage.directory_withdrawal_owed().unwrap(),
            "and leaves the withdrawal owed"
        );

        // The mid-publish circle resolves; the NEXT pass asks only for an
        // ordinary rewrite.
        manager.storage.delete_circle(&staged_gid).unwrap();
        assert!(manager
            .reconcile_member_directory(DirectoryReconcile::Rewrite, DIR_NOW)
            .await
            .unwrap());
        assert!(
            directory_row(&manager, &member_hex).is_none(),
            "the owed withdrawal must upgrade it, deleting rather than ageing out"
        );
        assert!(
            !manager.storage.directory_withdrawal_owed().unwrap(),
            "and only a completed withdrawing pass clears the debt"
        );
    }

    #[tokio::test]
    async fn an_unrecoverable_circle_stops_re_stamping_its_members() {
        // §5.3's second detector. An unrecoverable group is still "live", so
        // `converged_member_pubkeys` answers `Ok` with the roster frozen at its
        // last stable epoch — which would re-stamp those people `Current` with
        // the never-purge sentinel on every pass, so they could never age out
        // and a removal there could never be observed. The verdict is MDK's
        // persisted flag, set here the way MDK leaves it and read after an
        // open.
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let manager = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();
        let (event_gid, member_hex) = create_confirmed_circle(&manager, &keys, "Doomed").await;
        assert!(manager
            .reconcile_member_directory(DirectoryReconcile::Rewrite, DIR_NOW)
            .await
            .unwrap());
        assert_eq!(
            directory_row(&manager, &member_hex).unwrap().purge_after,
            crate::circle::DIRECTORY_PURGE_NEVER,
            "precondition: a current co-member is pinned against every clock"
        );
        assert_eq!(
            manager.directory_verdict_for_events(&[GroupEvent::GroupUnrecoverable {
                group_id: event_gid.clone(),
            }]),
            None,
            "the event itself asks for no pass — the group it names is now unreadable"
        );
        drop(manager);
        crate::nostr::mls::storage::set_group_unrecoverable_for_test(
            &crate::nostr::mls::StorageConfig::new(dir.path()).database_path(),
            &crate::nostr::mls::StorageConfig::test_sqlcipher_key().unwrap(),
            &event_gid,
            true,
        )
        .unwrap();
        let manager = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();

        assert!(manager
            .reconcile_member_directory(DirectoryReconcile::Rewrite, DIR_NOW)
            .await
            .unwrap());
        {
            let row = directory_row(&manager, &member_hex).expect("still a recent contact");
            assert_eq!(
                row.tier,
                DirectoryTier::Recent,
                "an unrecoverable group's frozen roster must stop asserting present membership"
            );
            assert_eq!(
                row.purge_after,
                DIR_NOW + DIR_RETENTION,
                "and its members must age out on the ordinary window"
            );
        }
    }

    #[tokio::test]
    async fn a_reconcile_cannot_interleave_with_a_removal() {
        // The walk reads every circle's roster and then writes the union, and it
        // is driven concurrently by live sync, catch-up and the Dart FFI. A walk
        // that read a roster before the user tapped Remove would re-insert the
        // person `remove_members` had just deleted — and because the rewrite
        // DEMOTES, they would return with a three-day timer instead of being
        // gone, which is exactly what owner decision D3 forbids.
        let circle = setup_two_party_circle().await;
        let bob_hex = circle.bob_keys.public_key().to_hex();
        assert!(circle
            .alice
            .reconcile_member_directory(DirectoryReconcile::Rewrite, DIR_NOW)
            .await
            .unwrap());
        assert!(directory_row(&circle.alice, &bob_hex).is_some());

        // Stands in for a walk that is mid-read: it holds the seam.
        let walk = circle.alice.directory_lock.lock().await;

        let removal = circle.alice.remove_members_staging(
            &circle.mls_group_id,
            std::slice::from_ref(&bob_hex),
            0,
        );
        futures::pin_mut!(removal);
        assert!(
            futures::poll!(&mut removal).is_pending(),
            "a removal must WAIT for the walk rather than deleting a row it is \
             about to rewrite"
        );
        // ...and so must a second walk.
        let second = circle
            .alice
            .reconcile_member_directory(DirectoryReconcile::Rewrite, DIR_NOW);
        futures::pin_mut!(second);
        assert!(
            futures::poll!(&mut second).is_pending(),
            "two walks must not read and write the union at the same time"
        );
        assert!(
            directory_row(&circle.alice, &bob_hex).is_some(),
            "nothing has happened while the seam is held"
        );

        drop(walk);
        removal
            .await
            .expect("the removal completes once the seam frees");
        assert!(
            directory_row(&circle.alice, &bob_hex).is_none(),
            "and the row is gone, with no walk able to have re-inserted it"
        );
    }

    #[tokio::test]
    async fn a_reconcile_storm_collapses_into_one_walk_at_the_strongest_verdict() {
        // `has_pending_convergence_inputs` deserialises every retained MLS
        // message at epoch ≥ tip−5 — a circle's whole location history, because
        // a circle's epoch only advances on a membership commit — per circle,
        // per pass, under the session mutex. A peer leaving a circle of M
        // produces up to M−1 competing auto-commits, and the fanout driver's
        // confirm is awaited inline from Dart, so an un-coalesced walk lands on
        // the visible latency of Add / Remove / Create Member.
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let manager = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();

        let departing = "ee".repeat(32);
        manager
            .storage
            .sync_co_members(std::slice::from_ref(&departing), DIR_NOW)
            .unwrap();

        // A walk is in progress; everything that arrives now must be folded into
        // it rather than starting its own.
        manager
            .directory_flight
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .running = true;

        manager
            .reconcile_member_directory_at(DirectoryReconcile::RewriteWithdrawing, DIR_NOW)
            .await;
        manager
            .reconcile_member_directory_at(DirectoryReconcile::Rewrite, DIR_NOW)
            .await;
        assert_eq!(
            directory_row(&manager, &departing).unwrap().tier,
            DirectoryTier::Current,
            "a queued request must not walk on its own"
        );
        assert_eq!(
            manager
                .directory_flight
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .owed,
            Some(DirectoryReconcile::RewriteWithdrawing),
            "and an ordinary rewrite queued beside a withdrawal must never \
             downgrade it"
        );

        // The walk finishes; the next caller adopts the whole backlog.
        manager
            .directory_flight
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .running = false;
        manager
            .reconcile_member_directory_at(DirectoryReconcile::Rewrite, DIR_NOW)
            .await;

        assert!(
            directory_row(&manager, &departing).is_none(),
            "three requests, one walk, resolved at the strongest verdict asked for"
        );
        let flight = manager
            .directory_flight
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let (running, owed) = (flight.running, flight.owed);
        drop(flight);
        assert!(!running, "the runner must release the flight");
        assert_eq!(owed, None, "and must leave nothing owed behind it");
    }

    #[tokio::test]
    async fn a_quarantined_circle_is_skipped_without_aborting_the_union() {
        // A group quarantined at session-open hydration is indistinguishable
        // from an unknown one on every engine accessor. Skipping it must not
        // stop the rest of the union from being written — an aborting reconcile
        // would freeze every peer's timestamp for the life of the session.
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let (quarantined_gid, stranded_hex) = {
            let manager = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();
            create_confirmed_circle(&manager, &keys, "Quarantined").await
        };
        // Destroy the group-scoped OpenMLS state (leaving the Marmot record and
        // the account's own signer intact) so the next open enumerates the group
        // and fails to hydrate it.
        tamper_session_db(
            dir.path(),
            "DELETE FROM openmls_values WHERE group_key IS NOT NULL;",
        );

        let manager = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();
        assert_eq!(
            manager.session().quarantined_group_ids().await,
            vec![quarantined_gid],
            "precondition: hydration quarantined the tampered group"
        );

        let (_healthy_gid, healthy_hex) = create_confirmed_circle(&manager, &keys, "Healthy").await;
        assert!(
            manager
                .reconcile_member_directory(DirectoryReconcile::Rewrite, DIR_NOW)
                .await
                .unwrap(),
            "a quarantined circle is a skip, never an abort"
        );

        assert_eq!(
            directory_row(&manager, &healthy_hex).unwrap().tier,
            DirectoryTier::Current
        );
        assert_eq!(
            directory_row(&manager, &stranded_hex).unwrap().tier,
            DirectoryTier::Recent,
            "the quarantined circle contributes nobody, so its members age out \
             on the ordinary window and are restored when the next session open \
             re-hydrates the group"
        );
    }

    #[tokio::test]
    async fn a_read_failure_aborts_the_rewrite_and_the_purge_together() {
        // A pubkey missing because its circle could not be read is
        // indistinguishable from one who left, so a partial union must write
        // nothing — AND sweep nothing, or the abort would still act on stale
        // retention it can no longer justify.
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let manager = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();
        let (_gid, member_hex) = create_confirmed_circle(&manager, &keys, "Readable").await;

        // A departed contact whose retention has already elapsed at the clock
        // the aborting reconcile will be handed.
        let departed = "aa".repeat(32);
        manager
            .storage
            .sync_co_members(&[member_hex.clone(), departed.clone()], DIR_NOW)
            .unwrap();
        manager
            .storage
            .sync_co_members(std::slice::from_ref(&member_hex), DIR_NOW)
            .unwrap();

        // Inject a genuine backend read failure inside the roster read.
        tamper_session_db(dir.path(), "DROP TABLE cgka_messages;");
        let err = manager
            .reconcile_member_directory(DirectoryReconcile::Rewrite, DIR_NOW + DIR_RETENTION + 1)
            .await
            .expect_err("a backend read failure must surface, not be swallowed");
        assert!(matches!(err, CircleError::Mls(_)));

        assert_eq!(
            directory_row(&manager, &departed).unwrap().tier,
            DirectoryTier::Recent,
            "the purge must not run on a union the reconcile refused to trust"
        );
        assert_eq!(
            directory_row(&manager, &member_hex).unwrap().tier,
            DirectoryTier::Current,
            "and neither may the rewrite"
        );
    }

    #[tokio::test]
    async fn the_reconcile_sweeps_expired_rows_at_the_exact_boundary() {
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let manager = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();

        let departed = "bb".repeat(32);
        manager
            .storage
            .sync_co_members(std::slice::from_ref(&departed), DIR_NOW)
            .unwrap();
        manager.storage.sync_co_members(&[], DIR_NOW).unwrap();

        assert!(manager
            .reconcile_member_directory(DirectoryReconcile::Rewrite, DIR_NOW + DIR_RETENTION)
            .await
            .unwrap());
        assert!(
            directory_row(&manager, &departed).is_some(),
            "the boundary second is still inside the window"
        );

        assert!(manager
            .reconcile_member_directory(DirectoryReconcile::Rewrite, DIR_NOW + DIR_RETENTION + 1)
            .await
            .unwrap());
        assert!(
            directory_row(&manager, &departed).is_none(),
            "the next second is outside it"
        );
    }

    #[tokio::test]
    async fn the_picker_read_sweeps_on_an_install_where_no_reconcile_ever_runs() {
        // The clock the caller passes must reach the DELETE. A device that sees
        // no membership change, no ingest and no catch-up runs nothing but this
        // read, so it is the whole of the three-day promise there.
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let manager = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();

        let departed = "dd".repeat(32);
        manager
            .storage
            .sync_co_members(std::slice::from_ref(&departed), DIR_NOW)
            .unwrap();
        manager.storage.sync_co_members(&[], DIR_NOW).unwrap();
        assert!(directory_row(&manager, &departed).is_some());

        assert!(
            manager
                .ranked_directory_members(DIR_NOW + DIR_RETENTION + 1)
                .expect("directory read")
                .is_empty(),
            "past the window, the read must offer nobody"
        );
        // Read back at a clock that cannot sweep: a display filter would still
        // have the row here.
        assert!(
            directory_row(&manager, &departed).is_none(),
            "and must have deleted them, not hidden them"
        );
    }

    #[tokio::test]
    async fn removing_a_member_deletes_their_row_before_the_commit_is_published() {
        // Owner decision D3, the "you remove them" direction. Deleting at
        // staging time is deliberate: until this returns, the person the user
        // just removed is still one tap from being re-offered as a co-member.
        let circle = setup_two_party_circle().await;
        let bob_hex = circle.bob_keys.public_key().to_hex();
        assert!(circle
            .alice
            .reconcile_member_directory(DirectoryReconcile::Rewrite, DIR_NOW)
            .await
            .unwrap());
        assert!(directory_row(&circle.alice, &bob_hex).is_some());

        circle
            .alice
            .remove_members_staging(&circle.mls_group_id, std::slice::from_ref(&bob_hex), 0)
            .await
            .expect("stage removal");

        assert!(
            directory_row(&circle.alice, &bob_hex).is_none(),
            "the removal must not wait for a relay ack, and must not age out"
        );
    }

    #[tokio::test]
    async fn being_removed_from_a_circle_deletes_its_co_members_immediately() {
        // Owner decision D3, the "they remove you" direction. `Group.removed`
        // is the only signal for it, and it survives until an authenticated
        // re-join or a branch selection that supersedes the removal.
        let circle = setup_two_party_circle().await;
        let alice_hex = circle.alice_keys.public_key().to_hex();
        // Stamped at [`DIR_FAR_FUTURE`] so a mere DEMOTION would still be
        // readable afterwards: the write site below reconciles on the wall
        // clock, and a row whose deadline the wall clock has passed would be
        // swept whether or not anything severed it.
        circle
            .bob
            .storage
            .sync_co_members(std::slice::from_ref(&alice_hex), DIR_FAR_FUTURE)
            .unwrap();
        assert_eq!(
            far_future_row(&circle.bob, &alice_hex).unwrap().tier,
            DirectoryTier::Current
        );

        let commit = circle
            .alice
            .remove_members_for_test(
                &circle.mls_group_id,
                &[circle.bob_keys.public_key().to_hex()],
            )
            .await
            .expect("stage removal");
        circle
            .bob
            .ingest_for_test(&commit)
            .await
            .expect("bob applies his own eviction");

        assert!(
            matches!(
                circle
                    .bob
                    .session()
                    .converged_member_pubkeys(&circle.mls_group_id)
                    .await
                    .unwrap(),
                ConvergedRoster::Converged { removed: true, .. }
            ),
            "precondition: the engine records the eviction"
        );
        assert!(
            !circle
                .bob
                .storage
                .has_leave_intent(&circle.mls_group_id)
                .unwrap(),
            "precondition: bob never asked to leave — this is the other direction"
        );
        assert!(
            far_future_row(&circle.bob, &alice_hex).is_none(),
            "a severed co-membership is deleted, not retained for three days"
        );
    }

    #[tokio::test]
    async fn a_location_message_never_touches_the_directory() {
        // §5.5: decrypting a kind-445 is not a membership signal. An
        // application message may be sealed up to `app_message_past_epoch_limit`
        // epochs behind the tip, so treating a sender as a co-member would
        // resurrect someone removed several epochs ago.
        let circle = setup_two_party_circle().await;
        let bob_hex = circle.bob_keys.public_key().to_hex();
        let send = || async {
            circle
                .bob
                .seal_location_for_test(&circle.mls_group_id, &LocationMessage::new(1.0, 2.0))
                .await
                .expect("bob sends")
                .0
        };
        let live = send().await;
        let held_back = send().await;

        // A tripwire only a reconcile can move: this pubkey is in no circle, so
        // any rewrite demotes it out of `Current`.
        let tripwire = "cc".repeat(32);
        circle
            .alice
            .storage
            .sync_co_members(&[bob_hex.clone(), tripwire.clone()], DIR_NOW)
            .unwrap();

        let results = circle.alice.ingest_for_test(&live).await.unwrap();
        assert!(
            results
                .iter()
                .any(|r| matches!(r, LocationMessageResult::Location { .. })),
            "precondition: the message really decrypted"
        );
        assert_eq!(
            directory_row(&circle.alice, &tripwire).unwrap().tier,
            DirectoryTier::Current,
            "a decrypted location must not trigger a rewrite"
        );

        // Now Bob is removed and his row is gone; the message he sealed at the
        // earlier epoch cannot bring it back.
        circle
            .alice
            .remove_members_for_test(&circle.mls_group_id, std::slice::from_ref(&bob_hex))
            .await
            .expect("stage removal");
        assert!(directory_row(&circle.alice, &bob_hex).is_none());

        circle
            .alice
            .ingest_for_test(&held_back)
            .await
            .expect("the past-epoch message is handled, whatever the verdict");
        assert!(
            directory_row(&circle.alice, &bob_hex).is_none(),
            "a past-epoch message from a removed member must not resurrect them"
        );
    }

    #[tokio::test]
    async fn the_union_spans_every_circle_in_one_pass() {
        // Constraint §4.3: callers pass the union across all circles, never a
        // per-circle partition — which is also what stops a row being tied to a
        // circle by its write time.
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let manager = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();
        let (_first, first_hex) = create_confirmed_circle(&manager, &keys, "First").await;
        let (_second, second_hex) = create_confirmed_circle(&manager, &keys, "Second").await;

        assert!(manager
            .reconcile_member_directory(DirectoryReconcile::Rewrite, DIR_NOW)
            .await
            .unwrap());

        let first = directory_row(&manager, &first_hex).expect("first circle's member");
        let second = directory_row(&manager, &second_hex).expect("second circle's member");
        assert_eq!(first.tier, DirectoryTier::Current);
        assert_eq!(second.tier, DirectoryTier::Current);
        assert_eq!(
            (first.tier, first.last_shared_day, first.purge_after),
            (second.tier, second.last_shared_day, second.purge_after),
            "one pass across all circles: every field the row stores is equal, \
             so no member of one circle is stamped apart from a member of another"
        );
    }

    #[tokio::test]
    async fn the_local_identity_is_never_its_own_directory_entry() {
        let circle = setup_two_party_circle().await;
        assert!(circle
            .alice
            .reconcile_member_directory(DirectoryReconcile::Rewrite, DIR_NOW)
            .await
            .unwrap());

        let entries = directory_of(&circle.alice);
        assert!(entries
            .iter()
            .any(|(pk, _)| *pk == circle.bob_keys.public_key().to_hex()));
        assert!(
            !entries
                .iter()
                .any(|(pk, _)| *pk == circle.alice_keys.public_key().to_hex()),
            "the directory lists other people; a self row would offer the user \
             to themselves"
        );
    }

    #[tokio::test]
    async fn a_welcome_preview_writes_no_directory_row() {
        // Pre-accept a welcome is seal-authenticated only — anyone can gift-wrap
        // one — and a row written here would break decline-leaves-no-trace.
        let relays = vec!["wss://relay.test.com".to_string()];
        let alice_dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap();
        let bob_dir = TempDir::new().unwrap();
        let bob_keys = Keys::generate();
        let bob = CircleManager::new_unencrypted(bob_dir.path(), &bob_keys).unwrap();

        let bob_kp_event = make_kp_event(&bob, &bob_keys, &relays).await;
        let config = CircleConfig::new("Preview").with_relays(relays.clone());
        let creation = alice
            .create_circle(
                &alice_keys,
                vec![MemberKeyPackage {
                    key_package_event: bob_kp_event,
                    inbox_relays: relays.clone(),
                    nip65_relays: vec![],
                    nip65_write_relays: vec![],
                }],
                &config,
            )
            .await
            .expect("create circle");
        let welcome = creation.welcome_events.first().expect("one welcome");

        bob.process_gift_wrapped_invitation(&bob_keys, &welcome.event)
            .await
            .expect("bob holds the welcome");
        assert!(
            directory_of(&bob).is_empty(),
            "holding a welcome must write nobody"
        );

        bob.accept_invitation(&welcome.event.id)
            .await
            .expect("bob accepts");
        assert!(
            directory_row(&bob, &alice_keys.public_key().to_hex()).is_some(),
            "accepting is what makes the roster real"
        );
    }

    #[test]
    fn only_membership_signals_ask_for_a_directory_rewrite() {
        let location = || LocationMessageResult::Location {
            sender_pubkey: "aa".repeat(32),
            content: String::new(),
            group_id: random_group_id(),
            epoch: 1,
        };
        let update = || LocationMessageResult::GroupUpdate {
            group_id: random_group_id(),
        };
        let joined = || LocationMessageResult::Joined {
            group_id: random_group_id(),
        };
        let invalidated = || LocationMessageResult::Invalidated {
            group_id: random_group_id(),
        };
        let unrecoverable = || LocationMessageResult::Unrecoverable {
            group_id: random_group_id(),
        };

        assert_eq!(DirectoryReconcile::for_receive_results(&[]), None);
        assert_eq!(
            DirectoryReconcile::for_receive_results(&[location()]),
            None,
            "a decrypted kind-445 may be up to five epochs old and is never a \
             membership signal"
        );
        assert_eq!(
            DirectoryReconcile::for_receive_results(&[unrecoverable()]),
            None,
            "an unrecoverable group's roster is frozen at its last stable epoch"
        );
        assert_eq!(
            DirectoryReconcile::for_receive_results(&[update()]),
            Some(DirectoryReconcile::Rewrite)
        );
        assert_eq!(
            DirectoryReconcile::for_receive_results(&[joined()]),
            Some(DirectoryReconcile::Rewrite)
        );
        assert_eq!(
            DirectoryReconcile::for_receive_results(&[invalidated()]),
            Some(DirectoryReconcile::RewriteWithdrawing)
        );
        assert_eq!(
            DirectoryReconcile::for_receive_results(&[
                location(),
                update(),
                invalidated(),
                unrecoverable()
            ]),
            Some(DirectoryReconcile::RewriteWithdrawing),
            "a withdrawal in the batch outranks an ordinary rewrite"
        );
    }

    #[test]
    fn the_engine_event_verdict_matches_the_folded_one() {
        let group_id = random_group_id();
        assert_eq!(
            DirectoryReconcile::for_group_events(&[GroupEvent::GroupCreated {
                group_id: group_id.clone()
            }]),
            None,
            "a local create is not an inbound membership change"
        );
        assert_eq!(
            DirectoryReconcile::for_group_events(&[GroupEvent::EpochChanged {
                group_id: group_id.clone(),
                from: crate::nostr::mls::types::EpochId(1),
                to: crate::nostr::mls::types::EpochId(2),
            }]),
            Some(DirectoryReconcile::Rewrite)
        );
        assert_eq!(
            DirectoryReconcile::for_group_events(&[
                GroupEvent::GroupUnrecoverable {
                    group_id: group_id.clone()
                },
                GroupEvent::GroupStateInvalidated {
                    group_id,
                    epoch: crate::nostr::mls::types::EpochId(1),
                    invalidated_commit_id: crate::nostr::mls::types::MessageId::new(vec![1]),
                    reason: cgka_traits::engine::GroupStateInvalidationReason::
                        SupersededByBranchSelection,
                },
            ]),
            Some(DirectoryReconcile::RewriteWithdrawing)
        );
    }

    #[tokio::test]
    async fn an_unknown_group_reads_as_absent_rather_than_a_read_failure() {
        // `find_group` collapses quarantine and "never seen" into `None`; this
        // accessor must make the same call so a stored circle row with no live
        // group is skipped instead of aborting every reconcile.
        let (manager, _keys, _dir) = create_test_manager();
        assert_eq!(
            manager
                .session()
                .converged_member_pubkeys(&random_group_id())
                .await
                .unwrap(),
            ConvergedRoster::Absent
        );
        assert!(manager.session().quarantined_group_ids().await.is_empty());
    }

    #[tokio::test]
    async fn a_circle_row_with_no_live_group_is_skipped_not_treated_as_empty() {
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let manager = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();
        let (_gid, member_hex) = create_confirmed_circle(&manager, &keys, "Live").await;
        // A stored circle whose MLS group the engine never held.
        save_stored_circle(&manager, MembershipStatus::Accepted);

        assert!(manager
            .reconcile_member_directory(DirectoryReconcile::Rewrite, DIR_NOW)
            .await
            .unwrap());
        assert_eq!(
            directory_of(&manager),
            vec![(member_hex, DirectoryTier::Current)]
        );
    }

    // ── Welcome-delivery cascade ─────────────────────────────────────────────

    #[tokio::test]
    async fn welcome_delivery_goes_to_the_invitees_inbox_relays_alone() {
        // Haven listens for gift wraps only on its kind-10050 inbox relays, so a
        // Welcome sent to a NIP-65 relay or to the sender's own inbox is lost.
        let dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(dir.path(), &alice_keys).unwrap();
        alice
            .add_user_relay(
                "wss://creator-inbox.example.com",
                crate::circle::relay_prefs::RelayType::Inbox,
            )
            .unwrap();
        let config = CircleConfig::new("Inbox Circle")
            .with_relays(vec!["wss://group.example.com".to_string()]);

        let member = make_member_with_relays(
            vec!["wss://member-inbox.example.com".to_string()],
            vec!["wss://member-nip65.example.com".to_string()],
        )
        .await;
        let result = alice
            .create_circle(&alice_keys, vec![member], &config)
            .await
            .expect("creation routes the Welcome to the invitee's inbox");
        assert_eq!(
            result.welcome_events[0].recipient_relays,
            vec!["wss://member-inbox.example.com".to_string()]
        );

        let without_inbox =
            make_member_with_relays(vec![], vec!["wss://member-nip65.example.com".to_string()])
                .await;
        let err = alice
            .create_circle(&alice_keys, vec![without_inbox], &config)
            .await
            .expect_err("neither a NIP-65 relay nor the creator's inbox is a route");
        assert!(matches!(err, CircleError::MissingWelcomeRelays));
        assert_eq!(alice.get_circles().await.expect("get_circles").len(), 1);
    }

    #[tokio::test]
    async fn welcome_delivery_drops_an_inbox_relay_haven_may_not_dial() {
        // The invitee wrote that list, not this device's user: an entry that
        // steers a socket at a plain-text, private or loopback host is dropped
        // whatever the caller resolved.
        let dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(dir.path(), &alice_keys).unwrap();
        let config = CircleConfig::new("Filtered Circle")
            .with_relays(vec!["wss://group.example.com".to_string()]);
        let undialable = [
            "ws://plain.example.com",
            "wss://10.0.0.1",
            "wss://127.0.0.1",
            "https://not-a-relay.example.com",
        ]
        .map(String::from);

        let mut inbox = undialable.to_vec();
        inbox.push("wss://member-inbox.example.com".to_string());
        let member = make_member_with_relays(inbox, vec![]).await;
        let result = alice
            .create_circle(&alice_keys, vec![member], &config)
            .await
            .expect("the dialable inbox relay is a route");
        assert_eq!(
            result.welcome_events[0].recipient_relays,
            vec!["wss://member-inbox.example.com".to_string()]
        );

        let member = make_member_with_relays(undialable.to_vec(), vec![]).await;
        let err = alice
            .create_circle(&alice_keys, vec![member], &config)
            .await
            .expect_err("no inbox relay Haven may dial is no route");
        assert!(matches!(err, CircleError::MissingWelcomeRelays));
    }

    #[tokio::test]
    async fn welcome_delivery_errors_when_no_relays() {
        let dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(dir.path(), &alice_keys).unwrap();

        let member = make_member_with_relays(vec![], vec![]).await;
        let config = CircleConfig::new("Fail Closed Circle")
            .with_relays(vec!["wss://group.example.com".to_string()]);

        let err = alice
            .create_circle(&alice_keys, vec![member], &config)
            .await
            .expect_err("creation must fail closed when no delivery relay exists");
        assert!(matches!(err, CircleError::MissingWelcomeRelays));
        assert_eq!(err.to_string(), "No reachable relay for welcome delivery");
        // No phantom state: failing closed persists NO circle.
        let circles = alice.get_circles().await.expect("get_circles");
        assert!(
            circles.is_empty(),
            "fail-closed create_circle must leave no circle in storage"
        );
    }

    // ── Group-relay-set derivation (`circle.relays`, `create_circle`) ────────
    //
    // A relay set the caller names is the circle's, verbatim; an empty one is
    // drawn from the location pool (`circle::location_pool`, proved end to end
    // in `tests/location_pool_e2e.rs`) and never from the creator's own lists.

    #[tokio::test]
    async fn create_circle_relays_are_the_passed_relays_not_the_creator_inbox() {
        // A named set is honoured as-is, even one the pick would avoid (here an
        // invitee's inbox). The creator's OWN configured inbox relay is a
        // DIFFERENT URL, so a passing assertion can only be explained by the
        // passed-in value winning — never by anything read from storage.
        const INVITEE_RELAY: &str = "wss://invitee.example.com";
        const CREATOR_INBOX_RELAY: &str = "wss://creator-inbox.example.com";

        let dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(dir.path(), &alice_keys).unwrap();
        alice
            .add_user_relay(
                CREATOR_INBOX_RELAY,
                crate::circle::relay_prefs::RelayType::Inbox,
            )
            .unwrap();

        let member = make_member_with_relays(vec![INVITEE_RELAY.to_string()], vec![]).await;
        let config =
            CircleConfig::new("Invitee Relay Circle").with_relays(vec![INVITEE_RELAY.to_string()]);

        let creation = alice
            .create_circle(&alice_keys, vec![member], &config)
            .await
            .expect("create");

        assert_eq!(
            creation.circle.relays,
            vec![INVITEE_RELAY.to_string()],
            "a non-empty passed-in relay set must be used as-is"
        );
        assert!(
            !creation
                .circle
                .relays
                .contains(&CREATOR_INBOX_RELAY.to_string()),
            "the creator's own configured inbox relay must NOT appear when the \
             caller named the relays"
        );
    }

    #[tokio::test]
    async fn create_circle_returns_the_name_as_stored_not_as_typed() {
        // The returned struct is itself a rendering path — the caller draws the
        // new circle from it before anything re-reads storage — so asserting on
        // a re-read here would prove nothing about what gets drawn. Bidi
        // override + zero-width space: exactly what `sanitize_circle_name`
        // strips, so an unsanitized return cannot pass by accident.
        const TYPED: &str = "Fa\u{202E}mi\u{200B}ly";

        let relays = vec!["wss://relay.test.com".to_string()];
        let dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(dir.path(), &alice_keys).unwrap();

        let member = make_member_with_relays(relays.clone(), vec![]).await;
        let config = CircleConfig::new(TYPED).with_relays(relays.clone());

        let creation = alice
            .create_circle(&alice_keys, vec![member], &config)
            .await
            .expect("create");

        assert_eq!(
            creation.circle.display_name, "Family",
            "create_circle must hand back the sanitized name it stored, not the \
             raw one it was handed"
        );
    }

    // ── Founding create: canonical on return (Rule 13) ───────────────────────

    #[tokio::test]
    async fn create_circle_is_canonical_without_a_confirm() {
        // A current-profile create returns `FoundingGroupCreated` with no
        // pending ref (MDK `cgka-session/src/lib.rs:268-270`): the group is
        // live and Stable at once, with nothing confirmed, and it survives a
        // restart — at MDK v0.9.4 an unconfirmed create was a staged commit
        // hydrate cleared.
        let relays = vec!["wss://relay.test.com".to_string()];
        let dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(dir.path(), &alice_keys).unwrap();

        let member = make_member_with_relays(relays.clone(), vec![]).await;
        let config = CircleConfig::new("Founded Circle").with_relays(relays.clone());
        let creation = alice
            .create_circle(&alice_keys, vec![member], &config)
            .await
            .expect("create");
        let gid = creation.circle.mls_group_id.clone();

        assert_eq!(alice.get_circles().await.unwrap().len(), 1);
        assert!(
            matches!(
                alice.session.epoch_state(&gid).await,
                Some(crate::nostr::mls::types::EpochState::Stable { .. })
            ),
            "a founded group is Stable on return — nothing is pending"
        );

        drop(alice);
        let reopened = CircleManager::new_unencrypted(dir.path(), &alice_keys).unwrap();
        assert_eq!(reopened.get_circles().await.unwrap().len(), 1);
        assert!(
            matches!(
                reopened.session.epoch_state(&gid).await,
                Some(crate::nostr::mls::types::EpochState::Stable { .. })
            ),
            "the founded group survives a restart: hydrate has nothing to roll back"
        );
    }

    #[tokio::test]
    async fn create_route_error_abandons_the_founded_group_and_leaves_no_row() {
        // Exercise the internal helper directly so `route_welcomes_with_cascade`
        // fails AFTER the MLS group is founded and the rows saved (a member with
        // no delivery relay and no creator fallback). A founded group cannot be
        // rolled back, so the error path must forget it locally and leave NO
        // orphan circle row and no MLS group.
        let dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(dir.path(), &alice_keys).unwrap();

        let member = make_member_with_relays(vec![], vec![]).await; // undeliverable
        let group_relays = vec!["wss://group.example.com".to_string()];
        let mls_config = LocationGroupConfig::new("Route Error Circle")
            .with_relays(group_relays.iter().map(String::as_str))
            .with_admin(alice_keys.public_key().to_hex());
        let config = CircleConfig::new("Route Error Circle").with_relays(group_relays.clone());
        let kp_events = vec![member.key_package_event.clone()];

        let result = alice
            .create_circle_with_config(&[member], kp_events, mls_config, &config, 0)
            .await;
        assert!(
            matches!(result, Err(CircleError::MissingWelcomeRelays)),
            "welcome routing must fail closed for an undeliverable member"
        );

        assert!(
            alice.get_circles().await.unwrap().is_empty(),
            "a post-create route error must leave no ghost circle row"
        );
        assert!(
            alice.session.live_group_ids().await.unwrap().is_empty(),
            "the founded group's MLS state must be forgotten, not left orphaned"
        );
        // A fresh, deliverable create then works cleanly.
        let ok_member =
            make_member_with_relays(vec!["wss://relay.test.com".to_string()], vec![]).await;
        let ok_config = CircleConfig::new("Recovered Circle")
            .with_relays(vec!["wss://relay.test.com".to_string()]);
        alice
            .create_circle(&alice_keys, vec![ok_member], &ok_config)
            .await
            .expect("a subsequent create is unaffected by the abandoned one");
        assert_eq!(alice.get_circles().await.unwrap().len(), 1);
    }

    /// The remedy the partial-send copy offers: an invitee whose invitation was
    /// never sent is still in the circle's tree (the commit that added them is
    /// applied), so they are removed, then invited again with a fresh
    /// `KeyPackage`, and that second invitation joins them.
    #[tokio::test]
    async fn an_invitee_whose_invitation_was_never_sent_can_be_removed_and_invited_again() {
        remove_an_unsent_invitee_and_invite_again(false).await;
    }

    /// The remedy as the app runs it: re-adding fetches the invitee's package
    /// again, and a last-resort package is the very same event.
    #[tokio::test]
    async fn re_inviting_with_the_same_key_package_event_joins_the_invitee() {
        remove_an_unsent_invitee_and_invite_again(true).await;
    }

    async fn remove_an_unsent_invitee_and_invite_again(same_event: bool) {
        let relays = vec!["wss://relay.test.com".to_string()];
        let alice_dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap();
        let bob_dir = TempDir::new().unwrap();
        let bob_keys = Keys::generate();
        let bob = CircleManager::new_unencrypted(bob_dir.path(), &bob_keys).unwrap();
        let bob_hex = bob_keys.public_key().to_hex();
        let member = |event| MemberKeyPackage {
            key_package_event: event,
            inbox_relays: relays.clone(),
            nip65_relays: vec![],
            nip65_write_relays: vec![],
        };

        let first_kp = make_kp_event(&bob, &bob_keys, &relays).await;
        let created = alice
            .create_circle(
                &alice_keys,
                vec![member(first_kp.clone())],
                &CircleConfig::new("Remedy Circle").with_relays(relays.clone()),
            )
            .await
            .expect("create");
        let gid = created.circle.mls_group_id.clone();
        // The Welcome is never published: Bob never hears of the circle.

        alice
            .remove_members_for_test(&gid, std::slice::from_ref(&bob_hex))
            .await
            .expect("an unsent invitee can be removed");
        assert!(!alice
            .session
            .member_pubkeys(&gid)
            .await
            .unwrap()
            .contains(&bob_hex));

        let second_kp = if same_event {
            first_kp
        } else {
            make_kp_event(&bob, &bob_keys, &relays).await
        };
        let readded = alice
            .add_members_for_test(&gid, &[member(second_kp)])
            .await
            .expect("and invited again");
        let welcome = &readded.1[0];
        bob.process_gift_wrapped_invitation(&bob_keys, welcome)
            .await
            .expect("bob receives the new invitation");
        bob.accept_invitation(&welcome.id)
            .await
            .expect("and the second invitation joins him");
        assert!(bob
            .session
            .member_pubkeys(&gid)
            .await
            .unwrap()
            .contains(&bob_hex));
    }

    #[tokio::test]
    async fn a_founded_group_whose_rows_do_not_save_is_abandoned() {
        let dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(dir.path(), &alice_keys).unwrap();
        alice
            .storage
            .conn()
            .lock()
            .unwrap()
            .execute_batch(
                "CREATE TRIGGER test_membership_fault BEFORE INSERT ON circle_memberships
                 BEGIN SELECT RAISE(ABORT, 'injected'); END;",
            )
            .unwrap();
        let relays = vec!["wss://relay.test.com".to_string()];
        let member = make_member_with_relays(relays.clone(), vec![]).await;

        let result = alice
            .create_circle(
                &alice_keys,
                vec![member],
                &CircleConfig::new("Unsaved Circle").with_relays(relays.clone()),
            )
            .await;

        assert!(result.is_err(), "a create whose rows cannot be saved fails");
        assert!(
            alice.get_circles().await.unwrap().is_empty(),
            "and leaves no half-saved circle row"
        );
        assert!(
            alice.session.live_group_ids().await.unwrap().is_empty(),
            "nor the founded group's MLS state, which no one else knows about"
        );
    }

    /// The abandon path's two warnings say which half failed, by code alone.
    #[tokio::test]
    async fn abandoning_reports_each_failed_half_without_an_identifier() {
        use crate::nostr::mls::storage::{set_engine_write_fault_for_test, EngineWrite};
        let tp = setup_two_party_circle().await;
        let key = crate::nostr::mls::StorageConfig::test_sqlcipher_key().unwrap();
        let db = crate::nostr::mls::StorageConfig::new(tp.alice_dir.path()).database_path();
        set_engine_write_fault_for_test(&db, &key, EngineWrite::ForgetGroup, true).unwrap();
        tp.alice
            .storage
            .conn()
            .lock()
            .unwrap()
            .execute_batch(
                "CREATE TRIGGER test_circle_delete_fault BEFORE DELETE ON circles
                 BEGIN SELECT RAISE(ABORT, 'injected'); END;",
            )
            .unwrap();

        let lines =
            crate::test_log::capture_log_lines(tp.alice.abandon_founded_group(&tp.mls_group_id))
                .await;
        set_engine_write_fault_for_test(&db, &key, EngineWrite::ForgetGroup, false).unwrap();

        for half in ["MLS forget failed", "circle-row cleanup failed"] {
            assert!(
                lines.iter().any(|line| line.contains(half)),
                "the failure of each half is reported: {half}"
            );
        }
        assert_no_identifier(&lines, &two_party_needles(&tp));
    }

    #[tokio::test]
    async fn a_failed_intent_retirement_says_so_without_an_identifier() {
        let tp = setup_two_party_circle().await;
        let unknown = QueuedIntentRef {
            group_id: tp.mls_group_id.clone(),
            intent_id: cgka_traits::types::MessageId::new(vec![0xAB; 32]),
        };
        let lines =
            crate::test_log::capture_log_lines(tp.alice.retire_released_intent(Some(&unknown)))
                .await;
        assert!(
            lines
                .iter()
                .any(|line| line.contains("retiring a released queued intent failed")),
            "a retirement the engine refused is reported"
        );
        let mut needles = two_party_needles(&tp);
        needles.push("ab".repeat(32));
        assert_no_identifier(&lines, &needles);
    }

    /// Every identifier a two-party circle's log lines could leak.
    fn two_party_needles(tp: &TwoPartyCircle) -> Vec<String> {
        vec![
            hex::encode(tp.mls_group_id.as_slice()),
            hex::encode(tp.nostr_group_id),
            tp.alice_keys.public_key().to_hex(),
            tp.bob_keys.public_key().to_hex(),
            "relay.test.com".to_string(),
        ]
    }

    /// No line carries a needle or its first eight characters.
    fn assert_no_identifier(lines: &[String], needles: &[String]) {
        for line in lines {
            for needle in needles {
                let prefix: String = needle.chars().take(8).collect();
                assert!(
                    !line.contains(needle.as_str()) && !line.contains(&prefix),
                    "a log line carries an identifier: {line}"
                );
            }
        }
    }

    #[test]
    fn fold_surfaces_pending_commit_recovered_as_group_update() {
        // Rust F1: the ingest/drain fold path must surface a hydrate-emitted
        // PendingCommitRecovered as a GroupUpdate (drive resync), not drop it.
        use crate::nostr::mls::types::EpochId;
        let gid = GroupId::new(vec![7, 7, 7]);
        let folded = fold_group_events(&[GroupEvent::PendingCommitRecovered {
            group_id: gid,
            recovered_epoch: EpochId(2),
        }]);
        assert!(
            matches!(
                folded.as_slice(),
                [LocationMessageResult::GroupUpdate { .. }]
            ),
            "a drained PendingCommitRecovered must fold to a GroupUpdate, got {folded:?}"
        );
    }

    // ── Basic construction / empty getters ───────────────────────────────────

    #[test]
    fn new_creates_manager() {
        let (_manager, _keys, _dir) = create_test_manager();
    }

    #[tokio::test]
    async fn get_circles_returns_empty_initially() {
        let (manager, _keys, _dir) = create_test_manager();
        assert!(manager.get_circles().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn get_visible_circles_returns_empty_initially() {
        let (manager, _keys, _dir) = create_test_manager();
        assert!(manager.get_visible_circles().await.unwrap().is_empty());
    }

    /// A manager that held an invitation before a restart: only the durable
    /// marker says so.
    fn manager_with_a_held_invitation() -> (CircleManager, Keys, TempDir) {
        let (manager, keys, dir) = create_test_manager();
        manager
            .storage
            .set_held_invitation_outstanding(true)
            .unwrap();
        (manager, keys, dir)
    }

    fn waits(manager: &CircleManager, now_secs: u64) -> bool {
        manager
            .consumed_key_package_replacement_waits(now_secs)
            .unwrap()
    }

    /// The hold a held invitation puts on a consumed `KeyPackage` is counted
    /// from the first call that waited, ends after 72 hours whatever is still
    /// held, and is over once a replacement was acknowledged.
    #[test]
    fn a_consumed_key_package_waits_for_a_held_invitation_for_72_hours_from_the_first_wait() {
        let (manager, _keys, _dir) = create_test_manager();
        assert!(
            !waits(&manager, 1_000),
            "nothing is held: nothing to wait for"
        );
        assert_eq!(manager.storage.consumed_hold_since().unwrap(), None);

        manager
            .storage
            .set_held_invitation_outstanding(true)
            .unwrap();
        let first = 1_000_000;
        for inside in [first, first + 1, first + CONSUMED_KEY_PACKAGE_HOLD_SECS - 1] {
            assert!(waits(&manager, inside));
        }
        assert_eq!(manager.storage.consumed_hold_since().unwrap(), Some(first));
        for past in [first + CONSUMED_KEY_PACKAGE_HOLD_SECS, u64::MAX] {
            assert!(
                !waits(&manager, past),
                "at the bound the wait is over, an invitation still held or not"
            );
        }

        // A replacement that was itself consumed in flight ends this hold and
        // keeps the marker: the next consumption gets a hold of its own. Any
        // other acknowledged replacement clears both.
        manager.note_key_package_replaced(true);
        assert_eq!(manager.storage.consumed_hold_since().unwrap(), None);
        assert!(manager.held_invitations_outstanding().unwrap());
        let next = first + 10 * CONSUMED_KEY_PACKAGE_HOLD_SECS;
        assert!(waits(&manager, next));
        assert_eq!(manager.storage.consumed_hold_since().unwrap(), Some(next));
        manager.note_key_package_replaced(false);
        assert!(!manager.held_invitations_outstanding().unwrap());
        assert!(!waits(&manager, next));
    }

    /// No clock movement buys a consumed key more time. A clock that reads
    /// earlier than the hold's start ends the hold instead of restarting it,
    /// and a hold that has ended does not resume wherever the clock goes
    /// next: only an acknowledged replacement lets a new one start.
    #[test]
    fn a_clock_set_back_ends_the_hold_and_nothing_resumes_or_restarts_it() {
        const HOLD: u64 = CONSUMED_KEY_PACKAGE_HOLD_SECS;
        let first = 1_000_000;

        // Behind the start: over at once, and still over after every further
        // step — back again, and forward into what was the hold's window.
        let (manager, _keys, _dir) = manager_with_a_held_invitation();
        assert!(waits(&manager, first));
        for now in [
            first - 1,
            first - 500_000,
            first - 1,
            first,
            first + 1,
            first + HOLD - 1,
        ] {
            assert!(
                !waits(&manager, now),
                "a clock set back behind the start ended the hold for good"
            );
        }

        // Run out but not yet acknowledged: a step back does not resume it,
        // into the window or behind the start.
        let (manager, _keys, _dir) = manager_with_a_held_invitation();
        assert!(waits(&manager, first));
        assert!(!waits(&manager, first + HOLD));
        for now in [first + HOLD - 1, first + 1, first, first - 1] {
            assert!(!waits(&manager, now), "a hold that ran out stays over");
        }

        // The acknowledged replacement ends it; the next consumption's hold is
        // counted from its own first wait, wherever the clock is by then.
        manager.note_key_package_replaced(true);
        let earlier = first - 500_000;
        assert!(waits(&manager, earlier));
        assert!(waits(&manager, earlier + HOLD - 1));
        assert!(!waits(&manager, earlier + HOLD));
    }

    /// A hold start that cannot be read is no start: it gives the one bounded
    /// hold an absent one gives, never an unbounded one and never a second.
    #[test]
    fn an_unreadable_hold_start_gives_exactly_one_bounded_hold() {
        const HOLD: u64 = CONSUMED_KEY_PACKAGE_HOLD_SECS;
        let (manager, _keys, _dir) = manager_with_a_held_invitation();
        crate::circle::storage_key_packages::plant_hold_start(&manager.storage, "not a second");

        let first = 1_000_000;
        assert!(waits(&manager, first));
        assert_eq!(manager.storage.consumed_hold_since().unwrap(), Some(first));
        assert!(waits(&manager, first + HOLD - 1));
        for past in [first + HOLD, first + HOLD + 1, first + 2 * HOLD] {
            assert!(!waits(&manager, past));
        }
    }

    #[test]
    fn get_pending_invitations_returns_empty_initially() {
        let (manager, _keys, _dir) = create_test_manager();
        assert!(manager.get_pending_invitations().unwrap().is_empty());
    }

    #[tokio::test]
    async fn pending_invitation_reports_the_seal_authenticated_inviter() {
        // FE-2 regression pin: a processed-but-unaccepted welcome must surface
        // the ONE identity a pre-join peel proves — the NIP-59 seal author —
        // through BOTH the process return and the pending list. It must surface
        // nothing else: the roster is inside the still-encrypted Welcome, so a
        // member count here could only ever have been a fabricated constant.
        let relays = vec!["wss://relay.test.com".to_string()];
        let alice_dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap();
        let bob_dir = TempDir::new().unwrap();
        let bob_keys = Keys::generate();
        let bob = CircleManager::new_unencrypted(bob_dir.path(), &bob_keys).unwrap();
        let bob_kp_event = make_kp_event(&bob, &bob_keys, &relays).await;
        let bob_member = MemberKeyPackage {
            key_package_event: bob_kp_event,
            inbox_relays: relays.clone(),
            nip65_relays: vec![],
            nip65_write_relays: vec![],
        };
        let config = CircleConfig::new("Test Circle").with_relays(relays.clone());
        let creation = alice
            .create_circle(&alice_keys, vec![bob_member], &config)
            .await
            .expect("create circle");
        let welcome = creation.welcome_events.first().expect("one welcome");

        let processed = bob
            .process_gift_wrapped_invitation(&bob_keys, &welcome.event)
            .await
            .expect("bob holds welcome");
        assert_eq!(processed.inviter_pubkey, alice_keys.public_key().to_hex());

        let pending = bob.get_pending_invitations().unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(
            pending[0].inviter_pubkey,
            alice_keys.public_key().to_hex(),
            "the pending list must preserve the seal-authenticated inviter"
        );
    }

    /// A Welcome-delivery relay must enter the contamination ledger, because
    /// the cascade is the ONLY place it is ever observed on device.
    ///
    /// The cascade resolves an invitee's delivery relays from their `KeyPackage`
    /// at send time; the result is written to neither `circles.relays` nor
    /// `user_relays`. So unlike every other contamination source, this one
    /// cannot be reconstructed later by `refresh_contamination_ledger` — if the
    /// write site regresses, the relay is invisible to the profile-pool
    /// exclusion forever, and Haven will happily route kind-0 traffic to a
    /// relay that already received this user's gift-wrapped Welcome.
    ///
    /// The invitee's inbox relay is deliberately DISJOINT from the circle's
    /// routing relays, so a passing assertion cannot be explained by the
    /// `CircleRouting` write site — the URL can only have reached the ledger
    /// through the Welcome cascade.
    #[tokio::test]
    async fn welcome_cascade_relays_are_recorded_as_contaminated() {
        const CIRCLE_RELAY: &str = "wss://circle-routing.test";
        const BOB_INBOX_RELAY: &str = "wss://bob-only-inbox.test";

        let circle_relays = vec![CIRCLE_RELAY.to_string()];
        let alice_dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap();

        // Bob is reachable ONLY at his own inbox relay, which Alice's circle
        // never routes through.
        let bob_member = make_member_with_relays(vec![BOB_INBOX_RELAY.to_string()], vec![]).await;

        let config = CircleConfig::new("Cascade Circle").with_relays(circle_relays.clone());
        let creation = alice
            .create_circle(&alice_keys, vec![bob_member], &config)
            .await
            .expect("create circle");

        // Non-vacuity: the cascade really did select Bob's inbox relay, so the
        // ledger assertion below is about a relay that was actually used.
        let welcome = creation.welcome_events.first().expect("one welcome");
        assert!(
            welcome
                .recipient_relays
                .iter()
                .any(|r| r.contains("bob-only-inbox")),
            "precondition: the cascade must have routed to Bob's inbox relay, \
             got {:?}",
            welcome.recipient_relays,
        );

        let ledger: Vec<String> = alice.storage.list_contaminated_relays().unwrap();
        assert!(
            ledger.iter().any(|r| r.contains("bob-only-inbox")),
            "the Welcome delivery relay is missing from the contamination \
             ledger — it is recorded nowhere else on device, so the profile \
             pool would keep treating it as clean and route kind-0 to a relay \
             that already holds this user's gift-wrapped Welcome. ledger={ledger:?}",
        );

        // The circle's own routing relay is contaminated too, by a different
        // write site. Asserting both keeps the test honest about which URL
        // proves which path.
        assert!(
            ledger.iter().any(|r| r.contains("circle-routing")),
            "the circle routing relay should also be contaminated: {ledger:?}",
        );
    }

    #[test]
    fn get_all_contacts_returns_empty_initially() {
        let (manager, _keys, _dir) = create_test_manager();
        assert!(manager.get_all_contacts().unwrap().is_empty());
    }

    // ── Contacts (local-only, sync) ──────────────────────────────────────────

    #[test]
    fn set_and_get_contact() {
        let (manager, _keys, _dir) = create_test_manager();
        let pk = Keys::generate().public_key().to_hex();
        let contact = manager
            .set_contact(&pk, Some("Alice"), Some("note"))
            .unwrap();
        assert_eq!(contact.display_name.as_deref(), Some("Alice"));
        let fetched = manager.get_contact(&pk).unwrap().unwrap();
        assert_eq!(fetched.display_name.as_deref(), Some("Alice"));
        assert_eq!(fetched.notes.as_deref(), Some("note"));
    }

    #[test]
    fn set_contact_updates_existing() {
        let (manager, _keys, _dir) = create_test_manager();
        let pk = Keys::generate().public_key().to_hex();
        let first = manager.set_contact(&pk, Some("Old"), None).unwrap();
        let second = manager.set_contact(&pk, Some("New"), None).unwrap();
        assert_eq!(second.display_name.as_deref(), Some("New"));
        assert_eq!(first.created_at, second.created_at, "created_at preserved");
    }

    #[test]
    fn delete_contact_removes_it() {
        let (manager, _keys, _dir) = create_test_manager();
        let pk = Keys::generate().public_key().to_hex();
        manager.set_contact(&pk, Some("X"), None).unwrap();
        manager.delete_contact(&pk).unwrap();
        assert!(manager.get_contact(&pk).unwrap().is_none());
    }

    #[test]
    fn get_contact_nonexistent_returns_none() {
        let (manager, _keys, _dir) = create_test_manager();
        let pk = Keys::generate().public_key().to_hex();
        assert!(manager.get_contact(&pk).unwrap().is_none());
    }

    #[tokio::test]
    async fn get_circle_nonexistent_returns_none() {
        let (manager, _keys, _dir) = create_test_manager();
        assert!(manager
            .get_circle(&random_group_id())
            .await
            .unwrap()
            .is_none());
    }

    // ── Stored-data getters (storage-only, no live MLS group) ─────────────────

    #[tokio::test]
    async fn get_circles_with_stored_data() {
        let (manager, _keys, _dir) = create_test_manager();
        save_stored_circle(&manager, MembershipStatus::Accepted);
        let circles = manager.get_circles().await.unwrap();
        assert_eq!(circles.len(), 1);
        // A stored-only circle (no live MLS group) tolerates an empty roster.
        assert!(circles[0].members.is_empty());
    }

    #[tokio::test]
    async fn get_visible_circles_filters_declined() {
        let (manager, _keys, _dir) = create_test_manager();
        save_stored_circle(&manager, MembershipStatus::Accepted);
        save_stored_circle(&manager, MembershipStatus::Declined);
        assert_eq!(manager.get_circles().await.unwrap().len(), 2);
        assert_eq!(manager.get_visible_circles().await.unwrap().len(), 1);
    }

    // ── MIP-01 group-relay update (admin) + member convergence ───────────────

    #[tokio::test]
    async fn admin_relay_update_converges_admin_and_member() {
        let tp = setup_two_party_circle().await;
        let new_relays = vec![
            "wss://relay.test.com".to_string(),
            "wss://relay2.test.com".to_string(),
        ];

        tp.alice
            .update_circle_relays_staging(&tp.mls_group_id, &new_relays, 0)
            .await
            .expect("admin must be allowed to update relays");

        // Publish-before-apply: before a relay takes it, the admin's app row is
        // unchanged.
        let alice_before = tp
            .alice
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(
            alice_before.relays, tp.relays,
            "circle.relays must not change before the commit is confirmed"
        );

        let update = tp
            .alice
            .land_staged_for_test()
            .await
            .pop()
            .expect("the update lands");

        let expected = sorted_relays(&new_relays);
        let alice_after = tp
            .alice
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(
            alice_after.relays, expected,
            "admin circle.relays must converge to the new set after confirm"
        );

        // The member (Bob) processes the commit through the REAL consumer path.
        let results = tp
            .bob
            .ingest_for_test(&update)
            .await
            .expect("bob processes the relay-update commit");
        assert!(
            results
                .iter()
                .any(|r| matches!(r, LocationMessageResult::GroupUpdate { .. })),
            "a routing-component commit must surface as GroupUpdate, got {results:?}"
        );
        let bob_after = tp
            .bob
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(
            bob_after.relays, expected,
            "member circle.relays must converge to the new set"
        );
        assert_eq!(
            alice_after.relays, bob_after.relays,
            "no split-brain: admin and member end on the same relay set"
        );
    }

    #[tokio::test]
    async fn admin_relay_replacement_drops_old_relay_and_converges() {
        let tp = setup_two_party_circle().await;
        let new_relays = vec!["wss://relay2.test.com".to_string()];

        let update = tp
            .alice
            .update_relays_for_test(&tp.mls_group_id, &new_relays)
            .await
            .expect("admin replaces the relay set");

        let expected = sorted_relays(&new_relays);
        let dropped = "wss://relay.test.com".to_string();

        let alice_after = tp
            .alice
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(alice_after.relays, expected);
        assert!(!alice_after.relays.contains(&dropped));

        let results = tp
            .bob
            .ingest_for_test(&update)
            .await
            .expect("bob processes the replacement commit");
        assert!(results
            .iter()
            .any(|r| matches!(r, LocationMessageResult::GroupUpdate { .. })));
        let bob_after = tp
            .bob
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(bob_after.relays, expected);
        assert!(!bob_after.relays.contains(&dropped));
        assert_eq!(alice_after.relays, bob_after.relays);
    }

    #[tokio::test]
    async fn non_admin_relay_update_is_rejected_and_changes_nothing() {
        let tp = setup_two_party_circle().await;
        // Bob is a plain member — the engine enforces admin-only routing commits.
        let result = tp
            .bob
            .update_circle_relays_staging(
                &tp.mls_group_id,
                &["wss://relay2.test.com".to_string()],
                0,
            )
            .await;
        assert!(
            matches!(result, Err(CircleError::Mls(_))),
            "the engine must reject a non-admin relay update, got {result:?}"
        );
        let bob_circle = tp
            .bob
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(bob_circle.relays, tp.relays);
    }

    #[tokio::test]
    async fn update_circle_relays_rejects_empty_set() {
        let tp = setup_two_party_circle().await;
        assert!(matches!(
            tp.alice
                .update_circle_relays_staging(&tp.mls_group_id, &[], 0)
                .await,
            Err(CircleError::InvalidData(_))
        ));
        let circle = tp
            .alice
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(circle.relays, tp.relays, "no commit staged on rejection");
    }

    #[tokio::test]
    async fn update_circle_relays_rejects_oversized_set() {
        let tp = setup_two_party_circle().await;
        let ledger = tp.alice.storage.list_contaminated_relays().unwrap();
        let many: Vec<String> = (0..17)
            .map(|i| format!("wss://relay{i}.test.com"))
            .collect();
        assert!(matches!(
            tp.alice
                .update_circle_relays_staging(&tp.mls_group_id, &many, 0)
                .await,
            Err(CircleError::InvalidData(_))
        ));
        assert_eq!(
            tp.alice.storage.list_contaminated_relays().unwrap(),
            ledger,
            "a refused relay set was recorded as carrying group traffic",
        );
    }

    /// A relay set MDK's routing component would refuse — more than 16
    /// relays, the old 20-relay cap included, or an entry too long to carry —
    /// is refused typed, before anything is recorded or staged; 16 is taken.
    #[tokio::test]
    async fn a_relay_set_the_engine_would_refuse_is_refused_typed_before_anything_is_recorded() {
        let tp = setup_two_party_circle().await;
        let ledger = tp.alice.storage.list_contaminated_relays().unwrap();
        let named = |count: usize| -> Vec<String> {
            (0..count)
                .map(|i| format!("wss://relay{i}.test.com"))
                .collect()
        };
        let long = vec![format!("wss://{}.test.com", "r".repeat(512))];
        for refused in [named(17), named(20), long] {
            assert!(
                matches!(
                    tp.alice
                        .update_circle_relays_staging(&tp.mls_group_id, &refused, 0)
                        .await,
                    Err(CircleError::InvalidData(_))
                ),
                "a set the engine would refuse was not refused typed",
            );
            assert_eq!(
                tp.alice.storage.list_contaminated_relays().unwrap(),
                ledger,
                "a refused relay set was recorded as carrying group traffic",
            );
            assert!(
                tp.alice
                    .session()
                    .fanout_ids_for_test(&tp.mls_group_id)
                    .await
                    .unwrap()
                    .is_empty(),
                "a refused relay set staged a commit",
            );
        }
        assert!(circle_relays(&named(16)).is_ok_and(|set| set.len() == 16));
    }

    /// One relay entry an admin might type: valid, upper-case and slashed,
    /// plaintext, another scheme, with credentials or a fragment, hostless,
    /// too long, a duplicate, or on a loopback, private or link-local host.
    fn relay_entry() -> impl proptest::strategy::Strategy<Value = String> {
        use proptest::prelude::*;
        prop_oneof![
            "[a-z]{1,8}".prop_map(|h| format!("wss://{h}.example.com")),
            "[a-z]{1,8}".prop_map(|h| format!("WSS://{h}.Example.com/")),
            "[a-z]{1,8}".prop_map(|h| format!("ws://{h}.example.com")),
            "[a-z]{1,8}".prop_map(|h| format!("https://{h}.example.com")),
            "[a-z]{1,8}".prop_map(|h| format!("wss://user:pw@{h}.example.com")),
            "[a-z]{1,8}".prop_map(|h| format!("wss://{h}.example.com/#frag")),
            Just("wss://".to_string()),
            Just(format!("wss://{}.example.com", "r".repeat(500))),
            Just("wss://dup.example.com".to_string()),
            "[a-z]{1,8}".prop_map(|h| format!("wss://{h}.localhost")),
            Just("wss://10.0.0.1".to_string()),
            Just("wss://[fe80::1]".to_string()),
        ]
    }

    proptest::proptest! {
        /// The circle's relay check accepts exactly what every entry's
        /// normalization, Haven's rule for a relay another client dials and
        /// MDK's routing component accept, and what it accepts round-trips
        /// MDK's codec (V17).
        #[test]
        fn routing_validation_matches_the_engine(
            entries in proptest::collection::vec(relay_entry(), 0..=24)
        ) {
            use cgka_traits::app_components::{
                decode_nostr_routing_v1, encode_nostr_routing_v1, NostrRoutingV1,
            };
            let normalized: Option<Vec<String>> = entries
                .iter()
                .map(|entry| super::super::storage_relay_prefs::normalize_url(entry).ok())
                .collect();
            let expected = normalized.and_then(|set| {
                let mut set = set;
                set.sort();
                set.dedup();
                (!set.is_empty()
                    && set.iter().all(|relay| crate::relay::foreign_relay_dialable(relay)))
                .then_some(set)
                .and_then(|set| NostrRoutingV1::new([7; 32], set).ok())
            });
            let got = circle_relays(&entries);
            proptest::prop_assert_eq!(got.is_ok(), expected.is_some());
            if let (Ok(set), Some(routing)) = (got, expected) {
                proptest::prop_assert_eq!(&set, &routing.relays);
                let decoded = decode_nostr_routing_v1(
                    &encode_nostr_routing_v1(&routing).expect("an accepted set encodes"),
                )
                .expect("an accepted set decodes");
                proptest::prop_assert_eq!(decoded.relays, set);
            }
        }
    }

    #[tokio::test]
    async fn update_circle_relays_rejects_plaintext_ws() {
        let tp = setup_two_party_circle().await;
        // Shares `normalize_url` with the user relay list, so the rejection is
        // the typed, user-presentable one rather than the opaque bucket.
        let err = tp
            .alice
            .update_circle_relays_staging(&tp.mls_group_id, &["ws://relay.test.com".to_string()], 0)
            .await
            .expect_err("a plaintext ws:// circle relay must be rejected");
        assert!(
            matches!(
                err,
                CircleError::InvalidRelayInput(crate::circle::RelayInputRejection::PlaintextWs)
            ),
            "expected the plaintext-ws rejection, got {err:?}"
        );
    }

    #[tokio::test]
    async fn resync_is_idempotent_noop_when_already_converged() {
        let tp = setup_two_party_circle().await;
        let before = tp
            .alice
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .unwrap();
        tp.alice
            .resync_circle_relays_from_mdk(&tp.mls_group_id)
            .await
            .expect("resync");
        let after = tp
            .alice
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(before.relays, after.relays);
    }

    /// A circle whose routing changed keeps the relays it left as an address
    /// its traffic is fetched at — on the member that applied the change and
    /// on the admin that made it — for as long as an epoch that used them can
    /// still be fetched (the wider retained-history window), and no longer
    /// (`app-components/nostr-routing-v1.md` 56-62). The change here is of
    /// relays; a rotated routing id is kept the same way
    /// (`foreign_routing_entry_e2e`).
    #[tokio::test]
    async fn a_prior_routing_is_an_address_until_its_epochs_age_out() {
        let tp = setup_two_party_circle().await;
        let before = tp
            .alice
            .get_circle(&tp.mls_group_id)
            .await
            .unwrap()
            .unwrap()
            .circle
            .relays;
        let renamed = vec!["wss://renamed.relay-canary7d2a.example.com".to_string()];
        let update = tp
            .alice
            .update_relays_for_test(&tp.mls_group_id, &renamed)
            .await
            .expect("alice stages the relay change");
        tp.bob
            .ingest_for_test(&update)
            .await
            .expect("bob applies it");
        let mut both = [before.clone(), renamed.clone()].concat();
        both.sort();
        for (who, member) in [("the admin", &tp.alice), ("the member", &tp.bob)] {
            assert_eq!(
                member.routing_addresses(&tp.mls_group_id, &renamed).await,
                both,
                "{who} does not fetch at the relays the circle left",
            );
        }
        for _ in 0..=routing_retained_epochs() {
            let effects = tp
                .alice
                .session()
                .send(crate::nostr::mls::types::SendIntent::SelfUpdate {
                    group_id: tp.mls_group_id.clone(),
                })
                .await
                .expect("a self-update");
            let pending = effects
                .publish
                .iter()
                .find_map(|work| match work {
                    PublishWork::GroupEvolution { pending, .. } => Some(*pending),
                    _ => None,
                })
                .expect("the commit is staged");
            tp.alice
                .session()
                .confirm_published(pending)
                .await
                .expect("applied");
        }
        assert_eq!(
            tp.alice.routing_addresses(&tp.mls_group_id, &renamed).await,
            renamed,
            "a prior routing outlived the epochs that used it",
        );
    }

    /// A routing id is taken when another circle holds it — as its routing id
    /// or a prior routing's — and not when only the circle itself used it
    /// before: a rotation back to its own prior id is followed.
    #[tokio::test]
    async fn a_routing_id_another_circle_used_is_taken_and_ones_own_prior_is_not() {
        let tp = setup_two_party_circle().await;
        let other = Circle {
            mls_group_id: GroupId::from_slice(&[0x5A; 32]),
            nostr_group_id: [0x5B; 32],
            display_name: "Other".to_string(),
            circle_type: CircleType::LocationSharing,
            relays: Vec::new(),
            created_at: 1,
            updated_at: 1,
        };
        tp.alice.storage.save_circle(&other).unwrap();
        let relays = vec!["wss://prior.example.com".to_string()];
        let prior = |nostr_group_id| PriorRouting {
            nostr_group_id,
            relays: &relays,
            until_epoch: 1,
            oldest_kept: 0,
            written_at: 1,
        };
        tp.alice
            .storage
            .keep_prior_routing(&other.mls_group_id, &prior([0x5C; 32]))
            .unwrap();
        tp.alice
            .storage
            .keep_prior_routing(&tp.mls_group_id, &prior([0x5D; 32]))
            .unwrap();
        for (id, taken) in [
            ([0x5B; 32], true),
            ([0x5C; 32], true),
            ([0x5D; 32], false),
            ([0x5E; 32], false),
        ] {
            assert_eq!(
                tp.alice
                    .other_circle_with_routing_id(&id, &tp.mls_group_id, UnreadEpoch::Holds)
                    .await
                    .unwrap(),
                taken.then(|| other.mls_group_id.clone()),
                "{id:?}"
            );
        }
    }

    /// A leave whose proposal was recorded at one epoch and never
    /// acknowledged, in a circle a peer's commit has since moved on — the
    /// engine re-minting the leave for the new epoch and nothing recording
    /// it — is answered unrecorded, never as already proposed, and nothing
    /// notes the new epoch's proposal as recorded: the earlier epoch's record,
    /// still standing, says nothing of a proposal no relay was handed.
    #[tokio::test]
    async fn an_earlier_epochs_standing_record_answers_no_later_leave_as_proposed() {
        use crate::relay::fanout::{DriveMode, Still};
        let tp = setup_two_party_circle().await;
        let full = DriveMode::Full;
        let first = tp
            .bob
            .propose_leave_staging(&tp.mls_group_id, 0, Still::always(&full))
            .await
            .expect("the leave is staged");
        assert!(
            matches!(first, LeaveStep::Recorded(_)),
            "premise: recorded at the first epoch, no relay called"
        );
        let changed = tp
            .alice
            .session()
            .update_relays(&tp.mls_group_id, vec!["wss://moved.test.com".to_string()])
            .await
            .expect("the admin changes the relays");
        let (msg, pending) = changed
            .publish
            .iter()
            .find_map(|work| match work {
                PublishWork::GroupEvolution { msg, pending, .. } => Some((msg, *pending)),
                _ => None,
            })
            .expect("a commit");
        tp.alice.session().confirm_published(pending).await.unwrap();
        let commit = crate::nostr::mls::SessionManager::transport_message_to_event(msg).unwrap();
        let _ = tp.bob.session().process_event(&commit).await.unwrap();
        let applied = tp
            .bob
            .session()
            .settle_receive_for_test(&tp.mls_group_id)
            .await
            .unwrap();
        // A receive advance takes inputs only; the full one re-mints the leave.
        let reminted = tp
            .bob
            .session()
            .advance_convergence(&tp.mls_group_id)
            .await
            .unwrap();
        assert!(
            applied
                .publish
                .iter()
                .chain(&reminted.publish)
                .any(|work| matches!(work, PublishWork::Proposal { .. })),
            "premise: the engine re-minted the leave for the new epoch, handed to nobody"
        );
        let later = tp.bob.session().leave_proposed_epoch(&tp.mls_group_id);
        assert!(
            !tp.bob
                .session()
                .fanout_ids_for_test(&tp.mls_group_id)
                .await
                .unwrap()
                .is_empty(),
            "premise: the earlier epoch's record still stands"
        );

        let again = tp
            .bob
            .propose_leave_staging(&tp.mls_group_id, 0, Still::always(&full))
            .await
            .expect("the leave is asked again");
        let marked = tp
            .bob
            .storage
            .leave_recorded_epoch(&tp.mls_group_id)
            .unwrap();
        assert!(
            matches!(again, LeaveStep::Unrecorded(_)) && marked != later,
            "an earlier epoch's record answered a later epoch's unrecorded leave as proposed, \
             or noted it as recorded"
        );
    }

    /// A prior routing id past the window an epoch that used it is retained
    /// for is nobody's — nothing sent under it can be peeled any more — and a
    /// rotation or a Welcome onto it holds nothing; one inside the window is
    /// its circle's.
    #[tokio::test]
    async fn a_prior_routing_id_past_its_epochs_is_nobodys() {
        let tp = setup_two_party_circle().await;
        for step in 0..=routing_retained_epochs() {
            let relays = vec![format!("wss://step{step}.example.com")];
            tp.alice
                .update_relays_for_test(&tp.mls_group_id, &relays)
                .await
                .expect("alice changes the relays");
        }
        let epoch = tp.alice.session.epoch(&tp.mls_group_id).await.unwrap();
        assert!(
            epoch > routing_retained_epochs(),
            "premise: the circle is past its window"
        );
        let relays = vec!["wss://prior.example.com".to_string()];
        for (id, until_epoch) in [([0x71; 32], 0), ([0x72; 32], epoch)] {
            tp.alice
                .storage
                .keep_prior_routing(
                    &tp.mls_group_id,
                    &PriorRouting {
                        nostr_group_id: id,
                        relays: &relays,
                        until_epoch,
                        oldest_kept: 0,
                        written_at: 1,
                    },
                )
                .unwrap();
        }
        let asking = GroupId::from_slice(&[0x70; 32]);
        assert_eq!(
            tp.alice
                .other_circle_with_routing_id(&[0x71; 32], &asking, UnreadEpoch::Holds)
                .await
                .unwrap(),
            None,
            "a prior routing past its epochs held a circle",
        );
        assert_eq!(
            tp.alice
                .other_circle_with_routing_id(&[0x72; 32], &asking, UnreadEpoch::Holds)
                .await
                .unwrap(),
            Some(tp.mls_group_id.clone()),
            "a prior routing inside its epochs was nobody's",
        );
    }

    /// A prior routing that names a circle's routing id, for a circle whose
    /// epoch cannot be read, holds nothing at a reconcile: the read is asked
    /// again at the next one. A hold that ends only with a leave is never set
    /// on two healthy circles for a read that failed once.
    #[tokio::test]
    async fn a_reconcile_that_cannot_read_a_holders_epoch_holds_nothing() {
        let tp = setup_two_party_circle().await;
        // A prior routing of a group the engine does not hold: its epoch
        // cannot be read.
        let unreadable = GroupId::from_slice(&[0x7c; 32]);
        tp.alice
            .storage
            .conn()
            .lock()
            .unwrap()
            .execute(
                "INSERT INTO routing_history
                 (mls_group_id, until_epoch, nostr_group_id, relays, written_at)
                 VALUES (?1, 5, ?2, '[]', 1)",
                rusqlite::params![unreadable.as_slice(), &tp.nostr_group_id[..]],
            )
            .unwrap();
        tp.alice.reconcile_routing().await;
        assert!(
            !tp.alice.session().routing_collided(&tp.mls_group_id),
            "a holder whose epoch could not be read held a circle until it is left",
        );
    }

    /// A routing whose prior cannot be kept is not followed at all — the row
    /// never names a routing whose prior is lost — and that is said in a
    /// line that names no circle and no relay; once the store can keep it
    /// again, the next reconcile follows. A prior routing that cannot be
    /// read is said the same way, and the circle's current relays are still
    /// its address.
    #[tokio::test]
    async fn a_prior_routing_not_kept_or_read_is_said_without_an_identifier() {
        let tp = setup_two_party_circle().await;
        let schema: String = tp
            .alice
            .storage
            .conn()
            .lock()
            .unwrap()
            .query_row(
                "SELECT sql FROM sqlite_master WHERE name = 'routing_history'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        tp.alice
            .storage
            .conn()
            .lock()
            .unwrap()
            .execute_batch("DROP TABLE routing_history;")
            .unwrap();
        let renamed = vec!["wss://renamed.relay-canary8f3b.example.com".to_string()];
        let relays_now = || {
            tp.alice
                .storage
                .get_circle(&tp.mls_group_id)
                .unwrap()
                .unwrap()
                .relays
        };
        let lines = Box::pin(crate::test_log::capture_log_lines(async {
            tp.alice
                .update_relays_for_test(&tp.mls_group_id, &renamed)
                .await
                .expect("alice changes the relays");
            assert_eq!(
                tp.alice.routing_addresses(&tp.mls_group_id, &renamed).await,
                renamed,
            );
        }))
        .await;
        assert_ne!(
            relays_now(),
            renamed,
            "the row followed a routing whose prior was not kept",
        );
        for expected in [
            "relay re-sync failed",
            "a circle's prior routing was not read",
        ] {
            assert!(
                lines.iter().any(|line| line.contains(expected)),
                "a prior routing's failure was not said: {expected}",
            );
        }
        let mut needles = two_party_needles(&tp);
        needles.push("relay-canary8f3b".to_string());
        assert_no_identifier(&lines, &needles);

        tp.alice
            .storage
            .conn()
            .lock()
            .unwrap()
            .execute_batch(&schema)
            .unwrap();
        tp.alice.reconcile_routing().await;
        assert_eq!(relays_now(), renamed, "the reconcile did not follow");
    }

    /// A resync that finds the circle's routing as its row has it writes
    /// nothing: a contamination ledger that cannot be written fails no
    /// reconcile of a circle that did not move.
    #[tokio::test]
    async fn a_resync_that_changes_nothing_writes_nothing() {
        let tp = setup_two_party_circle().await;
        tp.bob
            .storage
            .conn()
            .lock()
            .unwrap()
            .execute_batch("ALTER TABLE contaminated_relays RENAME TO contaminated_unwritable;")
            .unwrap();
        assert!(
            !tp.bob
                .resync_circle_relays_from_mdk(&tp.mls_group_id)
                .await
                .expect("a resync of an unmoved circle needs no write"),
            "an unmoved circle was followed",
        );
    }

    /// The routing reconcile's two lines name no circle, member or relay:
    /// one circle whose follow fails beside one that follows, and a store
    /// whose circles cannot be read at all.
    #[tokio::test]
    async fn the_routing_reconcile_says_what_failed_without_an_identifier() {
        let tp = setup_two_party_circle().await;
        // A row with no engine group behind it: its follow cannot be made.
        let stray = [0x5e; 32];
        tp.alice.keep_circle_row_for_test(stray);
        let mut needles = two_party_needles(&tp);
        needles.push(hex::encode(stray));

        let lines =
            crate::test_log::capture_log_lines(async { tp.alice.reconcile_routing().await }).await;
        assert!(
            lines
                .iter()
                .any(|line| line.contains("routing reconcile:") && line.contains("not followed")),
            "a reconcile with a circle it could not follow did not say so",
        );
        assert_no_identifier(&lines, &needles);

        tp.alice
            .storage
            .conn()
            .lock()
            .unwrap()
            .execute_batch("ALTER TABLE circles RENAME TO circles_unread;")
            .unwrap();
        let lines =
            crate::test_log::capture_log_lines(async { tp.alice.reconcile_routing().await }).await;
        assert!(
            lines
                .iter()
                .any(|line| line.contains("routing reconcile: the circles were not read")),
            "a reconcile that could not read the circles did not say so",
        );
        assert_no_identifier(&lines, &needles);
    }

    /// Alice's commit rotating the circle's routing id to `rotated`, as
    /// another client's admin would make it, confirmed on her side.
    async fn alice_rotates_to(tp: &TwoPartyCircle, rotated: [u8; 32]) -> nostr::Event {
        use crate::nostr::mls::types::{AppComponentData, SendIntent};
        use cgka_traits::app_components::{
            encode_nostr_routing_v1, NostrRoutingV1, NOSTR_ROUTING_COMPONENT_ID,
        };
        let effects = tp
            .alice
            .session()
            .send(SendIntent::UpdateAppComponents {
                group_id: tp.mls_group_id.clone(),
                updates: vec![AppComponentData {
                    component_id: NOSTR_ROUTING_COMPONENT_ID,
                    data: encode_nostr_routing_v1(
                        &NostrRoutingV1::new(rotated, tp.relays.clone()).unwrap(),
                    )
                    .unwrap(),
                }],
            })
            .await
            .expect("alice rotates the routing id, as another client would");
        let (msg, pending) = effects
            .publish
            .iter()
            .find_map(|work| match work {
                PublishWork::GroupEvolution { msg, pending, .. } => Some((msg.clone(), *pending)),
                _ => None,
            })
            .expect("staged");
        tp.alice.session().confirm_published(pending).await.unwrap();
        SessionManager::transport_message_to_event(&msg).unwrap()
    }

    /// A store that cannot say whether a rotated id is another circle's is
    /// answered as an error: nothing is followed, no collision is claimed in
    /// a line, the rotated circle IS held — MDK has moved its route, and the
    /// circle it may have taken it from cannot be named — and once the store
    /// answers again the next reconcile follows.
    #[tokio::test]
    async fn a_store_that_cannot_say_whether_an_id_is_taken_follows_nothing_and_holds_the_circle() {
        let tp = setup_two_party_circle().await;
        let schema: String = tp
            .bob
            .storage
            .conn()
            .lock()
            .unwrap()
            .query_row(
                "SELECT sql FROM sqlite_master WHERE name = 'routing_history'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        tp.bob
            .storage
            .conn()
            .lock()
            .unwrap()
            .execute_batch("DROP TABLE routing_history;")
            .unwrap();
        let rotated = [0x6Bu8; 32];
        let commit = alice_rotates_to(&tp, rotated).await;
        let lines = Box::pin(crate::test_log::capture_log_lines(async {
            tp.bob
                .ingest_for_test(&commit)
                .await
                .expect("bob applies the rotation");
        }))
        .await;
        let row_id = || {
            tp.bob
                .storage
                .get_circle(&tp.mls_group_id)
                .unwrap()
                .unwrap()
                .nostr_group_id
        };
        assert_eq!(
            row_id(),
            tp.nostr_group_id,
            "a rotation was followed unread"
        );
        assert!(
            lines
                .iter()
                .any(|line| line.contains("could not be read; its sends are held"))
                && !lines
                    .iter()
                    .any(|line| line.contains("onto one another circle holds")),
            "a store error was not said, or was said as a collision",
        );
        let held = || async {
            matches!(
                tp.bob
                    .session()
                    .held_away(&tp.mls_group_id, DriveMode::Full)
                    .await,
                Some(crate::nostr::mls::AwayHold::RoutingCollision)
            )
        };
        assert!(
            held().await,
            "a routing id MDK gave the circle that the store could not check left it sharing",
        );
        let mut needles = two_party_needles(&tp);
        needles.push(hex::encode(rotated));
        assert_no_identifier(&lines, &needles);

        tp.bob
            .storage
            .conn()
            .lock()
            .unwrap()
            .execute_batch(&schema)
            .unwrap();
        tp.bob.reconcile_routing().await;
        assert_eq!(row_id(), rotated, "the reconcile did not follow");
        assert!(held().await, "the hold ended before the circle was left");
    }

    /// A member learns an admin's relay change from the commit, and the fold
    /// that applied it writes the circle's row. When that write fails the
    /// commit stands, the fold goes on, and one line says so — naming no
    /// circle and no relay.
    #[tokio::test]
    async fn a_relay_resync_that_fails_in_the_fold_is_said_without_an_identifier() {
        let tp = setup_two_party_circle().await;
        let renamed = vec!["wss://renamed.relay-canary5e1c.example.com".to_string()];
        let update = tp
            .alice
            .update_relays_for_test(&tp.mls_group_id, &renamed)
            .await
            .expect("alice stages the relay change");
        tp.bob
            .storage
            .conn()
            .lock()
            .unwrap()
            .execute_batch(
                "CREATE TRIGGER test_circle_update_fault BEFORE UPDATE ON circles
                 BEGIN SELECT RAISE(ABORT, 'injected'); END;",
            )
            .unwrap();

        let lines = Box::pin(crate::test_log::capture_log_lines(async {
            tp.bob
                .ingest_for_test(&update)
                .await
                .expect("the commit is applied whatever becomes of the row");
        }))
        .await;

        assert!(
            lines
                .iter()
                .any(|line| line.contains("relay re-sync failed (will retry on next commit)")),
            "a circle row that could not follow its commit was not reported"
        );
        let mut needles = two_party_needles(&tp);
        needles.push("relay-canary5e1c".to_string());
        assert_no_identifier(&lines, &needles);
        assert_eq!(
            tp.bob.session.group_relays(&tp.mls_group_id).await.unwrap(),
            renamed,
            "premise: the engine holds the new list"
        );
        assert_eq!(
            tp.bob
                .storage
                .get_circle(&tp.mls_group_id)
                .unwrap()
                .unwrap()
                .relays,
            tp.relays,
            "premise: the row could not follow"
        );
    }

    // DELETED-WITH-SUBJECT: `resync_never_overwrites_nonempty_relays_with_empty`
    // drove the hazard via `mdk.update_relays(&[])` — the UNVALIDATED empty relay
    // update. The session's `routing_of` (MDK's `NostrRoutingV1::new`) now rejects
    // an empty set at the source (both `update_relays` and `create_group`), so the engine never
    // holds an empty routing set and the hazard is unreachable from the public
    // API. The defensive `if engine_relays.is_empty()` guard in
    // `resync_circle_relays_from_mdk` remains but cannot be driven.

    // ── Leave planning + local teardown ──────────────────────────────────────

    #[tokio::test]
    async fn plan_leave_non_admin_member_returns_non_admin() {
        let tp = setup_two_party_circle().await;
        let plan = tp
            .bob
            .plan_leave(&tp.mls_group_id, &tp.bob_keys.public_key())
            .await
            .expect("plan_leave for non-admin");
        assert!(matches!(plan, LeavePlan::NonAdmin));
    }

    #[tokio::test]
    async fn plan_leave_sole_admin_with_member_returns_handoff() {
        let tp = setup_two_party_circle().await;
        let plan = tp
            .alice
            .plan_leave(&tp.mls_group_id, &tp.alice_keys.public_key())
            .await
            .expect("plan_leave for sole admin");
        let LeavePlan::AdminHandoff { successor } = plan else {
            panic!("expected AdminHandoff, got {plan:?}");
        };
        assert_eq!(successor, tp.bob_keys.public_key());
    }

    #[tokio::test]
    async fn plan_leave_nonexistent_group_returns_orphan() {
        let (manager, _keys, _dir) = create_test_manager();
        let self_pk = Keys::generate().public_key();
        let plan = manager
            .plan_leave(&GroupId::from_slice(&[0u8; 32]), &self_pk)
            .await
            .expect("plan_leave should succeed for missing group");
        assert!(matches!(plan, LeavePlan::OrphanLocalOnly));
    }

    #[tokio::test]
    async fn admin_handoff_end_to_end() {
        // The full `LeavePlan::AdminHandoff` sequence: promote Bob, self-demote
        // Alice, then leave. Each step is asserted through the engine's own
        // admin view (`admin_pubkeys`) on BOTH sides, so a commit that Alice
        // applies locally but that Bob cannot ingest would fail here.
        let tp = setup_two_party_circle().await;
        let alice_pk = tp.alice_keys.public_key().to_bytes();
        let bob_pk = tp.bob_keys.public_key().to_bytes();

        assert_eq!(
            tp.alice
                .session()
                .admin_pubkeys(&tp.mls_group_id)
                .await
                .expect("alice admins"),
            vec![alice_pk],
            "the creator starts as the sole admin"
        );

        // Step 1 — promote Bob. The policy is additive: Alice stays an admin so
        // the group is never admin-less at an intermediate epoch.
        let promote = tp
            .alice
            .admin_handoff_for_test(&tp.mls_group_id, &tp.bob_keys.public_key())
            .await
            .expect("promote successor");
        tp.bob
            .ingest_for_test(&promote)
            .await
            .expect("bob ingests the promote commit");
        for (who, mgr) in [("alice", &tp.alice), ("bob", &tp.bob)] {
            let mut admins = mgr
                .session()
                .admin_pubkeys(&tp.mls_group_id)
                .await
                .unwrap_or_else(|e| panic!("{who} admins after promote: {e}"));
            admins.sort_unstable();
            let mut expected = vec![alice_pk, bob_pk];
            expected.sort_unstable();
            assert_eq!(admins, expected, "{who} must see BOTH admins after promote");
        }

        // Step 2 — Alice demotes herself, leaving Bob as sole admin.
        let demote = tp
            .alice
            .self_demote_for_test(&tp.mls_group_id)
            .await
            .expect("self demote");
        tp.bob
            .ingest_for_test(&demote)
            .await
            .expect("bob ingests the demote commit");
        for (who, mgr) in [("alice", &tp.alice), ("bob", &tp.bob)] {
            assert_eq!(
                mgr.session()
                    .admin_pubkeys(&tp.mls_group_id)
                    .await
                    .unwrap_or_else(|e| panic!("{who} admins after demote: {e}")),
                vec![bob_pk],
                "{who} must see Bob as the sole admin after Alice's self-demote"
            );
        }

        // Step 3 — the SelfRemove the admin gate previously rejected now passes.
        // This is the behavioral proof that the handoff actually cleared the
        // `AdminCannotSelfRemove` gate, not merely that two commits landed.
        tp.alice
            .propose_leave(&tp.mls_group_id)
            .await
            .expect("a demoted admin may finally SelfRemove")
            .expect("a first leave in this epoch proposes");
    }

    #[tokio::test]
    async fn propose_self_demote_by_sole_admin_is_rejected() {
        // The group must never be left admin-less: demoting without first
        // promoting a successor fails closed rather than emitting an empty
        // admin policy (which would brick every future membership commit).
        let tp = setup_two_party_circle().await;
        let err = tp
            .alice
            .self_demote_for_test(&tp.mls_group_id)
            .await
            .expect_err("the last admin must not be able to demote herself");
        assert!(matches!(err, CircleError::Mls(_)));
        assert!(
            !err.to_string()
                .to_lowercase()
                .contains(&hex::encode(tp.mls_group_id.as_slice())),
            "the last-admin error must not embed the MLS group id"
        );
        // The admin set is untouched — the rejection is a no-op, not a partial
        // apply that leaves the group in a half-demoted state.
        assert_eq!(
            tp.alice
                .session()
                .admin_pubkeys(&tp.mls_group_id)
                .await
                .expect("alice admins"),
            vec![tp.alice_keys.public_key().to_bytes()],
        );
    }

    // ── Epoch-rotation repair (Unit E / C4) ──────────────────────────────────

    /// A clock far enough past every rotation window for gates 3, 4 and 6 to be
    /// open on a circle whose rows were written "now".
    fn past_every_rotation_window() -> u64 {
        now_secs() + crate::circle::rotation::ROTATION_MIN_EPOCH_AGE_SECS + 3_600
    }

    /// The `nostr_group_id` of an in-flight `EpochChanged` observation.
    fn rotation_state(
        manager: &CircleManager,
        ngid: &[u8; 32],
    ) -> crate::circle::CircleRotationState {
        manager
            .storage
            .circle_rotation_state(ngid)
            .expect("rotation state")
    }

    #[tokio::test]
    async fn a_member_repairs_a_quiet_circle_and_the_peer_applies_the_commit() {
        let tp = setup_two_party_circle().await;
        let before = tp
            .alice
            .session()
            .epoch(&tp.mls_group_id)
            .await
            .expect("alice epoch");

        let (RepairOutcome::Rotated(_), Some(commit)) = tp
            .alice
            .repair_rotation_for_test(&tp.mls_group_id, past_every_rotation_window())
            .await
            .expect("the repair must not fail for a member of a quiet circle")
        else {
            panic!("a member of a quiet circle must rotate");
        };

        tp.bob
            .ingest_for_test(&commit)
            .await
            .expect("bob ingests the rotation commit");

        for (who, mgr) in [("alice", &tp.alice), ("bob", &tp.bob)] {
            assert_eq!(
                mgr.session()
                    .epoch(&tp.mls_group_id)
                    .await
                    .unwrap_or_else(|e| panic!("{who} epoch: {e}")),
                before + 1,
                "{who} must have applied the rotation"
            );
        }
        // A self-update changes this device's leaf alone, so the admin set is
        // unchanged — not a membership or permission change.
        assert_eq!(
            tp.bob
                .session()
                .admin_pubkeys(&tp.mls_group_id)
                .await
                .expect("bob admins"),
            vec![tp.alice_keys.public_key().to_bytes()],
        );
    }

    #[tokio::test]
    async fn a_repair_no_relay_acked_applies_nothing_and_leaves_the_circle_sending() {
        // Publish-before-apply (Rule 13) on the rotation path. A staged commit
        // that no relay accepted must roll back to the SAME epoch — otherwise
        // the author is a branch ahead of every peer, which is the fork the
        // engine's in-memory `committed_from` cannot reconcile across a restart
        // — and the circle must still be able to send afterwards.
        let tp = setup_two_party_circle().await;
        let before = tp
            .alice
            .session()
            .epoch(&tp.mls_group_id)
            .await
            .expect("alice epoch");

        let RepairOutcome::Rotated(rolled_back) = tp
            .alice
            .repair_rotation_refused_for_test(&tp.mls_group_id, past_every_rotation_window())
            .await
            .expect("repair")
        else {
            panic!("expected a rotation");
        };
        assert_eq!(
            rolled_back.status,
            crate::relay::fanout::EvolutionStatus::RolledBack,
            "premise: every relay refused the rotation",
        );

        assert_eq!(
            tp.alice
                .session()
                .epoch(&tp.mls_group_id)
                .await
                .expect("alice epoch"),
            before,
            "a rotation no relay acked must leave the epoch exactly where it was"
        );
        assert_eq!(
            tp.bob
                .session()
                .epoch(&tp.mls_group_id)
                .await
                .expect("bob epoch"),
            before,
            "control: the peer never saw the commit, so it cannot have moved either"
        );

        // The circle still SENDS — a rolled-back rotation must not leave the
        // group pinned in `PendingPublish`, where every later send would fail.
        let (event, ngid, _relays) = tp
            .alice
            .seal_location_for_test(&tp.mls_group_id, &LocationMessage::new(51.5, -0.12))
            .await
            .expect("a rolled-back rotation must not gate the next location send");
        assert_eq!(ngid, tp.nostr_group_id);
        let results = tp
            .bob
            .ingest_for_test(&event)
            .await
            .expect("bob ingests the location");
        assert!(
            results
                .iter()
                .any(|r| matches!(r, LocationMessageResult::Location { .. })),
            "the peer must still decrypt what the author sends after a rolled-back repair"
        );
    }

    #[tokio::test]
    async fn the_repair_emits_no_phantom_group_state_change_on_either_side() {
        // A self-update changes no membership, admin or group datum, so neither
        // the author nor the peer may synthesize a kind-1210 state-change row. A
        // phantom one would tell every member that something about the circle
        // changed when nothing did — a documentation-accuracy failure the user
        // reads directly.
        let tp = setup_two_party_circle().await;
        let StagedRepair::Rotated(staged) = tp
            .alice
            .repair_epoch_rotation_staging(
                &tp.mls_group_id,
                past_every_rotation_window(),
                0,
                Still::new(&DriveMode::Full, DriveMode::Full),
            )
            .await
            .expect("repair")
        else {
            panic!("expected a staged rotation");
        };
        let record = tp
            .alice
            .session()
            .fanout_probe_for_test(&staged.commit.expect("the rotation is recorded"))
            .await
            .expect("the record reads")
            .expect("the record is stored");
        let commit = Event::from_json(&record.payload).expect("the frozen commit");
        let Some(crate::nostr::mls::types::EpochState::PendingPublish(pending)) =
            tp.alice.session().epoch_state(&tp.mls_group_id).await
        else {
            panic!("premise: the rotation is staged");
        };

        // Author side: the session's own confirm effects, unfolded.
        let author = tp
            .alice
            .session()
            .confirm_published_past_its_fanout_for_test(pending.pending_ref())
            .await
            .expect("confirm");
        assert!(
            !author
                .events
                .iter()
                .any(|e| matches!(e, GroupEvent::GroupStateChanged { .. })),
            "the author's confirm must emit no GroupStateChanged: {:?}",
            author.events
        );
        assert!(
            author
                .events
                .iter()
                .any(|e| matches!(e, GroupEvent::EpochChanged { .. })),
            "control: the confirm must still report the epoch change"
        );

        // Peer side: the raw ingest effects and the advances that apply the
        // commit once its convergence pass closes, before any folding.
        let peer = tp
            .bob
            .session()
            .process_event(&commit)
            .await
            .expect("bob ingests");
        let mut events = peer
            .ingested()
            .expect("the commit reached the engine")
            .effects
            .events
            .clone();
        events.extend(
            tp.bob
                .session()
                .settle_receive_for_test(&tp.mls_group_id)
                .await
                .expect("bob settles the commit")
                .events,
        );
        assert!(
            !events
                .iter()
                .any(|e| matches!(e, GroupEvent::GroupStateChanged { .. })),
            "the peer's apply must emit no GroupStateChanged: {events:?}"
        );
        assert!(
            events
                .iter()
                .any(|e| matches!(e, GroupEvent::EpochChanged { .. })),
            "control: the peer must still report the epoch change"
        );
    }

    /// A proposal event whose content and `h` tag are recognisable, so a
    /// `Debug` that printed the wrapped event would be caught by the needles.
    const PROPOSAL_CONTENT: &str = "PROPOSAL-CIPHERTEXT-8f1c2d3e4a5b6c7d";
    const PROPOSAL_H_TAG: &str = "5e4d3c2b1a0f9e8d7c6b5a4938271605f4e3d2c1b0a99887766554433221100f";

    fn leaky_proposal() -> Event {
        let keys = Keys::generate();
        nostr::EventBuilder::new(nostr::Kind::Custom(445), PROPOSAL_CONTENT)
            .tag(nostr::Tag::custom(
                nostr::TagKind::custom("h"),
                [PROPOSAL_H_TAG],
            ))
            .sign_with_keys(&keys)
            .expect("sign the fixture proposal")
    }

    #[tokio::test]
    async fn decrypted_ingest_debug_redacts_the_fold_it_carries() {
        // The fold it carries holds a sender pubkey, the decrypted location
        // JSON and the MLS group id; only the magnitude may render, and
        // bucketed, because a result count is how many peers just moved.
        let sender = "3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b";
        let ingest = DecryptedIngest {
            results: vec![LocationMessageResult::Location {
                sender_pubkey: sender.to_string(),
                content: r#"{"latitude":37.7749,"longitude":-122.4194}"#.to_string(),
                group_id: GroupId::from_slice(&[0x7A; 32]),
                epoch: 14,
            }],
            proposals: vec![leaky_proposal()],
        };
        crate::assert_debug_redacted!(
            &ingest,
            "DecryptedIngest",
            &[
                sender,
                "37.7749",
                "122.4194",
                &hex::encode([0x7Au8; 32]),
                PROPOSAL_CONTENT,
                PROPOSAL_H_TAG
            ]
        );
        assert_eq!(
            format!("{ingest:?}"),
            "DecryptedIngest { results: \"1\", proposals: \"1\" }"
        );
    }

    #[tokio::test]
    async fn publish_work_debug_redacts_the_circle_it_belongs_to() {
        // What the FFI logs after a create wraps real events whose `h` tag is
        // the circle's `nostr_group_id` and whose welcomes name the invitee.
        let relays = vec!["wss://relay.test.com".to_string()];
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let manager = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();

        let first = make_member_with_relays(relays.clone(), vec![]).await;
        let first_hex = first.key_package_event.pubkey.to_hex();
        let config = CircleConfig::new("Bramble Family").with_relays(relays.clone());
        let creation: CircleCreationResult = manager
            .create_circle(&keys, vec![first], &config)
            .await
            .expect("create circle");
        let group_hex = hex::encode(creation.circle.nostr_group_id);
        let welcome_hex = hex::encode(creation.founding_welcomes[0].as_slice());
        let needles = [
            "Bramble Family",
            "wss://relay.test.com",
            first_hex.as_str(),
            group_hex.as_str(),
            welcome_hex.as_str(),
        ];
        crate::assert_debug_redacted!(&creation, "CircleCreationResult", &needles);
    }

    #[tokio::test]
    async fn a_non_admin_can_rotate() {
        // A self-update needs no admin (`protocol-core/group-setup.md` 92): a
        // stuck member repairs their own circle. Staged under a record,
        // confirmed on the relay's acknowledgement, applied by the admin, and
        // both sides read each other afterwards.
        let tp = setup_two_party_circle().await;
        let before = tp
            .bob
            .session()
            .epoch(&tp.mls_group_id)
            .await
            .expect("epoch");
        let leaf_before = tp
            .bob
            .session()
            .own_leaf_hash_for_test(&tp.mls_group_id)
            .await
            .expect("bob's leaf");
        let (RepairOutcome::Rotated(made), Some(commit)) = tp
            .bob
            .repair_rotation_for_test(&tp.mls_group_id, past_every_rotation_window())
            .await
            .expect("a non-admin's repair is an outcome, not a failure")
        else {
            panic!("a non-admin with every gate open must rotate");
        };
        assert_eq!(
            made.status,
            crate::relay::fanout::EvolutionStatus::Confirmed,
            "the repair is confirmed on the relay's acknowledgement",
        );
        assert_ne!(
            tp.bob
                .session()
                .own_leaf_hash_for_test(&tp.mls_group_id)
                .await
                .expect("bob's leaf"),
            leaf_before,
            "the repair is a self-update: it rotates the repairer's leaf",
        );
        tp.alice
            .ingest_for_test(&commit)
            .await
            .expect("the admin takes in the repair");
        for (who, mgr) in [("alice", &tp.alice), ("bob", &tp.bob)] {
            assert_eq!(
                mgr.session().epoch(&tp.mls_group_id).await.expect("epoch"),
                before + 1,
                "{who} applied the repair",
            );
        }
        for (from, to, latitude) in [(&tp.bob, &tp.alice, 12.5), (&tp.alice, &tp.bob, 13.5)] {
            let (event, _, _) = from
                .seal_location_for_test(&tp.mls_group_id, &LocationMessage::new(latitude, 1.0))
                .await
                .expect("a seal after the repair");
            let results = to.ingest_for_test(&event).await.expect("ingest");
            assert!(
                results
                    .iter()
                    .any(|r| matches!(r, LocationMessageResult::Location { .. })),
                "each side reads the other after a non-admin's repair",
            );
        }
    }

    #[tokio::test]
    async fn a_group_with_a_commit_already_staged_declines_the_repair_as_busy() {
        // Gate 2 end to end: `SessionManager::update_admin_policy` reads the
        // engine's `epoch_state` under the send's own lock and answers a
        // `PendingPublish` group with the typed `NostrError::EpochNotStable`.
        // Reaching that arm requires a real staged commit, which is what this
        // test manufactures.
        let tp = setup_two_party_circle().await;
        let full = Still::new(&DriveMode::Full, DriveMode::Full);
        tp.alice
            .propose_admin_handoff_staging(&tp.mls_group_id, &tp.bob_keys.public_key(), 0, full)
            .await
            .expect("stage a handoff commit and leave it unresolved");

        assert!(
            matches!(
                tp.alice
                    .repair_epoch_rotation_staging(
                        &tp.mls_group_id,
                        past_every_rotation_window(),
                        0,
                        full,
                    )
                    .await
                    .expect("a busy group is a typed outcome, never an opaque MLS error"),
                StagedRepair::Skipped(SkipReason::EpochNotStable)
            ),
            "a group with a commit already staged must decline the repair as busy"
        );

        // Control, so the assertion above is attributable to the epoch state and
        // not to some other gate: resolving the staged commit makes the very same
        // call succeed.
        tp.alice.refuse_staged_for_test().await;
        assert!(
            matches!(
                tp.alice
                    .repair_rotation_for_test(&tp.mls_group_id, past_every_rotation_window())
                    .await
                    .expect("outcome"),
                (RepairOutcome::Rotated(_), Some(_))
            ),
            "once the group is Stable again the repair must go through"
        );
    }

    #[tokio::test]
    async fn a_confirmed_repair_records_the_rate_limit_and_a_rolled_back_one_does_not() {
        // Publish-before-apply applied to bookkeeping: a repair no relay accepted
        // reset nobody's ratchet, so it must not lock the user out of retrying
        // for a day — while a confirmed one must.
        let tp = setup_two_party_circle().await;
        let now = past_every_rotation_window();

        let RepairOutcome::Rotated(rolled_back) = tp
            .alice
            .repair_rotation_refused_for_test(&tp.mls_group_id, now)
            .await
            .expect("repair")
        else {
            panic!("expected a rotation");
        };
        assert_eq!(
            rolled_back.status,
            crate::relay::fanout::EvolutionStatus::RolledBack,
            "premise: every relay refused the rotation",
        );
        assert_eq!(
            rotation_state(&tp.alice, &tp.nostr_group_id).last_rotation_at_ms,
            None,
            "a rolled-back repair must spend nothing"
        );

        let wall_clock_before_confirm = chrono::Utc::now().timestamp_millis();
        let (RepairOutcome::Rotated(_), Some(_)) = tp
            .alice
            .repair_rotation_for_test(&tp.mls_group_id, now)
            .await
            .expect("the rolled-back repair must be immediately retryable")
        else {
            panic!("expected a second rotation, confirmed");
        };
        let recorded = rotation_state(&tp.alice, &tp.nostr_group_id)
            .last_rotation_at_ms
            .expect("a confirmed repair must spend the circle's rate limit");
        assert!(
            recorded >= wall_clock_before_confirm,
            "the rate limit is stamped at the CONFIRM, not at the stage"
        );
    }

    #[tokio::test]
    async fn a_recent_rotation_record_declines_the_repair() {
        // Gate 6 on its own, with every other gate open: the rate limit must
        // hold even on a circle whose epoch-change observation is missing (a
        // circle repaired on another device, a storage row lost).
        let tp = setup_two_party_circle().await;
        let now = past_every_rotation_window();
        tp.alice
            .storage
            .note_rotation_confirmed(
                &tp.nostr_group_id,
                i64::try_from(now).expect("clock fits") * 1_000,
            )
            .expect("seed a rotation record");

        assert!(matches!(
            tp.alice
                .repair_rotation_for_test(&tp.mls_group_id, now)
                .await
                .expect("outcome")
                .0,
            RepairOutcome::Skipped(SkipReason::RotatedRecently)
        ));
    }

    #[tokio::test]
    async fn an_epoch_change_is_recorded_by_the_author_and_by_the_peer() {
        // The durable input gate 3 reads. Both sides must record it, because
        // either device may be the one holding the exhausted ratchet.
        let tp = setup_two_party_circle().await;
        assert_eq!(
            rotation_state(&tp.alice, &tp.nostr_group_id).last_epoch_change_seen_at_ms,
            None,
            "control: creating a circle is not an epoch CHANGE"
        );
        assert_eq!(
            rotation_state(&tp.bob, &tp.nostr_group_id).last_epoch_change_seen_at_ms,
            None,
        );

        let (RepairOutcome::Rotated(_), Some(commit)) = tp
            .alice
            .repair_rotation_for_test(&tp.mls_group_id, past_every_rotation_window())
            .await
            .expect("repair")
        else {
            panic!("expected a staged rotation");
        };
        tp.bob.ingest_for_test(&commit).await.expect("bob ingests");

        assert!(
            rotation_state(&tp.alice, &tp.nostr_group_id)
                .last_epoch_change_seen_at_ms
                .is_some(),
            "the author records the epoch change its own confirm applied"
        );
        assert!(
            rotation_state(&tp.bob, &tp.nostr_group_id)
                .last_epoch_change_seen_at_ms
                .is_some(),
            "the peer records the epoch change it ingested"
        );

        // Gate 3 now declines a repair on the CURRENT clock, without needing the
        // rotation record: an epoch that just moved has fresh ratchets.
        assert!(matches!(
            tp.alice
                .repair_rotation_for_test(&tp.mls_group_id, now_secs())
                .await
                .expect("outcome")
                .0,
            RepairOutcome::Skipped(SkipReason::RecentEpochChange)
        ));
    }

    #[tokio::test]
    async fn recent_inbound_traffic_declines_the_repair() {
        let tp = setup_two_party_circle().await;
        let now = past_every_rotation_window();
        let recent_ms = i64::try_from(now).expect("clock fits") * 1_000;
        tp.alice
            .storage
            .note_inbound_group_event(&tp.nostr_group_id, recent_ms)
            .expect("record an inbound group event");

        assert!(matches!(
            tp.alice
                .repair_rotation_for_test(&tp.mls_group_id, now)
                .await
                .expect("outcome")
                .0,
            RepairOutcome::Skipped(SkipReason::RecentInboundTraffic)
        ));
    }

    #[tokio::test]
    async fn a_decrypted_peer_location_is_the_inbound_traffic_the_gate_counts() {
        // The stamp is written from the RECEIVE funnel, on the engine's own
        // authenticated event batch — not from a bare "a kind-445 arrived", and
        // not from the delivery-health column, which is stamped by Dart only
        // after a location was decrypted AND persisted and is therefore
        // structurally absent on the very circles this repair exists to fix.
        let tp = setup_two_party_circle().await;
        assert_eq!(
            rotation_state(&tp.alice, &tp.nostr_group_id).last_inbound_event_at_ms,
            None,
            "control: nothing has been received yet"
        );

        let (event, _ngid, _relays) = tp
            .bob
            .seal_location_for_test(&tp.mls_group_id, &LocationMessage::new(48.85, 2.35))
            .await
            .expect("bob sends");
        tp.alice
            .ingest_for_test(&event)
            .await
            .expect("alice receives");

        let stamped = rotation_state(&tp.alice, &tp.nostr_group_id)
            .last_inbound_event_at_ms
            .expect("receiving a peer location must stamp the inbound observation");
        // And the gate reads it: a circle that just heard from a peer is not
        // quiescent, whatever the rotation windows say.
        let now = secs_from_ms(Some(stamped)).expect("a positive stamp");
        assert!(matches!(
            tp.alice
                .repair_rotation_for_test(&tp.mls_group_id, now)
                .await
                .expect("outcome")
                .0,
            RepairOutcome::Skipped(SkipReason::RecentInboundTraffic)
        ));
    }

    #[tokio::test]
    async fn an_uncommitted_peer_proposal_declines_the_repair() {
        // The auto-committer race, closed exactly. Bob's `SelfRemove` proposal
        // is committable by ANY remaining member (the auto-committer is not
        // admin-gated), so while it is stored uncommitted, Alice must not author
        // a competing commit at the same epoch — however quiet the circle looks.
        let tp = setup_two_party_circle().await;
        // Bob must leave the admin set first? He is not an admin, so he can
        // SelfRemove directly.
        let proposal = tp
            .bob
            .propose_leave(&tp.mls_group_id)
            .await
            .expect("bob proposes to leave")
            .expect("a first leave in this epoch proposes");
        tp.alice
            .session()
            .process_event(&proposal)
            .await
            .expect("alice ingests the proposal");

        assert!(matches!(
            tp.alice
                .repair_rotation_for_test(&tp.mls_group_id, past_every_rotation_window())
                .await
                .expect("outcome")
                .0,
            RepairOutcome::Skipped(SkipReason::PendingProposal)
        ));
    }

    /// One confirmed `SelfUpdate` commit from Bob, as the relays carry it.
    async fn bob_self_update(tp: &TwoPartyCircle) -> Event {
        let effects = tp
            .bob
            .session()
            .send(crate::nostr::mls::types::SendIntent::SelfUpdate {
                group_id: tp.mls_group_id.clone(),
            })
            .await
            .expect("bob self-updates");
        let (msg, pending) = effects
            .publish
            .iter()
            .find_map(|work| match work {
                PublishWork::GroupEvolution { msg, pending, .. } => Some((msg.clone(), *pending)),
                _ => None,
            })
            .expect("a self-update stages one group evolution");
        tp.bob
            .session()
            .confirm_published(pending)
            .await
            .expect("bob's relays acked his commit");
        SessionManager::transport_message_to_event(&msg).expect("commit event")
    }

    /// Leaves Alice — still the circle's sole admin — with a real future-epoch
    /// commit row in her store, and returns the commit that row depends on.
    ///
    /// Bob commits twice; Alice holds only the second, whose source epoch is
    /// one above her tip. A commit always gates outbound work (MDK v0.10.4
    /// `ConvergenceInputContext::gates_outbound`), and one that cannot chain
    /// from the tip stays unresolved, so every send for the circle queues until
    /// the returned predecessor is delivered. The row is copied from Bob's own
    /// store because a commit sealed at an epoch Alice has not reached cannot be
    /// peeled into one.
    async fn send_gated_sole_admin_circle() -> (TwoPartyCircle, Event) {
        let tp = setup_two_party_circle().await;
        let behind = tp
            .alice
            .session()
            .epoch(&tp.mls_group_id)
            .await
            .expect("alice epoch");
        let predecessor = bob_self_update(&tp).await;
        bob_self_update(&tp).await;
        assert_eq!(
            tp.bob
                .session()
                .epoch(&tp.mls_group_id)
                .await
                .expect("bob epoch"),
            behind + 2,
            "fixture: bob must be two commits ahead of the sole admin"
        );
        let row = tp
            .bob
            .session()
            .stored_convergence_input_for_test(
                &tp.mls_group_id,
                crate::nostr::mls::types::OpenMlsContentKind::Commit,
                behind + 1,
            )
            .await
            .expect("bob's own commit row at the higher epoch");
        tp.alice
            .session()
            .stage_convergence_input_for_test(
                &row,
                crate::nostr::mls::types::MessageState::Retryable,
                0,
            )
            .await
            .expect("alice stores the future-epoch commit she could not peel");
        (tp, predecessor)
    }

    /// Stores Bob's future-epoch commit in Alice's buffer again as
    /// `Retryable`: the row that gates her sends.
    async fn regate(tp: &TwoPartyCircle) {
        let tip = tp
            .alice
            .session()
            .epoch(&tp.mls_group_id)
            .await
            .expect("alice epoch");
        let row = tp
            .bob
            .session()
            .stored_convergence_input_for_test(
                &tp.mls_group_id,
                crate::nostr::mls::types::OpenMlsContentKind::Commit,
                tip + 1,
            )
            .await
            .expect("bob's own commit row at the higher epoch");
        tp.alice
            .session()
            .stage_convergence_input_for_test(
                &row,
                crate::nostr::mls::types::MessageState::Retryable,
                0,
            )
            .await
            .expect("alice stores the future-epoch commit again");
    }

    #[tokio::test]
    async fn a_rotation_racing_a_departure_at_one_epoch_resolves_to_the_rotation() {
        // What ACTUALLY closes the same-epoch race for a proposal that reached a
        // peer but not us — the engine, not gate 4's clock. The repair is a
        // commit at the epoch and the departure only a proposal: the commit
        // takes the epoch on every replica, the proposal goes stale with it,
        // and the departure is re-driven one epoch later from the durable
        // `LeaveRequest`. The cost is the one extra epoch, never a fork.
        let tp = setup_two_party_circle().await;
        let start = tp
            .alice
            .session()
            .epoch(&tp.mls_group_id)
            .await
            .expect("alice epoch");

        // Alice stages her repair FIRST, at the current epoch, without having
        // seen Bob's proposal — the exact case gate 4 cannot cover.
        let (RepairOutcome::Rotated(_), Some(rotation)) = tp
            .alice
            .repair_rotation_for_test(&tp.mls_group_id, past_every_rotation_window())
            .await
            .expect("repair")
        else {
            panic!("expected a rotation, acked and applied");
        };

        // Bob departs at the SAME source epoch, on a device that has not seen
        // the rotation.
        let proposal = tp
            .bob
            .propose_leave(&tp.mls_group_id)
            .await
            .expect("bob proposes to leave")
            .expect("a first leave in this epoch proposes");

        // Both members ingest what the other published.
        let (_, redriven) = tp
            .bob
            .ingest_landing_for_test(&rotation)
            .await
            .expect("bob ingests the rotation");
        let alice_saw_departure = tp
            .alice
            .ingest_landing_for_test(&proposal)
            .await
            .expect("alice ingests the departure proposal")
            .1;

        // The rotation is the branch BOTH devices are on.
        let alice_epoch = tp
            .alice
            .session()
            .epoch(&tp.mls_group_id)
            .await
            .expect("alice epoch");
        assert!(
            alice_epoch > start,
            "the rotation must have advanced the author's epoch"
        );
        assert_eq!(
            tp.bob
                .session()
                .epoch(&tp.mls_group_id)
                .await
                .expect("bob epoch"),
            start + 1,
            "the peer must land on the rotation's epoch, not on a competing branch"
        );

        assert_departure_completes_one_epoch_later(&tp, &alice_saw_departure, &redriven).await;
    }

    /// The second half of the race test: the losing departure is not dropped —
    /// Bob's durable `LeaveRequest` re-proposes it at the new epoch in the drain
    /// his ingest of the rotation runs, that ingest records and sends it, and
    /// Alice commits that.
    async fn assert_departure_completes_one_epoch_later(
        tp: &TwoPartyCircle,
        alice_saw_departure: &[Event],
        redriven: &[Event],
    ) {
        // Bob's proposal was made at the OLD epoch, so the rotation superseded
        // it — nothing Alice can commit.
        assert!(
            alice_saw_departure.is_empty(),
            "a proposal below the tip is superseded, not committable"
        );
        let bob_hex = hex::encode(tp.bob_keys.public_key().to_bytes());
        assert!(
            tp.alice
                .session()
                .member_pubkeys(&tp.mls_group_id)
                .await
                .expect("alice roster")
                .contains(&bob_hex),
            "control: bob is still a member at this point, so the assertion below is real"
        );

        // And the departure is not LOST: the rotation's epoch change owes Bob's
        // group an advance, the engine re-mints his durable `LeaveRequest` for
        // the new epoch inside it — once per epoch, so a receive path that
        // dropped it would wedge the leave — and his ingest hands it back.
        let [redriven] = redriven else {
            panic!(
                "the durable LeaveRequest must be re-proposed at the new epoch and \
                 handed back exactly once, got {}",
                redriven.len()
            );
        };
        let (_, evicted) = tp
            .alice
            .ingest_landing_for_test(redriven)
            .await
            .expect("alice ingests the re-proposed departure");
        assert_eq!(evicted.len(), 1, "alice commits the departure, on an ack");
        assert!(
            !tp.alice
                .session()
                .member_pubkeys(&tp.mls_group_id)
                .await
                .expect("alice roster")
                .contains(&bob_hex),
            "the departure must complete one epoch later, never be dropped"
        );
    }

    #[tokio::test]
    async fn a_repair_is_possible_again_once_the_departure_commits() {
        // The pending-proposal gate must CLEAR. A stored proposal row is retired
        // by nothing — the engine's ingest arm stores it and never marks it
        // `Processed` — so what makes it stop counting is the group moving past
        // the epoch it was made for. If that ever stopped working, every circle
        // that has ever had a departure would become permanently unrepairable,
        // and silently, because a skip is indistinguishable from a healthy
        // circle.
        let tp = setup_two_party_circle().await;
        let proposal = tp
            .bob
            .propose_leave(&tp.mls_group_id)
            .await
            .expect("bob proposes to leave")
            .expect("a first leave in this epoch proposes");

        // The foreground's receive path: ingesting the proposal STAGES the
        // eviction the auto-committer scheduled, under its record, so the
        // engine is now mid-commit.
        tp.alice
            .ingest_staging_for_test(&proposal)
            .await
            .expect("alice ingests the proposal");
        assert!(
            matches!(
                tp.alice
                    .repair_epoch_rotation_staging(
                        &tp.mls_group_id,
                        past_every_rotation_window(),
                        0,
                        Still::new(&DriveMode::Full, DriveMode::Full),
                    )
                    .await
                    .expect("outcome"),
                StagedRepair::Skipped(SkipReason::EpochNotStable)
            ),
            "a circle with an eviction already staged must not also stage a rotation"
        );

        // Resolve the departure on a relay's acknowledgement.
        assert_eq!(
            tp.alice.land_staged_for_test().await.len(),
            1,
            "premise: the eviction lands"
        );

        assert!(
            !tp.alice
                .session()
                .has_pending_proposal(&tp.mls_group_id)
                .await
                .expect("read the proposal window"),
            "moving past the proposal's epoch must clear the gate"
        );
        assert!(matches!(
            tp.alice
                .repair_rotation_for_test(&tp.mls_group_id, past_every_rotation_window())
                .await
                .expect("outcome")
                .0,
            RepairOutcome::Rotated(_)
        ));
    }

    #[tokio::test]
    async fn a_future_epoch_proposal_still_gates_the_repair() {
        // The proposal bound is `source_epoch >= tip`, not `== tip`, and the
        // upper half matters: a proposal sealed ABOVE this device's tip becomes
        // committable the moment the device catches up, so narrowing the bound
        // to equality would let a repair race a departure the device is already
        // holding but has not yet caught up to.
        //
        // Built the way Unit B builds its future-epoch fixtures: a REAL row a
        // real device really stored, copied verbatim into a device whose tip is
        // below it.
        let (tp, _) = send_gated_sole_admin_circle().await;
        let ahead = tp
            .bob
            .session()
            .epoch(&tp.mls_group_id)
            .await
            .expect("bob epoch");
        assert!(
            ahead
                > tp.alice
                    .session()
                    .epoch(&tp.mls_group_id)
                    .await
                    .expect("alice epoch"),
            "fixture: bob must be ahead of alice, so his proposal is sealed above her tip"
        );
        assert!(
            !tp.alice
                .session()
                .has_pending_proposal(&tp.mls_group_id)
                .await
                .expect("read the proposal window"),
            "control: nothing gates before the proposal is staged"
        );

        tp.bob
            .propose_leave(&tp.mls_group_id)
            .await
            .expect("bob proposes to leave at his own, higher epoch")
            .expect("a first leave in this epoch proposes");
        let row = tp
            .bob
            .session()
            .stored_convergence_input_for_test(
                &tp.mls_group_id,
                crate::nostr::mls::types::OpenMlsContentKind::Proposal,
                ahead,
            )
            .await
            .expect("bob's own proposal row at the higher epoch");
        tp.alice
            .session()
            .stage_convergence_input_for_test(
                &row,
                crate::nostr::mls::types::MessageState::Created,
                0,
            )
            .await
            .expect("alice stores the future-epoch proposal");

        assert!(
            tp.alice
                .session()
                .has_pending_proposal(&tp.mls_group_id)
                .await
                .expect("read the proposal window"),
            "a proposal above the tip is still committable once this device catches up"
        );
    }

    #[tokio::test]
    async fn the_pending_proposal_gate_survives_a_process_restart() {
        // The gate reads DURABLE storage, not the engine's in-memory
        // auto-commit schedule — which is exactly why it still holds after the
        // force-stop-and-relaunch that is the only lever a user actually has.
        let dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let bob_dir = TempDir::new().unwrap();
        let bob_keys = Keys::generate();
        let relays = vec!["wss://relay.test.com".to_string()];

        let mls_group_id = {
            let alice = CircleManager::new_unencrypted(dir.path(), &alice_keys).unwrap();
            let bob = CircleManager::new_unencrypted(bob_dir.path(), &bob_keys).unwrap();
            let bob_kp_event = make_kp_event(&bob, &bob_keys, &relays).await;
            let creation = alice
                .create_circle(
                    &alice_keys,
                    vec![MemberKeyPackage {
                        key_package_event: bob_kp_event,
                        inbox_relays: relays.clone(),
                        nip65_relays: vec![],
                        nip65_write_relays: vec![],
                    }],
                    &CircleConfig::new("Restart Circle").with_relays(relays.clone()),
                )
                .await
                .expect("create");
            let welcome = creation.welcome_events.first().expect("one welcome");
            bob.process_gift_wrapped_invitation(&bob_keys, &welcome.event)
                .await
                .expect("bob holds welcome");
            bob.accept_invitation(&welcome.event.id)
                .await
                .expect("bob accepts");

            let gid = creation.circle.mls_group_id.clone();
            let proposal = bob
                .propose_leave(&gid)
                .await
                .expect("bob proposes to leave")
                .expect("a first leave in this epoch proposes");
            // Ingest the proposal and stop there — no convergence drain, so the
            // eviction auto-commit is scheduled but never becomes due. That is
            // exactly the state a process killed mid-departure leaves: a stored
            // proposal row and no staged commit. (Draining and then discarding the
            // commit would model nothing reachable — no Haven plane may discard a
            // removal-bearing commit, and one left staged would gate on
            // `PendingPublish` instead, which is a different refusal.)
            alice
                .session()
                .process_event(&proposal)
                .await
                .expect("alice ingests the proposal");
            gid
        };

        // Both managers are dropped here: the session guard is released, every
        // in-memory schedule is gone, and only SQLCipher survives.
        let alice = CircleManager::new_unencrypted(dir.path(), &alice_keys)
            .expect("reopen the same database");
        assert!(
            alice
                .session()
                .has_pending_proposal(&mls_group_id)
                .await
                .expect("read the proposal window"),
            "a stored proposal must still gate after a restart"
        );
        assert!(matches!(
            alice
                .repair_rotation_for_test(&mls_group_id, past_every_rotation_window())
                .await
                .expect("outcome")
                .0,
            RepairOutcome::Skipped(SkipReason::PendingProposal)
        ));
    }

    #[tokio::test]
    async fn an_undecryptable_peer_message_does_not_hold_the_repair_shut() {
        // The mirror-image defect of an inert quiescence gate, and the reason
        // the inbound stamp is written from the engine's AUTHENTICATED event
        // batch rather than from "a kind-445 arrived": a circle whose sender
        // ratchet is exhausted receives a peer publish on every cadence tick and
        // decrypts none of them. If those stamped the gate, the repair would be
        // unreachable on exactly the circles it exists to fix.
        let tp = setup_two_party_circle().await;
        // A 445 for this circle that no member can decrypt: real routing, real
        // kind, ciphertext the engine cannot peel.
        let (real, _ngid, _relays) = tp
            .bob
            .seal_location_for_test(&tp.mls_group_id, &LocationMessage::new(1.0, 2.0))
            .await
            .expect("bob sends");
        let forged = nostr::EventBuilder::new(real.kind, "ZGVmaW5pdGVseSBub3QgY2lwaGVydGV4dA==")
            .tags(real.tags.clone())
            .sign_with_keys(&Keys::generate())
            .expect("sign the undecryptable event");
        let _ = tp.alice.ingest_for_test(&forged).await;

        assert_eq!(
            rotation_state(&tp.alice, &tp.nostr_group_id).last_inbound_event_at_ms,
            None,
            "an event the engine could not authenticate must not stamp the quiescence gate — \
             it is mintable by any observer of the circle's public `h` tag"
        );
        assert!(matches!(
            tp.alice
                .repair_rotation_for_test(&tp.mls_group_id, past_every_rotation_window())
                .await
                .expect("outcome")
                .0,
            RepairOutcome::Rotated(_)
        ));
    }

    #[tokio::test]
    async fn a_full_advance_drains_no_self_update_the_engine_queued_and_nothing_else_is_lost() {
        // AM-R3-1(b), the defence in depth: whatever left a self-update in
        // the engine's queue, the full advance that would drain it into a
        // commit nobody asked for retires it first, in the same hold — the
        // drive's advance and the user-facing one alike. A real change of the
        // circle queued beside it is the user's and is made.
        for drive in [true, false] {
            let tp = setup_two_party_circle().await;
            let alice = tp.alice_keys.public_key().to_bytes();
            let bob = tp.bob_keys.public_key().to_bytes();
            let handoff = SessionManager::admin_policy_payload_for_test(&[alice, bob])
                .expect("encode a handoff");
            tp.alice
                .session()
                .queue_self_update_intent_for_test(&tp.mls_group_id)
                .await
                .expect("queue a self-update");
            tp.alice
                .session()
                .queue_admin_policy_intent_for_test(&tp.mls_group_id, handoff)
                .await
                .expect("queue a handoff");

            let made = if drive {
                tp.alice
                    .session()
                    .advance_for_drive(&tp.mls_group_id, 0)
                    .await
                    .expect("the drive's full advance")
                    .fanouts
                    .len()
            } else {
                tp.alice
                    .session()
                    .advance_convergence(&tp.mls_group_id)
                    .await
                    .expect("the full advance")
                    .publish
                    .iter()
                    .filter(|work| matches!(work, PublishWork::GroupEvolution { .. }))
                    .count()
            };

            assert_eq!(
                tp.alice
                    .session()
                    .queued_self_update_count_for_test(&tp.mls_group_id)
                    .await
                    .expect("read the queue"),
                0,
                "the queued self-update is retired (drive: {drive})"
            );
            assert_eq!(
                tp.alice
                    .session()
                    .group_evolution_count_for_test()
                    .await
                    .expect("read the evolutions"),
                0,
                "no self-update was made: only a self-update writes a durable evolution \
                 (drive: {drive})"
            );
            assert_eq!(
                made, 1,
                "the queued handoff is made: the user's change is not lost with it (drive: {drive})"
            );
        }
    }

    #[tokio::test]
    async fn the_pre_check_keeps_a_send_gated_repair_out_of_the_engines_send_path() {
        // MUST-1's first defence, pinned independently of its second (the
        // retirement inside the send's own hold): a send-gated circle's
        // repair never asks the engine for a self-update at all.
        let (tp, _) = send_gated_sole_admin_circle().await;
        let asks = tp.alice.session().self_update_asks_for_test();

        let (outcome, _) = tp
            .alice
            .repair_rotation_for_test(&tp.mls_group_id, now_secs())
            .await
            .expect("outcome");
        assert!(matches!(outcome, RepairOutcome::Deferred { .. }));
        assert_eq!(
            tp.alice.session().self_update_asks_for_test(),
            asks,
            "a repair the pre-check declined must never reach the engine's send path"
        );
        assert_eq!(
            tp.alice
                .session()
                .queued_self_update_count_for_test(&tp.mls_group_id)
                .await
                .expect("read the queue"),
            0,
            "nothing was banked"
        );
    }

    #[tokio::test]
    async fn a_send_gated_circle_defers_the_repair_instead_of_reporting_no_work() {
        // Gate 7. A repair issued while the circle is send-gated must surface a
        // typed deferral carrying whatever the engine staged — not the opaque
        // "produced no GroupEvolution publish work" error, which is exactly the
        // string every caller used to drop on the floor while the device
        // silently stopped sharing.
        let (tp, _) = send_gated_sole_admin_circle().await;
        match tp
            .alice
            .repair_rotation_for_test(&tp.mls_group_id, past_every_rotation_window())
            .await
            .expect("a send-gated repair is a typed outcome, never an error")
            .0
        {
            RepairOutcome::Deferred { .. } => {}
            RepairOutcome::Rotated(_) => {
                panic!("the future-epoch row must gate the rotation send");
            }
            RepairOutcome::Skipped(reason) => {
                panic!("expected a deferral, got Skipped({reason:?})")
            }
        }
    }

    #[tokio::test]
    async fn a_send_gated_repair_banks_no_rotation_however_often_it_is_tapped() {
        // The engine does not REJECT a send it cannot perform — it QUEUES it,
        // durably, and drains it later into a real commit with none of the
        // repair's gates re-evaluated and no rate limit charged. Queued intent
        // ids are not deduplicated, so a user tapping Repair on a stalled circle
        // would bank one epoch bump per tap, all landing in a burst the moment
        // the circle unblocks. Nothing may be left behind.
        let (tp, predecessor) = send_gated_sole_admin_circle().await;
        let now = now_secs();

        for tap in 1..=5 {
            // A tap serves the engine's deadline, which parks the row out of
            // the gate (`ConvergenceDeferred`): each tap is given a gated
            // circle again, as a redelivery of the row would.
            regate(&tp).await;
            assert!(
                tp.alice.session().send_gated(&tp.mls_group_id).await,
                "premise: tap {tap} finds the circle send-gated"
            );
            assert!(
                matches!(
                    tp.alice
                        .repair_rotation_for_test(&tp.mls_group_id, now)
                        .await
                        .expect("outcome")
                        .0,
                    RepairOutcome::Deferred { .. }
                ),
                "tap {tap} must defer"
            );
            assert_eq!(
                tp.alice
                    .session()
                    .queued_self_update_count_for_test(&tp.mls_group_id)
                    .await
                    .expect("read the queue"),
                0,
                "tap {tap} left a self-update banked in the engine's outbound queue"
            );
        }

        // Unblock the circle — the missing predecessor arrives, so both of
        // Bob's commits apply — and drain: nothing of Alice's may come out, and
        // the epoch must land on Bob's. This is the assertion the burst would
        // break.
        let before = tp
            .alice
            .session()
            .epoch(&tp.mls_group_id)
            .await
            .expect("alice epoch");
        let delivered = tp
            .alice
            .session()
            .process_event_settled_for_test(&predecessor)
            .await
            .expect("the predecessor arrives");
        let drained = tp
            .alice
            .session()
            .advance_convergence(&tp.mls_group_id)
            .await
            .expect("drain whatever the queue holds");
        let delivered = delivered.ingested().expect("the commit reached the engine");
        assert!(
            delivered
                .effects
                .publish
                .iter()
                .chain(&drained.publish)
                .all(|work| !matches!(work, PublishWork::GroupEvolution { .. })),
            "unblocking a circle that was tapped five times must stage no self-update"
        );
        assert_eq!(
            tp.alice
                .session()
                .epoch(&tp.mls_group_id)
                .await
                .expect("alice epoch"),
            before + 2,
            "the circle converges on Bob's two commits and nothing else"
        );

        // And the repair still works once, deliberately, afterwards.
        assert!(matches!(
            tp.alice
                .repair_rotation_for_test(&tp.mls_group_id, past_every_rotation_window())
                .await
                .expect("outcome")
                .0,
            RepairOutcome::Rotated(_)
        ));
    }

    #[tokio::test]
    async fn a_location_queued_behind_the_send_gate_is_discarded_never_sent_later() {
        // A fix is ephemeral: the engine queues one it cannot send, and a queue
        // released when the circle unblocks would publish a stale position — one
        // per publish cycle the circle was stalled for.
        let (tp, predecessor) = send_gated_sole_admin_circle().await;

        let deferred = tp
            .alice
            .seal_location_for_test(&tp.mls_group_id, &LocationMessage::new(48.85, 2.35))
            .await;
        assert!(
            matches!(deferred, Err(CircleError::EngineHeld)),
            "the gated send is deferred"
        );
        assert_eq!(
            tp.alice
                .session()
                .queued_intent_count_for_test(&tp.mls_group_id)
                .await
                .expect("read the queue"),
            0
        );

        let delivered = tp
            .alice
            .session()
            .process_event_settled_for_test(&predecessor)
            .await
            .expect("the predecessor arrives");
        let drained = tp
            .alice
            .session()
            .advance_convergence(&tp.mls_group_id)
            .await
            .expect("drain whatever the queue holds");
        let delivered = delivered.ingested().expect("the commit reached the engine");
        assert!(
            delivered
                .effects
                .publish
                .iter()
                .chain(&drained.publish)
                .all(|work| !matches!(work, PublishWork::ApplicationMessage { .. })),
            "unblocking the circle must publish no location it queued while stalled"
        );
    }

    #[tokio::test]
    async fn a_send_gated_repair_leaves_a_queued_membership_change_alone() {
        // What a repair takes back out of the queue is a self-update, by its
        // intent kind. A real membership intent parked behind the same send
        // gate is durable user intent and must survive.
        let (tp, _) = send_gated_sole_admin_circle().await;
        let now = now_secs();

        // Queue a REAL admin-policy change (promote Bob) behind the same gate —
        // through the session, which keeps what the engine queues: the circle
        // manager's own hand-over reports a queued change as failed and takes
        // it back out of the queue.
        let handoff = tp
            .alice
            .session()
            .update_admin_policy(
                &tp.mls_group_id,
                &[
                    tp.alice_keys.public_key().to_bytes(),
                    tp.bob_keys.public_key().to_bytes(),
                ],
            )
            .await;
        assert!(
            handoff.is_ok_and(|effects| !effects.queued.is_empty()),
            "the send gate must queue the handoff rather than stage it"
        );
        let queued_before = tp
            .alice
            .session()
            .queued_admin_policy_payloads_for_test(&tp.mls_group_id)
            .await
            .expect("read the queue");
        assert_eq!(
            queued_before.len(),
            1,
            "fixture: exactly one real membership intent must be queued"
        );

        let (outcome, sent) = tp
            .alice
            .repair_rotation_for_test(&tp.mls_group_id, now)
            .await
            .expect("outcome");
        assert!(matches!(outcome, RepairOutcome::Deferred { .. }));

        // The deferral's served advance gives a queued change its attempt
        // once the engine parks the gating row: the handoff survives the
        // repair as its own commit, sent, never as a discard.
        assert!(sent.is_some(), "the queued handoff is released and sent");
        assert!(
            tp.alice
                .session()
                .queued_admin_policy_payloads_for_test(&tp.mls_group_id)
                .await
                .expect("read the queue")
                .is_empty(),
            "the released handoff left the queue"
        );
        let admins = tp
            .alice
            .session()
            .admin_pubkeys(&tp.mls_group_id)
            .await
            .expect("admins");
        assert!(
            admins.contains(&tp.bob_keys.public_key().to_bytes()),
            "the repair's discard must not touch a queued membership change"
        );
    }

    #[tokio::test]
    async fn propose_admin_handoff_rejects_a_non_member_successor() {
        // Admin is a capability over group state; granting it to someone with no
        // member leaf would create an admin nobody can remove and who holds no
        // ratchet position. The engine fail-closes and Haven surfaces it
        // redacted.
        let tp = setup_two_party_circle().await;
        let outsider = Keys::generate().public_key();
        let err = tp
            .alice
            .admin_handoff_for_test(&tp.mls_group_id, &outsider)
            .await
            .expect_err("a non-member must not be promotable to admin");
        assert!(matches!(err, CircleError::Mls(_)));
        assert!(
            !err.to_string().to_lowercase().contains(&outsider.to_hex()),
            "the rejection must not echo the candidate's pubkey"
        );
        assert_eq!(
            tp.alice
                .session()
                .admin_pubkeys(&tp.mls_group_id)
                .await
                .expect("alice admins"),
            vec![tp.alice_keys.public_key().to_bytes()],
            "a rejected promotion must not change the admin set"
        );
    }

    #[tokio::test]
    async fn complete_leave_nonexistent_group_succeeds() {
        let (manager, _keys, _dir) = create_test_manager();
        manager
            .complete_leave(&GroupId::from_slice(&[0u8; 32]), DIR_NOW)
            .await
            .expect("complete_leave should not fail when row is missing");
    }

    #[tokio::test]
    async fn complete_leave_removes_circle_row() {
        // DM has no per-group MLS delete (the `complete_leave_purges_mdk_state`
        // subject is gone); `complete_leave` removes the local circle row and its
        // cascade. The engine keeps its own `removed`-marked copy.
        let tp = setup_two_party_circle().await;
        assert!(tp
            .alice
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .is_some());
        tp.alice
            .complete_leave(&tp.mls_group_id, DIR_NOW)
            .await
            .expect("complete_leave");
        assert!(tp
            .alice
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .is_none());
    }

    #[tokio::test]
    async fn complete_leave_purges_per_circle_sync_cursor() {
        let tp = setup_two_party_circle().await;
        let key = crate::relay::live_sync::processor::group_cursor_stream(&hex::encode(
            tp.nostr_group_id,
        ));
        tp.alice
            .advance_sync_cursor(&key, 1_700_000_000_000)
            .expect("advance cursor");
        assert!(tp.alice.read_sync_cursor(&key).unwrap().is_some());
        tp.alice
            .complete_leave(&tp.mls_group_id, DIR_NOW)
            .await
            .expect("complete_leave");
        assert!(
            tp.alice.read_sync_cursor(&key).unwrap().is_none(),
            "the per-circle group cursor must be purged on leave (wipe-on-leave)"
        );
    }

    #[tokio::test]
    async fn propose_leave_by_non_admin_returns_proposal_event() {
        let tp = setup_two_party_circle().await;
        let ev = tp
            .bob
            .propose_leave(&tp.mls_group_id)
            .await
            .expect("non-admin bob can propose SelfRemove")
            .expect("a first leave in this epoch proposes");
        assert_eq!(ev.kind.as_u16(), 445);
    }

    #[tokio::test]
    async fn the_session_never_enrolls_a_group_in_periodic_rotation() {
        // MDK enrols every new group in periodic self-update by default
        // (`PeriodicMaintenancePolicy::EnabledForNewGroups`, `group_lifecycle.rs`
        // `persist_new_group_maintenance`). Haven changes keys on membership
        // changes and explicit repair only, so neither the founder's create nor
        // the joiner's Welcome may put the circle on a timer.
        let tp = setup_two_party_circle().await;
        for (who, manager) in [("the founder", &tp.alice), ("the joiner", &tp.bob)] {
            assert!(
                !manager
                    .session()
                    .periodic_rotation_enrolled_for_test(&tp.mls_group_id)
                    .await
                    .expect("read the maintenance record"),
                "{who}'s copy must not be enrolled in periodic rotation"
            );
        }
    }

    /// A mode that is full until it is read with the engine held for the
    /// `after`-th time more, and finish-only — its lifecycle over — from that
    /// read on: a pause that lands while a call waits for the engine.
    struct NarrowsWhenHeld<'a> {
        session: &'a SessionManager,
        after: std::sync::atomic::AtomicU64,
        narrowed: std::sync::atomic::AtomicBool,
    }

    impl<'a> NarrowsWhenHeld<'a> {
        const fn after(session: &'a SessionManager, held_reads: u64) -> Self {
            Self {
                session,
                after: std::sync::atomic::AtomicU64::new(held_reads),
                narrowed: std::sync::atomic::AtomicBool::new(false),
            }
        }

        fn narrowed(&self) -> bool {
            self.narrowed.load(std::sync::atomic::Ordering::SeqCst)
        }
    }

    impl crate::relay::fanout::ModeSource for NarrowsWhenHeld<'_> {
        fn mode(&self) -> DriveMode {
            use std::sync::atomic::Ordering::SeqCst;
            if self.session.session_is_held_for_test()
                && self
                    .after
                    .try_update(SeqCst, SeqCst, |left| left.checked_sub(1))
                    .is_err()
            {
                self.narrowed.store(true, SeqCst);
            }
            if self.narrowed() {
                DriveMode::FinishOnly
            } else {
                DriveMode::Full
            }
        }

        fn stands(&self) -> bool {
            !self.narrowed()
        }
    }

    /// A drive's advance is made once, and then again for as long as rows
    /// the engine could not open are untried — each time in a hold of its
    /// own, behind a wait for the engine in which the foreground can end.
    /// The first asks the mode again with the engine held; so does every
    /// later one, and the call ends where the mode no longer holds: a full
    /// advance made there could stage a commit behind a pause.
    #[tokio::test]
    async fn a_later_advance_of_a_drive_is_not_made_once_its_foreground_has_ended() {
        use base64::Engine as _;

        let tp = setup_two_party_circle().await;
        let session = tp.alice.session();
        // More rows nothing opens than one advance gives a try: the drive
        // goes on to a second.
        for index in 0..200_u32 {
            let content =
                base64::engine::general_purpose::STANDARD.encode(index.to_be_bytes().repeat(24));
            let envelope = nostr::EventBuilder::new(nostr::Kind::Custom(445), content)
                .tag(nostr::Tag::custom(
                    nostr::TagKind::custom("h"),
                    [hex::encode(tp.nostr_group_id)],
                ))
                .sign_with_keys(&Keys::generate())
                .expect("sign");
            let ingest = session
                .process_event(&envelope)
                .await
                .expect("the ingest runs")
                .ingested()
                .expect("a well-formed envelope passes the screen");
            assert!(
                matches!(
                    ingest.outcome,
                    crate::nostr::mls::types::IngestOutcome::TransportDeferred { .. }
                ),
                "premise: kept by the engine to be tried again",
            );
        }
        assert!(
            session.deferred_peels_due(&tp.mls_group_id).await,
            "premise: rows are untried",
        );

        let mode = NarrowsWhenHeld::after(session, 1);
        session
            .advance_for_drive_while(&tp.mls_group_id, 1, Still::new(&mode, DriveMode::Full))
            .await
            .expect("the first advance runs");
        assert!(
            mode.narrowed() && session.deferred_peels_due(&tp.mls_group_id).await,
            "a later advance of a drive was made in the full mode after the foreground it was \
             decided in had ended",
        );

        session
            .advance_for_drive(&tp.mls_group_id, 1)
            .await
            .expect("the advance runs");
        assert!(
            !session.deferred_peels_due(&tp.mls_group_id).await,
            "control: a drive whose mode stands goes on until every row has had its try",
        );
    }

    /// A circle left waiting for the foreground stops waiting where a full
    /// drive has completed in a claimed foreground — and nowhere else. Not in
    /// a process nobody has claimed the foreground for, not beside a session
    /// only started, not beside a pause; not when the foreground ended
    /// while the drive waited for the engine to say so; and not for a circle
    /// whose own record the drive ended on an error in — which holds no
    /// other circle's.
    #[tokio::test]
    async fn only_a_drive_that_is_still_a_claimed_foregrounds_ends_a_circles_wait_for_one() {
        let tp = setup_two_party_circle().await;
        let session = tp.alice.session();
        let group = &tp.mls_group_id;
        assert!(session.await_foreground(group), "the wait is said");
        let full = DriveMode::Full;
        let none = HashSet::new();

        session
            .foreground_drove(Still::new(&full, full), &none)
            .await;
        assert!(
            session.awaits_foreground(group),
            "a full drive in a process nobody had claimed the foreground for ended the wait",
        );
        for standing in [PlaneStanding::Launched, PlaneStanding::MakesNone] {
            session.plane_stands(1, standing);
            session
                .foreground_drove(Still::new(&full, full), &none)
                .await;
            assert!(
                session.awaits_foreground(group),
                "a full drive beside a plane that is not a claimed foreground ended the wait",
            );
        }

        session.plane_stands(1, PlaneStanding::Foreground);
        let mode = NarrowsWhenHeld::after(session, 0);
        session
            .foreground_drove(Still::new(&mode, DriveMode::Full), &none)
            .await;
        assert!(
            mode.narrowed() && session.awaits_foreground(group),
            "a drive whose foreground ended while it waited for the engine ended the wait",
        );

        session
            .foreground_drove(Still::new(&full, full), &HashSet::from([group.clone()]))
            .await;
        assert!(
            session.awaits_foreground(group),
            "a full drive that ended on an error of the circle's own record ended its wait",
        );
        let elsewhere = HashSet::from([GroupId::from_slice(&[0x3c; 32])]);
        session
            .foreground_drove(Still::new(&full, full), &elsewhere)
            .await;
        assert!(
            !session.awaits_foreground(group),
            "another circle's error held this circle's wait",
        );
    }

    /// A bridge call's mode is derived from the live plane's own lifecycle
    /// where a plane shares the session: its caller's word can narrow it but
    /// never widen it, so a stale "in front of its user" from a caller that
    /// has since gone to the background makes no commit beside a plane only
    /// started, in a burst or a pause. Only a process with no live plane goes
    /// by the word alone.
    #[tokio::test]
    async fn a_bridge_calls_word_widens_nothing_beside_a_live_plane() {
        use crate::relay::fanout::{Claimed, ModeSource};
        let tp = setup_two_party_circle().await;
        let session = tp.alice.session();
        let mode = |foreground: bool| Claimed::new(&tp.alice, foreground).mode();
        assert_eq!(
            (mode(true), mode(false)),
            (DriveMode::Full, DriveMode::FinishOnly),
            "with no live plane the word is all there is",
        );
        for standing in [PlaneStanding::Launched, PlaneStanding::MakesNone] {
            session.plane_stands(1, standing);
            assert_eq!(
                mode(true),
                DriveMode::FinishOnly,
                "a caller's word made commits beside a live plane that is not a claimed \
                 foreground",
            );
        }
        session.plane_stands(1, PlaneStanding::Foreground);
        assert_eq!(
            (mode(true), mode(false)),
            (DriveMode::Full, DriveMode::FinishOnly),
            "beside a claimed foreground the word still narrows, and only it widens",
        );
    }

    /// What a session is told of the live plane beside it is the newest
    /// plane's word, and a claim of the foreground is taken only from a plane
    /// that is still only started: one that a pause or a stop has overtaken
    /// lowers nothing. With no plane at all nothing has claimed the
    /// foreground, and that is read as what it is; a plane only started has
    /// not been claimed either, and is read as one that makes no commit.
    #[tokio::test]
    async fn a_planes_standing_is_the_newest_planes_and_a_late_claim_lowers_no_pause() {
        let tp = setup_two_party_circle().await;
        let session = tp.alice.session();
        let reads = || {
            (
                if session.beside_a_plane_that_makes_none() {
                    DriveMode::FinishOnly
                } else {
                    DriveMode::Full
                },
                session.away_from_the_foreground(),
            )
        };
        assert_eq!(
            reads(),
            (DriveMode::Full, true),
            "a process with no live plane was read as a claimed foreground",
        );

        session.plane_stands(2, PlaneStanding::Launched);
        assert_eq!(
            reads(),
            (DriveMode::FinishOnly, true),
            "a plane only started was read as one that makes commits",
        );
        session.plane_claimed(2);
        assert_eq!(reads(), (DriveMode::Full, false), "claimed");

        session.plane_stands(2, PlaneStanding::MakesNone);
        session.plane_claimed(2);
        assert_eq!(
            reads(),
            (DriveMode::FinishOnly, true),
            "a claim that a pause had overtaken put the plane back in the foreground",
        );
        session.plane_stands(1, PlaneStanding::Gone);
        assert_eq!(
            reads(),
            (DriveMode::FinishOnly, true),
            "an older plane let go late lowered the hold of the one that replaced it",
        );

        session.plane_stands(3, PlaneStanding::Launched);
        session.plane_claimed(2);
        session.plane_stands(2, PlaneStanding::Foreground);
        assert_eq!(
            reads(),
            (DriveMode::FinishOnly, true),
            "an older plane spoke last"
        );
        session.plane_stands(3, PlaneStanding::Gone);
        assert_eq!(
            reads(),
            (DriveMode::Full, true),
            "a plane that is gone left its claim of the foreground behind",
        );
    }

    /// The repair a deferred location send runs releases nothing the user
    /// queued in a plane that makes no commit: it settles what was received
    /// and leaves the change queued. In the full mode it gives the change its
    /// attempt, recorded in the hold that made it.
    #[tokio::test]
    async fn a_bursts_deferred_send_repair_releases_no_queued_change() {
        for burst in [true, false] {
            let tp = setup_two_party_circle().await;
            let payload = SessionManager::admin_policy_payload_for_test(&[
                tp.alice_keys.public_key().to_bytes(),
                tp.bob_keys.public_key().to_bytes(),
            ])
            .expect("payload");
            tp.alice
                .session()
                .queue_admin_policy_intent_for_test(&tp.mls_group_id, payload)
                .await
                .expect("queue the intent");
            let mode = if burst {
                DriveMode::FinishOnly
            } else {
                DriveMode::Full
            };

            let (_, recorded) = tp
                .alice
                .repair_deferred_send_staging(
                    &tp.mls_group_id,
                    now_secs(),
                    0,
                    Still::new(&mode, mode),
                )
                .await;
            let queued = tp
                .alice
                .session()
                .queued_admin_policy_payloads_for_test(&tp.mls_group_id)
                .await
                .expect("read the queue")
                .len();
            if burst {
                assert!(
                    recorded.is_empty() && queued == 1,
                    "a burst's deferred-send repair released a queued change",
                );
            } else {
                assert_eq!(
                    recorded.len(),
                    1,
                    "control: in the full mode the repair makes the queued change",
                );
            }
        }
    }

    #[tokio::test]
    async fn a_second_leave_in_the_same_epoch_is_not_an_error() {
        // MDK answers a second leave in the epoch its proposal already covers
        // with the typed `LeaveAlreadyRequested`. It must read as "already
        // leaving, proceed" — an error here makes the leaver backstop and the
        // resumed-leave path throw on every retry, for ever.
        let tp = setup_two_party_circle().await;
        tp.bob
            .propose_leave(&tp.mls_group_id)
            .await
            .expect("non-admin bob can propose SelfRemove")
            .expect("a first leave in this epoch proposes");
        let again = tp
            .bob
            .propose_leave(&tp.mls_group_id)
            .await
            .expect("a second leave in the same epoch is not an error");
        assert!(
            again.is_none(),
            "nothing new is published: the first proposal already covers this epoch"
        );
    }

    #[tokio::test]
    async fn propose_leave_by_sole_admin_is_rejected() {
        let tp = setup_two_party_circle().await;
        // Alice is the sole admin — the engine's AdminCannotSelfRemove gate
        // rejects a bare SelfRemove until she exits the admin set first. The
        // typed engine variant maps to Haven's stable AdminSelfDemoteRequired
        // message, so the surfaced error must (a) name the self-demote
        // remediation for UI/test routing and (b) never embed the group id.
        let err = tp
            .alice
            .propose_leave(&tp.mls_group_id)
            .await
            .expect_err("sole-admin proposeLeave must be rejected");
        // Asserted on the TYPED variant and on DISPLAY — what the FFI stringifies
        // for Dart. A payload would not do: `Mls`'s payload renders nowhere, so a
        // remediation hidden there never reaches the user (Rule 15).
        assert!(
            matches!(err, CircleError::AdminSelfDemoteRequired),
            "the admin gate must surface the typed self-demote variant, not {err:?}"
        );
        let surfaced = err.to_string().to_lowercase();
        assert!(
            surfaced.contains("self-demote"),
            "admin-gate error must name the self-demote remediation: {surfaced}"
        );
        assert!(
            !surfaced.contains(&hex::encode(tp.mls_group_id.as_slice())),
            "admin-gate error must not embed the MLS group id"
        );
    }

    // ── Member management ────────────────────────────────────────────────────

    #[tokio::test]
    async fn add_members_nonexistent_group_fails() {
        let (manager, _keys, _dir) = create_test_manager();
        let member = make_member_with_relays(vec!["wss://r.test".to_string()], vec![]).await;
        let res = manager
            .add_members_staging(&GroupId::from_slice(&[0u8; 32]), &[member], 0)
            .await;
        assert!(res.is_err());
    }

    #[tokio::test]
    async fn remove_members_nonexistent_group_fails() {
        let (manager, _keys, _dir) = create_test_manager();
        let res = manager
            .remove_members_staging(
                &GroupId::from_slice(&[0u8; 32]),
                &[Keys::generate().public_key().to_hex()],
                0,
            )
            .await;
        assert!(res.is_err());
    }

    /// The founding create's Welcomes, for the two fixtures that drive a bare
    /// [`SessionManager`] and so cannot call `CircleManager`'s draining
    /// extractors. A founding create stages nothing, so there is no ref.
    fn first_group_created(effects: SessionEffects) -> Vec<TransportMessage> {
        effects
            .publish
            .into_iter()
            .find_map(|work| match work {
                PublishWork::FoundingGroupCreated { welcomes } => Some(welcomes),
                _ => None,
            })
            .expect("create_group returns FoundingGroupCreated")
    }

    /// [`first_group_created`]'s evolution twin.
    fn first_group_evolution(effects: SessionEffects) -> (Event, PendingStateRef) {
        effects
            .publish
            .into_iter()
            .find_map(|work| match work {
                PublishWork::GroupEvolution { msg, pending, .. } => Some((
                    SessionManager::transport_message_to_event(&msg).expect("commit event"),
                    pending,
                )),
                _ => None,
            })
            .expect("an evolution stages a GroupEvolution")
    }

    /// A `MessageReceived` carrying a Haven location rumor, as the engine emits
    /// it — the one shape `persist_locations_from_events` acts on.
    fn location_event(group_id: &GroupId, sender_hex: &str, lat: f64, lon: f64) -> GroupEvent {
        let content = LocationMessage::new(lat, lon)
            .to_string()
            .expect("serialize");
        let rumor = serde_json::json!({
            "kind": crate::nostr::KIND_LOCATION_UPDATE,
            "content": content,
        });
        GroupEvent::MessageReceived {
            group_id: group_id.clone(),
            message_id: crate::nostr::mls::types::MessageId::new(vec![0x5A; 32]),
            sender: crate::nostr::mls::types::MemberId::new(
                hex::decode(sender_hex).expect("sender hex"),
            ),
            epoch: crate::nostr::mls::types::EpochId(1),
            payload: serde_json::to_vec(&rumor).expect("rumor bytes"),
            retention: None,
            authority: None,
        }
    }

    /// The batch cap stops the fold GENERATING work — it never drops a batch
    /// the engine has already handed back.
    ///
    /// Dropping one would be this whole packet's defect one layer down: the
    /// eviction inside is staged in the advance's hold and recorded there, and
    /// its handle comes back with the batch; a cap that returned early would
    /// leave a staged eviction nobody drives — invisible, and permanent for
    /// that session.
    /// Everything else in the pop rides the same decision: `persist_and_fold`
    /// is its first statement, so a disposal that ran is a pop that ran whole.
    ///
    /// # Why the batch is handed in rather than produced by a plane
    ///
    /// No production path reaches this cap. A fold's convergence set is seeded
    /// by `replay_buffered_messages`, which is SINGLE-group, and every engine
    /// call drains the global pending-convergence buffer on its way out — so
    /// one fold walks one group's batch plus that group's own re-pends
    /// (measured over this tree's entire suite: never past three batches, never
    /// past one re-tick). Reaching thirty-three means handing the fold a batch
    /// that names thirty-three groups. The circles here are real and the
    /// advances are real; only the seed is built by hand.
    ///
    /// The circle whose batch lands PAST the cap goes last, and it is the only
    /// one whose advance produces anything — a one-member circle advances to an
    /// empty batch, which is what makes thirty-two of them cost half a second.
    #[tokio::test(flavor = "multi_thread")]
    async fn the_batch_cap_stops_generating_without_dropping_what_it_holds() {
        let tp = setup_two_party_circle().await;
        // Ingested and left scheduled: the engine's jitter-delayed due time is
        // long past by the time the circles below are built, so the advance
        // inside the fold stages the eviction with no waiting and no polling.
        let proposal = tp
            .bob
            .propose_leave(&tp.mls_group_id)
            .await
            .expect("bob proposes leave")
            .expect("a first leave in this epoch proposes");
        tp.alice
            .session()
            .process_event(&proposal)
            .await
            .expect("alice ingests the proposal");

        let mut pending_convergence = Vec::with_capacity(MAX_FOLD_BATCHES + 1);
        for index in 0..MAX_FOLD_BATCHES {
            let filler = tp
                .alice
                .create_circle(
                    &tp.alice_keys,
                    vec![],
                    &CircleConfig::new(format!("Cap Filler {index}"))
                        .with_relays(tp.relays.clone()),
                )
                .await
                .expect("create a filler circle");
            pending_convergence.push(filler.circle.mls_group_id.clone());
        }
        // Nothing the setup left in the engine's buffers may ride into the
        // fold: the seed has to be exactly what this test names.
        let _ = tp.alice.session().drain().await;
        pending_convergence.push(tp.mls_group_id.clone());

        let seed = SessionEffects {
            events: Vec::new(),
            publish: Vec::new(),
            queued: Vec::new(),
            pending_convergence,
        };
        // Seed + one advance per group = MAX_FOLD_BATCHES + 2 pops, so the cap
        // falls on the second-to-last and the eviction's batch is the one after
        // it. Before this fix both were discarded unread.
        let (_, recorded) = tp
            .alice
            .fold_staged(seed, true, 0, Still::new(&DriveMode::Full, DriveMode::Full))
            .await;

        assert!(
            recorded.iter().any(|id| id.group() == &tp.mls_group_id),
            "the batch past the cap was not folded: the eviction it carried was \
             staged and left with no record for anything to drive"
        );
        assert!(
            !tp.alice
                .session()
                .member_pubkeys(&tp.mls_group_id)
                .await
                .expect("the projected roster reads")
                .contains(&tp.bob_keys.public_key().to_hex()),
            "and nothing was rolled back to tidy up: the leaver stays out, which \
             is the only disposition that does not drop the removal for good"
        );
    }

    #[tokio::test]
    async fn a_replayed_location_is_filtered_against_the_circles_current_roster() {
        // Haven's own second line behind the engine's sender attribution. A pin
        // for somebody the circle no longer holds is a location the user is
        // shown for a person who cannot see theirs — the asymmetry `remove` is
        // supposed to close (Rule 10).
        let tp = setup_two_party_circle().await;
        let bob_hex = tp.bob_keys.public_key().to_hex();
        let stranger_hex = "11".repeat(32);

        let results = tp
            .alice
            .persist_and_fold(&[
                location_event(&tp.mls_group_id, &bob_hex, 51.5, -0.12),
                location_event(&tp.mls_group_id, &stranger_hex, 48.85, 2.35),
            ])
            .await;

        // The SAME decision governs both halves. Filtering only the store would
        // hand the stranger's fix to a caller across the FFI, which writes it to
        // its own — the filter undone one layer up.
        let returned = |hex: &str| {
            results.iter().any(|r| {
                matches!(r, LocationMessageResult::Location { sender_pubkey, .. }
                    if sender_pubkey == hex)
            })
        };
        assert!(
            returned(&bob_hex),
            "precondition: a member of the circle IS returned"
        );
        assert!(
            !returned(&stranger_hex),
            "a sender the roster does not name is not handed to the caller either"
        );

        let rows = tp
            .alice
            .snapshot_last_known_for_circle(&tp.nostr_group_id, chrono::Utc::now().timestamp())
            .expect("snapshot");
        assert!(
            rows.iter().any(|r| r.sender_pubkey == bob_hex),
            "precondition: a member of the circle IS persisted, so the absence \
             below is the filter and not a dead helper"
        );
        assert!(
            !rows.iter().any(|r| r.sender_pubkey == stranger_hex),
            "a sender the circle's roster does not name gets no pin"
        );
    }

    #[tokio::test]
    async fn a_roster_read_failure_still_persists_the_replayed_location() {
        // Rule 12 outranks a transient read error: a roster this device cannot
        // read is not evidence that the sender left, and dropping a legitimate
        // offline backlog over it loses the fix permanently — the engine
        // delivers it exactly once. The display layer still gates.
        let tp = setup_two_party_circle().await;
        // A circle row whose MLS group the engine does not hold, so the roster
        // read genuinely FAILS rather than returning an empty roster.
        let unreadable = GroupId::from_slice(&[0xB1; 32]);
        let ngid = [0xB2u8; 32];
        tp.alice
            .storage
            .save_circle(&Circle {
                mls_group_id: unreadable.clone(),
                nostr_group_id: ngid,
                display_name: "Unreadable".to_string(),
                circle_type: CircleType::LocationSharing,
                relays: vec!["wss://relay.test.com".to_string()],
                created_at: 0,
                updated_at: 0,
            })
            .expect("save the circle row");
        assert!(
            tp.alice.get_members(&unreadable).await.is_err(),
            "precondition: the roster read really does fail for this group"
        );

        let bob_hex = tp.bob_keys.public_key().to_hex();
        let results = tp
            .alice
            .persist_and_fold(&[location_event(&unreadable, &bob_hex, 35.68, 139.69)])
            .await;

        let rows = tp
            .alice
            .snapshot_last_known_for_circle(&ngid, chrono::Utc::now().timestamp())
            .expect("snapshot");
        assert!(
            rows.iter().any(|r| r.sender_pubkey == bob_hex),
            "a failed roster read must fail OPEN"
        );
        assert!(
            results.iter().any(|r| {
                matches!(r, LocationMessageResult::Location { sender_pubkey, .. }
                    if *sender_pubkey == bob_hex)
            }),
            "and fail open on BOTH halves: a read error must not silently stop \
             the fix reaching the caller either"
        );
    }

    #[tokio::test]
    async fn get_members_nonexistent_group_fails() {
        let (manager, _keys, _dir) = create_test_manager();
        assert!(manager
            .get_members(&GroupId::from_slice(&[0u8; 32]))
            .await
            .is_err());
    }

    #[tokio::test]
    async fn get_members_returns_roster_with_admin_flag() {
        let tp = setup_two_party_circle().await;
        let members = tp.alice.get_members(&tp.mls_group_id).await.unwrap();
        assert_eq!(members.len(), 2, "alice + bob");
        let alice_hex = tp.alice_keys.public_key().to_hex();
        let bob_hex = tp.bob_keys.public_key().to_hex();
        let alice = members.iter().find(|m| m.pubkey == alice_hex).unwrap();
        let bob = members.iter().find(|m| m.pubkey == bob_hex).unwrap();
        assert!(alice.is_admin, "creator is admin");
        assert!(!bob.is_admin, "invitee is not admin");
    }

    #[tokio::test]
    async fn remove_members_flow_evicts_the_member() {
        let tp = setup_two_party_circle().await;
        let bob_hex = tp.bob_keys.public_key().to_hex();
        let commit = tp
            .alice
            .remove_members_for_test(&tp.mls_group_id, std::slice::from_ref(&bob_hex))
            .await
            .expect("admin removes bob");
        assert_eq!(commit.kind.as_u16(), 445);
        let members = tp.alice.get_members(&tp.mls_group_id).await.unwrap();
        assert!(
            members.iter().all(|m| m.pubkey != bob_hex),
            "bob must be gone from alice's roster after confirm"
        );
    }

    #[tokio::test]
    async fn add_members_with_welcomes_produces_one_welcome_per_member() {
        let tp = setup_two_party_circle().await;
        let carol = make_member_with_relays(vec!["wss://carol.test".to_string()], vec![]).await;
        let (commit, welcomes) = tp
            .alice
            .add_members_for_test(&tp.mls_group_id, &[carol])
            .await
            .expect("admin adds carol");
        assert_eq!(welcomes.len(), 1);
        assert_eq!(commit.kind.as_u16(), 445);
    }

    #[tokio::test]
    async fn add_members_with_welcomes_fails_closed_with_no_relays() {
        let tp = setup_two_party_circle().await;
        let carol = make_member_with_relays(vec![], vec![]).await;
        let err = tp
            .alice
            .add_members_staging(&tp.mls_group_id, &[carol], 0)
            .await
            .expect_err("no delivery relay must fail closed");
        assert!(matches!(err, CircleError::MissingWelcomeRelays));
    }

    #[tokio::test]
    async fn add_members_with_welcomes_non_admin_rejected() {
        let tp = setup_two_party_circle().await;
        let carol = make_member_with_relays(vec!["wss://carol.test".to_string()], vec![]).await;
        let res = tp
            .bob
            .add_members_staging(&tp.mls_group_id, &[carol], 0)
            .await;
        assert!(matches!(res, Err(CircleError::Mls(_))));
    }

    // ── Invitations (hold-before-ingest) ─────────────────────────────────────

    #[tokio::test]
    async fn accept_invitation_nonexistent_fails() {
        let (manager, _keys, _dir) = create_test_manager();
        let res = manager.accept_invitation(&EventId::all_zeros()).await;
        assert!(matches!(res, Err(CircleError::NotFound(_))));
    }

    #[tokio::test]
    async fn decline_invitation_nonexistent_is_idempotent() {
        // Decline is a local drop + resolution sentinel; it never touches the
        // wire (Rule 10) and is idempotent even with nothing held.
        let (manager, _keys, _dir) = create_test_manager();
        manager
            .decline_invitation(&EventId::all_zeros())
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn accept_invitation_materializes_circle_and_membership() {
        // The setup already accepts Bob's welcome; assert the resulting state.
        let tp = setup_two_party_circle().await;
        let circle = tp
            .bob
            .get_circle(&tp.mls_group_id)
            .await
            .unwrap()
            .expect("bob has the circle after accepting");
        assert!(circle.membership.status.is_visible());
        assert_eq!(
            circle.membership.inviter_pubkey,
            Some(tp.alice_keys.public_key().to_hex())
        );
        assert!(tp.bob.get_pending_invitations().unwrap().is_empty());
    }

    #[tokio::test]
    async fn reprocess_accepted_invitation_returns_already_processed() {
        let dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(dir.path(), &alice_keys).unwrap();

        let bob_dir = TempDir::new().unwrap();
        let bob_keys = Keys::generate();
        let bob = CircleManager::new_unencrypted(bob_dir.path(), &bob_keys).unwrap();

        let relays = vec!["wss://relay.test.com".to_string()];
        let bob_kp = make_kp_event(&bob, &bob_keys, &relays).await;
        let member = MemberKeyPackage {
            key_package_event: bob_kp,
            inbox_relays: relays.clone(),
            nip65_relays: vec![],
            nip65_write_relays: vec![],
        };
        let config = CircleConfig::new("Dedup Circle").with_relays(relays.clone());
        let creation = alice
            .create_circle(&alice_keys, vec![member], &config)
            .await
            .unwrap();
        let welcome = &creation.welcome_events[0];

        bob.process_gift_wrapped_invitation(&bob_keys, &welcome.event)
            .await
            .unwrap();
        bob.accept_invitation(&welcome.event.id).await.unwrap();

        // A second hold attempt after acceptance is rejected by the dedup row.
        let re = bob
            .process_gift_wrapped_invitation(&bob_keys, &welcome.event)
            .await;
        assert!(matches!(re, Err(CircleError::AlreadyProcessed)));
    }

    // ── Location sharing ─────────────────────────────────────────────────────

    #[tokio::test]
    async fn seal_location_nonexistent_circle_fails() {
        let (manager, _keys, _dir) = create_test_manager();
        let loc = crate::location::LocationMessage::new(1.0, 2.0);
        let res = manager
            .seal_location_for_test(&GroupId::from_slice(&[0u8; 32]), &loc)
            .await;
        assert!(matches!(res, Err(CircleError::NotFound(_))));
    }

    #[tokio::test]
    async fn seal_location_returns_correct_metadata() {
        let tp = setup_two_party_circle().await;
        let loc = crate::location::LocationMessage::new(37.7, -122.4);
        let (event, nostr_group_id, relays) = tp
            .alice
            .seal_location_for_test(&tp.mls_group_id, &loc)
            .await
            .expect("encrypt");
        assert_eq!(event.kind.as_u16(), 445);
        assert_eq!(nostr_group_id, tp.nostr_group_id);
        assert_eq!(relays, tp.relays);
    }

    #[tokio::test]
    async fn seal_location_and_decrypt_roundtrip() {
        let tp = setup_two_party_circle().await;
        let loc = crate::location::LocationMessage::new(51.5, -0.12);
        let (event, _ngid, _relays) = tp
            .alice
            .seal_location_for_test(&tp.mls_group_id, &loc)
            .await
            .expect("alice encrypts");

        let results = tp.bob.ingest_for_test(&event).await.expect("bob decrypts");
        let (sender, content) = expect_location(&results);
        assert_eq!(sender, tp.alice_keys.public_key().to_hex());
        let decoded = crate::location::LocationMessage::from_string(content).expect("parse");
        assert!((decoded.latitude - 51.5).abs() < 1e-9);
        assert!((decoded.longitude - -0.12).abs() < 1e-9);
    }

    #[tokio::test]
    async fn decrypt_location_bidirectional() {
        let tp = setup_two_party_circle().await;
        let loc = crate::location::LocationMessage::new(10.0, 20.0);
        let (event, _n, _r) = tp
            .bob
            .seal_location_for_test(&tp.mls_group_id, &loc)
            .await
            .expect("bob encrypts");
        let results = tp
            .alice
            .ingest_for_test(&event)
            .await
            .expect("alice decrypts");
        let (sender, _content) = expect_location(&results);
        assert_eq!(sender, tp.bob_keys.public_key().to_hex());
    }

    #[tokio::test]
    async fn seal_location_inner_event_carries_no_group_identifier() {
        // Rule 4: a published kind:445 must carry the pseudonymous
        // nostr_group_id, never the real MLS GroupId.
        let tp = setup_two_party_circle().await;
        let loc = crate::location::LocationMessage::new(1.0, 2.0);
        let (event, nostr_group_id, _relays) = tp
            .alice
            .seal_location_for_test(&tp.mls_group_id, &loc)
            .await
            .expect("encrypt");

        let raw_mls_hex = hex::encode(tp.mls_group_id.as_slice());
        let nostr_hex = hex::encode(nostr_group_id);
        assert_ne!(raw_mls_hex, nostr_hex);
        let json = event.as_json();
        assert!(
            !json.contains(&raw_mls_hex),
            "the real MLS group id must never appear in a published 445"
        );
        assert!(
            json.contains(&nostr_hex),
            "the pseudonymous nostr_group_id should appear (in the h tag)"
        );
    }

    #[tokio::test]
    async fn seal_location_attaches_group_retention_expiration() {
        // DM-2 deviation #2 re-wired: kind-445 APPLICATION messages carry a
        // NIP-40 `expiration` derived from the group's `message-retention.v1`
        // component — `inner_created_at + LOCATION_MESSAGE_RETENTION_SECS`,
        // and the outer created_at is bound to the inner one — so location
        // ciphertext cannot linger on relays indefinitely.
        let tp = setup_two_party_circle().await;
        let loc = crate::location::LocationMessage::new(10.0, 20.0);
        let (event, _n, _r) = tp
            .alice
            .seal_location_for_test(&tp.mls_group_id, &loc)
            .await
            .expect("encrypt");
        let expiration = event
            .tags
            .iter()
            .find_map(|t| match t.as_standardized() {
                Some(nostr::TagStandard::Expiration(ts)) => Some(ts.as_secs()),
                _ => None,
            })
            .expect("kind-445 location event must carry a NIP-40 expiration tag");
        assert_eq!(
            expiration,
            event.created_at.as_secs() + crate::location::ttl::LOCATION_MESSAGE_RETENTION_SECS,
            "expiration must equal created_at + the group retention window"
        );
    }

    #[tokio::test]
    async fn seal_location_publishes_neither_coordinate_nor_geohash() {
        // The WHOLE serialized 445 is searched — content and every tag — because
        // the falsification this guards is a coordinate, or the geohash derived
        // from one, reaching event content OR a tag. The geohash is the half a
        // content-only check misses: it is a lossy coordinate, not a coordinate.
        let tp = setup_two_party_circle().await;
        let loc = crate::location::LocationMessage::new(37.7749, -122.4194);
        let (event, _n, _r) = tp
            .alice
            .seal_location_for_test(&tp.mls_group_id, &loc)
            .await
            .expect("encrypt");

        // Anti-vacuity: the needles are the ones the sealed plaintext really
        // carries, so this cannot pass by searching for something absent.
        let plaintext = loc.to_string().expect("serialize");
        for needle in ["37.7749", "-122.4194", loc.geohash.as_str()] {
            assert!(
                plaintext.contains(needle),
                "the plaintext this path seals must contain '{needle}'"
            );
        }

        let json = event.as_json();
        for needle in ["37.7749", "-122.4194", loc.geohash.as_str()] {
            assert!(
                !json.contains(needle),
                "'{needle}' left the device in the clear: a 445 must carry the \
                 coordinate only as MLS ciphertext, never in content or a tag"
            );
        }
    }

    #[tokio::test]
    async fn evolution_commit_carries_no_expiration_tag() {
        // Commits/proposals are group HISTORY — a NIP-40 relay would stop
        // serving an expired commit and strand late joiners, so the engine
        // must never stamp them. (Re-expressed from the deleted
        // `*_evolution_event_has_no_expiration_tag` pre-Dark-Matter tests.)
        let tp = setup_two_party_circle().await;
        let update = tp
            .alice
            .update_relays_for_test(&tp.mls_group_id, &["wss://relay3.test.com".to_string()])
            .await
            .expect("relay update");
        assert!(
            !update
                .tags
                .iter()
                .any(|t| matches!(t.as_standardized(), Some(nostr::TagStandard::Expiration(_)))),
            "an MLS evolution commit must not carry a NIP-40 expiration tag"
        );
    }

    /// The NIP-40 `expiration` tag is not a validity signal (Marmot
    /// `transports/nostr.md:190-192`): an authentic location whose tag has
    /// passed is decrypted and returned on the poll path like any other, and
    /// presentation judges its age on the MLS-authenticated inner timestamp.
    #[tokio::test]
    async fn expired_tag_does_not_block_ingest() {
        let tp = setup_two_party_circle().await;
        let loc = crate::location::LocationMessage::new(10.0, 20.0);
        let (event, _n, _r) = tp
            .bob
            .seal_location_for_test(&tp.mls_group_id, &loc)
            .await
            .expect("bob encrypts");
        // Precondition: the rewrite below only maps an Expiration tag that is
        // already there, so without one it is a silent no-op. Two independent
        // things supply the tag — the circle's 0x8005 component and the
        // send-side bound — so this pins the rewrite's input rather than either
        // supplier.
        assert!(
            expiration_of(&event).is_some(),
            "the source location 445 must carry an expiration for the rewrite to bite"
        );
        // The same ciphertext with its expiration an hour in the past,
        // re-signed by a throwaway key — the shape a replaying relay, or a
        // member stamping a past expiration, produces.
        let past = nostr::Timestamp::now().as_secs() - 3600;
        let tags: Vec<nostr::Tag> = event
            .tags
            .iter()
            .map(|t| match t.as_standardized() {
                Some(nostr::TagStandard::Expiration(_)) => {
                    nostr::Tag::expiration(nostr::Timestamp::from(past))
                }
                _ => t.clone(),
            })
            .collect();
        let replayed = nostr::EventBuilder::new(event.kind, event.content.clone())
            .tags(tags)
            .sign_with_keys(&Keys::generate())
            .expect("re-sign the event");
        let results = tp
            .alice
            .ingest_for_test(&replayed)
            .await
            .expect("an expired kind-445 is ingested, not an error");
        let [LocationMessageResult::Location { sender_pubkey, .. }] = results.as_slice() else {
            panic!("the authentic location is returned, alone");
        };
        assert_eq!(*sender_pubkey, tp.bob_keys.public_key().to_hex());
    }

    // ── Joined circles whose creator declared a different retention ──────────
    //
    // The 0x8005 component is supplied at group CREATION, so a circle created by
    // a client other than a current Haven build carries whatever ITS creator
    // declared — including nothing at all, in which case the engine reports no
    // retention and stamps no NIP-40 `expiration` on this device's own
    // application 445s. Both halves of `privacyWhatOthersSeeDetailExpiry` invert
    // at once there: the four-minute claim goes false, AND an unstamped location
    // update reads as a membership change to any relay watching the circle's
    // `#h`. The send-side bound (`nostr::mls::RetentionBoundPeeler`) is what
    // keeps that off the wire; these tests drive it through the real join +
    // publish path, in both the undeclared and the shorter-than-Haven case.

    /// A circle created by a foreign party with a chosen `message-retention.v1`
    /// policy, joined by this device.
    ///
    /// The creator is a bare [`SessionManager`], not a `CircleManager`: a
    /// foreign client keeps no Haven circle rows, and everything the joiner
    /// consumes is on the wire (the gift-wrapped 1059).
    struct JoinedForeignCircle {
        creator: SessionManager,
        _creator_dir: TempDir,
        joiner: CircleManager,
        _joiner_dir: TempDir,
        mls_group_id: GroupId,
    }

    async fn setup_joined_foreign_circle(retention_secs: Option<u64>) -> JoinedForeignCircle {
        let relays = vec!["wss://relay.test.com".to_string()];

        let creator_dir = TempDir::new().unwrap();
        let creator_keys = Keys::generate();
        let creator = SessionManager::new_unencrypted(creator_dir.path(), &creator_keys).unwrap();

        let joiner_dir = TempDir::new().unwrap();
        let joiner_keys = Keys::generate();
        let joiner = CircleManager::new_unencrypted(joiner_dir.path(), &joiner_keys).unwrap();

        let joiner_kp_event = make_kp_event(&joiner, &joiner_keys, &relays).await;
        let key_package =
            SessionManager::key_package_from_event(&joiner_kp_event).expect("parse key package");

        let config = LocationGroupConfig::new("Foreign Circle")
            .with_relays(relays.clone())
            .with_admin(creator_keys.public_key().to_hex());
        let creation = creator
            .create_group_declaring_retention(vec![key_package], config, retention_secs)
            .await
            .expect("create a circle declaring the fixture's retention policy");
        let mls_group_id = creation.group_id.clone();
        let welcomes = first_group_created(creation.effects);

        let welcome_event =
            SessionManager::transport_message_to_event(welcomes.first().expect("one welcome"))
                .expect("welcome event");
        joiner
            .process_gift_wrapped_invitation(&joiner_keys, &welcome_event)
            .await
            .expect("joiner holds welcome");
        joiner
            .accept_invitation(&welcome_event.id)
            .await
            .expect("joiner accepts welcome");

        JoinedForeignCircle {
            creator,
            _creator_dir: creator_dir,
            joiner,
            _joiner_dir: joiner_dir,
            mls_group_id,
        }
    }

    /// Every tag name on an event, sorted — for asserting a tag set exactly.
    fn tag_names(event: &Event) -> Vec<String> {
        let mut names: Vec<String> = event
            .tags
            .iter()
            .filter_map(|t| t.as_slice().first().cloned())
            .collect();
        names.sort();
        names
    }

    fn expiration_of(event: &Event) -> Option<u64> {
        event.tags.iter().find_map(|t| match t.as_standardized() {
            Some(nostr::TagStandard::Expiration(ts)) => Some(ts.as_secs()),
            _ => None,
        })
    }

    /// The `h` routing value (the pseudonymous `nostr_group_id`, Rule 4).
    fn h_tag_of(event: &Event) -> Option<String> {
        event.tags.iter().find_map(|t| {
            let parts = t.as_slice();
            (parts.first().map(String::as_str) == Some("h"))
                .then(|| parts.get(1).cloned())
                .flatten()
        })
    }

    #[tokio::test]
    async fn a_locally_created_circle_declares_havens_retention_window_to_every_member() {
        // The other direction of the read-back, and the reason the `None` in the
        // joined-circle test below means something: a circle THIS device creates
        // really does carry the 0x8005 component, and the member who joined it
        // reads the same window back — so every member's client, not just this
        // one, stamps location 445s at Haven's window.
        let tp = setup_two_party_circle().await;
        for (who, manager) in [("creator", &tp.alice), ("joiner", &tp.bob)] {
            assert_eq!(
                manager
                    .session()
                    .group_message_retention_secs(&tp.mls_group_id)
                    .await
                    .expect("read the group's retention policy back"),
                Some(crate::location::ttl::LOCATION_MESSAGE_RETENTION_SECS),
                "the {who}'s view of a Haven-created circle must declare the retention window"
            );
        }
    }

    #[tokio::test]
    async fn location_445_expires_even_in_a_circle_that_declares_no_retention() {
        let joined = setup_joined_foreign_circle(None).await;

        // Anti-vacuity, read from the very group state the send path consults:
        // this circle declares NO retention window, so upstream hands the wrap
        // boundary `None`, which means "stamp nothing". Without the send-side
        // bound the assertion below could not pass.
        assert_eq!(
            joined
                .joiner
                .session()
                .group_message_retention_secs(&joined.mls_group_id)
                .await
                .expect("read the joined group's retention policy back"),
            None,
            "fixture must model a circle created without the 0x8005 component"
        );

        let loc = crate::location::LocationMessage::new(51.5, -0.12);
        let (event, _n, _r) = joined
            .joiner
            .seal_location_for_test(&joined.mls_group_id, &loc)
            .await
            .expect("encrypt");

        let expiration = expiration_of(&event).expect(
            "a location 445 published into a circle that declares no retention must STILL \
             carry a NIP-40 expiration: without one a relay may keep the ciphertext forever, \
             and the message reads as a membership change rather than a location update",
        );
        assert_eq!(
            expiration,
            event.created_at.as_secs() + crate::location::ttl::LOCATION_MESSAGE_RETENTION_SECS,
            "the expiry Haven asks for is its own window, measured from the event's created_at"
        );
    }

    #[tokio::test]
    async fn a_shorter_group_policy_reaches_the_wire_as_declared() {
        // The 0x8005 component is what governs every OTHER member's client, and
        // since the send-side bound now supplies an expiration unconditionally,
        // every tag-presence check — the wire journal's included — passes with
        // the component gone. This is the one observation that separates the
        // two: a window SHORTER than Haven's is honoured, so the number on the
        // wire can only have come from the group's declaration. Drop the
        // component from the send path and it reads 228 instead.
        //
        // Derived rather than literal so it stays shorter than Haven's window by
        // construction — a literal could quietly stop being the shorter one and
        // let the bound mask what this test exists to observe.
        let foreign_retention_secs = crate::location::ttl::LOCATION_MESSAGE_RETENTION_SECS / 2;
        let joined = setup_joined_foreign_circle(Some(foreign_retention_secs)).await;

        assert_eq!(
            joined
                .joiner
                .session()
                .group_message_retention_secs(&joined.mls_group_id)
                .await
                .expect("read the joined group's retention policy back"),
            Some(foreign_retention_secs),
            "the joiner must read the foreign creator's declared window out of group state"
        );

        let loc = crate::location::LocationMessage::new(48.86, 2.35);
        let (event, _n, _r) = joined
            .joiner
            .seal_location_for_test(&joined.mls_group_id, &loc)
            .await
            .expect("encrypt");

        assert_eq!(
            expiration_of(&event),
            Some(event.created_at.as_secs() + foreign_retention_secs),
            "a circle's own narrower window must reach the wire as declared: widening it \
             would ask relays to hold this location longer than the circle asked, and \
             stamping Haven's constant instead would mean the component drives nothing"
        );
    }

    /// The whole promise of the circle-details expiry segment, in one
    /// assertion: the number the sheet shows is the number a relay reads off
    /// this device's own location 445.
    ///
    /// Run over the three states that diverge — a much shorter foreign window,
    /// no declaration at all, and a declaration longer than Haven's own — so a
    /// change that made the accessor report the DECLARATION instead of the
    /// effective value fails on two of the three.
    #[tokio::test]
    async fn the_expiry_the_sheet_shows_is_the_expiry_on_the_wire() {
        let havens_own = crate::location::ttl::LOCATION_MESSAGE_RETENTION_SECS;
        // Derived, not literal, so "much shorter" stays true by construction:
        // this is the case the segment exists for, where a creator's window has
        // relays dropping this device's location almost immediately.
        let much_shorter = havens_own / 100;
        assert!(much_shorter > 0 && much_shorter < havens_own);

        for (declared, expected) in [
            (Some(much_shorter), much_shorter),
            (None, havens_own),
            (Some(86_400), havens_own),
        ] {
            let joined = setup_joined_foreign_circle(declared).await;

            let shown = joined
                .joiner
                .outgoing_location_expiry_secs(&joined.mls_group_id)
                .await
                .expect("the sheet's accessor must resolve for a joined circle");
            assert_eq!(
                shown, expected,
                "the sheet must show the window this device actually asks for, \
                 not the {declared:?} the group declares"
            );

            let loc = crate::location::LocationMessage::new(35.68, 139.69);
            let (event, _n, _r) = joined
                .joiner
                .seal_location_for_test(&joined.mls_group_id, &loc)
                .await
                .expect("encrypt");

            assert_eq!(
                expiration_of(&event),
                Some(event.created_at.as_secs() + shown),
                "the sheet would be lying about {declared:?}: a relay reads a different \
                 window off this device's own location message than the sheet displays"
            );
        }
    }

    #[tokio::test]
    async fn a_circle_with_no_live_mls_group_has_no_expiry_to_show() {
        // The degradation the subtitle depends on. `bounded_retention_secs`
        // answers "no declaration" with Haven's own window, so without the
        // group-existence check a legacy/orphaned circle would render "about
        // four minutes" for a circle that cannot send anything at all.
        let dir = TempDir::new().unwrap();
        let manager = CircleManager::new_unencrypted(dir.path(), &Keys::generate()).unwrap();

        let err = manager
            .outgoing_location_expiry_secs(&GroupId::from_slice(&[7u8; 32]))
            .await
            .expect_err("a circle with no live MLS group must not report a window");
        assert!(
            matches!(err, CircleError::NotFound(_)),
            "the missing group must surface as NotFound, not as a component read \
             failure: the caller hides the segment on either, but only one of them \
             says the circle has no group at all"
        );
    }

    #[tokio::test]
    async fn expiration_separates_location_from_control_and_no_other_tag_appears() {
        // The discriminator itself, over one circle: an application message
        // carries `h` + `expiration`, a control message carries `h` alone, and
        // neither carries anything else. Asserted in the joined circle because
        // that is where the application half was previously unstamped —
        // collapsing the two classes into one.
        let joined = setup_joined_foreign_circle(None).await;

        let loc = crate::location::LocationMessage::new(1.0, 2.0);
        let (app_event, _n, _r) = joined
            .joiner
            .seal_location_for_test(&joined.mls_group_id, &loc)
            .await
            .expect("encrypt");

        // The creator is the circle's admin, so its commit is a control message
        // over the SAME group state the application message was sealed under.
        let effects = joined
            .creator
            .update_relays(
                &joined.mls_group_id,
                vec!["wss://relay2.test.com".to_string()],
            )
            .await
            .expect("relay update");
        let (commit_event, pending) = first_group_evolution(effects);
        joined
            .creator
            .confirm_published(pending)
            .await
            .expect("confirm");

        assert_eq!(
            tag_names(&app_event),
            vec!["expiration".to_string(), "h".to_string()],
            "an application 445 carries the routing tag and the expiry request — nothing else"
        );
        assert_eq!(
            tag_names(&commit_event),
            vec!["h".to_string()],
            "a commit carries the routing tag alone: expiring group history would strand \
             every late joiner"
        );
        assert!(
            expiration_of(&commit_event).is_none(),
            "a commit must never be stamped"
        );
        let routing = h_tag_of(&app_event).expect("application 445 carries an h tag");
        assert_eq!(
            Some(&routing),
            h_tag_of(&commit_event).as_ref(),
            "both events must route to the same circle, or they are not comparable classes"
        );
    }

    /// Every kind of kind-445 a Haven circle puts on a relay, with its whole
    /// tag list: a location carries `h` and the retention-derived `expiration`
    /// (the circle's 0x8005 window, measured from the event's own
    /// `created_at`), a commit and a proposal carry `h` alone, each tag once
    /// and with one value. A peer on MDK v0.10.4 rejects anything else
    /// (`transport-nostr-peeler/src/event.rs:78-139`).
    #[tokio::test]
    async fn emitted_445_tags_subset_of_h_expiration() {
        let tp = setup_two_party_circle().await;
        let routing = hex::encode(tp.nostr_group_id);
        let retention = tp
            .alice
            .session()
            .group_message_retention_secs(&tp.mls_group_id)
            .await
            .expect("read the circle's retention component")
            .expect("a Haven circle declares 0x8005");

        let loc = crate::location::LocationMessage::new(10.0, 20.0);
        let (location, _n, _r) = tp
            .alice
            .seal_location_for_test(&tp.mls_group_id, &loc)
            .await
            .expect("encrypt");
        let commit = tp
            .alice
            .update_relays_for_test(&tp.mls_group_id, &["wss://relay3.test.com".to_string()])
            .await
            .expect("relay update");
        let proposal = tp
            .bob
            .propose_leave(&tp.mls_group_id)
            .await
            .expect("bob proposes to leave")
            .expect("a first leave in this epoch proposes");

        let h = vec!["h".to_string(), routing];
        let tags = |event: &Event| -> Vec<Vec<String>> {
            let mut tags: Vec<_> = event.tags.iter().map(|t| t.as_slice().to_vec()).collect();
            tags.sort();
            tags
        };
        assert_eq!(
            tags(&location),
            vec![
                vec![
                    "expiration".to_string(),
                    (location.created_at.as_secs() + retention).to_string()
                ],
                h.clone()
            ],
            "a location 445 carries exactly the expiry request and the routing tag"
        );
        for (what, event) in [("commit", &commit), ("proposal", &proposal)] {
            assert_eq!(event.kind, nostr::Kind::Custom(445));
            assert_eq!(
                tags(event),
                vec![h.clone()],
                "a {what} carries the routing tag alone"
            );
        }
    }

    #[tokio::test]
    async fn decrypt_relay_commit_surfaces_group_update() {
        let tp = setup_two_party_circle().await;
        let update = tp
            .alice
            .update_relays_for_test(&tp.mls_group_id, &["wss://relay3.test.com".to_string()])
            .await
            .expect("relay update");
        let results = tp
            .bob
            .ingest_for_test(&update)
            .await
            .expect("bob ingests the commit");
        assert!(results
            .iter()
            .any(|r| matches!(r, LocationMessageResult::GroupUpdate { .. })));
    }

    // ── Last-known location retention ────────────────────────────────────────

    #[test]
    fn upsert_last_known_location_overwrites_caller_supplied_purge_after() {
        // The privacy property behind LOCATION_RETENTION_SECS is that
        // `purge_after` is DERIVED at the receiver, never trusted from a
        // caller — a peer's location message carries no retention hint of its
        // own. Seeding the row with an already-expired caller-supplied
        // `purge_after` makes this non-vacuous: if the upsert ever started
        // passing the field through unchanged, this row would read back as
        // already purged instead of retained for a day.
        let (manager, keys, _dir) = create_test_manager();
        manager.keep_circle_row_for_test([7; 32]);
        let timestamp = 1_000_000_i64;
        let location = LastKnownLocation {
            nostr_group_id: [7; 32],
            sender_pubkey: keys.public_key().to_hex(),
            latitude: 40.7128,
            longitude: -74.0060,
            geohash: "dr5regw".to_string(),
            display_name: None,
            timestamp,
            expires_at: timestamp + 900,
            purge_after: timestamp, // caller-supplied — an already-expired sentinel
            updated_at: timestamp,
        };
        manager
            .upsert_last_known_location(&location)
            .expect("upsert succeeds");

        let rows = manager
            .snapshot_last_known_for_circle(&[7; 32], timestamp)
            .expect("snapshot succeeds");
        assert_eq!(
            rows.len(),
            1,
            "the caller-supplied purge_after must not have read as already-expired"
        );
        assert_eq!(
            rows[0].purge_after,
            timestamp + i64::try_from(crate::location::LOCATION_RETENTION_SECS).unwrap(),
            "purge_after must be derived from timestamp + LOCATION_RETENTION_SECS, \
             never the caller-supplied value"
        );
    }

    // ── Key packages ─────────────────────────────────────────────────────────

    #[tokio::test]
    async fn fresh_key_package_produces_bytes() {
        let (manager, _keys, _dir) = create_test_manager();
        let kp = manager
            .session()
            .fresh_key_package()
            .await
            .expect("fresh kp");
        assert!(!kp.bytes().is_empty());
    }

    #[tokio::test]
    async fn delete_key_package_is_idempotent() {
        let (manager, _keys, _dir) = create_test_manager();
        let kp = manager
            .session()
            .fresh_key_package()
            .await
            .expect("fresh kp");
        let session = manager.session();
        session.delete_key_package(&kp).await.expect("first delete");
        session
            .delete_key_package(&kp)
            .await
            .expect("idempotent delete");
    }

    // ── Publish-before-apply (Rule 13) unknown-ref rejection ─────────────────

    // ── Rule 14 (single-session) — RE-EXPRESSED write-site guard ─────────────

    #[test]
    fn single_account_device_session_construction_site() {
        // RE-EXPRESSES `m7b_every_mdk_write_site_acquires_the_writer_lock`.
        //
        // The pre-migration invariant ("every MDK write acquires the process
        // global `write_lock`") is superseded by the engine's own
        // `tokio::sync::Mutex<AccountDeviceSession>`: `&mut self` on every mutator
        // means the single session mutex IS the write serializer. The stronger
        // Rule-14 invariant that replaces it is STRUCTURAL: at most one live
        // `AccountDeviceSession` is ever constructed per DB file across all
        // isolates — divergent hydrated epoch state would erode forward secrecy
        // (security F4). This guard asserts the ONLY `AccountDeviceSession::open`
        // construction site in the whole crate is the sanctioned one inside
        // `SessionManager::open_session`; every other access reuses that one
        // handle (`Arc<SessionManager>`), never opening a second session.
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let mut files = Vec::new();
        production_sources(&root, &mut files);
        for (needle, what) in [
            ("AccountDeviceSession::open", "session open"),
            ("SessionConfig::new", "session configuration"),
        ] {
            let sites = production_sites(&files, needle);
            assert_eq!(
                sites.len(),
                1,
                "exactly one {what} site is allowed (Rule 14: one live session per \
                 DB file); found: {sites:?}"
            );
            assert!(
                sites[0].contains("/src/nostr/mls/manager.rs:"),
                "the single {what} site must live in SessionManager::open_session, found {}",
                sites[0]
            );
        }
        // A rename would hide a second open from those needles: the type is
        // named only in the session manager, and never aliased.
        let named = production_sites(&files, "AccountDeviceSession");
        assert!(
            named
                .iter()
                .all(|site| site.contains("/src/nostr/mls/manager.rs:")),
            "`AccountDeviceSession` is named only in nostr/mls/manager.rs, found {named:?}"
        );
        assert_eq!(
            aliases(&files, "AccountDeviceSession"),
            Vec::<String>::new(),
            "an alias would let a second session go unnamed"
        );
    }
    /// `src` with every comment, every string and char literal's contents, and
    /// every `#[cfg(test)]`-annotated item blanked to spaces — newlines kept, so
    /// whatever a needle matches in the result is production code on its own
    /// line. Only the annotated item is skipped — to its closing brace, or to
    /// the `;` or `,` that ends an item, field, variant or arm with no body —
    /// and never past the brace that encloses it: crate files put
    /// `#[cfg(test)]` items mid-file (`circle/storage.rs`, `keyring_policy.rs`,
    /// `nostr/mls/mod.rs`), and on fields and arms.
    ///
    /// Every ambiguity errs loud: a bare `>` or `|` in a body-less test item (a
    /// comparison, a bitwise or) ends the skip early, so the rest of that item
    /// is scanned as production — a needle there fails the guard visibly,
    /// never hides.
    fn production_text(src: &str) -> String {
        let code: Vec<char> = strip_comments_and_literals(src).chars().collect();
        let marker: Vec<char> = "#[cfg(test)]".chars().collect();
        let mut out = code.clone();
        let mut i = 0;
        while i < code.len() {
            if !code[i..].starts_with(&marker) {
                i += 1;
                continue;
            }
            let mut end = i + marker.len();
            let mut braces = 0usize;
            let mut nested = 0usize;
            let mut angles = 0usize;
            while end < code.len() {
                let ch = code[end];
                let enclosing = braces == 0 && nested == 0;
                match ch {
                    '{' => braces += 1,
                    // The enclosing item's brace, paren or bracket, or the
                    // `>` / `|` closing a generic or closure parameter list:
                    // the annotated thing ended without a separator (a last
                    // field, arm or parameter). Never `->` or `=>`.
                    '}' if braces == 0 => break,
                    ')' | ']' | '|' if enclosing => break,
                    '<' if enclosing => angles += 1,
                    '>' if enclosing && !matches!(code[end - 1], '-' | '=') => {
                        if angles == 0 {
                            break;
                        }
                        angles -= 1;
                    }
                    '}' => {
                        braces -= 1;
                        if braces == 0 {
                            end += 1;
                            break;
                        }
                    }
                    '(' | '[' => nested += 1,
                    ')' | ']' => nested = nested.saturating_sub(1),
                    ';' | ',' if braces == 0 && nested == 0 => {
                        end += 1;
                        break;
                    }
                    _ => {}
                }
                end += 1;
            }
            for ch in &mut out[i..end] {
                if *ch != '\n' {
                    *ch = ' ';
                }
            }
            i = end;
        }
        out.into_iter().collect()
    }

    /// `src` with comments and the contents of string and char literals blanked
    /// (one space per character, newlines kept), so braces and needles inside
    /// them neither count nor match.
    fn strip_comments_and_literals(src: &str) -> String {
        let c: Vec<char> = src.chars().collect();
        let mut out = String::with_capacity(src.len());
        let mut i = 0;
        while i < c.len() {
            let ch = c[i];
            let next = c.get(i + 1).copied();
            let ident_before = i > 0 && (c[i - 1].is_alphanumeric() || c[i - 1] == '_');
            i = if ch == '/' && next == Some('/') {
                blank_until(&c, i, &mut out, |at| c[at] == '\n', 0)
            } else if ch == '/' && next == Some('*') {
                blank_block_comment(&c, i, &mut out)
            } else if let Some(hashes) = raw_string_hashes(&c, i).filter(|_| !ident_before) {
                blank_raw_string(&c, i, hashes, &mut out)
            } else if ch == '"' {
                out.push('"');
                let mut at = i + 1;
                while at < c.len() && c[at] != '"' {
                    if c[at] == '\\' {
                        out.push(' ');
                        at += 1;
                    }
                    if at < c.len() {
                        out.push(blank(c[at]));
                        at += 1;
                    }
                }
                blank_until(&c, at, &mut out, |_| true, 1)
            } else if ch == '\'' && (next == Some('\\') || c.get(i + 2) == Some(&'\'')) {
                // A char literal; a lone `'` is a lifetime and is left alone.
                out.push('\'');
                let start = i + if next == Some('\\') { 3 } else { 2 };
                out.push(' ');
                if next == Some('\\') {
                    out.push(' ');
                }
                blank_until(&c, start, &mut out, |at| c[at] == '\'', 1)
            } else {
                out.push(ch);
                i + 1
            };
        }
        out
    }

    fn blank(ch: char) -> char {
        if ch == '\n' {
            '\n'
        } else {
            ' '
        }
    }

    /// Blanks from `at` until `stop` holds, then copies `keep` characters as
    /// they are (the closing delimiter); returns the index after them.
    fn blank_until(
        c: &[char],
        mut at: usize,
        out: &mut String,
        stop: impl Fn(usize) -> bool,
        keep: usize,
    ) -> usize {
        while at < c.len() && !stop(at) {
            out.push(blank(c[at]));
            at += 1;
        }
        for _ in 0..keep {
            if at < c.len() {
                out.push(c[at]);
                at += 1;
            }
        }
        at
    }

    fn blank_block_comment(c: &[char], mut at: usize, out: &mut String) -> usize {
        let mut depth = 0usize;
        while at < c.len() {
            if c[at] == '/' && c.get(at + 1) == Some(&'*') {
                depth += 1;
                out.push_str("  ");
                at += 2;
            } else if c[at] == '*' && c.get(at + 1) == Some(&'/') {
                depth -= 1;
                out.push_str("  ");
                at += 2;
                if depth == 0 {
                    break;
                }
            } else {
                out.push(blank(c[at]));
                at += 1;
            }
        }
        at
    }

    /// The `#` count of a raw string (`r"…"`, `r#"…"#`, `br#"…"#`) opening at
    /// `at`, if one does.
    fn raw_string_hashes(c: &[char], at: usize) -> Option<usize> {
        let mut j = match (c.get(at), c.get(at + 1)) {
            (Some('r'), _) => at + 1,
            (Some('b'), Some('r')) => at + 2,
            _ => return None,
        };
        let open = j;
        while c.get(j) == Some(&'#') {
            j += 1;
        }
        (c.get(j) == Some(&'"')).then_some(j - open)
    }

    fn blank_raw_string(c: &[char], at: usize, hashes: usize, out: &mut String) -> usize {
        let quote = c[at..]
            .iter()
            .position(|ch| *ch == '"')
            .map_or(c.len(), |p| at + p);
        out.extend(&c[at..=quote]);
        let closes = |i: usize| c[i] == '"' && (1..=hashes).all(|h| c.get(i + h) == Some(&'#'));
        blank_until(c, quote + 1, out, closes, hashes + 1)
    }

    /// Every `.rs` file under `dir`, recursively, as `(path, production text)`.
    fn production_sources(dir: &std::path::Path, files: &mut Vec<(String, String)>) {
        for entry in std::fs::read_dir(dir).expect("read_dir") {
            let path = entry.expect("entry").path();
            if path.is_dir() {
                production_sources(&path, files);
            } else if path.extension().and_then(|e| e.to_str()) == Some("rs") {
                let src = std::fs::read_to_string(&path).expect("read source");
                files.push((
                    path.display().to_string().replace('\\', "/"),
                    production_text(&src),
                ));
            }
        }
    }

    /// `path:line` for every production line of `files` containing `needle`.
    fn production_sites(files: &[(String, String)], needle: &str) -> Vec<String> {
        files
            .iter()
            .flat_map(|(path, text)| {
                text.lines()
                    .enumerate()
                    .filter(|(_, line)| line.contains(needle))
                    .map(move |(i, _)| format!("{path}:{}", i + 1))
            })
            .collect()
    }

    /// Each case: what it pins, a source, and how many production opens the
    /// scanner must find in it.
    fn scanner_cases() -> Vec<(&'static str, String, usize)> {
        let open = "SqliteAccountStorage::open_encrypted(p, k);";
        vec![
            ("plain production", format!("fn a() {{ {open} }}"), 1),
            (
                "a test fn before production is skipped alone",
                format!("#[cfg(test)]\nfn x() {{}}\nfn a() {{ {open} }}"),
                1,
            ),
            (
                "a test use before production is skipped alone",
                format!("#[cfg(test)]\nuse foo::bar;\nfn a() {{ {open} }}"),
                1,
            ),
            (
                "a test module is skipped",
                format!("#[cfg(test)]\nmod tests {{\n    fn t() {{ {open} }}\n}}"),
                0,
            ),
            (
                "braces in literals do not end a test module early",
                format!(
                    "#[cfg(test)]\nmod tests {{\n    const A: &str = \"}}\";\n    const B: char = '}}';\n    \
                     const C: &str = r#\"say \"}}\" here\"#;\n    fn t() {{ {open} }}\n}}\nfn a() {{ {open} }}"
                ),
                1,
            ),
            ("a commented-out open", format!("// {open}\n/* {open} */"), 0),
            ("an open inside a string", format!("const S: &str = \"{open}\";"), 0),
            (
                "a lifetime is not a char literal",
                format!("fn a<'x>(v: &'x str) {{ {open} }}"),
                1,
            ),
            (
                "a last test parameter ends at the enclosing paren",
                format!("fn a(x: u8, #[cfg(test)] y: u8) {{ {open} }}"),
                1,
            ),
            (
                "a last test closure parameter ends at the closing bar",
                format!("fn a() {{ let f = |x: u8, #[cfg(test)] y: u8| {{ {open} }}; }}"),
                1,
            ),
            (
                "a last test generic parameter ends at the closing angle",
                format!("fn a<T, #[cfg(test)] U>() {{ {open} }}"),
                1,
            ),
            (
                "a generic test fn is skipped whole",
                format!("#[cfg(test)]\nfn x<T: Into<u8>>(t: T) -> u8 {{ {open} }}"),
                0,
            ),
            (
                "a test fn's return arrow does not end it",
                format!("#[cfg(test)]\nfn x() -> u8 {{ {open} }}"),
                0,
            ),
            (
                "a test fn's parameter commas do not end it",
                format!("#[cfg(test)]\nfn x(a: u8, b: u8) {{ {open} }}"),
                0,
            ),
            (
                "a test field ends at its comma",
                format!("struct S {{\n    #[cfg(test)]\n    t: u8,\n    p: u8,\n}}\nfn a() {{ {open} }}"),
                1,
            ),
            (
                "a last test field ends at the enclosing brace",
                format!("struct S {{\n    #[cfg(test)]\n    t: u8\n}}\nfn a() {{ {open} }}"),
                1,
            ),
            (
                "a test match arm ends at its comma, its call's commas aside",
                format!("fn a() {{ match x {{ #[cfg(test)] 1 => b(c, d), _ => {{ {open} }} }} }}"),
                1,
            ),
            (
                "an escaped quote does not end a string",
                format!("#[cfg(test)]\nmod t {{ const A: &str = \"\\\"}}\"; fn t() {{ {open} }} }}\nfn a() {{ {open} }}"),
                1,
            ),
            (
                "escaped char literals",
                format!("#[cfg(test)]\nmod t {{ const Q: [char; 3] = ['\\'','\\n','}}']; fn t() {{ {open} }} }}\nfn a() {{ {open} }}"),
                1,
            ),
            (
                "escaped byte literals",
                format!("#[cfg(test)]\nmod t {{ const Q: [u8; 3] = [b'\\'',b'\\n',b'}}']; fn t() {{ {open} }} }}\nfn a() {{ {open} }}"),
                1,
            ),
            (
                "nested block comments",
                format!("#[cfg(test)]\nmod t {{ /* /* */ }} */ fn t() {{ {open} }} }}\nfn a() {{ {open} }}"),
                1,
            ),
        ]
    }

    #[test]
    fn the_production_scanner_skips_test_items_and_nothing_else() {
        for (name, src, expected) in scanner_cases() {
            let files = vec![("case.rs".to_string(), production_text(&src))];
            assert_eq!(
                production_sites(&files, "SqliteAccountStorage::open_encrypted").len(),
                expected,
                "{name}"
            );
        }
        assert_eq!(
            production_text("#[cfg(test)]\nfn x() {}\nfn y() {}")
                .lines()
                .count(),
            3,
            "line numbers survive the blanking"
        );
    }

    #[test]
    fn every_mls_database_open_site_is_sanctioned() {
        // The Rule-14 companion to the test above. That one pins the number of
        // hydrated SESSIONS; this one pins the call sites of MDK's storage
        // constructor (`SqliteAccountStorage::open_encrypted*`) on the same
        // encrypted database — not every way a process could open the file
        // (rusqlite is a direct dependency) — because the stuck-convergence-input sweep
        // needs a second one: neither `AccountDeviceSession` nor
        // `cgka_engine::Engine` exposes its `StorageProvider`, so there is no
        // public way to retire a stored message or discard a queued intent
        // without opening `session.sqlite` again.
        //
        // A second CONNECTION is not a second SESSION — it hydrates no epoch
        // state, no OpenMLS group and no exporter secret — but "it only touches
        // message rows" is a property of the code, not of the type, so it is
        // asserted here rather than left to a reviewer. A THIRD open site is the
        // shape that would quietly break the argument.
        //
        // Every `.rs` file under `src/` is scanned as production text
        // (`production_text`): comments and literals blanked, and only the
        // `#[cfg(test)]` items themselves skipped — a test may legitimately open
        // a database (the wrong-key round trip in `nostr/mls/storage.rs` does),
        // and a test open is not a live session. The scanner is pinned by
        // `the_production_scanner_skips_test_items_and_nothing_else`.
        let mut files = Vec::new();
        production_sources(
            &std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src"),
            &mut files,
        );
        let in_mls = |site: &str| {
            site.contains("/src/nostr/mls/storage.rs:")
                || site.contains("/src/nostr/mls/manager.rs:")
        };
        // The wrapper's open is in the set below only because it never runs in
        // production: its gate must sit directly on it.
        let storage_rs = std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/nostr/mls/storage.rs"),
        )
        .expect("read storage.rs");
        let lines: Vec<&str> = storage_rs.lines().map(str::trim).collect();
        let wrapper = lines
            .iter()
            .position(|line| line.starts_with("pub fn open_encrypted_storage("))
            .expect("the wrapper is defined");
        assert_eq!(
            lines[wrapper - 1],
            "#[cfg(any(test, feature = \"test-utils\"))]",
            "`open_encrypted_storage` is compiled for tests and test-utils builds only"
        );
        let halt = lines
            .iter()
            .position(|line| line.starts_with("pub fn set_group_unrecoverable_for_test("))
            .expect("the halt injector is defined");
        assert_eq!(
            lines[halt - 1],
            "#[cfg(any(test, feature = \"test-utils\"))]",
            "`set_group_unrecoverable_for_test` is compiled for tests and test-utils builds only"
        );

        // The exact set, by file: `StorageConfig::open_encrypted_storage` (its
        // definition and its one open; test and test-utils builds only, no
        // production caller), `set_group_unrecoverable_for_test`'s open of a
        // closed database (test and test-utils builds only) and the sweep's
        // message store
        // (`SessionManager::open_session`). The session's own connection is
        // opened inside the engine by `AccountDeviceSession::open`, which
        // `single_account_device_session_construction_site` pins. Any other
        // `open_encrypted*` — a third open, a second wrapper, a caller of the
        // wrapper — changes the set.
        let mut opens: Vec<(String, usize)> = Vec::new();
        for site in production_sites(&files, "open_encrypted") {
            let file = site.rsplit_once(':').map_or(site.as_str(), |(f, _)| f);
            let file = file[file.find("/src/").unwrap_or(0)..].to_string();
            match opens.iter_mut().find(|(f, _)| *f == file) {
                Some((_, n)) => *n += 1,
                None => opens.push((file, 1)),
            }
        }
        opens.sort();
        assert_eq!(
            opens,
            vec![
                ("/src/nostr/mls/manager.rs".to_string(), 1),
                ("/src/nostr/mls/storage.rs".to_string(), 3),
            ],
            "the sanctioned MLS-database opens are the session's storage and the \
             sweep's message store, nothing else"
        );
        // A rename would hide an open from that needle, so the type may be
        // named only where both opens live, and never aliased there.
        let named = production_sites(&files, "SqliteAccountStorage");
        assert!(
            named.iter().all(|site| in_mls(site)),
            "`SqliteAccountStorage` is named only in nostr/mls/{{manager,storage}}.rs, \
             found {named:?}"
        );
        assert_eq!(
            aliases(&files, "SqliteAccountStorage"),
            Vec::<String>::new(),
            "an alias would let an open go unnamed"
        );
    }

    /// Files of `files` that rename `ty` — `use … ty as X` or `type X = …ty` —
    /// read across line breaks.
    fn aliases(files: &[(String, String)], ty: &str) -> Vec<String> {
        files
            .iter()
            .filter(|(_, text)| {
                let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
                flat.contains(&format!("{ty} as "))
                    || flat
                        .split("type ")
                        .skip(1)
                        .any(|rest| rest.split(';').next().is_some_and(|decl| decl.contains(ty)))
            })
            .map(|(path, _)| path.clone())
            .collect()
    }

    /// How many commits a change staged beside its own is how many members
    /// left a circle, how many Welcomes it carries is how many were invited,
    /// and a handle is an MDK id: none is rendered.
    #[test]
    fn a_staged_changes_debug_says_only_whether_it_was_staged() {
        use crate::nostr::mls::types::{FanoutId, MessageId};
        let id = FanoutId::new(
            GroupId::from_slice(&[0xab; 16]),
            MessageId::new(vec![0xcd; 32]),
        );
        let change = StagedChange {
            commit: Some(id.clone()),
            also: vec![id.clone(), id.clone()],
            welcomes: vec![MessageId::new(vec![0xef; 32])],
            unrecorded: false,
            already: false,
        };
        crate::assert_debug_redacted!(
            change,
            "StagedChange",
            &["abab", "cdcd", "efef", "FanoutId"]
        );
        let alone = StagedChange {
            commit: Some(id),
            also: Vec::new(),
            welcomes: Vec::new(),
            unrecorded: false,
            already: false,
        };
        assert_eq!(
            format!("{change:?}"),
            format!("{alone:?}"),
            "the rendering tells how many other commits were staged",
        );
    }

    /// "Remove again" is offered for exactly the members a DROPPED removal
    /// named that the circle still lists: never while no dropped removal
    /// stands, and never for a member it no longer lists — one kept from an
    /// earlier copy of the circle.
    #[tokio::test]
    async fn unmade_removal_members_are_the_listed_targets_of_a_dropped_removal() {
        use crate::nostr::mls::types::MemberId;
        use crate::nostr::mls::{ChangeNote, CommitNotes as _};
        let fx = setup_two_party_circle().await;
        let group = &fx.mls_group_id;
        let bob = MemberId::new(fx.bob_keys.public_key().to_bytes().to_vec());
        let gone = MemberId::new(vec![0x5a; 32]);
        let notes = &fx.alice.storage;
        assert!(notes.keep_removal_targets(group, &[bob, gone], 3, 0));
        assert!(
            fx.alice.session().unmade_removal_members(group) == Some(Vec::new()),
            "a removal kept with no dropped one standing was offered again",
        );
        assert!(notes.note(group, ChangeNote::QueuedRemovalDropped));
        assert!(
            fx.alice.session().unmade_removal_members(group)
                == Some(vec![fx.bob_keys.public_key().to_hex()]),
            "not exactly the listed member a dropped removal named was offered",
        );
    }

    #[test]
    fn aliases_are_found_across_lines() {
        let files = |src: &str| vec![("case.rs".to_string(), production_text(src))];
        for (name, src, found) in [
            ("a use alias", "use x::{Store as S};", true),
            ("a type alias", "type S =\n    x::Store;", true),
            ("a plain use", "use x::Store;", false),
            ("a test alias", "#[cfg(test)]\nuse x::Store as S;", false),
        ] {
            assert_eq!(!aliases(&files(src), "Store").is_empty(), found, "{name}");
        }
    }

    /// Everything the sweep, its read-only counterpart, and the two test
    /// fixtures legitimately need from the second connection.
    /// `convergence_policy` is the READ half of `ConvergencePolicyStorage` (the
    /// sweep reads the persisted rewind window); `put_convergence_policy` is
    /// deliberately absent.
    const SECOND_HANDLE_SURFACE: &[&str] = &[
        // MDK's NIP-77 inventory and its two cursors
        // (`storage-sqlite/src/transport_reconciliation.rs`): ids, instants
        // and routing ids, no key material and no group state. Written at the
        // ingest funnels for what the engine took in, and read and moved by
        // the pass (`relay::negentropy`), each with the engine held; never
        // sent to a relay (`T-SECOND-HANDLE`).
        "record_transport_reconciliation_item",
        "transport_reconciliation_inventory",
        "transport_reconciliation_replay_cursor",
        "advance_transport_reconciliation_replay_cursor",
        "transport_reconciliation_route_cursor",
        "advance_transport_reconciliation_route_cursor",
        // GroupStorage (reads only)
        "get_group",
        "list_groups",
        // LeaveRequestStorage (read only): whether the engine has minted
        // this device's leave proposal — an epoch number and an instant, no
        // key material and nothing a read can move — which decides whether
        // a press renews the leave's instant (`SessionManager::leave_proposed`).
        "leave_request",
        // MessageStorage
        "get_message",
        "put_message",
        "list_messages",
        "update_message_state",
        // What the engine left stranded (T-PARKED-REPLAY): the rows in one
        // state — listed for a test's probe, and visited by MDK's own
        // streaming call, which stops where its caller has read enough, or
        // asked of MDK's indexed existence probe, which reads no row —
        // and whether the engine holds a row's event as processed: reads.
        // And the ONE release, which is MDK's own way to stop
        // holding transport bytes without a verdict on them
        // (`traits/src/storage.rs` 256-262). A stranded row is an event
        // nobody opened: releasing it moves no epoch, consumes no proposal
        // and touches no ratchet, and the engine keeps nothing of it in
        // memory. Held to the hand-back of its circle, after the event is
        // kept, by
        // `the_second_connection_releases_a_row_only_in_the_hand_back_with_the_engine_held`.
        "list_messages_in_states",
        "visit_messages_in_states",
        "has_messages_in_states",
        "has_processed_transport_id",
        "release_message_for_replay",
        // OutboundIntentStorage. `put_queued_outbound_intent` is reachable
        // only from the test-only `queue_admin_policy_intent_for_test`
        // fixture, for the same reason `put_message` is here: the engine
        // keeps `queue_outbound_intent` `pub(crate)`, so the discard's
        // payload discriminator has no other way to be exercised directly.
        // Still message-shaped — the intent queue holds no key material and
        // no group state.
        "list_queued_outbound_intents",
        "put_queued_outbound_intent",
        "delete_queued_outbound_intent",
        // The READ half of the own-commit intents: what a staged commit of
        // this device's was asked to do. Two readers, both of a record that
        // names members or carries a key package's public half and no key:
        // the open-time repair, which gives a record only to a commit known
        // to be a removal, and the staging hold that retires the queued
        // change a released commit was made from
        // (`SessionManager::retire_released_change`, T-QUEUED-INTENT-RESTORE).
        "own_commit_intent",
        // The same records, listed: read by the re-issue for what branch
        // selection withdrew (the read MDK's state-derived form makes,
        // `SessionManager::reissue_next_withdrawn`, T-REISSUE) and by the
        // open-time sweep for the twin of a change already made.
        "list_own_commit_intents",
        // And the ONE delete of such a record: a withdrawn removal naming a
        // member whose asks are spent, consumed instead of handed back to
        // MDK's re-issue, which would remove a member the circle invited back
        // (`SessionManager::drop_withdrawn_removal`). It is MDK's own
        // disposition of a record it does not queue again
        // (`own_commit_intent.rs` 117-129); the engine reads these records
        // from storage alone and keeps none in memory, and the delete moves no
        // epoch, consumes no proposal and touches no ratchet. Made once, with
        // the engine held.
        "delete_own_commit_intent",
        // ConvergencePolicyStorage (read half)
        "convergence_policy",
        // ConvergencePassStorage (read half): the engine's own record of a
        // circle's convergence pass — a phase, deadlines, the ids it
        // collected and whether its fairness slot is still available. No key
        // and no group state. One reader: the test of whether a queued
        // change is what holds a circle at its epoch
        // (`SessionManager::reservation_freezes`), which the session API
        // answers only through a command that can open a pass.
        "convergence_pass",
        // MessageStorage's pending application outputs
        // (`acknowledge_outputs` and its test-only count). A row is a
        // decrypted output the engine holds until the host has recorded
        // it: no key, no group state. MDK's contract is that the HOST
        // acknowledges, "only after their app projection has committed"
        // (`traits/src/storage.rs:361-363`), and the session exposes no
        // call for it (T-SECOND-HANDLE).
        "list_pending_application_events",
        "delete_pending_application_events",
        // KeyPackageBundleStorage — the ONE exception, and it is key
        // material: the stored private bundle of a `KeyPackage` whose
        // lifetime has ended (`delete_key_package_bundle`,
        // T-KP-EXPIRED-DELETE). MDK's own delete validates the lifetime
        // first and so refuses exactly that bundle. Removing one cannot
        // move an epoch, consume a proposal or touch a ratchet: a bundle
        // belongs to no group, and the engine keeps none in memory — it
        // reads the store when a Welcome arrives, and retires bundles
        // through these same two calls
        // (`cgka-engine/src/key_package.rs:315-345`). Held to one call
        // site below so the exception cannot widen unnoticed.
        "stored_key_package_bundles",
        "delete_stored_key_package_bundle",
        // OutboundFanoutStorage — BEFORE the session opens only
        // (`settle_fanouts_before_open`), when this handle is the only one
        // there is: held to that function by exact count below, with ONE
        // read besides it (the listing in `retry_quarantined_group`, of rows
        // the engine hides while their circle is quarantined). A fanout row
        // is the frozen signed event of a commit and where each relay stands
        // with it: no key, no MLS state. What these change is which row
        // MDK's hydrate finds — it restores a pending commit from a group's
        // first pending row without matching the two — so a finished
        // rollback's row and a row that no longer describes the staged
        // commit are deleted, and a commit staged with no row is given one
        // (T-STALE-FANOUT, T-KILL-WINDOW). The engine has no such pass and
        // its own calls need a hydrated session.
        "list_outbound_fanouts",
        "put_outbound_fanout",
        "delete_outbound_fanout",
        // MaintenanceStorage's group evolutions — BEFORE the session opens
        // only, in the same pass (`clear_unrecorded_self_updates`), held there
        // by exact count below. An evolution is MDK's durable note of a staged
        // self-update: no key, no MLS state. One no pending fanout row records
        // is a self-update a kill left with no record, which never left the
        // device; deleted, hydrate clears its commit instead of restoring it
        // under a pending ref of its own and handing it out to publish
        // (T-STALE-FANOUT). The engine has no such pass.
        "list_group_evolutions",
        "delete_group_evolution",
    ];

    /// The order of the session's open, which two promises rest on. A fanout
    /// row's event is refused by every other publish path only once the row
    /// is in the relay layer's registry, so the registry is filled before
    /// anything else the open does — and so before any publisher of this
    /// process can exist. And MDK's hydrate binds a group's first pending row
    /// to whatever commit it finds staged, so the rows are put right before
    /// the engine opens, and what the hydrate made of them is read back the
    /// moment it has.
    #[test]
    fn the_stored_fanouts_are_settled_before_the_engine_opens_and_read_back_after() {
        let source = std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/nostr/mls/manager.rs"),
        )
        .expect("read the session manager source");
        let flat = tight_code(&source);
        let body = |name: &str| {
            let from = flat
                .find(&format!("fn {name}("))
                .unwrap_or_else(|| panic!("fn {name} exists"));
            let rest = &flat[from..];
            &rest[..rest[1..].find("fn ").map_or(rest.len(), |next| next + 1)]
        };
        let at = |text: &str, needle: &str| {
            text.find(needle)
                .unwrap_or_else(|| panic!("the open no longer reads `{needle}`"))
        };

        let open = body("open_session");
        let before = at(open, "settle_fanouts_before_open(&message_store");
        let engine = at(open, "AccountDeviceSession::open(config)");
        let after = at(open, "settle_fanouts_after_open(&message_store,&session)");
        assert!(
            before < engine && engine < after,
            "the stored fanouts are no longer settled before the engine opens \
             and read back once it has",
        );
        assert!(
            !open[engine..after].contains("lock()"),
            "something can run between the engine's open and the pass that \
             reads back what its hydrate decided",
        );

        let settle = body("settle_fanouts_before_open");
        let owned = at(settle, "crate::relay::fanout::own(");
        for change in [
            "delete_outbound_fanout(",
            "put_outbound_fanout(",
            "retire_commit(",
        ] {
            assert!(
                owned < at(settle, change),
                "a stored fanout is changed before every row's event is the driver's alone",
            );
        }
        assert!(
            settle[..owned].matches('?').count() == 1,
            "something that can fail comes between reading the rows and \
             refusing their events to every other publisher",
        );
    }

    #[test]
    fn the_sweeps_second_connection_touches_only_message_shaped_storage() {
        // What makes the second connection safe is not that it is "read-mostly"
        // — it writes — but WHICH tables it can reach. Message records and the
        // outbound-intent queue carry no key material and no group state: a row
        // in `Created`/`Retryable` was never applied, so re-stating it cannot
        // move an epoch, consume a proposal, or touch a ratchet. Reaching
        // `mls_storage()`, a snapshot, a welcome, or a group WRITE would break
        // that argument instantly and silently, so the reachable surface is
        // pinned by name here.

        let source = std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/nostr/mls/manager.rs"),
        )
        .expect("read the session manager source");
        // Read as one line with no space beside punctuation: rustfmt wraps
        // most of these calls as `self.message_store⏎.method(`, which a
        // per-line scan cannot see. `store.` also matches `message_store.`,
        // so one receiver names every call exactly once.
        let flat = tight_code(&source);
        let seen = second_handle_calls(&flat);
        // The receiver scan above reads only `<…store>.method(`. A call can be
        // written three other ways, so the handle may be NAMED only where that
        // scan follows it: as a receiver, as a helper's `store` parameter, or
        // handed whole to such a helper.
        assert_eq!(
            unscanned_handle_uses(&flat),
            Vec::<String>::new(),
            "the second handle is used in a form the method scan cannot read \
             (a trait-qualified call, a rebinding, a parameter not named `store`)"
        );
        for wrapped in [
            "delete_pending_application_events",
            "list_pending_application_events",
        ] {
            assert!(
                seen.iter().any(|name| name == wrapped),
                "anti-vacuity: `{wrapped}` is written across two lines in the source, \
                 so a scan that misses it is reading line by line again"
            );
        }
        assert!(
            !seen.is_empty(),
            "the scanner found no message-store calls at all; the sweep was renamed or \
             removed — update this guard rather than deleting it"
        );
        let forbidden = outside_the_surface(&seen);
        assert!(
            forbidden.is_empty(),
            "the sweep's second connection reached storage outside the message-shaped \
             surface that makes it Rule-14-safe: {forbidden:?} (an empty name is a call \
             the scan could not read). Reaching group writes, snapshots, welcomes or \
             mls_storage() from a non-session connection is a confidentiality argument \
             this test exists to protect."
        );
        // The scan reads one file. The field is private, so only this file can
        // name it — unless a macro or a child module elsewhere does.
        let mut files = Vec::new();
        production_sources(
            &std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src"),
            &mut files,
        );
        let elsewhere: Vec<String> = production_sites(&files, "message_store")
            .into_iter()
            .filter(|site| !site.contains("/src/nostr/mls/manager.rs:"))
            .collect();
        assert_eq!(
            elsewhere,
            Vec::<String>::new(),
            "the second handle is named outside the one file this pin scans"
        );
        assert_eq!(
            flat.matches("delete_stored_key_package_bundle(").count(),
            1,
            "a KeyPackage bundle is deleted from exactly one place, by its ref"
        );
        for evolution_call in ["list_group_evolutions(", "delete_group_evolution("] {
            assert_eq!(
                flat.matches(evolution_call).count(),
                1,
                "`{evolution_call}` is made from one place"
            );
            let held = flat
                .find("fn clear_unrecorded_self_updates(")
                .map(|at| &flat[at..])
                .map(|body| &body[..body[1..].find("fn ").map_or(body.len(), |next| next + 1)]);
            assert!(
                held.is_some_and(|body| body.contains(evolution_call)),
                "`{evolution_call}` is made only in the pass before the session opens"
            );
        }
        assert_eq!(
            flat.matches("delete_own_commit_intent(").count(),
            1,
            "an own-commit intent is deleted from exactly one place, the drop of a \
             withdrawn removal"
        );
        let held = flat
            .find("fn reissue_next_withdrawn(")
            .map(|at| &flat[at..])
            .and_then(|body| {
                body.find("drop_withdrawn_removal(")
                    .map(|call| &body[..call])
            });
        assert!(
            held.is_some_and(|before| before.contains("let Ok(mut session)=self.engine().await")),
            "the drop of a withdrawn removal is made with the engine held"
        );
        assert_eq!(
            flat.matches("stored_key_package_bundles(").count(),
            2,
            "the stored bundles — private key material — are read in two places: to \
             find the one to delete, and by the test-only count"
        );
    }

    /// The fanout names are on the second handle's surface for the pass that
    /// runs BEFORE the session opens, when that handle is the only one there
    /// is. Under a live session a fanout row is the engine's to write: its
    /// pending state hangs off it.
    #[test]
    fn the_second_connection_writes_a_fanout_row_only_before_the_session_opens() {
        let source = std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/nostr/mls/manager.rs"),
        )
        .expect("read the session manager source");
        let flat = tight_code(&source);
        let body = |name: &str| {
            let from = flat
                .find(&format!("fn {name}("))
                .unwrap_or_else(|| panic!("fn {name} exists"));
            let rest = &flat[from..];
            &rest[..rest[1..].find("fn ").map_or(rest.len(), |next| next + 1)]
        };
        // The pass, the part of it that gives a recordless commit its trial,
        // and the part that clears a self-update no record names, which only
        // the pass calls.
        let before_open = [
            body("settle_fanouts_before_open"),
            body("try_recordless_removals"),
            body("retire_queued_group_changes"),
            body("clear_unrecorded_self_updates"),
        ]
        .concat();
        assert_eq!(
            flat.matches("clear_unrecorded_self_updates(").count(),
            2,
            "unrecorded self-updates are cleared from somewhere other than the pass \
             before the open",
        );
        assert_eq!(
            flat.matches("retire_queued_group_changes(").count(),
            2,
            "queued changes are retired from somewhere other than the pass before the open",
        );
        assert_eq!(
            flat.matches("try_recordless_removals(").count(),
            2,
            "the trial is written from somewhere other than the pass before the open",
        );
        assert_eq!(
            flat.matches("settle_fanouts_before_open(").count(),
            2,
            "the pass is called from somewhere other than the one place before the open",
        );
        for (name, in_the_pass, in_a_live_session) in [
            ("list_outbound_fanouts", 3, 1),
            ("put_outbound_fanout", 2, 0),
            ("delete_outbound_fanout", 2, 0),
        ] {
            let call = format!("store.{name}(");
            assert_eq!(
                (
                    before_open.matches(&call).count(),
                    flat.matches(&call).count()
                ),
                (in_the_pass, in_the_pass + in_a_live_session),
                "`{name}` is called on the second handle somewhere other than the \
                 pass that runs before the session opens",
            );
        }
        // The one read under a live session: before the engine is asked to
        // hydrate a quarantined circle, whose rows it does not show.
        let retry = body("retry_quarantined_group");
        let listed = retry
            .find("message_store.list_outbound_fanouts(")
            .expect("the quarantine retry reads the stored fanouts");
        let asked = retry
            .find("retry_hydrate_quarantined_group(")
            .expect("the quarantine retry asks the engine");
        assert!(
            listed < asked && retry[listed..asked].contains("if pending{return Ok(false);}"),
            "a quarantined circle with a pending fanout row is hydrated in a \
             live session",
        );
    }

    /// The writes of the second handle other pins do not already hold to a
    /// place: the fanout writes run only in the pass before the open
    /// (`the_second_connection_writes_a_fanout_row_only_before_the_session_opens`)
    /// and the release only in the hand-back
    /// (`the_second_connection_releases_a_row_only_in_the_hand_back_with_the_engine_held`).
    const SECOND_HANDLE_WRITES: [&str; 11] = [
        "put_message",
        "update_message_state",
        "put_queued_outbound_intent",
        "delete_queued_outbound_intent",
        "delete_own_commit_intent",
        "delete_pending_application_events",
        "delete_stored_key_package_bundle",
        "record_transport_reconciliation_item",
        "transport_reconciliation_inventory",
        "advance_transport_reconciliation_replay_cursor",
        "advance_transport_reconciliation_route_cursor",
    ];

    /// What holds the engine in a function's text, in [`tight_code`]'s form:
    /// either guard taken, or a session guard handed in.
    const ENGINE_HELD: [&str; 3] = [
        "self.engine().await",
        "self.reading().await",
        "AccountDeviceSession",
    ];

    /// Every function of `flat` as `(start, name)`, in source order.
    fn functions(flat: &str) -> Vec<(usize, String)> {
        flat.match_indices("fn ")
            .filter(|(at, _)| {
                flat[..*at]
                    .chars()
                    .next_back()
                    .is_none_or(|c| !(c.is_alphanumeric() || c == '_'))
            })
            .filter_map(|(at, _)| {
                let name: String = flat[at + 3..]
                    .chars()
                    .take_while(|c| c.is_alphanumeric() || *c == '_')
                    .collect();
                flat[at + 3 + name.len()..]
                    .starts_with(['(', '<'])
                    .then_some((at, name))
            })
            .collect()
    }

    /// Whether `holds` is true at `at` in `flat`: of the function around it —
    /// read as its text before `at` and its text after `at` — or else of
    /// every caller of that function where it calls, up the chain.
    fn holds_up_the_chain(
        flat: &str,
        fns: &[(usize, String)],
        at: usize,
        holds: &dyn Fn(&str, &str, &str) -> bool,
        seen: &mut Vec<String>,
    ) -> bool {
        let Some(index) = fns.iter().rposition(|(start, _)| *start < at) else {
            return false;
        };
        let (start, name) = &fns[index];
        let end = fns.get(index + 1).map_or(flat.len(), |(next, _)| *next);
        if holds(name, &flat[*start..at], &flat[at..end]) {
            return true;
        }
        if seen.contains(name) {
            return true;
        }
        seen.push(name.clone());
        let callers: Vec<usize> = flat
            .match_indices(&format!("{name}("))
            .map(|(call, _)| call)
            .filter(|call| {
                let before = &flat[..*call];
                !before.ends_with("fn ")
                    && before
                        .chars()
                        .next_back()
                        .is_some_and(|c| !(c.is_alphanumeric() || c == '_'))
            })
            .collect();
        !callers.is_empty()
            && callers
                .into_iter()
                .all(|call| holds_up_the_chain(flat, fns, call, holds, seen))
    }

    /// Whether the engine is held at `at` in `flat`: the function around it
    /// takes or is handed a guard before that point, or runs before the
    /// session opens, or every caller of it holds the engine where it calls.
    fn held_at(flat: &str, fns: &[(usize, String)], at: usize) -> bool {
        holds_up_the_chain(
            flat,
            fns,
            at,
            &|name, before, _| {
                ENGINE_HELD.iter().any(|guard| before.contains(guard))
                    || name == "settle_fanouts_before_open"
            },
            &mut Vec::new(),
        )
    }

    /// Every write the second connection makes runs with the engine held —
    /// in the function that makes it, or in every function up the chain of
    /// its callers — or before the session opens, when that connection is
    /// the only one: no engine statement is in flight against a row this
    /// handle writes (T-SECOND-HANDLE). A lexical reading: a guard taken
    /// earlier in the same function counts even if dropped before the write.
    #[test]
    fn every_second_handle_write_runs_with_the_engine_held() {
        let (_, production) = session_manager_texts();
        let fns = functions(&production);
        let mut unheld = Vec::new();
        let mut found = Vec::new();
        for write in SECOND_HANDLE_WRITES {
            for (at, _) in production.match_indices(&format!("store.{write}(")) {
                found.push(write);
                if !held_at(&production, &fns, at) {
                    unheld.push(text_around(&production, at, write.len()));
                }
            }
        }
        for known in [
            "update_message_state",
            "delete_queued_outbound_intent",
            "delete_pending_application_events",
            "delete_stored_key_package_bundle",
            "record_transport_reconciliation_item",
            "transport_reconciliation_inventory",
            "advance_transport_reconciliation_replay_cursor",
            "advance_transport_reconciliation_route_cursor",
        ] {
            assert!(
                found.contains(&known),
                "anti-vacuity: the scan no longer finds a `{known}` write",
            );
        }
        assert_eq!(
            unheld,
            Vec::<String>::new(),
            "a second-handle write can run with no engine held",
        );
    }

    /// The engine calls that hand out a batch of effects — and with it the
    /// engine's one-shot names of the groups owing an advance. Two names are
    /// spelled in halves: `check_advance_convergence_sites.sh` and
    /// `check_e2e_publish_before_apply.sh` read this file for the calls.
    const EFFECTS_CALLS: [&str; 10] = [
        "session.create_group(",
        "session.ingest(",
        "session.send(",
        concat!("session.advance_", "convergence("),
        "session.advance_convergence_inputs(",
        "session.confirm_published(",
        "session.confirm_published_fanout(",
        "session.publish_failed(",
        concat!("session.publish_", "failed_fanout("),
        "session.drain()",
    ];

    /// Every batch of effects the engine hands out reaches the owed-advance
    /// feed: the engine names a group owing an advance once, in whatever
    /// call comes next, so a batch whose names were dropped would leave its
    /// group to nobody (C7, T-SCHEDULER). Each call's result is passed to
    /// `noted` or `note_effects` after it — in its own function or in every
    /// caller up the chain — and those two are the feed's only ways in.
    #[test]
    fn every_engine_batch_reaches_the_owed_advance_feed() {
        let (_, production) = session_manager_texts();
        let fns = functions(&production);
        let feeds = |_: &str, _: &str, after: &str| {
            after.contains("self.noted(") || after.contains("self.note_effects(")
        };
        let mut unfed = Vec::new();
        let mut found = Vec::new();
        for call in EFFECTS_CALLS {
            for (at, _) in production.match_indices(call) {
                found.push(call);
                if !holds_up_the_chain(&production, &fns, at, &feeds, &mut Vec::new()) {
                    unfed.push(text_around(&production, at, call.len()));
                }
            }
        }
        assert_eq!(
            {
                let mut missing: Vec<&str> = EFFECTS_CALLS
                    .iter()
                    .copied()
                    .filter(|call| !found.contains(call))
                    .collect();
                missing.sort_unstable();
                missing
            },
            Vec::<&str>::new(),
            "anti-vacuity: an effects call is no longer found by the scan",
        );
        assert_eq!(
            unfed,
            Vec::<String>::new(),
            "an engine batch never reaches the owed-advance feed",
        );
        let generic = |name: &str| {
            let from = production
                .find(&format!("fn {name}<"))
                .unwrap_or_else(|| panic!("fn {name} exists"));
            let rest = &production[from..];
            rest[..rest[1..].find("fn ").map_or(rest.len(), |next| next + 1)].to_string()
        };
        assert!(
            generic("note_effects").contains("self.owe_advance(batch.pending());")
                && generic("noted").contains("self.note_effects(held,batch);")
                && production.matches("self.note_batch(").count() == 1,
            "the feed is not the one way an engine batch is noted",
        );
    }

    /// Every ingest of a relay's group traffic — each `session.ingest(` but
    /// the Welcome's — notes what it took in through the one funnel that
    /// records it for the NIP-77 pass, in the hold that took it in; and the
    /// funnel records only what the engine took in for a group it knows, so
    /// a refused or unpersisted object is never on record as held
    /// (Security Rule 12). Nothing else writes the inventory but a test seam.
    #[test]
    fn every_ingest_funnel_records_what_it_took_in_for_negentropy() {
        let (_, production) = session_manager_texts();
        let fns = functions(&production);
        let around = |at: usize| {
            let index = fns
                .iter()
                .rposition(|(start, _)| *start < at)
                .expect("a call sits in a function");
            let end = fns
                .get(index + 1)
                .map_or(production.len(), |(next, _)| *next);
            (fns[index].1.clone(), end)
        };
        let mut funnels = Vec::new();
        let mut unnoted = Vec::new();
        for (at, _) in production.match_indices("session.ingest(") {
            let (name, end) = around(at);
            if name == "accept_welcome" {
                continue;
            }
            if !production[at..end].contains("self.note_ingested(") {
                unnoted.push(name.clone());
            }
            funnels.push(name);
        }
        funnels.sort();
        assert_eq!(
            funnels,
            ["hand_back", "ingest", "staging_ingest"],
            "anti-vacuity: the ingest funnels are not the three this pin reads",
        );
        assert_eq!(
            unnoted,
            Vec::<String>::new(),
            "a funnel records nothing for the pass"
        );
        let funnel = fn_text(&production, "note_ingested");
        assert!(
            funnel.contains("self.took_in(id,result)")
                && funnel.contains("InputRejectionCategory::UnknownGroup")
                && funnel.contains("record_transport_reconciliation_item(")
                && funnel.contains("event.tags.expiration().is_none()"),
            "the funnel records something the engine did not take in, for a group it does \
             not know, or a location durably",
        );
        let writers: Vec<String> = production
            .match_indices("record_transport_reconciliation_item(")
            .map(|(at, _)| around(at).0)
            .filter(|name| name != "note_ingested" && !name.ends_with("_for_test"))
            .collect();
        assert_eq!(
            writers,
            Vec::<String>::new(),
            "the inventory is written outside the funnel"
        );
    }

    /// The session manager's source as one line with no space beside
    /// punctuation: all of it, and its production text alone.
    fn session_manager_texts() -> (String, String) {
        let source = std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/nostr/mls/manager.rs"),
        )
        .expect("read the session manager source");
        (tight_code(&source), tight_code(&production_text(&source)))
    }

    /// The text of `fn name(` in `text`, up to the next function.
    fn fn_text<'a>(text: &'a str, name: &str) -> &'a str {
        let from = text
            .find(&format!("fn {name}("))
            .unwrap_or_else(|| panic!("fn {name} exists"));
        let rest = &text[from..];
        &rest[..rest[1..].find("fn ").map_or(rest.len(), |next| next + 1)]
    }

    /// The one row the second connection deletes under a live session is a
    /// stranded one, and only inside the hand-back: with the engine held
    /// mutably by the caller, after the event is durably kept and verified
    /// as the event its entry names, of rows in the one state a stranded row
    /// has, in a circle the open engine reports stable — read again before
    /// each event. A release anywhere else — before the open, outside the
    /// hold, ahead of the keep or of the verification, or of a row in
    /// another state — could take from the engine something its own replay
    /// or sweep still owns, or leave an event with neither store.
    ///
    /// And the hand-back fails closed: a store that cannot say what stands
    /// is answered for as holding, an event ends only on an answer the
    /// engine or the refused ledger has on record, and an error ends one
    /// only where the engine wrote its own record of the event first.
    #[test]
    #[allow(clippy::too_many_lines)]
    fn the_second_connection_releases_a_row_only_in_the_hand_back_with_the_engine_held() {
        let (flat, _) = session_manager_texts();
        let body = |name: &str| fn_text(&flat, name);
        let (one, owed) = (body("hand_back_circle"), body("owed_a_hand_back"));
        let (beside, taken) = (body("take_up_kept"), body("take_over"));
        let releases = ".release_message_for_replay(&record)";
        assert_eq!(
            (
                flat.matches("release_message_for_replay(").count(),
                beside.matches(releases).count(),
                taken.matches(releases).count(),
                flat.matches("self.take_up_kept(").count(),
                one.matches("Owed::Kept(kept)=>self.take_up_kept(group_id,kept),")
                    .count(),
                flat.matches("self.take_over(").count(),
                one.matches("Owed::Row(row)=>self.take_over(group_id,*row,&mut used),")
                    .count(),
            ),
            (2, 1, 1, 1, 1, 1, 1),
            "a row is released from somewhere other than the hand-back of its circle",
        );
        assert_eq!(
            flat.matches("delete_message(").count(),
            0,
            "a stored row is deleted outright: a release is MDK's, a delete is nobody's",
        );
        // A row the engine still holds is rebuilt as an event, found to
        // carry the row's id, and kept, durably, before it is released. The
        // other release is of a row found standing beside a copy an earlier
        // hold had already kept: the copy is parsed, verified and found to
        // carry its entry's id first, so a copy that is no longer that event
        // never costs the engine's row — the only other copy there is.
        let rebuilt = "Self::transport_message_to_event(&message).ok().filter(|event|\
                       event.id.as_bytes().as_slice()==record.id.as_slice())else{\
                       return TakenOver::Left;};";
        let verified = "Event::from_json(&kept.event).ok().filter(|event|{event.verify().is_ok()\
                        &&event.id.as_bytes().as_slice()==kept.id.as_slice()})else{";
        assert!(
            taken
                .find(rebuilt)
                .zip(taken.find(".keep(group_id,&record.id,"))
                .zip(taken.find(releases))
                .is_some_and(|((rebuilt, kept), released)| rebuilt < kept && kept < released)
                && beside
                    .find(verified)
                    .zip(beside.find(releases))
                    .is_some_and(|(verified, released)| verified < released)
                && beside.contains("stranded_row(&self.message_store,record,&self.examined)"),
            "a row is released before its event is rebuilt, matched to the row's id and \
             durably kept, a kept copy is not parsed, verified and matched to its entry's id \
             before the row beside it is released, or one that is not a stranded row is \
             released there",
        );
        let each = one.find("for owed in owed").expect("the hand-back's loop");
        assert!(
            one.starts_with(
                "fn hand_back_circle(&self,session:&mut AccountDeviceSession,group_id:&GroupId,"
            ) && one.contains("let nothing=replays_nothing(&self.message_store,session,group_id);")
                && one[each..]
                    .find("match replays_nothing(&self.message_store,session,group_id){")
                    .zip(one[each..].find("self.take_up_kept(group_id,kept)"))
                    .is_some_and(|(read, released)| read < released),
            "the hand-back no longer runs with the engine held, or no longer asks the open \
             engine before each event whether the circle holds a pending commit",
        );
        assert!(
            one.contains(
                "match nothing{Some(true)=>{}Some(false)=>return drain,\
                 None=>return Drain::held(),}"
            ) && one.contains(
                "let Some((kept,rows,beyond))=self.owed_a_hand_back(group_id,*room)else{\
                 return Drain::held();};"
            ) && owed.contains("let kept=kept?;")
                && owed.contains("let(rows,beyond)=rows?;")
                && one[each..]
                    .contains("{Some(true)=>{}Some(false)=>break,None=>return Drain::held(),}")
                && taken.contains("TakenOver::Stopped{holds:self.commit_notes.durable(),"),
            "a store the hand-back could not read or write is no longer answered for as \
             holding: rows nobody looked at would stand with their circle neither told nor \
             held, and the next seal would go out ahead of them",
        );
        assert!(
            owed.contains(
                "stranded_rows(&self.message_store,group_id,&kept,room,&self.examined).ok();"
            ),
            "the hand-back takes over a row the stranded-row test did not name, or reads \
             more of them than the call has room for",
        );
        let answered = body("hand_back");
        assert!(
            answered.contains(
                "if self.message_store.has_processed_transport_id(id).unwrap_or(false){\
                 self.commit_notes.end(id);return HandedBack::Answered;}\
                 self.commit_notes.unanswered(id);return HandedBack::Unanswered;"
            ) && answered.contains(
                "let taken=if refused{!unrecorded&&self.refused_ledger.record(group_id,\
                 &[event.id],self.ledger_now_secs())}else{"
            ) && answered.contains(
                "if taken{self.commit_notes.end(id);}else{self.commit_notes.unanswered(id);}"
            ) && answered.contains(
                // An unknown route is dropped without a trace by design: no
                // redelivery changes that, and nothing is owed for it.
                "let refused=matches!(ingested.outcome,IngestOutcome::ResourceRefused{..})\
                 ||(ingested.left_object_unpersisted\
                 &&!matches!(ingested.outcome,IngestOutcome::Ignored{..}));"
            ),
            "an event the engine erred on ends without the engine's own record of it, or one \
             it refused ends without its id on record in the ledger: it would be in neither \
             store",
        );
        assert_eq!(
            (
                flat.matches("hand_back_circle(").count(),
                body("hand_back_stranded")
                    .matches(".hand_back_circle(session,")
                    .count(),
            ),
            (2, 1),
            "a circle's stranded rows are handed back from somewhere other than the one \
             entry the session's engine calls make",
        );
        let (unopened, row, rows) = (
            body("unopened_event"),
            body("stranded_row"),
            body("stranded_rows"),
        );
        assert!(
            unopened.contains("if record.state!=MessageState::Retryable{return None;}")
                && unopened.contains("payload.as_raw_transport().cloned()")
                && unopened.contains("TransportEnvelope::GroupMessage{..}")
                && row.contains("let Some(message)=unopened_event(&record)else{")
                && row.contains(
                    "Ok((!store.has_processed_transport_id(&record.id)?)\
                     .then_some((record,message)))"
                )
                && rows.contains("&[MessageState::Retryable],EpochId(0),")
                && rows.contains("if let Some(message)=unopened_event(&record){")
                && rows.contains(
                    "if!store.has_processed_transport_id(&record.id)?{\
                     rows.push((record,message));}"
                ),
            "the stranded-row test no longer names exactly an unopened group event stored \
             `Retryable` that the engine does not hold as processed",
        );
        let state = body("replays_nothing");
        assert!(
            state.contains("session.epoch_state(group_id),Some(EpochState::Stable{..})")
                && state.contains("Ok(group)=>Some(!group.is_terminal()&&!group.unrecoverable),")
                && state.contains("Err(_)=>None,"),
            "a circle is read as holding no pending commit from something other than the \
             open engine, or one this device is out of, or a halted one, is read so, or a \
             store that cannot say is read as saying something",
        );
    }

    /// The engine calls that take an event, seal, stage or advance — the
    /// leave's own send among them, which two entries share. The full
    /// advance's name is spelled in two halves:
    /// `check_advance_convergence_sites.sh` reads this file for the call.
    const ENGINE_CALLS: [&str; 5] = [
        "session.ingest(",
        "session.send(",
        concat!("session.advance_", "convergence("),
        "session.advance_convergence_inputs(",
        "Self::send_leave(",
    ];

    /// Functions that make one of [`ENGINE_CALLS`] and are not entries, each
    /// asked only where a hand-back has already run: the hand-back's own
    /// ingest; the send of an admin change or a self-update; the inputs-only advance that
    /// collects what a failed advance left; the leave's send, which its two
    /// entries make after their own hand-back. And a Welcome, which is no
    /// circle's event: it joins one this device holds nothing for.
    const NOT_ENTRIES: [&str; 6] = [
        "hand_back",
        "send_admin_policy_now",
        "send_self_update_now",
        "after_a_failed_advance",
        "send_leave",
        "accept_welcome",
    ];

    /// Every session entry that asks the engine to take an event, seal,
    /// stage or advance hands stranded input back first, and puts what came
    /// back ahead of its own batch or keeps it for the next — enumerated
    /// from the source, so a new entry that does not fails here. An entry
    /// that skipped it would take or seal something new of a circle before
    /// what that circle was owed; one that dropped it would lose what the
    /// engine applied.
    ///
    /// Three limits of this scan, recorded until they are closed (W9k):
    ///
    /// 1. It reads a call written `session.<call>(`. One written through the
    ///    guard without a binding — `self.engine().await?.<call>(` — is not
    ///    seen, and would pass with no hand-back.
    /// 2. `prepare_convergence_cutoff_delay_ms` is not one of
    ///    [`ENGINE_CALLS`]: it reads a deadline, and MDK may open a
    ///    convergence pass while answering. It is asked with no hand-back
    ///    first.
    /// 3. `accept_welcome` is exempt by NAME ([`NOT_ENTRIES`]) while its
    ///    body ingests: right for a Welcome, which joins a circle this
    ///    device holds nothing for, and unchecked for anything else that
    ///    function comes to take.
    #[test]
    fn every_entry_that_takes_seals_stages_or_advances_hands_stranded_input_back_first() {
        let (_, production) = session_manager_texts();
        let mut entries = Vec::new();
        for (at, _) in production.match_indices("fn ") {
            let rest = &production[at..];
            let entry = &rest[..rest[1..].find("fn ").map_or(rest.len(), |next| next + 1)];
            let name = entry[3..]
                .split(|c: char| !(c.is_alphanumeric() || c == '_'))
                .next()
                .unwrap_or_default();
            let Some(asked) = ENGINE_CALLS
                .iter()
                .filter_map(|call| entry.find(call))
                .min()
            else {
                continue;
            };
            if NOT_ENTRIES.contains(&name) || name.ends_with("_for_test") {
                continue;
            }
            assert!(
                entry
                    .find("=Box::pin(self.hand_back_stranded(")
                    .is_some_and(|handed| handed < asked)
                    && (entry.contains("self.behind_what_was_handed_back(ahead,")
                        || entry.contains("self.keep_handed_back(ahead)")),
                "`{name}` asks the engine before it has handed stranded input back, or does \
                 not put what came back ahead of its own batch",
            );
            entries.push(name);
        }
        assert_eq!(
            entries,
            [
                "leave_group",
                "leave_group_staging",
                "send_inner",
                "departure_holds_a_send",
                "ingest",
                // A relay's event and, never noted as one, a mesh packet's.
                "staging_ingest",
                "advance_once_for_receive",
                "advance_convergence",
                // The staging send's hold, with its hand-back, behind the
                // one-line `send_staging` and decision 180's ask, which
                // takes back in that hold what the engine queued.
                "send_staging_keeping",
                "send_location_staging",
                "advance_once_for_drive",
                "settle_inputs_for_drive",
            ],
            "the entries that ask the engine to take, seal, stage or advance are not the ones \
             this gate was written against",
        );
        for caller in ["change_admin_policy_staging", "send_admin_policy"] {
            let caller_body = fn_text(&production, caller);
            assert!(
                caller_body
                    .find("=Box::pin(self.hand_back_stranded(")
                    .zip(caller_body.find(".send_admin_policy_now("))
                    .is_some_and(|(handed, sent)| handed < sent)
                    && caller_body.contains("self.behind_what_was_handed_back(ahead,"),
                "`{caller}` sends an admin change before it has handed stranded input back",
            );
        }
        for caller in [
            "repair_self_update_staging",
            "post_join_self_update_staging",
        ] {
            let caller_body = fn_text(&production, caller);
            assert!(
                caller_body
                    .find("=Box::pin(self.hand_back_stranded(")
                    .zip(caller_body.find(".send_self_update_now("))
                    .is_some_and(|(handed, sent)| handed < sent)
                    && caller_body.contains("self.behind_what_was_handed_back(ahead,"),
                "`{caller}` sends a self-update before it has handed stranded input back",
            );
        }
        assert_eq!(
            production.matches("send_self_update_now(").count(),
            3,
            "a self-update is sent from somewhere other than its two callers, each of \
             which hands stranded input back first",
        );
        assert_eq!(
            (
                production.matches("send_admin_policy_now(").count(),
                production.matches("self.after_a_failed_advance(").count(),
                fn_text(&production, "advance_once_for_drive")
                    .matches("self.after_a_failed_advance(")
                    .count(),
                production.matches("self.hand_back(session,").count(),
                fn_text(&production, "hand_back_circle")
                    .matches("self.hand_back(session,")
                    .count(),
            ),
            // `send_admin_policy_now`: its definition and its two callers.
            (3, 1, 1, 1, 1),
            "an admin change is sent, a failed advance is collected, or one event is handed \
             back from somewhere no hand-back has run",
        );
    }

    /// A stored rolled-back record is finished before any engine call for
    /// its circle because the engine can be borrowed mutably through one
    /// accessor only, which finishes it or refuses (T-ROLLBACK-RESURRECT).
    ///
    /// The compiler holds most of that: the session's lock is a private
    /// field of `engine_gate::Gated`, and so is the lock guard inside what
    /// either accessor hands out, so nothing outside that module can lock
    /// the session, take a guard apart, or reach the lock back through one
    /// (`MutexGuard::mutex`); and what is owed can be raised only by a caller
    /// that holds the session. What the compiler cannot hold
    /// is pinned here: the shape inside the module, and that the session
    /// manager reaches the gate through its own two accessors — the gated
    /// one always with the finisher that retires.
    #[test]
    fn the_engine_is_borrowed_mutably_through_the_gated_accessor_alone() {
        let read = |file: &str| {
            let source = std::fs::read_to_string(
                std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(file),
            )
            .unwrap_or_else(|_| panic!("read {file}"));
            tight_code(&production_text(&source))
        };
        let body_of = |flat: &str, name: &str| {
            let from = flat
                .find(&format!("fn {name}"))
                .unwrap_or_else(|| panic!("fn {name} exists"));
            let rest = &flat[from..];
            rest[..rest[1..].find("fn ").map_or(rest.len(), |next| next + 1)].to_string()
        };

        let gate = read("src/nostr/mls/engine_gate.rs");
        assert!(
            gate.contains("session:Mutex<S>,")
                && !gate.contains("pub session")
                && !gate.contains("pub(super)session")
                && !gate.contains("pub(crate)session"),
            "the session's lock can be named outside the gate's module",
        );
        assert!(
            gate.contains("struct Reading<") && !gate.contains("(pub"),
            "the read guard can be taken apart outside the gate's module",
        );
        assert!(
            gate.matches("DerefMut").count() == 1
                && gate.contains("impl<S>std::ops::DerefMut for Engine<'_,S>"),
            "the read-only guard can be borrowed mutably",
        );
        assert!(
            gate.contains("struct Engine<'a,S>(MutexGuard<'a,S>);")
                && gate.contains("->Result<Engine<'_,S>,Held>")
                && gate.matches("MutexGuard<").count() == 2,
            "the gated accessor hands out tokio's own guard, which gives the lock back \
             (`MutexGuard::mutex`), or a guard whose inside can be named",
        );
        assert!(
            gate.contains("fn owe_finish(&self,_held:&S)")
                && gate.contains("fn is_held(&self)->bool{self.session.try_lock().is_err()}")
                && gate.matches("try_lock()").count() == 1,
            "what is owed can be raised by a caller that does not hold the session, or the \
             gate's test seam does more than ask whether the lock is held",
        );
        assert_eq!(
            gate.matches(".lock()").count(),
            2,
            "the session is locked somewhere other than the gate's two accessors",
        );
        assert!(body_of(&gate, "reading").contains("Reading(self.session.lock().await)"));
        let gated = body_of(&gate, "engine");
        let locked = gated.find("self.session.lock().await");
        let checked = gated.find("if self.unfinished.load(");
        let refused = gated.find("return Err(Held);");
        let handed = gated.rfind("Ok(Engine(session))");
        assert!(
            locked.is_some() && locked < checked && checked < refused && refused < handed,
            "the gated accessor hands the engine over before it has finished or refused",
        );
        assert_eq!(
            (
                gate.matches("Reading(").count(),
                gate.matches("Engine(").count()
            ),
            (1, 1),
            "a guard is built outside its accessor",
        );

        let manager = read("src/nostr/mls/manager.rs");
        assert_eq!(
            (
                manager.matches("self.session.").count(),
                manager.matches("self.session.reading().await").count(),
                manager
                    .matches("self.session.engine(|session|self.finish_rollbacks(session))")
                    .count(),
                manager.matches("self.session.owe_finish(session)").count()
                    + manager.matches("self.session.owe_finish(&session)").count(),
                // A test's question of whether the lock is held: a try-lock
                // that borrows nothing.
                manager.matches("self.session.is_held()").count(),
            ),
            (5, 1, 1, 2, 1),
            "the session is reached some other way than through its two accessors, or the \
             gated one is given a finisher that does not retire",
        );
        assert!(
            body_of(&manager, "finish_rollbacks").contains("retire_commit(")
                && body_of(&manager, "finish_rollbacks").contains("finish_rolled_back_in("),
            "the gate's finisher no longer retires what a rollback left stored as sent",
        );
        assert_eq!(
            (
                manager.matches(".await.held()").count(),
                body_of(&manager, "hold_session_for_test")
                    .matches("self.reading().await.held()")
                    .count()
            ),
            (1, 1),
            "the read-only guard's lock is taken out of it outside the one test seam",
        );
    }

    /// The code of `source` — comments and the contents of literals blanked —
    /// on one line, with no space beside punctuation. Blanked by the lexer
    /// the production scanner uses, not line by line: a comment can then
    /// neither hide the code after it nor be read as code.
    fn tight_code(source: &str) -> String {
        let spaced = strip_comments_and_literals(source)
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        let is_punct = |c: char| ".(),&:;={}<>|!?".contains(c);
        let chars: Vec<char> = spaced.chars().collect();
        chars
            .iter()
            .enumerate()
            .filter(|(i, c)| {
                **c != ' '
                    || !(i.checked_sub(1).is_some_and(|p| is_punct(chars[p]))
                        || chars.get(i + 1).is_some_and(|n| is_punct(*n)))
            })
            .map(|(_, c)| *c)
            .collect()
    }

    /// The method named after every `…store.` in `flat`. An empty name is
    /// not a call — `store..` builds a range that carries the handle away —
    /// and is reported, never skipped.
    fn second_handle_calls(flat: &str) -> Vec<String> {
        flat.split("store.")
            .skip(1)
            .map(|tail| {
                tail.chars()
                    .take_while(|c| c.is_alphanumeric() || *c == '_')
                    .collect()
            })
            .collect()
    }

    /// The calls of `seen` outside [`SECOND_HANDLE_SURFACE`], once each.
    fn outside_the_surface(seen: &[String]) -> Vec<&String> {
        let mut forbidden: Vec<&String> = seen
            .iter()
            .filter(|name| !SECOND_HANDLE_SURFACE.contains(&name.as_str()))
            .collect();
        forbidden.sort();
        forbidden.dedup();
        forbidden
    }

    /// How a helper declares the second handle, in [`tight_code`]'s form.
    const STORE_PARAM: &str = "(store:&SqliteAccountStorage";

    /// The text of `flat` around the `len` bytes at `at`, for a finding.
    fn text_around(flat: &str, at: usize, len: usize) -> String {
        let from = flat[..at]
            .char_indices()
            .rev()
            .nth(30)
            .map_or(0, |(i, _)| i);
        let to = flat[at + len..]
            .char_indices()
            .nth(12)
            .map_or(flat.len(), |(i, _)| at + len + i);
        flat[from..to].to_string()
    }

    /// Every place a name of `helpers` means something other than that
    /// helper. A local or a second free function under the name would be
    /// called exactly like the helper; a method of that name is not — it is
    /// never called unqualified.
    fn helper_name_misuses(flat: &str, helpers: &[String]) -> Vec<String> {
        let ident = |c: char| c.is_alphanumeric() || c == '_';
        let mut bad = Vec::new();
        for name in helpers {
            for (at, _) in flat.match_indices(name.as_str()) {
                let (before, after) = (&flat[..at], &flat[at + name.len()..]);
                if before.ends_with(ident) || after.starts_with(ident) {
                    continue;
                }
                let allowed = if before.ends_with("fn ") {
                    // `(selfish: …` is a parameter, not a receiver.
                    after.starts_with(STORE_PARAM)
                        || ["(&self", "(&mut self", "(self"].iter().any(|receiver| {
                            after
                                .strip_prefix(receiver)
                                .is_some_and(|rest| rest.starts_with([')', ',', ':']))
                        })
                } else {
                    after.starts_with('(')
                };
                if !allowed {
                    bad.push(text_around(flat, at, name.len()));
                }
            }
        }
        bad
    }

    /// Every place `flat` names the second storage handle in a form the
    /// receiver scan does not follow, as the text around it.
    ///
    /// Allowed, and nothing else: the field and its one constructor; a method
    /// receiver (`…store.`); a parameter spelled `store: &SqliteAccountStorage`;
    /// and the handle passed first, unqualified, to a function that declares
    /// exactly that parameter first — whose name must mean that function
    /// wherever it appears. A macro definition, an `include!` and a `#[path]`
    /// are findings wherever they are: each puts code where the scan is not.
    fn unscanned_handle_uses(flat: &str) -> Vec<String> {
        const TYPE: &str = "SqliteAccountStorage";
        let ident = |c: char| c.is_alphanumeric() || c == '_';
        // The identifier `before` ends with, when it is called unqualified.
        let callee = |before: &str| -> Option<String> {
            let name: String = before
                .chars()
                .rev()
                .take_while(|c| ident(*c))
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect();
            let qualified = before[..before.len() - name.len()].ends_with([':', '.']);
            (!name.is_empty() && !qualified).then_some(name)
        };
        let helpers: Vec<String> = flat
            .match_indices(STORE_PARAM)
            .filter_map(|(at, _)| {
                let name = callee(&flat[..at])?;
                flat[..at - name.len()].ends_with("fn ").then_some(name)
            })
            .collect();
        let to_helper = |before: &str| {
            before
                .strip_suffix('(')
                .and_then(callee)
                .is_some_and(|name| helpers.contains(&name))
        };
        let around = |at: usize, len: usize| text_around(flat, at, len);

        let mut bad = Vec::new();
        for (at, _) in flat.match_indices("message_store") {
            let (before, after) = (&flat[..at], &flat[at + "message_store".len()..]);
            let allowed = after.starts_with('.')
                || after.starts_with(":SqliteAccountStorage,")
                || (before.ends_with("let ") && after.starts_with("=SqliteAccountStorage::open_"))
                || before
                    .strip_suffix("&self.")
                    .or_else(|| before.strip_suffix('&'))
                    .is_some_and(to_helper)
                // The constructor's field initialiser.
                || (before.ends_with("preview_peeler,") && after.starts_with(",_live_guard:"));
            if !allowed {
                bad.push(around(at, "message_store".len()));
            }
        }
        for (at, _) in flat.match_indices("store") {
            let (before, after) = (&flat[..at], &flat[at + "store".len()..]);
            // Part of a longer name, or a method called `store`.
            if before.ends_with(|c: char| ident(c) || c == '.') || after.starts_with(ident) {
                continue;
            }
            let allowed = after.starts_with('.')
                || after.starts_with(":&SqliteAccountStorage")
                || to_helper(before);
            if !allowed {
                bad.push(around(at, "store".len()));
            }
        }
        for (at, _) in flat.match_indices(TYPE) {
            let (before, after) = (&flat[..at], &flat[at + TYPE.len()..]);
            let allowed = before.ends_with("(store:&")
                || before.ends_with(",store:&")
                || before.ends_with("message_store:")
                || (before.ends_with("let message_store=") && after.starts_with("::open_"))
                || before.ends_with("use storage_sqlite::{SqlCipherKey,");
            if !allowed {
                bad.push(around(at, TYPE.len()));
            }
        }
        // A call written through one of these is not in the text scanned.
        for unreadable in ["macro_rules!", "include!(", "#[path"] {
            if let Some(at) = flat.find(unreadable) {
                bad.push(around(at, unreadable.len()));
            }
        }
        bad.extend(helper_name_misuses(flat, &helpers));
        bad
    }

    /// Uses of the second handle the scans can follow, as `(what, code)`.
    fn followed_handle_forms() -> Vec<(&'static str, &'static str)> {
        vec![
            (
                "a receiver, wrapped",
                "self.message_store\n    .get_group(id);",
            ),
            (
                "the handle handed to a helper",
                "sweep(&self.message_store);",
            ),
            (
                "a helper handing it on",
                "fn outer(store: &SqliteAccountStorage) { sweep(store); }",
            ),
            (
                "a read assigned through a dereference",
                "*n = self.message_store.list_groups()?;",
            ),
            (
                "a method under the helper's name, calling it",
                "impl M { fn sweep(&self) { sweep(&self.message_store); } }\nm.sweep();",
            ),
            (
                "a comment between the handle and an allowed read",
                "self.message_store. /* c */ get_group(id);",
            ),
            (
                "a write named only in a comment or a string",
                "self.message_store.get_group(id); // not store.put_group(g)\nlet s = \"store.put_group\";",
            ),
        ]
    }

    /// Uses of the second handle the scans must refuse, as `(what, code)`.
    fn unfollowed_handle_forms() -> Vec<(&'static str, &'static str)> {
        vec![
            (
                "a trait-qualified call",
                "GroupStorage::put_group(\n    &self.message_store,\n    g,\n);",
            ),
            (
                "a rebinding",
                "let h = &self.message_store;\nh.put_group(g);",
            ),
            (
                "a rebinding inside a helper",
                "fn outer(store: &SqliteAccountStorage) { let h = store; h.put_group(g); }",
            ),
            (
                "a parameter under another name",
                "fn peek(db: &SqliteAccountStorage) { db.put_group(g); }",
            ),
            (
                "the handle handed to something else",
                "other(&self.message_store);",
            ),
            (
                "a method path on the helper's name",
                "Thing::sweep(&self.message_store);",
            ),
            (
                "a write assigned through a dereference",
                "*n = self.message_store.put_group(g)?;",
            ),
            (
                "a trait-qualified call assigned through a dereference",
                "*n = GroupStorage::list_groups(&self.message_store)?;",
            ),
            (
                "a comment between the handle and a write",
                "self.message_store. /* c */ put_group(g);",
            ),
            (
                "a call on the line a block comment makes look commented out",
                "let _ = /*\n// */ GroupStorage::list_groups(&self.message_store);",
            ),
            (
                "a range that carries the handle away",
                "fn outer(store: &SqliteAccountStorage) { let r = store..store; r.start.put_group(g); }",
            ),
            (
                "a method that only shares the helper's name",
                "x.sweep(&self.message_store);",
            ),
            (
                "a local that shadows the helper",
                "let sweep = <_ as GroupStorage>::put_group;\nsweep(&self.message_store, g);",
            ),
            (
                "a second function under the helper's name",
                "fn inner() { fn sweep(s: &impl GroupStorage) { s.put_group(g); } }",
            ),
            (
                "a second function whose parameter only begins with `self`",
                "fn inner() { fn sweep(selfish: &impl GroupStorage) { selfish.put_group(g); } }",
            ),
            (
                "a macro that could write the call",
                "macro_rules! via { ($s:expr) => { $s.list_groups() }; }",
            ),
            (
                "code included from another file",
                "include!(\"calls.rs\");",
            ),
            (
                "a module read from another path",
                "#[path = \"calls.rs\"]\nmod calls;",
            ),
            (
                "a parameter whose name only ends in `store`",
                "fn peek(kstore: &SqliteAccountStorage) { let h = kstore; h.put_group(g); }",
            ),
        ]
    }

    /// The handle scan refuses each form the receiver scan cannot read, and
    /// accepts the forms the session manager really uses.
    #[test]
    fn the_second_handle_scan_refuses_every_form_it_cannot_follow() {
        let refuses = |code: &str| {
            let flat = tight_code(&format!(
                "fn sweep(store: &SqliteAccountStorage) {{ store.list_groups(); }}\n{code}"
            ));
            !(unscanned_handle_uses(&flat).is_empty()
                && outside_the_surface(&second_handle_calls(&flat)).is_empty())
        };
        for (name, code) in followed_handle_forms() {
            assert!(!refuses(code), "{name}");
        }
        for (name, code) in unfollowed_handle_forms() {
            assert!(refuses(code), "{name}");
        }
    }

    /// Proposals owed a send are kept one an event id, and the newest
    /// [`OWED_PROPOSALS_CAP`] alone: a call that may call no relay, repeated
    /// without end, costs a bounded amount of memory, and the oldest is what
    /// goes.
    #[test]
    fn owed_proposals_are_kept_once_each_and_a_bounded_number() {
        let keys = nostr::Keys::generate();
        let proposal = |n: usize| {
            nostr::EventBuilder::new(nostr::Kind::Custom(445), n.to_string())
                .sign_with_keys(&keys)
                .expect("signed")
        };
        let ids = |owed: &[Event]| owed.iter().map(|event| event.id).collect::<Vec<_>>();
        let (first, second) = (proposal(0), proposal(1));
        let mut owed = Vec::new();

        owe(
            &mut owed,
            vec![first.clone(), second.clone(), first.clone()],
        );
        owe(&mut owed, vec![second.clone()]);
        assert!(
            ids(&owed) == [first.id, second.id],
            "a proposal owed twice is kept twice, and would be sent twice"
        );

        let later: Vec<Event> = (2..OWED_PROPOSALS_CAP + 3).map(proposal).collect();
        owe(&mut owed, later.clone());
        assert!(
            owed.len() == OWED_PROPOSALS_CAP,
            "more proposals are kept than the cap"
        );
        assert!(
            ids(&owed) == ids(&later[1..]),
            "the cap did not drop the oldest, in order"
        );
    }
}
