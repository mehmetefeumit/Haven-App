//! A membership change the user asked for while the circle's sends were gated
//! is QUEUED durably by the engine — and no plane that makes no commit
//! releases it: a session only started, a background burst, the wake's
//! sweep. A plane that DRIVES, in the foreground, releases it into a durable
//! fanout and sends it.
//!
//! Every receive plane advances (C7's edges, `docs/MDK_UPSTREAM_TRACKER.md` row
//! C7). One that makes no commit advances with MDK's inputs-only
//! `advance_convergence_inputs`: the epoch still moves and the gate still
//! opens, and the change stays queued — never published, never rolled back,
//! never dropped — for the foreground's drive that owns it.
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};

use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::{
    EpochState, GroupId, MessageState, OpenMlsContentKind, PublishWork,
};
use haven_core::nostr::mls::ChangeNote;
use haven_core::relay::catchup::{
    run_catchup_all_circles, run_catchup_driving, run_catchup_in_foreground, run_refused_refetch,
};
use haven_core::relay::fanout::scripted::{Answer, ScriptedFanout};
use haven_core::relay::fanout::UnrecordedPublisher;
use haven_core::relay::fanout::{DriveMode, FanoutClock, FanoutSend, Publishing};
use haven_core::relay::live_sync::{EngineProcessor, EventBus};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use haven_core::relay::{allow_ws_loopback_for_test, RelayManager};
use nostr::{Event, Keys};
use nostr_relay_builder::MockRelay;
use tempfile::TempDir;

mod helpers;

struct Member {
    manager: Arc<CircleManager>,
    keys: Keys,
    dir: TempDir,
}

impl Member {
    fn hex(&self) -> String {
        self.keys.public_key().to_hex()
    }
}

async fn mint() -> (Member, MemberKeyPackage) {
    let dir = TempDir::new().unwrap();
    let keys = Keys::generate();
    let manager = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();
    let key_package_event = build_kp_maintenance_events(
        manager.session(),
        &keys,
        &["wss://kp.example.com".to_string()],
        None,
        None,
    )
    .await
    .expect("key package")
    .event;
    (
        Member {
            manager: Arc::new(manager),
            keys,
            dir,
        },
        MemberKeyPackage {
            key_package_event,
            inbox_relays: vec!["wss://member-inbox.example.com".to_string()],
            nip65_relays: vec![],
            nip65_write_relays: vec![],
        },
    )
}

/// Alice and Bob both admin, Carol a member, and Bob's Remove-Carol QUEUED
/// behind a future-epoch commit that Alice's `commit` will let him chain.
struct Queued {
    alice: Member,
    bob: Member,
    carol: Member,
    gid: GroupId,
    nostr_group_id: [u8; 32],
    /// Alice's relay-list commit Bob has not seen: the event whose epoch change
    /// lets Bob's gate settle.
    commit: Event,
}

impl Queued {
    async fn queued_intents(&self) -> usize {
        self.bob
            .manager
            .session()
            .queued_intent_count_for_test(&self.gid)
            .await
            .expect("read the intent queue")
    }

    async fn bob_roster_holds_carol(&self) -> bool {
        self.bob
            .manager
            .session()
            .member_pubkeys(&self.gid)
            .await
            .expect("roster")
            .contains(&self.carol.hex())
    }
}

/// Alice (admin) with Bob promoted to a second admin, and Carol a member.
async fn two_admins_and_a_member(relay: &str) -> (Member, Member, Member, GroupId, [u8; 32]) {
    let relays = vec![relay.to_string()];
    let (bob, bob_kp) = mint().await;
    let (carol, carol_kp) = mint().await;
    let alice_dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let alice_manager = CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap();
    let created = alice_manager
        .create_circle(
            &alice_keys,
            vec![bob_kp, carol_kp],
            &CircleConfig::new("Queued Intent Circle").with_relays(relays.clone()),
        )
        .await
        .expect("create circle");
    for member in [&bob, &carol] {
        let welcome = created
            .welcome_events
            .iter()
            .find(|w| w.recipient_pubkey == member.hex())
            .expect("a welcome per member");
        member
            .manager
            .process_gift_wrapped_invitation(&member.keys, &welcome.event)
            .await
            .expect("holds the welcome");
        member
            .manager
            .accept_invitation(&welcome.event.id)
            .await
            .expect("accepts");
    }
    let alice = Member {
        manager: Arc::new(alice_manager),
        keys: alice_keys,
        dir: alice_dir,
    };
    let gid = created.circle.mls_group_id.clone();

    // Bob becomes a second admin, so a removal is his to ask for.
    let promote = alice
        .manager
        .admin_handoff_for_test(&gid, &bob.keys.public_key())
        .await
        .expect("promote bob");
    for member in [&bob, &carol] {
        member
            .manager
            .ingest_for_test(&promote)
            .await
            .expect("applies the promotion");
    }
    (alice, bob, carol, gid, created.circle.nostr_group_id)
}

async fn queue_a_removal(relay: &str) -> Queued {
    queue_a_removal_between(relay, "wss://second.example.com").await
}

/// [`queue_a_removal`], with the relay Alice's first commit adds named by the
/// caller: a sweep that runs after Bob applied that commit reads it too.
async fn queue_a_removal_between(relay: &str, second: &str) -> Queued {
    let queued = gated_circle(relay, second).await;
    // Queued through the session, which keeps what the engine queues.
    assert!(
        queued
            .bob
            .manager
            .session()
            .remove_members(&queued.gid, &[queued.carol.hex()])
            .await
            .is_ok_and(|effects| !effects.queued.is_empty()),
        "precondition: the gate must QUEUE the removal rather than stage it"
    );
    assert!(
        queued.bob_roster_holds_carol().await,
        "precondition: nothing has removed carol yet"
    );
    assert_eq!(
        queued.queued_intents().await,
        1,
        "precondition: the removal is queued"
    );
    queued
}

/// Alice and Bob both admin, Carol a member, and every change Bob asks for
/// gated behind a commit of Alice's he cannot chain until `commit` reaches
/// him. Nothing is queued.
async fn gated_circle(relay: &str, second: &str) -> Queued {
    let (alice, bob, carol, gid, nostr_group_id) = two_admins_and_a_member(relay).await;

    // Alice commits twice; Bob holds only the second, whose source epoch is
    // above his tip. A commit always gates (MDK v0.10.4
    // `ConvergenceInputContext::gates_outbound`) and this one cannot chain yet,
    // so Bob's sends queue until the first commit reaches him.
    let commit = alice
        .manager
        .update_relays_for_test(&gid, &[relay.to_string(), second.to_string()])
        .await
        .expect("alice stages a relay-list commit");
    let tip = alice.manager.group_epoch(&gid).await.expect("epoch");
    alice
        .manager
        .update_relays_for_test(&gid, &[relay.to_string()])
        .await
        .expect("alice stages a second relay-list commit");
    let row = alice
        .manager
        .session()
        .stored_convergence_input_for_test(&gid, OpenMlsContentKind::Commit, tip)
        .await
        .expect("alice's own commit row at the higher epoch");
    bob.manager
        .session()
        .stage_convergence_input_for_test(&row, MessageState::Retryable, 0)
        .await
        .expect("bob holds the future-epoch commit");

    Queued {
        alice,
        bob,
        carol,
        gid,
        nostr_group_id,
        commit,
    }
}

