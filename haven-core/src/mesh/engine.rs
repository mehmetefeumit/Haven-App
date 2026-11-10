//! The mesh engine: one phone's links, inventory flood, emission schedule and
//! link budget as an owned state machine (plan §3, §5.1, §6, §15).
//!
//! The engine holds no key, does no I/O and reads no clock. Every input names
//! the time on a clock that keeps counting during sleep; time never runs
//! backwards, and every input first runs the timers that fell due. What the
//! radio layer must do comes out of [`MeshEngine::poll_output`]; when to call
//! [`MeshEngine::advance`] next comes out of [`MeshEngine::next_wake_ms`].
//!
//! A link carries the two raw Noise handshake messages, then sealed frames of
//! exactly its frame size (`frame`). Each side opens with `HELLO`, announces
//! what it holds as `HAVE`, asks with `WANT` for what it lacks and may take,
//! and is sent each wanted packet as `PKT` chunks. A packet that was not asked
//! for on that link, a frame that does not open or does not parse, and a first
//! frame that is not `HELLO` close the link.
//!
//! **Duplicate links.** Two phones may connect in both directions. Of the
//! links on which one `HELLO` value has been seen, the one that saw it first
//! is kept and the others are closed with `BYE`; a value equal to this
//! phone's own closes the link it came on. Both ends see the same order
//! unless the two links' `HELLO`s cross, in which case each may close a
//! different one and the jittered back-off lets one re-form. The rule keeps
//! the older link because a `HELLO` value is not a secret: a rule the newer
//! link could win would let any neighbour of a peer close the link to it.
//!
//! **Reserved slots.** One outgoing slot is filled at random among the
//! sighted candidates and closed again after [`Config::rotate_ms`]. Whoever
//! connects in cannot be chosen, so once every incoming slot has been held
//! for [`Config::rotate_ms`] one incoming link, picked at random, is closed:
//! no peer keeps every incoming slot.
//!
//! **Credit.** Packets arrive only when asked for, and a link is asked for
//! no more than its allowance, which starts near zero and grows with its age;
//! the one way to exceed it is an unsolicited packet, which closes the link.
//!
//! Nothing here logs, and no type that holds a packet, an id or a peer is
//! `Debug` (Security Rule 15).

use std::cmp::Reverse;
use std::collections::{BTreeMap, VecDeque};

use rand::{CryptoRng, Rng, RngCore};

use super::frame::{self, Frame, FrameSize, HELLO_VALUE_LEN};
use super::noise::{self, Initiator, Transport};
use super::packet::{cover_packet, Packet, PacketId, PACKET_LEN};
use super::store::{Limits, Origin, Store, MAX_LINKS};

const MINUTE_MS: u64 = 60_000;

/// One radio link, named by the caller. The engine never reuses or
/// interprets it.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct LinkId(pub u64);

/// One advertiser the radio layer has seen, named by the caller: the engine
/// never sees a Bluetooth address.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct PeerRef(pub u64);

/// One outbox slot, named by session code: an opaque local number that tells
/// the engine nothing about the circle behind it.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct CircleSlot(pub u32);

/// This phone's side of a link.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    /// This phone connected: an outgoing link, and the handshake initiator.
    Central,
    /// The peer connected: an incoming link.
    Peripheral,
}

/// What the radio layer must do.
#[derive(Clone, PartialEq, Eq)]
pub enum Output {
    /// Send `bytes` on `link` as one frame, in order.
    Frame {
        /// The link to send on.
        link: LinkId,
        /// A handshake message, or a sealed frame of the link's frame size.
        bytes: Vec<u8>,
    },
    /// Disconnect `link`. The engine has already forgotten it.
    Close {
        /// The link to disconnect.
        link: LinkId,
    },
    /// Connect to `peer`, then report `link_up` or `connect_failed`.
    Connect {
        /// The advertiser to connect to.
        peer: PeerRef,
    },
}

/// Counts for the statistics sheet and for tests. Shown, never logged.
#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub struct Stats {
    /// Unique carried packets sent on to another phone that this phone could
    /// not open (§7.5).
    pub passed_on: u64,
    /// Links past their `HELLO` exchange.
    pub links: usize,
    /// Packets held.
    pub held: usize,
    /// Per-packet records kept.
    pub records: usize,
    /// Packets waiting for session code.
    pub unread: usize,
    /// Outbox entries waiting for an emission slot.
    pub outbox: usize,
    /// Emission slots served, cover packets included.
    pub emitted: u64,
    /// Packets accepted from links.
    pub accepted: u64,
    /// Packets handed in full to the radio layer.
    pub sent: u64,
    /// Packets received in full that already had a record: zero unless a
    /// request was given up on and answered late.
    pub duplicates: u64,
}

/// Every tunable of the engine. The defaults are the plan's where it names
/// one; the simulator fixes the rest (G-7).
#[derive(Clone)]
pub struct Config {
    /// §6.4 `L`: the longest a packet lives from its origin.
    pub life_ms: u64,
    /// §6.4: the most packets held.
    pub store_packets: usize,
    /// §5.2: the most packets queued for session code; the oldest go first.
    pub unread_packets: usize,
    /// §5.1: the middle of the emission slot period.
    pub emit_period_ms: u64,
    /// §5.1: an emission slot is the period ± this, drawn per slot.
    pub emit_jitter_ms: u64,
    /// §5.1: the most outbox slots; an offer for one more is dropped.
    pub outbox_slots: usize,
    /// §6.3: the period of the one tick on which new packets are announced
    /// to every link, requests are reviewed and links are planned.
    pub tick_ms: u64,
    /// §6.3: the most packets asked of one link and not yet received.
    pub want_window: usize,
    /// §6.3: how long a request waits before it is made again or given up.
    pub want_timeout_ms: u64,
    /// §6.3: how many times a packet is asked of one link before another
    /// link that announced it is asked.
    pub want_asks: u8,
    /// §6.3: the most announcements remembered per link for packets not yet
    /// held; further ones are ignored.
    pub offers_per_link: usize,
    /// §6.3: the most frames queued per link for the radio layer; the engine
    /// produces more as they are polled.
    pub link_queue_frames: usize,
    /// §6.5: the packets a link may be asked for the moment it opens.
    pub credit_initial: u64,
    /// §6.5: how fast a link's allowance grows with its age.
    pub credit_per_min: u64,
    /// §6.5: the rate of newly requested packets over all links.
    pub accept_per_min: u64,
    /// §6.5: the most packets requested at once over all links.
    pub accept_burst: u64,
    /// §6.5: the rate of new incoming links.
    pub inbound_per_min: u64,
    /// §6.5: the most incoming links taken at once.
    pub inbound_burst: u64,
    /// §6.1: the most outgoing links, one of them the random slot.
    pub max_outgoing: usize,
    /// §6.1: the most incoming links. Both together at most 32.
    pub max_incoming: usize,
    /// §6.1: how often the `HELLO` value is drawn afresh.
    pub hello_period_ms: u64,
    /// §6.1: the weakest signal a peer is connected to at.
    pub rssi_floor: i8,
    /// §6.1: how much stronger a candidate must be to replace the weakest
    /// signal-chosen link.
    pub rssi_hysteresis: u8,
    /// §6.1: how long the random outgoing link, and a full set of incoming
    /// links, lasts before one is closed.
    pub rotate_ms: u64,
    /// §6.1: how long a sighting makes a peer a candidate.
    pub sighting_ttl_ms: u64,
    /// §6.1: how long a connect attempt may take.
    pub connect_timeout_ms: u64,
    /// §6.1: how long a peer is left alone after a failed connect or a
    /// closed link.
    pub backoff_ms: u64,
    /// §6.1: up to this much is added to each back-off, drawn per use, so two
    /// phones that closed each other's link do not retry in step.
    pub backoff_jitter_ms: u64,
    /// §6.1: the most peers remembered from sightings.
    pub max_peers: usize,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            life_ms: 20 * MINUTE_MS,
            store_packets: 2048,
            unread_packets: 8192,
            emit_period_ms: 90_000,
            emit_jitter_ms: 30_000,
            outbox_slots: 64,
            tick_ms: 5000,
            want_window: 32,
            want_timeout_ms: 30_000,
            want_asks: 2,
            offers_per_link: 2048,
            link_queue_frames: 16,
            credit_initial: 16,
            credit_per_min: 120,
            accept_per_min: 240,
            accept_burst: 2048,
            inbound_per_min: 12,
            inbound_burst: 4,
            max_outgoing: 4,
            max_incoming: 4,
            hello_period_ms: 15 * MINUTE_MS,
            rssi_floor: -85,
            rssi_hysteresis: 8,
            rotate_ms: 10 * MINUTE_MS,
            sighting_ttl_ms: 30_000,
            connect_timeout_ms: 30_000,
            backoff_ms: 60_000,
            backoff_jitter_ms: 30_000,
            max_peers: 64,
        }
    }
}

impl Config {
    /// The size of the record table (§6.4): every packet that can be
    /// requested or emitted within the `2 L` a record lasts, so traffic
    /// inside the rate limit cannot fill it.
    #[must_use]
    pub fn record_capacity(&self) -> usize {
        let reaccept_ms = self.life_ms.saturating_mul(2);
        let requested = self
            .accept_per_min
            .saturating_mul(reaccept_ms.div_ceil(MINUTE_MS))
            .saturating_add(self.accept_burst);
        let shortest_slot = self.emit_period_ms.saturating_sub(self.emit_jitter_ms);
        let emitted = reaccept_ms / shortest_slot.max(1) + 1;
        usize::try_from(requested.saturating_add(emitted)).unwrap_or(usize::MAX)
    }

    /// Periods of at least a millisecond and no more links than a record
    /// tracks: a zero period would wake the caller forever.
    fn bounded(mut self) -> Self {
        self.tick_ms = self.tick_ms.max(1);
        self.emit_period_ms = self.emit_period_ms.max(1);
        self.emit_jitter_ms = self.emit_jitter_ms.min(self.emit_period_ms - 1);
        self.max_outgoing = self.max_outgoing.min(usize::from(MAX_LINKS));
        self.max_incoming = self
            .max_incoming
            .min(usize::from(MAX_LINKS) - self.max_outgoing);
        self
    }
}

/// A token bucket in units of a token-minute, so a rate per minute needs no
/// division.
struct Bucket {
    level: u64,
    at_ms: u64,
}

impl Bucket {
    const fn full(burst: u64, now_ms: u64) -> Self {
        Self {
            level: burst.saturating_mul(MINUTE_MS),
            at_ms: now_ms,
        }
    }

    fn take(&mut self, per_min: u64, burst: u64, now_ms: u64) -> bool {
        let gained = now_ms.saturating_sub(self.at_ms).saturating_mul(per_min);
        self.level = self
            .level
            .saturating_add(gained)
            .min(burst.saturating_mul(MINUTE_MS));
        self.at_ms = now_ms;
        let granted = self.level >= MINUTE_MS;
        if granted {
            self.level -= MINUTE_MS;
        }
        granted
    }
}

/// How a link got its slot.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Incoming,
    /// Outgoing, chosen by signal strength.
    Nearest,
    /// Outgoing, the slot filled at random.
    Random,
}

enum Phase {
    /// Outgoing: the handshake hello is sent, the reply awaited.
    Reply(Initiator),
    /// Incoming: the handshake hello is awaited.
    Hello,
    Open(Transport),
}

/// Where a packet a link announced, and this phone has no record of, stands.
#[derive(Clone, Copy)]
enum Ask {
    /// Announced, not asked for.
    Offered,
    /// Asked for `asks` times, last at `since_ms`.
    Asked { since_ms: u64, asks: u8 },
    /// Asked for and given up on: still taken if it arrives, but another
    /// link may be asked.
    Abandoned,
}

struct Offer {
    /// When the packet's lifetime ends, by the link's announcements.
    expires_ms: u64,
    state: Ask,
}

/// A packet being sent as chunks.
struct Sending {
    id: PacketId,
    packet: Packet,
    index: u8,
}

struct Link {
    id: LinkId,
    peer: Option<PeerRef>,
    /// A peer whose own link was closed as a duplicate of this one: reached
    /// through this link for as long as it lasts.
    alias: Option<PeerRef>,
    kind: Kind,
    up_ms: u64,
    size: FrameSize,
    phase: Phase,
    hello_due: bool,
    /// The peer's `HELLO` value and when it was first seen on this link, in
    /// the order the engine saw such values.
    peer_hello: Option<([u8; HELLO_VALUE_LEN], u64)>,
    /// An inventory scan is under way: packets due by `scan_ms`, in id order
    /// after `cursor`.
    announcing: bool,
    cursor: Option<PacketId>,
    scan_ms: u64,
    offers: BTreeMap<PacketId, Offer>,
    /// Offers in [`Ask::Asked`].
    asked: usize,
    /// Offers in [`Ask::Asked`] or [`Ask::Abandoned`]: packets that may
    /// arrive.
    expected: usize,
    /// Packets ever asked of this link: what its credit is spent on.
    charged: u64,
    /// Ids to put in `WANT` frames.
    wants: VecDeque<PacketId>,
    /// Packets the peer asked for, in order.
    sends: VecDeque<PacketId>,
    sending: Option<Sending>,
    /// The chunks of the packet the peer is sending, so far.
    assembly: Vec<u8>,
    /// Frames in the output queue.
    queued: usize,
    /// The output queue was full when the link last had a turn.
    blocked: bool,
}

struct Peer {
    rssi: i8,
    seen_ms: u64,
    /// Not connected to before this.
    retry_ms: u64,
}

struct Attempt {
    peer: PeerRef,
    kind: Kind,
    since_ms: u64,
}

struct Waiting {
    packet: Option<(Packet, u64)>,
    /// The emission that last served this slot; zero for never.
    served: u64,
}

struct Queued {
    output: Output,
    /// The packet this frame is the last chunk of.
    completes: Option<PacketId>,
}

impl Queued {
    const fn plain(output: Output) -> Self {
        Self {
            output,
            completes: None,
        }
    }

    fn is_frame_of(&self, id: LinkId) -> bool {
        matches!(&self.output, Output::Frame { link, .. } if *link == id)
    }
}

/// How a link ends.
#[derive(Clone, Copy, PartialEq, Eq)]
enum End {
    /// The radio layer reported it gone: nothing to send or say.
    Gone,
    /// The peer broke the protocol, or the phone has no room: disconnect,
    /// and send nothing more.
    Drop,
    /// This phone's own choice: send what is queued, then `BYE`, then
    /// disconnect.
    Bye,
}

/// One phone's mesh state machine. See the module documentation.
pub struct MeshEngine<R> {
    config: Config,
    rng: R,
    now_ms: u64,
    stopped: bool,
    store: Store,
    links: Vec<Option<Link>>,
    output: VecDeque<Queued>,
    outbox: BTreeMap<CircleSlot, Waiting>,
    next_emit_ms: u64,
    next_tick_ms: Option<u64>,
    hello: [u8; HELLO_VALUE_LEN],
    hello_ms: u64,
    /// Counts the `HELLO` values seen, to order them.
    hellos_seen: u64,
    peers: BTreeMap<PeerRef, Peer>,
    connecting: Option<Attempt>,
    accepts: Bucket,
    inbound: Bucket,
    emitted: u64,
    accepted: u64,
    sent: u64,
    duplicates: u64,
}

impl<R: RngCore + CryptoRng> MeshEngine<R> {
    /// An engine with nothing stored and no link, its first emission slot one
    /// slot period from `now_ms`.
    pub fn new(config: Config, mut rng: R, now_ms: u64) -> Self {
        let config = config.bounded();
        let mut store = Store::new(Limits {
            life_ms: config.life_ms,
            packets: config.store_packets,
            records: config.record_capacity(),
            unread: config.unread_packets,
        });
        store.advance(now_ms);
        let hello = rng.gen();
        let slots = config.max_outgoing + config.max_incoming;
        let mut engine = Self {
            accepts: Bucket::full(config.accept_burst, now_ms),
            inbound: Bucket::full(config.inbound_burst, now_ms),
            config,
            rng,
            now_ms,
            stopped: false,
            store,
            links: std::iter::repeat_with(|| None).take(slots).collect(),
            output: VecDeque::new(),
            outbox: BTreeMap::new(),
            next_emit_ms: now_ms,
            next_tick_ms: None,
            hello,
            hello_ms: now_ms,
            hellos_seen: 0,
            peers: BTreeMap::new(),
            connecting: None,
            emitted: 0,
            accepted: 0,
            sent: 0,
            duplicates: 0,
        };
        engine.next_emit_ms = now_ms.saturating_add(engine.slot_delay());
        engine
    }

    // ---- inputs ----------------------------------------------------------

