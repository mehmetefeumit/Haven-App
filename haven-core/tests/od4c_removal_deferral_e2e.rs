//! OD4-c, in its final form: a removal is made only where a commit may be
//! made, is never rolled back once a relay may hold it, and a circle the
//! engine has given up on is REPORTED — and nothing short of that is.
//!
//! Owner decision OD4-c took both halves of the crash-mid-burst problem:
//!
//! * **(iv)** a background burst must not open a publish-before-apply window for
//!   a removal-bearing auto-commit. A burst and a session only started make no
//!   commit of their own at all: the eviction comes due and stays due for the
//!   foreground (`live_plane_drive_e2e`). Every eviction is made under a durable
//!   fanout record, so a kill between SEND and OK leaves a record the next
//!   foreground drives — never a staged commit nothing will publish.
//! * **(i)** a circle that cannot recover is surfaced as a terminal per-circle
//!   verdict, so the user can re-invite instead of believing they are sharing.
//!   The verdict is the engine's own `Unrecoverable`; a backlog, an event that
//!   could not be applied, a pause and a circle awaiting its relays are not it.

use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::storage::set_stored_message_write_fault_for_test;
use haven_core::nostr::mls::types::{
    EpochState, GroupId, PendingStateRef, PublishWork, TransportMessage,
};
use haven_core::nostr::mls::{SessionManager, StorageConfig};
use haven_core::relay::fanout::scripted::{Answer, ScriptedFanout};
use haven_core::relay::fanout::{DriveMode, LocationSeal, SendHeld};
use haven_core::relay::live_sync::{
    CircleSpec, Claim, EngineProcessor, EventBus, LiveSyncCore, LiveSyncEvent, SyncStatusReason,
};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use haven_core::relay::{allow_ws_loopback_for_test, RelayManager};
use nostr::{Event, Keys};
use nostr_relay_builder::MockRelay;
use tempfile::TempDir;

mod helpers;
use helpers::drive::{through, ManualClock, Recorder};