/// A relay that acknowledges everything and remembers what it was handed.
#[derive(Default)]
struct RecordingRelay {
    published: Mutex<Vec<Event>>,
}

impl UnrecordedPublisher for RecordingRelay {
    fn publish_unrecorded<'a>(
        &'a self,
        event: &'a Event,
        _relays: &'a [String],
    ) -> Pin<Box<dyn Future<Output = bool> + Send + 'a>> {
        Box::pin(async move {
            self.published.lock().unwrap().push(event.clone());
            true
        })
    }
}

/// After a receive plane ran: the gate opened (Bob reached Alice's epochs), and
/// the removal the user asked for is still queued — the plane published
/// nothing, staged nothing and rolled nothing back.
async fn assert_still_queued_after(fx: &Queued, plane: &str, published: &[Event]) {
    assert!(
        published.is_empty(),
        "{plane}: a receive plane must publish nothing of the user's"
    );
    assert_eq!(
        fx.queued_intents().await,
        1,
        "{plane}: the removal must still be queued — never released by a receive \
         plane, never rolled back, never dropped"
    );
    assert!(
        fx.bob_roster_holds_carol().await,
        "{plane}: and nothing has removed carol"
    );
    assert!(
        matches!(
            fx.bob.manager.session().epoch_state(&fx.gid).await,
            Some(EpochState::Stable { .. })
        ),
        "{plane}: and nothing is left staged"
    );
}

/// The user-facing advance releases the queued removal intact, as the user's own
/// staged change: confirmed on an ack, it removes Carol and leaves the queue.
async fn assert_the_user_advance_releases_it(fx: &Queued) {
    let effects = fx
        .bob
        .manager
        .session()
        .advance_convergence(&fx.gid)
        .await
        .expect("the user-facing advance runs");
    let pendings: Vec<_> = effects
        .publish
        .iter()
        .filter_map(|work| match work {
            PublishWork::GroupEvolution { pending, .. } => Some(*pending),
            _ => None,
        })
        .collect();
    let [pending] = pendings.as_slice() else {
        panic!(
            "the queued removal is handed back as one staged change, got {}",
            pendings.len()
        );
    };
    fx.bob
        .manager
        .session()
        .confirm_published(*pending)
        .await
        .expect("the caller confirms it on an ack");
    assert!(
        !fx.bob_roster_holds_carol().await,
        "the released change is the removal the user asked for"
    );
    assert_eq!(fx.queued_intents().await, 0, "and it has left the queue");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_queued_removal_stays_queued_on_the_live_plane() {
    let fx = queue_a_removal("wss://group.example.com").await;
    // A session only started: nobody has claimed the foreground for it.
    let processor = EngineProcessor::new(Arc::clone(&fx.bob.manager), EventBus::new());

    let _ = processor
        .process_group_event(&fx.commit, &fx.nostr_group_id)
        .await;

    assert_still_queued_after(&fx, "the live plane", &[]).await;
    assert_the_user_advance_releases_it(&fx).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_queued_removal_stays_queued_through_the_open_advance() {
    let fx = queue_a_removal("wss://group.example.com").await;
    // Ingested through the bare engine seam and left to the open advance, which
    // is what serves its convergence window here.
    fx.bob
        .manager
        .session()
        .process_event(&fx.commit)
        .await
        .expect("bob's engine takes the commit");
    let processor = EngineProcessor::new(Arc::clone(&fx.bob.manager), EventBus::new());

    processor.drain_open_advance().await;

    assert_still_queued_after(&fx, "the open advance", &[]).await;
    assert_the_user_advance_releases_it(&fx).await;
}

/// The catch-up plane makes no commit, and what waits behind a queued change
/// is what it is there to take in: Alice's second commit, which the engine
/// takes up only once the removal has had its attempt. So the removal is set
/// aside, its circle told (`QueuedRemovalDropped`) with Carol kept as its
/// target, and the commit applied — nothing published, nothing staged.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_queued_removal_in_the_way_is_set_aside_and_told_by_the_catch_up_plane() {
    let _ = allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();
    let relay_mgr = RelayManager::new();
    let fx = queue_a_removal(&url).await;
    relay_mgr
        .publish_event(&fx.commit, std::slice::from_ref(&url))
        .await
        .expect("alice's commit reaches the relay");

    let _ = run_catchup_all_circles(&fx.bob.manager, &relay_mgr, 20).await;

    let stored = relay_mgr
        .fetch_events(
            nostr::Filter::new().kind(nostr::Kind::Custom(445)),
            std::slice::from_ref(&url),
            None,
        )
        .await
        .expect("read the relay back");
    assert!(
        stored.iter().all(|event| event.id == fx.commit.id),
        "the catch-up plane published something of the user's",
    );
    assert_eq!(
        (
            fx.queued_intents().await,
            told(&fx.bob, &fx.gid),
            epoch_of(&fx.bob, &fx.gid).await,
        ),
        (
            0,
            A_REMOVAL_SET_ASIDE.to_vec(),
            epoch_of(&fx.alice, &fx.gid).await
        ),
        "the removal in the way was kept, its circle not told, or the commit behind it \
         not applied",
    );
    assert!(
        fx.bob_roster_holds_carol().await
            && matches!(
                fx.bob.manager.session().epoch_state(&fx.gid).await,
                Some(EpochState::Stable { .. })
            ),
        "the catch-up plane made the removal, or left something staged",
    );
}

/// The poll is a plane that drives: in the foreground it gives the change
/// the user queued its attempt once the gate opens, under a record, and
/// sends it — the removal the user asked for lands.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_queued_removal_is_made_by_the_foreground_poll() {
    let fx = queue_a_removal("wss://group.example.com").await;

    let (_, sent) = fx
        .bob
        .manager
        .ingest_landing_for_test(&fx.commit)
        .await
        .expect("bob polls the commit");

    assert_eq!(
        sent.len(),
        1,
        "the queued removal was not sent under its record"
    );
    assert!(
        !fx.bob_roster_holds_carol().await && fx.queued_intents().await == 0,
        "the removal the user queued did not land, or was left queued",
    );
    fx.bob
        .manager
        .seal_location_for_test(&fx.gid, &LocationMessage::new(3.0, 4.0))
        .await
        .expect("and the circle is not left pending: bob can send again");
}

