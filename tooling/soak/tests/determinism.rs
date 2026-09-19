//! Same seed, same run.
//!
//! A soak run is only worth anything if a red one can be re-run. The banner
//! prints a profile name, a seed and an 8-hex schedule tag, and this is the
//! test that those three really do name one run: the same seed mints a
//! byte-identical schedule with the same digest, and a world of the same shape
//! hands out the same handles in the same order.
//!
//! # What determinism does NOT claim
//!
//! Event and subscription handles are minted in OBSERVATION order, which
//! depends on when frames cross a socket — so they are asserted only to be
//! bijective and never reused, never to be the same across two runs. Claiming
//! more would be claiming that two runs schedule their sockets identically,
//! which nothing in a multi-threaded runtime promises.
//!
//! # Why the rig's handles are its own ordinals
//!
//! `haven_core::log_alias`'s handles are salted from the OS CSPRNG, per process
//! and un-injectable — deliberately, because a handle an observer could
//! recompute would be an identifier. A determinism test cannot compare two runs'
//! salted handles, so the rig mints its own ordinals instead, in a vocabulary
//! (`simdev#`, `simcircle#`, `simrelay#`, `simevt#`) that is disjoint from
//! production's by design: both land in the same evidence file, and a reader
//! must never have to guess which minted which.

use haven_soak::nemesis::generator::Generator;
use haven_soak::profiles::{ProfileName, ProfileSpec, WorldShape};
use haven_soak::relay::SimRelay;
use haven_soak::rig::{
    install_process_globals, CapturedLine, LogDrain, RelayTag, SimWorld, TimelineSink,
};
use haven_soak::timeline::Timeline;
use nostr::EventId;

/// A log drain for a world whose logs are not the subject.
///
/// The rig's real drain takes a process-wide capture lease; this test is about
/// handles and schedules, so it takes nothing and returns nothing.
#[derive(Clone, Default)]
struct NoLogs;

impl LogDrain for NoLogs {
    fn drain_since(&self, _from: u64) -> Vec<CapturedLine> {
        Vec::new()
    }
}

/// The smallest world that proves anything: two devices, one circle, one relay.
const fn smallest() -> WorldShape {
    WorldShape {
        members: 2,
        circles: 1,
        relays: 1,
    }
}

fn pr() -> ProfileSpec {
    ProfileSpec::embedded(ProfileName::Pr).expect("the pr profile")
}

/// Every handle a world hands out, in the order it hands them out.
fn handle_table<T: TimelineSink, L: LogDrain>(world: &SimWorld<SimRelay, T, L>) -> Vec<String> {
    let mut out: Vec<String> = world
        .devices()
        .iter()
        .map(|device| device.tag.to_string())
        .collect();
    out.extend(world.circles().iter().map(|circle| circle.tag.to_string()));
    out.extend(world.relays().iter().map(|relay| {
        use haven_soak::rig::RelayPlane as _;
        relay.tag().to_string()
    }));
    out
}

#[test]
fn the_same_seed_mints_a_byte_identical_schedule() {
    let shape = pr().world;
    let first = Generator::new(pr(), 0x50a4).schedule(&shape);
    let second = Generator::new(pr(), 0x50a4).schedule(&shape);

    assert!(first.digest() == second.digest(), "the digest moved");
    assert!(first.ops() == second.ops(), "the ops moved");
    assert!(
        serde_json::to_string(&first).expect("a schedule renders")
            == serde_json::to_string(&second).expect("a schedule renders"),
        "the rendered schedule moved, so the file a run is reproduced from moved"
    );
    assert!(
        first.tag() == second.tag(),
        "the tag the banner prints moved"
    );
}

#[test]
fn a_different_seed_mints_a_different_schedule() {
    // Without this the test above would pass on a generator that ignored its
    // seed entirely.
    let shape = pr().world;
    let one = Generator::new(pr(), 1).schedule(&shape);
    let other = Generator::new(pr(), 2).schedule(&shape);
    assert!(one.digest() != other.digest(), "two seeds, one schedule");
}

