//! The packets a phone holds for the mesh, what it remembers of each, and the
//! queue of packets its session code has not yet tried to open (plan §5.2,
//! §6.4, §6.5).
//!
//! A packet lives at most [`Limits::life_ms`] (`L`) from its origin. Phones
//! tell each other how much is left in [`LIFETIME_UNITS`] steps of `L / 256`,
//! rounded down, and never a clock reading. For every packet accepted or
//! emitted the store keeps a record for `2 L` from first receipt:
//!
//! ```text
//! first receipt      expires           first + L          first + 2 L
//!   │ announced, sent  │ bytes kept, silent │ record only        │ forgotten
//! ```
//!
//! `expires` is what a peer announced, or the origin's draw; a later, larger
//! announcement raises it, never past `first + L`. While the record lasts the
//! same bytes are never taken again, so a relayed packet cannot bounce back.
//!
//! Own and carried packets are the same rows under the same rules. Links are
//! named by slot, a small number the engine assigns; the store never sees a
//! peer. Nothing here reads a clock: [`Store::advance`] is told the time. No
//! type here is `Debug`: a row holds a packet and its id (Security Rule 15).

use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::ops::Bound;

use rand::{Rng, RngCore};

use super::packet::{Packet, PacketId};

/// How many steps a lifetime is announced in: one byte's worth.
pub const LIFETIME_UNITS: u64 = 256;

/// How many link slots a record tracks: slots are `0..MAX_LINKS`.
pub const MAX_LINKS: u8 = 32;

/// The units an emitted packet starts with are drawn from the top quarter of
/// the lifetime (§6.4); the draw blurs a packet's age.
const ORIGIN_UNITS: std::ops::RangeInclusive<u64> = 192..=255;

/// Where a row came from: the class it is counted in when the store is full.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Origin {
    /// Emitted by this phone.
    Local,
    /// Received on the link in this slot.
    Link(u8),
    /// Received on a link that has since closed.
    Departed,
}

/// The sizes of a [`Store`].
#[derive(Clone, Copy)]
pub struct Limits {
    /// `L`: the longest a packet lives from its origin, in milliseconds.
    pub life_ms: u64,
    /// The most packets held.
    pub packets: usize,
    /// The most records kept. At this many, new packets are refused: records
    /// are forgotten by age alone.
    pub records: usize,
    /// The most packets queued for session code; past it the oldest go.
    pub unread: usize,
}

/// What session code has said about a carried packet.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Read {
    /// Nothing yet.
    Pending,
    /// It could not open it, or never got to.
    NotOurs,
    /// It opened it, or the packet is this phone's own: never counted.
    Settled,
}

struct Record {
    first_ms: u64,
    expires_ms: u64,
    /// `expires_ms` when the packet last became due for announcing: a raise
    /// of a whole unit past it is announced again.
    announced_ms: u64,
    /// When the packet last became due for announcing.
    ready_ms: u64,
    packet: Option<Packet>,
    origin: Origin,
    /// Slots that need no announcement: the source, those told since the
    /// packet last became due, and those that announced as much themselves.
    told: u32,
    /// Slots this packet was ever announced to: the ones that may ask for it.
    offered: u32,
    /// Slots it was given to, or is being given to.
    given: u32,
    /// Handed in full to a link.
    sent: bool,
    read: Read,
}

const fn bit(slot: u8) -> u32 {
    if slot < MAX_LINKS {
        1 << slot
    } else {
        0
    }
}

const fn source_bit(origin: Origin) -> u32 {
    match origin {
        Origin::Link(slot) => bit(slot),
        Origin::Local | Origin::Departed => 0,
    }
}

/// Lifetime units left at `now_ms`, rounded down.
fn units(expires_ms: u64, now_ms: u64, unit_ms: u64) -> u8 {
    u8::try_from(expires_ms.saturating_sub(now_ms) / unit_ms).unwrap_or(u8::MAX)
}

/// The mesh store of one phone. Memory only.
pub struct Store {
    limits: Limits,
    unit_ms: u64,
    now_ms: u64,
    records: BTreeMap<PacketId, Record>,
    /// Every record by first receipt, oldest first: the order they are
    /// forgotten in.
    aging: VecDeque<(u64, PacketId)>,
    /// Every row that had bytes, likewise: the order bytes are dropped in.
    keeping: VecDeque<(u64, PacketId)>,
    held: usize,
    unread: VecDeque<(PacketId, Packet)>,
    /// Carried packets that were sent on and whose record was forgotten
    /// before session code said whether it could open them.
    late: BTreeSet<PacketId>,
    passed_on: u64,
}

impl Store {
    /// An empty store at time zero.
    #[must_use]
    pub fn new(limits: Limits) -> Self {
        Self {
            limits,
            unit_ms: (limits.life_ms / LIFETIME_UNITS).max(1),
            now_ms: 0,
            records: BTreeMap::new(),
            aging: VecDeque::new(),
            keeping: VecDeque::new(),
            held: 0,
            unread: VecDeque::new(),
            late: BTreeSet::new(),
            passed_on: 0,
        }
    }

    /// Moves to `now_ms`, never backwards: drops the bytes of rows past
    /// `first + L` and forgets records past `first + 2 L`.
    pub fn advance(&mut self, now_ms: u64) {
        self.now_ms = self.now_ms.max(now_ms);
        let life = self.limits.life_ms;
        while let Some(&(first_ms, id)) = self.keeping.front() {
            if first_ms.saturating_add(life) > self.now_ms {
                break;
            }
            self.keeping.pop_front();
            self.drop_bytes(&id);
        }
        while let Some(&(first_ms, id)) = self.aging.front() {
            if first_ms.saturating_add(life.saturating_mul(2)) > self.now_ms {
                break;
            }
            self.aging.pop_front();
            let Some(record) = self.records.remove(&id) else {
                continue;
            };
            let unsettled = record.sent && record.read == Read::Pending;
            if unsettled && self.late.len() < self.limits.unread {
                self.late.insert(id);
            }
        }
    }

