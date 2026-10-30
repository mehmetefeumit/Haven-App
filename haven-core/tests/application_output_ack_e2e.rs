//! A decrypted application output is acknowledged once Haven has it.
//!
//! MDK v0.10.4 keeps every `MessageReceived` (the decrypted inner event) and
//! `GroupJoined` in its durable pending-output table until the host
//! acknowledges it, and re-emits every unacknowledged one at the next session
//! open (`cgka-engine/src/engine.rs:573-626`; `traits/src/storage.rs:340-364`).
//! A host that never acknowledges keeps every decrypted location it ever
//! received at rest, and hands each one back again on every launch.

mod helpers;

use std::sync::Arc;

use haven_core::circle::{CircleConfig, CircleCreationResult, CircleManager, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::storage::{set_engine_write_fault_for_test, EngineWrite};
use haven_core::nostr::mls::types::GroupEvent;
use haven_core::nostr::mls::StorageConfig;
use haven_core::relay::catchup::run_catchup_all_circles;
use haven_core::relay::live_sync::{EngineProcessor, EventBus};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use haven_core::relay::RelayManager;
use helpers::{assert_no_needles, capture_haven_log};
use nostr::{Event, Keys};
use tempfile::TempDir;

/// Alice's circle with Bob joined, and one location Bob sent into it.
struct Fixture {
    alice: Arc<CircleManager>,
    alice_dir: TempDir,
    alice_keys: Keys,
    bob_keys: Keys,
    created: CircleCreationResult,
    location: Event,
    _bob_dir: TempDir,
}

async fn bob_sends_into_alices_circle() -> Fixture {
    let bob_dir = TempDir::new().unwrap();
    let bob_keys = Keys::generate();
    let bob = CircleManager::new_unencrypted(bob_dir.path(), &bob_keys).unwrap();
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
    let alice_dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let alice = Arc::new(CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap());
    let relays = vec!["wss://group.example.com".to_string()];
    let created = alice
        .create_circle(
            &alice_keys,
            vec![MemberKeyPackage {
                key_package_event: kp_event,
                inbox_relays: vec!["wss://inbox.example.com".to_string()],
                nip65_relays: vec![],
            }],
            &CircleConfig::new("Ack Circle").with_relays(relays.clone()),
        )
        .await
        .expect("create");
    let welcome = &created.welcome_events[0];
    bob.process_gift_wrapped_invitation(&bob_keys, &welcome.event)
        .await
        .expect("welcome");
    bob.accept_invitation(&welcome.event.id)
        .await
        .expect("join");
    assert_eq!(
        bob.session()
            .pending_application_output_count_for_test()
            .await
            .unwrap(),
        0,
        "joining leaves no output waiting for redelivery"
    );

    let (location, _, _) = bob
        .seal_location_for_test(
            &created.circle.mls_group_id,
            &LocationMessage::new(48.85, 2.35),
        )
        .await
        .expect("bob encrypts");
    Fixture {
        alice,
        alice_dir,
        alice_keys,
        bob_keys,
        created,
        location,
        _bob_dir: bob_dir,
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_received_location_is_acknowledged_and_never_redelivered_after_a_reopen() {
    let Fixture {
        alice,
        alice_dir,
        alice_keys,
        location,
        ..
    } = bob_sends_into_alices_circle().await;
    let delivered = alice.ingest_for_test(&location).await.expect("alice reads");
    assert!(!delivered.is_empty(), "precondition: the fix arrived");
    assert_eq!(
        alice
            .session()
            .pending_application_output_count_for_test()
            .await
            .unwrap(),
        0,
        "the decrypted fix may not stay at rest once Haven has it"
    );

    drop(alice);
    let reopened = CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap();
    let replayed = reopened.session().drain().await;
    assert!(
        !replayed
            .events
            .iter()
            .any(|event| matches!(event, GroupEvent::MessageReceived { .. })),
        "a reopen must not hand the same fix back again"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_failed_acknowledgement_says_so_without_an_identifier_and_costs_only_a_redelivery() {
    let fx = bob_sends_into_alices_circle().await;
    let key = StorageConfig::test_sqlcipher_key().expect("test key");
    let db = StorageConfig::new(fx.alice_dir.path()).database_path();

    set_engine_write_fault_for_test(&db, &key, EngineWrite::AcknowledgeOutputs, true)
        .expect("arm the ack fault");
    let alice = Arc::clone(&fx.alice);
    let location = fx.location.clone();
    let lines = Box::pin(capture_haven_log(async move {
        let delivered = alice.ingest_for_test(&location).await.expect("alice reads");
        assert!(!delivered.is_empty(), "the fix still reaches Haven");
    }))
    .await;
    set_engine_write_fault_for_test(&db, &key, EngineWrite::AcknowledgeOutputs, false)
        .expect("disarm the ack fault");

    let warning = lines
        .iter()
        .find(|line| {
            line.message
                .contains("application outputs not acknowledged")
        })
        .expect("a failed acknowledgement must be reported, not swallowed");
    assert_no_needles(
        std::slice::from_ref(warning),
        &[
            &hex::encode(fx.created.circle.mls_group_id.as_slice()),
            &hex::encode(fx.created.circle.nostr_group_id),
            &fx.alice_keys.public_key().to_hex(),
            &fx.bob_keys.public_key().to_hex(),
            &fx.location.id.to_hex(),
            "group.example.com",
            "Ack Circle",
            "48.85",
        ],
    );
    assert_eq!(
        fx.alice
            .session()
            .pending_application_output_count_for_test()
            .await
            .unwrap(),
        1,
        "premise: the output is still held for redelivery"
    );

    let Fixture {
        alice,
        alice_dir,
        alice_keys,
        location,
        ..
    } = fx;
    drop(alice);
    let reopened = CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap();
    // The next receive after the open — here the relay redelivering the same
    // event — carries the held output, and the persist site acknowledges it.
    let replayed = reopened
        .ingest_for_test(&location)
        .await
        .expect("alice reads again");
    assert!(
        !replayed.is_empty(),
        "the unacknowledged fix comes back at the next open, so nothing is lost"
    );
    assert_eq!(
        reopened
            .session()
            .pending_application_output_count_for_test()
            .await
            .unwrap(),
        0,
        "and the redelivery is acknowledged in its turn"
    );
}

/// Arms an abort on inserts into one `circles-v2.db` table: the unencrypted
/// test store is a plain `SQLite` file.
fn fail_circle_inserts(dir: &std::path::Path, table: &str) {
    haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
    let conn = rusqlite::Connection::open(dir.join(haven_core::circle::CIRCLES_DB_FILENAME))
        .expect("open the circle store");
    conn.execute_batch(&format!(
        "CREATE TRIGGER test_insert_fault BEFORE INSERT ON {table}
         BEGIN SELECT RAISE(ABORT, 'injected'); END;"
    ))
    .expect("arm the insert fault");
}

fn clear_circle_insert_fault(dir: &std::path::Path) {
    haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
    rusqlite::Connection::open(dir.join(haven_core::circle::CIRCLES_DB_FILENAME))
        .expect("open the circle store")
        .execute_batch("DROP TRIGGER test_insert_fault")
        .expect("disarm the insert fault");
}

/// A location whose row did not commit is not acknowledged: the engine hands it
/// back at the next open instead of losing it to a kill between the two.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_location_whose_row_does_not_commit_is_handed_back_after_a_reopen() {
    let Fixture {
        alice,
        alice_dir,
        alice_keys,
        location,
        ..
    } = bob_sends_into_alices_circle().await;
    fail_circle_inserts(alice_dir.path(), "last_known_locations");

    let _ = alice.ingest_for_test(&location).await;
    assert_eq!(
        alice
            .session()
            .pending_application_output_count_for_test()
            .await
            .unwrap(),
        1,
        "an output Haven could not record stays owed"
    );

    drop(alice);
    let reopened = CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap();
    let replayed = reopened.session().drain().await;
    assert!(
        replayed
            .events
            .iter()
            .any(|event| matches!(event, GroupEvent::MessageReceived { .. })),
        "the next open hands the fix back"
    );
}

/// The recovered circle is the one the user accepted: an Accepted membership,
/// and the routing the founder chose — read from the engine's group, never
/// from the transport.
async fn assert_recovered_as_founded(
    reopened: &CircleManager,
    group_id: &haven_core::nostr::mls::types::GroupId,
    founded: &haven_core::circle::Circle,
) {
    let recovered = reopened
        .get_circle(group_id)
        .await
        .unwrap()
        .expect("the circle the engine joined is the user's circle");
    assert_eq!(
        recovered.membership.status,
        haven_core::circle::MembershipStatus::Accepted
    );
    assert_eq!(recovered.circle.nostr_group_id, founded.nostr_group_id);
    assert_eq!(recovered.circle.relays, founded.relays);
}

/// Bob is invited into Alice's circle, and his accept dies before the circle
/// row commits: the engine has joined, Haven has no circle.
struct InterruptedJoin {
    /// The circle as its founder recorded it: the routing a recovered circle
    /// must carry.
    founded: haven_core::circle::Circle,
    bob: CircleManager,
    bob_dir: TempDir,
    bob_keys: Keys,
    welcome: Event,
    group_id: haven_core::nostr::mls::types::GroupId,
    _alice: CircleManager,
    _alice_dir: TempDir,
}

async fn bob_accepts_and_the_circle_row_fails() -> InterruptedJoin {
    let bob_dir = TempDir::new().unwrap();
    let bob_keys = Keys::generate();
    let bob = CircleManager::new_unencrypted(bob_dir.path(), &bob_keys).unwrap();
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
    let alice_dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let alice = CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap();
    let relays = vec!["wss://group.example.com".to_string()];
    let created = alice
        .create_circle(
            &alice_keys,
            vec![MemberKeyPackage {
                key_package_event: kp_event,
                inbox_relays: vec!["wss://inbox.example.com".to_string()],
                nip65_relays: vec![],
            }],
            &CircleConfig::new("Owed Join").with_relays(relays.clone()),
        )
        .await
        .expect("create");
    let welcome = created.welcome_events[0].event.clone();
    bob.process_gift_wrapped_invitation(&bob_keys, &welcome)
        .await
        .expect("welcome");
    fail_circle_inserts(bob_dir.path(), "circles");

    assert!(
        bob.accept_invitation(&welcome.id).await.is_err(),
        "precondition: the circle row cannot be written"
    );
    assert_eq!(
        bob.session()
            .pending_application_output_count_for_test()
            .await
            .unwrap(),
        1,
        "the join stays owed until Haven has recorded the circle"
    );
    clear_circle_insert_fault(bob_dir.path());
    InterruptedJoin {
        bob,
        bob_dir,
        bob_keys,
        welcome,
        group_id: created.circle.mls_group_id.clone(),
        founded: created.circle,
        _alice: alice,
        _alice_dir: alice_dir,
    }
}

/// The join is recovered at the next open: the first receive pass records the
/// circle MDK handed back, and only then acknowledges it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_interrupted_join_is_recorded_by_the_next_session_and_then_acknowledged() {
    let fx = bob_accepts_and_the_circle_row_fails().await;
    drop(fx.bob);
    let reopened = CircleManager::new_unencrypted(fx.bob_dir.path(), &fx.bob_keys).unwrap();
    assert!(
        reopened.get_circle(&fx.group_id).await.unwrap().is_none(),
        "precondition: no circle yet"
    );

    let _ = run_catchup_all_circles(&reopened, &RelayManager::new(), 5).await;

    assert_recovered_as_founded(&reopened, &fx.group_id, &fx.founded).await;
    assert_eq!(
        reopened
            .session()
            .pending_application_output_count_for_test()
            .await
            .unwrap(),
        0,
        "and the join, recorded, is acknowledged"
    );
}

/// The live plane's first pass recovers it just the same.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_live_planes_first_pass_records_an_interrupted_join() {
    let fx = bob_accepts_and_the_circle_row_fails().await;
    drop(fx.bob);
    let reopened =
        Arc::new(CircleManager::new_unencrypted(fx.bob_dir.path(), &fx.bob_keys).unwrap());

    EngineProcessor::new(Arc::clone(&reopened), EventBus::new())
        .drain_open_advance()
        .await;

    assert_recovered_as_founded(&reopened, &fx.group_id, &fx.founded).await;
    assert_eq!(
        reopened
            .session()
            .pending_application_output_count_for_test()
            .await
            .unwrap(),
        0
    );
}

/// Accepting the same invitation again, after the reopen, records the circle
/// instead of telling the user to ask for a new invite.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn accepting_an_interrupted_join_again_records_its_circle() {
    let fx = bob_accepts_and_the_circle_row_fails().await;
    drop(fx.bob);
    let reopened = CircleManager::new_unencrypted(fx.bob_dir.path(), &fx.bob_keys).unwrap();
    reopened
        .process_gift_wrapped_invitation(&fx.bob_keys, &fx.welcome)
        .await
        .expect("the invitation is offered again");

    let accepted = reopened.accept_invitation(&fx.welcome.id).await;

    assert!(
        accepted.is_ok(),
        "a repeat of a join this device holds is not a dead invitation: {:?}",
        accepted.err()
    );
    assert_recovered_as_founded(&reopened, &fx.group_id, &fx.founded).await;
    assert_eq!(
        reopened
            .session()
            .pending_application_output_count_for_test()
            .await
            .unwrap(),
        0
    );
}

/// Bob, and a group someone else founded with Bob's public `KeyPackage`, with
/// the gift-wrapped Welcome to it.
struct Lure {
    bob: CircleManager,
    bob_dir: TempDir,
    bob_keys: Keys,
    welcome: Event,
    group_id: haven_core::nostr::mls::types::GroupId,
    founder: CircleManager,
    founder_keys: Keys,
    _founder_dir: TempDir,
}

async fn a_group_founded_with_bob() -> Lure {
    let bob_dir = TempDir::new().unwrap();
    let bob_keys = Keys::generate();
    let bob = CircleManager::new_unencrypted(bob_dir.path(), &bob_keys).unwrap();
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
    let founder_dir = TempDir::new().unwrap();
    let founder_keys = Keys::generate();
    let founder = CircleManager::new_unencrypted(founder_dir.path(), &founder_keys).unwrap();
    let relays = vec!["wss://group.example.com".to_string()];
    let created = founder
        .create_circle(
            &founder_keys,
            vec![MemberKeyPackage {
                key_package_event: kp_event,
                inbox_relays: vec!["wss://inbox.example.com".to_string()],
                nip65_relays: vec![],
            }],
            &CircleConfig::new("Lure").with_relays(relays.clone()),
        )
        .await
        .expect("create");
    Lure {
        bob,
        bob_dir,
        bob_keys,
        welcome: created.welcome_events[0].event.clone(),
        group_id: created.circle.mls_group_id,
        founder,
        founder_keys,
        _founder_dir: founder_dir,
    }
}

/// The engine joins any Welcome it is handed. One that reached it without the
/// user accepting — here handed to the session directly — is handed back at
/// the next open like any join, and the next session acknowledges it and
/// keeps it hidden: no circle, so nothing is ever sent to it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_join_nobody_accepted_is_acknowledged_and_kept_hidden() {
    let lure = a_group_founded_with_bob().await;
    lure.bob
        .session()
        .accept_welcome(&lure.welcome)
        .await
        .expect("the engine joins what it is handed");
    assert!(
        lure.bob
            .session()
            .find_group(&lure.group_id)
            .await
            .unwrap()
            .is_some(),
        "precondition: the engine joined"
    );

    drop(lure.bob);
    let reopened = CircleManager::new_unencrypted(lure.bob_dir.path(), &lure.bob_keys).unwrap();
    assert_eq!(
        reopened
            .session()
            .pending_application_output_count_for_test()
            .await
            .unwrap(),
        1,
        "anti-vacuity: the reopened session is handed the join"
    );
    let _ = run_catchup_all_circles(&reopened, &RelayManager::new(), 5).await;

    assert!(
        reopened.get_circle(&lure.group_id).await.unwrap().is_none(),
        "a join nobody accepted is never a circle"
    );
    assert_eq!(
        reopened
            .session()
            .pending_application_output_count_for_test()
            .await
            .unwrap(),
        0,
        "and it is acknowledged, not handed back for ever"
    );
}

