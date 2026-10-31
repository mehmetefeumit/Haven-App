//! Input the engine refused for a local resource bound is never recorded as
//! seen (Security Rule 12; Marmot `transports/nostr.md`, `resource_refused`).
//!
//! MDK v0.10.4 retains an undecryptable `kind:445` for its own re-peel
//! (`TransportDeferred`), up to `MAX_PEEL_DEFERRED_ROWS_PER_GROUP` rows per
//! group (`cgka-engine/src/message_processor/mod.rs:89`). Past that it answers
//! `ResourceRefused` and keeps nothing (`IngestEffects.left_object_unpersisted`),
//! so the relay is the object's only way back: the spec requires that its range
//! is not treated as synchronised and that it gets another delivery
//! opportunity. These tests fill a group's deferral store with undecryptable
//! envelopes, the way a hostile relay can, and pin what each receive plane does
//! with the genuine message the engine then refuses.
//!
//! The genuine message is a location Bob sealed one epoch ahead of Alice: she
//! cannot open it until she has his commit, so the engine would defer it — and,
//! with the store full, refuses it instead.

mod helpers;

use std::sync::Arc;
use std::time::Duration;

use base64::Engine as _;
use haven_core::circle::{CircleConfig, CircleManager, LastKnownLocation, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::GroupEvent;
use haven_core::nostr::mls::types::{
    GroupId, IngestOutcome, PublishWork, ScreenedIngest, SendIntent,
};
use haven_core::nostr::mls::{SessionManager, MAX_REFUSED_IDS_PER_GROUP};
use haven_core::relay::catchup::{
    run_catchup_all_circles, run_refused_refetch, REFETCH_IDS_PER_REQ, REFETCH_REQS_PER_SWEEP,
};
use haven_core::relay::live_sync::{
    group_cursor_stream, CircleSpec, Claim, EngineProcessor, EventBus, GroupProcessOutcome,
    LiveSyncCore, LiveSyncEvent, SyncStatusReason,
};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use haven_core::relay::{allow_ws_loopback_for_test, RelayManager};
use nostr::{Event, EventBuilder, EventId, Keys, Kind, Tag, TagKind, Timestamp};
use nostr_relay_builder::prelude::{
    BoxedFuture, MemoryDatabase, MemoryDatabaseOptions, PolicyResult, QueryPolicy,
};
use nostr_relay_builder::{LocalRelay, MockRelay, RelayBuilder};
use rand::RngCore;
use tempfile::TempDir;

struct TwoMemberCircle {
    alice: Arc<CircleManager>,
    alice_keys: Keys,
    bob: Arc<CircleManager>,
    bob_keys: Keys,
    mls_group_id: GroupId,
    nostr_group_id: [u8; 32],
    dirs: Vec<TempDir>,
}

impl TwoMemberCircle {
    fn group_hex(&self) -> String {
        hex::encode(self.nostr_group_id)
    }

    fn alice_cursor(&self) -> Option<i64> {
        self.alice
            .read_sync_cursor(&group_cursor_stream(&self.group_hex()))
            .expect("cursor read")
    }

    fn bob_location_reached_alice(&self) -> bool {
        let bob_hex = self.bob_keys.public_key().to_hex();
        self.alice
            .snapshot_last_known_for_circle(&self.nostr_group_id, chrono::Utc::now().timestamp())
            .expect("snapshot")
            .iter()
            .any(|loc: &LastKnownLocation| loc.sender_pubkey == bob_hex)
    }

    /// Fills Alice's deferral store for this circle with undecryptable
    /// envelopes until the engine refuses one, so the next object that needs
    /// deferring is refused too.
    async fn fill_alice_deferral_store(&self) {
        let session = self.alice.session();
        let mut deferred = 0usize;
        loop {
            let ScreenedIngest::Ingested(ingest) = session
                .process_event(&undecryptable_445(&self.group_hex(), now_secs()))
                .await
                .expect("an undecryptable envelope is not an ingest failure")
            else {
                panic!("a well-formed envelope passes the pre-auth screen");
            };
            match ingest.outcome {
                IngestOutcome::TransportDeferred { .. } => deferred += 1,
                IngestOutcome::ResourceRefused { .. } => break,
                _ => panic!("an undecryptable envelope is deferred or refused"),
            }
            assert!(
                deferred <= 4 * 2048,
                "the deferral store never filled: the engine's per-group cap is gone"
            );
        }
        assert!(
            deferred > 0,
            "the store took some envelopes before refusing"
        );
    }

    /// A location Bob seals one epoch ahead of Alice, and the commit that
    /// takes him there — which Alice does not have yet.
    async fn bob_location_one_epoch_ahead(&self) -> (Event, Event) {
        let effects = self
            .bob
            .session()
            .send(SendIntent::SelfUpdate {
                group_id: self.mls_group_id.clone(),
            })
            .await
            .expect("bob self-updates");
        let (msg, pending) = effects
            .publish
            .iter()
            .find_map(|work| match work {
                PublishWork::GroupEvolution { msg, pending, .. } => Some((msg.clone(), *pending)),
                _ => None,
            })
            .expect("a self-update stages one group evolution");
        self.bob
            .session()
            .confirm_published(pending)
            .await
            .expect("bob's relays acked his commit");
        let commit = SessionManager::transport_message_to_event(&msg).expect("commit event");
        let (location, _, _) = self
            .bob
            .seal_location_for_test(&self.mls_group_id, &LocationMessage::new(52.37, 4.89))
            .await
            .expect("bob encrypts at his new epoch");
        (location, commit)
    }

    /// Hands Alice Bob's commit and serves every deadline the engine announces
    /// until it is applied, so the refused location becomes one she can open.
    ///
    /// With the deferral store full, an advance first works through the stored
    /// rows a context change re-arms, in budgeted slices (MDK
    /// `message_processor/mod.rs:1512-1515` holds convergence while a peel
    /// generation is active), so the apply can take many advances.
    async fn alice_applies(&self, commit: &Event) {
        let session = self.alice.session();
        let before = session.epoch(&self.mls_group_id).await.unwrap();
        session
            .process_event(commit)
            .await
            .expect("alice ingests bob's commit");
        let started = std::time::Instant::now();
        while session.epoch(&self.mls_group_id).await.unwrap() == before {
            assert!(
                started.elapsed() < std::time::Duration::from_mins(2),
                "bob's commit was never applied"
            );
            if let Some(after) = session.receive_retick_after(&self.mls_group_id).await {
                tokio::time::sleep(after).await;
            }
            session
                .advance_for_receive(&self.mls_group_id)
                .await
                .expect("advance");
        }
        assert_eq!(
            session.epoch(&self.mls_group_id).await.unwrap(),
            before + 1,
            "precondition: alice is now at the epoch bob sealed the location in"
        );
    }
}

async fn build_two_member_circle(group_relays: Vec<String>) -> TwoMemberCircle {
    let bob_dir = TempDir::new().unwrap();
    let bob_keys = Keys::generate();
    let bob = Arc::new(CircleManager::new_unencrypted(bob_dir.path(), &bob_keys).unwrap());
    let kp_event = build_kp_maintenance_events(
        bob.session(),
        &bob_keys,
        &["wss://kp.example.com".to_string()],
        None,
        None,
    )
    .await
    .expect("bob key package")
    .event;
    let member = MemberKeyPackage {
        key_package_event: kp_event,
        inbox_relays: vec!["wss://member-inbox.example.com".to_string()],
        nip65_relays: vec![],
        nip65_write_relays: vec![],
    };

    let alice_dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let alice = Arc::new(CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap());
    let config = CircleConfig::new("Refusal Circle").with_relays(group_relays.clone());
    let result = alice
        .create_circle(&alice_keys, vec![member], &config)
        .await
        .expect("create circle");
    // As the app's driven create leaves it: the founding Welcomes sent from
    // their records and acknowledged, so no later drive sends them.
    let _ = alice.land_staged_for_test().await;
    let welcome = result
        .welcome_events
        .iter()
        .find(|w| w.recipient_pubkey == bob_keys.public_key().to_hex())
        .expect("welcome for bob");
    bob.process_gift_wrapped_invitation(&bob_keys, &welcome.event)
        .await
        .expect("process welcome");
    bob.accept_invitation(&welcome.event.id)
        .await
        .expect("accept");

    TwoMemberCircle {
        alice,
        alice_keys,
        bob,
        bob_keys,
        mls_group_id: result.circle.mls_group_id.clone(),
        nostr_group_id: result.circle.nostr_group_id,
        dirs: vec![alice_dir, bob_dir],
    }
}

fn now_secs() -> i64 {
    chrono::Utc::now().timestamp()
}

/// A correctly addressed `kind:445` whose content is well-formed base64 that
/// no group key opens — what anyone who has seen the circle's routing id can
/// mint.
fn undecryptable_445(group_hex: &str, created_at_secs: i64) -> Event {
    let mut bytes = [0u8; 96];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    EventBuilder::new(
        Kind::Custom(445),
        base64::engine::general_purpose::STANDARD.encode(bytes),
    )
    .tag(Tag::custom(TagKind::custom("h"), [group_hex.to_string()]))
    .custom_created_at(Timestamp::from(u64::try_from(created_at_secs).unwrap()))
    .sign_with_keys(&Keys::generate())
    .expect("sign")
}

/// Re-wraps an observed `kind:445` under a fresh key at `created_at_secs`,
/// keeping its tags (and so its NIP-40 `expiration`).
fn backdate(observed: &Event, created_at_secs: i64) -> Event {
    EventBuilder::new(observed.kind, observed.content.clone())
        .tags(observed.tags.iter().cloned().collect::<Vec<Tag>>())
        .custom_created_at(Timestamp::from(u64::try_from(created_at_secs).unwrap()))
        .sign_with_keys(&Keys::generate())
        .expect("re-sign")
}

async fn relay_under_test() -> (MockRelay, String, RelayManager) {
    let _ = allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();
    (relay, url, RelayManager::new())
}

/// The engine keeps no trace of a refused object, so an ingest that answers
/// `ResourceRefused` says so, and the same id is taken again once it can be
/// opened — never answered as already seen.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn left_unpersisted_id_not_marked_seen() {
    let fx = build_two_member_circle(vec!["wss://group.example.com".to_string()]).await;
    fx.fill_alice_deferral_store().await;
    let (location, commit) = fx.bob_location_one_epoch_ahead().await;

    let ScreenedIngest::Ingested(refused) =
        fx.alice.session().process_event(&location).await.unwrap()
    else {
        panic!("a genuine envelope passes the pre-auth screen");
    };
    assert!(matches!(
        refused.outcome,
        IngestOutcome::ResourceRefused { .. }
    ));
    assert!(
        refused.left_object_unpersisted,
        "a refusal must say the engine kept nothing, or no plane would fetch it again"
    );

    fx.alice_applies(&commit).await;
    let ScreenedIngest::Ingested(redelivered) =
        fx.alice.session().process_event(&location).await.unwrap()
    else {
        panic!("a genuine envelope passes the pre-auth screen");
    };
    assert_eq!(
        redelivered.outcome,
        IngestOutcome::Processed,
        "the redelivered id is ingested, never answered as a duplicate"
    );
}

