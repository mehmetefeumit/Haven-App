//! `mesh_sim`: many real mesh engines on a virtual radio (plan §9.1, layer L2).
//!
//! Every test here states one promise of `docs/BLUETOOTH_MESH_PLAN.md` §9.3
//! and fails when it breaks. The harness is `mesh_sim/world.rs`; it reaches an
//! engine only through `haven_core::mesh`'s public interface.

#![allow(clippy::unwrap_used, clippy::expect_used)]

#[path = "mesh_sim/world.rs"]
mod world;

use std::collections::{BTreeMap, BTreeSet};

use haven_core::mesh::engine::{CircleSlot, Config, Stats};
use haven_core::mesh::frame;
use haven_core::mesh::packet::{self, EventParts, Format, MeshKey, Packet, PacketId, PACKET_LEN};
use rand::rngs::StdRng;
use rand::SeedableRng;

use world::{Fault, Node, Radio, Reader, Seen, World};

const FRAME: usize = 512;
const MINUTE: u64 = 60_000;
/// The plan's `L`.
const LIFE: u64 = 20 * MINUTE;
/// One lifetime unit, `L / 256` rounded down.
const UNIT: u64 = LIFE / 256;
const TICK: u64 = 5000;

const fn wire() -> Radio {
    Radio::instant(FRAME)
}

/// A recognisable event: every field is a pattern a recorded byte stream can
/// be searched for.
const ROUTING_ID: &[u8; 32] = b"ROUTING-ID.h-tag.planted.0123456";
const PUBKEY: &[u8; 32] = b"PUBKEY.planted.ephemeral.key.xyz";
const EVENT_ID: &[u8; 32] = b"EVENT-ID.planted.marker.00112233";
const COORDINATES: &[u8] = b"lat=48.858370;lon=2.294481;geohash=u09tunq";
const SIGNATURE: [u8; 64] = [0x5c; 64];
const SECRET: [u8; 32] = [0xe7; 32];

fn key() -> MeshKey {
    MeshKey::derive(&SECRET)
}

fn event(n: u8) -> EventParts {
    let mut content = Vec::new();
    content.extend_from_slice(ROUTING_ID);
    content.extend_from_slice(EVENT_ID);
    content.extend_from_slice(COORDINATES);
    content.push(n);
    EventParts {
        format: Format::Bridgeable,
        pubkey: *PUBKEY,
        sig: SIGNATURE,
        created_at: 0x0102_0304_0506_0700 + u64::from(n),
        expiration: 0x1112_1314_1516_1700 + u64::from(n),
        content,
    }
}

/// The location update `n`, wrapped under the circle's key.
fn update(n: u8) -> Packet {
    let mut rng = StdRng::seed_from_u64(0x10ca_0000 + u64::from(n));
    packet::wrap(&key(), &event(n), &mut rng).expect("the event fits")
}

/// A packet no key opens.
fn junk(n: u64) -> Packet {
    packet::cover_packet(&mut StdRng::seed_from_u64(0x0bad_0000 + n))
}

fn offer(world: &mut World, node: Node, slot: u32, packet: &Packet) {
    world.drive(node, |engine, now| {
        engine.offer(CircleSlot(slot), packet.clone(), u64::MAX, now);
    });
}

/// Whether any of `needles` occurs in `hay`. Every needle is at least eight
/// bytes long.
fn finds(hay: &[u8], needles: &[Vec<u8>]) -> bool {
    let heads: BTreeSet<&[u8]> = needles.iter().filter_map(|n| n.get(..8)).collect();
    hay.windows(8).enumerate().any(|(at, head)| {
        heads.contains(head)
            && needles
                .iter()
                .any(|needle| hay.get(at..at + needle.len()) == Some(needle.as_slice()))
    })
}

/// What is planted in every [`update`], and the key it is wrapped under.
fn planted() -> Vec<Vec<u8>> {
    vec![
        ROUTING_ID.to_vec(),
        PUBKEY.to_vec(),
        EVENT_ID.to_vec(),
        COORDINATES.to_vec(),
        SIGNATURE[..16].to_vec(),
        SECRET.to_vec(),
        0x0102_0304_0506_0700u64.to_be_bytes()[..7].to_vec(),
    ]
}

/// What names a packet on a link: its id and stretches of its bytes.
fn traces(packet: &Packet) -> Vec<Vec<u8>> {
    let bytes = packet.as_bytes();
    vec![
        packet.id().0.to_vec(),
        bytes[..16].to_vec(),
        bytes[504..520].to_vec(),
        bytes[PACKET_LEN - 16..].to_vec(),
    ]
}

/// Five phones that find each other by scanning: `0 – 1 – 2 – 3 – 4` in a
/// line by signal, with `1` and `3` also in range.
fn scanned_line(seed: u64, readers: [Reader; 5]) -> World {
    let mut world = World::new();
    for (n, reader) in (0u64..).zip(readers) {
        world.phone(Config::default(), seed * 100 + n, reader);
    }
    for near in 0..4 {
        world.in_range(near, near + 1, -60);
    }
    world.in_range(1, 3, -75);
    world.scan(4000);
    world
}

/// The same seed gives the same bytes on every wire at the same instants; a
/// different seed gives others.
#[test]
fn a_seed_fixes_every_byte_on_every_wire() {
    let run = |seed: u64| {
        let mut world = scanned_line(
            seed,
            [
                Reader::Member(vec![key()]),
                Reader::Keyless,
                Reader::Absent,
                Reader::Keyless,
                Reader::Member(vec![key()]),
            ],
        );
        offer(&mut world, 0, 1, &update(1));
        world.run_until(6 * MINUTE);
        world.journal
    };
    let (first, again, other) = (run(7), run(7), run(8));
    assert!(
        first.len() > 200,
        "the run put {} frames on wires",
        first.len()
    );
    assert!(first == again, "one seed, two journals");
    assert!(first != other, "two seeds, one journal");
}

// ---- what crosses a link ---------------------------------------------------

/// T-PRIV-1 (L2): with real wrapped updates crossing a mesh of members and
/// strangers, nothing planted in them, no key, and nothing that names a
/// packet appears in any byte recorded on any wire; a phone without the key
/// holds nothing planted either; every packet a member recovers is exactly
/// 1024 bytes and every frame after a handshake is exactly its link's size.
#[test]
fn nothing_planted_crosses_a_link_and_every_packet_and_frame_has_its_one_size() {
    let mut world = scanned_line(
        11,
        [
            Reader::Member(vec![key()]),
            Reader::Keyless,
            Reader::Absent,
            Reader::Keyless,
            Reader::Member(vec![key()]),
        ],
    );
    // Two links the engines did not choose, with other frame sizes.
    world.link(2, 4, Radio::instant(185));
    world.link(3, 0, Radio::instant(64));
    for n in 1..=4u8 {
        offer(&mut world, 0, u32::from(n), &update(n));
    }
    world.run_until(10 * MINUTE);

    // The member at the far end recovers every update, whole.
    let recovered: Vec<&EventParts> = world
        .at(4)
        .taken
        .iter()
        .filter_map(|t| t.opened.as_ref())
        .collect();
    assert_eq!(recovered.len(), 4, "updates the far member opened");
    assert!((1..=4).all(|n| recovered.contains(&&event(n))));
    for taken in world
        .phones()
        .iter()
        .flat_map(|&node| &world.at(node).taken)
    {
        assert_eq!(taken.packet.as_bytes().len(), 1024);
    }
    // The scanner finds what is planted where it is: in the opened event.
    let opened = recovered
        .first()
        .map(|parts| [&parts.pubkey[..], &parts.content[..]].concat());
    assert!(opened.is_some_and(|plain| finds(&plain, &planted())));

    // A phone without the key holds the same packets and nothing planted.
    let carried: Vec<&Packet> = [1, 3]
        .iter()
        .flat_map(|&node| &world.at(node).taken)
        .map(|t| &t.packet)
        .collect();
    assert!((1..=4).all(|n| carried.contains(&&update(n))));
    assert!(carried
        .iter()
        .all(|packet| !finds(packet.as_bytes(), &planted())));

    // Nothing planted, and nothing naming any packet, on any wire: frame by
    // frame, and across the frames of each direction joined end to end.
    let mut needles = planted();
    for node in world.phones() {
        let phone = world.at(node);
        needles.extend(phone.taken.iter().flat_map(|t| traces(&t.packet)));
        needles.extend(phone.emissions.iter().map(|e| e.id.0.to_vec()));
    }
    assert!(needles.len() > 100, "packets crossed the mesh");
    let mut streams: BTreeMap<(u64, Node), Vec<u8>> = BTreeMap::new();
    for crossing in &world.journal {
        streams
            .entry((crossing.wire, crossing.from))
            .or_default()
            .extend_from_slice(&crossing.bytes);
    }
    assert!(world.journal.len() > 1000, "frames crossed the mesh");
    assert!(streams.values().all(|stream| !finds(stream, &needles)));

    // Each direction of each wire: one handshake message, then frames of the
    // link's one size.
    let mut sizes = BTreeSet::new();
    let mut started = BTreeSet::new();
    for crossing in &world.journal {
        let (central, _, radio) = world.wire_log[&crossing.wire];
        if started.insert((crossing.wire, crossing.from)) {
            let handshake = if crossing.from == central { 32 } else { 48 };
            assert_eq!(crossing.bytes.len(), handshake);
        } else {
            assert_eq!(crossing.bytes.len(), radio.max_frame);
            sizes.insert(radio.max_frame);
        }
    }
    assert!(
        sizes == BTreeSet::from([64, 185, FRAME]),
        "every frame size carried traffic"
    );
}

/// Two phones in range of each other, the second a member; the first has
/// update 1 to send.
fn pair(seed: u64) -> World {
    let mut world = World::new();
    world.phone(Config::default(), seed, Reader::Keyless);
    world.phone(Config::default(), seed + 1, Reader::Member(vec![key()]));
    world.in_range(0, 1, -60);
    world.scan(4000);
    offer(&mut world, 0, 1, &update(1));
    world
}

/// T-PRIV-8 (L2), the listener: someone recording a link without being on it
/// finds no packet id, no lifetime entry, no frame header and no padding; and
/// on a link a stranger is on, no sealed frame shows the header or the body
/// the stranger opens it to.
#[test]
fn a_listener_beside_a_link_finds_no_id_no_lifetime_and_no_frame_type() {
    let mut world = pair(21);
    let spy = world.stranger(29);
    world.them_mut(spy).want_all = true;
    let tapped = world.dial(spy, 0, wire());
    world.run_until(8 * MINUTE);

    let held: Vec<PacketId> = world.engine(1).store().ids().collect();
    assert!(
        held.len() >= 6,
        "the phones exchanged {} packets",
        held.len()
    );
    let between: Vec<&[u8]> = world
        .journal
        .iter()
        .filter(|c| c.wire != tapped)
        .map(|c| &c.bytes[..])
        .collect();
    let sealed: Vec<&[u8]> = between
        .iter()
        .copied()
        .filter(|bytes| bytes.len() == FRAME)
        .collect();
    assert!(
        sealed.len() > 30,
        "{} sealed frames between the two phones",
        sealed.len()
    );
    let stream = between.concat();
    for id in &held {
        // An inventory entry is the id and one byte: neither shows.
        assert!(!finds(&stream, &[id.0.to_vec()]));
    }
    for frame in &sealed {
        assert!(
            frame::decode(&frame[..FRAME - 16]).is_none(),
            "a frame readable as sent"
        );
        assert!(!finds(frame, &[vec![0; 8]]), "a run of padding in clear");
    }

    // What the stranger opened its own frames to is nowhere in them.
    let heard = &world.them(spy).heard;
    let kinds: BTreeSet<u8> = heard.iter().map(|h| h.plain[0]).collect();
    assert!(
        kinds.len() >= 3,
        "the tapped link carried HELLO, HAVE and PKT"
    );
    for frame in heard {
        assert_eq!(frame.sealed.len(), FRAME);
        assert!(frame.sealed[..3] != frame.plain[..3], "a header in clear");
        assert!(
            !finds(&frame.sealed, &[frame.plain[3..19].to_vec()]),
            "a body in clear"
        );
    }
}

