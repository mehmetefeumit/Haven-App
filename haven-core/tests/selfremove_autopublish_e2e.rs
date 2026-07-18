//! Receive-side auto-commit publish-before-apply (Rule 13 / security F13).
//!
//! When a member leaves via `SendIntent::Leave`, a bare `SelfRemove` proposal is
//! published; a REMAINING member's engine schedules a jitter-delayed auto-commit
//! of it that surfaces as `PublishWork::AutoPublish`. The DM-3 rewire resolved
//! that by an OPTIMISTIC `confirm_published` WITHOUT publishing the commit to
//! relays — so other remaining members never received the eviction commit (a
//! roster fork) AND a commit no relay acked was applied locally (a Rule 13
//! violation).
//!
//! These tests pin the fix over the shared publish-then-confirm path
//! ([`haven_core::relay::auto_commit::resolve_receive_publish_work`]) and its
//! live-sync consumer ([`haven_core::relay::live_sync::EngineProcessor`]):
//!
//! - the auto-commit is PUBLISHED and confirmed ONLY after a ≥1-relay OK-ack;
//! - a no-ack publish ROLLS BACK (never an optimistic confirm), keeping the
//!   leaver in the roster at the prior epoch;
//! - a THIRD remaining member, receiving the published auto-commit, converges on
//!   the post-eviction roster — the invariant the gap broke.

use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::{GroupId, PublishWork};
use haven_core::relay::auto_commit::{resolve_receive_publish_work, AutoCommitPublisher};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use nostr::{Event, Keys};
use tempfile::TempDir;

/// A recording fake relay plane: records every event it is asked to publish and
/// reports a fixed OK-ack verdict, so a test can drive `resolve_receive_publish_work`
/// with no network and assert the publish-then-confirm ordering deterministically.
struct FakePublisher {
    ack: bool,
    published: Mutex<Vec<Event>>,
}

impl FakePublisher {
    fn new(ack: bool) -> Self {
        Self {
            ack,
            published: Mutex::new(Vec::new()),
        }
    }

    fn published(&self) -> Vec<Event> {
        self.published.lock().unwrap().clone()
    }
}

impl AutoCommitPublisher for FakePublisher {
    fn publish_auto_commit<'a>(
        &'a self,
        event: &'a Event,
        _relays: &'a [String],
    ) -> Pin<Box<dyn Future<Output = bool> + Send + 'a>> {
        Box::pin(async move {
            self.published.lock().unwrap().push(event.clone());
            self.ack
        })
    }
}

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
/// the circle's stored relay set (what the receive-side auto-commit publisher
/// targets), so a real-relay test can point them at an in-process relay.
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
        .create_circle(
            &alice_keys,
            vec![bob_member, carol_member],
            &config,
            &group_relays,
        )
        .await
        .expect("create circle");
    let mls_group_id = result.circle.mls_group_id.clone();
    let nostr_group_id = result.circle.nostr_group_id;
    alice
        .confirm_published(result.pending)
        .await
        .expect("alice confirms creation");

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

