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
use haven_core::nostr::mls::types::{GroupId, PendingStateRef, PublishWork, TransportMessage};
use haven_core::relay::auto_commit::{
    resolve_receive_publish_work, rollback_receive_publish_work, AutoCommitPublisher,
};
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
    const fn new(ack: bool) -> Self {
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

/// A circle with Bob's eviction commit genuinely STAGED on Alice's side but not
/// yet resolved: the fixture, the wrapped commit, its engine pending ref, and
/// the epoch the group sits at once it is rolled back.
///
/// # What `epoch_before` means, and why it is captured here
///
/// A staged commit is already reflected in what the session reports: between
/// surfacing and resolution, `member_pubkeys` ALREADY omits the leaver and
/// `epoch` ALREADY reads one higher. Only the resolution decides whether that
/// view becomes real (`confirm_published`) or is reverted (`publish_failed`).
/// So the baseline a fail-closed test must compare against is the PRE-proposal
/// epoch, captured before any of this — comparing against the armed state would
/// invert every assertion below.
///
/// The tests also need a genuinely staged ref rather than a fabricated one:
/// they assert that group state does NOT move, and against an invented ref
/// nothing would have been staged to move in the first place.
struct ArmedAutoCommit {
    fx: ThreeMemberCircle,
    msg: TransportMessage,
    pending: PendingStateRef,
    epoch_before: u64,
}

async fn arm_staged_auto_commit() -> ArmedAutoCommit {
    let fx = build_three_member_circle(vec!["wss://group.example.com".to_string()]).await;
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
    let (msg, pending) = work
        .iter()
        .find_map(|w| match w {
            PublishWork::AutoPublish { msg, pending } => Some((msg.clone(), *pending)),
            _ => None,
        })
        .expect("the surfaced batch carries the auto-commit");
    ArmedAutoCommit {
        fx,
        msg,
        pending,
        epoch_before,
    }
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

    let sent = publisher.published();
    assert_eq!(
        sent.len(),
        1,
        "exactly one eviction commit must be published to the relay before confirming"
    );
    let commit_event = sent.into_iter().next().unwrap();

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
    let mut saw_publish = false;
    for i in 0..40 {
        tokio::time::sleep(Duration::from_millis(25)).await;
        let (loc_event, _, _) = fx
            .carol
            .encrypt_location(
                &fx.mls_group_id,
                &carol_pk,
                &LocationMessage::new(f64::from(i).mul_add(0.01, 1.0), 2.0),
                300,
            )
            .await
            .expect("carol encrypts a re-tick location");
        processor
            .process_group_event(&loc_event, &fx.nostr_group_id)
            .await;
        if !fake.published().is_empty() {
            saw_publish = true;
            break;
        }
    }

    assert!(
        saw_publish,
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

    // Teardown only: every assertion has already run. The outcome is not
    // asserted here because the drain contract itself is pinned by
    // `join_tasks_*` and the `stop_*` unit tests in
    // `src/relay/live_sync/session.rs`, and by the same-store restart
    // assertions in `live_sync_cursor_replay_e2e`.
    let _ = alice_engine.stop().await;
    let _ = carol_engine.stop().await;
}

// ═══════════════════════════════════════════════════════════════════════════
// Fail-closed paths.
//
// Everything above pins the happy path and the no-ack rollback. The branches
// below are the ones that decide what happens when the publish CANNOT be
// attempted at all — no relay plane wired, an unconvertible commit, or a work
// item that has no business being on the receive side. Each of them ends in
// `publish_failed`, and each was previously reachable only by reading the code:
// a regression that turned any one of them into an optimistic `confirm_published`
// would have applied a commit no relay ever saw (Rule 13) and forked the group,
// with every existing test still green.
// ═══════════════════════════════════════════════════════════════════════════

/// The catch-up sweep's relay plane. `RelayManager::publish_auto_commit` must
/// report `true` ONLY on a real relay OK-ack, and resolve every failure — a
/// transport error, an unusable relay set — to `false` so the caller rolls back.
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
        .expect("bob proposes leave");

    let manager = RelayManager::new();
    let publisher: &dyn AutoCommitPublisher = &manager;

    assert!(
        publisher
            .publish_auto_commit(&commit, std::slice::from_ref(&url))
            .await,
        "a relay that OK-acks the commit must resolve to an ack"
    );

    // Rule 13's other half: anything short of an OK-ack is `false`, never an
    // optimistic `true`. A non-wss relay is rejected before any socket is opened,
    // so this asserts the error branch without waiting on a network timeout.
    assert!(
        !publisher
            .publish_auto_commit(&commit, &["http://not-a-relay.example".to_string()])
            .await,
        "an unusable relay set must resolve to NO ack, so the caller rolls back"
    );
}

/// A receive path with no relay plane wired rolls the staged commit back rather
/// than applying it: the leaver stays in the roster at the prior epoch, and the
/// eviction re-derives when a relay-backed path next sees the proposal.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn rollback_receive_publish_work_never_applies_a_staged_commit() {
    let ArmedAutoCommit {
        fx,
        msg,
        pending,
        epoch_before,
    } = arm_staged_auto_commit().await;
    let bob_hex = fx.bob_keys.public_key().to_hex();

    // The real staged ref rides on the AutoPublish item; the send-side variants
    // carry a ref the engine never issued. Both arms must be walked, and a ref
    // that resolves to nothing must not stop the loop before the one that does —
    // so the ordering here (unknown refs AFTER the real one) is not the
    // interesting case; the un-ordered coverage of every arm is.
    let unknown = PendingStateRef::new(u64::MAX);
    rollback_receive_publish_work(
        &fx.alice,
        &[
            PublishWork::AutoPublish {
                msg: msg.clone(),
                pending,
            },
            PublishWork::GroupEvolution {
                msg: msg.clone(),
                welcomes: vec![],
                pending: unknown,
            },
            PublishWork::GroupCreated {
                welcomes: vec![],
                pending: unknown,
            },
            // Carries no pending ref: nothing to roll back, and it must not make
            // the loop stumble over the ones that do.
            PublishWork::ApplicationMessage { msg },
        ],
    )
    .await;

    assert!(
        roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "a rolled-back eviction must leave the leaver in the roster — applying it \
         with no relay plane to publish through would fork the group"
    );
    assert_eq!(
        epoch(&fx.alice, &fx.mls_group_id).await,
        epoch_before,
        "a rolled-back auto-commit leaves the epoch unchanged"
    );
}

