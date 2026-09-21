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
use super::storage::CircleStorage;
use super::storage_member_directory::DirectoryTier;
use super::types::{
    Circle, CircleConfig, CircleMember, CircleMembership, CircleType, CircleWithMembers, Contact,
    GiftWrappedWelcome, Invitation, MemberKeyPackage, MembershipStatus,
};
use crate::location::LocationMessage;
use crate::log_alias::{self, bucket, EventIdHex};
use crate::nostr::mls::types::{
    ConvergedRoster, ConvergenceSweep, GroupEvent, GroupId, GroupIdExt, KeyPackage,
    LocationGroupConfig, LocationMessageResult, PendingStateRef, PublishWork, SessionEffects,
    TransportMessage,
};
use crate::nostr::mls::{bounded_retention_secs, redact_hex_sequences};
use crate::nostr::mls::{PendingWelcome, PendingWelcomeStore, SessionManager};

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
fn redact_storage_error(err: &CircleError) -> CircleError {
    CircleError::Storage(redact_hex_sequences(&err.to_string()))
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
    /// Binds each in-flight `GroupCreated` `pending` to its group id so a
    /// create that is rolled back (all welcomes zero-ack → `publish_failed`, or
    /// a post-stage error) removes the eagerly-persisted circle/membership rows
    /// instead of stranding a ghost circle backed by no confirmed group (F2).
    /// In-memory: an unresolved create at process exit self-clears on restart
    /// (the engine also rolls the staged create back at hydrate).
    create_pending: Mutex<HashMap<PendingStateRef, GroupId>>,
    /// Binds each in-flight repair-rotation `pending` to the circle whose 24-hour
    /// rate limit it spends, so [`Self::confirm_published`] records the rotation
    /// and [`Self::publish_failed`] does not — see
    /// [`Self::register_rotation_pending`].
    rotation_pending: Mutex<HashMap<PendingStateRef, [u8; 32]>>,
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
    /// what keeps that off the latency of Add / Remove / Create Member, which
    /// Dart awaits inline through `confirm_published`.
    directory_flight: Mutex<DirectoryFlight>,
    /// Groups the engine has reported `Unrecoverable` during THIS session.
    ///
    /// `EpochState` has no accessor and is never persisted, so the
    /// `GroupUnrecoverable` event is the only signal there is. In-memory
    /// because that is exactly the state's scope: the one legal exit,
    /// `EpochState::repair_to_stable`, has no caller in the engine at the
    /// pinned rev, so the state is terminal within a session and gone after
    /// one — the same lifetime as hydration quarantine, and for the same
    /// reason. An unrecoverable group answers roster reads `Ok` with the roster
    /// frozen at its last stable epoch, so a reconcile that trusted it would
    /// re-stamp those people `Current` with the never-purge sentinel on every
    /// pass, and no removal there could ever be observed.
    unrecoverable_groups: Mutex<HashSet<GroupId>>,
    /// Removal-bearing receive-side auto-commits this device OWES a publish
    /// for, keyed by circle — see [`Self::owe_removal_publish`].
    ///
    /// At most one entry per circle, because a group holds at most one staged
    /// commit. Written by EVERY plane that takes such a commit, BEFORE it opens
    /// the publish-before-apply window rather than after that window fails — so
    /// the wedge a plane can leave behind is recorded whichever plane leaves it,
    /// and the detector is not blind to the planes that are not live-sync.
    ///
    /// In-memory because a [`PendingStateRef`] is: it is an engine handle valid
    /// for the life of this session and unresolvable after it. The DURABLE half
    /// lives in `deferred_removal_commits`, and the two disagreeing is the
    /// signal: a durable row this map does not know is an obligation a previous
    /// session took and never discharged.
    removal_deferrals: Mutex<HashMap<[u8; 32], CommitToPublish>>,
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
    pub(crate) storage: CircleStorage,
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

impl CircleManager {
    /// Maximum number of relays a circle may carry.
    ///
    /// MIP-01 says the group relay list SHOULD NOT exceed 20; Haven enforces it
    /// as a hard cap to bound kind-445 fan-out metadata and to stop an admin
    /// from inflating every member's subscription set.
    const MAX_CIRCLE_RELAYS: usize = 20;

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

        let session = SessionManager::new(data_dir, keys)
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;

        let db_path = data_dir.join("circles.db");
        let storage = CircleStorage::new(&db_path, circle_db_hex_key)?;
        Self::backfill_contamination_ledger(&storage);
        Self::prune_retired_profile_pool(&storage);
        Self::sweep_expired_directory_members(&storage);

        Ok(Self {
            session: Arc::new(session),
            pending_welcomes: PendingWelcomeStore::new(),
            create_pending: Mutex::new(HashMap::new()),
            rotation_pending: Mutex::new(HashMap::new()),
            profile_sync_lock: tokio::sync::Mutex::new(()),
            directory_lock: tokio::sync::Mutex::new(()),
            directory_flight: Mutex::new(DirectoryFlight::default()),
            unrecoverable_groups: Mutex::new(HashSet::new()),
            removal_deferrals: Mutex::new(HashMap::new()),
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

        let session = SessionManager::new_unencrypted(data_dir, keys)
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;

        let db_path = data_dir.join("circles.db");
        let storage = CircleStorage::new(&db_path, None)?;
        Self::backfill_contamination_ledger(&storage);
        Self::prune_retired_profile_pool(&storage);
        Self::sweep_expired_directory_members(&storage);

        Ok(Self {
            session: Arc::new(session),
            pending_welcomes: PendingWelcomeStore::new(),
            create_pending: Mutex::new(HashMap::new()),
            rotation_pending: Mutex::new(HashMap::new()),
            profile_sync_lock: tokio::sync::Mutex::new(()),
            directory_lock: tokio::sync::Mutex::new(()),
            directory_flight: Mutex::new(DirectoryFlight::default()),
            unrecoverable_groups: Mutex::new(HashSet::new()),
            removal_deferrals: Mutex::new(HashMap::new()),
            convergence_reticks: std::sync::atomic::AtomicUsize::new(0),
            storage,
        })
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
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?
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
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?
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
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;
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
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?
            .is_none()
        {
            return Ok(false);
        }

        Ok(self
            .session
            .member_pubkeys(mls_group_id)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?
            .iter()
            .any(|pk| pk == pubkey_hex))
    }

    // ==================== Circle Lifecycle ====================

    /// Creates a new circle with gift-wrapped welcome events.
    ///
    /// Creates the underlying MLS group and stores circle metadata. The engine
    /// produces the per-member gift-wrapped Welcomes (kind 1059) itself (the
    /// peeler owns the NIP-59 crypto now); Haven only resolves each recipient's
    /// delivery relays through the fail-closed cascade (member inbox → member
    /// NIP-65 → creator inbox → fail closed), so a bare-pubkey invitee with no
    /// advertised relay is uninvitable (the intended two-plane tradeoff).
    ///
    /// Publish-before-apply (Rule 13): the returned
    /// [`CircleCreationResult::pending`] must be confirmed via
    /// [`Self::confirm_published`] after the welcomes reach ≥1 relay, or rolled
    /// back via [`Self::publish_failed`] on failure.
    ///
    /// # Errors
    ///
    /// Returns an error if circle creation or welcome routing fails.
    pub async fn create_circle(
        &self,
        sender_keys: &Keys,
        members: Vec<MemberKeyPackage>,
        config: &CircleConfig,
        creator_fallback_relays: &[String],
    ) -> Result<CircleCreationResult> {
        // Fail closed BEFORE creating the MLS group: a member is deliverable iff
        // it advertises an inbox/NIP-65 relay OR the creator has an inbox
        // fallback (identical for every member). Pre-validate so the fail-closed
        // path leaves storage untouched.
        if creator_fallback_relays.is_empty() {
            for m in &members {
                if m.inbox_relays.is_empty() && m.nip65_relays.is_empty() {
                    return Err(CircleError::MissingWelcomeRelays);
                }
            }
        }

        // Default the group relay set to the user's Inbox relays when the caller
        // passed none (the group relay list drives kind-445 routing and the
        // Welcome metadata; the engine fail-closes on an empty set — W8).
        let effective_relays: Vec<String> = if config.relays.is_empty() {
            let inbox = self
                .storage
                .list_user_relays(crate::circle::relay_prefs::RelayType::Inbox)
                .unwrap_or_default();
            if inbox.is_empty() {
                log::warn!(
                    "[CircleManager] create_circle: user inbox relays empty, \
                     falling back to default relays (seed may not have run yet)"
                );
                crate::circle::types::default_relays()
            } else {
                inbox
            }
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

        self.create_circle_with_config(
            &members,
            key_package_events,
            mls_config,
            &cfg,
            creator_fallback_relays,
        )
        .await
    }

    /// Internal helper for circle creation with a configured MLS config.
    async fn create_circle_with_config(
        &self,
        members: &[MemberKeyPackage],
        key_package_events: Vec<Event>,
        mls_config: LocationGroupConfig,
        config: &CircleConfig,
        creator_fallback_relays: &[String],
    ) -> Result<CircleCreationResult> {
        let key_packages = parse_key_packages(&key_package_events)?;

        let effects = self
            .session
            .create_group(key_packages, mls_config)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;
        let group_id = effects.group_id.clone();

        // The transport routing id comes from the engine's freshly-minted
        // `marmot.transport.nostr.routing.v1` component (Rule 4: never the real
        // MLS group id).
        let (nostr_group_id, _) = self
            .session
            .group_routing(&group_id)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;

        // The engine returns gift-wrapped 1059 welcomes + a PendingStateRef under
        // GroupCreated. Extract BEFORE persisting any storage row, so a
        // (defensive) extraction failure leaves storage untouched.
        let (welcomes, pending) = self.take_group_created(effects.effects).await?;

        let now = chrono::Utc::now().timestamp();
        let circle = Circle {
            mls_group_id: group_id.clone(),
            nostr_group_id,
            display_name: config.name.clone(),
            circle_type: config.circle_type,
            relays: config.relays.clone(),
            created_at: now,
            updated_at: now,
        };
        // The STORED circle, not the struct assembled above: `save_circle`
        // sanitizes the display name, and this value is handed straight back to
        // the caller for rendering.
        let circle = self.storage.save_circle(&circle)?;
        // Contamination ledger: this set is about to carry the circle's kind-445
        // traffic and its commits, so it is permanently excluded from the
        // profile pool. Recorded BEFORE the welcomes go out — over-recording (a
        // create that is later rolled back) is the safe direction; the ledger is
        // append-only precisely because under-recording fails OPEN.
        self.record_contaminated(&circle.relays, ContaminationSource::CircleRouting)?;

        let membership = CircleMembership {
            mls_group_id: group_id.clone(),
            status: MembershipStatus::Accepted,
            inviter_pubkey: None,
            invited_at: now,
            responded_at: Some(now),
        };
        self.storage.save_membership(&membership)?;

        // F2: bind this create's `pending` to the just-saved rows so a later
        // rollback (all welcomes zero-ack → `publish_failed`, or the route error
        // below) deletes them instead of stranding a ghost circle backed by no
        // confirmed group.
        self.register_create_pending(pending, &group_id);

        // Route each welcome to its recipient's cascade relays. F3: if routing
        // fails AFTER the group + rows are staged, roll the pending back — which
        // also deletes the just-saved rows via the create-pending map — so
        // neither a PendingStateRef nor a ghost circle row leaks.
        let welcome_events =
            match self.route_welcomes_with_cascade(members, welcomes, creator_fallback_relays) {
                Ok(events) => events,
                Err(e) => {
                    // The rollback's own batch is discarded: this create was
                    // staged microseconds ago and has buffered nothing, and the
                    // caller is being handed an error rather than an ingest.
                    let _ = self.publish_failed(pending).await;
                    return Err(e);
                }
            };

        Ok(CircleCreationResult {
            circle,
            welcome_events,
            pending,
        })
    }

    /// Binds a create's `pending` to its group id so a later rollback removes
    /// the eagerly-persisted circle/membership rows (F2). See
    /// [`Self::publish_failed`].
    fn register_create_pending(&self, pending: PendingStateRef, group_id: &GroupId) {
        self.create_pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(pending, group_id.clone());
    }

    /// Removes and returns any group id bound to `pending` in the create-pending
    /// map (F2).
    fn take_create_pending(&self, pending: PendingStateRef) -> Option<GroupId> {
        self.create_pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&pending)
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
        creator_fallback_relays: &[String],
    ) -> Result<Vec<GiftWrappedWelcome>> {
        if welcomes.len() != members.len() {
            return Err(CircleError::Mls(format!(
                "Expected {} welcome(s), got {}",
                members.len(),
                welcomes.len()
            )));
        }

        let mut welcome_events = Vec::with_capacity(welcomes.len());
        for wt in welcomes {
            let event = SessionManager::transport_message_to_event(&wt)
                .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;

            // The gift wrap's `p` tag is the recipient identity.
            let recipient_pubkey = event
                .tags
                .iter()
                .find_map(|tag| {
                    let v = tag.as_slice();
                    if v.len() >= 2 && v[0] == "p" {
                        PublicKey::from_hex(&v[1]).ok()
                    } else {
                        None
                    }
                })
                .ok_or_else(|| {
                    CircleError::Mls("Welcome gift wrap missing recipient 'p' tag".to_string())
                })?;

            let member = members
                .iter()
                .find(|m| m.key_package_event.pubkey == recipient_pubkey)
                .ok_or_else(|| {
                    CircleError::Mls("No member matches welcome recipient".to_string())
                })?;

            // Cascade: member inbox → member NIP-65 → sender inbox → fail closed.
            let recipient_relays = if !member.inbox_relays.is_empty() {
                member.inbox_relays.clone()
            } else if !member.nip65_relays.is_empty() {
                member.nip65_relays.clone()
            } else if !creator_fallback_relays.is_empty() {
                creator_fallback_relays.to_vec()
            } else {
                return Err(CircleError::MissingWelcomeRelays);
            };

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

        Ok(welcome_events)
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

        let members = self.get_members(mls_group_id).await?;

        Ok(Some(CircleWithMembers {
            circle,
            membership,
            members,
        }))
    }

    /// Retrieves all circles.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub async fn get_circles(&self) -> Result<Vec<CircleWithMembers>> {
        let circles = self.storage.get_all_circles()?;
        let mut result = Vec::with_capacity(circles.len());

        for circle in circles {
            if let Some(membership) = self.storage.get_membership(&circle.mls_group_id)? {
                let members = self
                    .get_members(&circle.mls_group_id)
                    .await
                    .unwrap_or_default();
                result.push(CircleWithMembers {
                    circle,
                    membership,
                    members,
                });
            }
        }

        Ok(result)
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

    /// Step 1 of admin handoff: promote `successor` to admin via an
    /// `UpdateAppComponents(admin-policy.v1)` commit.
    ///
    /// The new policy is the group's current admin set plus `successor`, so a
    /// handoff never drops an existing admin. The caller stays an admin here —
    /// [`Self::propose_self_demote`] is the separate second commit — which keeps
    /// the group admin-covered at every intermediate epoch: a crash between the
    /// two commits leaves two admins, and `plan_leave` resumes cleanly on
    /// [`LeavePlan::AdminDemote`](super::leave::LeavePlan::AdminDemote) without
    /// re-promoting.
    ///
    /// Publish-before-apply (Rule 13): publish [`CommitToPublish::commit_event`],
    /// then [`Self::confirm_published`] on ≥1-relay ack or [`Self::publish_failed`]
    /// on failure.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::Mls`] if the caller is not an admin, if `successor`
    /// holds no member leaf in the group (the engine refuses to mint an admin
    /// who is not a member), or if the engine rejects the commit.
    pub async fn propose_admin_handoff(
        &self,
        mls_group_id: &GroupId,
        successor: &PublicKey,
    ) -> Result<CommitToPublish> {
        let mut admins = self
            .session
            .admin_pubkeys(mls_group_id)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;
        admins.push(successor.to_bytes());
        let effects = self
            .session
            .update_admin_policy(mls_group_id, &admins)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;
        let (commit_event, _welcomes, pending) = self.take_group_evolution(effects).await?;
        Ok(CommitToPublish {
            commit_event,
            pending,
        })
    }

    /// Proposes an admin update of a circle's group relay list (MIP-01) via an
    /// `UpdateAppComponents(nostr-routing.v1)` commit.
    ///
    /// Publish-before-apply (Rule 13): publish [`CommitToPublish::commit_event`]
    /// to the union of the circle's current and new relays, then
    /// [`Self::finalize_relay_update`] on ≥1-relay ack or [`Self::publish_failed`]
    /// on failure. The circle row is updated only on a successful confirm.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::InvalidData`] for an empty / all-invalid /
    /// oversized relay set, or [`CircleError::Mls`] if the caller is not an admin
    /// or the engine rejects the update.
    pub async fn update_circle_relays(
        &self,
        mls_group_id: &GroupId,
        new_relays: &[String],
    ) -> Result<CommitToPublish> {
        let mut canonical: Vec<String> = Vec::with_capacity(new_relays.len());
        for relay in new_relays {
            canonical.push(super::storage_relay_prefs::normalize_url(relay)?);
        }
        canonical.sort();
        canonical.dedup();

        if canonical.is_empty() {
            return Err(CircleError::InvalidData(
                "A circle must have at least one relay".to_string(),
            ));
        }
        if canonical.len() > Self::MAX_CIRCLE_RELAYS {
            return Err(CircleError::InvalidData(format!(
                "A circle may have at most {} relays",
                Self::MAX_CIRCLE_RELAYS
            )));
        }

        // Contamination is recorded for the NEW set even though the circle row
        // is not updated until `finalize_relay_update`: the caller publishes
        // this commit to the UNION of the circle's current and new relays, so
        // every incoming relay sees group traffic regardless of whether the
        // update is later confirmed or rolled back.
        self.record_contaminated(&canonical, ContaminationSource::CircleRouting)?;

        let effects = self
            .session
            .update_relays(mls_group_id, canonical)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;
        let (commit_event, _welcomes, pending) = self.take_group_evolution(effects).await?;
        Ok(CommitToPublish {
            commit_event,
            pending,
        })
    }

    /// Re-derives the app-level `circle.relays` row from the engine's routing
    /// component after a commit. Idempotent; never overwrites a non-empty
    /// `circle.relays` with an empty set (never bricks 445 routing).
    ///
    /// # Errors
    ///
    /// Returns an error if the engine or storage access fails.
    async fn resync_circle_relays_from_mdk(&self, mls_group_id: &GroupId) -> Result<()> {
        let mut engine_relays = self
            .session
            .group_relays(mls_group_id)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;
        engine_relays.sort();
        engine_relays.dedup();

        let Some(mut circle) = self.storage.get_circle(mls_group_id)? else {
            return Ok(());
        };

        if engine_relays.is_empty() {
            return Ok(());
        }

        // The receiving end of an admin's relay update: a non-admin member
        // learns the new routing set from the engine's component rather than
        // from `update_circle_relays`, so this is that member's write site.
        self.record_contaminated(&engine_relays, ContaminationSource::CircleRouting)?;

        let mut current = circle.relays.clone();
        current.sort();
        current.dedup();
        if current != engine_relays {
            circle.relays = engine_relays;
            circle.updated_at = chrono::Utc::now().timestamp();
            self.storage.save_circle(&circle)?;
        }
        Ok(())
    }

    /// Finalizes an admin relay update: confirms the pending commit, then
    /// re-syncs the admin's own `circle.relays` from the engine.
    ///
    /// # Errors
    ///
    /// Returns an error if the confirm fails. A confirm success followed by a
    /// transient re-sync failure is logged (not returned) — the commit is
    /// already applied and the re-sync self-heals idempotently.
    pub async fn finalize_relay_update(
        &self,
        pending: PendingStateRef,
        mls_group_id: &GroupId,
    ) -> Result<DecryptedIngest> {
        let ingest = self.confirm_published(pending).await?;
        if let Err(e) = self.resync_circle_relays_from_mdk(mls_group_id).await {
            log::warn!(
                "finalize_relay_update: relay re-sync failed (will self-heal): {}",
                e.code()
            );
        }
        Ok(ingest)
    }

    /// Step 2 of admin handoff (or the sole step on the `AdminDemote` path):
    /// drop the caller from the admin set via an
    /// `UpdateAppComponents(admin-policy.v1)` commit.
    ///
    /// The engine forbids an admin-less group, so this fails closed when the
    /// caller is the only admin — a sole admin must promote a successor first
    /// (that is exactly what [`LeavePlan::AdminHandoff`] sequences). Failing
    /// here rather than emitting an empty policy is what keeps a circle from
    /// being bricked into a state where nobody can add, remove, or re-key.
    ///
    /// Publish-before-apply (Rule 13): publish [`CommitToPublish::commit_event`],
    /// then [`Self::confirm_published`] on ≥1-relay ack or [`Self::publish_failed`]
    /// on failure.
    ///
    /// [`LeavePlan::AdminHandoff`]: super::leave::LeavePlan::AdminHandoff
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::Mls`] if the caller is not an admin, is the last
    /// admin (no successor was promoted first), or the engine rejects the commit.
    pub async fn propose_self_demote(&self, mls_group_id: &GroupId) -> Result<CommitToPublish> {
        let self_id = self.session.self_id().await;
        let admins: Vec<[u8; 32]> = self
            .session
            .admin_pubkeys(mls_group_id)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?
            .into_iter()
            .filter(|admin| admin.as_slice() != self_id.as_slice())
            .collect();
        if admins.is_empty() {
            return Err(CircleError::Mls(
                "cannot demote the last admin — promote a successor first".to_string(),
            ));
        }
        let effects = self
            .session
            .update_admin_policy(mls_group_id, &admins)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;
        let (commit_event, _welcomes, pending) = self.take_group_evolution(effects).await?;
        Ok(CommitToPublish {
            commit_event,
            pending,
        })
    }

    // ==================== Epoch-rotation repair (C4) ========================

    /// Repairs a circle whose sender ratchets are exhausted, by committing a
    /// byte-identical `UpdateAppComponents(admin-policy.v1)`.
    ///
    /// This is a **ratchet reset**, not key rotation: applying the commit
    /// derives a fresh `encryption_secret`, so every sender ratchet in the group
    /// restarts at generation 0 and a peer whose messages had run past
    /// `maximum_forward_distance` becomes decryptable again. The commit carries
    /// no `UpdatePath`, so it rotates no leaf key and provides **no**
    /// post-compromise security — see [`crate::circle::rotation`].
    ///
    /// Repair-TRIGGERED, never periodic: the caller is the user's "Repair"
    /// action (or the automatic repair behind it), and every gate in
    /// [`rotation_decision`] must be open. `now_secs` is the wall clock in Unix
    /// seconds, injected so the gates are testable without sleeping.
    ///
    /// # Honest limit
    ///
    /// It repairs the ADMIN-stuck case only. A stuck non-admin cannot author any
    /// commit (every commit-producing `SendIntent` is admin-gated) and there is
    /// no "please rekey" message in the protocol, so its remedy is to ask the
    /// circle's owner to remove and re-add it — until MDK exposes a bare
    /// self-update intent (`docs/EPOCH_ROTATION_REPAIR_PLAN.md` §6).
    ///
    /// # Publish-before-apply (Rule 13)
    ///
    /// On [`RepairRotationOutcome::Rotated`] the caller publishes
    /// [`CommitToPublish::commit_event`] to the circle's relays, then calls
    /// [`Self::confirm_published`] on a ≥1-relay OK-ack or
    /// [`Self::publish_failed`] on failure. Nothing is confirmed here. The
    /// 24-hour rate limit is recorded by [`Self::confirm_published`] itself, so
    /// a repair no relay accepted costs the user nothing and can be retried at
    /// once.
    ///
    /// On [`RepairRotationOutcome::Deferred`] the caller runs that SAME ladder
    /// over every [`DeferredWork::commits`] entry: the engine staged that work
    /// during the repair, and leaving it unresolved pins the group in
    /// `PendingPublish`, where every later send fails.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::NotFound`] if no circle row matches, or
    /// [`CircleError::Mls`] if the engine or the message store cannot be read,
    /// or rejects the commit for a reason other than a non-`Stable` epoch state
    /// (which is a [`SkipReason::EpochNotStable`] skip, not a failure).
    pub async fn repair_epoch_rotation(
        &self,
        mls_group_id: &GroupId,
        now_secs: u64,
    ) -> Result<RepairRotationOutcome> {
        // Storage errors reach the FFI boundary as prose, and a rusqlite message
        // can quote the failing statement — which on these two tables carries
        // the circle's `nostr_group_id` as hex. Every other fallible call in
        // this function is redacted; these two were the gap.
        let circle = self
            .storage
            .get_circle(mls_group_id)
            .map_err(|e| redact_storage_error(&e))?
            .ok_or_else(|| CircleError::NotFound("Circle not found: <redacted>".to_string()))?;

        let self_id = self.session.self_id().await;
        let admins = self
            .session
            .admin_pubkeys(mls_group_id)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;
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
            self_id: self_id.as_slice(),
            admins: &admins,
            // The only non-`Stable` state this device can observe BEFORE
            // attempting the send; `PendingPublish` / `Merging` / `Recovering`
            // have no getter at MDK `e391adc` and arrive as the typed rejection
            // below instead.
            group_is_unrecoverable: self.unrecoverable_group_ids().contains(mls_group_id),
            last_epoch_change_at: secs_from_ms(rotation_state.last_epoch_change_seen_at_ms),
            last_rotation_at: secs_from_ms(rotation_state.last_rotation_at_ms),
            last_inbound_event_at: secs_from_ms(rotation_state.last_inbound_event_at_ms),
            pending_proposal,
            now: now_secs,
        });
        if let RotationDecision::Skip(reason) = decision {
            return Ok(RepairRotationOutcome::Skipped(reason));
        }

        // The send gate, checked BEFORE the intent exists. `do_send` does not
        // reject a send it cannot perform — it QUEUES it, durably, and the queue
        // drains later into a real commit with none of the gates above
        // re-evaluated and no rate limit charged. Queued intent ids are not
        // deduplicated either, so without this every Repair tap on a stalled
        // circle would bank another epoch bump, all landing in a burst the
        // moment the circle unblocks. Asking the gate first means the intent is
        // never issued at all.
        if self.gating_input_count(mls_group_id).await > 0 {
            let report = self
                .repair_deferred_send(mls_group_id, Vec::new(), now_secs)
                .await;
            return Ok(RepairRotationOutcome::Deferred {
                unresolved_inputs: report.unresolved_inputs,
                discarded_intents: report.discarded_intents,
                repaired: report.repaired,
                work: report.work,
            });
        }

        // Byte-identical: the admin set the engine just reported, re-encoded.
        // `admin_changes(before, after)` therefore yields nothing, so the commit
        // emits no `GroupStateChange` and no member sees a phantom "admins
        // changed" row.
        let effects = match self
            .session
            .update_admin_policy(mls_group_id, &admins)
            .await
        {
            Ok(effects) => effects,
            Err(crate::nostr::NostrError::EpochNotStable) => {
                return Ok(RepairRotationOutcome::Skipped(SkipReason::EpochNotStable));
            }
            Err(crate::nostr::NostrError::EpochUnrecoverable) => {
                return Ok(RepairRotationOutcome::Skipped(
                    SkipReason::EpochUnrecoverable,
                ));
            }
            Err(e) => return Err(CircleError::Mls(redact_hex_sequences(&e.to_string()))),
        };

        // Gate 7, checked BEFORE `take_group_evolution` — which would otherwise
        // report a queued rotation as "produced no GroupEvolution publish work",
        // the same opaque error `encrypt_location` used to hand back. The
        // pre-check above models what it can; this stays as the fail-safe for
        // what it cannot (a non-`Stable` state the engine reports by queueing,
        // and `stage_due_self_remove_auto_commit` staging an eviction inside
        // this very call).
        if !effects.queued.is_empty() {
            // The intent is already banked at this point, so it must be taken
            // back out — see
            // [`SessionManager::discard_queued_repair_rotation_intents`].
            let discarded = self
                .discard_queued_repair_rotation(mls_group_id, &admins)
                .await;
            let report = self
                .repair_deferred_send(mls_group_id, effects.publish, now_secs)
                .await;
            log::warn!(
                "epoch-rotation repair deferred: {} input(s) still gating, \
                 {} queued rotation(s) taken back, {} staged commit(s) handed back",
                bucket(report.unresolved_inputs),
                bucket(discarded),
                bucket(report.work.commits.len())
            );
            return Ok(RepairRotationOutcome::Deferred {
                unresolved_inputs: report.unresolved_inputs,
                discarded_intents: report.discarded_intents,
                repaired: report.repaired,
                work: report.work,
            });
        }

        let (commit_event, pending) = self.take_rotation_commit(effects).await?;
        self.register_rotation_pending(pending, circle.nostr_group_id);
        Ok(RepairRotationOutcome::Rotated(CommitToPublish {
            commit_event,
            pending,
        }))
    }

    /// Extracts the staged rotation commit, rolling the engine's staged state
    /// back if the transport message cannot be turned into an event.
    ///
    /// A staged commit whose message will not serialize must be rolled back,
    /// never dropped: an unresolved `PendingStateRef` pins the group in
    /// `PendingPublish`, where every later send fails the engine's "requires
    /// Stable" gate — a total, permanent send blackout bought for a
    /// serialization error. Same disposition [`Self::collect_deferred_work`]
    /// uses on the same failure.
    ///
    /// # Errors
    ///
    /// Returns whatever [`take_group_evolution`] rejected, after the rollback.
    async fn take_rotation_commit(
        &self,
        effects: SessionEffects,
    ) -> Result<(Event, PendingStateRef)> {
        // Read the pending ref BEFORE `take_group_evolution` consumes the
        // effects, so a failure inside it still has something to roll back.
        let staged_pending = effects.publish.iter().find_map(|work| match work {
            PublishWork::GroupEvolution { pending, .. } => Some(*pending),
            _ => None,
        });
        match self.take_group_evolution(effects).await {
            Ok((commit_event, _welcomes, pending)) => Ok((commit_event, pending)),
            Err(e) => {
                if let Some(pending) = staged_pending {
                    // Discarded like the create rollback above: the rotation was
                    // staged in the call that just failed, and this function's
                    // contract is an error, not an ingest.
                    let _ = self.publish_failed(pending).await;
                }
                Err(e)
            }
        }
    }

    /// Takes a queued repair rotation back out of the engine's outbound queue,
    /// or `0` if the store cannot be written.
    ///
    /// Best-effort for the same reason every other step of a deferral is: the
    /// outcome must stay an actionable "sharing is stalled" signal. A discard
    /// that fails leaves ONE banked rotation, which the next drain turns into a
    /// single extra epoch bump — noisy, but not a burst, and the log line says
    /// so.
    async fn discard_queued_repair_rotation(
        &self,
        mls_group_id: &GroupId,
        current_admins: &[[u8; 32]],
    ) -> usize {
        self.session
            .discard_queued_repair_rotation_intents(mls_group_id, current_admins)
            .await
            .unwrap_or_else(|e| {
                log::warn!(
                    "epoch-rotation repair: taking the queued rotation back failed; one \
                     extra epoch bump may land when the circle unblocks: {}",
                    e.code()
                );
                0
            })
    }

    /// Binds a staged repair rotation to the circle whose rate limit it spends,
    /// so [`Self::confirm_published`] can record it without the caller having to
    /// remember to.
    ///
    /// Folded into the confirm rather than exposed as a separate
    /// `note_rotation_confirmed` FFI call for a safety reason, not a size one: a
    /// caller that forgot the extra call would leave the circle with no rate
    /// limit at all, and the failure would be silent. The map is in memory
    /// because the binding only has to outlive the publish attempt — a process
    /// death before the confirm leaves the commit unapplied, which is exactly
    /// the state a missing rate-limit record describes.
    fn register_rotation_pending(&self, pending: PendingStateRef, nostr_group_id: [u8; 32]) {
        self.rotation_pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(pending, nostr_group_id);
    }

    /// Removes and returns the circle bound to `pending` in the rotation map.
    fn take_rotation_pending(&self, pending: PendingStateRef) -> Option<[u8; 32]> {
        self.rotation_pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&pending)
    }

    /// Final step of every non-abandoning leave: returns a `SelfRemove` proposal
    /// event so peers can advance past the caller.
    ///
    /// A bare proposal has no `PendingStateRef` — a remaining member commits it
    /// later (RFC 9420 §12.1.2). The caller publishes the returned event, then
    /// calls [`Self::complete_leave`]; there is nothing to confirm.
    ///
    /// # Errors
    ///
    /// Returns an error if the engine rejects the leave (e.g. the caller is
    /// still an admin — `AdminCannotSelfRemove`).
    pub async fn propose_leave(&self, mls_group_id: &GroupId) -> Result<Event> {
        // Through the boundary conversion, not a flattening closure: it is what
        // keeps `AdminSelfDemoteRequired` a typed variant, so the caller sees the
        // self-demote remediation on `Display` instead of a bare "MLS error".
        let effects = self
            .session
            .leave_group(mls_group_id)
            .await
            .map_err(CircleError::from)?;
        let event = self.take_proposal(effects).await?;
        // Recorded only once the engine has accepted the departure, and durably,
        // because a peer may commit this `SelfRemove` before the local teardown
        // runs — possibly in another process. From that commit onward the
        // engine's `Group.removed` says only "you are out", never "who decided",
        // so this marker is the whole difference between ageing this circle's
        // co-members out over three days (R5) and deleting them as if someone
        // had cut the user off (D3). Best-effort: a leave must not fail because
        // the picker's index could not be annotated.
        if let Err(e) = self.storage.mark_leave_intent(mls_group_id) {
            log::warn!(
                "leave-intent marker not recorded; this circle's co-members may be \
                 dropped from the directory instead of ageing out: {}",
                e.code()
            );
        }
        Ok(event)
    }

    /// Finalizes a leave by removing the local circle row.
    ///
    /// The Dark Matter engine has no per-group delete: leaving is a `SelfRemove`
    /// (via [`Self::propose_leave`]) after which the engine marks its local copy
    /// `removed` (retained inactive, spec `member-departure.md`). Haven removes
    /// its own circle row here. Safe for the `OrphanLocalOnly` plan.
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
    /// Returns an error if the circle-row deletion fails. The directory refresh
    /// is best-effort and never fails the leave.
    pub async fn complete_leave(&self, mls_group_id: &GroupId, now_unix_secs: i64) -> Result<()> {
        // The in-memory half of an owed removal publish has to go with the row
        // `delete_circle` cascades away. The `nostr_group_id` is only resolvable
        // while the circle row still exists, so it is read FIRST; an entry left
        // behind would pin an `Event` and a dead engine ref to a circle that no
        // longer exists, and would answer `orphaned_removal_deferrals` for a
        // durable row that is already gone.
        let ngid = self
            .storage
            .get_circle(mls_group_id)
            .ok()
            .flatten()
            .map(|circle| circle.nostr_group_id);
        let _existed = self.storage.delete_circle(mls_group_id)?;
        if let Some(ngid) = ngid {
            self.forget_removal_deferral_in_memory(&ngid);
        }
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

    // ==================== Publish-before-apply (Rule 13) ====================

    /// Confirms a staged commit was published (≥1-relay OK-ack) so the engine
    /// applies it and advances the epoch.
    ///
    /// "Acked" MUST mean a relay returned OK — never merely "sent" — to avoid
    /// optimistic-merge forks (Rule 13, security F13).
    ///
    /// # What it hands back, and why it cannot be `()`
    ///
    /// The engine ends `do_confirm_published` in `replay_buffered_messages`,
    /// which re-ingests everything that arrived while the commit was staged —
    /// peer locations, peer commits, a re-proposed leave. Every one of those is
    /// delivered AT MOST ONCE. Locations are persisted before this returns; the
    /// rest comes back in the [`DecryptedIngest`] for the caller to route and
    /// publish.
    ///
    /// # Errors
    ///
    /// Returns an error if the pending ref is unknown or the engine rejects it.
    /// The error is returned UNCHANGED even though a batch may have been
    /// recovered from it: a confirm that failed after the durable merge must
    /// never be retried and must never be turned into a `publish_failed`.
    pub async fn confirm_published(&self, pending: PendingStateRef) -> Result<DecryptedIngest> {
        let result = self
            .session
            .confirm_published(pending)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())));
        // A confirmed create KEEPS its eagerly-persisted rows; just drop the
        // rollback binding so a subsequent stray `publish_failed` can never
        // delete a now-live circle (F2). A no-op for every non-create pending.
        // Taken BEFORE the early return: on a rejected confirm the binding is
        // dead either way, and leaving it in the map keeps a ref nothing will
        // ever resolve. Bounded and memory-only, but a map that only grows is
        // not a shape to leave in a long-lived session.
        let rotation = self.take_rotation_pending(pending);
        let effects = match result {
            Ok(effects) => effects,
            Err(e) => {
                // The engine aborted mid-replay: `cgka-session` propagates the
                // `?` BEFORE `collect_effects`, so nothing came back with the
                // error while everything already emitted sits in the engine's
                // buffers with its durable row written. Fold that, then return
                // the ORIGINAL error — the merge may already have happened, so
                // a retry would apply the commit twice and a `publish_failed`
                // would discard a commit the group has.
                let stranded = self.session.drain().await;
                if !stranded.is_empty() {
                    // The fold's own products are dropped on purpose: there is
                    // no caller to hand them to on an error return, and every
                    // auto-commit it surfaced is already PARKED with its
                    // obligation recorded, so the next foreground redemption
                    // pass picks it up. The locations, which cannot be
                    // re-delivered, are persisted by the fold itself.
                    let _ = self
                        .fold_resolved_publish(stranded, BatchOrigin::Drained)
                        .await;
                    log::warn!(
                        "a failed publish resolution stranded engine work; it was folded \
                         and the failure stands"
                    );
                }
                return Err(e);
            }
        };
        // An APPLIED commit is the obligation discharged. Every plane records a
        // removal-bearing auto-commit before it publishes, so without this each
        // peer-leave would leave a durable row behind and the next foreground
        // open would report a perfectly healthy circle unrecoverable. What
        // carries the safety is the SCOPE, not the position: matching on the
        // REF clears this commit's obligation and never the second-generation
        // one the fold below may record for the same circle (the map holds one
        // entry per circle, and recording overwrites it). Only on success: a
        // rejected confirm leaves the commit exactly as staged as it was, and
        // the obligation with it.
        self.discharge_owed_removal_publish(pending);
        let _ = self.take_create_pending(pending);
        // A repair rotation spends its circle's 24-hour rate limit HERE, not
        // when it was staged: a commit no relay accepted reset nobody's ratchet,
        // and charging the user for it would leave a stuck circle unrepairable
        // for a day.
        if let Some(nostr_group_id) = rotation {
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
        // Confirming is the first moment an announced membership is APPLIED
        // rather than projected, so it is a directory write site. Read BEFORE
        // the fold: it carries `note_epoch_changes`, which belongs to the
        // top-level batch alone.
        let mode = self.publish_outcome_verdict(&effects.events);
        let (ingest, drained) = self
            .fold_resolved_publish(effects, BatchOrigin::TopLevel)
            .await;
        // ONE reconcile, after everything the drain could add to the verdict.
        let mode = drained.map_or(mode, |drained| mode.max(drained));
        self.reconcile_member_directory_best_effort(mode).await;
        Ok(ingest)
    }

    /// Reports that a staged publish failed; the engine discards the staged
    /// commit and returns the group to `Stable` at the prior epoch.
    ///
    /// # The one commit it will NOT discard
    ///
    /// A removal-bearing receive-side auto-commit — a peer's `SelfRemove`
    /// eviction — is never rolled back, from any plane. At MDK `e391adc` that
    /// rollback is a PERMANENT SILENT DROP of the removal, so the leaver would
    /// stay in the circle and keep deriving its keys
    /// ([`Self::owe_removal_publish`] carries the mechanism). Every plane that
    /// takes one records the obligation first, and this is the ONE place that
    /// decides what an unacked publish means — so the guarantee covers the
    /// in-Rust receive planes, the Dart planes that call this over the FFI, and
    /// a plane written after this comment, instead of resting on three call
    /// sites agreeing. Such a commit stays STAGED and owed:
    /// [`Self::redeem_removal_deferrals`] retries it, a successful send
    /// discharges it ([`Self::discharge_removal_deferral_after_send`]), and a
    /// session that dies still owing one reports the circle
    /// ([`Self::orphaned_removal_deferrals`]).
    ///
    /// # What it hands back
    ///
    /// The same [`DecryptedIngest`] [`Self::confirm_published`] returns, and for
    /// the same reason: `do_publish_failed` also ends in
    /// `replay_buffered_messages`. It replays at the ORIGINAL epoch, which is
    /// what makes this the rung where a peer's buffered `SelfRemove` proposal is
    /// still applicable and reaches its auto-commit. The kept-owed early return
    /// above hands back an EMPTY ingest: no engine call was made, so there is
    /// honestly no batch.
    ///
    /// # Errors
    ///
    /// Returns an error if the pending ref is unknown.
    pub async fn publish_failed(&self, pending: PendingStateRef) -> Result<DecryptedIngest> {
        if self.keeps_its_removal_publish_owed(pending) {
            return Ok(DecryptedIngest::default());
        }
        let result = self
            .session
            .publish_failed(pending)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())));
        // F2: a rolled-back create must not strand a ghost circle row. Delete the
        // eagerly-persisted rows ONLY on a SUCCESSFUL rollback (the engine
        // actually discarded the staged create); an unknown / already-resolved
        // pending — e.g. one already confirmed — leaves storage untouched. A
        // no-op for every non-create pending (auto-commit / evolution).
        // A rolled-back rotation spent nothing: drop the binding without
        // recording it, so the user can retry the repair immediately. Taken
        // before the early return for the same reason as in
        // `confirm_published` — a rejected rollback leaves the ref just as dead.
        let _ = self.take_rotation_pending(pending);
        let effects = match result {
            Ok(effects) => effects,
            Err(e) => {
                // Same stranded-buffer recovery as `confirm_published` — see
                // there for why the original error is returned unchanged.
                let stranded = self.session.drain().await;
                if !stranded.is_empty() {
                    let _ = self
                        .fold_resolved_publish(stranded, BatchOrigin::Drained)
                        .await;
                    log::warn!(
                        "a failed publish resolution stranded engine work; it was folded \
                         and the failure stands"
                    );
                }
                return Err(e);
            }
        };
        if let Some(group_id) = self.take_create_pending(pending) {
            if let Err(e) = self.storage.delete_circle(&group_id) {
                log::warn!(
                    "create rollback: circle-row cleanup failed (self-heals on logout wipe): {}",
                    e.code()
                );
            }
        }
        // Restores anyone [`Self::remove_members`] optimistically deleted for the
        // commit that was just discarded.
        let mode = self.publish_outcome_verdict(&effects.events);
        let (ingest, drained) = self
            .fold_resolved_publish(effects, BatchOrigin::TopLevel)
            .await;
        let mode = drained.map_or(mode, |drained| mode.max(drained));
        self.reconcile_member_directory_best_effort(mode).await;
        Ok(ingest)
    }

    /// Folds a resolved publish's engine batch — and everything draining it
    /// releases — into the work its caller has to do.
    ///
    /// Iterative over an explicit worklist rather than recursive: a recursive
    /// `async fn` would need boxing, and the generation bound would be a
    /// call-stack depth rather than a number anyone can read.
    ///
    /// What each pass does, in this order: PERSIST the batch's locations (first,
    /// because nothing after it may fail before the durable write), fold the
    /// events into results, record the inbound observation the origin allows
    /// (R2), accumulate the directory verdict, and dispose of the publish work.
    /// Then the groups the batch left pending are advanced, and what comes back
    /// goes on the worklist as a DRAINED batch.
    ///
    /// The re-tick budget is ONE per call — not per batch and not per
    /// generation — and a batch with nothing pending sleeps not at all. The
    /// engine's `SelfRemove` auto-commit due time is a real `Instant`, so the
    /// delay has to be real time; capping it per call is what stops a cascade
    /// of leaves from multiplying it.
    ///
    /// # Rule 15, for every diagnostic in this function and in the resolve
    /// ladder it feeds
    ///
    /// NEVER add a `log_alias` circle handle to these lines. Each is a
    /// per-circle ACTIVITY signal the moment one is attached — "circle#a91f3c
    /// had a peer location replayed" and "circle#a91f3c re-ticked six times"
    /// say that a peer just moved and that a peer just left, which is exactly
    /// what a handle is supposed to make unsayable. Magnitudes stay bucketed
    /// and instants stay absent for the same reason. A later "just add the
    /// circle for debuggability" is a review stop, not a judgement call.
    async fn fold_resolved_publish(
        &self,
        seed: SessionEffects,
        origin: BatchOrigin,
    ) -> (DecryptedIngest, Option<DirectoryReconcile>) {
        let mut worklist: std::collections::VecDeque<(SessionEffects, BatchOrigin)> =
            std::collections::VecDeque::new();
        worklist.push_back((seed, origin));
        let mut convergence: Vec<GroupId> = Vec::new();
        // No `PendingStateRef` is resolved twice in one call: a ref rolled back
        // in one generation must never be rolled back again in the next.
        let mut resolved: HashSet<PendingStateRef> = HashSet::new();
        let mut out = DecryptedIngest::default();
        let mut verdict: Option<DirectoryReconcile> = None;
        let mut ticks_left = crate::relay::auto_commit::MAX_CONVERGENCE_RETICKS;
        let mut batches = 0_usize;
        // Whether a re-advance has already run in this call.
        let mut advanced = false;
        let mut capped = false;

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
                // `resolved` will not hand out twice, and each engine cycle
                // consumes one scheduled `SelfRemove` — of which there is at
                // most one per member per epoch, and `publish_failed` does not
                // re-arm it.
                if batches > MAX_FOLD_BATCHES {
                    capped = true;
                }

                out.results
                    .extend(self.persist_and_fold(&effects.events).await);
                match origin {
                    BatchOrigin::TopLevel => {
                        self.note_inbound_arrival_for_message_received(&effects.events);
                    }
                    BatchOrigin::Drained => self.note_inbound_group_events(&effects.events),
                }
                verdict = verdict.max(self.directory_verdict_for_events(&effects.events));

                for item in effects.publish {
                    if let Some(more) = self
                        .dispose_publish_work(item, origin, &mut out, &mut resolved)
                        .await
                    {
                        worklist.push_back((more, BatchOrigin::Drained));
                    }
                }

                for group_id in effects.pending_convergence {
                    if !convergence.contains(&group_id) {
                        convergence.push(group_id);
                    }
                }
            }

            if capped || convergence.is_empty() || ticks_left == 0 {
                break;
            }
            // A group that is STILL pending after the round that advanced it is
            // waiting on the engine's jitter-delayed auto-commit due time, which
            // reads a real `Instant`. Re-advancing it without waiting would spin
            // the CPU through the whole jitter window, so the delay is paid here
            // — once per re-advance, never before the first one (a commit whose
            // time has come surfaces with no delay at all) and never when
            // nothing pends.
            if advanced {
                ticks_left -= 1;
                self.convergence_reticks
                    .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                tokio::time::sleep(crate::relay::auto_commit::CONVERGENCE_RETICK_DELAY).await;
            }
            advanced = true;
            for group_id in std::mem::take(&mut convergence) {
                match self.session.advance_convergence(&group_id).await {
                    Ok(more) => worklist.push_back((more, BatchOrigin::Drained)),
                    // Re-added rather than dropped: the group still owes an
                    // advance, and the next tick retries it.
                    Err(e) => {
                        log::warn!(
                            "publish resolution: advancing convergence failed: {}",
                            e.code()
                        );
                        convergence.push(group_id);
                    }
                }
            }
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
        } else if ticks_left < crate::relay::auto_commit::MAX_CONVERGENCE_RETICKS {
            log::debug!(
                "publish resolution drained convergence after {} re-tick(s)",
                bucket(crate::relay::auto_commit::MAX_CONVERGENCE_RETICKS - ticks_left)
            );
        }
        (out, verdict)
    }

    /// One [`PublishWork`] item's disposition inside the fold, returning any
    /// batch a rollback produced for the caller's worklist.
    ///
    /// `resolved` is the call's set of pending refs already dealt with. A ref
    /// cannot legitimately be handed out twice by one engine — the buffers are
    /// one-shot drains — so a repeat is a bug, and resolving it again would
    /// either roll back a commit the first pass surfaced or surface a commit the
    /// first pass rolled back.
    #[deny(clippy::wildcard_enum_match_arm)]
    async fn dispose_publish_work(
        &self,
        item: PublishWork,
        origin: BatchOrigin,
        out: &mut DecryptedIngest,
        resolved: &mut HashSet<PendingStateRef>,
    ) -> Option<SessionEffects> {
        if let Some(pending) = pending_ref_of(&item) {
            if !resolved.insert(pending) {
                log::warn!("publish resolution saw a pending ref twice; the repeat is ignored");
                return None;
            }
        }
        match item {
            PublishWork::AutoPublish { msg, pending } => {
                self.surface_auto_commit(&msg, pending, &mut out.auto_commits)
                    .await
            }
            // A released queued intent, whose durable row the engine has
            // already deleted — rolling it back would destroy it. Only a
            // DRAINED batch can carry one; at top level `collect_effects` is
            // called with no send results, so this is unreachable there and
            // fails closed with everything else that cannot happen.
            PublishWork::GroupEvolution {
                msg,
                welcomes,
                pending,
            } if origin == BatchOrigin::Drained => {
                if !welcomes.is_empty() {
                    // O3: `CommitToPublish` carries no welcomes, so they are not
                    // published here. Pre-existing, and said out loud rather
                    // than becoming silent.
                    log::warn!("a drained commit carried welcome(s) that are not published here");
                }
                match SessionManager::transport_message_to_event(&msg) {
                    Ok(commit_event) => {
                        out.auto_commits.push(CommitToPublish {
                            commit_event,
                            pending,
                        });
                        None
                    }
                    Err(_) => self.rollback_unfolded(pending).await,
                }
            }
            PublishWork::GroupEvolution { pending, .. }
            | PublishWork::GroupCreated { pending, .. } => self.rollback_unfolded(pending).await,
            // The local user's own re-proposed leave (a peer commit landing
            // while a leave request stands re-mints it for the accepted epoch).
            // Dropping it wedges the leave behind the engine's send gate.
            PublishWork::Proposal { msg } => {
                match SessionManager::transport_message_to_event(&msg) {
                    Ok(event) => out.proposals.push(event),
                    Err(e) => log::warn!(
                        "publish resolution: dropping an unserializable proposal: {}",
                        e.code()
                    ),
                }
                None
            }
            // Argued drop: a location intent released by the drain is superseded
            // by the fresher fix the next cadence tick sends, and publishing a
            // stale one would put an out-of-date pin on every peer's map.
            PublishWork::ApplicationMessage { .. } => {
                log::debug!(
                    "publish resolution observed an application message it does not publish"
                );
                None
            }
        }
    }

    /// Rolls a staged commit back WITHOUT folding its own batch, handing that
    /// batch to the caller instead.
    ///
    /// NEVER promote this to [`Self::publish_failed`]. `remove_members` reaches
    /// this line while holding `directory_lock` — a non-reentrant tokio mutex —
    /// through `take_group_evolution` → `surface_co_drained_auto_commits` →
    /// `surface_auto_commit`, and `publish_failed` ends in a directory
    /// reconcile that takes the same lock. The deadlock would be silent and
    /// would look like a hung Remove Member.
    ///
    /// The owed-guard is kept: a removal-bearing commit this device owes a
    /// publish for is never discarded, from here any more than from
    /// [`Self::publish_failed`]. Unreachable for such a ref today (the
    /// serialization that would send us here fails before the obligation is
    /// recorded), and the guard stays anyway so a later reordering cannot turn
    /// this into a silent removal drop.
    async fn rollback_unfolded(&self, pending: PendingStateRef) -> Option<SessionEffects> {
        if self.keeps_its_removal_publish_owed(pending) {
            return None;
        }
        self.session.publish_failed(pending).await.ok()
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
    /// in `replay_buffered_messages` (`cgka-engine/src/publish.rs:255`), which
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

    /// Adds members to a circle, returning the engine [`SessionEffects`]
    /// (a `GroupEvolution` with the commit + welcomes + `PendingStateRef`).
    ///
    /// # Errors
    ///
    /// Returns an error if adding members fails.
    pub async fn add_members(
        &self,
        mls_group_id: &GroupId,
        key_packages: &[Event],
    ) -> Result<SessionEffects> {
        if let Some(mut circle) = self.storage.get_circle(mls_group_id)? {
            circle.updated_at = chrono::Utc::now().timestamp();
            self.storage.save_circle(&circle)?;
        }

        let kps = parse_key_packages(key_packages)?;
        self.session
            .add_members(mls_group_id, kps)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))
    }

    /// Adds members to an existing circle and routes their gift-wrapped Welcomes.
    ///
    /// Publish-before-apply (Rule 13): publish
    /// [`AddMembersResult::commit_event`] to the circle's relays, confirm via
    /// [`Self::confirm_published`] on ≥1-relay ack (or [`Self::publish_failed`]
    /// on failure), and only after a successful confirm publish each
    /// [`AddMembersResult::welcome_events`] entry.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::MissingWelcomeRelays`] (checked before staging) or
    /// [`CircleError::Mls`] if staging or the admin gate rejects.
    pub async fn add_members_with_welcomes(
        &self,
        _sender_keys: &Keys,
        mls_group_id: &GroupId,
        members: Vec<MemberKeyPackage>,
        creator_fallback_relays: &[String],
    ) -> Result<AddMembersResult> {
        if creator_fallback_relays.is_empty() {
            for m in &members {
                if m.inbox_relays.is_empty() && m.nip65_relays.is_empty() {
                    return Err(CircleError::MissingWelcomeRelays);
                }
            }
        }

        let key_package_events: Vec<Event> = members
            .iter()
            .map(|m| m.key_package_event.clone())
            .collect();

        let effects = self.add_members(mls_group_id, &key_package_events).await?;
        let (commit_event, welcomes, pending) = self.take_group_evolution(effects).await?;
        let welcome_events =
            self.route_welcomes_with_cascade(&members, welcomes, creator_fallback_relays)?;

        Ok(AddMembersResult {
            commit_event,
            welcome_events,
            pending,
        })
    }

    /// Removes members from a circle, returning the commit + pending ref.
    ///
    /// Publish-before-apply (Rule 13).
    ///
    /// # Errors
    ///
    /// Returns an error if removing members fails (e.g. `NotGroupAdmin`).
    pub async fn remove_members(
        &self,
        mls_group_id: &GroupId,
        member_pubkeys: &[String],
    ) -> Result<CommitToPublish> {
        // Held across the stage AND the directory delete, so no concurrent
        // reconcile can sit between them: a walk that read this circle's roster
        // a moment ago would otherwise re-insert the person this method just
        // removed, and a union rewrite demotes rather than deletes, so they
        // would return as a three-day "recent contact" instead of being gone.
        let _directory = self.directory_lock.lock().await;

        if let Some(mut circle) = self.storage.get_circle(mls_group_id)? {
            circle.updated_at = chrono::Utc::now().timestamp();
            self.storage.save_circle(&circle)?;
        }

        let effects = self
            .session
            .remove_members(mls_group_id, member_pubkeys)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;
        let (commit_event, _welcomes, pending) = self.take_group_evolution(effects).await?;

        // Owner decision D3, the "you remove them" direction: the row goes at
        // STAGING time, deliberately not waiting for a relay ack. Erring toward
        // deleting a row a rollback would restore costs a convenience —
        // `publish_failed` reconciles and puts it back; erring the other way
        // leaves someone the user just removed one tap from receiving live
        // location. Gated on the engine having accepted the removal, because a
        // rejected one (`NotGroupAdmin`) removed nobody.
        for pubkey_hex in member_pubkeys {
            if let Err(e) = self.storage.delete_directory_member(pubkey_hex) {
                log::warn!(
                    "member directory: removal row not deleted (the next reconcile \
                     demotes it instead of deleting it): {}",
                    e.code()
                );
            }
        }

        Ok(CommitToPublish {
            commit_event,
            pending,
        })
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
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;

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
    ///   removal there could ever be observed. Also un-healable in-session:
    ///   the state's only legal exit has no caller at the pinned rev.
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

        // Read once: both sets are fixed for the life of the session, so a
        // per-circle query would buy a lock acquisition per circle for an answer
        // that cannot change between them.
        let quarantined: HashSet<GroupId> = self
            .session
            .quarantined_group_ids()
            .await
            .into_iter()
            .collect();
        let unrecoverable = self.unrecoverable_group_ids();

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
            if quarantined.contains(group_id) || unrecoverable.contains(group_id) {
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
                Err(e) => return Err(CircleError::Mls(redact_hex_sequences(&e.to_string()))),
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

    /// The directory verdict for a folded receive batch, recording any group the
    /// engine reported unrecoverable on the way through.
    ///
    /// A method rather than a bare call to
    /// [`DirectoryReconcile::for_receive_results`] because the recording is the
    /// only signal Haven gets: `EpochState` has no accessor and is never
    /// persisted, so `Unrecoverable` is observable exactly once, as the event
    /// that announces it.
    pub(crate) fn directory_verdict_for_results(
        &self,
        results: &[LocationMessageResult],
    ) -> Option<DirectoryReconcile> {
        self.note_unrecoverable(results.iter().filter_map(|result| match result {
            LocationMessageResult::Unrecoverable { group_id } => Some(group_id.clone()),
            _ => None,
        }));
        DirectoryReconcile::for_receive_results(results)
    }

    /// [`Self::directory_verdict_for_results`] over a raw engine event batch,
    /// for the receive planes that hold `GroupEvent`s rather than folded
    /// results.
    ///
    /// Records nothing but the unrecoverable set. The epoch-change and
    /// inbound-observation facts have exactly ONE write site per path — the
    /// receive planes call [`Self::note_inbound_group_events`], the
    /// publish-before-apply resolution calls [`Self::note_epoch_changes`] — so
    /// that a plane doing both cannot record the same fact twice.
    pub(crate) fn directory_verdict_for_events(
        &self,
        events: &[GroupEvent],
    ) -> Option<DirectoryReconcile> {
        self.note_unrecoverable(events.iter().filter_map(|event| match event {
            GroupEvent::GroupUnrecoverable { group_id } => Some(group_id.clone()),
            _ => None,
        }));
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
                    // An epoch move discharges an ORPHANED obligation, and
                    // only an orphaned one. Whatever moved the epoch merged some
                    // commit, and a merge empties the proposal store — so the
                    // leaver's `SelfRemove` is gone and a row this session
                    // cannot redeem is evidence of nothing; leaving it would
                    // report a circle that has moved on as unrecoverable. A row
                    // this session CAN still redeem is the opposite case: the
                    // commit is staged and the publish is still owed, and
                    // dropping the in-memory entry would destroy the obligation
                    // with the commit still staged — a silent drop by another
                    // route.
                    //
                    // What does NOT arrive here is the case this used to claim:
                    // a remaining peer's own commit of the SAME `SelfRemove`
                    // emits no `EpochChanged` at all (the group record's epoch
                    // was already projected forward when our commit was staged,
                    // so applying theirs reports `Processed` with an empty event
                    // batch), which is exactly why
                    // [`Self::discharge_removal_deferral_after_send`] exists.
                    // What does arrive is an UNRELATED peer commit landing after
                    // an orphaned park — and this device's own confirm, which
                    // DOES fold through here (`confirm_published` →
                    // `publish_outcome_verdict`, and the engine returns
                    // `EpochChanged` for every group-evolution confirm). That is
                    // harmless rather than redundant-by-luck: the confirm has
                    // already called [`Self::discharge_owed_removal_publish`] for
                    // its own ref, so either this circle owed nothing (a no-op
                    // DELETE) or it still owes a DIFFERENT, superseded ref, which
                    // is redeemable and must survive — the same answer this arm
                    // gives every other caller.
                    self.clear_orphaned_removal_deferral(&circle.nostr_group_id);
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

    /// Adds `group_ids` to the session's unrecoverable set — see
    /// [`Self::unrecoverable_groups`].
    fn note_unrecoverable(&self, group_ids: impl IntoIterator<Item = GroupId>) {
        self.unrecoverable_groups
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .extend(group_ids);
    }

    /// The groups the engine has reported `Unrecoverable` during this session.
    fn unrecoverable_group_ids(&self) -> HashSet<GroupId> {
        self.unrecoverable_groups
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }

    /// Those same groups as pseudonymous `nostr_group_id`s (Security Rule 4) —
    /// the ONLY way to observe the engine's terminal verdict more than once.
    ///
    /// The engine announces `Unrecoverable` for a group EXACTLY ONCE per
    /// session: `mark_unrecoverable` latches the state, and every later
    /// convergence run short-circuits on `is_unrecoverable` before the arm that
    /// pushes `GroupUnrecoverable` (`cgka-engine/src/distributed_convergence.rs`
    /// lines 238 and 401 at rev `e391adc`). `EpochState` has no accessor, so a
    /// consumer that needs a second observation before it acts — as the wedge
    /// report does, because telling a user to rebuild a working circle costs
    /// them every invitation in it — cannot get one from the engine. It comes
    /// from here.
    ///
    /// A group whose circle row is gone is dropped: the verdict names a circle
    /// the consumer can act on, or it names nothing.
    #[must_use]
    pub fn unrecoverable_circles(&self) -> Vec<[u8; 32]> {
        self.unrecoverable_group_ids()
            .iter()
            .filter_map(|group_id| self.storage.get_circle(group_id).ok().flatten())
            .map(|circle| circle.nostr_group_id)
            .collect()
    }

    // ===== Owed removal publishes (OD4-c options (i) and (iv)) =====

    /// Parks a departing peer's eviction commit unpublished, because it surfaced
    /// inside a BACKGROUND burst (owner decision OD4-c, option (iv)).
    ///
    /// [`Self::owe_removal_publish`] plus the decision NOT to publish at all: a
    /// burst must not open a publish-before-apply window inside a wake window
    /// the OS may end, and a removal-bearing staged commit killed in that window
    /// is the ONE thing MDK's hydrate deliberately does not recover
    /// (`cgka-engine/src/engine.rs:820-828` at rev `e391adc` short-circuits on
    /// `staged_removes_member`).
    ///
    /// Returns `None` when the commit is parked, and hands it BACK when the
    /// obligation could not be recorded, so the caller falls back to its normal
    /// disposition: a park nobody can redeem OR report is worse than a publish.
    pub fn defer_removal_commit(&self, commit: CommitToPublish) -> Option<CommitToPublish> {
        if self.owe_removal_publish(&commit) {
            None
        } else {
            Some(commit)
        }
    }

    /// Records that this device OWES the publish of a removal-bearing
    /// receive-side auto-commit — durably first, then in memory. Returns whether
    /// the obligation was recorded.
    ///
    /// EVERY plane that takes such a commit calls this BEFORE it opens the
    /// publish-before-apply window, never only once that window has failed.
    /// A receive-side auto-commit is always removal-bearing (it commits a peer's
    /// `SelfRemove`), and MDK's hydrate deliberately refuses to recover a
    /// removal-bearing staged commit, so a process killed mid-publish leaves a
    /// staged commit no hydrate will clear and emits no
    /// `PendingCommitRecovered` for anyone to notice. The durable row is the only
    /// thing that survives that, which is why it is written first and written
    /// early: it is what turns an invisible wedge into
    /// [`Self::orphaned_removal_deferrals`], for every plane and not just the
    /// live-sync one. A crash between the durable write and the in-memory
    /// registration leaves the state that REPORTS itself, never the state that
    /// hides.
    ///
    /// # Why neither resolution is an alternative to recording this
    ///
    /// * **Confirming** without a relay ack applies a commit no peer received
    ///   (Rule 13) — a roster fork.
    /// * **Rolling back** is a SILENT PERMANENT DROP of the removal, verified at
    ///   source and by experiment at the pinned rev: the engine drops the
    ///   in-memory `scheduled_self_remove_auto_commits` entry before staging,
    ///   `do_publish_failed` does not re-arm it, and a redelivery of the proposal
    ///   short-circuits to `Buffered` off its durable `Created` row without ever
    ///   rescheduling. The leaver would stay in the circle — and keep deriving
    ///   its keys — until some unrelated commit moved the epoch. That is why
    ///   [`Self::publish_failed`] refuses to roll one of these back.
    ///
    /// `false` means the obligation could NOT be recorded: the `#h` names no
    /// circle this device holds, or the row could not be written. A caller that
    /// was going to park must then publish instead, and a caller that was going
    /// to publish must know that its own no-ack path can no longer keep the
    /// removal owed.
    pub fn owe_removal_publish(&self, commit: &CommitToPublish) -> bool {
        let Some(ngid) = nostr_group_id_from_commit_event(&commit.commit_event) else {
            return false;
        };
        // The circle must exist: the durable row is keyed by `nostr_group_id`
        // and `delete_circle` is what cascades it away, so a row for a circle
        // this device does not hold could never be cleared.
        if !self
            .storage
            .get_all_circles()
            .is_ok_and(|circles| circles.iter().any(|c| c.nostr_group_id == ngid))
        {
            return false;
        }
        if let Err(e) = self
            .storage
            .put_deferred_removal_commit(&ngid, chrono::Utc::now().timestamp_millis())
        {
            // The durable half is what makes the obligation loud if this process
            // dies. Without it, holding the commit would be exactly the silent
            // wedge OD4-c names, so report the failure to the caller.
            log::warn!("removal publish obligation not recorded: {}", e.code());
            return false;
        }
        self.removal_deferrals
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(
                ngid,
                CommitToPublish {
                    commit_event: commit.commit_event.clone(),
                    pending: commit.pending,
                },
            );
        true
    }

    /// Whether `pending` is a removal-bearing commit this device owes a publish
    /// for — the one answer [`Self::publish_failed`] needs to know it must not
    /// roll back.
    ///
    /// The obligation was recorded by the plane that took the commit, so nothing
    /// is written here. Linear over a map that holds at most one entry per circle
    /// mid-leave, and normally none at all.
    ///
    /// Matching on the REF and not on the circle is what keeps a send-side commit
    /// for the same circle (a Remove, a relay update) rolling back normally: the
    /// engine's `pending_counter` is monotonic within a session, so no other
    /// staged commit can wear an owed ref's id.
    fn keeps_its_removal_publish_owed(&self, pending: PendingStateRef) -> bool {
        self.removal_deferrals
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .values()
            .any(|commit| commit.pending == pending)
    }

    /// Clears the obligation `pending` belongs to, in memory and durably.
    ///
    /// [`Self::confirm_published`]'s discharge: the engine applied the eviction,
    /// so the removal has landed and nothing is owed. The ngid is resolved from
    /// the map rather than from the event, because that is the key the row is
    /// under and the map is the only place the two are already joined.
    fn discharge_owed_removal_publish(&self, pending: PendingStateRef) {
        let owed = {
            let deferrals = self
                .removal_deferrals
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            deferrals
                .iter()
                .find(|(_, commit)| commit.pending == pending)
                .map(|(ngid, _)| *ngid)
        };
        if let Some(ngid) = owed {
            self.clear_removal_deferral(&ngid);
        }
    }

    /// Publishes every owed eviction commit under the Rule-13 ladder and clears
    /// the ones that land. Returns how many were confirmed.
    ///
    /// `interrupt`, when supplied, is polled once per commit: a caller that holds
    /// a lifecycle lock across this pass can stop it rather than make a teardown
    /// wait out a cascade of relay round-trips.
    ///
    /// Call this from a FOREGROUND pass only: the whole point of the obligation
    /// is that the publish happens where the process is not about to be
    /// suspended. A commit that gets no relay ack STAYS owed — it is never rolled
    /// back, because a rollback is the silent drop
    /// [`Self::owe_removal_publish`] documents — so the next foreground pass
    /// retries it.
    ///
    /// It redeems what THIS session owes, whichever plane took the commit: the
    /// map holds the only live `PendingStateRef`s there are, and an obligation
    /// recorded by a session that has since died is unredeemable by construction
    /// (see [`Self::orphaned_removal_deferrals`]) — which is why a plane running
    /// in a short-lived isolate must publish rather than park.
    ///
    /// # Why it is a worklist and not a pass over a snapshot
    ///
    /// A confirm here ends in the engine's replay, which can surface the NEXT
    /// eviction in a cascade. This pass owns a publisher, so it runs that one
    /// too rather than leaving a commit staged for a foreground open that has
    /// already happened.
    pub async fn redeem_removal_deferrals(
        &self,
        publisher: &dyn crate::relay::auto_commit::AutoCommitPublisher,
        interrupt: Option<&std::sync::atomic::AtomicBool>,
    ) -> usize {
        let mut worklist: std::collections::VecDeque<CommitToPublish> = {
            let deferrals = self
                .removal_deferrals
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            deferrals
                .values()
                .map(|commit| CommitToPublish {
                    commit_event: commit.commit_event.clone(),
                    pending: commit.pending,
                })
                .collect()
        };
        let mut resolved: HashSet<PendingStateRef> = HashSet::new();
        let mut confirmed = 0;
        while let Some(commit) = worklist.pop_front() {
            // The caller holds a lifecycle lock across this whole pass, and a
            // cascade can be a cap's worth of relay round-trips — long enough
            // for a logout to look hung. What is abandoned here keeps its
            // durable row: this session's ref dies with it, so the circle is
            // REPORTED at the next foreground open instead of published. That
            // is the right trade against blocking a teardown the user asked
            // for, and it is the only place this pass gives anything up.
            if interrupt.is_some_and(|flag| flag.load(std::sync::atomic::Ordering::Acquire)) {
                log::info!("removal redemption yielded to a teardown; owed commits stand");
                break;
            }
            if !resolved.insert(commit.pending) {
                continue;
            }
            if resolved.len() > MAX_REDEMPTION_STEPS {
                // Everything still queued keeps its durable row and its live
                // ref, so the next foreground pass redeems it; nothing here is
                // rolled back and nothing is discarded.
                log::warn!(
                    "removal redemption stopped at the runaway cap; {} commit(s) stand owed",
                    bucket(worklist.len() + 1)
                );
                break;
            }
            let relays = self
                .relays_for_commit_event(&commit.commit_event)
                .unwrap_or_default();
            let acked = !relays.is_empty()
                && publisher
                    .publish_auto_commit(&commit.commit_event, &relays)
                    .await;
            if !acked {
                continue;
            }
            let Ok(ingest) = self.confirm_published(commit.pending).await else {
                // STAYS owed. A confirm can fail with the staged commit still
                // attached: the engine's durable transaction propagates a lock
                // blip BEFORE its in-memory state-machine transition, which is
                // why upstream marks the call retry-safe
                // (`EngineError::is_transient`). Clearing on ANY error would
                // delete the only record of a still-owed eviction, leaving a
                // wedge that reports nothing and a fail rung free to discard the
                // removal — the silent drop this obligation exists to prevent.
                // A ref that genuinely is gone costs one redundant publish per
                // foreground open until that circle's next successful send
                // discharges the row.
                continue;
            };
            // The obligation was discharged BY REF inside the confirm, at the
            // one scope that is correct. An ngid-scoped clear here would delete
            // a SECOND-generation obligation the confirm's own replay has just
            // recorded (the map holds one entry per circle), leaving a staged,
            // unpublished, no-longer-owed and no-longer-reported eviction — this
            // very wedge, re-armed and invisible.
            confirmed += 1;
            // `ingest.results` are already persisted and this pass has no UI
            // surface to route them to.
            for proposal in ingest.proposals {
                let relays = self.relays_for_commit_event(&proposal).unwrap_or_default();
                if !relays.is_empty() {
                    // A bare proposal opens no publish-before-apply window:
                    // nothing to confirm, nothing to roll back, and an unacked
                    // one is re-minted by the next commit this device applies.
                    let _ = publisher.publish_auto_commit(&proposal, &relays).await;
                }
            }
            worklist.extend(ingest.auto_commits);
        }
        confirmed
    }

    /// Every circle that owes an eviction commit, redeemable or not.
    ///
    /// The DURABLE view: it counts an obligation this session can still publish
    /// and one that outlived the session which took it alike. Use
    /// [`Self::orphaned_removal_deferrals`] for the second alone — that is the
    /// one that is a wedge.
    #[must_use]
    pub fn owed_removal_commits(&self) -> Vec<[u8; 32]> {
        self.storage.deferred_removal_commits().unwrap_or_default()
    }

    /// Circles with a DURABLE obligation row that this session cannot redeem —
    /// the wedge OD4-c option (i) reports.
    ///
    /// A row with no live in-memory entry was recorded by a session that is
    /// gone. Its `PendingStateRef` died with that session, and at MDK `e391adc`
    /// nothing can re-derive the eviction: the engine's `SelfRemove` auto-commit
    /// schedule is in-memory only, `do_publish_failed` does not re-arm it, and a
    /// redelivered proposal short-circuits to `Buffered`. The circle therefore
    /// carries a staged commit no code path will ever publish or clear, and it
    /// cannot recover on its own.
    ///
    /// Returns the pseudonymous `nostr_group_id`s only (Security Rule 4).
    #[must_use]
    pub fn orphaned_removal_deferrals(&self) -> Vec<[u8; 32]> {
        let Ok(rows) = self.storage.deferred_removal_commits() else {
            return Vec::new();
        };
        let live = self
            .removal_deferrals
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        rows.into_iter()
            .filter(|ngid| !live.contains_key(ngid))
            .collect()
    }

    /// Discharges `nostr_group_id`'s deferral because an outbound send for that
    /// circle just SUCCEEDED.
    ///
    /// A successful send proves the group is `Stable` — the engine refuses one
    /// from any other state — which proves no staged commit remains, which proves
    /// nothing is owed. It is the ONLY positive proof available at MDK `e391adc`:
    /// every read accessor (`epoch`, `members`, `group_record`,
    /// `current_safe_export_epoch`) projects the post-merge state from the moment
    /// a commit is staged, so none of them can tell a merged eviction from a
    /// staged one.
    ///
    /// This is what keeps [`Self::orphaned_removal_deferrals`] from reporting a
    /// circle another member's commit already healed: that heal arrives as
    /// `IngestOutcome::Processed` with NO engine events (the record's epoch was
    /// already projected forward, so nothing "changed"), so there is no event to
    /// clear the row on — but the very next publish for that circle succeeds, and
    /// this clears it.
    ///
    /// One indexed point lookup per successful send, on a table that holds at
    /// most one row per circle mid-leave.
    fn discharge_removal_deferral_after_send(&self, nostr_group_id: &[u8; 32]) {
        if self
            .storage
            .has_deferred_removal_commit(nostr_group_id)
            .unwrap_or(false)
        {
            self.clear_removal_deferral(nostr_group_id);
        }
    }

    /// Clears `nostr_group_id`'s obligation only when this session can no
    /// longer redeem it — the `EpochChanged` fold's discharge, argued at
    /// [`Self::note_epoch_changes`].
    fn clear_orphaned_removal_deferral(&self, nostr_group_id: &[u8; 32]) {
        let redeemable = self
            .removal_deferrals
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .contains_key(nostr_group_id);
        if !redeemable {
            self.clear_removal_deferral(nostr_group_id);
        }
    }

    /// Drops the in-memory half of `nostr_group_id`'s obligation, leaving the
    /// durable row to whoever owns it.
    ///
    /// For the one case where the row is already gone: `delete_circle` cascades
    /// `deferred_removal_commits`, so re-issuing the DELETE would be noise and
    /// the map is the only half left to clean up.
    fn forget_removal_deferral_in_memory(&self, nostr_group_id: &[u8; 32]) {
        self.removal_deferrals
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(nostr_group_id);
    }

    /// Forgets `nostr_group_id`'s obligation, in memory and durably.
    fn clear_removal_deferral(&self, nostr_group_id: &[u8; 32]) {
        self.removal_deferrals
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(nostr_group_id);
        if let Err(e) = self.storage.clear_deferred_removal_commit(nostr_group_id) {
            log::warn!("deferred removal commit not cleared: {}", e.code());
        }
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

        self.pending_welcomes
            .insert(PendingWelcome::new(gift_wrap_event.clone(), preview));

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

        let ingest = self
            .session
            .accept_welcome(held.gift_wrap())
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;

        let group_id = ingest
            .effects
            .events
            .iter()
            .find_map(|ev| match ev {
                GroupEvent::GroupJoined { group_id, .. } => Some(group_id.clone()),
                _ => None,
            })
            .ok_or_else(|| {
                CircleError::Mls("welcome accept did not yield a joined group".to_string())
            })?;

        let (nostr_group_id, relays) = self
            .session
            .group_routing(&group_id)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;
        let group = self
            .session
            .group_record(&group_id)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;

        let now = chrono::Utc::now().timestamp();
        let resolved_name = if group.name.is_empty() {
            "New Circle".to_string()
        } else {
            group.name
        };
        let effective_relays = if relays.is_empty() {
            crate::circle::types::default_relays()
        } else {
            relays
        };
        let circle = Circle {
            mls_group_id: group_id.clone(),
            nostr_group_id,
            display_name: resolved_name,
            circle_type: CircleType::LocationSharing,
            relays: effective_relays,
            created_at: now,
            updated_at: now,
        };
        let membership = CircleMembership {
            mls_group_id: group_id.clone(),
            status: MembershipStatus::Accepted,
            inviter_pubkey: Some(held.preview().inviter_pubkey.clone()),
            invited_at: now,
            responded_at: Some(now),
        };

        // Atomically persist the circle + membership + dedup row, then drop the
        // held welcome (terminal).
        self.storage
            .record_processed_invitation(gift_wrap_id, &circle, &membership, now)?;
        // A joined circle carries the INVITER's routing relays, which is the
        // most common way a relay this user never chose starts seeing their
        // kind-445 — and the most likely way a profile-pool relay would get
        // contaminated. Record before the circle is usable.
        self.record_contaminated(&circle.relays, ContaminationSource::CircleRouting)?;
        self.pending_welcomes.remove(gift_wrap_id);

        // Accepting is what makes the roster real, so it is the directory write
        // site — never the preview above, which is seal-authenticated only
        // (anyone can gift-wrap a welcome) and where a row would break
        // decline-leaves-no-trace. Placed after the storage write so the circle
        // the union is about to read is already persisted.
        self.reconcile_member_directory_best_effort(DirectoryReconcile::Rewrite)
            .await;

        self.get_circle(&group_id)
            .await?
            .ok_or_else(|| CircleError::NotFound("Circle not found after acceptance".to_string()))
    }

    /// Declines an invitation: drops the held 1059 locally.
    ///
    /// The welcome is never ingested, so there is no join commit, no
    /// self-remove, nothing on the wire (Rule 10). The gift wrap is marked
    /// resolved so a re-poll does not re-surface it.
    ///
    /// # Errors
    ///
    /// Returns an error only if the resolution sentinel write fails.
    pub fn decline_invitation(&self, gift_wrap_id: &EventId) -> Result<()> {
        self.pending_welcomes.remove(gift_wrap_id);
        let now = chrono::Utc::now().timestamp();
        // Reuse the failure-sentinel row as a "resolved, do not re-surface" mark.
        let _ = self.storage.record_gift_wrap_failure(gift_wrap_id, now);
        Ok(())
    }

    // ==================== Location Sharing ====================

    /// Encrypts a location for a circle, producing a kind 445 event.
    ///
    /// Builds the inner Marmot app event (kind
    /// [`KIND_LOCATION_UPDATE`](crate::nostr::KIND_LOCATION_UPDATE), untagged,
    /// `pubkey` == the local identity per W9) and sends it via the engine,
    /// returning the transport event plus the circle's `nostr_group_id` and
    /// relays for the relay layer to publish.
    ///
    /// The per-send NIP-40 expiration is dropped (retention is now a group-level
    /// `message-retention.v1` component, not a per-message tag — `dm2_report` #2);
    /// `update_interval_secs` is retained for signature stability but unused.
    ///
    /// # Errors
    ///
    /// Returns an error if the circle is not found, serialization fails, or the
    /// engine rejects the send. Returns [`CircleError::SendDeferred`] when the
    /// engine QUEUED the update instead of encrypting it — see that variant and
    /// [`Self::deferred_send_outcome`].
    pub async fn encrypt_location(
        &self,
        mls_group_id: &GroupId,
        _sender_pubkey: &PublicKey,
        location: &LocationMessage,
        _update_interval_secs: u64,
    ) -> Result<(Event, [u8; 32], Vec<String>)> {
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

        // `send_location` stamps the inner pubkey with the session identity (W9)
        // and generates a fresh ephemeral key per 445 (Rule 2, engine-owned).
        let effects = self
            .session
            .send_location(mls_group_id, content)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;

        // The engine queued rather than encrypted. Checked BEFORE
        // `take_app_message`, which would otherwise report the queue as "no
        // publish work" — the opaque error every Dart caller dropped into a
        // `debugPrint` while the device silently stopped sharing.
        if !effects.queued.is_empty() {
            // The deferred branch drains the same buffers the successful one
            // does, and it reaches `take_app_message` never — so the peer
            // locations this send replayed are persisted HERE. The publish half
            // is `collect_deferred_work`'s, which records its own obligations.
            self.note_send_drain(&effects.events).await;
            return Err(self
                .deferred_send_outcome(mls_group_id, effects.publish, now_secs())
                .await);
        }
        let event = self.take_app_message(effects).await?;
        // The engine accepted an outbound message, so this group is `Stable` and
        // holds no staged commit — the only positive proof that a deferred
        // eviction is no longer owed. See
        // [`Self::discharge_removal_deferral_after_send`].
        self.discharge_removal_deferral_after_send(&circle.nostr_group_id);

        Ok((event, circle.nostr_group_id, circle.relays))
    }

    /// Turns a deferred (queued) send into a typed, actionable outcome.
    ///
    /// Infallible by construction — every internal failure is logged and folded
    /// into the returned outcome, because the ONE thing this must never do is
    /// replace an actionable "sharing is stalled" signal with an unrelated
    /// error string.
    ///
    /// # Two causes, two paths
    ///
    /// `should_queue_outbound_intent` is true for exactly two reasons, and they
    /// need opposite handling:
    ///
    /// 1. **A staged auto-commit** — a peer's `SelfRemove` came due and the
    ///    engine staged the eviction commit inside this very call, draining it
    ///    into `publish`. Nothing is stuck; the circle is mid-handshake. Hand
    ///    the work back (see [`DeferredWork`] for why neither confirming,
    ///    rolling back, nor dropping is acceptable) and do NOT sweep: a group
    ///    in `PendingPublish` has no stuck row to clear, and a sweep would
    ///    report a repair nobody performed.
    /// 2. **A stored row the convergence gate cannot settle** — then `publish`
    ///    is empty and the repair below is the whole response.
    ///
    /// # The repair, in order
    ///
    /// 1. **Sweep this circle.** One pass does both halves: it discards the
    ///    location intent the engine just queued (a fix is ephemeral — the next
    ///    cadence tick carries a fresher one, and a queue that grows one row per
    ///    publish cycle is the other half of the leak), and it retires any
    ///    stored row the relay can no longer redeliver. The retirement is the
    ///    only step that can clear a future-epoch row: convergence re-feeds it
    ///    on every pass and deliberately keeps it `Retryable` so a late commit
    ///    can still resolve it.
    /// 2. **Advance convergence**, which releases everything step 1 unblocked
    ///    (the engine's `advance_convergence` runs
    ///    `advance_convergence_inputs_until_settled`, including
    ///    `retry_deferred_peels`, before draining queued work). Anything it
    ///    stages is surfaced, never resolved here — same rule as above.
    /// 3. **Re-read the gate, read-only.** A second mutating sweep would retire
    ///    rows nobody asked about and report a pass the caller never requested.
    ///
    /// No send is retried here. The next scheduled publish re-enters
    /// [`Self::encrypt_location`] with a current fix, which is both simpler and
    /// more accurate than resending the one that was queued.
    async fn deferred_send_outcome(
        &self,
        mls_group_id: &GroupId,
        publish: Vec<PublishWork>,
        now_secs: u64,
    ) -> CircleError {
        let report = self
            .repair_deferred_send(mls_group_id, publish, now_secs)
            .await;
        CircleError::SendDeferred {
            unresolved_inputs: report.unresolved_inputs,
            discarded_intents: report.discarded_intents,
            repaired: report.repaired,
            work: report.work,
        }
    }

    /// The repair itself, shaped as a value rather than as an error.
    ///
    /// Split out of [`Self::deferred_send_outcome`] so a deferred EPOCH ROTATION
    /// — which has no location event to lose and therefore is not an error —
    /// can run the identical repair and return the identical work without
    /// destructuring an error to get at it (see
    /// [`Self::repair_epoch_rotation`]). The behaviour is exactly what
    /// `encrypt_location` had; only the shape moved.
    async fn repair_deferred_send(
        &self,
        mls_group_id: &GroupId,
        publish: Vec<PublishWork>,
        now_secs: u64,
    ) -> DeferredSendReport {
        let mut work = self.collect_deferred_work(&publish).await;
        if !work.is_empty() {
            // No stored row is stuck here, so there is nothing to retire — but
            // the engine still QUEUED the location fix that triggered this
            // deferral, and leaving it banked until the next session open is
            // exactly the stale-position leak `SendDeferred` promises not to
            // have. Discard it on this branch too.
            let discarded_intents = self.discard_queued_location_intents(mls_group_id).await;
            return DeferredSendReport {
                unresolved_inputs: self.gating_input_count(mls_group_id).await,
                discarded_intents,
                repaired: false,
                work,
            };
        }

        let sweep = match self
            .session
            .sweep_unresolvable_inputs_for_group(mls_group_id, now_secs)
            .await
        {
            Ok(sweep) => sweep,
            Err(e) => {
                log::warn!("deferred send: convergence sweep failed: {}", e.code());
                ConvergenceSweep::default()
            }
        };

        match self.session.advance_convergence(mls_group_id).await {
            Ok(effects) => {
                // Through the FOLD, not a bare publish scan: this batch is a
                // drained one, so it carries whatever the release re-ingested —
                // peer locations (persisted by the fold, which is the point) and
                // the local user's own re-proposed leave, which must keep
                // reaching `work.proposals` or the leave wedges behind the
                // engine's send gate.
                let (advanced, verdict) = self
                    .fold_resolved_publish(effects, BatchOrigin::Drained)
                    .await;
                work.commits.extend(advanced.auto_commits);
                work.proposals.extend(advanced.proposals);
                if let Some(mode) = verdict {
                    self.reconcile_member_directory_best_effort(mode).await;
                }
            }
            Err(e) => log::warn!("deferred send: advancing convergence failed: {}", e.code()),
        }

        let unresolved_inputs = self.gating_input_count(mls_group_id).await;
        log::warn!(
            "send deferred by the MLS engine: {} input(s) still gating after repair \
             ({} queued location intent(s) discarded, {} stale input(s) retired, \
             {} staged commit(s) handed back)",
            bucket(unresolved_inputs),
            bucket(sweep.discarded_intents),
            bucket(sweep.disposed_messages),
            bucket(work.commits.len())
        );
        DeferredSendReport {
            unresolved_inputs,
            discarded_intents: sweep.discarded_intents,
            repaired: unresolved_inputs == 0 && work.is_empty(),
            work,
        }
    }

    /// Collects every publish item a deferred send drained, converting staged
    /// commits to [`CommitToPublish`] and bare proposals to signed events.
    ///
    /// Nothing is confirmed and nothing is rolled back — see [`DeferredWork`].
    /// An item whose transport message cannot be serialized is the ONE case
    /// that must still be resolved here, because there is no event for a caller
    /// to publish: it is rolled back (`publish_failed`) rather than left
    /// staged, which matches [`Self::collect_auto_commits`] on the receive path.
    ///
    /// Each of the three rollbacks keeps its OWN batch
    /// ([`Self::absorb_rollback`]): the engine replays on the way out of
    /// `publish_failed` too, so even this corner releases peer locations
    /// (persisted by the resolution itself) and can stage the next commit in a
    /// cascade.
    async fn collect_deferred_work(&self, work: &[PublishWork]) -> DeferredWork {
        let mut out = DeferredWork::default();
        for item in work {
            match item {
                // Split from `GroupEvolution` below for one reason: THIS is the
                // peer `SelfRemove` eviction the engine staged inside the send,
                // so it is removal-bearing and its publish is recorded as owed
                // before it crosses the FFI — exactly as on the receive path
                // ([`Self::collect_auto_commits`]). A `GroupEvolution` is a
                // send-side commit this device authored and may legitimately
                // roll back.
                PublishWork::AutoPublish { msg, pending } => {
                    match SessionManager::transport_message_to_event(msg) {
                        Ok(commit_event) => {
                            let commit = CommitToPublish {
                                commit_event,
                                pending: *pending,
                            };
                            if !self.owe_removal_publish(&commit) {
                                log::warn!(
                                    "deferred send handed back an eviction commit with no \
                                     recorded obligation: an unacked publish will roll it back"
                                );
                            }
                            out.commits.push(commit);
                        }
                        Err(_) => self.absorb_rollback(*pending, &mut out).await,
                    }
                }
                PublishWork::GroupEvolution { msg, pending, .. } => {
                    match SessionManager::transport_message_to_event(msg) {
                        Ok(commit_event) => out.commits.push(CommitToPublish {
                            commit_event,
                            pending: *pending,
                        }),
                        Err(_) => self.absorb_rollback(*pending, &mut out).await,
                    }
                }
                // A create can never surface on a send path for an existing
                // group; if the engine ever emitted one there would be no event
                // to publish here (welcomes only), so roll it back rather than
                // silently pin the group.
                PublishWork::GroupCreated { pending, .. } => {
                    self.absorb_rollback(*pending, &mut out).await;
                }
                PublishWork::Proposal { msg } => {
                    match SessionManager::transport_message_to_event(msg) {
                        Ok(event) => out.proposals.push(event),
                        Err(e) => log::warn!(
                            "deferred send: dropping an unserializable proposal: {}",
                            e.code()
                        ),
                    }
                }
                PublishWork::ApplicationMessage { .. } => {}
            }
        }
        out
    }

    /// Rolls a staged item back and keeps what the rollback itself released.
    ///
    /// The engine replays its buffer on the way out of `publish_failed`, so even
    /// this corner — an item whose transport message will not serialize — hands
    /// back peer locations (already persisted), the next eviction in a cascade,
    /// and any re-proposed leave. Folding them here is what stops the rollback
    /// from being a second drop site.
    async fn absorb_rollback(&self, pending: PendingStateRef, out: &mut DeferredWork) {
        let Ok(batch) = self.publish_failed(pending).await else {
            return;
        };
        out.commits.extend(batch.auto_commits);
        out.proposals.extend(batch.proposals);
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

    /// Rows still gating outbound sends for a circle, or `0` if the store
    /// cannot be read.
    ///
    /// Read-only. Zero on failure is the fail-SAFE direction here: it makes the
    /// outcome claim "repaired", and a wrong "repaired" only costs one more
    /// deferral on the next cadence tick, whereas a wrong "still stuck" would
    /// park a working circle behind a repair banner forever.
    async fn gating_input_count(&self, mls_group_id: &GroupId) -> usize {
        self.session
            .gating_input_count(mls_group_id)
            .await
            .unwrap_or_else(|e| {
                log::warn!("deferred send: reading the send gate failed: {}", e.code());
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
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))
    }

    /// The group relays a `kind:445` commit routes to, resolved from its `#h`
    /// (`nostr_group_id`) tag against the local circle rows.
    ///
    /// Used by the receive-side auto-commit publisher
    /// ([`crate::relay::auto_commit`]) to target a peer `SelfRemove` eviction
    /// commit at the correct circle's relays. Returns `None` (fail closed — the
    /// caller then rolls the commit back rather than publish it nowhere) when the
    /// `#h` tag is absent/malformed or no local circle matches.
    #[must_use]
    pub fn relays_for_commit_event(&self, event: &Event) -> Option<Vec<String>> {
        let ngid = nostr_group_id_from_commit_event(event)?;
        let circles = self.storage.get_all_circles().ok()?;
        circles
            .into_iter()
            .find(|c| c.nostr_group_id == ngid)
            .map(|c| c.relays)
    }

    /// Decrypts / ingests a received kind 445 event, returning the folded
    /// location-facing results AND any receive-side auto-commit(s) the engine
    /// staged (a peer `SelfRemove` eviction).
    ///
    /// Ingests the transport message, drains the engine's emitted
    /// [`GroupEvent`]s, advances stored convergence for any group with pending
    /// convergence, folds each event into a [`LocationMessageResult`], and
    /// collects every [`PublishWork::AutoPublish`] into a [`CommitToPublish`].
    ///
    /// Publish-before-apply (Rule 13): the caller MUST publish each returned
    /// [`DecryptedIngest::auto_commits`] entry's `commit_event` to the circle's
    /// relays and then [`Self::confirm_published`] on a ≥1-relay ack (or
    /// [`Self::publish_failed`] on failure) — exactly like [`CommitToPublish`]
    /// from the send paths, except that the failure rung keeps the publish OWED
    /// instead of discarding the eviction. The obligation is recorded before the
    /// commit is handed over ([`Self::collect_auto_commits`]). An auto-commit
    /// that cannot be serialized is rolled back here (never surfaced
    /// half-formed).
    ///
    /// An event Haven's receiver-side screen rejected before any MLS
    /// authentication (an expired NIP-40 replay) yields an EMPTY
    /// [`DecryptedIngest`]: no results, no auto-commits, nothing persisted. This
    /// entry point owns no sync cursor, so there is no cursor decision to make
    /// here — the two planes that do own one
    /// ([`crate::relay::live_sync`], [`crate::relay::catchup`]) call
    /// [`crate::nostr::mls::SessionManager::process_event`] directly and match on
    /// its [`ScreenedIngest`](crate::nostr::mls::types::ScreenedIngest).
    ///
    /// # Errors
    ///
    /// Returns an error only for a hard ingest failure.
    pub async fn decrypt_location_collecting_commits(
        &self,
        event: &Event,
    ) -> Result<DecryptedIngest> {
        let screened = self
            .session
            .process_event(event)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;
        let Some(ingest) = screened.ingested() else {
            return Ok(DecryptedIngest::default());
        };

        // This plane folds to results rather than routing raw events, so it is
        // its own receive-observation write site (the other planes call
        // `note_inbound_group_events` at their own `process_event` seam).
        self.note_inbound_group_events(&ingest.effects.events);
        let mut results = fold_group_events(&ingest.effects.events);
        let mut auto_commits = Vec::new();
        for rolled in self
            .collect_auto_commits(&ingest.effects.publish, &mut auto_commits)
            .await
        {
            results.extend(fold_group_events(&rolled.events));
        }

        // Release any queued work + buffered inbound now safe to apply, re-ticking
        // a group that stays pending until its jitter-delayed `SelfRemove`
        // auto-commit surfaces (bounded) — a single advance would drain the group
        // out of the engine's pending set before the auto-commit's wall-clock due
        // time, so the eviction would never be surfaced for the caller to publish.
        // A quiet group exits immediately (no delay).
        let mut pending: Vec<GroupId> = ingest.effects.pending_convergence.clone();
        for _ in 0..crate::relay::auto_commit::MAX_CONVERGENCE_RETICKS {
            if pending.is_empty() {
                break;
            }
            let mut next: Vec<GroupId> = Vec::new();
            for gid in &pending {
                if let Ok(more) = self.session.advance_convergence(gid).await {
                    self.note_inbound_group_events(&more.events);
                    results.extend(fold_group_events(&more.events));
                    for rolled in self
                        .collect_auto_commits(&more.publish, &mut auto_commits)
                        .await
                    {
                        results.extend(fold_group_events(&rolled.events));
                    }
                    next.extend(more.pending_convergence);
                }
            }
            pending = next;
            if !pending.is_empty() {
                tokio::time::sleep(crate::relay::auto_commit::CONVERGENCE_RETICK_DELAY).await;
            }
        }

        // Best-effort: re-derive `circle.relays` after a group update. Collect
        // ids first to avoid borrowing `results` across the await.
        let updated: Vec<GroupId> = results
            .iter()
            .filter_map(|r| match r {
                LocationMessageResult::GroupUpdate { group_id } => Some(group_id.clone()),
                _ => None,
            })
            .collect();
        for gid in updated {
            if let Err(e) = self.resync_circle_relays_from_mdk(&gid).await {
                log::debug!(
                    "decrypt_location: relay re-sync failed (will retry on next commit): {}",
                    e.code()
                );
            }
        }

        // ONE reconcile per ingest, after convergence has drained, so no roster
        // is ever read mid-drain. `for_receive_results` owns the decision about
        // WHICH results ask for one — a decrypted kind-445 never does
        // (`app_message_past_epoch_limit` epochs of slack would resurrect
        // someone removed several epochs ago).
        if let Some(mode) = self.directory_verdict_for_results(&results) {
            self.reconcile_member_directory_best_effort(mode).await;
        }

        Ok(DecryptedIngest {
            results,
            auto_commits,
            // This plane has no publish-resolution batch of its own, so the
            // only proposal shape it could see — the local re-proposed leave —
            // reaches it through the confirm/fail funnel instead.
            proposals: Vec::new(),
        })
    }

    /// Converts each [`PublishWork::AutoPublish`] in `work` into a surfaced
    /// [`CommitToPublish`], recording the publish this device now owes for it;
    /// an auto-commit whose wrapped message cannot be serialized is rolled back
    /// ([`Self::publish_failed`]) rather than surfaced half-formed (Rule 13:
    /// never leave a pending ref dangling).
    ///
    /// The obligation is recorded HERE, not by the caller, because the caller is
    /// across the FFI: the foreground poll plane and the Android foreground
    /// service's publish cycle both take the commit into Dart and publish it
    /// there. Recording it before it crosses is what makes their
    /// publish-before-apply window survivable — a process killed mid-publish
    /// leaves the row, and their no-ack `publishFailed` keeps the removal owed
    /// instead of dropping it (see [`Self::owe_removal_publish`]).
    /// Returns the batch of every rollback it had to perform, for the caller to
    /// fold — a rolled-back ref's effects are engine work like any other, and
    /// dropping them is the defect this whole path exists to close.
    async fn collect_auto_commits(
        &self,
        work: &[PublishWork],
        out: &mut Vec<CommitToPublish>,
    ) -> Vec<SessionEffects> {
        let mut rolled_back = Vec::new();
        for item in work {
            if let PublishWork::AutoPublish { msg, pending } = item {
                if let Some(effects) = self.surface_auto_commit(msg, *pending, out).await {
                    rolled_back.push(effects);
                }
            }
        }
        rolled_back
    }

    /// One [`PublishWork::AutoPublish`] surfaced as a [`CommitToPublish`] with
    /// its obligation recorded, or rolled back when the wrapped message will not
    /// serialize — in which case its batch comes back for the caller to fold.
    async fn surface_auto_commit(
        &self,
        msg: &TransportMessage,
        pending: PendingStateRef,
        out: &mut Vec<CommitToPublish>,
    ) -> Option<SessionEffects> {
        match SessionManager::transport_message_to_event(msg) {
            Ok(commit_event) => {
                let commit = CommitToPublish {
                    commit_event,
                    pending,
                };
                if !self.owe_removal_publish(&commit) {
                    // Not recordable (the circle row is gone, or the DB refused
                    // the write). Said out loud rather than assumed away: this
                    // is the one shape in which the caller's own no-ack path can
                    // still roll the eviction back.
                    log::warn!(
                        "receive-side eviction commit surfaced with no recorded \
                         obligation: an unacked publish will roll it back"
                    );
                }
                out.push(commit);
                None
            }
            Err(_) => self.rollback_unfolded(pending).await,
        }
    }

    /// Decrypts / ingests a received kind 445 event, returning ONLY the folded
    /// location-facing results.
    ///
    /// Back-compatible shim over [`Self::decrypt_location_collecting_commits`]
    /// for call sites (chiefly tests) that never trigger a peer `SelfRemove`. It
    /// does NOT surface receive-side auto-commits; to stay Rule-13-safe it
    /// reports each as failed ([`Self::publish_failed`]) rather than
    /// optimistically applying an unpublished commit. Production receive paths use
    /// [`Self::decrypt_location_collecting_commits`] (poll → Dart publishes) or
    /// the live-sync / catch-up planes (which publish in-Rust).
    ///
    /// That report does NOT discard the eviction: the surfacing recorded the
    /// obligation, so the commit stays staged and OWED
    /// ([`Self::owe_removal_publish`]). The circle cannot send while it stands
    /// (`create_message` refuses from `PendingPublish`), which is the honest cost
    /// of a caller that has no relay plane — the alternative, a rollback, would
    /// drop the removal permanently and silently and leave the circle equally
    /// unable to send (`GroupStateError(PendingProposal)`); see
    /// [`crate::relay::auto_commit::park_or_rollback_receive_publish_work`].
    ///
    /// # Errors
    ///
    /// Returns an error only for a hard ingest failure.
    pub async fn decrypt_location(&self, event: &Event) -> Result<Vec<LocationMessageResult>> {
        let mut ingest = self.decrypt_location_collecting_commits(event).await?;
        for commit in std::mem::take(&mut ingest.auto_commits) {
            // No relay plane here — never apply an unpublished eviction commit,
            // and never discard it either: this leaves it staged and owed. The
            // report's OWN batch is merged rather than dropped: the kept-owed
            // rung returns an empty one, but the rung that actually rolls back
            // replays, and a peer location it replays is deliverable once.
            if let Ok(nested) = self.publish_failed(commit.pending).await {
                ingest.results.extend(nested.results);
            }
        }
        Ok(ingest.results)
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
    /// The ONE persist site every receive plane shares, and the reason it is
    /// shared: the engine delivers `MessageReceived` AT MOST ONCE and writes
    /// the content row `Processed` in the same breath, with no
    /// application-acknowledgement boundary — a plane that folds the batch
    /// without persisting loses the fix permanently.
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
    async fn persist_locations_from_events(&self, events: &[GroupEvent]) -> RosterDeclined {
        let mut declined = RosterDeclined::default();
        let own_hex = self.session.identity_pubkey().to_hex();
        // One roster read per distinct group per batch. `None` records a read
        // that FAILED, which is the fail-open case, not an empty roster.
        let mut rosters: HashMap<GroupId, Option<HashSet<String>>> = HashMap::new();
        for event in events {
            let Some(LocationMessageResult::Location {
                sender_pubkey,
                content,
                group_id,
                ..
            }) = SessionManager::location_result_from_event(event)
            else {
                continue;
            };
            if sender_pubkey == own_hex {
                continue;
            }
            let Some(nostr_group_id) = self.nostr_group_id_for(&group_id) else {
                continue;
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
                continue;
            }
            let Ok(msg) = serde_json::from_str::<LocationMessage>(&content) else {
                continue;
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
            }
        }
        declined
    }

    /// [`Self::persist_and_fold`]'s persist half, for a plane that routes raw
    /// engine events and folds no results of its own (the catch-up sweep).
    ///
    /// The roster refusals go with it: there is no second half here for them to
    /// be applied to.
    pub(crate) async fn persist_replayed_locations(&self, events: &[GroupEvent]) {
        let _ = self.persist_locations_from_events(events).await;
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

        let mut clamped = location.clone();
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
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn note_publish_acked(&self, nostr_group_id: &[u8; 32], at_ms: i64) -> Result<()> {
        self.storage.note_publish_acked(nostr_group_id, at_ms)
    }

    /// Records a decrypted, persisted peer location for a circle (presence
    /// only).
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn note_peer_event(&self, nostr_group_id: &[u8; 32], at_ms: i64) -> Result<()> {
        self.storage.note_peer_event(nostr_group_id, at_ms)
    }

    /// Reads a circle's delivery-health timestamps.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn circle_health(&self, nostr_group_id: &[u8; 32]) -> Result<super::CircleHealth> {
        self.storage.circle_health(nostr_group_id)
    }

    /// Reads a circle's epoch-rotation stamps.
    ///
    /// Test-only. A harness that steps a policy clock must compute what a
    /// rotation gate will decide from the stamps the WRITE side actually
    /// recorded — which it stamps from real time
    /// ([`Self::note_inbound_group_events`], `note_epoch_changes`,
    /// [`Self::confirm_published`]) — and never from the offset it applied,
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

    // ==================== Key Packages ====================

    /// Produces a fresh `KeyPackage` for publishing to a directory (kind 30443).
    ///
    /// Event building / signing stays in Haven's relay layer (DM-2b); this
    /// returns the raw engine [`KeyPackage`].
    ///
    /// # Errors
    ///
    /// Returns an error if generation fails.
    pub async fn fresh_key_package(&self) -> Result<KeyPackage> {
        self.session
            .fresh_key_package()
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))
    }

    /// Deletes a previously generated `KeyPackage` bundle (publish-failure cleanup;
    /// mdk#160). Idempotent.
    ///
    /// # Errors
    ///
    /// Returns an error if deletion fails.
    pub async fn delete_key_package(&self, key_package: &KeyPackage) -> Result<()> {
        self.session
            .delete_key_package(key_package)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))
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

    /// See [`CircleStorage::record_published_key_package`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn record_published_key_package(
        &self,
        row: &super::storage_key_packages::PublishedKeyPackageRow,
    ) -> Result<()> {
        self.storage.record_published_key_package(row)
    }

    /// See [`CircleStorage::latest_published_key_package`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn latest_published_key_package(
        &self,
    ) -> Result<Option<super::storage_key_packages::PublishedKeyPackageRow>> {
        self.storage.latest_published_key_package()
    }

    /// See [`CircleStorage::latest_canonical_d_tag`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn latest_canonical_d_tag(&self) -> Result<Option<String>> {
        self.storage.latest_canonical_d_tag()
    }

    /// See [`CircleStorage::wipe_published_key_packages`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn wipe_published_key_packages(&self) -> Result<()> {
        self.storage.wipe_published_key_packages()
    }

    /// See [`CircleStorage::delete_published_key_package`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn delete_published_key_package(&self, d_tag: &str) -> Result<()> {
        self.storage.delete_published_key_package(d_tag)
    }

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

    /// See [`CircleStorage::legacy_kp_retraction_done`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn legacy_kp_retraction_done(&self) -> Result<bool> {
        self.storage.legacy_kp_retraction_done()
    }

    /// See [`CircleStorage::mark_legacy_kp_retraction_done`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn mark_legacy_kp_retraction_done(&self) -> Result<()> {
        self.storage.mark_legacy_kp_retraction_done()
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
    pub fn wipe_all_profiles(&self) -> Result<()> {
        self.storage.wipe_all_profiles()
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
/// ([`CircleManager::decrypt_location_collecting_commits`] → [`fold_group_events`]),
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

/// Extracts the `GroupCreated { welcomes, pending }` publish work from a
/// create-group's effects.
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
    /// widening `encrypt_location`'s return across the FFI for a signal the
    /// RECEIVE path already drives authoritatively (catch-up runs first after
    /// every open, and its fold maps both events to a `GroupUpdate`). What would
    /// close it is that same FFI widening. Recorded rather than assumed away:
    /// a deviation from an approved design is not a detail.
    async fn note_send_drain(&self, events: &[GroupEvent]) {
        note_dropped_resync_events(events);
        self.persist_replayed_locations(events).await;
    }

    /// Records the obligation for any eviction auto-commit a send co-drained.
    ///
    /// It is never the item a `take_*` is after, and dropping it with a live
    /// `PendingStateRef` is how a removal goes silent. Recording it is the whole
    /// disposition: the commit stays staged and OWED.
    ///
    /// # Its only recovery is the redemption pass — NOT that circle's next send
    ///
    /// The ref is always a DIFFERENT circle's: a same-circle staging puts the
    /// group in `PendingPublish`, so the send answers `Queued` and takes the
    /// deferred branch instead of reaching here. And that other circle's next
    /// send does not recover it either — it comes back `SendDeferred`, but
    /// [`Self::collect_deferred_work`] reads only that call's own publish
    /// vector, and the engine never re-emits the `AutoPublish` (the schedule is
    /// consumed before staging and `publish_failed` does not re-arm it, which is
    /// what [`Self::orphaned_removal_deferrals`] is built on). So
    /// [`Self::redeem_removal_deferrals`] — a FOREGROUND live-sync open — is the
    /// one path that publishes it, and in a `HAVEN_LIVE_SYNC=false` build
    /// nothing does. See `haven-core/SECURITY.md` for the full residual; closing
    /// it means widening `encrypt_location`'s return with what it collected.
    async fn surface_co_drained_auto_commits(&self, publish: &[PublishWork]) {
        let mut surfaced = Vec::new();
        for item in publish {
            if let PublishWork::AutoPublish { msg, pending } = item {
                // The rollback arm's batch is dropped: it is only reached for a
                // message the engine built moments ago and could not re-serialize.
                let _ = self.surface_auto_commit(msg, *pending, &mut surfaced).await;
            }
        }
    }

    /// Extracts the `GroupCreated { welcomes, pending }` publish work from a
    /// create-group's effects.
    async fn take_group_created(
        &self,
        effects: SessionEffects,
    ) -> Result<(Vec<TransportMessage>, PendingStateRef)> {
        self.note_send_drain(&effects.events).await;
        self.surface_co_drained_auto_commits(&effects.publish).await;
        for work in effects.publish {
            if let PublishWork::GroupCreated { welcomes, pending } = work {
                return Ok((welcomes, pending));
            }
        }
        Err(CircleError::Mls(
            "create_group produced no GroupCreated publish work".to_string(),
        ))
    }

    /// Extracts the `GroupEvolution { commit, welcomes, pending }` publish work from
    /// an invite/remove/update's effects, converting the commit to a signed Event.
    async fn take_group_evolution(
        &self,
        effects: SessionEffects,
    ) -> Result<(Event, Vec<TransportMessage>, PendingStateRef)> {
        self.note_send_drain(&effects.events).await;
        self.surface_co_drained_auto_commits(&effects.publish).await;
        for work in effects.publish {
            if let PublishWork::GroupEvolution {
                msg,
                welcomes,
                pending,
            } = work
            {
                let commit = SessionManager::transport_message_to_event(&msg)
                    .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;
                return Ok((commit, welcomes, pending));
            }
        }
        Err(CircleError::Mls(
            "operation produced no GroupEvolution publish work".to_string(),
        ))
    }

    /// Extracts the bare `Proposal { msg }` (`SelfRemove`) transport event.
    async fn take_proposal(&self, effects: SessionEffects) -> Result<Event> {
        self.note_send_drain(&effects.events).await;
        self.surface_co_drained_auto_commits(&effects.publish).await;
        for work in effects.publish {
            if let PublishWork::Proposal { msg } = work {
                return SessionManager::transport_message_to_event(&msg)
                    .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())));
            }
        }
        Err(CircleError::Mls(
            "leave produced no Proposal publish work".to_string(),
        ))
    }

    /// Extracts the `ApplicationMessage { msg }` (location) transport event.
    async fn take_app_message(&self, effects: SessionEffects) -> Result<Event> {
        self.note_send_drain(&effects.events).await;
        self.surface_co_drained_auto_commits(&effects.publish).await;
        for work in effects.publish {
            if let PublishWork::ApplicationMessage { msg } = work {
                return SessionManager::transport_message_to_event(&msg)
                    .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())));
            }
        }
        Err(CircleError::Mls(
            "send produced no ApplicationMessage publish work".to_string(),
        ))
    }
}