/// A publisher that is handed nothing in these tests, and dials nothing if it
/// is.
struct Nobody;

impl haven_core::relay::fanout::UnrecordedPublisher for Nobody {
    fn publish_unrecorded<'a>(
        &'a self,
        _event: &'a Event,
        _relays: &'a [String],
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = bool> + Send + 'a>> {
        Box::pin(async { false })
    }
}

/// The driver's poll entry answers hold for a refused object too: a plane
/// that polls through it keeps its cursor at or below the event, and the
/// relay is asked for it again (Security Rule 12).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_poll_entry_holds_its_cursor_at_a_refused_445() {
    use haven_core::relay::fanout::scripted::ScriptedFanout;
    use haven_core::relay::fanout::{DriveMode, Publishing, WallClock};
    use haven_core::relay::ReceiveOnlyOutcome;

    let fx = build_two_member_circle(vec!["wss://group.example.com".to_string()]).await;
    fx.fill_alice_deferral_store().await;
    let (location, _commit) = fx.bob_location_one_epoch_ahead().await;

    let transport = ScriptedFanout::default();
    let polled = Publishing {
        fanout: &transport,
        publisher: &Nobody,
        clock: &WallClock,
        deadline_ms: None,
        mode: &DriveMode::Full,
    }
    .ingest_for_poll(&fx.alice, &location)
    .await
    .expect("the refused object is not an ingest failure");
    assert_eq!(
        polled.verdict,
        ReceiveOnlyOutcome::Deferred,
        "an object the engine refused and kept nothing of did not hold the poll's cursor",
    );
    assert!(transport.calls().is_empty() && polled.replayed.is_empty());
}

/// The live plane holds its cursor at a refused event, so the next REQ asks
/// the relay for it again.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_resource_refused_445_holds_the_cursor() {
    let fx = build_two_member_circle(vec!["wss://group.example.com".to_string()]).await;
    fx.fill_alice_deferral_store().await;
    let (location, _commit) = fx.bob_location_one_epoch_ahead().await;

    let processor = EngineProcessor::new(Arc::clone(&fx.alice), EventBus::new());
    let floor = (now_secs() - 7200) * 1000;
    fx.alice
        .advance_sync_cursor(&group_cursor_stream(&fx.group_hex()), floor)
        .expect("seed");
    let opened_at = now_secs();
    processor.note_subscription_opened(&fx.group_hex(), opened_at);

    let refused_secs = now_secs() - 3600;
    let outcome = processor
        .process_group_event(&backdate(&location, refused_secs), &fx.nostr_group_id)
        .await;
    assert_eq!(outcome, GroupProcessOutcome::Refused);

    assert!(processor.note_end_of_stored_events(&fx.group_hex()));
    assert_eq!(
        fx.alice_cursor(),
        Some(refused_secs * 1000),
        "the EOSE may not carry the cursor past an event the engine kept nothing \
         of: its range is not synchronised (Rule 12)"
    );
}

/// The catch-up sweep holds its cursor at a refused event, and a later sweep
/// fetches the range again and applies it once it can be opened.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn resource_refused_range_refetched_after_capacity() {
    let (_relay, url, relay_mgr) = relay_under_test().await;
    let fx = build_two_member_circle(vec![url.clone()]).await;
    fx.fill_alice_deferral_store().await;
    let (location, commit) = fx.bob_location_one_epoch_ahead().await;
    relay_mgr
        .publish_event(&location, std::slice::from_ref(&url))
        .await
        .expect("bob's location reaches the relay");

    let _ = run_catchup_all_circles(&fx.alice, &relay_mgr, 20).await;
    assert!(
        !fx.bob_location_reached_alice(),
        "precondition: the first sweep's delivery was refused"
    );
    let held = fx.alice_cursor().expect("the sweep seeds the cursor");
    assert!(
        held <= i64::try_from(location.created_at.as_secs()).unwrap() * 1000,
        "the sweep may not carry the cursor past the refused event"
    );

    fx.alice_applies(&commit).await;
    let _ = run_catchup_all_circles(&fx.alice, &relay_mgr, 20).await;
    assert!(
        fx.bob_location_reached_alice(),
        "the refused event gets another delivery and is applied"
    );
}

/// A redelivery the relay pool has already seen still reaches the engine.
///
/// The live plane's client dedupes relay messages by event id for the life of
/// the session, so a refused event the relay sends again — on the re-anchored
/// REQ that the held cursor produces — must not be dropped as a repeat.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn haven_dedup_never_suppresses_refused_redelivery() {
    let (_relay, url, relay_mgr) = relay_under_test().await;
    let fx = build_two_member_circle(vec![url.clone()]).await;
    fx.fill_alice_deferral_store().await;
    let (location, commit) = fx.bob_location_one_epoch_ahead().await;
    relay_mgr
        .publish_event(&location, std::slice::from_ref(&url))
        .await
        .expect("bob's location reaches the relay");

    let engine = LiveSyncCore::new_local(
        Arc::clone(&fx.alice),
        fx.alice_keys.public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
    );
    let mut bus = engine.bus().subscribe();
    let spec = CircleSpec {
        group_id_hex: fx.group_hex(),
        relays: vec![url.clone()],
    };
    engine
        .start(std::slice::from_ref(&spec), &[])
        .await
        .expect("start");

    // The refusal is observable only as its hold: wait for the first REQ's
    // EOSE to have anchored the cursor no higher than the refused event.
    let refused_ms = i64::try_from(location.created_at.as_secs()).unwrap() * 1000;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while fx.alice_cursor().is_none_or(|c| c < refused_ms - 60_000) {
        assert!(
            tokio::time::Instant::now() < deadline,
            "the first REQ never reached its end of stored events"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(!fx.bob_location_reached_alice(), "precondition: refused");

    fx.alice_applies(&commit).await;
    engine
        .resume_after_background(Claim::Foreground)
        .await
        .expect("resume");

    let bob_hex = fx.bob_keys.public_key().to_hex();
    let mut delivered = false;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while tokio::time::Instant::now() < deadline {
        match tokio::time::timeout(Duration::from_secs(1), bus.recv()).await {
            Ok(Ok(LiveSyncEvent::Location { sender_pubkey, .. })) if sender_pubkey == bob_hex => {
                delivered = true;
                break;
            }
            Ok(Ok(_)) | Err(_) => {}
            Ok(Err(_)) => break,
        }
    }
    let _ = engine.stop().await;
    assert!(
        delivered,
        "the redelivered event must reach the engine: the relay pool had seen \
         its id, but the engine kept nothing of it"
    );
}

/// One by-id REQ: how many ids it named, and its `limit`.
type IdRequest = (usize, Option<usize>);

/// Records the `ids` of every REQ a relay is asked, and each such REQ's id
/// count and `limit`.
#[derive(Debug, Clone, Default)]
struct IdsAsked(
    Arc<std::sync::Mutex<Vec<EventId>>>,
    Arc<std::sync::Mutex<Vec<IdRequest>>>,
    /// REQs that named no ids: windows and ranges.
    Arc<std::sync::atomic::AtomicUsize>,
);

impl IdsAsked {
    fn contains(&self, id: &EventId) -> bool {
        self.0.lock().unwrap().contains(id)
    }

    fn requests(&self) -> Vec<IdRequest> {
        self.1.lock().unwrap().clone()
    }

    fn forget(&self) {
        self.0.lock().unwrap().clear();
        self.1.lock().unwrap().clear();
    }
}

impl QueryPolicy for IdsAsked {
    fn admit_query<'a>(
        &'a self,
        query: &'a nostr::Filter,
        _addr: &'a std::net::SocketAddr,
    ) -> BoxedFuture<'a, PolicyResult> {
        Box::pin(async move {
            if let Some(ids) = &query.ids {
                self.0.lock().unwrap().extend(ids.iter().copied());
                self.1.lock().unwrap().push((ids.len(), query.limit));
            } else {
                self.2.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            }
            PolicyResult::Accept
        })
    }
}