/// T-PRIV-8 (L2), the meddler, and T-SEC-3: a frame dropped, replayed,
/// reordered or altered on a link between two honest phones — the first
/// inventory, or any frame of the transfer that follows — closes that link,
/// puts no packet in either store that nobody emitted, and the update still
/// arrives, once, when the phones have connected again.
#[test]
fn a_dropped_replayed_reordered_or_altered_frame_closes_the_link() {
    for fault in [Fault::Drop, Fault::Replay, Fault::Swap, Fault::Flip] {
        for position in 0..5 {
            let mut world = pair(31);
            world.run_until(20_000);
            let link = world.wires_of(0);
            assert_eq!(link.len(), 1, "the phones linked");
            world.tamper(link[0], 0, fault, position);
            world.run_until(5 * MINUTE);
            let closed = &world.closed;
            let by_a_phone = closed.iter().any(|c| c.wire == link[0] && c.by.is_some());
            assert!(by_a_phone, "the phones kept a link that was tampered with");

            world.run_until(12 * MINUTE);
            let taken = &world.at(1).taken;
            let opened: Vec<_> = taken.iter().filter_map(|t| t.opened.clone()).collect();
            assert!(opened == vec![event(1)], "the update arrived once");
            let origins = origins(&world);
            for node in [0, 1] {
                let mut ids = world.engine(node).store().ids();
                assert!(
                    ids.all(|id| origins.contains_key(&id)),
                    "a packet nobody emitted"
                );
                let accepted = world.engine(node).stats().accepted;
                assert_eq!(accepted, world.at(node).taken.len() as u64);
            }
        }
    }
}

// ---- delivery ---------------------------------------------------------------

/// How long each packet a phone emitted in `window` took to reach each other
/// phone in `to`: `None` for one that never did. Every phone has a reader, so
/// the world saw each packet arrive.
fn latencies(world: &World, window: std::ops::Range<u64>, to: &[Node]) -> Vec<Option<u64>> {
    let mut out = Vec::new();
    for origin in world.phones() {
        for emission in &world.at(origin).emissions {
            if !window.contains(&emission.at_ms) {
                continue;
            }
            for &node in to.iter().filter(|&&node| node != origin) {
                let arrival = world.at(node).taken.iter().find(|t| t.id == emission.id);
                out.push(arrival.map(|t| t.at_ms - emission.at_ms));
            }
        }
    }
    out
}

fn worst(latencies: &[Option<u64>]) -> Option<u64> {
    latencies
        .iter()
        .copied()
        .try_fold(0, |worst, latency| Some(worst.max(latency?)))
}

fn delivered(latencies: &[Option<u64>]) -> usize {
    latencies.iter().flatten().count()
}

/// `n` phones nobody reads for but the world, which notes every arrival.
fn crowd(n: u64, seed: u64) -> World {
    let mut world = World::new();
    for node in 0..n {
        world.phone(Config::default(), seed * 1000 + node, Reader::Keyless);
    }
    world
}

/// Every phone in range of every other.
fn all_in_range(world: &mut World) {
    let phones = world.phones();
    for &a in &phones {
        for &b in phones.iter().filter(|&&b| b > a) {
            world.in_range(a, b, -60);
        }
    }
}

/// T-DELIV, a line: on six phones that each see only their neighbours, every
/// packet any phone emits reaches every other within one announcement tick
/// per hop.
#[test]
fn a_line_delivers_every_packet_within_a_tick_per_hop() {
    let mut world = crowd(6, 41);
    for near in 0..5 {
        world.in_range(near, near + 1, -60);
    }
    world.scan(4000);
    world.run_until(11 * MINUTE);
    let took = latencies(&world, MINUTE..10 * MINUTE, &world.phones());
    assert!(took.len() > 150, "{} deliveries were due", took.len());
    assert!(
        worst(&took).is_some_and(|ms| ms <= 5 * TICK),
        "worst {:?}",
        worst(&took)
    );
}

/// T-DELIV, a star: six phones that see only the hub reach each other
/// through it within two ticks, once the hub has linked them all.
#[test]
fn a_star_delivers_every_packet_within_two_ticks() {
    let mut world = crowd(7, 42);
    for leaf in 1..7 {
        world.in_range(0, leaf, -60);
    }
    world.scan(4000);
    world.run_until(11 * MINUTE);
    assert_eq!(world.neighbours(0).len(), 6, "the hub's links");
    let took = latencies(&world, 2 * MINUTE..10 * MINUTE, &world.phones());
    assert!(took.len() > 150, "{} deliveries were due", took.len());
    assert!(
        worst(&took).is_some_and(|ms| ms <= 2 * TICK),
        "worst {:?}",
        worst(&took)
    );
}

/// T-DELIV, a dense cluster: eight phones all in range link within their
/// budget of eight links each and deliver every packet within two ticks.
#[test]
fn a_cluster_delivers_every_packet_within_two_ticks() {
    let mut world = crowd(8, 43);
    all_in_range(&mut world);
    world.scan(4000);
    world.run_until(9 * MINUTE);
    let took = latencies(&world, 2 * MINUTE..8 * MINUTE, &world.phones());
    assert!(took.len() > 150, "{} deliveries were due", took.len());
    assert!(
        worst(&took).is_some_and(|ms| ms <= 2 * TICK),
        "worst {:?}",
        worst(&took)
    );
    // T-LIFE-2 in an honest mesh: no phone was sent a packet it had a record
    // of, so every packet any phone sent in full was a first receipt, and no
    // phone took a packet twice.
    let stats = |pick: fn(&Stats) -> u64| -> u64 {
        let phones = world.phones();
        phones.iter().map(|&n| pick(&world.engine(n).stats())).sum()
    };
    assert_eq!(stats(|s| s.duplicates), 0, "sent to a phone that had it");
    assert_eq!(stats(|s| s.sent), stats(|s| s.accepted));
    for node in world.phones() {
        let taken = &world.at(node).taken;
        let ids: BTreeSet<PacketId> = taken.iter().map(|t| t.id).collect();
        assert_eq!(ids.len(), taken.len(), "a packet taken twice");
    }
}

/// T-DELIV, partition and merge: two islands joined by one pair of phones
/// lose sight of each other for five minutes. What either island emitted
/// meanwhile is held and crosses once they meet again: within a scan, a
/// tick, a connect and one more tick into the far island.
#[test]
fn islands_that_merge_exchange_what_each_emitted_while_apart() {
    let mut world = crowd(6, 44);
    for island in [[0, 1, 2], [3, 4, 5]] {
        for a in island {
            for b in island.into_iter().filter(|&b| b > a) {
                world.in_range(a, b, -60);
            }
        }
    }
    world.in_range(2, 3, -60);
    world.scan(4000);
    world.run_until(4 * MINUTE);
    world.part(2, 3);
    let merge = 9 * MINUTE;
    world.run_until(merge);
    let apart = latencies(&world, 4 * MINUTE + TICK..merge, &world.phones());
    assert!(
        delivered(&apart) < apart.len(),
        "the islands were not apart"
    );
    world.in_range(2, 3, -60);
    world.run_until(merge + 3 * MINUTE);

    let mut late = 0;
    for origin in world.phones() {
        let far: Vec<Node> = if origin < 3 {
            vec![3, 4, 5]
        } else {
            vec![0, 1, 2]
        };
        for emission in &world.at(origin).emissions {
            if !(4 * MINUTE + TICK..merge).contains(&emission.at_ms) {
                continue;
            }
            for &node in &far {
                let arrival = world.at(node).taken.iter().find(|t| t.id == emission.id);
                let at = arrival
                    .map(|t| t.at_ms)
                    .expect("it crossed after the merge");
                late = late.max(at - merge);
            }
        }
    }
    assert!(
        late > 0 && late <= 4000 + TICK + world.connect_ms + TICK,
        "worst {late} ms after the merge"
    );
}

/// T-DELIV, a carrier: two islands never in range of each other, and one
/// phone that walks between them — asleep on the way out, awake on the way
/// back. Each island gets what the other emitted before the carrier left
/// it, within thirty seconds of the carrier coming into range: a scan, a
/// tick, a connect, a new link's allowance, and a tick into the island.
#[test]
fn a_carrier_walking_between_islands_delivers_both_ways() {
    let mut world = crowd(7, 45);
    for island in [[0, 1, 2], [3, 4, 5]] {
        for a in island {
            for b in island.into_iter().filter(|&b| b > a) {
                world.in_range(a, b, -60);
            }
        }
    }
    let carrier = 6;
    world.scan(4000);
    world.in_range(carrier, 0, -55);
    world.run_until(5 * MINUTE);
    world.part(carrier, 0);
    world.sleep(carrier);
    world.run_until(8 * MINUTE);
    world.wake(carrier);
    world.in_range(carrier, 3, -55);
    world.run_until(12 * MINUTE);
    world.part(carrier, 3);
    world.run_until(14 * MINUTE);
    world.in_range(carrier, 0, -55);
    world.run_until(16 * MINUTE);

    // Emitted at least three ticks before the carrier left: time to reach it.
    let legs = [
        (
            [0, 1, 2],
            [3, 4, 5],
            MINUTE..5 * MINUTE - 3 * TICK,
            8 * MINUTE,
        ),
        (
            [3, 4, 5],
            [0, 1, 2],
            MINUTE..12 * MINUTE - 3 * TICK,
            14 * MINUTE,
        ),
    ];
    for (from, to, window, arrives) in legs {
        let mut brought = 0;
        let mut worst = 0;
        for origin in from {
            for emission in &world.at(origin).emissions {
                if !window.contains(&emission.at_ms) {
                    continue;
                }
                for node in to {
                    let arrival = world.at(node).taken.iter().find(|t| t.id == emission.id);
                    let at = arrival.map(|t| t.at_ms).expect("the carrier brought it");
                    assert!(at >= arrives, "the islands were in touch");
                    worst = worst.max(at - arrives);
                    brought += 1;
                }
            }
        }
        assert!(brought >= 20, "{brought} deliveries were due");
        assert!(
            worst <= 30_000,
            "worst {worst} ms after the carrier arrived"
        );
    }
}

/// T-DELIV, arrivals and restarts: in a cluster where every forty seconds a
/// phone arrives or one restarts with nothing stored, every packet reaches
/// every phone that was up and linked when it was emitted, within two
/// ticks.
#[test]
fn arrivals_and_restarts_do_not_stop_delivery() {
    let mut world = crowd(4, 46);
    all_in_range(&mut world);
    world.scan(4000);
    // When each phone last started: it needs half a minute after that to be
    // found and linked.
    let mut starts: BTreeMap<Node, Vec<u64>> = (0..4).map(|node| (node, vec![0])).collect();
    for step in 0..14u64 {
        world.run_until((step + 1) * 40_000);
        let node = if step % 2 == 0 && world.phones().len() < 8 {
            let node = world.phone(Config::default(), 4600 + step, Reader::Keyless);
            all_in_range(&mut world);
            node
        } else {
            let node = usize::try_from(step % 4).expect("small");
            world.restart(node, 4700 + step);
            node
        };
        starts.entry(node).or_default().push(world.now);
    }
    world.run_until(11 * MINUTE);

    // Up since half a minute before `from` and not started again by `to`.
    let settled = |node: Node, from: u64, to: u64| {
        let times = starts.get(&node).map_or(&[][..], Vec::as_slice);
        let since = times.iter().copied().filter(|&at| at <= to).max();
        since.is_some_and(|since| since == 0 || since + 30_000 <= from)
    };
    let (mut due, mut worst) = (0, 0);
    for origin in world.phones() {
        for emission in &world.at(origin).emissions {
            let (from, to) = (emission.at_ms, emission.at_ms + 2 * TICK);
            if from > 10 * MINUTE || !settled(origin, from, to) {
                continue;
            }
            for node in world.phones() {
                if node == origin || !settled(node, from, to) {
                    continue;
                }
                let arrival =
                    (world.at(node).taken.iter()).find(|t| t.id == emission.id && t.at_ms >= from);
                let at = arrival.map(|t| t.at_ms).expect("a settled phone got it");
                worst = worst.max(at - from);
                due += 1;
            }
        }
    }
    assert!(due > 150, "{due} deliveries were due");
    assert!(worst <= 2 * TICK, "worst {worst} ms");
}

