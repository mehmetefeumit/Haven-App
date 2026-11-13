//! Seam 9 of `test_utils_seams.rs` — the live engine's address map
//! (`LiveSyncCore::new_local_with_relay_map_for_test`) — and seam 11, the dial
//! witness (`relay::dial_witness`), each proved over a real loopback relay.
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
use haven_core::relay::dial_witness::{AlreadyArmed, DialWatch};
use haven_core::relay::live_sync::{CircleSpec, Claim, LiveSyncCore};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use haven_core::relay::{normalize_relay_url, RelayManager};
use nostr::{EventBuilder, Filter, Keys, Kind};
use tempfile::TempDir;

/// The one address the circle stores; the engine's pool never holds it.
const GROUP_RELAY: &str = "wss://seams.example.com";

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
            nip65_write_relays: vec![],
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
        )
        .await
        .expect("create a circle");
    // As the app's driven create leaves it: the founding Welcomes sent from
    // their records and acknowledged, so no later drive sends them.
    let _ = alice.manager.land_staged_for_test().await;
    let mls_group_id = result.circle.mls_group_id.clone();
    let nostr_group_id = result.circle.nostr_group_id;
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

/// A mock relay the engine subscribes to under an address the circle never
/// stored, with Bob's leave already on it, and the leave.
async fn a_leave_on_an_unstored_address(
    c: &Circle,
) -> (
    nostr_relay_builder::MockRelay,
    String,
    nostr_sdk::Client,
    nostr::Event,
) {
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
        .expect("bob proposes to leave")
        .expect("a first leave in this epoch proposes");
    observer
        .send_event(&proposal)
        .await
        .expect("the proposal reaches the relay");
    (relay, url, observer, proposal)
}

/// Resolves once `done` holds, re-reading it on a short interval; `false` at
/// `bound`, which a loopback relay silent past is broken, not slow.
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

/// The live engine's own receive-side eviction, in the claimed foreground:
/// Bob's leave arrives over the relay, the session's drive makes the
/// eviction under a record and sends it through the map, which is asked for
/// the address the circle stored — and the relay holds it, which only that
/// address could have reached. Nothing is owed through the legacy table.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_claimed_foregrounds_eviction_goes_to_the_address_the_map_returns() {
    let c = two_member_circle("claimed mapped publisher").await;
    let (_relay, url, observer, _leave) = a_leave_on_an_unstored_address(&c).await;
    let asked: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
    let record = Arc::clone(&asked);
    let dialled = url.clone();
    let core = LiveSyncCore::new_local_with_relay_map_for_test(
        Arc::clone(&c.alice.manager),
        c.alice.keys.public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
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
    // The start's follow reads the map too: only what comes after is the
    // drive's.
    let before = asked.lock().unwrap().len();
    core.claim_foreground(Claim::Foreground).await;
    // The obligation is never written on this path, so the witness is the
    // map asked for the stored address by the drive's send, with no drive
    // pass left under way: a send that has returned.
    assert!(
        within(Duration::from_secs(20), || {
            asked.lock().unwrap()[before..]
                .iter()
                .any(|relay| relay == GROUP_RELAY)
                && core.processor().passes_under_way() == 0
        })
        .await,
        "the claimed foreground's drive did not send the eviction through the map",
    );
    assert!(
        stored_445s(&observer).await.len() == 2,
        "the relay at the mapped address does not hold the eviction, or it was owed through \
         the legacy table",
    );
    let _ = core.stop().await;
    observer.shutdown().await;
}

/// Seam 11: a relay client's dial is recorded while a watch is armed, a second
/// watch is refused while one lives, and the watch keeps nothing once dropped:
/// the next one starts empty though a dial was made in between. The sibling
/// test of this binary dials relays of its own, so dials are read by URL.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_dial_witness_records_each_dial_while_armed_and_nothing_after() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let watched_relay = nostr_relay_builder::MockRelay::run()
        .await
        .expect("a mock relay starts");
    let unwatched_relay = nostr_relay_builder::MockRelay::run()
        .await
        .expect("a mock relay starts");
    let watched = normalize_relay_url(&watched_relay.url().await.to_string()).expect("a relay url");
    let unwatched =
        normalize_relay_url(&unwatched_relay.url().await.to_string()).expect("a relay url");
    let dials_of = |dials: &[String], url: &str| {
        dials
            .iter()
            .filter(|dial| normalize_relay_url(dial).as_deref() == Some(url))
            .count()
    };
    let note = EventBuilder::text_note("dialled")
        .sign_with_keys(&Keys::generate())
        .expect("a locally built event signs");

    let Ok(watch) = DialWatch::arm() else {
        panic!("no watch is armed yet");
    };
    assert!(
        matches!(DialWatch::arm(), Err(AlreadyArmed)),
        "a second watch was armed beside the first",
    );
    let first = RelayManager::new();
    first
        .publish_event(&note, std::slice::from_ref(&watched))
        .await
        .expect("the relay takes the event");
    first.shutdown().await;
    assert!(
        dials_of(&watch.dials(), &watched) >= 1,
        "the dial made while the watch was armed was not recorded",
    );
    drop(watch);

    let second = RelayManager::new();
    second
        .publish_event(&note, std::slice::from_ref(&unwatched))
        .await
        .expect("the relay takes the event");
    second.shutdown().await;
    let Ok(next) = DialWatch::arm() else {
        panic!("the dropped watch is still armed");
    };
    let kept = next.dials();
    assert!(
        dials_of(&kept, &watched) == 0 && dials_of(&kept, &unwatched) == 0,
        "a dial from before this watch was armed is in its record",
    );
}