/// A circle the user left stays gone when its join is handed back again: the
/// accept intent was spent when the circle was first recorded. A leave's end
/// forgets the group — and the join MDK still owed with it — unless an
/// invitation from one of its members is held unanswered, which keeps the
/// group for that invitation; that is the case where the join can still be
/// handed back, so Bob holds one from the founder when he leaves.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_left_circle_whose_join_is_handed_back_stays_gone() {
    let lure = a_group_founded_with_bob().await;
    let second_package = build_kp_maintenance_events(
        lure.bob.session(),
        &lure.bob_keys,
        &["wss://kp.example.com".to_string()],
        None,
        None,
    )
    .await
    .expect("bob's second key package")
    .event;
    let another = lure
        .founder
        .create_circle(
            &lure.founder_keys,
            vec![MemberKeyPackage {
                key_package_event: second_package,
                inbox_relays: vec!["wss://inbox.example.com".to_string()],
                nip65_relays: vec![],
            }],
            &CircleConfig::new("Another").with_relays(vec!["wss://group.example.com".to_string()]),
        )
        .await
        .expect("create")
        .welcome_events[0]
        .event
        .clone();
    let key = StorageConfig::test_sqlcipher_key().expect("test key");
    let db = StorageConfig::new(lure.bob_dir.path()).database_path();
    lure.bob
        .process_gift_wrapped_invitation(&lure.bob_keys, &lure.welcome)
        .await
        .expect("welcome");
    set_engine_write_fault_for_test(&db, &key, EngineWrite::AcknowledgeOutputs, true)
        .expect("arm the ack fault");
    lure.bob
        .accept_invitation(&lure.welcome.id)
        .await
        .expect("bob accepts");
    set_engine_write_fault_for_test(&db, &key, EngineWrite::AcknowledgeOutputs, false)
        .expect("disarm the ack fault");
    assert_eq!(
        lure.bob
            .session()
            .pending_application_output_count_for_test()
            .await
            .unwrap(),
        1,
        "precondition: the join's acknowledgement was lost"
    );
    lure.bob
        .process_gift_wrapped_invitation(&lure.bob_keys, &another)
        .await
        .expect("the founder's other invitation is held");
    let _ = lure.bob.propose_leave(&lure.group_id).await;
    lure.bob
        .complete_leave(&lure.group_id, chrono::Utc::now().timestamp())
        .await
        .expect("bob leaves");
    assert!(
        lure.bob.session().group_is_live(&lure.group_id).await,
        "precondition: the held invitation keeps the left group unforgotten"
    );

    drop(lure.bob);
    let reopened = CircleManager::new_unencrypted(lure.bob_dir.path(), &lure.bob_keys).unwrap();
    let _ = run_catchup_all_circles(&reopened, &RelayManager::new(), 5).await;

    assert!(
        reopened.get_circle(&lure.group_id).await.unwrap().is_none(),
        "the circle the user left does not come back"
    );
    assert_eq!(
        reopened
            .session()
            .pending_application_output_count_for_test()
            .await
            .unwrap(),
        0
    );
}