/// T-DELIV, link loss: on a line of six, where every link matters, a link
/// picked at random is cut every twenty seconds on average for the whole run
/// (each of the five about every hundred seconds, and its phones wait a
/// minute or more before they connect again). Phones hold what they could
/// not pass on, so every packet still reaches every phone within its
/// lifetime: the floor is all of them.
#[test]
fn a_line_whose_links_keep_dropping_still_delivers_everything_in_time() {
    let mut world = crowd(6, 47);
    for near in 0..5 {
        world.in_range(near, near + 1, -60);
    }
    world.scan(4000);
    world.chaos(470, 20_000);
    world.run_until(24 * MINUTE);
    assert!(
        world.closed.iter().filter(|c| c.by.is_none()).count() > 40,
        "links were cut"
    );
    let took = latencies(&world, MINUTE..8 * MINUTE, &world.phones());
    assert!(took.len() > 100, "{} deliveries were due", took.len());
    assert_eq!(delivered(&took), took.len(), "worst {:?}", worst(&took));
    assert!(
        worst(&took).is_some_and(|ms| ms > 5 * TICK),
        "the cuts delayed nothing"
    );
}

// ---- lifetime ---------------------------------------------------------------

/// A stranger that sits on a phone's link like any neighbour and only
/// listens.
fn listener(world: &mut World, seed: u64) -> Node {
    world.stranger(seed)
}

/// Where and when each packet was first emitted, and when its lifetime ends
/// by its origin's own draw.
fn origins(world: &World) -> BTreeMap<PacketId, (Node, u64, u64)> {
    let mut found = BTreeMap::new();
    for node in world.phones() {
        for emission in &world.at(node).emissions {
            found.insert(emission.id, (node, emission.at_ms, emission.expires_ms));
        }
    }
    found
}

/// One inventory entry a phone gave a stranger, with what the world knows of
/// the packet.
struct Told {
    at_ms: u64,
    id: PacketId,
    units: u8,
    /// When the packet was first emitted, and when its origin's own figure
    /// for its lifetime ends.
    emitted_ms: u64,
    expires_ms: u64,
    /// The phone announcing it is the one that emitted it.
    own: bool,
}

/// What strangers were told in an honest mesh with arrivals and restarts.
struct Churn {
    told: Vec<Told>,
    /// Packets whose lifetime had ended and that the phone asked last still
    /// had a record of, and how many of them it announced then.
    remembered_past_life: usize,
    announced_past_life: usize,
}

/// An honest mesh on instant links: five phones, three more arriving, three
/// restarting with nothing stored, for thirty-one minutes; a stranger dials
/// each phone in turn every five seconds and is told its whole inventory.
/// Run once for the tests that read it.
fn honest_churn() -> &'static Churn {
    static RUN: std::sync::OnceLock<Churn> = std::sync::OnceLock::new();
    RUN.get_or_init(|| {
        let mut world = crowd(5, 51);
        all_in_range(&mut world);
        world.scan(4000);
        let probe = listener(&mut world, 52);
        let mut entries = Vec::new();
        let mut last = (0, 0);
        for step in 1..=372u64 {
            world.run_until(step * TICK + 1);
            match step {
                48 | 132 | 204 => {
                    world.phone(Config::default(), 51_000 + step, Reader::Keyless);
                    all_in_range(&mut world);
                }
                72 | 168 | 252 => {
                    world.restart(usize::try_from(step % 5).expect("small"), 51 + step);
                }
                _ => {}
            }
            let phones = world.phones();
            let phone = phones[usize::try_from(step).expect("small") % phones.len()];
            let tap = world.dial(probe, phone, wire());
            world.run_until(world.now);
            let heard = world.them(probe).haves().split_off(entries.len());
            let store = world.engine(phone).store();
            for (at_ms, wire, id, units) in heard {
                assert_eq!((at_ms, wire), (world.now, tap));
                // A restart forgets which packets were the phone's own.
                entries.push((at_ms, id, units, phone, store.is_local(&id)));
            }
            world.cut(tap);
            last = (phone, world.now);
        }

        let origins = origins(&world);
        let told: Vec<Told> = entries
            .iter()
            .map(|&(at_ms, id, units, phone, local)| {
                let (origin, emitted_ms, expires_ms) = origins[&id];
                Told {
                    at_ms,
                    id,
                    units,
                    emitted_ms,
                    expires_ms,
                    own: local && origin == phone,
                }
            })
            .collect();
        let (phone, at_ms) = last;
        let store = world.engine(phone).store();
        let ended = origins
            .iter()
            .filter(|(id, origin)| origin.2 <= at_ms && store.has_record(id));
        let ended: BTreeSet<PacketId> = ended.map(|(id, _)| *id).collect();
        let announced = told
            .iter()
            .filter(|entry| entry.at_ms == at_ms && ended.contains(&entry.id));
        Churn {
            announced_past_life: announced.count(),
            remembered_past_life: ended.len(),
            told,
        }
    })
}

/// T-LIFE-1: in an honest run with arrivals and restarts, no phone announces
/// a packet after its origin time + `L` — exactly: never with less than one
/// whole unit of the origin's own lifetime left — though it remembers the
/// packet for longer.
#[test]
fn no_phone_announces_a_packet_after_its_lifetime() {
    let run = honest_churn();
    assert!(run.told.len() > 5000, "{} entries", run.told.len());
    let mut near_the_end = 0;
    for entry in &run.told {
        assert!(
            entry.at_ms + UNIT <= entry.expires_ms,
            "announced with no unit left"
        );
        assert!(entry.at_ms < entry.emitted_ms + LIFE);
        near_the_end += u32::from(entry.at_ms + 3 * UNIT > entry.expires_ms);
    }
    assert!(
        near_the_end > 30,
        "{near_the_end} announcements in a packet's last units"
    );
    // The phones do remember packets past their lifetime, and stay silent.
    assert!(
        run.remembered_past_life >= 20,
        "{} packets remembered past their lifetime",
        run.remembered_past_life
    );
    assert_eq!(run.announced_past_life, 0);
}

/// T-LIFE-4: in the same honest run on instant links, the lifetime a phone
/// announces never exceeds the packet's true one, and for a packet it
/// emitted itself it is the true one, rounded down.
#[test]
fn an_announced_lifetime_never_exceeds_the_true_one() {
    let run = honest_churn();
    let (mut own, mut carried, mut short) = (0, 0, 0);
    for entry in &run.told {
        let truth = (entry.expires_ms - entry.at_ms) / UNIT;
        let units = u64::from(entry.units);
        assert!(units <= truth, "announced {units} of {truth}");
        if entry.own {
            assert_eq!(units, truth);
            own += 1;
        } else {
            carried += 1;
            short += u32::from(units < truth);
        }
    }
    assert!(own > 300 && carried > 3000, "{own} own, {carried} carried");
    assert!(
        short > 300,
        "{short} carried entries lost a unit to rounding"
    );
    // No id was announced that no phone emitted: `honest_churn` looked each
    // one up.
    let ids: BTreeSet<PacketId> = run.told.iter().map(|entry| entry.id).collect();
    assert!(ids.len() > 100, "{} packets were announced", ids.len());
}

/// `n` phones in a line, joined by wires the test chose, each link made at
/// its own instant so the phones' ticks are not in step.
fn wired_line(n: u64, seed: u64, radio: Radio) -> World {
    let mut world = crowd(n, seed);
    for near in 0..usize::try_from(n).expect("small") - 1 {
        world.run_until(world.now + 700);
        world.link(near, near + 1, radio);
    }
    world
}

/// T-LIFE-1, on links with delay. A lifetime crosses a link as a duration,
/// so the time an announcement spends in transit is added to it: the plan's
/// "never after origin + `L`" holds exactly on instant links only. What the
/// engine guarantees, and this pins on a four-hop line whose links each take
/// nine seconds: the lifetime a phone `h` hops out holds ends later than the
/// origin's by more than `h × (delay − unit)` and at most `h × delay`, and
/// that phone announces the packet exactly while a whole unit of that is
/// left. A packet that started with the full 255 units is therefore still
/// announced there after origin + `L`.
#[test]
fn link_delay_stretches_a_lifetime_by_at_most_the_delay_per_hop() {
    const DELAY: u64 = 9000;
    const HOPS: u64 = 4;
    let radio = Radio {
        max_frame: FRAME,
        delay_ms: DELAY,
        bytes_per_s: 0,
    };
    let mut world = wired_line(HOPS + 1, 53, radio);
    let last = usize::try_from(HOPS).expect("small");
    // The origin, played by a stranger so that its draw is the top one.
    let origin = world.stranger(54);
    let source = world.dial(origin, 0, wire());
    let probe = listener(&mut world, 55);
    for n in 1..=3 {
        world.run_for(MINUTE);
        let packet = junk(n);
        let id = packet.id();
        world.them_mut(origin).serve.insert(id, packet);
        world.announce(origin, source, &[(id, 255)]);
        let emitted_ms = world.now;
        let expires_ms = emitted_ms + 255 * UNIT;
        // A hop takes a tick and three crossings of its link.
        world.run_for(HOPS * (TICK + 3 * DELAY));
        assert_eq!(world.engine(0).store().expires_ms(&id), Some(expires_ms));
        let held = world.engine(last).store().expires_ms(&id);
        let held = held.expect("it crossed the line");
        let stretch = held - expires_ms;
        assert!(
            stretch > HOPS * (DELAY - UNIT) && stretch <= HOPS * DELAY,
            "stretched {stretch} ms"
        );

        // Asked every five seconds around the end, the far phone announces
        // the packet exactly while one unit of its own figure is left.
        world.run_until(expires_ms - 20_000);
        let mut last_announced = 0;
        while world.now < held + 20_000 {
            world.run_for(TICK);
            let before = world.them(probe).haves().len();
            let tap = world.dial(probe, last, wire());
            world.run_until(world.now);
            let entries = world.them(probe).haves().split_off(before);
            let announced = entries.iter().any(|entry| entry.2 == id);
            assert_eq!(announced, world.now + UNIT <= held, "at {}", world.now);
            if announced {
                last_announced = world.now;
            }
            world.cut(tap);
        }
        assert!(last_announced + UNIT <= expires_ms + HOPS * DELAY);
        assert!(
            last_announced > emitted_ms + LIFE,
            "last announced {} ms after its origin",
            last_announced - emitted_ms
        );
    }
}

