//! The mesh plane: every device's mesh engine, and the radio between them.
//!
//! The engines are the product's own (`haven_core::mesh::engine::MeshEngine`),
//! one a device. The plane is their environment: which devices are in radio
//! range, the frames carried between them, and the engines' clock.
//!
//! # Logical time
//!
//! The clock is a number a scenario moves ([`MeshPlane::run`]), never one the
//! process reads: a run does not wait ninety seconds for an emission slot, it
//! steps to it. Each engine's generator is seeded from the world's seed and
//! its device's ordinal, and whatever is due at one instant runs in device
//! order, so one seed carries the same frames in the same order
//! ([`MeshPlane::trace`]).
//!
//! # The hand-off
//!
//! As the app's bridge does before every engine call (`MeshSlot::apply`,
//! `haven/rust_builder/src/api.rs`), the plane applies what a device's session
//! left for its engine: a purge empties its slot, an offer fills it for as
//! long as its event still has, never longer than a location lives, and one
//! already expired empties the slot instead. How long an event still has is
//! the plane's one wall-clock reading: an expiration is an instant a device
//! stamped by its wall clock.
//!
//! # Why not `plane.rs`
//!
//! That file is the three environment traits a world is generic over. No
//! world is generic over a radio: a scenario that needs one builds it over
//! the world's devices.
//!
//! Nothing here is `Debug`: a packet and its id tell one packet from another
//! (Rule 15).

use std::sync::Arc;

use haven_core::location::LOCATION_MESSAGE_RETENTION_SECS;
use haven_core::mesh::engine::{Config, LinkId, MeshEngine, Output, Role, Stats};
use haven_core::mesh::frame::MAX_FRAME_LEN;
use haven_core::mesh::handoff::{Handoff, Op};
use haven_core::nostr::mls::types::LocationMessageResult;
use haven_core::relay::fanout::{FanoutClock as _, WallClock};
use rand::rngs::StdRng;
use rand::SeedableRng;
use sha2::{Digest, Sha256};

use crate::clock::WallNow;
use crate::rig::{DeviceTag, LogDrain, RelayPlane, RigError, SimDevice, SimWorld, TimelineSink};

/// The longest an offered location waits in an engine's outbox: a location
/// event's whole life, as the bridge has it.
const OFFER_MAX_MS: u64 = LOCATION_MESSAGE_RETENTION_SECS * 1_000;

/// How many packets one drive reads, as the bridge's does.
const DRIVE_PACKETS: usize = 256;

/// One device's engine, and where its session leaves what it wraps.
struct Node {
    engine: MeshEngine<StdRng>,
    handoff: Arc<Handoff>,
}

impl Node {
    /// The bridge's rule (`MeshSlot::apply`), on this plane's clock.
    fn apply(&mut self, now_ms: u64, wall: WallNow) {
        let wall_ms = u64::try_from(wall.secs())
            .unwrap_or(0)
            .saturating_mul(1_000);
        for (slot, op) in self.handoff.take() {
            match op {
                Op::Offer {
                    packet,
                    expires_at_secs,
                } if expires_at_secs.saturating_mul(1_000) > wall_ms => {
                    let left_ms = expires_at_secs.saturating_mul(1_000) - wall_ms;
                    let expires_ms = now_ms.saturating_add(left_ms.min(OFFER_MAX_MS));
                    self.engine.offer(slot, packet, expires_ms, now_ms);
                }
                // An offer whose event has expired still replaces what
                // waited: nothing older goes out in its place.
                Op::Offer { .. } | Op::Purge => self.engine.purge(slot, now_ms),
            }
        }
    }
}

/// How long a scenario turns a device's mesh on for: longer than any arm.
const MESH_ON_MS: u64 = 60 * 60 * 1_000;

/// Turns `device`'s mesh on, as the app's enable does: whether it is on.
///
/// # Errors
///
/// [`RigError::SessionNotLive`] if the device has no session.
pub async fn turn_on(device: &SimDevice) -> Result<bool, RigError> {
    let until_ms = WallClock.now_ms().saturating_add(MESH_ON_MS);
    Ok(device.session()?.mesh_on_until(until_ms).await)
}

/// What one [`MeshPlane::drive`] did.
///
/// No `Debug`: the locations are decrypted content.
pub struct Driven {
    /// How many updates the session read for the first time.
    pub from_circles: u64,
    /// The locations taken in.
    pub replayed: Vec<LocationMessageResult>,
    /// How many events the drive's own transport was asked to send. A mesh
    /// drive calls no relay, so anything but zero is the product's defect.
    pub sent: usize,
}

