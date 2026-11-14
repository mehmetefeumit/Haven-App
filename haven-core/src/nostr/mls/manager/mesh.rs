//! The mesh key ring, the publish hand-off and the packets a drive reads
//! (`docs/BLUETOOTH_MESH_PLAN.md` §4.2, §5.1 and §5.2).
//!
//! A mesh packet is sealed under `K_mesh = HKDF(G_e)`, `G_e` being a circle's
//! group-event exporter secret at one epoch. This keeps `G_e` and `K_mesh`
//! per circle for the epoch the engine stands on and the
//! [`DEFAULT_MAX_PAST_EPOCHS`] before it — in memory, and in the circle store
//! so a restart can still read a peer who is an epoch behind — and only while
//! mesh is on. MDK hands out `G_e` for the current epoch alone, so a key
//! exists only for an epoch this device was seen standing on.
//!
//! The one file under `nostr/` and `relay/` that names the mesh module
//! (`scripts/ci/check_mesh_seams.sh`). It re-exports nothing, names no engine
//! type and takes no lock of the engine's: what it reads of a circle it reads
//! through [`Held`], off the session its caller holds. The driver's
//! `mesh_drive` is handed packets and answers for them through
//! [`MeshPacket`] and [`MeshDrive`], declared here under names that guard
//! reads wherever they are used.
//!
//! Nothing here logs and no type is `Debug`: an epoch, a group id, a routing
//! id and a slot are identifiers, and a key is a secret (Security Rules 6
//! and 15).

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use nostr::{Event, EventId};
use rand::rngs::OsRng;
use rand::{CryptoRng, RngCore};
use subtle::ConstantTimeEq;
use zeroize::Zeroizing;

use super::{
    GroupEvent, GroupId, LocationMessageResult, LocationToSend, MemberId, SessionManager,
    DEFAULT_MAX_PAST_EPOCHS,
};
use crate::mesh::engine::CircleSlot;
use crate::mesh::event::{parts_of, rebuild};
use crate::mesh::handoff::Handoff;
use crate::mesh::packet::{open, wrap, Format, MeshKey, Packet, PacketId};
use crate::relay::fanout::LOCATION_SEND_MS;

/// The longest mesh stays on without being asked for again: the deadline is
/// never further ahead of the clock than this.
pub const MESH_ON_MAX_MS: u64 = 12 * 60 * 60 * 1_000;

/// How far behind the engine's epoch a key is still kept: the engine's own
/// window (Security Rule 5).
const PAST_EPOCHS: u64 = DEFAULT_MAX_PAST_EPOCHS as u64;

// A slot is one bit of the mask a free one is found in.
const _: () = assert!(Handoff::SLOTS <= u64::BITS);

/// How many events one drive offers the engine for one circle: what a member
/// who floods the mesh costs a drive, whatever it sends.
const DRIVE_PER_CIRCLE: usize = 32;

/// How many opened packets one circle keeps while the engine has not taken
/// their events in. A quota of its own for each circle, so a circle that
/// cannot take its input in — or a member flooding one — costs no other
/// circle a packet; past it the oldest goes.
const HELD_PER_CIRCLE: usize = 64;

/// How many updates of fellow members one circle keeps to pass on to its
/// relays (plan §5.5), one a member: so also the most one send of this
/// device's passes on.
const BRIDGE_PER_CIRCLE: usize = 4;

/// How many such updates every circle keeps together.
const BRIDGE_WAITING: usize = 32;

/// How long after one update of a member was passed on the next of that
/// member is: what a member who floods the mesh gets of this device.
const BRIDGE_SENDER_GAP_MS: u64 = 72_000;

/// The longest lifetime an event that is passed on may declare, seconds:
/// Haven's own for a location. A member cannot make this device publish an
/// event stamped to last longer.
const BRIDGE_LIFETIME_SECS: u64 = crate::location::ttl::LOCATION_MESSAGE_RETENTION_SECS;

/// A mesh packet, as `Publishing::mesh_drive` is handed one by the mesh
/// engine's owner. The driver does not name the mesh module
/// (`scripts/ci/check_mesh_seams.sh`): it names this.
pub type MeshPacket = Packet;

/// What one `Publishing::mesh_drive` did with the mesh's packets.
///
/// **No `Debug`**: a packet id tells one packet from another and the count
/// is exact (Security Rule 15).
#[derive(Default)]
#[must_use]
pub struct MeshDrive {
    /// Every packet this drive settled — one it was handed, or one an
    /// earlier drive held — with whether it opened under one of this
    /// device's keys: what the engine's owner marks read. A packet that
    /// opened and whose event the engine has not taken in is held, not here;
    /// a later drive answers for it.
    pub read: Vec<(PacketId, bool)>,
    /// How many updates from peers in this device's circles the engine read
    /// for the first time in this drive: one it had read before — from a
    /// relay, or from the mesh in any process — and one of this device's own
    /// are none. Stored already.
    pub from_circles: u64,
    /// The locations taken in, each stored already.
    pub replayed: Vec<LocationMessageResult>,
    /// Whether an ingest failed; its packet is held and offered again.
    pub errored: bool,
}

/// A packet that opened under a key of `circle`, with what its event is
/// checked against before the engine sees it.
pub(super) struct Opened {
    packet: PacketId,
    circle: GroupId,
    /// The event the packet carried, rebuilt under the routing id of the
    /// key that opened it, and verified.
    pub(super) event: Event,
    /// Whether the packet says a member may pass its event on to a relay
    /// ([`Format::Bridgeable`]).
    bridgeable: bool,
    /// The epoch of that key.
    pub(super) epoch: u64,
    /// The group-event exporter secret of that epoch.
    pub(super) exporter: Zeroizing<[u8; 32]>,
}

/// What the ring reads of the engine. The session manager implements it for
/// the session it holds, so a `&impl Held` is also the proof that its caller
/// holds the engine: everything here that changes a key or writes the store
/// takes one, and so runs one at a time.
pub(super) trait Held {
    /// The epoch `group` stands stable on. `None` while a commit is staged,
    /// while the circle recovers, is halted or disbanded, and for a group the
    /// engine does not hold live.
    fn stable_epoch(&self, group: &GroupId) -> Option<u64>;
    /// The group-event exporter secret MDK hands out for `group`, and the
    /// epoch it is of — the STAGED epoch's while a commit is staged.
    fn exporter(&self, group: &GroupId) -> Option<(u64, Zeroizing<Vec<u8>>)>;
    /// The circle's routing id (`nostr_group_id`) as it stands.
    fn routing_id(&self, group: &GroupId) -> Option<[u8; 32]>;
}

/// One stored key: a circle's group-event exporter secret at one epoch, and
/// the routing id the circle had at it.
pub struct StoredMeshKey {
    /// The epoch.
    pub epoch: u64,
    /// The circle's `nostr_group_id` at that epoch.
    // zeroize-ok: the epoch's routing id, an identifier and no secret
    pub routing: [u8; 32],
    /// The exporter secret; the packet key is derived from it on load.
    pub exporter: Zeroizing<[u8; 32]>,
}

/// Where the ring outlives the process, while mesh is on: the circle store.
///
/// Implementations log nothing: every argument is an identifier or a secret.
pub trait MeshKeyStore: Send + Sync {
    /// The stored instant mesh goes off at, wall-clock milliseconds; `None`
    /// when none is stored or it cannot be read, which is off.
    fn mesh_on_until(&self) -> Option<u64>;
    /// Stores the instant mesh goes off at. `None` removes it and, in the
    /// same transaction, every stored key. Returns whether the write landed.
    fn set_mesh_on_until(&self, until_ms: Option<u64>) -> bool;
    /// Every stored key with its circle, to restore at the open.
    fn mesh_keys(&self) -> Vec<(GroupId, StoredMeshKey)>;
    /// Makes `group`'s stored keys exactly `keys`, in one transaction; none
    /// deletes them. Returns whether the write landed.
    fn save_mesh_keys(&self, group: &GroupId, keys: &[StoredMeshKey]) -> bool;
}

/// A session with no circle store: the ring lasts as long as the process.
struct NoMeshKeyStore;

impl MeshKeyStore for NoMeshKeyStore {
    fn mesh_on_until(&self) -> Option<u64> {
        None
    }

    fn set_mesh_on_until(&self, _until_ms: Option<u64>) -> bool {
        true
    }

    fn mesh_keys(&self) -> Vec<(GroupId, StoredMeshKey)> {
        Vec::new()
    }

    fn save_mesh_keys(&self, _group: &GroupId, _keys: &[StoredMeshKey]) -> bool {
        true
    }
}

/// One epoch of one circle.
struct EpochKey {
    epoch: u64,
    // zeroize-ok: the epoch's routing id, an identifier and no secret
    routing: [u8; 32],
    exporter: Zeroizing<[u8; 32]>,
    mesh: MeshKey,
}

impl EpochKey {
    fn new(epoch: u64, routing: [u8; 32], exporter: Zeroizing<[u8; 32]>) -> Self {
        Self {
            epoch,
            routing,
            mesh: MeshKey::derive(&exporter),
            exporter,
        }
    }

    /// Whether this is the key of `epoch` on the branch `exporter` is of.
    fn is(&self, epoch: u64, exporter: &[u8; 32]) -> bool {
        self.epoch == epoch && bool::from(self.exporter.ct_eq(exporter))
    }
}

/// An update a packet carried, kept until the engine takes it in.
struct HeldUpdate {
    packet: PacketId,
    event: Event,
    /// The digest of the MLS message the event carries: the id the engine
    /// announces the update under once it reads it.
    // zeroize-ok: a digest of ciphertext, an identifier and no secret
    content: [u8; 32],
    /// Whether every packet of it this device opened says a member may pass
    /// it on to a relay. The mark is outside the signature, so one packet
    /// that says no decides.
    bridgeable: bool,
    /// The circle's turn when the packet was opened: an update is passed on
    /// only if nothing silenced its circle between the key that opened it
    /// and the engine taking it in — a branch reselected in that very hold
    /// leaves the epoch number as it was, and the key no longer the
    /// circle's.
    turn: u64,
}

/// A fellow member's update this device took in by mesh, which it may pass
/// on to the circle's relays at its own next send (plan §5.5).
pub struct Candidate {
    /// The member's own sealed event as its packet carried it, rebuilt and
    /// verified: what that member's relay send would have been, byte for
    /// byte.
    event: Event,
    /// The epoch it was sealed at.
    epoch: u64,
    /// Who sent it, as the engine authenticated it.
    sender: MemberId,
}

impl Candidate {
    /// `event`, if what the engine read in it for the first time — `update`,
    /// as it announced it — is a location another member than `own` sent.
    /// What this device sent itself the engine answers as an own echo and
    /// announces nothing for; an account's other device is not a fellow
    /// member either.
    fn of(event: Event, update: &GroupEvent, own: &[u8; 32]) -> Option<Self> {
        let GroupEvent::MessageReceived {
            sender,
            epoch,
            payload,
            ..
        } = update
        else {
            return None;
        };
        (sender.as_slice() != own && !super::inner_location_content(payload).is_empty()).then(
            || Self {
                event,
                epoch: epoch.0,
                sender: sender.clone(),
            },
        )
    }

    /// The event, the epoch it was sealed at and its sender, if the event
    /// may still be handed to a relay at `now_ms`: its declared lifetime is
    /// no longer than [`BRIDGE_LIFETIME_SECS`], it is not stamped ahead of
    /// this device's clock by more than a send takes, and a send begun now
    /// has ended before the relays and every member drop it — so no later
    /// than `min(declared, 228) − 10` seconds after it was sealed.
    pub(super) fn in_time(self, now_ms: u64) -> Option<(Event, u64, MemberId)> {
        let created = self.event.created_at.as_secs();
        let expires = self.event.tags.expiration()?.as_secs();
        let reach = now_ms.saturating_add(LOCATION_SEND_MS);
        (expires.saturating_sub(created) <= BRIDGE_LIFETIME_SECS
            && created.saturating_mul(1_000) <= reach
            && reach < expires.saturating_mul(1_000))
        .then_some((self.event, self.epoch, self.sender))
    }
}

/// One circle's keys and its outbox slot.
#[derive(Default)]
struct CircleKeys {
    /// The circle's outbox slot: the lowest free when its first key was
    /// installed, its own until it is forgotten. `None` when every slot was
    /// taken; such a circle offers nothing.
    slot: Option<CircleSlot>,
    /// Bumped each time the circle falls silent on mesh. An offer is made
    /// only at the turn its send-time check read.
    turn: u64,
    /// Newest first, at most one an epoch number. After a sync that answered
    /// with a turn, the first is the key of the epoch the engine stands on.
    keys: Vec<EpochKey>,
    /// Whether the store holds something else than `keys`.
    unsaved: bool,
    /// The packets that opened as an update of this circle and whose events
    /// the engine has not taken in, oldest first, one an event id and at
    /// most [`HELD_PER_CIRCLE`]. The mesh engine hands a packet out once, so
    /// each is offered again from here at every drive.
    held: VecDeque<HeldUpdate>,
    /// The updates waiting to be passed on, the newest of each member and at
    /// most [`BRIDGE_PER_CIRCLE`]. In memory alone, and gone whenever the
    /// circle falls silent: an epoch change, input held unread, a leave.
    bridge: Vec<Candidate>,
    /// When an update of each member was last passed on, on the clock of the
    /// drive that did.
    bridged: Vec<(MemberId, u64)>,
}

impl CircleKeys {
    /// Empties the circle's slot, ends the turn any send still holds, and
    /// drops what waited to be passed on.
    fn silence(&mut self, ring: &MeshKeys) {
        self.turn += 1;
        self.bridge.clear();
        if let Some(slot) = self.slot {
            ring.handoff.purge(slot);
        }
    }

    /// [`MeshKeys::hold`], for this circle.
    fn hold(&mut self, update: HeldUpdate) -> Vec<PacketId> {
        if let Some(held) = (self.held.iter_mut()).find(|held| held.event.id == update.event.id) {
            held.bridgeable &= update.bridgeable;
            return vec![update.packet];
        }
        self.held.push_back(update);
        let over = self.held.len().saturating_sub(HELD_PER_CIRCLE);
        self.held.drain(..over).map(|held| held.packet).collect()
    }

    fn rows(&self) -> Vec<StoredMeshKey> {
        self.keys
            .iter()
            .map(|key| StoredMeshKey {
                epoch: key.epoch,
                routing: key.routing,
                exporter: key.exporter.clone(),
            })
            .collect()
    }
}

/// What a send-time check read of its circle ([`MeshKeys::align`]): the hand-
/// off that follows is made only if nothing silenced the circle in between.
pub(super) struct Turn {
    circle: GroupId,
    at: u64,
}

/// What a send reads of its circle before its send-time check
/// ([`MeshKeys::before`]): the circle's turn, `None` while the ring holds
/// nothing of it, and how often a circle the ring holds nothing of fell
/// silent.
pub(super) type Before = (Option<u64>, u64);

/// On whose behalf a circle's keys are brought in line.
#[derive(Clone, Copy)]
enum Caller<'a> {
    /// An engine batch that names the circle, or mesh being turned on.
    /// `rewound`: the batch said a branch was reselected or the circle
    /// joined anew. `stands`: whether the circle's row still exists, asked
    /// only before a key is installed.
    Batch {
        rewound: bool,
        stands: &'a dyn Fn() -> bool,
    },
    /// A location's send-time check, which has just read that the circle's
    /// row stands. The relay send is behind it, so it waits for nothing: the
    /// ring's lock is only tried, the store is not touched, and a deadline
    /// that has passed is left for the next batch to act on. `before` is
    /// [`MeshKeys::before`] as read before the check began: a circle can be
    /// silenced with no engine hold, so one silenced while the check ran is
    /// answered no turn. `None` when the ring's lock was held then.
    Send { before: Option<Before> },
}

