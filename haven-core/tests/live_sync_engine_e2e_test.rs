//! End-to-end integration test for the persistent live-sync engine over a real
//! in-process Nostr relay.
//!
//! Proves the full networking glue wires up: the engine `Client` CONNECTS to a
//! real relay, the supervisor RECEIVES a live `kind:445`, the worker ROUTES it
//! by its `#h` tag to the right circle context, the processor PROCESSES it, and
//! the decrypted location REACHES the fan-out bus.
//!
//! # Why the oracle is a decrypted location on the bus
//!
//! Two earlier ports of this file used weaker proxies, and each was invalidated
//! by the layer underneath it.
//!
//! The pre-migration tests observed the traversal via a `Status(Unprocessable)`
//! bus emit for an undecryptable 445; the Dark Matter engine classifies an
//! undecryptable / unknown-group 445 as `Ok(Stale)` (not an error), so that
//! emit stopped firing. The DM-5a port therefore switched to "the per-circle
//! cursor advanced".
//!
//! That proxy is gone too, and for a reason worth stating: a delivered event no
//! longer advances any cursor, because its outer `created_at` is chosen by
//! whoever signed the envelope and is bound to nothing the engine authenticates
//! (see `live_sync::anchor`). In this plane the cursor moves when a relay sends
//! `EOSE`, which happens whether or not a single event was routed — so a
//! cursor-based delivery assertion would now pass VACUOUSLY.
//!
//! So these tests use real circles and real locations: a
//! `LiveSyncEvent::Location` carrying the expected `nostr_group_id` and sender
//! can only appear if the event traversed connect → subscribe → receive → route
//! → decrypt → emit. That is what the file claims to prove, and unlike both
//! proxies it cannot be satisfied by anything else.

mod helpers;

use std::sync::Arc;
use std::time::Duration;

use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::{GroupId, GroupIdExt as _};
use haven_core::relay::live_sync::{
    group_cursor_stream, CircleSpec, Claim, HealthAction, LiveSyncCore, LiveSyncEvent,
    SyncStatusReason,
};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use nostr::{Event, Keys};
use nostr_relay_builder::builder::{PolicyResult, QueryPolicy};
use nostr_relay_builder::{LocalRelay, MockRelay, RelayBuilder};
use nostr_sdk::Client;
use tempfile::TempDir;

/// A real MLS circle the engine's `CircleManager` administers, plus the peer
/// whose locations it will receive.
struct RealCircle {
    peer: Arc<CircleManager>,
    peer_keys: Keys,
    mls_group_id: GroupId,
    nostr_group_id: [u8; 32],
    _peer_dir: TempDir,
}

impl RealCircle {
    fn hex(&self) -> String {
        hex::encode(self.nostr_group_id)
    }

    /// The peer's store opened again by a manager of its own, the first one
    /// dropped before: a process's first open.
    fn reopened(self) -> Self {
        let Self {
            peer,
            peer_keys,
            mls_group_id,
            nostr_group_id,
            _peer_dir: dir,
        } = self;
        drop(peer);
        Self {
            peer: Arc::new(
                CircleManager::new_unencrypted(dir.path(), &peer_keys)
                    .expect("the peer's store opens again"),
            ),
            peer_keys,
            mls_group_id,
            nostr_group_id,
            _peer_dir: dir,
        }
    }

    fn spec(&self, url: &str) -> CircleSpec {
        CircleSpec {
            group_id_hex: self.hex(),
            relays: vec![url.to_string()],
        }
    }

    /// A genuine, MLS-encrypted `kind:445` location from the peer.
    async fn peer_location(&self, lat: f64, lon: f64) -> Event {
        self.peer
            .seal_location_for_test(&self.mls_group_id, &LocationMessage::new(lat, lon))
            .await
            .expect("peer encrypts a location")
            .0
    }
}

/// Creates a circle administered by `admin` with one fresh peer member.
async fn real_circle(
    admin: &Arc<CircleManager>,
    admin_keys: &Keys,
    relays: &[String],
) -> RealCircle {
    let peer_dir = TempDir::new().unwrap();
    let peer_keys = Keys::generate();
    let peer = Arc::new(CircleManager::new_unencrypted(peer_dir.path(), &peer_keys).unwrap());
    let kp_event = build_kp_maintenance_events(
        peer.session(),
        &peer_keys,
        &["wss://kp.example.com".to_string()],
        None,
        None,
    )
    .await
    .expect("peer key package")
    .event;
    let member = MemberKeyPackage {
        key_package_event: kp_event,
        inbox_relays: vec!["wss://inbox.example.com".to_string()],
        nip65_relays: vec![],
    };

    let config = CircleConfig::new("Engine E2E Circle").with_relays(relays.to_vec());
    let result = admin
        .create_circle(admin_keys, vec![member], &config)
        .await
        .expect("create circle");
    // As the app's driven create leaves it: the founding Welcomes sent from
    // their records and acknowledged, so no later drive sends them.
    let _ = admin.land_staged_for_test().await;
    let mls_group_id = result.circle.mls_group_id.clone();
    let nostr_group_id = result.circle.nostr_group_id;

    let welcome = result
        .welcome_events
        .iter()
        .find(|w| w.recipient_pubkey == peer_keys.public_key().to_hex())
        .expect("welcome for the peer");
    peer.process_gift_wrapped_invitation(&peer_keys, &welcome.event)
        .await
        .expect("peer processes the welcome");
    peer.accept_invitation(&welcome.event.id)
        .await
        .expect("peer joins");

    RealCircle {
        peer,
        peer_keys,
        mls_group_id,
        nostr_group_id,
        _peer_dir: peer_dir,
    }
}

/// Publishes `event` to `url` from a publisher independent of the engine.
async fn publish(url: &str, event: &Event) {
    let publisher = Client::builder().build();
    publisher.add_relay(url).await.unwrap();
    publisher.connect().await;
    publisher.send_event(event).await.expect("publish");
}

/// Whether a relay has answered the engine's REQ, issued at or after
/// `since_secs`, with `EOSE` for every one of `circles` (hex routing ids).
///
/// The engine's own signal: it moves a circle's cursor up to the instant it
/// issued the REQ only when that REQ's `EOSE` arrives (`live_sync::anchor`), and
/// until then the cursor is the start's seed, a day older.
fn anchored_since(engine_circle: &CircleManager, circles: &[String], since_secs: u64) -> bool {
    let floor_ms = i64::try_from(since_secs)
        .unwrap_or(i64::MAX)
        .saturating_mul(1000);
    circles.iter().all(|hex| {
        engine_circle
            .read_sync_cursor(&group_cursor_stream(hex))
            .ok()
            .flatten()
            .is_some_and(|ms| ms >= floor_ms)
    })
}