/// The circle an engine [`GroupEvent`] is about.
///
/// Exhaustive on purpose: every variant at MDK `e391adc` carries a `group_id`,
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
        | GroupEvent::ForkRecovered { group_id, .. }
        | GroupEvent::CommitRolledBack { group_id, .. }
        | GroupEvent::GroupStateInvalidated { group_id, .. }
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
/// Publish-before-apply (Rule 13): publish `welcome_events`, then confirm
/// `pending`.
pub struct CircleCreationResult {
    /// The created circle.
    pub circle: Circle,
    /// Gift-wrapped Welcome events (engine-produced 1059s) ready to publish.
    pub welcome_events: Vec<GiftWrappedWelcome>,
    /// The pending group-creation state to confirm after ≥1-relay welcome ack.
    pub pending: PendingStateRef,
}

impl std::fmt::Debug for CircleCreationResult {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CircleCreationResult")
            .field("circle", &"<redacted>")
            .field("welcome_events", &bucket(self.welcome_events.len()))
            .field("pending", &self.pending)
            .finish()
    }
}

/// Result of adding members to an existing circle.
///
/// Publish-before-apply (Rule 13): publish `commit_event`, confirm `pending`,
/// then publish `welcome_events`.
pub struct AddMembersResult {
    /// The kind:445 evolution (Add) commit to publish to the circle's relays.
    pub commit_event: Event,
    /// Gift-wrapped Welcome events for the newly added members. Publish only
    /// after `commit_event` is published and `pending` is confirmed.
    pub welcome_events: Vec<GiftWrappedWelcome>,
    /// The pending commit to confirm after ≥1-relay commit ack.
    pub pending: PendingStateRef,
}