/// Alice (admin) + Bob + Carol, each with their own real MLS store, built
/// through the PUBLIC circle API.
struct Fixture {
    alice: Arc<CircleManager>,
    alice_dir: TempDir,
    alice_keys: Keys,
    bob: Arc<CircleManager>,
    bob_keys: Keys,
    carol: Arc<CircleManager>,
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

async fn build_fixture() -> Fixture {
    build_fixture_on(vec!["wss://group.example.com".to_string()]).await
}

/// A circle Alice founded with two members who joined it.
struct Founded {
    leaver: Arc<CircleManager>,
    leaver_keys: Keys,
    other: Arc<CircleManager>,
    mls_group_id: GroupId,
    nostr_group_id: [u8; 32],
    dirs: Vec<TempDir>,
}

async fn found_circle(alice: &CircleManager, alice_keys: &Keys, relays: Vec<String>) -> Founded {
    let inbox = vec!["wss://member-inbox.example.com".to_string()];
    let (leaver, leaver_keys, leaver_member, leaver_dir) = mint_member(&inbox).await;
    let (other, other_keys, other_member, other_dir) = mint_member(&inbox).await;
    let config = CircleConfig::new("OD4-c Circle").with_relays(relays.clone());
    let result = alice
        .create_circle(alice_keys, vec![leaver_member, other_member], &config)
        .await
        .expect("create circle");
    // As the app's driven create leaves it: the founding Welcomes sent from
    // their records and acknowledged, so no later drive sends them.
    let _ = alice.land_staged_for_test().await;
    for (mgr, keys) in [(&leaver, &leaver_keys), (&other, &other_keys)] {
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
    Founded {
        leaver,
        leaver_keys,
        other,
        mls_group_id: result.circle.mls_group_id.clone(),
        nostr_group_id: result.circle.nostr_group_id,
        dirs: vec![leaver_dir, other_dir],
    }
}

/// [`build_fixture`], with the circle's relays given.
async fn build_fixture_on(group_relays: Vec<String>) -> Fixture {
    let alice_dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let alice = Arc::new(CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap());
    let founded = found_circle(&alice, &alice_keys, group_relays).await;
    Fixture {
        alice,
        alice_dir,
        alice_keys,
        bob: founded.leaver,
        bob_keys: founded.leaver_keys,
        carol: founded.other,
        mls_group_id: founded.mls_group_id,
        nostr_group_id: founded.nostr_group_id,
        _dirs: founded.dirs,
    }
}

/// Drains `circle`'s convergence until its jitter-delayed `SelfRemove`
/// auto-commit surfaces, returning the raw publish item — the wrapped commit and
/// its pending ref, exactly as a receive plane is handed it.
///
/// The engine holds the proposal for its convergence window and then the
/// auto-commit for its jitter, both on a real clock, so each advance waits for
/// the deadline the engine announces.
async fn stage_eviction_work(
    circle: &CircleManager,
    group_id: &GroupId,
) -> (TransportMessage, PendingStateRef) {
    for _ in 0..8 {
        let effects = circle
            .session()
            .stage_unrecorded_for_test(group_id)
            .await
            .expect("advance convergence");
        if let Some((msg, pending)) = effects.publish.iter().find_map(|w| match w {
            PublishWork::AutoPublish { msg, pending } => Some((msg.clone(), *pending)),
            _ => None,
        }) {
            return (msg, pending);
        }
        let wait = circle
            .session()
            .receive_retick_after(group_id)
            .await
            .expect("the engine still owes the eviction a deadline");
        tokio::time::sleep(wait).await;
    }
    panic!("the SelfRemove auto-commit never surfaced");
}

/// [`stage_eviction_work`] as the signed `kind:445` a publisher would send.
async fn stage_eviction(circle: &CircleManager, group_id: &GroupId) -> (Event, PendingStateRef) {
    let (msg, pending) = stage_eviction_work(circle, group_id).await;
    let event = SessionManager::transport_message_to_event(&msg).expect("commit event");
    (event, pending)
}

async fn roster(circle: &CircleManager, group_id: &GroupId) -> Vec<String> {
    circle.session().member_pubkeys(group_id).await.unwrap()
}

/// Whether `circle`'s engine holds a commit of its own staged for `group_id`.
async fn holds_a_staged_commit(circle: &CircleManager, group_id: &GroupId) -> bool {
    matches!(
        circle.session().epoch_state(group_id).await,
        Some(EpochState::PendingPublish(_))
    )
}

/// Asks `question` until it answers yes, for at most ten seconds, and
/// answers whether it did. The answer decides; the interval only spaces the
/// asking, so a slow machine waits longer and cannot change the verdict.
async fn comes_true<F, Fut>(question: F) -> bool
where
    F: Fn() -> Fut,
    Fut: Future<Output = bool>,
{
    for _ in 0..400 {
        if question().await {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    false
}

/// Whether the engine will accept an outbound location for `group_id` — i.e.
/// whether the group is back in `Stable` with no commit staged.
///
/// The only observable difference between "the eviction was merged" and "the
/// eviction is still staged": every projected read (`epoch`, `member_pubkeys`,
/// `converged_member_pubkeys`) reports the POST-merge state from the moment the
/// commit is staged, so none of them can tell the two apart. The send gate can.
async fn accepts_a_send(circle: &CircleManager, group_id: &GroupId) -> bool {
    circle
        .seal_location_for_test(group_id, &LocationMessage::new(1.0, 2.0))
        .await
        .is_ok()
}

// ═══════════════════════════════════════════════════════════════════════════
// (i) — a circle that cannot recover is reported, and nothing else is.
// ═══════════════════════════════════════════════════════════════════════════

/// Collects the bus events a closure produced.
fn drain(rx: &mut tokio::sync::broadcast::Receiver<LiveSyncEvent>) -> Vec<LiveSyncEvent> {
    let mut out = Vec::new();
    while let Ok(ev) = rx.try_recv() {
        out.push(ev);
    }
    out
}

fn unrecoverable_ids(events: &[LiveSyncEvent]) -> Vec<Vec<u8>> {
    events
        .iter()
        .filter_map(|ev| match ev {
            LiveSyncEvent::GroupUnrecoverable { nostr_group_id } => Some(nostr_group_id.clone()),
            _ => None,
        })
        .collect()
}

/// A paused engine reports nothing. A pause is a state, not a fault: it holds no
/// REQ and no socket, and it publishes nothing by design.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_paused_engine_reports_no_circle_unrecoverable() {
    let fx = build_fixture().await;
    let bus = EventBus::new();
    let mut rx = bus.subscribe();
    let processor = EngineProcessor::new(Arc::clone(&fx.alice), bus);
    // The pause's own signal, on a circle with nothing pending.
    processor.for_test().set_background_burst(true);
    processor.for_test().drive_due().await;

    let events = drain(&mut rx);
    assert!(
        unrecoverable_ids(&events).is_empty() && fx.alice.unrecoverable_circles().await.is_empty(),
        "a paused/backgrounded engine must not report a terminal verdict"
    );
    assert!(
        !events.iter().any(|ev| matches!(
            ev,
            LiveSyncEvent::Status {
                reason: SyncStatusReason::Paused
            }
        )),
        "and this path emits no status of its own"
    );
}

/// A FUTURE-EPOCH backlog reports nothing (Rule 12: legitimate offline backlog
/// must never be treated as a fault).
///
/// Alice is fed a location Carol encrypted at an epoch AHEAD of Alice's — the
/// shape a device that was offline across a membership commit comes back to —
/// and convergence, not a re-invite, is what resolves it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_future_epoch_backlog_reports_no_circle_unrecoverable() {
    let fx = build_fixture().await;
    let bus = EventBus::new();
    let mut rx = bus.subscribe();
    let processor = EngineProcessor::new(Arc::clone(&fx.alice), bus);

    // Bob leaves, CAROL makes the eviction and a relay acknowledges it, and
    // Carol then encrypts a location at her NEW epoch. Alice never sees the
    // commit, so that location is a future-epoch input.
    let proposal = fx
        .bob
        .propose_leave(&fx.mls_group_id)
        .await
        .unwrap()
        .expect("a first leave in this epoch proposes");
    let (_, evicted) = fx
        .carol
        .ingest_landing_for_test(&proposal)
        .await
        .expect("carol ingests the proposal");
    assert_eq!(evicted.len(), 1, "premise: carol made the eviction");
    let (future_loc, _, _) = fx
        .carol
        .seal_location_for_test(&fx.mls_group_id, &LocationMessage::new(3.0, 4.0))
        .await
        .expect("carol encrypts at her advanced epoch");

    let outcome = processor
        .process_group_event(&future_loc, &fx.nostr_group_id)
        .await;
    assert_ne!(
        outcome,
        haven_core::relay::live_sync::GroupProcessOutcome::Applied,
        "the premise: Alice could not apply Carol's post-eviction location, so this \
         IS the offline-backlog shape and not an ordinary receive"
    );
    processor.for_test().set_background_burst(false);
    processor.for_test().drive_due().await;

    assert!(
        unrecoverable_ids(&drain(&mut rx)).is_empty()
            && fx.alice.unrecoverable_circles().await.is_empty(),
        "a future-epoch input is backlog convergence drains, never a terminal \
         verdict (Rule 12)"
    );
}

/// A message that could not be applied reports nothing terminal: it is a
/// per-EVENT, self-clearing signal that names no circle.
///
/// At MDK v0.10.4 an envelope the engine cannot peel is its own terminal
/// verdict (`Ignored`), not an ingest failure, so the `Unprocessable` path is
/// driven by the one thing that still fails an ingest: a storage write fault on
/// a genuine event.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_unprocessable_event_reports_no_circle_unrecoverable() {
    let fx = build_fixture().await;
    let bus = EventBus::new();
    let mut rx = bus.subscribe();
    let processor = EngineProcessor::new(Arc::clone(&fx.alice), bus);

    let junk = nostr::EventBuilder::new(nostr::Kind::Custom(445), "not-ciphertext")
        .tag(nostr::Tag::custom(
            nostr::TagKind::custom("h"),
            [hex::encode(fx.nostr_group_id)],
        ))
        .sign_with_keys(&Keys::generate())
        .expect("sign junk");
    processor
        .process_group_event(&junk, &fx.nostr_group_id)
        .await;
    assert!(
        unrecoverable_ids(&drain(&mut rx)).is_empty(),
        "an envelope nobody can peel must never present as a terminal circle verdict"
    );

    let (genuine, _, _) = fx
        .bob
        .seal_location_for_test(&fx.mls_group_id, &LocationMessage::new(1.0, 2.0))
        .await
        .expect("bob encrypts a location");
    let key = StorageConfig::test_sqlcipher_key().expect("test key");
    let db = StorageConfig::new(fx.alice_dir.path()).database_path();
    set_stored_message_write_fault_for_test(&db, &key, true).expect("arm the write fault");
    let outcome = processor
        .process_group_event(&genuine, &fx.nostr_group_id)
        .await;
    set_stored_message_write_fault_for_test(&db, &key, false).expect("disarm the write fault");
    assert_eq!(
        outcome,
        haven_core::relay::live_sync::GroupProcessOutcome::Unprocessable,
        "premise: the engine failed the ingest"
    );

    let events = drain(&mut rx);
    assert!(
        unrecoverable_ids(&events).is_empty(),
        "one unprocessable event must never present as a terminal circle verdict"
    );
    assert!(
        events.iter().any(|ev| matches!(
            ev,
            LiveSyncEvent::Status {
                reason: SyncStatusReason::Unprocessable
            }
        )),
        "it is reported — as the per-event, self-clearing status it is"
    );
}

/// The ENGINE fact behind a rolled-back receive-side auto-commit, pinned
/// against the pinned MDK rev rather than against a Haven plane: at v0.10.4 a
/// rollback no longer drops the removal or wedges the circle.
///
/// Driven through `SessionManager::publish_failed` — the raw engine call, BELOW
/// the fanout driver, which rolls a removal back only when every relay proved
/// it refused it and none may hold it. That rollback relies on this fact: at
/// MDK `e391adc` a rollback dropped the removal permanently and left the
/// stored proposal blocking every send; at `fcc85edd` `do_publish_failed`
/// clears the self-remove-only staging residue
/// (`cgka-engine/src/publish.rs:414-455`) and re-arms the auto-commit schedule
/// from the durable rows (`publish.rs:531`).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_rolled_back_removal_commit_is_re_armed_and_the_circle_keeps_sending() {
    let fx = build_fixture().await;
    let bob_hex = fx.bob_keys.public_key().to_hex();

