//! A drive finishes the leave cascade it started, and is bounded without
//! losing anything.
//!
//! Confirming a peer's eviction ends in the engine's replay, which can apply the
//! NEXT leaver's proposal and schedule the next eviction. Every eviction is made
//! by the fanout driver under a durable record, and the drive asks to be run
//! again when the engine's next deadline falls due
//! ([`ResumeOutcome::retry_after_ms`]), so a cascade is finished by the drive's
//! own schedule — no later event has to arrive to notice it. What bounds a
//! drive is its wake's budget: a record it cannot see through is not begun,
//! and stays stored, staged and unattempted for the next drive. Nothing is ever
//! rolled back to tidy up.
//!
//! # How a cascade is staged here
//!
//! A `SelfRemove` proposal is valid only in its source epoch, so leavers cannot
//! all propose up front: each one has to propose at the epoch the PREVIOUS
//! eviction produced. The cascading transport below is what makes that
//! deterministic — it is a relay, so delivering the commit it was sent to the
//! remaining devices and letting the next leaver propose off the back of it is
//! exactly what a relay does.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::{EpochState, GroupId, TransportMessage};
use haven_core::nostr::mls::SessionManager;
use haven_core::relay::fanout::scripted::{Answer, ScriptedFanout};
use haven_core::relay::fanout::{
    DriveMode, FanoutClock, FanoutSend, FanoutTargetOutcome, Publishing, ResumeOutcome, Taken,
    UnrecordedPublisher, ROW_BUDGET_MS,
};
use haven_core::relay::live_sync::{EngineProcessor, EventBus, LiveDriver, LiveSyncEvent};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use nostr::{Event, Keys};
use tempfile::TempDir;

mod helpers;
use helpers::drive::{ManualClock, Recorder};

const GROUP_RELAY: &str = "wss://group.example.com";

// ============================================================================
// Fixture
// ============================================================================

struct Device {
    manager: CircleManager,
    keys: Keys,
}

impl Device {
    fn hex(&self) -> String {
        self.keys.public_key().to_hex()
    }
}

/// Alice (admin) plus `peers` co-members, each with their own real `SQLCipher`
/// MLS store, built through the PUBLIC circle API.
struct Cascade {
    alice: Arc<CircleManager>,
    alice_keys: Keys,
    alice_dir: TempDir,
    peers: Vec<Arc<Device>>,
    mls_group_id: GroupId,
    nostr_group_id: [u8; 32],
    _dirs: Vec<TempDir>,
}

async fn mint_device() -> (CircleManager, Keys, MemberKeyPackage, TempDir) {
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
    let member = MemberKeyPackage {
        key_package_event,
        inbox_relays: vec!["wss://member-inbox.example.com".to_string()],
        nip65_relays: vec![],
    };
    (manager, keys, member, dir)
}

async fn build_cascade(name: &str, peer_count: usize) -> Cascade {
    let relays = vec![GROUP_RELAY.to_string()];
    let mut peers = Vec::new();
    let mut key_packages = Vec::new();
    let mut dirs = Vec::new();
    for _ in 0..peer_count {
        let (manager, keys, member, dir) = mint_device().await;
        peers.push(Arc::new(Device { manager, keys }));
        key_packages.push(member);
        dirs.push(dir);
    }

    let alice_dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let alice = Arc::new(CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap());
    let config = CircleConfig::new(name).with_relays(relays.clone());
    let result = alice
        .create_circle(&alice_keys, key_packages, &config)
        .await
        .expect("create circle");
    for peer in &peers {
        let welcome = result
            .welcome_events
            .iter()
            .find(|w| w.recipient_pubkey == peer.hex())
            .expect("a welcome for each member");
        peer.manager
            .process_gift_wrapped_invitation(&peer.keys, &welcome.event)
            .await
            .expect("peer holds the welcome");
        peer.manager
            .accept_invitation(&welcome.event.id)
            .await
            .expect("peer accepts");
    }

    Cascade {
        alice,
        alice_keys,
        alice_dir,
        peers,
        mls_group_id: result.circle.mls_group_id.clone(),
        nostr_group_id: result.circle.nostr_group_id,
        _dirs: dirs,
    }
}