/// What the ring has cost, for a test to read; nothing in a shipped build.
#[derive(Default)]
struct Counts {
    #[cfg(any(test, feature = "test-utils"))]
    derives: std::sync::atomic::AtomicUsize,
    #[cfg(any(test, feature = "test-utils"))]
    wraps: std::sync::atomic::AtomicUsize,
    #[cfg(any(test, feature = "test-utils"))]
    writes: std::sync::atomic::AtomicUsize,
    #[cfg(any(test, feature = "test-utils"))]
    opens: std::sync::atomic::AtomicUsize,
    #[cfg(any(test, feature = "test-utils"))]
    ingests: std::sync::atomic::AtomicUsize,
    /// A test asked that the next mesh ingest read as one the engine kept
    /// nothing of.
    #[cfg(any(test, feature = "test-utils"))]
    unkept: AtomicBool,
}

/// One thing the ring did that a test counts.
#[derive(Clone, Copy)]
enum Cost {
    /// A packet key derived from an exporter secret (one HKDF).
    Derive,
    /// A packet sealed (one AEAD).
    Wrap,
    /// A write asked of the store.
    Write,
    /// A packet tried under one key (one AEAD open).
    Open,
    /// An event a packet carried handed to the engine.
    Ingest,
}

impl Counts {
    #[cfg(any(test, feature = "test-utils"))]
    fn one(&self, cost: Cost) {
        match cost {
            Cost::Derive => &self.derives,
            Cost::Wrap => &self.wraps,
            Cost::Write => &self.writes,
            Cost::Open => &self.opens,
            Cost::Ingest => &self.ingests,
        }
        .fetch_add(1, Ordering::Relaxed);
    }

    #[cfg(not(any(test, feature = "test-utils")))]
    #[allow(clippy::unused_self)]
    const fn one(&self, _cost: Cost) {}
}

/// The key ring, its store and the hand-off it fills.
pub(super) struct MeshKeys {
    /// The instant mesh goes off by itself, wall-clock milliseconds; zero
    /// while it is off.
    until_ms: AtomicU64,
    /// The latest instant any caller handed over: a clock set back brings
    /// the deadline no further away.
    latest_ms: AtomicU64,
    /// Whether some circle's keys are still to be saved ([`Self::flush`]).
    owed: AtomicBool,
    /// Whether mesh went off and the store could not be told
    /// ([`Self::finish_off`]).
    undeleted: AtomicBool,
    /// The circles forgotten whose stored keys the store did not delete:
    /// asked again by [`Self::flush`].
    forgotten: Mutex<Vec<GroupId>>,
    /// How often a circle the ring holds nothing of fell silent, or every
    /// circle did: what a send of such a circle is checked against, since no
    /// turn is kept for it ([`Self::before`]).
    unkeyed_silences: AtomicU64,
    /// Never held across the store or the engine, so the hand-off, which
    /// only tries it, is never kept from it for longer than one packet takes
    /// to seal or to be tried under every key.
    ring: Mutex<HashMap<GroupId, CircleKeys>>,
    store: Arc<dyn MeshKeyStore>,
    handoff: Arc<Handoff>,
    counts: Counts,
    /// Run once at a send's key sync, after its send-time check: where a
    /// test silences a circle between the two.
    #[cfg(any(test, feature = "test-utils"))]
    after_send_check: Mutex<Option<SendCheckHook>>,
}

#[cfg(any(test, feature = "test-utils"))]
type SendCheckHook = Box<dyn FnOnce(&SessionManager) + Send>;

impl MeshKeys {
    /// Mesh off, nothing kept, no store.
    pub(super) fn new() -> Self {
        Self {
            until_ms: AtomicU64::new(0),
            latest_ms: AtomicU64::new(0),
            owed: AtomicBool::new(false),
            undeleted: AtomicBool::new(false),
            forgotten: Mutex::new(Vec::new()),
            unkeyed_silences: AtomicU64::new(0),
            ring: Mutex::new(HashMap::new()),
            store: Arc::new(NoMeshKeyStore),
            handoff: Arc::new(Handoff::default()),
            counts: Counts::default(),
            #[cfg(any(test, feature = "test-utils"))]
            after_send_check: Mutex::new(None),
        }
    }

    /// Installs the store the ring is kept in and restores what an earlier
    /// process kept — if mesh is still on at `now_ms`. With no deadline
    /// stored, or one that has passed, every stored key is deleted instead.
    /// A stored deadline further ahead than [`MESH_ON_MAX_MS`] was written
    /// under a later clock, and is brought back to that.
    ///
    /// `stands` says whether a circle's row still exists. A key of a circle
    /// whose row is gone — left or disbanded, with the delete of its keys
    /// unmade — is not restored: it is deleted, and a delete the store does
    /// not take stays owed ([`Self::flush`]).
    pub(super) fn install(
        &mut self,
        store: Arc<dyn MeshKeyStore>,
        now_ms: u64,
        stands: &dyn Fn(&GroupId) -> bool,
    ) {
        self.store = store;
        let now = self.now(now_ms);
        let stored = self.store.mesh_on_until().unwrap_or(0);
        let until = stored.min(now.saturating_add(MESH_ON_MAX_MS));
        if until <= now || (until != stored && !self.write_until(Some(until))) {
            self.clear();
            return;
        }
        let mut ring = HashMap::<GroupId, CircleKeys>::new();
        let mut standing = HashMap::<GroupId, bool>::new();
        for (group, row) in self.store.mesh_keys() {
            if !*standing
                .entry(group.clone())
                .or_insert_with(|| stands(&group))
            {
                continue;
            }
            self.counts.one(Cost::Derive);
            (ring.entry(group).or_default().keys).push(EpochKey::new(
                row.epoch,
                row.routing,
                row.exporter,
            ));
        }
        for (slot, circle) in (0..Handoff::SLOTS).zip(ring.values_mut()) {
            circle.slot = Some(CircleSlot(slot));
        }
        for circle in ring.values_mut() {
            let stored = circle.keys.len();
            circle.keys.sort_by_key(|key| std::cmp::Reverse(key.epoch));
            circle.keys.dedup_by_key(|key| key.epoch);
            let newest = circle.keys.first().map_or(0, |key| key.epoch);
            (circle.keys).retain(|key| key.epoch.saturating_add(PAST_EPOCHS) >= newest);
            if circle.keys.len() != stored {
                circle.unsaved = true;
                self.owed.store(true, Ordering::Relaxed);
            }
        }
        for (group, _) in standing.into_iter().filter(|(_, stands)| !stands) {
            self.counts.one(Cost::Write);
            if !self.store.save_mesh_keys(&group, &[]) {
                self.forgotten().push(group);
                self.owed.store(true, Ordering::Relaxed);
            }
        }
        *self.ring() = ring;
        self.until_ms.store(until, Ordering::Relaxed);
    }

    /// The hand-off this ring fills.
    fn handoff(&self) -> Arc<Handoff> {
        Arc::clone(&self.handoff)
    }

    fn ring(&self) -> MutexGuard<'_, HashMap<GroupId, CircleKeys>> {
        self.ring.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn forgotten(&self) -> MutexGuard<'_, Vec<GroupId>> {
        self.forgotten
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
    }

    /// What a send reads of `group` before its send-time check; `None` when
    /// the ring's lock is held, and the send then gets no turn.
    fn before(&self, group: &GroupId) -> Option<Before> {
        let ring = self.ring.try_lock().ok()?;
        // Read under the ring's lock, which every silence is made under.
        Some((
            ring.get(group).map(|circle| circle.turn),
            self.unkeyed_silences.load(Ordering::Relaxed),
        ))
    }

    /// `now_ms`, or the latest instant seen if that is later.
    fn now(&self, now_ms: u64) -> u64 {
        self.latest_ms
            .fetch_max(now_ms, Ordering::Relaxed)
            .max(now_ms)
    }

    /// Whether a deadline stands, passed or not: read before a clock is.
    fn armed(&self) -> bool {
        self.until_ms.load(Ordering::Relaxed) != 0
    }

    /// Whether a deadline stands that has not passed at `now_ms`.
    fn lit(&self, now_ms: u64) -> bool {
        self.left_ms(now_ms) != 0
    }

    /// How long from `now_ms` the deadline is; zero when none stands or it
    /// has passed.
    fn left_ms(&self, now_ms: u64) -> u64 {
        (self.until_ms.load(Ordering::Relaxed)).saturating_sub(self.now(now_ms))
    }

    /// Whether mesh is on at `now_ms`. A deadline that has passed turns it
    /// off here: the first batch to see it deletes every key.
    fn on<H: Held>(&self, held: &H, now_ms: u64) -> bool {
        if self.lit(now_ms) {
            return true;
        }
        if self.armed() {
            self.turn_off(held);
        }
        false
    }

    /// The ring: waited for, or for a send only tried.
    fn ring_for(&self, caller: Caller<'_>) -> Option<MutexGuard<'_, HashMap<GroupId, CircleKeys>>> {
        match caller {
            Caller::Batch { .. } => Some(self.ring()),
            Caller::Send { .. } => self.ring.try_lock().ok(),
        }
    }

    fn write_until(&self, until_ms: Option<u64>) -> bool {
        self.counts.one(Cost::Write);
        self.store.set_mesh_on_until(until_ms)
    }

    /// Mesh on until `until_ms`, or until [`MESH_ON_MAX_MS`] from `now_ms` if
    /// that is sooner. A deadline that is not ahead of the clock, or that the
    /// store did not take, is mesh off. Returns whether mesh is on.
    ///
    /// A deadline that passed with nothing to see it is mesh off first: what
    /// is turned on now starts with no key of before.
    fn turn_on<H: Held>(&self, held: &H, until_ms: u64, now_ms: u64) -> bool {
        self.on(held, now_ms);
        let now = self.now(now_ms);
        let until = until_ms.min(now.saturating_add(MESH_ON_MAX_MS));
        if until <= now || !self.write_until(Some(until)) {
            self.turn_off(held);
            return false;
        }
        self.until_ms.store(until, Ordering::Relaxed);
        true
    }

    /// Mesh off: every key dropped, every slot emptied, the deadline and
    /// every stored key deleted. Returns whether the store took the delete;
    /// one it did not take is asked again ([`Self::finish_off`]).
    fn turn_off<H: Held>(&self, _held: &H) -> bool {
        self.clear()
    }

    fn clear(&self) -> bool {
        self.until_ms.store(0, Ordering::Relaxed);
        self.owed.store(false, Ordering::Relaxed);
        self.forgotten().clear();
        let circles = std::mem::take(&mut *self.ring());
        for slot in circles.values().filter_map(|circle| circle.slot) {
            self.handoff.purge(slot);
        }
        drop(circles);
        let deleted = self.write_until(None);
        self.undeleted.store(!deleted, Ordering::Relaxed);
        deleted
    }

    /// Asks the store again for a delete it did not take when mesh went off.
    fn finish_off<H: Held>(&self, _held: &H) {
        if self.undeleted.load(Ordering::Relaxed) {
            self.undeleted
                .store(!self.write_until(None), Ordering::Relaxed);
        }
    }

    /// The exporter secret of the epoch `group` stands stable on.
    ///
    /// `None` while a commit is staged, twice over: the circle is not stable
    /// then, and what MDK exports is the staged epoch's. A staged epoch's
    /// secret is so never read, and there is none to discard at a rollback.
    fn current<H: Held>(held: &H, group: &GroupId) -> Option<(u64, Zeroizing<[u8; 32]>)> {
        let epoch = held.stable_epoch(group)?;
        let (at, secret) = held.exporter(group)?;
        let mut exporter = Zeroizing::new([0; 32]);
        if at != epoch || secret.len() != exporter.len() {
            return None;
        }
        exporter.copy_from_slice(&secret);
        Some((epoch, exporter))
    }

    /// Brings `group`'s keys in line with the engine, in memory, and answers
    /// the circle's turn when its newest key is that of the epoch the engine
    /// stands stable on.
    ///
    /// - Mesh off, the circle not stable, or its exporter unreadable: no key
    ///   is installed and the circle is silenced.
    /// - The engine's key is already held: nothing is derived and nothing
    ///   changes, unless a key is held that the engine's contradicts.
    /// - Otherwise it is installed, if the circle's row stands, with the
    ///   routing id the circle has now; a circle whose row is gone is
    ///   forgotten.
    /// - A key held at or above the engine's epoch that is not the engine's
    ///   is an abandoned branch's, and so may be every other: all go. So do
    ///   all when the batch said the circle was rewound.
    /// - A key more than [`DEFAULT_MAX_PAST_EPOCHS`] behind goes.
    ///
    /// Any change silences the circle and leaves it to be saved
    /// ([`Self::flush`]). Epochs crossed inside one engine call get no key:
    /// only the epoch the engine stands on can be exported. For a send that
    /// finds the ring's lock held, nothing: no turn, so no hand-off; and no
    /// turn for a send during whose check its circle fell silent — another
    /// circle's silence is not this one's.
    fn align<H: Held>(
        &self,
        held: &H,
        group: &GroupId,
        now_ms: u64,
        caller: Caller<'_>,
    ) -> Option<Turn> {
        let (rewound, on) = match caller {
            Caller::Batch { rewound, .. } => (rewound, self.on(held, now_ms)),
            Caller::Send { .. } => (false, self.lit(now_ms)),
        };
        if !on {
            return None;
        }
        let Some((epoch, exporter)) = Self::current(held, group) else {
            if let Some(circle) = self.ring_for(caller)?.get_mut(group) {
                circle.silence(self);
                if rewound && !circle.keys.is_empty() {
                    circle.keys.clear();
                    circle.unsaved = true;
                    self.owed.store(true, Ordering::Relaxed);
                }
            }
            return None;
        };
        let held_already = (self.ring_for(caller)?.get(group))
            .is_some_and(|circle| circle.keys.iter().any(|key| key.is(epoch, &exporter)));
        let fresh = if held_already {
            None
        } else {
            if let Caller::Batch { stands, .. } = caller {
                if !stands() {
                    if self.ring().contains_key(group) {
                        self.forget(held, group);
                    }
                    return None;
                }
            }
            let Some(routing) = held.routing_id(group) else {
                if let Some(circle) = self.ring_for(caller)?.get_mut(group) {
                    circle.silence(self);
                }
                return None;
            };
            self.counts.one(Cost::Derive);
            Some(EpochKey::new(epoch, routing, exporter.clone()))
        };

        let mut ring = self.ring_for(caller)?;
        let taken = ring
            .values()
            .filter_map(|circle| circle.slot)
            .fold(0_u64, |taken, slot| taken | 1 << slot.0);
        let circle = ring.entry(group.clone()).or_default();
        let before = circle.keys.len();
        let rewound = rewound
            || (circle.keys.iter()).any(|key| key.epoch >= epoch && !key.is(epoch, &exporter));
        circle.keys.retain(|key| {
            if rewound {
                key.is(epoch, &exporter)
            } else {
                key.epoch.saturating_add(PAST_EPOCHS) >= epoch
            }
        });
        let changed = fresh.is_some() || circle.keys.len() != before;
        if let Some(key) = fresh {
            circle.keys.insert(0, key);
        }
        if changed {
            if circle.slot.is_none() {
                let free = (!taken).trailing_zeros();
                circle.slot = (free < Handoff::SLOTS).then_some(CircleSlot(free));
            }
            circle.silence(self);
            circle.unsaved = true;
            self.owed.store(true, Ordering::Relaxed);
        }
        let at = circle.turn;
        // The key this sync installed bumped the turn once itself. A circle
        // the ring held nothing of had no turn to read: it stands at the
        // turn its entry was made with, and no such circle fell silent.
        let silenced = match caller {
            Caller::Batch { .. } => false,
            Caller::Send { before: None } => true,
            Caller::Send {
                before: Some((Some(turn), _)),
            } => turn + u64::from(changed) != at,
            Caller::Send {
                before: Some((None, unkeyed)),
            } => {
                at != u64::from(changed) || unkeyed != self.unkeyed_silences.load(Ordering::Relaxed)
            }
        };
        drop(ring);
        (!silenced).then(|| Turn {
            circle: group.clone(),
            at,
        })
    }

    /// Saves every circle whose keys the store does not hold as they are.
    ///
    /// Not called from a location's send, which never waits on this store:
    /// what a send installed is saved by the next engine batch, and at the
    /// latest by the one that makes it a past epoch's. The store is written
    /// with the ring's lock released.
    fn flush<H: Held>(&self, _held: &H) {
        if !self.owed.swap(false, Ordering::Relaxed) {
            return;
        }
        // A forgotten circle's delete the store did not take, asked again —
        // unless the circle is keyed again: its save replaces every row.
        let forgotten = std::mem::take(&mut *self.forgotten());
        for group in forgotten {
            if let Some(circle) = self.ring().get_mut(&group) {
                circle.unsaved = true;
                continue;
            }
            self.counts.one(Cost::Write);
            if !self.store.save_mesh_keys(&group, &[]) {
                self.forgotten().push(group);
                self.owed.store(true, Ordering::Relaxed);
            }
        }
        let unsaved: Vec<(GroupId, Vec<StoredMeshKey>)> = (self.ring().iter_mut())
            .filter(|(_, circle)| circle.unsaved)
            .map(|(group, circle)| {
                circle.unsaved = false;
                (group.clone(), circle.rows())
            })
            .collect();
        for (group, rows) in unsaved {
            self.counts.one(Cost::Write);
            if !self.store.save_mesh_keys(&group, &rows) {
                if let Some(circle) = self.ring().get_mut(&group) {
                    circle.unsaved = true;
                }
                self.owed.store(true, Ordering::Relaxed);
            }
        }
    }

    /// Drops `group`'s keys, in memory and in the store, and frees its slot:
    /// the circle was left, disbanded or forgotten. A delete the store does
    /// not take stays owed ([`Self::flush`]).
    pub(super) fn forget<H: Held>(&self, _held: &H, group: &GroupId) {
        if !self.armed() {
            return;
        }
        let gone = self.ring().remove(group);
        if let Some(slot) = gone.and_then(|circle| circle.slot) {
            self.handoff.purge(slot);
        }
        self.counts.one(Cost::Write);
        if !self.store.save_mesh_keys(group, &[]) {
            self.forgotten().push(group.clone());
            self.owed.store(true, Ordering::Relaxed);
        }
    }

    /// Empties `group`'s outbox slot: the relay path would not send for the
    /// circle now, so nothing sealed before this goes out by mesh either.
    pub(super) fn silence(&self, group: &GroupId) {
        if !self.armed() {
            return;
        }
        match self.ring().get_mut(group) {
            Some(circle) => circle.silence(self),
            None => {
                self.unkeyed_silences.fetch_add(1, Ordering::Relaxed);
            }
        }
    }

    /// [`Self::silence`], for every circle.
    fn silence_all(&self) {
        if !self.armed() {
            return;
        }
        let mut ring = self.ring();
        self.unkeyed_silences.fetch_add(1, Ordering::Relaxed);
        for circle in ring.values_mut() {
            circle.silence(self);
        }
    }

    /// `packet` tried under every key of the ring, until one opens it: the
    /// event it carried, rebuilt under that key's routing id — `None` in the
    /// second place when it does not verify (Security Rule 16) — and what
    /// the event is checked against next. `None` when no key opens it.
    fn try_keys(&self, packet: &Packet) -> Option<(PacketId, Option<Opened>)> {
        let ring = self.ring();
        ring.iter().find_map(|(group, circle)| {
            circle.keys.iter().find_map(|key| {
                self.counts.one(Cost::Open);
                let parts = open(&key.mesh, packet)?;
                let opened = rebuild(&parts, &key.routing).map(|event| Opened {
                    packet: packet.id(),
                    circle: group.clone(),
                    event,
                    bridgeable: parts.format == Format::Bridgeable,
                    epoch: key.epoch,
                    exporter: key.exporter.clone(),
                });
                Some((packet.id(), opened))
            })
        })
    }

    /// Holds the update a packet carried until the engine takes it in;
    /// `content` is the digest of the MLS message its event carries. Answers
    /// the packets this settles: the packet itself when its circle is gone
    /// or holds the event already, and the oldest ones past the circle's
    /// quota.
    fn hold(&self, opened: Opened, content: [u8; 32]) -> Vec<PacketId> {
        let Opened {
            packet,
            circle,
            event,
            bridgeable,
            ..
        } = opened;
        (self.ring().get_mut(&circle)).map_or_else(
            || vec![packet],
            |circle| {
                let turn = circle.turn;
                circle.hold(HeldUpdate {
                    packet,
                    event,
                    content,
                    bridgeable,
                    turn,
                })
            },
        )
    }

    /// What one drive offers the engine: for each circle that holds any, its
    /// oldest held events, at most [`DRIVE_PER_CIRCLE`].
    fn due(&self) -> Vec<(GroupId, Vec<Event>)> {
        (self.ring().iter())
            .filter(|(_, circle)| !circle.held.is_empty())
            .map(|(group, circle)| {
                let events = (circle.held.iter().take(DRIVE_PER_CIRCLE))
                    .map(|held| held.event.clone())
                    .collect();
                (group.clone(), events)
            })
            .collect()
    }

    /// The digest the engine announces the held event `id` of `group`
    /// under, once it reads it.
    fn content_of(&self, group: &GroupId, id: &EventId) -> Option<[u8; 32]> {
        let ring = self.ring();
        let content = (ring.get(group)?.held.iter())
            .find(|held| held.event.id == *id)
            .map(|held| held.content);
        drop(ring);
        content
    }

    /// The engine took in the event `id` of `group`: the update, held no
    /// longer.
    fn taken_in(&self, group: &GroupId, id: &EventId) -> Option<HeldUpdate> {
        let mut ring = self.ring();
        let held = &mut ring.get_mut(group)?.held;
        let at = held.iter().position(|held| held.event.id == *id)?;
        let update = held.remove(at);
        drop(ring);
        update
    }

    /// Keeps `candidate` to be passed on at `group`'s own next send: the
    /// newest of its sender alone, and none past the circle's share or every
    /// circle's together — the mesh is lossy by design, and so is this.
    #[cfg(test)]
    fn wait_to_bridge(&self, group: &GroupId, candidate: Candidate) {
        Self::keep(&mut self.ring(), group, candidate);
    }

    /// [`Self::keep`], if `group` stands at `turn` still: the turn its
    /// packet was opened at ([`HeldUpdate::turn`]).
    fn wait_to_bridge_at(&self, group: &GroupId, candidate: Candidate, turn: u64) {
        let mut ring = self.ring();
        if ring.get(group).is_some_and(|circle| circle.turn == turn) {
            Self::keep(&mut ring, group, candidate);
        }
    }

    fn keep(ring: &mut HashMap<GroupId, CircleKeys>, group: &GroupId, candidate: Candidate) {
        let waiting: usize = ring.values().map(|circle| circle.bridge.len()).sum();
        if let Some(circle) = ring.get_mut(group) {
            let stamp = |event: &Event| (event.created_at, event.id);
            let room = circle.bridge.len() < BRIDGE_PER_CIRCLE && waiting < BRIDGE_WAITING;
            match (circle.bridge.iter_mut()).find(|waits| waits.sender == candidate.sender) {
                Some(waits) if stamp(&candidate.event) > stamp(&waits.event) => *waits = candidate,
                None if room => circle.bridge.push(candidate),
                _ => {}
            }
        }
    }

    /// What `group` kept to pass on, newest first — or, with `None`, what
    /// every circle kept — taken: whatever is not sent by the drive that
    /// takes it is never sent.
    pub(super) fn take_bridge(&self, group: Option<&GroupId>) -> Vec<Candidate> {
        let mut ring = self.ring();
        let mut taken: Vec<Candidate> = match group {
            Some(group) => (ring.get_mut(group))
                .map(|circle| std::mem::take(&mut circle.bridge))
                .unwrap_or_default(),
            None => (ring.values_mut())
                .flat_map(|circle| std::mem::take(&mut circle.bridge))
                .collect(),
        };
        drop(ring);
        taken.sort_by_key(|waits| std::cmp::Reverse((waits.event.created_at, waits.event.id)));
        taken
    }

    /// Whether an update of `sender` may be passed on for `group` at
    /// `now_ms`, [`BRIDGE_SENDER_GAP_MS`] after the last; if so, this one is
    /// the last. A clock set back passes none on until it has caught up.
    pub(super) fn bridges(&self, group: &GroupId, sender: &MemberId, now_ms: u64) -> bool {
        let mut ring = self.ring();
        let passes = ring.get_mut(group).is_some_and(|circle| {
            (circle.bridged).retain(|(_, at)| now_ms.saturating_sub(*at) < BRIDGE_SENDER_GAP_MS);
            let waits = circle.bridged.iter().any(|(member, _)| member == sender);
            if !waits {
                circle.bridged.push((sender.clone(), now_ms));
            }
            !waits
        });
        drop(ring);
        passes
    }

    /// Wraps `event` under its circle's newest key, as a packet of `format`,
    /// and leaves it in the hand-off — if the circle still stands at `turn`,
    /// has a slot, and the event is one a packet carries. Otherwise, and
    /// when the ring's lock is held, nothing: the caller is the relay send,
    /// and the mesh is lossy by design.
    fn offer<R: RngCore + CryptoRng>(
        &self,
        turn: &Turn,
        event: &Event,
        format: Format,
        rng: &mut R,
    ) {
        let Ok(circles) = self.ring.try_lock() else {
            return;
        };
        let Some(circle) = circles.get(&turn.circle).filter(|c| c.turn == turn.at) else {
            return;
        };
        let (Some(slot), Some(key)) = (circle.slot, circle.keys.first()) else {
            return;
        };
        let Some(parts) = parts_of(event, format) else {
            return;
        };
        self.counts.one(Cost::Wrap);
        if let Some(packet) = wrap(&key.mesh, &parts, rng) {
            // Inside the ring's lock, so no purge of this slot falls between
            // the turn read above and this.
            self.handoff.offer(slot, packet, parts.expiration);
        }
    }
}

