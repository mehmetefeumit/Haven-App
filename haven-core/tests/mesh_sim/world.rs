//! The virtual radio `mesh_sim` runs on: real [`MeshEngine`]s and scripted
//! strangers joined by wires, on one logical clock.
//!
//! The world knows an engine only through its public calls. It carries bytes,
//! tells the time, and writes down what it sees from outside: every frame that
//! crosses a wire (the journal), every packet a phone emits, and every packet
//! a phone's reader takes.
//!
//! Runs are reproducible to the byte: every generator is seeded, time is a
//! number, and whatever is due at one instant runs in a fixed order — carried
//! frames and other events in the order they were scheduled, then phones'
//! timers in node order.
//!
//! A wire with a byte rate sends one frame at a time. The world is a radio
//! layer that knows it: it asks an engine for a frame for such a wire only
//! when the wire's sender is free, so the frame is built then and no other
//! wire waits for it.

use std::collections::{BTreeMap, BTreeSet};

use haven_core::mesh::engine::{Config, LinkId, MeshEngine, Output, PeerRef, Role};
use haven_core::mesh::frame::{self, Frame, FrameSize};
use haven_core::mesh::noise::{self, Initiator, Transport};
use haven_core::mesh::packet::{self, EventParts, MeshKey, Packet, PacketId, PACKET_LEN};
use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};

pub type Engine = MeshEngine<StdRng>;

/// A phone or a stranger, by the order it joined.
pub type Node = usize;

/// One connection between two nodes.
pub type Wire = u64;

/// What a wire does to the frames on it.
#[derive(Clone, Copy)]
pub struct Radio {
    /// Length of every sealed frame.
    pub max_frame: usize,
    /// Time in the air, after the frame's last byte left.
    pub delay_ms: u64,
    /// Throughput per direction; zero for no cap.
    pub bytes_per_s: u64,
}

impl Radio {
    /// No delay and no cap: a frame arrives the instant it is sent.
    pub const fn instant(max_frame: usize) -> Self {
        Self {
            max_frame,
            delay_ms: 0,
            bytes_per_s: 0,
        }
    }
}

/// What a wire does once to a sealed frame from one side.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Fault {
    /// The frame never arrives.
    Drop,
    /// The frame arrives twice.
    Replay,
    /// The frame arrives after the one sent next.
    Swap,
    /// The frame arrives with one bit changed.
    Flip,
}

/// Who reads the packets a phone accepts: its session code, played by the
/// world.
pub enum Reader {
    /// Nobody: the app is not running.
    Absent,
    /// Session code that holds no key any packet opens under.
    Keyless,
    /// Session code holding these circle keys.
    Member(Vec<MeshKey>),
}

/// A packet a phone put into its own store in an emission slot.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Emission {
    pub at_ms: u64,
    pub id: PacketId,
    /// The lifetime it started with, as the store reports it.
    pub expires_ms: u64,
}

/// A packet a phone's reader took from the unread queue.
#[derive(Clone, PartialEq, Eq)]
pub struct Taken {
    pub at_ms: u64,
    pub id: PacketId,
    pub packet: Packet,
    /// What it opened to, under one of the reader's keys.
    pub opened: Option<EventParts>,
}

/// One real engine and what the world saw it do.
pub struct Phone {
    pub engine: Engine,
    config: Config,
    pub reader: Reader,
    asleep: bool,
    /// Links that went away while it slept: told on waking.
    lost: Vec<LinkId>,
    emitted_seen: u64,
    own: BTreeSet<PacketId>,
    pub emissions: Vec<Emission>,
    pub taken: Vec<Taken>,
    /// When it was started afresh, with nothing stored.
    pub restarts: Vec<u64>,
}

/// A frame a stranger opened.
#[derive(Clone, PartialEq, Eq)]
pub enum Seen {
    Hello([u8; 8]),
    Have(Vec<(PacketId, u8)>),
    Want(Vec<PacketId>),
    Pkt(u8, Vec<u8>),
    Bye,
}

#[derive(Clone, PartialEq, Eq)]
pub struct Heard {
    pub at_ms: u64,
    pub wire: Wire,
    pub frame: Seen,
    /// The frame as it crossed the wire.
    pub sealed: Vec<u8>,
    /// What it opened to.
    pub plain: Vec<u8>,
}

enum Shake {
    Dialling(Initiator),
    Waiting,
    Open(Transport),
    Broken,
}

struct Session {
    size: FrameSize,
    shake: Shake,
    assembly: Vec<u8>,
    asked: BTreeSet<PacketId>,
}

/// A scripted peer: not an engine. It speaks the link protocol with the
/// crate's public `noise` and `frame` functions, does what its switches say
/// on its own, and whatever else the test tells it through the [`World`].
pub struct Stranger {
    rng: StdRng,
    sessions: BTreeMap<Wire, Session>,
    /// Sent as `HELLO` as soon as a link's handshake is done.
    pub greeting: Option<[u8; 8]>,
    /// Greets each link with a value of its own, so the links do not look
    /// like two to one phone.
    pub fresh_greetings: bool,
    /// Asks for every packet announced to it.
    pub want_all: bool,
    /// Hands these over when asked for them.
    pub serve: BTreeMap<PacketId, Packet>,
    /// Takes a phone's connect.
    pub listens: bool,
    /// Every frame it opened, in order.
    pub heard: Vec<Heard>,
    /// Every packet it was sent in full.
    pub got: Vec<(u64, Wire, Packet)>,
    /// Frames that did not open or parse.
    pub garbled: usize,
}