    let proposal = fx
        .bob
        .propose_leave(&fx.mls_group_id)
        .await
        .expect("bob proposes leave")
        .expect("a first leave in this epoch proposes");
    fx.alice
        .session()
        .process_event(&proposal)
        .await
        .expect("alice ingests the proposal");
    let (_commit_event, pending) = stage_eviction(&fx.alice, &fx.mls_group_id).await;
    assert!(
        !roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "premise: the staged commit already projects the post-eviction roster"
    );

    fx.alice
        .session()
        .publish_failed(pending)
        .await
        .expect("the engine discards the staged commit");

    assert!(
        roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "the projected post-eviction roster rolled back with the staged commit"
    );
    // The removal is not dropped: the rollback re-arms its schedule from the
    // durable proposal (`cgka-engine/src/publish.rs` 531-535), which a
    // dropped removal (MDK `e391adc`) would not have.
    assert!(
        fx.alice
            .session()
            .eviction_due_after_for_test(&fx.mls_group_id)
            .await
            .is_some(),
        "the rollback dropped the removal: no eviction is scheduled again"
    );
    // Staged again on the engine's own deadline, and confirmed.
    let (_again, pending) = stage_eviction(&fx.alice, &fx.mls_group_id).await;
    assert!(
        !roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "and the engine re-stages the same eviction"
    );
    fx.alice
        .session()
        .confirm_published(pending)
        .await
        .expect("the eviction is applied");
    // With nothing left due, a send answers for residue alone.
    assert!(
        accepts_a_send(&fx.alice, &fx.mls_group_id).await,
        "the circle no longer sends: proposal residue outlived the cleared commit"
    );
}