impl SessionManager {
    /// Where this session leaves the locations it wraps for the mesh engine:
    /// the engine's owner takes what waits before each engine call. The same
    /// hand-off for the life of the session; a new session has a new one,
    /// with every slot numbered afresh.
    #[must_use]
    pub fn mesh_handoff(&self) -> Arc<Handoff> {
        self.mesh_keys.handoff()
    }

    /// How long mesh stays on by this session's clock, milliseconds: never
    /// more than [`MESH_ON_MAX_MS`], and zero when it is off. What the mesh
    /// engine's owner sets the engine's own deadline by. Reads the deadline
    /// alone, as [`Self::mesh_is_on`] does: one found passed is left for the
    /// next engine batch to act on.
    #[must_use]
    pub fn mesh_on_for_ms(&self) -> u64 {
        self.mesh_keys.left_ms(self.legacy_now_ms())
    }

    /// The user stopped sharing: nothing sealed before this goes out by
    /// mesh. Keys are kept — the mesh still receives.
    pub fn mesh_sharing_stopped(&self) {
        self.mesh_keys.silence_all();
    }

    /// Empties `group`'s outbox slot ([`MeshKeys::silence`]).
    pub(crate) fn mesh_silence(&self, group: &GroupId) {
        self.mesh_keys.silence(group);
    }

    /// The one hand-off (plan §5.1): wraps `event` under the key of the epoch
    /// it was sealed at and leaves the packet for the mesh engine.
    ///
    /// Called by the location's own send, after its send-time check and
    /// before its relay send. Nothing when mesh is off, the circle has no
    /// key or slot, the circle was silenced since the check read `record`,
    /// the event does not fit a packet, or the ring's lock is held.
    /// Synchronous, no I/O, no engine hold; cannot fail and cannot wait.
    ///
    /// A location sealed for the mesh alone goes out as the format no member
    /// passes on to a relay (plan §4.1): it never passed a send-time check
    /// made after a receive.
    pub(crate) fn mesh_offer(&self, event: &Event, record: &LocationToSend) {
        if let Some(turn) = &record.mesh_turn {
            let format = if record.mesh_only {
                Format::NeverBridged
            } else {
                Format::Bridgeable
            };
            self.mesh_keys.offer(turn, event, format, &mut OsRng);
        }
    }

    /// Whether mesh is on at `now_ms`, read off the deadline alone: no
    /// engine hold, no lock, and a deadline found passed is left for the
    /// next engine batch to act on.
    pub(crate) fn mesh_is_on(&self, now_ms: u64) -> bool {
        self.mesh_keys.lit(now_ms)
    }

    /// What a location's send-time check reads of `group` before it checks
    /// anything, and hands [`Self::mesh_turn`] after ([`Caller::Send`]).
    pub(super) fn mesh_silences(&self, group: &GroupId) -> Option<Before> {
        self.mesh_keys.before(group)
    }

    /// What a location's send-time check hands [`Self::mesh_offer`]: the
    /// circle's key brought in line with the engine in that check's own
    /// hold, where the circle stands stable on the epoch the location was
    /// sealed at. In memory only, and waiting for nothing ([`Caller::Send`]).
    /// `silences` is [`Self::mesh_silences`], read before the check.
    pub(super) fn mesh_turn<H: Held>(
        &self,
        held: &H,
        group: &GroupId,
        now_ms: u64,
        silences: Option<Before>,
    ) -> Option<Turn> {
        #[cfg(any(test, feature = "test-utils"))]
        {
            let hook = (self.mesh_keys.after_send_check.lock())
                .unwrap_or_else(PoisonError::into_inner)
                .take();
            if let Some(hook) = hook {
                hook(self);
            }
        }
        let caller = Caller::Send { before: silences };
        self.mesh_keys.align(held, group, now_ms, caller)
    }

    /// What every engine batch is owed (`Self::note_effects`): the keys of
    /// each circle a state-bearing event names brought in line with the
    /// engine, the circles a proposal names silenced, and what is unsaved
    /// saved. With no event it is what a maintenance tick owes: a deadline
    /// that has passed ends every key, in memory and in the store, though no
    /// batch came to see it.
    ///
    /// A location received, invalidated or refused changes no key, and is
    /// the hot path: such an event visits no circle.
    pub(super) fn sync_mesh_keys<H: Held>(
        &self,
        held: &H,
        events: &[GroupEvent],
        proposals: &[GroupId],
    ) {
        let keys = &self.mesh_keys;
        if !keys.armed() {
            keys.finish_off(held);
            return;
        }
        let now_ms = self.legacy_now_ms();
        let mut seen: Vec<(&GroupId, bool)> = Vec::new();
        for event in events {
            // Every variant is named: a new one is decided at the bump that
            // brings it.
            let (group, rewound) = match event {
                GroupEvent::MessageReceived { .. }
                | GroupEvent::AppMessageInvalidated { .. }
                | GroupEvent::TransportObjectResourceRefused { .. } => continue,
                GroupEvent::GroupJoined { group_id, .. }
                | GroupEvent::CommitRolledBack { group_id, .. }
                | GroupEvent::GroupStateInvalidated { group_id, .. }
                | GroupEvent::GroupStateRevalidated { group_id, .. } => (group_id, true),
                GroupEvent::GroupCreated { group_id }
                | GroupEvent::GroupStateChanged { group_id, .. }
                | GroupEvent::GroupHydrationQuarantined { group_id, .. }
                | GroupEvent::EpochChanged { group_id, .. }
                | GroupEvent::GroupUnrecoverable { group_id }
                | GroupEvent::PendingCommitRecovered { group_id, .. }
                | GroupEvent::GroupHydrationRecovered { group_id, .. } => (group_id, false),
            };
            match seen.iter_mut().find(|(named, _)| *named == group) {
                Some((_, already)) => *already |= rewound,
                None => seen.push((group, rewound)),
            }
        }
        for &(group, rewound) in &seen {
            let stands = || self.commit_notes.circle_stands(group) == Some(true);
            keys.align(
                held,
                group,
                now_ms,
                Caller::Batch {
                    rewound,
                    stands: &stands,
                },
            );
        }
        for group in proposals {
            keys.silence(group);
        }
        if keys.on(held, now_ms) {
            keys.flush(held);
        }
    }

    /// Mesh on until `until_ms` ([`MeshKeys::turn_on`]), on this session's
    /// clock, with a key for every circle of `groups` that stands stable.
    pub(super) fn turn_mesh_on<H: Held>(
        &self,
        held: &H,
        until_ms: u64,
        groups: &[GroupId],
    ) -> bool {
        self.mesh_keys.turn_on(held, until_ms, self.legacy_now_ms())
            && self.sync_mesh_circles(held, groups)
    }