/// A relay that records the ids it is asked for.
async fn recording_relay() -> (LocalRelay, String, IdsAsked) {
    let _ = allow_ws_loopback_for_test();
    let asked = IdsAsked::default();
    let db = MemoryDatabase::with_opts(MemoryDatabaseOptions {
        events: true,
        max_events: None,
    });
    let relay = LocalRelay::new(
        RelayBuilder::default()
            .query_policy(asked.clone())
            .database(db),
    );
    relay.run().await.expect("relay");
    let url = relay.url().await.to_string();
    (relay, url, asked)
}

/// Defers `junk` on Alice, then moves her epoch — by her own commits — until
/// the engine retires the row on its retry budget
/// (`MAX_DEFERRED_PEEL_ATTEMPTS`, `cgka-engine/src/message_processor/mod.rs:76`)
/// and announces it; returns the announced message id.
async fn retire_on_the_retry_budget(fx: &TwoMemberCircle, junk: &Event) -> Vec<u8> {
    let ScreenedIngest::Ingested(ingest) = fx.alice.session().process_event(junk).await.unwrap()
    else {
        panic!("a well-formed envelope passes the pre-auth screen");
    };
    assert!(
        matches!(ingest.outcome, IngestOutcome::TransportDeferred { .. }),
        "precondition: the engine keeps the envelope for its own re-peel"
    );
    for _ in 0..64 {
        let effects = fx
            .alice
            .session()
            .send(SendIntent::SelfUpdate {
                group_id: fx.mls_group_id.clone(),
            })
            .await
            .expect("alice self-updates");
        let pending = effects
            .publish
            .iter()
            .find_map(|work| match work {
                PublishWork::GroupEvolution { pending, .. } => Some(*pending),
                _ => None,
            })
            .expect("a self-update stages one group evolution");
        let confirmed = fx.alice.session().confirm_published(pending).await.unwrap();
        let advanced = fx
            .alice
            .session()
            .advance_convergence(&fx.mls_group_id)
            .await
            .unwrap();
        if let Some(message_id) =
            confirmed
                .events
                .iter()
                .chain(&advanced.events)
                .find_map(|event| match event {
                    GroupEvent::TransportObjectResourceRefused { message_id, .. } => {
                        Some(message_id.as_slice().to_vec())
                    }
                    _ => None,
                })
        {
            return message_id;
        }
    }
    panic!("the deferred envelope was never retired on its retry budget");
}

/// The id the engine announces a retired object under is the Nostr event id,
/// so a refetch by it asks the relay for exactly that event (PLAN §8 V27).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn resource_refused_message_id_equals_the_nostr_event_id() {
    let fx = build_two_member_circle(vec!["wss://group.example.com".to_string()]).await;
    let junk = undecryptable_445(&fx.group_hex(), now_secs());
    let message_id = retire_on_the_retry_budget(&fx, &junk).await;
    assert_eq!(message_id, junk.id.as_bytes().to_vec());
}

/// An object the engine retired after deferring it is asked for again, by id,
/// at the next catch-up sweep: the deferral let the cursor pass it, so no
/// window would ever bring it back.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn transport_object_resource_refused_event_refetches_by_id() {
    let (_relay, url, asked) = recording_relay().await;
    let fx = build_two_member_circle(vec![url.clone()]).await;
    let junk = undecryptable_445(&fx.group_hex(), now_secs());
    let relay_mgr = RelayManager::new();
    relay_mgr
        .publish_event(&junk, std::slice::from_ref(&url))
        .await
        .expect("the envelope reaches the relay");

    retire_on_the_retry_budget(&fx, &junk).await;
    assert!(
        !asked.contains(&junk.id),
        "precondition: never asked for by id"
    );

    let _ = run_catchup_all_circles(&fx.alice, &relay_mgr, 20).await;
    assert!(
        asked.contains(&junk.id),
        "the sweep must ask its relays for the retired object by id"
    );

    let _ = run_catchup_all_circles(&fx.alice, &relay_mgr, 20).await;
    let asked_again = asked
        .0
        .lock()
        .unwrap()
        .iter()
        .filter(|id| **id == junk.id)
        .count();
    assert_eq!(asked_again, 1, "one delivery opportunity per refusal");
}

/// An object refused at the circle's old relays is asked for by id at those
/// relays after the circle's routing has moved: its traffic of an epoch
/// that can still be fetched is fetched where it was sent
/// (`app-components/nostr-routing-v1.md` 56-64), not only at the relays the
/// circle has now.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refused_object_is_refetched_at_the_relays_the_circle_has_since_left() {
    let (_old, old_url, asked_old) = recording_relay().await;
    let (_new, new_url, _asked_new) = recording_relay().await;
    let fx = build_two_member_circle(vec![old_url.clone()]).await;
    let junk = undecryptable_445(&fx.group_hex(), now_secs());
    let relay_mgr = RelayManager::new();
    relay_mgr
        .publish_event(&junk, std::slice::from_ref(&old_url))
        .await
        .expect("the envelope reaches the old relay");
    retire_on_the_retry_budget(&fx, &junk).await;
    fx.alice
        .update_relays_for_test(&fx.mls_group_id, std::slice::from_ref(&new_url))
        .await
        .expect("the circle's relays change");
    assert!(
        !asked_old.contains(&junk.id),
        "precondition: never asked for by id"
    );

    let _ = run_refused_refetch(&fx.alice, &relay_mgr, 20).await;
    assert!(
        asked_old.contains(&junk.id),
        "an object refused at the relays the circle left was not asked for there",
    );
}

/// How many times the relay was asked for `id` by id.
fn times_asked(asked: &IdsAsked, id: EventId) -> usize {
    asked
        .0
        .lock()
        .unwrap()
        .iter()
        .filter(|asked| **asked == id)
        .count()
}

/// The refused id is recorded durably the moment the engine announces it, so
/// a process killed before the next sweep — or a wake whose deadline ran out —
/// still refetches it afterwards.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refused_id_survives_a_reopen_and_is_still_refetched() {
    let (_relay, url, asked) = recording_relay().await;
    let fx = build_two_member_circle(vec![url.clone()]).await;
    let junk = undecryptable_445(&fx.group_hex(), now_secs());
    let relay_mgr = RelayManager::new();
    relay_mgr
        .publish_event(&junk, std::slice::from_ref(&url))
        .await
        .expect("the envelope reaches the relay");
    retire_on_the_retry_budget(&fx, &junk).await;

    let TwoMemberCircle {
        alice,
        alice_keys,
        dirs,
        ..
    } = fx;
    drop(alice);
    let reopened = CircleManager::new_unencrypted(dirs[0].path(), &alice_keys)
        .expect("the same install opens again");
    let _ = run_catchup_all_circles(&reopened, &relay_mgr, 20).await;
    assert_eq!(
        times_asked(&asked, junk.id),
        1,
        "the refusal outlives the process that saw it"
    );
}

/// A relay address nothing listens at.
fn a_dead_relay() -> String {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().expect("addr").port();
    drop(listener);
    format!("ws://127.0.0.1:{port}")
}

/// Sets what `manager`'s refused ledger reads as now: `secs` after a fixed
/// instant near the real one.
fn at(manager: &CircleManager, secs: u64) {
    const ORIGIN_MS: u64 = 1_790_000_000_000;
    manager
        .session()
        .set_legacy_clock_for_test(ORIGIN_MS + secs * 1_000);
}