// ═══════════════════════════════════════════════════════════════════════════
// (iv) — a removal a relay may hold is kept, and made only in the foreground.
// ═══════════════════════════════════════════════════════════════════════════

/// Bob's leave taken in by Alice's foreground poll over `transport`, re-ticked
/// with Carol's locations until the eviction is staged — each tick waits out
/// the deadline the engine announces, never a time of this test's choosing.
async fn a_leave_made_by_the_poll(
    fx: &Fixture,
    transport: &ScriptedFanout,
    clock: &ManualClock,
) -> Event {
    let outbox = Recorder::acking(true);
    let poll = through(transport, &outbox, clock, &DriveMode::Full);
    let proposal = fx
        .bob
        .propose_leave(&fx.mls_group_id)
        .await
        .expect("bob proposes leave")
        .expect("a first leave in this epoch proposes");
    let _ = poll
        .ingest_for_poll(&fx.alice, &proposal)
        .await
        .expect("the poll runs");
    for i in 0..24 {
        if holds_a_staged_commit(&fx.alice, &fx.mls_group_id).await {
            return proposal;
        }
        let session = fx.alice.session();
        let announced = match session.eviction_due_after_for_test(&fx.mls_group_id).await {
            Some(wait) => Some(wait),
            None => session.receive_retick_after(&fx.mls_group_id).await,
        };
        tokio::time::sleep(announced.unwrap_or_default() + Duration::from_millis(5)).await;
        let (tick, _, _) = fx
            .carol
            .seal_location_for_test(
                &fx.mls_group_id,
                &LocationMessage::new(f64::from(i).mul_add(0.01, 5.0), 6.0),
            )
            .await
            .expect("carol encrypts a re-tick location");
        let _ = poll
            .ingest_for_poll(&fx.alice, &tick)
            .await
            .expect("the poll runs");
    }
    panic!("the poll never made the eviction of the member who left");
}