/// A plane with no relay handle, in the foreground, still records what it
/// makes: the change the user queued is given its attempt under a record and
/// sent by nothing — it is left for a plane that has a relay, which lands it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_queued_removal_is_recorded_with_no_relay_plane_and_landed_by_one_that_has() {
    let fx = queue_a_removal("wss://group.example.com").await;
    let processor = EngineProcessor::new(Arc::clone(&fx.bob.manager), EventBus::new());
    processor.for_test().set_background_burst(false);

    let _ = processor
        .process_group_event(&fx.commit, &fx.nostr_group_id)
        .await;
    let staged_at = fx.bob.manager.group_epoch(&fx.gid).await.expect("epoch");
    assert!(
        fx.queued_intents().await == 0
            && !fx
                .bob
                .manager
                .session()
                .fanout_ids_for_test(&fx.gid)
                .await
                .expect("the records are read")
                .is_empty()
            && matches!(
                fx.bob.manager.session().epoch_state(&fx.gid).await,
                Some(EpochState::PendingPublish(_))
            ),
        "the queued removal was not recorded, or left the device with no relay to send it",
    );
    assert_eq!(
        fx.bob.manager.land_staged_for_test().await.len(),
        1,
        "a plane with a relay did not send the record"
    );
    assert!(
        fx.bob.manager.group_epoch(&fx.gid).await.expect("epoch") == staged_at + 1
            && !fx.bob_roster_holds_carol().await,
        "the removal did not land",
    );
}

/// The driver's clock, set by the test.
struct DriveClock(std::sync::atomic::AtomicU64);

impl FanoutClock for DriveClock {
    fn now_ms(&self) -> u64 {
        self.0.load(std::sync::atomic::Ordering::SeqCst)
    }
}

/// A queued change of the user's that the catch-up plane releases is fanned
/// out, never rolled back. The sweep that drives applies the commit the gate
/// waited for, the engine releases the queued removal, and it is recorded in
/// that hold and sent. No relay answers: it stays staged and recorded — not
/// published once and abandoned, not rolled back, and gone from the queue.
/// When a relay does answer, the same bytes are applied.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_queued_user_evolution_released_by_the_catchup_plane_is_fanned_out_never_rolled_back() {
    let _ = allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();
    let other = MockRelay::run().await.expect("mock relay");
    let second = other.url().await.to_string();
    let relay_mgr = RelayManager::new();
    let fx = queue_a_removal_between(&url, &second).await;
    relay_mgr
        .publish_event(&fx.commit, std::slice::from_ref(&url))
        .await
        .expect("alice's commit reaches the relay");

    let transport = ScriptedFanout::default();
    for target in [&url, &second] {
        transport.answer(target, [Answer::Silent]);
    }
    let ladder = RecordingRelay::default();
    let clock = DriveClock(std::sync::atomic::AtomicU64::new(1_700_000_000_000));
    let publishing: Publishing<'_, dyn FanoutSend + '_> = Publishing {
        fanout: &transport,
        publisher: &ladder,
        clock: &clock,
        deadline_ms: None,
        mode: &DriveMode::Full,
    };
    let _ = run_catchup_driving(&fx.bob.manager, &relay_mgr, &publishing, 20).await;

    let sent = transport.calls();
    assert!(
        !sent.is_empty() && sent.iter().all(|call| call.event_id == sent[0].event_id),
        "the released removal was not sent to its circle's relays",
    );
    assert!(
        ladder.published.lock().unwrap().is_empty(),
        "a released change was handed to the ladder, which rolls back on anything \
         short of an acknowledgement",
    );
    assert_eq!(
        fx.queued_intents().await,
        0,
        "its record is its durable form now"
    );
    assert!(
        matches!(
            fx.bob.manager.session().epoch_state(&fx.gid).await,
            Some(EpochState::PendingPublish(_))
        ),
        "an unanswered removal was rolled back",
    );
    assert_eq!(
        fx.bob
            .manager
            .session()
            .fanout_ids_for_test(&fx.gid)
            .await
            .expect("the store is read")
            .len(),
        1,
    );

    // A relay answers: the same event is applied.
    for target in [&url, &second] {
        transport.answer(target, [Answer::Accepted]);
    }
    clock.0.store(
        1_700_000_000_000 + 31_000,
        std::sync::atomic::Ordering::SeqCst,
    );
    let _ = run_catchup_driving(&fx.bob.manager, &relay_mgr, &publishing, 20).await;
    let again = transport.calls();
    assert!(
        !again.is_empty()
            && again
                .iter()
                .all(|call| call.event_id == sent[0].event_id && call.payload == sent[0].payload),
        "the commit sent again was not the one recorded",
    );
    assert!(
        !fx.bob_roster_holds_carol().await,
        "the removal the user asked for was not applied on a relay's word",
    );
    assert!(
        !matches!(
            fx.bob.manager.session().epoch_state(&fx.gid).await,
            Some(EpochState::PendingPublish(_))
        ) && fx.queued_intents().await == 0,
        "the applied removal is still staged, or back in the queue",
    );
}