impl Cascade {
    /// Everyone still expected to be holding the circle.
    fn everyone(&self) -> Vec<Arc<Device>> {
        self.peers.clone()
    }

    async fn roster(&self) -> Vec<String> {
        self.alice
            .get_members(&self.mls_group_id)
            .await
            .expect("roster")
            .into_iter()
            .map(|m| m.pubkey)
            .collect()
    }

    /// `leaver` proposes, and everyone who needs the proposal to validate the
    /// commit that will cover it receives one.
    async fn propose_leave(&self, leaver: &Device) -> Event {
        let proposal = leaver
            .manager
            .propose_leave(&self.mls_group_id)
            .await
            .expect("the leaver proposes")
            .expect("a first leave in this epoch proposes");
        deliver(&self.alice, &self.peers, leaver, &proposal).await;
        proposal
    }
}

/// Hands `event` to Alice and to every co-member except its author.
async fn deliver(alice: &CircleManager, peers: &[Arc<Device>], author: &Device, event: &Event) {
    let _ = alice.session().process_event(event).await;
    for peer in peers {
        if peer.hex() == author.hex() {
            continue;
        }
        let _ = peer.manager.session().process_event(event).await;
    }
}

/// Whether `circle`'s engine holds a commit of its own staged for `group`.
async fn holds_a_staged_commit(circle: &CircleManager, group: &GroupId) -> bool {
    matches!(
        circle.session().epoch_state(group).await,
        Some(EpochState::PendingPublish(_))
    )
}

/// How many fanout records `circle` stores for `group`.
async fn records(circle: &CircleManager, group: &GroupId) -> usize {
    circle
        .session()
        .fanout_ids_for_test(group)
        .await
        .expect("the records are read")
        .len()
}

/// `proposal` taken in by `circle`'s foreground poll over a transport that
/// takes no relay, and its circle's driving advance served at each deadline
/// the engine announces until the eviction it brings is staged and recorded —
/// never sent.
async fn record_the_eviction(circle: &CircleManager, group: &GroupId, proposal: &Event) {
    let _ = circle.ingest_staging_for_test(proposal).await;
    // Caught up, as the poll's end of a page makes it: only then is an
    // eviction left due staged.
    circle.session().mark_caught_up_for_test(group);
    for _ in 0..12 {
        if holds_a_staged_commit(circle, group).await {
            assert_eq!(records(circle, group).await, 1, "premise: one record");
            return;
        }
        let session = circle.session();
        let announced = match session.eviction_due_after_for_test(group).await {
            Some(wait) => Some(wait),
            None => session.receive_retick_after(group).await,
        };
        tokio::time::sleep(announced.unwrap_or_default() + Duration::from_millis(5)).await;
        let _ = session.advance_for_drive(group, ManualClock::ORIGIN).await;
    }
    panic!("the eviction of the member who left was never staged");
}

/// A relay that also behaves like one: it delivers each commit it is sent to
/// the remaining devices, and lets the next scheduled leaver propose off the
/// back of it. Every send is acknowledged.
struct Cascading {
    inner: ScriptedFanout,
    alice: Arc<CircleManager>,
    group: GroupId,
    peers: Vec<Arc<Device>>,
    queue: Mutex<VecDeque<Arc<Device>>>,
    sent: Mutex<Vec<nostr::EventId>>,
}

#[async_trait::async_trait]
impl FanoutSend for Cascading {
    async fn take(&self, target: &str) -> Option<Taken> {
        self.inner.take(target).await
    }