/// When the engine has no room for anything a request brought back, the
/// sweep still asks for the whole of its share: an id that has not had its
/// turn keeps it — it may be the one event the engine can open, among any
/// number it cannot. What waits is what was asked for: every id the sweep
/// named waits out the minute it earned, and so does an id asked for earlier
/// whose own wait would have ended sooner — nothing says the engine has room
/// for it either.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_request_the_engine_has_no_room_for_costs_no_id_its_turn_and_makes_the_asked_wait() {
    let (_relay, url, asked) = recording_relay().await;
    // One relay never answers, so an id the other does not hold is not
    // discharged either: only the refusal is left to decide.
    let fx = build_two_member_circle(vec![url.clone(), a_dead_relay()]).await;
    let relay_mgr = RelayManager::new();
    fx.fill_alice_deferral_store().await;
    // Asked for first and found nowhere: it waits out its own minute.
    let earlier = random_ids(1);
    at(&fx.alice, 0);
    fx.alice
        .session()
        .record_refused_for_test(&fx.mls_group_id, &earlier);
    let _ = run_refused_refetch(&fx.alice, &relay_mgr, 20).await;
    assert!(asked.contains(&earlier[0]), "premise: asked for");
    asked.forget();

    // Fifty seconds on: an owed object the relay holds and the engine has
    // no room for, and more owed ids behind it than one request names.
    let held = undecryptable_445(&fx.group_hex(), now_secs() - 60);
    relay_mgr
        .publish_event(&held, std::slice::from_ref(&url))
        .await
        .expect("the relay holds the object");
    let mut owed = vec![held.id];
    owed.extend(random_ids(REFETCH_IDS_PER_REQ + 40));
    at(&fx.alice, 50);
    fx.alice
        .session()
        .record_refused_for_test(&fx.mls_group_id, &owed);

    let _ = run_refused_refetch(&fx.alice, &relay_mgr, 20).await;
    assert!(
        asked.contains(&held.id)
            && asked.requests().len() == REFETCH_REQS_PER_SWEEP
            && owed.iter().all(|id| asked.contains(id)),
        "after the engine had no room for what the first request brought back, the sweep \
         did not go on to ask for the rest of its share: an id lost its turn to a refusal \
         that was not its own",
    );
    asked.forget();
    for secs in [60, 109] {
        at(&fx.alice, secs);
        let _ = run_refused_refetch(&fx.alice, &relay_mgr, 20).await;
        assert!(
            asked.requests().is_empty(),
            "an id asked for before a request the engine had no room for was asked for \
             again before the wait that request earned was over",
        );
    }
    at(&fx.alice, 110);
    let _ = run_refused_refetch(&fx.alice, &relay_mgr, 20).await;
    assert!(
        asked.contains(&held.id) && asked.contains(&earlier[0]),
        "the refetch did not resume when the wait was over: something was forgotten",
    );
}

/// Only the engine having NO ROOM for what a request brought back makes the
/// ids already asked for wait. An event it parked instead — a commit of this
/// device's own is pending, so everything of the circle is stored unopened —
/// is still owed and says nothing about room: the id asked for earlier is
/// asked for again when its own minute is over. Read as "refused wholesale",
/// any event behind a pending commit, or any error, would put every owed id
/// of the circle off for as long as an outsider cared to keep one coming.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_event_the_engine_parks_is_not_one_it_had_no_room_for() {
    let (_relay, url, asked) = recording_relay().await;
    let fx = build_two_member_circle(vec![url.clone(), a_dead_relay()]).await;
    let relay_mgr = RelayManager::new();
    let earlier = random_ids(1);
    at(&fx.alice, 0);
    fx.alice
        .session()
        .record_refused_for_test(&fx.mls_group_id, &earlier);
    let _ = run_refused_refetch(&fx.alice, &relay_mgr, 20).await;
    assert!(asked.contains(&earlier[0]), "premise: asked for");

    // A commit of Alice's own is pending: what her circle is sent is parked.
    let staged = fx
        .alice
        .session()
        .send(SendIntent::SelfUpdate {
            group_id: fx.mls_group_id.clone(),
        })
        .await
        .expect("alice stages a commit");
    assert!(
        staged
            .publish
            .iter()
            .any(|work| matches!(work, PublishWork::GroupEvolution { .. })),
        "premise: a commit is pending",
    );
    let (parked, _, _) = fx
        .bob
        .seal_location_for_test(&fx.mls_group_id, &LocationMessage::new(52.37, 4.89))
        .await
        .expect("bob seals a location");
    relay_mgr
        .publish_event(&parked, std::slice::from_ref(&url))
        .await
        .expect("the relay holds the event");
    at(&fx.alice, 50);
    fx.alice
        .session()
        .record_refused_for_test(&fx.mls_group_id, &[parked.id]);
    let _ = run_refused_refetch(&fx.alice, &relay_mgr, 20).await;
    assert!(
        asked.contains(&parked.id)
            && fx
                .alice
                .session()
                .refused_redeliveries(&fx.mls_group_id, 8)
                .is_empty(),
        "premise: the event was fetched, parked, and is still owed behind its own wait",
    );

    asked.forget();
    at(&fx.alice, 60);
    let _ = run_refused_refetch(&fx.alice, &relay_mgr, 20).await;
    assert!(
        asked.contains(&earlier[0]),
        "an id asked for earlier waited for a request that brought back an event the engine \
         parked: a parked event was read as one the engine had no room for",
    );
}

/// A circle's history range is the same refetch by another filter, on a
/// schedule of its own. A pass that leaves the range unsettled — here one
/// relay of the circle never answers — is not made again at every wake: the
/// wait before the next doubles, as an id's does. And it waits for nothing
/// else: while the range is waiting the circle's ids are still asked for
/// when theirs are due, and a range that is due is asked for whatever its
/// ids are waiting for — past the cap an event is owed as part of the range
/// ONLY, so a range that waited on ids nothing can discharge would never
/// bring it back.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_range_is_asked_for_on_its_own_doubling_wait_whatever_its_ids_are_waiting_for() {
    let (_relay, url, asked) = recording_relay().await;
    // One relay never answers, so nothing is discharged and the range is
    // never answered in full.
    let fx = build_two_member_circle(vec![url.clone(), a_dead_relay()]).await;
    let relay_mgr = RelayManager::new();
    at(&fx.alice, 0);
    let share = REFETCH_IDS_PER_REQ * REFETCH_REQS_PER_SWEEP;
    fx.alice
        .session()
        .record_refused_for_test(&fx.mls_group_id, &random_ids(MAX_REFUSED_IDS_PER_GROUP + 1));
    assert!(
        fx.alice.session().refused_range(&fx.mls_group_id).is_some(),
        "premise: the circle owes its history as a range",
    );
    let ranges = || asked.2.load(std::sync::atomic::Ordering::SeqCst);

    // Every owed id is asked for once, a sweep's share at a time; the
    // history beside them once, by the first of those sweeps alone.
    let _ = run_refused_refetch(&fx.alice, &relay_mgr, 20).await;
    let by_range = ranges();
    assert!(by_range > 0, "premise: the history was asked for");
    for _ in 1..MAX_REFUSED_IDS_PER_GROUP / share {
        let _ = run_refused_refetch(&fx.alice, &relay_mgr, 20).await;
    }
    let by_id = asked.requests().len();
    assert!(
        by_id == MAX_REFUSED_IDS_PER_GROUP / REFETCH_IDS_PER_REQ && ranges() == by_range,
        "a range a pass had just left unsettled was walked again by the next sweep",
    );

    // Now all of it waits: nothing is asked, by id or as a range.
    for _ in 0..3 {
        let _ = run_refused_refetch(&fx.alice, &relay_mgr, 20).await;
    }
    assert_eq!(
        (asked.requests().len(), ranges()),
        (by_id, by_range),
        "a circle whose owed ids and range were all waiting was asked for something",
    );
    assert!(
        fx.alice.session().refused_range(&fx.mls_group_id).is_some(),
        "the range a waiting circle owes was forgotten",
    );

    // A minute on, the range's first wait is over: it is asked for again —
    // and has then earned two minutes. The ids asked for with it at this
    // sweep have too; the rest were last asked for a minute ago.
    at(&fx.alice, 60);
    let _ = run_refused_refetch(&fx.alice, &relay_mgr, 20).await;
    assert!(
        ranges() > by_range,
        "the range was not asked for again when its own wait was over",
    );
    let (by_id, by_range) = (asked.requests().len(), ranges());
    // Two minutes in: ids are due and are asked for; the range is not.
    at(&fx.alice, 120);
    let _ = run_refused_refetch(&fx.alice, &relay_mgr, 20).await;
    assert!(
        asked.requests().len() > by_id && ranges() == by_range,
        "the range was asked for with the circle's ids before its own wait was over, or the \
         ids waited for the range",
    );
    at(&fx.alice, 180);
    let _ = run_refused_refetch(&fx.alice, &relay_mgr, 20).await;
    assert!(
        ranges() > by_range,
        "the range was not asked for when the wait it had earned was over",
    );
}