/// WHAT IS TRUE of a change an admin queued before the device went offline:
/// it is made at the epoch the device left at, ahead of whatever the circle
/// committed meanwhile. That is the engine's rule, not the sweep's order.
/// While an admin's change is queued the engine opens no new convergence pass
/// — it applies nothing more it has received — until that change has had its
/// one attempt (`cgka-engine/src/distributed_convergence.rs` 728-744; the
/// Marmot spec's one-attempt reservation), and only the full advance makes
/// that attempt. So a sweep cannot read the backlog first and make the change
/// after it: held back, the backlog would simply not be applied.
///
/// Here Bob's removal is queued and can be made; Alice has committed since,
/// and her commit is on the relay. The sweep that drives sends ONE commit,
/// made at the epoch before Alice's — her rival — and the two devices then
/// agree on which of the two stands.
///
/// If this fails because the commit is made at the later epoch, the engine
/// has changed and a driving plane can order the queue behind the backlog.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[allow(clippy::too_many_lines)]
async fn a_queued_admin_change_is_made_ahead_of_the_backlog_as_a_rival_the_circle_adjudicates() {
    let _ = allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();
    let relay_mgr = RelayManager::new();
    let relays = vec![url.clone()];
    let (alice, bob, carol, gid, _) = two_admins_and_a_member(&url).await;

    // Bob's removal is queued behind a commit of Alice's he has not chained.
    let first = alice
        .manager
        .update_relays_for_test(&gid, &[url.clone(), "wss://second.example.com".to_string()])
        .await
        .expect("alice stages a relay-list commit");
    let tip = alice.manager.group_epoch(&gid).await.expect("epoch");
    alice
        .manager
        .update_relays_for_test(&gid, &relays)
        .await
        .expect("alice stages a second relay-list commit");
    let row = alice
        .manager
        .session()
        .stored_convergence_input_for_test(&gid, OpenMlsContentKind::Commit, tip)
        .await
        .expect("alice's own commit row at the higher epoch");
    bob.manager
        .session()
        .stage_convergence_input_for_test(&row, MessageState::Retryable, 0)
        .await
        .expect("bob holds the future-epoch commit");
    // Through the session, which keeps what the engine queues (the circle
    // manager's own removal would take it back out).
    assert!(
        bob.manager
            .session()
            .remove_members(&gid, &[carol.hex()])
            .await
            .is_ok_and(|effects| !effects.queued.is_empty()),
        "precondition: the gate must QUEUE the removal rather than stage it"
    );
    // The gate opens on a plane that never drains the queue: Bob is settled
    // at Alice's epoch with his removal still queued, and goes offline.
    bob.manager
        .session()
        .process_event_settled_for_test(&first)
        .await
        .expect("bob chains both of alice's commits");
    let queued = bob
        .manager
        .session()
        .queued_intent_count_for_test(&gid)
        .await
        .expect("the queue");
    assert_eq!(
        (
            queued,
            bob.manager.group_epoch(&gid).await.expect("epoch"),
            matches!(
                bob.manager.session().epoch_state(&gid).await,
                Some(EpochState::Stable { .. })
            ),
        ),
        (
            1,
            alice.manager.group_epoch(&gid).await.expect("epoch"),
            true
        ),
        "precondition: settled at alice's epoch, the removal still queued",
    );

    // Alice commits once more; the commit waits on the relay for Bob.
    let later = alice
        .manager
        .update_relays_for_test(&gid, &[url.clone(), "wss://third.example.com".to_string()])
        .await
        .expect("alice stages a third commit");
    relay_mgr
        .publish_event(&later, &relays)
        .await
        .expect("alice's commit reaches the relay");
    let after_the_backlog = alice.manager.group_epoch(&gid).await.expect("epoch");

    let transport = ScriptedFanout::default();
    for target in [&url, "wss://third.example.com"] {
        transport.answer(target, [Answer::Accepted]);
    }
    let ladder = RecordingRelay::default();
    let clock = DriveClock(std::sync::atomic::AtomicU64::new(1_700_000_000_000));
    let publishing: Publishing<'_, dyn FanoutSend + '_> = Publishing {
        fanout: &transport,
        publisher: &ladder,
        clock: &clock,
        deadline_ms: None,
        mode: &DriveMode::Full,
    };
    let _ = run_catchup_driving(&bob.manager, &relay_mgr, &publishing, 20).await;

    let sent = transport.calls();
    assert!(
        !sent.is_empty() && sent.iter().all(|call| call.event_id == sent[0].event_id),
        "the sweep did not send exactly one commit",
    );
    let made_at = bob
        .manager
        .session()
        .stored_message_record_for_test(&haven_core::nostr::mls::types::MessageId::new(
            sent[0].event_id.to_bytes().to_vec(),
        ))
        .await
        .expect("the store is read")
        .expect("the commit's own row")
        .epoch
        .0;
    assert_eq!(
        made_at + 1,
        after_the_backlog,
        "a queued admin change was made after the backlog it had not read: the engine's \
         one-attempt reservation no longer orders it first",
    );

    // Two commits at one epoch: the engine's branch selection keeps one, on
    // both devices the same. Which one is its rule, not Haven's — and when
    // it is Alice's, Bob's removal is set aside though a relay acknowledged
    // it and its record had ended as applied.
    let removal =
        <Event as nostr::JsonUtil>::from_json(&sent[0].payload).expect("the frozen event");
    alice
        .manager
        .session()
        .process_event_settled_for_test(&removal)
        .await
        .expect("alice ingests bob's removal");
    let _ = bob.manager.session().settle_receive_for_test(&gid).await;
    let lists_carol = |member: &Member| {
        let manager = Arc::clone(&member.manager);
        let (gid, carol) = (gid.clone(), carol.hex());
        async move {
            manager
                .session()
                .member_pubkeys(&gid)
                .await
                .expect("roster")
                .contains(&carol)
        }
    };
    assert_eq!(
        (
            alice.manager.group_epoch(&gid).await.expect("epoch"),
            lists_carol(&alice).await,
        ),
        (
            bob.manager.group_epoch(&gid).await.expect("epoch"),
            lists_carol(&bob).await,
        ),
        "the two rival commits left the two admins on different branches",
    );
}

/// The sweep's budget crosses the FFI as a number of seconds. A figure no
/// instant can represent is clamped, at every entry of the catch-up plane,
/// not added to the clock.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_sweep_budget_no_instant_can_hold_is_clamped_at_every_entry() {
    let (member, _) = mint().await;
    let relay_mgr = RelayManager::new();
    let swept = run_catchup_all_circles(&member.manager, &relay_mgr, u64::MAX).await;
    assert_eq!(swept.circles_swept, 0);
    let refetched = run_refused_refetch(&member.manager, &relay_mgr, u64::MAX).await;
    assert_eq!(refetched.circles_swept, 0);
    let driven = run_catchup_in_foreground(&member.manager, &relay_mgr, u64::MAX).await;
    assert_eq!(driven.circles_swept, 0);
    assert!(!driven.drive_errored);
}

// ── The one-attempt reservation (protocol review of W9g2, F1) ───────────────

async fn epoch_of(member: &Member, gid: &GroupId) -> u64 {
    member.manager.group_epoch(gid).await.expect("epoch")
}

/// Alice's next commit after the two the fixture made: one more relay change,
/// applied on her own device.
async fn alice_commits_again(fx: &Queued, relays: &[&str]) -> Event {
    let relays: Vec<String> = relays.iter().map(ToString::to_string).collect();
    let commit = fx
        .alice
        .manager
        .update_relays_for_test(&fx.gid, &relays)
        .await
        .expect("alice stages another relay-list commit");
    commit
}

/// The circle as [`queue_a_removal`] leaves it, with nothing asked of Bob
/// yet: his sends are gated behind a commit of Alice's he cannot chain.
async fn gated_bob(relay: &str) -> Queued {
    let fx = gated_circle(relay, "wss://second.example.com").await;
    assert_eq!(fx.queued_intents().await, 0, "premise");
    fx
}