    fn drop_bytes(&mut self, id: &PacketId) {
        if let Some(record) = self.records.get_mut(id) {
            if record.packet.take().is_some() {
                self.held -= 1;
            }
        }
    }

    /// One lifetime unit in milliseconds: `L / 256`, rounded down.
    #[must_use]
    pub const fn unit_ms(&self) -> u64 {
        self.unit_ms
    }

    /// When a packet emitted now expires: now plus a number of units drawn
    /// uniformly from the top quarter of the lifetime.
    pub fn origin_expiry<R: RngCore>(&self, rng: &mut R) -> u64 {
        self.now_ms
            .saturating_add(rng.gen_range(ORIGIN_UNITS) * self.unit_ms)
    }

    /// When a packet just announced with `remaining` units expires.
    #[must_use]
    pub fn announced_expiry(&self, remaining: u8) -> u64 {
        self.now_ms
            .saturating_add(u64::from(remaining).saturating_mul(self.unit_ms))
    }

    /// Takes in a packet received in full, or emitted, and writes its record.
    /// `expires_ms` is capped at now + `L`.
    ///
    /// `false`, changing nothing, when the packet has a record or the record
    /// table is full. A carried packet is also queued for session code. When
    /// the store is full a row is evicted first: one whose lifetime has
    /// ended, else one from a closed link, else one of the class that holds
    /// the most rows — this packet counted in its own — picked with `rng`.
    pub fn accept<R: RngCore>(
        &mut self,
        packet: Packet,
        origin: Origin,
        expires_ms: u64,
        rng: &mut R,
    ) -> bool {
        let id = packet.id();
        if self.records.contains_key(&id) || self.records.len() >= self.limits.records {
            return false;
        }
        let now = self.now_ms;
        let keep = self.held < self.limits.packets || self.evict(origin, rng);
        let expires_ms = expires_ms.min(now.saturating_add(self.limits.life_ms));
        let carried = origin != Origin::Local;
        self.records.insert(
            id,
            Record {
                first_ms: now,
                expires_ms,
                announced_ms: expires_ms,
                ready_ms: now,
                packet: keep.then(|| packet.clone()),
                origin,
                told: source_bit(origin),
                offered: 0,
                given: 0,
                sent: false,
                read: if carried {
                    Read::Pending
                } else {
                    Read::Settled
                },
            },
        );
        self.aging.push_back((now, id));
        if keep {
            self.keeping.push_back((now, id));
            self.held += 1;
        }
        if carried {
            self.unread.push_back((id, packet));
            if self.unread.len() > self.limits.unread {
                if let Some((dropped, _)) = self.unread.pop_front() {
                    self.not_ours(&dropped);
                }
            }
        }
        true
    }

    /// Drops the bytes of one row to make room for a packet of `incoming`.
    /// `false` when no row holds bytes.
    fn evict<R: RngCore>(&mut self, incoming: Origin, rng: &mut R) -> bool {
        let (now, unit) = (self.now_ms, self.unit_ms);
        let ended = |record: &Record| units(record.expires_ms, now, unit) == 0;
        let rows = || self.records.iter().filter(|(_, r)| r.packet.is_some());
        let class = if rows().any(|(_, record)| ended(record)) {
            None
        } else if rows().any(|(_, record)| record.origin == Origin::Departed) {
            Some(Origin::Departed)
        } else {
            self.largest_class(incoming)
        };
        // `None` is the class of rows whose lifetime has ended.
        let of_class =
            |record: &Record| class.map_or_else(|| ended(record), |c| record.origin == c);
        let count = rows().filter(|(_, record)| of_class(record)).count();
        if count == 0 {
            return false;
        }
        let pick = rng.gen_range(0..count);
        let victim = rows()
            .filter(|(_, record)| of_class(record))
            .nth(pick)
            .map(|(id, _)| *id);
        victim.is_some_and(|id| {
            self.drop_bytes(&id);
            true
        })
    }

    /// The live class holding the most rows, a packet of `incoming` counted
    /// in its own: no class is pushed below an equal share by another.
    fn largest_class(&self, incoming: Origin) -> Option<Origin> {
        let mut local = 0usize;
        let mut links = [0usize; MAX_LINKS as usize];
        for record in self.records.values().filter(|r| r.packet.is_some()) {
            match record.origin {
                Origin::Local => local += 1,
                Origin::Link(slot) => {
                    if let Some(count) = links.get_mut(usize::from(slot)) {
                        *count += 1;
                    }
                }
                Origin::Departed => {}
            }
        }
        let classes = std::iter::once((Origin::Local, local)).chain(
            (0..MAX_LINKS)
                .zip(links)
                .map(|(slot, n)| (Origin::Link(slot), n)),
        );
        let mut largest: Option<(Origin, usize)> = None;
        for (origin, rows) in classes.filter(|&(_, rows)| rows > 0) {
            let weight = rows + usize::from(origin == incoming);
            if largest.is_none_or(|(_, most)| weight > most) {
                largest = Some((origin, weight));
            }
        }
        largest.map(|(origin, _)| origin)
    }