#[test]
fn a_schedule_names_only_the_rigs_own_handles() {
    let rendered =
        serde_json::to_string(&Generator::new(pr(), 7).schedule(&pr().world)).expect("renders");
    for production in ["circle#", "peer#", "event#", "relay#", "subscription#"] {
        // Production's vocabulary is salted and per-process; the rig's is
        // ordinal. Both land in the same evidence file.
        let at_word_boundary = rendered.match_indices(production).any(|(index, _)| {
            index == 0 || !rendered.as_bytes()[index - 1].is_ascii_alphanumeric()
        });
        assert!(
            !at_word_boundary,
            "a schedule rendered production's own handle vocabulary"
        );
    }
    assert!(rendered.contains("simrelay#"), "the rig's own vocabulary");
}

#[test]
fn the_tag_the_banner_prints_is_short_enough_for_the_scanner() {
    let tag = Generator::new(pr(), 3).schedule(&pr().world).tag();
    assert!(tag.len() == 8, "the schedule tag is eight hex characters");
    assert!(tag.chars().all(|c| c.is_ascii_hexdigit()));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn two_worlds_of_one_shape_hand_out_the_same_handles() {
    install_process_globals().expect("the ws:// loopback opt-in");
    let shape = smallest();
    let schedule = Generator::new(pr(), 11).schedule(&shape);

    let mut tables = Vec::new();
    for _ in 0..2 {
        let relay = SimRelay::start(RelayTag::new(0))
            .await
            .expect("a relay plane");
        let world = SimWorld::build(
            &shape,
            schedule.clone(),
            vec![relay],
            Timeline::in_memory(),
            NoLogs,
        )
        .await
        .expect("a world builds");
        tables.push(handle_table(&world));
        world.teardown().await.expect("the world tears down");
    }

    assert!(
        tables[0] == tables[1],
        "two worlds of one shape handed out different handles, so a run cannot \
         be read against another run's timeline"
    );
    assert!(
        tables[0] == vec!["simdev#0", "simdev#1", "simcircle#0", "simrelay#0"],
        "the handle table is the world's shape in the rig's own vocabulary"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn event_handles_are_bijective_and_never_reused() {
    install_process_globals().expect("the ws:// loopback opt-in");
    let shape = smallest();
    let relay = SimRelay::start(RelayTag::new(0))
        .await
        .expect("a relay plane");
    let world = SimWorld::build(
        &shape,
        Generator::new(pr(), 13).schedule(&shape),
        vec![relay],
        Timeline::in_memory(),
        NoLogs,
    )
    .await
    .expect("a world builds");

    let sender = world.devices()[0].tag;
    let group = world.circles()[0].mls_group_id().clone();
    let mut ids: Vec<EventId> = Vec::new();
    for step in 0..3_u8 {
        let device = world.device(sender).expect("the sending device");
        let (event, _, _) = device
            .manager()
            .expect("a manager")
            .encrypt_location(
                &group,
                &device.keys.public_key(),
                &haven_core::location::LocationMessage::new(
                    f64::from(step) / 8.0,
                    f64::from(step) / 4.0,
                ),
                haven_core::location::LOCATION_MESSAGE_RETENTION_SECS,
            )
            .await
            .expect("a location encrypts");
        world
            .publish_witnessed(sender, std::slice::from_ref(&event))
            .await
            .expect("the witness reads")
            .expect("a relay acknowledged the location");
        ids.push(event.id);
    }

    let ledger = world.relays()[0].ledger();
    let mut handles: Vec<String> = Vec::new();
    for id in &ids {
        let tag = ledger.tag_of(id).expect("an observed event has a handle");
        // Minted once and never moved: a handle that changed between two
        // sightings of one event would make a timeline unreadable.
        assert!(
            ledger.tag_of(id) == Some(tag),
            "one event was given two handles"
        );
        let rendered = tag.to_string();
        assert!(
            rendered.starts_with("simevt#"),
            "an event handle must be the rig's own vocabulary"
        );
        handles.push(rendered);
    }

    let mut unique = handles.clone();
    unique.sort();
    unique.dedup();
    assert!(
        unique.len() == handles.len(),
        "two events share one handle, so the mapping is not bijective"
    );

    world.teardown().await.expect("the world tears down");
}
