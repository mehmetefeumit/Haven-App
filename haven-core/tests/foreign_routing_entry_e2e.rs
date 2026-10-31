//! A relay another client's admin wrote into a circle's routing component, and
//! which Haven may not dial, costs the circle that one relay and nothing else.
//!
//! MDK admits any URL that parses to `ws` or `wss` into the component, and
//! Haven validates its publish targets and its live-sync session as a whole. So
//! a plaintext entry used to stop every publish to the circle, the relay update
//! that would repair it, and — through the engine's session start — receiving
//! for every other circle on the device. The entry is now dropped where the
//! circle's own relay list is derived from the component; the component is
//! never rewritten. A routing id another client's admin rotates is followed,
//! except onto one another circle on the device holds.
//!
//! Real engine, one in-process relay. The refused entry names a host under
//! `.invalid`, which never resolves, so nothing here could reach a network
//! even if the entry were dialled.

mod helpers;

use std::sync::Arc;

use cgka_traits::app_components::{
    encode_nostr_routing_v1, NostrRoutingV1, NOSTR_ROUTING_COMPONENT_ID,
};
use haven_core::circle::{CircleConfig, CircleError, CircleManager};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::{
    AppComponentData, GroupId, LocationGroupConfig, PublishWork, SendIntent, SessionEffects,
};
use haven_core::nostr::mls::SessionManager;
use haven_core::relay::live_sync::{group_cursor_stream, CircleSpec, LiveSyncCore};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use haven_core::relay::{allow_ws_loopback_for_test, RelayManager};
use nostr::{Event, Keys};
use nostr_relay_builder::{LocalRelay, RelayBuilder};
use tempfile::TempDir;

/// A plaintext relay on a host that never resolves.
const REFUSED: &str = "ws://refused-entry.invalid";

/// Encrypted relays on hosts another client's admin may name and Haven may not
/// dial: loopback, private and link-local literals, and the loopback name.
const NON_PUBLIC: [&str; 6] = [
    "wss://127.0.0.1",
    "wss://10.0.0.1",
    "wss://192.168.1.1",
    "wss://[fe80::1]",
    "wss://[::1]",
    "wss://localhost",
];

/// What of [`NON_PUBLIC`] no log line may carry: each URL and each host that is
/// not also the loopback relay's own.
const NON_PUBLIC_NEEDLES: [&str; 10] = [
    "wss://127.0.0.1",
    "wss://10.0.0.1",
    "wss://192.168.1.1",
    "wss://[fe80::1]",
    "wss://[::1]",
    "wss://localhost",
    "10.0.0.1",
    "192.168.1.1",
    "fe80::1",
    "localhost",
];

/// Relays on public hosts. A domain is admitted unresolved, and `.invalid`
/// never resolves, so nothing here could reach a network even if dialled.
const PUBLIC: &str = "wss://public-entry.invalid";
const MOVED: &str = "wss://moved-entry.invalid";

/// Confirms the one commit `effects` staged and returns its event and Welcomes.
async fn confirm_commit(session: &SessionManager, effects: &SessionEffects) -> (Event, Vec<Event>) {
    let (msg, welcomes, pending) = effects
        .publish
        .iter()
        .find_map(|work| match work {
            PublishWork::GroupEvolution {
                msg,
                welcomes,
                pending,
            } => Some((msg, welcomes, *pending)),
            _ => None,
        })
        .expect("the change stages one commit");
    session
        .confirm_published(pending)
        .await
        .expect("the foreign admin applies its own commit");
    (
        SessionManager::transport_message_to_event(msg).expect("a commit event"),
        welcomes
            .iter()
            .map(|welcome| {
                SessionManager::transport_message_to_event(welcome).expect("a welcome event")
            })
            .collect(),
    )
}

/// The routing component `relays` as another client would write it: straight
/// to the engine, past Haven's own validation of what it may name.
async fn write_routing(session: &SessionManager, group: &GroupId, relays: &[&str]) -> Event {
    let (nostr_group_id, _) = session.group_routing(group).await.expect("routing");
    let mut relays: Vec<String> = relays.iter().map(ToString::to_string).collect();
    relays.sort();
    let routing = NostrRoutingV1::new(nostr_group_id, relays).expect("MDK admits ws and wss");
    let effects = session
        .send(SendIntent::UpdateAppComponents {
            group_id: group.clone(),
            updates: vec![AppComponentData {
                component_id: NOSTR_ROUTING_COMPONENT_ID,
                data: encode_nostr_routing_v1(&routing).expect("the component encodes"),
            }],
        })
        .await
        .expect("the engine stages the routing change");
    confirm_commit(session, &effects).await.0
}

struct Member {
    circle: Arc<CircleManager>,
    keys: Keys,
    dir: TempDir,
}

fn member() -> Member {
    let dir = TempDir::new().expect("temp dir");
    let keys = Keys::generate();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).expect("circle"));
    Member { circle, keys, dir }
}

/// A circle a foreign admin created on `good`, whose routing component then
/// names `component`, joined by a Haven device (an admin of it) and a third
/// member. Returns the device, the third member's key and the group.
async fn joined_foreign_circle(good: &str, component: &[&str]) -> (Member, String, GroupId) {
    let foreign_dir = TempDir::new().expect("temp dir");
    let foreign_keys = Keys::generate();
    let foreign =
        SessionManager::new_unencrypted(foreign_dir.path(), &foreign_keys).expect("session");
    let (device, third) = (member(), member());

    let created = foreign
        .create_group(
            Vec::new(),
            LocationGroupConfig::new("Foreign")
                .with_relay(good)
                .with_admin(foreign_keys.public_key().to_hex()),
        )
        .await
        .expect("the foreign admin founds the circle");
    let group = created.group_id;
    write_routing(&foreign, &group, component).await;

    let mut packages = Vec::new();
    for joiner in [&device, &third] {
        let event = build_kp_maintenance_events(
            joiner.circle.session(),
            &joiner.keys,
            &[good.to_string()],
            None,
            None,
        )
        .await
        .expect("a key package")
        .event;
        packages.push(SessionManager::key_package_from_event(&event).expect("it parses"));
    }
    let invited = foreign
        .add_members(&group, packages)
        .await
        .expect("the foreign admin invites both");
    let (_, welcomes) = confirm_commit(&foreign, &invited).await;
    for joiner in [&device, &third] {
        let to = joiner.keys.public_key().to_hex();
        let welcome = welcomes
            .iter()
            .find(|welcome| {
                welcome
                    .tags
                    .iter()
                    .any(|tag| tag.as_slice().get(1).is_some_and(|value| *value == to))
            })
            .expect("a welcome for each joiner");
        joiner
            .circle
            .process_gift_wrapped_invitation(&joiner.keys, welcome)
            .await
            .expect("the invitation is held");
        joiner
            .circle
            .accept_invitation(&welcome.id)
            .await
            .expect("the joiner accepts");
    }

    // The join derives the list on its own, before any later commit does.
    let mut usable: Vec<String> = component
        .iter()
        .filter(|relay| **relay != REFUSED && !NON_PUBLIC.contains(relay))
        .map(ToString::to_string)
        .collect();
    usable.sort();
    assert_eq!(
        relays_of(&device, &group).await,
        usable,
        "the join gave the circle a relay Haven may not dial",
    );

    // The device becomes an admin, so it can remove a member and repair the
    // relay list; receiving that commit is also what re-derives its list.
    let promoted = foreign
        .update_admin_policy(
            &group,
            &[
                foreign_keys.public_key().to_bytes(),
                device.keys.public_key().to_bytes(),
            ],
        )
        .await
        .expect("the foreign admin promotes the device");
    let (promotion, _) = confirm_commit(&foreign, &promoted).await;
    device
        .circle
        .ingest_for_test(&promotion)
        .await
        .expect("the device applies the promotion");

    let third_key = third.keys.public_key().to_hex();
    (device, third_key, group)
}