/// T-LIFE-5: on a line of eight hops — seven between phones and the one to
/// the listener — the lifetime a packet is announced with at the far end is
/// short of what its origin drew by less than eight units plus the time that
/// actually passed.
#[test]
fn a_line_of_k_hops_loses_under_k_units_beyond_the_time_elapsed() {
    const HOPS: u64 = 8;
    let mut world = wired_line(HOPS, 55, wire());
    let end = listener(&mut world, 56);
    world.dial(end, usize::try_from(HOPS).expect("small") - 1, wire());
    world.run_until(12 * MINUTE);

    let mut followed = 0;
    let mut most = 0;
    for emission in &world.at(0).emissions {
        let Some((at_ms, units)) = world.them(end).first_have(emission.id) else {
            continue;
        };
        let (drawn, left) = (
            emission.expires_ms - emission.at_ms,
            u64::from(units) * UNIT,
        );
        let elapsed = at_ms - emission.at_ms;
        assert!(elapsed >= TICK, "the line was crossed in {elapsed} ms");
        assert!(
            drawn - left < HOPS * UNIT + elapsed,
            "lost {} ms in {elapsed} ms",
            drawn - left
        );
        most = most.max(drawn - left - elapsed);
        followed += 1;
    }
    assert!(followed >= 5, "{followed} packets crossed the line");
    assert!(
        most > UNIT,
        "rounding cost at most {most} ms: the hops left no trace to bound"
    );
}

/// T-LIFE-1, in a cycle of slow links. Where an announcement takes longer
/// to cross a link than one unit, phones that all hold a packet keep raising
/// each other's figure for it: the lifetime no longer ends near its origin's.
/// What still holds, and is all that holds: no phone keeps or announces the
/// packet past its own first receipt + `L`.
#[test]
fn slow_links_in_a_cycle_never_carry_a_lifetime_past_first_receipt_plus_l() {
    let radio = Radio {
        max_frame: FRAME,
        delay_ms: 9000,
        bytes_per_s: 0,
    };
    let mut world = crowd(4, 57);
    for a in 0..4 {
        for b in a + 1..4 {
            world.run_for(700);
            world.link(a, b, radio);
        }
    }
    let origin = world.stranger(58);
    let source = world.dial(origin, 0, wire());
    world.run_for(MINUTE);
    let packet = junk(1);
    let id = packet.id();
    world.them_mut(origin).serve.insert(id, packet);
    world.announce(origin, source, &[(id, 200)]);
    let ends = world.now + 200 * UNIT;

    world.run_for(2 * MINUTE);
    let first: Vec<u64> = (0..4)
        .map(|node| {
            world
                .at(node)
                .taken
                .iter()
                .find(|t| t.id == id)
                .map(|t| t.at_ms)
        })
        .collect::<Option<_>>()
        .expect("every phone took it");
    while world.now < ends + LIFE {
        world.run_for(MINUTE);
        let now = world.now;
        for (node, &first) in first.iter().enumerate() {
            let store = world.settled(node).store();
            let left = u64::from(store.remaining(&id)) * UNIT;
            assert!(
                left == 0 || now + left <= first + LIFE,
                "phone {node} at {now}"
            );
            assert!(store
                .expires_ms(&id)
                .is_some_and(|ends| ends <= first + LIFE));
            assert_eq!(store.holds(&id), now < first + LIFE);
        }
    }
}

/// A phone with two strangers dialled in: one to feed it, one to watch it.
fn sandwich(config: Config, seed: u64) -> (World, Node, (Node, u64), (Node, u64)) {
    let mut world = World::new();
    let phone = world.phone(config, seed, Reader::Keyless);
    let feeder = world.stranger(seed + 1);
    let watcher = world.stranger(seed + 2);
    let fed = world.dial(feeder, phone, wire());
    let view = world.dial(watcher, phone, wire());
    world.run_until(1);
    (world, phone, (feeder, fed), (watcher, view))
}

/// T-LIFE-2: a phone never asks for a packet it has a record of, hands a
/// packet to a link once and never back to the link it came from — and takes
/// the same bytes again exactly when the re-accept interval `2 L` has
/// passed, not a millisecond before.
#[test]
fn a_packet_never_bounces_back_and_is_taken_again_only_after_two_lifetimes() {
    let (mut world, phone, (feeder, fed), (watcher, view)) = sandwich(Config::default(), 61);
    let packet = junk(1);
    let id = packet.id();
    world.them_mut(feeder).serve.insert(id, packet.clone());
    world.them_mut(watcher).serve.insert(id, packet);
    world.run_until(3000);
    world.announce(feeder, fed, &[(id, 250)]);
    let first = world.now;
    world.run_for(2 * TICK);

    // Announced to the watcher, never back to the feeder.
    assert!(world.them(watcher).first_have(id).is_some());
    assert!(world.them(feeder).first_have(id).is_none());
    // Handed over once, however often it is asked for; never to its source.
    for _ in 0..3 {
        world.ask(watcher, view, &[id]);
        world.ask(feeder, fed, &[id]);
        world.run_for(TICK);
    }
    assert_eq!(world.them(watcher).got.len(), 1);
    assert!(world.them(feeder).got.is_empty());

    // Announced back with any lifetime, at any time, it is not asked for
    // while the record lasts.
    let again = first + 2 * LIFE;
    for at in [
        first + MINUTE,
        first + LIFE - 1,
        first + LIFE + 1,
        again - 1,
    ] {
        world.run_until(at);
        world.announce(watcher, view, &[(id, 255)]);
        world.announce(feeder, fed, &[(id, 255)]);
    }
    world.run_before(again);
    let asked: Vec<u64> = [feeder, watcher]
        .iter()
        .flat_map(|&s| world.them(s).wants())
        .filter(|w| w.2 == id)
        .map(|w| w.0)
        .collect();
    assert!(asked == vec![first], "asked for at {asked:?}");
    assert!(world.engine(phone).store().has_record(&id));
    assert_eq!(world.engine(phone).stats().accepted, 1);

    // At `2 L` the record is gone and the same bytes are a new packet.
    world.announce(watcher, view, &[(id, 255)]);
    world.run_until(again);
    let asked: Vec<u64> = world
        .them(watcher)
        .wants()
        .iter()
        .filter(|w| w.2 == id)
        .map(|w| w.0)
        .collect();
    assert!(asked == vec![again], "asked for at {asked:?}");
    assert_eq!(world.engine(phone).stats().accepted, 2);
    assert_eq!(world.engine(phone).stats().duplicates, 0);
}

/// T-LIFE-3, under-stating: an attacker with a head start hands the only
/// phone on the way downstream a fresh packet with one unit of lifetime, so
/// that phone falls silent about it at once. When the honest announcement
/// arrives the phone raises the lifetime and passes the packet on.
#[test]
fn an_understated_lifetime_does_not_stop_delivery_once_the_honest_one_arrives() {
    // 0 originates; 2 is the only way to 3.
    let mut world = wired_line(4, 62, wire());
    let attacker = world.stranger(63);
    let hold = world.dial(attacker, 2, wire());
    let packet = update(1);
    let id = packet.id();
    world.them_mut(attacker).serve.insert(id, packet.clone());
    world.run_until(11_000);
    world.announce(attacker, hold, &[(id, 1)]);
    world.run_for(1);
    assert!(
        world.engine(2).store().holds(&id),
        "the attacker got there first"
    );

    offer(&mut world, 0, 1, &packet);
    let emitted = loop {
        world.run_for(1000);
        if let Some(emission) = world.at(0).emissions.iter().find(|e| e.id == id) {
            break emission.at_ms;
        }
    };
    assert!(
        emitted > 11_000 + 2 * UNIT,
        "the understated lifetime had ended"
    );
    assert!(
        !world.engine(3).store().has_record(&id),
        "one unit carried it no further"
    );
    assert_eq!(world.engine(2).store().remaining(&id), 0);

    // A tick to reach 1, one to reach 2, one for 2 to announce it on.
    world.run_until(emitted + 3 * TICK);
    assert!(world.engine(3).store().holds(&id));
    let true_left = world
        .at(0)
        .emissions
        .iter()
        .find(|e| e.id == id)
        .map(|e| e.expires_ms);
    let left = world.engine(3).store().expires_ms(&id);
    assert!(
        left <= true_left && left.map(|ms| ms + 4 * UNIT) > true_left,
        "{left:?} of {true_left:?}"
    );
    assert_eq!(
        world.engine(2).stats().accepted - world.engine(2).stats().duplicates,
        world.at(2).taken.len() as u64
    );
}

/// T-LIFE-3, over-stating: a peer that keeps announcing the maximum for an
/// old packet cannot make a phone keep or announce it past first receipt +
/// `L`, nor take it again inside the re-accept interval.
#[test]
fn an_overstated_lifetime_holds_a_packet_no_longer_and_gets_it_taken_no_sooner() {
    let (mut world, phone, (feeder, fed), (liar, lied)) = sandwich(Config::default(), 64);
    let packet = junk(2);
    let id = packet.id();
    world.them_mut(feeder).serve.insert(id, packet.clone());
    world.them_mut(liar).serve.insert(id, packet);
    world.run_until(3000);
    world.announce(feeder, fed, &[(id, 40)]);
    let first = world.now;
    let probe = listener(&mut world, 69);

    let mut last_announced = 0;
    let mut silent_probes = 0;
    while world.now < first + 2 * LIFE - TICK {
        world.run_for(TICK);
        world.announce(liar, lied, &[(id, 255)]);
        let before = world.them(probe).haves().len();
        let tap = world.dial(probe, phone, wire());
        world.run_until(world.now);
        if world
            .them(probe)
            .haves()
            .split_off(before)
            .iter()
            .any(|e| e.2 == id)
        {
            last_announced = world.now;
        } else {
            silent_probes += 1;
        }
        world.cut(tap);
        let store = world.engine(phone).store();
        assert_eq!(
            store.holds(&id),
            world.now < first + LIFE,
            "at {}",
            world.now - first
        );
        assert!(store
            .expires_ms(&id)
            .is_some_and(|ends| ends <= first + LIFE));
    }
    // The lie did extend it, to the cap and no further.
    assert!(
        last_announced > first + 40 * UNIT + MINUTE,
        "the lie changed nothing"
    );
    assert!(
        last_announced + UNIT <= first + LIFE,
        "announced {} ms after first receipt",
        last_announced - first
    );
    assert!(silent_probes > 200);
    let asked = world
        .them(liar)
        .wants()
        .iter()
        .filter(|w| w.2 == id)
        .count();
    assert_eq!(asked, 0, "asked the liar for it");
    assert_eq!(world.engine(phone).stats().accepted, 1);
}

// ---- floods -----------------------------------------------------------------

/// A lifetime of two minutes and small limits, so that a flood that fills
/// what the limits allow fits in a test: the record table follows from them.
fn small_limits() -> Config {
    Config {
        life_ms: 2 * MINUTE,
        accept_per_min: 60,
        accept_burst: 30,
        offers_per_link: 120,
        want_timeout_ms: 5000,
        credit_per_min: 600,
        store_packets: 64,
        ..Config::default()
    }
}