/// Waits (bounded) for [`anchored_since`]. An event published once this is
/// `true` reaches the engine LIVE — the relay holds the subscription and has
/// finished its stored page — never as part of that page.
async fn subscription_established(
    engine_circle: &CircleManager,
    circles: &[String],
    since_secs: u64,
) -> bool {
    for _ in 0..150 {
        if anchored_since(engine_circle, circles, since_secs) {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    false
}

/// The first whole second after the one `circle`'s cursor stands at, once the
/// local clock has reached it (bounded wait).
///
/// The cursor is the second a REQ was issued in. A REQ issued within the second
/// it already names would leave it where it is; one issued from the second
/// returned here on must lift it, so [`anchored_since`] that second tells the
/// two REQs apart.
async fn second_after_cursor(engine_circle: &CircleManager, circle: &str) -> Option<u64> {
    let cursor_ms = engine_circle
        .read_sync_cursor(&group_cursor_stream(circle))
        .ok()
        .flatten()?;
    for _ in 0..20 {
        let now_secs = nostr::Timestamp::now().as_secs();
        let now_ms = i64::try_from(now_secs)
            .unwrap_or(i64::MAX)
            .saturating_mul(1000);
        if now_ms > cursor_ms {
            return Some(now_secs);
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    None
}

/// Every filter a relay was asked with, and the socket that asked.
#[derive(Debug, Clone, Default)]
struct RecordedReqs(Arc<std::sync::Mutex<Vec<(std::net::SocketAddr, nostr::Filter)>>>);

impl QueryPolicy for RecordedReqs {
    fn admit_query<'a>(
        &'a self,
        query: &'a nostr::Filter,
        addr: &'a std::net::SocketAddr,
    ) -> nostr_sdk::prelude::BoxedFuture<'a, PolicyResult> {
        self.0
            .lock()
            .expect("the record of requests")
            .push((*addr, query.clone()));
        Box::pin(async { PolicyResult::Accept })
    }
}

/// Waits (bounded) for a decrypted location from `circle`'s peer on the bus.
///
/// Consumes unrelated events so a `Status` or another circle's `Location`
/// cannot mask the one being waited for.
async fn wait_for_location(
    bus: &mut tokio::sync::broadcast::Receiver<LiveSyncEvent>,
    circle: &RealCircle,
    budget: Duration,
) -> bool {
    let want_gid = circle.nostr_group_id.to_vec();
    let want_sender = circle.peer_keys.public_key().to_hex();
    let deadline = tokio::time::Instant::now() + budget;
    while tokio::time::Instant::now() < deadline {
        match tokio::time::timeout(Duration::from_millis(500), bus.recv()).await {
            Ok(Ok(LiveSyncEvent::Location {
                nostr_group_id,
                sender_pubkey,
                ..
            })) if nostr_group_id == want_gid && sender_pubkey == want_sender => return true,
            Ok(Ok(_)) | Err(_) => {}
            Ok(Err(_)) => return false,
        }
    }
    false
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_receives_routes_and_processes_a_kind445_over_a_real_relay() {
    // The engine enforces a WSS-only relay gate; arm the debug-only loopback
    // opt-in so the in-process `ws://127.0.0.1` relay is permitted for this test.
    let _ = haven_core::relay::allow_ws_loopback_for_test();

    let relay = MockRelay::run().await.expect("mock relay starts");
    let url = relay.url().await.to_string();

    let dir = TempDir::new().unwrap();
    let admin_keys = Keys::generate();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &admin_keys).unwrap());
    let fx = real_circle(&circle, &admin_keys, std::slice::from_ref(&url)).await;

    let engine = LiveSyncCore::new_local(
        Arc::clone(&circle),
        admin_keys.public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
    );
    let mut bus = engine.bus().subscribe();
    let opened = nostr::Timestamp::now().as_secs();
    engine
        .start(&[fx.spec(&url)], &[])
        .await
        .expect("engine starts and subscribes");
    assert!(
        subscription_established(&circle, &[fx.hex()], opened).await,
        "premise: the relay answered the engine's REQ before anything is published, \
         so the delivery below is live"
    );

    // A separate publisher sends the peer's real kind:445 for our circle.
    publish(&url, &fx.peer_location(52.370_216, 4.895_168).await).await;

    // The event must traverse connect → subscribe → receive → route → decrypt →
    // emit. Nothing but a genuine delivery produces this.
    assert!(
        wait_for_location(&mut bus, &fx, Duration::from_secs(15)).await,
        "the relayed kind:445 must traverse the whole engine path and surface as \
         a decrypted location"
    );

    // Teardown only: every assertion has already run. The outcome is not
    // asserted here because the drain contract itself is pinned by
    // `join_tasks_*` and the `stop_*` unit tests in
    // `src/relay/live_sync/session.rs`, and by the same-store restart
    // assertions in `live_sync_cursor_replay_e2e`.
    let _ = engine.stop().await;
}

/// Waits (bounded) for a decrypted location of `nostr_group_id` from
/// `sender` (hex) on the bus.
async fn wait_for_location_from(
    bus: &mut tokio::sync::broadcast::Receiver<LiveSyncEvent>,
    nostr_group_id: [u8; 32],
    sender: &str,
) -> bool {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
    while tokio::time::Instant::now() < deadline {
        match tokio::time::timeout(Duration::from_millis(500), bus.recv()).await {
            Ok(Ok(LiveSyncEvent::Location {
                nostr_group_id: gid,
                sender_pubkey,
                ..
            })) if gid == nostr_group_id.to_vec() && sender_pubkey == sender => return true,
            Ok(Ok(_)) | Err(_) => {}
            Ok(Err(_)) => return false,
        }
    }
    false
}

/// The committer of a change of a circle's relays listens where the circle
/// now lives: once its own change is applied — the legacy way here, which no
/// drive of the session confirms — the health tick a claimed foreground
/// makes moves the circle's REQ onto the new relays (and the old ones, for a
/// day), and a location the peer sends to the new relay alone is delivered.
/// No line about it names a circle or a relay.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_committer_of_a_relay_change_listens_where_the_circle_now_lives() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let old = MockRelay::run().await.expect("mock relay starts");
    let old_url = old.url().await.to_string();
    let new = MockRelay::run().await.expect("second mock relay starts");
    let new_url = new.url().await.to_string();
    let dir = TempDir::new().unwrap();
    let admin_keys = Keys::generate();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &admin_keys).unwrap());
    let fx = real_circle(&circle, &admin_keys, std::slice::from_ref(&old_url)).await;
    let engine = LiveSyncCore::new_local(
        Arc::clone(&circle),
        admin_keys.public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
    );
    let mut bus = engine.bus().subscribe();
    engine
        .start(&[fx.spec(&old_url)], &[])
        .await
        .expect("engine starts and subscribes");
    let update = circle
        .update_relays_for_test(&fx.mls_group_id, std::slice::from_ref(&new_url))
        .await
        .expect("the admin changes the circle's relays");
    fx.peer
        .ingest_for_test(&update)
        .await
        .expect("the peer applies it");

    let lines = helpers::capture_haven_log(async {
        let _ = engine.maintain_subscription_health(Claim::Foreground).await;
    })
    .await;
    helpers::assert_no_needles(
        &helpers::haven_core_lines(&lines),
        &[&fx.hex(), &old_url, &new_url, "127.0.0.1"],
    );
    publish(&new_url, &fx.peer_location(52.37, 4.89).await).await;
    assert!(
        wait_for_location_from(
            &mut bus,
            fx.nostr_group_id,
            &fx.peer_keys.public_key().to_hex()
        )
        .await,
        "a location sent to the circle's new relay alone was not delivered",
    );
    let _ = engine.stop().await;
}

/// The receiver of a peer's change of a circle's relays listens where the
/// circle now lives too, by itself: the engine applies the admin's routing
/// commit off the old relay, the session moves the circle's REQ with no call
/// from the app, and what the admin sends to the new relay alone is
/// delivered.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_receiver_of_a_peers_relay_change_listens_where_the_circle_now_lives() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let old = MockRelay::run().await.expect("mock relay starts");
    let old_url = old.url().await.to_string();
    let new = MockRelay::run().await.expect("second mock relay starts");
    let new_url = new.url().await.to_string();
    let dir = TempDir::new().unwrap();
    let admin_keys = Keys::generate();
    let admin = Arc::new(CircleManager::new_unencrypted(dir.path(), &admin_keys).unwrap());
    let fx = real_circle(&admin, &admin_keys, std::slice::from_ref(&old_url)).await;
    let engine = LiveSyncCore::new_local(
        Arc::clone(&fx.peer),
        fx.peer_keys.public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
    );
    let mut bus = engine.bus().subscribe();
    let opened = nostr::Timestamp::now().as_secs();
    engine
        .start(&[fx.spec(&old_url)], &[])
        .await
        .expect("the peer's engine starts and subscribes");
    assert!(
        subscription_established(&fx.peer, &[fx.hex()], opened).await,
        "premise: the old relay answered the engine's REQ"
    );
    let update = admin
        .update_relays_for_test(&fx.mls_group_id, std::slice::from_ref(&new_url))
        .await
        .expect("the admin changes the circle's relays, and applies it on its ack");
    publish(&old_url, &update).await;
    let applied = tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            if let Ok(LiveSyncEvent::GroupUpdate { nostr_group_id, .. }) = bus.recv().await {
                if nostr_group_id == fx.nostr_group_id.to_vec() {
                    return;
                }
            }
        }
    })
    .await;
    assert!(
        applied.is_ok(),
        "premise: the engine applied the routing commit"
    );

    let (sealed, _, _) = admin
        .seal_location_for_test(&fx.mls_group_id, &LocationMessage::new(48.85, 2.35))
        .await
        .expect("the admin seals at the new epoch");
    publish(&new_url, &sealed).await;
    assert!(
        wait_for_location_from(
            &mut bus,
            fx.nostr_group_id,
            &admin_keys.public_key().to_hex()
        )
        .await,
        "a location sent to the circle's new relay alone was not delivered to the receiver",
    );
    let _ = engine.stop().await;
}

