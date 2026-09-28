//! Seam 9 of `test_utils_seams.rs` — the live engine's auto-commit address map
//! (`LiveSyncCore::new_local_with_relay_map_for_test`) — proved over a real
//! loopback relay.
//!
//! A binary of its own because these tests open sockets: `test_utils_seams.rs`
//! holds a process-wide log capture that pins the exact set of third-party
//! loggers to `openmls`, and a websocket crate logging from a test running
//! beside it would redden that pin by chance. The seam's structural gate test
//! stays in `test_utils_seams.rs` with the other eight.
//!
//! # Rule 15 over this file
//!
//! No `{:?}` of any `haven_core` / `cgka_*` / `nostr` / `openmls` value, and no
//! assertion message that interpolates an identifier, a URL or an instant.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage};
use haven_core::nostr::mls::types::GroupId;
use haven_core::relay::live_sync::{CircleSpec, LiveSyncCore};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use nostr::{Filter, Keys, Kind};
use tempfile::TempDir;

/// The one address the circle stores; the engine's pool never holds it.
const GROUP_RELAY: &str = "wss://seams.example.com";

/// A loopback address nothing listens on and no engine pool is given.
const UNHELD_RELAY: &str = "ws://127.0.0.1:9";

/// Long enough for the engine's jittered auto-commit and one loopback OK; a
/// loopback relay silent past this is broken, not slow.
const AUTO_COMMIT_BOUND: Duration = Duration::from_secs(20);

struct Device {
    manager: Arc<CircleManager>,
    keys: Keys,
    _dir: TempDir,
}

impl Device {
    fn new() -> Self {
        let dir = TempDir::new().expect("temp dir");
        let keys = Keys::generate();
        let manager =
            Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).expect("open a session"));
        Self {
            manager,
            keys,
            _dir: dir,
        }
    }

    async fn key_package(&self) -> MemberKeyPackage {
        let key_package_event = build_kp_maintenance_events(
            self.manager.session(),
            &self.keys,
            &[GROUP_RELAY.to_string()],
            None,
            None,
        )
        .await
        .expect("mint a key package")
        .event;
        MemberKeyPackage {
            key_package_event,
            inbox_relays: vec![GROUP_RELAY.to_string()],
            nip65_relays: vec![],
        }
    }
}

/// A genuine two-member circle built through the public API, storing
/// [`GROUP_RELAY`] as its only relay.
struct Circle {
    alice: Device,
    bob: Device,
    mls_group_id: GroupId,
    nostr_group_id: [u8; 32],
}

async fn two_member_circle(name: &str) -> Circle {
    let relays = vec![GROUP_RELAY.to_string()];
    let alice = Device::new();
    let bob = Device::new();
    let result = alice
        .manager
        .create_circle(
            &alice.keys,
            vec![bob.key_package().await],
            &CircleConfig::new(name).with_relays(relays.clone()),
            &relays,
        )
        .await
        .expect("create a circle");
    let mls_group_id = result.circle.mls_group_id.clone();
    let nostr_group_id = result.circle.nostr_group_id;
    alice
        .manager
        .confirm_published(result.pending)
        .await
        .expect("confirm the create");
    bob.manager
        .process_gift_wrapped_invitation(&bob.keys, &result.welcome_events[0].event)
        .await
        .expect("bob peels the welcome");
    bob.manager
        .accept_invitation(&result.welcome_events[0].event.id)
        .await
        .expect("bob joins");
    Circle {
        alice,
        bob,
        mls_group_id,
        nostr_group_id,
    }
}

/// Resolves once `done` holds, re-reading it on a short interval; `false` at the
/// bound.
async fn within(bound: Duration, mut done: impl FnMut() -> bool) -> bool {
    let deadline = tokio::time::Instant::now() + bound;
    let mut tick = tokio::time::interval(Duration::from_millis(20));
    while tokio::time::Instant::now() < deadline {
        if done() {
            return true;
        }
        tick.tick().await;
    }
    done()
}

/// A mock relay the engine subscribes to under an address the circle never
/// stored, with Bob's leave already on it.
async fn leave_on_an_unstored_address(
    c: &Circle,
) -> (nostr_relay_builder::MockRelay, String, nostr_sdk::Client) {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = nostr_relay_builder::MockRelay::run()
        .await
        .expect("a mock relay starts");
    let url = relay.url().await.to_string();
    let observer = nostr_sdk::Client::default();
    observer.add_relay(url.as_str()).await.expect("add relay");
    observer.connect().await;
    let proposal = c
        .bob
        .manager
        .propose_leave(&c.mls_group_id)
        .await
        .expect("bob proposes to leave");
    observer
        .send_event(&proposal)
        .await
        .expect("the proposal reaches the relay");
    (relay, url, observer)
}

async fn stored_445s(observer: &nostr_sdk::Client) -> Vec<nostr::EventId> {
    observer
        .fetch_events(
            Filter::new().kind(Kind::Custom(445)),
            Duration::from_secs(5),
        )
        .await
        .expect("the relay answers")
        .into_iter()
        .map(|event| event.id)
        .collect()
}