async fn relays_of(device: &Member, group: &GroupId) -> Vec<String> {
    device
        .circle
        .get_circle(group)
        .await
        .expect("read the circle")
        .expect("the circle exists")
        .circle
        .relays
}

/// Starts the live-sync engine over every circle the device holds, each on
/// the relay list its row carries — what Dart hands the engine.
async fn engine_starts_for_every_circle(device: &Member, circles: usize) -> bool {
    let specs: Vec<CircleSpec> = device
        .circle
        .get_circles()
        .await
        .expect("the circles are read")
        .into_iter()
        .map(|held| CircleSpec {
            group_id_hex: hex::encode(held.circle.nostr_group_id),
            relays: held.circle.relays,
        })
        .collect();
    assert_eq!(
        specs.len(),
        circles,
        "premise: every circle is in the session"
    );
    let engine = LiveSyncCore::new_local(
        Arc::clone(&device.circle),
        device.keys.public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
    );
    let started = engine.start(&specs, &[]).await.is_ok();
    let _ = engine.stop().await;
    started
}

async fn publish_a_location(device: &Member, group: &GroupId, relays: &RelayManager) -> usize {
    let (event, _, targets) = device
        .circle
        .seal_location_for_test(group, &LocationMessage::new(1.0, 2.0))
        .await
        .expect("the location is encrypted");
    relays
        .publish_location_event(&event, &targets)
        .await
        .expect("the location is published")
        .accepted_by
        .len()
}

/// Removes `third_key` and then makes the relay update that takes the
/// refused entry out of the component — each through the fanout driver, over
/// the product's transport, which sends a commit to the relays it froze from
/// the circle's own list.
async fn remove_a_member_then_repair_the_relays(
    device: &Member,
    group: &GroupId,
    third_key: String,
    good: &str,
    publisher: &RelayManager,
) {
    use haven_core::relay::fanout::{DriveMode, EvolutionStatus, Publishing, WallClock};
    let transport = publisher.fanout_transport();
    let publishing = Publishing {
        fanout: &transport,
        publisher,
        clock: &WallClock,
        deadline_ms: None,
        mode: &DriveMode::Full,
    };
    let removal = publishing
        .remove_members(&device.circle, group, &[third_key])
        .await
        .expect("the removal is made");
    assert_eq!(
        removal.status,
        EvolutionStatus::Confirmed,
        "the removal was not acknowledged"
    );
    let repair = publishing
        .update_relays(&device.circle, group, &[good.to_string()])
        .await
        .expect("the repairing relay update is made");
    assert_eq!(
        repair.status,
        EvolutionStatus::Confirmed,
        "the repair was not acknowledged"
    );
    assert_eq!(
        device
            .circle
            .session()
            .group_relays(group)
            .await
            .expect("the component is read"),
        vec![good.to_string()],
        "the repair did not take the refused entry out of the component",
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refused_routing_entry_costs_the_circle_that_relay_and_nothing_else() {
    let _ = allow_ws_loopback_for_test();
    let relay = LocalRelay::new(RelayBuilder::default());
    relay.run().await.expect("the relay runs");
    let good = relay.url().await.to_string();
    let good = good.trim_end_matches('/').to_string();

    let (device, third_key, group) = joined_foreign_circle(&good, &[&good, REFUSED]).await;
    let second = device
        .circle
        .create_circle(
            &device.keys,
            Vec::new(),
            &CircleConfig::new("Second").with_relays([good.clone()]),
        )
        .await
        .expect("the device founds a circle of its own")
        .circle;

    let mut component = device
        .circle
        .session()
        .group_relays(&group)
        .await
        .expect("the component is read");
    component.sort();
    let mut named = vec![good.clone(), REFUSED.to_string()];
    named.sort();
    assert_eq!(
        component, named,
        "premise: the component names both relays, and Haven never rewrites it"
    );
    assert_eq!(
        relays_of(&device, &group).await,
        vec![good.clone()],
        "the circle's own relay list holds the entry Haven may dial and not the other",
    );

    // Receiving: the engine starts for BOTH circles, on what the lists name.
    assert!(
        engine_starts_for_every_circle(&device, 2).await,
        "the live-sync engine did not start: one circle's refused relay stopped \
         receiving for every circle on the device",
    );

    // Sending: a location, a removal, and the relay update that repairs it.
    let publisher = RelayManager::new();
    assert_eq!(
        publish_a_location(&device, &group, &publisher).await,
        1,
        "the circle's location was not acknowledged by its one usable relay",
    );
    assert_eq!(
        publish_a_location(&device, &second.mls_group_id, &publisher).await,
        1,
        "the device's other circle was affected",
    );

    remove_a_member_then_repair_the_relays(&device, &group, third_key, &good, &publisher).await;

    let dialled: Vec<String> = publisher
        .get_relay_status()
        .await
        .into_iter()
        .map(|status| status.url)
        .collect();
    assert!(
        !dialled.is_empty() && dialled.iter().all(|url| !url.contains("refused-entry")),
        "the refused entry reached the publish pool",
    );
}

/// When no entry of the component is one Haven may dial, the circle has no
/// relay, and says so: nothing is published anywhere else in its place.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_circle_whose_every_routing_entry_is_refused_has_no_relay() {
    let _ = allow_ws_loopback_for_test();
    let relay = LocalRelay::new(RelayBuilder::default());
    relay.run().await.expect("the relay runs");
    let good = relay.url().await.to_string();
    let good = good.trim_end_matches('/').to_string();

    let (device, _third, group) = joined_foreign_circle(&good, &[REFUSED]).await;
    assert!(
        relays_of(&device, &group).await.is_empty(),
        "a circle none of whose relays may be dialled was given a relay list",
    );

    assert!(
        device
            .circle
            .seal_location_for_test(&group, &LocationMessage::new(1.0, 2.0))
            .await
            .is_err(),
        "a location was sealed for a circle with no relay to send it to",
    );

    // The engine still starts, for this circle on no relay at all.
    assert!(
        engine_starts_for_every_circle(&device, 1).await,
        "a circle with no usable relay stopped the live-sync engine from starting",
    );
}

/// The relays a location sealed for `group` now is frozen for.
async fn location_targets(device: &Member, group: &GroupId) -> Vec<String> {
    device
        .circle
        .seal_location_for_test(group, &LocationMessage::new(1.0, 2.0))
        .await
        .expect("the location is sealed")
        .2
}

/// A routing entry on a loopback, private or link-local host costs the circle
/// that relay, on every path that takes the circle's relays from its routing
/// component — the join, a later commit's re-derivation and the relays a send
/// is frozen for — and no line about it names the host. The component itself
/// is never rewritten.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_routing_entry_on_a_non_public_host_is_dropped_on_every_read_path() {
    let lines = Box::pin(helpers::capture_haven_log(async {
        let mut component = NON_PUBLIC.to_vec();
        component.push(PUBLIC);
        // The join derives the list (the helper asserts it), and the commit
        // that promotes the device re-derives it.
        let (device, _third, joined) = joined_foreign_circle(PUBLIC, &component).await;
        assert_eq!(
            relays_of(&device, &joined).await,
            vec![PUBLIC.to_string()],
            "a later commit gave the circle a relay on a non-public host",
        );
        let mut named = device
            .circle
            .session()
            .group_relays(&joined)
            .await
            .expect("the component is read");
        named.sort();
        let mut written: Vec<String> = component.iter().map(ToString::to_string).collect();
        written.sort();
        assert_eq!(
            named, written,
            "premise: the component names every entry, and Haven never rewrites it",
        );
        assert_eq!(
            location_targets(&device, &joined).await,
            vec![PUBLIC.to_string()],
            "a location was frozen for a relay on a non-public host",
        );

        // A circle the device joined clean, then routed at the same hosts.
        let foreign = Foreign::found_with(&device, PUBLIC).await;
        let mut moved = NON_PUBLIC.to_vec();
        moved.push(MOVED);
        let commit = write_routing(&foreign.session, &foreign.group, &moved).await;
        device
            .circle
            .ingest_for_test(&commit)
            .await
            .expect("the device applies the routing change");
        assert_eq!(
            relays_of(&device, &foreign.group).await,
            vec![MOVED.to_string()],
            "the re-derived list holds a relay on a non-public host",
        );
        assert_eq!(
            location_targets(&device, &foreign.group).await,
            vec![MOVED.to_string()],
            "a location was frozen for a relay on a non-public host",
        );

        // Every entry on a non-public host: the circle has no relay.
        let commit = write_routing(&foreign.session, &foreign.group, &NON_PUBLIC).await;
        device
            .circle
            .ingest_for_test(&commit)
            .await
            .expect("the device applies the routing change");
        assert!(
            relays_of(&device, &foreign.group).await.is_empty(),
            "a circle none of whose relays is on a public host was given a relay list",
        );
        assert!(
            device
                .circle
                .seal_location_for_test(&foreign.group, &LocationMessage::new(1.0, 2.0))
                .await
                .is_err(),
            "a location was sealed for a circle with no relay on a public host",
        );
    }))
    .await;
    helpers::assert_some_line_from(&lines, "haven_core");
    helpers::assert_no_needles(&lines, &NON_PUBLIC_NEEDLES);
}