/// Ingests a proposal into `session` and drains `advance_convergence` until the
/// jitter-delayed `SelfRemove` auto-commit surfaces as `PublishWork::AutoPublish`,
/// returning the whole surfacing publish batch. Panics if it never surfaces.
async fn surface_auto_commit(circle: &CircleManager, group_id: &GroupId) -> Vec<PublishWork> {
    for _ in 0..40 {
        let eff = circle
            .session()
            .advance_convergence(group_id)
            .await
            .expect("advance convergence");
        if eff
            .publish
            .iter()
            .any(|w| matches!(w, PublishWork::AutoPublish { .. }))
        {
            return eff.publish;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("SelfRemove auto-commit never surfaced within the jitter window");
}

async fn roster(circle: &CircleManager, group_id: &GroupId) -> Vec<String> {
    circle.session().member_pubkeys(group_id).await.unwrap()
}

async fn epoch(circle: &CircleManager, group_id: &GroupId) -> u64 {
    circle.session().epoch(group_id).await.unwrap()
}

/// Rule 13 happy path + the cross-member invariant: Alice publishes the eviction
/// commit (≥1-relay ack), confirms it, evicts Bob and advances an epoch — and a
/// THIRD member (Carol) receiving that SAME published commit converges on the
/// post-eviction roster.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn auto_commit_is_published_then_confirmed_and_a_third_member_converges() {
    let fx = build_three_member_circle(vec!["wss://group.example.com".to_string()]).await;
    let bob_hex = fx.bob_keys.public_key().to_hex();
    let epoch_before = epoch(&fx.alice, &fx.mls_group_id).await;
    assert_eq!(roster(&fx.alice, &fx.mls_group_id).await.len(), 3);

    // Bob (non-admin) proposes SelfRemove.
    let proposal = fx
        .bob
        .propose_leave(&fx.mls_group_id)
        .await
        .expect("bob proposes leave");

    // Alice AND Carol ingest the proposal (each schedules an auto-commit).
    fx.alice
        .session()
        .process_event(&proposal)
        .await
        .expect("alice ingests proposal");
    fx.carol
        .session()
        .process_event(&proposal)
        .await
        .expect("carol ingests proposal");
    assert!(
        roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "the bare proposal must NOT apply the removal (jitter-delayed auto-commit)"
    );

    // Alice's auto-commit surfaces; resolve it via the shared path with a relay
    // that OK-acks. Publish-before-apply: the commit is published, THEN confirmed.
    let work = surface_auto_commit(&fx.alice, &fx.mls_group_id).await;
    let publisher = FakePublisher::new(true);
    resolve_receive_publish_work(&fx.alice, &publisher, &work).await;

    let published = publisher.published();
    assert_eq!(
        published.len(),
        1,
        "exactly one eviction commit must be published to the relay before confirming"
    );
    let commit_event = published.into_iter().next().unwrap();

    assert!(
        !roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "Alice evicts Bob only AFTER the commit was published + confirmed"
    );
    assert_eq!(
        epoch(&fx.alice, &fx.mls_group_id).await,
        epoch_before + 1,
        "Alice's epoch advances past the confirmed SelfRemove commit"
    );

    // THE invariant the gap broke: Carol, receiving the SAME published commit
    // over the relay, converges on the post-eviction roster.
    fx.carol
        .session()
        .process_event(&commit_event)
        .await
        .expect("carol ingests the published eviction commit");
    // Drain any convergence bookkeeping.
    let _ = fx
        .carol
        .session()
        .advance_convergence(&fx.mls_group_id)
        .await;

    assert!(
        !roster(&fx.carol, &fx.mls_group_id).await.contains(&bob_hex),
        "Carol converges on the post-eviction roster from the PUBLISHED commit \
         (the fork the optimistic-confirm gap produced)"
    );
    assert_eq!(
        epoch(&fx.carol, &fx.mls_group_id).await,
        epoch_before + 1,
        "Carol lands on the same post-eviction epoch as Alice"
    );
}

/// Rule 13 fail path: when NO relay acks the publish, the staged auto-commit is
/// ROLLED BACK (never optimistically confirmed) — the leaver stays in the roster
/// at the prior epoch, so the group never applies a commit no peer received.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn auto_commit_rolls_back_when_no_relay_acks() {
    let fx = build_three_member_circle(vec!["wss://group.example.com".to_string()]).await;
    let bob_hex = fx.bob_keys.public_key().to_hex();
    let epoch_before = epoch(&fx.alice, &fx.mls_group_id).await;

    let proposal = fx
        .bob
        .propose_leave(&fx.mls_group_id)
        .await
        .expect("bob proposes leave");
    fx.alice
        .session()
        .process_event(&proposal)
        .await
        .expect("alice ingests proposal");

    let work = surface_auto_commit(&fx.alice, &fx.mls_group_id).await;
    let publisher = FakePublisher::new(false); // every relay drops the publish
    resolve_receive_publish_work(&fx.alice, &publisher, &work).await;

    assert_eq!(
        publisher.published().len(),
        1,
        "a publish IS attempted (never a bare confirm)"
    );
    assert!(
        roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "with no relay ack the eviction must roll back — Bob stays in the roster \
         (Rule 13: never apply an unpublished commit)"
    );
    assert_eq!(
        epoch(&fx.alice, &fx.mls_group_id).await,
        epoch_before,
        "a rolled-back auto-commit leaves the epoch unchanged"
    );
}