/// An id no relay produced is discharged only once EVERY relay asked has
/// answered without it: one relay's empty answer says nothing about a relay
/// that never answered. So it stays owed — and is asked for again only when
/// the wait it has earned is over, which doubles: of six sweeps over three
/// minutes, three ask for it, at the first, a minute later, and two minutes
/// after that. A relay is not asked for the same id at every sweep for ever,
/// and nothing is forgotten.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refused_id_one_relay_never_answers_for_stays_owed_and_is_asked_for_on_a_doubling_wait() {
    let (_relay, url, asked) = recording_relay().await;
    let fx = build_two_member_circle(vec![url.clone(), a_dead_relay()]).await;
    at(&fx.alice, 0);
    // Never published: no relay holds it.
    let junk = undecryptable_445(&fx.group_hex(), now_secs());
    retire_on_the_retry_budget(&fx, &junk).await;
    let relay_mgr = RelayManager::new();

    let mut asked_at = Vec::new();
    for secs in [0, 30, 60, 90, 120, 180] {
        at(&fx.alice, secs);
        let before = times_asked(&asked, junk.id);
        let _ = run_catchup_all_circles(&fx.alice, &relay_mgr, 20).await;
        if times_asked(&asked, junk.id) > before {
            asked_at.push(secs);
        }
    }
    assert_eq!(
        asked_at,
        [0, 60, 180],
        "the seconds at which a relay was asked for one refused id over six sweeps",
    );
    at(&fx.alice, 180 + 239);
    assert!(
        fx.alice
            .session()
            .refused_redeliveries(&fx.mls_group_id, 8)
            .is_empty(),
        "premise: not due again before its third wait is over",
    );
    at(&fx.alice, 180 + 240);
    assert!(
        fx.alice.session().refused_redeliveries(&fx.mls_group_id, 8) == [junk.id],
        "an id no sweep could discharge was forgotten",
    );
}

/// A refused event a relay comes to hold is fetched when the wait its id has
/// earned is over, not before, and is then discharged: delivered, it is not
/// asked for again.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refused_event_a_relay_comes_to_hold_is_fetched_when_its_wait_is_over() {
    let (_relay, url, asked) = recording_relay().await;
    let fx = build_two_member_circle(vec![url.clone(), a_dead_relay()]).await;
    at(&fx.alice, 0);
    let (location, _, _) = fx
        .bob
        .seal_location_for_test(&fx.mls_group_id, &LocationMessage::new(52.37, 4.89))
        .await
        .expect("bob seals a location");
    fx.alice
        .session()
        .record_refused_for_test(&fx.mls_group_id, &[location.id]);
    let relay_mgr = RelayManager::new();

    let _ = run_catchup_all_circles(&fx.alice, &relay_mgr, 20).await;
    assert_eq!(
        times_asked(&asked, location.id),
        1,
        "premise: asked for, and found on no relay that answered",
    );
    relay_mgr
        .publish_event(&location, std::slice::from_ref(&url))
        .await
        .expect("the event reaches the relay");

    at(&fx.alice, 30);
    let _ = run_catchup_all_circles(&fx.alice, &relay_mgr, 20).await;
    assert_eq!(
        times_asked(&asked, location.id),
        1,
        "a refused id was asked for again before its wait was over",
    );
    at(&fx.alice, 60);
    let _ = run_catchup_all_circles(&fx.alice, &relay_mgr, 20).await;
    at(&fx.alice, 3_600);
    assert!(
        times_asked(&asked, location.id) == 2
            && fx
                .alice
                .session()
                .refused_redeliveries(&fx.mls_group_id, 8)
                .is_empty(),
        "a refused event its relay had come to hold was not fetched when its wait was over, \
         or was not discharged once delivered",
    );
    let _ = run_catchup_all_circles(&fx.alice, &relay_mgr, 20).await;
    assert_eq!(
        times_asked(&asked, location.id),
        2,
        "a delivered event was asked for again",
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refused_id_every_relay_answers_without_is_discharged() {
    let (_relay, url, asked) = recording_relay().await;
    let fx = build_two_member_circle(vec![url.clone()]).await;
    let junk = undecryptable_445(&fx.group_hex(), now_secs());
    retire_on_the_retry_budget(&fx, &junk).await;
    let relay_mgr = RelayManager::new();

    let _ = run_catchup_all_circles(&fx.alice, &relay_mgr, 20).await;
    let _ = run_catchup_all_circles(&fx.alice, &relay_mgr, 20).await;
    assert_eq!(
        times_asked(&asked, junk.id),
        1,
        "proven gone from every relay, it is not asked for again"
    );
}

/// A relay's answer to a request by id is read for the ids asked alone: an
/// event it sends beside them that no request named is not taken in, and
/// proves nothing about the ids — one it did not send is discharged as absent
/// by that one request, not asked for again on the strength of the stray.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_answer_by_id_is_read_for_the_asked_ids_alone() {
    use haven_core::relay::scripted_relay::{Frame, ScriptedRelay};
    use std::sync::atomic::{AtomicUsize, Ordering};

    let relay = ScriptedRelay::start();
    let fx = build_two_member_circle(vec![relay.url().to_string()]).await;
    let (unasked, _, _) = fx
        .bob
        .seal_location_for_test(&fx.mls_group_id, &LocationMessage::new(52.37, 4.89))
        .await
        .expect("bob seals a location");
    let by_id = Arc::new(AtomicUsize::new(0));
    let counted = Arc::clone(&by_id);
    relay.answer(
        move |filter| {
            let asks_by_id = filter.ids.is_some();
            if asks_by_id {
                counted.fetch_add(1, Ordering::SeqCst);
            }
            asks_by_id
        },
        vec![Frame::Event(unasked), Frame::Eose],
    );
    at(&fx.alice, 0);
    fx.alice
        .session()
        .record_refused_for_test(&fx.mls_group_id, &random_ids(1));

    let _ = run_refused_refetch(&fx.alice, &RelayManager::new(), 20).await;

    assert_eq!(
        by_id.load(Ordering::SeqCst),
        1,
        "an id the relay answered without was asked for again because of an event nobody asked for",
    );
    assert!(
        fx.alice
            .session()
            .refused_redeliveries(&fx.mls_group_id, 8)
            .is_empty(),
        "an id the only relay answered without was not discharged",
    );
    assert!(
        !fx.bob_location_reached_alice(),
        "an event no request named was taken in from an answer by id",
    );
}

fn random_ids(count: usize) -> Vec<EventId> {
    (0..count)
        .map(|_| {
            let mut bytes = [0u8; 32];
            rand::rngs::OsRng.fill_bytes(&mut bytes);
            EventId::from_byte_array(bytes)
        })
        .collect()
}

/// Absence is proved only by an answer that could have held the event.
///
/// A relay may clamp a REQ's `limit` below what matches it: it then sends a
/// subset of what it holds and its EOSE. An id left out of such an answer
/// is not gone — read as gone, an event the relay holds would stop being
/// owed with nobody having delivered it (Security Rule 12). It is asked for
/// again by itself, and only an answer that brings nothing ends it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_id_a_relay_left_out_beside_others_it_sent_is_asked_for_again_and_not_given_up() {
    use haven_core::relay::scripted_relay::{Frame, ScriptedRelay};

    let relay = ScriptedRelay::start();
    let fx = build_two_member_circle(vec![relay.url().to_string()]).await;
    let held: Vec<Event> = (0..3)
        .map(|_| undecryptable_445(&fx.group_hex(), now_secs() - 60))
        .collect();
    let ids: Vec<EventId> = held.iter().map(|event| event.id).collect();
    // The relay holds all three and sends one a REQ: the first of those it
    // is asked for.
    let served = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    for (index, event) in held.iter().enumerate() {
        let (before, own) = (ids[..index].to_vec(), ids[index]);
        let served = Arc::clone(&served);
        relay.answer(
            move |filter| {
                let named = filter.ids.as_ref();
                let first = named.is_some_and(|named| {
                    named.contains(&own) && !before.iter().any(|id| named.contains(id))
                });
                if first {
                    served.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                }
                first
            },
            vec![Frame::Event(event.clone()), Frame::Eose],
        );
    }
    fx.alice
        .session()
        .record_refused_for_test(&fx.mls_group_id, &ids);
    let owed = || {
        fx.alice
            .session()
            .refused_redeliveries(&fx.mls_group_id, 16)
    };
    let relay_mgr = RelayManager::new();

    let _ = run_refused_refetch(&fx.alice, &relay_mgr, 20).await;
    assert!(
        served.load(std::sync::atomic::Ordering::SeqCst) == REFETCH_REQS_PER_SWEEP,
        "premise: the sweep's share is two requests, each answered with one event",
    );
    // `assert!`, not `assert_eq!`: an id is never formatted (Security Rule 15).
    assert!(
        owed() == [ids[2]],
        "an id a relay left out of an answer that brought others was given up as gone, or \
         was not asked for again by itself and lost its turn",
    );

    let _ = run_refused_refetch(&fx.alice, &relay_mgr, 20).await;
    assert!(
        served.load(std::sync::atomic::Ordering::SeqCst) == 3 && owed().is_empty(),
        "the id left over was not asked for by the next sweep, or is still owed after the \
         relay sent its event",
    );
}