/// Every device's mesh engine on one logical clock, and the links between
/// them.
pub struct MeshPlane {
    now_ms: u64,
    nodes: Vec<Node>,
    /// Each live link: its id on both engines, the device that connected,
    /// and the one it connected to.
    links: Vec<(LinkId, usize, usize)>,
    next_link: u64,
    carried: u64,
    trace: Sha256,
}

impl MeshPlane {
    /// One engine for each hand-off, in device order, each generator seeded
    /// from `seed` and its ordinal.
    #[must_use]
    pub fn new(seed: u64, handoffs: Vec<Arc<Handoff>>) -> Self {
        let nodes = (0_u64..)
            .zip(handoffs)
            .map(|(ordinal, handoff)| Node {
                engine: MeshEngine::new(
                    Config::default(),
                    StdRng::seed_from_u64(seed ^ (ordinal + 1).rotate_left(32)),
                    0,
                ),
                handoff,
            })
            .collect();
        Self {
            now_ms: 0,
            nodes,
            links: Vec::new(),
            next_link: 0,
            carried: 0,
            trace: Sha256::new(),
        }
    }

    /// The plane over `devices`, each engine fed by its device's session.
    ///
    /// # Errors
    ///
    /// [`RigError::SessionNotLive`] if a device has no session.
    pub fn over(seed: u64, devices: &[SimDevice]) -> Result<Self, RigError> {
        let handoffs = devices
            .iter()
            .map(|device| Ok(device.session()?.mesh_handoff()))
            .collect::<Result<_, RigError>>()?;
        Ok(Self::new(seed, handoffs))
    }

    fn index(&self, device: DeviceTag) -> Result<usize, RigError> {
        usize::try_from(device.ordinal())
            .ok()
            .filter(|index| *index < self.nodes.len())
            .ok_or(RigError::UnknownTarget)
    }

    /// One emission slot at its longest and the announce ticks behind it:
    /// run for this long, every engine has emitted once and what it emitted
    /// has crossed the links in range.
    #[must_use]
    pub fn slot_ms() -> u64 {
        let config = Config::default();
        config.emit_period_ms + config.emit_jitter_ms + 4 * config.tick_ms
    }

    /// Puts `from` and `to` in radio range: `from` connects to `to`.
    ///
    /// # Errors
    ///
    /// [`RigError::UnknownTarget`] for a device the plane has no engine for.
    pub fn link(&mut self, from: DeviceTag, to: DeviceTag) -> Result<(), RigError> {
        let (from, to) = (self.index(from)?, self.index(to)?);
        let link = LinkId(self.next_link);
        self.next_link += 1;
        for (end, role) in [(from, Role::Central), (to, Role::Peripheral)] {
            self.nodes[end]
                .engine
                .link_up(link, role, MAX_FRAME_LEN, None, self.now_ms);
        }
        self.links.push((link, from, to));
        Ok(())
    }

    /// Moves every engine's clock `span_ms` on, running each engine's timers
    /// at every instant one of them has work and carrying what they send.
    pub fn run(&mut self, span_ms: u64, wall: WallNow) {
        let until_ms = self.now_ms.saturating_add(span_ms);
        loop {
            self.settle(wall);
            let next_ms = self
                .nodes
                .iter()
                .filter_map(|node| node.engine.next_wake_ms())
                .min()
                .map_or(until_ms, |wake_ms| wake_ms.max(self.now_ms + 1));
            if next_ms >= until_ms {
                break;
            }
            self.now_ms = next_ms;
        }
        self.now_ms = until_ms;
        self.settle(wall);
    }

    /// Applies every hand-off, runs the timers due now, and carries frames
    /// between linked engines until none has one to send.
    fn settle(&mut self, wall: WallNow) {
        let now_ms = self.now_ms;
        for node in &mut self.nodes {
            node.apply(now_ms, wall);
            node.engine.advance(now_ms);
        }
        let mut moved = true;
        while moved {
            moved = false;
            for from in 0..self.nodes.len() {
                while let Some(output) = self.nodes[from].engine.poll_output(now_ms) {
                    moved = true;
                    self.carry(from, output);
                }
            }
        }
    }

    /// Does what `from`'s engine asked of its radio.
    fn carry(&mut self, from: usize, output: Output) {
        let now_ms = self.now_ms;
        let peer = |links: &[(LinkId, usize, usize)], link: LinkId| {
            links.iter().find_map(|&(id, a, b)| {
                (id == link && (a == from || b == from)).then_some(if a == from { b } else { a })
            })
        };
        match output {
            Output::Frame { link, bytes } => {
                if let Some(to) = peer(&self.links, link) {
                    self.carried += 1;
                    for part in [now_ms, from as u64, to as u64] {
                        self.trace.update(part.to_be_bytes());
                    }
                    self.trace.update(&bytes);
                    self.nodes[to].engine.receive(link, &bytes, now_ms);
                }
            }
            Output::Close { link } => {
                if let Some(to) = peer(&self.links, link) {
                    self.nodes[to].engine.link_down(link, now_ms);
                }
                self.links.retain(|&(id, _, _)| id != link);
            }
            // No sighting is ever reported: a scenario says who is in range.
            Output::Connect { .. } => {}
        }
    }