/// Asserts a relay update of `own` and a create naming `host` are each refused
/// typed, in text that names no host.
async fn refuses_to_write(device: &Member, own: &GroupId, host: &str) {
    let names_no_host = |refused: &CircleError| {
        let rendered = format!("{refused} {refused:?}");
        NON_PUBLIC_NEEDLES
            .iter()
            .all(|needle| !rendered.contains(needle))
    };
    let set = [PUBLIC.to_string(), host.to_string()];
    let Err(refused) = device
        .circle
        .update_circle_relays_staging(own, &set, 0)
        .await
    else {
        panic!("a relay update naming a non-public host was staged");
    };
    assert!(
        matches!(refused, CircleError::InvalidData(_)),
        "a relay update naming a non-public host was not refused typed",
    );
    assert!(names_no_host(&refused), "the refusal names the host");
    let Err(refused) = device
        .circle
        .create_circle(
            &device.keys,
            Vec::new(),
            &CircleConfig::new("Refused").with_relays(set),
        )
        .await
    else {
        panic!("a circle was founded on a non-public host");
    };
    assert!(
        matches!(refused, CircleError::Mls(_)),
        "a create naming a non-public host was not refused typed",
    );
    assert!(names_no_host(&refused), "the refusal names the host");
}

/// Haven never writes a relay on a non-public host into a routing component:
/// a relay update or a create naming one is refused, typed and in fixed text
/// that names no host, before anything is recorded or staged, and no line
/// about it names the host.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn haven_never_writes_a_routing_relay_on_a_non_public_host() {
    let lines = Box::pin(helpers::capture_haven_log(async {
        let device = member();
        let own = device
            .circle
            .create_circle(
                &device.keys,
                Vec::new(),
                &CircleConfig::new("Own").with_relays([PUBLIC]),
            )
            .await
            .expect("the device founds a circle on a public relay")
            .circle
            .mls_group_id;
        let session = device.circle.session();
        let epoch = session.epoch(&own).await.expect("the epoch");
        let fanouts = session
            .fanout_ids_for_test(&own)
            .await
            .expect("the records");
        let ledger = device
            .circle
            .list_contaminated_relays()
            .expect("the ledger");
        let circles = device
            .circle
            .get_circles()
            .await
            .expect("the circles")
            .len();
        for host in NON_PUBLIC {
            refuses_to_write(&device, &own, host).await;
        }
        assert_eq!(
            session.epoch(&own).await.expect("the epoch"),
            epoch,
            "a refused relay set moved the circle's epoch",
        );
        assert_eq!(
            session
                .fanout_ids_for_test(&own)
                .await
                .expect("the records"),
            fanouts,
            "a refused relay set staged a commit",
        );
        assert_eq!(
            device
                .circle
                .list_contaminated_relays()
                .expect("the ledger"),
            ledger,
            "a refused relay set was recorded as carrying group traffic",
        );
        assert_eq!(
            relays_of(&device, &own).await,
            vec![PUBLIC.to_string()],
            "a refused relay set changed the circle's relays",
        );
        assert_eq!(
            device
                .circle
                .get_circles()
                .await
                .expect("the circles")
                .len(),
            circles,
            "a circle was founded on a non-public host",
        );
    }))
    .await;
    helpers::assert_some_line_from(&lines, "haven_core");
    helpers::assert_no_needles(&lines, &NON_PUBLIC_NEEDLES);
}

/// A foreign admin — another client's, straight on the engine — and the
/// circle it founded on `relay` with `device` joined.
struct Foreign {
    session: SessionManager,
    group: GroupId,
    _dir: TempDir,
}

impl Foreign {
    async fn found_with(device: &Member, relay: &str) -> Self {
        let dir = TempDir::new().expect("temp dir");
        let keys = Keys::generate();
        let session = SessionManager::new_unencrypted(dir.path(), &keys).expect("session");
        let group = session
            .create_group(
                Vec::new(),
                LocationGroupConfig::new("Foreign")
                    .with_relay(relay)
                    .with_admin(keys.public_key().to_hex()),
            )
            .await
            .expect("the foreign admin founds the circle")
            .group_id;
        let event = build_kp_maintenance_events(
            device.circle.session(),
            &device.keys,
            &[relay.to_string()],
            None,
            None,
        )
        .await
        .expect("a key package")
        .event;
        let invited = session
            .add_members(
                &group,
                vec![SessionManager::key_package_from_event(&event).expect("it parses")],
            )
            .await
            .expect("the foreign admin invites the device");
        let (_, welcomes) = confirm_commit(&session, &invited).await;
        let welcome = welcomes.first().expect("a welcome");
        device
            .circle
            .process_gift_wrapped_invitation(&device.keys, welcome)
            .await
            .expect("the invitation is held");
        device
            .circle
            .accept_invitation(&welcome.id)
            .await
            .expect("the device joins");
        Self {
            session,
            group,
            _dir: dir,
        }
    }

    /// Rotates the circle's routing id to `to`, relays unchanged
    /// (`app-components/nostr-routing-v1.md` 44-45), and returns the commit,
    /// which is sealed under the id it rotates away from.
    async fn rotate(&self, to: [u8; 32]) -> Event {
        let (_, relays) = self
            .session
            .group_routing(&self.group)
            .await
            .expect("routing");
        self.rotate_with(to, relays).await
    }

    /// [`Self::rotate`], the routing naming `relays`.
    async fn rotate_with(&self, to: [u8; 32], relays: Vec<String>) -> Event {
        let routing = NostrRoutingV1::new(to, relays).expect("a routing state");
        let effects = self
            .session
            .send(SendIntent::UpdateAppComponents {
                group_id: self.group.clone(),
                updates: vec![AppComponentData {
                    component_id: NOSTR_ROUTING_COMPONENT_ID,
                    data: encode_nostr_routing_v1(&routing).expect("the component encodes"),
                }],
            })
            .await
            .expect("the foreign admin rotates the routing id");
        confirm_commit(&self.session, &effects).await.0
    }
}

async fn routing_id_of(device: &Member, group: &GroupId) -> [u8; 32] {
    device
        .circle
        .get_circle(group)
        .await
        .expect("read")
        .expect("the circle")
        .circle
        .nostr_group_id
}

