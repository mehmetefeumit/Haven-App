//! Minting a schedule from a seed.
//!
//! The generator is the only place in the crate that draws a random number, and
//! it draws every one of them from a `StdRng` seeded with the run's seed. That
//! is the whole reproducibility contract: `profile + seed` names a schedule, the
//! schedule names a digest, and the banner prints the digest's first four bytes
//! so a red run can be re-run byte for byte.
//!
//! # Count-driven, never clock-driven
//!
//! Every position in the schedule is a TICK — a count from the world's origin —
//! derived from the profile's declared duration and tick period. Nothing here
//! reads a clock, so a run on a loaded machine applies exactly the ops a run on
//! an idle one does, in the same order, and the only thing that differs is how
//! long each tick took.
//!
//! # What the schedule is, and what it is not
//!
//! It is the run's **background** nemesis: the faults and device events a
//! profile run applies while the scenarios observe. A scenario that needs one
//! exact fault at one exact moment — S01's outage, S18's swallowed
//! acknowledgement — applies it itself, because an expectation floor may never
//! depend on a random draw having chosen the right relay. The two are one
//! mechanism from the world's side (both go through `RelayPlane::apply`) and
//! two from the reader's: the schedule is what the timeline's first records
//! declare, and a scenario's own faults are recorded as it applies them.
//!
//! # Every fault heals inside its own slot
//!
//! The run is cut into equal slots and at most one scheduled fault is live in
//! any of them: a fault fires in the first half of its slot and is healed in the
//! same slot, before the next one fires. That is what makes a liveness bound
//! derivable at all — two overlapping faults have no single recovery bound —
//! and it is why a slot ends with a probe, when the world is supposed to have
//! recovered.

use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};

use crate::nemesis::types::{ClosedPrefix, DeviceOp, Fault, Op, Schedule, ScheduledOp};
use crate::profiles::{ProfileSpec, WorldShape};
use crate::rig::{DeviceTag, KillKind, RelayTag};

/// Scheduled faults per relay plane over one run.
const FAULTS_PER_RELAY: usize = 2;

/// Scheduled device events per device over one run.
const EVENTS_PER_DEVICE: usize = 1;

/// The text of a scheduled `NOTICE`.
///
/// A literal from this file, and it has to be: a `NOTICE` a relay composed
/// would be remote-authored prose, which Rule 15 keeps out of every rendering,
/// and the timeline records this value.
const HARNESS_NOTICE: &str = "haven-soak scheduled notice";

/// The faults a schedule may carry.
///
/// [`Fault::Heal`] and [`Fault::Up`] are deliberately absent: healing is what
/// `heal_at` means, and a schedule that could also heal by naming a fault would
/// have two mechanisms for one thing — and the second one would carry no bound.
const FAULT_PALETTE: [Fault; 8] = [
    Fault::Down,
    Fault::WipeStore,
    Fault::Closed(ClosedPrefix::RateLimited),
    Fault::Closed(ClosedPrefix::AuthRequired),
    Fault::Notice(HARNESS_NOTICE),
    Fault::SwallowOk,
    Fault::DoubleEveryEvent,
    Fault::ReversePages,
];

/// The device events a schedule may carry.
///
/// [`DeviceOp::ComeOnline`] is absent because the generator emits it as the
/// PAIR of a `GoOffline` rather than on its own — resuming a device that never
/// paused proves nothing, and leaving one paused for the rest of a run makes
/// every later expectation about it vacuous. [`DeviceOp::StepPolicyOffset`] is
/// absent for a stronger reason: a policy clock may only be stepped between
/// quiescent phases, and a schedule minted before the first tick cannot know
/// when the world is quiescent. The scenarios that need a step take it at a
/// phase boundary they themselves established.
const DEVICE_PALETTE: [DeviceOp; 3] = [
    DeviceOp::Restart(KillKind::Soft),
    DeviceOp::Restart(KillKind::Hard),
    DeviceOp::GoOffline,
];

/// Mints a schedule from a seed.
///
/// Holds the profile because the schedule's length is the profile's: a `weekly`
/// run is not a `pr` run with more faults per minute, it is the same density
/// over a longer span.
pub struct Generator {
    rng: StdRng,
    spec: ProfileSpec,
}

impl Generator {
    /// Seeds a generator for `spec`.
    ///
    /// `StdRng::seed_from_u64` and nothing else: `thread_rng` would make a run
    /// unreproducible from its own banner, which is the one thing a soak run has
    /// to be.
    #[must_use]
    pub fn new(spec: ProfileSpec, seed: u64) -> Self {
        Self {
            rng: StdRng::seed_from_u64(seed),
            spec,
        }
    }