    /// The keys of every circle of `groups` brought in line with the engine
    /// and saved, if mesh is on, which it answers: what turning mesh on and
    /// every mesh drive begin with. A drive so reads a circle joined since
    /// the last batch that named it, and ends the keys of a deadline that
    /// has passed.
    pub(super) fn sync_mesh_circles<H: Held>(&self, held: &H, groups: &[GroupId]) -> bool {
        let (keys, now_ms) = (&self.mesh_keys, self.legacy_now_ms());
        if !keys.on(held, now_ms) {
            return false;
        }
        for group in groups {
            let stands = || self.commit_notes.circle_stands(group) == Some(true);
            keys.align(
                held,
                group,
                now_ms,
                Caller::Batch {
                    rewound: false,
                    stands: &stands,
                },
            );
        }
        keys.flush(held);
        true
    }

    /// Mesh off ([`MeshKeys::turn_off`]).
    pub(super) fn turn_mesh_off<H: Held>(&self, held: &H) -> bool {
        self.mesh_keys.turn_off(held)
    }

    /// One packet a mesh drive was handed, tried under every key. `None`
    /// when `drive` has its answer already: no key opened it, or one did and
    /// the event it carried does not verify.
    pub(super) fn mesh_opened(&self, packet: &MeshPacket, drive: &mut MeshDrive) -> Option<Opened> {
        match self.mesh_keys.try_keys(packet) {
            None => drive.read.push((packet.id(), false)),
            Some((id, None)) => drive.read.push((id, true)),
            Some((_, Some(opened))) => return Some(opened),
        }
        None
    }

    /// What becomes of a packet that opened and verified: held for the
    /// engine when its event is an `update` of its circle — an application
    /// message of the epoch its key is of, here by the digest of the MLS
    /// message it carries — and dropped as read when it is anything else.
    pub(super) fn mesh_keep(
        &self,
        opened: Opened,
        update: Option<[u8; 32]>,
        drive: &mut MeshDrive,
    ) {
        let Some(content) = update else {
            drive.read.push((opened.packet, true));
            return;
        };
        let settled = self.mesh_keys.hold(opened, content);
        (drive.read).extend(settled.into_iter().map(|id| (id, true)));
    }

    /// The id the engine announces the held `event` of `group` under once it
    /// reads it ([`HeldUpdate::content`]).
    pub(super) fn mesh_content(&self, group: &GroupId, event: &Event) -> Option<[u8; 32]> {
        self.mesh_keys.content_of(group, &event.id)
    }

    /// What a drive offers the engine ([`MeshKeys::due`]).
    pub(super) fn mesh_due(&self) -> Vec<(GroupId, Vec<Event>)> {
        self.mesh_keys.due()
    }

    /// Counts one event handed to the engine by a mesh drive, for a test.
    pub(super) fn mesh_ingesting(&self) {
        self.mesh_keys.counts.one(Cost::Ingest);
    }

    /// The engine took in `event`, which a packet carried for `group`: the
    /// packet is read. `update` is what the engine announced if it read in
    /// the event an update it had not read before
    /// ([`Self::ingest_from_mesh`]); such an update is kept to be passed on
    /// to the circle's relays (plan §5.5) when every packet of it said a
    /// member may ([`Format::Bridgeable`]), it is a fellow member's location
    /// ([`Candidate::of`]) and [`Self::keeps_to_pass_on`] holds. One the
    /// engine had read already — a relay delivered it, or the mesh did
    /// before — is announced as nothing, and so is never kept: an event is
    /// passed on once, by its id, whatever packets carry it.
    pub(crate) fn mesh_taken_in(
        &self,
        group: &GroupId,
        event: &Event,
        update: Option<&GroupEvent>,
        drive: &mut MeshDrive,
    ) {
        let Some(held) = self.mesh_keys.taken_in(group, &event.id) else {
            return;
        };
        drive.read.push((held.packet, true));
        let (own, turn) = (self.identity_pubkey().to_bytes(), held.turn);
        let candidate = update
            .filter(|_| held.bridgeable && self.keeps_to_pass_on(group))
            .and_then(|update| Candidate::of(held.event, update, &own));
        if let Some(candidate) = candidate {
            self.mesh_keys.wait_to_bridge_at(group, candidate, turn);
        }
    }
}