/// Waits (bounded) for `sender`'s next decrypted fix of `nostr_group_id` on
/// the bus and returns its content.
async fn next_fix_from(
    bus: &mut tokio::sync::broadcast::Receiver<LiveSyncEvent>,
    nostr_group_id: [u8; 32],
    sender: &str,
) -> Option<String> {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
    while tokio::time::Instant::now() < deadline {
        match tokio::time::timeout(Duration::from_millis(500), bus.recv()).await {
            Ok(Ok(LiveSyncEvent::Location {
                nostr_group_id: gid,
                sender_pubkey,
                content,
                ..
            })) if gid == nostr_group_id.to_vec() && sender_pubkey == sender => {
                return Some(content)
            }
            Ok(Ok(_)) | Err(_) => {}
            Ok(Err(_)) => return None,
        }
    }
    None
}

/// The receiver of another client's rotation of a circle's routing id
/// listens under the new id by itself: the engine applies the admin's commit
/// off the prior id, the session subscribes the new id with no call from the
/// app, and what is sent under the new id alone is delivered. The prior id
/// keeps its REQ for a day — a fix sent under it is delivered — and past the
/// day the session closes it: a fix sent under it then is not, while one
/// sent under the new id right after it is.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_receiver_of_a_routing_rotation_listens_under_the_new_id_and_the_prior_for_a_day() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay starts");
    let url = relay.url().await.to_string();
    let dir = TempDir::new().unwrap();
    let admin_keys = Keys::generate();
    let admin = Arc::new(CircleManager::new_unencrypted(dir.path(), &admin_keys).unwrap());
    let fx = real_circle(&admin, &admin_keys, std::slice::from_ref(&url)).await;
    let from = admin_keys.public_key().to_hex();
    let seal = |lat: f64| {
        let (admin, group) = (Arc::clone(&admin), fx.mls_group_id.clone());
        async move {
            admin
                .seal_location_for_test(&group, &LocationMessage::new(lat, 1.0))
                .await
                .expect("the admin seals a fix")
                .0
        }
    };
    let within_the_day = seal(11.111_111).await;
    let past_the_day = seal(22.222_222).await;

    let engine = LiveSyncCore::new_local(
        Arc::clone(&fx.peer),
        fx.peer_keys.public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
    );
    let mut bus = engine.bus().subscribe();
    let opened = nostr::Timestamp::now().as_secs();
    engine
        .start(&[fx.spec(&url)], &[])
        .await
        .expect("the peer's engine starts and subscribes");
    assert!(
        subscription_established(&fx.peer, &[fx.hex()], opened).await,
        "premise: the relay answered the engine's REQ"
    );
    let seen = engine.follows_for_test();

    let rotated: [u8; 32] = rand::random();
    let (rotation, pending) =
        rotate_routing_id(&admin, &fx.mls_group_id, rotated, vec![url.clone()]).await;
    publish(&url, &rotation).await;
    let session = admin.session();
    session
        .confirm_published(pending)
        .await
        .expect("the admin applies it");
    // The session follows the rotation by itself.
    followed(&engine, seen).await;

    publish(&url, &seal(33.333_333).await).await;
    assert!(
        next_fix_from(&mut bus, rotated, &from)
            .await
            .is_some_and(|content| content.contains("33.333333")),
        "a fix sent under the new routing id alone was not delivered",
    );
    publish(&url, &within_the_day).await;
    assert!(
        next_fix_from(&mut bus, rotated, &from)
            .await
            .is_some_and(|content| content.contains("11.111111")),
        "a fix sent under the prior routing id within the day was not delivered",
    );

    fx.peer
        .date_prior_routing_for_test(&fx.mls_group_id, chrono::Utc::now().timestamp() - 86_401);
    assert_eq!(
        engine.follow_routing().await.expect("followed"),
        1,
        "past the day the prior routing id's REQ was not closed",
    );
    // One socket, one relay: had the prior id's REQ stood, its fix — sent
    // first — would have arrived first.
    publish(&url, &past_the_day).await;
    publish(&url, &seal(44.444_444).await).await;
    let next = next_fix_from(&mut bus, rotated, &from).await;
    assert!(
        next.as_deref()
            .is_some_and(|content| content.contains("44.444444")),
        "past the day a fix sent under the prior routing id was delivered, or one sent \
         under the new id was not: {}",
        next.is_some(),
    );
    let _ = engine.stop().await;
}

/// `admin` moves `fx`'s circle to `to` and applies the change, and the
/// circle's peer applies it too.
async fn move_circle_to(admin: &CircleManager, fx: &RealCircle, to: &str) {
    let update = admin
        .update_relays_for_test(&fx.mls_group_id, &[to.to_string()])
        .await
        .expect("the admin changes the circle's relays");
    fx.peer
        .ingest_for_test(&update)
        .await
        .expect("the peer applies it");
}

/// `admin` rotates `group`'s routing id to `to` on `relays`, straight on its
/// engine as another client's admin would, and returns the commit — sealed
/// under the id it rotates away from — with its pending ref.
async fn rotate_routing_id(
    admin: &CircleManager,
    group: &GroupId,
    to: [u8; 32],
    relays: Vec<String>,
) -> (Event, haven_core::nostr::mls::types::PendingStateRef) {
    use cgka_traits::app_components::{
        encode_nostr_routing_v1, NostrRoutingV1, NOSTR_ROUTING_COMPONENT_ID,
    };
    use haven_core::nostr::mls::types::{AppComponentData, PublishWork, SendIntent};

    let effects = admin
        .session()
        .send(SendIntent::UpdateAppComponents {
            group_id: group.clone(),
            updates: vec![AppComponentData {
                component_id: NOSTR_ROUTING_COMPONENT_ID,
                data: encode_nostr_routing_v1(
                    &NostrRoutingV1::new(to, relays).expect("a routing state"),
                )
                .expect("the component encodes"),
            }],
        })
        .await
        .expect("the admin rotates the routing id, as another client would");
    effects
        .publish
        .iter()
        .find_map(|work| match work {
            PublishWork::GroupEvolution { msg, pending, .. } => Some((
                haven_core::nostr::mls::SessionManager::transport_message_to_event(msg)
                    .expect("a commit event"),
                *pending,
            )),
            _ => None,
        })
        .expect("the rotation is staged")
}

/// A circle this device holds is listened for under its current routing id
/// even when the app listed it under none of its ids — a stale id whose
/// prior routing has been pruned: a fix sent under the current id is
/// delivered.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_held_circle_the_app_listed_under_a_stale_id_is_listened_for_under_its_own() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay starts");
    let url = relay.url().await.to_string();
    let dir = TempDir::new().unwrap();
    let admin_keys = Keys::generate();
    let admin = Arc::new(CircleManager::new_unencrypted(dir.path(), &admin_keys).unwrap());
    let fx = real_circle(&admin, &admin_keys, std::slice::from_ref(&url)).await;
    let fix = admin
        .seal_location_for_test(&fx.mls_group_id, &LocationMessage::new(44.444_444, 1.0))
        .await
        .expect("the admin seals a fix")
        .0;
    let engine = LiveSyncCore::new_local(
        Arc::clone(&fx.peer),
        fx.peer_keys.public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
    );
    let mut bus = engine.bus().subscribe();
    let stale: [u8; 32] = rand::random();
    engine
        .start(
            &[CircleSpec {
                group_id_hex: hex::encode(stale),
                relays: vec![url.clone()],
            }],
            &[],
        )
        .await
        .expect("the session starts under an id no circle routes");
    publish(&url, &fix).await;
    assert!(
        next_fix_from(
            &mut bus,
            fx.nostr_group_id,
            &admin_keys.public_key().to_hex()
        )
        .await
        .is_some_and(|content| content.contains("44.444444")),
        "a held circle the app listed under a stale id was listened for under none",
    );
    let _ = engine.stop().await;
}