    /// The profile this generator mints for.
    #[must_use]
    pub const fn spec(&self) -> &ProfileSpec {
        &self.spec
    }

    /// How many ticks the run spans.
    ///
    /// At least one: a profile whose duration is shorter than a single tick
    /// still has a first tick, and a schedule with nowhere to put an op would
    /// be a run that proves nothing rather than an error to report.
    #[must_use]
    pub const fn ticks(&self) -> u64 {
        let period = if self.spec.tick_ms == 0 {
            1
        } else {
            self.spec.tick_ms
        };
        let ticks = self.spec.duration_secs.saturating_mul(1_000) / period;
        if ticks == 0 {
            1
        } else {
            ticks
        }
    }

    /// Mints the schedule for `shape`.
    ///
    /// Deterministic in the seed and the shape alone: the same pair yields a
    /// byte-identical schedule and the same digest, whatever machine it runs on
    /// and however long a tick takes.
    #[must_use]
    pub fn schedule(&mut self, shape: &WorldShape) -> Schedule {
        let slots = shape.relays * FAULTS_PER_RELAY + shape.members * EVENTS_PER_DEVICE;
        let Ok(slot_count) = u64::try_from(slots) else {
            return Schedule::new(Vec::new());
        };
        let ticks = self.ticks();
        // One slot per op plus one for the world to settle in before the first
        // fault: a world graded on its first tick is graded while it is still
        // opening its subscriptions.
        let span = ticks / (slot_count + 1);
        if span < MIN_SLOT_TICKS {
            // Too short to carry a fault AND its heal AND a probe. A schedule
            // that fired a fault it could not heal would hand every bound
            // derived from it a heal that never happens, so this run carries
            // probes alone and says so through its (short) op list.
            return Schedule::new(self.probes_only(ticks));
        }

        let mut ops: Vec<ScheduledOp> = Vec::with_capacity(slots * 3);
        for slot in 0..slot_count {
            let base = (slot + 1) * span;
            // Faults first, then device events: a device event inside an active
            // outage would be graded against two causes at once.
            if slot < u64::try_from(shape.relays * FAULTS_PER_RELAY).unwrap_or(0) {
                ops.push(self.fault_in_slot(shape, base, span));
            } else {
                ops.extend(self.device_event_in_slot(shape, base, span));
            }
            // The slot's probe: after the heal, when the world is meant to have
            // recovered. A probe during an unhealed fault would assert liveness
            // the schedule itself removed.
            ops.push(ScheduledOp {
                tick: base + span - 1,
                op: Op::Probe,
                heal_at: None,
            });
        }
        Schedule::new(ops)
    }

    /// The schedule for a run too short to heal anything.
    fn probes_only(&mut self, ticks: u64) -> Vec<ScheduledOp> {
        // Still a draw, so a short profile advances the RNG exactly as a long
        // one does for the same call and two runs of the same seed cannot
        // diverge on a duration override alone.
        let _ = self.rng.gen::<u64>();
        vec![ScheduledOp {
            tick: ticks.saturating_sub(1),
            op: Op::Probe,
            heal_at: None,
        }]
    }

    /// One fault, placed in the first half of its slot and healed in the second.
    fn fault_in_slot(&mut self, shape: &WorldShape, base: u64, span: u64) -> ScheduledOp {
        let relay = self.rng.gen_range(0..shape.relays);
        let fault = FAULT_PALETTE[self.rng.gen_range(0..FAULT_PALETTE.len())];
        let offset = self.rng.gen_range(0..span / 2);
        let hold = self.rng.gen_range(1..=span / 4);
        let tick = base + offset;
        ScheduledOp {
            tick,
            op: Op::Fault {
                relay: RelayTag::new(u32::try_from(relay).unwrap_or(0)),
                fault,
            },
            // Inside the slot by construction: offset < span/2 and hold <=
            // span/4, so the heal lands before the slot's probe.
            heal_at: Some(tick + hold),
        }
    }