/// A backlog of refused ids bigger than one sweep's share is asked for in
/// REQs no bigger than a relay is asked to answer, each capped at what it
/// names, and the next sweep starts with the ids that waited longest.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refused_backlog_is_asked_for_in_bounded_requests_oldest_first() {
    let (_relay, url, asked) = recording_relay().await;
    let dead = {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = listener.local_addr().expect("addr").port();
        drop(listener);
        format!("ws://127.0.0.1:{port}")
    };
    // One relay never answers, so nothing is discharged and every id stays owed.
    let fx = build_two_member_circle(vec![url.clone(), dead]).await;
    let share = REFETCH_IDS_PER_REQ * REFETCH_REQS_PER_SWEEP;
    let owed = random_ids(share + 88);
    fx.alice
        .session()
        .record_refused_for_test(&fx.mls_group_id, &owed);
    let relay_mgr = RelayManager::new();

    let _ = run_catchup_all_circles(&fx.alice, &relay_mgr, 20).await;
    let first = asked.requests();
    assert_eq!(
        first.len(),
        REFETCH_REQS_PER_SWEEP,
        "one sweep's share, no more"
    );
    for (ids, limit) in &first {
        assert!(
            *ids <= REFETCH_IDS_PER_REQ,
            "no REQ names more ids than a relay is asked to take"
        );
        assert_eq!(
            *limit,
            Some(*ids),
            "and none can be answered with more than it names"
        );
    }
    let never_asked: Vec<_> = owed
        .iter()
        .filter(|id| !asked.contains(id))
        .copied()
        .collect();
    assert_eq!(never_asked.len(), 88);

    asked.forget();
    let _ = run_catchup_all_circles(&fx.alice, &relay_mgr, 20).await;
    assert!(
        never_asked.iter().all(|id| asked.contains(id)),
        "the ids the last sweep could not reach go first"
    );
}

/// A circle that reaches a new epoch is asked for what it owes at once: on
/// the live plane, which holds no REQ of its own to ask with, by the status
/// the app answers with a refetch — and not when its circle owes nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_new_epoch_on_the_live_plane_asks_for_what_its_circle_owes() {
    for owes in [true, false] {
        let fx = build_two_member_circle(vec!["wss://relay.example.com".to_string()]).await;
        if owes {
            fx.alice
                .session()
                .record_refused_for_test(&fx.mls_group_id, &random_ids(1));
        }
        let (_, commit) = fx.bob_location_one_epoch_ahead().await;
        let bus = EventBus::new();
        let mut carried = bus.subscribe();
        let processor = EngineProcessor::new(Arc::clone(&fx.alice), bus);
        let before = fx.alice.session().epoch(&fx.mls_group_id).await.unwrap();
        let _ = processor
            .process_group_event(&commit, &fx.nostr_group_id)
            .await;
        assert_eq!(
            fx.alice.session().epoch(&fx.mls_group_id).await.unwrap(),
            before + 1,
            "premise: the plane applied the commit",
        );
        let mut asked = false;
        while let Ok(event) = carried.try_recv() {
            asked |= matches!(
                event,
                LiveSyncEvent::Status {
                    reason: SyncStatusReason::RefetchOwed
                }
            );
        }
        assert_eq!(
            asked, owes,
            "a circle that reached a new epoch was not asked for what it owes, or one that \
             owes nothing was",
        );
    }
}

/// A new epoch inside a sweep asks for the circle's owed ids there and then,
/// out of the sweep's own share: a relay is asked no more often than it
/// would have been, only sooner.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_new_epoch_inside_a_sweep_costs_a_relay_no_request_beyond_the_sweeps_share() {
    let (_relay, url, asked) = recording_relay().await;
    // One relay never answers, so nothing is discharged and every id stays owed.
    let fx = build_two_member_circle(vec![url.clone(), a_dead_relay()]).await;
    let relay_mgr = RelayManager::new();
    fx.alice.session().record_refused_for_test(
        &fx.mls_group_id,
        &random_ids(REFETCH_IDS_PER_REQ * (REFETCH_REQS_PER_SWEEP + 1)),
    );
    let (_, commit) = fx.bob_location_one_epoch_ahead().await;
    relay_mgr
        .publish_event(&commit, std::slice::from_ref(&url))
        .await
        .expect("the relay holds the commit");
    let before = fx.alice.session().epoch(&fx.mls_group_id).await.unwrap();

    let _ = run_catchup_all_circles(&fx.alice, &relay_mgr, 60).await;
    assert_eq!(
        fx.alice.session().epoch(&fx.mls_group_id).await.unwrap(),
        before + 1,
        "premise: the sweep's window brought the commit and the epoch moved in it",
    );
    assert_eq!(
        asked.requests().len(),
        REFETCH_REQS_PER_SWEEP,
        "a sweep in which the circle reached a new epoch asked a relay for refused ids more \
         often than its share",
    );
}

/// Refuses every windowed `#h` query — the sweep's ordinary window — and
/// serves the rest: a relay whose answer to the window never carried an
/// object, so only a refetch of the history from its start brings it back.
#[derive(Debug, Clone, Default)]
struct WindowWithheld;

impl QueryPolicy for WindowWithheld {
    fn admit_query<'a>(
        &'a self,
        query: &'a nostr::Filter,
        _addr: &'a std::net::SocketAddr,
    ) -> BoxedFuture<'a, PolicyResult> {
        Box::pin(async move {
            if query.since.is_some_and(|since| since.as_secs() > 0) {
                PolicyResult::Reject("window withheld".to_string())
            } else {
                PolicyResult::Accept
            }
        })
    }
}

/// Withholds every windowed query like [`WindowWithheld`], and the first time
/// it is asked for a circle's history, records refusals past the per-circle
/// cap for that circle on the device asking — refusals that land while a range
/// pass runs.
type RangePassTarget = Arc<std::sync::Mutex<Option<(Arc<CircleManager>, GroupId)>>>;

#[derive(Clone, Default)]
struct RefusalDuringRangePass {
    target: RangePassTarget,
    fired: Arc<std::sync::atomic::AtomicBool>,
}

impl std::fmt::Debug for RefusalDuringRangePass {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("RefusalDuringRangePass")
    }
}

impl QueryPolicy for RefusalDuringRangePass {
    fn admit_query<'a>(
        &'a self,
        query: &'a nostr::Filter,
        _addr: &'a std::net::SocketAddr,
    ) -> BoxedFuture<'a, PolicyResult> {
        Box::pin(async move {
            if query.since.is_some_and(|since| since.as_secs() > 0) {
                return PolicyResult::Reject("window withheld".to_string());
            }
            if query.ids.is_none() && !self.fired.swap(true, std::sync::atomic::Ordering::SeqCst) {
                if let Some((device, group)) = self.target.lock().unwrap().as_ref() {
                    // Enough to overflow the by-id ledger however much of it
                    // this sweep's by-id refetch has already discharged.
                    device
                        .session()
                        .record_refused_for_test(group, &random_ids(MAX_REFUSED_IDS_PER_GROUP + 1));
                }
            }
            PolicyResult::Accept
        })
    }
}

/// A refusal recorded while a range pass runs widens the range past what the
/// pass asked for, so the pass — however whole its answer — must not discharge
/// it: the redelivery that refusal is owed has not happened (Rule 12).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refusal_recorded_during_a_range_pass_keeps_the_range_owed() {
    let _ = allow_ws_loopback_for_test();
    let policy = RefusalDuringRangePass::default();
    let relay = LocalRelay::new(
        RelayBuilder::default()
            .query_policy(policy.clone())
            .database(MemoryDatabase::with_opts(MemoryDatabaseOptions {
                events: true,
                max_events: None,
            })),
    );
    relay.run().await.expect("relay");
    let url = relay.url().await.to_string();
    let fx = build_two_member_circle(vec![url.clone()]).await;
    *policy.target.lock().unwrap() = Some((Arc::clone(&fx.alice), fx.mls_group_id.clone()));
    fx.alice
        .session()
        .record_refused_for_test(&fx.mls_group_id, &random_ids(MAX_REFUSED_IDS_PER_GROUP + 1));
    let read = fx.alice.session().refused_range(&fx.mls_group_id);
    assert!(read.is_some(), "precondition: a range is owed");

    let _ = run_catchup_all_circles(&fx.alice, &RelayManager::new(), 20).await;

    assert!(
        policy.fired.load(std::sync::atomic::Ordering::SeqCst),
        "anti-vacuity: the refusal landed during the range pass"
    );
    let after = fx.alice.session().refused_range(&fx.mls_group_id);
    assert!(
        after.is_some(),
        "the range stays owed for the later refusal"
    );
    assert!(
        after != read,
        "and it is the widened range, not the one read"
    );
}