/// Send-side work must never be optimistically confirmed if it ever appears in a
/// receive batch. `GroupCreated` / `GroupEvolution` originate from `send`, so the
/// receive resolver treats them as a contract violation and rolls them back —
/// publishing nothing, applying nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn send_side_work_on_the_receive_path_is_rolled_back_never_confirmed() {
    let ArmedAutoCommit {
        fx,
        msg,
        pending,
        epoch_before,
    } = arm_staged_auto_commit().await;
    let bob_hex = fx.bob_keys.public_key().to_hex();

    // The resolver decides on the VARIANT alone, so wrapping the genuinely staged
    // commit in each send-side shape is what puts the branch under test — and the
    // ref really is staged, so "nothing moved" is a real observation.
    let publisher = FakePublisher::new(true);
    resolve_receive_publish_work(
        &fx.alice,
        &publisher,
        &[
            PublishWork::GroupEvolution {
                msg: msg.clone(),
                welcomes: vec![],
                pending,
            },
            PublishWork::GroupCreated {
                welcomes: vec![],
                pending,
            },
        ],
    )
    .await;

    assert!(
        publisher.published().is_empty(),
        "receive-side send work must not be published — it is a contract \
         violation, not a commit to broadcast"
    );
    assert!(
        roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "and it must be rolled back, not confirmed, even with a relay acking"
    );
    assert_eq!(
        epoch(&fx.alice, &fx.mls_group_id).await,
        epoch_before,
        "no epoch may advance on a commit this path never published"
    );
}