    /// One device event, with its pair when it has one.
    fn device_event_in_slot(
        &mut self,
        shape: &WorldShape,
        base: u64,
        span: u64,
    ) -> Vec<ScheduledOp> {
        let device = self.rng.gen_range(0..shape.members);
        let event = DEVICE_PALETTE[self.rng.gen_range(0..DEVICE_PALETTE.len())];
        let offset = self.rng.gen_range(0..span / 2);
        let hold = self.rng.gen_range(1..=span / 4);
        let tag = DeviceTag::new(u32::try_from(device).unwrap_or(0));
        let tick = base + offset;
        let mut ops = vec![ScheduledOp {
            tick,
            op: Op::Device {
                device: tag,
                op: event,
            },
            heal_at: None,
        }];
        if event == DeviceOp::GoOffline {
            ops.push(ScheduledOp {
                tick: tick + hold,
                op: Op::Device {
                    device: tag,
                    op: DeviceOp::ComeOnline,
                },
                heal_at: None,
            });
        }
        ops
    }
}

/// The shortest slot that can hold a fault, its heal and the probe after it.
///
/// Four ticks: the fault lands in the first half, the heal at least one tick
/// later and still inside the slot, and the probe on the slot's last tick.
const MIN_SLOT_TICKS: u64 = 4;

#[cfg(test)]
mod tests {
    use super::{Generator, FAULT_PALETTE, MIN_SLOT_TICKS};
    use crate::nemesis::types::{DeviceOp, Fault, Op};
    use crate::profiles::{ProfileName, ProfileSpec, WorldShape};

    fn pr() -> ProfileSpec {
        ProfileSpec::embedded(ProfileName::Pr).expect("pr profile")
    }

    fn shape() -> WorldShape {
        pr().world
    }

    #[test]
    fn the_same_seed_mints_the_same_schedule_byte_for_byte() {
        let first = Generator::new(pr(), 0x5eed).schedule(&shape());
        let second = Generator::new(pr(), 0x5eed).schedule(&shape());
        assert_eq!(first.digest(), second.digest());
        assert_eq!(first.ops(), second.ops());
        assert_eq!(
            serde_json::to_string(&first).expect("serialises"),
            serde_json::to_string(&second).expect("serialises")
        );
    }

    #[test]
    fn a_different_seed_mints_a_different_schedule() {
        let one = Generator::new(pr(), 1).schedule(&shape());
        let other = Generator::new(pr(), 2).schedule(&shape());
        assert_ne!(one.digest(), other.digest());
    }

    #[test]
    fn every_scheduled_fault_carries_its_own_heal_and_no_device_event_does() {
        let schedule = Generator::new(pr(), 7).schedule(&shape());
        for scheduled in schedule.ops() {
            match scheduled.op {
                Op::Fault { .. } => {
                    let heal = scheduled.heal_at.expect("a fault schedules its heal");
                    assert!(heal > scheduled.tick, "a heal before its fault");
                }
                // Only a fault can be healed: the world refuses anything else,
                // and a heal that quietly did not happen leaves every bound
                // derived from it a fiction.
                Op::Device { .. } | Op::Probe => assert_eq!(scheduled.heal_at, None),
            }
        }
    }

    #[test]
    fn a_schedule_never_heals_by_naming_a_fault() {
        let schedule = Generator::new(pr(), 11).schedule(&shape());
        for scheduled in schedule.ops() {
            if let Op::Fault { fault, .. } = scheduled.op {
                assert!(
                    !matches!(fault, Fault::Heal | Fault::Up),
                    "healing is what heal_at means"
                );
            }
        }
    }

    #[test]
    fn every_target_exists_in_the_world_the_schedule_was_minted_for() {
        let shape = shape();
        let schedule = Generator::new(pr(), 3).schedule(&shape);
        for scheduled in schedule.ops() {
            match scheduled.op {
                Op::Fault { relay, .. } => assert!(
                    (relay.ordinal() as usize) < shape.relays,
                    "a fault named a relay the world lacks"
                ),
                Op::Device { device, .. } => assert!(
                    (device.ordinal() as usize) < shape.members,
                    "an event named a device the world lacks"
                ),
                Op::Probe => {}
            }
        }
    }

    #[test]
    fn a_paused_device_is_always_resumed_again() {
        // Over several seeds, because whether a `GoOffline` is drawn at all is
        // a property of the seed and this invariant is not.
        let mut paused = 0;
        for seed in 0..16 {
            let schedule = Generator::new(pr(), seed).schedule(&shape());
            for (index, scheduled) in schedule.ops().iter().enumerate() {
                let Op::Device { device, op } = scheduled.op else {
                    continue;
                };
                if op != DeviceOp::GoOffline {
                    continue;
                }
                paused += 1;
                let resumed = schedule.ops()[index + 1..].iter().any(|later| {
                    later.op
                        == Op::Device {
                            device,
                            op: DeviceOp::ComeOnline,
                        }
                        && later.tick > scheduled.tick
                });
                assert!(resumed, "a device was paused and never resumed");
            }
        }
        assert!(paused > 0, "no seed drew a pause, so nothing was proven");
    }