fn spec_for(c: &Circle, relay: String) -> CircleSpec {
    CircleSpec {
        group_id_hex: hex::encode(c.nostr_group_id),
        relays: vec![relay],
    }
}

/// The map is asked for the address the circle STORED, and the live engine's
/// receive-side eviction reaches the relay at the address it returned:
/// stored beside the proposal, and no longer owed — which only an OK-ack from
/// that relay can clear (Rule 13).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_engine_publishes_its_auto_commit_to_the_address_the_map_returns() {
    let c = two_member_circle("mapped publisher").await;
    let (_relay, url, observer) = leave_on_an_unstored_address(&c).await;
    let asked: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
    let record = Arc::clone(&asked);
    let dialled = url.clone();
    let core = LiveSyncCore::new_local_with_relay_map_for_test(
        Arc::clone(&c.alice.manager),
        c.alice.keys.public_key(),
        move |relay| {
            record.lock().unwrap().push(relay.to_owned());
            if relay == GROUP_RELAY {
                dialled.clone()
            } else {
                relay.to_owned()
            }
        },
    );
    core.start(&[spec_for(&c, url)], &[])
        .await
        .expect("the engine starts");

    // The obligation is cleared only by an acknowledged publish, so an empty
    // owed list after the map was consulted is a publish that landed.
    assert!(
        within(AUTO_COMMIT_BOUND, || {
            !asked.lock().unwrap().is_empty()
                && core.processor().in_flight_publishes() == 0
                && c.alice.manager.owed_removal_commits().is_empty()
        })
        .await,
        "the engine consults the map, publishes, and the eviction is no longer owed"
    );
    assert!(
        *asked.lock().unwrap() == vec![GROUP_RELAY.to_string()],
        "the map is asked exactly once, for the address the circle stored"
    );
    assert!(
        stored_445s(&observer).await.len() == 2,
        "the relay holds the proposal and the eviction commit"
    );
    let _ = core.stop().await;
    observer.shutdown().await;
}

/// The wrapper passes the `Client`'s own verdict through: a map pointing the
/// stored address at one the pool does not hold gets production's refusal
/// (`RelayNotFound` ⇒ not acked), so the eviction stays owed. This is what
/// backs "cannot be substituted" — a wrapper that reported an ack it did not
/// get would discharge the obligation here.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_map_to_an_address_the_pool_does_not_hold_leaves_the_eviction_owed() {
    let c = two_member_circle("mapped nowhere").await;
    let (_relay, url, observer) = leave_on_an_unstored_address(&c).await;
    let asked: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
    let record = Arc::clone(&asked);
    let core = LiveSyncCore::new_local_with_relay_map_for_test(
        Arc::clone(&c.alice.manager),
        c.alice.keys.public_key(),
        move |relay| {
            record.lock().unwrap().push(relay.to_owned());
            UNHELD_RELAY.to_owned()
        },
    );
    core.start(&[spec_for(&c, url)], &[])
        .await
        .expect("the engine starts");

    assert!(
        within(AUTO_COMMIT_BOUND, || {
            !asked.lock().unwrap().is_empty() && core.processor().in_flight_publishes() == 0
        })
        .await,
        "the engine consults the map and the refused publish returns"
    );
    assert!(
        c.alice.manager.owed_removal_commits() == vec![c.nostr_group_id],
        "a publish the pool refused is not an ack: the eviction stays owed"
    );
    assert!(
        stored_445s(&observer).await.len() == 1,
        "the relay holds the proposal alone: the commit never left the device"
    );
    let _ = core.stop().await;
    observer.shutdown().await;
}

/// The measured defect the seam exists for, pinned so nobody cures it by
/// widening the pool: the production constructor over a pool that lacks the
/// stored address refuses the publish, and the eviction stays owed.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_production_engine_publisher_leaves_the_eviction_owed_when_its_pool_lacks_the_stored_address(
) {
    let c = two_member_circle("unmapped publisher").await;
    let (_relay, url, observer) = leave_on_an_unstored_address(&c).await;
    let core = LiveSyncCore::new_local(Arc::clone(&c.alice.manager), c.alice.keys.public_key());
    core.start(&[spec_for(&c, url)], &[])
        .await
        .expect("the engine starts");

    // The obligation is written AFTER the in-flight gauge rises, so an owed
    // row with the gauge back at zero is a publish that has returned.
    assert!(
        within(AUTO_COMMIT_BOUND, || {
            !c.alice.manager.owed_removal_commits().is_empty()
                && core.processor().in_flight_publishes() == 0
        })
        .await,
        "the engine attempts the auto-commit and the attempt returns"
    );
    assert!(
        c.alice.manager.owed_removal_commits() == vec![c.nostr_group_id],
        "an eviction the pool could not publish stays owed, never rolled back"
    );
    assert!(
        stored_445s(&observer).await.len() == 1,
        "the relay holds the proposal alone: the commit never left the device"
    );
    let _ = core.stop().await;
    observer.shutdown().await;
}
