//! Everything a world mints reaches the needle manifest — including the circles
//! an ARM builds after the world was declared.
//!
//! A value the rig minted and never declared is one the scan cannot look for.
//! The structural rules still catch a 64-hex group id, but a circle name is
//! just a word: `soak-circle-2` in a captured line is indistinguishable from
//! prose unless this run said it minted it.
//!
//! Counts per class, never values: a test that spelled a declared value would
//! put it in a source file, which is the one place it must not be.

use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use haven_logscan::manifest::Manifest;

use haven_soak::logsink::Needles;
use haven_soak::nemesis::types::Schedule;
use haven_soak::profiles::{ProfileName, ProfileSpec, WorldShape};
use haven_soak::relay::SimRelay;
use haven_soak::rig::{CapturedLine, DeclareSink, LogDrain, RelayTag, RigError, SimWorld};
use haven_soak::scenarios::{Scenario, ScenarioWorld};
use haven_soak::timeline::Timeline;

/// A drain with nothing in it: no oracle and no arm reads a captured line, and
/// the scan is another file's subject.
#[derive(Clone, Copy, Default)]
struct EmptyDrain;

impl LogDrain for EmptyDrain {
    fn drain_since(&self, _from: u64) -> Vec<CapturedLine> {
        Vec::new()
    }
}

/// The declaration sink, built here rather than borrowed from the driver: the
/// seam is public, and a test that could not implement it would not be proving
/// the seam is usable.
struct Sink {
    needles: Mutex<Needles>,
}

impl Sink {
    fn new() -> Self {
        Self {
            needles: Mutex::new(Needles::new().expect("the compiled-in policy loads")),
        }
    }

    fn seal(&self) -> Manifest {
        self.locked()
            .seal("declarations-test")
            .expect("the declarations seal")
    }

    fn locked(&self) -> std::sync::MutexGuard<'_, Needles> {
        self.needles.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl DeclareSink for Sink {
    fn declare_device(&self, secret_hex: &str, pubkey_hex: &str) -> Result<(), RigError> {
        let mut needles = self.locked();
        needles
            .declare_secret_key(secret_hex)
            .and_then(|()| needles.declare_pubkey(pubkey_hex))
            .map_err(|_| RigError::DeclarationRefused)
    }

    fn declare_circle(
        &self,
        mls_group_id_hex: &str,
        nostr_group_id_hex: &str,
        name: &str,
    ) -> Result<(), RigError> {
        let mut needles = self.locked();
        needles
            .declare_mls_group_id(mls_group_id_hex)
            .and_then(|()| needles.declare_nostr_group_id(nostr_group_id_hex))
            .and_then(|()| needles.declare_circle_name(name))
            .map_err(|_| RigError::DeclarationRefused)
    }

    fn declare_relay(&self, url: &str) -> Result<(), RigError> {
        self.locked()
            .declare_relay_url(url)
            .map_err(|_| RigError::DeclarationRefused)
    }
}

/// How many values of `class` a sealed manifest carries.
fn declared(manifest: &Manifest, class: &str) -> usize {
    manifest
        .values
        .iter()
        .filter(|value| value.class == class)
        .count()
}

/// Two devices and two circles: S13's floor, and the smallest world in which a
/// quarantined group has a sibling to prove it did not freeze.
const fn shape() -> WorldShape {
    WorldShape {
        members: 2,
        circles: 2,
        relays: 1,
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_circle_an_arm_builds_mid_run_is_declared_like_every_other() {
    let sink = Arc::new(Sink::new());
    let relay = SimRelay::start(RelayTag::new(0))
        .await
        .expect("the relay plane starts");
    let mut world: ScenarioWorld<Timeline, EmptyDrain> = SimWorld::build(
        &shape(),
        Schedule::new(Vec::new()),
        vec![relay],
        Timeline::in_memory(),
        EmptyDrain,
    )
    .await
    .expect("the world builds");
    world
        .declare_to(Arc::clone(&sink) as Arc<dyn DeclareSink>)
        .expect("the world declares what it minted");

    let built = sink.seal();
    assert!(
        declared(&built, "nostr_group_id") == 2,
        "the world's own circles are declared as it is built"
    );
    assert!(
        declared(&built, "mls_group_id") == 2,
        "both of each circle's ids, because a leak of either is a leak"
    );
    assert!(
        declared(&built, "circle_name") == 2,
        "and the name, which no structural rule can recognise"
    );
    assert!(
        declared(&built, "pubkey") == 2 && declared(&built, "nsec") == 2,
        "every device's identity, both halves"
    );
    assert!(
        declared(&built, "relay_url") == 1,
        "and every endpoint the world dials"
    );

    // S13 builds one more circle inside its own body and breaks it. Before the
    // world owned the declaration seam, that circle's two ids and its name
    // reached no manifest at all.
    let scenario = Scenario::HydrationQuarantine;
    let spec = ProfileSpec::embedded(ProfileName::Pr).expect("the pr profile parses");
    let tick = Duration::from_millis(spec.tick_ms);
    let arm = scenario
        .arm("hydration-quarantine")
        .expect("the scenario offers its arm");
    scenario
        .run(&mut world, arm, tick)
        .await
        .expect("the arm runs");

    let after = sink.seal();
    assert!(
        declared(&after, "nostr_group_id") == 3,
        "the circle the arm built is declared through the same seam"
    );
    assert!(declared(&after, "mls_group_id") == 3, "both of its ids");
    assert!(declared(&after, "circle_name") == 3, "and its name");
    assert!(
        declared(&after, "pubkey") == 2 && declared(&after, "nsec") == 2,
        "the arm minted no new device, so nothing was declared twice"
    );

    world.teardown().await.expect("teardown");
}