/// Gives the circle routed by `id` what a circle keeps under its routing id:
/// a last-known location of `peer`'s, a delivery stamp at `now` and a sync
/// cursor at `cursor_ms`.
fn keep_under(device: &Member, id: [u8; 32], peer: &str, now: i64, cursor_ms: i64) {
    device
        .circle
        .upsert_last_known_location(&haven_core::circle::LastKnownLocation {
            nostr_group_id: id,
            sender_pubkey: peer.to_string(),
            latitude: 1.5,
            longitude: 2.5,
            geohash: "s00twy01".to_string(),
            display_name: None,
            timestamp: now,
            expires_at: now + 300,
            purge_after: 0,
            updated_at: now,
        })
        .expect("a peer's last-known location");
    device
        .circle
        .note_publish_acked(&id, now * 1000)
        .expect("a delivery stamp");
    device
        .circle
        .advance_sync_cursor(&group_cursor_stream(&hex::encode(id)), cursor_ms)
        .expect("the circle's cursor");
}

/// Another client's admin rotates the circle's `nostr_group_id`: Haven
/// applies the commit and follows it. The row, the circle's last-known
/// locations and its delivery health move to the new id; the new id's
/// cursor starts a day back at the latest, so what was sent under it since
/// the commit is asked for; the prior id still routes what was sent under it
/// to the circle; and a leave takes the prior id's sync state with the
/// circle. No line about it names either id.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_routing_rotation_another_client_makes_is_followed_with_what_the_circle_keeps() {
    const GOOD: &str = "wss://rotation-canary61d0.example.com";
    let device = member();
    let foreign = Foreign::found_with(&device, GOOD).await;
    let group = &foreign.group;
    let joined = routing_id_of(&device, group).await;
    let now = chrono::Utc::now().timestamp();
    let peer = Keys::generate().public_key().to_hex();
    let stream = |id: &[u8; 32]| group_cursor_stream(&hex::encode(id));
    let prior_cursor = now * 1000 - 5_000;
    keep_under(&device, joined, &peer, now, prior_cursor);

    let rotated: [u8; 32] = rand::random();
    let rotation = foreign.rotate(rotated).await;
    let lines = Box::pin(helpers::capture_haven_log(async {
        device
            .circle
            .ingest_for_test(&rotation)
            .await
            .expect("the device applies the rotation");
    }))
    .await;
    helpers::assert_no_needles(
        &helpers::haven_core_lines(&lines),
        &[&hex::encode(joined), &hex::encode(rotated)],
    );

    assert_eq!(
        routing_id_of(&device, group).await,
        rotated,
        "the row did not follow"
    );
    let kept = device
        .circle
        .snapshot_last_known_for_circle(&rotated, now)
        .expect("snapshot");
    assert!(
        kept.len() == 1 && kept[0].sender_pubkey == peer,
        "the circle's last-known locations did not move with it",
    );
    assert!(
        device
            .circle
            .snapshot_last_known_for_circle(&joined, now)
            .expect("snapshot")
            .is_empty(),
        "a last-known location stayed under the prior id",
    );
    assert_eq!(
        device
            .circle
            .circle_health(&rotated)
            .expect("health")
            .last_publish_acked_at_ms,
        Some(now * 1000),
        "the circle's delivery health did not move with it",
    );
    let started = device
        .circle
        .read_sync_cursor(&stream(&rotated))
        .expect("read")
        .expect("the new id's cursor is seeded");
    assert!(
        started <= prior_cursor
            && started <= i64::try_from(rotation.created_at.as_secs()).expect("fits") * 1000,
        "the new id's cursor starts after the rotating commit or the prior id's cursor",
    );
    assert_eq!(
        device
            .circle
            .read_sync_cursor(&stream(&joined))
            .expect("read"),
        Some(prior_cursor),
        "the prior id's cursor went while it stands",
    );
    assert_eq!(
        device.circle.relays_for_commit_event(&rotation),
        Some(vec![GOOD.to_string()]),
        "what was sent under the prior id is not the circle's",
    );

    device
        .circle
        .complete_leave(group, now)
        .await
        .expect("the device leaves");
    for id in [&joined, &rotated] {
        assert_eq!(
            device.circle.read_sync_cursor(&stream(id)).expect("read"),
            None,
            "a routing id's cursor outlived the circle",
        );
    }
}

/// A rotation onto the routing id another circle on the device holds is not
/// followed, and both circles are held: MDK has given that id's route to the
/// rotated group, so the other circle hears none of its commits, removals
/// included. Neither circle seals — not even for a claimed foreground's full
/// drive — the hold survives a reopen, and the line that says so names
/// neither circle.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_routing_rotation_onto_another_circles_id_holds_both_circles() {
    const GOOD: &str = "wss://rotation-canary7a2e.example.com";
    // Each circle at relays of its own: what one circle's traffic reaches
    // tells which circle it was sent for.
    const OWN: &str = "wss://own-canary7a2e.example.com";
    let dir = TempDir::new().expect("temp dir");
    let keys = Keys::generate();
    let open = || Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).expect("circle"));
    let device = Member {
        circle: open(),
        keys: keys.clone(),
        dir: TempDir::new().expect("temp dir"),
    };
    let foreign = Foreign::found_with(&device, GOOD).await;
    let joined = routing_id_of(&device, &foreign.group).await;
    let own = own_circle_with_a_member(&device, OWN).await;

    let rotation = foreign.rotate(own.nostr_group_id).await;
    let lines = Box::pin(helpers::capture_haven_log(async {
        device
            .circle
            .ingest_for_test(&rotation)
            .await
            .expect("the device applies the rotation");
    }))
    .await;
    assert_eq!(
        device
            .circle
            .session()
            .group_routing(&foreign.group)
            .await
            .expect("routing")
            .0,
        own.nostr_group_id,
        "premise: the engine applied the rotation",
    );
    assert_eq!(
        routing_id_of(&device, &foreign.group).await,
        joined,
        "a rotation onto another circle's routing id was followed",
    );
    assert_eq!(
        routing_id_of(&device, &own.mls_group_id).await,
        own.nostr_group_id,
        "the other circle's row changed",
    );
    let core_lines = helpers::haven_core_lines(&lines);
    assert!(
        core_lines
            .iter()
            .any(|line| line.message.contains("both circles' sends are held")),
        "a rotation onto another circle's id was not said",
    );
    helpers::assert_no_needles(
        &core_lines,
        &[&hex::encode(joined), &hex::encode(own.nostr_group_id)],
    );

    // Traffic addressed to the shared id is MDK's to give to either circle:
    // it is routed to neither, so none reaches the other circle's relays.
    let addressed = nostr::EventBuilder::new(nostr::Kind::Custom(445), "ciphertext")
        .tag(nostr::Tag::parse(["h", &hex::encode(own.nostr_group_id)]).expect("an h tag"))
        .sign_with_keys(&Keys::generate())
        .expect("signed");
    assert_eq!(
        device.circle.relays_for_commit_event(&addressed),
        None,
        "traffic addressed to a shared routing id was routed to one of the circles",
    );
    let groups = [foreign.group.clone(), own.mls_group_id.clone()];
    assert!(
        held_as_collided(&device.circle, &groups).await,
        "a circle of the two sealed, or was held for another reason",
    );
    drop(device);
    assert!(
        held_as_collided(&open(), &groups).await,
        "the hold did not survive a reopen",
    );

    only_the_leave_is_made(&open(), &own.mls_group_id, OWN).await;
    each_leave_goes_to_its_own_relays(
        &open(),
        &keys,
        (&foreign.group, GOOD),
        (&own.mls_group_id, OWN),
    )
    .await;
}