#[cfg(any(test, feature = "test-utils"))]
impl SessionManager {
    /// The epochs the ring holds a key for in `group`, newest first, each
    /// with the routing id recorded for it.
    #[must_use]
    pub fn mesh_key_epochs_for_test(&self, group: &GroupId) -> Vec<(u64, [u8; 32])> {
        (self.mesh_keys.ring().get(group))
            .map(|circle| {
                (circle.keys.iter())
                    .map(|key| (key.epoch, key.routing))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// The outbox slot the ring gave `group`, if it has one.
    #[must_use]
    pub fn mesh_slot_for_test(&self, group: &GroupId) -> Option<CircleSlot> {
        (self.mesh_keys.ring().get(group)).and_then(|circle| circle.slot)
    }

    /// `packet` opened as a receiver opens one: under every key the ring
    /// holds, then rebuilt with the routing id recorded for the key that
    /// opened it and verified. The circle, the key's epoch and the event.
    #[must_use]
    pub fn mesh_open_for_test(
        &self,
        packet: &crate::mesh::packet::Packet,
    ) -> Option<(GroupId, u64, Event)> {
        let ring = self.mesh_keys.ring();
        ring.iter().find_map(|(group, circle)| {
            circle.keys.iter().find_map(|key| {
                let parts = crate::mesh::packet::open(&key.mesh, packet)?;
                let event = crate::mesh::event::rebuild(&parts, &key.routing)?;
                Some((group.clone(), key.epoch, event))
            })
        })
    }

    /// How many packet keys the ring derived, packets it sealed and writes
    /// it asked of its store, since the session opened.
    #[must_use]
    pub fn mesh_costs_for_test(&self) -> (usize, usize, usize) {
        let counts = &self.mesh_keys.counts;
        (
            counts.derives.load(Ordering::Relaxed),
            counts.wraps.load(Ordering::Relaxed),
            counts.writes.load(Ordering::Relaxed),
        )
    }

    /// The instant mesh goes off at, zero while it is off.
    #[must_use]
    pub fn mesh_on_until_for_test(&self) -> u64 {
        self.mesh_keys.until_ms.load(Ordering::Relaxed)
    }

    /// Holds the ring's lock until the guard is dropped, as a task that is
    /// bringing a key in line holds it.
    pub fn hold_mesh_ring_for_test(&self) -> impl Drop + '_ {
        self.mesh_keys.ring()
    }

    /// Runs `hook` once, inside the next location's send-time hold, after
    /// its check and before its key sync.
    pub fn after_send_check_for_test(&self, hook: impl FnOnce(&Self) + Send + 'static) {
        *(self.mesh_keys.after_send_check.lock()).unwrap_or_else(PoisonError::into_inner) =
            Some(Box::new(hook));
    }

    /// How many times a packet was tried under a key, and how many events a
    /// mesh drive handed the engine, since the session opened.
    #[must_use]
    pub fn mesh_reads_for_test(&self) -> (usize, usize) {
        let counts = &self.mesh_keys.counts;
        (
            counts.opens.load(Ordering::Relaxed),
            counts.ingests.load(Ordering::Relaxed),
        )
    }

    /// Makes the next mesh ingest read as one the engine answered with a
    /// want of room, whatever it answered: no event a packet can carry draws
    /// that answer from the engine on cue.
    pub fn leave_next_mesh_ingest_unkept_for_test(&self) {
        self.mesh_keys.counts.unkept.store(true, Ordering::Relaxed);
    }

    /// Whether [`Self::leave_next_mesh_ingest_unkept_for_test`] was asked,
    /// once.
    pub(super) fn mesh_ingest_unkept_for_test(&self) -> bool {
        self.mesh_keys.counts.unkept.swap(false, Ordering::Relaxed)
    }

    /// How many packets `group` holds for the engine.
    #[must_use]
    pub fn mesh_held_for_test(&self, group: &GroupId) -> usize {
        (self.mesh_keys.ring().get(group)).map_or(0, |circle| circle.held.len())
    }

    /// The ids of the events `group` keeps to pass on to its relays.
    #[must_use]
    pub fn mesh_bridge_waiting_for_test(&self, group: &GroupId) -> Vec<EventId> {
        (self.mesh_keys.ring().get(group))
            .map(|circle| circle.bridge.iter().map(|waits| waits.event.id).collect())
            .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::sync::atomic::AtomicUsize;

    use base64::engine::general_purpose::STANDARD as BASE64;
    use base64::Engine as _;
    use nostr::{EventBuilder, JsonUtil as _, Keys, Kind, Tag, Timestamp};

    use super::*;
    use crate::mesh::event::rebuild;
    use crate::mesh::handoff::Op;
    use crate::mesh::packet::{cover_packet, open, Packet};
    use crate::mesh::test_rng::Scripted;
    use crate::nostr::mls::GroupIdExt as _;
    use crate::nostr::KIND_GROUP_MESSAGE;

    const NOW: u64 = 1_800_000_000_000;
    const HOUR: u64 = 60 * 60 * 1_000;

    // A ring entry's secret stays in a buffer that is wiped, and its packet
    // key in the type that wipes itself: demoting either field is a type
    // mismatch here (Security Rule 7).
    const _: fn(EpochKey) -> (Zeroizing<[u8; 32]>, MeshKey) = |key| (key.exporter, key.mesh);
    const EXPIRES_AT_SECS: u64 = 1_800_000_228;

    fn circle(n: u8) -> GroupId {
        GroupId::from_slice(&[n; 32])
    }

    /// The exporter secret of `epoch` on the branch `branch`.
    fn secret(epoch: u64, branch: u8) -> [u8; 32] {
        let mut secret = [branch; 32];
        secret[..8].copy_from_slice(&epoch.to_be_bytes());
        secret
    }

    /// What the engine says of one circle.
    #[derive(Clone, Copy)]
    struct Standing {
        stable: Option<u64>,
        exported: Option<(u64, [u8; 32])>,
        routing: Option<[u8; 32]>,
    }

    /// The engine as the ring reads it, set by the test.
    #[derive(Default)]
    struct Engine(RefCell<HashMap<GroupId, Standing>>);

    impl Engine {
        /// `group` stands stable on `epoch` of `branch`, routed by `routing`.
        fn stands(&self, group: &GroupId, epoch: u64, branch: u8, routing: u8) {
            self.0.borrow_mut().insert(
                group.clone(),
                Standing {
                    stable: Some(epoch),
                    exported: Some((epoch, secret(epoch, branch))),
                    routing: Some([routing; 32]),
                },
            );
        }

        fn set(&self, group: &GroupId, standing: Standing) {
            self.0.borrow_mut().insert(group.clone(), standing);
        }
    }

    impl Held for Engine {
        fn stable_epoch(&self, group: &GroupId) -> Option<u64> {
            self.0.borrow().get(group)?.stable
        }

        fn exporter(&self, group: &GroupId) -> Option<(u64, Zeroizing<Vec<u8>>)> {
            let (epoch, secret) = self.0.borrow().get(group)?.exported?;
            Some((epoch, Zeroizing::new(secret.to_vec())))
        }

        fn routing_id(&self, group: &GroupId) -> Option<[u8; 32]> {
            self.0.borrow().get(group)?.routing
        }
    }

    /// An engine whose exporter is a byte short.
    struct Short;

    impl Held for Short {
        fn stable_epoch(&self, _: &GroupId) -> Option<u64> {
            Some(4)
        }

        fn exporter(&self, _: &GroupId) -> Option<(u64, Zeroizing<Vec<u8>>)> {
            Some((4, Zeroizing::new(vec![0xa0; 31])))
        }

        fn routing_id(&self, _: &GroupId) -> Option<[u8; 32]> {
            Some([0x70; 32])
        }
    }

    type Row = (u64, [u8; 32], [u8; 32]);

    /// A store in memory. It counts its writes, refuses them on demand, and
    /// notes each one made while the ring's lock was held.
    #[derive(Default)]
    struct Store {
        until: Mutex<Option<u64>>,
        keys: Mutex<HashMap<GroupId, Vec<Row>>>,
        writes: AtomicUsize,
        refuses: AtomicBool,
        ring_is_free: Mutex<Option<Box<dyn Fn() -> bool + Send>>>,
        written_under_the_lock: AtomicUsize,
    }

    impl Store {
        fn written(&self) -> bool {
            self.writes.fetch_add(1, Ordering::Relaxed);
            let free = (self.ring_is_free.lock().unwrap().as_ref()).is_none_or(|free| free());
            if !free {
                self.written_under_the_lock.fetch_add(1, Ordering::Relaxed);
            }
            !self.refuses.load(Ordering::Relaxed)
        }

        fn writes(&self) -> usize {
            self.writes.load(Ordering::Relaxed)
        }

        /// The rows kept for `group`, newest first.
        fn rows(&self, group: &GroupId) -> Vec<Row> {
            let mut rows = (self.keys.lock().unwrap().get(group))
                .cloned()
                .unwrap_or_default();
            rows.sort_by_key(|row| std::cmp::Reverse(row.0));
            rows
        }

        fn is_empty(&self) -> bool {
            self.until.lock().unwrap().is_none() && self.keys.lock().unwrap().is_empty()
        }
    }

    impl MeshKeyStore for Store {
        fn mesh_on_until(&self) -> Option<u64> {
            *self.until.lock().unwrap()
        }

        fn set_mesh_on_until(&self, until_ms: Option<u64>) -> bool {
            if !self.written() {
                return false;
            }
            *self.until.lock().unwrap() = until_ms;
            if until_ms.is_none() {
                self.keys.lock().unwrap().clear();
            }
            true
        }

        fn mesh_keys(&self) -> Vec<(GroupId, StoredMeshKey)> {
            (self.keys.lock().unwrap().iter())
                .flat_map(|(group, rows)| {
                    rows.iter().map(|&(epoch, routing, exporter)| {
                        (
                            group.clone(),
                            StoredMeshKey {
                                epoch,
                                routing,
                                exporter: Zeroizing::new(exporter),
                            },
                        )
                    })
                })
                .collect()
        }

        fn save_mesh_keys(&self, group: &GroupId, keys: &[StoredMeshKey]) -> bool {
            if !self.written() {
                return false;
            }
            let rows: Vec<Row> = (keys.iter())
                .map(|key| (key.epoch, key.routing, *key.exporter))
                .collect();
            let mut stored = self.keys.lock().unwrap();
            if rows.is_empty() {
                stored.remove(group);
            } else {
                stored.insert(group.clone(), rows);
            }
            true
        }
    }

    struct Fixture {
        keys: Arc<MeshKeys>,
        engine: Engine,
        store: Arc<Store>,
    }

    /// A ring over `store`, opened at `now_ms`.
    fn opened(store: Arc<Store>, now_ms: u64) -> Fixture {
        opened_without(store, now_ms, &[])
    }

    /// [`opened`], when the circles of `gone` have no row any more.
    fn opened_without(store: Arc<Store>, now_ms: u64, gone: &[GroupId]) -> Fixture {
        let mut keys = MeshKeys::new();
        keys.install(store.clone(), now_ms, &|group| !gone.contains(group));
        let keys = Arc::new(keys);
        let ring = Arc::downgrade(&keys);
        *store.ring_is_free.lock().unwrap() = Some(Box::new(move || {
            (ring.upgrade()).is_none_or(|keys| keys.ring.try_lock().is_ok())
        }));
        Fixture {
            keys,
            engine: Engine::default(),
            store,
        }
    }

    /// A ring with mesh on for an hour from [`NOW`].
    fn on() -> Fixture {
        let fx = opened(Arc::default(), NOW);
        assert!(fx.keys.turn_on(&fx.engine, NOW + HOUR, NOW));
        fx
    }

    impl Fixture {
        /// As one engine batch naming `group`: the sync, then the save.
        fn batch(&self, group: &GroupId, rewound: bool) -> Option<Turn> {
            let turn = self.sync_at(group, NOW, rewound, true);
            self.keys.flush(&self.engine);
            turn
        }

        /// A batch's sync of `group` at `now_ms`, with nothing saved after.
        fn sync_at(
            &self,
            group: &GroupId,
            now_ms: u64,
            rewound: bool,
            stands: bool,
        ) -> Option<Turn> {
            let stands = || stands;
            let caller = Caller::Batch {
                rewound,
                stands: &stands,
            };
            self.keys.align(&self.engine, group, now_ms, caller)
        }

        /// A send-time check's sync of `group` at `now_ms`.
        fn send_at(&self, group: &GroupId, now_ms: u64) -> Option<Turn> {
            let before = self.keys.before(group);
            let caller = Caller::Send { before };
            self.keys.align(&self.engine, group, now_ms, caller)
        }

        /// `group` moves to `epoch` of `branch` in one batch.
        fn moves(&self, group: &GroupId, epoch: u64, branch: u8) -> Option<Turn> {
            self.engine.stands(group, epoch, branch, 0x70);
            self.batch(group, false)
        }

        /// The epochs the ring holds for `group`, newest first, each with
        /// the branch its secret is of.
        fn held(&self, group: &GroupId) -> Vec<(u64, u8)> {
            (self.keys.ring().get(group))
                .map(|circle| {
                    (circle.keys.iter())
                        .map(|key| (key.epoch, key.exporter[31]))
                        .collect()
                })
                .unwrap_or_default()
        }

        /// The same of what the store holds.
        fn stored(&self, group: &GroupId) -> Vec<(u64, u8)> {
            (self.store.rows(group).iter())
                .map(|row| (row.0, row.2[31]))
                .collect()
        }

        fn slot(&self, group: &GroupId) -> Option<u32> {
            (self.keys.ring().get(group)).and_then(|circle| circle.slot.map(|slot| slot.0))
        }

        /// What waits in the hand-off: each slot, with its packet or `None`
        /// for a purge.
        fn waiting(&self) -> Vec<(u32, Option<Packet>)> {
            (self.keys.handoff.take().into_iter())
                .map(|(slot, op)| match op {
                    Op::Offer { packet, .. } => (slot.0, Some(packet)),
                    Op::Purge => (slot.0, None),
                })
                .collect()
        }

        fn costs(&self) -> (usize, usize, usize) {
            let counts = &self.keys.counts;
            (
                counts.derives.load(Ordering::Relaxed),
                counts.wraps.load(Ordering::Relaxed),
                counts.writes.load(Ordering::Relaxed),
            )
        }
    }

    /// A kind 445 in the shape a sealed location has, routed by `[0x70; 32]`.
    fn location() -> Event {
        let tag = |tag: [&str; 2]| Tag::parse(tag).expect("a tag");
        EventBuilder::new(Kind::Custom(KIND_GROUP_MESSAGE), BASE64.encode([7; 120]))
            .tags([
                tag(["h", &hex::encode([0x70; 32])]),
                tag(["expiration", &EXPIRES_AT_SECS.to_string()]),
            ])
            .custom_created_at(Timestamp::from_secs(EXPIRES_AT_SECS - 228))
            .sign_with_keys(&Keys::generate())
            .expect("sign")
    }

    fn offer(fx: &Fixture, turn: &Turn, event: &Event) {
        fx.keys.offer(turn, event, Format::Bridgeable, &mut OsRng);
    }

    /// The key of `epoch` on `branch`, as a peer derives it.
    fn peer_key(epoch: u64, branch: u8) -> MeshKey {
        MeshKey::derive(&secret(epoch, branch))
    }

    #[test]
    fn a_stable_circle_gets_the_key_of_its_epoch_in_memory_and_in_the_store() {
        let fx = on();
        let group = circle(1);
        let turn = fx.moves(&group, 4, 0xa0).expect("a key, so a turn");

        assert!(
            fx.held(&group) == [(4, 0xa0)],
            "the ring does not hold the epoch's key"
        );
        assert!(
            fx.store.rows(&group) == [(4, [0x70; 32], secret(4, 0xa0))],
            "the store does not hold the epoch's exporter secret and routing id"
        );
        assert!(
            fx.slot(&group) == Some(0),
            "the first circle keyed did not get the lowest slot"
        );

        let event = location();
        offer(&fx, &turn, &event);
        let [(0, Some(packet))] = &fx.waiting()[..] else {
            panic!("one packet waits, in the circle's slot");
        };
        let parts = open(&peer_key(4, 0xa0), packet).expect("the epoch's key opens it");
        assert!(
            rebuild(&parts, &[0x70; 32]).expect("it verifies").as_json() == event.as_json(),
            "the packet did not open as the event that was offered"
        );
        assert!(open(&peer_key(4, 0xa1), packet).is_none());
        assert!(
            fx.store.written_under_the_lock.load(Ordering::Relaxed) == 0,
            "the store was written with the ring's lock held"
        );
    }

    /// While a commit is staged MDK exports the STAGED epoch's secret. It is
    /// never installed: not while the circle is pending, and not if the
    /// engine called it stable while a commit was staged. The confirm
    /// installs it; a rollback leaves no trace of it.
    #[test]
    fn a_staged_epochs_key_is_installed_at_the_confirm_and_never_before() {
        let fx = on();
        let group = circle(1);
        fx.moves(&group, 4, 0xa0);
        let staged = Standing {
            stable: None,
            exported: Some((5, secret(5, 0xa0))),
            routing: Some([0x70; 32]),
        };

        for standing in [
            staged,
            Standing {
                stable: Some(4),
                ..staged
            },
        ] {
            fx.engine.set(&group, standing);
            let before = fx.costs();
            assert!(fx.batch(&group, false).is_none());
            assert!(fx.held(&group) == [(4, 0xa0)] && fx.stored(&group) == [(4, 0xa0)]);
            assert!(
                fx.costs() == before,
                "a staged commit cost a derivation or a write"
            );
        }

        // Rolled back: the circle stands where it stood, and nothing of the
        // staged epoch was ever held to discard.
        fx.engine.stands(&group, 4, 0xa0, 0x70);
        assert!(fx.batch(&group, false).is_some());
        assert!(fx.held(&group) == [(4, 0xa0)] && fx.stored(&group) == [(4, 0xa0)]);

        // Staged again, and confirmed.
        fx.engine.set(&group, staged);
        assert!(fx.batch(&group, false).is_none());
        fx.engine.stands(&group, 5, 0xa0, 0x70);
        assert!(fx.batch(&group, false).is_some());
        assert!(
            fx.held(&group) == [(5, 0xa0), (4, 0xa0)],
            "the confirm did not install the new epoch's key beside the last"
        );
        assert!(
            fx.stored(&group) == [(5, 0xa0), (4, 0xa0)],
            "the confirm's key was not saved"
        );
    }

    #[test]
    fn keys_are_pruned_in_step_with_the_engines_window() {
        let fx = on();
        let group = circle(1);
        for epoch in 1..=6 {
            fx.moves(&group, epoch, 0xa0);
        }
        let all: Vec<(u64, u8)> = (1..=6).rev().map(|epoch| (epoch, 0xa0)).collect();
        assert!(fx.held(&group) == all && fx.stored(&group) == all);

        // The sixth change: the first epoch is the sixth behind, and goes.
        fx.moves(&group, 7, 0xa0);
        assert!(
            fx.held(&group)
                == [
                    (7, 0xa0),
                    (6, 0xa0),
                    (5, 0xa0),
                    (4, 0xa0),
                    (3, 0xa0),
                    (2, 0xa0)
                ],
            "the sixth epoch change left the oldest key in the ring",
        );
        assert!(
            fx.stored(&group) == fx.held(&group),
            "the sixth epoch change left the oldest key in the store"
        );
        assert!(
            fx.held(&group).len() == DEFAULT_MAX_PAST_EPOCHS + 1,
            "the ring holds more or fewer epochs than the engine's window"
        );
    }

    /// Only the epoch the engine stands on can be exported: the epochs one
    /// engine call crossed get no key, and the ones behind them are kept
    /// while they are inside the window.
    #[test]
    fn epochs_crossed_in_one_engine_call_get_no_key() {
        let fx = on();
        let group = circle(1);
        fx.moves(&group, 3, 0xa0);
        fx.moves(&group, 6, 0xa0);
        assert!(
            fx.held(&group) == [(6, 0xa0), (3, 0xa0)],
            "an epoch the engine never stood on has a key, or the one before the gap lost its"
        );
        assert!(
            fx.stored(&group) == [(6, 0xa0), (3, 0xa0)],
            "the store and the ring differ after a gap"
        );

        fx.moves(&group, 9, 0xa0);
        assert!(
            fx.held(&group) == [(9, 0xa0), (6, 0xa0)],
            "a key outside the window survived a gap, or one inside it did not"
        );
        assert!(
            fx.stored(&group) == [(9, 0xa0), (6, 0xa0)],
            "the store and the ring differ after a second gap"
        );

        fx.moves(&group, 40, 0xa0);
        assert!(fx.held(&group) == [(40, 0xa0)] && fx.stored(&group) == [(40, 0xa0)]);
    }

    /// One key an epoch number. Another branch at the same height replaces
    /// the key, and every key behind it goes, whether the batch said a branch
    /// was reselected or not.
    #[test]
    fn a_branch_reselected_at_the_same_height_replaces_the_key_and_drops_the_past() {
        for told in [true, false] {
            let fx = on();
            let group = circle(1);
            for epoch in 3..=5 {
                fx.moves(&group, epoch, 0xa0);
            }
            let turn = fx.batch(&group, false).expect("a turn");

            fx.engine.stands(&group, 5, 0xb0, 0x70);
            let next = fx.batch(&group, told).expect("a turn");
            assert!(fx.held(&group) == [(5, 0xb0)] && fx.stored(&group) == [(5, 0xb0)]);
            assert!(
                next.at != turn.at,
                "the reselection did not silence the circle"
            );

            // A send that read its turn on the abandoned branch offers
            // nothing; one that read it since is wrapped under the new key.
            let event = location();
            offer(&fx, &turn, &event);
            assert!(fx.waiting() == [(0, None)]);
            offer(&fx, &next, &event);
            let [(0, Some(packet))] = &fx.waiting()[..] else {
                panic!("one packet waits");
            };
            assert!(open(&peer_key(5, 0xb0), packet).is_some());
            assert!(open(&peer_key(5, 0xa0), packet).is_none());
        }
    }

    /// A reselection the batch told of drops the past keys even when the
    /// engine's own key is one the ring already holds.
    #[test]
    fn a_reselection_drops_the_past_keys_of_a_branch_that_was_kept() {
        let fx = on();
        let group = circle(1);
        for epoch in 3..=5 {
            fx.moves(&group, epoch, 0xa0);
        }
        let (derived, _, _) = fx.costs();
        assert!(fx.batch(&group, true).is_some());
        assert!(fx.held(&group) == [(5, 0xa0)] && fx.stored(&group) == [(5, 0xa0)]);
        assert!(
            fx.costs().0 == derived,
            "a key the ring held was derived again"
        );
    }

    /// A rewind below the newest key held, or onto a longer branch: no key of
    /// the abandoned branch outlives it.
    #[test]
    fn a_reselection_to_another_height_keeps_no_abandoned_key() {
        let fx = on();
        let group = circle(1);
        for epoch in 3..=6 {
            fx.moves(&group, epoch, 0xa0);
        }
        // Back to epoch 5 of another branch, with no word of it in the batch.
        fx.moves(&group, 5, 0xb0);
        assert!(fx.held(&group) == [(5, 0xb0)] && fx.stored(&group) == [(5, 0xb0)]);

        // On to a longer third branch, told.
        fx.engine.stands(&group, 8, 0xc0, 0x70);
        fx.batch(&group, true);
        assert!(fx.held(&group) == [(8, 0xc0)] && fx.stored(&group) == [(8, 0xc0)]);
    }

    /// A reselection that leaves the circle unstable confirms no key: none
    /// is kept.
    #[test]
    fn a_reselection_that_leaves_no_stable_epoch_drops_every_key() {
        let fx = on();
        let group = circle(1);
        fx.moves(&group, 4, 0xa0);
        fx.moves(&group, 5, 0xa0);
        fx.engine.set(
            &group,
            Standing {
                stable: None,
                exported: None,
                routing: None,
            },
        );
        assert!(fx.batch(&group, true).is_none());
        assert!(fx.held(&group).is_empty() && fx.store.rows(&group).is_empty());
    }

    #[test]
    fn each_key_records_the_routing_id_of_its_epoch() {
        let fx = on();
        let group = circle(1);
        fx.engine.stands(&group, 4, 0xa0, 0x70);
        fx.batch(&group, false);
        // The circle's routing id rotates at epoch 5.
        fx.engine.stands(&group, 5, 0xa0, 0x71);
        fx.batch(&group, false);

        let routed: Vec<(u64, [u8; 32])> = (fx.keys.ring().get(&group).expect("held").keys.iter())
            .map(|key| (key.epoch, key.routing))
            .collect();
        assert!(
            routed == [(5, [0x71; 32]), (4, [0x70; 32])],
            "a key does not carry the routing id of its own epoch"
        );
        assert!(
            fx.store.rows(&group)
                == [
                    (5, [0x71; 32], secret(5, 0xa0)),
                    (4, [0x70; 32], secret(4, 0xa0)),
                ],
            "a stored key does not carry the routing id of its own epoch",
        );
    }

    /// No key without a routing id to rebuild its events with, and none of
    /// an exporter that is not thirty-two bytes.
    #[test]
    fn a_circle_whose_routing_or_exporter_cannot_be_read_gets_no_key() {
        let fx = on();
        let group = circle(1);
        let stable = Standing {
            stable: Some(4),
            exported: Some((4, secret(4, 0xa0))),
            routing: None,
        };
        fx.engine.set(&group, stable);
        assert!(fx.batch(&group, false).is_none() && fx.held(&group).is_empty());

        let stands = || true;
        let caller = Caller::Batch {
            rewound: false,
            stands: &stands,
        };
        assert!(fx.keys.align(&Short, &group, NOW, caller).is_none());
        assert!(fx.held(&group).is_empty() && !fx.store.is_empty());
        assert!(fx.store.rows(&group).is_empty());
    }

    /// A circle whose row is gone — left with its MLS group kept, or never
    /// finished being made — gets no key, and loses what it held.
    #[test]
    fn a_circle_whose_row_is_gone_gets_no_key_and_keeps_none() {
        let fx = on();
        let group = circle(1);
        fx.engine.stands(&group, 4, 0xa0, 0x70);
        assert!(fx.sync_at(&group, NOW, false, false).is_none());
        assert!(fx.held(&group).is_empty() && fx.store.rows(&group).is_empty());
        assert!(
            fx.costs().0 == 0,
            "a key was derived for a circle with no row"
        );

        fx.moves(&group, 4, 0xa0);
        fx.engine.stands(&group, 5, 0xa0, 0x70);
        assert!(fx.sync_at(&group, NOW, false, false).is_none());
        assert!(fx.held(&group).is_empty() && fx.store.rows(&group).is_empty());
        assert!(fx.waiting() == [(0, None)]);
    }

    /// The common case costs nothing: a sync that finds the engine where the
    /// ring has it derives no key and writes no row, as a batch and as a
    /// send.
    #[test]
    fn a_sync_that_changes_nothing_derives_nothing_and_writes_nothing() {
        let fx = on();
        let (one, two) = (circle(1), circle(2));
        fx.moves(&one, 4, 0xa0);
        fx.moves(&one, 5, 0xa0);
        fx.moves(&two, 9, 0xb0);
        let (before, turn) = (fx.costs(), fx.batch(&one, false).expect("a turn"));
        let _ = fx.waiting();

        for _ in 0..3 {
            let again = fx.batch(&one, false).expect("a turn");
            let sent = fx.send_at(&one, NOW);
            assert!(again.at == turn.at && sent.is_some_and(|sent| sent.at == turn.at));
            fx.batch(&two, false);
        }
        assert!(
            fx.costs() == before,
            "a sync that changed nothing derived a key, sealed a packet or asked for a write"
        );
        assert!(
            fx.store.writes() == before.2,
            "a sync that changed nothing wrote to the store"
        );
        assert!(fx.waiting().is_empty(), "an unchanged circle was silenced");
    }

    /// A send installs a key the batches missed, in memory: the store is
    /// written by the next batch, of any circle, and never by the send.
    #[test]
    fn a_send_writes_no_row_and_the_next_batch_saves_what_it_installed() {
        let fx = on();
        let (one, two) = (circle(1), circle(2));
        fx.moves(&one, 4, 0xa0);
        fx.moves(&two, 9, 0xb0);
        let (writes, _) = (fx.store.writes(), fx.waiting());

        fx.engine.stands(&one, 5, 0xa0, 0x70);
        let turn = fx.send_at(&one, NOW).expect("a turn");
        assert!(
            fx.held(&one) == [(5, 0xa0), (4, 0xa0)],
            "a send did not install, in memory, the key its batches missed"
        );
        assert!(fx.stored(&one) == [(4, 0xa0)] && fx.store.writes() == writes);
        let event = location();
        offer(&fx, &turn, &event);
        assert!(
            matches!(&fx.waiting()[..], [(0, Some(packet))] if open(&peer_key(5, 0xa0), packet).is_some())
        );

        fx.batch(&two, false);
        assert!(fx.stored(&one) == [(5, 0xa0), (4, 0xa0)] && fx.store.writes() == writes + 1);
        assert!(
            fx.store.written_under_the_lock.load(Ordering::Relaxed) == 0,
            "the store was written with the ring's lock held"
        );
    }

    #[test]
    fn a_save_the_store_refused_is_made_again_at_the_next_batch() {
        let fx = on();
        let group = circle(1);
        fx.moves(&group, 4, 0xa0);
        fx.store.refuses.store(true, Ordering::Relaxed);
        fx.moves(&group, 5, 0xa0);
        assert!(fx.held(&group) == [(5, 0xa0), (4, 0xa0)] && fx.stored(&group) == [(4, 0xa0)]);

        fx.store.refuses.store(false, Ordering::Relaxed);
        fx.batch(&circle(2), false);
        assert!(
            fx.stored(&group) == [(5, 0xa0), (4, 0xa0)],
            "a save the store refused was not made again"
        );
    }

    /// The deadline: none, passed, or not ahead of the clock is mesh off;
    /// one further ahead than twelve hours is brought back to twelve.
    #[test]
    fn mesh_is_on_only_until_a_deadline_no_more_than_twelve_hours_ahead() {
        let group = circle(1);
        let keyless = |fx: &Fixture| {
            fx.engine.stands(&group, 4, 0xa0, 0x70);
            fx.batch(&group, false).is_none() && fx.held(&group).is_empty() && fx.store.is_empty()
        };

        // Never turned on.
        let fx = opened(Arc::default(), NOW);
        assert!(keyless(&fx) && fx.costs().0 == 0);

        // A deadline at or behind the clock.
        for until in [0, NOW - 1, NOW] {
            let fx = opened(Arc::default(), NOW);
            assert!(!fx.keys.turn_on(&fx.engine, until, NOW));
            assert!(keyless(&fx));
        }

        // Further ahead than twelve hours: twelve hours.
        let fx = opened(Arc::default(), NOW);
        assert!(fx.keys.turn_on(&fx.engine, u64::MAX, NOW));
        assert!(
            fx.store.mesh_on_until() == Some(NOW + MESH_ON_MAX_MS),
            "a deadline further ahead than twelve hours was stored as asked"
        );
        assert!(
            fx.keys.until_ms.load(Ordering::Relaxed) == NOW + MESH_ON_MAX_MS,
            "a deadline further ahead than twelve hours was kept as asked"
        );
        assert!(fx.moves(&group, 4, 0xa0).is_some());

        // Asked again later, the deadline moves, and is still no further.
        assert!(fx.keys.turn_on(&fx.engine, u64::MAX, NOW + HOUR));
        assert!(
            fx.store.mesh_on_until() == Some(NOW + HOUR + MESH_ON_MAX_MS),
            "asked again, the deadline did not move to twelve hours from then"
        );
        assert!(fx.keys.turn_on(&fx.engine, NOW + 2 * HOUR, NOW + HOUR));
        assert!(
            fx.store.mesh_on_until() == Some(NOW + 2 * HOUR),
            "a nearer deadline was not taken as asked"
        );
        assert!(
            fx.held(&group) == [(4, 0xa0)],
            "moving the deadline cost the circle its key"
        );
    }

    /// Whichever caller first sees the deadline passed deletes every key, in
    /// memory and in the store, and empties every slot.
    #[test]
    fn a_deadline_that_passes_deletes_every_key_and_empties_every_slot() {
        let fx = on();
        let (one, two) = (circle(1), circle(2));
        fx.moves(&one, 4, 0xa0);
        fx.moves(&two, 9, 0xb0);
        let (turn, _) = (fx.batch(&one, false).expect("a turn"), fx.waiting());
        let event = location();
        offer(&fx, &turn, &event);
        assert!(matches!(&fx.waiting()[..], [(0, Some(_))]));
        offer(&fx, &turn, &event);

        // A millisecond before the deadline nothing changes.
        assert!(fx.sync_at(&two, NOW + HOUR - 1, false, true).is_some());
        assert!(fx.send_at(&one, NOW + HOUR - 1).is_some() && fx.held(&one) == [(4, 0xa0)]);

        // At it a send gets no turn, and touches neither the keys nor the
        // store: the relay send behind it waits for no delete.
        let writes = fx.store.writes();
        assert!(fx.send_at(&one, NOW + HOUR).is_none());
        assert!(fx.held(&one) == [(4, 0xa0)] && fx.store.writes() == writes);
        offer(&fx, &turn, &event);

        // The first batch to see it, of whichever circle, ends them all.
        assert!(fx.sync_at(&two, NOW + HOUR, false, true).is_none());
        assert!(fx.held(&one).is_empty() && fx.held(&two).is_empty());
        assert!(fx.store.is_empty() && !fx.keys.armed());
        assert!(fx.waiting() == [(0, None), (1, None)]);

        // And a turn read before it offers nothing after.
        offer(&fx, &turn, &event);
        assert!(fx.waiting().is_empty());
        assert!(fx.moves(&one, 5, 0xa0).is_none() && fx.store.is_empty());
    }

    /// A clock set back brings the deadline no further away: time is the
    /// latest instant any caller has handed over.
    #[test]
    fn a_clock_set_back_does_not_keep_mesh_on() {
        let fx = on();
        let group = circle(1);
        fx.moves(&group, 4, 0xa0);
        // A caller sees the clock a minute short of the deadline; the clock
        // is then set back eleven hours.
        assert!(fx.keys.on(&fx.engine, NOW + HOUR - 60_000));
        assert!(fx.keys.on(&fx.engine, NOW - 11 * HOUR));
        assert!(!fx
            .keys
            .turn_on(&fx.engine, NOW + HOUR - 60_000, NOW - 11 * HOUR));
        assert!(fx.held(&group).is_empty() && fx.store.is_empty());

        // Asked for again under the earlier clock, mesh is on for no longer
        // than twelve hours from the latest instant seen.
        assert!(fx.keys.turn_on(&fx.engine, u64::MAX, NOW - 11 * HOUR));
        assert!(
            fx.store.mesh_on_until() == Some(NOW + HOUR - 60_000 + MESH_ON_MAX_MS),
            "a clock set back bought more than twelve hours from the latest instant seen"
        );
    }

    /// At the open: a live deadline restores the keys an earlier process
    /// kept; none, or one that has passed, deletes them; one further ahead
    /// than twelve hours — written under a later clock — is brought back.
    #[test]
    fn the_open_restores_keys_under_a_live_deadline_and_deletes_them_otherwise() {
        let group = circle(1);
        let kept = || {
            let fx = on();
            for epoch in 3..=5 {
                fx.moves(&group, epoch, 0xa0);
            }
            fx.engine.stands(&group, 5, 0xa0, 0x71);
            fx.store
        };

        // Live: restored, newest first, at no cost to the store, and a
        // packet a peer sealed two epochs back still opens.
        let store = kept();
        let writes = store.writes();
        let fx = opened(store, NOW + 1);
        assert!(
            fx.held(&group) == [(5, 0xa0), (4, 0xa0), (3, 0xa0)],
            "the open did not restore the stored keys, newest first"
        );
        assert!(fx.store.writes() == writes && fx.slot(&group) == Some(0));
        let event = location();
        let parts = parts_of(&event, Format::Bridgeable).expect("a location");
        let packet = wrap(&peer_key(3, 0xa0), &parts, &mut OsRng).expect("fits");
        let ring = fx.keys.ring();
        let opened_by: Vec<u64> = (ring.get(&group).expect("held").keys.iter())
            .filter(|key| open(&key.mesh, &packet).is_some())
            .map(|key| key.epoch)
            .collect();
        drop(ring);
        assert!(
            opened_by == [3],
            "a packet sealed two epochs back did not open under that epoch's restored key alone"
        );
        // The engine stands where it stood: nothing is derived or written.
        fx.engine.stands(&group, 5, 0xa0, 0x70);
        let before = fx.costs();
        assert!(fx.batch(&group, false).is_some() && fx.costs() == before);

        // Passed while the app was not running.
        let fx = opened(kept(), NOW + HOUR);
        assert!(fx.held(&group).is_empty() && fx.store.is_empty() && !fx.keys.armed());

        // No deadline at all, with rows an earlier process left.
        let store = kept();
        *store.until.lock().unwrap() = None;
        let fx = opened(store, NOW);
        assert!(fx.held(&group).is_empty() && fx.store.is_empty());

        // Opened under a clock a day earlier than the one it was written
        // under: on for twelve hours of this clock, and stored so.
        let fx = opened(kept(), NOW - 24 * HOUR);
        assert!(
            fx.held(&group).len() == 3,
            "a deadline brought back to twelve hours cost the stored keys"
        );
        assert!(
            fx.store.mesh_on_until() == Some(NOW - 24 * HOUR + MESH_ON_MAX_MS),
            "a deadline written under a later clock was not brought back to twelve hours"
        );
    }

    /// Rows the ring would not have left — more than the window holds — are
    /// not restored, and the next batch deletes them.
    #[test]
    fn the_open_restores_no_key_outside_the_window() {
        let group = circle(1);
        let store = Arc::<Store>::default();
        *store.until.lock().unwrap() = Some(NOW + HOUR);
        store.keys.lock().unwrap().insert(
            group.clone(),
            (1..=9)
                .map(|epoch| (epoch, [0x70; 32], secret(epoch, 0xa0)))
                .collect(),
        );
        let fx = opened(store, NOW);
        let window: Vec<(u64, u8)> = (4..=9).rev().map(|epoch| (epoch, 0xa0)).collect();
        assert!(
            fx.held(&group) == window,
            "the open restored a key outside the window"
        );
        fx.batch(&circle(2), false);
        assert!(
            fx.stored(&group) == window,
            "the rows outside the window were not deleted by the next batch"
        );
    }

    #[test]
    fn mesh_off_deletes_every_key_and_a_refused_delete_is_asked_again() {
        let fx = on();
        let group = circle(1);
        fx.moves(&group, 4, 0xa0);
        fx.store.refuses.store(true, Ordering::Relaxed);
        assert!(!fx.keys.turn_off(&fx.engine));
        assert!(fx.held(&group).is_empty() && !fx.keys.armed());
        assert!(fx.waiting() == [(0, None)]);
        assert!(!fx.store.is_empty(), "premise: the store kept its rows");

        // Still refused: still owed.
        fx.keys.finish_off(&fx.engine);
        assert!(!fx.store.is_empty());
        fx.store.refuses.store(false, Ordering::Relaxed);
        fx.keys.finish_off(&fx.engine);
        assert!(fx.store.is_empty());
        let writes = fx.store.writes();
        fx.keys.finish_off(&fx.engine);
        assert!(
            fx.store.writes() == writes,
            "a delete that landed was made again"
        );
    }

    #[test]
    fn a_forgotten_circle_keeps_no_key_and_gives_up_its_slot() {
        let fx = on();
        let (one, two, three) = (circle(1), circle(2), circle(3));
        fx.moves(&one, 4, 0xa0);
        fx.moves(&two, 9, 0xb0);
        assert!(fx.slot(&one) == Some(0) && fx.slot(&two) == Some(1));
        let _ = fx.waiting();

        fx.keys.forget(&fx.engine, &one);
        assert!(fx.held(&one).is_empty() && fx.store.rows(&one).is_empty());
        assert!(fx.held(&two) == [(9, 0xb0)] && fx.stored(&two) == [(9, 0xb0)]);
        assert!(fx.waiting() == [(0, None)]);

        // The lowest free slot is the next circle's.
        fx.moves(&three, 2, 0xc0);
        assert!(fx.slot(&three) == Some(0) && fx.slot(&two) == Some(1));
    }

    /// Every slot taken, one more circle keeps its keys and offers nothing.
    #[test]
    fn a_circle_past_the_last_slot_has_keys_and_no_slot() {
        let fx = on();
        for n in 0..Handoff::SLOTS {
            let group = GroupId::from_slice(&n.to_be_bytes());
            fx.moves(&group, 1, 0xa0);
            assert!(
                fx.slot(&group) == Some(n),
                "a circle did not get the lowest free slot"
            );
        }
        let _ = fx.waiting();
        let extra = circle(0xee);
        let turn = fx.moves(&extra, 1, 0xa0).expect("a turn");
        assert!(fx.held(&extra) == [(1, 0xa0)] && fx.slot(&extra).is_none());
        offer(&fx, &turn, &location());
        assert!(fx.waiting().is_empty());
    }

    /// A circle silenced after a send read its turn is offered nothing by
    /// that send: a purge is not followed by the packet it was for.
    #[test]
    fn a_turn_read_before_the_circle_fell_silent_offers_nothing() {
        let fx = on();
        let (one, two) = (circle(1), circle(2));
        fx.moves(&one, 4, 0xa0);
        fx.moves(&two, 9, 0xb0);
        let (event, _) = (location(), fx.waiting());
        let silenced: [&dyn Fn(&Fixture); 4] = [
            &|fx| fx.keys.silence(&circle(1)),
            &|fx| fx.keys.silence_all(),
            &|fx| drop(fx.moves(&circle(1), 5, 0xa0)),
            &|fx| {
                fx.engine.set(
                    &circle(1),
                    Standing {
                        stable: None,
                        exported: None,
                        routing: None,
                    },
                );
                drop(fx.batch(&circle(1), false));
                fx.engine.stands(&circle(1), 5, 0xa0, 0x70);
            },
        ];
        for silence in silenced {
            let turn = fx.batch(&one, false).expect("a turn");
            offer(&fx, &turn, &event);
            assert!(matches!(&fx.waiting()[..], [(0, Some(_))]));

            offer(&fx, &turn, &event);
            silence(&fx);
            offer(&fx, &turn, &event);
            assert!(
                fx.waiting()
                    .iter()
                    .all(|(slot, op)| op.is_none() && *slot <= 1),
                "a packet waits for a circle that was silenced",
            );
        }
        // Another circle's silence is not this one's.
        let turn = fx.batch(&one, false).expect("a turn");
        fx.keys.silence(&two);
        offer(&fx, &turn, &event);
        assert!(matches!(&fx.waiting()[..], [(0, Some(_)), (1, None)]));
    }

    /// A send never waits for the ring: while another thread holds its lock,
    /// the send-time check and the offer both return at once, and leave
    /// nothing.
    #[test]
    fn an_offer_does_not_wait_for_the_rings_lock() {
        let fx = on();
        let group = circle(1);
        let turn = fx.moves(&group, 4, 0xa0).expect("a turn");
        let _ = fx.waiting();
        let event = location();

        // Held by another thread until the offer has returned — or, so that
        // an offer that waits fails here rather than hangs, until a watchdog
        // lets go.
        let (locked, returned) = (std::sync::mpsc::channel(), std::sync::mpsc::channel::<()>());
        let held_throughout = std::thread::scope(|scope| {
            let (keys, is_held, has_returned) = (&*fx.keys, locked.0, returned.1);
            let holder = scope.spawn(move || {
                let _held = keys.ring();
                is_held.send(()).expect("the test waits");
                (has_returned.recv_timeout(std::time::Duration::from_mins(1))).is_ok()
            });
            locked.1.recv().expect("the lock is held");
            fx.keys.offer(&turn, &event, Format::Bridgeable, &mut OsRng);
            // Nor does the send-time check before it: no turn, so no offer.
            fx.engine.stands(&group, 5, 0xa0, 0x70);
            let checked = fx.send_at(&group, NOW);
            let _ = returned.0.send(());
            holder.join().expect("the holder ends") && checked.is_none()
        });
        assert!(held_throughout, "a send waited for the ring's lock");
        assert!(
            fx.held(&group) == [(4, 0xa0)],
            "a send that found the ring's lock held installed a key"
        );
        fx.engine.stands(&group, 4, 0xa0, 0x70);
        assert!(fx.waiting().is_empty() && fx.costs().1 == 0);

        offer(&fx, &turn, &event);
        assert!(matches!(&fx.waiting()[..], [(0, Some(_))]) && fx.costs().1 == 1);
    }

    /// One packet, one fresh twelve-byte nonce from the generator, under the
    /// newest key, marked with the format it was offered as; an event a
    /// packet cannot carry draws nothing.
    #[test]
    fn an_offer_seals_once_under_the_newest_key_with_a_nonce_from_the_generator() {
        let fx = on();
        let group = circle(1);
        fx.moves(&group, 4, 0xa0);
        let turn = fx.moves(&group, 5, 0xa0).expect("a turn");
        let _ = fx.waiting();
        let event = location();

        let nonce: [u8; 12] = std::array::from_fn(|i| 0xc0 + u8::try_from(i).expect("small"));
        let mut rng = Scripted::new(&nonce);
        fx.keys.offer(&turn, &event, Format::Bridgeable, &mut rng);
        assert!(rng.is_spent() && fx.costs().1 == 1);
        let [(0, Some(packet))] = &fx.waiting()[..] else {
            panic!("one packet waits");
        };
        assert!(
            packet.as_bytes()[..12] == nonce,
            "the packet's nonce is not the generator's twelve bytes"
        );
        let format = |packet| open(&peer_key(5, 0xa0), packet).map(|parts| parts.format);
        assert_eq!(format(packet), Some(Format::Bridgeable));
        assert!(open(&peer_key(4, 0xa0), packet).is_none());
        let [(
            _,
            Op::Offer {
                packet,
                expires_at_secs,
            },
        )] = &{
            fx.keys
                .offer(&turn, &event, Format::NeverBridged, &mut OsRng);
            fx.keys.handoff.take()
        }[..]
        else {
            panic!("one packet waits");
        };
        assert!(
            *expires_at_secs == EXPIRES_AT_SECS,
            "the offer does not carry its event's expiration"
        );
        assert!(
            format(packet) == Some(Format::NeverBridged),
            "an offer made as never bridged does not say so in its packet"
        );

        // A commit carries no expiration: not a shape a packet holds.
        let commit = EventBuilder::new(Kind::Custom(KIND_GROUP_MESSAGE), BASE64.encode([7; 120]))
            .tags([Tag::parse(["h", &hex::encode([0x70; 32])]).expect("a tag")])
            .sign_with_keys(&Keys::generate())
            .expect("sign");
        fx.keys
            .offer(&turn, &commit, Format::Bridgeable, &mut Scripted::new(&[]));
        assert!(fx.waiting().is_empty() && fx.costs().1 == 2);
    }

    /// A send's turn is the one its check ran under. A circle is silenced
    /// with no engine hold — a leave asked, fetched input held — so one
    /// silenced after the check began and before the key sync read its turn
    /// is handed nothing by that send; the key the sync itself installs is
    /// no such silence, and neither is the silence of another circle.
    #[test]
    fn a_send_during_whose_check_its_circle_fell_silent_gets_no_turn() {
        let fx = on();
        let (one, two) = (circle(1), circle(2));
        fx.moves(&one, 4, 0xa0);
        fx.moves(&two, 9, 0xb0);
        let (event, _) = (location(), fx.waiting());
        let checked = |group: &GroupId, before| {
            let caller = Caller::Send { before };
            fx.keys.align(&fx.engine, group, NOW, caller)
        };

        let silenced: [&dyn Fn(); 2] = [&|| fx.keys.silence(&one), &|| fx.keys.silence_all()];
        for silence in silenced {
            let before = fx.keys.before(&one);
            silence();
            assert!(
                checked(&one, before).is_none(),
                "a send took the turn of a circle silenced while it checked"
            );
        }
        let _ = fx.waiting();

        // Another circle's silence, and one of a circle the ring holds
        // nothing of, are not this circle's: the send is offered.
        let before = fx.keys.before(&one);
        fx.keys.silence(&two);
        fx.keys.silence(&circle(3));
        let turn = checked(&one, before).expect("a turn");
        let _ = fx.waiting();
        offer(&fx, &turn, &event);
        assert!(
            matches!(&fx.waiting()[..], [(0, Some(_))]),
            "another circle's silence cost this one its hand-off"
        );

        // The sync installs the key of an epoch the ring had missed: that
        // silence is its own, and the send is offered.
        fx.engine.stands(&one, 5, 0xa0, 0x70);
        let turn = checked(&one, fx.keys.before(&one)).expect("a turn");
        let _ = fx.waiting();
        offer(&fx, &turn, &event);
        assert!(matches!(&fx.waiting()[..], [(0, Some(_))]));

        // The same install with a silence beside it: none.
        fx.engine.stands(&one, 6, 0xa0, 0x70);
        let before = fx.keys.before(&one);
        fx.keys.silence(&one);
        assert!(checked(&one, before).is_none() && fx.held(&one)[0] == (6, 0xa0));

        // A send that found the ring's lock held when it began gets none.
        assert!(checked(&one, None).is_none());
    }

    /// A circle the ring holds nothing of — made since the last batch — has
    /// no turn to read. Its first send installs its key and is offered; one
    /// during whose check it fell silent, by itself or with every circle, is
    /// not, though the ring kept no turn for it.
    #[test]
    fn a_circle_with_no_key_yet_that_fell_silent_while_a_send_checked_gets_no_turn() {
        type Silence<'a> = &'a dyn Fn(&Fixture, &GroupId);
        let silenced: [(Silence<'_>, bool); 4] = [
            (&|_, _| {}, true),
            (&|fx, group| fx.keys.silence(group), false),
            (&|fx, _| fx.keys.silence_all(), false),
            // A keyed circle's silence is not this one's.
            (&|fx, _| fx.keys.silence(&circle(2)), true),
        ];
        for (silence, offered) in silenced {
            let fx = on();
            let (new, keyed) = (circle(1), circle(2));
            fx.moves(&keyed, 9, 0xb0);
            fx.engine.stands(&new, 4, 0xa0, 0x70);
            let before = fx.keys.before(&new);
            assert!(
                matches!(before, Some((None, _))),
                "premise: the ring holds nothing"
            );
            silence(&fx, &new);
            let caller = Caller::Send { before };
            let turn = fx.keys.align(&fx.engine, &new, NOW, caller);
            assert!(
                turn.is_some() == offered && fx.held(&new) == [(4, 0xa0)],
                "a circle with no key yet was offered though it fell silent, or was not though \
                 nothing silenced it"
            );
        }
    }

    /// A deadline that passed with no batch to see it is mesh off: turned on
    /// again, the ring starts with no key of before, and neither does the
    /// store.
    #[test]
    fn mesh_turned_on_again_after_its_deadline_passed_unseen_keeps_no_key_of_before() {
        let fx = on();
        let group = circle(1);
        fx.moves(&group, 4, 0xa0);
        assert!(fx.keys.turn_on(&fx.engine, NOW + 3 * HOUR, NOW + 2 * HOUR));
        assert!(
            fx.held(&group).is_empty() && fx.store.rows(&group).is_empty(),
            "a key outlived the deadline it was kept under"
        );
        assert_eq!(fx.store.mesh_on_until(), Some(NOW + 3 * HOUR));
        assert!(fx.sync_at(&group, NOW + 2 * HOUR, false, true).is_some());
        assert_eq!(fx.held(&group), [(4, 0xa0)]);
    }

    /// A forgotten circle's delete the store refused stays owed: the next
    /// batch asks again, and once it lands it is not made a third time. A
    /// circle keyed again meanwhile is saved as a whole instead.
    #[test]
    fn a_forgotten_circles_delete_the_store_refused_is_asked_again() {
        let fx = on();
        let (one, two) = (circle(1), circle(2));
        fx.moves(&one, 4, 0xa0);
        fx.moves(&two, 9, 0xb0);

        fx.store.refuses.store(true, Ordering::Relaxed);
        fx.keys.forget(&fx.engine, &one);
        assert!(fx.held(&one).is_empty());
        assert!(
            fx.stored(&one) == [(4, 0xa0)],
            "premise: the store kept the forgotten circle's key"
        );
        // Still refused: still owed.
        fx.batch(&two, false);
        assert_eq!(fx.stored(&one), [(4, 0xa0)]);

        fx.store.refuses.store(false, Ordering::Relaxed);
        fx.batch(&two, false);
        assert!(
            fx.store.rows(&one).is_empty(),
            "a forgotten circle's key stayed stored after the store took writes again"
        );
        assert_eq!(fx.stored(&two), [(9, 0xb0)]);
        let writes = fx.store.writes();
        fx.batch(&two, false);
        assert!(
            fx.store.writes() == writes,
            "a delete that landed was made again"
        );

        // Forgotten, refused, and keyed again before the store answers: what
        // is stored is the new key alone.
        fx.store.refuses.store(true, Ordering::Relaxed);
        fx.keys.forget(&fx.engine, &two);
        fx.moves(&two, 10, 0xb1);
        assert_eq!(fx.stored(&two), [(9, 0xb0)]);
        fx.store.refuses.store(false, Ordering::Relaxed);
        fx.batch(&one, false);
        assert_eq!(fx.stored(&two), [(10, 0xb1)]);
    }

    /// A key whose circle has no row when the process opens — the circle was
    /// left and the delete of its keys did not land — is not restored, and
    /// is deleted; if the store refuses that too, the delete stays owed.
    #[test]
    fn the_open_restores_no_key_of_a_circle_whose_row_is_gone() {
        let (left, kept) = (circle(1), circle(2));
        let stored = || {
            let fx = on();
            fx.moves(&left, 4, 0xa0);
            fx.moves(&left, 5, 0xa0);
            fx.moves(&kept, 9, 0xb0);
            fx.store
        };

        let fx = opened_without(stored(), NOW + 1, std::slice::from_ref(&left));
        assert!(
            fx.held(&left).is_empty() && fx.store.rows(&left).is_empty(),
            "the open restored, or left stored, a key of a circle whose row is gone"
        );
        assert!(fx.held(&kept) == [(9, 0xb0)] && fx.stored(&kept) == [(9, 0xb0)]);
        assert!(
            fx.costs().0 == 1,
            "a packet key was derived for a circle whose row is gone"
        );

        // The store refuses the delete: owed, and made by the next batch.
        let store = stored();
        store.refuses.store(true, Ordering::Relaxed);
        let fx = opened_without(store, NOW + 1, std::slice::from_ref(&left));
        assert!(fx.held(&left).is_empty() && fx.stored(&left).len() == 2);
        fx.store.refuses.store(false, Ordering::Relaxed);
        fx.engine.stands(&kept, 9, 0xb0, 0x70);
        fx.batch(&kept, false);
        assert!(
            fx.store.rows(&left).is_empty(),
            "a delete the store refused at the open was not asked again"
        );
    }

    /// `event` in a packet sealed under the key of `epoch` on `branch`, with
    /// a nonce of its own: every call is another packet of the same event.
    fn packet_of(event: &Event, epoch: u64, branch: u8) -> Packet {
        let parts = parts_of(event, Format::Bridgeable).expect("a location");
        wrap(&peer_key(epoch, branch), &parts, &mut OsRng).expect("fits")
    }

    /// `packet`, opened and verified by the ring.
    fn read(fx: &Fixture, packet: &Packet) -> Opened {
        let (id, opened) = fx.keys.try_keys(packet).expect("a key opens it");
        assert!(id == packet.id());
        opened.expect("its event verifies")
    }

    /// The packet of the held `event` of `group`, taken as the engine's
    /// having taken the event in takes it.
    fn taken(fx: &Fixture, group: &GroupId, event: &Event) -> Option<PacketId> {
        (fx.keys.taken_in(group, &event.id)).map(|held| held.packet)
    }

    /// T-PERF-2: a packet costs one open a key the ring holds, at most, and
    /// none past the key that opens it — counted, not timed. What opens
    /// comes back as the event, under the routing id recorded for the key,
    /// with that key's epoch and secret; an event that does not verify under
    /// that routing id comes back as none.
    #[test]
    fn a_packet_is_tried_once_under_each_key_and_no_further_than_the_one_that_opens() {
        let fx = on();
        let (one, two, elsewhere) = (circle(1), circle(2), circle(3));
        for epoch in 1..=6 {
            fx.moves(&one, epoch, 0xa0);
        }
        for epoch in 1..=3 {
            fx.moves(&two, epoch, 0xb0);
        }
        fx.engine.stands(&elsewhere, 1, 0xc0, 0x71);
        fx.batch(&elsewhere, false);
        let keys = 6 + 3 + 1;
        let opens = || fx.keys.counts.opens.load(Ordering::Relaxed);

        let before = opens();
        assert!(fx.keys.try_keys(&cover_packet(&mut OsRng)).is_none());
        assert!(
            opens() - before == keys,
            "a packet no key opens was not tried under each key exactly once"
        );

        let event = location();
        for (group, epoch, branch) in [(&one, 6, 0xa0), (&one, 1, 0xa0), (&two, 2, 0xb0)] {
            let before = opens();
            let opened = read(&fx, &packet_of(&event, epoch, branch));
            assert!(
                (1..=keys).contains(&(opens() - before)),
                "a packet cost more opens than the ring holds keys"
            );
            assert!(opened.circle == *group && opened.epoch == epoch);
            assert_eq!(*opened.exporter, secret(epoch, branch));
            assert_eq!(opened.event.as_json(), event.as_json());
        }

        // Signed for another routing id than the one its key recorded, and
        // a signature that is not the event's: opened, and no event.
        let rerouted = fx.keys.try_keys(&packet_of(&event, 1, 0xc0));
        assert!(matches!(rerouted, Some((_, None))));
        let mut parts = parts_of(&event, Format::Bridgeable).expect("a location");
        parts.sig[0] ^= 1;
        let forged = wrap(&peer_key(6, 0xa0), &parts, &mut OsRng).expect("fits");
        assert!(matches!(fx.keys.try_keys(&forged), Some((id, None)) if id == forged.id()));
        // An abandoned branch's key of a held epoch opens nothing.
        assert!(fx.keys.try_keys(&packet_of(&event, 6, 0xa1)).is_none());
    }

    /// An update is one event id, however many packets carry it: held once,
    /// and its second packet is settled where it stands. Once the engine
    /// took it in it is held no longer; a later packet of it is offered to
    /// the engine again, which answers for a duplicate.
    #[test]
    fn an_update_is_held_once_by_its_event_id() {
        let fx = on();
        let group = circle(1);
        fx.moves(&group, 4, 0xa0);
        let event = location();
        let (first, again, later) = (
            packet_of(&event, 4, 0xa0),
            packet_of(&event, 4, 0xa0),
            packet_of(&event, 4, 0xa0),
        );
        assert!(
            first.id() != again.id(),
            "premise: two packets of one event"
        );

        assert!(fx.keys.hold(read(&fx, &first), [0; 32]).is_empty());
        assert!(
            fx.keys.hold(read(&fx, &again), [0; 32]) == [again.id()],
            "a second packet of a held event was held beside the first"
        );
        let due = fx.keys.due();
        assert!(due.len() == 1 && due[0].0 == group);
        assert!(due[0].1.len() == 1 && due[0].1[0].id == event.id);

        assert!(taken(&fx, &group, &event) == Some(first.id()));
        assert!(fx.keys.due().is_empty() && taken(&fx, &group, &event).is_none());
        assert!(
            fx.keys.hold(read(&fx, &later), [0; 32]).is_empty(),
            "a later packet of an update the engine took in was not offered to it again"
        );
        assert!(taken(&fx, &group, &event) == Some(later.id()));
    }

    /// Each circle holds its own quota: one that overflows loses its own
    /// oldest packets and none of another circle's, and a drive is offered
    /// no more of a circle than its share, oldest first.
    #[test]
    fn a_circle_holds_its_own_quota_and_a_drive_is_offered_a_bounded_share_of_it() {
        let fx = on();
        let (flooded, quiet) = (circle(1), circle(2));
        fx.moves(&flooded, 4, 0xa0);
        fx.moves(&quiet, 9, 0xb0);
        let kept: Vec<Event> = (0..2).map(|_| location()).collect();
        for event in &kept {
            assert!(fx
                .keys
                .hold(read(&fx, &packet_of(event, 9, 0xb0)), [0; 32])
                .is_empty());
        }

        let (mut packets, mut events, mut pushed_out) = (Vec::new(), Vec::new(), Vec::new());
        for _ in 0..HELD_PER_CIRCLE + 3 {
            let event = location();
            let packet = packet_of(&event, 4, 0xa0);
            pushed_out.extend(fx.keys.hold(read(&fx, &packet), [0; 32]));
            packets.push(packet.id());
            events.push(event.id);
        }
        assert!(
            pushed_out == packets[..3],
            "a circle over its quota did not give up its own oldest packets, in order"
        );
        let held = |group: &GroupId| {
            (fx.keys.ring().get(group).expect("held").held.iter())
                .map(|held| held.event.id)
                .collect::<Vec<_>>()
        };
        assert_eq!(held(&flooded), events[3..]);
        assert!(
            held(&quiet) == [kept[0].id, kept[1].id],
            "one circle's flood cost another circle a held packet"
        );

        let due: HashMap<GroupId, Vec<EventId>> = (fx.keys.due().into_iter())
            .map(|(group, events)| (group, events.iter().map(|event| event.id).collect()))
            .collect();
        assert_eq!(due[&flooded], events[3..3 + DRIVE_PER_CIRCLE]);
        assert_eq!(due[&quiet], [kept[0].id, kept[1].id]);
    }

    /// What a circle holds goes with the circle and with mesh; a packet that
    /// opened for a circle since forgotten is settled, not held.
    #[test]
    fn what_a_circle_holds_goes_with_the_circle_and_with_mesh() {
        let fx = on();
        let (one, two) = (circle(1), circle(2));
        fx.moves(&one, 4, 0xa0);
        fx.moves(&two, 9, 0xb0);
        let (event, other) = (location(), location());
        let packet = packet_of(&event, 4, 0xa0);
        let late = read(&fx, &packet_of(&other, 4, 0xa0));
        assert!(fx.keys.hold(read(&fx, &packet), [0; 32]).is_empty());
        assert!(fx
            .keys
            .hold(read(&fx, &packet_of(&other, 9, 0xb0)), [0; 32])
            .is_empty());

        fx.keys.forget(&fx.engine, &one);
        assert!(fx.keys.due().len() == 1 && fx.keys.try_keys(&packet).is_none());
        let late_packet = late.packet;
        assert!(fx.keys.hold(late, [0; 32]) == [late_packet]);

        assert!(fx.keys.turn_off(&fx.engine));
        assert!(fx.keys.due().is_empty());
    }

    /// What the engine announces for a location `sender` sent at `epoch`.
    fn announced(sender: u8, epoch: u64, payload: &[u8]) -> GroupEvent {
        GroupEvent::MessageReceived {
            group_id: circle(1),
            message_id: super::super::MessageId::new(vec![sender; 32]),
            sender: MemberId::new(vec![sender; 32]),
            epoch: super::super::EpochId(epoch),
            payload: payload.to_vec(),
            retention: None,
            authority: None,
        }
    }

    const FIX: &[u8] = br#"{"kind":25442,"content":"{}"}"#;
    const OWN: [u8; 32] = [0x0f; 32];

    /// A location event sealed `age_secs` before [`NOW`] that declares
    /// `life_secs` to live.
    fn sealed_ago(age_secs: u64, life_secs: u64) -> Event {
        let created = NOW / 1_000 - age_secs;
        let tag = |tag: [&str; 2]| Tag::parse(tag).expect("a tag");
        EventBuilder::new(Kind::Custom(KIND_GROUP_MESSAGE), BASE64.encode([7; 120]))
            .tags([
                tag(["h", &hex::encode([0x70; 32])]),
                tag(["expiration", &(created + life_secs).to_string()]),
            ])
            .custom_created_at(Timestamp::from_secs(created))
            .sign_with_keys(&Keys::generate())
            .expect("sign")
    }

    /// A candidate of `sender`, sealed `age_secs` before [`NOW`].
    fn candidate(sender: u8, age_secs: u64) -> Candidate {
        Candidate::of(sealed_ago(age_secs, 228), &announced(sender, 4, FIX), &OWN)
            .expect("a fellow member's location")
    }

    fn waiting(fx: &Fixture, group: &GroupId) -> Vec<EventId> {
        let ring = fx.keys.ring();
        (ring.get(group).expect("held").bridge.iter())
            .map(|waits| waits.event.id)
            .collect()
    }

    /// Only a location another member sent is kept to be passed on: not
    /// what this account sent, not an update that carries no location, and
    /// nothing the engine announced that is not an update.
    #[test]
    fn only_a_fellow_members_location_is_a_candidate() {
        let event = location();
        let kept = Candidate::of(event.clone(), &announced(0xa1, 9, FIX), &OWN)
            .expect("a fellow member's location is kept");
        assert!(kept.event.id == event.id && kept.epoch == 9);
        assert!(
            kept.sender == MemberId::new(vec![0xa1; 32]),
            "the candidate is not its sender's"
        );

        assert!(
            Candidate::of(event.clone(), &announced(0x0f, 9, FIX), &OWN).is_none(),
            "this account's own update was kept to be passed on"
        );
        for payload in [
            &br#"{"kind":9,"content":"hello"}"#[..],
            &br#"{"kind":25442,"content":""}"#[..],
            b"not json",
        ] {
            assert!(
                Candidate::of(event.clone(), &announced(0xa1, 9, payload), &OWN).is_none(),
                "an update that carries no location was kept to be passed on"
            );
        }
        let joined = GroupEvent::GroupCreated {
            group_id: circle(1),
        };
        assert!(Candidate::of(event, &joined, &OWN).is_none());
    }

    /// The window an event may be passed on in, both ends, by this device's
    /// clock: begun no later than ten seconds before a 228-second life ends
    /// — and before a shorter declared one does — never for an event that
    /// declares a longer life, and never for one stamped further ahead than
    /// a send takes.
    #[test]
    fn an_event_is_passed_on_only_inside_its_own_window() {
        let at = |event: &Event, now_ms: u64| {
            Candidate::of(event.clone(), &announced(0xa1, 4, FIX), &OWN)
                .expect("a candidate")
                .in_time(now_ms)
                .is_some()
        };
        let fresh = sealed_ago(0, 228);
        assert!(at(&fresh, NOW) && at(&fresh, NOW + 217_999));
        assert!(
            !at(&fresh, NOW + 218_000) && !at(&fresh, NOW + 500_000),
            "an event was passed on at or past 218 seconds"
        );
        let short = sealed_ago(0, 60);
        assert!(at(&short, NOW + 49_999) && !at(&short, NOW + 50_000));
        assert!(
            !at(&sealed_ago(0, 229), NOW) && !at(&sealed_ago(0, 86_400 * 365), NOW),
            "an event that declares a longer life than a location's was passed on"
        );
        // Stamped ahead of this clock: by a send's length at most.
        assert!(at(&fresh, NOW - 10_000));
        assert!(
            !at(&fresh, NOW - 10_001),
            "an event stamped ahead of the clock was passed on"
        );
        // An expiration before its own stamp, and none at all.
        let tag = |tag: [&str; 2]| Tag::parse(tag).expect("a tag");
        let bare = EventBuilder::new(Kind::Custom(KIND_GROUP_MESSAGE), "")
            .tags([tag(["h", &hex::encode([0x70; 32])])])
            .custom_created_at(Timestamp::from_secs(NOW / 1_000))
            .sign_with_keys(&Keys::generate())
            .expect("sign");
        assert!(!at(&bare, NOW));
    }

    /// An update is kept to pass on only at the turn its packet was opened
    /// at: a circle silenced in between — a branch reselected, an epoch
    /// moved — may no longer be the one its key was of.
    #[test]
    fn an_update_is_kept_only_if_nothing_silenced_its_circle_since_its_packet_opened() {
        let fx = on();
        let group = circle(1);
        fx.moves(&group, 4, 0xa0);
        let turn = |fx: &Fixture| fx.keys.ring().get(&group).expect("keyed").turn;

        let opened_at = turn(&fx);
        fx.keys
            .wait_to_bridge_at(&group, candidate(0xa1, 10), opened_at);
        assert!(waiting(&fx, &group).len() == 1, "premise: kept at its turn");
        let _ = fx.keys.take_bridge(Some(&group));

        fx.keys.silence(&group);
        assert!(turn(&fx) != opened_at, "premise: a silence is a new turn");
        fx.keys
            .wait_to_bridge_at(&group, candidate(0xa2, 10), opened_at);
        assert!(
            waiting(&fx, &group).is_empty(),
            "an update was kept to pass on though its circle was silenced since its \
             packet was opened"
        );
    }

    /// A circle keeps the newest update of each member, at most
    /// [`BRIDGE_PER_CIRCLE`] of them, and every circle together at most
    /// [`BRIDGE_WAITING`]; what is taken comes newest first and leaves
    /// nothing behind.
    #[test]
    fn a_circle_keeps_the_newest_of_each_member_and_a_bounded_number() {
        let fx = on();
        let group = circle(1);
        fx.moves(&group, 4, 0xa0);

        let (older, newer) = (candidate(0xa1, 30), candidate(0xa1, 10));
        let (older_id, newer_id) = (older.event.id, newer.event.id);
        fx.keys.wait_to_bridge(&group, newer);
        fx.keys.wait_to_bridge(&group, older);
        assert!(
            waiting(&fx, &group) == [newer_id],
            "an older update of a member replaced, or waits beside, a newer one"
        );
        fx.keys.wait_to_bridge(&group, candidate(0xa1, 5));
        assert!(waiting(&fx, &group).len() == 1 && waiting(&fx, &group) != [newer_id]);
        assert!(!waiting(&fx, &group).contains(&older_id));

        for (sender, age) in (0xb0..).zip([40, 20, 60, 50, 1]) {
            fx.keys.wait_to_bridge(&group, candidate(sender, age));
        }
        assert!(
            waiting(&fx, &group).len() == BRIDGE_PER_CIRCLE,
            "a circle kept more to pass on than its share"
        );
        let taken = fx.keys.take_bridge(Some(&group));
        let stamps: Vec<_> = (taken.iter()).map(|waits| waits.event.created_at).collect();
        assert!(taken.len() == BRIDGE_PER_CIRCLE && stamps.is_sorted_by(|a, b| a >= b));
        assert!(waiting(&fx, &group).is_empty() && fx.keys.take_bridge(Some(&group)).is_empty());

        // Every circle together.
        let circles: Vec<GroupId> = (10..).take(BRIDGE_WAITING).map(circle).collect();
        for other in &circles {
            fx.moves(other, 2, 0xc0);
            fx.keys.wait_to_bridge(other, candidate(0xa1, 3));
        }
        fx.keys.wait_to_bridge(&group, candidate(0xa2, 3));
        assert!(
            waiting(&fx, &group).is_empty(),
            "every circle together kept more to pass on than the bound"
        );
        assert_eq!(fx.keys.take_bridge(None).len(), BRIDGE_WAITING);
        // A circle the ring holds nothing of keeps nothing.
        fx.keys.wait_to_bridge(&circle(200), candidate(0xa1, 3));
        assert!(fx.keys.take_bridge(None).is_empty());
    }

    /// One update of a member is passed on, then none of that member for
    /// [`BRIDGE_SENDER_GAP_MS`], whatever other members send; a clock set
    /// back passes none on until it has caught up.
    #[test]
    fn a_member_is_passed_on_once_a_gap() {
        let fx = on();
        let group = circle(1);
        fx.moves(&group, 4, 0xa0);
        let (flooder, quiet) = (MemberId::new(vec![0xa1; 32]), MemberId::new(vec![0xa2; 32]));

        assert!(fx.keys.bridges(&group, &flooder, NOW));
        assert!(
            !fx.keys.bridges(&group, &flooder, NOW)
                && !fx
                    .keys
                    .bridges(&group, &flooder, NOW + BRIDGE_SENDER_GAP_MS - 1),
            "a second update of one member was passed on inside the gap"
        );
        assert!(
            fx.keys.bridges(&group, &quiet, NOW + 1),
            "one member's update cost another member its own"
        );
        assert!(fx
            .keys
            .bridges(&group, &flooder, NOW + BRIDGE_SENDER_GAP_MS));
        assert!(
            !fx.keys.bridges(&group, &flooder, NOW),
            "a clock set back passed a member's update on inside the gap"
        );
        assert!(!fx.keys.bridges(&circle(9), &flooder, NOW));
    }

    /// What a circle kept to pass on goes when the circle falls silent — an
    /// epoch change, a silence asked for it or for every circle — with the
    /// circle, and with mesh.
    #[test]
    fn what_waits_to_be_passed_on_goes_when_its_circle_falls_silent() {
        let fx = on();
        let (one, two) = (circle(1), circle(2));
        fx.moves(&one, 4, 0xa0);
        fx.moves(&two, 9, 0xb0);
        let keep = |fx: &Fixture| {
            for group in [&one, &two] {
                fx.keys.wait_to_bridge(group, candidate(0xa1, 3));
            }
        };

        keep(&fx);
        fx.moves(&one, 5, 0xa0);
        assert!(
            waiting(&fx, &one).is_empty() && waiting(&fx, &two).len() == 1,
            "an epoch change kept what waited, or cost another circle its own"
        );
        keep(&fx);
        fx.keys.silence(&one);
        assert!(waiting(&fx, &one).is_empty() && waiting(&fx, &two).len() == 1);
        keep(&fx);
        fx.keys.silence_all();
        assert!(waiting(&fx, &one).is_empty() && waiting(&fx, &two).is_empty());
        keep(&fx);
        fx.keys.forget(&fx.engine, &one);
        assert_eq!(fx.keys.take_bridge(None).len(), 1);
        keep(&fx);
        assert!(fx.keys.turn_off(&fx.engine));
        assert!(fx.keys.take_bridge(None).is_empty());
    }

    /// A second packet of a held update that says a member may not pass it
    /// on decides for the update, whichever came first.
    #[test]
    fn one_packet_that_forbids_passing_an_update_on_decides() {
        let fx = on();
        let group = circle(1);
        fx.moves(&group, 4, 0xa0);
        let never = |event: &Event| {
            let parts = parts_of(event, Format::NeverBridged).expect("a location");
            wrap(&peer_key(4, 0xa0), &parts, &mut OsRng).expect("fits")
        };
        let bridgeable = |fx: &Fixture, event: &Event| {
            (fx.keys.taken_in(&group, &event.id))
                .expect("held")
                .bridgeable
        };

        let alone = location();
        assert!(fx
            .keys
            .hold(read(&fx, &packet_of(&alone, 4, 0xa0)), [1; 32])
            .is_empty());
        assert_eq!(fx.keys.content_of(&group, &alone.id), Some([1; 32]));
        assert!(bridgeable(&fx, &alone));

        for first_forbids in [true, false] {
            let event = location();
            let (first, second) = if first_forbids {
                (never(&event), packet_of(&event, 4, 0xa0))
            } else {
                (packet_of(&event, 4, 0xa0), never(&event))
            };
            assert!(fx.keys.hold(read(&fx, &first), [2; 32]).is_empty());
            assert!(fx.keys.hold(read(&fx, &second), [2; 32]) == [second.id()]);
            assert!(
                !bridgeable(&fx, &event),
                "an update one packet forbade passing on is marked as one that may be"
            );
        }
    }
}