/// A plane only started — it makes no commit: Bob's, fed one event.
async fn through_the_ladder(fx: &Queued, event: &Event) {
    let processor = EngineProcessor::new(Arc::clone(&fx.bob.manager), EventBus::new());
    let _ = processor
        .process_group_event(event, &fx.nostr_group_id)
        .await;
}

async fn bob_seals_and_alice_reads(fx: &Queued) -> bool {
    let (sealed, _, _) = fx
        .bob
        .manager
        .seal_location_for_test(&fx.gid, &LocationMessage::new(3.0, 4.0))
        .await
        .expect("bob seals a location");
    fx.alice
        .manager
        .ingest_for_test(&sealed)
        .await
        .is_ok_and(|read| read.len() == 1)
}

/// A change of the group left QUEUED meets a plane that does not make the
/// engine's full advance: once the circle's convergence pass has closed, the
/// engine opens no other until that change has had its one attempt, which
/// such a plane cannot give it. So when a peer's next commit waits behind it
/// the change is retired, its circle told (`QueuedChangeDropped`), and the
/// commit applied: the device moves with its circle instead of sealing, send
/// after send, at an epoch the circle has left.
///
/// A queued removal holds every send away from the foreground instead
/// (`RemovalUnmade`), so the change here is one that holds none: Carol made
/// an admin.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_change_left_queued_is_retired_and_told_when_a_commit_waits_behind_it_on_a_plane_that_does_not_drive(
) {
    let fx = gated_bob("wss://group.example.com").await;
    let admins = [&fx.alice, &fx.bob, &fx.carol].map(|member| member.keys.public_key().to_bytes());
    assert!(
        fx.bob
            .manager
            .session()
            .update_admin_policy(&fx.gid, &admins)
            .await
            .is_ok_and(|effects| !effects.queued.is_empty()),
        "precondition: the gate must QUEUE the promotion rather than stage it"
    );
    through_the_ladder(&fx, &fx.commit).await;
    let caught_up = epoch_of(&fx.alice, &fx.gid).await;
    assert_eq!(
        (epoch_of(&fx.bob, &fx.gid).await, fx.queued_intents().await),
        (caught_up, 1),
        "premise: the gate opened and the change is still queued: nothing waits behind it",
    );

    let next =
        alice_commits_again(&fx, &["wss://group.example.com", "wss://third.example.com"]).await;
    through_the_ladder(&fx, &next).await;

    assert_eq!(
        (
            epoch_of(&fx.bob, &fx.gid).await,
            epoch_of(&fx.alice, &fx.gid).await,
            fx.queued_intents().await,
        ),
        (caught_up + 1, caught_up + 1, 0),
        "the change in the way was kept, or the commit behind it was not applied",
    );
    assert!(
        fx.bob
            .manager
            .session()
            .peek_change_notes(&fx.gid)
            .contains(&ChangeNote::QueuedChangeDropped),
        "the change was retired and its circle not told",
    );
    assert!(
        bob_seals_and_alice_reads(&fx).await,
        "what the device seals is not read at its circle's epoch",
    );
}

/// A leave the engine QUEUES behind a gate is taken back out of the queue
/// in the hold that queued it; a store that cannot take the retirement
/// leaves it queued behind that answer. That is said, in a line that names
/// nothing, and the circle is told durably.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_leave_queued_that_cannot_be_taken_back_is_said_and_names_nothing() {
    use haven_core::nostr::mls::storage::{set_engine_write_fault_for_test, EngineWrite};
    use haven_core::nostr::mls::StorageConfig;

    let fx = gated_bob("wss://group.example.com").await;
    // Carol is gated the way Bob is: she holds Alice's second commit and not
    // the first.
    let tip = epoch_of(&fx.alice, &fx.gid).await - 1;
    let row = fx
        .alice
        .manager
        .session()
        .stored_convergence_input_for_test(&fx.gid, OpenMlsContentKind::Commit, tip)
        .await
        .expect("alice's own commit row at the higher epoch");
    fx.carol
        .manager
        .session()
        .stage_convergence_input_for_test(&row, MessageState::Retryable, 0)
        .await
        .expect("carol holds the future-epoch commit");
    let db = StorageConfig::new(fx.carol.dir.path()).database_path();
    let key = StorageConfig::test_sqlcipher_key().expect("the test key");
    set_engine_write_fault_for_test(&db, &key, EngineWrite::QueuedIntentDelete, true).expect("arm");
    let lines = helpers::capture_haven_log(async {
        let _ = fx
            .carol
            .manager
            .session()
            .leave_group_staging_for_test(&fx.gid, 0, &DriveMode::Full)
            .await;
    })
    .await;
    set_engine_write_fault_for_test(&db, &key, EngineWrite::QueuedIntentDelete, false)
        .expect("disarm");

    assert_eq!(
        fx.carol
            .manager
            .session()
            .queued_intent_count_for_test(&fx.gid)
            .await
            .expect("read the intent queue"),
        1,
        "premise: the gate queued the leave and the store kept it",
    );
    assert!(
        fx.carol
            .manager
            .session()
            .peek_change_notes(&fx.gid)
            .contains(&ChangeNote::QueuedChangesHeld),
        "a change left queued behind an answer that said it was not made was not told \
         to its circle durably",
    );
    let said: Vec<_> = lines
        .iter()
        .filter(|line| {
            line.message
                .contains("a change reported as not made is still queued")
        })
        .cloned()
        .collect();
    assert_eq!(
        said.len(),
        1,
        "the queued change left behind was not said once"
    );
    helpers::assert_no_needles(
        &said,
        &[
            &hex::encode(fx.gid.as_slice()),
            &hex::encode(fx.nostr_group_id),
            &fx.carol.hex(),
            &fx.bob.hex(),
        ],
    );
}

// ── What a session open does with a change it finds queued ───────────────────

/// Ends `member`'s process and starts another over the same stores.
fn reopened(member: Member) -> Member {
    let Member { manager, keys, dir } = member;
    drop(Arc::try_unwrap(manager).unwrap_or_else(|_| panic!("the manager is still shared")));
    let manager = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).expect("reopens"));
    Member { manager, keys, dir }
}

fn told(member: &Member, gid: &GroupId) -> Vec<ChangeNote> {
    member.manager.session().peek_change_notes(gid)
}

/// What a circle is told when a removal its user asked for is retired
/// unmade with the member it named still in the circle: that a REMOVAL was
/// dropped — that member may still be reading.
const A_REMOVAL_SET_ASIDE: [ChangeNote; 1] = [ChangeNote::QueuedRemovalDropped];