/// T-SEC-8: a peer floods a phone with packets as fast as its allowance and
/// the phone's intake limit let it — including packets it let the phone ask
/// for and held back, to hand over all at once on top of the steady flood.
/// The record table never passes its capacity and is never filled, so the
/// phone goes on taking an honest neighbour's packets and emitting its own;
/// and whatever the flooder announces again, the phone takes no packet twice
/// within the re-accept interval.
#[test]
fn a_flood_within_its_allowance_neither_fills_the_record_table_nor_gets_a_packet_retaken() {
    let config = small_limits();
    let life = config.life_ms;
    let capacity = config.record_capacity();
    let mut world = World::new();
    let victim = world.phone(config.clone(), 71, Reader::Keyless);
    let honest = world.phone(config, 72, Reader::Keyless);
    world.link(honest, victim, wire());
    let flooder = world.stranger(73);
    world.them_mut(flooder).fresh_greetings = true;
    let links = [
        world.dial(flooder, victim, wire()),
        world.dial(flooder, victim, wire()),
    ];

    world.run_until(1000);

    // Phase one: announce, let the phone ask, deliver nothing. The requests
    // are given up on but would still be taken.
    let mut next = 0;
    let mut banked: Vec<Vec<Packet>> = vec![Vec::new(), Vec::new()];
    for (link, held) in banked.iter_mut().enumerate() {
        held.extend((0..120).map(|n| junk(1000 * (link as u64 + 1) + n)));
    }
    let entries = |held: &[Packet]| held.iter().map(|p| (p.id(), 255)).collect::<Vec<_>>();
    while world.now < 4 * MINUTE {
        for (link, held) in banked.iter().enumerate() {
            world.announce(flooder, links[link], &entries(held));
        }
        world.run_for(30_000);
    }
    let asked: BTreeSet<PacketId> = world.them(flooder).wants().iter().map(|w| w.2).collect();
    assert!(
        asked.len() > 200,
        "the phone asked for {} held-back packets",
        asked.len()
    );

    // Phase two: everything held back at once, then a steady flood of new
    // packets at half the phone's intake limit, each announced again later.
    for (link, held) in banked.iter().enumerate() {
        for packet in held.iter().filter(|p| asked.contains(&p.id())) {
            world.hand(flooder, links[link], packet);
        }
    }
    let dumped = world.now;
    let mut repeats: Vec<PacketId> = Vec::new();
    let mut most = 0;
    while world.now < dumped + 3 * life {
        world.run_for(2000);
        let packet = junk(next);
        next += 1;
        world
            .them_mut(flooder)
            .serve
            .insert(packet.id(), packet.clone());
        repeats.push(packet.id());
        world.announce(flooder, links[0], &[(packet.id(), 255)]);
        if next % 10 == 0 {
            let again: Vec<_> = repeats.iter().map(|&id| (id, 255)).collect();
            world.announce(flooder, links[1], &again);
        }
        let stats = world.engine(victim).stats();
        most = most.max(stats.records);
        assert!(
            stats.records < capacity,
            "{} records of {capacity}",
            stats.records
        );
    }
    assert!(most > 300, "the flood left {most} records at most");
    assert!(
        world.is_up(links[0]) && world.is_up(links[1]),
        "the flooder was cut off"
    );

    // The phone's own emissions and its honest neighbour's all landed.
    let phone = world.at(victim);
    assert_eq!(phone.emissions.len() as u64, phone.engine.stats().emitted);
    for emission in &world.at(honest).emissions {
        if emission.at_ms + 2 * TICK > world.now {
            continue;
        }
        let arrival = phone.taken.iter().find(|t| t.id == emission.id);
        let late = arrival.map(|t| t.at_ms - emission.at_ms);
        assert!(
            late.is_some_and(|ms| ms <= 2 * TICK),
            "an honest packet took {late:?}"
        );
    }
    // Nothing was taken twice within two lifetimes.
    let mut taken: BTreeMap<PacketId, u64> = BTreeMap::new();
    let mut retaken = 0;
    for entry in &phone.taken {
        if let Some(before) = taken.insert(entry.id, entry.at_ms) {
            assert!(
                entry.at_ms >= before + 2 * life,
                "retaken after {} ms",
                entry.at_ms - before
            );
            retaken += 1;
        }
    }
    assert!(
        retaken > 20,
        "{retaken} packets came round again after two lifetimes"
    );
}

// ---- what a neighbour can tell ---------------------------------------------

/// Emission slots every fifteen to twenty-five seconds and room for twelve
/// packets: a mesh of these is always evicting.
fn crowded() -> Config {
    Config {
        emit_period_ms: 20_000,
        emit_jitter_ms: 5000,
        store_packets: 12,
        ..Config::default()
    }
}

/// T-PRIV-3, member and non-member: the same mesh run three times, the
/// middle phone once a member that opens its circle's updates, once with a
/// reader that holds no key, once with nobody reading at all. Every byte on
/// every wire, every packet the phone ends up holding and every emission
/// time is the same — with its store full and evicting throughout.
#[test]
fn what_a_phone_forwards_does_not_depend_on_what_it_can_open() {
    struct Trace {
        journal: Vec<world::Crossing>,
        held: Vec<Vec<PacketId>>,
        emitted: Vec<u64>,
        opened: usize,
        accepted: u64,
    }
    let run = |reader: Reader| {
        let mut world = World::new();
        for (n, reader) in (0u64..).zip([
            Reader::Keyless,
            Reader::Keyless,
            reader,
            Reader::Keyless,
            Reader::Keyless,
        ]) {
            world.phone(crowded(), 8100 + n, reader);
        }
        for near in 0..4 {
            world.in_range(near, near + 1, -60);
        }
        world.scan(4000);
        for n in 1..=12u8 {
            offer(&mut world, 0, 1, &update(n));
            world.run_for(25_000);
        }
        Trace {
            held: (0..5)
                .map(|n| world.engine(n).store().ids().collect())
                .collect(),
            emitted: world.at(2).emissions.iter().map(|e| e.at_ms).collect(),
            opened: world
                .at(2)
                .taken
                .iter()
                .filter(|t| t.opened.is_some())
                .count(),
            accepted: world.engine(2).stats().accepted,
            journal: world.journal,
        }
    };
    let member = run(Reader::Member(vec![key()]));
    let keyless = run(Reader::Keyless);
    let unread = run(Reader::Absent);

    assert!(
        member.opened >= 8 && keyless.opened == 0,
        "the member opened {}",
        member.opened
    );
    assert!(
        member.accepted > 40 && member.held[2].len() == 12,
        "the phone's store was not under pressure"
    );
    assert!(
        member.journal.len() > 1000,
        "{} frames",
        member.journal.len()
    );
    for other in [&keyless, &unread] {
        assert!(member.journal == other.journal, "the wires differ");
        assert!(member.held == other.held, "the stores differ");
        assert!(member.emitted == other.emitted, "the emission times differ");
    }
}

/// What a watcher saw of one packet: when it was announced and with how many
/// units, and when it was handed over.
fn sighting(world: &World, watcher: Node, id: PacketId) -> (Option<(u64, u8)>, Option<u64>) {
    (
        world.them(watcher).first_have(id),
        world.them(watcher).got_at(id),
    )
}

/// T-PRIV-3, own and carried: a packet a phone emitted itself and the same
/// packet arriving from a neighbour at that instant with that lifetime reach
/// a watching neighbour at the same time, with the same lifetime, and are
/// handed over the same — also to a neighbour that connects later while a
/// third link floods the phone's store.
#[test]
fn an_own_packet_and_a_carried_one_are_forwarded_alike() {
    let config = Config {
        store_packets: 8,
        ..Config::default()
    };
    let packet = update(1);
    let id = packet.id();
    let run = |emitted: Option<(u64, u8)>| {
        let (mut world, phone, (feeder, fed), (watcher, _)) = sandwich(config.clone(), 82);
        world.them_mut(watcher).want_all = true;
        let flooder = world.stranger(86);
        let flood = world.dial(flooder, phone, wire());
        let slot = if let Some((at_ms, units)) = emitted {
            // Carried: it arrives the instant the phone's slot falls due.
            world.run_before(at_ms);
            world.them_mut(feeder).serve.insert(id, packet.clone());
            world.announce(feeder, fed, &[(id, units)]);
            world.run_until(at_ms);
            at_ms
        } else {
            // Own: it is in the outbox when the slot falls due.
            offer(&mut world, phone, 1, &packet);
            world.run_until(2 * MINUTE);
            world.at(phone).emissions[0].at_ms
        };
        let store = world.engine(phone).store();
        assert_eq!(store.is_local(&id), emitted.is_none());
        let drawn = store.expires_ms(&id).map(|ends| (ends - slot) / UNIT);
        let units = u8::try_from(drawn.expect("the phone holds it")).expect("under 256");

        // A flood, then a neighbour that connects into it.
        world.run_until(3 * MINUTE);
        let junk: Vec<Packet> = (0..30).map(junk).collect();
        for packet in &junk {
            world
                .them_mut(flooder)
                .serve
                .insert(packet.id(), packet.clone());
        }
        let entries: Vec<_> = junk.iter().map(|p| (p.id(), 250)).collect();
        world.announce(flooder, flood, &entries);
        world.run_for(4 * TICK);
        assert_eq!(world.engine(phone).stats().held, 8, "the store is full");
        let late = world.stranger(87);
        world.them_mut(late).want_all = true;
        world.dial(late, phone, wire());
        world.run_for(2 * TICK);
        (
            (slot, units),
            sighting(&world, watcher, id),
            sighting(&world, late, id),
        )
    };
    let (slot, own_first, own_late) = run(None);
    let (_, carried_first, carried_late) = run(Some(slot));
    assert!(
        own_first.0.is_some() && own_first.1.is_some(),
        "the watcher got the packet"
    );
    assert!(
        own_late.0.is_some() && own_late.1.is_some(),
        "the late neighbour got the packet"
    );
    assert!(
        own_first == carried_first,
        "a watching neighbour can tell own from carried"
    );
    assert!(
        own_late == carried_late,
        "a later neighbour can tell own from carried"
    );
}

/// What a neighbour that asks for everything sees of a phone.
#[derive(PartialEq, Eq)]
struct Seeing {
    /// Each announcement: when, and with how many units.
    announced: Vec<(u64, u8)>,
    /// When each packet was handed over.
    handed: Vec<u64>,
    /// Each frame either way: when, and how long.
    frames: Vec<(u64, usize)>,
}

/// A neighbour's view of a phone over twelve minutes, and how many of the
/// packets it was handed open under the circle's key. `outbox` is told each
/// half minute to do what a sharing phone would.
fn neighbours_view(outbox: impl Fn(&mut World, Node, u8)) -> (Seeing, usize) {
    let mut world = World::new();
    let phone = world.phone(Config::default(), 83, Reader::Keyless);
    let watcher = world.stranger(84);
    world.them_mut(watcher).want_all = true;
    world.dial(watcher, phone, wire());
    for step in 0..24 {
        outbox(&mut world, phone, step);
        world.run_for(30_000);
    }
    let seen = world.them(watcher);
    let opens = |got: &&(u64, u64, Packet)| packet::open(&key(), &got.2).is_some();
    let real = seen.got.iter().filter(opens).count();
    let journal = world.journal.iter();
    let seeing = Seeing {
        announced: seen.haves().iter().map(|e| (e.0, e.3)).collect(),
        handed: seen.got.iter().map(|got| got.0).collect(),
        frames: journal.map(|c| (c.sent_ms, c.bytes.len())).collect(),
    };
    (seeing, real)
}

/// T-PRIV-4: a neighbour sees the same number of new packets at the same
/// times, with the same lifetimes, in frames of the same size, whether the
/// phone shares with no circle, one, or ten, and when a circle's slot is
/// purged mid-way.
#[test]
fn emissions_look_the_same_whatever_the_outbox_holds() {
    let (nothing, none_real) = neighbours_view(|_, _, _| {});
    let (one, one_real) = neighbours_view(|world, phone, step| {
        offer(world, phone, 1, &update(step));
    });
    let (ten, ten_real) = neighbours_view(|world, phone, step| {
        for slot in 0..10u8 {
            offer(world, phone, u32::from(slot), &update(step * 10 + slot));
        }
    });
    let (purged, purged_real) = neighbours_view(|world, phone, step| {
        offer(world, phone, 1, &update(step));
        if step == 9 {
            world.drive(phone, |engine, now| engine.purge(CircleSlot(1), now));
        }
    });
    let slots = nothing.handed.len();
    assert!(slots >= 6, "{slots} packets in twelve minutes");
    assert_eq!(none_real, 0);
    assert_eq!(one_real, slots, "every slot carried the circle's update");
    assert_eq!(ten_real, slots);
    // One slot fell after the purge and before the next update.
    assert_eq!(purged_real, slots - 1);
    assert!(nothing == one, "one circle shows");
    assert!(nothing == ten, "ten circles show");
    assert!(nothing == purged, "a purge shows");
}