impl Stranger {
    /// The entries of every `HAVE` it heard: when, on which wire, which
    /// packet, with how many units.
    pub fn haves(&self) -> Vec<(u64, Wire, PacketId, u8)> {
        let mut entries = Vec::new();
        for heard in &self.heard {
            if let Seen::Have(had) = &heard.frame {
                entries.extend(
                    had.iter()
                        .map(|&(id, units)| (heard.at_ms, heard.wire, id, units)),
                );
            }
        }
        entries
    }

    /// The ids of every `WANT` it heard.
    pub fn wants(&self) -> Vec<(u64, Wire, PacketId)> {
        let mut ids = Vec::new();
        for heard in &self.heard {
            if let Seen::Want(wanted) = &heard.frame {
                ids.extend(wanted.iter().map(|&id| (heard.at_ms, heard.wire, id)));
            }
        }
        ids
    }

    /// When it was first told of `id`, and with how many units.
    pub fn first_have(&self, id: PacketId) -> Option<(u64, u8)> {
        self.haves()
            .into_iter()
            .find(|entry| entry.2 == id)
            .map(|(at_ms, _, _, units)| (at_ms, units))
    }

    /// When it had `id` in full.
    pub fn got_at(&self, id: PacketId) -> Option<u64> {
        self.got
            .iter()
            .find(|(_, _, packet)| packet.id() == id)
            .map(|&(at_ms, _, _)| at_ms)
    }

    fn seal(&mut self, wire: Wire, plain: Option<Vec<u8>>) -> Vec<u8> {
        let session = self.sessions.get_mut(&wire).expect("a link to speak on");
        let Shake::Open(transport) = &mut session.shake else {
            panic!("the stranger's handshake is not done");
        };
        transport
            .seal(&plain.expect("the frame encodes"))
            .expect("the frame seals")
    }

    /// One frame arrived: what to send back.
    fn hear(&mut self, wire: Wire, bytes: &[u8], now: u64) -> Vec<Vec<u8>> {
        let Some(session) = self.sessions.get_mut(&wire) else {
            return Vec::new();
        };
        let mut replies = Vec::new();
        let size = session.size;
        match std::mem::replace(&mut session.shake, Shake::Broken) {
            Shake::Dialling(initiator) => {
                if let Some(transport) = initiator.finish(bytes) {
                    session.shake = Shake::Open(transport);
                }
            }
            Shake::Waiting => {
                if let Some((transport, reply)) = noise::respond(bytes, &mut self.rng) {
                    session.shake = Shake::Open(transport);
                    replies.push(reply.to_vec());
                }
            }
            Shake::Open(mut transport) => {
                let plain = transport.open(bytes);
                session.shake = Shake::Open(transport);
                let Some(plain) = plain else {
                    self.garbled += 1;
                    return replies;
                };
                let Some(frame) = frame::decode(&plain) else {
                    self.garbled += 1;
                    return replies;
                };
                let seen = match frame {
                    Frame::Hello(value) => Seen::Hello(value),
                    Frame::Have(entries) => Seen::Have(entries.iter().collect()),
                    Frame::Want(ids) => Seen::Want(ids.iter().collect()),
                    Frame::Pkt { index, chunk } => Seen::Pkt(index, chunk.to_vec()),
                    Frame::Bye => Seen::Bye,
                };
                let plains = self.react(wire, &seen, now);
                self.heard.push(Heard {
                    at_ms: now,
                    wire,
                    frame: seen,
                    sealed: bytes.to_vec(),
                    plain,
                });
                for plain in plains {
                    replies.push(self.seal(wire, Some(plain)));
                }
                return replies;
            }
            Shake::Broken => {}
        }
        // The handshake just finished on this frame, or failed.
        let open = self
            .sessions
            .get(&wire)
            .is_some_and(|session| matches!(session.shake, Shake::Open(_)));
        if let (true, Some(value)) = (open, self.greeting) {
            let value = if self.fresh_greetings {
                self.rng.gen()
            } else {
                value
            };
            replies.push(self.seal(wire, frame::hello(&value, size)));
        }
        replies
    }

    /// What its switches make of one frame: plaintexts to send back.
    fn react(&mut self, wire: Wire, seen: &Seen, now: u64) -> Vec<Vec<u8>> {
        let Some(session) = self.sessions.get_mut(&wire) else {
            return Vec::new();
        };
        let size = session.size;
        let mut plains = Vec::new();
        match seen {
            Seen::Have(entries) if self.want_all => {
                let fresh: Vec<PacketId> = entries
                    .iter()
                    .map(|&(id, _)| id)
                    .filter(|id| session.asked.insert(*id))
                    .collect();
                for batch in fresh.chunks(size.want_capacity()) {
                    plains.extend(frame::want(batch, size));
                }
            }
            Seen::Want(ids) => {
                for id in ids {
                    if let Some(packet) = self.serve.get(id) {
                        plains.extend(chunks(packet, size));
                    }
                }
            }
            Seen::Pkt(_, chunk) => {
                session.assembly.extend_from_slice(chunk);
                if session.assembly.len() >= PACKET_LEN {
                    let whole = std::mem::take(&mut session.assembly);
                    if let Ok(bytes) = <[u8; PACKET_LEN]>::try_from(whole) {
                        self.got.push((now, wire, Packet::from_bytes(bytes)));
                    }
                }
            }
            _ => {}
        }
        plains
    }
}