/// The relays a rotation onto another circle's routing id names are in the
/// contamination ledger though the row follows nothing: the engine hands the
/// circle's traffic — its leave among it — to them from then on, so the
/// profile pool must never use them.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_rotation_onto_another_circles_id_records_the_relays_it_names() {
    const GOOD: &str = "wss://rotation-canary3f6a.example.com";
    const OWN: &str = "wss://own-canary3f6a.example.com";
    const MOVED: &str = "wss://moved-canary3f6a.example.com";
    let device = member();
    let foreign = Foreign::found_with(&device, GOOD).await;
    let joined = routing_id_of(&device, &foreign.group).await;
    let own = own_circle_with_a_member(&device, OWN).await;
    let rotation = foreign
        .rotate_with(
            own.nostr_group_id,
            vec![GOOD.to_string(), MOVED.to_string()],
        )
        .await;
    device
        .circle
        .ingest_for_test(&rotation)
        .await
        .expect("the device applies the rotation");
    assert_eq!(
        routing_id_of(&device, &foreign.group).await,
        joined,
        "premise: a rotation onto another circle's routing id was not followed",
    );
    assert!(
        device
            .circle
            .list_contaminated_relays()
            .expect("the ledger reads")
            .iter()
            .any(|relay| relay.contains("moved-canary3f6a")),
        "a relay the engine sends a held circle's traffic to is missing from the ledger",
    );
}

/// The device's own circle, with one more member: its leave of it starts with
/// a hand-over, the admin step a leave takes under a hold.
async fn own_circle_with_a_member(device: &Member, relay: &str) -> haven_core::circle::Circle {
    let friend = member();
    let friend_package = haven_core::circle::MemberKeyPackage {
        key_package_event: build_kp_maintenance_events(
            friend.circle.session(),
            &friend.keys,
            &[relay.to_string()],
            None,
            None,
        )
        .await
        .expect("a key package")
        .event,
        inbox_relays: vec![relay.to_string()],
        nip65_relays: Vec::new(),
        nip65_write_relays: Vec::new(),
    };
    let own = device
        .circle
        .create_circle(
            &device.keys,
            vec![friend_package],
            &CircleConfig::new("Own").with_relays([relay.to_string()]),
        )
        .await
        .expect("the device founds a circle of its own")
        .circle;
    // As the app's driven create leaves it: the founding Welcomes sent from
    // their records and acknowledged, so no later drive sends them.
    let _ = device.circle.land_staged_for_test().await;
    own
}

/// Whether every one of `groups` is held as a routing collision by the
/// driver, and no relay called.
async fn held_as_collided(circle: &CircleManager, groups: &[GroupId]) -> bool {
    use haven_core::relay::fanout::{scripted::ScriptedFanout, DriveMode, LocationSeal, SendHeld};
    let transport = ScriptedFanout::default();
    let outbox = helpers::drive::Recorder::acking(true);
    let clock = helpers::drive::ManualClock::at(0);
    let full = DriveMode::Full;
    let driver = helpers::drive::through(&transport, &outbox, &clock, &full);
    for group in groups {
        let sealed = driver
            .seal_location(circle, group, &LocationMessage::new(1.0, 2.0))
            .await
            .expect("the seal is answered");
        if !matches!(
            sealed.seal,
            LocationSeal::Deferred(SendHeld::RoutingCollision)
        ) {
            return false;
        }
    }
    transport.calls().is_empty()
}

/// Nothing but the leave is made for a collided circle: an invite, a relay
/// change, an admin change, a removal or the rotation repair would be made at
/// an epoch the engine may not be at. The leave goes through — a member's,
/// and an admin's that hands the circle over first.
async fn only_the_leave_is_made(circle: &CircleManager, own: &GroupId, relay: &str) {
    use haven_core::relay::fanout::{scripted::ScriptedFanout, DriveMode};
    let transport = ScriptedFanout::default();
    let outbox = helpers::drive::Recorder::acking(true);
    let clock = helpers::drive::ManualClock::at(0);
    let full = DriveMode::Full;
    let driver = helpers::drive::through(&transport, &outbox, &clock, &full);
    let refused =
        |answer: Result<_, CircleError>| matches!(answer, Err(CircleError::RoutingCollision));
    let somebody = Keys::generate().public_key();
    assert!(
        refused(driver.add_members(circle, own, &[]).await)
            && refused(
                driver
                    .update_relays(circle, own, &[relay.to_string()])
                    .await
            )
            && refused(driver.admin_handoff(circle, own, &somebody).await)
            && refused(driver.self_demote(circle, own).await)
            && refused(
                driver
                    .remove_members(circle, own, &[somebody.to_hex()])
                    .await
            )
            && matches!(
                driver.repair_rotation(circle, own).await,
                Err(CircleError::RoutingCollision)
            )
            && transport.calls().is_empty(),
        "a change other than the leave was made for a circle whose routing id is shared",
    );
}

/// Each leave of two collided circles goes to its own circle's relays and
/// never the other's: the member's of `member` (at `member_relay`) is
/// recorded and proposed, and the admin's of `admin` (at `admin_relay`)
/// hands the circle over there first and is then proposed there. A leave
/// sent to the other circle's relays would tell them of a circle they do not
/// carry.
async fn each_leave_goes_to_its_own_relays(
    circle: &CircleManager,
    keys: &Keys,
    (member, member_relay): (&GroupId, &str),
    (admin, admin_relay): (&GroupId, &str),
) {
    use haven_core::relay::fanout::scripted::{Answer, ScriptedFanout};
    use haven_core::relay::fanout::{DriveMode, LeaveStatus};
    let transport = ScriptedFanout::default();
    let outbox = helpers::drive::Recorder::acking(true);
    let clock = helpers::drive::ManualClock::at(0);
    let full = DriveMode::Full;
    let driver = helpers::drive::through(&transport, &outbox, &clock, &full);
    let to = |calls: Vec<haven_core::relay::fanout::scripted::Call>| -> Vec<String> {
        calls.into_iter().map(|call| call.target).collect()
    };
    let left = driver
        .leave(circle, member, &keys.public_key())
        .await
        .expect("the member's leave is answered");
    let sent = to(transport.calls());
    assert!(
        left.status == LeaveStatus::Proposed
            && !sent.is_empty()
            && sent.iter().all(|target| target == member_relay),
        "a member's leave of a held circle was not recorded and sent to its own relays alone \
         ({:?}, {sent:?})",
        left.status,
    );
    // The admin circle's relay takes what it is sent: the hand-over must be
    // applied before the admin's own proposal can be made.
    transport.answer(admin_relay, [Answer::Accepted; 4]);
    let handed = driver
        .leave(circle, admin, &keys.public_key())
        .await
        .expect("the admin's leave is answered");
    let resumed = driver
        .resume_leave(circle, admin, &keys.public_key())
        .await
        .expect("the admin's leave carries on");
    let calls = transport.calls();
    let events: std::collections::HashSet<nostr::EventId> =
        calls.iter().map(|call| call.event_id).collect();
    let sent = to(calls);
    // Two events at least: the hand-over, then the admin's own proposal.
    assert!(
        resumed.status == LeaveStatus::Proposed
            && events.len() >= 2
            && sent.iter().all(|target| target == admin_relay),
        "an admin's leave of a held circle did not hand it over and propose at its own relays \
         alone ({:?} then {:?}, {} event(s), {sent:?})",
        handed.status,
        resumed.status,
        events.len(),
    );
}