/// A rotated circle the app starts the session with under its new id alone is
/// listened for under its prior id as well, from the start — a fix sent under
/// the prior id is delivered — and listed again when the app unlists it
/// inside its day; once the circle is left, the session lists none of its
/// ids.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_start_lists_a_rotated_circles_prior_id_and_a_leave_lists_none_of_its_ids() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay starts");
    let url = relay.url().await.to_string();
    let dir = TempDir::new().unwrap();
    let admin_keys = Keys::generate();
    let admin = Arc::new(CircleManager::new_unencrypted(dir.path(), &admin_keys).unwrap());
    let fx = real_circle(&admin, &admin_keys, std::slice::from_ref(&url)).await;
    let preseal = |lat: f64| {
        let (admin, group) = (Arc::clone(&admin), fx.mls_group_id.clone());
        async move {
            admin
                .seal_location_for_test(&group, &LocationMessage::new(lat, 1.0))
                .await
                .expect("the admin seals a fix under the prior id")
                .0
        }
    };
    let presealed = preseal(55.555_555).await;
    let again = preseal(66.666_666).await;
    let rotated: [u8; 32] = rand::random();
    let (rotation, pending) =
        rotate_routing_id(&admin, &fx.mls_group_id, rotated, vec![url.clone()]).await;
    admin
        .session()
        .confirm_published(pending)
        .await
        .expect("the admin applies it");
    fx.peer
        .ingest_for_test(&rotation)
        .await
        .expect("the peer applies it, and its row follows");
    // The start is a process's first, as each Android return to the
    // foreground is: nothing the rotation woke is left to list the prior id.
    let fx = fx.reopened();

    let engine = LiveSyncCore::new_local(
        Arc::clone(&fx.peer),
        fx.peer_keys.public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
    );
    let mut bus = engine.bus().subscribe();
    engine
        .start(
            &[CircleSpec {
                group_id_hex: hex::encode(rotated),
                relays: vec![url.clone()],
            }],
            &[],
        )
        .await
        .expect("the session starts under the new id");
    publish(&url, &presealed).await;
    assert!(
        next_fix_from(&mut bus, rotated, &admin_keys.public_key().to_hex())
            .await
            .is_some_and(|content| content.contains("55.555555")),
        "a fix sent under the prior id was not delivered right after a start",
    );
    // The app takes the prior id out of what it lists: the session's follow
    // lists it again while it stands.
    let seen = engine.follows_for_test();
    engine
        .unsubscribe_circle(&hex::encode(fx.nostr_group_id))
        .await
        .expect("the app unlists the prior id");
    followed(&engine, seen).await;
    publish(&url, &again).await;
    assert!(
        next_fix_from(&mut bus, rotated, &admin_keys.public_key().to_hex())
            .await
            .is_some_and(|content| content.contains("66.666666")),
        "a prior id the app unlisted inside its day was not listed again",
    );

    let seen = engine.follows_for_test();
    fx.peer
        .complete_leave(&fx.mls_group_id, chrono::Utc::now().timestamp())
        .await
        .expect("the peer leaves");
    followed(&engine, seen).await;
    assert_eq!(
        engine.pool_subscription_count().await,
        0,
        "an id of a circle left is still listened for",
    );
    let _ = engine.stop().await;
}

/// A circle whose move fails — its new REQ is taken by no relay — stays LISTED
/// on the relays it wants, so the health repair issues its REQ there once
/// the relay answers; the other circle of the same follow is moved all the
/// same, a second follow moves nothing, and the line that says so names no
/// circle and no relay. Run with the failure on each circle in turn, so one
/// run's follow meets the failing circle before the other whatever order it
/// visits them in.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_circle_whose_move_fails_stays_listed_and_the_health_repair_issues_it() {
    for fault_on_first in [true, false] {
        assert!(
            a_move_fails_on_one_of_two_circles(fault_on_first).await,
            "the circle moved in the same follow is not listened for where it now lives \
             (fault on the first: {fault_on_first})",
        );
    }
}

/// The scenario, asserting each step but the last; answers whether the
/// circle moved in the same follow is listened for where it now lives.
async fn a_move_fails_on_one_of_two_circles(fault_on_first: bool) -> bool {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let old = MockRelay::run().await.expect("mock relay starts");
    let old_url = old.url().await.to_string();
    let first_new = MockRelay::run().await.expect("second mock relay starts");
    let first_url = first_new.url().await.to_string();
    let second_new = MockRelay::run().await.expect("third mock relay starts");
    let second_url = second_new.url().await.to_string();
    let dir = TempDir::new().unwrap();
    let admin_keys = Keys::generate();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &admin_keys).unwrap());
    let first = real_circle(&circle, &admin_keys, std::slice::from_ref(&old_url)).await;
    let second = real_circle(&circle, &admin_keys, std::slice::from_ref(&old_url)).await;
    let engine = LiveSyncCore::new_local(
        Arc::clone(&circle),
        admin_keys.public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
    );
    let mut bus = engine.bus().subscribe();
    // Both rows move before the session starts, so the one follow the start
    // is woken for takes up both circles in a single call.
    for (fx, to) in [(&first, &first_url), (&second, &second_url)] {
        move_circle_to(&circle, fx, to).await;
    }
    let ((stuck, stuck_url), (moving, moving_url)) = if fault_on_first {
        ((&first, &first_url), (&second, &second_url))
    } else {
        ((&second, &second_url), (&first, &first_url))
    };
    engine.fail_next_subscribe_of_for_test(&stuck.hex());
    let lines = helpers::capture_haven_log(async {
        let seen = engine.follows_for_test();
        engine
            .start(&[first.spec(&old_url), second.spec(&old_url)], &[])
            .await
            .expect("engine starts and subscribes");
        followed(&engine, seen).await;
    })
    .await;
    let moving_relay = nostr::RelayUrl::parse(moving_url).expect("a relay url");
    assert!(
        engine
            .relays_in_pool_for_test()
            .await
            .contains(&moving_relay),
        "the other circle of the follow was not moved past the one whose move failed \
         (fault on the first: {fault_on_first})",
    );
    let core_lines = helpers::haven_core_lines(&lines);
    assert!(
        core_lines.iter().any(|line| line
            .message
            .contains("it stays listed for the health repair")),
        "a move that failed was not said",
    );
    helpers::assert_no_needles(
        &core_lines,
        &[
            &stuck.hex(),
            &moving.hex(),
            &old_url,
            &first_url,
            &second_url,
            "127.0.0.1",
        ],
    );
    assert_eq!(
        engine.follow_routing().await.expect("followed again"),
        0,
        "a circle whose move failed was not listed where it wants to be",
    );

    let _ = engine.maintain_subscription_health(Claim::Foreground).await;
    publish(stuck_url, &stuck.peer_location(10.0, 10.0).await).await;
    assert!(
        wait_for_location_from(
            &mut bus,
            stuck.nostr_group_id,
            &stuck.peer_keys.public_key().to_hex()
        )
        .await,
        "the health repair did not issue the REQ of a circle whose move had failed",
    );
    publish(moving_url, &moving.peer_location(20.0, 20.0).await).await;
    let listened = wait_for_location_from(
        &mut bus,
        moving.nostr_group_id,
        &moving.peer_keys.public_key().to_hex(),
    )
    .await;
    let _ = engine.stop().await;
    listened
}

/// A relay a circle left keeps a standing REQ for a day from the routing
/// change's own record, and no longer: past the day — or on a clock that
/// reads earlier than the record — the circle's REQ is on its new relays
/// alone and the pool lets the old relay go, while the old relay is still
/// an address the circle's traffic is fetched at by id.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_relay_a_circle_left_keeps_its_standing_req_for_a_day_and_no_longer() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let old = MockRelay::run().await.expect("mock relay starts");
    let old_url = old.url().await.to_string();
    let new = MockRelay::run().await.expect("second mock relay starts");
    let new_url = new.url().await.to_string();
    let dir = TempDir::new().unwrap();
    let admin_keys = Keys::generate();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &admin_keys).unwrap());
    let fx = real_circle(&circle, &admin_keys, std::slice::from_ref(&old_url)).await;
    let engine = LiveSyncCore::new_local(
        Arc::clone(&circle),
        admin_keys.public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
    );
    engine
        .start(&[fx.spec(&old_url)], &[])
        .await
        .expect("engine starts and subscribes");
    let seen = engine.follows_for_test();
    circle
        .update_relays_for_test(&fx.mls_group_id, std::slice::from_ref(&new_url))
        .await
        .expect("the admin changes the circle's relays");
    let (old_relay, new_relay) = (
        nostr::RelayUrl::parse(&old_url).expect("a relay url"),
        nostr::RelayUrl::parse(&new_url).expect("a relay url"),
    );
    // The session follows the change by itself.
    followed(&engine, seen).await;
    let pooled = engine.relays_in_pool_for_test().await;
    assert!(
        pooled.contains(&old_relay) && pooled.contains(&new_relay),
        "premise: within the day the circle listens at both",
    );
    let now = chrono::Utc::now().timestamp();
    for (what, written_at, moves) in [
        ("past the day", now - 86_401, 1),
        ("on a clock set back", now + 3_600, 0),
    ] {
        circle.date_prior_routing_for_test(&fx.mls_group_id, written_at);
        assert_eq!(
            engine.follow_routing().await.expect("followed"),
            moves,
            "{what}"
        );
        let pooled = engine.relays_in_pool_for_test().await;
        assert!(
            !pooled.contains(&old_relay) && pooled.contains(&new_relay),
            "{what}: the relay the circle left kept a standing REQ or a socket",
        );
        assert!(
            circle
                .routing_addresses(&fx.mls_group_id, std::slice::from_ref(&new_url))
                .await
                .contains(&old_url),
            "{what}: the relay the circle left is no longer an address its traffic is \
             fetched at",
        );
    }
    let _ = engine.stop().await;
}