/// Every `PKT` plaintext of `packet` on a link of `size`, in order.
pub fn chunks(packet: &Packet, size: FrameSize) -> Vec<Vec<u8>> {
    (0..size.chunk_count())
        .map(|index| {
            let index = u8::try_from(index).expect("few chunks");
            frame::pkt(packet, index, size).expect("the chunk encodes")
        })
        .collect()
}

enum Slot {
    Phone(Box<Phone>),
    Stranger(Box<Stranger>),
}

struct End {
    node: Node,
    link: LinkId,
    open: bool,
    /// When this side's sender is free again.
    busy_ms: u64,
    /// When the last frame this side sent arrives.
    arrives_ms: u64,
    /// A fault waiting for a sealed frame from this side, after letting this
    /// many pass.
    fault: Option<(Fault, usize)>,
    /// A frame [`Fault::Swap`] is holding back.
    held: Option<Vec<u8>>,
}

struct Line {
    radio: Radio,
    /// The central first.
    ends: [End; 2],
}

/// One frame on a wire, as a listener beside it would record it.
#[derive(Clone, PartialEq, Eq)]
pub struct Crossing {
    pub sent_ms: u64,
    pub arrives_ms: u64,
    pub wire: Wire,
    pub from: Node,
    pub to: Node,
    pub bytes: Vec<u8>,
}

/// A wire that came down: when, and which node asked for it — `None` for the
/// world itself.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Closed {
    pub at_ms: u64,
    pub wire: Wire,
    pub by: Option<Node>,
}

enum Event {
    Deliver {
        wire: Wire,
        to: usize,
        bytes: Vec<u8>,
    },
    Hangup {
        wire: Wire,
    },
    Scan {
        node: Node,
    },
    /// The connect the engine at `from` asked for, in its `era`, is over.
    Dialled {
        from: Node,
        era: usize,
        addr: u64,
    },
    /// A wire of `node` with a byte rate has sent its frame.
    Ready {
        node: Node,
    },
    Chaos,
}

pub struct World {
    pub now: u64,
    seq: u64,
    nodes: Vec<Slot>,
    /// What each node advertises as; a restart draws a new one.
    addr: Vec<u64>,
    by_addr: BTreeMap<u64, Node>,
    next_id: u64,
    wires: BTreeMap<Wire, Line>,
    ends: BTreeMap<(Node, u64), (Wire, usize)>,
    events: BTreeMap<(u64, u64), Event>,
    wakes: BTreeSet<(u64, Node)>,
    wake_of: Vec<Option<u64>>,
    /// Who sees whom advertising, and how strongly.
    range: BTreeMap<(Node, Node), i8>,
    scan_ms: Option<u64>,
    /// How long a connect the engine asked for takes.
    pub connect_ms: u64,
    /// The wire two nodes get when an engine chose the link.
    pub radio: Radio,
    chaos: Option<(StdRng, u64)>,
    /// Whether the journal keeps frame bytes, or their length only.
    pub keep_bytes: bool,
    pub journal: Vec<Crossing>,
    pub closed: Vec<Closed>,
    /// Every wire there ever was: its central, its peripheral, its radio.
    pub wire_log: BTreeMap<Wire, (Node, Node, Radio)>,
}

impl World {
    pub const fn new() -> Self {
        Self {
            now: 0,
            seq: 0,
            nodes: Vec::new(),
            addr: Vec::new(),
            by_addr: BTreeMap::new(),
            next_id: 1,
            wires: BTreeMap::new(),
            ends: BTreeMap::new(),
            events: BTreeMap::new(),
            wakes: BTreeSet::new(),
            wake_of: Vec::new(),
            range: BTreeMap::new(),
            scan_ms: None,
            connect_ms: 200,
            radio: Radio::instant(512),
            chaos: None,
            keep_bytes: true,
            journal: Vec::new(),
            closed: Vec::new(),
            wire_log: BTreeMap::new(),
        }
    }

    const fn fresh_id(&mut self) -> u64 {
        self.next_id += 1;
        self.next_id
    }

    fn join(&mut self, slot: Slot) -> Node {
        let node = self.nodes.len();
        let addr = self.fresh_id();
        self.nodes.push(slot);
        self.addr.push(addr);
        self.by_addr.insert(addr, node);
        self.wake_of.push(None);
        node
    }

    // ---- nodes -------------------------------------------------------------