    #[test]
    fn the_policy_clock_is_never_stepped_by_a_schedule() {
        for seed in 0..16 {
            let schedule = Generator::new(pr(), seed).schedule(&shape());
            for scheduled in schedule.ops() {
                assert!(
                    !matches!(
                        scheduled.op,
                        Op::Device {
                            op: DeviceOp::StepPolicyOffset { .. },
                            ..
                        }
                    ),
                    "a step between non-quiescent phases would fabricate an age-out"
                );
            }
        }
    }

    #[test]
    fn at_most_one_scheduled_fault_is_live_at_a_time() {
        let schedule = Generator::new(pr(), 23).schedule(&shape());
        let mut spans: Vec<(u64, u64)> = schedule
            .ops()
            .iter()
            .filter(|op| matches!(op.op, Op::Fault { .. }))
            .map(|op| (op.tick, op.heal_at.unwrap_or(op.tick)))
            .collect();
        spans.sort_unstable();
        for pair in spans.windows(2) {
            assert!(
                pair[0].1 < pair[1].0,
                "two faults overlap, so neither has a derivable bound"
            );
        }
    }

    #[test]
    fn every_slot_ends_with_a_probe_after_its_heal() {
        let schedule = Generator::new(pr(), 31).schedule(&shape());
        let probes: Vec<u64> = schedule
            .ops()
            .iter()
            .filter(|op| op.op == Op::Probe)
            .map(|op| op.tick)
            .collect();
        assert!(!probes.is_empty());
        for scheduled in schedule.ops() {
            if let Some(heal) = scheduled.heal_at {
                assert!(
                    probes.iter().any(|probe| *probe > heal),
                    "a fault healed with no probe left to prove recovery"
                );
            }
        }
    }

    #[test]
    fn a_run_too_short_to_heal_anything_carries_probes_and_no_fault() {
        let mut spec = pr();
        spec.duration_secs = 1;
        spec.tick_ms = 1_000;
        let schedule = Generator::new(spec, 5).schedule(&shape());
        assert!(schedule
            .ops()
            .iter()
            .all(|scheduled| scheduled.op == Op::Probe));
        assert!(!schedule.ops().is_empty(), "even a short run is probed");
    }

    #[test]
    fn the_tick_count_is_the_profiles_own_duration_and_period() {
        let mut spec = pr();
        spec.duration_secs = 120;
        spec.tick_ms = 250;
        assert_eq!(Generator::new(spec, 0).ticks(), 480);

        let mut spec = pr();
        spec.duration_secs = 0;
        assert_eq!(
            Generator::new(spec, 0).ticks(),
            1,
            "a run shorter than one tick still has a first tick"
        );
    }

    #[test]
    fn a_bigger_world_is_broken_in_more_places() {
        let small = Generator::new(pr(), 42).schedule(&WorldShape {
            members: 2,
            circles: 1,
            relays: 1,
        });
        let big = Generator::new(pr(), 42).schedule(&WorldShape {
            members: 5,
            circles: 4,
            relays: 3,
        });
        assert!(
            big.ops().len() > small.ops().len(),
            "the op count is driven by the world's size, not by the clock"
        );
    }

    #[test]
    fn the_whole_fault_palette_is_reachable() {
        // A palette entry no seed can draw is a fault nobody tests, so the
        // generator's own reach is asserted rather than assumed.
        let mut seen = std::collections::BTreeSet::new();
        for seed in 0..256 {
            let schedule = Generator::new(pr(), seed).schedule(&WorldShape {
                members: 4,
                circles: 2,
                relays: 3,
            });
            for scheduled in schedule.ops() {
                if let Op::Fault { fault, .. } = scheduled.op {
                    seen.insert(fault.label());
                }
            }
        }
        for fault in FAULT_PALETTE {
            assert!(
                seen.contains(fault.label()),
                "no seed ever drew {}",
                fault.label()
            );
        }
    }

    #[test]
    fn a_slot_is_never_shorter_than_a_fault_and_its_heal() {
        // The one derived constant the placement arithmetic rests on: with a
        // slot below this, `span / 4` is zero and a heal could land on its own
        // fault's tick.
        const { assert!(MIN_SLOT_TICKS >= 4) }
    }
}
