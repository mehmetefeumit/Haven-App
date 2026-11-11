//! Where session code leaves a wrapped location for the mesh engine, and
//! where the engine's owner collects it (plan §5.1).
//!
//! The relay path's send and the radio never meet: the send puts a packet
//! here and returns, and the engine's owner drains this before it calls the
//! engine. What waits is the last thing said of each outbox slot — an offer
//! replaces what waited, a purge removes it — which is all the engine acts
//! on, so nothing here grows with what is never drained: at most
//! [`Handoff::SLOTS`] entries, one packet each.
//!
//! A slot is an opaque local number. Nothing here says which circle is
//! behind one, and nothing is `Debug`.

use std::collections::BTreeMap;
use std::sync::{Mutex, PoisonError};

use super::engine::CircleSlot;
use super::packet::Packet;

/// The last thing said of one outbox slot.
pub enum Op {
    /// Put `packet` in the slot, replacing what waits there. Its event
    /// expires at `expires_at_secs`, wall-clock seconds: the engine's owner
    /// turns that into the engine's own clock, and drops an offer whose
    /// event has already expired.
    Offer {
        /// The wrapped event.
        packet: Packet,
        /// The event's NIP-40 `expiration`.
        expires_at_secs: u64,
    },
    /// Empty the slot.
    Purge,
}

/// The offers and purges session code has made since the engine's owner last
/// took them.
#[derive(Default)]
pub struct Handoff {
    ops: Mutex<BTreeMap<CircleSlot, Op>>,
}

impl Handoff {
    /// How many slots there are: session code hands out `CircleSlot(n)` for
    /// `n` below this and no other, so what waits here is bounded however
    /// long it goes undrained. No more than the engine's own
    /// `Config::outbox_slots` default.
    pub const SLOTS: u32 = 64;

    /// Leaves `packet` for `slot`, in place of whatever waits for it.
    ///
    /// Never waits: when the lock is held — the owner is taking what waits,
    /// or another circle is being offered — the packet is dropped. The mesh
    /// is lossy by design, and the relay send this is called from is not
    /// held up for it.
    pub fn offer(&self, slot: CircleSlot, packet: Packet, expires_at_secs: u64) {
        if slot.0 >= Self::SLOTS {
            return;
        }
        if let Ok(mut ops) = self.ops.try_lock() {
            ops.insert(
                slot,
                Op::Offer {
                    packet,
                    expires_at_secs,
                },
            );
        }
    }

    /// Empties `slot`: whatever waits here for it goes, and the engine is
    /// told to empty its own. Never dropped — the lock is only ever held for
    /// one insert or one take.
    pub fn purge(&self, slot: CircleSlot) {
        if slot.0 < Self::SLOTS {
            self.ops().insert(slot, Op::Purge);
        }
    }

    /// Everything that waits, by slot, leaving nothing: what the engine's
    /// owner applies — `MeshEngine::purge` for a purge, `MeshEngine::offer`
    /// for an offer — before any other engine call.
    #[must_use]
    pub fn take(&self) -> Vec<(CircleSlot, Op)> {
        std::mem::take(&mut *self.ops()).into_iter().collect()
    }

    fn ops(&self) -> std::sync::MutexGuard<'_, BTreeMap<CircleSlot, Op>> {
        self.ops.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[cfg(test)]
mod tests {
    use rand::rngs::StdRng;
    use rand::SeedableRng;

    use super::*;
    use crate::mesh::engine::{Config, MeshEngine};
    use crate::mesh::packet::cover_packet;

    fn packet(seed: u64) -> Packet {
        cover_packet(&mut StdRng::seed_from_u64(seed))
    }

    /// What waits, as `(slot, Some(packet) | None for a purge)`.
    fn taken(handoff: &Handoff) -> Vec<(u32, Option<Packet>)> {
        handoff
            .take()
            .into_iter()
            .map(|(slot, op)| match op {
                Op::Offer { packet, .. } => (slot.0, Some(packet)),
                Op::Purge => (slot.0, None),
            })
            .collect()
    }