    /// A phone arrives, started now with nothing stored.
    pub fn phone(&mut self, config: Config, seed: u64, reader: Reader) -> Node {
        let engine = MeshEngine::new(config.clone(), StdRng::seed_from_u64(seed), self.now);
        let node = self.join(Slot::Phone(Box::new(Phone {
            engine,
            config,
            reader,
            asleep: false,
            lost: Vec::new(),
            emitted_seen: 0,
            own: BTreeSet::new(),
            emissions: Vec::new(),
            taken: Vec::new(),
            restarts: Vec::new(),
        })));
        self.first_scan(node);
        self.after(node);
        node
    }

    /// A stranger arrives: it greets, and does nothing else unasked.
    pub fn stranger(&mut self, seed: u64) -> Node {
        let mut rng = StdRng::seed_from_u64(seed);
        let greeting = Some(rng.gen());
        self.join(Slot::Stranger(Box::new(Stranger {
            rng,
            sessions: BTreeMap::new(),
            greeting,
            fresh_greetings: false,
            want_all: false,
            serve: BTreeMap::new(),
            listens: true,
            heard: Vec::new(),
            got: Vec::new(),
            garbled: 0,
        })))
    }

    pub fn at(&self, node: Node) -> &Phone {
        match self.nodes.get(node) {
            Some(Slot::Phone(phone)) => phone,
            _ => panic!("not a phone"),
        }
    }

    fn phone_mut(&mut self, node: Node) -> &mut Phone {
        match self.nodes.get_mut(node) {
            Some(Slot::Phone(phone)) => phone,
            _ => panic!("not a phone"),
        }
    }

    pub fn engine(&self, node: Node) -> &Engine {
        &self.at(node).engine
    }

    /// The engine with its clock at now: what its accessors report is as of
    /// the engine's last input.
    pub fn settled(&mut self, node: Node) -> &Engine {
        self.drive(node, Engine::advance);
        self.engine(node)
    }

    /// Calls into a phone's engine as its session code does, asleep or
    /// awake: nothing of the radio layer's follows the call.
    pub fn session<T>(&mut self, node: Node, call: impl FnOnce(&mut Engine) -> T) -> T {
        call(&mut self.phone_mut(node).engine)
    }

    /// Calls into a phone's engine, then carries out whatever the engine
    /// wants done, as the radio layer does after a call of its own.
    pub fn drive<T>(&mut self, node: Node, call: impl FnOnce(&mut Engine, u64) -> T) -> T {
        let now = self.now;
        let result = call(&mut self.phone_mut(node).engine, now);
        self.after(node);
        result
    }

    pub fn set_reader(&mut self, node: Node, reader: Reader) {
        self.phone_mut(node).reader = reader;
        self.after(node);
    }

    pub fn them(&self, node: Node) -> &Stranger {
        match self.nodes.get(node) {
            Some(Slot::Stranger(stranger)) => stranger,
            _ => panic!("not a stranger"),
        }
    }

    pub fn them_mut(&mut self, node: Node) -> &mut Stranger {
        match self.nodes.get_mut(node) {
            Some(Slot::Stranger(stranger)) => stranger,
            _ => panic!("not a stranger"),
        }
    }

    pub fn phones(&self) -> Vec<Node> {
        (0..self.nodes.len())
            .filter(|&node| matches!(self.nodes.get(node), Some(Slot::Phone(_))))
            .collect()
    }

    /// Whether a phone could be found and connected to now.
    fn on_air(&self, node: Node) -> bool {
        match self.nodes.get(node) {
            Some(Slot::Phone(phone)) => !phone.asleep && phone.engine.next_wake_ms().is_some(),
            Some(Slot::Stranger(stranger)) => stranger.listens,
            None => false,
        }
    }

    /// The phone's processor stops: it takes no input until [`Self::wake`],
    /// and its links are gone by then.
    pub fn sleep(&mut self, node: Node) {
        self.sever(node);
        self.phone_mut(node).asleep = true;
        self.refresh(node);
    }

    /// The phone runs again, its clock having jumped to now.
    pub fn wake(&mut self, node: Node) {
        let now = self.now;
        let phone = self.phone_mut(node);
        phone.asleep = false;
        for link in std::mem::take(&mut phone.lost) {
            phone.engine.link_down(link, now);
        }
        phone.engine.advance(now);
        self.after(node);
    }

    /// The phone's process dies and starts again: a new engine with nothing
    /// stored and a new address.
    pub fn restart(&mut self, node: Node, seed: u64) {
        self.sever(node);
        let now = self.now;
        let phone = self.phone_mut(node);
        phone.engine = MeshEngine::new(phone.config.clone(), StdRng::seed_from_u64(seed), now);
        phone.lost.clear();
        phone.asleep = false;
        phone.emitted_seen = 0;
        phone.own.clear();
        phone.restarts.push(now);
        let addr = self.fresh_id();
        if let Some(old) = self.addr.get_mut(node) {
            self.by_addr.remove(old);
            *old = addr;
        }
        self.by_addr.insert(addr, node);
        self.after(node);
    }

    /// Mesh off.
    pub fn stop(&mut self, node: Node) {
        self.phone_mut(node).engine.stop();
        self.after(node);
    }

    // ---- wires -------------------------------------------------------------

