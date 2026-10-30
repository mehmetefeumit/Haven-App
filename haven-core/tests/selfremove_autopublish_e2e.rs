//! Receive-side eviction publish-before-apply (Rule 13 / security F13).
//!
//! When a member leaves via `SendIntent::Leave`, a bare `SelfRemove` proposal is
//! published; a REMAINING member's engine owes a jitter-delayed eviction commit
//! of it. Once a rewire resolved that by an OPTIMISTIC confirm WITHOUT
//! publishing the commit to relays — so other remaining members never received
//! the eviction (a roster fork) AND a commit no relay acked was applied locally
//! (a Rule 13 violation).
//!
//! The eviction is now made by the fanout driver, like every commit of this
//! device's own. These tests pin, end to end:
//!
//! - the eviction is SENT and applied ONLY after a relay's OK-ack, and a THIRD
//!   remaining member receiving it converges on the post-eviction roster — the
//!   invariant the gap broke;
//! - two live-sync engines make, send and converge on it over a real relay;
//! - the plane a proposal is published through reads only a real OK as an ack.
//!
//! Every other answer a relay can give a commit is crossed with the driver in
//! `publish_before_apply_send_e2e` and the `fanout_*` suites.

use std::sync::Arc;
use std::time::Duration;

use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage};
use haven_core::nostr::mls::types::GroupId;
use haven_core::relay::fanout::UnrecordedPublisher;
use haven_core::relay::maintenance::build_kp_maintenance_events;
use nostr::Keys;
use tempfile::TempDir;

/// A genuine three-member circle (Alice admin + Bob + Carol) built through the
/// PUBLIC circle API, each with their own real MLS store.
struct ThreeMemberCircle {
    alice: Arc<CircleManager>,
    alice_keys: Keys,
    bob: Arc<CircleManager>,
    bob_keys: Keys,
    carol: Arc<CircleManager>,
    carol_keys: Keys,
    mls_group_id: GroupId,
    nostr_group_id: [u8; 32],
    _dirs: Vec<TempDir>,
}

async fn mint_member(relays: &[String]) -> (Arc<CircleManager>, Keys, MemberKeyPackage, TempDir) {
    let dir = TempDir::new().unwrap();
    let keys = Keys::generate();
    let mgr = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();
    let kp_event = build_kp_maintenance_events(
        mgr.session(),
        &keys,
        &["wss://kp.example.com".to_string()],
        None,
        None,
    )
    .await
    .expect("member key package")
    .event;
    let member = MemberKeyPackage {
        key_package_event: kp_event,
        inbox_relays: relays.to_vec(),
        nip65_relays: vec![],
    };
    (Arc::new(mgr), keys, member, dir)
}

/// Builds Alice (admin) + Bob + Carol as real co-members. `group_relays` become
/// the circle's stored relay set (what the eviction's fanout targets), so a
/// real-relay test can point them at an in-process relay.
async fn build_three_member_circle(group_relays: Vec<String>) -> ThreeMemberCircle {
    let inbox = vec!["wss://member-inbox.example.com".to_string()];
    let (bob, bob_keys, bob_member, bob_dir) = mint_member(&inbox).await;
    let (carol, carol_keys, carol_member, carol_dir) = mint_member(&inbox).await;

    let alice_dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let alice = Arc::new(CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap());
    let config =
        CircleConfig::new("SelfRemove AutoPublish Circle").with_relays(group_relays.clone());
    let result = alice
        .create_circle(&alice_keys, vec![bob_member, carol_member], &config)
        .await
        .expect("create circle");
    // As the app's driven create leaves it: the founding Welcomes sent from
    // their records and acknowledged, so no later drive sends them.
    let _ = alice.land_staged_for_test().await;
    let mls_group_id = result.circle.mls_group_id.clone();
    let nostr_group_id = result.circle.nostr_group_id;

    // Bob + Carol join from their gift-wrapped welcomes.
    for (mgr, keys) in [(&bob, &bob_keys), (&carol, &carol_keys)] {
        let welcome = result
            .welcome_events
            .iter()
            .find(|w| w.recipient_pubkey == keys.public_key().to_hex())
            .expect("welcome for member");
        mgr.process_gift_wrapped_invitation(keys, &welcome.event)
            .await
            .expect("process welcome");
        mgr.accept_invitation(&welcome.event.id)
            .await
            .expect("accept");
    }

    ThreeMemberCircle {
        alice,
        alice_keys,
        bob,
        bob_keys,
        carol,
        carol_keys,
        mls_group_id,
        nostr_group_id,
        _dirs: vec![alice_dir, bob_dir, carol_dir],
    }
}