/// T-PRIV-4 and §5.1 item 5: a phone that slept through twenty emission
/// slots emits exactly one packet on waking, whatever its outbox holds, and
/// its slots fall at the same times either way.
#[test]
fn a_phone_that_slept_through_many_slots_emits_one_packet_on_waking() {
    let run = |slots: u8| {
        let mut world = World::new();
        let phone = world.phone(Config::default(), 85, Reader::Keyless);
        for slot in 0..slots {
            offer(&mut world, phone, u32::from(slot), &update(slot));
        }
        world.run_until(5 * MINUTE);
        world.sleep(phone);
        world.run_until(35 * MINUTE);
        world.wake(phone);
        world.run_until(40 * MINUTE);
        let outbox = world.engine(phone).stats().outbox;
        let times: Vec<u64> = world.at(phone).emissions.iter().map(|e| e.at_ms).collect();
        (times, outbox)
    };
    let (times, _) = run(0);
    let asleep = |at: &&u64| (5 * MINUTE..35 * MINUTE).contains(*at);
    assert_eq!(
        times.iter().filter(asleep).count(),
        0,
        "emitted while asleep"
    );
    let woke = times.iter().filter(|&&at| at == 35 * MINUTE).count();
    assert_eq!(woke, 1, "packets on waking");
    let next = times.iter().find(|&&at| at > 35 * MINUTE);
    assert!(
        next.is_some_and(|&at| at >= 36 * MINUTE),
        "the slot after waking came early"
    );
    for slots in [1, 10] {
        let (with_updates, outbox) = run(slots);
        assert!(
            with_updates == times,
            "slot times differ with {slots} circles"
        );
        // Ten circles had more waiting than slots passed: still one each.
        assert_eq!(outbox, usize::from(slots).saturating_sub(times.len()));
    }
}

/// The units each packet a lone phone emitted started with, by the phone's
/// own store, beside the units its one neighbour first heard for it.
fn first_lifetimes(seed: u64) -> Vec<(u64, u8)> {
    let mut world = World::new();
    let phone = world.phone(Config::default(), seed, Reader::Keyless);
    let watcher = world.stranger(seed + 1);
    world.dial(watcher, phone, wire());
    world.run_until(30 * MINUTE);
    let heard = world.them(watcher);
    let emissions = world.at(phone).emissions.iter();
    emissions
        .filter_map(|e| Some(((e.expires_ms - e.at_ms) / UNIT, heard.first_have(e.id)?.1)))
        .collect()
}

/// T-PRIV-7: the lifetime a phone's own packet starts with is the
/// generator's draw from the top quarter, different from seed to seed; and
/// every value a neighbour first hears for an own packet — the draw, less
/// the tick it waited — it can also first hear for a carried one: a phone
/// handed a packet with one unit more, a millisecond before its tick,
/// announces exactly that value.
///
/// That is the whole of what holds. The top value an own packet shows, 254,
/// needs a peer that announced 255, which an honest phone does only when its
/// slot and its tick run in one call; and no carried packet is ever first
/// announced with 255.
#[test]
fn an_own_packets_first_lifetime_is_drawn_and_is_one_a_carried_packet_can_show() {
    let runs: Vec<Vec<(u64, u8)>> = (0..6)
        .map(|seed| first_lifetimes(910 + 10 * seed))
        .collect();
    assert!(runs[0] == first_lifetimes(910), "one seed, two sequences");
    assert!(runs[0] != runs[1], "two seeds, one sequence");
    let packets: usize = runs.iter().map(Vec::len).sum();
    let drawn: BTreeSet<u64> = runs.iter().flatten().map(|&(start, _)| start).collect();
    assert!(drawn.iter().all(|start| (192..=255).contains(start)));
    assert!(
        packets >= 100 && drawn.len() >= 40,
        "{} different starting values in {packets} packets",
        drawn.len()
    );
    // A tick is a little over one unit: the first announcement has lost one
    // unit or two.
    let mut own = BTreeSet::new();
    for &(start, first) in runs.iter().flatten() {
        let waited = start - u64::from(first);
        assert!((1..=2).contains(&waited), "{start} first heard as {first}");
        own.insert(first);
    }

    let (mut world, _, (feeder, fed), (watcher, _)) = sandwich(Config::default(), 92);
    world.run_until(3 * MINUTE);
    let phase = world
        .them(watcher)
        .haves()
        .first()
        .map(|entry| entry.0 % TICK);
    let phase = phase.expect("the phone announced its own packets on its tick");
    let mut carried = BTreeSet::new();
    for aim in 190..=254u8 {
        let tick = (world.now / TICK + 2) * TICK + phase;
        let packet = junk(u64::from(aim));
        let id = packet.id();
        world.them_mut(feeder).serve.insert(id, packet);
        world.run_until(tick - 1);
        world.announce(feeder, fed, &[(id, aim + 1)]);
        world.run_until(tick);
        let heard = world.them(watcher).first_have(id);
        assert!(heard == Some((tick, aim)), "aimed at {aim}");
        carried.insert(aim);
    }
    assert!(
        own.len() >= 40 && own.is_subset(&carried),
        "an own packet showed a value no carried one did"
    );
}

// ---- a peer that breaks the rules ------------------------------------------

/// What a stranger does on a link of its own to break the rules.
type Attack = fn(&mut World, Node, u64);

/// Every way of breaking the link protocol the test tries, by name.
fn attacks() -> Vec<(&'static str, Attack)> {
    fn raw(world: &mut World, who: Node, link: u64, change: impl FnOnce(&mut Vec<u8>)) {
        let mut plain = frame::hello(&[7; 8], world.frame_size(link)).expect("encodes");
        change(&mut plain);
        world.say(who, link, Some(plain));
    }
    vec![
        ("an unknown frame type", |w, s, l| {
            raw(w, s, l, |plain| plain[0] = 9);
        }),
        ("padding that is not zero", |w, s, l| {
            raw(w, s, l, |plain| plain[400] = 1);
        }),
        ("a body longer than the frame", |w, s, l| {
            raw(w, s, l, |plain| plain[1] = 0xff);
        }),
        ("an inventory entry with no lifetime", |w, s, l| {
            raw(w, s, l, |plain| plain[..3].copy_from_slice(&[2, 0, 17]));
        }),
        ("a frame one byte longer", |w, s, l| {
            raw(w, s, l, |plain| plain.push(0));
        }),
        ("a frame one byte shorter", |w, s, l| {
            raw(w, s, l, |plain| plain.truncate(plain.len() - 1));
        }),
        ("a truncated sealed frame", |w, s, l| {
            w.say_raw(s, l, vec![0x5a; FRAME - 1]);
        }),
        ("an oversized sealed frame", |w, s, l| {
            w.say_raw(s, l, vec![0x5a; 5000]);
        }),
        ("a frame that does not open", |w, s, l| {
            w.say_raw(s, l, vec![0x5a; FRAME]);
        }),
        ("an empty frame", |w, s, l| w.say_raw(s, l, Vec::new())),
        ("a packet nobody asked for", |w, s, l| {
            w.hand(s, l, &junk(2));
        }),
        ("a packet announced but not asked for", |w, s, l| {
            // Thirty are announced to a link whose allowance is sixteen.
            let all: Vec<Packet> = (100..130).map(junk).collect();
            let entries: Vec<_> = all.iter().map(|p| (p.id(), 200)).collect();
            w.announce(s, l, &entries);
            w.run_until(w.now);
            let asked: Vec<PacketId> = w.them(s).wants().iter().map(|want| want.2).collect();
            assert_eq!(asked.len(), 16);
            let unasked = all.iter().find(|p| !asked.contains(&p.id())).expect("most");
            w.hand(s, l, unasked);
        }),
        ("another packet than the one asked for", |w, s, l| {
            w.announce(s, l, &[(junk(3).id(), 200)]);
            w.hand(s, l, &junk(4));
        }),
        ("the second chunk first", |w, s, l| {
            w.announce(s, l, &[(junk(1).id(), 200)]);
            let chunks = world::chunks(&junk(1), w.frame_size(l));
            w.say(s, l, Some(chunks[1].clone()));
        }),
        ("a chunk twice", |w, s, l| {
            w.announce(s, l, &[(junk(1).id(), 200)]);
            let chunks = world::chunks(&junk(1), w.frame_size(l));
            w.say(s, l, Some(chunks[0].clone()));
            w.say(s, l, Some(chunks[0].clone()));
        }),
        ("a chunk left out", |w, s, l| {
            w.announce(s, l, &[(junk(1).id(), 200)]);
            let chunks = world::chunks(&junk(1), w.frame_size(l));
            w.say(s, l, Some(chunks[0].clone()));
            w.say(s, l, Some(chunks[2].clone()));
        }),
        ("the phone's own HELLO value", |w, s, l| {
            let hello = w.them(s).heard.iter().rev().find_map(|h| match h.frame {
                Seen::Hello(value) if h.wire == l => Some(value),
                _ => None,
            });
            let size = w.frame_size(l);
            w.say(s, l, frame::hello(&hello.expect("the phone greeted"), size));
        }),
    ]
}

/// T-SEC-3: a peer that sends a malformed, oversized, truncated,
/// undecryptable, unsolicited, mis-ordered or out-of-turn frame, or shows a
/// `HELLO` value that is the phone's own or an honest neighbour's, is cut
/// off at once; none of it adds a packet or a record to the phone, and the
/// phone's honest link goes on delivering.
#[test]
fn a_peer_that_breaks_the_link_protocol_is_cut_off_at_no_cost() {
    let wanted = junk(1);
    let mut world = World::new();
    let victim = world.phone(Config::default(), 101, Reader::Keyless);
    let honest = world.phone(Config::default(), 102, Reader::Keyless);
    world.link(honest, victim, wire());
    world.run_until(1000);
    let cut_off = |world: &World, link: u64| {
        world
            .closed
            .iter()
            .any(|c| c.wire == link && c.by == Some(victim))
    };

    for (n, (name, attack)) in (0u64..).zip(attacks()) {
        // Six seconds apart: a phone takes twelve new incoming links a minute.
        world.run_until(6000 * (n + 1));
        let before = world.engine(victim).stats();
        let attacker = world.stranger(110 + n);
        let link = world.dial(attacker, victim, wire());
        world.run_until(world.now);
        assert!(
            world.is_up(link) && !cut_off(&world, link),
            "{name}: no link to break"
        );
        attack(&mut world, attacker, link);
        world.run_until(world.now);
        assert!(cut_off(&world, link), "{name}: the link was kept");
        let after = world.engine(victim).stats();
        assert!(
            (after.held, after.records, after.unread)
                == (before.held, before.records, before.unread),
            "{name}: it left something behind"
        );
        assert!(!world.engine(victim).store().has_record(&wanted.id()));
    }

    // A neighbour's HELLO value, replayed: the newer link is the one closed.
    world.run_for(6000);
    let thief = world.stranger(150);
    let tap = world.dial(thief, honest, wire());
    world.run_until(world.now);
    let stolen = world.them(thief).heard.iter().find_map(|h| match h.frame {
        Seen::Hello(value) => Some(value),
        _ => None,
    });
    world.cut(tap);
    world.them_mut(thief).greeting = stolen;
    let link = world.dial(thief, victim, wire());
    world.run_until(world.now);
    assert!(
        cut_off(&world, link),
        "a replayed HELLO value kept its link"
    );
    assert_eq!(world.neighbours(victim), BTreeSet::from([honest]));

    // A flood of announcements: five thousand ids, none ever delivered. The
    // phone asks for a new link's allowance and its window, no more, and
    // holds nothing for the rest.
    world.run_for(6000);
    let before = world.engine(victim).stats();
    let hoarder = world.stranger(151);
    let link = world.dial(hoarder, victim, wire());
    world.run_until(world.now);
    let flood: Vec<(PacketId, u8)> = (5000..10_000).map(|n| (junk(n).id(), 255)).collect();
    world.announce(hoarder, link, &flood);
    world.run_until(world.now);
    let config = Config::default();
    assert_eq!(
        world.them(hoarder).wants().len() as u64,
        config.credit_initial
    );
    world.run_for(40_000);
    let asked: BTreeSet<PacketId> = world.them(hoarder).wants().iter().map(|w| w.2).collect();
    assert_eq!(
        asked.len(),
        config.want_window,
        "one window, asked for twice"
    );
    let after = world.engine(victim).stats();
    assert!(after.records <= before.records + 2 && after.held <= config.store_packets);
    assert!(after.records <= config.record_capacity() && after.unread <= config.unread_packets);

    // The honest link was never touched: its packets still arrive in a tick.
    world.run_until(8 * MINUTE);
    let took = latencies(&world, 2 * MINUTE..7 * MINUTE, &[victim]);
    assert!(
        took.len() >= 3 && worst(&took).is_some_and(|ms| ms <= TICK),
        "{:?}",
        worst(&took)
    );
    let origins = origins(&world);
    assert!(
        world
            .engine(victim)
            .store()
            .ids()
            .all(|id| origins.contains_key(&id)),
        "a packet nobody emitted"
    );
}