/// What the live plane runs on `RefetchOwed`: the redelivery alone, only for a
/// circle that owes one. No window is swept, so a stranger's flood of refusals
/// cannot turn each into a full catch-up.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refetch_request_runs_only_the_owed_redelivery() {
    let (_relay, url, asked) = recording_relay().await;
    let fx = build_two_member_circle(vec![url.clone()]).await;
    let relay_mgr = RelayManager::new();

    let _ = run_refused_refetch(&fx.alice, &relay_mgr, 20).await;
    assert!(
        asked.requests().is_empty() && asked.2.load(std::sync::atomic::Ordering::SeqCst) == 0,
        "a circle that owes nothing is not asked anything"
    );

    let owed = random_ids(1);
    fx.alice
        .session()
        .record_refused_for_test(&fx.mls_group_id, &owed);
    let _ = run_refused_refetch(&fx.alice, &relay_mgr, 20).await;

    assert!(asked.contains(&owed[0]), "the owed id is asked for");
    assert_eq!(
        asked.2.load(std::sync::atomic::Ordering::SeqCst),
        0,
        "and no window is swept"
    );
}

/// Refusals past the per-circle cap are owed as the circle's history instead:
/// a sweep walks the range down, brings back what the window never carried,
/// and discharges the range once every relay answered it in full.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn refusals_past_the_cap_are_redelivered_as_a_history_range() {
    let _ = allow_ws_loopback_for_test();
    let relay = LocalRelay::new(
        RelayBuilder::default()
            .query_policy(WindowWithheld)
            .database(MemoryDatabase::with_opts(MemoryDatabaseOptions {
                events: true,
                max_events: None,
            })),
    );
    relay.run().await.expect("relay");
    // One that does not speak NIP-77, whose withheld window the range walk
    // alone brings back: a pass would fetch it by id first.
    let declines = helpers::neg_wire::NegWire::in_front_of(
        &relay.url().await.to_string(),
        helpers::neg_wire::NegPolicy::Notice("ERROR: bad msg: unknown cmd".into()),
    )
    .await;
    let url = declines.url.clone();
    let fx = build_two_member_circle(vec![url.clone()]).await;
    let relay_mgr = RelayManager::new();
    let (location, _, _) = fx
        .bob
        .seal_location_for_test(&fx.mls_group_id, &LocationMessage::new(52.37, 4.89))
        .await
        .expect("bob sends");
    relay_mgr
        .publish_event(&location, std::slice::from_ref(&url))
        .await
        .expect("the location reaches the relay");
    let _ = run_catchup_all_circles(&fx.alice, &relay_mgr, 20).await;
    assert!(
        !fx.bob_location_reached_alice(),
        "precondition: the sweep's own window never carried it"
    );

    fx.alice
        .session()
        .record_refused_for_test(&fx.mls_group_id, &random_ids(MAX_REFUSED_IDS_PER_GROUP + 1));
    assert!(fx.alice.session().refused_range(&fx.mls_group_id).is_some());
    let _ = run_catchup_all_circles(&fx.alice, &relay_mgr, 20).await;

    assert!(
        fx.bob_location_reached_alice(),
        "the history range brought back what the cursor had passed"
    );
    assert!(
        fx.alice.session().refused_range(&fx.mls_group_id).is_none(),
        "answered in full, the range is discharged"
    );
}

/// A history range that reaches back across a rotation of the circle's
/// routing id by another client's admin is asked for under the prior id as
/// well: what was sent before the rotation was sent under it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_history_range_reaching_back_across_a_rotation_is_asked_under_the_prior_id() {
    use cgka_traits::app_components::{
        encode_nostr_routing_v1, NostrRoutingV1, NOSTR_ROUTING_COMPONENT_ID,
    };
    use haven_core::nostr::mls::types::AppComponentData;

    let _ = allow_ws_loopback_for_test();
    let relay = LocalRelay::new(
        RelayBuilder::default()
            .query_policy(WindowWithheld)
            .database(MemoryDatabase::with_opts(MemoryDatabaseOptions {
                events: true,
                max_events: None,
            })),
    );
    relay.run().await.expect("relay");
    // One that does not speak NIP-77, whose withheld window the range walk
    // alone brings back: a pass would fetch it by id first.
    let declines = helpers::neg_wire::NegWire::in_front_of(
        &relay.url().await.to_string(),
        helpers::neg_wire::NegPolicy::Notice("ERROR: bad msg: unknown cmd".into()),
    )
    .await;
    let url = declines.url.clone();
    let fx = build_two_member_circle(vec![url.clone()]).await;
    let relay_mgr = RelayManager::new();
    let (location, _, _) = fx
        .bob
        .seal_location_for_test(&fx.mls_group_id, &LocationMessage::new(52.37, 4.89))
        .await
        .expect("bob sends");
    relay_mgr
        .publish_event(&location, std::slice::from_ref(&url))
        .await
        .expect("the location reaches the relay");

    let rotated: [u8; 32] = rand::random();
    let effects = fx
        .alice
        .session()
        .send(SendIntent::UpdateAppComponents {
            group_id: fx.mls_group_id.clone(),
            updates: vec![AppComponentData {
                component_id: NOSTR_ROUTING_COMPONENT_ID,
                data: encode_nostr_routing_v1(
                    &NostrRoutingV1::new(rotated, vec![url.clone()]).expect("a routing state"),
                )
                .expect("the component encodes"),
            }],
        })
        .await
        .expect("alice rotates the routing id, as another client would");
    let pending = effects
        .publish
        .iter()
        .find_map(|work| match work {
            PublishWork::GroupEvolution { pending, .. } => Some(*pending),
            _ => None,
        })
        .expect("the rotation is staged");
    fx.alice
        .session()
        .confirm_published(pending)
        .await
        .expect("alice applies it, and her row follows");
    let reached = || {
        fx.alice
            .snapshot_last_known_for_circle(&rotated, chrono::Utc::now().timestamp())
            .expect("snapshot")
            .iter()
            .any(|loc| loc.sender_pubkey == fx.bob_keys.public_key().to_hex())
    };
    let _ = run_catchup_all_circles(&fx.alice, &relay_mgr, 20).await;
    assert!(
        !reached(),
        "precondition: the sweep's own window never carried it"
    );

    fx.alice
        .session()
        .record_refused_for_test(&fx.mls_group_id, &random_ids(MAX_REFUSED_IDS_PER_GROUP + 1));
    let _ = run_catchup_all_circles(&fx.alice, &relay_mgr, 20).await;
    assert!(
        reached(),
        "the history range did not bring back what was sent under the prior routing id",
    );
}

/// Alice's store holds a stranger's full deferred-peel flood, and Bob's commit
/// has re-armed all of it: applied through single user-facing advances, as the
/// send path would see a commit a plane applied without draining.
async fn alice_holds_a_rearmed_flood(fx: &TwoMemberCircle) {
    fx.fill_alice_deferral_store().await;
    let (_, commit) = fx.bob_location_one_epoch_ahead().await;
    let session = fx.alice.session();
    let before = session.epoch(&fx.mls_group_id).await.unwrap();
    session.process_event(&commit).await.expect("ingest");
    let started = std::time::Instant::now();
    while session.epoch(&fx.mls_group_id).await.unwrap() == before {
        assert!(
            started.elapsed() < Duration::from_mins(2),
            "bob's commit was never applied"
        );
        if let Some(after) = session.receive_retick_after(&fx.mls_group_id).await {
            tokio::time::sleep(after).await;
        }
        session
            .advance_convergence(&fx.mls_group_id)
            .await
            .expect("advance");
    }
    assert!(
        session
            .deferred_peels_untried_for_test(&fx.mls_group_id)
            .await,
        "anti-vacuity: the flood is still untried when the user sends"
    );
}