    /// The link in `slot` announced `id` with a lifetime ending at
    /// `expires_ms`. `false` when the store has no record of `id`.
    ///
    /// A later end raises the packet's, never past `first + L`; a raise of a
    /// whole unit makes it due for announcing again, to every link but its
    /// source and this one. A link that announced about as much as the store
    /// holds needs no announcement back.
    pub fn heard(&mut self, id: &PacketId, slot: u8, expires_ms: u64) -> bool {
        let (now, unit, life) = (self.now_ms, self.unit_ms, self.limits.life_ms);
        let Some(record) = self.records.get_mut(id) else {
            return false;
        };
        let theirs = expires_ms.min(record.first_ms.saturating_add(life));
        if theirs.saturating_add(unit) > record.expires_ms {
            record.told |= bit(slot);
        }
        if theirs > record.expires_ms {
            record.expires_ms = theirs;
            if theirs >= record.announced_ms.saturating_add(unit) {
                record.announced_ms = theirs;
                record.ready_ms = now;
                record.told = bit(slot) | source_bit(record.origin);
            }
        }
        true
    }

    /// The next packet in id order after `after` to announce to `slot`, with
    /// its units left, marked as announced there: held, unexpired, due since
    /// no later than `since_ms`, and not yet told to that link.
    pub fn next_announcement(
        &mut self,
        slot: u8,
        after: Option<PacketId>,
        since_ms: u64,
    ) -> Option<(PacketId, u8)> {
        let (now, unit, mark) = (self.now_ms, self.unit_ms, bit(slot));
        let from = after.map_or(Bound::Unbounded, Bound::Excluded);
        self.records
            .range_mut((from, Bound::Unbounded))
            .find_map(|(id, record)| {
                let remaining = units(record.expires_ms, now, unit);
                let due = record.packet.is_some()
                    && remaining > 0
                    && record.told & mark == 0
                    && record.ready_ms <= since_ms;
                due.then(|| {
                    record.told |= mark;
                    record.offered |= mark;
                    (*id, remaining)
                })
            })
    }

    /// Whether the link in `slot` may be sent `id` now, marking it given: it
    /// was announced there, was not given there before, and is held unexpired.
    pub fn claim(&mut self, id: &PacketId, slot: u8) -> bool {
        let (now, unit, mark) = (self.now_ms, self.unit_ms, bit(slot));
        self.records.get_mut(id).is_some_and(|record| {
            let free = record.packet.is_some()
                && units(record.expires_ms, now, unit) > 0
                && record.offered & mark != 0
                && record.given & mark == 0;
            record.given |= if free { mark } else { 0 };
            free
        })
    }

    /// The packet, while it is held and unexpired: what may still be sent.
    #[must_use]
    pub fn packet(&self, id: &PacketId) -> Option<Packet> {
        let record = self.records.get(id)?;
        (units(record.expires_ms, self.now_ms, self.unit_ms) > 0)
            .then(|| record.packet.clone())
            .flatten()
    }

    /// `id` was handed in full to a link.
    pub fn sent(&mut self, id: &PacketId) {
        if let Some(record) = self.records.get_mut(id) {
            if !record.sent {
                record.sent = true;
                if record.read == Read::NotOurs {
                    self.passed_on += 1;
                }
            }
        }
    }

    /// The link in `slot` closed: its rows join the departed class and the
    /// slot is free for another link, which is owed every announcement.
    pub fn depart(&mut self, slot: u8) {
        let mark = bit(slot);
        for record in self.records.values_mut() {
            record.told &= !mark;
            record.offered &= !mark;
            record.given &= !mark;
            if record.origin == Origin::Link(slot) {
                record.origin = Origin::Departed;
            }
        }
    }

    /// Up to `max` carried packets not yet handed to session code, oldest
    /// first. A packet is handed out once, whether or not its lifetime ended.
    pub fn take_unread(&mut self, max: usize) -> Vec<Packet> {
        let count = max.min(self.unread.len());
        self.unread
            .drain(..count)
            .map(|(_, packet)| packet)
            .collect()
    }

    /// Session code's verdict on a packet it took: `opened` under one of its
    /// keys, or not.
    pub fn mark_read(&mut self, id: &PacketId, opened: bool) {
        if !opened {
            self.not_ours(id);
        } else if let Some(record) = self.records.get_mut(id) {
            if record.read == Read::Pending {
                record.read = Read::Settled;
            }
        } else {
            self.late.remove(id);
        }
    }

    /// A carried packet this phone could not open, or never tried: counted
    /// as passed on once, when it has also been sent on.
    fn not_ours(&mut self, id: &PacketId) {
        let counted = match self.records.get_mut(id) {
            Some(record) if record.read == Read::Pending => {
                record.read = Read::NotOurs;
                record.sent
            }
            Some(_) => false,
            None => self.late.remove(id),
        };
        self.passed_on += u64::from(counted);
    }

    /// Drops every packet, record and unread entry. The passed-on count,
    /// which names no packet, stays.
    pub fn clear(&mut self) {
        self.records.clear();
        self.aging.clear();
        self.keeping.clear();
        self.held = 0;
        self.unread.clear();
        self.late.clear();
    }

    /// How many packets are held.
    #[must_use]
    pub const fn held(&self) -> usize {
        self.held
    }

    /// How many records are kept.
    #[must_use]
    pub fn records(&self) -> usize {
        self.records.len()
    }

    /// How many packets wait for session code.
    #[must_use]
    pub fn unread(&self) -> usize {
        self.unread.len()
    }

    /// Unique carried packets sent on to another phone that this phone could
    /// not open (§7.5).
    #[must_use]
    pub const fn passed_on(&self) -> u64 {
        self.passed_on
    }

    /// Whether `id` was accepted or emitted within the last `2 L`.
    #[must_use]
    pub fn has_record(&self, id: &PacketId) -> bool {
        self.records.contains_key(id)
    }

    /// Whether the bytes of `id` are held.
    #[must_use]
    pub fn holds(&self, id: &PacketId) -> bool {
        self.records
            .get(id)
            .is_some_and(|record| record.packet.is_some())
    }