impl std::fmt::Debug for AddMembersResult {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AddMembersResult")
            .field("commit_event", &"<redacted>")
            .field("welcome_events", &bucket(self.welcome_events.len()))
            .field("pending", &self.pending)
            .finish()
    }
}

/// A group-evolving commit awaiting publish + confirm (remove / relay update).
pub struct CommitToPublish {
    /// The kind:445 commit to publish to the circle's relays.
    pub commit_event: Event,
    /// The pending commit to confirm after ≥1-relay ack.
    pub pending: PendingStateRef,
}

/// The folded outcome of one engine batch.
///
/// Either a received `kind:445`
/// ([`CircleManager::decrypt_location_collecting_commits`]) or the replay a
/// resolved publish releases ([`CircleManager::confirm_published`],
/// [`CircleManager::publish_failed`], [`CircleManager::finalize_relay_update`]).
///
/// Carries the location-facing results AND any receive-side auto-commit the
/// engine staged (a peer `SelfRemove` eviction). Publish-before-apply (Rule 13):
/// each [`Self::auto_commits`] entry MUST be published to the circle's relays and
/// then confirmed on a ≥1-relay ack, else reported as failed — which for these
/// commits keeps the publish OWED rather than rolling it back
/// ([`CircleManager::owe_removal_publish`]).
#[derive(Default)]
pub struct DecryptedIngest {
    /// The folded location-facing results (locations, joins, updates, …).
    pub results: Vec<LocationMessageResult>,
    /// Receive-side auto-commits the caller must publish then confirm/fail.
    pub auto_commits: Vec<CommitToPublish>,
    /// Bare proposals to publish — no pending ref, nothing to confirm. At MDK
    /// `e391adc` this is the local user's own re-proposed leave, re-minted for
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
            .field("auto_commits", &bucket(self.auto_commits.len()))
            .field("proposals", &bucket(self.proposals.len()))
            .finish()
    }
}