    /// Hands `device`'s session the packets its engine accepted from links
    /// (`Publishing::mesh_drive`), and marks read what the drive settled.
    ///
    /// # Errors
    ///
    /// [`RigError`] if the device has no engine here or no session.
    pub async fn drive<R: RelayPlane, T: TimelineSink, L: LogDrain>(
        &mut self,
        world: &SimWorld<R, T, L>,
        device: DeviceTag,
        wall: WallNow,
    ) -> Result<Driven, RigError> {
        let (index, now_ms) = (self.index(device)?, self.now_ms);
        let node = &mut self.nodes[index];
        node.apply(now_ms, wall);
        let taken = node.engine.take_unread(DRIVE_PACKETS);
        let (drive, sent) = world.mesh_drive(device, taken).await?;
        for (packet, opened) in &drive.read {
            self.nodes[index].engine.mark_read(*packet, *opened);
        }
        Ok(Driven {
            from_circles: drive.from_circles,
            replayed: drive.replayed,
            sent,
        })
    }

    /// `device`'s engine's own counts.
    ///
    /// # Errors
    ///
    /// [`RigError::UnknownTarget`] for a device the plane has no engine for.
    pub fn stats(&self, device: DeviceTag) -> Result<Stats, RigError> {
        Ok(self.nodes[self.index(device)?].engine.stats())
    }

    /// How many frames crossed a link.
    #[must_use]
    pub const fn carried(&self) -> u64 {
        self.carried
    }

    /// A digest of every frame carried so far: when, from whom, to whom, and
    /// its bytes. Compared, never rendered.
    #[must_use]
    pub fn trace(&self) -> [u8; 32] {
        self.trace.clone().finalize().into()
    }
}

#[cfg(test)]
mod tests {
    use haven_core::mesh::engine::CircleSlot;
    use haven_core::mesh::packet::{cover_packet, Packet, PacketId};

    use super::*;

    /// The packets `device`'s engine accepted from links and has not handed
    /// out, as a drive would take them.
    fn unread(plane: &mut MeshPlane, device: DeviceTag) -> Vec<PacketId> {
        let index = plane.index(device).expect("the device has an engine");
        plane.nodes[index]
            .engine
            .take_unread(DRIVE_PACKETS)
            .iter()
            .map(Packet::id)
            .collect()
    }

    fn device(ordinal: u32) -> DeviceTag {
        DeviceTag::new(ordinal)
    }

    fn packet(seed: u64) -> Packet {
        cover_packet(&mut StdRng::seed_from_u64(seed))
    }

    /// A wall instant, and the expiration of an event with its whole life
    /// left at it.
    fn wall_and_expiry() -> (WallNow, u64) {
        let wall = WallNow::from_secs(1_800_000_000);
        let expires = u64::try_from(wall.secs()).expect("after 1970") + 200;
        (wall, expires)
    }

    /// Two devices in range, the first with `offered` left for its engine.
    fn pair(seed: u64, offered: &Packet) -> (MeshPlane, WallNow) {
        let (wall, expires) = wall_and_expiry();
        let handoffs = vec![Arc::new(Handoff::default()), Arc::new(Handoff::default())];
        handoffs[0].offer(CircleSlot(0), offered.clone(), expires);
        let mut plane = MeshPlane::new(seed, handoffs);
        plane.link(device(0), device(1)).expect("both have engines");
        (plane, wall)
    }

    #[test]
    fn an_offered_packet_reaches_the_device_in_range_and_no_other() {
        let offered = packet(7);
        let (wall, expires) = wall_and_expiry();
        let handoffs: Vec<Arc<Handoff>> = (0..3).map(|_| Arc::new(Handoff::default())).collect();
        handoffs[0].offer(CircleSlot(0), offered.clone(), expires);
        let mut plane = MeshPlane::new(1, handoffs);
        plane.link(device(0), device(1)).expect("both have engines");

        plane.run(MeshPlane::slot_ms(), wall);

        assert!(
            unread(&mut plane, device(1)).contains(&offered.id()),
            "the device in range accepted the packet"
        );
        assert!(
            unread(&mut plane, device(2)).is_empty(),
            "a device out of range is carried nothing"
        );
        assert!(
            !unread(&mut plane, device(0)).contains(&offered.id()),
            "a device is never handed back what it emitted"
        );
        assert!(plane.carried() > 0, "frames crossed the link");
    }