    /// Whether `id` is a packet this phone emitted.
    #[must_use]
    pub fn is_local(&self, id: &PacketId) -> bool {
        self.records
            .get(id)
            .is_some_and(|record| record.origin == Origin::Local)
    }

    /// The lifetime units `id` would be announced with now; zero for a packet
    /// that is not held or whose lifetime has ended.
    #[must_use]
    pub fn remaining(&self, id: &PacketId) -> u8 {
        self.records
            .get(id)
            .filter(|record| record.packet.is_some())
            .map_or(0, |record| {
                units(record.expires_ms, self.now_ms, self.unit_ms)
            })
    }

    /// When the lifetime of `id` ends, while its record lasts.
    #[must_use]
    pub fn expires_ms(&self, id: &PacketId) -> Option<u64> {
        self.records.get(id).map(|record| record.expires_ms)
    }

    /// The ids of the packets held, in id order.
    pub fn ids(&self) -> impl Iterator<Item = PacketId> + '_ {
        self.records
            .iter()
            .filter(|(_, record)| record.packet.is_some())
            .map(|(id, _)| *id)
    }
}

#[cfg(test)]
mod tests {
    use proptest::prelude::*;
    use rand::rngs::StdRng;
    use rand::{Rng, SeedableRng};

    use super::*;
    use crate::mesh::packet::cover_packet;

    const LIFE: u64 = 20 * 60 * 1000;
    const UNIT: u64 = 4687;

    // The draw's bounds are the lifetime's top quarter, to within a unit.
    const _: () = assert!(192 * UNIT >= LIFE * 3 / 4 - UNIT && 255 * UNIT < LIFE);

    fn store(packets: usize, records: usize, unread: usize) -> Store {
        Store::new(Limits {
            life_ms: LIFE,
            packets,
            records,
            unread,
        })
    }

    fn roomy() -> Store {
        store(64, 256, 64)
    }

    fn rng() -> StdRng {
        StdRng::seed_from_u64(99)
    }

    fn packet(n: u64) -> Packet {
        cover_packet(&mut StdRng::seed_from_u64(n))
    }

    fn id(n: u64) -> PacketId {
        packet(n).id()
    }

    /// Accepts packet `n` with `units` of lifetime announced now.
    fn take(store: &mut Store, n: u64, origin: Origin, units: u8) -> bool {
        let expires = store.announced_expiry(units);
        store.accept(packet(n), origin, expires, &mut rng())
    }

    /// Every announcement `slot` is owed at the store's present time.
    fn announced(store: &mut Store, slot: u8) -> Vec<(PacketId, u8)> {
        let now = store.now_ms;
        let mut out = Vec::new();
        while let Some(entry) = store.next_announcement(slot, out.last().map(|e: &(_, _)| e.0), now)
        {
            out.push(entry);
        }
        out
    }

    #[test]
    fn a_unit_is_the_lifetime_over_256_rounded_down() {
        let mut store = roomy();
        assert_eq!(store.unit_ms(), UNIT);
        assert_eq!(LIFE / 256, UNIT);
        store.advance(1000);
        assert_eq!(store.announced_expiry(200), 1000 + 200 * UNIT);
        assert_eq!(store.announced_expiry(0), 1000);
    }

    #[test]
    fn units_left_are_rounded_down() {
        let mut store = roomy();
        let expires = 10 * UNIT + UNIT - 1;
        assert!(store.accept(packet(1), Origin::Link(0), expires, &mut rng()));
        assert_eq!(store.remaining(&id(1)), 10);
        store.advance(UNIT - 1);
        assert_eq!(store.remaining(&id(1)), 10);
        store.advance(UNIT);
        assert_eq!(store.remaining(&id(1)), 9);
        store.advance(10 * UNIT - 1);
        assert_eq!(store.remaining(&id(1)), 1);
        store.advance(10 * UNIT);
        assert_eq!(store.remaining(&id(1)), 0);
    }

    #[test]
    fn an_expiry_never_passes_first_receipt_plus_the_lifetime() {
        let mut store = roomy();
        store.advance(5000);
        assert!(store.accept(packet(1), Origin::Link(0), u64::MAX, &mut rng()));
        assert_eq!(store.expires_ms(&id(1)), Some(5000 + LIFE));

        assert!(take(&mut store, 2, Origin::Link(0), 3));
        store.advance(60_000);
        assert!(store.heard(&id(2), 1, u64::MAX));
        assert_eq!(store.expires_ms(&id(2)), Some(5000 + LIFE));
        // Held, announced or not, until first + L and not a millisecond more.
        store.advance(5000 + LIFE - 1);
        assert!(store.holds(&id(2)) && store.remaining(&id(2)) == 0);
        store.advance(5000 + LIFE);
        assert!(!store.holds(&id(2)) && store.has_record(&id(2)));
        assert_eq!(store.held(), 0);
    }

    #[test]
    fn a_larger_announcement_raises_the_expiry_and_a_smaller_one_does_not() {
        let mut store = roomy();
        assert!(take(&mut store, 1, Origin::Link(0), 100));
        assert!(store.heard(&id(1), 1, 50 * UNIT));
        assert_eq!(store.expires_ms(&id(1)), Some(100 * UNIT));
        assert!(store.heard(&id(1), 1, 100 * UNIT + 1));
        assert_eq!(store.expires_ms(&id(1)), Some(100 * UNIT + 1));
        assert!(store.heard(&id(1), 2, 180 * UNIT));
        assert_eq!(store.expires_ms(&id(1)), Some(180 * UNIT));
        assert!(!store.heard(&id(2), 1, 180 * UNIT));
    }