/// What a send for `group_id` is answered with by a plane that makes no
/// commit.
async fn send_held(circle: &CircleManager, group_id: &GroupId) -> Option<SendHeld> {
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    match through(&transport, &outbox, &clock, &DriveMode::FinishOnly)
        .seal_location(circle, group_id, &LocationMessage::new(1.0, 2.0))
        .await
        .expect("the send is answered")
        .seal
    {
        LocationSeal::Deferred(held) => Some(held),
        LocationSeal::Sealed { .. } => None,
    }
}

/// A removal the poll plane made and sent, that no relay answered, is kept:
/// a relay may hold it, so a refusal that comes later never rolls it back —
/// a rollback would put the leaver back in the circle, still able to derive
/// its keys, while a peer may already have applied the removal. The circle's
/// sends wait behind it as awaiting relays, and the first relay that
/// acknowledges it lands it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_removal_the_poll_sent_that_no_relay_answered_is_kept_and_never_rolled_back() {
    let fx = build_fixture().await;
    let bob_hex = fx.bob_keys.public_key().to_hex();
    let relay = "wss://group.example.com";
    let transport = ScriptedFanout::default();
    transport.answer(relay, [Answer::Silent]);
    let clock = ManualClock::at(0);
    a_leave_made_by_the_poll(&fx, &transport, &clock).await;
    assert!(
        !transport.calls().is_empty(),
        "premise: the eviction was sent, and no relay answered"
    );

    // Every later answer is a refusal.
    transport.answer(relay, [Answer::Refused]);
    let outbox = Recorder::acking(true);
    clock.set(3_600_000);
    let _ = through(&transport, &outbox, &clock, &DriveMode::Full)
        .resume(&fx.alice)
        .await;
    assert!(
        !transport.calls().is_empty(),
        "premise: the relay was asked again"
    );
    assert!(
        holds_a_staged_commit(&fx.alice, &fx.mls_group_id).await
            && !roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "an eviction a relay may hold was rolled back on a later refusal",
    );
    assert_eq!(
        send_held(&fx.alice, &fx.mls_group_id).await,
        Some(SendHeld::AwaitingRelays),
        "the circle's sends do not wait behind the eviction as awaiting relays",
    );

    transport.answer(relay, [Answer::Accepted]);
    clock.set(2 * 3_600_000);
    let _ = through(&transport, &outbox, &clock, &DriveMode::Full)
        .resume(&fx.alice)
        .await;
    assert!(
        !holds_a_staged_commit(&fx.alice, &fx.mls_group_id).await
            && accepts_a_send(&fx.alice, &fx.mls_group_id).await,
        "the relay that acknowledged the eviction did not land it",
    );
}

/// The claim that puts a started session in the foreground serves it as the
/// foreground's: an eviction the poll recorded and never sent is sent over
/// the session's own sockets and applied on the relay's acknowledgement. A
/// start does not make its first send, and neither does a claim of nothing:
/// neither can tell a foreground launch from a background wake that
/// cold-launched the process.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_claim_that_puts_a_session_in_the_foreground_sends_what_the_poll_left_unsent() {
    let _ = allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();
    let fx = build_fixture_on(vec![url.clone()]).await;
    let bob_hex = fx.bob_keys.public_key().to_hex();
    // A poll whose transport took no relay: recorded, never sent.
    a_leave_made_by_the_poll(&fx, &ScriptedFanout::default(), &ManualClock::at(0)).await;
    let unsent = || async {
        holds_a_staged_commit(&fx.alice, &fx.mls_group_id).await
            && fx
                .alice
                .session()
                .fanout_ids_for_test(&fx.mls_group_id)
                .await
                .is_ok_and(|ids| ids.len() == 1)
    };
    assert!(unsent().await, "premise: recorded and staged");

    let core = LiveSyncCore::new_local(
        Arc::clone(&fx.alice),
        fx.alice_keys.public_key(),
        Arc::new(RelayManager::new()),
    );
    core.start(
        &[CircleSpec {
            group_id_hex: hex::encode(fx.nostr_group_id),
            relays: vec![url],
        }],
        &[],
    )
    .await
    .expect("the session starts");
    assert!(
        unsent().await,
        "a start sent a commit for the first time: it cannot tell a foreground launch \
         from a background wake"
    );
    core.claim_foreground(Claim::Nothing).await;
    assert!(
        unsent().await,
        "a claim of nothing was served as the foreground's"
    );

    // The claim itself sends nothing: it holds the lock a pause and a stop
    // take first. The session's drive does, on its own task.
    core.claim_foreground(Claim::Foreground).await;
    assert!(
        comes_true(|| async {
            !holds_a_staged_commit(&fx.alice, &fx.mls_group_id).await
                && !roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex)
        })
        .await
            && accepts_a_send(&fx.alice, &fx.mls_group_id).await,
        "the claim that put the session in the foreground did not have the recorded \
         eviction sent and applied"
    );
    let _ = core.stop().await;
}