    /// The radio layer has a connection. A central starts the handshake at
    /// once; a peripheral waits for it.
    ///
    /// The link is refused with [`Output::Close`] when `max_frame` is outside
    /// `frame::MIN_FRAME_LEN..=frame::MAX_FRAME_LEN`, when its direction has
    /// no free slot, or when incoming links arrive faster than the limit.
    /// `peer` is who the link is to, when the radio layer knows.
    pub fn link_up(
        &mut self,
        link: LinkId,
        role: Role,
        max_frame: usize,
        peer: Option<PeerRef>,
        now_ms: u64,
    ) {
        if self.stopped {
            return;
        }
        self.clock(now_ms);
        // The caller reused an id: whatever the engine held for it is void.
        if let Some(slot) = self.slot_of(link) {
            self.end(slot, End::Gone);
        }
        self.output
            .retain(|queued| !queued.is_frame_of(link) && queued.output != Output::Close { link });
        if !self.admit(link, role, max_frame, peer) {
            self.output.push_back(Queued::plain(Output::Close { link }));
        }
        self.settle();
    }

    /// The radio layer lost `link`, or closed it as told.
    pub fn link_down(&mut self, link: LinkId, now_ms: u64) {
        if self.stopped {
            return;
        }
        self.clock(now_ms);
        if let Some(slot) = self.slot_of(link) {
            self.end(slot, End::Gone);
        }
        self.settle();
    }

    /// One frame arrived on `link`, whole and in order.
    pub fn receive(&mut self, link: LinkId, bytes: &[u8], now_ms: u64) {
        if self.stopped {
            return;
        }
        self.clock(now_ms);
        if let Some(slot) = self.slot_of(link) {
            if !self.take_bytes(slot, bytes) {
                self.end(slot, End::Drop);
            }
        }
        self.settle();
    }

    /// The scan saw `peer` advertising at `rssi` dBm.
    pub fn sighting(&mut self, peer: PeerRef, rssi: i8, now_ms: u64) {
        if self.stopped {
            return;
        }
        self.clock(now_ms);
        if let Some(known) = self.peers.get_mut(&peer) {
            known.rssi = rssi;
            known.seen_ms = self.now_ms;
        } else if rssi >= self.config.rssi_floor && self.peers.len() < self.config.max_peers {
            // A peer too weak to connect to is not worth a wake-up.
            let seen_ms = self.now_ms;
            self.peers.insert(
                peer,
                Peer {
                    rssi,
                    seen_ms,
                    retry_ms: 0,
                },
            );
        }
        self.settle();
    }

    /// The connect the engine asked for did not produce a link.
    pub fn connect_failed(&mut self, peer: PeerRef, now_ms: u64) {
        if self.stopped {
            return;
        }
        self.clock(now_ms);
        if self.connecting.as_ref().is_some_and(|c| c.peer == peer) {
            self.connecting = None;
        }
        self.back_off(peer);
        self.settle();
    }

    /// Puts `packet` in the outbox slot `slot`, replacing what waits there.
    /// It is emitted at most once, in an emission slot before `expires_ms`
    /// on the engine's clock, or not at all.
    pub fn offer(&mut self, slot: CircleSlot, packet: Packet, expires_ms: u64, now_ms: u64) {
        if self.stopped {
            return;
        }
        self.clock(now_ms);
        let entry = Some((packet, expires_ms));
        if let Some(waiting) = self.outbox.get_mut(&slot) {
            waiting.packet = entry;
        } else if self.outbox.len() < self.config.outbox_slots {
            self.outbox.insert(
                slot,
                Waiting {
                    packet: entry,
                    served: 0,
                },
            );
        }
        self.settle();
    }

    /// Empties and forgets the outbox slot `slot`.
    pub fn purge(&mut self, slot: CircleSlot, now_ms: u64) {
        if self.stopped {
            return;
        }
        self.clock(now_ms);
        self.outbox.remove(&slot);
        self.settle();
    }

    /// Runs the timers due at `now_ms`.
    pub fn advance(&mut self, now_ms: u64) {
        if self.stopped {
            return;
        }
        self.clock(now_ms);
        self.settle();
    }

    /// Mesh off: drops the store, the records, the outbox, the unread queue
    /// and every link, leaving one [`Output::Close`] per link to poll. The
    /// engine takes no further input; the counts in [`Self::stats`] stay.
    pub fn stop(&mut self) {
        if self.stopped {
            return;
        }
        self.stopped = true;
        self.output.clear();
        for slot in 0..self.links.len() {
            self.end(slot, End::Drop);
        }
        self.store.clear();
        self.outbox.clear();
        self.peers.clear();
        self.connecting = None;
        self.next_tick_ms = None;
    }

    // ---- outputs ---------------------------------------------------------

    /// The next thing for the radio layer to do, in order.
    ///
    /// The engine queues at most [`Config::link_queue_frames`] frames per
    /// link, one connect, and one close per link it was told of; it seals
    /// more frames as these are taken.
    pub fn poll_output(&mut self) -> Option<Output> {
        let Queued { output, completes } = self.output.pop_front()?;
        if let Output::Frame { link, .. } = &output {
            if let Some(id) = completes {
                self.store.sent(&id);
                self.sent += 1;
            }
            if let Some(slot) = self.slot_of(*link) {
                let refill = self.link_mut(slot).is_some_and(|link| {
                    link.queued = link.queued.saturating_sub(1);
                    link.blocked
                });
                if refill {
                    self.pump(slot);
                }
            }
        }
        Some(output)
    }

    /// The earliest time [`Self::advance`] has work; `None` once stopped.
    #[must_use]
    pub fn next_wake_ms(&self) -> Option<u64> {
        (!self.stopped).then(|| {
            self.next_tick_ms
                .map_or(self.next_emit_ms, |tick| tick.min(self.next_emit_ms))
        })
    }

    // ---- for session code ------------------------------------------------

    /// Up to `max` packets accepted from links and not yet handed out, oldest
    /// first. Packets this phone emitted are never among them.
    pub fn take_unread(&mut self, max: usize) -> Vec<Packet> {
        self.store.take_unread(max)
    }

    /// Whether a packet from [`Self::take_unread`] opened under one of this
    /// phone's keys.
    pub fn mark_read(&mut self, id: PacketId, opened: bool) {
        self.store.mark_read(&id, opened);
    }

    /// The engine's counts.
    #[must_use]
    pub fn stats(&self) -> Stats {
        Stats {
            passed_on: self.store.passed_on(),
            links: self.live().filter(|l| l.peer_hello.is_some()).count(),
            held: self.store.held(),
            records: self.store.records(),
            unread: self.store.unread(),
            outbox: self.outbox.values().filter(|w| w.packet.is_some()).count(),
            emitted: self.emitted,
            accepted: self.accepted,
            sent: self.sent,
            duplicates: self.duplicates,
        }
    }

    /// The store, to read.
    #[must_use]
    pub const fn store(&self) -> &Store {
        &self.store
    }

    // ---- time ------------------------------------------------------------

    /// Moves to `now_ms`, never backwards, and runs what fell due: at most
    /// one emission and one tick, however long the phone slept.
    fn clock(&mut self, now_ms: u64) {
        self.now_ms = self.now_ms.max(now_ms);
        self.store.advance(self.now_ms);
        if self.now_ms >= self.next_emit_ms {
            self.emit();
        }
        if self.next_tick_ms.is_some_and(|tick| self.now_ms >= tick) {
            self.next_tick_ms = Some(self.now_ms.saturating_add(self.config.tick_ms));
            self.tick();
        }
    }

    /// Ends every input: gives each link its turn to produce frames, and
    /// keeps the tick running only while there is a link or a peer to plan
    /// for, so an isolated phone wakes for its emission slots alone.
    fn settle(&mut self) {
        for slot in 0..self.links.len() {
            self.pump(slot);
        }
        let wanted =
            self.live().next().is_some() || !self.peers.is_empty() || self.connecting.is_some();
        self.next_tick_ms = match (wanted, self.next_tick_ms) {
            (false, _) => None,
            (true, None) => Some(self.now_ms.saturating_add(self.config.tick_ms)),
            (true, tick) => tick,
        };
    }

    fn slot_delay(&mut self) -> u64 {
        let jitter = self.config.emit_jitter_ms;
        let drawn = self.rng.gen_range(0..=jitter.saturating_mul(2));
        (self.config.emit_period_ms - jitter).saturating_add(drawn)
    }

    /// One emission slot: the outbox entry of the least recently served
    /// circle, or a cover packet, into the store like any received packet.
    fn emit(&mut self) {
        // The cover packet, the lifetime and the next slot are drawn whatever
        // the outbox holds: the generator's stream, and so every later draw
        // and every slot time, does not depend on whether a circle had an
        // update (T-PRIV-4).
        let cover = cover_packet(&mut self.rng);
        let expires_ms = self.store.origin_expiry(&mut self.rng);
        self.next_emit_ms = self.now_ms.saturating_add(self.slot_delay());
        self.emitted += 1;

        let (now, serial) = (self.now_ms, self.emitted);
        let real = self
            .outbox
            .values_mut()
            .filter(|waiting| waiting.packet.as_ref().is_some_and(|(_, ends)| *ends > now))
            .min_by_key(|waiting| waiting.served)
            .and_then(|waiting| {
                waiting.served = serial;
                waiting.packet.take()
            });
        for waiting in self.outbox.values_mut() {
            waiting.packet.take_if(|(_, ends)| *ends <= now);
        }
        let packet = real.map_or(cover, |(packet, _)| packet);
        self.store
            .accept(packet, Origin::Local, expires_ms, &mut self.rng);
    }

    /// The one coalesced tick.
    fn tick(&mut self) {
        let now = self.now_ms;
        if now.saturating_sub(self.hello_ms) >= self.config.hello_period_ms {
            self.hello = self.rng.gen();
            self.hello_ms = now;
            for link in self.links.iter_mut().flatten() {
                link.hello_due = matches!(link.phase, Phase::Open(_));
            }
        }
        let timeout = self.config.connect_timeout_ms;
        if let Some(stale) = self
            .connecting
            .take_if(|attempt| now.saturating_sub(attempt.since_ms) >= timeout)
        {
            self.back_off(stale.peer);
        }
        self.forget_peers();
        for slot in 0..self.links.len() {
            self.review_offers(slot);
            self.request(slot);
            if let Some(link) = self.link_mut(slot) {
                if link.peer_hello.is_some() {
                    link.announcing = true;
                    link.cursor = None;
                    link.scan_ms = now;
                }
            }
        }
        self.rotate();
        self.plan_links();
    }

    // ---- links -----------------------------------------------------------

    fn live(&self) -> impl Iterator<Item = &Link> {
        self.links.iter().flatten()
    }

    fn link_mut(&mut self, slot: usize) -> Option<&mut Link> {
        self.links.get_mut(slot)?.as_mut()
    }

    fn slot_of(&self, id: LinkId) -> Option<usize> {
        self.links
            .iter()
            .position(|link| link.as_ref().is_some_and(|link| link.id == id))
    }

    fn count(&self, incoming: bool) -> usize {
        self.live()
            .filter(|link| (link.kind == Kind::Incoming) == incoming)
            .count()
    }

    /// Gives a new link a slot and starts its handshake. `false` when it is
    /// refused.
    fn admit(&mut self, id: LinkId, role: Role, max_frame: usize, peer: Option<PeerRef>) -> bool {
        let Some(size) = FrameSize::of_link(max_frame) else {
            return false;
        };
        let now = self.now_ms;
        let kind = match role {
            Role::Central => {
                let attempt = self
                    .connecting
                    .take_if(|attempt| Some(attempt.peer) == peer);
                if self.count(false) >= self.config.max_outgoing {
                    return false;
                }
                attempt.map_or(Kind::Nearest, |attempt| attempt.kind)
            }
            Role::Peripheral => {
                let (rate, burst) = (self.config.inbound_per_min, self.config.inbound_burst);
                if self.count(true) >= self.config.max_incoming
                    || !self.inbound.take(rate, burst, now)
                {
                    return false;
                }
                Kind::Incoming
            }
        };
        let Some(slot) = self.links.iter().position(Option::is_none) else {
            return false;
        };
        let (phase, queued) = match role {
            Role::Central => {
                let (initiator, hello) = Initiator::start(&mut self.rng);
                self.output.push_back(Queued::plain(Output::Frame {
                    link: id,
                    bytes: hello.to_vec(),
                }));
                (Phase::Reply(initiator), 1)
            }
            Role::Peripheral => (Phase::Hello, 0),
        };
        let link = Link {
            id,
            peer,
            alias: None,
            kind,
            up_ms: now,
            size,
            phase,
            hello_due: false,
            peer_hello: None,
            announcing: false,
            cursor: None,
            scan_ms: now,
            offers: BTreeMap::new(),
            asked: 0,
            expected: 0,
            charged: 0,
            wants: VecDeque::new(),
            sends: VecDeque::new(),
            sending: None,
            assembly: Vec::new(),
            queued,
            blocked: false,
        };
        if let Some(free) = self.links.get_mut(slot) {
            *free = Some(link);
        }
        true
    }

    /// Forgets the link in `slot`. Its rows join the departed class and its
    /// peer is left alone for a while.
    fn end(&mut self, slot: usize, how: End) {
        let Some(mut link) = self.links.get_mut(slot).and_then(Option::take) else {
            return;
        };
        if how == End::Bye {
            // Sealed after what is already queued, so the peer can open it.
            if let Phase::Open(transport) = &mut link.phase {
                let bye = frame::bye(link.size).and_then(|plain| transport.seal(&plain));
                if let Some(bytes) = bye {
                    self.output.push_back(Queued::plain(Output::Frame {
                        link: link.id,
                        bytes,
                    }));
                }
            }
        } else {
            self.output.retain(|queued| !queued.is_frame_of(link.id));
        }
        if how != End::Gone {
            self.output
                .push_back(Queued::plain(Output::Close { link: link.id }));
        }
        if let Ok(slot) = u8::try_from(slot) {
            self.store.depart(slot);
        }
        if let Some(peer) = link.peer {
            self.back_off(peer);
        }
    }

    fn back_off(&mut self, peer: PeerRef) {
        if let Some(known) = self.peers.get_mut(&peer) {
            let jitter = self.rng.gen_range(0..=self.config.backoff_jitter_ms);
            let wait = self.config.backoff_ms.saturating_add(jitter);
            known.retry_ms = self.now_ms.saturating_add(wait);
        }
    }

    // ---- receiving -------------------------------------------------------

    /// One frame from the link in `slot`. `false` closes the link.
    fn take_bytes(&mut self, slot: usize, bytes: &[u8]) -> bool {
        let Some(link) = self.links.get_mut(slot).and_then(Option::as_mut) else {
            return true;
        };
        match std::mem::replace(&mut link.phase, Phase::Hello) {
            Phase::Reply(initiator) => {
                let Some(transport) = initiator.finish(bytes) else {
                    return false;
                };
                link.phase = Phase::Open(transport);
                link.hello_due = true;
                true
            }
            Phase::Hello => {
                let Some((transport, reply)) = noise::respond(bytes, &mut self.rng) else {
                    return false;
                };
                link.phase = Phase::Open(transport);
                link.hello_due = true;
                link.queued += 1;
                self.output.push_back(Queued::plain(Output::Frame {
                    link: link.id,
                    bytes: reply.to_vec(),
                }));
                true
            }
            Phase::Open(mut transport) => {
                let plain = (bytes.len() == link.size.sealed_len())
                    .then(|| transport.open(bytes))
                    .flatten();
                link.phase = Phase::Open(transport);
                plain.is_some_and(|plain| self.take_frame(slot, &plain))
            }
        }
    }

    fn take_frame(&mut self, slot: usize, plain: &[u8]) -> bool {
        let Some(frame) = frame::decode(plain) else {
            return false;
        };
        let greeted = self
            .link_mut(slot)
            .is_some_and(|link| link.peer_hello.is_some());
        match frame {
            Frame::Hello(value) => self.take_hello(slot, value),
            _ if !greeted => false,
            Frame::Have(entries) => {
                self.take_have(slot, entries.iter());
                true
            }
            Frame::Want(ids) => {
                self.take_want(slot, ids.iter());
                true
            }
            Frame::Pkt { index, chunk } => self.take_chunk(slot, index, chunk),
            Frame::Bye => false,
        }
    }