/// T-SEC-3, a stalled transfer: a peer announces a packet first, is asked
/// for it, sends one chunk and stops. The phone asks it once more, gives up
/// after two request timeouts and takes the packet from its honest
/// neighbour at the next tick; the stalled chunk and the late remainder add
/// no packet and no record. (The stalling link is not closed for it: the
/// plan's "stalled frames close the link" is not what the engine does.)
#[test]
fn a_stalled_transfer_delays_a_packet_by_two_timeouts_and_adds_nothing() {
    let timeout = Config::default().want_timeout_ms;
    let mut world = World::new();
    let victim = world.phone(Config::default(), 121, Reader::Keyless);
    let honest = world.phone(Config::default(), 122, Reader::Keyless);
    world.link(honest, victim, wire());
    let staller = world.stranger(123);
    let stall = world.dial(staller, victim, wire());
    let packet = update(1);
    let id = packet.id();
    offer(&mut world, honest, 1, &packet);
    let emitted = loop {
        world.run_for(100);
        if let Some(emission) = world.at(honest).emissions.first() {
            break emission.at_ms;
        }
    };
    // Before the honest phone's next tick announces it.
    world.announce(staller, stall, &[(id, 200)]);
    world.run_until(world.now);
    let asked = world.them(staller).wants();
    assert!(
        asked.len() == 1 && asked[0].2 == id,
        "the phone asked the staller"
    );
    let chunks = world::chunks(&packet, world.frame_size(stall));
    world.say(staller, stall, Some(chunks[0].clone()));

    world.run_until(emitted + 2 * timeout);
    assert!(
        !world.engine(victim).store().has_record(&id),
        "the stall cost nothing"
    );
    assert_eq!(world.them(staller).wants().len(), 2, "asked once more");
    world.run_until(emitted + 2 * timeout + 3 * TICK);
    assert!(
        world.engine(victim).store().holds(&id),
        "the honest link was not asked"
    );
    let before = world.engine(victim).stats();

    // The rest of the stalled transfer, late.
    for chunk in &chunks[1..] {
        world.say(staller, stall, Some(chunk.clone()));
    }
    world.run_until(world.now);
    let after = world.engine(victim).stats();
    assert_eq!(
        (after.records, after.held, after.accepted),
        (before.records, before.held, before.accepted)
    );
    assert_eq!(after.duplicates, 1);
    assert_eq!(
        world.at(victim).taken.iter().filter(|t| t.id == id).count(),
        1
    );
}

/// Emission slots every three to seven seconds, to fill a store of
/// forty-eight within minutes.
fn busy() -> Config {
    Config {
        emit_period_ms: 5000,
        emit_jitter_ms: 2000,
        store_packets: 48,
        ..Config::default()
    }
}

/// T-SEC-4, address cycling: a phone's store is full of its own packets and
/// those of a long-lived honest link. An attacker connects sixty times from
/// a fresh address, each time pushing all a new link is asked for —
/// `credit_initial`, sixteen — and leaving. Over nine hundred packets go in;
/// the honest rows never fall below the store less one new link's
/// allowance, because a closed link's rows are the first evicted.
#[test]
fn an_address_cycling_attacker_displaces_no_more_than_one_new_links_allowance() {
    let allowance = usize::try_from(busy().credit_initial).expect("small");
    let mut world = World::new();
    let victim = world.phone(busy(), 131, Reader::Keyless);
    let honest = world.phone(busy(), 132, Reader::Keyless);
    world.link(honest, victim, wire());
    world.run_until(3 * MINUTE);
    assert_eq!(
        world.engine(victim).stats().held,
        48,
        "the store is full of honest packets"
    );

    let mut pushed = BTreeSet::new();
    let (mut least_honest, mut most_hostile) = (usize::MAX, 0);
    for cycle in 0..60u64 {
        let attacker = world.stranger(1300 + cycle);
        let link = world.dial(attacker, victim, wire());
        let flood: Vec<Packet> = (0..40).map(|n| junk(cycle * 100 + n)).collect();
        for packet in &flood {
            world
                .them_mut(attacker)
                .serve
                .insert(packet.id(), packet.clone());
        }
        world.run_until(world.now);
        let entries: Vec<_> = flood.iter().map(|p| (p.id(), 255)).collect();
        world.announce(attacker, link, &entries);
        world.run_for(500);
        pushed.extend(world.them(attacker).wants().iter().map(|want| want.2));
        world.cut(link);

        let store = world.engine(victim).store();
        let hostile = store.ids().filter(|id| pushed.contains(id)).count();
        assert_eq!(store.held(), 48);
        least_honest = least_honest.min(48 - hostile);
        most_hostile = most_hostile.max(hostile);
        world.run_for(5500);
    }
    assert!(
        pushed.len() > 900,
        "the attacker got {} packets in",
        pushed.len()
    );
    assert!(
        most_hostile >= allowance,
        "the attacker never held its allowance"
    );
    assert!(
        least_honest >= 48 - allowance - 1,
        "{least_honest} honest rows left of 48"
    );
}

/// T-SEC-4, eclipse: ten attacker addresses with the strongest signal — four
/// dial in to fill every incoming slot and dial again the moment one is
/// freed, six advertise to draw the outgoing ones — around a phone that
/// also sees six honest phones, weaker. The three signal-chosen outgoing
/// links go to attackers. The fourth is drawn at random among whoever
/// advertises and drawn again every ten minutes, so the phone gets an
/// honest link and honest packets: within twenty-five minutes for each of
/// these seeds.
#[test]
fn an_eclipse_attacker_with_the_strongest_signal_cannot_hold_every_slot() {
    for seed in [141, 142] {
        let mut world = World::new();
        let victim = world.phone(Config::default(), seed, Reader::Keyless);
        let honest: Vec<Node> = (0..6)
            .map(|n| world.phone(Config::default(), seed * 10 + n, Reader::Keyless))
            .collect();
        for (n, &a) in honest.iter().enumerate() {
            world.in_range(victim, a, -70);
            for &b in &honest[n + 1..] {
                world.in_range(a, b, -60);
            }
        }
        let attackers: Vec<Node> = (0..10)
            .map(|n| {
                let attacker = world.stranger(seed * 100 + n);
                let them = world.them_mut(attacker);
                them.fresh_greetings = true;
                them.listens = n >= 4;
                if n >= 4 {
                    world.in_range(victim, attacker, -30);
                }
                attacker
            })
            .collect();
        world.scan(4000);

        let mut first_honest = None;
        let mut hostile_outgoing = 0;
        while world.now < 25 * MINUTE {
            // The dialling attackers take any incoming slot that is free.
            for &attacker in &attackers[..4] {
                if world.wires_of(attacker).is_empty() {
                    world.dial(attacker, victim, wire());
                }
            }
            world.run_for(1000);
            let neighbours = world.neighbours(victim);
            hostile_outgoing = hostile_outgoing.max(
                attackers[4..]
                    .iter()
                    .filter(|a| neighbours.contains(a))
                    .count(),
            );
            if first_honest.is_none() && honest.iter().any(|h| neighbours.contains(h)) {
                first_honest = Some(world.now);
            }
        }
        assert!(
            hostile_outgoing >= 3,
            "the attackers drew {hostile_outgoing} outgoing links"
        );
        assert!(
            first_honest.is_some(),
            "seed {seed}: no honest link in 25 minutes"
        );
        let emitted: BTreeSet<PacketId> = honest
            .iter()
            .flat_map(|&h| world.at(h).emissions.iter().map(|e| e.id))
            .collect();
        let got = world
            .at(victim)
            .taken
            .iter()
            .filter(|t| emitted.contains(&t.id))
            .count();
        assert!(
            got >= 10,
            "seed {seed}: {got} honest packets, first honest link at {first_honest:?}"
        );
    }
}

/// The plan's intake and credit limits a tenth the size, in the same
/// proportion to each other, and a five-minute lifetime: a flood that
/// saturates them for three lifetimes fits in a test, and the honest load
/// stays small beside the intake limit, as it is in the plan.
fn tenth_limits() -> Config {
    Config {
        life_ms: 5 * MINUTE,
        accept_per_min: 24,
        accept_burst: 12,
        credit_per_min: 12,
        credit_initial: 4,
        store_packets: 512,
        ..Config::default()
    }
}

