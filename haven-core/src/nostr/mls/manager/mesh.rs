//! The mesh key ring and the publish hand-off (`docs/BLUETOOTH_MESH_PLAN.md`
//! §4.2 and §5.1).
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
//! through [`Held`], off the session its caller holds.
//!
//! Nothing here logs and no type is `Debug`: an epoch, a group id, a routing
//! id and a slot are identifiers, and a key is a secret (Security Rules 6
//! and 15).

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use nostr::Event;
use rand::rngs::OsRng;
use rand::{CryptoRng, RngCore};
use subtle::ConstantTimeEq;
use zeroize::Zeroizing;

use super::{GroupEvent, GroupId, LocationToSend, SessionManager, DEFAULT_MAX_PAST_EPOCHS};
use crate::mesh::engine::CircleSlot;
use crate::mesh::event::parts_of;
use crate::mesh::handoff::Handoff;
use crate::mesh::packet::{wrap, Format, MeshKey};

/// The longest mesh stays on without being asked for again: the deadline is
/// never further ahead of the clock than this.
pub const MESH_ON_MAX_MS: u64 = 12 * 60 * 60 * 1_000;

/// How far behind the engine's epoch a key is still kept: the engine's own
/// window (Security Rule 5).
const PAST_EPOCHS: u64 = DEFAULT_MAX_PAST_EPOCHS as u64;

// A slot is one bit of the mask a free one is found in.
const _: () = assert!(Handoff::SLOTS <= u64::BITS);

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
}