/// A loopback proxy in front of `target` (`ws://host:port`): its address, and
/// how many of the connections made through it have since been closed by
/// either side, with a wake at each.
async fn closing_proxy(
    target: &str,
) -> (
    String,
    Arc<std::sync::atomic::AtomicUsize>,
    Arc<tokio::sync::Notify>,
) {
    let target = target
        .trim_start_matches("ws://")
        .trim_end_matches('/')
        .to_string();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("the proxy binds");
    let url = format!("ws://{}", listener.local_addr().expect("an address"));
    let closed = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let woken = Arc::new(tokio::sync::Notify::new());
    let (count, wake) = (Arc::clone(&closed), Arc::clone(&woken));
    tokio::spawn(async move {
        while let Ok((mut client, _)) = listener.accept().await {
            let (target, count, wake) = (target.clone(), Arc::clone(&count), Arc::clone(&wake));
            tokio::spawn(async move {
                if let Ok(mut relay) = tokio::net::TcpStream::connect(&target).await {
                    let _ = tokio::io::copy_bidirectional(&mut client, &mut relay).await;
                }
                count.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                wake.notify_waiters();
            });
        }
    });
    (url, closed, woken)
}

/// A relay a circle left is let go when its day ends, with nothing asking:
/// the session wakes its follow at the first second the prior routing no
/// longer stands, the circle's REQ there ends and the socket to it closes.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_relay_a_circle_left_is_let_go_when_its_day_ends_with_nothing_asking() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let old = MockRelay::run().await.expect("mock relay starts");
    let (old_url, closed, woken) = closing_proxy(&old.url().await.to_string()).await;
    let new = MockRelay::run().await.expect("second mock relay starts");
    let new_url = new.url().await.to_string();
    let dir = TempDir::new().unwrap();
    let admin_keys = Keys::generate();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &admin_keys).unwrap());
    let fx = real_circle(&circle, &admin_keys, std::slice::from_ref(&old_url)).await;
    let engine = LiveSyncCore::new_local(
        Arc::clone(&circle),
        admin_keys.public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
    );
    engine
        .start(&[fx.spec(&old_url)], &[])
        .await
        .expect("engine starts and subscribes");
    let seen = engine.follows_for_test();
    circle
        .update_relays_for_test(&fx.mls_group_id, std::slice::from_ref(&new_url))
        .await
        .expect("the admin changes the circle's relays");
    followed(&engine, seen).await;
    let old_relay = nostr::RelayUrl::parse(&old_url).expect("a relay url");
    assert!(
        engine.relays_in_pool_for_test().await.contains(&old_relay),
        "premise: within the day the circle listens at the relay it left",
    );

    // The day ends a few seconds from now. A follow woken now finds it still
    // standing, so only the timer it arms can end it.
    circle.date_prior_routing_for_test(&fx.mls_group_id, chrono::Utc::now().timestamp() - 86_395);
    let before = closed.load(std::sync::atomic::Ordering::SeqCst);
    let seen = engine.follows_for_test();
    circle.wake_routing_follow_for_test();
    followed(&engine, seen).await;
    assert!(
        engine.relays_in_pool_for_test().await.contains(&old_relay),
        "premise: the follow woken inside the day kept the relay the circle left",
    );
    let socket_closed = tokio::time::timeout(Duration::from_secs(30), async {
        loop {
            let wake = woken.notified();
            if closed.load(std::sync::atomic::Ordering::SeqCst) > before {
                return;
            }
            wake.await;
        }
    })
    .await;
    assert!(
        socket_closed.is_ok(),
        "the socket to a relay the circle left stayed open past its day",
    );
    assert!(
        !engine.relays_in_pool_for_test().await.contains(&old_relay),
        "the relay the circle left is still in the pool past its day",
    );
    let _ = engine.stop().await;
}

/// A burst opened with a measured budget keeps it when a pause had the
/// lifecycle lock first: the budget is set under the lock, so the lifecycle
/// the pause writes cannot clear it before the burst opens.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_bursts_measured_budget_survives_a_pause_that_had_the_lock_first() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay starts");
    let url = relay.url().await.to_string();
    let dir = TempDir::new().unwrap();
    let admin_keys = Keys::generate();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &admin_keys).unwrap());
    let fx = real_circle(&circle, &admin_keys, std::slice::from_ref(&url)).await;
    let engine = LiveSyncCore::new_local(
        Arc::clone(&circle),
        admin_keys.public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
    );
    engine
        .start(&[fx.spec(&url)], &[])
        .await
        .expect("engine starts and subscribes");
    engine
        .pause_subscriptions()
        .await
        .expect("the session pauses");
    let pause = engine.hold_lifecycle_for_test().await;
    let (opened, ()) = tokio::join!(engine.open_background_burst_within(60_000), async {
        // One yield: by the time this goes on, the open has been polled up to
        // the lock the pause holds, whichever of the two was polled first.
        tokio::task::yield_now().await;
        engine.processor().for_test().leave_foreground();
        drop(pause);
    });
    opened.expect("the burst opens");
    assert!(
        engine.processor().for_test().burst_is_bounded(),
        "a pause that had the lock first left the burst without its measured end",
    );
    let _ = engine.stop().await;
}

/// A burst open moves a circle the paused session did not hear move: here
/// the day of the relay it left ended while the session was paused, which
/// wakes nothing, and the open lists the circle on its new relay alone
/// before it issues anything — the relay it left gets no REQ and no socket.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_burst_open_moves_a_circle_whose_routing_changed_while_paused() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let old = MockRelay::run().await.expect("mock relay starts");
    let old_url = old.url().await.to_string();
    let new = MockRelay::run().await.expect("second mock relay starts");
    let new_url = new.url().await.to_string();
    let dir = TempDir::new().unwrap();
    let admin_keys = Keys::generate();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &admin_keys).unwrap());
    let fx = real_circle(&circle, &admin_keys, std::slice::from_ref(&old_url)).await;
    let engine = LiveSyncCore::new_local(
        Arc::clone(&circle),
        admin_keys.public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
    );
    engine
        .start(&[fx.spec(&old_url)], &[])
        .await
        .expect("engine starts and subscribes");
    let seen = engine.follows_for_test();
    circle
        .update_relays_for_test(&fx.mls_group_id, std::slice::from_ref(&new_url))
        .await
        .expect("the admin changes the circle's relays");
    followed(&engine, seen).await;
    let (old_relay, new_relay) = (
        nostr::RelayUrl::parse(&old_url).expect("a relay url"),
        nostr::RelayUrl::parse(&new_url).expect("a relay url"),
    );
    assert!(
        engine.relays_in_pool_for_test().await.contains(&old_relay),
        "premise: within the day the circle listens at the relay it left",
    );
    engine
        .pause_subscriptions()
        .await
        .expect("the session pauses");
    circle.date_prior_routing_for_test(&fx.mls_group_id, chrono::Utc::now().timestamp() - 86_401);

    engine
        .open_background_burst()
        .await
        .expect("the burst opens");
    let pooled = engine.relays_in_pool_for_test().await;
    assert!(
        !pooled.contains(&old_relay) && pooled.contains(&new_relay),
        "the burst open issued the circle's REQ where it no longer lives",
    );
    let _ = engine.stop().await;
}