/// Whether `member`, in a session that has only been started, is answered
/// with the typed deferral when it asks for a location for `gid`.
async fn a_started_session_seals_nothing(member: &Member, gid: &GroupId) -> bool {
    let plane = EngineProcessor::new(Arc::clone(&member.manager), EventBus::new());
    plane.for_test().note_launched();
    matches!(
        member
            .manager
            .seal_location_for_test(gid, &LocationMessage::new(3.0, 4.0))
            .await,
        Err(haven_core::circle::CircleError::EngineHeld)
    )
}

/// A change of the group found queued when a session opens is retired before
/// any advance, its circle told first — in each receive configuration. It is
/// not made later, unasked: the removal's target stays; and it holds nothing
/// back: the peer's next commit is applied.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_change_found_queued_at_an_open_is_retired_said_and_holds_nothing_back() {
    for live_sync in [true, false] {
        let mut fx = queue_a_removal("wss://group.example.com").await;
        assert!(told(&fx.bob, &fx.gid).is_empty(), "premise");
        let before = epoch_of(&fx.bob, &fx.gid).await;

        fx.bob = reopened(fx.bob);
        assert_eq!(
            (fx.queued_intents().await, told(&fx.bob, &fx.gid)),
            (0, A_REMOVAL_SET_ASIDE.to_vec()),
            "a removal found queued at the open was kept, retired with nothing said, or \
             not said as a removal",
        );

        // The commit the gate waited for, then one more of the peer's.
        let next =
            alice_commits_again(&fx, &["wss://group.example.com", "wss://third.example.com"]).await;
        for event in [&fx.commit, &next] {
            if live_sync {
                through_the_ladder(&fx, event).await;
            } else {
                let _ = fx
                    .bob
                    .manager
                    .ingest_for_test(event)
                    .await
                    .expect("the poll plane ingests");
            }
        }
        assert_eq!(
            epoch_of(&fx.bob, &fx.gid).await,
            epoch_of(&fx.alice, &fx.gid).await,
            "the device did not follow its circle after the open (live_sync={live_sync})",
        );
        assert!(epoch_of(&fx.bob, &fx.gid).await > before);
        assert!(
            fx.bob_roster_holds_carol().await,
            "the change retired at the open was made all the same",
        );

        // The member it named still reads: nothing is sealed for the circle
        // away from a claimed foreground. A session that has only been
        // started is not one.
        assert!(
            a_started_session_seals_nothing(&fx.bob, &fx.gid).await,
            "a removal retired at the open left its circle's sends unheld with the member \
             it named still in the circle (live_sync={live_sync})",
        );

        // The other admin removes that member and this device applies it.
        // Nobody the removal named is listed any more, so it holds nothing,
        // and the user is told nothing more: what they asked for is so — not
        // a removal to ask for again.
        let removal = fx
            .alice
            .manager
            .remove_members_for_test(&fx.gid, &[fx.carol.hex()])
            .await
            .expect("alice removes carol");
        let _ = fx
            .bob
            .manager
            .ingest_for_test(&removal)
            .await
            .expect("bob ingests the removal");
        assert!(
            !fx.bob_roster_holds_carol().await,
            "premise: the member is gone"
        );
        fx.bob = reopened(fx.bob);
        assert!(
            told(&fx.bob, &fx.gid).is_empty(),
            "an open still says a removal has to be asked for again when nobody it named is \
             in the circle (live_sync={live_sync})",
        );
        assert!(
            !a_started_session_seals_nothing(&fx.bob, &fx.gid).await,
            "a removal of nobody still in the circle holds its sends (live_sync={live_sync})",
        );
    }
}

/// A circle that cannot be told keeps its queued change: the note is the
/// only other trace of what the user asked for.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_change_found_queued_at_an_open_is_kept_while_its_circle_cannot_be_told() {
    let mut fx = queue_a_removal("wss://group.example.com").await;
    let circles = fx
        .bob
        .dir
        .path()
        .join(haven_core::circle::CIRCLES_DB_FILENAME);
    let arm = |armed: bool| {
        haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
        let db = rusqlite::Connection::open(&circles).expect("open the circle store");
        db.execute_batch(if armed {
            "CREATE TRIGGER test_note_insert BEFORE INSERT ON commit_notes
             BEGIN SELECT RAISE(ABORT, 'injected'); END;
             CREATE TRIGGER test_note_update BEFORE UPDATE ON commit_notes
             BEGIN SELECT RAISE(ABORT, 'injected'); END;"
        } else {
            "DROP TRIGGER test_note_insert; DROP TRIGGER test_note_update;"
        })
        .expect("the fault is set");
    };

    arm(true);
    fx.bob = reopened(fx.bob);
    assert_eq!(
        fx.queued_intents().await,
        1,
        "a queued change was retired though its circle could not be told",
    );
    arm(false);
    assert!(told(&fx.bob, &fx.gid).is_empty());

    // Nor is a removal retired whose names could not be kept: they are what
    // holds the circle's sends while the member still reads.
    let names = |armed: bool| {
        haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
        let db = rusqlite::Connection::open(&circles).expect("open the circle store");
        db.execute_batch(if armed {
            "DELETE FROM removal_targets;
             CREATE TRIGGER test_target_insert BEFORE INSERT ON removal_targets
             BEGIN SELECT RAISE(ABORT, 'injected'); END;"
        } else {
            "DROP TRIGGER test_target_insert;"
        })
        .expect("the fault is set");
    };
    names(true);
    fx.bob = reopened(fx.bob);
    assert_eq!(
        (fx.queued_intents().await, told(&fx.bob, &fx.gid)),
        (1, Vec::new()),
        "a queued removal was retired though who it named could not be kept",
    );
    names(false);

    fx.bob = reopened(fx.bob);
    assert_eq!(
        (fx.queued_intents().await, told(&fx.bob, &fx.gid)),
        (0, A_REMOVAL_SET_ASIDE.to_vec()),
    );
}

// ── The poll plane's entry on the driver ─────────────────────────────────────