/// `ApplicationMessage` / `Proposal` carry no pending ref: the resolver skips
/// them entirely, publishing nothing AND — the part worth pinning — leaving a
/// co-batched staged commit still live, neither confirmed nor rolled back.
///
/// "Still live" needs an observation, not an absence. A staged commit already
/// reads as applied (see [`ArmedAutoCommit`]), so it is indistinguishable from a
/// confirmed one; what only a LIVE ref can still do is roll back. The skip is
/// therefore followed by a rollback, and the state reverting is the proof.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn work_without_a_pending_ref_is_skipped_and_disturbs_nothing() {
    let ArmedAutoCommit {
        fx,
        msg,
        pending,
        epoch_before,
    } = arm_staged_auto_commit().await;
    let bob_hex = fx.bob_keys.public_key().to_hex();

    let publisher = FakePublisher::new(true);
    resolve_receive_publish_work(
        &fx.alice,
        &publisher,
        &[
            PublishWork::ApplicationMessage { msg: msg.clone() },
            PublishWork::Proposal { msg: msg.clone() },
        ],
    )
    .await;

    assert!(
        publisher.published().is_empty(),
        "neither variant is publishable work on this path"
    );
    assert_eq!(
        epoch(&fx.alice, &fx.mls_group_id).await,
        epoch_before + 1,
        "the skip must leave the staged view exactly as it found it"
    );

    // Only a ref the engine still holds can be rolled back, so the revert below
    // is what proves the skip consumed nothing.
    rollback_receive_publish_work(&fx.alice, &[PublishWork::AutoPublish { msg, pending }]).await;
    assert!(
        roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "the staged commit must still have been rollable — proof the skip left \
         the pending ref alone rather than silently resolving it"
    );
    assert_eq!(
        epoch(&fx.alice, &fx.mls_group_id).await,
        epoch_before,
        "and the revert lands back on the pre-proposal epoch"
    );
}

/// A commit that cannot be converted to a signed `kind:445` cannot be published,
/// so it fails closed: no publish attempt, and the staged commit rolled back.
///
/// The conversion reads `msg.payload` as the transport DTO, so corrupting the
/// payload of a REAL staged auto-commit reproduces the branch without inventing
/// an engine state — the pending ref is genuine, which is what makes "the epoch
/// did not move" evidence rather than a tautology.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_unconvertible_auto_commit_rolls_back_without_publishing() {
    let ArmedAutoCommit {
        fx,
        msg,
        pending,
        epoch_before,
    } = arm_staged_auto_commit().await;
    let bob_hex = fx.bob_keys.public_key().to_hex();

    let mut corrupted = msg;
    corrupted.payload = b"not a transport-wrapped nostr event".to_vec();

    let publisher = FakePublisher::new(true);
    resolve_receive_publish_work(
        &fx.alice,
        &publisher,
        &[PublishWork::AutoPublish {
            msg: corrupted,
            pending,
        }],
    )
    .await;

    assert!(
        publisher.published().is_empty(),
        "an unconvertible commit must never reach the relay plane"
    );
    assert!(
        roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "and must roll back rather than confirm — a relay acking a DIFFERENT \
         event would otherwise apply a commit nobody received"
    );
    assert_eq!(
        epoch(&fx.alice, &fx.mls_group_id).await,
        epoch_before,
        "no epoch advance on a commit that was never published"
    );
}

/// The live-sync engine's own relay plane (`nostr_sdk::Client`) must resolve a
/// transport error to NO ack, so the caller rolls the staged commit back.
///
/// The error branch is the one that matters here and is the harder of the two to
/// reach: the success branch is exercised end-to-end by
/// `two_live_sync_engines_publish_and_converge_on_the_eviction`, but nothing
/// drives a send that fails outright. A client with an EMPTY relay pool asked to
/// send to a relay it does not hold errors before any socket work, so this needs
/// no network and cannot flake on a timeout.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn live_sync_publisher_resolves_a_transport_error_to_no_ack() {
    use nostr::{EventBuilder, Kind};
    use nostr_sdk::Client;

    let event = EventBuilder::new(Kind::Custom(445), "opaque-ciphertext")
        .sign_with_keys(&Keys::generate())
        .expect("sign");

    let client = Client::builder().build();
    let publisher: &dyn AutoCommitPublisher = &client;

    assert!(
        !publisher
            .publish_auto_commit(&event, &["wss://not-in-the-pool.example".to_string()])
            .await,
        "a send that errors must resolve to NO ack — an optimistic `true` here \
         would confirm a commit no relay ever received (Rule 13)"
    );
}