/// Where a batch reaching the publish-resolution fold came from.
///
/// The only thing the fold's inbound observation (R2) and its `GroupEvolution`
/// disposition (a released queued intent, whose durable row the engine has
/// already deleted) need to differ on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BatchOrigin {
    /// The batch `confirm_published` / `publish_failed` returned.
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

/// How many owed commits one redemption pass publishes before it stops.
///
/// The same runaway guard as [`MAX_FOLD_BATCHES`], on the pass that has a
/// publisher. Its disposition is a PAUSE, not a loss: what it does not reach
/// keeps its durable row and its live ref, so the next foreground pass redeems
/// it, and nothing is rolled back.
pub const MAX_REDEMPTION_STEPS: usize = 32;

/// The pending ref a publish item owns, if any.
///
/// Exhaustive so a new `PublishWork` variant carrying a ref cannot slip past the
/// fold's resolved-once rule.
#[deny(clippy::wildcard_enum_match_arm)]
const fn pending_ref_of(item: &PublishWork) -> Option<PendingStateRef> {
    match item {
        PublishWork::AutoPublish { pending, .. }
        | PublishWork::GroupEvolution { pending, .. }
        | PublishWork::GroupCreated { pending, .. } => Some(*pending),
        PublishWork::ApplicationMessage { .. } | PublishWork::Proposal { .. } => None,
    }
}