    #[test]
    fn a_packet_at_zero_units_is_silent_but_kept_until_first_plus_the_lifetime() {
        let mut store = roomy();
        assert!(store.accept(packet(1), Origin::Link(0), UNIT - 1, &mut rng()));
        assert!(announced(&mut store, 1).is_empty());

        assert!(take(&mut store, 2, Origin::Link(0), 2));
        assert!(announced(&mut store, 1) == vec![(id(2), 2)]);
        store.advance(UNIT + 1);
        assert!(store.packet(&id(2)).is_none());
        assert!(!store.claim(&id(2), 1));
        assert_eq!(store.remaining(&id(2)), 0);

        store.advance(LIFE - 1);
        assert!(store.holds(&id(1)) && store.holds(&id(2)));
        store.advance(LIFE);
        assert!(!store.holds(&id(1)) && !store.holds(&id(2)));
    }

    #[test]
    fn a_packet_is_announced_to_a_link_once_in_id_order_and_never_to_its_source() {
        let mut store = roomy();
        for n in 1..=5 {
            assert!(take(&mut store, n, Origin::Link(0), 200));
        }
        assert!(take(&mut store, 6, Origin::Local, 200));
        let mut expected: Vec<_> = (1..=6).map(|n| (id(n), 200)).collect();
        expected.sort();

        assert!(announced(&mut store, 1) == expected);
        assert!(announced(&mut store, 1).is_empty());
        assert!(announced(&mut store, 0) == vec![(id(6), 200)]);
        assert!(announced(&mut store, 2) == expected);
    }

    #[test]
    fn a_packet_is_announced_only_once_it_was_due_at_the_scan_time() {
        let mut store = roomy();
        store.advance(1000);
        assert!(take(&mut store, 1, Origin::Link(0), 200));
        assert!(store.next_announcement(1, None, 999).is_none());
        assert!(store.next_announcement(1, None, 1000).is_some());
    }

    /// T-LIFE-3: a packet handed over with almost no lifetime is announced
    /// again once an honest announcement raises it.
    #[test]
    fn a_raise_announces_a_packet_again_to_all_but_its_source_and_the_raiser() {
        let mut store = roomy();
        assert!(take(&mut store, 1, Origin::Link(0), 1));
        assert!(announced(&mut store, 1) == vec![(id(1), 1)]);
        store.advance(UNIT);
        assert_eq!(store.remaining(&id(1)), 0);
        assert!(announced(&mut store, 3).is_empty());

        let honest = store.announced_expiry(180);
        assert!(store.heard(&id(1), 2, honest));
        assert!(announced(&mut store, 1) == vec![(id(1), 180)]);
        assert!(announced(&mut store, 3) == vec![(id(1), 180)]);
        assert!(announced(&mut store, 0).is_empty());
        assert!(announced(&mut store, 2).is_empty());
    }

    #[test]
    fn a_raise_under_one_unit_is_not_announced_again() {
        let mut store = roomy();
        assert!(take(&mut store, 1, Origin::Link(0), 100));
        assert_eq!(announced(&mut store, 1).len(), 1);
        assert!(store.heard(&id(1), 2, 100 * UNIT + UNIT - 1));
        assert_eq!(store.expires_ms(&id(1)), Some(100 * UNIT + UNIT - 1));
        assert!(announced(&mut store, 1).is_empty());
        // The sub-unit raises add up: a whole unit past the last announcement.
        assert!(store.heard(&id(1), 2, 101 * UNIT));
        assert!(announced(&mut store, 1) == vec![(id(1), 101)]);
    }

    #[test]
    fn a_link_that_announced_as_much_is_not_told_and_one_a_unit_behind_is() {
        let mut store = roomy();
        assert!(take(&mut store, 1, Origin::Link(0), 100));
        assert!(store.heard(&id(1), 1, 99 * UNIT + 1));
        assert!(announced(&mut store, 1).is_empty());
        assert!(store.heard(&id(1), 2, 99 * UNIT));
        assert!(announced(&mut store, 2) == vec![(id(1), 100)]);
    }

    #[test]
    fn a_packet_is_given_only_where_it_was_announced_and_only_once() {
        let mut store = roomy();
        assert!(take(&mut store, 1, Origin::Link(0), 100));
        assert!(!store.claim(&id(1), 1));
        assert_eq!(announced(&mut store, 1).len(), 1);
        assert!(!store.claim(&id(1), 0));
        assert!(!store.claim(&id(1), 2));
        assert!(store.claim(&id(1), 1));
        assert!(!store.claim(&id(1), 1));
        assert!(!store.claim(&id(2), 1));
        assert!(store.packet(&id(1)) == Some(packet(1)));
    }

    /// T-LIFE-2.
    #[test]
    fn a_record_lasts_twice_the_lifetime_and_the_packet_is_taken_again_exactly_then() {
        let mut store = roomy();
        store.advance(7000);
        assert!(take(&mut store, 1, Origin::Link(0), 255));
        assert!(!take(&mut store, 1, Origin::Link(1), 255));
        store.advance(7000 + LIFE);
        assert!(!store.holds(&id(1)));
        assert!(!take(&mut store, 1, Origin::Link(1), 255));
        store.advance(7000 + 2 * LIFE - 1);
        assert!(store.has_record(&id(1)));
        assert!(!take(&mut store, 1, Origin::Link(1), 255));
        assert_eq!(store.records(), 1);
        store.advance(7000 + 2 * LIFE);
        assert!(!store.has_record(&id(1)));
        assert!(take(&mut store, 1, Origin::Link(1), 255));
        assert!(store.holds(&id(1)));
    }