    /// `central` connects to `peripheral`.
    pub fn link(&mut self, central: Node, peripheral: Node, radio: Radio) -> Wire {
        let wire = self.fresh_id();
        let end = |node, link| End {
            node,
            link: LinkId(link),
            open: true,
            busy_ms: 0,
            arrives_ms: 0,
            fault: None,
            held: None,
        };
        let (near, far) = (self.fresh_id(), self.fresh_id());
        self.wire_log.insert(wire, (central, peripheral, radio));
        self.wires.insert(
            wire,
            Line {
                radio,
                ends: [end(central, near), end(peripheral, far)],
            },
        );
        self.ends.insert((central, near), (wire, 0));
        self.ends.insert((peripheral, far), (wire, 1));
        self.up(wire, 0);
        self.up(wire, 1);
        self.after(central);
        self.after(peripheral);
        wire
    }

    fn up(&mut self, wire: Wire, side: usize) {
        let now = self.now;
        let Some(wired) = self.wires.get(&wire) else {
            return;
        };
        let (Some(end), Some(other)) = (wired.ends.get(side), wired.ends.get(1 - side)) else {
            return;
        };
        let (node, link, max_frame) = (end.node, end.link, wired.radio.max_frame);
        // Only the side that connected knows whom it reached: a central's own
        // address is not the one it advertises under.
        let peer = self.addr.get(other.node).map(|&addr| PeerRef(addr));
        let hello = match self.nodes.get_mut(node) {
            Some(Slot::Phone(phone)) => {
                let (role, peer) = if side == 0 {
                    (Role::Central, peer)
                } else {
                    (Role::Peripheral, None)
                };
                phone.engine.link_up(link, role, max_frame, peer, now);
                None
            }
            Some(Slot::Stranger(stranger)) => {
                let frames = FrameSize::of_link(max_frame).expect("a frame size a link may have");
                let (shake, hello) = if side == 0 {
                    let (initiator, hello) = Initiator::start(&mut stranger.rng);
                    (Shake::Dialling(initiator), Some(hello.to_vec()))
                } else {
                    (Shake::Waiting, None)
                };
                stranger.sessions.insert(
                    wire,
                    Session {
                        size: frames,
                        shake,
                        assembly: Vec::new(),
                        asked: BTreeSet::new(),
                    },
                );
                hello
            }
            None => None,
        };
        if let Some(hello) = hello {
            self.transmit(wire, side, hello);
        }
    }

    /// The wires `node` is an open end of.
    pub fn wires_of(&self, node: Node) -> Vec<Wire> {
        self.wires
            .iter()
            .filter(|(_, line)| line.ends.iter().any(|end| end.node == node && end.open))
            .map(|(&wire, _)| wire)
            .collect()
    }

    /// The nodes `node` has an open wire to, in node order.
    pub fn neighbours(&self, node: Node) -> BTreeSet<Node> {
        let mut found = BTreeSet::new();
        for line in self.wires.values() {
            let [a, b] = &line.ends;
            if a.open && b.open && (a.node == node || b.node == node) {
                found.insert(if a.node == node { b.node } else { a.node });
            }
        }
        found
    }

    pub fn is_up(&self, wire: Wire) -> bool {
        self.wires
            .get(&wire)
            .is_some_and(|line| line.ends.iter().all(|end| end.open))
    }

    pub fn frame_size(&self, wire: Wire) -> FrameSize {
        let line = self.wires.get(&wire).expect("a live wire");
        FrameSize::of_link(line.radio.max_frame).expect("a frame size a link may have")
    }

    fn side_of(&self, wire: Wire, node: Node) -> Option<usize> {
        self.wires
            .get(&wire)?
            .ends
            .iter()
            .position(|end| end.node == node && end.open)
    }

    /// The radio loses `wire`: both ends are told, and what was in the air is
    /// gone.
    pub fn cut(&mut self, wire: Wire) {
        self.closed.push(Closed {
            at_ms: self.now,
            wire,
            by: None,
        });
        self.hang_up(wire);
    }

    fn hang_up(&mut self, wire: Wire) {
        let now = self.now;
        let Some(line) = self.wires.remove(&wire) else {
            return;
        };
        for end in line.ends.iter().filter(|end| end.open) {
            self.ends.remove(&(end.node, end.link.0));
            match self.nodes.get_mut(end.node) {
                Some(Slot::Phone(phone)) if phone.asleep => phone.lost.push(end.link),
                Some(Slot::Phone(phone)) => phone.engine.link_down(end.link, now),
                Some(Slot::Stranger(stranger)) => {
                    stranger.sessions.remove(&wire);
                }
                None => {}
            }
            self.after(end.node);
        }
    }

    /// Every wire of `node` goes, without `node` being told yet.
    fn sever(&mut self, node: Node) {
        for wire in self.wires_of(node) {
            if let Some(side) = self.side_of(wire, node) {
                let ends = self.wires.get_mut(&wire).map(|line| &mut line.ends);
                if let Some(end) = ends.and_then(|ends| ends.get_mut(side)) {
                    end.open = false;
                    let link = end.link;
                    self.ends.remove(&(node, link.0));
                    self.phone_mut(node).lost.push(link);
                }
            }
            self.cut(wire);
        }
    }