/// A rotation whose follow a kill between the engine's commit and Haven's
/// persist missed is not missed for good: the row still names the prior id,
/// and after a reopen the next catch-up sweep follows it before it reads the
/// circles.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_rotation_whose_follow_a_kill_missed_is_followed_by_the_next_sweep_after_a_reopen() {
    let _ = allow_ws_loopback_for_test();
    let relay = LocalRelay::new(RelayBuilder::default());
    relay.run().await.expect("the relay runs");
    let url = relay.url().await.to_string();
    let url = url.trim_end_matches('/').to_string();
    let dir = TempDir::new().expect("temp dir");
    let keys = Keys::generate();
    let open = || Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).expect("circle"));
    let device = Member {
        circle: open(),
        keys: keys.clone(),
        dir: TempDir::new().expect("temp dir"),
    };
    let foreign = Foreign::found_with(&device, &url).await;
    let joined = routing_id_of(&device, &foreign.group).await;
    let rotated: [u8; 32] = rand::random();
    let rotation = foreign.rotate(rotated).await;
    device.circle.skip_next_follow_for_test();
    device
        .circle
        .ingest_for_test(&rotation)
        .await
        .expect("the device applies the rotation");
    assert_eq!(
        routing_id_of(&device, &foreign.group).await,
        joined,
        "premise: the follow was missed",
    );
    drop(device);

    let reopened = Member {
        circle: open(),
        keys: keys.clone(),
        dir: TempDir::new().expect("temp dir"),
    };
    let _ = haven_core::relay::catchup::run_catchup_all_circles(
        &reopened.circle,
        &RelayManager::new(),
        10,
    )
    .await;
    assert_eq!(
        routing_id_of(&reopened, &foreign.group).await,
        rotated,
        "a missed follow was not made by the next sweep",
    );
}
/// A Welcome whose routing id the store cannot check against the circles
/// it holds is joined and its circle held, as for a collision: MDK has given
/// the id's route to the joined group already, and a store that cannot say
/// whose the id was cannot name the circle it may have taken it from. The
/// line that says so names nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_welcome_whose_routing_id_the_store_cannot_check_is_joined_and_held() {
    use haven_core::relay::fanout::{scripted::ScriptedFanout, DriveMode, LocationSeal, SendHeld};
    const GOOD: &str = "wss://welcome-canary4c8e.example.com";
    let device = member();
    let dir = TempDir::new().expect("temp dir");
    let foreign_keys = Keys::generate();
    let session = SessionManager::new_unencrypted(dir.path(), &foreign_keys).expect("session");
    let group = session
        .create_group(
            Vec::new(),
            LocationGroupConfig::new("Foreign")
                .with_relay(GOOD)
                .with_admin(foreign_keys.public_key().to_hex()),
        )
        .await
        .expect("the foreign admin founds the circle")
        .group_id;
    let event = build_kp_maintenance_events(
        device.circle.session(),
        &device.keys,
        &[GOOD.to_string()],
        None,
        None,
    )
    .await
    .expect("a key package")
    .event;
    let invited = session
        .add_members(
            &group,
            vec![SessionManager::key_package_from_event(&event).expect("it parses")],
        )
        .await
        .expect("the foreign admin invites the device");
    let (_, welcomes) = confirm_commit(&session, &invited).await;
    let welcome = welcomes.first().expect("a welcome");
    device
        .circle
        .process_gift_wrapped_invitation(&device.keys, welcome)
        .await
        .expect("the invitation is held");
    haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
    rusqlite::Connection::open(
        device
            .dir
            .path()
            .join(haven_core::circle::CIRCLES_DB_FILENAME),
    )
    .expect("the circle store opens")
    .execute_batch("DROP TABLE routing_history;")
    .expect("the history cannot be read");
    let lines = helpers::capture_haven_log(async {
        device
            .circle
            .accept_invitation(&welcome.id)
            .await
            .expect("the device joins");
    })
    .await;
    let joined = routing_id_of(&device, &group).await;
    let core_lines = helpers::haven_core_lines(&lines);
    assert!(
        core_lines
            .iter()
            .any(|line| line.message.contains("could not be read") && line.message.contains("held")),
        "a Welcome whose routing id was not checked was not said",
    );
    helpers::assert_no_needles(&core_lines, &[&hex::encode(joined), GOOD]);
    let transport = ScriptedFanout::default();
    let outbox = helpers::drive::Recorder::acking(true);
    let clock = helpers::drive::ManualClock::at(0);
    let full = DriveMode::Full;
    let driver = helpers::drive::through(&transport, &outbox, &clock, &full);
    let sealed = driver
        .seal_location(&device.circle, &group, &LocationMessage::new(1.0, 2.0))
        .await
        .expect("the seal is answered");
    assert!(
        matches!(
            sealed.seal,
            LocationSeal::Deferred(SendHeld::RoutingCollision)
        ) && transport.calls().is_empty(),
        "a circle joined under a routing id nobody could check shares",
    );
}

/// A Welcome to a circle whose routing id another circle on the device
/// already holds — another client's admin rotated its circle onto it before
/// inviting — holds both circles, as a rotation onto it does: MDK has given
/// the id's route to the joined group.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_welcome_naming_another_circles_routing_id_holds_both_circles() {
    const GOOD: &str = "wss://rotation-canary2d4b.example.com";
    const OWN: &str = "wss://own-canary2d4b.example.com";
    let device = member();
    let own = own_circle_with_a_member(&device, OWN).await;
    let (foreign, welcome) = invited_onto(&device, own.nostr_group_id, GOOD).await;
    let lines = helpers::capture_haven_log(async {
        device
            .circle
            .accept_invitation(&welcome)
            .await
            .expect("the device joins");
    })
    .await;
    helpers::assert_no_needles(
        &helpers::haven_core_lines(&lines),
        &[&hex::encode(own.nostr_group_id)],
    );
    assert!(
        held_as_collided(
            &device.circle,
            &[foreign.group.clone(), own.mls_group_id.clone()],
        )
        .await,
        "a circle of the two was not held after a Welcome named the other's routing id",
    );
    each_leave_goes_to_its_own_relays(
        &device.circle,
        &device.keys,
        (&foreign.group, GOOD),
        (&own.mls_group_id, OWN),
    )
    .await;
    a_shared_id_is_nobodys(&device, &foreign.group, own.nostr_group_id).await;
}

/// A circle at `good` another client's admin founded, rotated onto `id` and
/// then invited `device` to, and the id of the Welcome `device` holds, not
/// yet accepted.
async fn invited_onto(device: &Member, id: [u8; 32], good: &str) -> (Foreign, nostr::EventId) {
    let dir = TempDir::new().expect("temp dir");
    let foreign_keys = Keys::generate();
    let session = SessionManager::new_unencrypted(dir.path(), &foreign_keys).expect("session");
    let group = session
        .create_group(
            Vec::new(),
            LocationGroupConfig::new("Foreign")
                .with_relay(good)
                .with_admin(foreign_keys.public_key().to_hex()),
        )
        .await
        .expect("the foreign admin founds the circle")
        .group_id;
    let foreign = Foreign {
        session,
        group,
        _dir: dir,
    };
    let _ = foreign.rotate(id).await;
    let event = build_kp_maintenance_events(
        device.circle.session(),
        &device.keys,
        &[good.to_string()],
        None,
        None,
    )
    .await
    .expect("a key package")
    .event;
    let invited = foreign
        .session
        .add_members(
            &foreign.group,
            vec![SessionManager::key_package_from_event(&event).expect("it parses")],
        )
        .await
        .expect("the foreign admin invites the device");
    let (_, welcomes) = confirm_commit(&foreign.session, &invited).await;
    let welcome = welcomes.first().expect("a welcome");
    device
        .circle
        .process_gift_wrapped_invitation(&device.keys, welcome)
        .await
        .expect("the invitation is held");
    (foreign, welcome.id)
}