    #[test]
    fn a_packet_crosses_two_links_to_a_device_its_sender_cannot_reach() {
        let offered = packet(7);
        let (wall, expires) = wall_and_expiry();
        let handoffs: Vec<Arc<Handoff>> = (0..3).map(|_| Arc::new(Handoff::default())).collect();
        handoffs[0].offer(CircleSlot(0), offered.clone(), expires);
        let mut plane = MeshPlane::new(1, handoffs);
        plane.link(device(0), device(1)).expect("both have engines");
        plane.link(device(1), device(2)).expect("both have engines");

        plane.run(MeshPlane::slot_ms(), wall);

        assert!(
            unread(&mut plane, device(2)).contains(&offered.id()),
            "the middle device passed it on"
        );
    }

    #[test]
    fn one_seed_carries_the_same_frames_and_another_seed_others() {
        let offered = packet(7);
        let run = |seed| {
            let (mut plane, wall) = pair(seed, &offered);
            plane.run(MeshPlane::slot_ms(), wall);
            (plane.trace(), plane.carried())
        };
        let (first, carried) = run(11);
        assert!(carried > 0, "premise: the run carried frames");
        assert!(
            run(11) == (first, carried),
            "the same seed carries the same frames in the same order"
        );
        assert!(
            run(12).0 != first,
            "another seed draws other handshakes and slots"
        );
    }

    #[test]
    fn an_offer_whose_event_has_expired_empties_the_slot_instead() {
        let (stale, late) = (packet(7), packet(8));
        let (mut plane, wall) = pair(1, &stale);
        // Applied, and waiting for its emission slot.
        plane.run(1, wall);
        assert!(
            plane.stats(device(0)).expect("an engine").outbox == 1,
            "premise: the first offer waits in the outbox"
        );

        let expired = u64::try_from(wall.secs()).expect("after 1970") - 1;
        plane.nodes[0]
            .handoff
            .offer(CircleSlot(0), late.clone(), expired);
        plane.run(MeshPlane::slot_ms(), wall);

        assert!(
            plane.stats(device(0)).expect("an engine").outbox == 0,
            "the expired offer emptied the slot"
        );
        let read = unread(&mut plane, device(1));
        assert!(
            !read.contains(&stale.id()) && !read.contains(&late.id()),
            "neither the expired event nor the one it replaced was emitted"
        );
    }

    #[test]
    fn a_purge_withdraws_what_waited() {
        let offered = packet(7);
        let (mut plane, wall) = pair(1, &offered);
        plane.run(1, wall);
        plane.nodes[0].handoff.purge(CircleSlot(0));
        plane.run(MeshPlane::slot_ms(), wall);
        assert!(
            !unread(&mut plane, device(1)).contains(&offered.id()),
            "a purged slot emits nothing"
        );
    }

    #[test]
    fn an_offer_waits_a_locations_life_and_no_longer() {
        // Five circles' offers, each stamped to expire a day ahead — a wall
        // clock set back since. One goes out a slot, the first within one
        // slot and the fourth no sooner than four of the shortest.
        let config = Config::default();
        let (shortest, longest) = (
            config.emit_period_ms - config.emit_jitter_ms,
            config.emit_period_ms + config.emit_jitter_ms,
        );
        assert!(
            longest < OFFER_MAX_MS && 4 * shortest > OFFER_MAX_MS,
            "premise: the first slot is inside a location's life and the fourth past it"
        );
        let (wall, _) = wall_and_expiry();
        let far = u64::try_from(wall.secs()).expect("after 1970") + 86_400;
        let offered: Vec<Packet> = (0..5).map(packet).collect();
        let handoffs = vec![Arc::new(Handoff::default()), Arc::new(Handoff::default())];
        for (slot, packet) in (0..).zip(&offered) {
            handoffs[0].offer(CircleSlot(slot), packet.clone(), far);
        }
        let mut plane = MeshPlane::new(1, handoffs);
        plane.link(device(0), device(1)).expect("both have engines");

        plane.run(5 * longest + 2 * config.tick_ms, wall);

        let read = unread(&mut plane, device(1));
        let arrived = offered
            .iter()
            .filter(|packet| read.contains(&packet.id()))
            .count();
        assert!(
            (1..=3).contains(&arrived),
            "what waited past a location's life was never emitted"
        );
    }

    #[test]
    fn a_device_the_plane_has_no_engine_for_is_refused() {
        let mut plane = MeshPlane::new(1, vec![Arc::new(Handoff::default())]);
        assert_eq!(
            plane.link(device(0), device(1)),
            Err(RigError::UnknownTarget)
        );
        assert!(plane.stats(device(4)).is_err());
    }
}