    /// The engine at `node` asked for `link` to be disconnected: what it had
    /// already sent still arrives, then the other end is told.
    fn close(&mut self, node: Node, link: LinkId) {
        let Some((wire, side)) = self.ends.remove(&(node, link.0)) else {
            return;
        };
        self.closed.push(Closed {
            at_ms: self.now,
            wire,
            by: Some(node),
        });
        let Some(wired) = self.wires.get_mut(&wire) else {
            return;
        };
        let Some(end) = wired.ends.get_mut(side) else {
            return;
        };
        end.open = false;
        let at = end.arrives_ms.max(self.now);
        self.schedule(at, Event::Hangup { wire });
    }

    /// Arms one fault on the sealed frames `from` sends on `wire`, after
    /// letting `after` of them pass.
    pub fn tamper(&mut self, wire: Wire, from: Node, fault: Fault, after: usize) {
        let side = self.side_of(wire, from).expect("an end of that wire");
        let ends = self.wires.get_mut(&wire).map(|line| &mut line.ends);
        if let Some(end) = ends.and_then(|ends| ends.get_mut(side)) {
            end.fault = Some((fault, after));
        }
    }

    /// Puts one frame from `side` on `wire`, through whatever fault is armed.
    fn transmit(&mut self, wire: Wire, side: usize, bytes: Vec<u8>) {
        let Some(line) = self.wires.get_mut(&wire) else {
            return;
        };
        let sealed = bytes.len() == line.radio.max_frame;
        let Some(end) = line.ends.get_mut(side) else {
            return;
        };
        let mut out = Vec::new();
        if let Some(held) = end.held.take() {
            out.extend([bytes, held]);
        } else {
            match end.fault {
                Some((fault, 0)) if sealed => {
                    end.fault = None;
                    match fault {
                        Fault::Drop => {}
                        Fault::Replay => out.extend([bytes.clone(), bytes]),
                        Fault::Swap => end.held = Some(bytes),
                        Fault::Flip => {
                            let mut bytes = bytes;
                            if let Some(byte) = bytes.get_mut(7) {
                                *byte ^= 0x10;
                            }
                            out.push(bytes);
                        }
                    }
                }
                Some((fault, left)) if sealed => {
                    end.fault = Some((fault, left - 1));
                    out.push(bytes);
                }
                _ => out.push(bytes),
            }
        }
        for bytes in out {
            self.put(wire, side, bytes);
        }
    }

    fn put(&mut self, wire: Wire, side: usize, bytes: Vec<u8>) {
        let now = self.now;
        let Some(line) = self.wires.get_mut(&wire) else {
            return;
        };
        let radio = line.radio;
        let (from, to) = match &mut line.ends {
            [a, b] if side == 0 => (a, b.node),
            [a, b] => (b, a.node),
        };
        let length = u64::try_from(bytes.len()).expect("a frame's length");
        let airtime = if radio.bytes_per_s == 0 {
            0
        } else {
            (length * 1000).div_ceil(radio.bytes_per_s)
        };
        from.busy_ms = from.busy_ms.max(now) + airtime;
        from.arrives_ms = from.busy_ms + radio.delay_ms;
        let crossing = Crossing {
            sent_ms: now,
            arrives_ms: from.arrives_ms,
            wire,
            from: from.node,
            to,
            bytes: if self.keep_bytes {
                bytes.clone()
            } else {
                // The length alone, for the size and timing checks.
                vec![0; bytes.len()]
            },
        };
        let (at, free_ms, node) = (from.arrives_ms, from.busy_ms, from.node);
        self.journal.push(crossing);
        self.schedule(
            at,
            Event::Deliver {
                wire,
                to: 1 - side,
                bytes,
            },
        );
        if free_ms > now {
            self.schedule(free_ms, Event::Ready { node });
        }
    }

    // ---- what a stranger does ----------------------------------------------

    /// The stranger `who` connects to `to`.
    pub fn dial(&mut self, who: Node, to: Node, radio: Radio) -> Wire {
        assert!(matches!(self.nodes.get(who), Some(Slot::Stranger(_))));
        self.link(who, to, radio)
    }

    /// The stranger sends one frame: `plain` sealed for `wire`.
    pub fn say(&mut self, who: Node, wire: Wire, plain: Option<Vec<u8>>) {
        let sealed = self.them_mut(who).seal(wire, plain);
        self.say_raw(who, wire, sealed);
    }

    /// The stranger sends `bytes` as they are.
    pub fn say_raw(&mut self, who: Node, wire: Wire, bytes: Vec<u8>) {
        if let Some(side) = self.side_of(wire, who) {
            self.transmit(wire, side, bytes);
        }
    }

    pub fn announce(&mut self, who: Node, wire: Wire, entries: &[(PacketId, u8)]) {
        let size = self.frame_size(wire);
        for batch in entries.chunks(size.have_capacity()) {
            self.say(who, wire, frame::have(batch, size));
        }
    }

    pub fn ask(&mut self, who: Node, wire: Wire, ids: &[PacketId]) {
        let size = self.frame_size(wire);
        for batch in ids.chunks(size.want_capacity()) {
            self.say(who, wire, frame::want(batch, size));
        }
    }