/// A queued change of the user's that the poll plane releases is fanned out,
/// never rolled back. One polled event — the commit the gate waited for —
/// goes through the driver's poll entry: it is applied, the engine releases
/// the queued removal, and that is recorded in the hold and sent. No relay
/// answers: it stays staged and recorded, handed to no ladder and gone from
/// the queue. When a relay does answer, the same bytes are applied.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_queued_user_evolution_released_by_the_poll_plane_is_fanned_out_never_rolled_back() {
    let (url, second) = ("wss://group.example.com", "wss://second.example.com");
    let fx = queue_a_removal_between(url, second).await;
    let transport = ScriptedFanout::default();
    for target in [url, second] {
        transport.answer(target, [Answer::Silent]);
    }
    let ladder = RecordingRelay::default();
    let clock = DriveClock(std::sync::atomic::AtomicU64::new(1_700_000_000_000));
    let publishing = Publishing {
        fanout: &transport,
        publisher: &ladder,
        clock: &clock,
        deadline_ms: None,
        mode: &DriveMode::Full,
    };
    let polled = publishing
        .ingest_for_poll(&fx.bob.manager, &fx.commit)
        .await
        .expect("the polled event is ingested");
    assert!(!polled.errored);

    let sent = transport.calls();
    assert!(
        !sent.is_empty() && sent.iter().all(|call| call.event_id == sent[0].event_id),
        "the released removal was not sent to its circle's relays",
    );
    assert!(
        ladder.published.lock().unwrap().is_empty(),
        "a released change was handed to the publisher of what has no record",
    );
    assert_eq!(
        fx.queued_intents().await,
        0,
        "its record is its durable form now"
    );
    assert!(
        matches!(
            fx.bob.manager.session().epoch_state(&fx.gid).await,
            Some(EpochState::PendingPublish(_))
        ),
        "an unanswered removal was rolled back",
    );

    // A relay answers when it is next due: the next polled event's call
    // drives the pending record first, and the same bytes are applied.
    for target in [url, second] {
        transport.answer(target, [Answer::Accepted]);
    }
    clock.0.store(
        1_700_000_000_000 + 31_000,
        std::sync::atomic::Ordering::SeqCst,
    );
    let _ = publishing
        .ingest_for_poll(&fx.bob.manager, &fx.commit)
        .await
        .expect("a polled event is ingested");
    let again = transport.calls();
    assert!(
        !again.is_empty()
            && again
                .iter()
                .all(|call| call.event_id == sent[0].event_id && call.payload == sent[0].payload),
        "the commit sent again was not the one recorded",
    );
    assert!(
        !fx.bob_roster_holds_carol().await
            && !matches!(
                fx.bob.manager.session().epoch_state(&fx.gid).await,
                Some(EpochState::PendingPublish(_))
            )
            && fx.queued_intents().await == 0,
        "the removal the user asked for was not applied on a relay's word",
    );
}

// ── A reservation met by a call that makes no commit ─────────────────────────

/// A change of the group left queued holds its circle at its epoch for as
/// long as nothing makes the engine's full advance — and a finish-only call
/// never does. So at the moment that change is what stands in the way —
/// input the circle has received is waiting, no pass is open to take it up —
/// a finish-only call retires it, its circle told first, and the circle is
/// followed again. Not before: while the change is in nothing's way it is
/// kept for the full advance that makes it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_queued_change_that_would_hold_a_finish_only_device_at_its_epoch_is_retired_and_said() {
    let url = "wss://group.example.com";
    let fx = queue_a_removal(url).await;
    let transport = ScriptedFanout::default();
    let ladder = RecordingRelay::default();
    let clock = DriveClock(std::sync::atomic::AtomicU64::new(1_700_000_000_000));
    let publishing = Publishing {
        fanout: &transport,
        publisher: &ladder,
        clock: &clock,
        deadline_ms: Some(1_700_000_000_000 + 3_600_000),
        mode: &DriveMode::FinishOnly,
    };

    // The commit the gate waited for: nothing is behind the queued change
    // yet, and it is kept.
    let _ = publishing
        .ingest_for_poll(&fx.bob.manager, &fx.commit)
        .await
        .expect("the polled commit is ingested");
    let caught_up = epoch_of(&fx.alice, &fx.gid).await;
    assert_eq!(
        (
            epoch_of(&fx.bob, &fx.gid).await,
            fx.queued_intents().await,
            told(&fx.bob, &fx.gid),
        ),
        (caught_up, 1, Vec::new()),
        "a queued change that was in nothing's way was retired, or the gate did not open",
    );

    // The peer commits again: behind the reservation that commit would wait
    // for good.
    let next = alice_commits_again(&fx, &[url, "wss://third.example.com"]).await;
    let _ = publishing
        .ingest_for_poll(&fx.bob.manager, &next)
        .await
        .expect("the polled commit is ingested");
    assert_eq!(
        (
            epoch_of(&fx.bob, &fx.gid).await,
            fx.queued_intents().await,
            told(&fx.bob, &fx.gid),
        ),
        (caught_up + 1, 0, A_REMOVAL_SET_ASIDE.to_vec()),
        "the device stayed at its epoch behind a change no finish-only call can make, or \
         the removal went with nothing said, or not said as a removal",
    );
    assert!(
        fx.bob_roster_holds_carol().await
            && transport.calls().is_empty()
            && ladder.published.lock().unwrap().is_empty(),
        "the retired change was made, or something was sent",
    );
}

/// The same reservation met by the live plane's come-back after an open,
/// which is inputs only in every lifecycle: in a claimed foreground the
/// queued change is NOT retired — that foreground's drive gives it its full
/// advance — and nothing is said of it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_come_back_in_the_foreground_retires_no_queued_change() {
    use haven_core::relay::live_sync::LiveDriver;

    let url = "wss://group.example.com";
    let fx = queue_a_removal(url).await;
    let _ = fx
        .bob
        .manager
        .session()
        .process_event(&fx.commit)
        .await
        .expect("the commit the gate waited for is ingested");
    let next = alice_commits_again(&fx, &[url, "wss://third.example.com"]).await;
    let _ = fx
        .bob
        .manager
        .session()
        .process_event(&next)
        .await
        .expect("the peer's next commit is ingested");
    let transport = Arc::new(ScriptedFanout::default());
    let ladder = Arc::new(RecordingRelay::default());
    let processor = EngineProcessor::with_driver(
        Arc::clone(&fx.bob.manager),
        EventBus::new(),
        LiveDriver {
            fanout: Arc::clone(&transport) as Arc<dyn FanoutSend>,
            publisher: Arc::clone(&ladder) as Arc<dyn UnrecordedPublisher>,
            clock: Arc::new(DriveClock(std::sync::atomic::AtomicU64::new(
                1_700_000_000_000,
            ))),
        },
    );
    processor.for_test().note_launched();
    assert!(
        processor.for_test().prove_foreground(),
        "premise: the foreground"
    );
    fx.bob
        .manager
        .session()
        .owe_advance(std::slice::from_ref(&fx.gid));
    processor.for_test().owe_come_back();
    processor.for_test().come_back_if_owed().await;
    assert!(
        fx.queued_intents().await == 1 && told(&fx.bob, &fx.gid).is_empty(),
        "a come-back in the foreground retired the queued change, or said so",
    );
}

// ── The send entry's own repair ──────────────────────────────────────────────