    async fn publish(
        &self,
        target: &str,
        message: &TransportMessage,
        taken: Taken,
    ) -> FanoutTargetOutcome {
        let event = SessionManager::transport_message_to_event(message).expect("a commit event");
        self.sent.lock().unwrap().push(event.id);
        for peer in &self.peers {
            let _ = peer
                .manager
                .session()
                .process_event_settled_for_test(&event)
                .await;
        }
        let next = self.queue.lock().unwrap().pop_front();
        if let Some(leaver) = next {
            if let Ok(Some(proposal)) = leaver.manager.propose_leave(&self.group).await {
                deliver(&self.alice, &self.peers, &leaver, &proposal).await;
            }
        }
        self.inner.publish(target, message, taken).await
    }

    async fn publish_location(
        &self,
        event: &Event,
        targets: &[String],
    ) -> haven_core::relay::RelayResult<haven_core::relay::PublishResult> {
        self.inner.publish_location(event, targets).await
    }
}

/// A transport whose every send takes `by_ms` of the driver's clock: how a
/// test spends a wake's budget one row at a time.
struct Spending {
    inner: ScriptedFanout,
    clock: Arc<ManualClock>,
    by_ms: u64,
}

#[async_trait::async_trait]
impl FanoutSend for Spending {
    async fn take(&self, target: &str) -> Option<Taken> {
        self.inner.take(target).await
    }

    async fn publish(
        &self,
        target: &str,
        message: &TransportMessage,
        taken: Taken,
    ) -> FanoutTargetOutcome {
        let outcome = self.inner.publish(target, message, taken).await;
        self.clock
            .set(self.clock.now_ms() - ManualClock::ORIGIN + self.by_ms);
        outcome
    }

    async fn publish_location(
        &self,
        event: &Event,
        targets: &[String],
    ) -> haven_core::relay::RelayResult<haven_core::relay::PublishResult> {
        self.inner.publish_location(event, targets).await
    }
}

/// Drives `alice`'s stored records over `fanout` until the drive asks for
/// nothing more, waiting out each deadline the drive itself names — the
/// engine's own, which nothing can set (`docs/MDK_UPSTREAM_TRACKER.md`
/// T-CONVERGENCE-CLOCK).
async fn drive_until_settled<T: FanoutSend>(alice: &CircleManager, fanout: &T) {
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    for _ in 0..24 {
        let ResumeOutcome { retry_after_ms, .. } = Publishing {
            fanout,
            publisher: &outbox,
            clock: clock.as_ref(),
            deadline_ms: None,
            mode: &DriveMode::Full,
        }
        .resume(alice)
        .await;
        let Some(after) = retry_after_ms else {
            return;
        };
        tokio::time::sleep(Duration::from_millis(after) + Duration::from_millis(5)).await;
    }
    panic!("the drive never stopped asking to be run again");
}

/// One circle of Alice + one peer, the peer's eviction staged and recorded on
/// Alice's side and never sent.
struct RecordedCircle {
    mls_group_id: GroupId,
    peer: Arc<Device>,
    _dir: TempDir,
}

/// Builds `count` such circles inside ONE `CircleManager`. Two members each,
/// so the cost is linear in circles.
async fn record_evictions_in(
    alice: &Arc<CircleManager>,
    alice_keys: &Keys,
    count: usize,
) -> Vec<RecordedCircle> {
    let relays = vec![GROUP_RELAY.to_string()];
    let mut recorded = Vec::with_capacity(count);
    for index in 0..count {
        let (manager, keys, member, dir) = mint_device().await;
        let result = alice
            .create_circle(
                alice_keys,
                vec![member],
                &CircleConfig::new(format!("Drive Circle {index}")).with_relays(relays.clone()),
            )
            .await
            .expect("create circle");
        let welcome = &result.welcome_events[0];
        manager
            .process_gift_wrapped_invitation(&keys, &welcome.event)
            .await
            .expect("peer holds the welcome");
        manager
            .accept_invitation(&welcome.event.id)
            .await
            .expect("peer accepts");
        let peer = Arc::new(Device { manager, keys });
        let group = result.circle.mls_group_id.clone();
        let proposal = peer
            .manager
            .propose_leave(&group)
            .await
            .expect("the peer proposes leave")
            .expect("a first leave in this epoch proposes");
        record_the_eviction(alice, &group, &proposal).await;
        recorded.push(RecordedCircle {
            mls_group_id: group,
            peer,
            _dir: dir,
        });
    }
    recorded
}