/// The poll and background planes hand every fetched event to
/// `decrypt_location_collecting_commits`. A Welcome handed there — whatever
/// relay served it — is refused before the engine sees it: Bob joins nothing,
/// gains no circle, owes nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_welcome_handed_to_the_poll_plane_joins_nothing() {
    let lure = a_group_founded_with_bob().await;

    let outcome = lure
        .bob
        .ingest_for_test(&lure.welcome)
        .await
        .expect("a refused event is no ingest failure");

    assert!(outcome.is_empty());
    assert!(lure
        .bob
        .session()
        .find_group(&lure.group_id)
        .await
        .unwrap()
        .is_none());
    assert!(lure.bob.get_circle(&lure.group_id).await.unwrap().is_none());
    assert_eq!(
        lure.bob
            .session()
            .pending_application_output_count_for_test()
            .await
            .unwrap(),
        0
    );
}

/// The live plane, which also carries iOS background bursts, refuses a Welcome
/// a relay delivers on a circle's subscription just the same.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_welcome_delivered_on_the_live_plane_joins_nothing() {
    let lure = a_group_founded_with_bob().await;
    let bob = Arc::new(lure.bob);

    let _ = EngineProcessor::new(Arc::clone(&bob), EventBus::new())
        .process_group_event(&lure.welcome, &[7u8; 32])
        .await;

    assert!(bob
        .session()
        .find_group(&lure.group_id)
        .await
        .unwrap()
        .is_none());
    assert!(bob.get_circle(&lure.group_id).await.unwrap().is_none());
    assert_eq!(
        bob.session()
            .pending_application_output_count_for_test()
            .await
            .unwrap(),
        0
    );
}