/// A stop whose lifecycle lock a holder will not give up — a start or a pause
/// wedged on a relay call — is bounded: past its budget it tears the session
/// down beside the holder, so a logout's stop returns and every REQ and socket
/// of the session is closed all the same.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stop_whose_lock_is_held_tears_down_within_its_bound() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay starts");
    let url = relay.url().await.to_string();
    let dir = TempDir::new().unwrap();
    let admin_keys = Keys::generate();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &admin_keys).unwrap());
    let fx = real_circle(&circle, &admin_keys, std::slice::from_ref(&url)).await;
    let engine = LiveSyncCore::new_local(
        Arc::clone(&circle),
        admin_keys.public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
    );
    engine
        .start(&[fx.spec(&url)], &[])
        .await
        .expect("engine starts and subscribes");
    assert!(
        engine.pool_subscription_count().await > 0
            && engine.lifecycle() == Some(haven_core::relay::live_sync::Lifecycle::Launched),
        "premise: the session holds REQs, only started"
    );
    let wedged = engine.hold_lifecycle_for_test().await;
    let stopped = std::sync::atomic::AtomicBool::new(false);
    let lines = helpers::capture_haven_log(async {
        let bounded = tokio::time::timeout(
            Duration::from_secs(30),
            engine.stop_within_for_test(Duration::from_millis(200)),
        )
        .await;
        stopped.store(bounded.is_ok(), std::sync::atomic::Ordering::SeqCst);
    })
    .await;
    assert!(
        stopped.into_inner(),
        "a stop waited on a lifecycle lock its holder would not give up",
    );
    let core_lines = helpers::haven_core_lines(&lines);
    assert!(
        core_lines
            .iter()
            .any(|line| line.message.contains("tearing down beside its holder")),
        "a stop that tore down beside its holder did not say so",
    );
    helpers::assert_no_needles(
        &core_lines,
        &[
            &fx.hex(),
            &url,
            "127.0.0.1",
            &admin_keys.public_key().to_hex(),
        ],
    );
    assert!(
        engine.pool_subscription_count().await == 0 && engine.lifecycle().is_none(),
        "a stop that could not have the lock left the session's REQs open, or the session \
         read as running",
    );
    drop(wedged);
}

/// A stop bounded beside a wedged holder ends the foreground for every other
/// caller in the process at once, not when the session's processor is
/// dropped: from its return the session reads as away from the foreground,
/// and a bridge entry may make no commit.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stop_beside_a_wedged_holder_leaves_no_foreground_standing() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay starts");
    let url = relay.url().await.to_string();
    let dir = TempDir::new().unwrap();
    let admin_keys = Keys::generate();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &admin_keys).unwrap());
    let fx = real_circle(&circle, &admin_keys, std::slice::from_ref(&url)).await;
    let engine = LiveSyncCore::new_local(
        Arc::clone(&circle),
        admin_keys.public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
    );
    engine
        .start(&[fx.spec(&url)], &[])
        .await
        .expect("engine starts and subscribes");
    let _ = engine.maintain_subscription_health(Claim::Foreground).await;
    assert_eq!(
        circle.session().foreground_reads_for_test(),
        (false, true),
        "premise: a claimed foreground stands behind the session",
    );
    let wedged = engine.hold_lifecycle_for_test().await;
    let stopped = tokio::time::timeout(
        Duration::from_secs(30),
        engine.stop_within_for_test(Duration::from_millis(200)),
    )
    .await;
    assert!(stopped.is_ok(), "premise: the stop is bounded");
    assert_eq!(
        circle.session().foreground_reads_for_test(),
        (true, false),
        "a stop beside a wedged holder left the foreground standing for other callers",
    );
    drop(wedged);
}

/// Two circles sharing one relay set are served by a SINGLE multiplexed `#h`
/// REQ on ONE socket: the relay is asked once, with one filter naming both
/// circles, both deliver, and an `#h` the engine did not subscribe to is in no
/// filter the relay was sent, so the relay never serves it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_multiplexes_two_circles_and_drops_unsubscribed_h() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    // `MockRelay` is this relay with no policy; the policy only records.
    let asked = RecordedReqs::default();
    let relay = LocalRelay::new(RelayBuilder::default().query_policy(asked.clone()));
    relay.run().await.expect("relay starts");
    let url = relay.url().await.to_string();

    let dir = TempDir::new().unwrap();
    let admin_keys = Keys::generate();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &admin_keys).unwrap());
    let fx_a = real_circle(&circle, &admin_keys, std::slice::from_ref(&url)).await;
    let fx_b = real_circle(&circle, &admin_keys, std::slice::from_ref(&url)).await;
    let hex_unsubscribed = hex::encode([0xCCu8; 32]);

    let engine = LiveSyncCore::new_local(
        Arc::clone(&circle),
        admin_keys.public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
    );
    let mut bus = engine.bus().subscribe();
    let opened = nostr::Timestamp::now().as_secs();
    engine
        .start(&[fx_a.spec(&url), fx_b.spec(&url)], &[])
        .await
        .expect("start");
    assert!(
        subscription_established(&circle, &[fx_a.hex(), fx_b.hex()], opened).await,
        "premise: the relay answered the multiplexed REQ for both circles before \
         anything is published, so both deliveries below are live"
    );

    publish(&url, &fx_a.peer_location(1.0, 2.0).await).await;
    publish(&url, &fx_b.peer_location(3.0, 4.0).await).await;
    // A 445 for a circle the engine never subscribed to; must be filtered out.
    publish(
        &url,
        &nostr::EventBuilder::new(nostr::Kind::Custom(445), "opaque-ciphertext")
            .tags([nostr::Tag::parse(["h", &hex_unsubscribed]).unwrap()])
            .sign_with_keys(&Keys::generate())
            .unwrap(),
    )
    .await;

    assert!(
        wait_for_location(&mut bus, &fx_a, Duration::from_secs(15)).await,
        "circle A delivers on the multiplexed socket"
    );
    assert!(
        wait_for_location(&mut bus, &fx_b, Duration::from_secs(15)).await,
        "circle B delivers on the SAME multiplexed socket"
    );
    // What the relay was asked, by filter. The publishers above only write,
    // so these are the engine's. A filter that names no kind, or names 445,
    // can be answered with a group event — whether or not it names a circle.
    let asked = asked.0.lock().expect("the record of requests").clone();
    let can_match_445 = |filter: &nostr::Filter| {
        filter
            .kinds
            .as_ref()
            .is_none_or(|kinds| kinds.contains(&nostr::Kind::Custom(445)))
    };
    assert_eq!(
        asked
            .iter()
            .filter(|(_, filter)| can_match_445(filter))
            .count(),
        1,
        "group events are asked for by ONE filter: none beside it, with or without an #h"
    );
    let h = nostr::SingleLetterTag::lowercase(nostr::Alphabet::H);
    let group_reqs: Vec<_> = asked
        .into_iter()
        .filter(|(_, filter)| filter.generic_tags.contains_key(&h))
        .collect();
    assert_eq!(
        group_reqs.len(),
        1,
        "two circles on one relay set are ONE filter in ONE REQ, so on one socket"
    );
    // Compared before the assertion so that a failure prints no circle id.
    let (_socket, filter) = &group_reqs[0];
    let names_both_and_no_other =
        filter.generic_tags.get(&h) == Some(&[fx_a.hex(), fx_b.hex()].into());
    assert!(
        names_both_and_no_other,
        "the one REQ names both circles and no other: the unsubscribed #h is \
         excluded at the relay, by the filter"
    );

    // Teardown only: every assertion has already run. The outcome is not
    // asserted here because the drain contract itself is pinned by
    // `join_tasks_*` and the `stop_*` unit tests in
    // `src/relay/live_sync/session.rs`, and by the same-store restart
    // assertions in `live_sync_cursor_replay_e2e`.
    let _ = engine.stop().await;
}

/// `resume_after_background` re-anchors the subscriptions: it re-issues the
/// circle's REQ (the cursor moves past the start's, which only a relay's answer
/// to a later REQ can do), emits `BackgroundResumed`, AND a `kind:445` published
/// after that answer is delivered live.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_resume_after_background_re_anchors_and_still_delivers() {
    use haven_core::relay::live_sync::SyncStatusReason;

    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();

    let dir = TempDir::new().unwrap();
    let admin_keys = Keys::generate();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &admin_keys).unwrap());
    let fx = real_circle(&circle, &admin_keys, std::slice::from_ref(&url)).await;

    let engine = LiveSyncCore::new_local(
        Arc::clone(&circle),
        admin_keys.public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
    );
    let opened = nostr::Timestamp::now().as_secs();
    engine.start(&[fx.spec(&url)], &[]).await.expect("start");
    assert!(
        subscription_established(&circle, &[fx.hex()], opened).await,
        "premise: the start's own subscription is live before it is resumed, so \
         the resume re-anchors a session rather than racing its start"
    );

    // The start's REQ has spent its one cursor advance. From this second on,
    // only an answer to a REQ issued by the resume can move the cursor here.
    let resumed = second_after_cursor(&circle, &fx.hex())
        .await
        .expect("premise: the clock passes the second the start's REQ was issued in");
    assert!(
        !anchored_since(&circle, &[fx.hex()], resumed),
        "premise: no REQ issued this late has been answered before the resume"
    );

    // Subscribe BEFORE resume so we observe the BackgroundResumed status.
    let mut rx = engine.bus().subscribe();
    engine
        .resume_after_background(Claim::Foreground)
        .await
        .expect("resume re-anchors the subscriptions");
    assert!(
        subscription_established(&circle, &[fx.hex()], resumed).await,
        "the resume must re-issue the circle's REQ and a relay must answer it"
    );

    // Drain a short window for the resume status (proves the resume path ran).
    let mut saw_resumed = false;
    while let Ok(Ok(ev)) = tokio::time::timeout(Duration::from_millis(800), rx.recv()).await {
        if matches!(
            ev,
            LiveSyncEvent::Status {
                reason: SyncStatusReason::BackgroundResumed
            }
        ) {
            saw_resumed = true;
            break;
        }
    }
    assert!(
        saw_resumed,
        "resume must emit BackgroundResumed (proves the resume path executed)"
    );

    // Post-resume delivery: an event published after resume still arrives.
    publish(&url, &fx.peer_location(9.0, 9.0).await).await;
    assert!(
        wait_for_location(&mut rx, &fx, Duration::from_secs(15)).await,
        "an event published after resume must still be received and processed"
    );

    // Teardown only: every assertion has already run. The outcome is not
    // asserted here because the drain contract itself is pinned by
    // `join_tasks_*` and the `stop_*` unit tests in
    // `src/relay/live_sync/session.rs`, and by the same-store restart
    // assertions in `live_sync_cursor_replay_e2e`.
    let _ = engine.stop().await;
}