/// A circle MDK halted reads as such from the open on — on every read, by
/// its pseudonymous id, and again after a claim — with nothing that could
/// identify the MLS group in any rendering (Security Rule 4). No announcement
/// is needed for it: MDK's flag is persisted and re-seeded at every open.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_unrecoverable_circle_reads_as_such_from_the_open_by_its_pseudonymous_id() {
    let fx = build_fixture().await;
    let mls_group_id = fx.mls_group_id.as_slice().to_vec();
    let nostr_group_id = fx.nostr_group_id;
    assert_ne!(
        mls_group_id,
        nostr_group_id.to_vec(),
        "premise: two distinct ids"
    );
    let Fixture {
        alice,
        alice_dir,
        alice_keys,
        ..
    } = fx;
    drop(Arc::try_unwrap(alice).unwrap_or_else(|_| panic!("alice's manager is shared")));
    haven_core::nostr::mls::storage::set_group_unrecoverable_for_test(
        &haven_core::nostr::mls::StorageConfig::new(alice_dir.path()).database_path(),
        &haven_core::nostr::mls::StorageConfig::test_sqlcipher_key().expect("test key"),
        &GroupId::new(mls_group_id.clone()),
        true,
    )
    .expect("the halt is persisted");
    let alice = Arc::new(
        CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).expect("the stores reopen"),
    );
    for read in 0..2 {
        assert_eq!(
            alice.unrecoverable_circles().await,
            vec![nostr_group_id],
            "read {read}: the halted circle is named by its routing id, every time"
        );
    }

    let core = LiveSyncCore::new_local(
        Arc::clone(&alice),
        alice_keys.public_key(),
        Arc::new(RelayManager::new()),
    );
    let mut rx = core.bus().subscribe();
    core.claim_foreground(Claim::Foreground).await;
    assert_eq!(alice.unrecoverable_circles().await, vec![nostr_group_id]);
    for event in &drain(&mut rx) {
        let rendered = format!("{event:?}");
        assert!(
            !rendered.contains(&hex::encode(&mls_group_id))
                && !rendered.contains(&hex::encode(nostr_group_id)),
            "a verdict rendered a group id: {rendered}"
        );
    }
    let _ = core.stop().await;
}

/// A circle awaiting its own relays is never reported: it is a transient
/// state, not a wedge — reporting it would tell the user to re-create a
/// circle that is about to heal itself.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_circle_awaiting_its_own_ack_is_not_reported_unrecoverable() {
    let fx = build_fixture().await;
    let bus = EventBus::new();
    let mut rx = bus.subscribe();
    let transport = ScriptedFanout::default();
    transport.answer("wss://group.example.com", [Answer::Silent]);
    a_leave_made_by_the_poll(&fx, &transport, &ManualClock::at(0)).await;
    assert!(
        holds_a_staged_commit(&fx.alice, &fx.mls_group_id).await,
        "premise: pending"
    );

    let processor = EngineProcessor::new(Arc::clone(&fx.alice), bus);
    processor.for_test().set_background_burst(false);
    processor.for_test().drive_due().await;
    assert!(
        unrecoverable_ids(&drain(&mut rx)).is_empty()
            && fx.alice.unrecoverable_circles().await.is_empty(),
        "a circle awaiting its relays was reported unrecoverable",
    );
}