    #[test]
    fn the_last_thing_said_of_a_slot_is_what_waits() {
        let handoff = Handoff::default();
        handoff.offer(CircleSlot(3), packet(1), 10);
        handoff.offer(CircleSlot(3), packet(2), 11);
        handoff.offer(CircleSlot(5), packet(3), 12);
        handoff.purge(CircleSlot(5));
        handoff.purge(CircleSlot(7));
        handoff.offer(CircleSlot(7), packet(4), 13);

        assert!(taken(&handoff) == [(3, Some(packet(2))), (5, None), (7, Some(packet(4))),]);
        assert!(handoff.take().is_empty(), "a take left something waiting");
    }

    #[test]
    fn an_offer_carries_its_events_expiration() {
        let handoff = Handoff::default();
        handoff.offer(CircleSlot(0), packet(1), 1_800_000_228);
        assert!(matches!(
            handoff.take().as_slice(),
            [(
                CircleSlot(0),
                Op::Offer {
                    expires_at_secs: 1_800_000_228,
                    ..
                }
            )]
        ));
    }

    /// Never drained, it holds one entry a slot and no slot past the last.
    #[test]
    fn what_waits_is_bounded_by_the_slots() {
        let handoff = Handoff::default();
        for round in 0..3_u64 {
            for slot in 0..Handoff::SLOTS + 8 {
                handoff.offer(CircleSlot(slot), packet(round), 1);
                handoff.purge(CircleSlot(slot.wrapping_add(1)));
            }
        }
        handoff.offer(CircleSlot(u32::MAX), packet(9), 1);
        handoff.purge(CircleSlot(u32::MAX));
        let waiting = handoff.take();
        assert!(
            waiting.len() == Handoff::SLOTS as usize,
            "what waits is not one entry a slot"
        );
        assert!(waiting.iter().all(|(slot, _)| slot.0 < Handoff::SLOTS));
    }

    /// An offer never waits for the lock; a purge is never lost to it.
    #[test]
    fn a_held_lock_drops_an_offer_and_keeps_what_waits() {
        let handoff = Handoff::default();
        handoff.offer(CircleSlot(1), packet(1), 1);
        let held = handoff.ops();
        handoff.offer(CircleSlot(1), packet(2), 1);
        handoff.offer(CircleSlot(2), packet(3), 1);
        drop(held);
        assert!(taken(&handoff) == [(1, Some(packet(1)))]);
    }

    /// Every slot the hand-off can name is one the engine has room for.
    #[test]
    fn the_engine_has_an_outbox_slot_for_every_slot_here() {
        assert!(Config::default().outbox_slots >= Handoff::SLOTS as usize);
    }

    /// The owner's drain: an offer is emitted by the engine once, a purge
    /// that follows it before the drain leaves the engine nothing to emit.
    #[test]
    fn what_is_taken_drives_a_real_engine() {
        let config = Config::default();
        let slot_end = config.emit_period_ms + config.emit_jitter_ms;
        let apply = |engine: &mut MeshEngine<StdRng>, handoff: &Handoff, now_ms: u64| {
            for (slot, op) in handoff.take() {
                match op {
                    Op::Offer { packet, .. } => engine.offer(slot, packet, u64::MAX, now_ms),
                    Op::Purge => engine.purge(slot, now_ms),
                }
            }
        };

        let handoff = Handoff::default();
        let mut engine = MeshEngine::new(config.clone(), StdRng::seed_from_u64(7), 0);
        handoff.offer(CircleSlot(2), packet(1), 1);
        apply(&mut engine, &handoff, 0);
        engine.advance(slot_end);
        assert!(
            engine.stats().emitted == 1 && engine.store().is_local(&packet(1).id()),
            "the engine did not emit the packet it was handed",
        );

        let mut engine = MeshEngine::new(config, StdRng::seed_from_u64(7), 0);
        handoff.offer(CircleSlot(2), packet(1), 1);
        handoff.purge(CircleSlot(2));
        apply(&mut engine, &handoff, 0);
        engine.advance(slot_end);
        assert!(
            engine.stats().emitted == 1 && !engine.store().holds(&packet(1).id()),
            "a purged packet was emitted",
        );
    }
}