/// What the three tests above wait for is not met by a start alone: with a
/// relay that never answers, the cursor is the start's seed, below the instant
/// the REQ was issued.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_start_no_relay_has_answered_is_not_an_established_subscription() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    // A refused loopback port: nothing there will ever send an `EOSE`.
    let dead_url = "ws://127.0.0.1:1".to_string();
    let hex = hex::encode([0x33u8; 32]);

    let dir = TempDir::new().unwrap();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &Keys::generate()).unwrap());
    let engine = LiveSyncCore::new_local(
        Arc::clone(&circle),
        Keys::generate().public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
    );
    let opened = nostr::Timestamp::now().as_secs();
    engine
        .start(
            &[CircleSpec {
                group_id_hex: hex.clone(),
                relays: vec![dead_url],
            }],
            &[],
        )
        .await
        .expect("start tolerates a down relay (subscribe queues on it)");

    let seeded = circle
        .read_sync_cursor(&group_cursor_stream(&hex))
        .expect("the cursor reads");
    assert!(seeded.is_some(), "the start lays the circle's cursor seed");
    assert!(
        !anchored_since(&circle, &[hex], opened),
        "a seeded cursor no relay has answered must not read as an established subscription"
    );

    let _ = engine.stop().await;
}

/// M8-4: over a live relay, a health tick reports `Healthy` (relays present,
/// none dropped) — the "relays present" case the unit test's empty pool can't
/// reach.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn subscription_health_reports_healthy_over_a_connected_relay() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();

    let dir = TempDir::new().unwrap();
    let circle =
        Arc::new(CircleManager::new_unencrypted(dir.path(), &nostr::Keys::generate()).unwrap());
    // A session lists the ids of circles its manager holds.
    circle.keep_circle_row_for_test([0x11; 32]);
    let engine = LiveSyncCore::new_local(
        circle,
        Keys::generate().public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
    );
    engine
        .start(
            &[CircleSpec {
                group_id_hex: hex::encode([0x11u8; 32]),
                relays: vec![url.clone()],
            }],
            &[],
        )
        .await
        .expect("start");

    // Poll until the single relay reaches Connected.
    let mut connected = false;
    for _ in 0..50 {
        let s = engine.relay_health().await;
        if s.total == 1 && s.disconnected == 0 {
            connected = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(connected, "the live relay must reach Connected");

    let outcome = engine
        .maintain_subscription_health(Claim::Foreground)
        .await
        .unwrap();
    assert_eq!(outcome.action, HealthAction::Healthy);
    assert_eq!(outcome.relays_total, 1);
    assert_eq!(outcome.relays_disconnected, 0);

    // Teardown only: every assertion has already run. The outcome is not
    // asserted here because the drain contract itself is pinned by
    // `join_tasks_*` and the `stop_*` unit tests in
    // `src/relay/live_sync/session.rs`, and by the same-store restart
    // assertions in `live_sync_cursor_replay_e2e`.
    let _ = engine.stop().await;
}

/// A relay that is down does not re-anchor the session (P2, owner-decided):
/// with one live relay and one refused loopback port in a circle's list, a
/// claimed health tick finds the session healthy — the pool keeps the dropped
/// relay's REQs and retries that relay alone on its own schedule — and the
/// dropped relay, left out of the circle's coverage, owes the circle its
/// history from the `since` it was asked (Security Rule 12).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_relay_that_is_down_does_not_reanchor_the_session_and_owes_its_floor() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let live_url = relay.url().await.to_string();
    // A refused loopback port (nothing listening) — the pool marks it dropped.
    let dead_url = "ws://127.0.0.1:1".to_string();
    let hex = hex::encode([0x22u8; 32]);

    let dir = TempDir::new().unwrap();
    let circle =
        Arc::new(CircleManager::new_unencrypted(dir.path(), &nostr::Keys::generate()).unwrap());
    // A session lists the ids of circles its manager holds.
    circle.keep_circle_row_for_test([0x22; 32]);
    let engine = LiveSyncCore::new_local(
        Arc::clone(&circle),
        Keys::generate().public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
    );
    engine
        .start(
            &[CircleSpec {
                group_id_hex: hex.clone(),
                relays: vec![live_url.clone(), dead_url.clone()],
            }],
            &[],
        )
        .await
        .expect("start tolerates a down relay (subscribe queues on it)");

    // Poll until the refused relay is observed as dropped. Connection-refused on
    // a loopback port is fast, and the pool's retry backoff keeps it in the
    // dropped state between attempts, so this settles quickly.
    let mut saw_drop = false;
    for _ in 0..80 {
        let s = engine.relay_health().await;
        if s.total >= 2 && s.disconnected >= 1 {
            saw_drop = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(saw_drop, "the refused relay must be observed as dropped");
    // The live relay alone vouches for the circle: its cursor advances and
    // the circle is caught up, the down relay holding neither.
    // The kept row's MLS id is its routing id (`keep_circle_row_for_test`).
    let routed = GroupId::from_slice(&[0x22; 32]);
    let mut advanced = false;
    for _ in 0..80 {
        if circle
            .read_sync_cursor(&group_cursor_stream(&hex))
            .expect("the cursor reads")
            .is_some()
            && circle.session().caught_up_for_test(&routed)
        {
            advanced = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(
        advanced,
        "a relay the pool only queued the REQ for held the circle's advance or caught-up mark"
    );
    let mut bus = engine.bus().subscribe();

    let outcome = engine
        .maintain_subscription_health(Claim::Foreground)
        .await
        .unwrap();
    assert_eq!(
        outcome.action,
        HealthAction::Healthy,
        "a relay that is down re-anchored the whole session"
    );
    assert!(outcome.relays_disconnected >= 1);
    let mut reanchored = false;
    while let Ok(event) = bus.try_recv() {
        reanchored |= matches!(
            event,
            LiveSyncEvent::Status {
                reason: SyncStatusReason::BackgroundResumed
            }
        );
    }
    assert!(!reanchored, "the tick announced a re-anchor");
    let dead = nostr::RelayUrl::parse(&dead_url).expect("a relay url");
    assert!(
        circle.relay_floor_for_test(&hex, dead.as_str()).is_some(),
        "the relay left out of the circle's coverage owes it no floor"
    );

    let _ = engine.stop().await;
}

/// A background wake that finds no session starts one directly into a burst
/// (decision 190): the session reads as in a burst — the lifecycle that
/// makes no commit — not as only started, and its inbox REQ keeps the
/// start's lookback: with no
/// inbox cursor the cold-start week, so an invitation sent before this device
/// ever heard an inbox EOSE is not skipped, and with one the re-anchor's four
/// days.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_session_started_into_a_burst_reads_as_one_and_keeps_the_starts_inbox_lookback() {
    use haven_core::relay::cursor::STREAM_INBOX_1059;
    use haven_core::relay::live_sync::Lifecycle;

    let _ = haven_core::relay::allow_ws_loopback_for_test();
    for has_cursor in [false, true] {
        let asked = RecordedReqs::default();
        let relay = LocalRelay::new(RelayBuilder::default().query_policy(asked.clone()));
        relay.run().await.expect("relay starts");
        let url = relay.url().await.to_string();
        let dir = TempDir::new().unwrap();
        let admin_keys = Keys::generate();
        let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &admin_keys).unwrap());
        let fx = real_circle(&circle, &admin_keys, std::slice::from_ref(&url)).await;
        let now = i64::try_from(nostr::Timestamp::now().as_secs()).unwrap();
        if has_cursor {
            circle
                .advance_sync_cursor(STREAM_INBOX_1059, now * 1000)
                .expect("the inbox cursor is written");
        }
        let engine = LiveSyncCore::new_local(
            Arc::clone(&circle),
            admin_keys.public_key(),
            Arc::new(haven_core::relay::RelayManager::new()),
        );
        engine
            .start_into_burst(&[fx.spec(&url)], std::slice::from_ref(&url), None)
            .await
            .expect("the session starts into a burst");
        assert_eq!(
            engine.lifecycle(),
            Some(Lifecycle::Burst),
            "a session started into a burst is not in one (cursor: {has_cursor})",
        );
        let mut inbox_since = None;
        for _ in 0..150 {
            inbox_since = asked
                .0
                .lock()
                .expect("the record of requests")
                .iter()
                .find(|(_, filter)| {
                    filter
                        .kinds
                        .as_ref()
                        .is_some_and(|kinds| kinds.contains(&nostr::Kind::GiftWrap))
                })
                .and_then(|(_, filter)| filter.since)
                .and_then(|since| i64::try_from(since.as_secs()).ok());
            if inbox_since.is_some() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        let since = inbox_since.expect("the burst asked the relay for the inbox");
        if has_cursor {
            assert!(
                since >= now - 345_600 - 60 && since > now - 604_800,
                "with an inbox cursor the start replayed more than the re-anchor's four days",
            );
        } else {
            assert!(
                since <= now - 604_800,
                "with no inbox cursor the start skipped the cold-start week",
            );
        }
        let _ = engine.stop().await;
    }
}

/// Waits for the session's next follow to end after `seen`, failing rather
/// than hanging when none does: a follow that never comes is the defect.
async fn followed(engine: &LiveSyncCore, seen: u64) {
    tokio::time::timeout(Duration::from_secs(30), engine.follows_ended_for_test(seen))
        .await
        .expect("no follow of the session ended");
}

/// What X1's tests share: an admin's circle on `old_url` with a live session
/// started over it and claimed for the foreground, and the bus it reports on.
async fn a_claimed_session_on(
    circle: &Arc<CircleManager>,
    admin_keys: &Keys,
    old_url: &str,
) -> (
    RealCircle,
    LiveSyncCore,
    tokio::sync::broadcast::Receiver<LiveSyncEvent>,
) {
    let fx = real_circle(circle, admin_keys, &[old_url.to_owned()]).await;
    let engine = LiveSyncCore::new_local(
        Arc::clone(circle),
        admin_keys.public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
    );
    let bus = engine.bus().subscribe();
    engine
        .start(&[fx.spec(old_url)], &[])
        .await
        .expect("engine starts and subscribes");
    engine.claim_foreground(Claim::Foreground).await;
    (fx, engine, bus)
}

/// An own change of a circle's relays that the LIVE session's drive confirms,
/// in a claimed foreground and with no health tick, moves the session's REQ
/// by itself: a location the peer sends to the new relay alone is delivered.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_own_relay_change_the_live_drive_confirms_is_followed_with_no_health_tick() {
    use haven_core::relay::fanout::scripted::ScriptedFanout;
    use haven_core::relay::fanout::{Claimed, Publishing};

    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let old = MockRelay::run().await.expect("mock relay starts");
    let old_url = old.url().await.to_string();
    let new = MockRelay::run().await.expect("second mock relay starts");
    let new_url = new.url().await.to_string();
    let dir = TempDir::new().unwrap();
    let admin_keys = Keys::generate();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &admin_keys).unwrap());
    let (fx, engine, mut bus) = a_claimed_session_on(&circle, &admin_keys, &old_url).await;

    // Recorded by a bridge call with no room to send: the session's own drive
    // is what sends it and confirms it.
    let unsent = ScriptedFanout::default();
    let outbox = helpers::drive::Recorder::acking(true);
    let clock = helpers::drive::ManualClock::at(0);
    let mode = Claimed::new(&circle, true);
    let _ = Publishing {
        fanout: &unsent,
        publisher: &outbox,
        clock: clock.as_ref(),
        deadline_ms: Some(0),
        mode: &mode,
    }
    .update_relays(&circle, &fx.mls_group_id, std::slice::from_ref(&new_url))
    .await
    .expect("the change is recorded");
    drop(mode);
    assert!(
        unsent.calls().is_empty(),
        "premise: the bridge sent nothing"
    );
    let seen = engine.follows_for_test();
    engine.processor().for_test().request_drive();
    followed(&engine, seen).await;
    assert!(
        circle
            .get_circle(&fx.mls_group_id)
            .await
            .expect("read")
            .is_some_and(|c| c.circle.relays == [new_url.clone()]),
        "premise: the live drive confirmed the change and the row moved"
    );

    publish(&new_url, &fx.peer_location(52.37, 4.89).await).await;
    assert!(
        wait_for_location_from(
            &mut bus,
            fx.nostr_group_id,
            &fx.peer_keys.public_key().to_hex()
        )
        .await,
        "a location sent to the circle's new relay alone was not delivered: the session \
         did not follow a change its own drive confirmed",
    );
    let _ = engine.stop().await;
}