/// A live plane over `alice` whose drive sends through `fanout` on `clock`.
fn plane(
    alice: &Arc<CircleManager>,
    fanout: Arc<dyn FanoutSend>,
    clock: &Arc<ManualClock>,
    bus: EventBus,
) -> EngineProcessor {
    EngineProcessor::with_driver(
        Arc::clone(alice),
        bus,
        LiveDriver {
            fanout,
            publisher: Arc::new(Recorder::acking(true)) as Arc<dyn UnrecordedPublisher>,
            clock: Arc::clone(clock) as Arc<dyn FanoutClock>,
        },
    )
}

// ============================================================================
// The drive finishes the cascade it started
// ============================================================================

/// Three leavers, one after the other. Each eviction's CONFIRM is what applies
/// the next leaver's proposal and schedules the next eviction, so a drive that
/// made one generation and stopped asking would leave two leavers in the
/// circle until some later event happened to arrive.
#[tokio::test(flavor = "multi_thread")]
async fn the_drive_finishes_the_leave_cascade_it_started_on_its_own_schedule() {
    let fx = build_cascade("Drive Cascade Circle", 3).await;
    let bob = Arc::clone(&fx.peers[0]);
    let cascading = Cascading {
        inner: ScriptedFanout::default(),
        alice: Arc::clone(&fx.alice),
        group: fx.mls_group_id.clone(),
        peers: fx.everyone(),
        queue: Mutex::new(vec![Arc::clone(&fx.peers[1]), Arc::clone(&fx.peers[2])].into()),
        sent: Mutex::new(Vec::new()),
    };
    cascading.inner.answer(GROUP_RELAY, [Answer::Accepted]);

    let proposal = fx.propose_leave(&bob).await;
    record_the_eviction(&fx.alice, &fx.mls_group_id, &proposal).await;
    drive_until_settled(fx.alice.as_ref(), &cascading).await;

    assert_eq!(
        cascading.sent.lock().unwrap().len(),
        3,
        "every generation the cascade produced must be sent by the drive's own schedule"
    );
    assert_eq!(
        fx.roster().await,
        vec![fx.alice_keys.public_key().to_hex()],
        "and applied: all three leavers are out, which only an applied commit does"
    );
    assert!(
        !holds_a_staged_commit(&fx.alice, &fx.mls_group_id).await,
        "no commit is left staged"
    );

    // A kill after the cascade: the same store opened again holds nothing a
    // next foreground would have to drive or report.
    let Cascade {
        alice,
        alice_keys,
        alice_dir,
        mls_group_id,
        ..
    } = fx;
    drop(cascading);
    drop(alice);
    let reborn = CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).expect("reopen");
    assert!(
        !holds_a_staged_commit(&reborn, &mls_group_id).await
            && reborn
                .session()
                .fanout_ids_for_test(&mls_group_id)
                .await
                .is_ok_and(|ids| ids.is_empty()),
        "a drive that finished its cascade left a record or a staged commit behind"
    );
}

// ============================================================================
// The location a drive's confirm replays reaches the plane
// ============================================================================