    /// The peer's `HELLO`: the first starts the inventory exchange, and any
    /// may show this link to be a second one to a phone already linked.
    fn take_hello(&mut self, slot: usize, value: [u8; HELLO_VALUE_LEN]) -> bool {
        if value == self.hello {
            return false;
        }
        let (now, seen) = (self.now_ms, self.hellos_seen);
        let Some(link) = self.link_mut(slot) else {
            return true;
        };
        match &mut link.peer_hello {
            Some((known, _)) if *known == value => return true,
            Some(known) => *known = (value, seen),
            None => {
                link.peer_hello = Some((value, seen));
                link.announcing = true;
                link.cursor = None;
                link.scan_ms = now;
            }
        }
        self.hellos_seen += 1;

        let same = |link: &Link| link.peer_hello.is_some_and(|(known, _)| known == value);
        let first = |link: &Link| link.peer_hello.map(|(_, seen)| seen);
        let Some(kept) = (0..self.links.len())
            .filter(|&s| self.links.get(s).and_then(Option::as_ref).is_some_and(same))
            .min_by_key(|&s| self.links.get(s).and_then(Option::as_ref).and_then(first))
        else {
            return true;
        };
        for other in 0..self.links.len() {
            let Some(duplicate) = self.links.get(other).and_then(Option::as_ref) else {
                continue;
            };
            if other == kept || !same(duplicate) {
                continue;
            }
            let reached = duplicate.peer;
            self.end(other, End::Bye);
            if let Some(keeper) = self.link_mut(kept) {
                if reached.is_some() && reached != keeper.peer {
                    keeper.alias = reached;
                }
            }
        }
        true
    }

    /// The peer's inventory: raises what is held, remembers what is not, and
    /// asks for as much of that as the link's credit allows.
    fn take_have(&mut self, slot: usize, entries: impl Iterator<Item = (PacketId, u8)>) {
        let cap = self.config.offers_per_link;
        let Ok(mark) = u8::try_from(slot) else {
            return;
        };
        for (id, remaining) in entries {
            let expires_ms = self.store.announced_expiry(remaining);
            if self.store.heard(&id, mark, expires_ms) {
                continue;
            }
            let Some(link) = self.links.get_mut(slot).and_then(Option::as_mut) else {
                return;
            };
            if let Some(offer) = link.offers.get_mut(&id) {
                offer.expires_ms = offer.expires_ms.max(expires_ms);
            } else if link.offers.len() < cap {
                let state = Ask::Offered;
                link.offers.insert(id, Offer { expires_ms, state });
            }
        }
        self.request(slot);
    }

    /// The peer's requests: each packet it was told of, once, while it is
    /// held and unexpired. Anything else is ignored, so asking tells nothing.
    fn take_want(&mut self, slot: usize, ids: impl Iterator<Item = PacketId>) {
        let cap = self.config.store_packets;
        let Ok(mark) = u8::try_from(slot) else {
            return;
        };
        let Some(link) = self.links.get_mut(slot).and_then(Option::as_mut) else {
            return;
        };
        for id in ids {
            if link.sends.len() < cap && self.store.claim(&id, mark) {
                link.sends.push_back(id);
            }
        }
    }

    /// One chunk of a packet the peer is sending. A whole packet is taken
    /// only if this link was asked for it.
    fn take_chunk(&mut self, slot: usize, index: u8, chunk: &[u8]) -> bool {
        let Ok(mark) = u8::try_from(slot) else {
            return false;
        };
        let Some(link) = self.links.get_mut(slot).and_then(Option::as_mut) else {
            return true;
        };
        let in_order = usize::from(index) * link.size.chunk_len() == link.assembly.len();
        if link.expected == 0 || !in_order {
            return false;
        }
        link.assembly.extend_from_slice(chunk);
        if link.assembly.len() < PACKET_LEN {
            return true;
        }
        let Ok(bytes) = <[u8; PACKET_LEN]>::try_from(std::mem::take(&mut link.assembly)) else {
            return false;
        };
        let packet = Packet::from_bytes(bytes);
        let id = packet.id();
        let expires_ms = match link.offers.remove(&id) {
            Some(Offer {
                state: Ask::Asked { .. },
                expires_ms,
            }) => {
                link.asked = link.asked.saturating_sub(1);
                expires_ms
            }
            Some(Offer {
                state: Ask::Abandoned,
                expires_ms,
            }) => expires_ms,
            Some(Offer {
                state: Ask::Offered,
                ..
            })
            | None => return false,
        };
        link.expected = link.expected.saturating_sub(1);

        if self.store.has_record(&id) {
            self.duplicates += 1;
            self.store.heard(&id, mark, expires_ms);
        } else if self
            .store
            .accept(packet, Origin::Link(mark), expires_ms, &mut self.rng)
        {
            self.accepted += 1;
        }
        // Every other link that announced it holds it too, and may have
        // announced a longer lifetime than the one that delivered.
        for (other, link) in self.links.iter_mut().enumerate() {
            let (Some(link), Ok(other)) = (link, u8::try_from(other)) else {
                continue;
            };
            if let Some(offer) = link.offers.get(&id) {
                self.store.heard(&id, other, offer.expires_ms);
                if matches!(offer.state, Ask::Offered) {
                    link.offers.remove(&id);
                }
            }
        }
        true
    }

    // ---- asking ----------------------------------------------------------

    /// Drops offers whose packet has expired, asks again for what did not
    /// arrive in time, and gives up after [`Config::want_asks`] tries.
    fn review_offers(&mut self, slot: usize) {
        let (now, timeout, max_asks) = (
            self.now_ms,
            self.config.want_timeout_ms,
            self.config.want_asks,
        );
        let Some(link) = self.links.get_mut(slot).and_then(Option::as_mut) else {
            return;
        };
        let (asked, expected, wants) = (&mut link.asked, &mut link.expected, &mut link.wants);
        // Requests not yet framed for offers since dropped or given up: with
        // them gone the queue holds each live request once per try at most.
        wants.retain(|id| {
            matches!(
                link.offers.get(id),
                Some(Offer {
                    state: Ask::Asked { .. },
                    ..
                })
            )
        });
        link.offers.retain(|id, offer| {
            let Ask::Asked { since_ms, asks } = &mut offer.state else {
                // A packet given up on may still arrive for a while.
                let abandoned = matches!(offer.state, Ask::Abandoned);
                let keep = offer
                    .expires_ms
                    .saturating_add(u64::from(abandoned) * timeout)
                    > now;
                *expected = expected.saturating_sub(usize::from(abandoned && !keep));
                return keep;
            };
            if offer.expires_ms.saturating_add(timeout) <= now {
                *asked = asked.saturating_sub(1);
                *expected = expected.saturating_sub(1);
                return false;
            }
            if now.saturating_sub(*since_ms) >= timeout {
                if *asks < max_asks {
                    *asks += 1;
                    *since_ms = now;
                    wants.push_back(*id);
                } else {
                    offer.state = Ask::Abandoned;
                    *asked = asked.saturating_sub(1);
                }
            }
            true
        });
    }

    /// Asks the link in `slot` for packets it announced, in id order: ones
    /// with no record, that no link is being asked for, within the link's
    /// window and credit and the rate limit over all links.
    fn request(&mut self, slot: usize) {
        let now = self.now_ms;
        let Some(link) = self.links.get_mut(slot).and_then(Option::as_mut) else {
            return;
        };
        let mut offers = std::mem::take(&mut link.offers);
        let age_ms = now.saturating_sub(link.up_ms);
        let allowance = self
            .config
            .credit_initial
            .saturating_add(age_ms.saturating_mul(self.config.credit_per_min) / MINUTE_MS);
        let (mut asked, mut charged) = (link.asked, link.charged);
        let mut picked = Vec::new();
        for (id, offer) in &mut offers {
            if asked >= self.config.want_window || charged >= allowance {
                break;
            }
            // This link's offers are out of `self` for the loop, so `live`
            // shows the other links'.
            let asked_elsewhere = || {
                self.live().any(|other| {
                    matches!(
                        other.offers.get(id),
                        Some(Offer {
                            state: Ask::Asked { .. },
                            ..
                        })
                    )
                })
            };
            if !matches!(offer.state, Ask::Offered)
                || offer.expires_ms <= now
                || self.store.has_record(id)
                || asked_elsewhere()
            {
                continue;
            }
            let (rate, burst) = (self.config.accept_per_min, self.config.accept_burst);
            if !self.accepts.take(rate, burst, now) {
                break;
            }
            offer.state = Ask::Asked {
                since_ms: now,
                asks: 1,
            };
            asked += 1;
            charged += 1;
            picked.push(*id);
        }
        if let Some(link) = self.links.get_mut(slot).and_then(Option::as_mut) {
            link.offers = offers;
            link.asked = asked;
            link.charged = charged;
            link.expected += picked.len();
            link.wants.extend(picked);
        }
    }

    // ---- sending ---------------------------------------------------------

    /// Seals frames for the link in `slot` until it has nothing to send or
    /// its share of the output queue is full.
    fn pump(&mut self, slot: usize) {
        loop {
            let limit = self.config.link_queue_frames;
            let Some(link) = self.links.get_mut(slot).and_then(Option::as_mut) else {
                return;
            };
            link.blocked = link.queued >= limit;
            if link.blocked {
                return;
            }
            let Some((plain, completes)) = self.next_frame(slot) else {
                return;
            };
            let Some(link) = self.links.get_mut(slot).and_then(Option::as_mut) else {
                return;
            };
            let Phase::Open(transport) = &mut link.phase else {
                return;
            };
            let Some(bytes) = transport.seal(&plain) else {
                self.end(slot, End::Drop);
                return;
            };
            link.queued += 1;
            let output = Output::Frame {
                link: link.id,
                bytes,
            };
            self.output.push_back(Queued { output, completes });
        }
    }

    /// The next plaintext frame the link in `slot` has to send, and the
    /// packet it completes: `HELLO`, then requests, then inventory, then
    /// packets.
    fn next_frame(&mut self, slot: usize) -> Option<(Vec<u8>, Option<PacketId>)> {
        let mark = u8::try_from(slot).ok()?;
        let link = self.links.get_mut(slot)?.as_mut()?;
        let size = link.size;
        if link.hello_due {
            link.hello_due = false;
            return Some((frame::hello(&self.hello, size)?, None));
        }
        link.peer_hello?;

        let mut ids = Vec::new();
        while ids.len() < size.want_capacity() {
            let Some(id) = link.wants.pop_front() else {
                break;
            };
            // An offer dropped since must not be asked for: its packet would
            // arrive unasked.
            if matches!(
                link.offers.get(&id),
                Some(Offer {
                    state: Ask::Asked { .. },
                    ..
                })
            ) {
                ids.push(id);
            }
        }
        if !ids.is_empty() {
            return Some((frame::want(&ids, size)?, None));
        }

        let mut entries = Vec::new();
        while link.announcing && entries.len() < size.have_capacity() {
            let next = self
                .store
                .next_announcement(mark, link.cursor, link.scan_ms);
            link.announcing = next.is_some();
            if let Some(entry) = next {
                link.cursor = Some(entry.0);
                entries.push(entry);
            }
        }
        if !entries.is_empty() {
            return Some((frame::have(&entries, size)?, None));
        }

        while link.sending.is_none() {
            let id = link.sends.pop_front()?;
            // Checked when the transfer starts, not when it was asked for: a
            // packet that expired in the queue is not sent.
            link.sending = self.store.packet(&id).map(|packet| Sending {
                id,
                packet,
                index: 0,
            });
        }
        let sending = link.sending.as_mut()?;
        let plain = frame::pkt(&sending.packet, sending.index, size)?;
        sending.index += 1;
        let last = usize::from(sending.index) == size.chunk_count();
        let completes = last.then_some(sending.id);
        if last {
            link.sending = None;
        }
        Some((plain, completes))
    }

    // ---- link budget -----------------------------------------------------

    /// Whether `peer` is reached by a link, or being connected to.
    fn linked(&self, peer: PeerRef) -> bool {
        self.live()
            .any(|link| link.peer == Some(peer) || link.alias == Some(peer))
            || self.connecting.as_ref().is_some_and(|c| c.peer == peer)
    }

    /// Peers worth connecting to now, with their signal.
    fn candidates(&self) -> Vec<(PeerRef, i8)> {
        let now = self.now_ms;
        self.peers
            .iter()
            .filter(|(peer, known)| {
                known.seen_ms.saturating_add(self.config.sighting_ttl_ms) > now
                    && known.rssi >= self.config.rssi_floor
                    && known.retry_ms <= now
                    && !self.linked(**peer)
            })
            .map(|(peer, known)| (*peer, known.rssi))
            .collect()
    }

    /// Forgets peers not seen lately, unless something still refers to them.
    fn forget_peers(&mut self) {
        let (now, ttl) = (self.now_ms, self.config.sighting_ttl_ms);
        let mut peers = std::mem::take(&mut self.peers);
        peers.retain(|peer, known| {
            known.seen_ms.saturating_add(ttl) > now || known.retry_ms > now || self.linked(*peer)
        });
        self.peers = peers;
    }

    /// Closes the random outgoing link once it has lasted its turn and
    /// another peer could take the slot, and one incoming link at random once
    /// every incoming slot has been held that long.
    fn rotate(&mut self) {
        let (now, turn) = (self.now_ms, self.config.rotate_ms);
        let aged = |link: &Link| now.saturating_sub(link.up_ms) >= turn;
        let slots_of = |links: &[Option<Link>], kind: Kind| -> Vec<usize> {
            (0..links.len())
                .filter(|&s| {
                    links
                        .get(s)
                        .and_then(Option::as_ref)
                        .is_some_and(|l| l.kind == kind)
                })
                .collect()
        };

        let random = slots_of(&self.links, Kind::Random);
        let due = random
            .first()
            .filter(|&&s| self.links.get(s).and_then(Option::as_ref).is_some_and(aged));
        if let Some(&slot) = due {
            if !self.candidates().is_empty() {
                self.end(slot, End::Bye);
            }
        }

        let incoming = slots_of(&self.links, Kind::Incoming);
        let all_aged = incoming
            .iter()
            .all(|&s| self.links.get(s).and_then(Option::as_ref).is_some_and(aged));
        if !incoming.is_empty() && incoming.len() >= self.config.max_incoming && all_aged {
            let pick = self.rng.gen_range(0..incoming.len());
            if let Some(&slot) = incoming.get(pick) {
                self.end(slot, End::Bye);
            }
        }
    }

    /// Starts at most one connect: the strongest candidate into a free
    /// signal-chosen slot, else a random candidate into the random slot, else
    /// the strongest in place of the weakest signal-chosen link it beats by
    /// the hysteresis.
    fn plan_links(&mut self) {
        // One attempt at a time, and none while the radio layer has yet to
        // take the last: an unpolled engine queues one connect, not many.
        let unpolled = |queued: &Queued| matches!(queued.output, Output::Connect { .. });
        if self.connecting.is_some() || self.output.iter().any(unpolled) {
            return;
        }
        let candidates = self.candidates();
        let Some(&(best, best_rssi)) = candidates
            .iter()
            .max_by_key(|(peer, rssi)| (*rssi, Reverse(*peer)))
        else {
            return;
        };
        let nearest = self.live().filter(|l| l.kind == Kind::Nearest).count();
        let random = self.live().any(|l| l.kind == Kind::Random);
        let outgoing = self.count(false);
        let limit = self.config.max_outgoing;

        if nearest < limit.saturating_sub(1) {
            self.connect(best, Kind::Nearest);
        } else if !random && outgoing < limit {
            let pick = self.rng.gen_range(0..candidates.len());
            if let Some(&(peer, _)) = candidates.get(pick) {
                self.connect(peer, Kind::Random);
            }
        } else if let Some((slot, rssi)) = self.weakest_nearest() {
            let margin = i16::from(self.config.rssi_hysteresis);
            if i16::from(best_rssi) >= i16::from(rssi) + margin {
                self.end(slot, End::Bye);
                self.connect(best, Kind::Nearest);
            }
        }
    }

    /// The signal-chosen link with the weakest signal, among those whose
    /// peer is still being sighted.
    fn weakest_nearest(&self) -> Option<(usize, i8)> {
        let now = self.now_ms;
        (0..self.links.len())
            .filter_map(|slot| {
                let link = self.links.get(slot)?.as_ref()?;
                let known = self.peers.get(&link.peer?)?;
                let fresh = known.seen_ms.saturating_add(self.config.sighting_ttl_ms) > now;
                (link.kind == Kind::Nearest && fresh).then_some((slot, known.rssi))
            })
            .min_by_key(|&(_, rssi)| rssi)
    }