    /// T-SEC-8.
    #[test]
    fn a_full_record_table_refuses_new_packets_and_forgets_only_by_age() {
        let mut store = store(2, 4, 64);
        for n in 1..=4 {
            store.advance(n * 1000);
            assert!(take(&mut store, n, Origin::Link(0), 255));
        }
        assert_eq!((store.records(), store.held()), (4, 2));
        assert!(!take(&mut store, 5, Origin::Link(1), 255));
        assert!(!store.has_record(&id(5)));
        assert_eq!(store.unread(), 4);
        for n in 1..=4 {
            assert!(store.has_record(&id(n)));
        }

        store.advance(1000 + 2 * LIFE - 1);
        assert!(!take(&mut store, 5, Origin::Link(1), 255));
        store.advance(1000 + 2 * LIFE);
        assert!(take(&mut store, 5, Origin::Link(1), 255));
        assert!(!store.has_record(&id(1)) && store.has_record(&id(2)));
        assert!(!take(&mut store, 6, Origin::Link(1), 255));
    }

    #[test]
    fn a_full_store_evicts_a_row_whose_lifetime_ended_first() {
        let mut store = store(3, 64, 64);
        assert!(take(&mut store, 1, Origin::Link(0), 255));
        assert!(take(&mut store, 2, Origin::Link(1), 1));
        assert!(take(&mut store, 3, Origin::Departed, 255));
        store.advance(UNIT);
        assert!(take(&mut store, 4, Origin::Link(0), 255));
        assert!(!store.holds(&id(2)) && store.has_record(&id(2)));
        assert!(store.holds(&id(1)) && store.holds(&id(3)) && store.holds(&id(4)));
        assert_eq!(store.held(), 3);
    }

    #[test]
    fn a_full_store_evicts_rows_of_closed_links_before_any_live_class() {
        let mut store = store(4, 64, 64);
        assert!(take(&mut store, 1, Origin::Link(0), 255));
        assert!(take(&mut store, 2, Origin::Link(0), 255));
        assert!(take(&mut store, 3, Origin::Link(1), 255));
        assert!(take(&mut store, 4, Origin::Local, 255));
        store.depart(1);
        assert!(take(&mut store, 5, Origin::Link(2), 255));
        assert!(!store.holds(&id(3)));
        assert_eq!(store.held(), 4);
    }

    /// T-SEC-4 at the store: the class that holds the most pays, so a flood
    /// from one link evicts its own rows, not a smaller class's.
    #[test]
    fn a_full_store_evicts_from_the_class_that_holds_the_most() {
        let mut store = store(8, 256, 256);
        for n in 1..=3 {
            assert!(take(&mut store, n, Origin::Link(0), 255));
        }
        assert!(take(&mut store, 4, Origin::Local, 255));
        for n in 5..=8 {
            assert!(take(&mut store, n, Origin::Link(1), 255));
        }
        for n in 9..=60 {
            assert!(take(&mut store, n, Origin::Link(1), 255));
            assert_eq!(store.held(), 8);
            assert!((1..=4).all(|kept| store.holds(&id(kept))));
        }
    }

    #[test]
    fn the_incoming_packet_counts_in_its_own_class() {
        let mut store = store(4, 64, 64);
        assert!(take(&mut store, 1, Origin::Link(0), 255));
        assert!(take(&mut store, 2, Origin::Link(0), 255));
        assert!(take(&mut store, 3, Origin::Link(1), 255));
        assert!(take(&mut store, 4, Origin::Link(1), 255));
        // Two rows each: the newcomer's link is the larger with it counted.
        assert!(take(&mut store, 5, Origin::Link(1), 255));
        assert!(store.holds(&id(1)) && store.holds(&id(2)) && store.holds(&id(5)));
        // A third class with no row yet evicts from the first of the equals.
        assert!(take(&mut store, 6, Origin::Local, 255));
        assert_eq!(
            store
                .ids()
                .filter(|held| [id(1), id(2)].contains(held))
                .count(),
            1
        );
    }

    #[test]
    fn the_evicted_row_within_a_class_is_the_generators_pick() {
        let victims: BTreeSet<PacketId> = (0..40)
            .map(|seed| {
                let mut store = store(8, 64, 64);
                for n in 1..=8 {
                    assert!(take(&mut store, n, Origin::Link(0), 255));
                }
                let expires = store.announced_expiry(255);
                let mut rng = StdRng::seed_from_u64(seed);
                assert!(store.accept(packet(9), Origin::Link(0), expires, &mut rng));
                let gone: Vec<_> = (1..=8).map(id).filter(|id| !store.holds(id)).collect();
                assert_eq!(gone.len(), 1);
                gone[0]
            })
            .collect();
        assert!(
            victims.len() > 4,
            "the pick did not vary with the generator"
        );
    }

    #[test]
    fn a_store_with_no_room_keeps_the_record_and_the_unread_packet() {
        let mut store = store(0, 64, 64);
        assert!(take(&mut store, 1, Origin::Link(0), 255));
        assert!(store.has_record(&id(1)) && !store.holds(&id(1)));
        assert_eq!(store.held(), 0);
        assert!(store.take_unread(8) == vec![packet(1)]);
    }

    #[test]
    fn a_closed_links_slot_is_owed_every_announcement_again() {
        let mut store = roomy();
        assert!(take(&mut store, 1, Origin::Link(0), 200));
        assert!(take(&mut store, 2, Origin::Link(1), 200));
        assert_eq!(announced(&mut store, 1).len(), 1);
        assert!(store.claim(&id(1), 1));
        store.depart(1);
        // The slot's next link has been told nothing and given nothing.
        assert!(!store.claim(&id(1), 1));
        assert_eq!(announced(&mut store, 1).len(), 2);
        assert!(store.claim(&id(1), 1) && store.claim(&id(2), 1));
    }