/// A Welcome naming another circle's routing id, joined while the store
/// could not say whose the id was, holds the joined circle at once and the
/// other — the one MDK took the route from — from the next routing
/// reconcile on, which finds the two rows naming one id. Until then the
/// other is not held: a repair after the fact, not a prevention. The line
/// that says so names neither circle.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_welcome_joined_under_a_store_error_holds_the_other_circle_at_the_next_reconcile() {
    const GOOD: &str = "wss://rotation-canary5e1f.example.com";
    const OWN: &str = "wss://own-canary5e1f.example.com";
    let device = member();
    let own = own_circle_with_a_member(&device, OWN).await;
    let (foreign, welcome) = invited_onto(&device, own.nostr_group_id, GOOD).await;
    haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
    let store = rusqlite::Connection::open(
        device
            .dir
            .path()
            .join(haven_core::circle::CIRCLES_DB_FILENAME),
    )
    .expect("the circle store opens");
    store
        .execute_batch("ALTER TABLE routing_history RENAME TO routing_history_unread;")
        .expect("the history cannot be read");
    device
        .circle
        .accept_invitation(&welcome)
        .await
        .expect("the device joins");
    store
        .execute_batch("ALTER TABLE routing_history_unread RENAME TO routing_history;")
        .expect("the history reads again");
    assert!(
        held_as_collided(&device.circle, std::slice::from_ref(&foreign.group)).await
            && !held_as_collided(&device.circle, std::slice::from_ref(&own.mls_group_id)).await,
        "premise: the joined circle is held and the other is not",
    );
    let lines = helpers::capture_haven_log(device.circle.reconcile_routing()).await;
    assert!(
        held_as_collided(
            &device.circle,
            &[foreign.group.clone(), own.mls_group_id.clone()],
        )
        .await,
        "the circle whose routing id a Welcome took under a store error was not held by the next \
         reconcile",
    );
    let core_lines = helpers::haven_core_lines(&lines);
    assert!(
        core_lines
            .iter()
            .any(|line| line.message.contains("share a routing id")),
        "the hold the reconcile found was not said",
    );
    helpers::assert_no_needles(
        &core_lines,
        &[
            &hex::encode(own.nostr_group_id),
            &hex::encode(own.mls_group_id.as_slice()),
            &hex::encode(foreign.group.as_slice()),
            GOOD,
            OWN,
        ],
    );
}

/// In a circle whose routing id another circle on the device holds too, the
/// leave the engine re-mints for a later epoch is recorded — for the circle
/// MDK's own record of the proposal names, not the one its shared address
/// would name — and sent to that circle's relays alone: the lookup by
/// address finds two circles there, and recorded nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_collided_circles_later_leave_proposal_is_recorded_for_its_own_relays() {
    use haven_core::relay::fanout::scripted::{Answer, ScriptedFanout};
    use haven_core::relay::fanout::{DriveMode, LeaveStatus};
    const GOOD: &str = "wss://rotation-canary6c0e.example.com";
    const OWN: &str = "wss://own-canary6c0e.example.com";
    let device = member();
    let foreign = Foreign::found_with(&device, GOOD).await;
    let own = own_circle_with_a_member(&device, OWN).await;
    let transport = ScriptedFanout::default();
    transport.answer(GOOD, [Answer::Accepted; 4]);
    let outbox = helpers::drive::Recorder::acking(true);
    let clock = helpers::drive::ManualClock::at(0);
    let full = DriveMode::Full;
    let driver = helpers::drive::through(&transport, &outbox, &clock, &full);
    let left = driver
        .leave(&device.circle, &foreign.group, &device.keys.public_key())
        .await
        .expect("the leave is answered");
    assert_eq!(
        left.status,
        LeaveStatus::Proposed,
        "premise: the first epoch's leave"
    );
    let _ = transport.calls();

    // The foreign admin's commit moves the circle on; the engine re-mints the
    // leave for the epoch it reaches.
    let foreign_id = routing_id_of(&device, &foreign.group).await;
    let commit = foreign
        .rotate_with(foreign_id, vec![GOOD.to_string()])
        .await;
    let session = device.circle.session();
    let _ = session.process_event(&commit).await;
    let mut reminted = session
        .settle_receive_for_test(&foreign.group)
        .await
        .expect("the commit is applied");
    // A receive advance takes inputs only; the full one re-mints the leave.
    reminted.publish.extend(
        session
            .advance_convergence(&foreign.group)
            .await
            .expect("the full advance")
            .publish,
    );
    assert!(
        reminted
            .publish
            .iter()
            .any(|work| matches!(work, PublishWork::Proposal { .. })),
        "premise: the engine re-minted the leave for the epoch the commit reached",
    );
    // The device's own circle comes to name the same routing id, as a
    // collision leaves two groups: the address names both.
    let (_, own_relays) = session
        .group_routing(&own.mls_group_id)
        .await
        .expect("routing");
    let onto = NostrRoutingV1::new(foreign_id, own_relays).expect("a routing state");
    let effects = session
        .send(SendIntent::UpdateAppComponents {
            group_id: own.mls_group_id.clone(),
            updates: vec![AppComponentData {
                component_id: NOSTR_ROUTING_COMPONENT_ID,
                data: encode_nostr_routing_v1(&onto).expect("the component encodes"),
            }],
        })
        .await
        .expect("the own circle's routing moves");
    let _ = confirm_commit(session, &effects).await;

    let staged = session
        .stage_commits_for_test(reminted, helpers::drive::ManualClock::ORIGIN)
        .await;
    let _ = driver.resume(&device.circle).await;
    let sent: Vec<String> = transport
        .calls()
        .into_iter()
        .map(|call| call.target)
        .collect();
    assert!(
        !staged.proposals.is_empty() && !sent.is_empty() && sent.iter().all(|to| to == GOOD),
        "a collided circle's later leave proposal was not recorded and sent to its own relays \
         alone ({} recorded, {sent:?})",
        staged.proposals.len(),
    );
}

/// A routing id two rows name — a Welcome named another circle's — on
/// distinct relays is listened for once, at both rows' relays: the first
/// follow moves it once, and a follow that finds it so moves nothing: a listing per row would move its REQ from
/// one row's relays to the other's at every follow.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_routing_id_two_rows_name_is_listed_once_at_both_rows_relays() {
    const GOOD: &str = "wss://rotation-canary8b3d.example.com";
    const OWN: &str = "wss://own-canary8b3d.example.com";
    let device = member();
    let own = own_circle_with_a_member(&device, OWN).await;
    let (_foreign, welcome) = invited_onto(&device, own.nostr_group_id, GOOD).await;
    device
        .circle
        .accept_invitation(&welcome)
        .await
        .expect("the device joins");
    let specs: Vec<CircleSpec> = device
        .circle
        .get_circles()
        .await
        .expect("the circles are read")
        .into_iter()
        .map(|held| CircleSpec {
            group_id_hex: hex::encode(held.circle.nostr_group_id),
            relays: held.circle.relays,
        })
        .collect();
    let engine = LiveSyncCore::new_local(
        Arc::clone(&device.circle),
        device.keys.public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
    );
    engine.start(&specs, &[]).await.expect("the engine starts");
    let first = engine.follow_routing().await.expect("followed");
    let again = engine.follow_routing().await.expect("followed again");
    let pooled: Vec<String> = engine
        .relays_in_pool_for_test()
        .await
        .iter()
        .map(ToString::to_string)
        .collect();
    let _ = engine.stop().await;
    assert!(
        first == 1
            && again == 0
            && [GOOD, OWN]
                .iter()
                .all(|relay| pooled.iter().any(|pooled| pooled.starts_with(relay))),
        "a routing id two rows name was moved more than once by one follow, or again by a follow \
         that found it listed, or is not listened for at both rows' relays ({first} then {again} \
         moved)",
    );
}