    /// The stranger sends `packet` whole, whether or not it was asked for.
    pub fn hand(&mut self, who: Node, wire: Wire, packet: &Packet) {
        for plain in chunks(packet, self.frame_size(wire)) {
            self.say(who, wire, Some(plain));
        }
    }

    // ---- the air -----------------------------------------------------------

    /// `a` and `b` see each other advertising at `rssi` dBm.
    pub fn in_range(&mut self, a: Node, b: Node, rssi: i8) {
        self.range.insert((a, b), rssi);
        self.range.insert((b, a), rssi);
    }

    pub fn out_of_range(&mut self, a: Node, b: Node) {
        self.range.remove(&(a, b));
        self.range.remove(&(b, a));
    }

    /// `a` and `b` lose sight of each other and every wire between them.
    pub fn part(&mut self, a: Node, b: Node) {
        self.out_of_range(a, b);
        let between: Vec<Wire> = self
            .wires
            .iter()
            .filter(|(_, line)| {
                let [x, y] = &line.ends;
                (x.node, y.node) == (a, b) || (x.node, y.node) == (b, a)
            })
            .map(|(&wire, _)| wire)
            .collect();
        for wire in between {
            self.cut(wire);
        }
    }

    /// Every phone scans every `every_ms` from now on, each at its own phase
    /// as phones do, and is told whom it sees; the engines choose their own
    /// links from that.
    pub fn scan(&mut self, every_ms: u64) {
        let first = self.scan_ms.is_none();
        self.scan_ms = Some(every_ms);
        if first {
            for node in self.phones() {
                self.first_scan(node);
            }
        }
    }

    fn first_scan(&mut self, node: Node) {
        if let Some(every) = self.scan_ms {
            let phase = u64::try_from(node).expect("a node number") * 1237 % every;
            self.schedule(self.now + phase, Event::Scan { node });
        }
    }

    /// From now on a wire picked with the seeded generator is cut every
    /// `mean_ms` on average.
    pub fn chaos(&mut self, seed: u64, mean_ms: u64) {
        let first = self.chaos.is_none();
        self.chaos = Some((StdRng::seed_from_u64(seed), mean_ms));
        if first {
            self.schedule(self.now + mean_ms, Event::Chaos);
        }
    }

    fn sightings(&mut self, node: Node) {
        let now = self.now;
        if !self.on_air(node) {
            return;
        }
        let seen: Vec<(u64, i8)> = self
            .range
            .range((node, 0)..=(node, Node::MAX))
            .filter(|(&(_, other), _)| self.on_air(other))
            .filter_map(|(&(_, other), &rssi)| Some((*self.addr.get(other)?, rssi)))
            .collect();
        let engine = &mut self.phone_mut(node).engine;
        for (addr, rssi) in seen {
            engine.sighting(PeerRef(addr), rssi, now);
        }
        self.after(node);
    }

    /// The connect an engine asked for has run its course.
    fn dialled(&mut self, from: Node, era: usize, addr: u64) {
        let now = self.now;
        // An engine that was restarted since never asked for this.
        if !self.on_air(from) || self.at(from).restarts.len() != era {
            return;
        }
        let reached = self
            .by_addr
            .get(&addr)
            .copied()
            .filter(|&to| self.on_air(to) && self.range.contains_key(&(from, to)));
        if let Some(to) = reached {
            self.link(from, to, self.radio);
        } else {
            self.phone_mut(from)
                .engine
                .connect_failed(PeerRef(addr), now);
            self.after(from);
        }
    }

    // ---- time --------------------------------------------------------------

    fn schedule(&mut self, at_ms: u64, event: Event) {
        self.seq += 1;
        self.events.insert((at_ms, self.seq), event);
    }

    /// Runs everything due up to and including `until_ms`.
    pub fn run_until(&mut self, until_ms: u64) {
        while self.step(until_ms) {}
        self.now = self.now.max(until_ms);
    }

    /// Runs everything due before `at_ms` and stops the clock at `at_ms`
    /// with what is due then still to run: a test acts first at that instant.
    pub fn run_before(&mut self, at_ms: u64) {
        if let Some(last) = at_ms.checked_sub(1) {
            while self.step(last) {}
        }
        self.now = self.now.max(at_ms);
    }

    pub fn run_for(&mut self, ms: u64) {
        self.run_until(self.now + ms);
    }

    fn step(&mut self, limit_ms: u64) -> bool {
        let event = self.events.first_key_value().map(|(&(at, _), _)| at);
        let wake = self.wakes.first().map(|&(at, _)| at);
        let timer = match (event, wake) {
            (None, None) => return false,
            (Some(event), Some(wake)) => wake < event,
            (None, Some(_)) => true,
            (Some(_), None) => false,
        };
        let at = if timer { wake } else { event };
        let Some(at) = at.filter(|&at| at <= limit_ms) else {
            return false;
        };
        self.now = self.now.max(at);
        if timer {
            if let Some((_, node)) = self.wakes.pop_first() {
                if let Some(wake) = self.wake_of.get_mut(node) {
                    *wake = None;
                }
                let now = self.now;
                self.phone_mut(node).engine.advance(now);
                self.after(node);
            }
        } else if let Some((_, event)) = self.events.pop_first() {
            self.handle(event);
        }
        true
    }

