//! The mesh engine: one phone's links, inventory flood, emission schedule and
//! link budget as an owned state machine (plan §3, §5.1, §6, §15).
//!
//! The engine holds no key, does no I/O and reads no clock. Every call names
//! the time on a clock that keeps counting during sleep; time never runs
//! backwards, and every call, [`MeshEngine::poll_output`] included, first
//! runs the timers that fell due. What the radio layer must do comes out of
//! [`MeshEngine::poll_output`]; when to call [`MeshEngine::advance`] next
//! comes out of [`MeshEngine::next_wake_ms`].
//!
//! A link carries the two raw Noise handshake messages, then sealed frames of
//! exactly its frame size (`frame`). Each side opens with `HELLO`, announces
//! what it holds as `HAVE`, asks with `WANT` for what it lacks and may take,
//! and is sent each wanted packet as `PKT` chunks. A packet that was not asked
//! for on that link, a frame that does not open or does not parse, and a first
//! frame that is not `HELLO` close the link; so does a peer whose `HELLO` has
//! not come within [`Config::connect_timeout_ms`] of the link coming up.
//!
//! **Frames are built when polled.** A link frame is sealed by the call that
//! hands it out, so the lifetime it announces is the one at that instant and
//! a transfer starts only on a packet that may still be sent. Nothing waits
//! in a queue but handshake messages, `BYE`s, closes and one connect.
//!
//! **Duplicate links.** Two phones may connect in both directions. Of the
//! links on which one `HELLO` value has been seen, the one that saw it first
//! is kept and the others are closed with `BYE`; a value equal to this
//! phone's own closes the link it came on. Both ends see the same order
//! unless the two links' `HELLO`s cross, in which case each may close a
//! different one and the jittered back-off lets one re-form. The rule keeps
//! the older link because a `HELLO` value is not a secret: a rule the newer
//! link could win would let any neighbour of a peer close the link to it,
//! and the second link of a crossed pair looks, from either end, exactly
//! like such a neighbour's. The peer whose link was closed is taken as
//! reached through the one kept only until that link's value changes or
//! [`Config::rotate_ms`] has passed, then dialled again: a link that showed
//! a neighbour's value first does not keep the neighbour away for good.
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
//! A request not answered within [`Config::want_timeout_ms`] is given up and
//! may be made of another link; its packet is still taken for as long again,
//! and after that it was asked for by nobody. Until then it counts against
//! [`Config::want_window`], so requests do not pile up behind a slow link; a
//! link too slow to deliver a window within two timeouts is still closed by
//! its late answers.
//!
//! **Rate limit.** Requests over all links are limited together, and the
//! limit is shared out by turns, one request per link per turn: a link that
//! announces without pause is asked for no more than any other link that has
//! something to ask for.
//!
//! Nothing here logs, and no type that holds a packet, an id or a peer is
//! `Debug` (Security Rule 15).

use std::cmp::Reverse;
use std::collections::{BTreeMap, VecDeque};
use std::ops::Bound;

use rand::{CryptoRng, Rng, RngCore};

use super::frame::{self, Frame, FrameSize, HELLO_VALUE_LEN};
use super::noise::{self, Initiator, Transport};
use super::packet::{cover_packet, Packet, PacketId, PACKET_LEN};
use super::store::{Limits, Origin, Store, MAX_LINKS};

const MINUTE_MS: u64 = 60_000;

/// How many ended `HELLO` intervals one call draws before it gives up
/// catching up: far more than any sleep spans (seven weeks at the default
/// period), few enough that a clock jumping by years returns at once.
const HELLO_CATCH_UP: u32 = 10_000;

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

impl Output {
    fn is_frame_of(&self, id: LinkId) -> bool {
        matches!(self, Self::Frame { link, .. } if *link == id)
    }
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
    /// request was given up on, made of another link and answered by both.
    /// Such a packet is dropped and changes nothing else.
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
    /// §6.3: the most packets one link may still deliver: asked of it, not
    /// received, and still taken if they come.
    pub want_window: usize,
    /// §6.3: how long a request waits for its packet before another link
    /// that announced it may be asked. The packet is still taken for as long
    /// again, and keeps its place in the window meanwhile; after that it was
    /// asked for by nobody.
    pub want_timeout_ms: u64,
    /// §6.3: the most announcements remembered per link for packets not yet
    /// held; further ones are ignored.
    pub offers_per_link: usize,
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
    /// §6.1: the middle of the interval after which the `HELLO` value is
    /// drawn afresh; each interval is drawn between half of it and one and a
    /// half.
    pub hello_period_ms: u64,
    /// §6.1: the weakest signal a peer is connected to at.
    pub rssi_floor: i8,
    /// §6.1: how much stronger a candidate must be to replace the weakest
    /// signal-chosen link.
    pub rssi_hysteresis: u8,
    /// §6.1: how long the random outgoing link, and a full set of incoming
    /// links, lasts before one is closed; and how long a peer whose link was
    /// closed as a duplicate is taken as reached through the one kept.
    pub rotate_ms: u64,
    /// §6.1: how long a sighting makes a peer a candidate.
    pub sighting_ttl_ms: u64,
    /// §6.1: how long a connect attempt may take, and how long a link may
    /// take from coming up to its peer's `HELLO`.
    pub connect_timeout_ms: u64,
    /// §6.1: how long a peer is left alone after a failed connect or a
    /// closed link.
    pub backoff_ms: u64,
    /// §6.1: up to this much is added to each back-off, drawn per use, so two
    /// phones that closed each other's link do not retry in step.
    pub backoff_jitter_ms: u64,
    /// §6.1: the most peers remembered from sightings; one more takes the
    /// place of one picked at random.
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
            offers_per_link: 2048,
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
    /// The size of the record table (§6.4): every packet that can have a
    /// record at one time, so traffic inside the rate limit cannot fill it.
    ///
    /// A record lasts `2 L`, and a packet is taken only within two request
    /// timeouts of the request the rate limit counted. So the packets with a
    /// record are at most the requests the limit allows in `2 L` and that
    /// wait together, and this phone's own emissions in `2 L`.
    #[must_use]
    pub fn record_capacity(&self) -> usize {
        let reaccept_ms = self.life_ms.saturating_mul(2);
        let asked_ms = reaccept_ms.saturating_add(self.want_timeout_ms.saturating_mul(2));
        let requested = self
            .accept_per_min
            .saturating_mul(asked_ms.div_ceil(MINUTE_MS))
            .saturating_add(self.accept_burst);
        let shortest_slot = self.emit_period_ms.saturating_sub(self.emit_jitter_ms);
        let emitted = reaccept_ms / shortest_slot.max(1) + 1;
        usize::try_from(requested.saturating_add(emitted)).unwrap_or(usize::MAX)
    }