impl CircleKeys {
    /// Empties the circle's slot and ends the turn any send still holds.
    fn silence(&mut self, handoff: &Handoff) {
        self.turn += 1;
        if let Some(slot) = self.slot {
            handoff.purge(slot);
        }
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
    /// that has passed is left for the next batch to act on.
    Send,
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
}

impl Counts {
    #[cfg(any(test, feature = "test-utils"))]
    fn one(&self, cost: Cost) {
        match cost {
            Cost::Derive => &self.derives,
            Cost::Wrap => &self.wraps,
            Cost::Write => &self.writes,
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
    /// Never held across the store or the engine, so the hand-off, which
    /// only tries it, is never kept from it for longer than one packet takes
    /// to seal.
    ring: Mutex<HashMap<GroupId, CircleKeys>>,
    store: Arc<dyn MeshKeyStore>,
    handoff: Arc<Handoff>,
    counts: Counts,
}

impl MeshKeys {
    /// Mesh off, nothing kept, no store.
    pub(super) fn new() -> Self {
        Self {
            until_ms: AtomicU64::new(0),
            latest_ms: AtomicU64::new(0),
            owed: AtomicBool::new(false),
            undeleted: AtomicBool::new(false),
            ring: Mutex::new(HashMap::new()),
            store: Arc::new(NoMeshKeyStore),
            handoff: Arc::new(Handoff::default()),
            counts: Counts::default(),
        }
    }

    /// Installs the store the ring is kept in and restores what an earlier
    /// process kept — if mesh is still on at `now_ms`. With no deadline
    /// stored, or one that has passed, every stored key is deleted instead.
    /// A stored deadline further ahead than [`MESH_ON_MAX_MS`] was written
    /// under a later clock, and is brought back to that.
    pub(super) fn install(&mut self, store: Arc<dyn MeshKeyStore>, now_ms: u64) {
        self.store = store;
        let now = self.now(now_ms);
        let stored = self.store.mesh_on_until().unwrap_or(0);
        let until = stored.min(now.saturating_add(MESH_ON_MAX_MS));
        if until <= now || (until != stored && !self.write_until(Some(until))) {
            self.clear();
            return;
        }
        let mut ring = HashMap::<GroupId, CircleKeys>::new();
        for (group, row) in self.store.mesh_keys() {
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
        let until = self.until_ms.load(Ordering::Relaxed);
        until != 0 && self.now(now_ms) < until
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
            Caller::Send => self.ring.try_lock().ok(),
        }
    }

    fn write_until(&self, until_ms: Option<u64>) -> bool {
        self.counts.one(Cost::Write);
        self.store.set_mesh_on_until(until_ms)
    }

    /// Mesh on until `until_ms`, or until [`MESH_ON_MAX_MS`] from `now_ms` if
    /// that is sooner. A deadline that is not ahead of the clock, or that the
    /// store did not take, is mesh off. Returns whether mesh is on.
    fn turn_on<H: Held>(&self, held: &H, until_ms: u64, now_ms: u64) -> bool {
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
    /// finds the ring's lock held, nothing: no turn, so no hand-off.
    fn align<H: Held>(
        &self,
        held: &H,
        group: &GroupId,
        now_ms: u64,
        caller: Caller<'_>,
    ) -> Option<Turn> {
        let (rewound, on) = match caller {
            Caller::Batch { rewound, .. } => (rewound, self.on(held, now_ms)),
            Caller::Send => (false, self.lit(now_ms)),
        };
        if !on {
            return None;
        }
        let Some((epoch, exporter)) = Self::current(held, group) else {
            if let Some(circle) = self.ring_for(caller)?.get_mut(group) {
                circle.silence(&self.handoff);
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
                    circle.silence(&self.handoff);
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
            circle.silence(&self.handoff);
            circle.unsaved = true;
            self.owed.store(true, Ordering::Relaxed);
        }
        let at = circle.turn;
        drop(ring);
        Some(Turn {
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
    /// the circle was left, disbanded or forgotten.
    pub(super) fn forget<H: Held>(&self, _held: &H, group: &GroupId) {
        if !self.armed() {
            return;
        }
        let gone = self.ring().remove(group);
        if let Some(slot) = gone.and_then(|circle| circle.slot) {
            self.handoff.purge(slot);
        }
        self.counts.one(Cost::Write);
        let _ = self.store.save_mesh_keys(group, &[]);
    }

    /// Empties `group`'s outbox slot: the relay path would not send for the
    /// circle now, so nothing sealed before this goes out by mesh either.
    pub(super) fn silence(&self, group: &GroupId) {
        if !self.armed() {
            return;
        }
        if let Some(circle) = self.ring().get_mut(group) {
            circle.silence(&self.handoff);
        }
    }

    /// [`Self::silence`], for every circle.
    fn silence_all(&self) {
        if !self.armed() {
            return;
        }
        for circle in self.ring().values_mut() {
            circle.silence(&self.handoff);
        }
    }

    /// Wraps `event` under its circle's newest key and leaves the packet in
    /// the hand-off — if the circle still stands at `turn`, has a slot, and
    /// the event is one a packet carries. Otherwise, and when the ring's
    /// lock is held, nothing: the caller is the relay send, and the mesh is
    /// lossy by design.
    fn offer<R: RngCore + CryptoRng>(&self, turn: &Turn, event: &Event, rng: &mut R) {
        let Ok(circles) = self.ring.try_lock() else {
            return;
        };
        let Some(circle) = circles.get(&turn.circle).filter(|c| c.turn == turn.at) else {
            return;
        };
        let (Some(slot), Some(key)) = (circle.slot, circle.keys.first()) else {
            return;
        };
        let Some(parts) = parts_of(event, Format::Bridgeable) else {
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
    pub(crate) fn mesh_offer(&self, event: &Event, record: &LocationToSend) {
        if let Some(turn) = &record.mesh_turn {
            self.mesh_keys.offer(turn, event, &mut OsRng);
        }
    }

    /// What a location's send-time check hands [`Self::mesh_offer`]: the
    /// circle's key brought in line with the engine in that check's own
    /// hold, where the circle stands stable on the epoch the location was
    /// sealed at. In memory only, and waiting for nothing ([`Caller::Send`]).
    pub(super) fn mesh_turn<H: Held>(
        &self,
        held: &H,
        group: &GroupId,
        now_ms: u64,
    ) -> Option<Turn> {
        self.mesh_keys.align(held, group, now_ms, Caller::Send)
    }

    /// What every engine batch is owed (`Self::note_effects`): the keys of
    /// each circle a state-bearing event names brought in line with the
    /// engine, the circles a proposal names silenced, and what is unsaved
    /// saved.
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
        let (keys, now_ms) = (&self.mesh_keys, self.legacy_now_ms());
        if !keys.turn_on(held, until_ms, now_ms) {
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
    use crate::mesh::packet::{open, Packet};
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
        let mut keys = MeshKeys::new();
        keys.install(store.clone(), now_ms);
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
            self.keys.align(&self.engine, group, now_ms, Caller::Send)
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
        fx.keys.offer(turn, event, &mut OsRng);
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
            fx.keys.offer(&turn, &event, &mut OsRng);
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
    /// newest key; an event a packet cannot carry draws nothing.
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
        fx.keys.offer(&turn, &event, &mut rng);
        assert!(rng.is_spent() && fx.costs().1 == 1);
        let [(0, Some(packet))] = &fx.waiting()[..] else {
            panic!("one packet waits");
        };
        assert!(
            packet.as_bytes()[..12] == nonce,
            "the packet's nonce is not the generator's twelve bytes"
        );
        assert!(open(&peer_key(5, 0xa0), packet).is_some());
        assert!(open(&peer_key(4, 0xa0), packet).is_none());
        let [(
            _,
            Op::Offer {
                expires_at_secs, ..
            },
        )] = &{
            fx.keys.offer(&turn, &event, &mut OsRng);
            fx.keys.handoff.take()
        }[..]
        else {
            panic!("one packet waits");
        };
        assert!(
            *expires_at_secs == EXPIRES_AT_SECS,
            "the offer does not carry its event's expiration"
        );

        // A commit carries no expiration: not a shape a packet holds.
        let commit = EventBuilder::new(Kind::Custom(KIND_GROUP_MESSAGE), BASE64.encode([7; 120]))
            .tags([Tag::parse(["h", &hex::encode([0x70; 32])]).expect("a tag")])
            .sign_with_keys(&Keys::generate())
            .expect("sign");
        fx.keys.offer(&turn, &commit, &mut Scripted::new(&[]));
        assert!(fx.waiting().is_empty() && fx.costs().1 == 2);
    }
}