/// The eviction's publish-before-apply window holds whatever arrives behind
/// it unread. The drive's confirm replays that — and the plane has to be
/// handed the result, or the map shows nothing until the next delivery from
/// that peer.
#[tokio::test(flavor = "multi_thread")]
async fn a_location_replayed_by_a_drives_confirm_reaches_the_plane() {
    let fx = build_cascade("Drive Replay Circle", 2).await;
    let bob = Arc::clone(&fx.peers[0]);
    let carol = Arc::clone(&fx.peers[1]);
    // Minted BEFORE the leave reaches her: a device holding a peer's pending
    // `SelfRemove` is send-gated, which is not this test's subject.
    let (carol_fix, _, _) = carol
        .manager
        .seal_location_for_test(&fx.mls_group_id, &LocationMessage::new(45.46, 9.19))
        .await
        .expect("carol encrypts");
    let proposal = fx.propose_leave(&bob).await;
    record_the_eviction(&fx.alice, &fx.mls_group_id, &proposal).await;

    let transport = Arc::new(ScriptedFanout::default());
    transport.answer(GROUP_RELAY, [Answer::Accepted]);
    let clock = ManualClock::at(0);
    let bus = EventBus::new();
    let mut rx = bus.subscribe();
    let processor = plane(
        &fx.alice,
        Arc::clone(&transport) as Arc<dyn FanoutSend>,
        &clock,
        bus,
    );
    processor.for_test().set_background_burst(false);
    // Carol's fix arrives while Alice's eviction is staged: held unread.
    let _ = processor
        .process_group_event(&carol_fix, &fx.nostr_group_id)
        .await;
    processor.for_test().drive_due().await;

    let mut routed = false;
    while let Ok(event) = rx.try_recv() {
        if let LiveSyncEvent::Location { sender_pubkey, .. } = event {
            routed |= sender_pubkey == carol.hex();
        }
    }
    assert!(
        transport.calls().len() == 1 && routed,
        "the plane was not handed the fix the drive's confirm replayed"
    );
    let rows = fx
        .alice
        .snapshot_last_known_for_circle(&fx.nostr_group_id, chrono::Utc::now().timestamp())
        .expect("snapshot");
    assert!(
        rows.iter().any(|r| r.sender_pubkey == carol.hex()),
        "and the core has persisted it, which is why no plane re-persists"
    );
}

// ============================================================================
// route_results: every location is keyed off its OWN circle
// ============================================================================

/// A location reaches the bus under the circle its own event belongs to, never
/// under the subscription that happened to carry it. At MDK v0.10.4 an engine
/// batch no longer spans two circles (nothing emits a message before its durable
/// write, so no failed call strands one for the next to collect), so the cross
/// shape is driven the one way it still reaches the plane: another circle's
/// event delivered on this circle's subscription.
#[tokio::test(flavor = "multi_thread")]
async fn a_location_reaches_the_bus_under_its_own_circle() {
    let fx = build_cascade("Router Home Circle", 1).await;

    // A second circle in Alice's OWN store.
    let (dave_manager, dave_keys, dave_member, _dave_dir) = mint_device().await;
    let relays = vec![GROUP_RELAY.to_string()];
    let sibling = fx
        .alice
        .create_circle(
            &fx.alice_keys,
            vec![dave_member],
            &CircleConfig::new("Router Sibling Circle").with_relays(relays.clone()),
        )
        .await
        .expect("create the sibling circle");
    let sibling_ngid = sibling.circle.nostr_group_id;
    let welcome = &sibling.welcome_events[0];
    dave_manager
        .process_gift_wrapped_invitation(&dave_keys, &welcome.event)
        .await
        .expect("dave holds the welcome");
    dave_manager
        .accept_invitation(&welcome.event.id)
        .await
        .expect("dave accepts");
    let dave_fix = dave_manager
        .seal_location_for_test(
            &sibling.circle.mls_group_id,
            &LocationMessage::new(-22.9, -43.17),
        )
        .await
        .expect("dave encrypts")
        .0;

    let bus = EventBus::new();
    let mut rx = bus.subscribe();
    let processor = EngineProcessor::new(Arc::clone(&fx.alice), bus);
    // Delivered on the HOME circle's subscription.
    let _ = processor
        .process_group_event(&dave_fix, &fx.nostr_group_id)
        .await;

    let mut routed = Vec::new();
    while let Ok(event) = rx.try_recv() {
        if let LiveSyncEvent::Location {
            nostr_group_id,
            sender_pubkey,
            ..
        } = event
        {
            routed.push((nostr_group_id, sender_pubkey));
        }
    }
    assert!(
        routed.contains(&(sibling_ngid.to_vec(), dave_keys.public_key().to_hex())),
        "a location must reach the bus under ITS OWN circle — the subscription \
         that carried it belongs to a circle that peer is not even in"
    );
    assert!(
        !routed
            .iter()
            .any(|(ngid, _)| ngid.as_slice() == fx.nostr_group_id.as_slice()),
        "and never under the circle whose subscription carried it"
    );
}