    /// Periods of at least a millisecond and no more links than a record
    /// tracks: a zero period would wake the caller forever.
    fn bounded(mut self) -> Self {
        self.tick_ms = self.tick_ms.max(1);
        self.hello_period_ms = self.hello_period_ms.max(1);
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

    /// Whether a token is there to take at `now_ms`.
    fn has(&mut self, per_min: u64, burst: u64, now_ms: u64) -> bool {
        let gained = now_ms.saturating_sub(self.at_ms).saturating_mul(per_min);
        self.level = self
            .level
            .saturating_add(gained)
            .min(burst.saturating_mul(MINUTE_MS));
        self.at_ms = now_ms;
        self.level >= MINUTE_MS
    }

    fn take(&mut self, per_min: u64, burst: u64, now_ms: u64) -> bool {
        let granted = self.has(per_min, burst, now_ms);
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
    /// Asked for at `since_ms`: no other link is asked meanwhile.
    Asked { since_ms: u64 },
    /// Asked for at `since_ms` and not delivered within the request timeout:
    /// another link may be asked.
    Abandoned { since_ms: u64 },
}

struct Offer {
    /// When the packet's lifetime ends, by the link's announcements.
    expires_ms: u64,
    state: Ask,
}

impl Offer {
    /// Whether the packet may still arrive: it was asked for less than two
    /// request timeouts ago. The bound is on the time since the request, not
    /// on the packet's lifetime, which the peer can announce again and again:
    /// it is what lets the record table be sized (`Config::record_capacity`).
    const fn awaited(&self, now_ms: u64, timeout_ms: u64) -> bool {
        match self.state {
            Ask::Offered => false,
            Ask::Asked { since_ms } | Ask::Abandoned { since_ms } => {
                now_ms.saturating_sub(since_ms) < timeout_ms.saturating_mul(2)
            }
        }
    }
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
    /// A peer whose own link was closed as a duplicate of this one, and
    /// when: reached through this link until its `HELLO` value changes or
    /// [`Config::rotate_ms`] has passed.
    alias: Option<(PeerRef, u64)>,
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
    /// Offers in [`Ask::Asked`] or [`Ask::Abandoned`]: the packets the peer
    /// may still send, which is what the window counts.
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

/// How a link ends.
#[derive(Clone, Copy, PartialEq, Eq)]
enum End {
    /// The radio layer reported it gone: nothing to send or say.
    Gone,
    /// The peer broke the protocol, or the phone has no room: disconnect,
    /// and send nothing more.
    Drop,
    /// This phone's own choice: send `BYE`, then disconnect.
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
    /// Handshake messages, `BYE`s, closes and connects, in order. Every other
    /// frame is built when it is polled.
    output: VecDeque<Output>,
    outbox: BTreeMap<CircleSlot, Waiting>,
    next_emit_ms: u64,
    next_tick_ms: Option<u64>,
    hello: [u8; HELLO_VALUE_LEN],
    /// When the `HELLO` value is next drawn afresh.
    hello_ms: u64,
    /// Counts the `HELLO` values seen, to order them.
    hellos_seen: u64,
    peers: BTreeMap<PeerRef, Peer>,
    connecting: Option<Attempt>,
    accepts: Bucket,
    /// The slot whose turn it is to be asked for a packet.
    asking: usize,
    /// The slot whose turn it is to have a frame built.
    serving: usize,
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
            hello_ms: now_ms,
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
            hellos_seen: 0,
            peers: BTreeMap::new(),
            connecting: None,
            asking: 0,
            serving: 0,
            emitted: 0,
            accepted: 0,
            sent: 0,
            duplicates: 0,
        };
        engine.hello_ms = now_ms.saturating_add(engine.hello_interval());
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
            .retain(|output| !output.is_frame_of(link) && *output != Output::Close { link });
        if !self.admit(link, role, max_frame, peer) {
            self.output.push_back(Output::Close { link });
        }
        self.settle();
    }

    /// The radio layer lost `link`, or closed it as told.
    pub fn link_down(&mut self, link: LinkId, now_ms: u64) {
        if self.stopped {
            return;
        }
        self.clock(now_ms);
        match self.slot_of(link) {
            Some(slot) => self.end(slot, End::Gone),
            // Already ended with a `BYE` that can no longer be sent.
            None => self.output.retain(|output| !output.is_frame_of(link)),
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
        } else if rssi >= self.config.rssi_floor && self.make_room() {
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

    /// The next thing for the radio layer to do, in order, after running the
    /// timers due at `now_ms`.
    ///
    /// A link frame is sealed by the call that returns it, so a lifetime it
    /// announces is the one at `now_ms`. Links with frames to send take
    /// turns, one frame each.
    pub fn poll_output(&mut self, now_ms: u64) -> Option<Output> {
        self.poll(None, now_ms)
    }

    /// As [`Self::poll_output`], for a radio layer whose links cannot all
    /// send now: nothing comes out for a link that is not in `ready` but its
    /// close, and that only once no frame waits ahead of it. A link that is
    /// slow to take its frames so holds up no other, and its own frames are
    /// built when it can send them.
    pub fn poll_output_ready(&mut self, ready: &[LinkId], now_ms: u64) -> Option<Output> {
        self.poll(Some(ready), now_ms)
    }

    fn poll(&mut self, ready: Option<&[LinkId]>, now_ms: u64) -> Option<Output> {
        if !self.stopped {
            self.clock(now_ms);
            self.settle();
        }
        let can_send = |link: LinkId| ready.is_none_or(|ready| ready.contains(&link));
        let queued = (0..self.output.len()).find(|&at| match self.output.get(at) {
            Some(Output::Frame { link, .. }) => can_send(*link),
            // After the `BYE` queued for its link.
            Some(Output::Close { link }) => {
                !(self.output.iter().take(at)).any(|ahead| ahead.is_frame_of(*link))
            }
            Some(Output::Connect { .. }) => true,
            None => false,
        });
        if let Some(at) = queued {
            return self.output.remove(at);
        }
        for _ in 0..self.links.len() {
            let slot = self.serving;
            self.serving = (slot + 1) % self.links.len();
            let sends = (self.links.get(slot).and_then(Option::as_ref))
                .is_some_and(|link| can_send(link.id));
            if let Some(output) = sends.then(|| self.build(slot)).flatten() {
                return Some(output);
            }
        }
        None
    }

    /// The earliest time [`Self::advance`] has work; `None` once stopped.
    #[must_use]
    pub fn next_wake_ms(&self) -> Option<u64> {
        let stalls = self
            .live()
            .filter(|link| link.peer_hello.is_none())
            .map(|link| link.up_ms.saturating_add(self.config.connect_timeout_ms));
        // Only a phone with a link to greet wakes to draw a new `HELLO`.
        let greeting = self.live().next().map(|_| self.hello_ms);
        let timers = self.next_tick_ms.into_iter().chain(greeting).chain(stalls);
        (!self.stopped).then(|| timers.fold(self.next_emit_ms, u64::min))
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
        // Before anything a link could be greeted with: the tick stops while
        // the phone is alone, and a value kept through that would show a
        // later peer which phone this was hours ago.
        self.renew_hello();
        if self.now_ms >= self.next_emit_ms {
            self.emit();
        }
        self.drop_stalled();
        if self.next_tick_ms.is_some_and(|tick| self.now_ms >= tick) {
            self.next_tick_ms = Some(self.now_ms.saturating_add(self.config.tick_ms));
            self.tick();
        }
    }

    /// Ends every input: keeps the tick running only while there is a link
    /// or a peer to plan for, so an isolated phone wakes for its emission
    /// slots alone.
    fn settle(&mut self) {
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

    /// How long one `HELLO` value lasts: drawn per value, between half the
    /// period and one and a half. On a fixed beat the time of day at which a
    /// phone's value changes would be the same for as long as it runs, and
    /// whoever saw it change at two meetings could tell them to be one phone.
    fn hello_interval(&mut self) -> u64 {
        let period = self.config.hello_period_ms;
        let longest = period.saturating_add(period / 2);
        self.rng.gen_range(period.div_ceil(2)..=longest)
    }

    /// Draws the `HELLO` value afresh, once for every interval that has
    /// ended, and greets every open link again. An interval runs from when
    /// the last one ended, not from now, and each is drawn even when many
    /// ended unseen: what the generator has been asked for by any instant
    /// does not depend on when the engine was called, so neither does
    /// anything drawn after it (T-PRIV-4). Past [`HELLO_CATCH_UP`] intervals
    /// the next one runs from now instead, so the loop always ends.
    fn renew_hello(&mut self) {
        let mut drawn = 0;
        while self.now_ms >= self.hello_ms {
            let interval = self.hello_interval();
            self.hello = self.rng.gen();
            for link in self.links.iter_mut().flatten() {
                link.hello_due = matches!(link.phase, Phase::Open(_));
            }
            drawn += 1;
            if drawn == HELLO_CATCH_UP {
                self.hello_ms = self.now_ms.saturating_add(interval);
                break;
            }
            self.hello_ms = self.hello_ms.saturating_add(interval);
        }
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

    /// Closes, with no frame, every link whose peer's `HELLO` has not come
    /// within the connect timeout of the link coming up: a peer that stalls
    /// the handshake or the greeting holds no slot.
    fn drop_stalled(&mut self) {
        let (now, limit) = (self.now_ms, self.config.connect_timeout_ms);
        for slot in 0..self.links.len() {
            let stalled = (self.links.get(slot).and_then(Option::as_ref)).is_some_and(|link| {
                link.peer_hello.is_none() && now.saturating_sub(link.up_ms) >= limit
            });
            if stalled {
                self.end(slot, End::Drop);
            }
        }
    }

    /// The one coalesced tick.
    fn tick(&mut self) {
        let now = self.now_ms;
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
        }
        self.request();
        for link in self.links.iter_mut().flatten() {
            if link.peer_hello.is_some() {
                link.announcing = true;
                link.cursor = None;
                link.scan_ms = now;
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
        let phase = match role {
            Role::Central => {
                let (initiator, hello) = Initiator::start(&mut self.rng);
                self.output.push_back(Output::Frame {
                    link: id,
                    bytes: hello.to_vec(),
                });
                Phase::Reply(initiator)
            }
            Role::Peripheral => Phase::Hello,
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
            expected: 0,
            charged: 0,
            wants: VecDeque::new(),
            sends: VecDeque::new(),
            sending: None,
            assembly: Vec::new(),
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
                    self.output.push_back(Output::Frame {
                        link: link.id,
                        bytes,
                    });
                }
            }
        } else {
            self.output.retain(|output| !output.is_frame_of(link.id));
        }
        if how != End::Gone {
            self.output.push_back(Output::Close { link: link.id });
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
                self.output.push_back(Output::Frame {
                    link: link.id,
                    bytes: reply.to_vec(),
                });
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
            Some(known) => {
                *known = (value, seen);
                // Whoever this link stood in for showed the value it had.
                link.alias = None;
            }
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
                    keeper.alias = reached.map(|peer| (peer, now));
                }
            }
        }
        true
    }

    /// The peer's inventory: raises what is held and remembers what is not.
    /// What is then asked for is settled over all links together.
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
        self.request();
    }

    /// The peer's requests: each packet it was told of, once, while it is
    /// held and may be sent. Anything else is ignored, so asking tells
    /// nothing.
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
    /// only if this link was asked for it less than two request timeouts
    /// ago.
    fn take_chunk(&mut self, slot: usize, index: u8, chunk: &[u8]) -> bool {
        let (now, timeout) = (self.now_ms, self.config.want_timeout_ms);
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
        let Some(offer) = (link.offers.remove(&id)).filter(|offer| offer.awaited(now, timeout))
        else {
            return false;
        };
        link.expected = link.expected.saturating_sub(1);

        if self.store.has_record(&id) {
            // Given up on here, asked of another link and delivered by both:
            // the second copy is dropped and changes nothing.
            self.duplicates += 1;
            return true;
        }
        if self
            .store
            .accept(packet, Origin::Link(mark), offer.expires_ms, &mut self.rng)
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

    /// Forgets offers whose packet expired unasked, gives up on requests a
    /// timeout old, so that another link may be asked, and forgets those two
    /// timeouts old.
    fn review_offers(&mut self, slot: usize) {
        let (now, timeout) = (self.now_ms, self.config.want_timeout_ms);
        let Some(link) = self.links.get_mut(slot).and_then(Option::as_mut) else {
            return;
        };
        let expected = &mut link.expected;
        link.offers.retain(|_, offer| {
            match offer.state {
                Ask::Offered => return offer.expires_ms > now,
                Ask::Asked { since_ms } if now.saturating_sub(since_ms) >= timeout => {
                    offer.state = Ask::Abandoned { since_ms };
                }
                Ask::Asked { .. } | Ask::Abandoned { .. } => {}
            }
            let keep = offer.awaited(now, timeout);
            *expected = expected.saturating_sub(usize::from(!keep));
            keep
        });
        // A request not yet framed for an offer given up since must not be
        // sent: the packet would arrive when another link's has.
        let offers = &link.offers;
        link.wants.retain(|id| {
            matches!(
                offers.get(id),
                Some(Offer {
                    state: Ask::Asked { .. },
                    ..
                })
            )
        });
    }

    /// Asks for packets the links announced while the rate limit over all
    /// links has a token: lowest id first on each link, ones with no record
    /// that no link is being asked for, within the link's window and credit.
    ///
    /// The tokens are shared out by turns, one request per link per turn,
    /// and the turn carries on from call to call. A link that announces
    /// without pause is so asked for no more than any other link that has
    /// something to ask for, whoever's frame brought the call about.
    fn request(&mut self) {
        let slots = self.links.len();
        let (now, rate, burst) = (
            self.now_ms,
            self.config.accept_per_min,
            self.config.accept_burst,
        );
        // How far each link's offers have been looked through in this call.
        let mut looked = vec![Bound::Unbounded; slots];
        let mut passed = 0;
        while passed < slots && self.accepts.has(rate, burst, now) {
            let slot = self.asking;
            let found = looked
                .get_mut(slot)
                .and_then(|from| self.next_to_ask(slot, from));
            if let Some(id) = found {
                self.accepts.take(rate, burst, now);
                self.ask(slot, id);
            }
            passed = if found.is_some() { 0 } else { passed + 1 };
            self.asking = (slot + 1) % slots;
        }
    }

    /// The next packet to ask the link in `slot` for, in id order from
    /// `from`, which is moved past it — to the end when the link has no
    /// room or nothing more to ask for.
    fn next_to_ask(&self, slot: usize, from: &mut Bound<PacketId>) -> Option<PacketId> {
        let now = self.now_ms;
        let link = self.links.get(slot)?.as_ref()?;
        let age_ms = now.saturating_sub(link.up_ms);
        let allowance = self
            .config
            .credit_initial
            .saturating_add(age_ms.saturating_mul(self.config.credit_per_min) / MINUTE_MS);
        // A request given up still has its place: the peer has it queued and
        // will answer, and requests made in its place would wait behind it
        // until an answer came too late to be taken.
        let room = link.expected < self.config.want_window && link.charged < allowance;
        let asked_elsewhere = |id: &PacketId| {
            self.links.iter().enumerate().any(|(other, link)| {
                let offer = link.as_ref().and_then(|link| link.offers.get(id));
                other != slot && offer.is_some_and(|offer| matches!(offer.state, Ask::Asked { .. }))
            })
        };
        let found = room
            .then(|| {
                let mut rest = link.offers.range((*from, Bound::Unbounded));
                rest.find(|(id, offer)| {
                    matches!(offer.state, Ask::Offered)
                        && offer.expires_ms > now
                        && !self.store.has_record(id)
                        && !asked_elsewhere(id)
                })
            })
            .flatten()
            .map(|(id, _)| *id);
        *from = Bound::Excluded(found.unwrap_or(PacketId([u8::MAX; 16])));
        found
    }

    fn ask(&mut self, slot: usize, id: PacketId) {
        let now = self.now_ms;
        let Some(link) = self.link_mut(slot) else {
            return;
        };
        if let Some(offer) = link.offers.get_mut(&id) {
            offer.state = Ask::Asked { since_ms: now };
            link.expected += 1;
            link.charged += 1;
            link.wants.push_back(id);
        }
    }

    // ---- sending ---------------------------------------------------------

    /// Seals the next frame the link in `slot` has to send.
    fn build(&mut self, slot: usize) -> Option<Output> {
        let (plain, completes) = self.next_frame(slot)?;
        let link = self.links.get_mut(slot)?.as_mut()?;
        let Phase::Open(transport) = &mut link.phase else {
            return None;
        };
        let Some(bytes) = transport.seal(&plain) else {
            self.end(slot, End::Drop);
            // The close just queued: nothing else waits for this link.
            return self.output.pop_back();
        };
        let link = link.id;
        if let Some(id) = completes {
            self.store.sent(&id);
            self.sent += 1;
        }
        Some(Output::Frame { link, bytes })
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
            // An offer given up since must not be asked for: its packet
            // would arrive when another link's has.
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
            // packet that expired meanwhile is not sent.
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
        let (now, turn) = (self.now_ms, self.config.rotate_ms);
        let stands_in = |link: &Link| {
            (link.alias).is_some_and(|(alias, since_ms)| {
                alias == peer && now.saturating_sub(since_ms) < turn
            })
        };
        self.live()
            .any(|link| link.peer == Some(peer) || stands_in(link))
            || self.connecting.as_ref().is_some_and(|c| c.peer == peer)
    }

    /// Room in the peer table for one more. When it is full a peer picked at
    /// random among those neither linked nor being dialled is forgotten, so
    /// whoever advertises under many addresses keeps nobody out of it.
    fn make_room(&mut self) -> bool {
        if self.peers.len() < self.config.max_peers {
            return true;
        }
        let idle: Vec<PeerRef> = (self.peers.keys().copied())
            .filter(|peer| !self.linked(*peer))
            .collect();
        if idle.is_empty() {
            return false;
        }
        let pick = self.rng.gen_range(0..idle.len());
        (idle.get(pick)).is_some_and(|gone| self.peers.remove(gone).is_some())
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
        let unpolled = |output: &Output| matches!(output, Output::Connect { .. });
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
        self.output.push_back(Output::Connect { peer });
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
            match self.engine.poll_output(self.now) {
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

        /// Carries out the next thing the engine has for the radio layer, if
        /// any.
        fn step(&mut self) -> bool {
            let output = self.engine.poll_output(self.now);
            output.map(|output| self.carry(output)).is_some()
        }

        /// As [`Self::pump`], with only the links in `ready` able to send.
        fn pump_ready(&mut self, ready: &[LinkId]) {
            while let Some(output) = self.engine.poll_output_ready(ready, self.now) {
                self.carry(output);
            }
        }

        fn carry(&mut self, output: Output) {
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
                    while let Some(output) = self.nodes[node].poll_output(self.now) {
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

    /// What an engine with no scripted peers has for the radio layer, at the
    /// time of its last input.
    fn drain(engine: &mut Engine) -> Vec<Output> {
        let now = engine.now_ms;
        std::iter::from_fn(|| engine.poll_output(now)).collect()
    }

    /// Takes the handshake message the engine has queued for `link`.
    fn handshake_of(engine: &mut Engine, link: LinkId, now: u64) -> Vec<u8> {
        match engine.poll_output(now) {
            Some(Output::Frame { link: on, bytes }) if on == link => bytes,
            _ => panic!("the engine did not send its handshake message"),
        }
    }

    /// Greets the engine on `link` as its peer and takes its own greeting:
    /// a link whose peer never greets is closed at the stall deadline.
    fn greet_as_peer(engine: &mut Engine, link: LinkId, mut peer: Transport, now: u64) {
        let hello = frame::hello(&link.0.to_le_bytes(), size()).expect("encodes");
        engine.receive(link, &peer.seal(&hello).expect("seals"), now);
        while let Some(output) = engine.poll_output(now) {
            assert!(
                output.is_frame_of(link),
                "something other than the greeting"
            );
        }
    }

    /// The engine connects out on `link` to a peer that shakes hands and
    /// greets.
    fn open_outgoing(engine: &mut Engine, link: LinkId, peer: PeerRef, now: u64) {
        engine.link_up(link, Role::Central, FRAME, Some(peer), now);
        let hello = handshake_of(engine, link, now);
        let (transport, reply) =
            noise::respond(&hello, &mut StdRng::seed_from_u64(link.0)).expect("a hello");
        engine.receive(link, &reply, now);
        greet_as_peer(engine, link, transport, now);
    }

    /// A peer connects in on `link`, shakes hands and greets.
    fn open_incoming(engine: &mut Engine, link: LinkId, now: u64) {
        engine.link_up(link, Role::Peripheral, FRAME, None, now);
        let (initiator, hello) = Initiator::start(&mut StdRng::seed_from_u64(link.0));
        engine.receive(link, &hello, now);
        let reply = handshake_of(engine, link, now);
        let transport = initiator.finish(&reply).expect("the engine's reply");
        greet_as_peer(engine, link, transport, now);
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

    const HELLO_PERIOD: u64 = 15 * MINUTE_MS;

    /// §6.1: a `HELLO` value lasts half a period at least and one and a half
    /// at most, and a new one is sent on every open link.
    #[test]
    fn the_hello_value_is_drawn_afresh_within_half_a_period_of_fifteen_minutes_and_sent_again() {
        let mut rig = Rig::new(quiet());
        let link = rig.peer(1);
        let first = rig.engine.hello;
        rig.take(link);
        rig.run(HELLO_PERIOD / 2 - 1);
        assert!(rig.take(link).is_empty() && rig.engine.hello == first);
        rig.run(HELLO_PERIOD + 1);
        let second = rig.engine.hello;
        assert_ne!(first, second);
        let sent = rig.take(link);
        assert!(sent.last() == Some(&Seen::Hello(second)));
        assert!(sent.iter().all(|seen| matches!(seen, Seen::Hello(_))));
    }

    /// When an engine with one link up sends a new `HELLO`, over ten hours.
    fn renewals(seed: u64) -> Vec<u64> {
        let mut rig = Rig {
            engine: engine(quiet(), seed),
            ..Rig::new(quiet())
        };
        let link = rig.peer(1);
        rig.take(link);
        let greeting = |seen: &Seen| matches!(seen, Seen::Hello(_));
        let mut times = Vec::new();
        while rig.now < 600 * MINUTE_MS {
            let wake = rig.engine.next_wake_ms().expect("running");
            rig.run(wake - rig.now);
            if rig.take(link).iter().any(greeting) {
                times.push(wake);
            }
        }
        times
    }

    /// §6.1, the renewal's phase: on a fixed beat the time of day at which a
    /// phone's value changes, modulo the period, would be the same for as
    /// long as it runs, and whoever saw it change at two meetings could tell
    /// them to be one phone. Each value lasts a time drawn for it: one
    /// phone's renewals keep no phase, and two phones started in the same
    /// instant do not renew together.
    #[test]
    fn the_hello_value_changes_at_drawn_intervals_that_keep_no_phase() {
        let (one, other) = (renewals(1), renewals(2));
        for times in [&one, &other] {
            assert!(times.len() >= 26, "{} renewals in ten hours", times.len());
            let starts = std::iter::once(&0).chain(times.iter());
            let lasted: Vec<u64> = starts
                .zip(times.iter())
                .map(|(from, to)| to - from)
                .collect();
            assert!(lasted
                .iter()
                .all(|ms| (HELLO_PERIOD / 2..=HELLO_PERIOD * 3 / 2).contains(ms)));
            let lengths: BTreeSet<u64> = lasted.iter().copied().collect();
            assert!(lengths.len() > lasted.len() / 2, "the intervals repeat");
            let phases: BTreeSet<u64> = times.iter().map(|at| at % HELLO_PERIOD).collect();
            assert!(phases.len() > times.len() / 2, "the renewals keep a phase");
            // No beat: the phases are spread over the period.
            let ends = phases.first().zip(phases.last());
            assert!(ends.is_some_and(|(min, max)| max - min > HELLO_PERIOD / 2));
        }
        assert!(
            one.iter().zip(&other).skip(3).all(|(a, b)| a != b),
            "two phones renew at the same instants"
        );
    }

    /// §6.1: the `HELLO` value is drawn afresh before a link can be greeted
    /// with one older than one and a half periods — also when the phone was
    /// alone, when no tick ran, whether it woke for its emission slots
    /// meanwhile or not at all. The next peer is not shown the value this
    /// phone had an hour or a day ago, nor that value and then a new one:
    /// every interval that ended unseen is over by the first greeting, and
    /// the next greeting comes when the one then under way ends.
    /// A generator that counts what it is asked for. The traits are named in
    /// full: proptest's prelude brings in another `RngCore`.
    struct Counting(StdRng, u64);

    impl rand::RngCore for Counting {
        fn next_u32(&mut self) -> u32 {
            self.1 += 1;
            rand::RngCore::next_u32(&mut self.0)
        }

        fn next_u64(&mut self) -> u64 {
            self.1 += 1;
            rand::RngCore::next_u64(&mut self.0)
        }

        fn fill_bytes(&mut self, dest: &mut [u8]) {
            self.1 += 1;
            rand::RngCore::fill_bytes(&mut self.0, dest);
        }

        fn try_fill_bytes(&mut self, dest: &mut [u8]) -> Result<(), rand::Error> {
            self.1 += 1;
            rand::RngCore::try_fill_bytes(&mut self.0, dest)
        }
    }

    impl rand::CryptoRng for Counting {}

    /// The clock is the phone's own, but a wrong unit or a value near the end
    /// of its range must cost a bounded amount of work, not a loop over every
    /// interval since the engine began.
    #[test]
    fn a_clock_that_jumps_by_centuries_costs_a_bounded_amount_of_work() {
        for now in [1_000 * 365 * 24 * 60 * MINUTE_MS, u64::MAX - 1, u64::MAX] {
            let rng = Counting(StdRng::seed_from_u64(7), 0);
            let mut engine = MeshEngine::new(Config::default(), rng, 0);
            let old = engine.hello;
            let before = engine.rng.1;

            engine.advance(now);
            assert_ne!(engine.hello, old);
            // An interval and an eight-byte value a step, and one emission:
            // well under sixteen draws a step. A thousand years of intervals
            // unbounded would be tens of millions of steps.
            let bound = 16 * u64::from(HELLO_CATCH_UP);
            assert!(engine.rng.1 - before < bound);
            assert!(engine.hello_ms >= now);

            // And it stays bounded on every later call at that instant.
            let before = engine.rng.1;
            engine.advance(now);
            assert!(engine.rng.1 - before < bound);
        }
    }

    #[test]
    fn a_phone_alone_for_a_period_and_a_half_greets_its_next_link_with_a_fresh_value() {
        for alone in [HELLO_PERIOD * 3 / 2, 60 * MINUTE_MS, 24 * 60 * MINUTE_MS] {
            for woken in [false, true] {
                let mut rig = Rig::new(Config::default());
                let old = rig.engine.hello;
                if woken {
                    rig.run(alone);
                } else {
                    rig.now = alone;
                }
                let link = rig.dial(1);
                let fresh = rig.engine.hello;
                assert_ne!(fresh, old);
                assert!(rig.take(link) == vec![Seen::Hello(fresh)]);
                rig.greet(link, [1; 8]);
                let greeting = |seen: &Seen| matches!(seen, Seen::Hello(_));
                let ends = rig.engine.hello_ms;
                assert!(ends > rig.now && ends <= rig.now + HELLO_PERIOD * 3 / 2);
                rig.run(ends - 1 - rig.now);
                assert!(!rig.take(link).iter().any(greeting));
                rig.run(1);
                let again = rig.engine.hello;
                assert!(again != fresh && rig.take(link).contains(&Seen::Hello(again)));
            }
        }
        // Alone for less than half a period, it has the value it started with.
        let mut rig = Rig::new(Config::default());
        let old = rig.engine.hello;
        rig.now = HELLO_PERIOD / 2 - 1;
        let link = rig.dial(1);
        assert!(rig.take(link) == vec![Seen::Hello(old)]);
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
        let mut expected: Vec<_> = ns.iter().map(|&n| (id(n), 199)).collect();
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
        // Four seconds old: 199 whole units are left, and one less is said.
        assert!(rig.haves(other) == vec![(id(1), 198)]);
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
        assert!(rig.haves(other) == vec![(id(1), 197)]);
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
        // Two units are gone by the first tick, and a packet is announced
        // one unit short: three leave nothing to announce then, four leave
        // one unit, and none by the tick after.
        rig.feed(source, &[1], 3);
        rig.feed(source, &[2], 200);
        rig.feed(source, &[3], 4);
        rig.run(TICK);
        let mut told = vec![(id(2), 197), (id(3), 1)];
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
        // Four units: one is announced at the first tick, none by the second.
        rig.feed(liar, &[1], 4);
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
        assert!(rig.haves(downstream) == vec![(id(1), 177)]);
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
        assert_eq!(rig.store().remaining(&id(1)), 179);
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

    /// §6.3: a request given up keeps its place in the window for as long as
    /// its packet is still taken. A peer has been asked for it and will
    /// answer, however slowly; requests made in its place would queue behind
    /// it there, and their answers come too late to be taken. So the
    /// requests a link may still answer never number more than the window,
    /// and each of them, answered at the last instant, is taken.
    #[test]
    fn a_request_given_up_keeps_its_place_in_the_window_while_its_packet_is_still_taken() {
        const TIMEOUT: u64 = 7000;
        let config = Config {
            want_window: 5,
            want_timeout_ms: TIMEOUT,
            ..trusting()
        };
        let mut rig = Rig::new(config);
        let link = rig.peer(1);
        let names: BTreeMap<PacketId, u64> = (1..=40).map(|n| (id(n), n)).collect();
        let entries: Vec<_> = names.keys().map(|id| (*id, 250)).collect();
        rig.announce(link, &entries);

        // Every request, with when it was made; answered in its last
        // millisecond, when the peer is slow, or never.
        let mut asked: Vec<(u64, PacketId)> = Vec::new();
        let (mut answered, mut most) = (0, 0);
        while rig.now < 150_000 {
            asked.extend(rig.wants(link).into_iter().map(|id| (rig.now, id)));
            let open = |at: &u64| rig.now - at < 2 * TIMEOUT;
            let still_taken = asked.iter().filter(|(at, _)| open(at)).count();
            assert!(still_taken <= 5, "{still_taken} at {}", rig.now);
            most = most.max(still_taken);
            let last_instant = |at: &u64| rig.now - at == 2 * TIMEOUT - 1;
            let due: Vec<PacketId> = (asked.iter())
                .filter(|(at, id)| last_instant(at) && names[id].is_multiple_of(2))
                .map(|(_, id)| *id)
                .collect();
            for id in due {
                rig.deliver(link, &packet(names[&id]));
                answered += 1;
            }
            rig.run(1);
        }
        assert!(rig.closed.is_empty(), "an answer in time closed the link");
        assert_eq!((answered, rig.engine.stats().accepted), (20, 20));
        // The window was full, and turned over: all forty were asked for,
        // each once.
        let ids: BTreeSet<PacketId> = asked.iter().map(|(_, id)| *id).collect();
        assert_eq!((most, asked.len(), ids.len()), (5, 40, 40));
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

    /// §6.5: the rate limit is shared by turns. Two links announce three new
    /// packets a second each and hand over all they are asked for; a third
    /// announces one a second. With one request a second for all, the turn
    /// passes round the three, so of the requests made once each had
    /// something to ask for, every third is the third link's: its share is
    /// at least the whole less two, over three.
    #[test]
    fn a_link_that_announces_without_pause_is_asked_for_no_more_than_any_other() {
        let mut rig = Rig::new(Config {
            accept_per_min: 60,
            accept_burst: 3,
            ..trusting()
        });
        let links = [rig.peer(1), rig.peer(2), rig.peer(3)];
        let mut names = BTreeMap::new();
        let mut asked = [0usize; 3];
        let mut announce = |rig: &mut Rig, link: LinkId, ns: std::ops::Range<u64>| {
            names.extend(ns.clone().map(|n| (id(n), n)));
            let entries: Vec<_> = ns.map(|n| (id(n), 250)).collect();
            rig.announce(link, &entries);
            // Whatever the link has been asked for by now, it hands over.
            for (at, &link) in links.iter().enumerate() {
                for wanted in rig.wants(link) {
                    rig.deliver(link, &packet(names[&wanted]));
                    if rig.now > 0 {
                        asked[at] += 1;
                    }
                }
            }
        };
        for second in 0..300 {
            announce(&mut rig, links[0], second * 10..second * 10 + 3);
            announce(&mut rig, links[1], second * 10 + 3..second * 10 + 6);
            announce(&mut rig, links[2], second * 10 + 6..second * 10 + 7);
            rig.run(1000);
        }
        let total: usize = asked.iter().sum();
        assert!(total >= 295, "{total} requests in five minutes");
        assert!(3 * asked[2] + 2 >= total, "{asked:?}");
        assert!(rig.closed.is_empty());
    }

    /// §6.4: the record table has room for every packet that can have a
    /// record at one time. A link is asked for all the rate limit allows
    /// from the first moment; it holds back what it is asked for in the
    /// first two request timeouts and hands it over together at the last
    /// instant it may, and everything after at once; the engine emits a
    /// packet of its own every ten seconds. For two lifetimes and the wait
    /// the table is never full and no emission goes without its record —
    /// and a table with no room for the wait would have been full.
    #[test]
    fn the_record_table_is_never_filled_by_traffic_within_the_rate_limit() {
        const LIFE: u64 = 2 * MINUTE_MS;
        const TIMEOUT: u64 = 5000;
        let config = Config {
            life_ms: LIFE,
            accept_per_min: 60,
            accept_burst: 30,
            want_timeout_ms: TIMEOUT,
            emit_period_ms: 10_000,
            ..trusting()
        };
        let capacity = config.record_capacity();
        // The burst, a request a second for two lifetimes, and an emission
        // every ten seconds: what a table that forgot the wait would hold.
        let without_the_wait = 30 + 2 * 120 + 25;
        assert!(capacity > without_the_wait);
        let mut rig = Rig::new(config);
        let link = rig.peer(1);
        let last_instant = 2 * TIMEOUT - 1;

        let mut names = BTreeMap::new();
        let (mut held_back, mut most, mut emitted) = (Vec::new(), 0, 0);
        for second in 0..(2 * LIFE + 4 * TIMEOUT) / 1000 {
            let own = 1_000_000 + second;
            rig.engine
                .offer(CircleSlot(1), packet(own), u64::MAX, rig.now);
            let fresh = second * 50..second * 50 + if second == 0 { 40 } else { 3 };
            names.extend(fresh.clone().map(|n| (id(n), n)));
            let entries: Vec<_> = fresh.map(|n| (id(n), 255)).collect();
            rig.announce(link, &entries);
            for step in [last_instant % 1000, 1000 - last_instant % 1000] {
                held_back.extend(rig.wants(link));
                if rig.now >= last_instant {
                    for wanted in std::mem::take(&mut held_back) {
                        rig.deliver(link, &packet(names[&wanted]));
                    }
                }
                rig.run(step);
            }
            let stats = rig.engine.stats();
            if stats.emitted > emitted {
                emitted = stats.emitted;
                assert!(rig.store().is_local(&id(own)), "an emission was refused");
            }
            most = most.max(stats.records);
            assert!(stats.records < capacity, "{} of {capacity}", stats.records);
        }
        assert!(emitted >= 25 && rig.closed.is_empty());
        assert!(
            most >= without_the_wait,
            "at most {most} records: the rate limit was not used in full"
        );
    }

    /// §6.4: two links let the engine ask for all it may and hand nothing
    /// over, announcing the same packets again every five seconds so that
    /// the offers outlive any lifetime, then hand over at once everything
    /// they were ever asked for. All but the requests of the last two
    /// timeouts were given up for good: such a packet closes its link, and
    /// the table gains no more than the rate limit let the engine ask for in
    /// that time.
    #[test]
    fn packets_held_back_and_handed_over_late_do_not_fill_the_record_table() {
        let config = Config {
            life_ms: 2 * MINUTE_MS,
            accept_per_min: 60,
            accept_burst: 30,
            offers_per_link: 120,
            want_timeout_ms: 5000,
            credit_per_min: 600,
            ..quiet()
        };
        let mut rig = Rig::new(config);
        let hoards = [(rig.peer(1), 0..120u64), (rig.peer(2), 200..320)];
        let (mut asked, mut requests) = (BTreeSet::new(), 0);
        for _ in 0..48 {
            for (link, ns) in &hoards {
                let entries: Vec<_> = ns.clone().map(|n| (id(n), 255)).collect();
                rig.announce(*link, &entries);
            }
            rig.run(5000);
            for (link, _) in &hoards {
                let wanted = rig.wants(*link);
                requests += wanted.len();
                asked.extend(wanted);
            }
        }
        assert!(
            requests > 200 && asked.len() > 30,
            "{requests} requests for {} packets",
            asked.len()
        );
        for (link, ns) in &hoards {
            for n in ns.clone().filter(|&n| asked.contains(&id(n))) {
                if rig.peers.contains_key(link) {
                    rig.deliver(*link, &packet(n));
                }
            }
        }
        assert!(rig.closed == vec![hoards[0].0, hoards[1].0]);
        // A request a second for the two timeouts, ten seconds, and the one
        // the tokens' rounding allows.
        assert!(rig.store().records() <= 11);
        assert_eq!(rig.engine.stats().accepted, rig.store().records() as u64);
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
    fn a_request_not_answered_in_time_is_made_of_another_link_and_not_again_of_the_first() {
        let mut rig = Rig::new(trusting());
        let slow = rig.peer(1);
        let other = rig.peer(2);
        rig.announce(slow, &[(id(1), 250)]);
        rig.announce(other, &[(id(1), 250)]);
        assert!(rig.wants(slow) == vec![id(1)] && rig.wants(other).is_empty());

        rig.run(30_000 - TICK);
        assert!(rig.wants(slow).is_empty() && rig.wants(other).is_empty());
        rig.run(TICK);
        assert!(rig.wants(slow).is_empty() && rig.wants(other) == vec![id(1)]);
        // While either may still answer, neither is asked again, whatever
        // it announces.
        rig.announce(slow, &[(id(1), 250)]);
        rig.announce(other, &[(id(1), 250)]);
        rig.run(20_000);
        assert!(rig.wants(slow).is_empty() && rig.wants(other).is_empty());
        rig.deliver(other, &packet(1));
        assert_eq!(rig.engine.stats().accepted, 1);
        assert!(rig.closed.is_empty());
    }

    /// T-LIFE-2: a packet asked of two links, the first given up on, arrives
    /// at most once on each. Only the first copy is stored; the second is
    /// dropped and changes nothing but the count of duplicates; a third was
    /// asked for by nobody. And whatever is announced, no link is asked for a
    /// packet the engine has a record of.
    #[test]
    fn a_late_answer_to_a_request_given_up_is_dropped_and_changes_nothing() {
        let mut rig = Rig::new(trusting());
        let slow = rig.peer(1);
        let other = rig.peer(2);
        let watcher = rig.peer(3);
        rig.announce(slow, &[(id(1), 100)]);
        rig.announce(other, &[(id(1), 200)]);
        rig.run(30_000);
        assert!(rig.wants(slow) == vec![id(1)] && rig.wants(other) == vec![id(1)]);
        rig.deliver(other, &packet(1));
        rig.run(TICK);
        // Told on to the watcher, and to the slow link, which announced less.
        assert_eq!(rig.haves(watcher).len(), 1);
        assert_eq!(rig.haves(slow).len(), 1);
        rig.ask(watcher, &[id(1)]);
        rig.engine.mark_read(id(1), false);
        rig.take(watcher);

        let charged = |rig: &Rig| -> Vec<u64> { rig.engine.live().map(|l| l.charged).collect() };
        let before = (
            rig.engine.stats(),
            rig.store().expires_ms(&id(1)),
            charged(&rig),
        );
        rig.deliver(slow, &packet(1));
        let after = (
            rig.engine.stats(),
            rig.store().expires_ms(&id(1)),
            charged(&rig),
        );
        assert_eq!(after.0.duplicates, 1);
        let counted_once = Stats {
            duplicates: 0,
            ..after.0
        };
        assert!(counted_once == before.0 && after.1 == before.1 && after.2 == before.2);
        assert_eq!(rig.engine.take_unread(9).len(), 1);

        // Nothing is said because of it, and nothing asked, whatever the
        // links announce from then on.
        rig.run(2 * TICK);
        for link in [slow, other, watcher] {
            assert!(rig.take(link).is_empty());
        }
        rig.announce(slow, &[(id(1), 255)]);
        rig.announce(other, &[(id(1), 255)]);
        rig.run(2 * TICK);
        for link in [slow, other, watcher] {
            assert!(rig.wants(link).is_empty());
        }
        assert!(rig.closed.is_empty());
        // A third copy was asked for by nobody.
        rig.send(slow, frame::pkt(&packet(1), 0, size()));
        assert!(rig.closed == vec![slow]);
    }

    /// §6.4: a request is forgotten two timeouts after it was made, however
    /// long the peer says the packet lives and however often it says so. A
    /// millisecond before, the packet is taken; from then on it closes the
    /// link like any packet nobody asked for.
    #[test]
    fn an_answer_two_timeouts_late_was_asked_for_by_nobody() {
        for late in [false, true] {
            let mut rig = Rig::new(Config {
                want_timeout_ms: 7000,
                ..trusting()
            });
            let link = rig.peer(1);
            rig.announce(link, &[(id(1), 255)]);
            assert!(rig.wants(link) == vec![id(1)]);
            for _ in 0..2 {
                rig.run(TICK);
                rig.announce(link, &[(id(1), 255)]);
            }
            rig.run(14_000 - u64::from(!late) - rig.now);
            rig.deliver(link, &packet(1));
            assert!(rig.wants(link).is_empty(), "asked for once");
            assert_eq!(rig.closed.is_empty(), !late);
            assert_eq!(rig.store().has_record(&id(1)), !late);
            assert_eq!(rig.engine.stats().unread, usize::from(!late));
        }
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
    /// and one given up on while waiting is never sent — its packet would
    /// arrive when another link's may have — nor do such requests pile up.
    #[test]
    fn requests_given_up_before_they_were_sent_are_never_sent_and_do_not_pile_up() {
        let mut rig = Rig::new(Config {
            want_window: 2,
            ..trusting()
        });
        let link = rig.dial(2);
        let sealed = rig.seal(link, frame::hello(&[2; 8], size()));
        rig.engine.receive(link, &sealed, 0);
        for round in 0..10u64 {
            let fresh = [(id(2 * round), 250), (id(2 * round + 1), 250)];
            let sealed = rig.seal(link, frame::have(&fresh, size()));
            rig.engine.receive(link, &sealed, rig.now);
            rig.now += 40_000;
            rig.engine.advance(rig.now);
            assert_consistent(&rig.engine);
        }
        // The requests made on the last tick are given up in their turn.
        rig.now += 40_000;
        rig.engine.advance(rig.now);
        rig.pump();
        assert!(rig.wants(link).is_empty());
        assert!(rig.closed.is_empty());
    }

    /// T-LIFE-1 and §3: a frame is built at the time of the poll that hands
    /// it out. A packet asked for in time whose lifetime has run down by the
    /// time the radio layer polls is not sent.
    #[test]
    fn a_packet_that_expires_before_the_radio_layer_polls_is_not_sent() {
        let mut rig = Rig::new(trusting());
        let source = rig.peer(1);
        rig.feed(source, &[1], 250);
        rig.feed(source, &[2], 3);
        let reader = rig.peer(2);
        assert_eq!(rig.haves(reader).len(), 2);
        // Both are claimed now; the engine is told nothing more, and the
        // radio layer comes for the frames two units later.
        let sealed = rig.seal(reader, frame::want(&[id(1), id(2)], size()));
        rig.engine.receive(reader, &sealed, 0);
        rig.now = 2 * UNIT;
        rig.pump();
        assert_eq!(rig.take(reader).len(), 3);
        assert_eq!(rig.engine.stats().sent, 1);
    }

    /// §3: the lifetime a frame announces is the one left when the frame is
    /// polled, not when the engine last heard from anyone.
    #[test]
    fn a_lifetime_is_announced_as_it_stands_when_the_frame_is_polled() {
        let mut rig = Rig::new(trusting());
        let source = rig.peer(1);
        let other = rig.peer(2);
        rig.feed(source, &[1], 200);
        rig.engine.advance(TICK);
        // Polled three units after the tick that made the packet due: one
        // unit and a bit were gone at the tick, four and a bit are now.
        rig.now = TICK + 3 * UNIT;
        rig.pump();
        assert!(rig.haves(other) == vec![(id(1), 200 - 5 - 1)]);
    }

    /// §3: a link that cannot send holds up no other. Its frames are passed
    /// over, and built when it can send, with what is true then.
    #[test]
    fn a_link_that_cannot_send_holds_up_no_other() {
        let mut rig = Rig::new(trusting());
        let source = rig.peer(1);
        let slow = rig.peer(2);
        let fast = rig.peer(3);
        rig.feed(source, &[1, 2], 200);
        rig.take(slow);
        rig.take(fast);
        rig.now = TICK;
        rig.pump_ready(&[fast]);
        let told = rig.haves(fast);
        assert!(told.len() == 2 && told.iter().all(|entry| entry.1 == 197));
        let sealed = rig.seal(fast, frame::want(&[id(1)], size()));
        rig.engine.receive(fast, &sealed, rig.now);
        rig.pump_ready(&[fast]);
        assert_eq!((rig.take(fast).len(), rig.engine.stats().sent), (3, 1));
        assert!(rig.take(slow).is_empty());

        rig.now = TICK + 3 * UNIT;
        rig.pump_ready(&[slow]);
        let told = rig.haves(slow);
        assert!(told.len() == 2 && told.iter().all(|entry| entry.1 == 194));
        assert!(rig.take(fast).is_empty() && rig.closed.is_empty());
    }

    /// A close comes out only after the `BYE` queued for its link, and a
    /// `BYE` for a link the radio layer has lost meanwhile is withdrawn, so
    /// the close does not wait for ever.
    #[test]
    fn a_close_waits_for_its_bye_and_a_lost_link_takes_its_bye_with_it() {
        let mut rig = Rig::new(trusting());
        let first = rig.peer(1);
        let duplicate = |rig: &mut Rig, link: u64| {
            let link = rig.dial(link);
            rig.take(link);
            let sealed = rig.seal(link, frame::hello(&1u64.to_le_bytes(), size()));
            rig.engine.receive(link, &sealed, 0);
            link
        };
        let second = duplicate(&mut rig, 2);
        rig.pump_ready(&[first]);
        assert!(rig.closed.is_empty() && rig.take(second).is_empty());
        rig.pump_ready(&[second]);
        assert!(rig.take(second) == vec![Seen::Bye] && rig.closed == vec![second]);

        let third = duplicate(&mut rig, 3);
        rig.engine.link_down(third, 0);
        rig.pump_ready(&[]);
        assert!(rig.closed == vec![second, third] && rig.take(third).is_empty());
        assert!(rig.engine.output.is_empty());
    }

    /// Requests a link makes faster than its packets go out are not queued
    /// without bound: past the store's size they are dropped, to be made
    /// again.
    #[test]
    fn a_links_send_queue_is_bounded_by_the_store() {
        let mut rig = Rig::new(Config {
            store_packets: 2,
            ..trusting()
        });
        let source = rig.peer(1);
        let reader = rig.peer(2);
        let (a, b, c, d) = (100, 101, 102, 103);
        // Frames go in without anything being taken out, so what the reader
        // is owed stays as the test leaves it.
        let inject = |rig: &mut Rig, link: LinkId, plain: Option<Vec<u8>>| {
            let sealed = rig.seal(link, plain);
            rig.engine.receive(link, &sealed, rig.now);
        };
        let ids = |ns: &[u64]| ns.iter().map(|&n| id(n)).collect::<Vec<PacketId>>();

        // Two short-lived packets, asked for while they have a unit to
        // announce; the transfer of the first starts.
        rig.feed(source, &[a, b], 4);
        rig.run(TICK);
        assert_eq!(rig.haves(reader).len(), 2);
        inject(&mut rig, reader, frame::want(&ids(&[a, b]), size()));
        assert!(rig.step());
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
        // They are announced at the next tick, ahead of the transfer under
        // way, and the reader asks for both at once, behind the one still
        // waiting.
        rig.now += TICK;
        assert!(rig.step());
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

    /// Nothing is built for a link until the radio layer polls: an engine
    /// whose links are slow to send queues no frame for them, however much
    /// it has to say.
    #[test]
    fn nothing_is_built_for_a_link_before_it_is_polled() {
        let mut rig = Rig::new(trusting());
        let source = rig.peer(1);
        let ns: Vec<u64> = (1..=300).collect();
        rig.feed(source, &ns, 250);

        let reader = rig.dial(2);
        let sealed = rig.seal(reader, frame::hello(&[2; 8], size()));
        rig.engine.receive(reader, &sealed, 0);
        assert!(rig.engine.output.is_empty());
        while rig.step() {
            assert!(rig.engine.output.is_empty());
        }
        let told = rig.haves(reader);
        assert_eq!(told.len(), 300);

        let ids: Vec<PacketId> = told.iter().map(|entry| entry.0).collect();
        for batch in ids.chunks(size().want_capacity()) {
            let sealed = rig.seal(reader, frame::want(batch, size()));
            rig.engine.receive(reader, &sealed, 0);
            assert!(rig.engine.output.is_empty());
        }
        let mut frames = 0;
        while rig.step() {
            frames += 1;
            assert!(rig.engine.output.is_empty());
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
        open_incoming(&mut engine, LinkId(1), 0);
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
            // Drawn from the top quarter, less up to ten seconds since,
            // rounded down, less one.
            assert!((188..=253).contains(&engine.store().remaining(&held)));
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
            assert!((191..=254).contains(&about_it[0].1));
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
                open_outgoing(engine, LinkId(peer.0), peer, *now);
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
                open_outgoing(engine, LinkId(peer.0), peer, now);
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
                open_outgoing(&mut engine, LinkId(peer.0), peer, at);
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
                open_outgoing(&mut alone, LinkId(1), peer, at);
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
                open_incoming(&mut engine, LinkId(link), 0);
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
            open_incoming(&mut roomy, LinkId(link), 0);
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

    /// §6.1: a full peer table keeps nobody out. Eight addresses fill it and
    /// are sighted again every round, so none is ever forgotten; an honest
    /// peer is sighted first in each round, the order that leaves it in the
    /// table least often, since each of the up to eight re-entries that
    /// follow puts it out with one chance in eight. With only the random
    /// slot to fill, a round dials it with a chance of at least
    /// (7/8)^8 × 1/8 > 0.043 whatever went before, so it stays undialled for
    /// 400 rounds with a chance under 0.957^400 < 3 in 10^8.
    #[test]
    fn a_full_peer_table_does_not_keep_a_new_peer_out() {
        let config = Config {
            max_peers: 8,
            max_outgoing: 1,
            ..quiet()
        };
        let honest = PeerRef(100);
        for seed in 0..8 {
            let mut engine = engine(config.clone(), seed);
            let flood = |engine: &mut Engine, now: u64| {
                for address in 1..=8 {
                    engine.sighting(PeerRef(address), -30, now);
                }
            };
            flood(&mut engine, 0);
            let mut dialled = false;
            for round in 1..=400 {
                let now = round * TICK;
                engine.sighting(honest, -70, now - TICK);
                flood(&mut engine, now - TICK);
                engine.advance(now);
                for peer in connects(&drain(&mut engine)) {
                    dialled |= peer == honest;
                    engine.connect_failed(peer, now);
                }
                assert_eq!(engine.peers.len(), 8);
            }
            assert!(dialled, "seed {seed}: never dialled");
        }

        // A peer that is linked is not the one forgotten.
        let mut engine = engine(config, 1);
        engine.sighting(honest, -70, 0);
        open_outgoing(&mut engine, LinkId(1), honest, 0);
        for address in 1..=200 {
            engine.sighting(PeerRef(address), -30, 0);
        }
        assert!(engine.peers.contains_key(&honest) && engine.peers.len() == 8);
    }

    /// T-SEC-3: a peer that never answers the handshake, never starts it, or
    /// shakes hands and never greets holds its slot until the connect
    /// timeout from the link coming up, and not a tick longer: the link is
    /// closed then, with no frame, and the engine wakes for it.
    #[test]
    fn a_link_whose_peer_never_greets_is_closed_at_the_deadline() {
        let stalls: [fn(&mut Rig) -> LinkId; 3] = [
            |rig| {
                let link = LinkId(2);
                rig.engine
                    .link_up(link, Role::Central, FRAME, Some(PeerRef(7)), rig.now);
                rig.raw_frame(link);
                link
            },
            |rig| {
                let link = LinkId(2);
                rig.engine
                    .link_up(link, Role::Peripheral, FRAME, None, rig.now);
                link
            },
            |rig| rig.dial(2),
        ];
        for stall in stalls {
            let mut rig = Rig::new(quiet());
            let honest = rig.peer(1);
            // Off the tick's beat: only the deadline itself wakes for it.
            rig.now = 1234;
            let stalled = stall(&mut rig);
            rig.take(honest);
            rig.take(stalled);
            let before = (rig.engine.count(true), rig.engine.count(false));
            let mut closed_at = None;
            while let Some(wake) = rig.engine.next_wake_ms().filter(|&wake| wake <= 60_000) {
                assert!(wake > rig.now, "woken again for the same instant");
                rig.now = wake;
                rig.engine.advance(wake);
                rig.pump();
                closed_at = closed_at.or_else(|| rig.closed.contains(&stalled).then_some(wake));
            }
            assert_eq!(closed_at, Some(1234 + 30_000));
            assert!(rig.closed == vec![stalled] && rig.take(stalled).is_empty());
            let after = (rig.engine.count(true), rig.engine.count(false));
            assert_eq!(
                after.0 + after.1 + 1,
                before.0 + before.1,
                "the slot is free"
            );
            assert_eq!(rig.engine.stats().links, 1, "a peer that greeted stays");
        }
    }

    /// An incoming link greets with `value`; the engine then dials peer 7,
    /// which greets with the same value, so that link is closed as the
    /// second to one phone. Returns the link kept.
    fn shadowed(rig: &mut Rig, value: [u8; 8]) -> LinkId {
        let keeper = rig.dial(1);
        rig.greet(keeper, value);
        let dialled = rig.answer(2, PeerRef(7));
        rig.greet(dialled, value);
        assert!(rig.closed == vec![dialled]);
        keeper
    }

    /// Runs `seconds` with peer 7 in sight, and reports whether it was
    /// dialled.
    fn dials_seven(rig: &mut Rig, seconds: u64) -> bool {
        for _ in 0..seconds {
            rig.engine.sighting(PeerRef(7), -50, rig.now);
            rig.run(1000);
        }
        std::mem::take(&mut rig.connects) == vec![PeerRef(7)]
    }

    /// §6.1: a link that showed a peer's `HELLO` value first stands in for
    /// that peer only while it shows that value. When its value changes the
    /// peer is dialled again — so a neighbour that copied the value once
    /// does not keep the peer away.
    #[test]
    fn a_peer_shadowed_by_another_link_is_dialled_again_when_that_links_value_changes() {
        let mut rig = Rig::new(quiet());
        let keeper = shadowed(&mut rig, [5; 8]);
        // Long past the back-off of the closed link.
        assert!(!dials_seven(&mut rig, 180));
        rig.greet(keeper, [6; 8]);
        assert!(dials_seven(&mut rig, 2 * TICK / 1000));
    }

    /// §6.1: and it stands in for that peer no longer than one turn, however
    /// long it keeps showing the value.
    #[test]
    fn a_peer_shadowed_by_another_link_is_dialled_again_after_a_turn() {
        let mut rig = Rig::new(Config {
            rotate_ms: 5 * MINUTE_MS,
            // The one incoming link is not rotated out meanwhile.
            max_incoming: 2,
            ..quiet()
        });
        shadowed(&mut rig, [5; 8]);
        assert!(!dials_seven(&mut rig, 299));
        assert!(dials_seven(&mut rig, 1 + TICK / 1000));
    }

    /// Why the first link to show a value is kept whatever the two links'
    /// directions and however close together they come up: the second link
    /// of a crossed pair of dials and a neighbour replaying the peer's value
    /// look the same. A rule that sometimes kept the second link — one that
    /// compared the two `HELLO` values, say — would let the replayer close a
    /// link that had just formed. The peer's value is tried on either side
    /// of the engine's own.
    #[test]
    fn a_value_replayed_on_a_second_link_never_closes_the_first_whatever_their_directions() {
        for value in [[0; 8], [0xff; 8]] {
            let mut rig = Rig::new(trusting());
            let real = rig.answer(1, PeerRef(7));
            rig.greet(real, value);
            let replay = rig.dial(2);
            rig.greet(replay, value);
            assert!(rig.closed == vec![replay]);

            let mut rig = Rig::new(trusting());
            let real = rig.dial(1);
            rig.greet(real, value);
            let replay = rig.answer(2, PeerRef(7));
            rig.greet(replay, value);
            assert!(rig.closed == vec![replay]);
        }
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
        // Still owed to the reader: nothing of it may outlive the stop.
        let sealed = rig.seal(other, frame::want(&[id(2), id(3)], size()));
        rig.engine.receive(other, &sealed, rig.now);
        assert!(rig.engine.live().any(|link| !link.sends.is_empty()));
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
        assert!(rig.engine.poll_output(later + 60 * MINUTE_MS).is_none());
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
            let abandoned = count(|state| matches!(state, Ask::Abandoned { .. }));
            assert_eq!(link.expected, asked + abandoned);
            assert!(link.expected <= config.want_window);
            assert!(link.offers.len() <= config.offers_per_link);
            assert!(link.sends.len() <= config.store_packets);
            assert!(link.wants.len() <= config.want_window);
            assert!(link.assembly.len() < PACKET_LEN);
        }
        // A handshake message or a `BYE`, and a close, for each link there
        // can be, and one connect: every other frame is built when polled.
        assert!(engine.output.len() <= 2 * engine.links.len() + 1);
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
            // One connect, and a close for each link, whose peer never
            // greeted.
            assert!(engine.output.len() <= 5);
        }
        assert_consistent(&engine);
        assert_eq!(connects(&drain(&mut engine)).len(), 1);
    }

    // ---- waking -----------------------------------------------------------

    /// Everything one engine does over ten minutes when it is advanced at its
    /// wake times and at `extra` times besides: with a link that is asked for
    /// packets and never delivers, a second that announced the same ones, a
    /// third whose peer never greets, peers in sight that never answer, an
    /// outbox, and a `HELLO` period off the tick's beat.
    fn wake_trace(extra: &[u64]) -> Vec<(u64, u64, Vec<u64>)> {
        let mut rig = Rig::new(Config {
            hello_period_ms: 241_700,
            ..Config::default()
        });
        let links = [rig.peer(1), rig.peer(2)];
        let entries: Vec<_> = (1..=5).map(|n| (id(n), 250)).collect();
        for link in links {
            rig.announce(link, &entries);
            rig.take(link);
        }
        for peer in 1..=3 {
            rig.engine.sighting(PeerRef(peer), -50, 0);
        }
        rig.engine.offer(CircleSlot(1), packet(9), u64::MAX, 0);
        // Off the tick's beat, so that only its own deadline wakes for it.
        rig.now = 1234;
        rig.dial(3);

        let mut extra = extra.iter().copied().peekable();
        let mut trace = Vec::new();
        while let Some(wake) = rig.engine.next_wake_ms().filter(|&wake| wake <= 600_000) {
            assert!(wake > rig.now, "woken again for the same instant");
            while let Some(early) = extra.next_if(|&early| early < wake) {
                rig.engine.advance(early);
                assert!(
                    rig.engine.poll_output(early).is_none(),
                    "work was due before the wake"
                );
                assert_eq!(rig.engine.next_wake_ms(), Some(wake));
            }
            rig.now = wake;
            rig.engine.advance(wake);
            rig.pump();
            let emitted = rig.engine.stats().emitted;
            for (link, seen) in std::mem::take(&mut rig.seen) {
                let kind = match seen {
                    Seen::Hello(_) => 1,
                    Seen::Have(entries) => 20 + entries.len() as u64,
                    Seen::Want(ids) => 40 + ids.len() as u64,
                    Seen::Pkt(..) => 3,
                    Seen::Bye => 4,
                };
                trace.push((wake, emitted, vec![kind, link.0]));
            }
            for link in std::mem::take(&mut rig.closed) {
                trace.push((wake, emitted, vec![5, link.0]));
            }
            for peer in std::mem::take(&mut rig.connects) {
                trace.push((wake, emitted, vec![100, peer.0]));
            }
            for peer in 1..=3 {
                rig.engine.sighting(PeerRef(peer), -50, wake);
            }
        }
        trace
    }

    #[test]
    fn the_wake_trace_covers_requests_dials_stalls_and_emissions() {
        let trace = wake_trace(&[]);
        let of = |named: &[u64]| -> Vec<u64> {
            let entries = trace.iter().filter(|entry| entry.2.starts_with(named));
            entries.map(|entry| entry.0).collect()
        };
        assert!(
            of(&[45, 2]) == vec![30_000],
            "the request given up is made of the other link"
        );
        assert!(
            of(&[5, 3]) == vec![31_234],
            "the link that never greeted is closed at its deadline"
        );
        // Each interval between half the period and one and a half.
        let greetings = of(&[1, 1]);
        let mut lasted = std::iter::once(&0).chain(&greetings).zip(&greetings);
        assert!(
            !greetings.is_empty()
                && lasted.all(|(from, to)| (120_850..=362_550).contains(&(to - from))),
            "the greeting is renewed when its interval ends"
        );
        assert!(
            of(&[100]).len() >= 4,
            "peers are dialled again after their back-off"
        );
        assert!(of(&[21]).len() >= 3, "emitted packets are announced");
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