    fn connect(&mut self, peer: PeerRef, kind: Kind) {
        self.connecting = Some(Attempt {
            peer,
            kind,
            since_ms: self.now_ms,
        });
        self.output
            .push_back(Queued::plain(Output::Connect { peer }));
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use proptest::prelude::*;
    use rand::rngs::StdRng;
    use rand::SeedableRng;

    use super::*;

    type Engine = MeshEngine<StdRng>;

    const FRAME: usize = 512;
    const TICK: u64 = 5000;
    const LIFE: u64 = 20 * MINUTE_MS;
    const UNIT: u64 = LIFE / 256;

    /// No emission within any test's time: only what a test puts in moves.
    fn quiet() -> Config {
        Config {
            emit_period_ms: 1 << 40,
            emit_jitter_ms: 0,
            ..Config::default()
        }
    }

    /// An emission slot every ten seconds exactly.
    fn emitting() -> Config {
        Config {
            emit_period_ms: 10_000,
            emit_jitter_ms: 0,
            ..Config::default()
        }
    }

    /// Credit that never binds, for tests about something else.
    fn trusting() -> Config {
        Config {
            credit_initial: 10_000,
            want_window: 10_000,
            ..quiet()
        }
    }

    fn engine(config: Config, seed: u64) -> Engine {
        MeshEngine::new(config, StdRng::seed_from_u64(seed), 0)
    }

    fn packet(n: u64) -> Packet {
        cover_packet(&mut StdRng::seed_from_u64(0xbeef_0000 + n))
    }

    fn id(n: u64) -> PacketId {
        packet(n).id()
    }

    fn size() -> FrameSize {
        FrameSize::of_link(FRAME).expect("within bounds")
    }

    /// One frame the engine sent to a scripted peer, opened and decoded.
    #[derive(Clone, PartialEq, Eq)]
    enum Seen {
        Hello([u8; 8]),
        Have(Vec<(PacketId, u8)>),
        Want(Vec<PacketId>),
        Pkt(u8, Vec<u8>),
        Bye,
    }

    /// One engine and the test as its radio layer: scripted peers that speak
    /// the link protocol by hand, so a test sees every frame the engine
    /// sends and can send it anything.
    struct Rig {
        engine: Engine,
        now: u64,
        peers: BTreeMap<LinkId, Transport>,
        seen: Vec<(LinkId, Seen)>,
        closed: Vec<LinkId>,
        connects: Vec<PeerRef>,
        /// Every frame the engine put on a link, as sent.
        air: Vec<Vec<u8>>,
    }

    impl Rig {
        fn new(config: Config) -> Self {
            Self {
                engine: engine(config, 1),
                now: 0,
                peers: BTreeMap::new(),
                seen: Vec::new(),
                closed: Vec::new(),
                connects: Vec::new(),
                air: Vec::new(),
            }
        }

        fn raw_frame(&mut self, link: LinkId) -> Vec<u8> {
            match self.engine.poll_output() {
                Some(Output::Frame { link: on, bytes }) if on == link => {
                    self.air.push(bytes.clone());
                    bytes
                }
                _ => panic!("the engine did not send its handshake message"),
            }
        }

        /// A scripted peer connects in and finishes the handshake.
        fn dial(&mut self, link: u64) -> LinkId {
            let link = LinkId(link);
            self.engine
                .link_up(link, Role::Peripheral, FRAME, None, self.now);
            let (initiator, hello) = Initiator::start(&mut StdRng::seed_from_u64(link.0));
            self.engine.receive(link, &hello, self.now);
            let reply = self.raw_frame(link);
            let transport = initiator.finish(&reply).expect("the engine's reply");
            self.peers.insert(link, transport);
            self.pump();
            link
        }

        /// The engine connects out to a scripted peer.
        fn answer(&mut self, link: u64, peer: PeerRef) -> LinkId {
            let link = LinkId(link);
            self.engine
                .link_up(link, Role::Central, FRAME, Some(peer), self.now);
            let hello = self.raw_frame(link);
            let (transport, reply) =
                noise::respond(&hello, &mut StdRng::seed_from_u64(link.0)).expect("a hello");
            self.peers.insert(link, transport);
            self.engine.receive(link, &reply, self.now);
            self.pump();
            link
        }

        /// A peer that dialled in and greeted with a value of its own.
        fn peer(&mut self, link: u64) -> LinkId {
            let id = self.dial(link);
            self.greet(id, link.to_le_bytes());
            id
        }

        fn seal(&mut self, link: LinkId, plain: Option<Vec<u8>>) -> Vec<u8> {
            self.peers
                .get_mut(&link)
                .expect("a live scripted peer")
                .seal(&plain.expect("the frame encodes"))
                .expect("seals")
        }

        fn send(&mut self, link: LinkId, plain: Option<Vec<u8>>) {
            let sealed = self.seal(link, plain);
            self.engine.receive(link, &sealed, self.now);
            self.pump();
        }

        fn greet(&mut self, link: LinkId, value: [u8; 8]) {
            self.send(link, frame::hello(&value, size()));
        }

        fn announce(&mut self, link: LinkId, entries: &[(PacketId, u8)]) {
            for batch in entries.chunks(size().have_capacity()) {
                self.send(link, frame::have(batch, size()));
            }
        }

        fn ask(&mut self, link: LinkId, ids: &[PacketId]) {
            for batch in ids.chunks(size().want_capacity()) {
                self.send(link, frame::want(batch, size()));
            }
        }

        fn deliver(&mut self, link: LinkId, packet: &Packet) {
            for index in 0..size().chunk_count() {
                let index = u8::try_from(index).expect("few chunks");
                self.send(link, frame::pkt(packet, index, size()));
            }
        }

        /// Announces packets `ns` with `remaining` units and delivers every
        /// one the engine asks for. Returns what it asked for.
        fn feed(&mut self, link: LinkId, ns: &[u64], remaining: u8) -> Vec<PacketId> {
            let entries: Vec<_> = ns.iter().map(|&n| (id(n), remaining)).collect();
            self.announce(link, &entries);
            let wanted = self.wants(link);
            for &n in ns {
                if wanted.contains(&id(n)) {
                    self.deliver(link, &packet(n));
                }
            }
            wanted
        }

        /// Carries out the next thing the engine has queued, if any.
        fn step(&mut self) -> bool {
            let Some(output) = self.engine.poll_output() else {
                return false;
            };
            match output {
                Output::Frame { link, bytes } => {
                    assert_eq!(bytes.len(), FRAME, "a sealed frame of another length");
                    let transport = self.peers.get_mut(&link).expect("a frame for no peer");
                    let plain = transport.open(&bytes).expect("the engine's frame opens");
                    let seen = match frame::decode(&plain).expect("the engine's frame parses") {
                        Frame::Hello(value) => Seen::Hello(value),
                        Frame::Have(entries) => Seen::Have(entries.iter().collect()),
                        Frame::Want(ids) => Seen::Want(ids.iter().collect()),
                        Frame::Pkt { index, chunk } => Seen::Pkt(index, chunk.to_vec()),
                        Frame::Bye => Seen::Bye,
                    };
                    self.seen.push((link, seen));
                    self.air.push(bytes);
                }
                Output::Close { link } => {
                    self.peers.remove(&link);
                    self.closed.push(link);
                }
                Output::Connect { peer } => self.connects.push(peer),
            }
            true
        }

        fn pump(&mut self) {
            while self.step() {}
        }

        fn run(&mut self, ms: u64) {
            let until = self.now + ms;
            while let Some(wake) = self.engine.next_wake_ms().filter(|&wake| wake <= until) {
                self.now = self.now.max(wake);
                self.engine.advance(self.now);
                self.pump();
            }
            self.now = until;
            self.engine.advance(until);
            self.pump();
        }

        /// What the engine sent on `link` since the last call.
        fn take(&mut self, link: LinkId) -> Vec<Seen> {
            let (mine, rest) = std::mem::take(&mut self.seen)
                .into_iter()
                .partition(|(on, _)| *on == link);
            self.seen = rest;
            mine.into_iter().map(|(_, seen)| seen).collect()
        }

        fn wants(&mut self, link: LinkId) -> Vec<PacketId> {
            let mut ids = Vec::new();
            for seen in self.take(link) {
                if let Seen::Want(wanted) = seen {
                    ids.extend(wanted);
                }
            }
            ids
        }

        fn haves(&mut self, link: LinkId) -> Vec<(PacketId, u8)> {
            let mut entries = Vec::new();
            for seen in self.take(link) {
                if let Seen::Have(had) = seen {
                    entries.extend(had);
                }
            }
            entries
        }

        fn store(&self) -> &Store {
            self.engine.store()
        }
    }

    /// Several engines wired to each other: the test only carries bytes.
    struct Mesh {
        nodes: Vec<Engine>,
        wires: BTreeMap<(usize, LinkId), (usize, LinkId)>,
        now: u64,
        next_link: u64,
        air: Vec<Vec<u8>>,
        closes: Vec<(usize, LinkId)>,
        connects: Vec<(usize, PeerRef)>,
    }

    impl Mesh {
        fn new(configs: Vec<Config>) -> Self {
            Self {
                nodes: (1000..)
                    .zip(configs)
                    .map(|(seed, c)| engine(c, seed))
                    .collect(),
                wires: BTreeMap::new(),
                now: 0,
                next_link: 1,
                air: Vec::new(),
                closes: Vec::new(),
                connects: Vec::new(),
            }
        }

        /// `central` connects to `peripheral`.
        fn link(&mut self, central: usize, peripheral: usize) -> (LinkId, LinkId) {
            let (near, far) = (LinkId(self.next_link), LinkId(self.next_link + 1));
            self.next_link += 2;
            self.wires.insert((central, near), (peripheral, far));
            self.wires.insert((peripheral, far), (central, near));
            let peer = Some(PeerRef(peripheral as u64));
            self.nodes[central].link_up(near, Role::Central, FRAME, peer, self.now);
            self.nodes[peripheral].link_up(far, Role::Peripheral, FRAME, None, self.now);
            self.carry();
            (near, far)
        }

        /// Carries outputs between the engines until all are quiet.
        fn carry(&mut self) {
            let mut moved = true;
            while std::mem::take(&mut moved) {
                for node in 0..self.nodes.len() {
                    while let Some(output) = self.nodes[node].poll_output() {
                        moved = true;
                        match output {
                            Output::Frame { link, bytes } => {
                                if let Some(&(to, far)) = self.wires.get(&(node, link)) {
                                    self.nodes[to].receive(far, &bytes, self.now);
                                    self.air.push(bytes);
                                }
                            }
                            Output::Close { link } => {
                                self.closes.push((node, link));
                                if let Some((to, far)) = self.wires.remove(&(node, link)) {
                                    self.wires.remove(&(to, far));
                                    self.nodes[to].link_down(far, self.now);
                                }
                            }
                            Output::Connect { peer } => self.connects.push((node, peer)),
                        }
                    }
                }
            }
        }

        /// Runs every timer due up to `until`, in time order.
        fn run_to(&mut self, until: u64) {
            loop {
                let next = self.nodes.iter().filter_map(Engine::next_wake_ms).min();
                let Some(at) = next.filter(|&at| at <= until) else {
                    break;
                };
                self.now = self.now.max(at);
                for node in &mut self.nodes {
                    node.advance(self.now);
                }
                self.carry();
            }
            self.now = until;
            for node in &mut self.nodes {
                node.advance(until);
            }
            self.carry();
        }
    }

    /// The outputs an engine with no scripted peers has queued.
    fn drain(engine: &mut Engine) -> Vec<Output> {
        std::iter::from_fn(|| engine.poll_output()).collect()
    }

    fn connects(outputs: &[Output]) -> Vec<PeerRef> {
        outputs
            .iter()
            .filter_map(|output| match output {
                Output::Connect { peer } => Some(*peer),
                _ => None,
            })
            .collect()
    }

    fn closes(outputs: &[Output]) -> Vec<LinkId> {
        outputs
            .iter()
            .filter_map(|output| match output {
                Output::Close { link } => Some(*link),
                _ => None,
            })
            .collect()
    }

    // ---- handshake and greeting -------------------------------------------

    #[test]
    fn two_engines_shake_hands_greet_and_seal_every_frame_to_the_link_size() {
        let mut mesh = Mesh::new(vec![quiet(), quiet()]);
        mesh.link(0, 1);
        assert_eq!(mesh.nodes[0].stats().links, 1);
        assert_eq!(mesh.nodes[1].stats().links, 1);
        let lengths: Vec<usize> = mesh.air.iter().map(Vec::len).collect();
        assert_eq!(lengths, [noise::HELLO_LEN, noise::REPLY_LEN, FRAME, FRAME]);
        assert!(mesh.closes.is_empty());
    }

    #[test]
    fn the_engine_greets_first_with_its_value_whichever_side_it_is() {
        let mut rig = Rig::new(quiet());
        let incoming = rig.dial(1);
        let outgoing = rig.answer(2, PeerRef(7));
        let value = rig.engine.hello;
        assert!(rig.take(incoming) == vec![Seen::Hello(value)]);
        assert!(rig.take(outgoing) == vec![Seen::Hello(value)]);
        // Not past its greeting until the peer's arrives.
        assert_eq!(rig.engine.stats().links, 0);
        rig.greet(incoming, [1; 8]);
        assert_eq!(rig.engine.stats().links, 1);
    }

    #[test]
    fn the_hello_value_is_drawn_afresh_every_fifteen_minutes_and_sent_again() {
        let mut rig = Rig::new(quiet());
        let link = rig.peer(1);
        let first = rig.engine.hello;
        rig.take(link);
        rig.run(15 * MINUTE_MS - TICK);
        assert!(rig.take(link).is_empty());
        rig.run(TICK);
        let second = rig.engine.hello;
        assert_ne!(first, second);
        assert!(rig.take(link) == vec![Seen::Hello(second)]);
    }

    // ---- inventory flood --------------------------------------------------

    #[test]
    fn a_packet_emitted_by_one_phone_reaches_the_next_and_the_one_after() {
        let mut mesh = Mesh::new(vec![emitting(), quiet(), quiet()]);
        mesh.link(0, 1);
        mesh.link(1, 2);
        mesh.nodes[0].offer(CircleSlot(1), packet(1), u64::MAX, 0);
        mesh.run_to(9999);
        assert_eq!(mesh.nodes[0].stats().held, 0);
        mesh.run_to(19_999);

        for node in &mesh.nodes {
            assert!(node.store().holds(&id(1)));
        }
        assert!(mesh.nodes[0].store().is_local(&id(1)));
        assert!(mesh.nodes[0].take_unread(9).is_empty());
        assert!(mesh.nodes[1].take_unread(9) == vec![packet(1)]);
        assert!(mesh.nodes[2].take_unread(9) == vec![packet(1)]);

        // One hop each way and nothing back: every transfer was a first.
        let stats: Vec<Stats> = mesh.nodes.iter().map(Engine::stats).collect();
        assert_eq!(
            (stats[0].accepted, stats[1].accepted, stats[2].accepted),
            (0, 1, 1)
        );
        assert_eq!(stats.iter().map(|s| s.duplicates).sum::<u64>(), 0);
        mesh.run_to(60_000);
        let sent: u64 = mesh.nodes.iter().map(|node| node.stats().sent).sum();
        let accepted: u64 = mesh.nodes.iter().map(|node| node.stats().accepted).sum();
        assert_eq!(sent, accepted);
    }

    #[test]
    fn a_new_link_is_told_the_whole_store_in_id_order() {
        let mut rig = Rig::new(trusting());
        let source = rig.peer(1);
        let ns: Vec<u64> = (1..=70).collect();
        assert_eq!(rig.feed(source, &ns, 200).len(), 70);

        let late = rig.dial(2);
        assert!(rig.haves(late).is_empty());
        rig.greet(late, [2; 8]);
        let told = rig.haves(late);
        let mut expected: Vec<_> = ns.iter().map(|&n| (id(n), 200)).collect();
        expected.sort();
        assert!(told == expected);
        // Batched: as many per frame as fit.
        assert!(rig.air.len() < 400);
    }

    #[test]
    fn a_new_packet_is_announced_on_the_tick_and_not_before() {
        let mut rig = Rig::new(trusting());
        let source = rig.peer(1);
        let other = rig.peer(2);
        rig.run(1000);
        rig.feed(source, &[1], 200);
        rig.run(TICK - 1001);
        assert!(rig.haves(other).is_empty());
        rig.run(1);
        assert!(rig.haves(other) == vec![(id(1), 199)]);
        rig.run(10 * TICK);
        assert!(rig.haves(other).is_empty());
    }

    /// T-LIFE-2.
    #[test]
    fn a_packet_never_goes_back_and_crosses_a_link_once() {
        let mut rig = Rig::new(trusting());
        let source = rig.peer(1);
        let other = rig.peer(2);
        assert!(rig.feed(source, &[1], 200) == vec![id(1)]);
        rig.run(TICK);

        // Told to the other link, never to the one it came from.
        assert!(rig.haves(other) == vec![(id(1), 198)]);
        assert!(rig.take(source).is_empty());

        // Sent where it was asked for, once.
        rig.ask(other, &[id(1)]);
        let chunks = rig.take(other);
        assert_eq!(chunks.len(), 3);
        let bytes: Vec<u8> = chunks
            .iter()
            .flat_map(|seen| match seen {
                Seen::Pkt(_, chunk) => chunk.clone(),
                _ => panic!("something other than the packet was sent"),
            })
            .collect();
        assert_eq!(bytes[..], packet(1).as_bytes()[..]);
        rig.ask(other, &[id(1)]);
        assert!(rig.take(other).is_empty());

        // Never toward its source, and never to a link it was not told to.
        rig.ask(source, &[id(1)]);
        assert!(rig.take(source).is_empty());

        // Announced back, it is not asked for: the engine has its record.
        rig.announce(other, &[(id(1), 255)]);
        rig.announce(source, &[(id(1), 255)]);
        rig.run(10 * TICK);
        assert!(rig.take(other).is_empty() && rig.take(source).is_empty());
        assert_eq!(rig.engine.stats().sent, 1);
        assert!(rig.closed.is_empty());
    }

    #[test]
    fn a_want_for_a_packet_not_announced_to_that_link_tells_nothing() {
        let mut rig = Rig::new(trusting());
        let source = rig.peer(1);
        let prober = rig.peer(2);
        rig.feed(source, &[1], 200);
        rig.take(prober);
        // Held, but the prober has not been told: asking finds out nothing.
        rig.ask(prober, &[id(1), id(2)]);
        assert!(rig.take(prober).is_empty() && rig.closed.is_empty());
        rig.run(TICK);
        assert_eq!(rig.haves(prober).len(), 1);
        rig.ask(prober, &[id(2), id(1)]);
        assert_eq!(rig.take(prober).len(), 3);
    }

    /// T-LIFE-1 at one phone.
    #[test]
    fn a_packet_whose_lifetime_ended_is_neither_announced_nor_sent() {
        let mut rig = Rig::new(trusting());
        let source = rig.peer(1);
        let other = rig.peer(2);
        // Two units are gone by the first tick; three leave one unit then,
        // and none by the tick after.
        rig.feed(source, &[1], 2);
        rig.feed(source, &[2], 200);
        rig.feed(source, &[3], 3);
        rig.run(TICK);
        let mut told = vec![(id(2), 198), (id(3), 1)];
        told.sort();
        assert!(rig.haves(other) == told);
        rig.run(TICK);
        rig.ask(other, &[id(1), id(2), id(3)]);
        let sent = rig.take(other);
        assert_eq!(sent.len(), 3, "only the live packet is sent");
        assert!(sent.iter().all(|seen| matches!(seen, Seen::Pkt(..))));
        assert_eq!(rig.engine.stats().sent, 1);
        assert!(rig.store().holds(&id(1)), "kept, silent, until first + L");
        assert_eq!(rig.store().remaining(&id(1)), 0);

        let late = rig.peer(3);
        assert!(rig.haves(late).iter().all(|(told, _)| *told == id(2)));
    }
    // ---- lying about lifetimes --------------------------------------------

    /// T-LIFE-3.
    #[test]
    fn an_understated_lifetime_does_not_kill_a_packet_once_an_honest_one_is_heard() {
        let mut rig = Rig::new(trusting());
        let liar = rig.peer(1);
        let honest = rig.peer(2);
        let downstream = rig.peer(3);
        // Three units: one is left at the first tick, none by the second.
        rig.feed(liar, &[1], 3);
        rig.run(TICK);
        assert!(rig.haves(downstream) == vec![(id(1), 1)]);
        rig.run(TICK);
        assert_eq!(rig.store().remaining(&id(1)), 0);
        rig.take(honest);

        rig.announce(honest, &[(id(1), 180)]);
        assert!(rig.wants(honest).is_empty(), "never asked for twice");
        rig.run(TICK - 1);
        assert!(rig.haves(downstream).is_empty(), "not before the tick");
        rig.run(1);
        // Told a second time, with the honest lifetime less the wait.
        assert!(rig.haves(downstream) == vec![(id(1), 178)]);
        assert!(rig.haves(honest).is_empty() && rig.haves(liar).is_empty());
        rig.ask(downstream, &[id(1)]);
        assert_eq!(rig.take(downstream).len(), 3);
    }

    #[test]
    fn the_longest_lifetime_announced_before_a_packet_arrives_is_the_one_kept() {
        let mut rig = Rig::new(trusting());
        let liar = rig.peer(1);
        let honest = rig.peer(2);
        rig.announce(liar, &[(id(1), 1)]);
        assert!(rig.wants(liar) == vec![id(1)]);
        rig.announce(honest, &[(id(1), 180)]);
        assert!(rig.wants(honest).is_empty(), "asked of one link at a time");
        rig.deliver(liar, &packet(1));
        assert_eq!(rig.store().remaining(&id(1)), 180);
        // Both hold it: neither is told.
        rig.run(TICK);
        assert!(rig.take(liar).is_empty() && rig.take(honest).is_empty());
    }

    /// T-LIFE-3, the other lie.
    #[test]
    fn an_overstated_lifetime_holds_a_packet_no_longer_and_gets_it_taken_no_sooner() {
        let mut rig = Rig::new(trusting());
        let liar = rig.peer(1);
        rig.run(1000);
        let first = rig.now;
        rig.feed(liar, &[1], 255);
        rig.run(10 * MINUTE_MS);
        rig.announce(liar, &[(id(1), 255)]);
        assert_eq!(rig.store().expires_ms(&id(1)), Some(first + LIFE));

        rig.run(first + LIFE - 1 - rig.now);
        assert!(rig.store().holds(&id(1)));
        rig.run(1);
        assert!(!rig.store().holds(&id(1)));

        rig.run(first + 2 * LIFE - 1 - rig.now);
        rig.announce(liar, &[(id(1), 255)]);
        assert!(
            rig.wants(liar).is_empty(),
            "refused just before the record ends"
        );
        rig.run(1);
        rig.announce(liar, &[(id(1), 255)]);
        assert!(rig.wants(liar) == vec![id(1)], "taken as new at its end");
    }

    // ---- violations -------------------------------------------------------

    fn assert_dropped(rig: &Rig, link: LinkId) {
        assert!(rig.closed == vec![link]);
        assert_eq!(rig.engine.stats().links, 0);
        assert_eq!(rig.engine.stats().records, 0);
        assert_eq!(rig.engine.stats().unread, 0);
    }

    /// T-SEC-3.
    #[test]
    fn a_packet_nobody_asked_for_closes_the_link_at_its_first_chunk() {
        let mut rig = Rig::new(trusting());
        let link = rig.peer(1);
        rig.send(link, frame::pkt(&packet(1), 0, size()));
        assert_dropped(&rig, link);
    }

    #[test]
    fn a_packet_other_than_the_one_asked_for_closes_the_link_and_is_not_kept() {
        let mut rig = Rig::new(trusting());
        let link = rig.peer(1);
        rig.announce(link, &[(id(1), 200)]);
        assert!(rig.wants(link) == vec![id(1)]);
        rig.deliver(link, &packet(2));
        assert_dropped(&rig, link);

        // One it was told of but chose not to ask for is no better.
        let mut rig = Rig::new(Config {
            want_window: 1,
            ..trusting()
        });
        let link = rig.peer(1);
        rig.announce(link, &[(id(1), 200), (id(2), 200)]);
        let asked = rig.wants(link);
        assert_eq!(asked.len(), 1);
        let unasked = if asked[0] == id(1) { 2 } else { 1 };
        rig.deliver(link, &packet(unasked));
        assert_dropped(&rig, link);
    }

    #[test]
    fn a_chunk_out_of_order_closes_the_link() {
        let mut rig = Rig::new(trusting());
        let link = rig.peer(1);
        rig.announce(link, &[(id(1), 200)]);
        rig.send(link, frame::pkt(&packet(1), 1, size()));
        assert_dropped(&rig, link);

        let mut rig = Rig::new(trusting());
        let link = rig.peer(1);
        rig.announce(link, &[(id(1), 200)]);
        rig.send(link, frame::pkt(&packet(1), 0, size()));
        rig.send(link, frame::pkt(&packet(1), 0, size()));
        assert_dropped(&rig, link);
    }

    #[test]
    fn a_malformed_frame_closes_the_link() {
        let spoil: [fn(&mut Vec<u8>); 4] = [
            |plain| plain[0] = 9,
            |plain| plain[400] = 1,
            |plain| plain[1] = 0xff,
            |plain| plain[2] = 1,
        ];
        for spoil in spoil {
            let mut rig = Rig::new(trusting());
            let link = rig.peer(1);
            let mut plain = frame::bye(size()).expect("encodes");
            spoil(&mut plain);
            rig.send(link, Some(plain));
            assert_dropped(&rig, link);
        }
        // A lifetime of zero is announced by no honest phone.
        let mut rig = Rig::new(trusting());
        let link = rig.peer(1);
        let mut plain = frame::have(&[(id(1), 1)], size()).expect("encodes");
        plain[3 + 16] = 0;
        rig.send(link, Some(plain));
        assert_dropped(&rig, link);
    }

    #[test]
    fn a_frame_of_the_wrong_length_closes_the_link() {
        for cut in [1, FRAME - 1] {
            let mut rig = Rig::new(trusting());
            let link = rig.peer(1);
            let sealed = rig.seal(link, frame::bye(size()));
            rig.engine.receive(link, &sealed[..cut], 0);
            rig.pump();
            assert_dropped(&rig, link);
        }
        // Validly sealed, but not of this link's size.
        let mut rig = Rig::new(trusting());
        let link = rig.peer(1);
        let other = FrameSize::of_link(FRAME - 1).expect("within bounds");
        // The peer's own greeting again: harmless, had it the right length.
        let sealed = rig.seal(link, frame::hello(&1u64.to_le_bytes(), other));
        rig.engine.receive(link, &sealed, 0);
        rig.pump();
        assert_dropped(&rig, link);
    }

    /// T-PRIV-8: a frame that does not open, a replayed one included.
    #[test]
    fn a_frame_that_does_not_open_closes_the_link() {
        let mut rig = Rig::new(trusting());
        let link = rig.peer(1);
        let mut sealed = rig.seal(link, frame::have(&[(id(1), 9)], size()));
        sealed[100] ^= 1;
        rig.engine.receive(link, &sealed, 0);
        rig.pump();
        assert_dropped(&rig, link);

        let mut rig = Rig::new(trusting());
        let link = rig.peer(1);
        let sealed = rig.seal(link, frame::have(&[(id(1), 9)], size()));
        rig.engine.receive(link, &sealed, 0);
        rig.pump();
        assert!(rig.closed.is_empty());
        rig.engine.receive(link, &sealed, 0);
        rig.pump();
        assert!(rig.closed == vec![link]);
    }

    #[test]
    fn a_first_frame_that_is_not_hello_closes_the_link() {
        let frames = [
            frame::have(&[(id(1), 9)], size()),
            frame::want(&[id(1)], size()),
            frame::pkt(&packet(1), 0, size()),
            frame::bye(size()),
        ];
        for plain in frames {
            let mut rig = Rig::new(trusting());
            let link = rig.dial(1);
            rig.send(link, plain);
            assert_dropped(&rig, link);
        }
    }

    #[test]
    fn a_handshake_message_that_is_not_one_closes_the_link() {
        let mut engine = engine(quiet(), 1);
        engine.link_up(LinkId(1), Role::Peripheral, FRAME, None, 0);
        engine.receive(LinkId(1), &[7; 31], 0);
        assert!(drain(&mut engine) == vec![Output::Close { link: LinkId(1) }]);

        engine.link_up(LinkId(2), Role::Central, FRAME, None, 0);
        engine.receive(LinkId(2), &[7; 48], 0);
        let outputs = drain(&mut engine);
        assert!(closes(&outputs) == vec![LinkId(2)]);
        assert_eq!(outputs.len(), 1, "the hello it had queued is withdrawn");
        assert_eq!(engine.stats().links, 0);
    }

    #[test]
    fn a_bye_closes_the_link() {
        let mut rig = Rig::new(trusting());
        let link = rig.peer(1);
        rig.take(link);
        rig.send(link, frame::bye(size()));
        assert!(rig.closed == vec![link] && rig.take(link).is_empty());
    }

    #[test]
    fn a_link_with_an_impossible_frame_size_is_refused() {
        let mut engine = engine(quiet(), 1);
        engine.link_up(
            LinkId(1),
            Role::Peripheral,
            frame::MIN_FRAME_LEN - 1,
            None,
            0,
        );
        engine.link_up(LinkId(2), Role::Central, frame::MAX_FRAME_LEN + 1, None, 0);
        let outputs = drain(&mut engine);
        assert!(closes(&outputs) == vec![LinkId(1), LinkId(2)] && outputs.len() == 2);

        engine.link_up(LinkId(3), Role::Peripheral, frame::MIN_FRAME_LEN, None, 0);
        engine.link_up(LinkId(4), Role::Peripheral, frame::MAX_FRAME_LEN, None, 0);
        assert!(drain(&mut engine).is_empty());
    }

    #[test]
    fn a_link_id_used_again_starts_clean() {
        let mut engine = engine(quiet(), 1);
        engine.link_up(LinkId(1), Role::Peripheral, 10, None, 0);
        engine.link_up(LinkId(1), Role::Central, FRAME, None, 0);
        // Neither the refusal of the first nor the hello of the second
        // outlives the id's next use.
        engine.link_up(LinkId(1), Role::Peripheral, FRAME, None, 0);
        assert!(drain(&mut engine).is_empty());
        assert_eq!((engine.count(true), engine.count(false)), (1, 0));
    }

    #[test]
    fn frames_for_a_link_the_engine_does_not_know_are_ignored() {
        let mut engine = engine(quiet(), 1);
        engine.receive(LinkId(5), &[1; FRAME], 0);
        engine.link_down(LinkId(5), 0);
        assert!(drain(&mut engine).is_empty());
    }

    // ---- duplicate links --------------------------------------------------

    #[test]
    fn of_two_links_between_two_phones_both_close_the_second() {
        let mut mesh = Mesh::new(vec![quiet(), quiet()]);
        let (near, far) = mesh.link(0, 1);
        let (second_near, second_far) = mesh.link(1, 0);

        let mut closed = mesh.closes.clone();
        closed.sort();
        assert!(closed == vec![(0, second_far), (1, second_near)]);
        let left: Vec<_> = mesh.wires.keys().copied().collect();
        assert!(left == vec![(0, near), (1, far)]);
        assert_eq!(mesh.nodes[0].stats().links, 1);
        assert_eq!(mesh.nodes[1].stats().links, 1);

        // The peer it dialled is reached through the link that stayed: it is
        // not dialled again while that lasts.
        for at in (0..120_000).step_by(1000) {
            mesh.nodes[1].sighting(PeerRef(0), -40, at);
            mesh.run_to(at);
        }
        assert!(mesh.connects.is_empty());
        mesh.nodes[1].link_down(far, mesh.now);
        for at in (120_000..180_000).step_by(1000) {
            mesh.nodes[1].sighting(PeerRef(0), -40, at);
            mesh.run_to(at);
        }
        assert!(mesh.connects == vec![(1, PeerRef(0))]);
    }

    #[test]
    fn the_surviving_link_still_carries_packets() {
        let mut mesh = Mesh::new(vec![emitting(), quiet()]);
        mesh.link(0, 1);
        mesh.link(1, 0);
        mesh.nodes[0].offer(CircleSlot(1), packet(1), u64::MAX, 0);
        mesh.run_to(15_000);
        assert!(mesh.nodes[1].store().holds(&id(1)));
    }

    /// The older link wins whatever the newer one does, so a neighbour that
    /// replays a peer's value closes only its own link.
    #[test]
    fn a_link_showing_a_value_already_seen_is_the_one_closed() {
        let mut rig = Rig::new(trusting());
        let first = rig.dial(1);
        rig.greet(first, [5; 8]);
        let second = rig.dial(2);
        rig.take(second);
        rig.greet(second, [5; 8]);
        assert!(rig.closed == vec![second]);
        assert!(rig.take(second) == vec![Seen::Bye]);
        assert_eq!(rig.engine.stats().links, 1);

        // A link that later changes its value to one already seen loses too.
        let third = rig.dial(3);
        rig.greet(third, [6; 8]);
        rig.greet(third, [6; 8]);
        assert!(rig.closed == vec![second]);
        rig.greet(third, [5; 8]);
        assert!(rig.closed == vec![second, third]);
        assert_eq!(rig.engine.stats().links, 1);
    }

    #[test]
    fn a_link_that_mirrors_the_engines_own_value_is_closed() {
        let mut rig = Rig::new(trusting());
        let link = rig.dial(1);
        let own = rig.engine.hello;
        rig.greet(link, own);
        assert!(rig.closed == vec![link]);
    }

    // ---- credit and limits ------------------------------------------------

    /// T-SEC-4.
    #[test]
    fn a_new_link_is_asked_for_no_more_than_its_allowance() {
        let mut rig = Rig::new(quiet());
        let link = rig.peer(1);
        let ns: Vec<u64> = (1..=100).collect();
        assert_eq!(rig.feed(link, &ns, 250).len(), 16);
        assert_eq!(rig.engine.stats().accepted, 16);

        // Two packets a second from then on.
        rig.run(TICK);
        let more = rig.wants(link);
        assert_eq!(more.len(), 10);
        for &n in &ns {
            if more.contains(&id(n)) {
                rig.deliver(link, &packet(n));
            }
        }
        assert_eq!(rig.engine.stats().accepted, 26);

        // Anything pushed beyond it was not asked for.
        let unasked = ns.iter().find(|&&n| !rig.store().has_record(&id(n)));
        rig.send(
            link,
            frame::pkt(&packet(*unasked.expect("most")), 0, size()),
        );
        assert!(rig.closed == vec![link]);
        assert_eq!(rig.engine.stats().records, 26);
    }

    #[test]
    fn a_link_is_asked_for_no_more_than_its_window_at_once() {
        let mut rig = Rig::new(Config {
            want_window: 5,
            ..trusting()
        });
        let link = rig.peer(1);
        let entries: Vec<_> = (1..=20).map(|n| (id(n), 250)).collect();
        rig.announce(link, &entries);
        let first = rig.wants(link);
        assert_eq!(first.len(), 5);
        let arrived: Vec<u64> = (1..=20).filter(|&n| first[..2].contains(&id(n))).collect();
        for n in arrived {
            rig.deliver(link, &packet(n));
        }
        rig.run(TICK);
        assert_eq!(rig.wants(link).len(), 2);
    }

    #[test]
    fn requests_over_all_links_stay_within_the_rate_limit() {
        let mut rig = Rig::new(Config {
            accept_burst: 10,
            accept_per_min: 60,
            ..trusting()
        });
        let one = rig.peer(1);
        let two = rig.peer(2);
        let first: Vec<_> = (1..=20).map(|n| (id(n), 250)).collect();
        let second: Vec<_> = (21..=40).map(|n| (id(n), 250)).collect();
        rig.announce(one, &first);
        rig.announce(two, &second);
        assert_eq!(rig.wants(one).len() + rig.wants(two).len(), 10);
        rig.run(TICK);
        assert_eq!(rig.wants(one).len() + rig.wants(two).len(), 5);
    }

    /// §6.4: traffic inside the rate limit cannot fill the record table.
    #[test]
    fn the_record_table_holds_everything_the_rate_limit_lets_in_for_two_lifetimes() {
        let config = Config::default();
        assert_eq!(config.record_capacity(), 2048 + 240 * 40 + 41);
        let engine = engine(config, 1);
        assert_eq!(engine.store().records(), 0);
    }

    /// T-SEC-4: a flood costs the flooder's rows, not a smaller link's.
    #[test]
    fn a_flooding_link_cannot_evict_another_links_packets() {
        let mut rig = Rig::new(Config {
            store_packets: 8,
            ..trusting()
        });
        let honest = rig.peer(1);
        let flooder = rig.peer(2);
        rig.feed(honest, &[1, 2, 3], 250);
        let flood: Vec<u64> = (100..160).collect();
        assert_eq!(rig.feed(flooder, &flood, 250).len(), 60);
        assert_eq!(rig.engine.stats().held, 8);
        assert!((1..=3).all(|n| rig.store().holds(&id(n))));

        // The flooder gone, its rows go first.
        rig.engine.link_down(flooder, rig.now);
        rig.feed(honest, &[4, 5, 6, 7, 8], 250);
        assert!((1..=8).all(|n| rig.store().holds(&id(n))));
    }

    /// T-SEC-4: cycling addresses buys nothing: each new link starts with
    /// almost no credit and leaves its rows first in line for eviction.
    #[test]
    fn an_address_cycling_attacker_cannot_evict_a_long_lived_links_packets() {
        let mut rig = Rig::new(Config {
            store_packets: 8,
            credit_initial: 5,
            credit_per_min: 0,
            ..quiet()
        });
        let honest = rig.peer(1);
        assert_eq!(rig.feed(honest, &[1, 2, 3], 250).len(), 3);
        for cycle in 0..12u64 {
            rig.run(TICK);
            let attacker = rig.peer(10 + cycle);
            let ns: Vec<u64> = (0..9).map(|n| 1000 + cycle * 10 + n).collect();
            assert_eq!(rig.feed(attacker, &ns, 250).len(), 5);
            assert!((1..=3).all(|n| rig.store().holds(&id(n))));
            rig.engine.link_down(attacker, rig.now);
        }
        assert_eq!(rig.engine.stats().held, 8);
    }

    #[test]
    fn a_request_not_answered_is_made_again_then_made_of_another_link() {
        let mut rig = Rig::new(trusting());
        let slow = rig.peer(1);
        let other = rig.peer(2);
        rig.announce(slow, &[(id(1), 250)]);
        rig.announce(other, &[(id(1), 250)]);
        assert!(rig.wants(slow) == vec![id(1)] && rig.wants(other).is_empty());

        rig.run(30_000 - TICK);
        assert!(rig.wants(slow).is_empty() && rig.wants(other).is_empty());
        rig.run(TICK);
        assert!(rig.wants(slow) == vec![id(1)] && rig.wants(other).is_empty());
        rig.run(30_000);
        assert!(rig.wants(slow).is_empty() && rig.wants(other) == vec![id(1)]);

        rig.deliver(other, &packet(1));
        assert_eq!(rig.engine.stats().accepted, 1);
        // The slow link's answer, late, is no violation: it was asked.
        rig.deliver(slow, &packet(1));
        let stats = rig.engine.stats();
        assert_eq!((stats.accepted, stats.duplicates, stats.links), (1, 1, 2));
        assert!(rig.closed.is_empty());
        // A third copy was asked for by nobody.
        rig.send(slow, frame::pkt(&packet(1), 0, size()));
        assert!(rig.closed == vec![slow]);
    }

    #[test]
    fn an_offer_is_forgotten_once_its_packet_arrives_by_another_link() {
        let mut rig = Rig::new(Config {
            offers_per_link: 2,
            ..trusting()
        });
        let first = rig.peer(1);
        let second = rig.peer(2);
        rig.announce(first, &[(id(1), 250)]);
        rig.announce(second, &[(id(1), 250)]);
        rig.deliver(first, &packet(1));
        // Room again for two announcements the engine has not heard.
        rig.announce(second, &[(id(2), 250), (id(3), 250), (id(4), 250)]);
        assert_eq!(rig.wants(second).len(), 2);
    }

    /// A link whose frames the radio layer does not take: its requests wait,
    /// and one whose offer expired while waiting is never sent — the packet
    /// would arrive unasked — nor do such requests pile up.
    #[test]
    fn requests_that_outlive_their_offer_are_never_sent_and_do_not_pile_up() {
        let mut rig = Rig::new(Config {
            link_queue_frames: 1,
            want_window: 2,
            ..trusting()
        });
        let source = rig.peer(1);
        rig.feed(source, &[100], 250);
        let link = rig.dial(2);
        // The greeting brings one inventory frame, which fills the queue.
        let sealed = rig.seal(link, frame::hello(&[2; 8], size()));
        rig.engine.receive(link, &sealed, 0);
        for round in 0..10u64 {
            let short_lived = [(id(2 * round), 1), (id(2 * round + 1), 1)];
            let sealed = rig.seal(link, frame::have(&short_lived, size()));
            rig.engine.receive(link, &sealed, rig.now);
            rig.now += 40_000;
            rig.engine.advance(rig.now);
            assert_eq!(rig.engine.output.len(), 1);
            assert_consistent(&rig.engine);
        }
        rig.pump();
        assert!(rig.wants(link).is_empty());
        assert!(rig.closed.is_empty());
    }

    /// T-LIFE-1: asked for in time, but expired by its turn in the queue.
    #[test]
    fn a_packet_that_expires_while_it_waits_to_be_sent_is_not_sent() {
        let mut rig = Rig::new(Config {
            link_queue_frames: 1,
            ..trusting()
        });
        let source = rig.peer(1);
        rig.feed(source, &[1], 250);
        rig.feed(source, &[2], 3);
        let reader = rig.peer(2);
        assert_eq!(rig.haves(reader).len(), 2);
        // Both are claimed now; the second waits behind the first's chunks.
        let sealed = rig.seal(reader, frame::want(&[id(1), id(2)], size()));
        rig.engine.receive(reader, &sealed, 0);
        rig.now = 3 * UNIT;
        rig.engine.advance(rig.now);
        rig.pump();
        assert_eq!(rig.take(reader).len(), 3);
        assert_eq!(rig.engine.stats().sent, 1);
    }

    /// Requests a link makes faster than its packets go out are not queued
    /// without bound: past the store's size they are dropped, to be made
    /// again.
    #[test]
    fn a_links_send_queue_is_bounded_by_the_store() {
        let mut rig = Rig::new(Config {
            store_packets: 2,
            link_queue_frames: 1,
            ..trusting()
        });
        let source = rig.peer(1);
        let reader = rig.peer(2);
        let (a, b, c, d) = (100, 101, 102, 103);
        // Frames go in without anything being taken out, so the reader's
        // queue stays as full as the test leaves it.
        let inject = |rig: &mut Rig, link: LinkId, plain: Option<Vec<u8>>| {
            let sealed = rig.seal(link, plain);
            rig.engine.receive(link, &sealed, rig.now);
        };
        let ids = |ns: &[u64]| ns.iter().map(|&n| id(n)).collect::<Vec<PacketId>>();

        // Two short-lived packets, asked for while they have a unit left: the
        // first chunk of the first fills the reader's queue.
        rig.feed(source, &[a, b], 3);
        rig.run(TICK);
        assert_eq!(rig.haves(reader).len(), 2);
        inject(&mut rig, reader, frame::want(&ids(&[a, b]), size()));
        // Their lifetime over, two more arrive in their place.
        rig.now = 3 * UNIT;
        rig.engine.advance(rig.now);
        inject(
            &mut rig,
            source,
            frame::have(&[(id(c), 250), (id(d), 250)], size()),
        );
        for n in [c, d] {
            for index in 0..3 {
                inject(&mut rig, source, frame::pkt(&packet(n), index, size()));
            }
        }
        assert!(rig.store().holds(&id(c)) && rig.store().holds(&id(d)));
        // They are announced once the reader's queue has room, and the reader
        // asks for both at once, behind the one still waiting.
        rig.now += TICK;
        rig.engine.advance(rig.now);
        assert!(rig.step() && rig.step() && rig.step());
        assert_eq!(rig.haves(reader).len(), 2);
        inject(&mut rig, reader, frame::want(&ids(&[c, d]), size()));
        rig.pump();
        let chunks = |rig: &mut Rig| {
            let seen = rig.take(reader);
            seen.iter()
                .filter(|seen| matches!(seen, Seen::Pkt(..)))
                .count()
        };
        // The rest of the first, nothing of the second, which expired before
        // its turn, the third in full, and the fourth never queued.
        assert_eq!((chunks(&mut rig), rig.engine.stats().sent), (5, 2));
        inject(&mut rig, reader, frame::want(&ids(&[d]), size()));
        rig.pump();
        assert_eq!((chunks(&mut rig), rig.engine.stats().sent), (3, 3));
    }

    #[test]
    fn no_link_queues_more_frames_than_its_share() {
        let cap = 4;
        let mut rig = Rig::new(Config {
            link_queue_frames: cap,
            ..trusting()
        });
        let source = rig.peer(1);
        let ns: Vec<u64> = (1..=300).collect();
        rig.feed(source, &ns, 250);

        let reader = rig.dial(2);
        let sealed = rig.seal(reader, frame::hello(&[2; 8], size()));
        rig.engine.receive(reader, &sealed, 0);
        assert_eq!(rig.engine.output.len(), cap);
        while rig.step() {
            assert!(rig.engine.output.len() <= cap);
        }
        let told = rig.haves(reader);
        assert_eq!(told.len(), 300);

        let ids: Vec<PacketId> = told.iter().map(|entry| entry.0).collect();
        for batch in ids.chunks(size().want_capacity()) {
            let sealed = rig.seal(reader, frame::want(batch, size()));
            rig.engine.receive(reader, &sealed, 0);
            assert!(rig.engine.output.len() <= cap);
        }
        let mut frames = 0;
        while rig.step() {
            frames += 1;
            assert!(rig.engine.output.len() <= cap);
        }
        assert_eq!(frames, 900);
        assert_eq!(rig.engine.stats().sent, 300);
    }

    // ---- emission ---------------------------------------------------------

    /// The times of an engine's emissions over two hours, with session code
    /// calling `script` every seven seconds in between.
    fn emission_times(script: impl Fn(&mut Engine, u64)) -> (Vec<u64>, Stats) {
        let mut engine = engine(Config::default(), 77);
        let mut times = Vec::new();
        let mut now = 0;
        while now < 2 * 60 * MINUTE_MS {
            let wake = engine.next_wake_ms().expect("running");
            for at in (now + 1..wake).step_by(7000) {
                script(&mut engine, at);
            }
            now = wake;
            let before = engine.stats().emitted;
            engine.advance(now);
            if engine.stats().emitted > before {
                times.push(now);
            }
        }
        (times, engine.stats())
    }

    /// T-PRIV-4.
    #[test]
    fn emissions_are_the_same_in_count_and_time_whatever_the_outbox_holds() {
        let (idle, idle_stats) = emission_times(|_, _| {});
        let (one, one_stats) = emission_times(|engine, at| {
            engine.offer(CircleSlot(1), packet(at), u64::MAX, at);
        });
        let (ten, ten_stats) = emission_times(|engine, at| {
            for slot in 0..10 {
                engine.offer(CircleSlot(slot), packet(at + u64::from(slot)), u64::MAX, at);
            }
        });
        let (held, held_stats) = emission_times(|engine, at| {
            engine.offer(CircleSlot(1), packet(at), u64::MAX, at);
            engine.purge(CircleSlot(1), at);
        });

        assert!(idle.len() > 60 && idle.len() < 120);
        assert!(idle
            .windows(2)
            .all(|pair| (60_000..=120_000).contains(&(pair[1] - pair[0]))));
        assert!(idle == one && idle == ten && idle == held);
        for stats in [one_stats, ten_stats, held_stats] {
            assert_eq!(stats.emitted, idle_stats.emitted);
            assert_eq!(stats.held, idle_stats.held);
            assert_eq!(stats.records, idle_stats.records);
        }
        // The runs differ only in what the slots carried: the last one took
        // the one entry, and one of the ten.
        assert_eq!(
            (idle_stats.outbox, one_stats.outbox, held_stats.outbox),
            (0, 0, 0)
        );
        assert_eq!(ten_stats.outbox, 9);
    }

    #[test]
    fn the_slot_period_is_the_generators_draw_between_one_and_two_minutes() {
        let gaps: BTreeSet<u64> = (0..40)
            .map(|seed| {
                let engine = engine(Config::default(), seed);
                engine.next_wake_ms().expect("running")
            })
            .collect();
        assert!(gaps.len() > 30);
        assert!(gaps.iter().all(|gap| (60_000..=120_000).contains(gap)));
    }

    /// T-PRIV-4: one packet on waking, whatever the outbox holds.
    #[test]
    fn a_clock_jump_over_many_slots_emits_one_packet() {
        let mut engine = engine(Config::default(), 3);
        engine.link_up(LinkId(1), Role::Peripheral, FRAME, None, 0);
        for slot in 0..10 {
            engine.offer(CircleSlot(slot), packet(u64::from(slot)), u64::MAX, 0);
        }
        let hour = 60 * MINUTE_MS;
        engine.advance(hour);
        assert_eq!(engine.stats().emitted, 1);
        assert_eq!((engine.stats().held, engine.stats().outbox), (1, 9));
        // One tick too, and the next a period on: nothing is caught up.
        assert_eq!(engine.next_wake_ms(), Some(hour + TICK));
        engine.link_down(LinkId(1), hour);
        let next = engine.next_wake_ms().expect("running");
        assert!((hour + 60_000..=hour + 120_000).contains(&next));
        // Time never runs backwards: an earlier reading is no time passed.
        engine.advance(5);
        assert_eq!(engine.now_ms, hour);
        assert_eq!(engine.stats().emitted, 1);
    }

    #[test]
    fn an_emitted_packet_is_a_store_row_with_a_drawn_lifetime_and_never_unread() {
        let mut engine = engine(emitting(), 5);
        engine.offer(CircleSlot(1), packet(1), u64::MAX, 0);
        engine.advance(10_000);
        engine.advance(20_000);
        let stats = engine.stats();
        assert_eq!(
            (stats.emitted, stats.held, stats.records, stats.unread),
            (2, 2, 2, 0)
        );
        assert!(engine.store().is_local(&id(1)));
        for held in engine.store().ids() {
            assert!(engine.store().is_local(&held));
            // Drawn from the top quarter, less the time since.
            assert!((189..=255).contains(&engine.store().remaining(&held)));
        }
        assert!(engine.take_unread(9).is_empty());
    }

    #[test]
    fn the_outbox_serves_the_least_recently_served_slot_newest_packet_once() {
        let mut engine = engine(emitting(), 5);
        let own = |engine: &Engine, n: u64| engine.store().is_local(&id(n));
        engine.offer(CircleSlot(1), packet(1), u64::MAX, 0);
        engine.offer(CircleSlot(2), packet(2), u64::MAX, 0);
        engine.offer(CircleSlot(3), packet(3), u64::MAX, 0);
        engine.offer(CircleSlot(1), packet(11), u64::MAX, 0);
        engine.advance(10_000);
        assert!(own(&engine, 11) && !own(&engine, 1) && !own(&engine, 2));
        engine.advance(20_000);
        assert!(own(&engine, 2) && !own(&engine, 3));

        // Slot 3 has never been served: it goes before the two that have.
        engine.offer(CircleSlot(2), packet(22), u64::MAX, 21_000);
        engine.offer(CircleSlot(1), packet(12), u64::MAX, 21_000);
        engine.advance(30_000);
        assert!(own(&engine, 3) && !own(&engine, 12) && !own(&engine, 22));
        engine.advance(40_000);
        assert!(own(&engine, 12) && !own(&engine, 22));
        engine.advance(50_000);
        assert!(own(&engine, 22));

        // Each entry was used once: the next slot carries a cover packet.
        engine.advance(60_000);
        assert_eq!((engine.stats().emitted, engine.stats().held), (6, 6));
        assert!(!own(&engine, 1));
        assert_eq!(engine.stats().outbox, 0);
    }

    /// T-SEC-7.
    #[test]
    fn an_outbox_entry_is_dropped_at_its_expiry_on_purge_and_past_the_slot_cap() {
        let mut engine = engine(
            Config {
                outbox_slots: 2,
                ..emitting()
            },
            5,
        );
        engine.offer(CircleSlot(1), packet(1), 10_000, 0);
        engine.offer(CircleSlot(2), packet(2), 10_001, 0);
        engine.offer(CircleSlot(3), packet(3), u64::MAX, 0);
        assert_eq!(engine.stats().outbox, 2);
        engine.advance(10_000);
        assert!(engine.store().is_local(&id(2)) && !engine.store().has_record(&id(1)));
        assert_eq!(engine.stats().outbox, 0);

        engine.offer(CircleSlot(1), packet(4), u64::MAX, 11_000);
        engine.purge(CircleSlot(1), 12_000);
        assert_eq!(engine.stats().outbox, 0);
        engine.advance(20_000);
        assert!(!engine.store().has_record(&id(4)));
        // The purge freed the slot for another circle.
        engine.offer(CircleSlot(3), packet(3), u64::MAX, 21_000);
        assert_eq!(engine.stats().outbox, 1);
    }

    /// T-PRIV-3: what a neighbour sees of a packet does not depend on whether
    /// the phone emitted it or carried it.
    #[test]
    fn an_own_packet_and_a_carried_one_are_forwarded_alike() {
        let forwarded = |own: bool| {
            let mut rig = Rig::new(Config {
                credit_initial: 100,
                ..emitting()
            });
            let source = rig.peer(1);
            let neighbour = rig.peer(2);
            if own {
                rig.engine.offer(CircleSlot(1), packet(1), u64::MAX, 0);
            } else {
                rig.run(9000);
                rig.feed(source, &[1], 250);
            }
            rig.run(10_000 - rig.now);
            let told = rig.haves(neighbour);
            let about_it: Vec<_> = told.iter().filter(|entry| entry.0 == id(1)).collect();
            assert_eq!(about_it.len(), 1);
            assert!((190..=255).contains(&about_it[0].1));
            rig.ask(neighbour, &[id(1)]);
            let trace = rig.take(neighbour);
            assert_eq!(rig.engine.stats().sent, 1);
            (told.len(), trace)
        };
        let (own_told, own_trace) = forwarded(true);
        let (carried_told, carried_trace) = forwarded(false);
        // The carrying phone also emitted a cover packet in that slot.
        assert_eq!((own_told, carried_told), (1, 2));
        assert!(own_trace == carried_trace && own_trace.len() == 3);
    }

    // ---- link budget ------------------------------------------------------

    /// Ten peers in range, the lower numbers nearer.
    fn sight_ten(engine: &mut Engine, now: u64) {
        for n in 1..=10u8 {
            let rssi = -40 - i8::try_from(n).expect("small");
            engine.sighting(PeerRef(u64::from(n)), rssi, now);
        }
    }

    /// Runs ticks with the ten peers in sight until the engine dials, and
    /// reports the link up. Returns who it dialled.
    fn next_dial(engine: &mut Engine, now: &mut u64) -> Option<PeerRef> {
        for _ in 0..3 {
            sight_ten(engine, *now);
            *now += TICK;
            engine.advance(*now);
            let dialled = connects(&drain(engine));
            assert!(dialled.len() <= 1, "one connect at a time");
            if let Some(&peer) = dialled.first() {
                engine.link_up(LinkId(peer.0), Role::Central, FRAME, Some(peer), *now);
                return Some(peer);
            }
        }
        None
    }

    #[test]
    fn it_dials_the_nearest_three_then_one_at_random_and_no_more() {
        let mut random = BTreeSet::new();
        for seed in 0..24 {
            let mut engine = engine(quiet(), seed);
            let mut now = 0;
            for nearest in 1..=3 {
                assert!(next_dial(&mut engine, &mut now) == Some(PeerRef(nearest)));
            }
            let fourth = next_dial(&mut engine, &mut now).expect("the random slot");
            assert!((4..=10).contains(&fourth.0));
            random.insert(fourth);
            assert!(
                next_dial(&mut engine, &mut now).is_none(),
                "four outgoing at most"
            );

            // An outgoing link it has no slot for is closed.
            engine.link_up(LinkId(99), Role::Central, FRAME, Some(PeerRef(9)), now);
            assert!(closes(&drain(&mut engine)) == vec![LinkId(99)]);
        }
        assert!(
            random.len() > 3,
            "the random slot did not vary with the generator"
        );
    }

    #[test]
    fn it_dials_one_peer_at_a_time() {
        let mut engine = engine(quiet(), 1);
        sight_ten(&mut engine, 0);
        engine.advance(TICK);
        assert!(connects(&drain(&mut engine)) == vec![PeerRef(1)]);
        for at in (2 * TICK..=25_000).step_by(5000) {
            sight_ten(&mut engine, at);
            engine.advance(at);
            assert!(drain(&mut engine).is_empty());
        }
    }

    /// When the engine next dials `peer`, sighted every second.
    fn redial_time(engine: &mut Engine, peer: PeerRef, from: u64) -> u64 {
        for at in (from..from + 300_000).step_by(1000) {
            engine.sighting(peer, -50, at);
            engine.advance(at);
            if connects(&drain(engine)).contains(&peer) {
                return at;
            }
        }
        panic!("the peer was never dialled again");
    }

    #[test]
    fn a_failed_connect_a_timed_out_one_and_a_closed_link_each_get_a_back_off() {
        let peer = PeerRef(1);
        let wait = |after: u64, redial: u64| {
            assert!((60_000..=90_000 + TICK).contains(&(redial - after)));
        };

        let mut failed = engine(quiet(), 1);
        assert_eq!(redial_time(&mut failed, peer, 0), TICK);
        failed.connect_failed(peer, 6000);
        wait(6000, redial_time(&mut failed, peer, 6000));

        // No answer at all: given up after the connect timeout.
        let mut silent = engine(quiet(), 2);
        assert_eq!(redial_time(&mut silent, peer, 0), TICK);
        let redial = redial_time(&mut silent, peer, 6000);
        wait(TICK + 30_000, redial);

        let mut closed = engine(quiet(), 3);
        assert_eq!(redial_time(&mut closed, peer, 0), TICK);
        closed.link_up(LinkId(1), Role::Central, FRAME, Some(peer), 6000);
        closed.link_down(LinkId(1), 7000);
        wait(7000, redial_time(&mut closed, peer, 7000));
    }

    #[test]
    fn a_peer_too_weak_or_no_longer_sighted_is_not_dialled() {
        let mut engine = engine(quiet(), 1);
        engine.sighting(PeerRef(1), -86, 0);
        assert_eq!(engine.next_tick_ms, None, "a weak stranger wakes nobody");
        engine.sighting(PeerRef(2), -85, 0);
        // Sighted once, stale by the time it could be dialled.
        let mut other = self::engine(quiet(), 1);
        other.sighting(PeerRef(3), -50, 0);
        other.advance(30_000 - 1);
        other.connect_failed(PeerRef(3), 30_000 - 1);
        drain(&mut other);
        other.advance(200_000);
        assert!(drain(&mut other).is_empty());

        engine.advance(TICK);
        assert!(connects(&drain(&mut engine)) == vec![PeerRef(2)]);

        // In range once, out of it by the time the engine plans.
        let mut faded = self::engine(quiet(), 1);
        faded.sighting(PeerRef(4), -50, 0);
        faded.sighting(PeerRef(4), -90, 1000);
        faded.advance(TICK);
        assert!(drain(&mut faded).is_empty());
    }

    #[test]
    fn incoming_links_are_capped_and_rate_limited() {
        let mut engine = engine(quiet(), 1);
        for link in 1..=4 {
            engine.link_up(LinkId(link), Role::Peripheral, FRAME, None, 0);
        }
        assert!(drain(&mut engine).is_empty());
        engine.link_up(LinkId(5), Role::Peripheral, FRAME, None, 0);
        assert!(closes(&drain(&mut engine)) == vec![LinkId(5)]);

        // Slots free again, but four links were just taken: one more is let
        // in every five seconds.
        for link in 1..=4 {
            engine.link_down(LinkId(link), 1000);
        }
        engine.link_up(LinkId(6), Role::Peripheral, FRAME, None, 4999);
        assert!(closes(&drain(&mut engine)) == vec![LinkId(6)]);
        engine.link_up(LinkId(7), Role::Peripheral, FRAME, None, 5000);
        assert!(drain(&mut engine).is_empty());
        engine.link_up(LinkId(8), Role::Peripheral, FRAME, None, 5001);
        assert!(closes(&drain(&mut engine)) == vec![LinkId(8)]);
    }

    #[test]
    fn a_much_stronger_peer_replaces_the_weakest_chosen_link_and_a_slightly_stronger_does_not() {
        let mut engine = engine(
            Config {
                max_outgoing: 3,
                ..quiet()
            },
            1,
        );
        let mut now = 0;
        let mut signal = BTreeMap::from([(1u64, -60i8), (2, -80)]);
        let mut round = |engine: &mut Engine, signal: &BTreeMap<u64, i8>| {
            for (&peer, &rssi) in signal {
                engine.sighting(PeerRef(peer), rssi, now);
            }
            now += TICK;
            engine.advance(now);
            let outputs = drain(engine);
            for &peer in &connects(&outputs) {
                engine.link_up(LinkId(peer.0), Role::Central, FRAME, Some(peer), now);
            }
            outputs
        };
        assert!(connects(&round(&mut engine, &signal)) == vec![PeerRef(1)]);
        assert!(connects(&round(&mut engine, &signal)) == vec![PeerRef(2)]);
        signal.insert(3, -75);
        assert!(
            connects(&round(&mut engine, &signal)) == vec![PeerRef(3)],
            "the random slot"
        );

        signal.insert(4, -73);
        for _ in 0..4 {
            let outputs = round(&mut engine, &signal);
            assert!(connects(&outputs).is_empty() && closes(&outputs).is_empty());
        }
        signal.insert(4, -72);
        let outputs = round(&mut engine, &signal);
        assert!(closes(&outputs) == vec![LinkId(2)]);
        assert!(connects(&outputs) == vec![PeerRef(4)]);
    }

    #[test]
    fn the_random_outgoing_link_is_rotated_when_another_peer_could_take_its_slot() {
        let config = Config {
            max_outgoing: 1,
            rotate_ms: 60_000,
            ..quiet()
        };
        let mut engine = engine(config.clone(), 1);
        let mut dialled = Vec::new();
        for at in (0..200_000).step_by(1000) {
            for peer in 1..=3 {
                engine.sighting(PeerRef(peer), -50, at);
            }
            engine.advance(at);
            let outputs = drain(&mut engine);
            for link in closes(&outputs) {
                let last = dialled.last().map(|(_, peer): &(u64, PeerRef)| peer.0);
                assert_eq!(Some(link.0), last);
            }
            for &peer in &connects(&outputs) {
                engine.link_up(LinkId(peer.0), Role::Central, FRAME, Some(peer), at);
                dialled.push((at, peer));
            }
        }
        assert_eq!(dialled.len(), 4);
        assert!(dialled.windows(2).all(|pair| {
            pair[0].1 != pair[1].1 && (60_000..=65_000).contains(&(pair[1].0 - pair[0].0))
        }));

        // With nobody else in sight it stays.
        let mut alone = self::engine(config, 1);
        for at in (0..200_000).step_by(1000) {
            alone.sighting(PeerRef(1), -50, at);
            alone.advance(at);
            let outputs = drain(&mut alone);
            assert!(closes(&outputs).is_empty());
            for &peer in &connects(&outputs) {
                alone.link_up(LinkId(1), Role::Central, FRAME, Some(peer), at);
            }
        }
        assert_eq!(alone.count(false), 1);
    }

    #[test]
    fn one_incoming_link_at_random_is_closed_once_all_slots_were_held_a_turn() {
        let config = Config {
            rotate_ms: 60_000,
            ..quiet()
        };
        let mut victims = BTreeSet::new();
        for seed in 0..24 {
            let mut engine = engine(config.clone(), seed);
            for link in 1..=4 {
                engine.link_up(LinkId(link), Role::Peripheral, FRAME, None, 0);
            }
            engine.advance(55_000);
            assert!(drain(&mut engine).is_empty());
            engine.advance(60_000);
            let closed = closes(&drain(&mut engine));
            assert_eq!(closed.len(), 1);
            victims.insert(closed[0]);
            // The slot it freed is not full for a turn: nobody else goes.
            engine.advance(110_000);
            assert!(drain(&mut engine).is_empty());
            assert_eq!(engine.count(true), 3);
        }
        assert!(
            victims.len() > 2,
            "the pick did not vary with the generator"
        );

        // With a slot still free there is nothing to make room for.
        let mut roomy = engine(config, 1);
        for link in 1..=3 {
            roomy.link_up(LinkId(link), Role::Peripheral, FRAME, None, 0);
        }
        roomy.advance(300_000);
        assert!(drain(&mut roomy).is_empty());
    }

    #[test]
    fn an_isolated_phone_wakes_only_for_its_emission_slots() {
        let mut engine = engine(Config::default(), 1);
        assert_eq!(engine.next_tick_ms, None);
        assert_eq!(engine.next_wake_ms(), Some(engine.next_emit_ms));

        engine.sighting(PeerRef(1), -50, 1000);
        assert_eq!(engine.next_wake_ms(), Some(1000 + TICK));
        // Never answered and never seen again: dialled once, then forgotten.
        let mut now = 1000;
        while let Some(wake) = engine.next_wake_ms().filter(|&wake| wake < 400_000) {
            now = wake;
            engine.advance(now);
        }
        assert!(connects(&drain(&mut engine)) == vec![PeerRef(1)]);
        assert_eq!(engine.next_tick_ms, None);
        assert!(engine.peers.is_empty() && now < 400_000);
    }

    // ---- mesh off ---------------------------------------------------------

    /// T-SEC-7.
    #[test]
    fn stop_leaves_no_packet_record_unread_entry_outbox_entry_or_link() {
        let mut rig = Rig::new(Config {
            credit_initial: 100,
            ..emitting()
        });
        let source = rig.peer(1);
        let other = rig.peer(2);
        rig.feed(source, &[1, 2, 3], 250);
        rig.run(10_000);
        rig.ask(other, &[id(1)]);
        rig.engine.mark_read(id(1), false);
        rig.engine
            .offer(CircleSlot(1), packet(9), u64::MAX, rig.now);
        rig.engine.sighting(PeerRef(4), -50, rig.now);
        // Left queued for the reader: nothing of it may outlive the stop.
        let sealed = rig.seal(other, frame::want(&[id(2), id(3)], size()));
        rig.engine.receive(other, &sealed, rig.now);
        assert!(!rig.engine.output.is_empty());
        rig.take(source);
        rig.take(other);
        let before = rig.engine.stats();
        assert!(before.held > 3 && before.unread == 3 && before.outbox == 1);
        assert_eq!(before.passed_on, 1);

        rig.engine.stop();
        rig.pump();
        assert!(rig.closed == vec![source, other]);
        assert!(rig.seen.is_empty() && rig.connects.is_empty());
        let after = rig.engine.stats();
        assert_eq!(
            (
                after.held,
                after.records,
                after.unread,
                after.outbox,
                after.links
            ),
            (0, 0, 0, 0, 0)
        );
        assert_eq!(rig.engine.store().ids().count(), 0);
        assert!(rig.engine.take_unread(9).is_empty());
        assert_eq!(rig.engine.next_wake_ms(), None);
        assert_eq!((after.passed_on, after.emitted), (1, before.emitted));

        // Off is off: nothing it is told afterwards starts it again.
        let later = rig.now + 60 * MINUTE_MS;
        rig.engine.advance(later);
        rig.engine.offer(CircleSlot(1), packet(10), u64::MAX, later);
        rig.engine.sighting(PeerRef(5), -50, later);
        rig.engine
            .link_up(LinkId(9), Role::Peripheral, FRAME, None, later);
        rig.engine.receive(LinkId(9), &[0; 32], later);
        rig.engine.connect_failed(PeerRef(5), later);
        rig.engine.purge(CircleSlot(1), later);
        rig.engine.link_down(LinkId(9), later);
        rig.engine.advance(later + 60 * MINUTE_MS);
        rig.engine.stop();
        assert!(rig.engine.poll_output().is_none());
        assert!(rig.engine.stats() == after);
        assert!(rig.engine.peers.is_empty() && rig.engine.outbox.is_empty());
    }

    // ---- counters ---------------------------------------------------------

    /// T-STAT-1.
    #[test]
    fn passed_on_counts_carried_packets_sent_on_and_not_opened_once_each() {
        let mut rig = Rig::new(Config {
            credit_initial: 100,
            ..emitting()
        });
        let source = rig.peer(1);
        let other = rig.peer(2);
        rig.engine.offer(CircleSlot(1), packet(9), u64::MAX, 0);
        rig.feed(source, &[1, 2, 3, 4], 250);
        rig.run(10_000);
        // Three carried packets and the phone's own are sent on.
        rig.ask(other, &[id(1), id(2), id(3), id(9)]);
        assert_eq!(rig.engine.stats().sent, 4);
        assert_eq!(rig.engine.stats().passed_on, 0, "nothing is counted unread");

        let unread = rig.engine.take_unread(9);
        assert!(unread == vec![packet(1), packet(2), packet(3), packet(4)]);
        rig.engine.mark_read(id(1), false);
        rig.engine.mark_read(id(2), true);
        rig.engine.mark_read(id(4), false);
        rig.engine.mark_read(id(9), false);
        assert_eq!(rig.engine.stats().passed_on, 1);
        rig.engine.mark_read(id(1), false);
        rig.engine.mark_read(id(2), false);
        assert_eq!(rig.engine.stats().passed_on, 1);
        rig.engine.mark_read(id(3), false);
        assert_eq!(rig.engine.stats().passed_on, 2);

        // Not sent on when it was judged: counted when it is.
        rig.ask(other, &[id(4)]);
        assert_eq!(rig.engine.stats().passed_on, 3);
        // A duplicate announcement or request changes nothing.
        rig.announce(source, &[(id(1), 250)]);
        rig.ask(other, &[id(1), id(4)]);
        rig.run(10_000);
        assert_eq!(rig.engine.stats().passed_on, 3);
    }

    #[test]
    fn a_packet_counts_as_sent_once_its_last_chunk_is_handed_over() {
        let mut rig = Rig::new(trusting());
        let source = rig.peer(1);
        let other = rig.peer(2);
        rig.feed(source, &[1], 250);
        rig.engine.mark_read(id(1), false);
        rig.run(TICK);
        let sealed = rig.seal(other, frame::want(&[id(1)], size()));
        rig.engine.receive(other, &sealed, rig.now);
        assert!(rig.step() && rig.step());
        assert_eq!(
            (rig.engine.stats().sent, rig.engine.stats().passed_on),
            (0, 0)
        );
        assert!(rig.step() && !rig.step());
        assert_eq!(
            (rig.engine.stats().sent, rig.engine.stats().passed_on),
            (1, 1)
        );
    }

    // ---- what a listener sees ---------------------------------------------

    fn contains(haystack: &[u8], needle: &[u8]) -> bool {
        haystack
            .windows(needle.len())
            .any(|window| window == needle)
    }

    /// T-PRIV-1 and T-PRIV-8 at the engine: on a recorded mesh no packet id,
    /// no packet bytes and no frame layout appear in clear, and every frame
    /// after the handshake has the link's one length.
    #[test]
    fn a_recorded_link_shows_no_id_no_packet_and_no_frame_layout() {
        let mut mesh = Mesh::new(vec![emitting(), emitting(), emitting()]);
        mesh.link(0, 1);
        mesh.link(1, 2);
        for n in 0..5u64 {
            mesh.nodes[0].offer(CircleSlot(1), packet(n), u64::MAX, mesh.now);
            mesh.run_to((n + 1) * 10_000 + 1);
        }
        mesh.run_to(70_000);

        let mut packets: Vec<Packet> = (0..5).map(packet).collect();
        for node in &mut mesh.nodes {
            packets.extend(node.take_unread(usize::MAX));
        }
        assert!(packets.len() > 15, "packets crossed the links");
        assert!((0..5).all(|n| mesh.nodes[2].store().holds(&id(n))));

        let handshakes = mesh.air.iter().filter(|frame| frame.len() != FRAME);
        let lengths: Vec<usize> = handshakes.map(Vec::len).collect();
        assert_eq!(lengths, [32, 48, 32, 48]);
        assert!(mesh.air.len() > 100);

        for sealed in mesh.air.iter().filter(|frame| frame.len() == FRAME) {
            assert!(frame::decode(&sealed[..FRAME - noise::TAG_LEN]).is_none());
            assert!(!contains(sealed, &[0; 8]), "a run of padding in clear");
        }
        for packet in &packets {
            let bytes = packet.as_bytes();
            let id = packet.id();
            for sealed in &mesh.air {
                assert!(!contains(sealed, &id.0));
                assert!(!contains(sealed, &bytes[..16]));
                assert!(!contains(sealed, &bytes[500..516]));
                assert!(!contains(sealed, &bytes[PACKET_LEN - 16..]));
            }
        }
    }

    // ---- whatever a peer does --------------------------------------------

    /// The engine's own bookkeeping agrees with itself and stays inside the
    /// bounds its configuration sets.
    fn assert_consistent(engine: &Engine) {
        let config = &engine.config;
        for link in engine.live() {
            let count = |wanted: fn(&Ask) -> bool| {
                link.offers.values().filter(|o| wanted(&o.state)).count()
            };
            let asked = count(|state| matches!(state, Ask::Asked { .. }));
            let abandoned = count(|state| matches!(state, Ask::Abandoned));
            assert_eq!(link.asked, asked);
            assert_eq!(link.expected, asked + abandoned);
            assert!(link.asked <= config.want_window);
            assert!(link.offers.len() <= config.offers_per_link);
            assert!(link.sends.len() <= config.store_packets);
            assert!(link.wants.len() <= config.want_window * usize::from(config.want_asks));
            assert!(link.assembly.len() < PACKET_LEN);
            let frames = engine.output.iter().filter(|q| q.is_frame_of(link.id));
            assert_eq!(frames.count(), link.queued);
            // The handshake reply rides on top of the share.
            assert!(link.queued <= config.link_queue_frames + 1);
        }
        assert!(engine.store.held() <= config.store_packets);
        assert!(engine.store.records() <= config.record_capacity());
        assert!(engine.store.unread() <= config.unread_packets);
        assert!(engine.peers.len() <= config.max_peers);
        assert!(engine.outbox.len() <= config.outbox_slots);
    }

    #[derive(Clone, Debug)]
    enum Act {
        Announce { link: usize, n: u64, remaining: u8 },
        Ask { link: usize, n: u64 },
        Chunk { link: usize, n: u64, index: u8 },
        Deliver { link: usize, n: u64 },
        Hello { link: usize, value: u8 },
        Garbage { link: usize, len: usize },
        Offer { n: u64 },
        Run(u64),
    }

    fn act() -> impl Strategy<Value = Act> {
        let link = 0usize..3;
        let n = 0u64..12;
        prop_oneof![
            4 => (link.clone(), n.clone(), 1u8..=255)
                .prop_map(|(link, n, remaining)| Act::Announce { link, n, remaining }),
            2 => (link.clone(), n.clone()).prop_map(|(link, n)| Act::Ask { link, n }),
            2 => (link.clone(), n.clone(), 0u8..4)
                .prop_map(|(link, n, index)| Act::Chunk { link, n, index }),
            4 => (link.clone(), n.clone()).prop_map(|(link, n)| Act::Deliver { link, n }),
            1 => (link.clone(), 0u8..4).prop_map(|(link, value)| Act::Hello { link, value }),
            1 => (link, prop_oneof![Just(0usize), Just(31), Just(FRAME)])
                .prop_map(|(link, len)| Act::Garbage { link, len }),
            1 => n.prop_map(|n| Act::Offer { n }),
            3 => (0u64..40_000).prop_map(Act::Run),
        ]
    }

    proptest! {
        // Each case runs a dozen handshakes: fewer cases, each a long script.
        #![proptest_config(ProptestConfig::with_cases(64))]

        /// T-SEC-3. Three peers that send any frame at any time, well-formed
        /// or not: the engine never panics, never sends a frame that does not
        /// open and parse, keeps its books, stays inside its bounds, and
        /// holds no packet it did not ask for.
        #[test]
        fn prop_no_peer_behaviour_breaks_the_engine(
            acts in proptest::collection::vec(act(), 1..150),
        ) {
            let mut rig = Rig::new(Config {
                store_packets: 5,
                unread_packets: 4,
                want_window: 3,
                credit_initial: 4,
                link_queue_frames: 3,
                offers_per_link: 6,
                inbound_per_min: 60_000,
                inbound_burst: 1000,
                emit_period_ms: 20_000,
                emit_jitter_ms: 5000,
                ..Config::default()
            });
            let mut links = [rig.peer(1), rig.peer(2), rig.peer(3)];
            let mut next_link = 4;
            let mut wanted = BTreeSet::new();
            for act in acts {
                match act {
                    Act::Announce { link, n, remaining } => {
                        rig.announce(links[link], &[(id(n), remaining)]);
                    }
                    Act::Ask { link, n } => rig.ask(links[link], &[id(n)]),
                    Act::Chunk { link, n, index } => {
                        rig.send(links[link], frame::pkt(&packet(n), index % 3, size()));
                    }
                    Act::Deliver { link, n } => {
                        for index in 0..3 {
                            if rig.peers.contains_key(&links[link]) {
                                rig.send(links[link], frame::pkt(&packet(n), index, size()));
                            }
                        }
                    }
                    Act::Hello { link, value } => rig.greet(links[link], [value; 8]),
                    Act::Garbage { link, len } => {
                        rig.engine.receive(links[link], &vec![0x5a; len], rig.now);
                        rig.pump();
                    }
                    Act::Offer { n } => {
                        rig.engine.offer(CircleSlot(1), packet(100 + n), u64::MAX, rig.now);
                    }
                    Act::Run(ms) => rig.run(ms),
                }
                assert_consistent(&rig.engine);
                for (_, seen) in &rig.seen {
                    if let Seen::Want(ids) = seen {
                        wanted.extend(ids.iter().copied());
                    }
                }
                rig.seen.clear();
                for n in 0..12 {
                    prop_assert!(!rig.store().has_record(&id(n)) || wanted.contains(&id(n)));
                }
                for link in &mut links {
                    if !rig.peers.contains_key(link) {
                        *link = rig.peer(next_link);
                        next_link += 1;
                    }
                }
            }
        }
    }

    /// T-SEC-3: a dropped, duplicated or reordered frame of a transfer adds
    /// no packet, and the packet still arrives afterwards.
    #[test]
    fn a_damaged_transfer_adds_no_packet_and_the_packet_still_arrives() {
        let orders: [&[usize]; 7] = [
            &[1, 2],
            &[0, 2],
            &[0, 1],
            &[0, 0, 1, 2],
            &[0, 1, 1, 2],
            &[1, 0, 2],
            &[0, 2, 1],
        ];
        for order in orders {
            let mut rig = Rig::new(trusting());
            let link = rig.peer(1);
            rig.announce(link, &[(id(1), 250)]);
            assert_eq!(rig.wants(link).len(), 1);
            let sealed: Vec<Vec<u8>> = (0..3)
                .map(|index| rig.seal(link, frame::pkt(&packet(1), index, size())))
                .collect();
            for &index in order {
                rig.engine.receive(link, &sealed[index], 0);
            }
            rig.pump();
            assert_eq!(rig.engine.stats().records, 0);
            assert_eq!(rig.engine.stats().unread, 0);
            // Only a transfer cut short leaves the link up, waiting.
            assert_eq!(rig.closed.is_empty(), order == [0, 1]);

            let again = rig.peer(2);
            rig.run(60_000);
            assert!(rig.feed(again, &[1], 250) == vec![id(1)] || rig.store().holds(&id(1)));
            assert!(rig.store().holds(&id(1)));
        }
    }

    #[test]
    fn an_engine_nobody_polls_queues_no_more_than_its_bounds() {
        let mut engine = engine(Config::default(), 1);
        for link in 1..=4 {
            engine.link_up(LinkId(link), Role::Peripheral, FRAME, None, 0);
        }
        for at in (0..60 * MINUTE_MS).step_by(1000) {
            sight_ten(&mut engine, at);
            engine.advance(at);
            // One connect, and a close for each incoming link rotated out.
            assert!(engine.output.len() <= 5);
        }
        assert_consistent(&engine);
        assert_eq!(connects(&drain(&mut engine)).len(), 1);
    }

    // ---- waking -----------------------------------------------------------

    /// Everything one engine does over ten minutes with a peer that never
    /// delivers, peers in sight that never answer and an outbox, when it is
    /// advanced at its wake times and at `extra` times besides.
    fn wake_trace(extra: &[u64]) -> Vec<(u64, u64, Vec<u8>)> {
        let mut rig = Rig::new(Config::default());
        let link = rig.peer(1);
        let entries: Vec<_> = (1..=5).map(|n| (id(n), 250)).collect();
        rig.announce(link, &entries);
        for peer in 1..=3 {
            rig.engine.sighting(PeerRef(peer), -50, 0);
        }
        rig.engine.offer(CircleSlot(1), packet(9), u64::MAX, 0);
        rig.take(link);

        let mut extra = extra.iter().copied().peekable();
        let mut trace = Vec::new();
        while let Some(wake) = rig.engine.next_wake_ms().filter(|&wake| wake <= 600_000) {
            while let Some(early) = extra.next_if(|&early| early < wake) {
                rig.engine.advance(early);
                assert!(
                    rig.engine.poll_output().is_none(),
                    "work was due before the wake"
                );
                assert_eq!(rig.engine.next_wake_ms(), Some(wake));
            }
            rig.now = wake;
            rig.engine.advance(wake);
            rig.pump();
            let stats = rig.engine.stats();
            for seen in rig.take(link) {
                let kind = match seen {
                    Seen::Hello(_) => 1,
                    Seen::Have(entries) => 20 + entries.len(),
                    Seen::Want(ids) => 40 + ids.len(),
                    Seen::Pkt(..) => 3,
                    Seen::Bye => 4,
                };
                trace.push((
                    wake,
                    stats.emitted,
                    vec![u8::try_from(kind).expect("small")],
                ));
            }
            for peer in std::mem::take(&mut rig.connects) {
                trace.push((
                    wake,
                    stats.emitted,
                    vec![100, u8::try_from(peer.0).expect("small")],
                ));
            }
            for peer in 1..=3 {
                rig.engine.sighting(PeerRef(peer), -50, wake);
            }
        }
        trace
    }

    #[test]
    fn the_wake_trace_covers_requests_dials_and_emissions() {
        let trace = wake_trace(&[]);
        let of = |kind: u8| trace.iter().filter(|entry| entry.2[0] == kind).count();
        assert!(of(45) >= 1, "the unanswered requests are made again");
        assert!(of(100) >= 4, "peers are dialled again after their back-off");
        assert!(of(21) >= 3, "emitted packets are announced");
        assert!(trace.last().is_some_and(|last| last.1 >= 5));
    }

    proptest! {
        /// `next_wake_ms` is never later than the next due timer: advancing
        /// at any other time does nothing, so advancing exactly at each wake
        /// time does all the work there is.
        #[test]
        fn prop_nothing_is_due_before_the_next_wake(
            mut extra in proptest::collection::vec(0u64..600_000, 0..200),
        ) {
            extra.sort_unstable();
            prop_assert!(wake_trace(&extra) == wake_trace(&[]));
        }
    }
}