/// With two rows naming one routing id — `joined`'s and another's — a write
/// made with the id is attributed to neither circle, the health read under it
/// carries no instant, and leaving `joined` drops the rows under the id,
/// whose owner neither circle can be told to be, and leaves the other circle
/// routed by it.
async fn a_shared_id_is_nobodys(device: &Member, joined: &GroupId, shared: [u8; 32]) {
    assert_eq!(
        routing_id_of(device, joined).await,
        shared,
        "premise: the joined circle's row names the id the other's does",
    );
    device
        .circle
        .note_peer_event(&shared, chrono::Utc::now().timestamp() * 1000)
        .expect("the stamp is taken");
    assert_eq!(
        device
            .circle
            .circle_health(&shared)
            .expect("health")
            .last_peer_event_at_ms,
        None,
        "a write made with a routing id two circles name was given to one of them",
    );
    haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
    let store = rusqlite::Connection::open(
        device
            .dir
            .path()
            .join(haven_core::circle::CIRCLES_DB_FILENAME),
    )
    .expect("the circle store opens");
    store
        .execute(
            "INSERT INTO circle_health (nostr_group_id, last_publish_acked_at_ms) VALUES (?1, 1) \
             ON CONFLICT (nostr_group_id) DO UPDATE SET last_publish_acked_at_ms = 1",
            [&shared[..]],
        )
        .expect("the other circle's row under the id");
    // That row is either circle's to have written: neither is shown its
    // instants, and a held circle's health is unknown, not stale.
    assert_eq!(
        device.circle.circle_health(&shared).expect("health"),
        haven_core::circle::CircleHealth::default(),
        "a circle held for a collision was shown instants another circle may have written",
    );
    device
        .circle
        .complete_leave(joined, chrono::Utc::now().timestamp())
        .await
        .expect("the joined circle is left");
    let kept: i64 = store
        .query_row(
            "SELECT COUNT(*) FROM circle_health WHERE nostr_group_id = ?1",
            [&shared[..]],
            |row| row.get(0),
        )
        .expect("read");
    assert_eq!(
        kept, 0,
        "leaving one of two circles that name a routing id kept a row under it that either \
         may have written",
    );
    assert!(
        device
            .circle
            .get_circles()
            .await
            .expect("the circles are read")
            .iter()
            .any(|held| held.circle.nostr_group_id == shared && held.circle.mls_group_id != *joined),
        "leaving one of two circles that name a routing id took the other circle with it",
    );
}

/// The outer layer of `event` re-signed by a fresh throwaway key with
/// `created_at` set: a relay's copy of a kind-445 whose envelope says it was
/// authored then. The inner MLS message — what the engine authenticates — is
/// untouched.
fn dated(event: &Event, created_at: u64) -> Event {
    nostr::EventBuilder::new(event.kind, event.content.clone())
        .tags(event.tags.clone())
        .custom_created_at(nostr::Timestamp::from(created_at))
        .sign_with_keys(&Keys::generate())
        .expect("signed")
}

/// A rotation applied more than a day after it was authored — taken in while
/// this device's own commit was pending, and applied once that commit was
/// undone — has its new id asked for from no later than the
/// rotating commit, not from a day back: everything sent under the new id
/// since the rotation is asked for.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_rotation_applied_days_after_it_was_made_asks_the_new_id_from_the_rotation() {
    const GOOD: &str = "wss://rotation-canary9e1f.example.com";
    let device = member();
    let foreign = Foreign::found_with(&device, GOOD).await;
    let own = device
        .circle
        .session()
        .send(SendIntent::SelfUpdate {
            group_id: foreign.group.clone(),
        })
        .await
        .expect("the device stages a commit of its own");
    let pending = own
        .publish
        .iter()
        .find_map(|work| match work {
            PublishWork::GroupEvolution { pending, .. } => Some(*pending),
            _ => None,
        })
        .expect("the commit is pending");
    let rotated: [u8; 32] = rand::random();
    let made_at = nostr::Timestamp::now().as_secs() - 3 * 86_400;
    let rotation = dated(&foreign.rotate(rotated).await, made_at);
    device
        .circle
        .ingest_for_test(&rotation)
        .await
        .expect("the rotation is taken in behind the pending commit");
    assert_ne!(
        routing_id_of(&device, &foreign.group).await,
        rotated,
        "premise: nothing is applied behind the pending commit",
    );
    device
        .circle
        .session()
        .publish_failed(pending)
        .await
        .expect("the device's own commit is undone");
    // The rotation waits as a convergence input: its deadlines are served, as
    // a receive plane serves them, and the next reconcile follows it.
    let session = device.circle.session();
    let _ = session.advance_for_receive(&foreign.group).await;
    while let Some(after) = session.receive_retick_after(&foreign.group).await {
        tokio::time::sleep(after).await;
        let _ = session.advance_for_receive(&foreign.group).await;
    }
    device.circle.reconcile_routing().await;
    assert_eq!(
        routing_id_of(&device, &foreign.group).await,
        rotated,
        "premise: the rotation was applied and the row followed",
    );
    let started = device
        .circle
        .read_sync_cursor(&group_cursor_stream(&hex::encode(rotated)))
        .expect("read")
        .expect("the new id's cursor is seeded");
    assert!(
        started <= i64::try_from(made_at).expect("fits") * 1000,
        "the new id is asked for from later than the rotation: what was sent under it since \
         is never asked for",
    );
}

/// What a caller writes with the routing id a circle had before a rotation —
/// a last-known location, a delivery stamp, read from a row read before the
/// move — lands on the circle under the id its row names now, never on an
/// orphan row; and a leave takes every row under every id the circle used,
/// a residue row under its prior id included.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn writes_made_with_a_rotated_circles_prior_id_land_on_it_and_go_with_it() {
    const GOOD: &str = "wss://rotation-canary4c8a.example.com";
    let device = member();
    let foreign = Foreign::found_with(&device, GOOD).await;
    let group = &foreign.group;
    let prior = routing_id_of(&device, group).await;
    let rotated: [u8; 32] = rand::random();
    let rotation = foreign.rotate(rotated).await;
    device
        .circle
        .ingest_for_test(&rotation)
        .await
        .expect("the device applies the rotation");
    assert_eq!(
        routing_id_of(&device, group).await,
        rotated,
        "premise: followed"
    );

    let now = chrono::Utc::now().timestamp();
    let peer = Keys::generate().public_key().to_hex();
    keep_under(&device, prior, &peer, now, now * 1000);
    device
        .circle
        .note_peer_event(&prior, now * 1000)
        .expect("a peer stamp");
    let db = device
        .dir
        .path()
        .join(haven_core::circle::CIRCLES_DB_FILENAME);
    haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
    let store = rusqlite::Connection::open(&db).expect("the circle store opens");
    let rows_under = |id: &[u8; 32]| -> i64 {
        ["last_known_locations", "circle_health"]
            .iter()
            .map(|table| {
                store
                    .query_row(
                        &format!("SELECT COUNT(*) FROM {table} WHERE nostr_group_id = ?1"),
                        [&id[..]],
                        |row| row.get::<_, i64>(0),
                    )
                    .expect("counted")
            })
            .sum()
    };
    assert_eq!(
        rows_under(&prior),
        0,
        "a write with the prior id left an orphan row"
    );
    let kept = device
        .circle
        .snapshot_last_known_for_circle(&rotated, now)
        .expect("snapshot");
    let health = device.circle.circle_health(&rotated).expect("health");
    assert!(
        kept.iter().any(|row| row.sender_pubkey == peer)
            && health.last_publish_acked_at_ms == Some(now * 1000)
            && health.last_peer_event_at_ms == Some(now * 1000),
        "a write with the prior id did not land on the circle",
    );

    // Residue under the prior id, as a write before this batch could leave.
    store
        .execute(
            "INSERT INTO circle_health (nostr_group_id, last_publish_acked_at_ms) VALUES (?1, 1)",
            [&prior[..]],
        )
        .expect("residue planted");
    device
        .circle
        .complete_leave(group, now)
        .await
        .expect("the device leaves");
    assert_eq!(
        (rows_under(&prior), rows_under(&rotated)),
        (0, 0),
        "a row under an id the circle used outlived the leave",
    );
}