/// T-SEC-SYBIL: five honest phones, every pair linked; an adversary holds
/// three links to one of them and for fifteen minutes — three lifetimes —
/// offers it three times what its intake limit lets in. Measured: how many
/// honest packets emitted under the flood reach the four phones that are two
/// hops from the adversary.
///
/// The floor, from the engine's fairness rule. A phone asks one link for at
/// most `credit_per_min` packets a minute, lowest id first, whoever they
/// belong to, and the attacked phone gains at most `accept_per_min` a minute
/// from its links. With credit half of intake, each neighbour takes about
/// half of what the attacked phone holds — the same half, the flood's and
/// that phone's own alike — and has half its own intake left over. So a
/// packet between two far phones is not held up at all, the attacked
/// phone's own reach a far phone at the share `credit / accept` = 1/2, and
/// delivery to the far phones stays at or above 1/2 overall. That is a
/// share, not a promise for any one packet, and the plan claims nothing
/// beyond the measurement (§6.5). The measured figures are in the assertion
/// messages, with the one for packets *into* the attacked phone, for which
/// there is no floor: the adversary's links take its intake tokens as they
/// fall due (measured here: none of 26 arrived).
#[test]
fn two_hops_from_a_flooding_adversary_honest_delivery_keeps_its_share() {
    let config = tenth_limits();
    let mut world = World::new();
    world.keep_bytes = false;
    for n in 0..5 {
        world.phone(config.clone(), 150 + n, Reader::Keyless);
    }
    // The attacked phone dials all its honest links: its incoming slots are
    // the adversary's to take.
    for a in 0..5 {
        for b in a + 1..5 {
            world.run_for(700);
            world.link(a, b, wire());
        }
    }
    let adversary = world.stranger(159);
    world.them_mut(adversary).fresh_greetings = true;
    let links: Vec<u64> = (0..3).map(|_| world.dial(adversary, 0, wire())).collect();
    world.run_until(MINUTE);

    let (from, to) = (MINUTE, 16 * MINUTE);
    let mut next = 0;
    while world.now < to {
        for &link in &links {
            let fresh: Vec<Packet> = (next..next + 3).map(junk).collect();
            next += 3;
            for packet in &fresh {
                let them = world.them_mut(adversary);
                them.serve.insert(packet.id(), packet.clone());
            }
            let entries: Vec<_> = fresh.iter().map(|p| (p.id(), 255)).collect();
            world.announce(adversary, link, &entries);
            world.run_for(2500);
        }
    }
    // Saturated: the adversary alone filled nine tenths of what the
    // attacked phone's intake limit allows in those fifteen minutes.
    let flooded = world.them(adversary).wants().len();
    assert!(
        flooded >= 324,
        "the attacked phone took {flooded} flood packets"
    );
    world.run_until(to + config.life_ms);

    // Emitted with a whole lifetime of flood ahead.
    let window = from..to - config.life_ms;
    let ratio = |origins: &[Node], destinations: &[Node]| {
        let (mut due, mut got) = (0u32, 0u32);
        for &origin in origins {
            let emissions = world.at(origin).emissions.iter();
            for emission in emissions.filter(|e| window.contains(&e.at_ms)) {
                for &node in destinations.iter().filter(|&&node| node != origin) {
                    let taken = &world.at(node).taken;
                    due += 1;
                    got += u32::from(taken.iter().any(|t| t.id == emission.id));
                }
            }
        }
        (got, due)
    };
    let far = [1, 2, 3, 4];
    let between = ratio(&far, &far);
    let outward = ratio(&[0], &far);
    let inward = ratio(&far, &[0]);
    let overall = (between.0 + outward.0, between.1 + outward.1);
    let measured = format!(
        "delivered of due: far to far {between:?}, attacked phone to far {outward:?}, \
         far to attacked phone {inward:?}"
    );
    assert!(between.1 > 60 && outward.1 > 20, "{measured}");
    assert_eq!(between.0, between.1, "{measured}");
    assert!(2 * overall.0 >= overall.1, "{measured}");
}

// ---- counters and the unread queue -----------------------------------------

/// T-STAT-1 (engine part): on a line, where a packet has one way from end to
/// end, each phone's "passed on" count equals what the others' readers
/// show: the packets it did not emit and could not open that a phone on its
/// far side took. A member's opened updates, its own packets and packets
/// nobody has read yet are not counted; once somebody reads, the unread ones
/// are.
#[test]
fn passed_on_equals_what_the_neighbours_took_through_the_phone() {
    let mut world = World::new();
    let readers = [
        Reader::Keyless,
        Reader::Keyless,
        Reader::Member(vec![key()]),
        Reader::Absent,
        Reader::Keyless,
    ];
    for (n, reader) in (0u64..).zip(readers) {
        world.phone(Config::default(), 160 + n, reader);
    }
    for near in 0..4 {
        world.run_for(700);
        world.link(near, near + 1, wire());
    }
    for n in 1..=6u8 {
        offer(&mut world, 0, 1, &update(n));
        world.run_for(2 * MINUTE);
    }

    // Through phone `via`, by what the phones on either side took. Phone 3
    // has no reader: what reached 4 passed it, and what reached it passed 2.
    let emitted = |node: Node| -> BTreeSet<PacketId> {
        world.at(node).emissions.iter().map(|e| e.id).collect()
    };
    let took =
        |node: Node| -> BTreeSet<PacketId> { world.at(node).taken.iter().map(|t| t.id).collect() };
    let opened: BTreeSet<PacketId> = world
        .at(2)
        .taken
        .iter()
        .filter(|t| t.opened.is_some())
        .map(|t| t.id)
        .collect();
    assert_eq!(opened.len(), 6, "the member opened every update");
    let up = |from: std::ops::Range<Node>| from.flat_map(emitted).collect::<BTreeSet<_>>();
    let through_1 =
        up(0..1).intersection(&took(2)).count() + up(2..5).intersection(&took(0)).count();
    let through_2 = up(0..2)
        .intersection(&took(4))
        .filter(|id| !opened.contains(id))
        .count()
        + up(3..5).intersection(&took(1)).count();
    let through_3 =
        up(0..3).intersection(&took(4)).count() + up(4..5).intersection(&took(2)).count();
    assert!(through_1 > 20 && through_2 > 20 && through_3 > 20);

    let passed = |world: &World, node: Node| world.engine(node).stats().passed_on;
    assert_eq!(passed(&world, 0), 0, "an end of the line passes nothing on");
    assert_eq!(passed(&world, 4), 0);
    assert_eq!(passed(&world, 1), through_1 as u64);
    assert_eq!(
        passed(&world, 2),
        through_2 as u64,
        "opened updates are not counted"
    );
    assert_eq!(passed(&world, 3), 0, "nothing is counted before it is read");

    // The app starts on phone 3 and opens nothing.
    world.set_reader(3, Reader::Keyless);
    assert_eq!(passed(&world, 3), through_3 as u64);
    // Sent more than once, to more than one link, counted once: the counts
    // are far below the packets sent.
    assert!(world.engine(1).stats().sent > passed(&world, 1));
}

/// T-BG-3: packets that arrived while nobody was reading are handed to the
/// reader later — after their lifetime ended, after their bytes left the
/// store, after their records were forgotten — whole and in arrival order;
/// past the queue's size the oldest are dropped.
#[test]
fn packets_nobody_read_in_their_lifetime_are_still_read_later() {
    let config = Config {
        unread_packets: 8,
        ..Config::default()
    };
    let (mut world, phone, (feeder, fed), _) = sandwich(config, 171);
    world.set_reader(phone, Reader::Absent);
    // A phone asks for what one frame announces in id order: so they arrive.
    let mut first: Vec<Packet> = (0..5).map(junk).collect();
    first.sort_by_key(Packet::id);
    for packet in &first {
        world
            .them_mut(feeder)
            .serve
            .insert(packet.id(), packet.clone());
    }
    world.run_until(3000);
    // Two units to live: about nine seconds.
    let entries: Vec<_> = first.iter().map(|p| (p.id(), 2)).collect();
    world.announce(feeder, fed, &entries);

    world.run_until(3000 + 2 * LIFE + MINUTE);
    let store = world.settled(phone).store();
    assert!(
        first.iter().all(|p| !store.has_record(&p.id())),
        "the records are gone"
    );
    assert_eq!(store.unread(), 5);
    let read = world.drive(phone, |engine, _| engine.take_unread(3));
    assert!(read == first[..3], "the oldest three, whole, in order");

    // Twelve more into a queue of eight that still holds two.
    let more: Vec<Packet> = (10..22).map(junk).collect();
    for packet in &more {
        world
            .them_mut(feeder)
            .serve
            .insert(packet.id(), packet.clone());
        world.announce(feeder, fed, &[(packet.id(), 2)]);
        world.run_for(1000);
    }
    assert_eq!(world.engine(phone).stats().unread, 8);
    world.run_for(LIFE);
    let read = world.drive(phone, |engine, _| engine.take_unread(usize::MAX));
    assert!(
        read == more[4..],
        "the newest eight; the oldest six were dropped"
    );
    assert_eq!(world.engine(phone).stats().unread, 0);
}

// ---- scale ------------------------------------------------------------------

/// T-PERF-1: the plan's ceiling is about 150 phones for a 2048-packet store
/// (§6.6: a mesh of `n` holds about `13 n`). A debug build seals and opens
/// every frame unoptimised, so this runs the same load per store slot at a
/// size that takes seconds: 16 phones with a store of 218 (2048 × 16 / 150),
/// every other limit the plan's, each phone linked to six others by links of
/// 185-byte frames capped at 2 kB/s each way with 30 ms in the air, for a
/// lifetime and a little.
///
/// Bounds, asserted: every packet reaches every phone, once; the 95th percentile
/// of logical delivery latency over every packet and phone is within two
/// ticks and the worst within three (the mesh is three hops across); and
/// the fullest store ever holds between `12 n` and its cap, never reaching
/// it, so nothing is evicted.
#[test]
fn at_the_supported_size_latency_and_store_occupancy_stay_bounded() {
    const N: usize = 16;
    let config = Config {
        store_packets: 218,
        ..Config::default()
    };
    let radio = Radio {
        max_frame: 185,
        delay_ms: 30,
        bytes_per_s: 2000,
    };
    let mut world = World::new();
    world.keep_bytes = false;
    for seed in 0..N as u64 {
        world.phone(config.clone(), 180 + seed, Reader::Keyless);
    }
    // Each phone dials its next two neighbours round a ring and one phone
    // across it.
    for a in 0..N {
        for step in [1, 2, 7] {
            world.run_for(211);
            world.link(a, (a + step) % N, radio);
        }
    }
    let mut peak = 0;
    while world.now < 22 * MINUTE {
        world.run_for(15_000);
        let fullest = (0..N).map(|n| world.engine(n).stats().held).max();
        peak = peak.max(fullest.unwrap_or(0));
    }
    let took = latencies(&world, MINUTE..21 * MINUTE, &world.phones());
    assert!(took.len() > 3000, "{} deliveries were due", took.len());
    assert_eq!(delivered(&took), took.len(), "packets were lost");
    let mut took: Vec<u64> = took.into_iter().flatten().collect();
    took.sort_unstable();
    let (p95, worst) = (took[took.len() * 95 / 100], took[took.len() - 1]);
    assert!(
        p95 <= 2 * TICK && worst <= 3 * TICK,
        "p95 {p95} ms, worst {worst} ms"
    );
    assert!(
        peak >= 12 * N && peak < config.store_packets,
        "the fullest store held {peak} of {}",
        config.store_packets
    );
    // T-LIFE-2 on links that take time: no phone was sent a packet it had a
    // record of, and none took a packet twice.
    for node in world.phones() {
        assert_eq!(world.engine(node).stats().duplicates, 0);
        let taken = &world.at(node).taken;
        let ids: BTreeSet<PacketId> = taken.iter().map(|t| t.id).collect();
        assert_eq!(ids.len(), taken.len(), "a packet taken twice");
    }
}

/// §5.1, T-SEC-7 at the mesh: a phone whose mesh is turned off keeps no
/// packet, record or unread entry, closes its links, sends nothing more —
/// and its neighbours' own link carries on.
#[test]
fn a_phone_turned_off_keeps_nothing_and_falls_silent() {
    let mut world = crowd(3, 191);
    all_in_range(&mut world);
    world.scan(4000);
    world.set_reader(1, Reader::Absent);
    world.run_until(4 * MINUTE);
    let before = world.engine(1).stats();
    assert!(before.held > 3 && before.unread > 1 && before.links == 2);

    world.stop(1);
    let off = world.now;
    let after = world.engine(1).stats();
    let kept = (after.held, after.records, after.unread, after.outbox);
    assert_eq!(kept, (0, 0, 0, 0));
    assert_eq!(after.links, 0);
    assert!(world.drive(1, |engine, _| engine.take_unread(9)).is_empty());
    world.run_until(8 * MINUTE);
    assert!(
        world.neighbours(1).is_empty(),
        "nobody connects to a phone that is off"
    );
    let sent_later = world
        .journal
        .iter()
        .filter(|c| c.from == 1 && c.sent_ms > off);
    assert_eq!(sent_later.count(), 0, "frames from a phone that is off");
    let took = latencies(&world, 5 * MINUTE..7 * MINUTE, &[0, 2]);
    assert!(took.len() >= 2 && worst(&took).is_some_and(|ms| ms <= TICK));
}