/// A deferred-peel store a non-member filled to MDK's cap costs the user no
/// location, however slow the device: every row a commit re-arms gets its try
/// before the send, so the send's own preflight — four rows a send, queuing
/// the send when spent (`cgka-engine/src/message_processor/mod.rs:215-222,1208-1230`)
/// — finds nothing left to try (`docs/MDK_UPSTREAM_TRACKER.md`
/// T-FOREGROUND-PEEL).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_full_deferred_peel_store_never_defers_the_next_location_send() {
    use haven_core::nostr::mls::storage::{
        slow_deferred_peel_writes_for_test, slow_deferred_peel_writes_left_for_test, StorageConfig,
    };
    use haven_core::relay::fanout::{
        scripted::Inert, DriveMode, LocationSeal, Publishing, WallClock,
    };
    // The foreground's send, and the background's, which makes no commit.
    for mode in [DriveMode::Full, DriveMode::FinishOnly] {
        let fx = build_two_member_circle(vec!["wss://group.example.com".to_string()]).await;
        alice_holds_a_rearmed_flood(&fx).await;
        // Advances cut after a row or two, as MDK's 500 ms budget cuts them
        // on a slow device: more rows short than a drain sized at 64 rows an
        // advance has advances to spare.
        let db = StorageConfig::new(fx.dirs[0].path()).database_path();
        let key = StorageConfig::test_sqlcipher_key().expect("test key");
        slow_deferred_peel_writes_for_test(&db, &key, 6).expect("arm");

        let sent = Publishing::<'_, Inert> {
            fanout: &Inert,
            publisher: &Inert,
            clock: &WallClock,
            deadline_ms: None,
            mode: &mode,
        }
        .seal_location(
            &fx.alice,
            &fx.mls_group_id,
            &LocationMessage::new(48.85, 2.35),
        )
        .await
        .expect("the send runs")
        .seal;
        assert!(
            matches!(sent, LocationSeal::Sealed { .. }),
            "the next location is sent, not deferred behind a stranger's flood \
             ({mode:?}: {sent:?})",
        );
        assert!(
            slow_deferred_peel_writes_left_for_test(&db, &key).expect("read") == 0,
            "anti-vacuity: the slow rows were tried ({mode:?})"
        );
    }
}

/// A send begun with no room left in its wake for the pre-send drain — a
/// background burst near its end — begins no drain advance: it is held as
/// the wake running out, with nothing sealed, published or lost, and the
/// next wake with room drains the flood and sends.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_send_with_no_room_left_in_its_wake_for_the_drain_is_held_and_the_next_wake_drains_on() {
    use haven_core::relay::fanout::{
        scripted::Inert, DriveMode, FanoutClock as _, LocationSeal, Publishing, SendHeld,
        WallClock, LOCATION_SEND_MS,
    };
    let fx = build_two_member_circle(vec!["wss://group.example.com".to_string()]).await;
    alice_holds_a_rearmed_flood(&fx).await;
    let wake = |deadline_ms| Publishing::<'_, Inert> {
        fanout: &Inert,
        publisher: &Inert,
        clock: &WallClock,
        deadline_ms,
        mode: &DriveMode::FinishOnly,
    };

    let held = wake(Some(WallClock.now_ms() + LOCATION_SEND_MS))
        .seal_location(
            &fx.alice,
            &fx.mls_group_id,
            &LocationMessage::new(48.85, 2.35),
        )
        .await
        .expect("the send runs");
    assert!(
        matches!(held.seal, LocationSeal::Deferred(SendHeld::StoredInput)),
        "a send with no room for the drain was not held behind the stored input: {:?}",
        held.seal,
    );
    assert_eq!(
        held.retry_after_ms,
        Some(0),
        "the hold does not say the wake ran out",
    );
    assert!(
        fx.alice
            .session()
            .deferred_peels_untried_for_test(&fx.mls_group_id)
            .await,
        "the flood is no longer there for the next wake to drain",
    );

    let sent = wake(None)
        .seal_location(
            &fx.alice,
            &fx.mls_group_id,
            &LocationMessage::new(48.86, 2.36),
        )
        .await
        .expect("the send runs")
        .seal;
    assert!(
        matches!(sent, LocationSeal::Sealed { .. }),
        "the next wake with room did not drain the flood and send: {sent:?}",
    );
}

/// A drain stops at its deadline: with the budget spent it takes one advance
/// and leaves the rest of the flood to later passes.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_spent_drain_budget_leaves_the_flood_to_later_passes() {
    let fx = build_two_member_circle(vec!["wss://group.example.com".to_string()]).await;
    alice_holds_a_rearmed_flood(&fx).await;
    let session = fx.alice.session();

    let drained = session
        .drain_deferred_peels(&fx.mls_group_id, Some(std::time::Instant::now()))
        .await
        .expect("the drain runs");
    assert!(drained.is_some(), "rows were untried, so one advance ran");
    assert!(
        session
            .deferred_peels_untried_for_test(&fx.mls_group_id)
            .await,
        "a spent budget drains no further than its first advance"
    );
}

/// Records every by-id REQ a relay is asked, with whether it named a routing
/// id: the NIP-77 pass's ask carries `#h`, the refused-object refetch's does
/// not.
#[derive(Debug, Clone, Default)]
struct ByIdAsks(Arc<std::sync::Mutex<Vec<ByIdAsk>>>);

/// One by-id REQ: the ids it named, and whether it named a routing id.
type ByIdAsk = (Vec<EventId>, bool);

impl QueryPolicy for ByIdAsks {
    fn admit_query<'a>(
        &'a self,
        query: &'a nostr::Filter,
        _addr: &'a std::net::SocketAddr,
    ) -> BoxedFuture<'a, PolicyResult> {
        Box::pin(async move {
            if let Some(ids) = &query.ids {
                let routed = query
                    .generic_tags
                    .contains_key(&nostr::SingleLetterTag::lowercase(nostr::Alphabet::H));
                self.0
                    .lock()
                    .unwrap()
                    .push((ids.iter().copied().collect(), routed));
            }
            PolicyResult::Accept
        })
    }
}

/// An event the NIP-77 pass recovers and the engine has no room for is never
/// on record as held: the inventory lacks it, the sweep's cursor stays at or
/// below it, and the next pass asks for it again — its redelivery
/// (Security Rule 12). Once the refused ledger owes it by id, no pass asks
/// for it: the ledger's own doubling wait is in charge of it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_reconciled_event_the_engine_refuses_is_owed_by_id_and_never_recorded() {
    let _ = allow_ws_loopback_for_test();
    let asks = ByIdAsks::default();
    let db = MemoryDatabase::with_opts(MemoryDatabaseOptions {
        events: true,
        max_events: None,
    });
    let relay = LocalRelay::new(
        RelayBuilder::default()
            .query_policy(asks.clone())
            .database(db.clone()),
    );
    relay.run().await.expect("relay");
    let url = relay.url().await.to_string();
    let fx = build_two_member_circle(vec![url.clone()]).await;
    fx.fill_alice_deferral_store().await;
    let (location, _commit) = fx.bob_location_one_epoch_ahead().await;
    // A full page of junk in the second above it: no page of the pager
    // reaches it, and only the pass can.
    let above = location.created_at.as_secs() + 1;
    let mut seeded = vec![location.clone()];
    seeded.extend((0..500).map(|i| {
        EventBuilder::new(Kind::Custom(445), format!("cGlsZQ-{i}"))
            .tags(vec![
                Tag::parse(["h", &fx.group_hex()]).unwrap(),
                Tag::parse(["h", &hex::encode([0x11u8; 32])]).unwrap(),
            ])
            .custom_created_at(Timestamp::from(above))
            .sign_with_keys(&Keys::generate())
            .unwrap()
    }));
    for event in &seeded {
        assert!(
            nostr_relay_builder::prelude::NostrDatabase::save_event(&db, event)
                .await
                .expect("seed")
                .is_success()
        );
    }
    while u64::try_from(now_secs()).unwrap() <= above {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let mut at = u64::try_from(now_secs()).unwrap() * 1_000;
    let relay_mgr = RelayManager::new();
    let asked_by_the_pass = || {
        asks.0
            .lock()
            .unwrap()
            .iter()
            .filter(|(ids, routed)| *routed && ids.contains(&location.id))
            .count()
    };
    let mut pass = || {
        at += haven_core::relay::negentropy::NEG_PASS_SPACING_MS + 1_000;
        fx.alice.session().set_legacy_clock_for_test(at);
        run_catchup_all_circles(&fx.alice, &relay_mgr, 30)
    };

    let _ = pass().await;
    assert_eq!(
        asked_by_the_pass(),
        1,
        "premise: the pass asked for the event by id"
    );
    assert!(
        !fx.bob_location_reached_alice(),
        "premise: the engine refused it"
    );
    assert!(
        !fx.alice
            .session()
            .neg_inventory_for_test(fx.nostr_group_id)
            .await
            .contains(&location.id),
        "a refused event is on record as held"
    );
    assert!(
        fx.alice_cursor()
            .is_none_or(|ms| ms <= i64::try_from(location.created_at.as_secs()).unwrap() * 1000),
        "the cursor passed an event the engine kept nothing of"
    );

    let _ = pass().await;
    assert_eq!(
        asked_by_the_pass(),
        2,
        "nothing else owes it, so the next pass asks again"
    );

    fx.alice
        .session()
        .record_refused_for_test(&fx.mls_group_id, &[location.id]);
    let _ = pass().await;
    assert_eq!(
        asked_by_the_pass(),
        2,
        "a pass asked by id for what the refused ledger already owes"
    );
}