// ============================================================================
// What bounds a drive
// ============================================================================

/// A drive begins no record it could not see through inside its wake: one
/// whose budget runs out after the first row sends that row alone. The
/// records it did not reach are stored, staged and unattempted — nothing is
/// rolled back, nothing dropped — and the next drive sends each exactly once.
#[tokio::test(flavor = "multi_thread")]
async fn a_drive_stops_at_its_budget_and_every_record_it_did_not_reach_stands() {
    let alice_dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let alice = Arc::new(CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap());
    let recorded = record_evictions_in(&alice, &alice_keys, 3).await;

    let clock = ManualClock::at(0);
    let spending = Spending {
        inner: ScriptedFanout::default(),
        clock: Arc::clone(&clock),
        by_ms: ROW_BUDGET_MS,
    };
    spending.inner.answer(GROUP_RELAY, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let _ = Publishing {
        fanout: &spending,
        publisher: &outbox,
        clock: clock.as_ref(),
        deadline_ms: Some(clock.now_ms() + ROW_BUDGET_MS + 1),
        mode: &DriveMode::Full,
    }
    .resume(&alice)
    .await;
    let first = spending.inner.calls();
    assert_eq!(
        first.len(),
        1,
        "a drive began a row its wake could not see through"
    );
    let mut standing = 0;
    for circle in &recorded {
        assert!(
            !alice
                .session()
                .member_pubkeys(&circle.mls_group_id)
                .await
                .expect("the roster reads")
                .contains(&circle.peer.hex()),
            "an eviction was rolled back",
        );
        if holds_a_staged_commit(&alice, &circle.mls_group_id).await
            && records(&alice, &circle.mls_group_id).await == 1
        {
            standing += 1;
        }
    }
    assert_eq!(
        standing,
        recorded.len() - 1,
        "a record the drive did not reach was rolled back, dropped or ended",
    );

    drive_until_settled(alice.as_ref(), &spending.inner).await;
    let rest = spending.inner.calls();
    assert!(
        rest.len() == recorded.len() - 1
            && rest.iter().all(|call| call.event_id != first[0].event_id),
        "the next drive did not send each record it had not reached exactly once",
    );
    for circle in &recorded {
        assert!(
            !holds_a_staged_commit(&alice, &circle.mls_group_id).await,
            "an eviction a relay acknowledged was not applied by the next drive",
        );
    }
}

/// A record driven again once its relay acknowledged it is not sent again:
/// one record, one send, and the second drive changes nothing.
#[tokio::test(flavor = "multi_thread")]
async fn a_record_driven_again_after_its_ack_is_sent_once() {
    let fx = build_cascade("Drive Duplicate Circle", 2).await;
    let bob = Arc::clone(&fx.peers[0]);
    let proposal = fx.propose_leave(&bob).await;
    record_the_eviction(&fx.alice, &fx.mls_group_id, &proposal).await;
    let transport = ScriptedFanout::default();
    transport.answer(GROUP_RELAY, [Answer::Accepted]);

    drive_until_settled(fx.alice.as_ref(), &transport).await;
    let epoch = fx.alice.group_epoch(&fx.mls_group_id).await.expect("epoch");
    drive_until_settled(fx.alice.as_ref(), &transport).await;

    assert_eq!(
        transport.calls().len(),
        1,
        "one record, one send — a drive after the ack sent it again"
    );
    assert!(
        !fx.roster().await.contains(&bob.hex())
            && fx.alice.group_epoch(&fx.mls_group_id).await.expect("epoch") == epoch,
        "the one resolution was not applied once and left as it was"
    );
}

/// A session that leaves the foreground — a pause, a stop, a logout — stops
/// its drive before it begins anything: no relay is called, and every record
/// stays as it was. The foreground that follows sends each, exactly once.
#[tokio::test(flavor = "multi_thread")]
async fn a_teardown_stops_the_drive_without_losing_a_record() {
    let alice_dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let alice = Arc::new(CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap());
    let recorded = record_evictions_in(&alice, &alice_keys, 2).await;
    let transport = Arc::new(ScriptedFanout::default());
    transport.answer(GROUP_RELAY, [Answer::Accepted]);
    let clock = ManualClock::at(0);
    let processor = plane(
        &alice,
        Arc::clone(&transport) as Arc<dyn FanoutSend>,
        &clock,
        EventBus::new(),
    );

    processor.for_test().leave_foreground();
    processor.for_test().drive_due().await;
    assert!(
        transport.calls().is_empty(),
        "a drive ran after the session left the foreground"
    );
    for circle in &recorded {
        assert!(
            holds_a_staged_commit(&alice, &circle.mls_group_id).await
                && records(&alice, &circle.mls_group_id).await == 1,
            "a teardown rolled back or ended a record",
        );
    }

    processor.for_test().set_background_burst(false);
    processor.for_test().drive_due().await;
    assert_eq!(
        transport.calls().len(),
        recorded.len(),
        "the foreground did not send each record once"
    );
    for circle in &recorded {
        assert!(
            !holds_a_staged_commit(&alice, &circle.mls_group_id).await,
            "an acknowledged eviction was not applied",
        );
    }
}

/// A background burst's drive is bounded by the burst's measured end: it
/// sends again the record that is due and fits, and begins none past it. What
/// it did not reach is stored and staged, and the next burst sends it.
#[tokio::test(flavor = "multi_thread")]
async fn a_bursts_drive_stops_at_its_budget_with_every_record_still_standing() {
    let alice_dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let alice = Arc::new(CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap());
    let recorded = record_evictions_in(&alice, &alice_keys, 2).await;
    let clock = ManualClock::at(0);
    let spending = Arc::new(Spending {
        inner: ScriptedFanout::default(),
        clock: Arc::clone(&clock),
        by_ms: ROW_BUDGET_MS,
    });
    // The first send of each, in the foreground: unanswered.
    spending.inner.answer(GROUP_RELAY, [Answer::Silent]);
    let processor = plane(
        &alice,
        Arc::clone(&spending) as Arc<dyn FanoutSend>,
        &clock,
        EventBus::new(),
    );
    processor.for_test().set_background_burst(false);
    processor.for_test().drive_due().await;
    assert_eq!(
        spending.inner.calls().len(),
        recorded.len(),
        "premise: each sent once"
    );

    clock.set(4 * 3_600_000);
    spending.inner.answer(GROUP_RELAY, [Answer::Accepted]);
    processor.for_test().set_background_burst(true);
    processor
        .for_test()
        .set_burst_budget(Some(ROW_BUDGET_MS + 1));
    processor.for_test().drive_due().await;
    assert_eq!(
        spending.inner.calls().len(),
        1,
        "a burst's drive began a row past its end"
    );
    for circle in &recorded {
        assert_eq!(
            records(&alice, &circle.mls_group_id).await,
            1,
            "a record the burst did not reach was rolled back or ended",
        );
    }

    processor.for_test().set_background_burst(true);
    processor
        .for_test()
        .set_burst_budget(Some(4 * ROW_BUDGET_MS));
    processor.for_test().drive_due().await;
    for circle in &recorded {
        assert!(
            !holds_a_staged_commit(&alice, &circle.mls_group_id).await,
            "the next burst did not land the record the first one left",
        );
    }
}