// Redacts the commit event (whose `h` tag carries the `nostr_group_id`) so a
// stray `{:?}` cannot leak group-id material (Rule 4/6).
impl std::fmt::Debug for CommitToPublish {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CommitToPublish")
            .field("commit_event", &"<redacted>")
            .field("pending", &self.pending)
            .finish()
    }
}

/// What [`CircleManager::repair_epoch_rotation`] did.
///
/// Not a `Result` shape: a declined repair is a normal answer the UI shows, and
/// a deferred one carries work the caller must publish. Only a genuine failure
/// (an unreadable store, an engine rejection that is not about epoch state) is
/// an `Err`.
pub enum RepairRotationOutcome {
    /// The commit is staged. Publish it, then confirm on a ≥1-relay OK-ack or
    /// roll it back (Rule 13) — see [`CircleManager::repair_epoch_rotation`].
    Rotated(CommitToPublish),
    /// A gate declined the repair; nothing was staged and nothing changed.
    Skipped(SkipReason),
    /// The engine QUEUED the rotation instead of staging it, because the circle
    /// is send-gated. The repair ran anyway (the same one a deferred location
    /// send runs), and anything it staged is here: the caller MUST run the
    /// publish → confirm/roll-back ladder over
    /// [`DeferredWork::commits`], or the group stays in `PendingPublish` and
    /// stops sending entirely.
    ///
    /// Carries the same counters as [`CircleError::SendDeferred`], and for the
    /// same reason: `unresolved_inputs == 0` is what a caller reads as "the
    /// next send will encrypt", so it must never be a placeholder.
    Deferred {
        /// Stored rows still gating outbound sends, read AFTER the repair.
        unresolved_inputs: usize,
        /// Queued location intents the repair discarded.
        discarded_intents: usize,
        /// Whether the circle was left with nothing gating and nothing staged.
        repaired: bool,
        /// Publish work the engine staged during the repair (Rule 13).
        work: DeferredWork,
    },
}

// Presence-only: the commit event's `h` tag carries the `nostr_group_id`
// (Rules 4/8). `SkipReason` and `DeferredWork` are already leak-free.
impl std::fmt::Debug for RepairRotationOutcome {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Rotated(_) => f.write_str("Rotated"),
            Self::Skipped(reason) => f.debug_tuple("Skipped").field(reason).finish(),
            Self::Deferred {
                unresolved_inputs,
                discarded_intents,
                repaired,
                work,
            } => f
                .debug_struct("Deferred")
                .field("unresolved_inputs", &bucket(*unresolved_inputs))
                .field("discarded_intents", &bucket(*discarded_intents))
                .field("repaired", repaired)
                .field("work", work)
                .finish(),
        }
    }
}

/// The result of the repair a deferred send performs, before it is shaped into
/// a [`CircleError::SendDeferred`] or a [`RepairRotationOutcome::Deferred`].
struct DeferredSendReport {
    /// Stored rows still gating outbound sends, read AFTER the repair.
    unresolved_inputs: usize,
    /// Queued location intents dropped so a stalled circle cannot accumulate
    /// one stale fix per publish cycle.
    discarded_intents: usize,
    /// Whether the circle was left with nothing gating and nothing staged.
    repaired: bool,
    /// Publish work the engine staged or emitted during the deferral.
    work: DeferredWork,
}

/// Publish work the engine drained during a DEFERRED send, handed to the caller
/// instead of being resolved here.
///
/// # Why this is surfaced rather than resolved
///
/// `cgka-engine`'s `should_queue_outbound_intent` returns true in exactly two
/// situations, and one of them STAGES a commit: when a peer's `SelfRemove`
/// proposal has become due, `stage_due_self_remove_auto_commit` stages the
/// eviction auto-commit and reports "queued" for the send that triggered it.
/// `collect_effects` then drains that commit into the very `SessionEffects` the
/// deferred send returns, carrying a [`PendingStateRef`].
///
/// Both obvious dispositions are wrong (Rule 13):
///
/// - **Confirming** applies a commit no relay has acked.
/// - **Rolling back** (`publish_failed`) looks safe and is not: the engine
///   removes the in-memory `scheduled_self_remove_auto_commits` entry *before*
///   staging and `do_publish_failed` does not re-arm it, while a redelivery of
///   the proposal short-circuits to `Buffered` without rescheduling. The
///   eviction is then never re-staged and the leaver stays in the circle
///   forever.
/// - **Dropping it** silently leaves the group in `PendingPublish`, where every
///   later send fails the engine's "send requires Stable" gate — a total send
///   blackout.
///
/// So the only correct disposition is the one the receive path already uses:
/// hand the caller the publish → ack → `confirm_published` /
/// [`CircleManager::publish_failed`] ladder it already runs for
/// [`DecryptedIngest::auto_commits`] — where the fail rung does NOT roll a
/// removal-bearing commit back but keeps it owed
/// ([`CircleManager::owe_removal_publish`]), which is what makes "rolling back
/// is never a disposition" true of the Dart planes too.
#[derive(Default)]
pub struct DeferredWork {
    /// Staged commits: publish each, then [`CircleManager::confirm_published`]
    /// on a ≥1-relay ack, or [`CircleManager::publish_failed`] on failure.
    pub commits: Vec<CommitToPublish>,
    /// Bare proposals the engine emitted (no staged state, nothing to confirm).
    /// Publish-or-lose, but recoverable: a re-proposed `SelfRemove` is driven by
    /// the durable `LeaveRequest`, so a later convergence pass re-emits it.
    pub proposals: Vec<Event>,
}

impl DeferredWork {
    /// Whether the engine handed back nothing to publish.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.commits.is_empty() && self.proposals.is_empty()
    }
}