async fn roster(circle: &CircleManager, group_id: &GroupId) -> Vec<String> {
    circle.session().member_pubkeys(group_id).await.unwrap()
}

async fn epoch(circle: &CircleManager, group_id: &GroupId) -> u64 {
    circle.session().epoch(group_id).await.unwrap()
}

/// Rule 13 happy path + the cross-member invariant: Alice's foreground poll
/// takes in Bob's proposal, makes the eviction, sends it, and applies it on
/// the relay's ack — and a THIRD member (Carol), in a plane that makes no
/// commit, converges on the post-eviction roster from that SAME sent commit.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_receive_side_eviction_is_sent_then_applied_and_a_third_member_converges() {
    let fx = build_three_member_circle(vec!["wss://group.example.com".to_string()]).await;
    let bob_hex = fx.bob_keys.public_key().to_hex();
    let epoch_before = epoch(&fx.alice, &fx.mls_group_id).await;
    assert_eq!(roster(&fx.alice, &fx.mls_group_id).await.len(), 3);

    let proposal = fx
        .bob
        .propose_leave(&fx.mls_group_id)
        .await
        .expect("bob proposes leave")
        .expect("a first leave in this epoch proposes");
    fx.carol
        .ingest_for_test(&proposal)
        .await
        .expect("carol ingests proposal");
    assert!(
        roster(&fx.carol, &fx.mls_group_id).await.contains(&bob_hex),
        "the bare proposal must NOT apply the removal"
    );

    let (_, sent) = fx
        .alice
        .ingest_landing_for_test(&proposal)
        .await
        .expect("alice ingests proposal");
    assert_eq!(
        sent.len(),
        1,
        "exactly one eviction commit must be sent to the relays before it is applied"
    );
    assert!(
        !roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "Alice evicts Bob once a relay acknowledged the commit"
    );
    assert_eq!(
        epoch(&fx.alice, &fx.mls_group_id).await,
        epoch_before + 1,
        "Alice's epoch advances past the acknowledged SelfRemove commit"
    );

    // THE invariant the gap broke: Carol, receiving the SAME sent commit over
    // the relay, converges on the post-eviction roster.
    fx.carol
        .ingest_for_test(&sent[0])
        .await
        .expect("carol ingests the sent eviction commit");
    assert!(
        !roster(&fx.carol, &fx.mls_group_id).await.contains(&bob_hex),
        "Carol converges on the post-eviction roster from the SENT commit \
         (the fork the optimistic-confirm gap produced)"
    );
    assert_eq!(
        epoch(&fx.carol, &fx.mls_group_id).await,
        epoch_before + 1,
        "Carol lands on the same post-eviction epoch as Alice"
    );
}