    fn handle(&mut self, event: Event) {
        match event {
            Event::Deliver { wire, to, bytes } => self.deliver(wire, to, &bytes),
            Event::Hangup { wire } => self.hang_up(wire),
            Event::Scan { node } => {
                if let Some(every) = self.scan_ms {
                    self.sightings(node);
                    self.schedule(self.now + every, Event::Scan { node });
                }
            }
            Event::Dialled { from, era, addr } => self.dialled(from, era, addr),
            Event::Ready { node } => self.after(node),
            Event::Chaos => {
                let Some((rng, mean_ms)) = &mut self.chaos else {
                    return;
                };
                let live: Vec<Wire> = self.wires.keys().copied().collect();
                let pick = (!live.is_empty()).then(|| rng.gen_range(0..live.len()));
                let next = rng.gen_range(1..=*mean_ms * 2);
                if let Some(&wire) = pick.and_then(|pick| live.get(pick)) {
                    self.cut(wire);
                }
                self.schedule(self.now + next, Event::Chaos);
            }
        }
    }

    fn deliver(&mut self, wire: Wire, to: usize, bytes: &[u8]) {
        let now = self.now;
        let Some(end) = self.wires.get(&wire).and_then(|line| line.ends.get(to)) else {
            return;
        };
        if !end.open {
            return;
        }
        let (node, link) = (end.node, end.link);
        let replies = match self.nodes.get_mut(node) {
            Some(Slot::Phone(phone)) => {
                phone.engine.receive(link, bytes, now);
                Vec::new()
            }
            Some(Slot::Stranger(stranger)) => stranger.hear(wire, bytes, now),
            None => Vec::new(),
        };
        for reply in replies {
            self.transmit(wire, to, reply);
        }
        self.after(node);
    }

    /// The links of `node` whose wire can send a frame now.
    fn ready(&self, node: Node) -> Vec<LinkId> {
        let ends = self.ends.range((node, 0)..=(node, u64::MAX));
        ends.filter(|(_, &(wire, side))| {
            let end = self.wires.get(&wire).and_then(|line| line.ends.get(side));
            end.is_some_and(|end| end.busy_ms <= self.now)
        })
        .map(|(&(_, link), _)| LinkId(link))
        .collect()
    }

    /// After any call into the phone at `node`: carries out its outputs,
    /// plays its reader, notes what it emitted and when it next wants to run.
    fn after(&mut self, node: Node) {
        loop {
            let (now, ready) = (self.now, self.ready(node));
            let Some(Slot::Phone(phone)) = self.nodes.get_mut(node) else {
                return;
            };
            let Some(output) = phone.engine.poll_output_ready(&ready, now) else {
                break;
            };
            match output {
                Output::Frame { link, bytes } => {
                    if let Some(&(wire, side)) = self.ends.get(&(node, link.0)) {
                        self.transmit(wire, side, bytes);
                    }
                }
                Output::Close { link } => self.close(node, link),
                Output::Connect { peer } => {
                    let at = self.now + self.connect_ms;
                    let era = phone.restarts.len();
                    let addr = peer.0;
                    self.schedule(
                        at,
                        Event::Dialled {
                            from: node,
                            era,
                            addr,
                        },
                    );
                }
            }
        }
        self.observe(node);
        self.refresh(node);
    }

    fn observe(&mut self, node: Node) {
        let now = self.now;
        let phone = self.phone_mut(node);
        let emitted = phone.engine.stats().emitted;
        if emitted > phone.emitted_seen {
            phone.emitted_seen = emitted;
            let store = phone.engine.store();
            let fresh: Vec<PacketId> = store
                .ids()
                .filter(|id| store.is_local(id) && !phone.own.contains(id))
                .collect();
            for id in fresh {
                let expires_ms = store.expires_ms(&id).unwrap_or(now);
                phone.own.insert(id);
                phone.emissions.push(Emission {
                    at_ms: now,
                    id,
                    expires_ms,
                });
            }
        }
        if matches!(phone.reader, Reader::Absent) || phone.engine.store().unread() == 0 {
            return;
        }
        for packet in phone.engine.take_unread(usize::MAX) {
            let id = packet.id();
            let opened = match &phone.reader {
                Reader::Member(keys) => keys.iter().find_map(|key| packet::open(key, &packet)),
                Reader::Absent | Reader::Keyless => None,
            };
            phone.engine.mark_read(id, opened.is_some());
            phone.taken.push(Taken {
                at_ms: now,
                id,
                packet,
                opened,
            });
        }
    }

    fn refresh(&mut self, node: Node) {
        let Some(Slot::Phone(phone)) = self.nodes.get(node) else {
            return;
        };
        let next = if phone.asleep {
            None
        } else {
            phone.engine.next_wake_ms()
        };
        let Some(known) = self.wake_of.get_mut(node) else {
            return;
        };
        if *known != next {
            if let Some(at) = known.take() {
                self.wakes.remove(&(at, node));
            }
            if let Some(at) = next {
                self.wakes.insert((at, node));
            }
            *known = next;
        }
    }
}