/// A send whose wake has less than a fold's budget left does not begin the
/// deferred-send repair: the repair waits out the engine's own deadlines.
/// Nothing is advanced, so the invite the repair would release stays
/// queued, no relay is called, and the answer says the wake ran out and
/// what still holds the circle. The same send with the budget runs the
/// repair.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_send_with_no_room_for_the_repair_folds_nothing_and_says_the_wake_ran_out() {
    use haven_core::relay::fanout::{EvolutionStatus, LocationSeal, SendHeld, FOLD_BUDGET_MS};

    let (url, second) = ("wss://group.example.com", "wss://second.example.com");
    let fx = gated_circle(url, second).await;
    let (dave, package) = mint().await;
    let transport = ScriptedFanout::default();
    for target in [url, second] {
        transport.answer(target, [Answer::Accepted]);
    }
    let ladder = RecordingRelay::default();
    let clock = DriveClock(std::sync::atomic::AtomicU64::new(1_700_000_000_000));
    let with = |deadline_ms: Option<u64>| Publishing {
        fanout: &transport,
        publisher: &ladder,
        clock: &clock,
        deadline_ms,
        mode: &DriveMode::Full,
    };
    let invited = with(None)
        .add_members(&fx.bob.manager, &fx.gid, &[package])
        .await
        .expect("the invite is accepted");
    assert_eq!(invited.status, EvolutionStatus::Queued, "premise");
    fx.bob
        .manager
        .session()
        .process_event(&fx.commit)
        .await
        .expect("the commit is ingested");
    let fix = LocationMessage::new(3.0, 4.0);
    let on_the_roster = || async {
        fx.bob
            .manager
            .session()
            .member_pubkeys(&fx.gid)
            .await
            .expect("roster")
            .contains(&dave.hex())
    };

    let short = with(Some(1_700_000_000_000 + FOLD_BUDGET_MS - 1))
        .seal_location(&fx.bob.manager, &fx.gid, &fix)
        .await
        .expect("the send runs");
    assert!(
        matches!(short.seal, LocationSeal::Deferred(SendHeld::StoredInput)),
        "a send whose repair was not begun was sealed, or did not say what the store \
         shows still holds its circle",
    );
    assert_eq!(
        (
            short.retry_after_ms,
            fx.queued_intents().await,
            transport.calls().len(),
            on_the_roster().await,
        ),
        (Some(0), 1, 0, false),
        "a send with no room for the repair began it, or did not say the wake ran out",
    );

    let roomy = with(None)
        .seal_location(&fx.bob.manager, &fx.gid, &fix)
        .await
        .expect("the send runs");
    assert!(matches!(roomy.seal, LocationSeal::Deferred(_)));
    assert!(
        fx.queued_intents().await == 0 && on_the_roster().await,
        "control: the same send with the budget runs the repair",
    );
}

/// An invite the user queued and the deferred-send repair releases keeps its
/// Welcome obligation. The send that finds the circle gated runs the repair
/// as a plane that drives runs it: the advance applies what was waiting, the
/// engine releases the queued invite, it is recorded with its Welcome in
/// that hold, driven by the same call, and — only once a relay has
/// acknowledged the commit and the invitee is on the roster — the Welcome is
/// delivered to the invitee and completed in the engine. The location that
/// asked is deferred, and the next one is sealed.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[allow(clippy::too_many_lines)]
async fn a_queued_invite_released_by_the_deferred_send_repair_keeps_its_welcome_obligation() {
    use haven_core::relay::fanout::{EvolutionStatus, LocationSeal};

    let (url, second) = ("wss://group.example.com", "wss://second.example.com");
    let fx = gated_circle(url, second).await;
    let (dave, package) = mint().await;
    let transport = ScriptedFanout::default();
    for target in [url, second] {
        transport.answer(target, [Answer::Accepted]);
    }
    let ladder = RecordingRelay::default();
    let clock = DriveClock(std::sync::atomic::AtomicU64::new(1_700_000_000_000));
    let publishing = Publishing {
        fanout: &transport,
        publisher: &ladder,
        clock: &clock,
        deadline_ms: None,
        mode: &DriveMode::Full,
    };
    let owed_before = fx
        .bob
        .manager
        .session()
        .outstanding_welcome_count_for_test()
        .await
        .expect("welcomes");
    let invited = publishing
        .add_members(&fx.bob.manager, &fx.gid, &[package])
        .await
        .expect("the invite is accepted");
    assert_eq!(invited.status, EvolutionStatus::Queued, "premise");
    assert!(transport.calls().is_empty() && ladder.published.lock().unwrap().is_empty());

    // The commit the gate waits for arrives, and nothing advances the circle
    // before the next location is sent.
    fx.bob
        .manager
        .session()
        .process_event(&fx.commit)
        .await
        .expect("the commit is ingested");
    let fix = LocationMessage::new(3.0, 4.0);
    let sent = publishing
        .seal_location(&fx.bob.manager, &fx.gid, &fix)
        .await
        .expect("the send runs");
    assert!(
        matches!(sent.seal, LocationSeal::Deferred(_)),
        "premise: the gated circle deferred the send",
    );

    let commits = transport.calls();
    assert!(
        !commits.is_empty()
            && commits
                .iter()
                .all(|call| call.event_id == commits[0].event_id),
        "the released invite was not sent under its record",
    );
    let roster = fx
        .bob
        .manager
        .session()
        .member_pubkeys(&fx.gid)
        .await
        .expect("roster");
    assert!(roster.contains(&dave.hex()), "the invite was not applied");
    let welcomes: Vec<Event> = ladder
        .published
        .lock()
        .unwrap()
        .iter()
        .filter(|event| event.kind.as_u16() == 1059)
        .cloned()
        .collect();
    assert_eq!(
        welcomes.len(),
        1,
        "the released invite's Welcome was not delivered once"
    );
    assert!(
        welcomes[0].tags.iter().any(|tag| {
            let tag = tag.as_slice();
            tag.len() >= 2 && tag[0] == "p" && tag[1] == dave.hex()
        }),
        "the Welcome was not addressed to the invitee",
    );
    assert_eq!(
        (
            fx.bob
                .manager
                .session()
                .outstanding_welcome_count_for_test()
                .await
                .expect("welcomes"),
            fx.queued_intents().await,
        ),
        (owed_before, 0),
        "the delivered Welcome is still owed, or the invite is still queued",
    );

    let next = publishing
        .seal_location(&fx.bob.manager, &fx.gid, &fix)
        .await
        .expect("the send runs");
    assert!(
        matches!(next.seal, LocationSeal::Sealed { .. }),
        "the send after the repair is not sealed",
    );
}