/// End-to-end over an in-process relay: two live-sync engines (Alice + Carol),
/// receiving the leaver's `SelfRemove` proposal, PUBLISH the eviction auto-commit
/// to the shared relay and BOTH converge on the post-eviction roster — the whole
/// live-sync path (ingest → jitter re-tick → publish → confirm → peer converge),
/// which the optimistic-confirm gap left forked.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn two_live_sync_engines_publish_and_converge_on_the_eviction() {
    use haven_core::relay::live_sync::{CircleSpec, Claim, LiveSyncCore};
    use nostr_relay_builder::MockRelay;
    use nostr_sdk::Client;

    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();

    // The circle's stored relays ARE the in-process relay, so the eviction's
    // fanout targets a socket the engines are connected to.
    let fx = build_three_member_circle(vec![url.clone()]).await;
    let hex = hex::encode(fx.nostr_group_id);
    let bob_hex = fx.bob_keys.public_key().to_hex();
    let epoch_before = epoch(&fx.alice, &fx.mls_group_id).await;

    let alice_engine = LiveSyncCore::new_local(
        Arc::clone(&fx.alice),
        fx.alice_keys.public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
    );
    let carol_engine = LiveSyncCore::new_local(
        Arc::clone(&fx.carol),
        fx.carol_keys.public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
    );
    let spec = CircleSpec {
        group_id_hex: hex,
        relays: vec![url.clone()],
    };
    alice_engine
        .start(std::slice::from_ref(&spec), &[])
        .await
        .expect("alice engine starts");
    carol_engine
        .start(std::slice::from_ref(&spec), &[])
        .await
        .expect("carol engine starts");
    // As the app does once a start returns: a session only started makes no
    // commit, so each eviction is its claimed foreground's to make.
    alice_engine.claim_foreground(Claim::Foreground).await;
    carol_engine.claim_foreground(Claim::Foreground).await;
    tokio::time::sleep(Duration::from_millis(500)).await; // both REQs register

    // Bob (non-admin) leaves; his SelfRemove proposal is published to the relay.
    let proposal = fx
        .bob
        .propose_leave(&fx.mls_group_id)
        .await
        .expect("bob proposes leave")
        .expect("a first leave in this epoch proposes");
    let publisher = Client::builder().build();
    publisher.add_relay(&url).await.unwrap();
    publisher.connect().await;
    publisher
        .send_event(&proposal)
        .await
        .expect("publish proposal");

    // Both engines must ingest the proposal, publish the auto-commit to the relay,
    // and converge on the post-eviction roster (Bob gone, epoch advanced) — with
    // NO manual confirm anywhere (the engines do it, only after a relay ack).
    let mut converged = false;
    for _ in 0..150 {
        let alice_ok = !roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex)
            && epoch(&fx.alice, &fx.mls_group_id).await > epoch_before;
        let carol_ok = !roster(&fx.carol, &fx.mls_group_id).await.contains(&bob_hex)
            && epoch(&fx.carol, &fx.mls_group_id).await > epoch_before;
        if alice_ok && carol_ok {
            converged = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }

    assert!(
        converged,
        "both live-sync engines must publish the eviction to the relay and converge \
         on the post-eviction roster (the fork the optimistic-confirm gap produced)"
    );
    assert_eq!(
        epoch(&fx.alice, &fx.mls_group_id).await,
        epoch(&fx.carol, &fx.mls_group_id).await,
        "no split-brain: Alice and Carol land on the same post-eviction epoch"
    );

    // Teardown only: every assertion has already run. The outcome is not
    // asserted here because the drain contract itself is pinned by
    // `join_tasks_*` and the `stop_*` unit tests in
    // `src/relay/live_sync/session.rs`, and by the same-store restart
    // assertions in `live_sync_cursor_replay_e2e`.
    let _ = alice_engine.stop().await;
    let _ = carol_engine.stop().await;
}

/// The plane what has no record — a proposal, a Welcome — is published through.
/// `RelayManager::publish_unrecorded` must report `true` ONLY on a real relay
/// OK-ack, and resolve every failure — a transport error, an unusable relay
/// set — to `false`, so nothing reads it as sent.
///
/// Runs against an in-process relay rather than a fake: this impl exists purely
/// to translate `RelayManager`'s own result type into the ack verdict, so a fake
/// would be asserting the translation against itself.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn relay_manager_publisher_acks_only_on_a_real_relay_ok() {
    use haven_core::relay::{allow_ws_loopback_for_test, RelayManager};
    use nostr_relay_builder::MockRelay;

    let _ = allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();

    // A genuine signed kind:445 — Bob's own SelfRemove proposal — rather than an
    // arbitrary event, so the relay sees the event shape this path really carries.
    let fx = build_three_member_circle(vec![url.clone()]).await;
    let commit = fx
        .bob
        .propose_leave(&fx.mls_group_id)
        .await
        .expect("bob proposes leave")
        .expect("a first leave in this epoch proposes");

    let manager = RelayManager::new();
    let publisher: &dyn UnrecordedPublisher = &manager;

    assert!(
        publisher
            .publish_unrecorded(&commit, std::slice::from_ref(&url))
            .await,
        "a relay that OK-acks the commit must resolve to an ack"
    );

    // Rule 13's other half: anything short of an OK-ack is `false`, never an
    // optimistic `true`. A non-wss relay is rejected before any socket is opened,
    // so this asserts the error branch without waiting on a network timeout.
    assert!(
        !publisher
            .publish_unrecorded(&commit, &["http://not-a-relay.example".to_string()])
            .await,
        "an unusable relay set must resolve to NO ack"
    );
}