    /// T-BG-3.
    #[test]
    fn unread_packets_outlive_their_lifetime_and_the_oldest_go_past_the_cap() {
        let mut store = store(8, 64, 3);
        for n in 1..=3 {
            assert!(take(&mut store, n, Origin::Link(0), 10));
        }
        assert!(take(&mut store, 4, Origin::Local, 255));
        assert_eq!(store.unread(), 3);
        store.advance(3 * LIFE);
        assert_eq!((store.held(), store.records(), store.unread()), (0, 0, 3));

        assert!(take(&mut store, 5, Origin::Link(0), 10));
        assert_eq!(store.unread(), 3);
        assert!(store.take_unread(2) == vec![packet(2), packet(3)]);
        assert!(store.take_unread(9) == vec![packet(5)]);
        assert!(store.take_unread(9).is_empty());
    }

    fn carried_and_sent(store: &mut Store, n: u64) {
        assert!(take(store, n, Origin::Link(0), 200));
        store.sent(&id(n));
    }

    /// T-STAT-1.
    #[test]
    fn a_carried_packet_sent_on_and_not_opened_is_passed_on_once() {
        let mut store = roomy();
        carried_and_sent(&mut store, 1);
        assert_eq!(store.passed_on(), 0);
        store.mark_read(&id(1), false);
        assert_eq!(store.passed_on(), 1);
        store.mark_read(&id(1), false);
        store.sent(&id(1));
        assert_eq!(store.passed_on(), 1);

        // The verdict first, the send after.
        assert!(take(&mut store, 2, Origin::Link(0), 200));
        store.mark_read(&id(2), false);
        assert_eq!(store.passed_on(), 1);
        store.sent(&id(2));
        assert_eq!(store.passed_on(), 2);
    }

    #[test]
    fn an_opened_an_own_and_an_unsent_packet_are_never_passed_on() {
        let mut store = roomy();
        carried_and_sent(&mut store, 1);
        store.mark_read(&id(1), true);
        store.mark_read(&id(1), false);

        assert!(take(&mut store, 2, Origin::Local, 200));
        store.sent(&id(2));
        store.mark_read(&id(2), false);

        assert!(take(&mut store, 3, Origin::Link(0), 200));
        store.mark_read(&id(3), false);

        store.mark_read(&id(4), false);
        assert_eq!(store.passed_on(), 0);
    }

    #[test]
    fn a_packet_dropped_unread_from_the_queue_counts_as_not_ours() {
        let mut store = store(8, 64, 1);
        carried_and_sent(&mut store, 1);
        assert!(take(&mut store, 2, Origin::Link(0), 200));
        assert_eq!(store.passed_on(), 1);
        assert!(take(&mut store, 3, Origin::Link(0), 200));
        assert_eq!(store.passed_on(), 1);
    }

    #[test]
    fn a_verdict_after_the_record_is_forgotten_still_counts() {
        let mut store = roomy();
        carried_and_sent(&mut store, 1);
        carried_and_sent(&mut store, 2);
        assert!(take(&mut store, 3, Origin::Link(0), 200));
        store.advance(2 * LIFE);
        assert_eq!(store.records(), 0);
        assert_eq!(store.take_unread(8).len(), 3);
        store.mark_read(&id(1), false);
        store.mark_read(&id(1), false);
        store.mark_read(&id(2), true);
        store.mark_read(&id(2), false);
        store.mark_read(&id(3), false);
        assert_eq!(store.passed_on(), 1);

        // Dropped from the queue after its record went: counted there.
        let mut store = store_with_unread(1);
        carried_and_sent(&mut store, 1);
        store.advance(2 * LIFE);
        assert!(take(&mut store, 2, Origin::Link(0), 200));
        assert_eq!(store.passed_on(), 1);
    }

    fn store_with_unread(unread: usize) -> Store {
        store(8, 64, unread)
    }

    /// Session code that never gives a verdict cannot grow the store.
    #[test]
    fn verdicts_awaited_past_a_records_life_are_bounded() {
        let mut store = store(8, 64, 2);
        for n in 1..=6 {
            carried_and_sent(&mut store, n);
            let _ = store.take_unread(8);
        }
        store.advance(2 * LIFE);
        assert_eq!(store.late.len(), 2);
    }

    #[test]
    fn clearing_drops_everything_but_the_count() {
        let mut store = roomy();
        carried_and_sent(&mut store, 1);
        store.mark_read(&id(1), false);
        assert!(take(&mut store, 2, Origin::Local, 200));
        store.clear();
        assert_eq!((store.held(), store.records(), store.unread()), (0, 0, 0));
        assert!(store.ids().next().is_none() && store.late.is_empty());
        assert_eq!(store.passed_on(), 1);
        assert!(take(&mut store, 1, Origin::Link(0), 200));
    }

    /// T-PRIV-7: the starting lifetime is the generator's draw from the top
    /// quarter, every step of it reachable.
    #[test]
    fn an_emitted_packet_starts_in_the_top_quarter_of_the_lifetime() {
        let mut store = roomy();
        store.advance(1000);
        let drawn = StdRng::seed_from_u64(7).gen_range(192..=255u64);
        assert_eq!(
            store.origin_expiry(&mut StdRng::seed_from_u64(7)),
            1000 + drawn * UNIT
        );

        let mut rng = rng();
        let seen: BTreeSet<u64> = (0..5000)
            .map(|_| (store.origin_expiry(&mut rng) - 1000) / UNIT)
            .collect();
        assert!(seen.iter().copied().eq(192..=255));
    }

    #[derive(Clone, Debug)]
    enum Op {
        Accept { n: u64, origin: u8, units: u8 },
        Advance(u64),
        Heard { n: u64, slot: u8, units: u8 },
        Announce(u8),
        Claim { n: u64, slot: u8 },
        Sent(u64),
        Depart(u8),
        Take(usize),
        Mark { n: u64, opened: bool },
    }