/// An own change of a circle's relays a bridge `*_driven` entry confirms, in
/// a claimed foreground and with no health tick, moves the session's REQ by
/// itself: a location the peer sends to the new relay alone is delivered.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_own_relay_change_a_bridge_entry_confirms_is_followed_with_no_health_tick() {
    use haven_core::relay::fanout::scripted::{Answer, ScriptedFanout};
    use haven_core::relay::fanout::{Claimed, EvolutionStatus, Publishing};

    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let old = MockRelay::run().await.expect("mock relay starts");
    let old_url = old.url().await.to_string();
    let new = MockRelay::run().await.expect("second mock relay starts");
    let new_url = new.url().await.to_string();
    let dir = TempDir::new().unwrap();
    let admin_keys = Keys::generate();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &admin_keys).unwrap());
    let (fx, engine, mut bus) = a_claimed_session_on(&circle, &admin_keys, &old_url).await;

    let transport = ScriptedFanout::default();
    transport.answer(&old_url, [Answer::Accepted]);
    let outbox = helpers::drive::Recorder::acking(true);
    let clock = helpers::drive::ManualClock::at(0);
    let mode = Claimed::new(&circle, true);
    let seen = engine.follows_for_test();
    let outcome = Publishing {
        fanout: &transport,
        publisher: &outbox,
        clock: clock.as_ref(),
        deadline_ms: None,
        mode: &mode,
    }
    .update_relays(&circle, &fx.mls_group_id, std::slice::from_ref(&new_url))
    .await
    .expect("the change is driven");
    drop(mode);
    assert_eq!(
        outcome.status,
        EvolutionStatus::Confirmed,
        "premise: confirmed"
    );
    followed(&engine, seen).await;

    publish(&new_url, &fx.peer_location(52.37, 4.89).await).await;
    assert!(
        wait_for_location_from(
            &mut bus,
            fx.nostr_group_id,
            &fx.peer_keys.public_key().to_hex()
        )
        .await,
        "a location sent to the circle's new relay alone was not delivered: the session \
         did not follow a change a bridge entry confirmed",
    );
    let _ = engine.stop().await;
}

/// A burst opened with its measured budget on a session that has stopped
/// answers "no session", the typed refusal the bridge hands Dart, and opens
/// nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_burst_open_on_a_stopped_session_answers_no_session() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay starts");
    let url = relay.url().await.to_string();
    let dir = TempDir::new().unwrap();
    let admin_keys = Keys::generate();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &admin_keys).unwrap());
    let fx = real_circle(&circle, &admin_keys, std::slice::from_ref(&url)).await;
    let engine = LiveSyncCore::new_local(
        Arc::clone(&circle),
        admin_keys.public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
    );
    engine
        .start(&[fx.spec(&url)], &[])
        .await
        .expect("engine starts");
    let _ = engine.stop().await;
    assert!(
        matches!(
            engine.open_background_burst_within(30_000).await,
            Err(haven_core::relay::live_sync::LiveSyncError::NoSession)
        ) && engine.pool_subscription_count().await == 0,
        "a stopped session's burst open did not answer no session, or opened something",
    );
}