// Presence-only: a proposal event's `h` tag carries the `nostr_group_id` and its
// content is group ciphertext, so only counts are printed (Rules 4/6/8).
impl std::fmt::Debug for DeferredWork {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DeferredWork")
            .field("commits", &bucket(self.commits.len()))
            .field("proposals", &bucket(self.proposals.len()))
            .finish()
    }
}

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

        let conn = rusqlite::Connection::open(temp_dir.path().join("circles.db")).unwrap();
        conn.execute_batch("ALTER TABLE circles RENAME TO circles_x")
            .unwrap();
        drop(conn);

        let err = manager
            .repair_epoch_rotation(&group_id, now_secs())
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
        let conn = rusqlite::Connection::open(temp_dir.path().join("circles.db")).unwrap();
        conn.execute_batch("DROP TABLE circle_health").unwrap();
        drop(conn);

        let err = manager
            .repair_epoch_rotation(&group_id, now_secs())
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
        }
    }

    /// A real two-party MLS circle established over the Dark Matter stack.
    struct TwoPartyCircle {
        alice: CircleManager,
        _alice_dir: TempDir,
        alice_keys: Keys,
        bob: CircleManager,
        _bob_dir: TempDir,
        bob_keys: Keys,
        mls_group_id: GroupId,
        nostr_group_id: [u8; 32],
        relays: Vec<String>,
    }

    /// Establishes a two-party circle: Alice creates with Bob's `KeyPackage`,
    /// confirms the pending create (publish-before-apply), then Bob holds and
    /// accepts the engine-produced gift-wrapped (1059) welcome.
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
        };

        let config = CircleConfig::new("Test Circle").with_relays(relays.clone());
        let creation = alice
            .create_circle(&alice_keys, vec![bob_member], &config, &relays)
            .await
            .expect("create two-party circle");
        alice
            .confirm_published(creation.pending)
            .await
            .expect("confirm create");

        let mls_group_id = creation.circle.mls_group_id.clone();
        let nostr_group_id = creation.circle.nostr_group_id;

        let welcome = creation.welcome_events.first().expect("one welcome");
        bob.process_gift_wrapped_invitation(&bob_keys, &welcome.event)
            .await
            .expect("bob holds welcome");
        bob.accept_invitation(&welcome.event.id)
            .await
            .expect("bob accepts welcome");

        TwoPartyCircle {
            alice,
            _alice_dir: alice_dir,
            alice_keys,
            bob,
            _bob_dir: bob_dir,
            bob_keys,
            mls_group_id,
            nostr_group_id,
            relays,
        }
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
        let conn = rusqlite::Connection::open(data_dir.join("session.sqlite")).expect("open");
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
            .create_circle(keys, vec![member], &config, &relays)
            .await
            .expect("create circle");
        manager
            .confirm_published(creation.pending)
            .await
            .expect("confirm create");
        (creation.circle.mls_group_id.clone(), member_hex)
    }

    #[tokio::test]
    async fn a_staged_add_is_never_written_to_the_directory() {
        // The hazard §5.2 names: `session.members()` returns the engine's
        // OPTIMISTIC PROJECTION while a commit is staged, so the invitee is in
        // the roster before any relay has seen the commit — and branch
        // selection can still withdraw it. The gate, not the roster, is what
        // keeps that person off disk.
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let relays = vec!["wss://relay.test.com".to_string()];
        let manager = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();

        let member = make_member_with_relays(relays.clone(), vec![]).await;
        let member_hex = member.key_package_event.pubkey.to_hex();
        let config = CircleConfig::new("Staged").with_relays(relays.clone());
        let creation = manager
            .create_circle(&keys, vec![member], &config, &relays)
            .await
            .expect("create circle");
        let group_id = creation.circle.mls_group_id.clone();

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
        assert!(
            directory_of(&manager).is_empty(),
            "nothing may be written from a projection"
        );

        manager
            .confirm_published(creation.pending)
            .await
            .expect("confirm create");
        assert!(manager
            .reconcile_member_directory(DirectoryReconcile::Rewrite, DIR_NOW)
            .await
            .unwrap());
        assert_eq!(
            directory_of(&manager),
            vec![(member_hex, DirectoryTier::Current)],
            "and everything may be written once the commit is applied"
        );
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
            .expect("non-admin bob may propose SelfRemove");
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
            .remove_members(
                &circle.mls_group_id,
                &[circle.bob_keys.public_key().to_hex()],
            )
            .await
            .expect("stage the commit that takes bob out");
        circle
            .alice
            .confirm_published(commit.pending)
            .await
            .expect("confirm");
        circle
            .bob
            .decrypt_location(&commit.commit_event)
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
        // ends in `replay_buffered_messages` (`cgka-engine/src/publish.rs:255`),
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
        let relays = vec!["wss://relay.test.com".to_string()];
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

        // A second circle stuck mid-publish: from here every pass defers.
        let staged = manager
            .create_circle(
                &keys,
                vec![make_member_with_relays(relays.clone(), vec![]).await],
                &CircleConfig::new("Staged").with_relays(relays.clone()),
                &relays,
            )
            .await
            .expect("create circle");
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
        manager
            .storage
            .delete_circle(&staged.circle.mls_group_id)
            .unwrap();
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
        // §5.3's second detector. An `Unrecoverable` group is still "live", so
        // `converged_member_pubkeys` answers `Ok` with the roster frozen at its
        // last stable epoch — which would re-stamp those people `Current` with
        // the never-purge sentinel on every pass, so they could never age out
        // and a removal there could never be observed. `EpochState` has no
        // accessor and is never persisted, so the event that announces it is the
        // only signal there is; it is fed here directly for the same reason.
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let manager = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();
        // One circle per way the news can arrive: the receive planes hold raw
        // engine events, the poll path holds folded results, and a group missed
        // by either entry point keeps its members pinned for ever.
        let (event_gid, via_events_hex) = create_confirmed_circle(&manager, &keys, "Doomed").await;
        let (result_gid, via_results_hex) =
            create_confirmed_circle(&manager, &keys, "Also doomed").await;
        assert!(manager
            .reconcile_member_directory(DirectoryReconcile::Rewrite, DIR_NOW)
            .await
            .unwrap());
        for member_hex in [&via_events_hex, &via_results_hex] {
            assert_eq!(
                directory_row(&manager, member_hex).unwrap().purge_after,
                crate::circle::DIRECTORY_PURGE_NEVER,
                "precondition: a current co-member is pinned against every clock"
            );
        }

        assert_eq!(
            manager.directory_verdict_for_events(&[GroupEvent::GroupUnrecoverable {
                group_id: event_gid,
            }]),
            None,
            "the event itself asks for no pass — the group it names is now unreadable"
        );
        assert_eq!(
            manager.directory_verdict_for_results(&[LocationMessageResult::Unrecoverable {
                group_id: result_gid,
            }]),
            None
        );

        assert!(manager
            .reconcile_member_directory(DirectoryReconcile::Rewrite, DIR_NOW)
            .await
            .unwrap());
        for member_hex in [&via_events_hex, &via_results_hex] {
            let row = directory_row(&manager, member_hex).expect("still a recent contact");
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

        let removal = circle
            .alice
            .remove_members(&circle.mls_group_id, std::slice::from_ref(&bob_hex));
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
        // produces up to M−1 competing auto-commits, and `confirm_published` is
        // awaited inline from Dart, so an un-coalesced walk lands on the visible
        // latency of Add / Remove / Create Member.
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

        let commit = circle
            .alice
            .remove_members(&circle.mls_group_id, std::slice::from_ref(&bob_hex))
            .await
            .expect("stage removal");

        assert!(
            directory_row(&circle.alice, &bob_hex).is_none(),
            "the removal must not wait for a relay ack, and must not age out"
        );
        drop(commit);
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
            .remove_members(
                &circle.mls_group_id,
                &[circle.bob_keys.public_key().to_hex()],
            )
            .await
            .expect("stage removal");
        circle
            .alice
            .confirm_published(commit.pending)
            .await
            .expect("confirm removal");
        circle
            .bob
            .decrypt_location(&commit.commit_event)
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
                .encrypt_location(
                    &circle.mls_group_id,
                    &circle.bob_keys.public_key(),
                    &LocationMessage::new(1.0, 2.0),
                    60,
                )
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

        let results = circle.alice.decrypt_location(&live).await.unwrap();
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
        let commit = circle
            .alice
            .remove_members(&circle.mls_group_id, std::slice::from_ref(&bob_hex))
            .await
            .expect("stage removal");
        circle
            .alice
            .confirm_published(commit.pending)
            .await
            .expect("confirm removal");
        assert!(directory_row(&circle.alice, &bob_hex).is_none());

        circle
            .alice
            .decrypt_location(&held_back)
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
                }],
                &config,
                &relays,
            )
            .await
            .expect("create circle");
        alice
            .confirm_published(creation.pending)
            .await
            .expect("confirm create");
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
    async fn welcome_delivery_uses_creator_inbox_as_tier3() {
        let dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(dir.path(), &alice_keys).unwrap();

        // Member advertises NO relays (empty inbox + empty NIP-65), forcing the
        // cascade down to the creator's own inbox relays (tier 3).
        let member = make_member_with_relays(vec![], vec![]).await;
        let config = CircleConfig::new("Tier3 Circle")
            .with_relays(vec!["wss://group.example.com".to_string()]);
        let creator_inbox = vec!["wss://creator-inbox.example.com".to_string()];

        let result = alice
            .create_circle(&alice_keys, vec![member], &config, &creator_inbox)
            .await
            .expect("creation should succeed using the creator's inbox as tier 3");

        assert_eq!(result.welcome_events.len(), 1);
        assert_eq!(result.welcome_events[0].recipient_relays, creator_inbox);
        for d in crate::circle::PRODUCTION_DEFAULT_RELAYS {
            assert!(
                !result.welcome_events[0]
                    .recipient_relays
                    .iter()
                    .any(|r| r.starts_with(d)),
                "welcome delivery must never fall back to a public default ({d})"
            );
        }
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
            .create_circle(&alice_keys, vec![member], &config, &[])
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
    // Pins the exact source of the value the circle-details sheet's
    // `circleDetailsRelaysNote` describes. The Dart caller
    // (`NostrCircleService.createCircle`) passes `relays` as the UNION of the
    // invitees' own published `KeyPackage` relays (their kind 10050 inbox
    // lists) — never the creator's own relay preferences — and only when that
    // union is completely empty does `create_circle` substitute anything, in
    // two tiers: the creator's LOCALLY STORED inbox relays first, then the
    // hard-coded production default list. These three tests keep that whole
    // chain honest so the Dart-side copy, which now names both fallbacks,
    // cannot silently drift from what the code actually does.

    #[tokio::test]
    async fn create_circle_relays_are_the_passed_relays_not_the_creator_inbox() {
        // Mirrors the common case: at least one invitee published a relay, so
        // Dart's `circleRelays` union is non-empty and is passed straight
        // through. The creator's OWN configured inbox relay is seeded to a
        // DIFFERENT URL, so a passing assertion can only be explained by the
        // passed-in value winning — never by a fallback to storage.
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
            .create_circle(&alice_keys, vec![member], &config, &[])
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
             invitee already supplied one"
        );
    }

    #[tokio::test]
    async fn create_circle_falls_back_to_stored_creator_inbox_when_relays_empty() {
        // No invitee supplied a relay (config.relays is empty, matching Dart
        // passing memberRelays == []). The fallback reads the creator's inbox
        // relays from LOCAL STORAGE — not from the `creator_fallback_relays`
        // parameter, which is deliberately set to a DIFFERENT URL here so a
        // passing assertion can only be explained by the storage read, never
        // by an accidental echo of that parameter.
        const STORED_INBOX_RELAY: &str = "wss://creator-inbox-storage.example.com";
        const WELCOME_TIER3_PARAM_RELAY: &str = "wss://different-tier3-param.example.com";

        let dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(dir.path(), &alice_keys).unwrap();
        alice
            .add_user_relay(
                STORED_INBOX_RELAY,
                crate::circle::relay_prefs::RelayType::Inbox,
            )
            .unwrap();

        let member = make_member_with_relays(vec![], vec![]).await; // no relays
        let config = CircleConfig::new("Fallback Circle"); // relays left empty

        let creation = alice
            .create_circle(
                &alice_keys,
                vec![member],
                &config,
                &[WELCOME_TIER3_PARAM_RELAY.to_string()],
            )
            .await
            .expect("create using the stored creator inbox as the group relay set");

        assert_eq!(
            creation.circle.relays,
            vec![STORED_INBOX_RELAY.to_string()],
            "an empty passed-in relay set must fall back to the creator's \
             LOCALLY STORED inbox relays"
        );
        assert_ne!(
            creation.circle.relays,
            vec![WELCOME_TIER3_PARAM_RELAY.to_string()],
            "the group relay set must come from storage, not from the \
             creator_fallback_relays parameter"
        );
    }

    #[tokio::test]
    async fn create_circle_falls_back_to_default_relays_when_relays_and_creator_inbox_empty() {
        // Neither the passed-in relays nor the creator's stored inbox has
        // anything — the deepest fallback tier, production DEFAULT_RELAYS.
        let dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(dir.path(), &alice_keys).unwrap();
        // Deliberately never seeded / never called add_user_relay: the
        // creator's stored inbox relay list stays empty.

        let member = make_member_with_relays(vec![], vec![]).await; // no relays
        let config = CircleConfig::new("Default Fallback Circle"); // relays empty
        let welcome_tier3 = vec!["wss://tier3.example.com".to_string()];

        let creation = alice
            .create_circle(&alice_keys, vec![member], &config, &welcome_tier3)
            .await
            .expect("create using the production default relays");

        assert_eq!(
            creation.circle.relays,
            crate::circle::types::default_relays(),
            "both fallback tiers empty must land on the production default relays"
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
            .create_circle(&alice_keys, vec![member], &config, &relays)
            .await
            .expect("create");

        assert_eq!(
            creation.circle.display_name, "Family",
            "create_circle must hand back the sanitized name it stored, not the \
             raw one it was handed"
        );
    }

    // ── Create rollback / ghost-row cleanup (F2/F3) ──────────────────────────

    #[tokio::test]
    async fn create_then_publish_failed_removes_orphan_circle_row() {
        // F2: create succeeds (deliverable member) and eagerly persists a circle
        // row; then all welcomes zero-ack and the caller calls `publish_failed`.
        // The circle row MUST be rolled back — no ghost circle backed by an
        // unconfirmed group survives.
        let relays = vec!["wss://relay.test.com".to_string()];
        let dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(dir.path(), &alice_keys).unwrap();

        let member = make_member_with_relays(relays.clone(), vec![]).await;
        let config = CircleConfig::new("Rollback Circle").with_relays(relays.clone());
        let creation = alice
            .create_circle(&alice_keys, vec![member], &config, &relays)
            .await
            .expect("create");

        // Before rollback the row exists (eager persistence is unchanged).
        assert_eq!(alice.get_circles().await.unwrap().len(), 1);

        alice
            .publish_failed(creation.pending)
            .await
            .expect("rollback the unconfirmed create");

        assert!(
            alice.get_circles().await.unwrap().is_empty(),
            "publish_failed on a create must remove the orphan circle row"
        );
    }

    #[tokio::test]
    async fn create_then_confirm_persists_exactly_one_circle() {
        // The happy path is unchanged: a confirmed create keeps exactly one row.
        let relays = vec!["wss://relay.test.com".to_string()];
        let dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(dir.path(), &alice_keys).unwrap();

        let member = make_member_with_relays(relays.clone(), vec![]).await;
        let config = CircleConfig::new("Confirmed Circle").with_relays(relays.clone());
        let creation = alice
            .create_circle(&alice_keys, vec![member], &config, &relays)
            .await
            .expect("create");
        assert_eq!(alice.get_circles().await.unwrap().len(), 1);

        alice
            .confirm_published(creation.pending)
            .await
            .expect("confirm");
        assert_eq!(
            alice.get_circles().await.unwrap().len(),
            1,
            "a confirmed create persists exactly one circle"
        );

        // A stray publish_failed after confirm must NOT delete the now-live row
        // (the create binding was dropped on confirm). It errors on the unknown
        // pending; the circle survives.
        let _ = alice.publish_failed(creation.pending).await;
        assert_eq!(
            alice.get_circles().await.unwrap().len(),
            1,
            "a confirmed circle must survive a stray publish_failed"
        );
    }

    #[tokio::test]
    async fn create_route_error_rolls_back_pending_and_leaves_no_row() {
        // F3: exercise the internal helper directly so `route_welcomes_with_cascade`
        // fails AFTER the MLS group + storage rows are staged (a member with no
        // delivery relay and no creator fallback). The post-stage error path MUST
        // roll the pending back and leave NO orphan circle row.
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
            .create_circle_with_config(&[member], kp_events, mls_config, &config, &[])
            .await;
        assert!(
            matches!(result, Err(CircleError::MissingWelcomeRelays)),
            "welcome routing must fail closed for an undeliverable member"
        );

        assert!(
            alice.get_circles().await.unwrap().is_empty(),
            "a post-stage route error must roll back the ghost circle row (F2/F3)"
        );
        // The create binding was consumed by the rollback, so nothing lingers to
        // re-delete: a fresh, deliverable create then works cleanly.
        let ok_member =
            make_member_with_relays(vec!["wss://relay.test.com".to_string()], vec![]).await;
        let ok_config = CircleConfig::new("Recovered Circle")
            .with_relays(vec!["wss://relay.test.com".to_string()]);
        alice
            .create_circle(
                &alice_keys,
                vec![ok_member],
                &ok_config,
                &["wss://relay.test.com".to_string()],
            )
            .await
            .expect("a subsequent create is unaffected by the prior rollback");
        assert_eq!(alice.get_circles().await.unwrap().len(), 1);
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
        };
        let config = CircleConfig::new("Test Circle").with_relays(relays.clone());
        let creation = alice
            .create_circle(&alice_keys, vec![bob_member], &config, &relays)
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
            .create_circle(&alice_keys, vec![bob_member], &config, &circle_relays)
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

        let update = tp
            .alice
            .update_circle_relays(&tp.mls_group_id, &new_relays)
            .await
            .expect("admin must be allowed to update relays");

        // Publish-before-apply: before finalize, the admin's app row is unchanged.
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

        tp.alice
            .finalize_relay_update(update.pending, &tp.mls_group_id)
            .await
            .expect("admin finalize");

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
            .decrypt_location(&update.commit_event)
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
            .update_circle_relays(&tp.mls_group_id, &new_relays)
            .await
            .expect("admin replaces the relay set");
        tp.alice
            .finalize_relay_update(update.pending, &tp.mls_group_id)
            .await
            .expect("admin finalize");

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
            .decrypt_location(&update.commit_event)
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
            .update_circle_relays(&tp.mls_group_id, &["wss://relay2.test.com".to_string()])
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
            tp.alice.update_circle_relays(&tp.mls_group_id, &[]).await,
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
        let many: Vec<String> = (0..=CircleManager::MAX_CIRCLE_RELAYS)
            .map(|i| format!("wss://relay{i}.test.com"))
            .collect();
        assert!(many.len() > CircleManager::MAX_CIRCLE_RELAYS);
        assert!(matches!(
            tp.alice.update_circle_relays(&tp.mls_group_id, &many).await,
            Err(CircleError::InvalidData(_))
        ));
    }

    #[tokio::test]
    async fn update_circle_relays_rejects_plaintext_ws() {
        let tp = setup_two_party_circle().await;
        // Shares `normalize_url` with the user relay list, so the rejection is
        // the typed, user-presentable one rather than the opaque bucket.
        let err = tp
            .alice
            .update_circle_relays(&tp.mls_group_id, &["ws://relay.test.com".to_string()])
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
    // DELETED-WITH-SUBJECT: `resync_never_overwrites_nonempty_relays_with_empty`
    // drove the hazard via `mdk.update_relays(&[])` — the UNVALIDATED empty relay
    // update. The session's `validate_group_relays` now rejects an empty set at
    // the source (both `update_relays` and `create_group`), so the engine never
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
            .propose_admin_handoff(&tp.mls_group_id, &tp.bob_keys.public_key())
            .await
            .expect("promote successor");
        tp.alice
            .confirm_published(promote.pending)
            .await
            .expect("confirm promote");
        tp.bob
            .decrypt_location(&promote.commit_event)
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
            .propose_self_demote(&tp.mls_group_id)
            .await
            .expect("self demote");
        tp.alice
            .confirm_published(demote.pending)
            .await
            .expect("confirm demote");
        tp.bob
            .decrypt_location(&demote.commit_event)
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
            .expect("a demoted admin may finally SelfRemove");
    }

    #[tokio::test]
    async fn propose_self_demote_by_sole_admin_is_rejected() {
        // The group must never be left admin-less: demoting without first
        // promoting a successor fails closed rather than emitting an empty
        // admin policy (which would brick every future membership commit).
        let tp = setup_two_party_circle().await;
        let err = tp
            .alice
            .propose_self_demote(&tp.mls_group_id)
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
    async fn a_sole_admin_repairs_a_quiet_circle_and_the_peer_applies_the_commit() {
        let tp = setup_two_party_circle().await;
        let before = tp
            .alice
            .session()
            .epoch(&tp.mls_group_id)
            .await
            .expect("alice epoch");

        let RepairRotationOutcome::Rotated(commit) = tp
            .alice
            .repair_epoch_rotation(&tp.mls_group_id, past_every_rotation_window())
            .await
            .expect("the repair must not fail for the sole admin of a quiet circle")
        else {
            panic!("the sole admin of a quiet circle must stage a rotation");
        };

        tp.alice
            .confirm_published(commit.pending)
            .await
            .expect("confirm the rotation on a relay ack");
        tp.bob
            .decrypt_location(&commit.commit_event)
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
        // The commit is byte-identical policy, so the admin set is unchanged —
        // this is a ratchet reset, not a membership or permission change.
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

        let RepairRotationOutcome::Rotated(commit) = tp
            .alice
            .repair_epoch_rotation(&tp.mls_group_id, past_every_rotation_window())
            .await
            .expect("repair")
        else {
            panic!("expected a staged rotation");
        };
        tp.alice
            .publish_failed(commit.pending)
            .await
            .expect("zero acks roll the rotation back");

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
            .encrypt_location(
                &tp.mls_group_id,
                &tp.alice_keys.public_key(),
                &LocationMessage::new(51.5, -0.12),
                60,
            )
            .await
            .expect("a rolled-back rotation must not gate the next location send");
        assert_eq!(ngid, tp.nostr_group_id);
        let results = tp
            .bob
            .decrypt_location(&event)
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
        // A byte-identical admin policy diffs to nothing, so neither the author
        // nor the peer may synthesize a kind-1210 "admins changed" row. A phantom
        // one would tell every member that somebody's permissions changed when
        // nothing did — a documentation-accuracy failure the user reads directly.
        let tp = setup_two_party_circle().await;
        let RepairRotationOutcome::Rotated(commit) = tp
            .alice
            .repair_epoch_rotation(&tp.mls_group_id, past_every_rotation_window())
            .await
            .expect("repair")
        else {
            panic!("expected a staged rotation");
        };

        // Author side: the session's own confirm effects, unfolded.
        let author = tp
            .alice
            .session()
            .confirm_published(commit.pending)
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

        // Peer side: the raw ingest effects, before any folding.
        let peer = tp
            .bob
            .session()
            .process_event(&commit.commit_event)
            .await
            .expect("bob ingests");
        let peer = peer.ingested().expect("the commit reached the engine");
        assert!(
            !peer
                .effects
                .events
                .iter()
                .any(|e| matches!(e, GroupEvent::GroupStateChanged { .. })),
            "the peer's ingest must emit no GroupStateChanged: {:?}",
            peer.effects.events
        );
        assert!(
            peer.effects
                .events
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
    async fn repair_rotation_outcome_debug_redacts_the_staged_work() {
        // `Rotated` wraps a `CommitToPublish` whose commit event's `h` tag is the
        // circle's `nostr_group_id`; a derived `Debug` would print it through any
        // stray log line (Rules 4/8). Structural, so a later payload addition has
        // to face this assertion.
        assert_eq!(
            format!(
                "{:?}",
                RepairRotationOutcome::Skipped(SkipReason::NotSoleAdmin)
            ),
            "Skipped(NotSoleAdmin)"
        );
        let deferred = RepairRotationOutcome::Deferred {
            unresolved_inputs: 2,
            discarded_intents: 1,
            repaired: false,
            work: DeferredWork {
                commits: vec![],
                proposals: vec![leaky_proposal()],
            },
        };
        crate::assert_debug_redacted!(
            &deferred,
            "RepairRotationOutcome",
            marker = "Deferred",
            &[PROPOSAL_CONTENT, PROPOSAL_H_TAG]
        );
        // Counts are bucketed: how many rows gate a circle is a per-circle
        // magnitude, and the bucket carries the triage signal (Rule 15).
        assert_eq!(
            format!("{deferred:?}"),
            "Deferred { unresolved_inputs: \"2-4\", discarded_intents: \"1\", repaired: false, \
             work: DeferredWork { commits: \"0\", proposals: \"1\" } }"
        );
        let work = DeferredWork {
            commits: vec![],
            proposals: vec![leaky_proposal()],
        };
        crate::assert_debug_redacted!(&work, "DeferredWork", &[PROPOSAL_CONTENT, PROPOSAL_H_TAG]);
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
            auto_commits: vec![],
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
            "DecryptedIngest { results: \"1\", auto_commits: \"0\", proposals: \"1\" }"
        );
    }

    #[tokio::test]
    async fn publish_work_debug_redacts_the_circle_it_belongs_to() {
        // These three are what the FFI logs after a create / an add / a
        // handoff, and each wraps a real event whose `h` tag is the circle's
        // `nostr_group_id` and whose welcomes name the invitee.
        let relays = vec!["wss://relay.test.com".to_string()];
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let manager = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();

        let first = make_member_with_relays(relays.clone(), vec![]).await;
        let first_hex = first.key_package_event.pubkey.to_hex();
        let config = CircleConfig::new("Bramble Family").with_relays(relays.clone());
        let creation: CircleCreationResult = manager
            .create_circle(&keys, vec![first], &config, &relays)
            .await
            .expect("create circle");
        let group_hex = hex::encode(creation.circle.nostr_group_id);
        let needles = [
            "Bramble Family",
            "wss://relay.test.com",
            first_hex.as_str(),
            group_hex.as_str(),
        ];
        crate::assert_debug_redacted!(&creation, "CircleCreationResult", &needles);
        let group_id = creation.circle.mls_group_id.clone();
        manager
            .confirm_published(creation.pending)
            .await
            .expect("confirm create");

        let second = make_member_with_relays(relays.clone(), vec![]).await;
        let second_hex = second.key_package_event.pubkey.to_hex();
        let added: AddMembersResult = manager
            .add_members_with_welcomes(&keys, &group_id, vec![second], &relays)
            .await
            .expect("add a member");
        crate::assert_debug_redacted!(
            &added,
            "AddMembersResult",
            &[
                "Bramble Family",
                "wss://relay.test.com",
                second_hex.as_str(),
                group_hex.as_str(),
            ]
        );
        manager
            .confirm_published(added.pending)
            .await
            .expect("confirm add");

        let handoff: CommitToPublish = manager
            .propose_admin_handoff(
                &group_id,
                &PublicKey::parse(&first_hex).expect("hex pubkey"),
            )
            .await
            .expect("stage a handoff commit");
        crate::assert_debug_redacted!(&handoff, "CommitToPublish", &needles);
    }

    #[tokio::test]
    async fn a_non_admin_is_declined_the_repair() {
        // The honest limit of this unit, pinned: a stuck NON-admin has no
        // self-service repair, because every commit-producing intent is
        // admin-gated. It must be told so, not handed an opaque engine error.
        let tp = setup_two_party_circle().await;
        assert!(matches!(
            tp.bob
                .repair_epoch_rotation(&tp.mls_group_id, past_every_rotation_window())
                .await
                .expect("a declined repair is an outcome, not a failure"),
            RepairRotationOutcome::Skipped(SkipReason::NotSoleAdmin)
        ));
    }

    #[tokio::test]
    async fn a_group_with_a_commit_already_staged_declines_the_repair_as_busy() {
        // Gate 2's interim mechanism, end to end. `AccountDeviceSession` exposes
        // no epoch-state getter at MDK `e391adc`, so a non-`Stable` group is only
        // discoverable by attempting the send: the engine answers
        // `InvalidTransition { from: "PendingPublish", .. }`, which
        // `SessionManager::update_admin_policy` maps to the typed
        // `NostrError::EpochNotStable` BEFORE `map_mls_err` stringifies it.
        // Reaching that arm requires a real staged commit, which is what this
        // test manufactures — the token-set tests pin the classifier, and this
        // pins that the classifier is actually on the path.
        let tp = setup_two_party_circle().await;
        let staged = tp
            .alice
            .propose_admin_handoff(&tp.mls_group_id, &tp.bob_keys.public_key())
            .await
            .expect("stage a handoff commit and leave it unconfirmed");

        assert!(
            matches!(
                tp.alice
                    .repair_epoch_rotation(&tp.mls_group_id, past_every_rotation_window())
                    .await
                    .expect("a busy group is a typed outcome, never an opaque MLS error"),
                RepairRotationOutcome::Skipped(SkipReason::EpochNotStable)
            ),
            "a group with a commit already staged must decline the repair as busy"
        );

        // Control, so the assertion above is attributable to the epoch state and
        // not to some other gate: resolving the staged commit makes the very same
        // call succeed.
        tp.alice
            .publish_failed(staged.pending)
            .await
            .expect("roll the staged handoff back");
        let RepairRotationOutcome::Rotated(commit) = tp
            .alice
            .repair_epoch_rotation(&tp.mls_group_id, past_every_rotation_window())
            .await
            .expect("outcome")
        else {
            panic!("once the group is Stable again the repair must go through");
        };
        tp.alice
            .publish_failed(commit.pending)
            .await
            .expect("leave nothing staged");
    }

    #[tokio::test]
    async fn a_confirmed_repair_records_the_rate_limit_and_a_rolled_back_one_does_not() {
        // Publish-before-apply applied to bookkeeping: a repair no relay accepted
        // reset nobody's ratchet, so it must not lock the user out of retrying
        // for a day — while a confirmed one must.
        let tp = setup_two_party_circle().await;
        let now = past_every_rotation_window();

        let RepairRotationOutcome::Rotated(rolled_back) = tp
            .alice
            .repair_epoch_rotation(&tp.mls_group_id, now)
            .await
            .expect("repair")
        else {
            panic!("expected a staged rotation");
        };
        tp.alice
            .publish_failed(rolled_back.pending)
            .await
            .expect("roll the rotation back");
        assert_eq!(
            rotation_state(&tp.alice, &tp.nostr_group_id).last_rotation_at_ms,
            None,
            "a rolled-back repair must spend nothing"
        );

        let RepairRotationOutcome::Rotated(confirmed) = tp
            .alice
            .repair_epoch_rotation(&tp.mls_group_id, now)
            .await
            .expect("the rolled-back repair must be immediately retryable")
        else {
            panic!("expected a second staged rotation");
        };
        let wall_clock_before_confirm = chrono::Utc::now().timestamp_millis();
        tp.alice
            .confirm_published(confirmed.pending)
            .await
            .expect("confirm");
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
                .repair_epoch_rotation(&tp.mls_group_id, now)
                .await
                .expect("outcome"),
            RepairRotationOutcome::Skipped(SkipReason::RotatedRecently)
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

        let RepairRotationOutcome::Rotated(commit) = tp
            .alice
            .repair_epoch_rotation(&tp.mls_group_id, past_every_rotation_window())
            .await
            .expect("repair")
        else {
            panic!("expected a staged rotation");
        };
        tp.alice
            .confirm_published(commit.pending)
            .await
            .expect("confirm");
        tp.bob
            .decrypt_location(&commit.commit_event)
            .await
            .expect("bob ingests");

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
                .repair_epoch_rotation(&tp.mls_group_id, now_secs())
                .await
                .expect("outcome"),
            RepairRotationOutcome::Skipped(SkipReason::RecentEpochChange)
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
                .repair_epoch_rotation(&tp.mls_group_id, now)
                .await
                .expect("outcome"),
            RepairRotationOutcome::Skipped(SkipReason::RecentInboundTraffic)
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
            .encrypt_location(
                &tp.mls_group_id,
                &tp.bob_keys.public_key(),
                &LocationMessage::new(48.85, 2.35),
                60,
            )
            .await
            .expect("bob sends");
        tp.alice
            .decrypt_location(&event)
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
                .repair_epoch_rotation(&tp.mls_group_id, now)
                .await
                .expect("outcome"),
            RepairRotationOutcome::Skipped(SkipReason::RecentInboundTraffic)
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
            .expect("bob proposes to leave");
        tp.alice
            .session()
            .process_event(&proposal)
            .await
            .expect("alice ingests the proposal");

        assert!(matches!(
            tp.alice
                .repair_epoch_rotation(&tp.mls_group_id, past_every_rotation_window())
                .await
                .expect("outcome"),
            RepairRotationOutcome::Skipped(SkipReason::PendingProposal)
        ));
    }

    /// Leaves Alice — still the circle's sole admin — one epoch BEHIND Bob with
    /// a real future-epoch application row in her store, which is the one shape
    /// the engine deliberately never resolves and therefore the one that gates
    /// every send for the circle.
    ///
    /// The divergence is produced the way production produces it: a commit the
    /// relays actually accepted (so Bob applied it) that this device never
    /// learned of and rolled back — `docs/EPOCH_ROTATION_REPAIR_PLAN.md` §2,
    /// the cross-restart twin fork. A rolled-back rotation spends no rate limit
    /// and records no epoch change, so every rotation gate is still open
    /// afterwards.
    async fn send_gated_sole_admin_circle() -> TwoPartyCircle {
        let tp = setup_two_party_circle().await;
        let RepairRotationOutcome::Rotated(delivered) = tp
            .alice
            .repair_epoch_rotation(&tp.mls_group_id, past_every_rotation_window())
            .await
            .expect("repair")
        else {
            panic!("expected a staged rotation");
        };
        tp.bob
            .decrypt_location(&delivered.commit_event)
            .await
            .expect("bob applies the commit the relays accepted");
        tp.alice
            .publish_failed(delivered.pending)
            .await
            .expect("alice never learned of the ack and rolls back");

        let ahead = tp
            .bob
            .session()
            .epoch(&tp.mls_group_id)
            .await
            .expect("bob epoch");
        assert_eq!(
            ahead,
            tp.alice
                .session()
                .epoch(&tp.mls_group_id)
                .await
                .expect("alice epoch")
                + 1,
            "fixture: bob must be exactly one epoch ahead of the sole admin"
        );

        tp.bob
            .encrypt_location(
                &tp.mls_group_id,
                &tp.bob_keys.public_key(),
                &LocationMessage::new(9.0, 9.0),
                60,
            )
            .await
            .expect("bob sends at the higher epoch");
        let row = tp
            .bob
            .session()
            .stored_convergence_input_for_test(
                &tp.mls_group_id,
                crate::nostr::mls::types::OpenMlsContentKind::Application,
                ahead,
            )
            .await
            .expect("bob's own row at the higher epoch");
        tp.alice
            .session()
            .stage_convergence_input_for_test(
                &row,
                crate::nostr::mls::types::MessageState::Retryable,
                0,
            )
            .await
            .expect("alice stores the future-epoch row she could not decrypt");
        tp
    }

    #[tokio::test]
    async fn a_rotation_racing_a_departure_at_one_epoch_resolves_to_the_rotation() {
        // What ACTUALLY closes the same-epoch race for a proposal that reached a
        // peer but not us — the engine, not gate 4's clock.
        //
        // Both commits carry the same `source_epoch`, so `CommitOrderingKey::cmp`
        // breaks the tie on `priority`, and the LOWEST key wins
        // (`fork_recovery.rs`: a candidate `>=` the incumbent loses). The repair
        // is an `UpdateAppComponents(admin-policy.v1)`, which
        // `commit_ordering_priority_for_staged` classifies `Privileged`; a
        // SelfRemove-only auto-commit is `Ordinary`, and `Privileged` is declared
        // first so it sorts below. The rotation therefore wins on EVERY replica,
        // and the departure is re-driven one epoch later from the durable
        // `LeaveRequest`.
        //
        // This is the test that fails if MDK ever reorders
        // `CommitOrderingPriority` — at which point the residual stops being
        // "one extra epoch" and the gate-4 reasoning has to be redone.
        let tp = setup_two_party_circle().await;
        let start = tp
            .alice
            .session()
            .epoch(&tp.mls_group_id)
            .await
            .expect("alice epoch");

        // Alice stages her repair FIRST, at the current epoch, without having
        // seen Bob's proposal — the exact case gate 4 cannot cover.
        let RepairRotationOutcome::Rotated(rotation) = tp
            .alice
            .repair_epoch_rotation(&tp.mls_group_id, past_every_rotation_window())
            .await
            .expect("repair")
        else {
            panic!("expected a staged rotation");
        };

        // Bob departs; the auto-committer stages the eviction at the SAME source
        // epoch on a peer that has not seen the rotation.
        let proposal = tp
            .bob
            .propose_leave(&tp.mls_group_id)
            .await
            .expect("bob proposes to leave");

        // Both commits are now published and both members ingest both.
        tp.alice
            .confirm_published(rotation.pending)
            .await
            .expect("alice's rotation is acked and applied");
        let bob_saw_rotation = tp
            .bob
            .decrypt_location_collecting_commits(&rotation.commit_event)
            .await
            .expect("bob ingests the rotation");
        for staged in bob_saw_rotation.auto_commits {
            // Bob may have staged his own eviction alongside; it lost, so it is
            // rolled back rather than published.
            let _ = tp.bob.publish_failed(staged.pending).await;
        }
        let alice_saw_departure = tp
            .alice
            .decrypt_location_collecting_commits(&proposal)
            .await
            .expect("alice ingests the departure proposal");

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

        assert_departure_completes_one_epoch_later(&tp, &alice_saw_departure).await;
    }

    /// The second half of the race test: the losing departure is not dropped —
    /// Bob's durable `LeaveRequest` re-proposes it at the new epoch on his next
    /// convergence drain, and Alice commits that.
    async fn assert_departure_completes_one_epoch_later(
        tp: &TwoPartyCircle,
        alice_saw_departure: &DecryptedIngest,
    ) {
        // Bob's proposal was made at the OLD epoch, so the rotation superseded
        // it — nothing Alice can commit.
        assert!(
            alice_saw_departure.auto_commits.is_empty(),
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

        // And the departure is not LOST: Bob's durable `LeaveRequest` re-proposes
        // it at the new epoch on his next convergence drain, which is the
        // engine's own re-drive, not anything Haven schedules.
        let redriven = {
            let effects = tp
                .bob
                .session()
                .advance_convergence(&tp.mls_group_id)
                .await
                .expect("bob's convergence re-drives his leave request");
            effects
                .publish
                .iter()
                .find_map(|work| match work {
                    PublishWork::Proposal { msg } => {
                        SessionManager::transport_message_to_event(msg).ok()
                    }
                    _ => None,
                })
                .expect("the durable LeaveRequest must be re-proposed at the new epoch")
        };
        let staged = tp
            .alice
            .decrypt_location_collecting_commits(&redriven)
            .await
            .expect("alice ingests the re-proposed departure");
        for eviction in staged.auto_commits {
            tp.alice
                .confirm_published(eviction.pending)
                .await
                .expect("alice publishes and confirms the eviction");
        }
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
            .expect("bob proposes to leave");

        // The real receive path: ingesting the proposal STAGES the eviction the
        // auto-committer scheduled, so the engine is now mid-commit.
        let ingest = tp
            .alice
            .decrypt_location_collecting_commits(&proposal)
            .await
            .expect("alice ingests the proposal");
        let [eviction] = <[CommitToPublish; 1]>::try_from(ingest.auto_commits)
            .unwrap_or_else(|c| panic!("expected exactly one staged eviction, got {}", c.len()));
        assert!(
            matches!(
                tp.alice
                    .repair_epoch_rotation(&tp.mls_group_id, past_every_rotation_window())
                    .await
                    .expect("outcome"),
                RepairRotationOutcome::Skipped(SkipReason::EpochNotStable)
            ),
            "a circle with an eviction already staged must not also stage a rotation"
        );

        // Resolve the departure through the real Rule-13 ladder.
        tp.alice
            .confirm_published(eviction.pending)
            .await
            .expect("confirm the eviction on a relay ack");

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
                .repair_epoch_rotation(&tp.mls_group_id, past_every_rotation_window())
                .await
                .expect("outcome"),
            RepairRotationOutcome::Rotated(_)
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
        let tp = send_gated_sole_admin_circle().await;
        let ahead = tp
            .bob
            .session()
            .epoch(&tp.mls_group_id)
            .await
            .expect("bob epoch");
        assert_eq!(
            ahead,
            tp.alice
                .session()
                .epoch(&tp.mls_group_id)
                .await
                .expect("alice epoch")
                + 1,
            "fixture: bob must be one epoch ahead of alice"
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
            .expect("bob proposes to leave at his own, higher epoch");
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
                    }],
                    &CircleConfig::new("Restart Circle").with_relays(relays.clone()),
                    &relays,
                )
                .await
                .expect("create");
            alice
                .confirm_published(creation.pending)
                .await
                .expect("confirm create");
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
                .expect("bob proposes to leave");
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
                .repair_epoch_rotation(&mls_group_id, past_every_rotation_window())
                .await
                .expect("outcome"),
            RepairRotationOutcome::Skipped(SkipReason::PendingProposal)
        ));
    }

    #[tokio::test]
    async fn a_rotation_whose_commit_cannot_be_serialized_is_rolled_back() {
        // Rule 13's other edge. If the staged commit's transport message will
        // not turn into an event, dropping the `PendingStateRef` would leave the
        // group in `PendingPublish` — where every later send fails the engine's
        // "requires Stable" gate, permanently, for a serialization error.
        use cgka_traits::transport::{TransportEnvelope, TransportSource};

        let tp = setup_two_party_circle().await;
        let effects = tp
            .alice
            .session()
            .update_admin_policy(
                &tp.mls_group_id,
                &tp.alice
                    .session()
                    .admin_pubkeys(&tp.mls_group_id)
                    .await
                    .expect("admins"),
            )
            .await
            .expect("stage a real rotation");
        let pending = effects
            .publish
            .iter()
            .find_map(|work| match work {
                PublishWork::GroupEvolution { pending, .. } => Some(*pending),
                _ => None,
            })
            .expect("the engine staged a commit");

        // The SAME pending ref the engine really holds, carried by a message
        // whose payload is not the JSON the peeler DTO parses.
        let unserializable = SessionEffects {
            events: Vec::new(),
            publish: vec![PublishWork::GroupEvolution {
                msg: TransportMessage {
                    id: cgka_traits::types::MessageId::new(vec![7; 32]),
                    payload: b"not json".to_vec(),
                    timestamp: cgka_traits::transport::Timestamp(0),
                    causal_deps: Vec::new(),
                    source: TransportSource("test".to_string()),
                    envelope: TransportEnvelope::GroupMessage {
                        transport_group_id: tp.nostr_group_id.to_vec(),
                    },
                },
                welcomes: Vec::new(),
                pending,
            }],
            queued: Vec::new(),
            pending_convergence: Vec::new(),
        };

        tp.alice
            .take_rotation_commit(unserializable)
            .await
            .expect_err("an unserializable commit must not be reported as staged");

        // The promise: the group is Stable again, so the circle still sends.
        tp.alice
            .encrypt_location(
                &tp.mls_group_id,
                &tp.alice_keys.public_key(),
                &LocationMessage::new(51.5, -0.12),
                60,
            )
            .await
            .expect("a rolled-back rotation must leave the circle able to send");
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
            .encrypt_location(
                &tp.mls_group_id,
                &tp.bob_keys.public_key(),
                &LocationMessage::new(1.0, 2.0),
                60,
            )
            .await
            .expect("bob sends");
        let forged = nostr::EventBuilder::new(real.kind, "ZGVmaW5pdGVseSBub3QgY2lwaGVydGV4dA==")
            .tags(real.tags.clone())
            .sign_with_keys(&Keys::generate())
            .expect("sign the undecryptable event");
        let _ = tp.alice.decrypt_location(&forged).await;

        assert_eq!(
            rotation_state(&tp.alice, &tp.nostr_group_id).last_inbound_event_at_ms,
            None,
            "an event the engine could not authenticate must not stamp the quiescence gate — \
             it is mintable by any observer of the circle's public `h` tag"
        );
        assert!(matches!(
            tp.alice
                .repair_epoch_rotation(&tp.mls_group_id, past_every_rotation_window())
                .await
                .expect("outcome"),
            RepairRotationOutcome::Rotated(_)
        ));
    }

    #[tokio::test]
    async fn the_repair_discard_removes_the_no_op_policy_and_nothing_else() {
        // The DIRECT test of the take-back. Reaching it through
        // `repair_epoch_rotation` cannot exercise its discriminator, because the
        // pre-check returns first on every send-gated shape a test can build —
        // so a `panic!` on entry to the discard used to stay green.
        let tp = setup_two_party_circle().await;
        let alice = tp.alice_keys.public_key().to_bytes();
        let bob = tp.bob_keys.public_key().to_bytes();

        // The repair's own payload: the CURRENT policy, re-stated.
        let no_op = SessionManager::admin_policy_payload_for_test(&[alice])
            .expect("encode the current policy");
        // A real membership change: durable user intent parked behind the same
        // send gate, which must survive.
        let handoff =
            SessionManager::admin_policy_payload_for_test(&[alice, bob]).expect("encode a handoff");
        assert_ne!(no_op, handoff, "fixture: the two payloads must differ");

        for data in [no_op, handoff.clone()] {
            tp.alice
                .session()
                .queue_admin_policy_intent_for_test(&tp.mls_group_id, data)
                .await
                .expect("queue an intent");
        }
        assert_eq!(
            tp.alice
                .session()
                .queued_admin_policy_payloads_for_test(&tp.mls_group_id)
                .await
                .expect("read the queue")
                .len(),
            2,
            "fixture: both intents must be queued before the discard runs"
        );

        let removed = tp
            .alice
            .session()
            .discard_queued_repair_rotation_intents(&tp.mls_group_id, &[alice])
            .await
            .expect("discard");

        assert_eq!(removed, 1, "exactly the repair's own intent is taken back");
        assert_eq!(
            tp.alice
                .session()
                .queued_admin_policy_payloads_for_test(&tp.mls_group_id)
                .await
                .expect("read the queue"),
            vec![handoff],
            "the survivor must be the membership change, byte for byte"
        );
    }

    #[tokio::test]
    async fn the_pre_check_keeps_a_send_gated_repair_out_of_the_engines_send_path() {
        // MUST-1's first defence, pinned independently of its second.
        //
        // The probe is a decoy intent carrying the repair's own payload. If the
        // pre-check fires, the repair never issues an intent and therefore never
        // runs the take-back, so the decoy survives untouched. If the pre-check
        // is removed, the repair queues its own rotation, reaches the take-back,
        // and the take-back removes the decoy along with it — because the bytes
        // are identical. That difference is the only externally visible trace of
        // which of the two defences ran.
        let tp = send_gated_sole_admin_circle().await;
        let alice = tp.alice_keys.public_key().to_bytes();
        let decoy = SessionManager::admin_policy_payload_for_test(&[alice])
            .expect("encode the current policy");
        tp.alice
            .session()
            .queue_admin_policy_intent_for_test(&tp.mls_group_id, decoy.clone())
            .await
            .expect("queue the decoy");

        assert!(matches!(
            tp.alice
                .repair_epoch_rotation(&tp.mls_group_id, now_secs())
                .await
                .expect("outcome"),
            RepairRotationOutcome::Deferred { .. }
        ));

        assert_eq!(
            tp.alice
                .session()
                .queued_admin_policy_payloads_for_test(&tp.mls_group_id)
                .await
                .expect("read the queue"),
            vec![decoy],
            "a repair the pre-check declined must never reach the engine's send path, so it \
             has nothing to take back"
        );
    }

    #[tokio::test]
    async fn a_send_gated_circle_defers_the_repair_instead_of_reporting_no_work() {
        // Gate 7. A repair issued while the circle is send-gated must surface a
        // typed deferral carrying whatever the engine staged — not the opaque
        // "produced no GroupEvolution publish work" error, which is exactly the
        // string every caller used to drop on the floor while the device
        // silently stopped sharing.
        let tp = send_gated_sole_admin_circle().await;
        match tp
            .alice
            .repair_epoch_rotation(&tp.mls_group_id, past_every_rotation_window())
            .await
            .expect("a send-gated repair is a typed outcome, never an error")
        {
            RepairRotationOutcome::Deferred { .. } => {}
            RepairRotationOutcome::Rotated(commit) => {
                // Leave nothing staged before failing.
                tp.alice
                    .publish_failed(commit.pending)
                    .await
                    .expect("roll back");
                panic!("the future-epoch row must gate the rotation send");
            }
            RepairRotationOutcome::Skipped(reason) => {
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
        let tp = send_gated_sole_admin_circle().await;
        // A clock the sweep's age rule cannot use to retire the gating row, so
        // the circle stays gated across all three taps and the assertion is
        // about the banking, not about the repair having quietly succeeded.
        let now = now_secs();

        for tap in 1..=3 {
            assert!(
                matches!(
                    tp.alice
                        .repair_epoch_rotation(&tp.mls_group_id, now)
                        .await
                        .expect("outcome"),
                    RepairRotationOutcome::Deferred { .. }
                ),
                "tap {tap} must defer"
            );
            assert!(
                tp.alice
                    .session()
                    .queued_admin_policy_payloads_for_test(&tp.mls_group_id)
                    .await
                    .expect("read the queue")
                    .is_empty(),
                "tap {tap} left a rotation banked in the engine's outbound queue"
            );
        }

        // Unblock the circle and drain: nothing may come out, and the epoch must
        // not move. This is the assertion the burst would break.
        let before = tp
            .alice
            .session()
            .epoch(&tp.mls_group_id)
            .await
            .expect("alice epoch");
        tp.alice
            .sweep_unresolvable_inputs(now + 10 * 60)
            .await
            .expect("retire the gating row");
        tp.alice
            .session()
            .advance_convergence(&tp.mls_group_id)
            .await
            .expect("drain whatever the queue holds");
        assert_eq!(
            tp.alice
                .session()
                .epoch(&tp.mls_group_id)
                .await
                .expect("alice epoch"),
            before,
            "unblocking a circle that was tapped three times must not replay three rotations"
        );

        // And the repair still works once, deliberately, afterwards.
        assert!(matches!(
            tp.alice
                .repair_epoch_rotation(&tp.mls_group_id, past_every_rotation_window())
                .await
                .expect("outcome"),
            RepairRotationOutcome::Rotated(_)
        ));
    }

    #[tokio::test]
    async fn a_send_gated_repair_leaves_a_queued_membership_change_alone() {
        // The discard is keyed on the admin-policy payload equalling the CURRENT
        // policy — which is what makes a repair rotation a no-op re-statement and
        // a handoff something else entirely. A real membership intent parked
        // behind the same send gate is durable user intent and must survive.
        let tp = send_gated_sole_admin_circle().await;
        let now = now_secs();

        // Queue a REAL admin-policy change (promote Bob) behind the same gate.
        let handoff = tp
            .alice
            .propose_admin_handoff(&tp.mls_group_id, &tp.bob_keys.public_key())
            .await;
        assert!(
            handoff.is_err(),
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

        assert!(matches!(
            tp.alice
                .repair_epoch_rotation(&tp.mls_group_id, now)
                .await
                .expect("outcome"),
            RepairRotationOutcome::Deferred { .. }
        ));

        assert_eq!(
            tp.alice
                .session()
                .queued_admin_policy_payloads_for_test(&tp.mls_group_id)
                .await
                .expect("read the queue"),
            queued_before,
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
            .propose_admin_handoff(&tp.mls_group_id, &outsider)
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
            .expect("non-admin bob can propose SelfRemove");
        assert_eq!(ev.kind.as_u16(), 445);
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
            .add_members(
                &GroupId::from_slice(&[0u8; 32]),
                &[member.key_package_event],
            )
            .await;
        assert!(res.is_err());
    }

    #[tokio::test]
    async fn remove_members_nonexistent_group_fails() {
        let (manager, _keys, _dir) = create_test_manager();
        let res = manager
            .remove_members(
                &GroupId::from_slice(&[0u8; 32]),
                &[Keys::generate().public_key().to_hex()],
            )
            .await;
        assert!(res.is_err());
    }

    /// The `GroupCreated` publish item, for the two fixtures that drive a bare
    /// [`SessionManager`] and so cannot call `CircleManager`'s draining
    /// extractors.
    fn first_group_created(effects: SessionEffects) -> (Vec<TransportMessage>, PendingStateRef) {
        effects
            .publish
            .into_iter()
            .find_map(|work| match work {
                PublishWork::GroupCreated { welcomes, pending } => Some((welcomes, pending)),
                _ => None,
            })
            .expect("create_group stages a GroupCreated")
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
            sender: crate::nostr::mls::types::MemberId::new(
                hex::decode(sender_hex).expect("sender hex"),
            ),
            epoch: crate::nostr::mls::types::EpochId(1),
            payload: serde_json::to_vec(&rumor).expect("rumor bytes"),
        }
    }

    #[tokio::test]
    async fn a_co_drained_auto_commit_on_the_send_path_is_recorded_not_dropped() {
        // The engine's publish buffer is global, so a send can drain an eviction
        // auto-commit it was not after. Dropping it would leave a live
        // `PendingStateRef` with nothing recording the debt — the silent wedge —
        // while rolling it back would discard a peer's removal permanently. The
        // disposition is neither: record the obligation and leave the commit
        // staged, so the next foreground redemption publishes it.
        let tp = setup_two_party_circle().await;
        let proposal = tp
            .bob
            .propose_leave(&tp.mls_group_id)
            .await
            .expect("bob proposes leave");
        tp.alice
            .session()
            .process_event(&proposal)
            .await
            .expect("alice ingests the proposal");
        let mut staged = None;
        for _ in 0..40 {
            let effects = tp
                .alice
                .session()
                .advance_convergence(&tp.mls_group_id)
                .await
                .expect("advance convergence");
            if let Some(item) = effects
                .publish
                .into_iter()
                .find(|w| matches!(w, PublishWork::AutoPublish { .. }))
            {
                staged = Some(item);
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        }
        let item = staged.expect("the eviction auto-commit surfaces within the jitter window");

        tp.alice
            .surface_co_drained_auto_commits(std::slice::from_ref(&item))
            .await;

        assert!(
            tp.alice.owed_removal_commits().contains(&tp.nostr_group_id),
            "the obligation is RECORDED, so a session that dies here reports the \
             wedge instead of hiding it"
        );
        assert!(
            tp.alice.orphaned_removal_deferrals().is_empty(),
            "and this session still holds the ref that can publish it"
        );
        assert!(
            tp.alice
                .encrypt_location(
                    &tp.mls_group_id,
                    &tp.alice_keys.public_key(),
                    &LocationMessage::new(1.0, 2.0),
                    60,
                )
                .await
                .is_err(),
            "nothing was rolled back: the commit is still staged, which is what \
             keeps the removal from being dropped"
        );
    }

    #[tokio::test]
    async fn the_send_extractor_itself_records_a_co_drained_eviction() {
        // The test above proves the DISPOSITION; this one proves the send path
        // actually asks for it. `take_app_message` is the one extractor every
        // location publish goes through, and the engine's publish buffer is
        // global, so an eviction for another circle rides back in the same
        // vector. Deleting that one call leaves a live `PendingStateRef` with no
        // durable row behind it — invisible to `orphaned_removal_deferrals`, so
        // the wedge stops being reportable — while every other test on this path
        // stays green, because the helper it calls still works when called
        // directly.
        let tp = setup_two_party_circle().await;
        let proposal = tp
            .bob
            .propose_leave(&tp.mls_group_id)
            .await
            .expect("bob proposes leave");
        tp.alice
            .session()
            .process_event(&proposal)
            .await
            .expect("alice ingests the proposal");
        let mut staged = None;
        for _ in 0..40 {
            let effects = tp
                .alice
                .session()
                .advance_convergence(&tp.mls_group_id)
                .await
                .expect("advance convergence");
            if let Some(item) = effects
                .publish
                .into_iter()
                .find(|w| matches!(w, PublishWork::AutoPublish { .. }))
            {
                staged = Some(item);
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        }
        let item = staged.expect("the eviction auto-commit surfaces within the jitter window");
        assert!(
            tp.alice.owed_removal_commits().is_empty(),
            "precondition: nothing is owed yet, so the assertion below is this \
             call's doing"
        );

        // The shape a send is handed when the buffer held someone else's
        // eviction and no location of its own: the extractor must still have
        // recorded the obligation before it reports the miss.
        let co_drained = SessionEffects {
            events: Vec::new(),
            publish: vec![item],
            queued: Vec::new(),
            pending_convergence: Vec::new(),
        };
        tp.alice
            .take_app_message(co_drained)
            .await
            .expect_err("there was no application message to extract");

        assert!(
            tp.alice.owed_removal_commits().contains(&tp.nostr_group_id),
            "the send extractor records the obligation for a commit it did not \
             ask for, so the ref it leaves staged is one a redemption pass can \
             still publish"
        );
    }

    #[tokio::test]
    async fn a_drained_group_evolution_is_surfaced_with_its_welcomes_noted() {
        // O3. A queued Invite released by a convergence drain comes back as a
        // `GroupEvolution` carrying WELCOMES, and `CommitToPublish` has nowhere
        // to put them — pre-existing, and the one thing this fold must not do is
        // make it silent. So the commit is surfaced (never rolled back: that
        // would discard a membership change the engine has already queued and
        // whose durable row it has already deleted), and the dropped welcomes
        // get a bucketed warn. The warn's own emission is pinned at source by
        // `security_rule_gates::drained_group_evolution_welcomes_are_never_dropped_silently`.
        let tp = setup_two_party_circle().await;
        let invitee = make_member_with_relays(tp.relays.clone(), vec![]).await;
        let effects = tp
            .alice
            .session()
            .add_members(
                &tp.mls_group_id,
                parse_key_packages(&[invitee.key_package_event]).unwrap(),
            )
            .await
            .expect("stage an add");
        let item = effects
            .publish
            .into_iter()
            .find(|w| matches!(w, PublishWork::GroupEvolution { .. }))
            .expect("an add stages a GroupEvolution");
        let PublishWork::GroupEvolution {
            welcomes, pending, ..
        } = &item
        else {
            unreachable!("just matched")
        };
        assert!(
            !welcomes.is_empty(),
            "precondition: an add really does carry welcomes, or the arm under \
             test is about nothing"
        );
        let pending = *pending;

        let mut out = DecryptedIngest::default();
        let mut resolved = HashSet::new();
        let rolled_back = tp
            .alice
            .dispose_publish_work(item, BatchOrigin::Drained, &mut out, &mut resolved)
            .await;

        assert!(
            rolled_back.is_none(),
            "a drained evolution is NOT rolled back: the engine deleted its queued \
             row when it released it, so a rollback destroys the change"
        );
        assert_eq!(
            out.auto_commits.len(),
            1,
            "it is handed to the caller to publish"
        );
        assert_eq!(out.auto_commits[0].pending, pending);
        // Leave the group sendable for the fixture's drop.
        let _ = tp.alice.publish_failed(pending).await;
    }

    /// The batch cap stops the fold GENERATING work — it never drops a batch
    /// the engine has already handed back.
    ///
    /// Dropping one would be this whole packet's defect one layer down: the
    /// `AutoPublish` inside carries a live `PendingStateRef` that nothing but
    /// [`CircleManager::surface_auto_commit`] records an obligation for, so a
    /// cap that returned early would leave a staged, unpublished, unrecorded
    /// and unreported eviction — invisible, and permanent for that session.
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
            .expect("bob proposes leave");
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
                    &tp.relays,
                )
                .await
                .expect("create a filler circle");
            tp.alice
                .confirm_published(filler.pending)
                .await
                .expect("confirm the filler create");
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
        let (out, _) = tp
            .alice
            .fold_resolved_publish(seed, BatchOrigin::Drained)
            .await;

        assert_eq!(
            out.auto_commits.len(),
            1,
            "the batch past the cap was still folded, so the eviction it carried \
             reaches the caller instead of vanishing with a live ref"
        );
        assert!(
            tp.alice.owed_removal_commits().contains(&tp.nostr_group_id),
            "and it was surfaced through the obligation, not around it: a staged \
             removal commit with no durable row is a wedge nothing reports"
        );
        assert!(
            tp.alice.orphaned_removal_deferrals().is_empty(),
            "the obligation is this session's to redeem, not an orphan"
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
            .remove_members(&tp.mls_group_id, std::slice::from_ref(&bob_hex))
            .await
            .expect("admin removes bob");
        assert_eq!(commit.commit_event.kind.as_u16(), 445);
        tp.alice
            .confirm_published(commit.pending)
            .await
            .expect("confirm remove");
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
        let result = tp
            .alice
            .add_members_with_welcomes(&tp.alice_keys, &tp.mls_group_id, vec![carol], &tp.relays)
            .await
            .expect("admin adds carol");
        assert_eq!(result.welcome_events.len(), 1);
        assert_eq!(result.commit_event.kind.as_u16(), 445);
    }

    #[tokio::test]
    async fn add_members_with_welcomes_fails_closed_with_no_relays() {
        let tp = setup_two_party_circle().await;
        let carol = make_member_with_relays(vec![], vec![]).await;
        let err = tp
            .alice
            .add_members_with_welcomes(&tp.alice_keys, &tp.mls_group_id, vec![carol], &[])
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
            .add_members_with_welcomes(&tp.bob_keys, &tp.mls_group_id, vec![carol], &tp.relays)
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

    #[test]
    fn decline_invitation_nonexistent_is_idempotent() {
        // Decline is a local drop + resolution sentinel; it never touches the
        // wire (Rule 10) and is idempotent even with nothing held.
        let (manager, _keys, _dir) = create_test_manager();
        manager.decline_invitation(&EventId::all_zeros()).unwrap();
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
        };
        let config = CircleConfig::new("Dedup Circle").with_relays(relays.clone());
        let creation = alice
            .create_circle(&alice_keys, vec![member], &config, &relays)
            .await
            .unwrap();
        alice.confirm_published(creation.pending).await.unwrap();
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
    async fn encrypt_location_nonexistent_circle_fails() {
        let (manager, keys, _dir) = create_test_manager();
        let loc = crate::location::LocationMessage::new(1.0, 2.0);
        let res = manager
            .encrypt_location(
                &GroupId::from_slice(&[0u8; 32]),
                &keys.public_key(),
                &loc,
                60,
            )
            .await;
        assert!(matches!(res, Err(CircleError::NotFound(_))));
    }

    #[tokio::test]
    async fn encrypt_location_returns_correct_metadata() {
        let tp = setup_two_party_circle().await;
        let loc = crate::location::LocationMessage::new(37.7, -122.4);
        let (event, nostr_group_id, relays) = tp
            .alice
            .encrypt_location(&tp.mls_group_id, &tp.alice_keys.public_key(), &loc, 60)
            .await
            .expect("encrypt");
        assert_eq!(event.kind.as_u16(), 445);
        assert_eq!(nostr_group_id, tp.nostr_group_id);
        assert_eq!(relays, tp.relays);
    }

    #[tokio::test]
    async fn encrypt_location_and_decrypt_roundtrip() {
        let tp = setup_two_party_circle().await;
        let loc = crate::location::LocationMessage::new(51.5, -0.12);
        let (event, _ngid, _relays) = tp
            .alice
            .encrypt_location(&tp.mls_group_id, &tp.alice_keys.public_key(), &loc, 60)
            .await
            .expect("alice encrypts");

        let results = tp.bob.decrypt_location(&event).await.expect("bob decrypts");
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
            .encrypt_location(&tp.mls_group_id, &tp.bob_keys.public_key(), &loc, 60)
            .await
            .expect("bob encrypts");
        let results = tp
            .alice
            .decrypt_location(&event)
            .await
            .expect("alice decrypts");
        let (sender, _content) = expect_location(&results);
        assert_eq!(sender, tp.bob_keys.public_key().to_hex());
    }

    #[tokio::test]
    async fn encrypt_location_inner_event_carries_no_group_identifier() {
        // Rule 4: a published kind:445 must carry the pseudonymous
        // nostr_group_id, never the real MLS GroupId.
        let tp = setup_two_party_circle().await;
        let loc = crate::location::LocationMessage::new(1.0, 2.0);
        let (event, nostr_group_id, _relays) = tp
            .alice
            .encrypt_location(&tp.mls_group_id, &tp.alice_keys.public_key(), &loc, 60)
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
    async fn encrypt_location_attaches_group_retention_expiration() {
        // DM-2 deviation #2 re-wired: kind-445 APPLICATION messages carry a
        // NIP-40 `expiration` derived from the group's `message-retention.v1`
        // component — `inner_created_at + LOCATION_MESSAGE_RETENTION_SECS`,
        // and the outer created_at is bound to the inner one — so location
        // ciphertext cannot linger on relays indefinitely.
        let tp = setup_two_party_circle().await;
        let loc = crate::location::LocationMessage::new(10.0, 20.0);
        let (event, _n, _r) = tp
            .alice
            .encrypt_location(&tp.mls_group_id, &tp.alice_keys.public_key(), &loc, 60)
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
    async fn encrypt_location_publishes_neither_coordinate_nor_geohash() {
        // The WHOLE serialized 445 is searched — content and every tag — because
        // the falsification this guards is a coordinate, or the geohash derived
        // from one, reaching event content OR a tag. The geohash is the half a
        // content-only check misses: it is a lossy coordinate, not a coordinate.
        let tp = setup_two_party_circle().await;
        let loc = crate::location::LocationMessage::new(37.7749, -122.4194);
        let (event, _n, _r) = tp
            .alice
            .encrypt_location(&tp.mls_group_id, &tp.alice_keys.public_key(), &loc, 60)
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
            .update_circle_relays(&tp.mls_group_id, &["wss://relay3.test.com".to_string()])
            .await
            .expect("relay update");
        assert!(
            !update
                .commit_event
                .tags
                .iter()
                .any(|t| matches!(t.as_standardized(), Some(nostr::TagStandard::Expiration(_)))),
            "an MLS evolution commit must not carry a NIP-40 expiration tag"
        );
        tp.alice
            .confirm_published(update.pending)
            .await
            .expect("confirm");
    }

    #[tokio::test]
    async fn decrypt_location_drops_expired_event() {
        // Receiver-side NIP-40 enforcement (defense-in-depth vs relay
        // replay, restored post-Dark-Matter): an otherwise-valid kind-445
        // whose expiration (+60s grace) has passed is dropped before any
        // engine processing — no results, no error.
        let tp = setup_two_party_circle().await;
        let loc = crate::location::LocationMessage::new(10.0, 20.0);
        let (event, _n, _r) = tp
            .bob
            .encrypt_location(&tp.mls_group_id, &tp.bob_keys.public_key(), &loc, 60)
            .await
            .expect("bob encrypts");
        // Precondition: the rewrite below only maps an Expiration tag that is
        // already there, so without one it is a silent no-op and this test would
        // fail somewhere far from its cause. Two independent things now supply
        // the tag — the circle's 0x8005 component and the send-side bound — so
        // this pins the rewrite's input rather than either supplier.
        assert!(
            expiration_of(&event).is_some(),
            "the source location 445 must carry an expiration for the replay rewrite to bite"
        );
        // Rebuild the event with its expiration forced into the past (beyond
        // the 60s grace), re-signed by a fresh throwaway key — the guard runs
        // before any signature/AAD validation, mirroring a replaying relay.
        let past = nostr::Timestamp::now().as_secs()
            - crate::location::ttl::RECEIVER_EXPIRATION_GRACE_SECS
            - 120;
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
            .expect("re-sign replayed event");
        // Session-level oracle: only the receiver-side guard yields
        // `RejectedBeforeAuth` for this event — without the guard the engine
        // would either decrypt it (an `Ingested` with non-empty effects) or
        // classify it `Stale { PeelFailed }` (an `Ingested` either way), so this
        // cannot pass vacuously.
        //
        // The variant matters as much as the drop: the guard used to report a
        // synthetic `Stale`, which both cursor planes read as "advance past
        // this". Since NOTHING about this replay is authenticated — it is
        // re-signed here by a throwaway key precisely to model that — its
        // `created_at` must never be able to move a sync cursor.
        let screened = tp
            .alice
            .session()
            .process_event(&replayed)
            .await
            .expect("expired event is dropped, not an error");
        assert!(
            matches!(
                screened,
                crate::nostr::mls::types::ScreenedIngest::RejectedBeforeAuth(
                    crate::nostr::mls::types::PreAuthRejection::Expired
                )
            ),
            "the expiration guard must report a PRE-AUTHENTICATION rejection, \
             never an engine outcome the cursor planes would advance past"
        );
        assert!(
            screened.ingested().is_none(),
            "a pre-auth rejection carries no engine effects at all"
        );
        // Behavior-level check through the production drain API.
        let results = tp
            .alice
            .decrypt_location(&replayed)
            .await
            .expect("expired event is dropped, not an error");
        assert!(
            results.is_empty(),
            "an expired kind-445 must be dropped before decryption"
        );
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
        joiner_keys: Keys,
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
        let (welcomes, pending) = first_group_created(creation.effects);
        creator.confirm_published(pending).await.expect("confirm");

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
            joiner_keys,
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
            .encrypt_location(
                &joined.mls_group_id,
                &joined.joiner_keys.public_key(),
                &loc,
                60,
            )
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
            .encrypt_location(
                &joined.mls_group_id,
                &joined.joiner_keys.public_key(),
                &loc,
                60,
            )
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
                .encrypt_location(
                    &joined.mls_group_id,
                    &joined.joiner_keys.public_key(),
                    &loc,
                    60,
                )
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
            .encrypt_location(
                &joined.mls_group_id,
                &joined.joiner_keys.public_key(),
                &loc,
                60,
            )
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

    #[tokio::test]
    async fn decrypt_relay_commit_surfaces_group_update() {
        let tp = setup_two_party_circle().await;
        let update = tp
            .alice
            .update_circle_relays(&tp.mls_group_id, &["wss://relay3.test.com".to_string()])
            .await
            .expect("relay update");
        tp.alice
            .confirm_published(update.pending)
            .await
            .expect("confirm");
        let results = tp
            .bob
            .decrypt_location(&update.commit_event)
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
        let kp = manager.fresh_key_package().await.expect("fresh kp");
        assert!(!kp.bytes().is_empty());
    }

    #[tokio::test]
    async fn delete_key_package_is_idempotent() {
        let (manager, _keys, _dir) = create_test_manager();
        let kp = manager.fresh_key_package().await.expect("fresh kp");
        manager.delete_key_package(&kp).await.expect("first delete");
        manager
            .delete_key_package(&kp)
            .await
            .expect("idempotent delete");
    }

    // ── Publish-before-apply (Rule 13) unknown-ref rejection ─────────────────

    #[tokio::test]
    async fn confirm_published_unknown_pending_fails() {
        let (manager, _keys, _dir) = create_test_manager();
        let bogus = PendingStateRef::new(u64::MAX);
        assert!(manager.confirm_published(bogus).await.is_err());
    }

    #[tokio::test]
    async fn publish_failed_unknown_pending_fails() {
        let (manager, _keys, _dir) = create_test_manager();
        let bogus = PendingStateRef::new(u64::MAX);
        assert!(manager.publish_failed(bogus).await.is_err());
    }

    // ── Rule 14 (single-session) — RE-EXPRESSED write-site guard ─────────────

    /// Recursively collects `path:line` sites where `needle` appears in a
    /// non-comment source line under `dir`.
    fn walk_for_sites(dir: &std::path::Path, needle: &str, sites: &mut Vec<String>) {
        for entry in std::fs::read_dir(dir).expect("read_dir") {
            let path = entry.expect("entry").path();
            if path.is_dir() {
                walk_for_sites(&path, needle, sites);
            } else if path.extension().and_then(|e| e.to_str()) == Some("rs") {
                let src = std::fs::read_to_string(&path).expect("read source");
                for (i, line) in src.lines().enumerate() {
                    let t = line.trim_start();
                    // Skip comment / doc lines that merely name the type.
                    if t.starts_with("//") || t.starts_with('*') {
                        continue;
                    }
                    if line.contains(needle) {
                        sites.push(format!("{}:{}", path.display(), i + 1));
                    }
                }
            }
        }
    }

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
        // Built by concatenation so THIS scanner's own source line does not
        // contain the literal needle and thus never self-matches.
        let needle = concat!("AccountDeviceSession", "::open(");
        let mut sites: Vec<String> = Vec::new();
        walk_for_sites(&root, needle, &mut sites);
        assert_eq!(
            sites.len(),
            1,
            "exactly one AccountDeviceSession::open construction site is allowed \
             (Rule 14: one live session per DB file); found: {sites:?}"
        );
        assert!(
            sites[0].replace('\\', "/").contains("nostr/mls/manager.rs"),
            "the single session construction site must live in \
             SessionManager::open_session, found {}",
            sites[0]
        );
    }
    #[test]
    fn every_mls_database_open_site_is_sanctioned() {
        // The Rule-14 companion to the test above. That one pins the number of
        // hydrated SESSIONS; this one pins the number of raw CONNECTIONS to the
        // same encrypted database, because the stuck-convergence-input sweep
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
        // Scans PRODUCTION lines only: an in-file `#[cfg(test)] mod tests` may
        // legitimately open a database (the wrong-key round trip in
        // `nostr/mls/storage.rs` does), and those opens are not live sessions.
        // Every file in this crate puts its test module last, so stopping at the
        // first `#[cfg(test)]` is exact rather than approximate — and a file that
        // ever stops doing so trips the "found no open sites" guard below rather
        // than silently under-reporting.
        fn walk_production_sites(dir: &std::path::Path, needle: &str, sites: &mut Vec<String>) {
            for entry in std::fs::read_dir(dir).expect("read_dir") {
                let path = entry.expect("entry").path();
                if path.is_dir() {
                    walk_production_sites(&path, needle, sites);
                    continue;
                }
                if path.extension().and_then(|e| e.to_str()) != Some("rs") {
                    continue;
                }
                let src = std::fs::read_to_string(&path).expect("read source");
                for (i, line) in src.lines().enumerate() {
                    let t = line.trim_start();
                    if t.starts_with("#[cfg(test)]") {
                        break;
                    }
                    if t.starts_with("//") || t.starts_with('*') {
                        continue;
                    }
                    if line.contains(needle) {
                        sites.push(format!("{}:{}", path.display(), i + 1));
                    }
                }
            }
        }
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let needle = concat!("SqliteAccountStorage", "::open_encrypted");
        let mut production: Vec<String> = Vec::new();
        walk_production_sites(&root, needle, &mut production);
        // Both sanctioned opens live in the MLS module: the session's own
        // storage (`StorageConfig::open_encrypted_storage`) and the sweep's
        // message store (`SessionManager::open_session`).
        assert_eq!(
            production.len(),
            2,
            "exactly two MLS-database open sites are sanctioned (the session's storage \
             and the sweep's message store); found: {production:?}"
        );
        for site in &production {
            let site = site.replace('\\', "/");
            assert!(
                site.contains("nostr/mls/storage.rs") || site.contains("nostr/mls/manager.rs"),
                "an MLS-database open outside the MLS module cannot be reasoned about \
                 for Rule 14, found {site}"
            );
        }
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
        // Everything the sweep, its read-only counterpart, and the two test
        // fixtures legitimately need. `convergence_policy` is the READ half of
        // `ConvergencePolicyStorage` (the sweep reads the persisted rewind
        // window); `put_convergence_policy` is deliberately absent.
        const ALLOWED: &[&str] = &[
            // GroupStorage (reads only)
            "get_group",
            "list_groups",
            // MessageStorage
            "get_message",
            "put_message",
            "list_messages",
            "update_message_state",
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
            // ConvergencePolicyStorage (read half)
            "convergence_policy",
        ];

        let source = std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/nostr/mls/manager.rs"),
        )
        .expect("read the session manager source");
        let mut seen: Vec<String> = Vec::new();
        for line in source.lines() {
            let trimmed = line.trim_start();
            if trimmed.starts_with("//") || trimmed.starts_with('*') {
                continue;
            }
            for receiver in ["message_store.", "store."] {
                let mut rest = line;
                while let Some(at) = rest.find(receiver) {
                    // Only a genuine method position: `.foo(` or `.foo()?`.
                    let tail = &rest[at + receiver.len()..];
                    let name: String = tail
                        .chars()
                        .take_while(|c| c.is_alphanumeric() || *c == '_')
                        .collect();
                    if !name.is_empty() {
                        seen.push(name);
                    }
                    rest = &rest[at + receiver.len()..];
                }
            }
        }
        assert!(
            !seen.is_empty(),
            "the scanner found no message-store calls at all; the sweep was renamed or \
             removed — update this guard rather than deleting it"
        );
        let mut forbidden: Vec<&String> = seen
            .iter()
            .filter(|name| !ALLOWED.contains(&name.as_str()))
            .collect();
        forbidden.sort();
        forbidden.dedup();
        assert!(
            forbidden.is_empty(),
            "the sweep's second connection reached storage outside the message-shaped \
             surface that makes it Rule-14-safe: {forbidden:?}. Reaching group writes, \
             snapshots, welcomes or mls_storage() from a non-session connection is a \
             confidentiality argument this test exists to protect."
        );
    }

    // ── Owed removal publishes: what discharges one, and what must not ──────

    /// A synthetic `kind:445` carrying `ngid` in its `#h` tag — the only field
    /// [`CircleManager::owe_removal_publish`] reads, so an obligation can be
    /// recorded without driving a real peer leave.
    fn commit_event_for(ngid: &[u8; 32]) -> Event {
        nostr::EventBuilder::new(nostr::Kind::Custom(445), "ciphertext")
            .tag(nostr::Tag::custom(
                nostr::TagKind::custom("h"),
                [hex::encode(ngid)],
            ))
            .sign_with_keys(&Keys::generate())
            .expect("sign the synthetic commit")
    }

    fn epoch_changed(group_id: &GroupId) -> GroupEvent {
        GroupEvent::EpochChanged {
            group_id: group_id.clone(),
            from: crate::nostr::mls::types::EpochId(1),
            to: crate::nostr::mls::types::EpochId(2),
        }
    }

    /// D9, direction 1: an `EpochChanged` for a circle whose obligation this
    /// session CANNOT redeem clears it — otherwise the next foreground open would
    /// report a circle that has moved on as unrecoverable.
    ///
    /// This is the reachable case: an unrelated peer commit landing after an
    /// orphaned park merges, which empties the proposal store and discards the
    /// leaver's `SelfRemove`. The row then describes nothing.
    #[tokio::test]
    async fn an_epoch_change_clears_an_obligation_this_session_cannot_redeem() {
        let (manager, keys, _dir) = create_test_manager();
        let (gid, _member) = create_confirmed_circle(&manager, &keys, "Orphan").await;
        let ngid = manager
            .storage
            .get_circle(&gid)
            .unwrap()
            .unwrap()
            .nostr_group_id;
        // The durable half ALONE: exactly what a session that died mid-leave
        // leaves behind.
        manager
            .storage
            .put_deferred_removal_commit(&ngid, 1)
            .unwrap();
        assert_eq!(manager.orphaned_removal_deferrals(), vec![ngid]);

        manager.note_inbound_group_events(&[epoch_changed(&gid)]);

        assert!(
            manager.owed_removal_commits().is_empty(),
            "an orphaned row must be cleared by an epoch move: the commit that \
             moved it discarded the leaver's proposal, so the row is evidence of \
             nothing and would be a false `GroupUnrecoverable`"
        );
    }

    /// D9, direction 2: an `EpochChanged` must NOT clear an obligation this
    /// session can still redeem.
    ///
    /// The commit is STAGED and its publish is still owed. Dropping the in-memory
    /// entry here would destroy the only handle that can publish it while leaving
    /// the commit staged — a silent drop of the removal by another route, and
    /// invisible because every projected read already shows the post-eviction
    /// roster.
    #[tokio::test]
    async fn an_epoch_change_does_not_clear_an_obligation_this_session_owes() {
        let (manager, keys, _dir) = create_test_manager();
        let (gid, _member) = create_confirmed_circle(&manager, &keys, "Owed").await;
        let ngid = manager
            .storage
            .get_circle(&gid)
            .unwrap()
            .unwrap()
            .nostr_group_id;
        let pending = PendingStateRef::new(4242);
        assert!(manager.owe_removal_publish(&CommitToPublish {
            commit_event: commit_event_for(&ngid),
            pending,
        }));
        assert!(
            manager.orphaned_removal_deferrals().is_empty(),
            "premise: this obligation IS redeemable by this session"
        );

        manager.note_inbound_group_events(&[epoch_changed(&gid)]);

        assert_eq!(
            manager.owed_removal_commits(),
            vec![ngid],
            "a live obligation survives an epoch move"
        );
        assert!(
            manager.orphaned_removal_deferrals().is_empty(),
            "and stays REDEEMABLE — the in-memory handle is what \
             `redeem_removal_deferrals` publishes from, so losing it would wedge \
             the circle while reporting nothing"
        );
    }

    /// A relay plane that OK-acks every publish and records what it was handed,
    /// so a test can prove the ladder actually reached the confirm rung.
    struct AckingPublisher {
        published: Mutex<Vec<Event>>,
    }

    /// The boxed future shape `AutoCommitPublisher` returns.
    type AckFuture<'a> = std::pin::Pin<Box<dyn std::future::Future<Output = bool> + Send + 'a>>;

    impl crate::relay::auto_commit::AutoCommitPublisher for AckingPublisher {
        fn publish_auto_commit<'a>(
            &'a self,
            event: &'a Event,
            _relays: &'a [String],
        ) -> AckFuture<'a> {
            self.published
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .push(event.clone());
            Box::pin(async { true })
        }
    }

    /// A publish the relay ACKED whose confirm the engine then refuses must leave
    /// the obligation standing.
    ///
    /// `confirm_published` can fail with the staged commit still attached: the
    /// engine's durable transaction propagates a lock blip BEFORE its in-memory
    /// state-machine transition, which is exactly why upstream marks the call
    /// retry-safe. Clearing the row on that error deletes the only record of a
    /// still-owed eviction — nothing would retry it, `orphaned_removal_deferrals`
    /// would never name it, and the fail rung would be free to discard the
    /// removal, which is the permanent silent drop this obligation exists to
    /// prevent.
    #[tokio::test]
    async fn a_refused_confirm_keeps_the_removal_publish_owed() {
        let (manager, keys, _dir) = create_test_manager();
        let (gid, _member) = create_confirmed_circle(&manager, &keys, "Refused").await;
        let ngid = manager
            .storage
            .get_circle(&gid)
            .unwrap()
            .unwrap()
            .nostr_group_id;
        // A ref the engine never issued, standing in for every refusal that
        // leaves the staged commit attached.
        assert!(manager.owe_removal_publish(&CommitToPublish {
            commit_event: commit_event_for(&ngid),
            pending: PendingStateRef::new(u64::MAX),
        }));

        let publisher = AckingPublisher {
            published: Mutex::new(Vec::new()),
        };
        let confirmed = manager.redeem_removal_deferrals(&publisher, None).await;

        assert_eq!(
            publisher
                .published
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .len(),
            1,
            "premise: the ladder reached the wire and got its ack, so the confirm \
             rung is what refused — without this the assertion below would also \
             pass for a publish that never happened"
        );
        assert_eq!(confirmed, 0, "a refused confirm confirms nothing");
        assert_eq!(
            manager.owed_removal_commits(),
            vec![ngid],
            "the obligation SURVIVES a refused confirm: the commit may still be \
             staged, and the row is the only thing that would ever report it"
        );
    }

    /// D10: deleting a circle takes the in-memory half of its obligation with the
    /// durable row `delete_circle` cascades.
    #[tokio::test]
    async fn leaving_a_circle_forgets_the_removal_publish_it_owed() {
        let (manager, keys, _dir) = create_test_manager();
        let (gid, _member) = create_confirmed_circle(&manager, &keys, "Left").await;
        let ngid = manager
            .storage
            .get_circle(&gid)
            .unwrap()
            .unwrap()
            .nostr_group_id;
        assert!(manager.owe_removal_publish(&CommitToPublish {
            commit_event: commit_event_for(&ngid),
            pending: PendingStateRef::new(9),
        }));

        manager.complete_leave(&gid, DIR_NOW).await.unwrap();

        assert!(
            manager.owed_removal_commits().is_empty(),
            "the cascade removed the durable row"
        );
        assert!(
            !manager.keeps_its_removal_publish_owed(PendingStateRef::new(9)),
            "and the in-memory entry went with it: leaving it behind would pin an \
             Event and a dead engine ref to a circle that no longer exists"
        );
    }

    /// A confirmed publish discharges the obligation; a REJECTED one does not.
    ///
    /// Both halves matter. Without the discharge every peer-leave would leave a
    /// durable row behind and the next foreground open would report a healthy
    /// circle unrecoverable. And a confirm the engine refused leaves the commit
    /// exactly as staged as it was, so keeping the row is what makes that wedge
    /// visible rather than assumed away.
    #[tokio::test]
    async fn only_a_confirmed_publish_discharges_an_owed_removal() {
        let (manager, keys, _dir) = create_test_manager();
        let (gid, _member) = create_confirmed_circle(&manager, &keys, "Discharge").await;
        let ngid = manager
            .storage
            .get_circle(&gid)
            .unwrap()
            .unwrap()
            .nostr_group_id;
        let unknown = PendingStateRef::new(u64::MAX);
        assert!(manager.owe_removal_publish(&CommitToPublish {
            commit_event: commit_event_for(&ngid),
            pending: unknown,
        }));

        // The engine never issued this ref, so the confirm is rejected.
        assert!(manager.confirm_published(unknown).await.is_err());
        assert_eq!(
            manager.owed_removal_commits(),
            vec![ngid],
            "a rejected confirm applied nothing, so nothing is discharged"
        );
    }
}