/// The live-sync engine loop ([`EngineProcessor`]) drives the auto-commit through
/// the SAME publish-then-confirm path: feeding the proposal through
/// `process_group_event` PUBLISHES the eviction commit (never a bare optimistic
/// confirm) and, after the ack, evicts the leaver.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_processor_publishes_the_auto_commit_before_confirming() {
    use haven_core::relay::live_sync::{EngineProcessor, EventBus};

    let fx = build_three_member_circle(vec!["wss://group.example.com".to_string()]).await;
    let bob_hex = fx.bob_keys.public_key().to_hex();

    let proposal = fx
        .bob
        .propose_leave(&fx.mls_group_id)
        .await
        .expect("bob proposes leave");

    let fake = Arc::new(FakePublisher::new(true));
    let publisher: Arc<dyn AutoCommitPublisher> = fake.clone();
    let processor =
        EngineProcessor::with_publisher(Arc::clone(&fx.alice), EventBus::new(), publisher);

    // Feed the proposal through the real engine loop. The auto-commit is
    // jitter-delayed, so the loop re-ticks the processor with a fresh distinct
    // peer event (a Carol location) each round: its ingest drains the still-pending
    // group and drives `advance_convergence`, which surfaces the now-due
    // auto-commit — which the processor then PUBLISHES over its relay plane.
    processor
        .process_group_event(&proposal, &fx.nostr_group_id)
        .await;
    let carol_pk = fx.carol_keys.public_key();
    let mut published = false;
    for i in 0..40 {
        tokio::time::sleep(Duration::from_millis(25)).await;
        let (loc_event, _, _) = fx
            .carol
            .encrypt_location(
                &fx.mls_group_id,
                &carol_pk,
                &LocationMessage::new(1.0 + f64::from(i) * 0.01, 2.0),
                300,
            )
            .await
            .expect("carol encrypts a re-tick location");
        processor
            .process_group_event(&loc_event, &fx.nostr_group_id)
            .await;
        if !fake.published().is_empty() {
            published = true;
            break;
        }
    }

    assert!(
        published,
        "the processor must PUBLISH the auto-commit over its relay plane, not \
         optimistically confirm it"
    );
    assert!(
        !roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "after the published commit is confirmed the processor evicts the leaver"
    );
}

/// End-to-end over an in-process relay: two live-sync engines (Alice + Carol),
/// receiving the leaver's `SelfRemove` proposal, PUBLISH the eviction auto-commit
/// to the shared relay and BOTH converge on the post-eviction roster — the whole
/// live-sync path (ingest → jitter re-tick → publish → confirm → peer converge),
/// which the optimistic-confirm gap left forked.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn two_live_sync_engines_publish_and_converge_on_the_eviction() {
    use haven_core::relay::live_sync::{CircleSpec, LiveSyncCore};
    use nostr_relay_builder::MockRelay;
    use nostr_sdk::Client;

    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();

    // The circle's stored relays ARE the in-process relay, so the receive-side
    // auto-commit publisher targets a socket the engines are connected to.
    let fx = build_three_member_circle(vec![url.clone()]).await;
    let hex = hex::encode(fx.nostr_group_id);
    let bob_hex = fx.bob_keys.public_key().to_hex();
    let epoch_before = epoch(&fx.alice, &fx.mls_group_id).await;

    let alice_engine = LiveSyncCore::new_local(Arc::clone(&fx.alice), fx.alice_keys.public_key());
    let carol_engine = LiveSyncCore::new_local(Arc::clone(&fx.carol), fx.carol_keys.public_key());
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
    tokio::time::sleep(Duration::from_millis(500)).await; // both REQs register

    // Bob (non-admin) leaves; his SelfRemove proposal is published to the relay.
    let proposal = fx
        .bob
        .propose_leave(&fx.mls_group_id)
        .await
        .expect("bob proposes leave");
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

    alice_engine.stop().await;
    carol_engine.stop().await;
}