    fn op() -> impl Strategy<Value = Op> {
        let n = 0u64..24;
        let slot = 0u8..3;
        prop_oneof![
            4 => (n.clone(), 0u8..4, any::<u8>())
                .prop_map(|(n, origin, units)| Op::Accept { n, origin, units }),
            3 => (0..LIFE / 2).prop_map(Op::Advance),
            2 => (n.clone(), slot.clone(), any::<u8>())
                .prop_map(|(n, slot, units)| Op::Heard { n, slot, units }),
            1 => slot.clone().prop_map(Op::Announce),
            1 => (n.clone(), slot.clone()).prop_map(|(n, slot)| Op::Claim { n, slot }),
            1 => n.clone().prop_map(Op::Sent),
            1 => slot.prop_map(Op::Depart),
            1 => (0usize..5).prop_map(Op::Take),
            1 => (n, any::<bool>()).prop_map(|(n, opened)| Op::Mark { n, opened }),
        ]
    }

    proptest! {
        /// Whatever happens to a store, it stays inside its limits, a held
        /// packet has a record, a record lasts exactly `2 L`, bytes are gone
        /// by `first + L`, and no lifetime ends past `first + L`.
        #[test]
        fn prop_a_store_stays_within_its_limits(ops in proptest::collection::vec(op(), 1..120)) {
            const PACKETS: usize = 6;
            const RECORDS: usize = 12;
            const UNREAD: usize = 5;
            let mut store = store(PACKETS, RECORDS, UNREAD);
            let mut rng = rng();
            let mut now = 0;
            let mut first: BTreeMap<u64, u64> = BTreeMap::new();
            let mut passed_on = 0;
            for op in ops {
                match op {
                    Op::Accept { n, origin, units } => {
                        let origin = match origin {
                            0 => Origin::Local,
                            slot => Origin::Link(slot - 1),
                        };
                        let expires = store.announced_expiry(units);
                        let fresh = !first.contains_key(&n) && first.len() < RECORDS;
                        prop_assert_eq!(store.accept(packet(n), origin, expires, &mut rng), fresh);
                        if fresh {
                            first.insert(n, now);
                        }
                    }
                    Op::Advance(by) => {
                        now += by;
                        store.advance(now);
                        first.retain(|_, at| *at + 2 * LIFE > now);
                    }
                    Op::Heard { n, slot, units } => {
                        let expires = store.announced_expiry(units);
                        prop_assert_eq!(store.heard(&id(n), slot, expires), first.contains_key(&n));
                    }
                    Op::Announce(slot) => {
                        for (announced, remaining) in announced(&mut store, slot) {
                            prop_assert!(remaining > 0 && store.holds(&announced));
                            prop_assert_eq!(remaining, store.remaining(&announced));
                        }
                    }
                    Op::Claim { n, slot } => {
                        if store.claim(&id(n), slot) {
                            prop_assert!(store.packet(&id(n)).is_some());
                            prop_assert!(!store.claim(&id(n), slot));
                        }
                    }
                    Op::Sent(n) => store.sent(&id(n)),
                    Op::Depart(slot) => store.depart(slot),
                    Op::Take(max) => prop_assert!(store.take_unread(max).len() <= max),
                    Op::Mark { n, opened } => store.mark_read(&id(n), opened),
                }

                prop_assert!(store.held() <= PACKETS);
                prop_assert_eq!(store.held(), store.ids().count());
                prop_assert!(store.records() <= RECORDS);
                prop_assert_eq!(store.records(), first.len());
                prop_assert!(store.unread() <= UNREAD);
                prop_assert!(store.late.len() <= UNREAD);
                prop_assert!(store.passed_on() >= passed_on);
                passed_on = store.passed_on();
                for n in 0..24 {
                    let id = id(n);
                    let at = first.get(&n).copied();
                    prop_assert_eq!(store.has_record(&id), at.is_some());
                    prop_assert!(!store.holds(&id) || at.is_some_and(|at| now < at + LIFE));
                    prop_assert!(store.remaining(&id) == 0 || store.holds(&id));
                    let ends = store.expires_ms(&id);
                    prop_assert_eq!(ends.is_some(), at.is_some());
                    prop_assert!(ends.unwrap_or(0) <= at.unwrap_or(0) + LIFE);
                }
            }
        }

        /// T-LIFE-4 and T-LIFE-5 on a line of honest phones with no transit
        /// delay: no phone's lifetime for a packet ends after the one it
        /// heard it from, a hop loses under one unit, and so nobody announces
        /// the packet past its origin time + `L`.
        #[test]
        fn prop_an_honest_line_never_stretches_a_lifetime(
            seed in any::<u64>(),
            waits in proptest::collection::vec(0u64..40_000, 1..40),
        ) {
            let mut rng = StdRng::seed_from_u64(seed);
            let mut now = 1000;
            let mut holder = roomy();
            holder.advance(now);
            let origin_expires = holder.origin_expiry(&mut rng);
            prop_assert!(holder.accept(packet(1), Origin::Local, origin_expires, &mut rng));
            prop_assert!(origin_expires < now + LIFE);
            let mut hops = 0;
            for wait in waits {
                now += wait;
                holder.advance(now);
                let Some((_, remaining)) = holder.next_announcement(1, None, now) else {
                    prop_assert!(holder.remaining(&id(1)) == 0);
                    break;
                };
                let before = holder.expires_ms(&id(1)).expect("recorded");
                let mut next = roomy();
                next.advance(now);
                let expires = next.announced_expiry(remaining);
                prop_assert!(next.accept(packet(1), Origin::Link(0), expires, &mut rng));
                hops += 1;
                prop_assert!(expires <= before && before - expires < UNIT);
                prop_assert!(origin_expires - expires < hops * UNIT);
                holder = next;
            }
        }
    }
}
